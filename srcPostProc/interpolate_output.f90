! 2020.08.10  Keebler
! From an input location timeseries, output interpolated values
! along the trajectory.

program interpolate_output
  
  ! Read a *.outs IDL file of type ascii/real4/real8 and a satellite file,
  ! then interpolate the *.outs to the trajectory from the satellite file.

  use ModPlotFile,       ONLY: read_plot_file
  use ModTimeConvert,    ONLY: time_int_to_real, time_real_to_int
  use ModNumConst,       ONLY: cRadToDeg, cDegToRad
  use ModInterpolate,    ONLY: interpolate_vector, bilinear
  use ModCoordTransform, ONLY: atan2_check
  use ModUtilities,      ONLY: open_file, close_file
  use ModIoUnit,         ONLY: UnitTmp_
  
  implicit none

  integer:: iError      ! I/O error
  integer:: iTime_I(7)  ! array for year, month ... msec
  real   :: Time        ! time in number of seconds since 00UT 1965/1/1
  real   :: StartTime   ! start time in seconds since 00UT 1965/1/1

  ! Point position file
  character(len=100):: NameFilePoints ! name of position file
  character(len=100):: StringLine     ! single line from trajectory file
  character(len=3)  :: NameCoordPoint ! coordinate system of the points
  real, allocatable :: TrajTime_I(:)  ! simulation time from trajectory file
  character(len=3), allocatable:: NameMag_I(:) ! name of magnetic stations
  real, allocatable :: CoordPoint_DI(:,:) ! positions
  real, allocatable :: CoordIn_DI(:,:)    ! positions in the input file system
  real, allocatable :: CoordNorm_DI(:,:)  ! normalized positions 
  integer           :: nPoint         ! number of points for interpolation
  
  ! Input mulit-D file
  character(len=100):: NameFileIn     ! name of input data file
  character(len=10) :: TypeFileIn     ! ascii/real4/real8
  character(len=3)  :: NameCoordIn    ! coordinate system of input data file
  character(len=500):: NameVar
  integer           :: nDim, nVar
  logical           :: IsCartesian
  real, allocatable :: Var_VII(:,:,:)
  integer           :: n1, n2, n3     ! grid size
  integer           :: nSnapshot      ! number of snapshots to be read

  ! Interpolated file
  character(len=100):: NameFileOut      ! name of output file
  character(len=100):: NameDirOut       ! name of output directory

  logical:: IsMagStation = .false., IsTrajectory = .true.

  character(len=*), parameter:: NameProgram = 'interpolate_output'
  !-------------------------------------------------------------------------

  write(*,*) NameProgram,': start read_parameters'
  call read_parameters
  write(*,*) NameProgram,': start read_positions'
  call read_positions
  write(*,*) NameProgram,': start read_through_first'
  call read_through_first

  if(IsTrajectory)then
     write(*,*) NameProgram,': start interpolate_trajectory'
     call interpolate_trajectory
  elseif(IsMagStation)then
     write(*,*) NameProgram,': start interpolate_mag_station'
     call interpolate_mag_station
  end if
  write(*,*) NameProgram,' finished'

contains
  !===========================================================================
  subroutine read_parameters

    use ModUtilities, ONLY: fix_dir_name, make_dir
    
    ! Read  file names and types from STDIN (can be piped in from a file):
    !
    ! z=0_mhd_1_e19970517-033600-000.outs
    ! real4
    ! MARS.dat
    ! my_interpolated_output.dat
    !
    ! Input data file MUST contain the simulation start time in the filename.
    ! for accurate conversion between satellite time and simulation time.

    integer:: i
    !-------------------------------------------------------------------------
    
    write(*,'(a)', ADVANCE='NO') 'Name of multi-dimensional data file:    '
    read(*,'(a)',iostat=iError) NameFileIn

    ! Figure out if we extract magnetometer stations or trajectories
    IsMagStation = index(NameFileIn, 'mag_grid') > 0
    IsTrajectory = .not. IsMagStation

    write(*,'(a,a,l1)') trim(NameFileIn), ', IsMagStation=', IsMagStation

    ! Get simulation start date-time from filename *_e(....)
    i = index(NameFileIn, '_e') + 2
    iTime_I = 0
    read(NameFileIn(i:i+14),'(i4,2i2,1x,3i2)', iostat=iError) iTime_I(1:6)
    if(iError /= 0)then
       write(*,*) NameProgram,': could not read date from file name ', &
            trim(NameFileIn)
       STOP
    end if
    call time_int_to_real(iTime_I, StartTime)
    write(*,*) NameProgram,': StartTime=', iTime_I

    ! Set default coordinate systems
    if(IsMagStation)then
       NameCoordIn    = 'GEO'
       NameCoordPoint = 'GEO'
    else
       NameCoordIn    = 'HGI'
       NameCoordPoint = 'HGI'
    end if

    write(*,'(a)', ADVANCE='NO') 'Type of input file (ascii/real4/real8): '
    read(*,'(a)',iostat=iError) TypeFileIn
    select case(TypeFileIn)
    case('ascii','real4','real8')
       write(*,'(a)') trim(TypeFileIn)
    case default
       write(*,*) NameProgram//': incorrect TypeFileIn='//TypeFileIn
       STOP
    end select
    write(*,'(a)', ADVANCE='NO') 'Name of file containing positions:      '
    read(*,'(a)',iostat=iError) NameFilePoints
    write(*,'(a)') trim(NameFilePoints)
    if(IsMagStation)then
       write(*,'(a)', ADVANCE='NO') 'Name of output directory:               '
       read(*,'(a)',iostat=iError) NameDirOut
       if(NameDirOut == '' .or. NameDirOut == '.')then
          NameDirOut = './'
       else
          call fix_dir_name(NameDirOut)
          call make_dir(NameDirOut)
       end if
    else
       write(*,'(a)', ADVANCE='NO') 'Name of output file:                    '
       read(*,'(a)',iostat=iError) NameFileOut
    end if

  end subroutine read_parameters
  !============================================================================
  subroutine read_positions

    ! File should be in the same format as satellite/magnetometer station files
    ! Coordinate system is either read or assumed to be the same as the
    ! data file. Data lines follow the #START command. Examples:
    !
    ! Satellite file:
    !
    ! year mo dy hr mn sc msc x y z
    ! #START
    !  1997 5 17 3 35 00 000 -0.368 5.275 0.0
    !  ...
    !
    ! Magnetometer station file:
    !
    ! #COORD
    ! MAG
    !
    ! name lat lon
    ! #START
    ! YKC 68.93 299.36
    ! ...

    integer:: iPoint         ! line number in position file
    real:: Lon, Lat
    !--------------------------------------------------------------------------
    ! Open the position file
    call open_file(File=NameFilePoints, Status="old", NameCaller=NameProgram)

    ! Find the number of points in the point position file
    ! Read the header first
    do
       read(UnitTmp_,'(a)',iostat=iError) StringLine
       if(iError /= 0)then
          write(*,*) NameProgram//': no #START in position file'
          STOP
       end if
       if(StringLine(1:5) == '#COOR') &
            read(UnitTmp_,'(a3)') NameCoordPoint
       if(index(StringLine, '#START') > 0) EXIT
    end do
    ! Count points
    nPoint = 0
    do
       read(UnitTmp_, '(a)', iostat=iError) StringLine
       if(iError /= 0) EXIT
       ! DST is not a real magnetometer station
       if(IsMagStation .and. StringLine(1:3) == 'DST') CYCLE
       nPoint = nPoint + 1
    enddo

    write(*,*) NameProgram, ': nPoint=', nPoint,', CoordPoint=', NameCoordPoint

    ! Allocate arrays to hold times/positions
    if(IsTrajectory) allocate(TrajTime_I(nPoint))
    if(IsMagStation) allocate(NameMag_I(nPoint))
    allocate(CoordPoint_DI(2,nPoint), CoordIn_DI(2,nPoint))

    ! Rewind to start of file for reading times/positions.
    rewind(unit=UnitTmp_) 

    ! Skip header
    do
       read(UnitTmp_,'(a)') StringLine
       if(index(StringLine, '#START') > 0) EXIT
    end do

    ! Read point information
    do iPoint = 1, nPoint
       read(UnitTmp_,'(a)') StringLine
       if(IsMagStation)then
          ! DST is not a real station, so skip it
          if(StringLine(1:3) == 'DST') read(UnitTmp_,'(a)') StringLine

          read(StringLine, *, iostat=iError) NameMag_I(iPoint), Lat, Lon
          if(Lon < -360 .or. Lon > 360 .or. Lat < -90 .or. Lat > 90)then
             write(*,*) NameProgram//': incorrect Lat, Lon values in '//trim(StringLine)
             STOP
          end if
          if(Lon < 0) Lon = Lon + 360
          CoordPoint_DI(:,iPoint) = [ Lon, Lat ]
       else
          read(StringLine, *, iostat=iError) iTime_I, CoordPoint_DI(:,iPoint)
       end if
       if(iError /= 0)then
          write(*,*) NameProgram,': error reading line ',iPoint,':'
          write(*,*) trim(StringLine)
          STOP
       end if

       if(IsTrajectory)then
          ! Convert integer time to simulation time.
          call time_int_to_real(iTime_I, Time)
          TrajTime_I(iPoint) = Time - StartTime
       end if
    enddo

    ! Close the trajectory file.
    call close_file(NameCaller=NameProgram)

  end subroutine read_positions
  !============================================================================
  subroutine read_through_first

    ! Read first snapshot to figure out start time, coordinates,
    ! coordinate system, number of snapshots
    
    use ModCoordTransform, ONLY: xyz_to_lonlat, lonlat_to_xyz
    use CON_planet, ONLY: init_planet_const, set_planet_defaults
    use CON_axes, ONLY: init_axes, transform_matrix

    character(len=500):: StringHeader
    integer:: iPoint
    real:: Time, CoordMax_D(2), CoordMin_D(2), dCoord_D(2)
    real:: PointToIn_DD(3,3), XyzPoint_D(3), XyzIn_D(3)
    !-------------------------------------------------------------------------
    call read_plot_file(&
         NameFile = NameFileIn,          &
         TypeFileIn = TypeFileIn,        &
         StringHeaderOut = StringHeader, &
         NameVarOut = NameVar,           &
         TimeOut = Time,                 & ! simulation time
         nDimOut = nDim,                 & ! number of dimensions
         IsCartesianOut = IsCartesian,   &
         nVarOut = nVar,                 & ! number of variables
         n1Out = n1,                     & ! grid sizes
         n2Out = n2 )

    write(*,*) NameProgram,': initial Time=', Time,', n1=', n1, ', n2=', n2
    write(*,*) NameProgram,': nDim=', nDim, ', nVar=', nVar, ', NameVar=', &
         trim(NameVar)

    if(nDim /= 2)then
       write(*,*) NameProgram//' only works for 2D input file for now'
       STOP
    end if

    if(IsMagStation)then
       ! Extract coordinate system
       if(index(StringHeader, 'GEO') > 0) NameCoordIn = 'GEO'
       if(index(StringHeader, 'MAG') > 0) NameCoordIn = 'MAG'
       if(index(StringHeader, 'SMG') > 0) NameCoordIn = 'SMG'
       if(index(StringHeader, 'GSM') > 0) NameCoordIn = 'GSM'
       write(*,*) NameProgram,': CoordIn=', NameCoordIn
    end if

    ! Fix start time (subtract simulation time)
    StartTime = StartTime - Time

    ! Convert point coordinates into the input coordinates
    if(NameCoordIn /= NameCoordPoint)then
       ! This works when the two coordinates systems don't move relative
       ! to each other, like GEO and MAG
       call init_planet_const
       call set_planet_defaults
       call init_axes(StartTime)
       
       PointToIn_DD = transform_matrix(0.0, NameCoordPoint, NameCoordIn)
       write(*,*) NameProgram, &
            ': convert from ', NameCoordPoint, ' to ', NameCoordIn
       do iPoint = 1, nPoint
          call lonlat_to_xyz(CoordPoint_DI(:,iPoint)*cDegToRad, XyzPoint_D)
          XyzIn_D = matmul(PointToIn_DD, XyzPoint_D)
          call xyz_to_lonlat(XyzIn_D, CoordIn_DI(:,iPoint))
       end do
       CoordIn_DI = cRadToDeg*CoordIn_DI
    else
       CoordIn_DI = CoordPoint_DI
    end if

    ! Allocate variable array
    allocate(Var_VII(nVar,n1,n2))

    ! Get coordinate limits
    call read_plot_file(NameFileIn, TypeFileIn=TypeFileIn, iUnitIn=UnitTmp_, &
         VarOut_VII=Var_VII, &
         CoordMinOut_D=CoordMin_D, CoordMaxOut_D=CoordMax_D, iErrorOut=iError)

    if(iError /= 0)then
       write(*,*) NameProgram//': could not read first snapshot, iError=', iError
       STOP
    end if
    
    dCoord_D = (CoordMax_D - CoordMin_D)/ [n1-1, n2-1]

    write(*,*) NameProgram,': CoordMin_D=', CoordMin_D
    write(*,*) NameProgram,': CoordMax_D=', CoordMax_D
    write(*,*) NameProgram,': dCoord_D  =', dCoord_D
    
    ! Normalize point coordinates
    allocate(CoordNorm_DI(2,nPoint))
    do iPoint = 1, nPoint
       CoordNorm_DI(:,iPoint) = &
            1 + (CoordIn_DI(:,iPoint) - CoordMin_D) / dCoord_D
    end do

    ! Read the whole file through to get the number of snapshots
    nSnapshot = 1
    do
       call read_plot_file(NameFileIn, TypeFileIn=TypeFileIn, iUnitIn=UnitTmp_, &
            VarOut_VII=Var_VII, &
            TimeOut = Time, iErrorOut=iError)

       if(iError /= 0) EXIT
       if(IsTrajectory)then
          if(Time < TrajTime_I(1)) CYCLE  ! before start of trajectory file
          if(Time > TrajTime_I(nPoint)) EXIT  ! after end of trajectory file
       end if
       nSnapshot = nSnapshot + 1
    end do
    close(UnitTmp_)

    write(*,*) NameProgram,': nSnapshot=', nSnapshot
    
  end subroutine read_through_first
  !============================================================================
  subroutine interpolate_mag_station

    ! Interpolate dB to the position of the magnetometer stations

    real,    allocatable:: dB_DG(:,:,:)  ! deltaB on Lon-Lat grid
    real,    allocatable:: dB_DII(:,:,:) ! deltaB per snapshot and station
    integer, allocatable:: iTime_II(:,:) ! Date-time for each snapshot

    real:: Time ! simulation time
    integer:: iSnapshot, iPoint
    !-------------------------------------------------------------------------
    ! Extra cell for periodic longitudes
    allocate(dB_DG(3,n1+1,n2), dB_DII(3,nSnapshot,nPoint), &
         iTime_II(6,nSnapshot))

    do iSnapshot = 1, nSnapshot
       ! Read variable and time
       call read_plot_file(NameFileIn, TypeFileIn=TypeFileIn, iUnitIn=UnitTmp_, &
            TimeOut = Time, VarOut_VII=Var_VII, iErrorOut=iError)

       if(iError /= 0)then
          write(*,*) NameProgram,' ERROR reading iSnapshot,iError=', iSnapshot,iError
          EXIT
       end if

       call time_real_to_int(StartTime + Time, iTime_I)
       iTime_II(:,iSnapshot) = iTime_I(1:6)

       ! Copy the first three variables (dBn dBe dBd)
       dB_DG(:,1:n1,:) = Var_VII(1:3,:,:)

       ! Apply periodic longitudes
       dB_DG(:,n1+1,:) = dB_DG(:,1,:)

       do iPoint = 1, nPoint
          dB_DII(:,iSnapshot,iPoint) = &
               bilinear(dB_DG, 3, 1, n1+1, 1, n2, CoordNorm_DI(:,iPoint), &
               DoExtrapolate=.false.)
       end do
    end do
    close(UnitTmp_)
    
    do iPoint = 1, nPoint
       call open_file(FILE=trim(NameDirOut)//NameMag_I(iPoint)//'.txt')
       write(UnitTmp_, '(a)') &
            '# North, East and vertical components of magnetic field in nT'
       write(UnitTmp_, '(a)') &
            '# computed from magnetosphere and ionosphere currents'
       write(UnitTmp_, '(a,2f10.3)') &
            '# '//NameCoordPoint//' lon, lat=', CoordPoint_DI(:,iPoint)
       if(NameCoordIn /= NameCoordPoint) write(UnitTmp_, '(a,2f10.3)') &
            '# '//NameCoordIn//' lon, lat=', CoordIn_DI(:,iPoint)
       write(UnitTmp_, '(a)') &
            '# Station: '//NameMag_I(iPoint)
       write(UnitTmp_, '(a)') &
            'Year Month Day Hour Min Sec '// &
            'B_NorthGeomag B_EastGeomag B_DownGeomag'       
       do iSnapshot = 1, nSnapshot
          write(UnitTmp_,'(i4,5i3,3f10.3)') &
               iTime_II(:,iSnapshot), dB_DII(:,iSnapshot,iPoint)
       end do
       call close_file
    end do

    deallocate(iTime_II, dB_DG, dB_DII)
    
  end subroutine interpolate_mag_station
  !============================================================================
  subroutine interpolate_trajectory

    ! Interpolate trajectory position to snapshot time and
    ! then interpolate state variables to this position and write it out

    real, allocatable:: Coord_DII(:,:,:)
    real, allocatable:: InterpData_VI(:,:) ! fully interpolated output
    real, allocatable:: InterpCoord_DI(:,:)! time interpolated trajectory
    real, allocatable:: TimeOut_I(:)       ! time of snapshots

    real   :: InterpCoord_D(2) ! interpolated trajectory coordinates
    real   :: RadMin, RadMax, PhiMin, PhiMax, dPhi
    integer:: Weight
    integer:: iTrajTimestamp, iSnapshot ! loop indices
    !-------------------------------------------------------------------------

    ! Create arrays to hold interpolated data.
    allocate(                               & 
         Coord_DII(nDim, n1, 0:n2+1),       &
         Var_VII(nVar, n1, 0:n2+1),         &
         TimeOut_I(nSnapshot),              &
         InterpData_VI(nVar,nSnapshot),     &
         InterpCoord_DI(nDim,nSnapshot))

    iSnapshot = 0
    iTrajTimestamp = 1
    do
       ! Read next snapshot from .outs file
       call read_plot_file( &
            NameFile = NameFileIn,              &
            TypeFileIn = TypeFileIn,            &
            iUnitIn = UnitTmp_,                 &
            CoordOut_DII = Coord_DII(:,:,1:n2), &
            VarOut_VII = Var_VII(:,:,1:n2),     &
            TimeOut = Time)                        ! simulation time

       if(Time < TrajTime_I(1)) CYCLE  ! before start of trajectory file
       if(Time > TrajTime_I(nPoint)) EXIT  ! after end of trajectory file

       iSnapshot = iSnapshot + 1
       
       ! Interpolate location of trajectory file in time to snapshot.
       do while(Time > TrajTime_I(iTrajTimestamp))
          iTrajTimestamp = iTrajTimestamp + 1
       enddo
       if(Time == TrajTime_I(iTrajTimestamp))then
          InterpCoord_D = CoordPoint_DI(:,iTrajTimestamp)
       else
          Weight = (TrajTime_I(iTrajTimestamp) - Time)/ &
               (TrajTime_I(iTrajTimestamp)-TrajTime_I(iTrajTimestamp-1))
          InterpCoord_D = &
               CoordPoint_DI(:,iTrajTimestamp-1)*Weight + &
               CoordPoint_DI(:,iTrajTimestamp)*(1-Weight)
       endif

       ! Convert (x,y) coordinates to (logr,phi) [deg]
       if(.not.IsCartesian)then
          ! Coordinates converted from [x,y] to [ln(r),phi]
          InterpCoord_D = [log(sqrt(sum(InterpCoord_D(1:2)**2))), &
               atan2_check(InterpCoord_D(2), InterpCoord_D(1))*cRadToDeg]

          RadMin = log(sqrt(sum(Coord_DII(1:2,1,1)**2)))
          RadMax = log(sqrt(sum(Coord_DII(1:2,n1,n2)**2)))
          PhiMin = atan2_check(Coord_DII(2,1,1),Coord_DII(1,1,1))*cRadToDeg
          PhiMax = atan2_check(Coord_DII(2,n1,n2),Coord_DII(1,n1,n2))*cRadToDeg
          dPhi   = (PhiMax - PhiMin)/(n2-1)
          PhiMin = PhiMin - dPhi ! account for ghost cells
          PhiMax = PhiMax + dPhi
       endif

       ! Fill in ghost cells in phi
       Var_VII(:,:,0)    = Var_VII(:,:,n2)
       Var_VII(:,:,n2+1) = Var_VII(:,:,1)

       ! Normalize coordinates
       InterpCoord_D(1) = (InterpCoord_D(1)-RadMin)*(n1-1)/(RadMax-RadMin) + 1
       InterpCoord_D(2) = (InterpCoord_D(2)-PhiMin)*(n2+1)/(PhiMax-PhiMin)

       ! Interpolate snapshot to trajectory location
       InterpData_VI(:,iSnapshot) = interpolate_vector( &
            a_VC = Var_VII, & ! variable array
            nVar = nVar, &    ! number of variables (11)
            nDim = 2, &       ! number of dimensions
            Min_D = [1,0], &
            Max_D = [n1,n2+1], &
            x_D = InterpCoord_D, & ! desired position
            DoExtrapolate = .false.)

       InterpCoord_DI(:,iSnapshot) = InterpCoord_D
       TimeOut_I(iSnapshot) = Time

    enddo

    call close_file(NameCaller=NameProgram)
    deallocate(Coord_DII, Var_VII)

    ! Open file for interpolated output
    call open_file(file=NameFileOut, NameCaller=NameProgram) 

    ! Include header
    write(UnitTmp_,'(a,a)')'t ', trim(NameVar)

    ! Write data. For now, time is in simulation time
    do iSnapshot = 1, nSnapshot
       write(UnitTmp_,'(100es13.6)') TimeOut_I(iSnapshot), &
            InterpCoord_DI(:,iSnapshot), InterpData_VI(:,iSnapshot)
    enddo
    
    call close_file(NameCaller=NameProgram)
    
  end subroutine interpolate_trajectory
  !============================================================================

end program





