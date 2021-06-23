!  Copyright (C) 2002 Regents of the University of Michigan,
!  portions used with permission
!  For more information, see http://csem.engin.umich.edu/tools/swmf

module ModRestartFile

  use BATL_lib, ONLY: &
       test_start, test_stop, iTest, jTest, kTest, iBlockTest, iProcTest, &
       iProc, nProc, iComm
  use ModIO,         ONLY: nFile, Dt_Output, Dn_Output, Restart_, &
       restart, save_restart_file
  use ModMain,       ONLY: &
       nBlockAll,      &
       n_step, Time_Simulation, dt_BLK, Cfl, CodeVersion, nByteReal, &
       NameThisComp, iteration_number, DoThinCurrentSheet, NameVarCouple
  use ModVarIndexes, ONLY: nVar, DefaultState_V, SignB_, NameVar_V
  use ModAdvance,    ONLY: State_VGB
  use ModGeometry,   ONLY: CellSize_DB, xyzStart_BLK, NameGridFile
  use ModIO,         ONLY: Restart_Bface
  use ModConstrainDivB, ONLY: BxFace_BLK, ByFace_BLK, BzFace_BLK
  use ModMain,       ONLY: UseConstrainB
  use ModPIC,        ONLY: write_pic_status_file, &
       read_pic_status_file, DoRestartPicStatus, &
       AdaptPic
  use ModImplicit, ONLY: UseImplicit, &
       n_prev, ImplOld_VCB, dt_prev
  use ModKind,       ONLY: Real4_, Real8_, Int8_
  use ModIoUnit,     ONLY: UnitTmp_
  use ModUtilities,  ONLY: open_file, close_file
  use ModGroundMagPerturb, ONLY: DoWriteIndices
  use ModBoundaryGeometry, ONLY: fix_block_geometry
  use BATL_lib,      ONLY: &
       write_tree_file, iMortonNode_A, iNode_B, &
       nBlock, Unused_B, nDim, nI, nJ, nK, MinI, MaxI, MinJ, MaxJ, MinK, MaxK,&
       IsCartesian, IsCartesianGrid, IsGenRadius, &
       IsRoundCube, rRound0, rRound1
  use ModBlockData, ONLY: write_block_restart_files, read_block_restart_files
  use ModWritePlot, ONLY: reverse_field
  implicit none

  private ! except

  public :: read_restart_parameters
  public :: write_restart_files
  public :: read_restart_files
  public :: init_mod_restart_file
  public :: string_append_iter

  ! Directories for input and output restart files
  character(len=100), public :: NameRestartInDir ="GM/restartIN/"
  character(len=100), public :: NameRestartOutDir="GM/restartOUT/"

  ! Flags to include iteration number in restart files
  logical, public :: UseRestartInSeries=.false.
  logical, public :: UseRestartOutSeries=.false.

  ! simulation time read in upon restart
  real, public    :: tSimulationRead

  ! Variables for allowing the user to use a different set of state variables
  ! from those saved in an existing restart file.
  logical, public :: DoChangeRestartVariables = .false.
  integer, public :: nVarRestart = nVar
  ! Length is set to exceed the variable names in the current equation module
  ! so that accidental matches are avoided.
  character(len(NameVar_V)+1), allocatable, public:: NameVarRestart_V(:)

  logical, public :: DoSpecifyRestartVarMapping = .false.
  integer, public :: nVarRestartMapping = nVar
  character(len(NameVar_V)+1), allocatable, public:: NameVarRestartFrom_V(:)
  character(len(NameVar_V)+1), allocatable, public:: NameVarRestartTo_V(:)

  ! Local variables
  character(len=*), parameter :: StringRestartExt  = ".rst"
  character(len=*), parameter :: NameBlkFile       = "blk"
  character(len=*), parameter :: NameHeaderFile    = "restart.H"
  character(len=*), parameter :: NameDataFile      = "data.rst"
  character(len=*), parameter :: NameIndexFile     = "index.rst"
  character(len=*), parameter :: NameGeoindFile    = "geoindex.rst"

  integer :: nByteRealRead = 8     ! Real precision in restart files

  ! One can use 'block', 'proc' or 'one' format for input and output
  ! restart files.
  ! The input format is set to 'block' for backwards compatibility
  character (len=20)  :: TypeRestartInFile ='block'

  ! 'proc' should work fine on all machines, so it is the default
  character (len=20)  :: TypeRestartOutFile='proc'

  ! Variables for file and record index for 'proc' type restart files
  integer, allocatable:: iFileMorton_I(:), iRecMorton_I(:)

  character(len=100) :: NameFile

  ! Logical variable for saving block data in the restart
  logical :: DoWriteBlockData = .false.
  logical :: DoReadBlockData  = .false.

  ! Temporary variables to read arbitrary precision data files
  real (Real8_) :: Dt8, Time8, Dxyz8_D(3), Xyz8_D(3)
  real (Real4_) :: Dt4, Time4, Dxyz4_D(3), Xyz4_D(3)
  real (Real8_) :: B8_X(nI+1,nJ,nK), B8_Y(nI,nJ+1,nK), B8_Z(nI,nJ,nK+1)
  real (Real4_) :: B4_X(nI+1,nJ,nK), B4_Y(nI,nJ+1,nK), B4_Z(nI,nJ,nK+1)
  real (Real8_),allocatable :: State8_CV(:,:,:,:), State8_VC(:,:,:,:)
  real (Real4_),allocatable :: State4_CV(:,:,:,:), State4_VC(:,:,:,:)

  ! Temporary array to store the complete state read from the restart file.
  ! Allows loading only a subset of the variables into current run, if needed.
  real,allocatable :: StateRead_VCB(:,:,:,:,:)
  real,allocatable :: ImplOldRead_VCB(:,:,:,:,:)

  ! Logical variable if FullB is saved in restart
  logical, public :: UseRestartWithFullB = .false.

contains
  !============================================================================

  subroutine init_mod_restart_file

    !--------------------------------------------------------------------------
    NameRestartInDir(1:2)  = NameThisComp
    NameRestartOutDir(1:2) = NameThisComp

  end subroutine init_mod_restart_file
  !============================================================================

  subroutine read_restart_parameters(NameCommand)

    use ModReadParam, ONLY: read_var
    use ModUtilities, ONLY: fix_dir_name
    use ModMain,      ONLY: UseStrict

    character(len=*), intent(in) :: NameCommand
    integer:: i
    logical:: DoTest
    character(len=*), parameter:: NameSub = 'read_restart_parameters'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)

    select case(NameCommand)
    case("#SAVERESTART")
       call read_var('DoSaveRestart', save_restart_file)
       if(save_restart_file)then
          call read_var('DnSaveRestart', dn_output(restart_))
          call read_var('DtSaveRestart', dt_output(restart_))
          nFile = max(nFile, restart_)
       end if
    case("#NEWRESTART")
       restart = .true.
       call read_var('DoRestartBFace', Restart_Bface)
    case("#PRECISION")
       call read_var('nByteReal',nByteRealRead)
       if(nByteReal/=nByteRealRead)then
          if(iProc==0) write(*,'(a,i1,a,i1)') NameSub// &
               ' WARNING: BATSRUS was compiled with ',nByteReal,&
               ' byte reals, requested precision is ',nByteRealRead
          if(UseStrict)call stop_mpi(NameSub// &
               ' ERROR: differing precisions for reals')
       end if
    case("#RESTARTINDIR")
       call read_var("NameRestartInDir",NameRestartInDir)
       call fix_dir_name(NameRestartInDir)
    case("#RESTARTOUTDIR")
       call read_var("NameRestartOutDir",NameRestartOutDir)
       call fix_dir_name(NameRestartOutDir)
    case("#RESTARTINFILE")
       call read_var('TypeRestartInFile',TypeRestartInFile)
       i = index(TypeRestartInFile, 'series')
       UseRestartInSeries = i > 0
       if(i > 0) TypeRestartInFile = TypeRestartInFile(1:i-1)

    case("#RESTARTOUTFILE")
       call read_var('TypeRestartOutFile',TypeRestartOutFile)
       i = index(TypeRestartOutFile, 'series')
       UseRestartOutSeries = i > 0
       if(i > 0) TypeRestartOutFile = TypeRestartOutFile(1:i-1)

    case("#RESTARTBLOCKDATA")
       call read_var('DoWriteBlockData', DoWriteBlockData)
       call read_var('DoReadBlockData',  DoReadBlockData)

    case default
       call stop_mpi(NameSub//' unknown NameCommand='//NameCommand)
    end select

    call test_stop(NameSub, DoTest)
  end subroutine read_restart_parameters
  !============================================================================

  subroutine write_restart_files

    use ModB0,       ONLY: UseB0, add_b0, subtract_b0, B0_DGB
    use ModGeometry, ONLY: true_cell
    use ModMain,     ONLY: UseFieldLineThreads, UseBufferGrid
    use ModFieldLineThread, ONLY: save_thread_restart
    use ModBuffer,   ONLY: save_buffer_restart
    integer :: iBlock
    logical:: DoTest
    character(len=*), parameter:: NameSub = 'write_restart_files'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)
    call timing_start(NameSub)

    !$acc update host(State_VGB, B0_DGB)
    
    if(SignB_>1 .and. DoThinCurrentSheet)then
       do iBlock = 1, nBlock
          if(.not.Unused_B(iBlock)) call reverse_field(iBlock)
       end do
    end if
    if(UseB0)then
       !$omp parallel do
       do iBlock = 1, nBlock
          if(.not.Unused_B(iBlock)) call add_b0(iBlock)
       end do
       !$omp end parallel do
    end if

    write(NameFile,'(a)') trim(NameRestartOutDir)//'octree.rst'
    if (UseRestartOutSeries) &
         call string_append_iter(NameFile,iteration_number)
    call write_tree_file(NameFile)
    ! Save the solution on threads if present
    if(UseFieldLineThreads)call save_thread_restart
    ! Save the buffer grid state if present (at zeroth proc only!)
    if(UseBufferGrid.and.iProc==0)call save_buffer_restart
    if(iProc==0) call write_restart_header
    select case(TypeRestartOutFile)
    case('block')
       do iBlock = 1, nBlock
          if (.not.Unused_B(iBlock)) call write_restart_file(iBlock)
       end do

    case('proc')
       allocate(iFileMorton_I(nBlockAll), iRecMorton_I(nBlockAll))
       iFileMorton_I = 0
       iRecMorton_I  = 0
       call write_direct_restart_file
       call write_restart_index
       deallocate(iFileMorton_I, iRecMorton_I)
    case('one')
       call write_direct_restart_file
    case default
       call stop_mpi('Unknown TypeRestartOutFile='//TypeRestartOutFile)
    end select
    if(DoWriteIndices .and. iProc==0)call write_geoind_restart

    if(DoWriteBlockData .and. n_step > 0) &
         call write_block_restart_files(NameRestartOutDir, UseRestartOutSeries)

    if(SignB_>1 .and. DoThinCurrentSheet)then
       do iBlock = 1, nBlock
          if (.not.Unused_B(iBlock)) call reverse_field(iBlock)
       end do
    end if
    if(UseB0)then
       do iBlock = 1, nBlock
          if(.not.Unused_B(iBlock)) call subtract_b0(iBlock)
       end do
    end if

    call timing_stop(NameSub)

    if(DoTest .and. iProc==iProcTest)then
       write(*,*)NameSub,': iProc, iBlockTest =',iProc, iBlockTest
       write(*,*)NameSub,': dt, TrueCell   =',dt_BLK(iBlockTest), &
            true_cell(iTest,jTest,kTest,iBlockTest)
       write(*,*)NameSub,': dx,dy,dz_BLK   =', CellSize_DB(:,iBlockTest)
       write(*,*)NameSub,': xyzStart_BLK   =',xyzStart_BLK(:,iBlockTest)
       write(*,*)NameSub,': State_VGB      =', &
            State_VGB(:,iTest,jTest,kTest,iBlockTest)
       write(*,*)NameSub,' finished'
    end if

    call test_stop(NameSub, DoTest)
  end subroutine write_restart_files
  !============================================================================

  subroutine read_restart_files

    use ModBuffer, ONLY: DoRestartBuffer, read_buffer_restart
    integer :: iBlock
    logical:: DoTest
    character(len=*), parameter:: NameSub = 'read_restart_files'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)
    call timing_start(NameSub)

    ! Allocate temporary array for reading restart data
    ! with arbitrary percision and number of state variables.
    allocate(State8_CV(nI,nJ,nK,nVarRestart))
    allocate(State8_VC(nVarRestart,nI,nJ,nK))
    allocate(State4_CV(nI,nJ,nK,nVarRestart))
    allocate(State4_VC(nVarRestart,nI,nJ,nK))
    allocate(StateRead_VCB(nVarRestart,nI,nJ,nK,nBlock))
    if(UseImplicit .or. n_prev == n_step) &
         allocate(ImplOldRead_VCB(nVarRestart,nI,nJ,nK,nBlock))

    select case(TypeRestartInFile)
    case('block')
       do iBlock = 1, nBlock
          if (.not.Unused_B(iBlock)) call read_restart_file(iBlock)
       end do
    case('proc')
       allocate(iFileMorton_I(nBlockAll), iRecMorton_I(nBlockAll))
       call read_restart_index
       call read_direct_restart_file
       deallocate(iFileMorton_I, iRecMorton_I)
    case('one')
       call read_direct_restart_file
    case default
       call stop_mpi('Unknown TypeRestartInFile='//TypeRestartinFile)
    end select

    ! Copy restart data into State_VGB as needed.
    call match_copy_restart_variables

    ! Restart buffer grid if present
    if(DoRestartBuffer)call read_buffer_restart
    ! Deallocate temporary arrays
    deallocate(State8_CV)
    deallocate(State8_VC)
    deallocate(State4_CV)
    deallocate(State4_VC)
    deallocate(StateRead_VCB)
    if(allocated(ImplOldRead_VCB)) deallocate(ImplOldRead_VCB)

    do iBlock = 1, nBlock
       if (.not.Unused_B(iBlock)) call fix_block_geometry(iBlock)
    end do

    if(SignB_>1)then
       if(DoThinCurrentSheet)then
          do iBlock = 1, nBlock
             if (.not.Unused_B(iBlock)) call reverse_field(iBlock)
          end do
       else
          do iBlock = 1, nBlock
             if (.not.Unused_B(iBlock)) State_VGB(SignB_,:,:,:,iBlock) = 0
          end do
       end if
    end if
    ! The subtraction of B0 from full B0+B1 to obtain B1 is in set_ICs
    ! after B0 is set

    ! Try reading geoIndices restart file if needed
    if(DoWriteIndices .and. iProc==0)call read_geoind_restart

    if(DoReadBlockData)  &
         call read_block_restart_files(NameRestartInDir, UseRestartInSeries)

    call timing_stop(NameSub)

    if(DoTest .and. iProc==iProcTest)then
       write(*,*)NameSub,': iProc, iBlockTest =',iProc, iBlockTest
       write(*,*)NameSub,': dt             =',dt_BLK(iBlockTest)
       write(*,*)NameSub,': dx,dy,dz_BLK   =', CellSize_DB(:,iBlockTest)
       write(*,*)NameSub,': xyzStart_BLK   =',xyzStart_BLK(:,iBlockTest)
       write(*,*)NameSub,': State_VGB      =', &
            State_VGB(:,iTest,jTest,kTest,iBlockTest)
       write(*,*)NameSub,' finished'
    end if

    call test_stop(NameSub, DoTest)
  end subroutine read_restart_files
  !============================================================================

  subroutine write_restart_header

    use ModMain,       ONLY: Dt, NameThisComp, TypeCoordSystem, nBlockAll, &
         Body1, UseBody2, Time_Accurate, iStartTime_I, IsStandAlone,       &
         UseBufferGrid
    use ModPhysics,    ONLY: &
         sw_n_dim, sw_t_dim, sw_ux_dim, sw_uy_dim, &
         sw_uz_dim, sw_bx_dim, sw_by_dim, sw_bz_dim, &
         TypeIoUnit, TypeNormalization, No2Si_V, Io2Si_V, No2Io_V, &
         UnitX_, UnitU_, UnitRho_, &
         rBody, rCurrents, BodyNDim_I, BodyNSpeciesDim_I, BodyTDim_I, &
         rBody2, xBody2, yBody2, zBody2, rCurrentsBody2, &
         UseBody2Orbit, OrbitPeriod, &
         RhoDimBody2, tDimBody2, &
         nVar, nFluid, IonFirst_

    ! If nFluid or IonFirst_ is taken directly from ModVarIndexes,
    ! the PGF90 compiler fails.
    use ModVarIndexes, ONLY: NameEquation
    use ModAdvance,    ONLY: UseMultiSpecies, nSpecies

    use ModGeometry, ONLY: x1, x2, y1, y2, z1, z2, &
         RadiusMin, RadiusMax, TypeGeometry, CoordDimMin_D, CoordDimMax_D
    use ModUser,     ONLY: NameUserModule, VersionUserModule
    use CON_planet,  ONLY: NamePlanet
    use ModReadParam, ONLY: i_line_command
    use ModUtilities, ONLY: cTab, write_string_tabs_name
    use ModIO,       ONLY: NameMaxTimeUnit
    use ModMain,     ONLY: UseFieldLineThreads
    use BATL_lib,    ONLY: nRoot_D
    use ModBuffer,   ONLY: write_buffer_restart_header

    integer :: iSpecies, iFluid, iDim
    logical :: IsLimitedGeometry=.false.

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'write_restart_header'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)

    if (iProc/=0) RETURN

    NameFile = trim(NameRestartOutDir)//NameHeaderFile
    if (UseRestartOutSeries) call string_append_iter(NameFile,iteration_number)

    call open_file(file=NameFile, NameCaller=NameSub)

    write(UnitTmp_,'(a)')'#CODEVERSION'
    write(UnitTmp_,'(f5.2,a)')CodeVersion, cTab//cTab//cTab//'CodeVersion'
    write(UnitTmp_,*)
    write(UnitTmp_,'(a)')'#USERMODULE'
    call write_string_tabs_name(NameUserModule, 'NameUserModule')
    write(UnitTmp_,'(f5.2,a)') &
         VersionUserModule, cTab//cTab//cTab//'VersionUserModule'
    write(UnitTmp_,*)
    write(UnitTmp_,'(a)')'#COMPONENT'
    write(UnitTmp_,'(a)')NameThisComp//cTab//cTab//cTab//'NameComp'
    write(UnitTmp_,*)
    write(UnitTmp_,'(a)')'#PRECISION'
    write(UnitTmp_,'(i1,a)')nByteReal, cTab//cTab//cTab//'nByteReal'
    write(UnitTmp_,*)
    write(UnitTmp_,'(a)')'#EQUATION'
    call write_string_tabs_name(NameEquation, 'NameEquation')
    write(UnitTmp_,'(i8,a)')nVar, cTab//cTab//'nVar'
    write(UnitTmp_,*)
    write(UnitTmp_,'(a)')'#RESTARTVARIABLES'
    call write_string_tabs_name(NameVarCouple, 'NameRestartVar')
    write(UnitTmp_,*)
    write(UnitTmp_,'(a)')'#CHECKGRIDSIZE'
    write(UnitTmp_,'(i8,a)') nI, cTab//cTab//'nI'
    write(UnitTmp_,'(i8,a)') nJ, cTab//cTab//'nJ'
    write(UnitTmp_,'(i8,a)') nK, cTab//cTab//'nK'
    write(UnitTmp_,'(i8,a)') nBlockALL, cTab//cTab//'MinBlockAll'
    if (IsStandAlone .and. NameThisComp == 'GM') then
       write(UnitTmp_,*)
       if(NamePlanet == 'NEW')then
          write(UnitTmp_,'(a)')'!!! PLANET'
       else
          write(UnitTmp_,'(a)')'#PLANET'
       end if
       call write_string_tabs_name(NamePlanet,'NamePlanet')
       if(i_line_command("#IDEALAXES", iSessionIn=1) > 0)then
          write(UnitTmp_,*)
          write(UnitTmp_,'(a)')'#IDEALAXES'
       end if
    end if
    write(UnitTmp_,*)
    write(UnitTmp_,'(a)')'#NEWRESTART'
    write(UnitTmp_,'(l1,a)')UseConstrainB, cTab//cTab//cTab//'DoRestartBFace'
    write(UnitTmp_,*)
    write(UnitTmp_,'(a)')'#RESTARTINFILE'
    ! Note that the output file format is saved as the input for next restart
    call write_string_tabs_name(TypeRestartOutFile, 'StringRestartInFile')
    write(UnitTmp_,*)
    write(UnitTmp_,'(a)')'#NSTEP'
    write(UnitTmp_,'(i8,a)')n_step, cTab//cTab//'nStep'
    write(UnitTmp_,*)
    if(n_prev == n_step)then
       write(UnitTmp_,'(a)')'#NPREVIOUS'
       write(UnitTmp_,'(i8,a)')      n_prev, cTab//cTab//'nPrev'
       write(UnitTmp_,'(es22.15,a)') dt_prev, cTab//cTab//'DtPrev'
       write(UnitTmp_,*)
    end if
    write(UnitTmp_,'(a)')'#STARTTIME'
    write(UnitTmp_,'(i8,a)')iStartTime_I(1), cTab//cTab//'iYear'
    write(UnitTmp_,'(i8,a)')iStartTime_I(2), cTab//cTab//'iMonth'
    write(UnitTmp_,'(i8,a)')iStartTime_I(3), cTab//cTab//'iDay'
    write(UnitTmp_,'(i8,a)')iStartTime_I(4), cTab//cTab//'iHour'
    write(UnitTmp_,'(i8,a)')iStartTime_I(5), cTab//cTab//'iMinute'
    write(UnitTmp_,'(i8,a)')iStartTime_I(6), cTab//cTab//'iSecond'
    write(UnitTmp_,*)
    write(UnitTmp_,'(a)')'#TIMESIMULATION'
    write(UnitTmp_,'(es22.15,a)') time_simulation, cTab//cTab//'tSimulation'
    write(UnitTmp_,*)
    if(.not.IsCartesian)then
       IsLimitedGeometry = CoordDimMin_D(1) < CoordDimMax_D(1)
       if(IsLimitedGeometry) then
          write(UnitTmp_,'(a)')'#GRIDGEOMETRYLIMIT'
       else
          write(UnitTmp_,'(a)')'#GRIDGEOMETRY'
       endif
       call write_string_tabs_name(TypeGeometry, 'TypeGeometry')
       if(IsGenRadius) &
            call write_string_tabs_name(NameGridFile, 'NameGridFile')
       if(IsRoundCube) then
          write(UnitTmp_,'(es22.15,a)') rRound0, cTab//cTab//'rRound0'
          write(UnitTmp_,'(es22.15,a)') rRound1, cTab//cTab//'rRound1'
       endif
       if(IsLimitedGeometry) then
          do iDim = 1, nDim
             write(UnitTmp_,'(es22.15,a)') &
                  CoordDimMin_D(iDim), cTab//cTab//'CoordDimMin_D'
             write(UnitTmp_,'(es22.15,a)') &
                  CoordDimMax_D(iDim), cTab//cTab//'CoordDimMax_D'
          end do
       endif
       write(UnitTmp_,*)
    end if
    write(UnitTmp_,'(a)')'#GRID'
    write(UnitTmp_,'(i8,a)') nRoot_D(1), cTab//cTab//'nRootBlock1'
    write(UnitTmp_,'(i8,a)') nRoot_D(2), cTab//cTab//'nRootBlock2'
    write(UnitTmp_,'(i8,a)') nRoot_D(3), cTab//cTab//'nRootBlock3'
    write(UnitTmp_,'(es22.15,a)') x1,    cTab//cTab//'xMin'
    write(UnitTmp_,'(es22.15,a)') x2,    cTab//cTab//'xMax'
    write(UnitTmp_,'(es22.15,a)') y1,    cTab//cTab//'yMin'
    write(UnitTmp_,'(es22.15,a)') y2,    cTab//cTab//'yMax'
    write(UnitTmp_,'(es22.15,a)') z1,    cTab//cTab//'zMin'
    write(UnitTmp_,'(es22.15,a)') z2,    cTab//cTab//'zMax'
    write(UnitTmp_,*)
    if(.not.IsCartesianGrid .and.  RadiusMin >= 0.0 .and. RadiusMax > 0.0 &
         .and. .not.IsLimitedGeometry)then
       write(UnitTmp_,'(a)')'#LIMITRADIUS'
       write(UnitTmp_,'(es22.15,a)') RadiusMin, cTab//cTab//'rMin'
       write(UnitTmp_,'(es22.15,a)') RadiusMax, cTab//cTab//'rMax'
       write(UnitTmp_,*)
    end if
    write(UnitTmp_,'(a)')'#COORDSYSTEM'
    call write_string_tabs_name(TypeCoordSystem,'TypeCoordSystem')
    write(UnitTmp_,*)
    write(UnitTmp_,'(a)')'#SOLARWIND'
    write(UnitTmp_,'(es22.15,a)')SW_n_dim,  cTab//cTab//'SwNDim'
    write(UnitTmp_,'(es22.15,a)')SW_T_dim,  cTab//cTab//'SwTDim'
    write(UnitTmp_,'(es22.15,a)')SW_Ux_dim, cTab//cTab//'SwUxDim'
    write(UnitTmp_,'(es22.15,a)')SW_Uy_dim, cTab//cTab//'SwUyDim'
    write(UnitTmp_,'(es22.15,a)')SW_Uz_dim, cTab//cTab//'SwUzDim'
    write(UnitTmp_,'(es22.15,a)')SW_Bx_dim, cTab//cTab//'SwBxDim'
    write(UnitTmp_,'(es22.15,a)')SW_By_dim, cTab//cTab//'SwByDim'
    write(UnitTmp_,'(es22.15,a)')SW_Bz_dim, cTab//cTab//'SwBzDim'
    write(UnitTmp_,*)
    write(UnitTmp_,'(a)')'#IOUNITS'
    call write_string_tabs_name(TypeIoUnit, 'TypeIoUnit')
    write(UnitTmp_,*)
    write(UnitTmp_,'(a)')'#NORMALIZATION'
    if(TypeNormalization == "NONE")then
       write(UnitTmp_,'(a)')'NONE'//cTab//cTab//cTab//'TypeNormalization'
    else
       write(UnitTmp_,'(a)')'READ'//cTab//cTab//cTab//'TypeNormalization'
       write(UnitTmp_,'(es22.15,a)')No2Si_V(UnitX_),   cTab//cTab//'No2SiUnitX'
       write(UnitTmp_,'(es22.15,a)')No2Si_V(UnitU_),   cTab//cTab//'No2SiUnitU'
       write(UnitTmp_,'(es22.15,a)')No2Si_V(UnitRho_), &
            cTab//cTab//'No2SiUnitRho'
    end if
    write(UnitTmp_,*)
    write(UnitTmp_,'(a)')'#PLOTFILENAME'
    call write_string_tabs_name(NameMaxTimeUnit, 'NameMaxTimeUnit')
    write(UnitTmp_,*)

    if(body1)then
       write(UnitTmp_,'(a)')'#BODY'
       write(UnitTmp_,'(a)') 'T'//cTab//cTab//cTab//'UseBody'
       write(UnitTmp_,'(es22.15,a)') rBody, cTab//cTab//'rBody'
       if(NameThisComp=='GM') &
            write(UnitTmp_,'(es22.15,a)') rCurrents, cTab//cTab//'rCurrents'
       if(UseMultiSpecies)then
          do iSpecies = 1, nSpecies
             write(UnitTmp_,'(es22.15,a)') &
                  BodyNSpeciesDim_I(iSpecies), cTab//cTab//'BodyNDim'
          end do
          write(UnitTmp_,'(es22.15,a)') &
               BodyTDim_I(IonFirst_), cTab//cTab//'BodyTDim'
       else
          do iFluid = IonFirst_, nFluid
             write(UnitTmp_,'(es22.15,a)') &
                  BodyNDim_I(iFluid), cTab//cTab//'BodyNDim'
             write(UnitTmp_,'(es22.15,a)') &
                  BodyTDim_I(iFluid), cTab//cTab//'BodyTDim'
          end do
       end if
       write(UnitTmp_,*)
    end if

    if(UseFieldLineThreads)then
       write(UnitTmp_,'(a)')'#THREADRESTART'
       write(UnitTmp_,'(l1,a)')UseFieldLineThreads,&
            cTab//cTab//cTab//'DoThreadRestart'
       write(UnitTmp_,*)
    end if
    if(UseBufferGrid)call write_buffer_restart_header(UnitTmp_)

    if(UseBody2)then
       write(UnitTmp_,'(a)')'#SECONDBODY'
       write(UnitTmp_,'(l1,a)')UseBody2,     cTab//cTab//cTab//'UseBody2'
       write(UnitTmp_,'(es22.15,a)')Rbody2,        cTab//cTab//'rBody2'
       write(UnitTmp_,'(es22.15,a)')xbody2,        cTab//cTab//'xBody2'
       write(UnitTmp_,'(es22.15,a)')ybody2,        cTab//cTab//'yBody2'
       write(UnitTmp_,'(es22.15,a)')zbody2,        cTab//cTab//'zBody2'
       write(UnitTmp_,'(es22.15,a)')rCurrentsBody2,cTab//cTab//'rCurrentsBody2'
       write(UnitTmp_,'(es22.15,a)')RhoDimBody2,   cTab//cTab//'RhoDimBody2'
       write(UnitTmp_,'(es22.15,a)')tDimBody2,     cTab//cTab//'tDimBody2'
       write(UnitTmp_,'(l1,a)')UseBody2Orbit,cTab//cTab//cTab//'UseBody2Orbit'
       write(UnitTmp_,'(es22.15,a)')OrbitPeriod,   cTab//cTab//'OrbitPeriod'
       write(UnitTmp_,*)
    end if

    write(UnitTmp_,'(a)')'#RESTARTWITHFULLB'
    write(UnitTmp_,*)

    write(UnitTmp_,'(a)')'#END'
    write(UnitTmp_,*)
    write(UnitTmp_,'(a)')'Additional info'
    write(UnitTmp_,*)
    write(UnitTmp_,'(l8,a)') time_accurate,   ' time_accurate'
    write(UnitTmp_,*)
    if(time_accurate)write(UnitTmp_,'(2es13.5,a)')&
         time_simulation, dt, ' time_simulation, dt'

    write(UnitTmp_,'(a)')'Io2Si_V='
    write(UnitTmp_,'(100es13.5)') Io2Si_V
    write(UnitTmp_,'(a)')'No2Io_V='
    write(UnitTmp_,'(100es13.5)') No2Io_V

    call close_file

    call test_stop(NameSub, DoTest)
  end subroutine write_restart_header
  !============================================================================

  subroutine write_restart_index

    use ModMpi, ONLY: MPI_reduce, MPI_INTEGER, MPI_SUM

    integer, allocatable:: Int_I(:)
    integer:: iMorton, iError

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'write_restart_index'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)
    if(nProc > 1)then
       ! Collect file and record indexes onto the root processor
       allocate(Int_I(nBlockAll))
       call MPI_reduce(iFileMorton_I, Int_I, nBlockAll, MPI_INTEGER, &
            MPI_SUM, 0, iComm, iError)
       iFileMorton_I = Int_I
       call MPI_reduce(iRecMorton_I, Int_I, nBlockAll, MPI_INTEGER, &
            MPI_SUM, 0, iComm, iError)
       iRecMorton_I = Int_I
       deallocate(Int_I)
    end if

    if(iProc /= 0) RETURN

    ! Save index file
    NameFile = trim(NameRestartOutDir)//NameIndexFile
    if (UseRestartOutSeries) call string_append_iter(NameFile,iteration_number)
    call open_file(FILE=NameFile, NameCaller=NameSub)
    write(UnitTmp_,*) nBlockAll
    do iMorton = 1, nBlockAll
       write(UnitTmp_,*) iFileMorton_I(iMorton), iRecMorton_I(iMorton)
    end do
    call close_file

    call test_stop(NameSub, DoTest)
  end subroutine write_restart_index
  !============================================================================
  subroutine read_restart_index

    integer:: iMorton, nBlockAllRead

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'read_restart_index'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)
    NameFile = trim(NameRestartInDir)//NameIndexFile
    if (UseRestartInSeries) call string_append_iter(NameFile,iteration_number)
    call open_file(FILE=NameFile, STATUS='old', NameCaller=NameSub)
    read(UnitTmp_,*) nBlockAllRead

    if(nBlockAllRead /= nBlockAll) &
         call stop_mpi('Incorrect nBlockAll value in '//trim(NameFile))

    do iMorton = 1, nBlockAll
       read(UnitTmp_,*) iFileMorton_I(iMorton), iRecMorton_I(iMorton)
    end do
    call close_file

    call test_stop(NameSub, DoTest)
  end subroutine read_restart_index
  !============================================================================
  subroutine read_restart_file(iBlock)

    integer, intent(in) :: iBlock

    integer   :: iVar, i, j, k, iError, iBlockRestart
    character :: StringDigit

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'read_restart_file'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest, iBlock)

    iBlockRestart = iMortonNode_A(iNode_B(iBlock))

    write(StringDigit,'(i1)') max(5,1+int(alog10(real(iBlockRestart))))

    write(NameFile,'(a,i'//StringDigit//'.'//StringDigit//',a)') &
         trim(NameRestartInDir)//NameBlkFile,iBlockRestart,StringRestartExt
    if (UseRestartInSeries) call string_append_iter(NameFile,iteration_number)

    call open_file(file=NameFile, status='old', form='UNFORMATTED', &
         NameCaller=NameSub)

    ! Fill in ghost cells
    do k=MinK,MaxK; do j=MinJ,MaxJ; do i=MinI,MaxI
       State_VGB(1:nVar, i, j, k, iBlock) = DefaultState_V(1:nVar)
    end do;end do;end do

    ! Do not overwrite time_simulation which is read from header file
    if(nByteRealRead == 8)then
       read(UnitTmp_, iostat = iError) Dt8, Time8
       dt_BLK(iBlock) = Dt8
       tSimulationRead   = Time8

       read(UnitTmp_, iostat = iError) Dxyz8_D, Xyz8_D
       CellSize_DB(:,iBlock) = Dxyz8_D
       XyzStart_BLK(:,iBlock) = Xyz8_D

       read(UnitTmp_, iostat = iError) State8_CV

       do iVar = 1, nVarRestart
          StateRead_VCB(iVar,1:nI,1:nJ,1:nK,iBlock) = State8_CV(:,:,:,iVar)
       end do

       if(Restart_Bface)then
          read(UnitTmp_, iostat = iError) b8_X, b8_Y, b8_Z
          BxFace_BLK(1:nI+1,1:nJ,1:nK,iBlock) = b8_X
          ByFace_BLK(1:nI,1:nJ+1,1:nK,iBlock) = b8_Y
          BzFace_BLK(1:nI,1:nJ,1:nK+1,iBlock) = b8_Z
       end if
       if(n_prev==n_step) then
          read(UnitTmp_, iostat = iError) State8_CV
          do iVar = 1, nVarRestart
             ImplOldRead_VCB(iVar,:,:,:,iBlock) = State8_CV(:,:,:,iVar)
          end do
       end if
    else
       read(UnitTmp_, iostat = iError) Dt4, Time4
       dt_BLK(iBlock) = Dt4
       tSimulationRead   = Time4

       read(UnitTmp_, iostat = iError) Dxyz4_D, Xyz4_D
       CellSize_DB(:,iBlock) = Dxyz4_D
       XyzStart_BLK(:,iBlock) = Xyz4_D

       read(UnitTmp_, iostat = iError) State4_CV
       do iVar = 1, nVarRestart
          StateRead_VCB(iVar,1:nI,1:nJ,1:nK,iBlock) = State4_CV(:,:,:,iVar)
       end do

       if(Restart_Bface)then
          read(UnitTmp_, iostat = iError) b4_X, b4_Y, b4_Z
          BxFace_BLK(1:nI+1,1:nJ,1:nK,iBlock) = b4_X
          ByFace_BLK(1:nI,1:nJ+1,1:nK,iBlock) = b4_Y
          BzFace_BLK(1:nI,1:nJ,1:nK+1,iBlock) = b4_Z
       end if
       if(n_prev==n_step) then
          read(UnitTmp_, iostat = iError) State4_CV
          do iVar = 1, nVarRestart
             ImplOldRead_VCB(iVar,:,:,:,iBlock) = State4_CV(:,:,:,iVar)
          end do
       end if
    endif

    if(iError /= 0) call stop_mpi(NameSub// &
         ' could not read data from '//trim(NameFile))

    call close_file

    if(CodeVersion>5.60 .and. CodeVersion <7.00) &
         dt_BLK(iBlock)=dt_BLK(iBlock)/cfl

    if(any(CellSize_DB(:,iBlock) < 0  &
         .or. Dt_BLK(iBlock) < 0 .or. tSimulationRead < 0))then
       write(*,*)NameSub,': corrupt restart data!!!'
       write(*,*)'iBlock  =', iBlock
       write(*,*)'Dxyz    =', CellSize_DB(:,iBlock)
       write(*,*)'Dt,tSim =', Dt_BLK(iBlock), tSimulationRead
       write(*,*)'XyzStart=', XyzStart_BLK(:,iBlock)
       write(*,*)'State111=', StateRead_VCB(1:nVarRestart,1,1,1,iBlock)
       call stop_mpi(NameSub//': corrupt restart data!!!')
    end if

    if(DoTest)then
       write(*,*)NameSub,': iProc, iBlock =',iProc, iBlock
       write(*,*)NameSub,': dt,tSimRead =',dt_BLK(iBlock),tSimulationRead
       write(*,*)NameSub,': dx,dy,dz_BLK=', CellSize_DB(:,iBlock)
       write(*,*)NameSub,': xyzStart_BLK=',xyzStart_BLK(:,iBlock)
       write(*,*)NameSub,': StateRead_VCB   =', &
            StateRead_VCB(:,iTest,jTest,kTest,iBlock)
       write(*,*)NameSub,' finished'
    end if

    call test_stop(NameSub, DoTest, iBlock)
  end subroutine read_restart_file
  !============================================================================

  subroutine write_restart_file(iBlock)

    integer, intent(in) :: iBlock

    integer:: iVar, iBlockRestart
    character:: StringDigit

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'write_restart_file'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest, iBlock)

    iBlockRestart = iMortonNode_A(iNode_B(iBlock))

    write(StringDigit,'(i1)') max(5,int(1+alog10(real(iBlockRestart))))

    write(NameFile,'(a,i'//StringDigit//'.'//StringDigit//',a)') &
         trim(NameRestartOutDir)//NameBlkFile,iBlockRestart,StringRestartExt

    if (UseRestartOutSeries) call string_append_iter(NameFile,iteration_number)

    call open_file(file=NameFile, form='UNFORMATTED', NameCaller=NameSub)

    write(UnitTmp_) dt_BLK(iBlock),time_Simulation
    write(UnitTmp_) CellSize_DB(:,iBlock), xyzStart_BLK(:,iBlock)
    write(UnitTmp_) &
         ( State_VGB(iVar,1:nI,1:nJ,1:nK,iBlock), iVar=1,nVar)
    if(UseConstrainB)then
       write(UnitTmp_) &
            BxFace_BLK(1:nI+1,1:nJ,1:nK,iBlock),&
            ByFace_BLK(1:nI,1:nJ+1,1:nK,iBlock),&
            BzFace_BLK(1:nI,1:nJ,1:nK+1,iBlock)
    end if
    if(n_prev==n_step) write(UnitTmp_) &
         (ImplOld_VCB(iVar,:,:,:,iBlock), iVar=1,nVar)
    call close_file

    call test_stop(NameSub, DoTest, iBlock)
  end subroutine write_restart_file
  !============================================================================

  subroutine open_direct_restart_file(DoRead, iFile)

    logical, intent(in)           :: DoRead
    integer, intent(in), optional :: iFile

    integer :: lRecord, l, lReal
    logical :: DoTestme

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'open_direct_restart_file'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)
    if(DoTest)write(*,*) NameSub,' starting with DoRead=',DoRead

    ! Size of a single real number in units of record length
    inquire (IOLENGTH = lReal) 1.0

    ! Calculate the record length for the first block
    if (DoRead) then
       inquire (IOLENGTH = lRecord ) &
            Dt_BLK(1), CellSize_DB(:,1), XyzStart_BLK(:,1), &
            StateRead_VCB(1:nVarRestart,1:nI,1:nJ,1:nK,1)
    else
       inquire (IOLENGTH = lRecord ) &
            Dt_BLK(1), CellSize_DB(:,1), XyzStart_BLK(:,1), &
            State_VGB(1:nVar,1:nI,1:nJ,1:nK,1)
    end if

    if(DoRead .and. Restart_Bface .or. &
         .not.DoRead .and. UseConstrainB)then
       l = lReal*((nI+1)*nJ*nK + nI*(nJ+1)*nK + nI*nJ*(nK+1))
       lRecord = lRecord + l
    end if
    if(n_prev==n_step)then
       if(DoRead) then
          l = lReal*nVarRestart*nI*nJ*nK
       else
          l = lReal*nVar*nI*nJ*nK
       end if
       lRecord = lRecord + l
    end if

    if(DoTest)write(*,*) NameSub,' nByteReal, nByteRealRead, lRecord=',&
         nByteReal, nByteRealRead, lRecord

    if(DoRead)then
       if(nByteReal /= nByteRealRead) &
            lRecord = (lRecord * nByteRealRead)/nByteReal

       NameFile = trim(NameRestartInDir)//NameDataFile
       if (present(iFile)) &
            write(NameFile, '(a,i6.6)') trim(NameFile)//'_p', iFile
       if (UseRestartInSeries) &
            call string_append_iter(NameFile, iteration_number)

       call open_file(FILE=NameFile, &
            RECL = lRecord, ACCESS = 'direct', FORM = 'unformatted', &
            STATUS = 'old', NameCaller=NameSub//':read')
    else
       NameFile = trim(NameRestartOutDir)//NameDataFile
       if (present(iFile)) &
            write(NameFile, '(a,i6.6)') trim(NameFile)//'_p', iFile
       if (UseRestartOutSeries) &
            call string_append_iter(NameFile,iteration_number)

       ! Delete and open restart files
       if(TypeRestartOutFile == 'proc') &
            call open_file(FILE=NameFile, FORM='unformatted', &
            RECL = lRecord, ACCESS = 'direct',                &
            NameCaller=NameSub//':write direct proc')

       ! Pass iComm=iComm so only processor 0 deletes the file
       if(TypeRestartOutFile == 'one') &
            call open_file(FILE=NameFile, FORM='unformatted', &
            RECL = lRecord, ACCESS = 'direct', iComm=iComm,   &
            NameCaller=NameSub//':write direct one')

    end if

    call test_stop(NameSub, DoTest)
  end subroutine open_direct_restart_file
  !============================================================================

  subroutine read_direct_restart_file

    integer :: i, j, k, iBlock, iMorton, iRec, iVar, iFile, iFileLast = -1
    logical :: IsRead
    logical:: DoTest
    character(len=*), parameter:: NameSub = 'read_direct_restart_file'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)

    if(TypeRestartInFile == 'one') &
         call open_direct_restart_file(DoRead = .true.)

    if(DoTest)write(*,*) NameSub,' starting with nBlock=', nBlock

    do iBlock = 1, nBlock

       if(Unused_B(iBlock)) CYCLE
       ! Use the global block index as the record number
       iMorton = iMortonNode_A(iNode_B(iBlock))

       if(TypeRestartInFile == 'proc')then
          ! Find the appropriate 'proc' restart file and the record number
          iFile = iFileMorton_I(iMorton)
          iRec  = iRecMorton_I(iMorton)
          if(iFile /= iFileLast) then
             if(iFileLast > 0) call close_file
             call open_direct_restart_file(DoRead = .true., iFile = iFile)
             iFileLast = iFile
          end if
       else
          ! For 'one' restart file record index is given by Morton index
          iRec = iMorton
       end if

       if(DoTest) write(*,*) NameSub,' iBlock, iRec=', iBlock, iRec

       ! Fill in ghost cells
       do k=MinK,MaxK; do j=MinJ,MaxJ; do i=MinI,MaxI
          State_VGB(1:nVar, i, j, k, iBlock) = DefaultState_V(1:nVar)
       end do; end do; end do

       IsRead = .false.
       if(nByteRealRead == 4)then
          if(Restart_Bface)then
             ! Read with face centered magnetic field for constrained transport
             read(UnitTmp_, rec=iRec) Dt4, Dxyz4_D, Xyz4_D, State4_VC, &
                  B4_X, B4_Y, B4_Z
             if(UseConstrainB)then
                BxFace_BLK(1:nI+1,1:nJ,1:nK,iBlock) = B4_X
                ByFace_BLK(1:nI,1:nJ+1,1:nK,iBlock) = B4_Y
                BzFace_BLK(1:nI,1:nJ,1:nK+1,iBlock) = B4_Z
             end if
             IsRead = .true.
          endif
          if(n_prev==n_step)then
             ! Read with previous state for sake of implicit BDF2 scheme
             read(UnitTmp_, rec=iRec) Dt4, Dxyz4_D, Xyz4_D, State4_VC, &
                  State4_CV
             if(UseImplicit)then
                do iVar = 1, nVarRestart
                   ImplOldRead_VCB(iVar,:,:,:,iBlock) = State4_CV(:,:,:,iVar)
                end do
             end if
             IsRead = .true.
          end if
          if(.not.IsRead) &
               read(UnitTmp_, rec=iRec) Dt4, Dxyz4_D, Xyz4_D, State4_VC

          Dt_BLK(iBlock) = Dt4
          CellSize_DB(:,iBlock)  = Dxyz4_D
          XyzStart_BLK(:,iBlock) = Xyz4_D
          StateRead_VCB(1:nVarRestart,1:nI,1:nJ,1:nK,iBlock) = State4_VC

       else
          if(Restart_Bface)then
             ! Read with face centered magnetic field for constrained transport
             read(UnitTmp_, rec=iRec) Dt8, Dxyz8_D, Xyz8_D, State8_VC, &
                  B8_X, B8_Y, B8_Z
             if(UseConstrainB)then
                BxFace_BLK(1:nI+1,1:nJ,1:nK,iBlock) = B8_X
                ByFace_BLK(1:nI,1:nJ+1,1:nK,iBlock) = B8_Y
                BzFace_BLK(1:nI,1:nJ,1:nK+1,iBlock) = B8_Z
             end if
             IsRead = .true.
          endif
          if(n_prev==n_step)then
             ! Read with previous state for sake of implicit BDF2 scheme
             read(UnitTmp_, rec=iRec) Dt8, Dxyz8_D, Xyz8_D, State8_VC, &
                  State8_CV
             if(UseImplicit)then
                do iVar = 1, nVarRestart
                   ImplOldRead_VCB(iVar,:,:,:,iBlock) = State8_CV(:,:,:,iVar)
                end do
             end if
             IsRead = .true.
          end if
          if(.not.IsRead) &
               read(UnitTmp_, rec=iRec) Dt8, Dxyz8_D, Xyz8_D, State8_VC

          Dt_BLK(iBlock) = Dt8
          CellSize_DB(:,iBLock) = Dxyz8_D
          XyzStart_BLK(:,iBlock) = Xyz8_D
          StateRead_VCB(1:nVarRestart,1:nI,1:nJ,1:nK,iBlock) = State8_VC
       end if

       if(any(CellSize_DB(:,iBLock) < 0) .or. Dt_BLK(iBlock) < 0)then
          write(*,*)NameSub,': corrupt restart data!!!'
          write(*,*)'iBlock  =', iBlock
          write(*,*)'Dxyz    =', CellSize_DB(:,iBLock)
          write(*,*)'Dt      =', Dt_BLK(iBlock)
          write(*,*)'XyzStart=', XyzStart_BLK(:,iBlock)
          write(*,*)'State111=', StateRead_VCB(1:nVarRestart,1,1,1,iBlock)
          call stop_mpi(NameSub//': corrupt restart data!!!')
       end if
    end do

    call close_file

    if(DoRestartPicStatus) call read_pic_status_file

    call test_stop(NameSub, DoTest)
  end subroutine read_direct_restart_file
  !============================================================================

  subroutine write_direct_restart_file

    integer :: iBlock, iMorton, iRec, iVar

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'write_direct_restart_file'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)
    if(TypeRestartOutFile == 'one')then
       call open_direct_restart_file(DoRead = .false.)
    else
       ! For 'proc' type open file with processor index
       ! and write block records in the order they are stored
       call open_direct_restart_file(DoRead = .false., iFile = iProc)
       iRec = 0
    end if

    do iBlock = 1, nBlock

       if(Unused_B(iBlock)) CYCLE
       ! Use the global block index as the record number
       iMorton = iMortonNode_A(iNode_B(iBlock))

       if(TypeRestartOutFile == 'proc')then
          ! Write block into next record and store info for index file
          iRec = iRec + 1
          iFileMorton_I(iMorton) = iProc
          iRecMorton_I(iMorton)  = iRec
       else
          ! For 'one' restart file record index is given by Morton index
          iRec = iMorton
       end if

       if(UseConstrainB)then
          ! Save face centered magnetic field
          write(UnitTmp_, rec=iRec)  Dt_BLK(iBlock),&
               CellSize_DB(:,iBLock), &
               XyzStart_BLK(:,iBlock), &
               State_VGB(1:nVar,1:nI,1:nJ,1:nK,iBlock), &
               BxFace_BLK(1:nI+1,1:nJ,1:nK,iBlock),&
               ByFace_BLK(1:nI,1:nJ+1,1:nK,iBlock),&
               BzFace_BLK(1:nI,1:nJ,1:nK+1,iBlock)
          CYCLE
       endif
       if(n_prev==n_step)then
          ! Save previous time step for sake of BDF2 scheme
          write(UnitTmp_, rec=iRec) &
               Dt_BLK(iBlock), &
               CellSize_DB(:,iBLock), &
               XyzStart_BLK(:,iBlock), &
               State_VGB(1:nVar,1:nI,1:nJ,1:nK,iBlock), &
               (ImplOld_VCB(iVar,:,:,:,iBlock), iVar = 1, nVar)
          CYCLE
       endif

       write(UnitTmp_, rec=iRec) &
            Dt_BLK(iBlock), &
            CellSize_DB(:,iBLock), &
            XyzStart_BLK(:,iBlock), &
            State_VGB(1:nVar,1:nI,1:nJ,1:nK,iBlock)
    end do

    call close_file

    if(AdaptPic % DoThis) call write_pic_status_file

    call test_stop(NameSub, DoTest)
  end subroutine write_direct_restart_file
  !============================================================================

  subroutine string_append_iter(NameFile, nIter)

    character (len=100), intent(inout) :: NameFile
    integer, intent(in) :: nIter

    ! Note: Fortran cannot write parts of a string into the same string!
    character(len=100):: NameFileOld
    integer:: i

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'string_append_iter'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)
    if (nIter < 0) call stop_mpi(NameSub//' nIter cannot be negative')

    NameFileOld = NameFile
    i = index(NameFileOld,'/',back=.true.)
    write(NameFile,'(a,i8.8,a)') &
         NameFileOld(1:i)//'n', nIter, '_'//NameFileOld(i+1:90)

    call test_stop(NameSub, DoTest)
  end subroutine string_append_iter
  !============================================================================

  subroutine write_geoind_restart

    ! Save ModGroundMagPerturb::MagHistory_II to a restart file on proc 0

    use ModGroundMagPerturb, ONLY: nKpMag, iSizeKpWindow, MagHistory_DII

    integer            :: i, j, iDim
    character(len=100) :: NameFile
    character(len=1)   :: NameDim(2) = ['x', 'y']

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'write_geoind_restart'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)

    ! Ensure that restart files are only written from head node.
    if(iProc/=0) RETURN

    do iDim=1, 2
       ! Open restart file.
       NameFile = trim(NameRestartOutDir)//NameDim(iDim)//'_'//NameGeoIndFile
       call open_file(file=NameFile, NameCaller=NameSub)

       ! Size of array:
       write(UnitTmp_,*) nKpMag, iSizeKpWindow
       ! Save MagHistory_II
       do j = 1, iSizeKpWindow
          do i = 1, nKpMag
             write(UnitTmp_, '(es20.12)' ) MagHistory_DII(iDim, i,j)
          end do
       end do
       call close_file
    end do

    call test_stop(NameSub, DoTest)
  end subroutine write_geoind_restart
  !============================================================================

  subroutine read_geoind_restart

    ! Read MagHistory_II from restart file on processor 0

    use ModGroundMagPerturb, ONLY: nKpMag, iSizeKpWindow, MagHistory_DII, &
         IsFirstCalc, IsSecondCalc

    integer            :: i, j, iDim, nMagTmp, iSizeTmp
    logical            :: DoRestart
    character(len=100) :: NameFile
    character(len=1)   :: NameDim(2) = ['x', 'y']

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'read_geoind_restart'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)

    do iDim=1, 2

       NameFile = trim(NameRestartInDir)//NameDim(iDim)//'_'//NameGeoindFile

       ! Check for restart file.  If one exists, use it.
       inquire(file=NameFile, exist=DoRestart)
       if(.not. DoRestart) then
          write(*,*) NameSub, &
               ": WARNING did not find geoindices restart file ", &
               trim(NameFile)
          MagHistory_DII(iDim,:,:) = 0.0
          CYCLE
       end if

       write(*,*)'GM: ',NameSub, ' reading ',trim(NameFile)

       call open_file(file=NameFile, status='OLD', NameCaller=NameSub)

       ! Read size of array, ensure that it matches expected.
       ! If not, it means that the restart is incompatible and cannot be used.
       read(UnitTmp_, *) nMagTmp, iSizeTmp

       if( nMagTmp /= nKpMag .or. iSizeTmp /= iSizeKpWindow ) then
          write(*,*)'ERROR: in file ',trim(NameFile)
          write(*,*)'Restart file contains  nMagTmp, iSizeTmp=', &
               nMagTmp, iSizeTmp
          write(*,*)'PARAM.in contains nKpMag, iSizeKpWindow =', &
               nKpMag, iSizeKpWindow
          call stop_mpi(NameSub//' restart does not match Kp settings!')
       end if

       do j = 1, iSizeKpWindow
          do i = 1, nKpMag
             read(UnitTmp_,*) MagHistory_DII(iDim,i,j)
          end do
       end do
       call close_file

    end do

    IsFirstCalc  = .false.
    IsSecondCalc = .false.

    call test_stop(NameSub, DoTest)
  end subroutine read_geoind_restart
  !============================================================================

  ! ===================================================================
  subroutine match_copy_restart_variables

    ! This subroutine allows to use the state stored in an existing
    ! restart file even if the variables or their order as defined in
    ! the present equation file has changed.

    ! PROCEDURE:
    ! 1. Locate the current state variable in the array read from the
    ! restart file (by matching their name strings).
    ! 2. Copy the restart data into the correct position in State_VGB.
    ! 3. Apply specific rules for handling non-matching state variables.

    ! IMPORTANT NOTES!!
    ! 1. If the restart file includes additional variables which are not part
    !    of the current equation module, they will be ignored, unless a
    !    a specific rule is implemented here.
    ! 2. If the current equation module includes variables not present
    !    in the restart file, they will be assigned values according to
    !    specific rules implemented here. If no rule is defined, the default
    !    state will be used for these variables (unless UseStrict=T, in which
    !    case the code will stop excution).

    use ModVarIndexes, ONLY: nVar, NameVar_V, p_, Pe_, DefaultState_V, &
         ChargeStateFirst_, ChargeStateLast_
    use ModAdvance,    ONLY: UseElectronPressure
    use ModMain,       ONLY: UseStrict, NameVarLower_V

    integer :: i, j, k, iVar, iVarRead, iBlock, iVarPeRestart
    integer :: iVarMatch_V(nVar) = 0
    logical :: UseElectronPressureRestart = .false.

    integer              :: iVarMapping
    integer, allocatable :: iVarFrom_I(:), iVarTo_I(:)

    ! -----------------------------------------------------------------
    ! If no change of variables occured, copy directly and return.

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'match_copy_restart_variables'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)

    if(.not. DoChangeRestartVariables) then
       do iBlock = 1,nBlock
          State_VGB(:,1:nI,1:nJ,1:nK,iBlock) = &
               StateRead_VCB(:,1:nI,1:nJ,1:nK,iBlock)
          if (n_prev == n_step) &
               ImplOld_VCB(:,1:nI,1:nJ,1:nK,iBlock) = &
               ImplOldRead_VCB(:,1:nI,1:nJ,1:nK,iBlock)
       end do
       RETURN
    end if

    ! Change of state variables!!
    if(iProc==0) then
       write(*,*) 'Changing state variables from restart file'
       write(*,*) 'Restart file variables: ', NameVarRestart_V
       write(*,*) 'Current variables:      ', NameVar_V
       write(*,*) 'DoSpecifyRestartVarMapping =', DoSpecifyRestartVarMapping
       if (DoSpecifyRestartVarMapping) &
            write(*,*) 'nVarRestartMapping         =', nVarRestartMapping
    end if

    ! Loop over the current state variables, and locate the index of
    ! the corresponding variable in the restart file
    MATCHLOOP: do iVar = 1,nVar
       do iVarRead = 1, nVarRestart
          if (NameVarLower_V(iVar) == NameVarRestart_V(iVarRead)) then
             iVarMatch_V(iVar) = iVarRead
             CYCLE MATCHLOOP
          end if
       end do
    end do MATCHLOOP

    if (DoSpecifyRestartVarMapping) then
       if (allocated(iVarFrom_I)) deallocate(iVarFrom_I)
       if (allocated(iVarTo_I))   deallocate(iVarTo_I)
       allocate(iVarFrom_I(nVarRestartMapping))
       allocate(iVarTo_I(nVarRestartMapping))

       do iVarMapping = 1, nVarRestartMapping
          do iVar = 1, nVar
             if (NameVarRestartTo_V(iVarMapping) /= NameVarLower_V(iVar)) CYCLE
             iVarTo_I(iVarMapping) = iVar
             EXIT
          end do

          do iVarRead = 1, nVarRestart
             if (NameVarRestartFrom_V(iVarMapping) /= &
                  NameVarRestart_V(iVarRead)) CYCLE
             iVarFrom_I(iVarMapping) = iVarRead
             EXIT
          end do

          if (iVarFrom_I(iVarMapping) < 0 .or.                         &
               iVarFrom_I(iVarMapping) > nVarRestart .and. iProc == 0) &
               call stop_mpi(NameSub//                                 &
               ': unknown NameVar in NameVarsRestartFrom')

          if (iVarTo_I(iVarMapping) < 0 .or.                  &
               iVarTo_I(iVarMapping) > nVar .and. iProc == 0) &
               call stop_mpi(NameSub//': unknown NameVar in NameVarsRestartTo')

          iVarMatch_V(iVarTo_I(iVarMapping)) = iVarFrom_I(iVarMapping)
       end do
    end if

    if (iProc == 0) then
       write(*,*) 'Mapping information:'
       do iVar = 1, nVar
          if (iVarMatch_V(iVar) <=0) CYCLE
          write(*,'(1x, A, A1, I2, A1, 3x, A, 3x, A, A1, I2, A1)')       &
               trim(NameVarRestart_V(iVarMatch_V(iVar))), &
               '(', iVarMatch_V(iVar), ')', '==>', &
               trim(NameVar_V(iVar)), '(', iVar, ')'
       end do
    end if

    ! Copy restart data into State_VGB as needed
    do iVar = 1,nVar
       if (iVarMatch_V(iVar) > 0) then
          do iBlock = 1,nBlock
             do i =1,nI ; do j=1,nJ; do k=1,nK
                State_VGB(iVar,i,j,k,iBlock) = &
                     StateRead_VCB(iVarMatch_V(iVar),i,j,k,iBlock)
             end do; end do ; end do
          end do
       else
          ! Rules for initializing state variables that are not present
          ! in the restart file
          select case(NameVar_V(iVar))
          case('Bx','By','Bz','Hyp')
             State_VGB(iVar,1:nI,1:nJ,1:nK,iBlock) = 0.0

          case('Pe')
             ! When electron pressure is used but is not present in the restart
             ! file, divide pressure from restart state between ions and
             ! electrons
             do iBlock = 1,nBlock
                do i =1,nI ; do j=1,nJ; do k=1,nK
                   State_VGB(Pe_,i,j,k,iBlock) = &
                        0.5*StateRead_VCB(iVarMatch_V(p_),i,j,k,iBlock)
                   State_VGB(p_,1:nI,1:nJ,1:nK,iBlock) = &
                        0.5*StateRead_VCB(iVarMatch_V(p_),i,j,k,iBlock)
                end do; end do ; end do
             end do
          case default
             if(ChargeStateLast_ > 1 .and. iVar >= ChargeStateFirst_ .and. &
                  iVar <= ChargeStateLast_)then
                if(iProc == 0 .and. iVar == ChargeStateFirst_)write(*,*)&
                     'charge state variable initialized via user action !!!'
                CYCLE
             end if
             if(iProc==0) &
                  write(*,*) 'WARNING!!! : the state variable ', &
                  NameVar_V(iVar) //                            &
                  'is not present in the restart file and no rule is'//&
                  ' implemented to define its value.'
             if(UseStrict) then
                call stop_mpi(NameSub// &
                     ' ERROR: State after restart not well defined!')
             else
                if(iProc==0) write(*,*) 'Using default values instead.'
                State_VGB(iVar,1:nI,1:nJ,1:nK,iBlock) = DefaultState_V(iVar)
             end if
          end select
       end if
    end do

    ! Check if restart file contains certain additional variables
    if(.not. UseElectronPressure) then
       ! Check if the restart file containes electron pressure
       do iVarRead = 1, nVarRestart
          if (NameVarRestart_V(iVarRead) == 'Pe') then
             UseElectronPressureRestart = .true.
             iVarPeRestart = iVarRead
             EXIT
          end if
       end do
    end if

    ! Implement rules for using additional variables present in the restart
    ! file but not in the equation module

    ! PRESSURE
    if(.not. UseElectronPressure .and. UseElectronPressureRestart) then
       do iBlock = 1,nBlock
          do i =1,nI ; do j=1,nJ; do k=1,nK
             ! Add the restart file electron pressure to the total pressure.
             State_VGB(p_,i,j,k,iBlock) = State_VGB(p_,i,j,k,iBlock) + &
                  StateRead_VCB(iVarPeRestart,i,j,k,iBlock)
          end do; end do; end do
       end do
    end if
    ! ADD MORE RULES HERE WHEN NEEDED

    ! For BFD2 scheme
    ! Copy state into ImplOld_VCB
    ! Note this will affect the accuracy of the solution in the
    ! next iteration, but this should be a small effect compared to
    ! the change of state variables
    if (n_prev == n_step) then
       do iBlock = 1,nBlock
          do i =1,nI ; do j=1,nJ; do k=1,nK
             ImplOld_VCB(:,i,j,k,iBlock) = &
                  State_VGB(:,i,j,k,iBlock)
          end do; end do ; end do
       end do
    end if

    call test_stop(NameSub, DoTest)
  end subroutine match_copy_restart_variables
  !============================================================================

end module ModRestartFile
!==============================================================================

