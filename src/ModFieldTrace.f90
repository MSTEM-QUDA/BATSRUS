!  Copyright (C) 2002 Regents of the University of Michigan,
!  portions used with permission
!  For more information, see http://csem.engin.umich.edu/tools/swmf

module ModFieldTrace

  use BATL_lib, ONLY: &
       test_start, test_stop, StringTest, xTest, yTest, zTest, &
       iTest, jTest, kTest, iBlockTest, iProcTest, iProc, iComm, &
       IsNeighbor_P, nDim, nI, nJ, nK, MinI, MaxI, MinJ, MaxJ, MinK, MaxK, &
       MaxBlock, x_, y_, z_, IsCartesianGrid
  use ModMain, ONLY: iNewDecomposition, TypeCoordSystem
  use ModPhysics, ONLY: rBody
#ifdef OPENACC
  use ModUtilities, ONLY: norm2
#endif
  use ModNumConst, ONLY: i_DD
  use ModKind, ONLY: Real8_
  use ModIO,   ONLY: iUnitOut, write_prefix

  implicit none
  save

  private ! except
  public:: init_mod_field_trace       ! initialize module
  public:: clean_mod_field_trace      ! clean module
  public:: read_field_trace_param     ! set trace parameters
  public:: trace_field_grid           ! trace field from 3D MHD grid cells
  public:: trace_field_equator        ! trace field from equatorial plane
  public:: extract_field_lines        ! extract field lines
  public:: integrate_field_from_sphere! integrate field from spherical surface
  public:: write_plot_line            ! extract field lines into plot file(s)
  public:: write_plot_ieb             !
  public:: write_plot_lcb             ! write plot with last closed B lines
  public:: write_plot_equator         !

  ! extracting variables (in SI units?) along the field trace
  logical, public:: DoExtractState   = .false.
  logical, public:: DoExtractUnitSi  = .false.
  logical, public:: DoExtractBGradB1 = .false.
  logical, public:: DoExtractEfield  = .false.

  ! Transfrom to SM coordinates?
  logical:: UseSmg = .true.

  ! mapping to the ionosphere
  real, public, allocatable:: RayMapLocal_DSII(:,:,:,:), RayMap_DSII(:,:,:,:)

  ! Ray and rayface contain the x,y,z coordinates for the foot point of a given
  ! field line for both directions, eg.
  ! ray(2,1,i,j,k,iBlock) is the y coord for direction 1
  ! ray is for cell centers; rayface is for block surfaces with
  ! a -0.5,-0.5,-0.5 shift in block normalized coordinates

  real, public, allocatable :: ray(:,:,:,:,:,:)
  real, public, allocatable :: rayface(:,:,:,:,:,:)

  ! Integrals added up for all the local ray segments
  ! The fist index corresponds to the variables (index 0 shows closed vs. open)
  ! The second and third indexes correspond to the latitude and longitude of
  ! the IM/RCM grid
  real, public, allocatable :: RayIntegral_VII(:,:,:)
  real, public, allocatable :: RayResult_VII(:,:,:)

  ! map rays to the SM equatorial plane
  logical, public :: DoMapEquatorRay= .false.

  real, public :: rIonosphere = 0.

  ! Radius where the tracing stops
  real, public :: rTrace = 0.

  ! Named indexes
  integer, public, parameter :: &
       InvB_=1, Z0x_=2, Z0y_=3, Z0b_=4, &
       RhoInvB_=5, pInvB_=6,  &
       HpRhoInvB_=5, HpPInvB_=6, OpRhoInvB_=7, OpPInvB_=8

  ! These indexes depend on multi-ion
  integer, public:: PeInvB_, xEnd_, yEnd_, zEnd_, Length_

  ! Various values indicating the end state of a ray
  real, public :: CLOSEDRAY, OPENRAY, BODYRAY, LOOPRAY, NORAY, OUTRAY

  ! Select between fast less accurate and slower but more accurate algorithms
  logical, public:: UseAccurateTrace    = .false.

  ! Logical for raytracing in IE coupling
  logical, public :: DoTraceIE = .false.

  ! Conversion matrix between SM and GM coordinates
  ! (to be safe initialized to unit matrix)
  real, public :: GmSm_DD(3,3) = i_DD

  ! Local variables --------------------------------

  ! Square of radii to save computation
  real :: rTrace2 = 0.0
  real :: rIonosphere2 = 0.0

  ! Inner radius to end tracing (either rTrace or rIonosphere)
  real :: rInner = 0.0, rInner2 = 0.0

  ! Possible tasks
  logical :: DoTraceRay     = .true.  ! trace rays from all cell centers
  logical :: DoMapRay       = .false. ! map rays down to the ionosphere
  logical :: DoExtractRay   = .false. ! extract info along the rays into arrays
  logical :: DoIntegrateRay = .false. ! integrate some functions along the rays

  ! Use old IJK based logic for Cartesian tracing
  logical :: UseOldMethodOfRayTrace = .true.

  ! Number of rays per dimension on the starting grid
  ! This is needed for DoExtractRay = .true. only
  integer :: nRay_D(4) = [0, 0, 0, 0]

  ! The vector field to trace: B/U/J
  character         :: NameVectorField = 'B'

  ! How often shall we synchronize PE-s for the accurate algorithms
  real         :: DtExchangeRay = 0.1

  ! The minimum number of time steps between two ray traces on the same grid
  integer      :: DnRaytrace = 1

  ! Named parameters for ray status
  ! These values all must be less than 1, because 1..6 correspond to the
  ! six faces of the block. The ordering of these values is arbitrary.
  integer, parameter ::       &
       ray_iono_    =  0,     &
       ray_equator_ = -1,     &
       ray_block_   = -2,     &
       ray_open_    = -3,     &
       ray_loop_    = -4,     &
       ray_body_    = -5,     &
       ray_out_     = -6

  ! Stored face and cell indices of the 2 rays starting from a face of a block
  integer, allocatable :: rayend_ind(:,:,:,:,:,:)

  ! Stored weights for the 2 rays starting from a face of a block
  real, allocatable :: rayend_pos(:,:,:,:,:,:)

  ! Radius where ray tracing with numerical B stops and
  ! radius and radius squared of ionosphere

  ! Node interpolated magnetic field components without B0
  real, allocatable :: bb_x(:,:,:,:)
  real, allocatable :: bb_y(:,:,:,:)
  real, allocatable :: bb_z(:,:,:,:)

  ! Total magnetic field with second order ghost cells
  real, allocatable :: Bxyz_DGB(:,:,:,:,:)

  ! Prefer open and closed field lines in interpolation ?!
  logical :: UsePreferredInterpolation

  ! Maximum length of ray
  real :: RayLengthMax = 200.

  ! Testing
  logical :: DoTestRay=.false.

  ! Base time for timed exchanges between rays
  real(Real8_) :: CpuTimeStartRay

  ! Number of rays found to be open based on the neighbors
  integer      :: nOpen

  ! ----------- Variables for integrals along the ray -------------------

  ! Number of integrals depends on UseMultiIon and UseAnisPressure
  integer:: nRayIntegral

  ! Number of state variables to be integrated and number of variables for
  ! a local segment
  integer :: nExtraIntegral, nLocalIntegral

  ! Flow variables to be integrated (rho and P) other than the magnetic field
  real, allocatable :: Extra_VGB(:,:,:,:,:)

  ! Integrals for a local ray segment
  real, allocatable :: RayIntegral_V(:)

  ! Temporary array for extracting b.grad(B1) info
  real, allocatable :: bGradB1_DGB(:,:,:,:,:)

  ! Temporary array for extracting curvature of B info
  real, allocatable :: CurvatureB_GB(:,:,:,:)
  logical:: DoExtractCurvatureB = .false.

  integer :: iLatTest = 1, iLonTest = 1

contains
  !============================================================================

  subroutine read_field_trace_param(NameCommand)

    use ModMain,      ONLY: UseRaytrace
    use ModReadParam, ONLY: read_var

    character(len=*), intent(in):: NameCommand

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'read_field_trace_param'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)
    select case(NameCommand)
    case("#TRACE", "#RAYTRACE")
       call read_var('UseTrace', UseRaytrace)
       if(UseRaytrace)then
          call read_var('UseAccurateTrace', UseAccurateTrace)
          call read_var('DtExchangeTrace',  DtExchangeRay)
          call read_var('DnTrace',          DnRaytrace)
       end if
    case("#TRACERADIUS")
       call read_var('rTrace',      rTrace)
       call read_var('rIonosphere', rIonosphere)
    case("#TRACELIMIT", "#RAYTRACELIMIT")
       call read_var('TraceLengthMax', RayLengthMax)
    case("#TRACEEQUATOR", "#RAYTRACEEQUATOR")
       call read_var('DoMapEquatorTrace', DoMapEquatorRay)
    case("#TRACEIE", "#IE")
       call read_var('DoTraceIE', DoTraceIE)
    case default
       call stop_mpi(NameSub//': unknown command='//NameCommand)
    end select

    call test_stop(NameSub, DoTest)
  end subroutine read_field_trace_param
  !============================================================================
  subroutine xyz_to_latlon(Pos_D)

    use ModNumConst, ONLY: cTiny, cRadToDeg

    ! Convert xyz coordinates to latitude and longitude (in degrees)
    ! Put the latitude and longitude into the 1st and 2nd elements
    real, intent(inout) :: Pos_D(3)

    real :: x, y, z

    character(len=*), parameter:: NameSub = 'xyz_to_latlon'
    !--------------------------------------------------------------------------
    ! Check if this direction is connected to the ionosphere or not
    if(Pos_D(1) > CLOSEDRAY)then

       ! Convert GM position into IM position
       Pos_D = matmul(Pos_D, GmSm_DD)

       ! Store input coordinates
       x = Pos_D(1); y = Pos_D(2); z = Pos_D(3)

       ! Make sure that asin will work, -1<= z <=1
       z = max(-1.0+cTiny, z)
       z = min( 1.0-cTiny, z)

       ! Calculate  -90 < latitude = asin(z)  <  90
       Pos_D(1) = cRadToDeg * asin(z)

       ! Calculate -180 < longitude = atan2(y,x) < 180
       if(abs(x) < cTiny .and. abs(y) < cTiny) x = 1.0
       Pos_D(2) = cRadToDeg * atan2(y,x)

       ! Get rid of negative longitude angles
       if(Pos_D(2) < 0.0) Pos_D(2) = Pos_D(2) + 360.0

    else
       ! Impossible values
       Pos_D(1) = -100.
       Pos_D(2) = -200.
    endif

  end subroutine xyz_to_latlon
  !============================================================================

  subroutine xyz_to_rphi(Pos_DI)

    use ModNumConst, ONLY: cRadToDeg

    ! Convert X,Y coordinates into radial distance in the XY plane
    ! and longitude (in degrees) for closed rays
    real, intent(inout) :: Pos_DI(3,2)

    real :: x, y, r, Phi

    ! index for the direction connected to the equator
    integer:: iDir

    ! Check if both directions are connected to the ionosphere
    ! or the equatorial plane

    character(len=*), parameter:: NameSub = 'xyz_to_rphi'
    !--------------------------------------------------------------------------
    if(all(Pos_DI(3,:) > CLOSEDRAY))then

       ! Check if the first direction of the ray ends on the ionosphere
       if(Pos_DI(1,1)**2 + Pos_DI(2,1)**2 <= rIonosphere2) then
          iDir = 2
       else
          iDir = 1
       end if

       ! Convert to radius and longitude in degrees
       x   = Pos_DI(1,iDir)
       y   = Pos_DI(2,iDir)
       r   = sqrt(x**2 + y**2)
       Phi = cRadToDeg * atan2(y, x)
       ! Get rid of negative longitude angles
       if(Phi < 0.0) Phi = Phi + 360.0

       ! Put r and Phi for BOTH directions
       Pos_DI(1,:) = r
       Pos_DI(2,:) = Phi

    else
       ! Impossible values
       Pos_DI(1,:) = -1.0
       Pos_DI(2,:) = -200.
    endif

  end subroutine xyz_to_rphi
  !============================================================================

  subroutine xyz_to_latlonstatus(Ray_DI)

    real, intent(inout) :: Ray_DI(3,2)

    integer :: iRay

    ! Convert 1st and 2nd elements into latitude and longitude

    character(len=*), parameter:: NameSub = 'xyz_to_latlonstatus'
    !--------------------------------------------------------------------------
    if(DoMapEquatorRay)then
       call xyz_to_rphi(Ray_DI)
    else
       do iRay=1,2
          call xyz_to_latlon(Ray_DI(:,iRay))
       end do
    end if
    ! Convert 3rd element into a status variable

    if(Ray_DI(3,1)>CLOSEDRAY .and. Ray_DI(3,2)>CLOSEDRAY)then
       Ray_DI(3,:)=3.      ! Fully closed
    elseif(Ray_DI(3,1)>CLOSEDRAY .and. Ray_DI(3,2)==OPENRAY)then
       Ray_DI(3,:)=2.      ! Half closed in positive direction
    elseif(Ray_DI(3,2)>CLOSEDRAY .and. Ray_DI(3,1)==OPENRAY)then
       Ray_DI(3,:)=1.      ! Half closed in negative direction
    elseif(Ray_DI(3,1)==OPENRAY .and. Ray_DI(3,2)==OPENRAY) then
       Ray_DI(3,:)=0.      ! Fully open
    elseif(Ray_DI(3,1)==BODYRAY)then
       Ray_DI(3,:)=-1.     ! Cells inside body
    elseif(Ray_DI(3,1)==LOOPRAY .and.  Ray_DI(3,2)==LOOPRAY) then
       Ray_DI(3,:)=-2.     ! Loop ray within block
    else
       Ray_DI(3,:)=-3.     ! Strange status
    end if

  end subroutine xyz_to_latlonstatus
  !============================================================================

  subroutine init_mod_field_trace

    use ModPhysics, ONLY: DipoleStrengthSi
    use ModAdvance, ONLY: UseElectronPressure
    use ModMain,    ONLY: DoMultiFluidIMCoupling

    ! True if ray array is still to be initialized
    logical :: DoInitRay = .true.

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'init_mod_field_trace'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)

    if(rIonosphere == 0.0)then
       ! Set default ionosphere radius
       ! Currently follow_iono only works for a dipole
       ! This may be generalized in the future
       if(DipoleStrengthSi /= 0.0)then
          rIonosphere = 1.0
       else
          rIonosphere = -1.0
       end if
    end if

    if(rTrace == 0.0)then
       if(rBody > 0.0)then
          rTrace = max(rBody, rIonosphere)
       else
          rTrace = -1.0
       end if
    end if

    ! Radius square preserving sign
    rIonosphere2 = rIonosphere*abs(rIonosphere)
    rTrace2      = rTrace*abs(rTrace)

    if(rIonosphere < 0.0)then
       rInner = abs(rTrace)
    else
       rInner = rIonosphere
    end if
    rInner2 = rInner**2

    CLOSEDRAY= -(rInner + 0.05)
    OPENRAY  = -(rInner + 0.1)
    BODYRAY  = -(rInner + 0.2)
    LOOPRAY  = -(rInner + 0.3)
    NORAY    = -(rInner + 100.0)
    OUTRAY   = -(rInner + 200.0)

    if(DoTest)then
       write(*,*) 'rTrace, rTrace2          =', rTrace, rTrace2
       write(*,*) 'rIonosphere, rIonosphere2=', rIonosphere, rIonosphere2
       write(*,*) 'rInner, rInner2          =', rInner, rInner2
       write(*,*) 'CLOSEDRAY,OPENRAY,OUTRAY =', CLOSEDRAY, OPENRAY, OUTRAY
    end if
    if(allocated(ray)) RETURN

    ! Determine number of flow variable integrals
    if(DoMultiFluidIMCoupling)then
       ! H+ and O+ densities pressures
       nExtraIntegral = 4
    else
       ! total density and pressure
       nExtraIntegral = 2
    end if

    if(UseElectronPressure)then
       nExtraIntegral = nExtraIntegral + 1
       PeInvB_ = nExtraIntegral
    end if

    ! Number of integrals for a local ray segment:
    !    InvB_, Z0x_, Z0y_, Z0b_ and extras
    nLocalIntegral = nExtraIntegral + 4

    ! Indexes for the final position of the ray
    xEnd_ = nLocalIntegral + 1; yEnd_ = xEnd_ + 1; zEnd_ = yEnd_ + 1
    Length_ = zEnd_ + 1

    ! Number of reals stored in the RayIntegral_VII and RayResult_VII arrays
    nRayIntegral = Length_

    ! Initialize ray array (write_logfile may use it before first ray tracing)
    allocate(ray(3,2,nI+1,nJ+1,nK+1,MaxBlock))
    allocate(rayface(3,2,nI+1,nJ+1,nK+1,MaxBlock))
    allocate(rayend_ind(3,2,nI+1,nJ+1,nK+1,MaxBlock))
    allocate(rayend_pos(4,2,nI+1,nJ+1,nK+1,MaxBlock))
    allocate(bb_x(1:nI+1,1:nJ+1,1:nK+1,MaxBlock))
    allocate(bb_y(1:nI+1,1:nJ+1,1:nK+1,MaxBlock))
    allocate(bb_z(1:nI+1,1:nJ+1,1:nK+1,MaxBlock))
    allocate(Bxyz_DGB(3,MinI:MaxI,MinJ:MaxJ,MinK:MaxK,MaxBlock))
    allocate(Extra_VGB(nExtraIntegral,MinI:MaxI,MinJ:MaxJ,MinK:MaxK,MaxBlock))
    allocate(RayIntegral_V(1:nLocalIntegral))

    if(DoInitRay)then
       ray       = 0.0
       DoInitRay = .false.
    end if

    if(iProc==0)then
       call write_prefix
       write(iUnitOut,'(a)') NameSub//' allocated arrays'
    end if

    UseSmg = TypeCoordSystem == 'GSM' .or. TypeCoordSystem == 'GSE'

    call test_stop(NameSub, DoTest)
  end subroutine init_mod_field_trace
  !============================================================================

  subroutine clean_mod_field_trace

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'clean_mod_field_trace'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)
    if(.not.allocated(ray)) RETURN
    deallocate(ray)
    deallocate(rayface)
    deallocate(rayend_ind)
    deallocate(rayend_pos)
    deallocate(bb_x)
    deallocate(bb_y)
    deallocate(bb_z)
    deallocate(Bxyz_DGB)
    deallocate(Extra_VGB)
    deallocate(RayIntegral_V)

    if(iProc==0)then
       call write_prefix
       write(iUnitOut,'(a)') 'clean_mod_raytrace deallocated arrays'
    end if

    call test_stop(NameSub, DoTest)
  end subroutine clean_mod_field_trace
  !============================================================================

  subroutine ray_trace_accurate

    ! Trace field lines from cell centers to the outer or inner boundaries

    use CON_ray_trace,    ONLY: ray_init
    use ModMain
    use ModAdvance,       ONLY: State_VGB, Bx_, Bz_
    use ModB0,            ONLY: B0_DGB
    use ModGeometry,      ONLY: r_BLK, true_cell
    use BATL_lib,         ONLY: Xyz_DGB, message_pass_cell
    use ModMpi

    ! Indices corresponding to the starting point and directon of the ray
    integer :: i, j, k, iBlock, iRay

    ! Testing and timing
    logical :: DoTime

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'ray_trace_accurate'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)

    if(DoTest)write(*,*) NameSub,' starting'

    ! Initialize constants
    DoTraceRay     = .true.
    DoMapRay       = .false.
    DoIntegrateRay = .false.
    DoExtractRay   = .false.
    nRay_D         = [ nI, nJ, nK, nBlock ]
    NameVectorField = 'B'

    ! (Re)initialize CON_ray_trace
    call ray_init(iComm)

    if(DoTime) call timing_reset('ray_pass', 2)

    ! Copy magnetic field into Bxyz_DGB
    do iBlock = 1, nBlock; if(Unused_B(iBlock))CYCLE
       Bxyz_DGB(:,:,:,:,iBlock) = State_VGB(Bx_:Bz_,:,:,:,iBlock)
    end do
    ! Fill in ghost cells with first order prolongation
    call message_pass_cell(3, Bxyz_DGB, nProlongOrderIn=1)
    if(UseB0)then
       ! Add B0
       do iBlock = 1, nBlock; if(Unused_B(iBlock))CYCLE
          Bxyz_DGB(:,:,:,:,iBlock) = &
               Bxyz_DGB(:,:,:,:,iBlock) + B0_DGB(:,:,:,:,iBlock)
       end do
    end if

    ! Initial values
    ray = NORAY

    if(DoTest)write(*,*)'rayface normalized B'
    if(DoTime.and.iProc==0)then
       write(*,'(a)',ADVANCE='NO') 'setup and normalization:'
       call timing_show('ray_trace',1)
    end if

    ! This loop order seems to give optimal speed
    CpuTimeStartRay = MPI_WTIME();
    do k = 1, nK; do j = 1, nJ; do i = 1, nI
       do iBlock = 1, nBlock
          if(Unused_B(iBlock))CYCLE

          DoTestRay = DoTest .and. &
               all( [i,j,k,iBlock,iProc]== &
               [iTest,jTest,kTest,iBlockTest,iProcTest] )

          do iRay = 1,2
             ! Short cut for inner and false cells
             if(R_BLK(i,j,k,iBlock) < rInner .or. &
                  .not.true_cell(i,j,k,iBlock))then
                ray(:,:,i,j,k,iBlock)=BODYRAY
                if(DoTestRay)write(*,*)'Shortcut BODYRAY iProc,iRay=',iProc,iRay
                CYCLE
             end if

             if(DoTestRay)write(*,*)'calling follow_ray iProc,iRay=',iProc,iRay

             ! Follow ray in direction iRay
             call follow_ray(iRay, [i,j,k,iBlock], Xyz_DGB(:,i,j,k,iBlock))

          end do ! iRay
       end do    ! iBlock
    end do; end do; end do  ! i, j, k

    ! Do remaining rays passed from other PE-s
    call finish_ray

    ! Convert x, y, z to latitude and longitude, and status
    do iBlock=1,nBlock
       if(Unused_B(iBlock)) CYCLE
       do k=1,nK; do j=1,nJ; do i=1,nI

          call xyz_to_latlonstatus(ray(:,:,i,j,k,iBlock))

          ! Comment out these statements as they spew thousands of lines with IM coupling
          ! if(ray(3,1,i,j,k,iBlock)==-2.) write(*,*) &
          !     'Loop ray found at iProc,iBlock,i,j,k,ray=',&
          !     iProc,iBlock,i,j,k,ray(:,:,i,j,k,iBlock)

          ! if(ray(3,1,i,j,k,iBlock)==-3.) write(*,*) &
          !     'Strange ray found at iProc,iBlock,i,j,k,ray=',&
          !     iProc,iBlock,i,j,k,ray(:,:,i,j,k,iBlock)
       end do; end do; end do
    end do

    if(DoTest)write(*,*)'ray lat, lon, status=',&
         ray(:,:,iTest,jTest,kTest,iBlockTest)

    if(DoTime.and.iProc==0)then
       write(*,'(a)',ADVANCE='NO') 'Total ray tracing time:'
       call timing_show('ray_trace', 1)
    end if

    if(DoTest)write(*,*) NameSub,' finished'

    call test_stop(NameSub, DoTest)
  end subroutine ray_trace_accurate
  !============================================================================

  subroutine finish_ray

    ! This subroutine is a simple interface for the last call to follow_ray
    !--------------------------------------------------------------------------
    call follow_ray(0, [0, 0, 0, 0], [ 0., 0., 0. ])

  end subroutine finish_ray
  !============================================================================

  subroutine follow_ray(iRayIn,i_D,XyzIn_D)

    !DESCRIPTION:
    ! Follow ray in direction iRayIn (1 is parallel with the field,
    !                                 2 is anti-parallel,
    !                                 0 means that no ray is passed
    ! Always follow rays received from other PE-s.
    !
    ! The passed ray is identified by the four dimensional index array i\_D.
    ! The meaning of i\_D d depends on the context:
    !  3 cell + 1 block index for 3D ray tracing
    !  1 latitude + 1 longitude index for ray integration
    !  1 linear index for ray extraction.
    !
    ! The rays are followed until the ray hits the outer or inner
    ! boundary of the computational domain. The results are saved into
    ! arrays defined in ModFieldTrace or into files based on the logicals
    ! in ModFieldtrace (more than one of these can be true):
    !
    ! If DoTraceRay, follow the ray from cell centers of the 3D AMR grid,
    !    and save the final position into
    !    ModFieldTrace::ray(:,iRayIn,i_D(1),i_D(2),i_D(3),i_D(4)) on the
    !    processor that started the ray trace.
    !
    ! If DoMapRay, map the rays down to the ionosphere, save spherical
    !    coordinates (in SMG) into
    !    ModFieldTrace::RayMap_DSII(4,i_D(1),i_D(2),i_D(3))
    !
    ! If DoIntegrateRay, do integration along the rays and
    !    save the integrals into ModFieldTrace::RayIntegral_VII(i_D(1),i_D(2))
    !
    ! If DoExtractRay, extract data along the rays, collect and sort it
    !    In this case the rays are indexed with i_D(1).
    !
    ! EOP

    use CON_ray_trace, ONLY: ray_exchange, ray_get, ray_put

    use ModKind
    use BATL_lib, ONLY: find_grid_block, iNodeNei_IIIB, iTree_IA, Proc_, nProc, &
         CellSize_DB, CoordMin_DB, Unused_B
    use BATL_size, ONLY: MaxBlock, nBlock

    use ModMpi

    !INPUT ARGUMENTS:
    integer, intent(in) :: iRayIn     ! ray direction, 0 if no ray is passed
    integer, intent(in) :: i_D(4)     ! general index array for start position
    real,    intent(in) :: XyzIn_D(3) ! coordinates of starting position

    !LOCAL VARIABLES:
    ! Cell, block and PE indexes for initial position and ray direction
    integer :: iStart, jStart, kStart, iBlockStart, iProcStart, iRay
    integer :: iStart_D(4)

    ! Current position of the ray
    integer :: iBlockRay
    real    :: XyzRay_D(3)

    ! Current length of ray
    real    :: RayLength

    ! Is the ray trace done
    logical :: DoneRay

    ! Shall we get ray from other PE-s
    logical :: DoGet

    ! Did we get rays from other PE-s
    logical :: IsFound

    ! Is the ray parallel with the vector field
    logical :: IsParallel

    integer, parameter :: MaxCount = 1000
    integer :: iFace, iCount, jProc, jBlock

    logical :: DoneAll
    integer :: iCountRay = 0

    real(Real8_) :: CpuTimeNow

    integer :: i, j, k, iBlock, iNode

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'follow_ray'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)

    if(iRayIn /= 0)then

       ! Store starting indexes and ray direction
       iStart = i_D(1); jStart = i_D(2); kStart = i_D(3);
       iBlockStart = i_D(4); iProcStart = iProc
       iRay   = iRayIn

       iStart_D = i_D
       if(DoTest)call set_DoTestRay

       ! Current position and length
       iBlockRay = i_D(4)
       XyzRay_D  = XyzIn_D
       RayLength = 0.0

       if(DoTestRay)write(*,'(a,6i4,3es12.4)')&
            'Local ray at iProc,i_D,iRay,XyzIn_D=',iProc,i_D,iRay,XyzIn_D

    end if

    ! If iRayIn==0 there are no more local rays to follow so get from other PEs
    DoGet = iRayIn==0
    IsFound = .true.

    RAYS: do

       if(DoGet)then
          GETRAY: do
             call ray_get(IsFound,iProcStart,iStart_D,XyzRay_D,RayLength,&
                  IsParallel,DoneRay)

             if(IsFound)then
                if(DoTest)call set_DoTestRay

                if(IsParallel)then
                   iRay=1
                else
                   iRay=2
                end if
                if(DoTestRay)write(*,*)'Recv ray iProc,iRay,Done,XyzRay_D=',&
                     iProc,iRay,DoneRay,XyzRay_D

                if(DoneRay)then
                   if(.not.DoTraceRay)then
                      write(*,*)NameSub,' WARNING ',&
                           'received DoneRay=T for DoTraceRay = .false. !'
                      CYCLE GETRAY
                   end if

                   ! Store the result into the ModFieldTrace::ray
                   iStart      = iStart_D(1)
                   jStart      = iStart_D(2)
                   kStart      = iStart_D(3)
                   iBlockStart = iStart_D(4)

                   ray(:,iRay,iStart,jStart,kStart,iBlockStart)=XyzRay_D

                   if(DoTestRay)write(*,*)&
                        'Storing recv ray iProc,iRay,i,j,k,iBlock,ray=',&
                        iProc,iRay,iStart,jStart,kStart,iBlockStart,XyzRay_D

                   ! Get another ray from the others
                   CYCLE GETRAY
                else
                   ! Find block for the received ray
                   call find_grid_block(XyzRay_D,jProc,iBlockRay)

                   if(jProc /= iProc)call stop_mpi(&
                        'GM_ERROR in ray_trace: Recvd ray is not in this PE')

                   if(DoTestRay)write(*,*)'Block for recv ray iProc,iBlock=',&
                        iProc,iBlockRay
                end if
             end if
             EXIT GETRAY
          end do GETRAY
       end if ! DoGet

       if(IsFound)then
          call follow_this_ray
          DoGet = .true.
       else
          if(iRayIn>0)then
             ! Stop working on received rays if there are no more
             ! but there are still local rays
             RETURN
          else
             ! Try to get more rays from others and check if everyone is done
             call ray_exchange(.true., DoneAll, IsNeighbor_P)
             if(DoneAll)then
                EXIT RAYS
             else
                CYCLE RAYS
             end if
          end if
       end if

       iCountRay = iCountRay + 1

       if(iRayIn>0)then
          ! If there are still local rays, exchange only occasionally
          CpuTimeNow = MPI_WTIME()

          if(CpuTimeNow - CpuTimeStartRay > DtExchangeRay)then
             ! This PE is not done yet, so pass .false.
             call ray_exchange(.false., DoneAll, IsNeighbor_P)
             CpuTimeStartRay = CpuTimeNow
          end if
       end if

    end do RAYS

    call ray_exchange(.true., DoneAll)

    GETRAYFINAL: do
       call ray_get(IsFound,iProcStart,iStart_D,XyzRay_D,RayLength,&
                    IsParallel,DoneRay, IsEnd=.true.)

       if(IsFound)then
          if(IsParallel)then
             iRay=1
          else
             iRay=2
          end if

          if(.not.DoTraceRay)then
             write(*,*)NameSub,' WARNING ',&
                       'received DoneRay=T for DoTraceRay = .false. !'
             CYCLE GETRAYFINAL
          end if

          ! Store the result into the ModFieldTrace::ray
          iStart      = iStart_D(1)
          jStart      = iStart_D(2)
          kStart      = iStart_D(3)
          iBlockStart = iStart_D(4)

          ray(:,iRay,iStart,jStart,kStart,iBlockStart)=XyzRay_D

          ! Get another ray from the others
          CYCLE GETRAYFINAL
       end if
       EXIT GETRAYFINAL
    end do GETRAYFINAL

    call test_stop(NameSub, DoTest)
  contains
    !==========================================================================

    subroutine follow_this_ray

      ! Initialize integrals for this segment
      !------------------------------------------------------------------------
      if(DoIntegrateRay)RayIntegral_V = 0.0

      ! Follow the ray through the local blocks
      BLOCK: do iCount = 1, MaxCount

         if(iCount < MaxCount)then
            call follow_ray_block(iStart_D, iRay, iBlockRay, XyzRay_D, &
                 RayLength,iFace)
         else
            write(*,*)NameSub,' WARNING ray passed through more than MaxCount=',&
                 MaxCount,' blocks:'
            write(*,*)NameSub,' iStart_D    =', iStart_D
            write(*,*)NameSub,' XyzRay_D    =', XyzRay_D
            write(*,*)NameSub,' CoordMin_DB =', CoordMin_DB(:,iBlockRay)
            iFace = ray_loop_
         end if

         select case(iFace)
         case(ray_block_)

            ! Find the new PE and block for the current position
            call find_grid_block(XyzRay_D, jProc, jBlock)

            if(jProc /= iProc)then
               ! Send ray to the next processor and return from here
               if(DoTestRay)write(*,*)'Sending ray iProc,jProc,iRay,Xyz=',&
                    iProc,jProc,iRay,XyzRay_D

               ! Add partial results to the integrals.
               ! Pass .false., because this is not the final position
               if(DoIntegrateRay)call store_integral(.false.)

               call ray_put(iProcStart,iStart_D,jProc,XyzRay_D,RayLength,&
                    iRay==1,.false.)
               RETURN
            elseif(jBlock /= iBlockRay)then
               ! Continue the same ray in the next block
               iBlockRay = jBlock
               if(DoTestRay)write(*,'(a,3i4,3es12.4)')&
                    'Continuing ray iProc,jBlock,iRay,Xyz=',&
                    iProc,jBlock,iRay,XyzRay_D
               CYCLE BLOCK
            else
               write(*,*)'ERROR for follow_this_ray, iProc=',iProc
               write(*,*)'ERROR iBlockRay==jBlock    =',iBlockRay,jBlock
               write(*,*)'ERROR iStart_D, iProcStart =',iStart_D, iProcStart
               write(*,*)'ERROR for XyzRay_D, r, iRay=',XyzRay_D, norm2(XyzRay_D), iRay
               write(*,*)'CoordMin_DB, CellSize_DB  =', &
                    CoordMin_DB(:,jBlock), CellSize_DB(:,jBlock)
               ! call stop_mpi(&
               !     'GM_ERROR in follow_ray: continues in same BLOCK')
            end if
         case(ray_open_)
            ! The ray reached the outer boundary (or expected to do so)
            XyzRay_D = OPENRAY
            if(DoTestRay)write(*,*)&
                 'follow_ray finished with OPENRAY, iProc,iRay=',iProc,iRay

         case(ray_loop_)
            ! The ray did not hit the wall of the block
            XyzRay_D = LOOPRAY
            if(DoTestRay)write(*,*)&
                 'follow_ray finished with LOOPRAY, iProc,iRay=',iProc,iRay

         case(ray_body_)
            ! The ray hit a body
            XyzRay_D = BODYRAY
            if(DoTestRay)write(*,*)&
                 'follow_ray finished with BODYRAY, iProc,iRay=',iProc,iRay

         case(ray_iono_)
            ! The ray hit the ionosphere
            if(DoTestRay)write(*,'(a,2i4,3es12.4)')&
                 'follow_this_ray finished on the ionosphere '// &
                 'at iProc,iRay,Xyz=',iProc,iRay,XyzRay_D

         case(ray_equator_)
            ! The ray hit the SM equatorial plane
            if(DoTestRay)write(*,'(a,2i4,3es12.4)')&
                 'follow_this_ray finished on the SM equator '// &
                 'at iProc,iRay,Xyz=',iProc,iRay,XyzRay_D

         case default
            write(*,*)'Impossible value for iface=',iFace,&
                 ' at XyzRay_D,iBlockRay=',XyzRay_D,iBlockRay
            call stop_mpi('GM_ERROR in follow_ray: impossible iFace value')
         end select

         ! Store integrals and the final position
         if(DoIntegrateRay)call store_integral(.true.)

         if(DoMapRay)then
            if(.not.allocated(RayMapLocal_DSII))then
               if(allocated(RayMap_DSII)) deallocate(RayMap_DSII)
               allocate(RayMap_DSII(3,nRay_D(1),nRay_D(2),nRay_D(3)))
               allocate(RayMapLocal_DSII(3,nRay_D(1),nRay_D(2),nRay_D(3)))
               RayMapLocal_DSII = 0.0
            end if
            RayMapLocal_DSII(:,iStart_D(1),iStart_D(2),iStart_D(3)) = XyzRay_D
         end if

         ! Nothing more to do if not tracing
         if(.not.DoTraceRay) EXIT BLOCK

         ! For tracing either store results or send them back to starting PE
         if(iProcStart == iProc)then

            ! Store the result into the ModFieldTrace::ray
            iStart      = iStart_D(1)
            jStart      = iStart_D(2)
            kStart      = iStart_D(3)
            iBlockStart = iStart_D(4)

            ray(:,iRay,iStart,jStart,kStart,iBlockStart)=XyzRay_D

            if(DoTestRay)write(*,*) &
                 'Storing into iProc,iBlock,i,j,k,iRay,Xyz=',&
                 iProc,iBlockStart,iStart,jStart,kStart,iRay,XyzRay_D

         else
            ! Send back result to iProcStart.
            call ray_put(iProcStart,iStart_D,iProc,XyzRay_D,RayLength,&
                 iRay==1,.true.)

            if(DoTestRay)write(*,*) &
                 'Send result iProc,iProcStart,iRay,Xyz=',&
                 iProc,iProcStart,iRay,XyzRay_D

         end if
         EXIT BLOCK

      end do BLOCK

    end subroutine follow_this_ray
    !==========================================================================

    subroutine store_integral(DoneRay)

      ! Store integrals of this ray into the

      logical, intent(in) :: DoneRay

      integer :: iLat, iLon

      !------------------------------------------------------------------------
      iLat = iStart_D(1)
      iLon = iStart_D(2)

      RayIntegral_VII(InvB_:nLocalIntegral,iLat,iLon) = &
           RayIntegral_VII(InvB_:nLocalIntegral,iLat,iLon) + RayIntegral_V

      if(DoneRay)then
         RayIntegral_VII(xEnd_:zEnd_,iLat,iLon) = XyzRay_D
         RayIntegral_VII(Length_,iLat,iLon)     = RayLength
      end if
    end subroutine store_integral
    !==========================================================================

    subroutine set_DoTestRay

      !------------------------------------------------------------------------
      if(DoIntegrateRay)then
         ! Test the ray starting from a given Lat-Lon grid point
         DoTestRay = DoTest .and. all(iStart_D(1:2) == [iLatTest,iLonTest])
      else if(DoTraceRay)then
         ! Test the ray starting from a given grid cell
         DoTestRay = DoTest .and. iProcStart == iProcTest .and. &
              all(iStart_D == [iTest,jTest,kTest,iBlockTest])
      else
         ! Check the ray indexed in line plot files.
         DoTestRay = DoTest .and. iStart_D(1) == iTest
      end if

    end subroutine set_DoTestRay
    !==========================================================================

  end subroutine follow_ray
  !============================================================================

  subroutine follow_ray_block(iStart_D,iRay,iBlock,XyzInOut_D,Length,iFace)

    !DESCRIPTION:
    ! Follow ray identified by index array iStart_D,
    ! starting at initial position XyzInOut_D inside block iBlock,
    ! in direction iRay until we hit the wall of the block or the ionosphere
    ! or the SM equatorial plane (if required).
    ! Return XyzInOut_D with the final position.
    ! Integrate and/or extract values if required.
    ! Also return Length increased by the length of the ray in this block.
    !
    ! Return iFace = 1..6 if the ray hit outer domain boundary
    ! Return ray_block_   if the ray hit the block boundary
    ! Return ray_iono_    if the ray hit the ionosphere
    ! Return ray_loop_    if the ray did not hit anything
    ! Return ray_body_    if the ray goes into or is inside a body
    ! Return ray_open_    if the ray goes outside the computational box
    ! EOP

    use ModNumConst, ONLY: cTiny
    use ModMain, ONLY: nI, nJ, nK
    use ModGeometry, ONLY: XyzStart_BLK, XyzMax_D, XyzMin_D, &
         rMin_BLK, x1,x2,y1,y2,z1,z2
    use CON_planet, ONLY: DipoleStrength
    use ModMultiFLuid
    use BATL_lib, ONLY: xyz_to_coord, Xyz_DGB, CellSize_DB

    ! Arguments

    integer, intent(in) :: iStart_D(4)
    integer, intent(in) :: iRay
    integer, intent(in) :: iBlock
    real, intent(inout) :: XyzInOut_D(3)
    real, intent(inout) :: Length
    integer, intent(out):: iFace

    ! Local variables

    ! Block size
    real :: Dxyz_D(3)

    ! initial/mid/current points of: IJK and XYZ coordinates
    real, dimension(3) :: &
         IjkIni_D, IjkMid_D, IjkCur_D, XyzIni_D, XyzMid_D, XyzCur_D

    ! General coordinates and reference Ijk
    real, dimension(3) :: Gen_D, Ijk_D

    ! Direction of B field, true interpolated field
    real, dimension(3) :: bNormIni_D, bNormMid_D, b_D

    ! Radial distance from origin and square
    real :: rCur, r2Cur, rIni

    ! dx is the difference between 1st and 2nd order RK to estimate accuracy
    ! dxOpt is the required accuracy, dxRel=dx/dxOpt
    real :: dxRel, dxOpt

    ! Ray step size, step length, next step size
    real :: dl, dlp, dLength, dlNext

    ! Fraction of the last step inside the ionosphere
    real :: Fraction

    ! Step size limits
    real :: dlMax, dlMin, dlTiny

    ! counter for ray integration
    integer :: nSegment
    integer :: nSegmentMax=10*(nI+nJ+nK)

    ! True if Rmin_BLK < rTrace
    logical :: DoCheckInnerBc

    ! True if the block already containes open rays
    logical :: DoCheckOpen

    ! Counter for entering follow_iono
    integer :: nIono

    ! Control volume limits in local coordinates
    real, dimension(3) :: xmin, xmax

    ! Cell indices corresponding to current or final Ijk position
    integer :: i1,j1,k1,i2,j2,k2

    ! Distance between Ijk and i1,j1,k1, and i2,j2,k2
    real :: dx1, dy1, dz1, dx2, dy2, dz2

    ! dl/B in physical units
    real :: InvBDl, RhoP_V(nExtraIntegral)

    ! Debugging
    logical :: okdebug=.false.

    logical :: IsWall

    character(len=*), parameter:: NameSub = 'follow_ray_block'
    !--------------------------------------------------------------------------
    if(DoTestRay)write(*,'(a,3i4,3es12.4)')&
         'Starting follow_ray_block: me,iBlock,iRay,XyzInOut_D=',&
         iProc,iBlock,iRay,XyzInOut_D

    ! Store local block deltas
    Dxyz_D  = CellSize_DB(:,iBlock)

    ! Convert initial position to block coordinates
    XyzCur_D = XyzInOut_D
    call xyz_to_ijk(XyzCur_D, IjkCur_D, iBlock, &
         XyzCur_D, XyzStart_BLK(:,iBlock), Dxyz_D)

    ! Set flag if checking on the ionosphere is necessary
    if(UseOldMethodOfRayTrace .and. IsCartesianGrid)then
       DoCheckInnerBc = Rmin_BLK(iBlock) < rTrace + sum(Dxyz_D)
    else
       DoCheckInnerBc = Rmin_BLK(iBlock) < 1.2*rTrace
    end if

    ! Set flag if checking for open rays is useful
    DoCheckOpen = .false.
    ! !! any(ray(1,iRay,1:nI,1:nJ,1:nK,iBlock)==OPENRAY)

    ! Set the boundaries of the control volume in block coordinates
    ! We go out to the first ghost cell centers for sake of speed and to avoid
    ! problems at the boundaries
    xmin = [0.0, 0.0, 0.0]
    xmax = [nI+1.0, nJ+1.0, nK+1.0]

    ! Go out to the block interface at the edges of the computational domain
    where(XyzStart_BLK(:,iBlock)+Dxyz_D*(xmax-1.0) > XyzMax_D)xmax = xmax - 0.5
    where(XyzStart_BLK(:,iBlock)+Dxyz_D*(xmin-1.0) < XyzMin_D)xmin = xmin + 0.5
    if(.not.IsCartesianGrid)then
       xmin(2)=0.0;  xmax(2)=nJ+1.0
       xmin(3)=0.0;  xmax(3)=nK+1.0
    end if

    ! Step size limits
    if(UseOldMethodOfRayTrace .and. IsCartesianGrid)then
       dlMax = 1.0
       dlMin = 0.05
       dlTiny= 1.e-6
    else
       dlMax = sum(abs(Xyz_DGB(:,nI,nJ,nK,iBlock)-Xyz_DGB(:,1,1,1,iBlock))) &
            /(nI + nJ + nK - 3)
       dlMin = dlMax*0.05
       dlTiny= dlMax*1.e-6
    end if

    ! Initial value
    dlNext=sign(dlMax,1.5-iRay)

    ! Accuracy in terms of a kind of normalized coordinates
    dxOpt = 0.01*dlMax

    ! Reference Ijk
    Ijk_D = [ nI/2, nJ/2, nK/2 ]

    ! Length and maximum length of ray within control volume
    nSegment = 0
    nIono    = 0

    IsWall=.false.

    ! Integration loop
    FOLLOW: do

       ! Integrate with 2nd order scheme
       dl    = dlNext
       IjkIni_D = IjkCur_D
       XyzIni_D = XyzCur_D

       ! Half step
       call interpolate_b(IjkIni_D, b_D, bNormIni_D)
       if(sum(bNormIni_D**2) < 0.5)then
          iFace = ray_loop_
          EXIT FOLLOW
       end if
       if(UseOldMethodOfRayTrace .and. IsCartesianGrid)then
          IjkMid_D = IjkIni_D + 0.5*dl*bNormIni_D
          XyzMid_D = XyzStart_BLK(:,iBlock) + Dxyz_D*(IjkMid_D - 1.)
       else
          HALF: do
             ! Try a half step in XYZ space (and get IJK from it)
             XyzMid_D = XyzIni_D + 0.5*dl*bNormIni_D
             call xyz_to_ijk(XyzMid_D, IjkMid_D, iBlock, &
                  XyzIni_D, XyzStart_BLK(:,iBlock), Dxyz_D)

             ! Check if it stepped too far, cut step if needed
             if(any(IjkMid_D<(xmin-0.5)) .or. any(IjkMid_D>(xmax+0.5)))then
                ! Step too far, reduce and try again
                dl = 0.5*dl

                if(abs(dl) < dlMin)then
                   ! Cannot reduce dl further
                   dl = 0.0
                   ! Obtain a point outside the block by mirroring the block
                   ! center Ijk_D to the starting location of this step IjkIni_D
                   IjkMid_D = 2*IjkIni_D - Ijk_D
                   ! Reduce length of Ijk_D --> IjkMid_D vector to end
                   ! something like a 10th of a cell outside the block
                   dlp = 1.1*(1.-maxval(max(xmin-IjkMid_D,IjkMid_D-xmax) &
                        /(abs(IjkMid_D-IjkIni_D)+dlTiny)))
                   IjkMid_D=IjkIni_D+dlp*(IjkMid_D-IjkIni_D)

                   ! Make sure that IjkMid_D is just outside the control volume
                   IjkMid_D=max(xmin-.1,IjkMid_D)
                   IjkMid_D=min(xmax+.1,IjkMid_D)
                   call interpolate_xyz(IjkMid_D,XyzMid_D)
                   call interpolate_b(IjkMid_D, b_D, bNormMid_D)
                   IjkCur_D=IjkMid_D; XyzCur_D=XyzMid_D

                   ! We exited the block and have a good location to continued from
                   IsWall=.true.
                   EXIT HALF
                end if
             else
                ! Step was OK, continue
                EXIT HALF
             end if
          end do HALF
       end if

       ! Extract ray values using around IjkIni_D
       if(DoExtractRay)call ray_extract(IjkIni_D,XyzIni_D)

       STEP: do
          if(IsWall)EXIT STEP

          ! Full step
          bNormMid_D = bNormIni_D ! In case interpolation would give zero vector
          call interpolate_b(IjkMid_D, b_D, bNormMid_D)

          ! Calculate the difference between 1st and 2nd order integration
          ! and take ratio relative to dxOpt
          dxRel = abs(dl) * maxval(abs(bNormMid_D-bNormIni_D)) / dxOpt

          if(DoTestRay.and.okdebug)&
               write(*,*)'me,iBlock,IjkMid_D,bNormMid_D,dxRel=', &
               iProc,iBlock,IjkMid_D,bNormMid_D,dxRel

          ! Make sure that dl does not change more than a factor of 2 or 0.5
          dxRel = max(0.5, min(2., dxRel))

          if(dxRel > 1.)then
             ! Not accurate enough, decrease dl if possible

             if(abs(dl) <= dlMin + dlTiny)then
                ! Cannot reduce dl further
                dlNext=dl
                EXIT STEP
             end if

             dl = sign(max(dlMin,abs(dl)/(dxRel+0.001)),dl)

             ! New mid point using the reduced dl
             if(UseOldMethodOfRayTrace .and. IsCartesianGrid)then
                IjkMid_D = IjkIni_D + 0.5*dl*bNormIni_D
                XyzMid_D = XyzStart_BLK(:,iBlock) + Dxyz_D*(IjkMid_D - 1.)
             else
                HALF2: do
                   ! Try new half step in XYZ space (and get IJK from it)
                   XyzMid_D = XyzIni_D + 0.5*dl*bNormIni_D
                   call xyz_to_ijk(XyzMid_D, IjkMid_D, iBlock, &
                        XyzIni_D, XyzStart_BLK(:,iBlock), Dxyz_D)

                   ! Check if it stepped too far, cut step if needed
                   if(any(IjkMid_D<(xmin-0.5)) .or. any(IjkMid_D>(xmax+0.5)))then
                      ! Step too far, reduce and try again
                      dl=0.5*dl

                      if(abs(dl) < dlMin)then
                         ! Cannot reduce dl further
                         dl = 0.
                         ! Obtain a point outside the block by mirroring block
                         ! center Ijk_D to starting location of step IjkIni_D
                         IjkMid_D=2.*IjkIni_D-Ijk_D

                         ! Reduce length of Ijk_D --> IjkMid_D vector to end
                         ! something like a 10th of a cell outside the block
                         dlp = 1.1*(1.-maxval(max(xmin-IjkMid_D,IjkMid_D-xmax) &
                              /(abs(IjkMid_D-IjkIni_D)+dlTiny)))
                         IjkMid_D=IjkIni_D+dlp*(IjkMid_D-IjkIni_D)

                         ! Make sure IjkMid_D is just outside the control volume
                         IjkMid_D = max(xmin-0.1, IjkMid_D)
                         IjkMid_D = min(xmax+0.1, IjkMid_D)
                         call interpolate_xyz(IjkMid_D, XyzMid_D)
                         call interpolate_b(IjkMid_D, b_D, bNormMid_D)
                         IjkCur_D=IjkMid_D; XyzCur_D=XyzMid_D

                         ! We exited block and have good location to continued
                         IsWall = .true.
                         EXIT HALF2
                      end if
                   else
                      ! Step was OK, continue
                      EXIT HALF2
                   end if
                end do HALF2
             end if

             if(DoTestRay.and.okdebug) write(*,*) &
                  'new decreased dl: me,iBlock,dl=',iProc,iBlock,dl
          else
             ! Too accurate, increase dl if possible
             if(abs(dl) < dlMax - dlTiny)then
                dlNext = sign(min(dlMax, abs(dl)/sqrt(dxRel)), dl)

                if(DoTestRay.and.okdebug) write(*,*) &
                     'new increased dlNext: me,iBlock,dlNext=', &
                     iProc, iBlock, dlNext
             end if
             EXIT STEP
          end if
       end do STEP

       ! Update position after the full step
       if(.not.IsWall)then
          if(UseOldMethodOfRayTrace .and. IsCartesianGrid)then
             IjkCur_D = IjkIni_D + bNormMid_D*dl
             XyzCur_D = XyzStart_BLK(:,iBlock) + Dxyz_D*(IjkCur_D - 1.)
          else
             XyzCur_D = XyzIni_D + dl*bNormMid_D
             call xyz_to_ijk(XyzCur_D, IjkCur_D, iBlock, &
                  XyzIni_D, XyzStart_BLK(:,iBlock), Dxyz_D)

             ! Check if it stepped too far, use midpoint if it did
             if(any(IjkCur_D < (xmin-0.5)) .or. any(IjkCur_D > (xmax+0.5)))then
                IjkCur_D=IjkMid_D; XyzCur_D=XyzMid_D
             end if
          end if
       end if  ! .not.IsWall

       ! Update number of segments
       nSegment = nSegment + 1

       ! Step size in MH units  !!! Use simpler formula for cubic cells ???
       if(UseOldMethodOfRayTrace .and. IsCartesianGrid)then
          dLength = abs(dl)*norm2(bNormMid_D*Dxyz_D)
       else
          dLength = norm2(XyzCur_D - XyzIni_D)
       end if

       ! Update ray length
       Length  = Length + dLength

       ! Check SM equator crossing for ray integral (GM -> RCM)
       ! or if we map to the equator (HEIDI/RAM-SCB -> GM)
       ! but don't check if we map equator to ionosphere (GM -> HEIDI/RAM-SCB)
       if(DoIntegrateRay .or. (DoMapEquatorRay .and. .not.DoMapRay))then
          ! Check if we crossed the z=0 plane in the SM coordinates
          ! Stop following ray if the function returns true
          if(do_stop_at_sm_equator()) EXIT FOLLOW
       end if

       if(DoIntegrateRay)then

          ! Interpolate density and pressure
          ! Use the last indexes and distances already set in interpolate_b
          RhoP_V = &
               +dx1*(dy1*(dz1*Extra_VGB(:,i2,j2,k2,iBlock)   &
               +          dz2*Extra_VGB(:,i2,j2,k1,iBlock))  &
               +     dy2*(dz1*Extra_VGB(:,i2,j1,k2,iBlock)   &
               +          dz2*Extra_VGB(:,i2,j1,k1,iBlock))) &
               +dx2*(dy1*(dz1*Extra_VGB(:,i1,j2,k2,iBlock)   &
               +          dz2*Extra_VGB(:,i1,j2,k1,iBlock))  &
               +     dy2*(dz1*Extra_VGB(:,i1,j1,k2,iBlock)   &
               +          dz2*Extra_VGB(:,i1,j1,k1,iBlock)))

          ! Calculate physical step size divided by physical field strength
          InvBDl = dLength / norm2(b_D)

          ! Intgrate field line volume = \int dl/B
          RayIntegral_V(InvB_) = RayIntegral_V(InvB_) + InvBDl

          ! Integrate density and pressure = \int Rho dl/B and \int P dl/B
          RayIntegral_V(RhoInvB_:nLocalIntegral) = &
               RayIntegral_V(RhoInvB_:nLocalIntegral) + InvBDl * RhoP_V

       end if

       if(DoTestRay.and.okdebug)&
            write(*,*)'me,iBlock,nSegment,IjkCur_D=', &
            iProc,iBlock,nSegment,IjkCur_D

       if(DoCheckOpen)then
          if(all(ray(1,iRay,i1:i2,j1:j2,k1:k2,iBlock)==OPENRAY))then
             nOpen=nOpen+1
             iFace = ray_open_
             EXIT FOLLOW
          end if
       end if

       ! Check if we got inside the ionosphere
       if(DoCheckInnerBc)then
          r2Cur = sum(XyzCur_D**2)

          if(r2Cur <= rTrace2)then

             ! If inside surface, then tracing is finished

             if(NameVectorField /= 'B' .or. r2Cur < rInner2)then
                XyzInOut_D = XyzCur_D
                iFace=ray_iono_
                EXIT FOLLOW
             end if

             ! Try mapping down to rIonosphere if we haven't tried yet (a lot)
             if(nIono<5)then
                if(.not.follow_iono())then
                   ! We did not hit the surface of the ionosphere
                   ! continue the integration
                   nIono=nIono+1
                else
                   if(DoTestRay)write(*,'(a,3i4,6es12.4)')&
                        'Inside rTrace at me,iBlock,nSegment,IjkCur_D,XyzCur_D=',&
                        iProc,iBlock,nSegment,IjkCur_D,XyzCur_D

                   rCur = sqrt(r2Cur)
                   rIni = norm2(XyzIni_D)

                   ! The fraction of the last step inside body is estimated from
                   ! the radii.
                   Fraction = (rTrace - rCur) / (rIni - rCur)

                   ! Reduce ray length
                   Length = Length - Fraction * dLength

                   ! Recalculate position
                   IjkCur_D = IjkCur_D - Fraction*(IjkCur_D-IjkIni_D)
                   call interpolate_xyz(IjkCur_D,XyzCur_D)

                   if(DoIntegrateRay)then
                      ! Reduce integrals with the fraction of the last step
                      if(DoTestRay)write(*,'(a,4es12.4)')&
                           'Before reduction InvBdl, RayIntegral_V=', InvBdl, &
                           RayIntegral_V(InvB_),RayIntegral_V(RhoInvB_:pInvB_)

                      ! Recalculate dLength/abs(B)
                      InvBDl = Fraction * InvBDl

                      ! Reduce field line volume
                      RayIntegral_V(InvB_) = RayIntegral_V(InvB_) - InvBDl

                      ! Reduce density and pressure integrals
                      RayIntegral_V(RhoInvB_:nLocalIntegral) = &
                           RayIntegral_V(RhoInvB_:nLocalIntegral) - InvBDl*RhoP_V

                      if(DoTestRay)then
                         write(*,'(a,4es12.4)')&
                              'After  reduction InvBdl, RayIntegral_V=',InvBdl, &
                              RayIntegral_V(InvB_),RayIntegral_V(RhoInvB_:pInvB_)

                         write(*,*)'Reduction at InvBDl,RhoP_V   =',InvBDl,RhoP_V
                         write(*,*)'Reduction rIni,rCur,rTrace =',&
                              rIni,rCur,rTrace
                      end if

                   end if

                   ! Exit integration loop (XyzInOut_D is set by follow_iono)
                   iFace=ray_iono_
                   EXIT FOLLOW
                end if
             end if
          end if
       end if

       ! Check if the ray hit the wall of the control volume
       if(any(IjkCur_D<xmin) .or. any(IjkCur_D>xmax))then
          ! Compute generalized coords without pole or edge wrapping
          call xyz_to_coord(XyzCur_D,Gen_D)

          if(any(Gen_D < XyzMin_D) .or. any(Gen_D > XyzMax_D))then
             iFace = ray_open_
          else
             iFace = ray_block_
          end if

          XyzInOut_D = XyzCur_D
          EXIT FOLLOW
       end if

       if(.not.IsCartesianGrid)then
          ! Can also hit wall if spherical before reaching xmin,xmax
          if(  XyzCur_D(1)<x1 .or. XyzCur_D(2)<y1 .or. XyzCur_D(3)<z1 .or. &
               XyzCur_D(1)>x2 .or. XyzCur_D(2)>y2 .or. XyzCur_D(3)>z2 )then

             XyzInOut_D = XyzCur_D
             iFace = ray_open_
             EXIT FOLLOW
          end if
       end if

       ! Check if we have integrated for too long
       if( nSegment > nSegmentMax .or. Length > RayLengthMax )then
          ! Seems to be a closed loop within a block
          if(DoTestRay) write(*,*)'CLOSED LOOP at me,iBlock,IjkCur_D,XyzCur_D=', &
               iProc,iBlock,IjkCur_D,XyzCur_D

          iFace=ray_loop_
          EXIT FOLLOW
       end if

    end do FOLLOW

    ! Extract last point if ray is done.
    if(iFace /= ray_block_ .and. DoExtractRay) &
         call ray_extract(IjkCur_D,XyzCur_D)

    if(DoTestRay) then
       write(*,'(a,4i4)')&
            'Finished follow_ray_block at me,iBlock,nSegment,iFace=',&
            iProc,iBlock,nSegment,iFace
       write(*,'(a,i4,9es12.4)')&
            'Finished follow_ray_block at me,IjkCur_D,XyzCur_D,XyzInOut_D=',&
            iProc,IjkCur_D,XyzCur_D,XyzInOut_D
    end if

  contains
    !==========================================================================
    logical function do_stop_at_sm_equator()

      ! Check if we crossed the Z=0 plane in the SM coord system
      ! Return true if there is no reason to follow the ray further

      ! SM coordinates
      real:: XyzSMIni_D(3), XyzSMCur_D(3), XySm_D(2)

      real:: Dz1, Dz2

      !------------------------------------------------------------------------
      do_stop_at_sm_equator = .false.

      ! Convert GM position into SM frame using the transposed GmSm_DD
      XyzSMIni_D = matmul(XyzIni_D, GmSm_DD)
      XyzSMCur_D = matmul(XyzCur_D, GmSm_DD)

      ! Check if we have crossed the magnetic equator in the SM frame
      if(XyzSMCur_D(3)*XyzSMIni_D(3) > 0) RETURN

      ! Crossing the magnetic equator in opposite direction is not accepted
      if(DipoleStrength*(iRay-1.5)<0)then
         if(XyzSMIni_D(3) <= 0 .and. XyzSMCur_D(3) >= 0)then
            iFace = ray_loop_
            do_stop_at_sm_equator = .true.
            RETURN
         end if
      else
         if(XyzSMIni_D(3) >= 0 .and. XyzSMCur_D(3) <= 0)then
            iFace = ray_loop_
            do_stop_at_sm_equator = .true.
            RETURN
         end if
      end if

      ! Interpolate x and y
      Dz1 = abs(XyzSMIni_D(3))/(abs(XyzSMCur_D(3)) + abs(XyzSMIni_D(3)))
      Dz2 = 1.0 - Dz1
      XySM_D = Dz2*XyzSMIni_D(1:2) + Dz1*XyzSMCur_D(1:2)

      if(DoIntegrateRay)then
         RayIntegral_V(Z0x_:Z0y_) = XySm_D

         ! Assign Z0b_ as the middle point value of the magnetic field
         RayIntegral_V(Z0b_) = norm2(b_D)
         if(DoTestRay)then
            write(*,'(a,3es12.4)') &
                 'Found z=0 crossing at XyzSMIni_D=',XyzSMIni_D
            write(*,'(a,3es12.4)') &
                 'Found z=0 crossing at XyzSMCur_D=',XyzSMCur_D
            write(*,'(a,3es12.4)')&
                 'RayIntegral_V(Z0x_:Z0b_)=',RayIntegral_V(Z0x_:Z0b_)
         end if
      elseif(DoMapEquatorRay)then
         ! Stop at the equator and store final SM coordinates
         XyzInOut_D(1:2) = XySM_D
         XyzInOut_D(3)   = 0.0
         iFace = ray_equator_
         do_stop_at_sm_equator = .true.
      end if

    end function do_stop_at_sm_equator
    !==========================================================================

    subroutine interpolate_b(IjkIn_D,b_D,bNorm_D)

      ! Interpolate the magnetic field at normalized location IjkIn_D
      ! and return the result in b_D.
      ! The direction of b_D (normalized to a unit vector) is returned
      ! in bNorm_D if the magnitude of b_D is not zero.

      real, intent(in) :: IjkIn_D(3)  ! location
      real, intent(out):: b_D(3)      ! interpolated magnetic field
      real, intent(out):: bNorm_D(3)  ! unit magnetic field vector

      !LOCAL VARIABLES:
      real :: Dir0_D(3)

      !------------------------------------------------------------------------

      ! Determine cell indices corresponding to location IjkIn_D
      i1=floor(IjkIn_D(1)); i2=i1+1
      j1=floor(IjkIn_D(2)); j2=j1+1
      k1=floor(IjkIn_D(3)); k2=k1+1

      ! Distance relative to the cell centers
      dx1 = IjkIn_D(1) - i1; dx2 = 1.0 - dx1
      dy1 = IjkIn_D(2) - j1; dy2 = 1.0 - dy1
      dz1 = IjkIn_D(3) - k1; dz2 = 1.0 - dz1

      ! Interpolate the magnetic field
      b_D = dx1*(dy1*(dz1*Bxyz_DGB(:,i2,j2,k2,iBlock)+dz2*Bxyz_DGB(:,i2,j2,k1,iBlock)) &
           +     dy2*(dz1*Bxyz_DGB(:,i2,j1,k2,iBlock)+dz2*Bxyz_DGB(:,i2,j1,k1,iBlock))) &
           +dx2*(dy1*(dz1*Bxyz_DGB(:,i1,j2,k2,iBlock)+dz2*Bxyz_DGB(:,i1,j2,k1,iBlock))  &
           +     dy2*(dz1*Bxyz_DGB(:,i1,j1,k2,iBlock)+dz2*Bxyz_DGB(:,i1,j1,k1,iBlock)))

      ! Set bNorm_D as a unit vector. It will be zero if b_D is zero.
      if(.not.(UseOldMethodOfRayTrace .and. IsCartesianGrid))then
         bNorm_D = b_D/max(1e-30, norm2(b_D))
      else
         ! Stretch according to normalized coordinates
         Dir0_D = b_D/Dxyz_D
         bNorm_D = Dir0_D/max(1e-30, norm2(Dir0_D))
      end if

    end subroutine interpolate_b
    !==========================================================================

    subroutine interpolate_xyz(IjkIn_D,XyzOut_D)

      ! !! We should use share/Library/src/ModInterpolate !!!

      ! Interpolate X/Y/Z at normalized location IjkIn_D
      ! and return the result in XyzOut_D.

      real, intent(in)   :: IjkIn_D(3)  ! Ijk location
      real, intent(out)  :: XyzOut_D(3) ! Xyz location

      ! Determine cell indices corresponding to location IjkIn_D

      !------------------------------------------------------------------------
      i1=floor(IjkIn_D(1)); i2=i1+1
      j1=floor(IjkIn_D(2)); j2=j1+1
      k1=floor(IjkIn_D(3)); k2=k1+1

      ! Distance relative to the cell centers
      dx1 = IjkIn_D(1) - i1; dx2 = 1.0 - dx1
      dy1 = IjkIn_D(2) - j1; dy2 = 1.0 - dy1
      dz1 = IjkIn_D(3) - k1; dz2 = 1.0 - dz1

      ! Interpolate the magnetic field
      XyzOut_D(1) = &
           +dx1*(dy1*(dz1*Xyz_DGB(x_,i2,j2,k2,iBlock)+dz2*Xyz_DGB(x_,i2,j2,k1,iBlock))  &
           +     dy2*(dz1*Xyz_DGB(x_,i2,j1,k2,iBlock)+dz2*Xyz_DGB(x_,i2,j1,k1,iBlock))) &
           +dx2*(dy1*(dz1*Xyz_DGB(x_,i1,j2,k2,iBlock)+dz2*Xyz_DGB(x_,i1,j2,k1,iBlock))  &
           +     dy2*(dz1*Xyz_DGB(x_,i1,j1,k2,iBlock)+dz2*Xyz_DGB(x_,i1,j1,k1,iBlock)))
      XyzOut_D(2) = &
           +dx1*(dy1*(dz1*Xyz_DGB(y_,i2,j2,k2,iBlock)+dz2*Xyz_DGB(y_,i2,j2,k1,iBlock))  &
           +     dy2*(dz1*Xyz_DGB(y_,i2,j1,k2,iBlock)+dz2*Xyz_DGB(y_,i2,j1,k1,iBlock))) &
           +dx2*(dy1*(dz1*Xyz_DGB(y_,i1,j2,k2,iBlock)+dz2*Xyz_DGB(y_,i1,j2,k1,iBlock))  &
           +     dy2*(dz1*Xyz_DGB(y_,i1,j1,k2,iBlock)+dz2*Xyz_DGB(y_,i1,j1,k1,iBlock)))
      XyzOut_D(3) = &
           +dx1*(dy1*(dz1*Xyz_DGB(z_,i2,j2,k2,iBlock)+dz2*Xyz_DGB(z_,i2,j2,k1,iBlock))  &
           +     dy2*(dz1*Xyz_DGB(z_,i2,j1,k2,iBlock)+dz2*Xyz_DGB(z_,i2,j1,k1,iBlock))) &
           +dx2*(dy1*(dz1*Xyz_DGB(z_,i1,j2,k2,iBlock)+dz2*Xyz_DGB(z_,i1,j2,k1,iBlock))  &
           +     dy2*(dz1*Xyz_DGB(z_,i1,j1,k2,iBlock)+dz2*Xyz_DGB(z_,i1,j1,k1,iBlock)))

    end subroutine interpolate_xyz
    !==========================================================================

    logical function follow_iono()

      ! Follow ray inside ionosphere starting from XyzCur_D which is given in
      ! real coordinates and use analytic mapping.
      ! On return XyzInOut_D contains the final coordinates.
      ! Return true if it was successfully integrated down to rIonosphere,
      ! return false if the ray exited rTrace or too many integration
      ! steps were done

      use CON_planet_field, ONLY: map_planet_field
      use CON_planet,       ONLY: get_planet
      use ModMain, ONLY: Time_Simulation

      integer :: iHemisphere
      real    :: x_D(3), DipoleStrength=0.0

      !------------------------------------------------------------------------
      if(DipoleStrength==0)call get_planet(DipoleStrengthOut=DipoleStrength)

      call map_planet_field(Time_Simulation, XyzCur_D, TypeCoordSystem//' NORM',&
           rIonosphere, x_D, iHemisphere)

      if(iHemisphere==0)then
         write(*,*)'iHemisphere==0 for XyzCur_D=',XyzCur_D
         write(*,*)'iBlock, iRay=',iBlock,iRay
         call stop_mpi('ERROR in follow_iono')
      end if

      if(iHemisphere*DipoleStrength*sign(1.0,1.5-iRay) < 0.0)then
         XyzInOut_D = x_D
         follow_iono = .true.
      else
         follow_iono = .false.
      end if

    end function follow_iono
    !==========================================================================

    subroutine ray_extract(x_D,Xyz_D)

      use CON_line_extract, ONLY: line_put
      use ModPhysics, ONLY: No2Si_V, UnitX_, UnitB_, UnitElectric_, iUnitPrim_V
      use ModAdvance, ONLY: State_VGB, nVar, Bx_, Bz_, Efield_DGB
      use ModElectricField, ONLY: Epot_DGB
      use ModMain, ONLY: UseB0
      use ModB0,   ONLY: get_b0
      use ModInterpolate, ONLY: trilinear

      real, intent(in) :: x_D(3)   ! normalized coordinates
      real, intent(in) :: Xyz_D(3) ! Cartesian coordinates

      real    :: State_V(nVar), B0_D(3), PlotVar_V(4+nVar+10)
      integer :: n, iLine

      !------------------------------------------------------------------------
      PlotVar_V(1)   = Length
      PlotVar_V(2:4) = Xyz_D

      if(DoExtractUnitSi) PlotVar_V(1:4) = PlotVar_V(1:4)*No2Si_V(UnitX_)

      if(DoExtractState)then

         ! Determine cell indices corresponding to location x_D
         i1=floor(x_D(1)); i2=i1+1
         j1=floor(x_D(2)); j2=j1+1
         k1=floor(x_D(3)); k2=k1+1

         ! Distance relative to the cell centers
         dx1 = x_D(1) - i1; dx2 = 1.0 - dx1
         dy1 = x_D(2) - j1; dy2 = 1.0 - dy1
         dz1 = x_D(3) - k1; dz2 = 1.0 - dz1

         ! Interpolate state to x_D
         State_V = &
              +dx1*(dy1*(dz1*State_VGB(:,i2,j2,k2,iBlock)   &
              +          dz2*State_VGB(:,i2,j2,k1,iBlock))  &
              +     dy2*(dz1*State_VGB(:,i2,j1,k2,iBlock)   &
              +          dz2*State_VGB(:,i2,j1,k1,iBlock))) &
              +dx2*(dy1*(dz1*State_VGB(:,i1,j2,k2,iBlock)   &
              +          dz2*State_VGB(:,i1,j2,k1,iBlock))  &
              +     dy2*(dz1*State_VGB(:,i1,j1,k2,iBlock)   &
              +          dz2*State_VGB(:,i1,j1,k1,iBlock)))

         ! Convert momentum to velocity
         State_V(iUx_I) = State_V(iRhoUx_I)/State_V(iRho_I)
         State_V(iUy_I) = State_V(iRhoUy_I)/State_V(iRho_I)
         State_V(iUz_I) = State_V(iRhoUz_I)/State_V(iRho_I)

         ! Add B0 to the magnetic field
         if(UseB0)then
            call get_b0(Xyz_D, B0_D)
            State_V(Bx_:Bz_) = State_V(Bx_:Bz_) + B0_D
         end if

         ! Convert to SI units if required
         if(DoExtractUnitSi) State_V = State_V*No2Si_V(iUnitPrim_V)

         PlotVar_V(5:4+nVar) = State_V

         n = 4 + nVar

         if(DoExtractCurvatureB)then

            n = n + 1

            ! Interpolate curvature of the magnetic field
            PlotVar_V(n) = &
                 trilinear(CurvatureB_GB(:,:,:,iBlock), &
                 0, nI+1, 0, nJ+1, 0, nK+1, x_D, DoExtrapolate=.false.)

            if(DoExtractUnitSi) PlotVar_V(n) = &
                 PlotVar_V(n) * No2Si_V(UnitX_)

         end if

         if(DoExtractBGradB1)then

            n = n + 3

            ! Interpolate b.grad B1 into the next 3 elements
            PlotVar_V(n-2:n) = &
                 trilinear(bGradB1_DGB(:,:,:,:,iBlock), &
                 3, 0, nI+1, 0, nJ+1, 0, nK+1, x_D, DoExtrapolate=.false.)

            if(DoExtractUnitSi) PlotVar_V(n-2:n) = &
                 PlotVar_V(n-2:n) * No2Si_V(UnitB_)/No2Si_V(UnitX_)

         end if

         if(DoExtractEfield)then

            n = n + 3
            ! Interpolate Efield into next 3 elements
            PlotVar_V(n-2:n) = &
                 trilinear(Efield_DGB(:,:,:,:,iBlock), &
                 3, MinI, MaxI, MinJ, MaxJ, MinK, MaxK, x_D, &
                 DoExtrapolate=.false.)

            n = n + 3
            ! Interpolate Epot into next 3 elements
            PlotVar_V(n-2:n) = &
                 trilinear(Epot_DGB(:,:,:,:,iBlock), &
                 3, MinI, MaxI, MinJ, MaxJ, MinK, MaxK, x_D, &
                 DoExtrapolate=.false.)

            if(DoExtractUnitSi) PlotVar_V(n-5:n) = &
                 PlotVar_V(n-5:n) * No2Si_V(UnitElectric_)

         end if
      else
         n = 4
      end if

      ! get a unique line index based on starting indexes
      ! ignore index 4 if nRay_D(4) is zero
      iLine = &
           ((max(0, min(nRay_D(4), iStart_D(4)-1))*nRay_D(3) &
           + max(0,iStart_D(3)-1) )*nRay_D(2) &
           + max(0,iStart_D(2)-1) )*nRay_D(1) &
           + iStart_D(1)

      if(iLine < 0)then
         write(*,*)'iLine=',iLine
         write(*,*)'nRay_D  =',nRay_D
         write(*,*)'iStart_D=',iStart_D
         call stop_mpi('DEBUG')
      end if
      call line_put(iLine,n,PlotVar_V(1:n))

    end subroutine ray_extract
    !==========================================================================

  end subroutine follow_ray_block
  !============================================================================

  subroutine ray_trace_sorted

    ! This subroutine is an experiment to sort blocks and cells such that
    ! open field lines can be found very fast.
    ! It works well for simple problems,
    ! but it does not seem to improve the performance for realistic grids

    use ModMain, ONLY: MaxBlock, nBlock, nI, nJ, nK, Unused_B
    use ModPhysics, ONLY: SW_Bx, SW_By, SW_Bz
    use ModGeometry, ONLY: XyzMin_D, XyzMax_D, XyzStart_BLK
    use ModSort, ONLY: sort_quick
    use ModMpi, ONLY: MPI_WTIME

    integer :: iStart, iEnd, iStride, jStart, jEnd, jStride, &
         kStart, kEnd, kStride

    real    :: Weight_D(3)                 ! weights for the directions
    real    :: SortFunc_B(MaxBlock)        ! sorting function
    integer :: iBlockSorted_B(MaxBlock)    ! sorted block inxdexes

    ! index order for sorted blocks
    integer :: iSort, iSortStart, iSortEnd, iSortStride

    ! Indices corresponding to the starting point and directon of the ray
    integer :: i, j, k, iBlock, iRay

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'ray_trace_sorted'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)

    ! Sort blocks according to the direction of the solar wind magnetic field
    ! so that open rays are found fast from already calculated ray values.

    ! Weight X, Y and Z according to the SW_Bx, SW_By, SW_Bz components
    ! The Y and Z directions are preferred to X (usually SW_Bx=0 anyways).
    Weight_D(1) = sign(1.0,SW_Bx)
    ! Select Y or Z direction to be the slowest changing value
    ! to maximize overlap
    if(abs(SW_By) > abs(SW_Bz))then
       Weight_D(2) = sign(100.0,SW_By)
       Weight_D(3) = sign( 10.0,SW_Bz)
    else
       Weight_D(2) = sign( 10.0,SW_By)
       Weight_D(3) = sign(100.0,SW_Bz)
    end if

    do iBlock=1,nBlock
       if(Unused_B(iBlock))then
          SortFunc_B(iBlock) = -10000.0
       else
          SortFunc_B(iBlock) = sum(Weight_D*&
               (XyzStart_BLK(:,iBlock) - XyzMin_D)/(XyzMax_D - XyzMin_D))
       end if
    end do

    call sort_quick(nBlock,SortFunc_B,iBlockSorted_B)

    ! Assign face ray values to cell centers

    ! nOpen = 0
    CpuTimeStartRay = MPI_WTIME()
    do iRay=1,2

       if(iRay==1)then
          iSortStart=nBlock; iSortEnd=1; iSortStride=-1
       else
          iSortStart=1; iSortEnd=nBlock; iSortStride=1
       end if

       if(iRay==1 .eqv. SW_Bx >= 0.0)then
          iStart = nI; iEnd=1; iStride=-1
       else
          iStart = 1; iEnd=nK; iStride= 1
       end if

       if(iRay==1 .eqv. SW_By >= 0.0)then
          jStart = nJ; jEnd=1; jStride=-1
       else
          jStart = 1; jEnd=nJ; jStride= 1
       end if

       if(iRay==1 .eqv. SW_Bz >= 0.0)then
          kStart = nK; kEnd=1; kStride=-1
       else
          kStart = 1; kEnd=nK; kStride= 1
       end if

       do iSort = iSortStart, iSortEnd, iSortStride
          iBlock = iBlockSorted_B(iSort)

          do k = kStart, kEnd, kStride
             do j = jStart, jEnd, jStride
                do i = iStart, iEnd, iStride

                end do
             end do
          end do
       end do

    end do

    call test_stop(NameSub, DoTest)
  end subroutine ray_trace_sorted
  !============================================================================

  subroutine integrate_field_from_sphere(&
       nLat, nLon, Lat_I, Lon_I, Radius, NameVar)

    use CON_ray_trace, ONLY: ray_init
    use CON_planet_field, ONLY: map_planet_field
    use CON_axes, ONLY: transform_matrix
    use ModMain,    ONLY: nBlock, Unused_B, Time_Simulation, UseB0
    use ModAdvance, ONLY: nVar, State_VGB, Bx_, Bz_, UseMultiSpecies, nSpecies
    use ModB0,      ONLY: B0_DGB
    use ModMpi
    use BATL_lib,          ONLY: message_pass_cell, find_grid_block
    use ModNumConst,       ONLY: cDegToRad, cTiny
    use ModCoordTransform, ONLY: sph_to_xyz
    use CON_line_extract,  ONLY: line_init, line_collect, line_clean
    use CON_planet,        ONLY: DipoleStrength
    use ModMultiFluid
    use ModMessagePass,    ONLY: exchange_messages

    !INPUT ARGUMENTS:
    integer, intent(in):: nLat, nLon
    real,    intent(in):: Lat_I(nLat), Lon_I(nLon), Radius
    character(len=*), intent(in):: NameVar

    !DESCRIPTION:
    ! Lat_I(nLat) and Lon_I(nLon) are the coordinates of a 2D spherical
    ! grid in the SM(G) coordinate system in degrees. The 2D grid is
    ! at radius Radius given in units of planet radii.
    ! NameVar lists the variables that need to be extracted and/or integrated.
    ! The subroutine can calculate the integral of various quantities
    ! and/or extract state variables along the field lines starting from the 2D
    ! spherical grid.

    real    :: Theta, Phi, Lat, Lon, XyzIono_D(3), Xyz_D(3)
    integer :: iBlock, iFluid, iLat, iLon, iHemisphere, iRay
    integer :: iProcFound, iBlockFound, i, j, k
    integer :: nStateVar
    integer :: iError

    ! Variables for multispecies coupling
    real, allocatable :: NumDens_I(:)

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'integrate_field_from_sphere'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)

    if(DoTest)write(*,*)NameSub,' starting on iProc=',iProc,&
         ' with nLat, nLon, Radius=',nLat,nLon,Radius

    iLatTest = 49; iLonTest = 1

    call timing_start(NameSub)

    DoTestRay = .false.

    ! Initialize some basic variables
    DoIntegrateRay = index(NameVar, 'InvB') > 0 .or. index(NameVar, 'Z0') > 0
    DoExtractRay   = index(NameVar, '_I') > 0
    DoTraceRay     = .false.
    DoMapRay       = .false.

    if(DoTest)write(*,*)NameSub,' DoIntegrateRay,DoExtractRay,DoTraceRay=',&
         DoIntegrateRay,DoExtractRay,DoTraceRay

    if(DoExtractRay)then
       nRay_D  = [ nLat, nLon, 0, 0 ]
       DoExtractState = .true.
       DoExtractUnitSi= .true.
       nStateVar = 4 + nVar
       call line_init(nStateVar)
    end if

    NameVectorField = 'B'

    ! (Re)initialize CON_ray_trace
    call ray_init(iComm)

    ! Fill in all ghost cells without monotone restrict
    call message_pass_cell(nVar, State_VGB, nProlongOrderIn=1)

    ! Copy magnetic field into Bxyz_DGB
    do iBlock = 1, nBlock; if(Unused_B(iBlock))CYCLE
       Bxyz_DGB(:,:,:,:,iBlock) = State_VGB(Bx_:Bz_,:,:,:,iBlock)
       ! Add B0
       if(UseB0) Bxyz_DGB(:,:,:,:,iBlock) = &
            Bxyz_DGB(:,:,:,:,iBlock) + B0_DGB(:,:,:,:,iBlock)
    end do

    if(DoIntegrateRay)then
       if(UseMultiSpecies) allocate(NumDens_I(nSpecies))
       ! Copy density and pressure into Extra_VGB
       do iBlock = 1, nBlock
          if(Unused_B(iBlock)) CYCLE
          do k = MinK,MaxK; do j=MinJ,MaxJ; do i=MinI,MaxI
             if(UseMultiSpecies)then
                ! Set the densities
                Extra_VGB(1:3:2,i,j,k,iBlock) = &
                     State_VGB(SpeciesFirst_:SpeciesFirst_+1,i,j,k,iBlock)
                ! Calculate number densities for all species
                NumDens_I = State_VGB(SpeciesFirst_:SpeciesLast_,i,j,k,iBlock)&
                     /MassSpecies_V
                ! Calculte fraction relative to the total number density
                NumDens_I = NumDens_I/sum(NumDens_I)
                ! Store the pressures of the 1st and 2nd species
                Extra_VGB(2:4:2,i,j,k,iBlock) = &
                     State_VGB(p_,i,j,k,iBlock)*NumDens_I(1:2)
             else
                do iFluid = 1, min(2,nIonFluid)
                   Extra_VGB(2*iFluid-1,i,j,k,iBlock) = &
                        State_VGB(iRhoIon_I(iFluid),i,j,k,iBlock)
                   Extra_VGB(2*iFluid  ,i,j,k,iBlock) = &
                        State_VGB(iPIon_I(iFluid),i,j,k,iBlock)
                end do
             end if
          end do; end do; end do
       end do
       if(UseMultiSpecies) deallocate(NumDens_I)

       allocate(&
            RayIntegral_VII(nRayIntegral,nLat,nLon), &
            RayResult_VII(nRayIntegral,nLat,nLon))
       RayIntegral_VII = 0.0
       RayResult_VII   = 0.0

    end if

    ! Transformation matrix between the SM and GM coordinates
    GmSm_DD = transform_matrix(time_simulation,'SMG',TypeCoordSystem)

    ! Integrate rays starting from the latitude-longitude pairs defined
    ! by the arrays Lat_I, Lon_I
    CpuTimeStartRay = MPI_WTIME()
    do iLat = 1, nLat

       Lat = Lat_I(iLat)
       Theta = cDegToRad*(90.0 - Lat)

       do iLon = 1, nLon

          Lon = Lon_I(iLon)
          Phi = cDegToRad*Lon

          ! Convert to SMG Cartesian coordinates on the surface of the ionosphere
          call sph_to_xyz(Radius, Theta, Phi, XyzIono_D)

          ! Map from the ionosphere to rBody
          call map_planet_field(time_simulation, XyzIono_D, 'SMG NORM', &
               rBody+cTiny, Xyz_D, iHemisphere)

          ! Figure out direction of tracing outward
          if(iHemisphere*DipoleStrength>0)then
             iRay = 1
          else
             iRay = 2
          end if

          ! Check if the mapping is on the north hemisphere
          if(iHemisphere == 0)then
             !  write(*,*)NameSub,' point did not map to rBody, ',&
             !   'implement analytic integrals here! Lat, Lon=', Lat, Lon
             CYCLE
          end if

          ! Convert SM position to GM (Note: these are identical for ideal axes)
          if(UseSmg) Xyz_D = matmul(GmSm_DD,Xyz_D)

          ! Find processor and block for the location
          call find_grid_block(Xyz_D,iProcFound,iBlockFound)

          ! If location is on this PE, follow and integrate ray
          if(iProc == iProcFound)then

             if(DoTest .and. iLat==iLatTest .and. iLon==iLonTest)then
                write(*,'(a,2i3,a,i3,a,i4)') &
                     'start of ray iLat, iLon=',iLat, iLon,&
                     ' found on iProc=',iProc,' iBlock=',iBlockFound
                write(*,'(a,2i4,2es12.4)')'iLon, iLat, Lon, Lat=',&
                     iLon, iLat, Lon, Lat
                write(*,'(a,3es12.4)')'XyzIono_D=',XyzIono_D
                write(*,'(a,3es12.4)')'Xyz_D    =',Xyz_D
             end if

             call follow_ray(iRay, [iLat, iLon, 0, iBlockFound], Xyz_D)

          end if
       end do
    end do

    ! Do remaining rays obtained from other PE-s
    call finish_ray

    if(DoTest .and. DoIntegrateRay .and. iLatTest<=nLat .and. iLonTest<=nLon) &
         write(*,*)NameSub,' iProc, RayIntegral_VII=',&
         iProc, RayIntegral_VII(:,iLatTest,iLonTest)

    if(DoIntegrateRay) call MPI_reduce( &
         RayIntegral_VII, RayResult_VII, nLat*nLon*nRayIntegral, &
         MPI_REAL, MPI_SUM, 0, iComm, iError)

    if(DoExtractRay)then
       call line_collect(iComm,0)
       if(iProc /= 0) call line_clean
    end if

    call exchange_messages

    call timing_stop(NameSub)

    call test_stop(NameSub, DoTest)
  end subroutine integrate_field_from_sphere
  !============================================================================

  subroutine integrate_field_from_points(nPts, XyzPt_DI, NameVar)

    use CON_ray_trace,     ONLY: ray_init
    use CON_axes,          ONLY: transform_matrix
    use CON_line_extract,  ONLY: line_init, line_collect, line_clean
    use ModMain,           ONLY: nBlock, Time_Simulation, UseB0, Unused_B
    use ModAdvance,        ONLY: nVar, State_VGB, Bx_, Bz_, &
         UseMultiSpecies, nSpecies
    use ModB0,             ONLY: B0_DGB
    use ModMpi
    use ModMultiFluid
    use BATL_lib,          ONLY: find_grid_block

    !INPUT ARGUMENTS:
    integer, intent(in):: nPts
    real,    intent(in):: XyzPt_DI(3,nPts)
    character(len=*), intent(in):: NameVar

    !DESCRIPTION:
    ! A 1D list of points is sent in with x,y,z values in GM coordinates.
    ! NameVar lists the variables that need to be extracted and/or integrated.
    ! The subroutine can calculate the integral of various quantities
    ! and/or extract state variables along the field lines starting from the
    ! points sent in.

    real    :: Xyz_D(3)
    integer :: iPt
    integer :: iProcFound, iBlockFound, i, j, k, iBlock, iFluid
    integer :: nStateVar
    integer :: iError

    ! Variables for multispecies coupling
    real, allocatable :: NumDens_I(:)

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'integrate_field_from_points'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)

    if(DoTest)write(*,*)NameSub,' starting on iProc=',iProc,' with nPts=',nPts

    call timing_start('integrate_ray_1d')

    DoTestRay = .false.

    ! Initialize some basic variables
    DoIntegrateRay = index(NameVar, 'InvB') > 0 .or. index(NameVar, 'Z0') > 0
    DoExtractRay   = index(NameVar, '_I') > 0
    DoTraceRay     = .false.
    DoMapRay       = .false.

    if(DoTest)write(*,*)NameSub,' DoIntegrateRay,DoExtractRay,DoTraceRay=',&
         DoIntegrateRay,DoExtractRay,DoTraceRay

    if(DoExtractRay)then
       nRay_D  = [ 2, nPts, 0, 0 ]
       DoExtractState = .true.
       DoExtractUnitSi= .true.
       nStateVar = 4 + nVar
       call line_init(nStateVar)
    end if

    NameVectorField = 'B'

    ! (Re)initialize CON_ray_trace
    call ray_init(iComm)

    do iBlock = 1, nBlock; if(Unused_B(iBlock))CYCLE
       Bxyz_DGB(:,:,:,:,iBlock) = State_VGB(Bx_:Bz_,:,:,:,iBlock)
       ! Add B0
       if(UseB0) Bxyz_DGB(:,:,:,:,iBlock) = &
            Bxyz_DGB(:,:,:,:,iBlock) + B0_DGB(:,:,:,:,iBlock)
    end do

    if(DoIntegrateRay)then
       if(UseMultiSpecies) allocate(NumDens_I(nSpecies))
       ! Copy density and pressure into Extra_VGB
       do iBlock = 1, nBlock
          if(Unused_B(iBlock)) CYCLE
          do k = MinK,MaxK; do j=MinJ,MaxJ; do i=MinI,MaxI
             if(UseMultiSpecies)then
                ! Set the densities
                Extra_VGB(1:3:2,i,j,k,iBlock) = &
                     State_VGB(SpeciesFirst_:SpeciesFirst_+1,i,j,k,iBlock)
                ! Calculate number densities for all species
                NumDens_I = State_VGB(SpeciesFirst_:SpeciesLast_,i,j,k,iBlock) &
                     /MassSpecies_V
                ! Calculte fraction relative to the total number density
                NumDens_I = NumDens_I/sum(NumDens_I)
                ! Store the pressures of the 1st and 2nd species
                Extra_VGB(2:4:2,i,j,k,iBlock) = &
                     State_VGB(p_,i,j,k,iBlock)*NumDens_I(1:2)
             else
                do iFluid = 1, min(2,nIonFluid)
                   Extra_VGB(2*iFluid-1,i,j,k,iBlock) = &
                        State_VGB(iRho_I(iFluid),i,j,k,iBlock)
                   Extra_VGB(2*iFluid  ,i,j,k,iBlock) = &
                        State_VGB(iP_I(iFluid), i,j,k,iBlock)
                end do
             end if
          end do; end do; end do
       end do
       if(UseMultiSpecies) deallocate(NumDens_I)

       allocate(&
            RayIntegral_VII(nRayIntegral,nRay_D(1),nRay_D(2)), &
            RayResult_VII(nRayIntegral,nRay_D(1),nRay_D(2)))
       RayIntegral_VII = 0.0
       RayResult_VII   = 0.0

    end if

    ! Transformation matrix between the SM and GM coordinates
    if(UseSmg) GmSm_DD = transform_matrix(time_simulation,'SMG',TypeCoordSystem)

    ! Integrate rays
    CpuTimeStartRay = MPI_WTIME()
    do iPt = 1, nPts
       Xyz_D=XyzPt_DI(:,iPt)

       ! Find processor and block for the location
       call find_grid_block(Xyz_D,iProcFound,iBlockFound)

       ! If location is on this PE, follow and integrate ray
       if(iProc == iProcFound)then
          call follow_ray(1, [1, iPt, 0, iBlockFound], Xyz_D)
          call follow_ray(2, [2, iPt, 0, iBlockFound], Xyz_D)
       end if
    end do

    ! Do remaining rays obtained from other PE-s
    call finish_ray

    if(DoIntegrateRay) call MPI_reduce( RayIntegral_VII, RayResult_VII, &
         size(RayIntegral_VII), MPI_REAL, MPI_SUM, 0, iComm, iError)

    if(DoExtractRay)then
       call line_collect(iComm,0)
       if(iProc /= 0) call line_clean
    end if

    call timing_stop('integrate_ray_1d')

    call test_stop(NameSub, DoTest)
  end subroutine integrate_field_from_points
  !============================================================================

  subroutine write_plot_equator(iFile)

    use ModMain, ONLY: n_step, time_accurate, Time_Simulation, NamePrimitive_V
    use ModIo, ONLY: &
         StringDateOrTime, NamePlotDir, plot_range, plot_type, TypeFile_I
    use ModAdvance,        ONLY: nVar, Ux_, Uz_, Bx_, Bz_
    use ModIoUnit,         ONLY: UnitTmp_
    use ModPlotFile,       ONLY: save_plot_file
    use CON_line_extract,  ONLY: line_get, line_clean
    use CON_axes,          ONLY: transform_matrix
    use ModNumConst,       ONLY: cDegToRad
    use ModInterpolate,    ONLY: fit_parabola
    use ModUtilities,      ONLY: open_file, close_file

    !INPUT ARGUMENTS:
    integer, intent(in):: iFile

    !DESCRIPTION:
    ! Follow field lines starting from a 2D polar grid on the
    ! magnetic equatorial plane in the SM(G) coordinate system.
    ! The grid parameters are given by plot_rang(1:4, iFile)
    ! The subroutine extracts coordinates and state variables
    ! along the field lines going in both directions
    ! starting from the 2D polar grid.

    integer :: nRadius, nLon
    real    :: rMin, rMax, LonMin, LonMax
    integer :: iR, iLon
    integer :: iPoint, nPoint, nVarOut, nVarPlot, iVar
    real, allocatable:: Radius_I(:),Longitude_I(:),PlotVar_VI(:,:),PlotVar_V(:)
    real    :: SmGm_DD(3,3)

    ! Number of points along the Up and Down halves of the field line
    integer:: nPointDn, nPointUp, nPointAll

    ! Indexes of the start and end points of the Up and Down halves
    integer:: iPointMin, iPointMid, iPointMax

    ! State variables along a single field line (both halves)
    real, allocatable:: State_VI(:,:)

    ! Coordinates, state variables and curvature
    ! at the minimum B location indexed by r and Lon
    real, allocatable:: StateMinB_VII(:,:,:)

    ! Names of quantities in StateMin_VIIB
    character(len=12), allocatable:: Name_I(:)

    ! True for "eqb" plot area
    logical:: IsMinB

    ! Weights for interpolating to minimum location
    real:: Weight_I(3)

    integer:: iLine

    character(len=100) :: NameFile, NameFileEnd

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'write_plot_equator'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)

    IsMinB = plot_type(iFile)(1:3) == 'eqb'

    DoExtractCurvatureB = IsMinB

    ! Extract grid info from plot_range
    ! See MH_set_parameters for plot_type eqr and eqb
    nRadius = nint(plot_range(1,iFile))
    nLon    = nint(plot_range(2,iFile))
    rMin    = plot_range(3,iFile)
    rMax    = plot_range(4,iFile)
    LonMin  = cDegToRad*plot_range(5,iFile)
    LonMax  = cDegToRad*plot_range(6,iFile)

    allocate(Radius_I(nRadius), Longitude_I(nLon))
    do iR = 1, nRadius
       Radius_I(iR) = rMin + (iR-1)*(rMax - rMin)/(nRadius - 1)
    end do
    do iLon = 1, nLon
       Longitude_I(iLon) = LonMin + (iLon-1)*(LonMax - LonMin)/(nLon - 1)
    end do

    call trace_field_equator(nRadius, nLon, Radius_I, Longitude_I, .false.)

    deallocate(Radius_I, Longitude_I)

    if(iProc/=0) RETURN

    ! Set number of variables at each point along line; allocate accordingly.
    if(DoExtractCurvatureB)then
       ! length + coordinates + variables + rCurvature
       nVarPlot = nVar + 5
    else
       ! length + coordinates + variables
       nVarPlot = nVar + 4
    end if

    NameFileEnd = ""
    if(time_accurate)then
       call get_time_string
       NameFileEnd = "_t"//StringDateOrTime
    end if
    write(NameFileEnd,'(a,i7.7)') trim(NameFileEnd) // '_n',n_step
    if(TypeFile_I(iFile) == 'tec')then
       NameFileEnd = trim(NameFileEnd)//'.dat'
    else
       NameFileEnd = trim(NameFileEnd)//'.out'
    end if

    call line_get(nVarOut, nPoint)

    if(nVarOut /= nVarPlot)then
       write(*,*) NameSub,': nVarOut, nVarPlot=', nVarOut, nVarPlot
       call stop_mpi(NameSub//': nVarOut error')
    end if
    allocate(PlotVar_VI(0:nVarOut, nPoint))
    call line_get(nVarOut, nPoint, PlotVar_VI, DoSort=.true.)

    ! Convert vectors from BATSRUS coords to SM coords.
    if(UseSmg) SmGm_DD = transform_matrix(time_simulation, TypeCoordSystem, 'SMG')

    if(.not.IsMinB)then

       NameFile = trim(NamePlotDir)//"eqr"//NameFileEnd
       call open_file(FILE=NameFile)
       write(UnitTmp_, *) 'nRadius, nLon, nPoint=',nRadius, nLon, nPoint
       write(UnitTmp_, *) 'iLine l x y z rho ux uy uz bx by bz p rCurve'

       allocate(PlotVar_V(0:nVarPlot))
       do iPoint = 1, nPoint
          ! Convert vectors to SM coordinates
          PlotVar_V = PlotVar_VI(:, iPoint)
          if(UseSmg)then
             PlotVar_V(2:4) = matmul(SmGm_DD,PlotVar_V(2:4))
             PlotVar_V(4+Ux_:4+Uz_) = matmul(SmGm_DD,PlotVar_V(4+Ux_:4+Uz_))
             PlotVar_V(4+Bx_:4+Bz_) = matmul(SmGm_DD,PlotVar_V(4+Bx_:4+Bz_))
          end if
          ! Save into file
          write(UnitTmp_, *) PlotVar_V
       end do
       deallocate(PlotVar_V)

       call close_file
    else
       ! StateMinB: x,y,z,state variables and curvature at min B and Z=0
       allocate( &
            StateMinB_VII(2*(nVar+4),nRadius,nLon), &
            Name_I(2*(nVar+4)), &
            State_VI(0:nVarOut,nPoint))

       iPointMin = 1
       iPointMid = 0
       iPointMax = 0
       iLine  = 0
       do iLon = 1, nLon
          do iR = 1, nRadius

             iLine = iLine + 1   ! Collect info from both directions
             do
                if(nint(PlotVar_VI(0,iPointMid + 1)) > iLine) EXIT
                iPointMid = iPointMid + 1
             end do

             iLine = iLine + 1
             iPointMax = iPointMid + 1
             do
                if(iPointMax == nPoint) EXIT
                if(nint(PlotVar_VI(0,iPointMax + 1)) > iLine) EXIT
                iPointMax = iPointMax + 1
             end do

             ! Note: we skip one of the repeated starting point!
             nPointUp = iPointMid - iPointMin
             nPointDn = iPointMax - iPointMid
             nPointAll= nPointDn + nPointUp

             ! Skip all (half)open field lines
             if(any(RayMap_DSII(1,:,iR,iLon) < CLOSEDRAY))then
                ! Set impossible values (density cannot be zero)
                StateMinB_VII(:,iR,iLon)  = 0.0
                ! Set coordinates to starting point position in the SM Z=0 plane
                StateMinB_VII(1:2,iR,iLon)           = 2*PlotVar_VI(2:3,iPointMin)
                StateMinB_VII(nVar+5:nVar+6,iR,iLon) =   PlotVar_VI(2:3,iPointMin)
             else
                ! Put together the two halves
                State_VI(:,1:nPointDn) &
                     = PlotVar_VI(:,iPointMax:iPointMid+1:-1)
                State_VI(:,nPointDn+1:nPointAll) &
                     = PlotVar_VI(:,iPointMin+1:iPointMid)

                ! Flip the sign of the "length" variables for the Down half
                ! so that the length is a continuous function along the whole field line
                State_VI(1,1:nPointDn) = -State_VI(1,1:nPointDn)

                ! Find minimum of B^2
                iPoint = minloc( sum(State_VI(4+Bx_:4+Bz_,1:nPointAll)**2, DIM=1), &
                     DIM=1)

                ! Fit parabola around minimum B value using "length" as the coordinate
                call fit_parabola( &
                     State_VI(1,iPoint-1:iPoint+1), &
                     sqrt(sum(State_VI(4+Bx_:4+Bz_,iPoint-1:iPoint+1)**2, DIM=1)), &
                     Weight3Out_I=Weight_I)

                ! Don't save line index and length

                ! First nVar+4 variables are at minimum B
                ! Interpolate to minimum point obtained from fit_parabola
                do iVar = 1, nVar+4
                   StateMinB_VII(iVar,iR,iLon) = &
                        sum(State_VI(iVar+1,iPoint-1:iPoint+1)*Weight_I)
                end do

                ! Next nVar+4 variables are at z=0 (which is the start point)
                StateMinB_VII(nVar+5: ,iR,iLon) = State_VI(2:,nPointDn)

                if(UseSmg)then
                   ! Convert magnetic fields into SM coordinate system
                   StateMinB_VII(3+Bx_:3+Bz_,iR,iLon) = &
                        matmul(SmGm_DD, StateMinB_VII(3+Bx_:3+Bz_,iR,iLon))

                   StateMinB_VII(nVar+7+Bx_:nVar+7+Bz_,iR,iLon) = &
                        matmul(SmGm_DD, StateMinB_VII(nVar+7+Bx_:nVar+7+Bz_,iR,iLon))
                end if

             end if

             ! Prepare for the next line
             iPointMin = iPointMax + 1
             iPointMid = iPointMax

          end do
       end do

       ! Create list of variables for eqb file
       Name_I(1) = 'x'
       Name_I(2) = 'y'
       Name_I(3) = 'z'
       Name_I(4:nVar+3) = NamePrimitive_V
       do iVar = 3+Bx_, 3+Bz_
          Name_I(iVar) = trim(Name_I(iVar))//'SM'
       end do
       Name_I(nVar+4) = 'rCurve'
       do iVar = 1, nVar+4
          Name_I(iVar+nVar+4) = trim(Name_I(iVar))//'Z0'
       end do

       NameFile = trim(NamePlotDir)//"eqb"//NameFileEnd
       call save_plot_file( &
            NameFile, &
            TypeFileIn=TypeFile_I(iFile), &
            StringHeaderIn = 'Values at minimum B', &
            TimeIn  = time_simulation, &
            nStepIn = n_step, &
            NameVarIn_I= Name_I, &
            IsCartesianIn= .false., &
            CoordIn_DII  = StateMinB_VII(1:2,:,:), &
            VarIn_VII    = StateMinB_VII(3:,:,:))

       deallocate(StateMinB_VII, Name_I, State_VI)

    end if

    call line_clean
    deallocate(PlotVar_VI)

    ! Now save the mapping files
    NameFile = trim(NamePlotDir)//"map_north"//NameFileEnd
    call save_plot_file( &
         NameFile, &
         TypeFileIn=TypeFile_I(iFile), &
         StringHeaderIn = 'Mapping to northern ionosphere', &
         TimeIn       = time_simulation, &
         nStepIn      = n_step, &
         NameVarIn    = 'r Lon rIono ThetaIono PhiIono', &
         CoordMinIn_D = [rMin,   0.0], &
         CoordMaxIn_D = [rMax, 360.0], &
         VarIn_VII  = RayMap_DSII(:,1,:,:))

    NameFile = trim(NamePlotDir)//"map_south"//NameFileEnd
    call save_plot_file( &
         NameFile, &
         TypeFileIn=TypeFile_I(iFile), &
         StringHeaderIn = 'Mapping to southern ionosphere', &
         TimeIn       = time_simulation, &
         nStepIn      = n_step, &
         NameVarIn    = 'r Lon rIono ThetaIono PhiIono', &
         CoordMinIn_D = [rMin,   0.0], &
         CoordMaxIn_D = [rMax, 360.0], &
         VarIn_VII  = RayMap_DSII(:,2,:,:))

    deallocate(RayMap_DSII)

    call test_stop(NameSub, DoTest)
  end subroutine write_plot_equator
  !============================================================================

  subroutine trace_field_equator(nRadius, nLon, Radius_I, Longitude_I, &
       DoMessagePass)

    use ModMain,       ONLY: x_, y_, z_, nI, nJ, nK, Unused_B
    use CON_ray_trace, ONLY: ray_init
    use CON_axes,      ONLY: transform_matrix
    use ModMain,       ONLY: nBlock, Time_Simulation, UseB0
    use ModAdvance,    ONLY: nVar, State_VGB, Bx_, Bz_
    use ModB0,         ONLY: B0_DGB
    use ModGeometry,       ONLY: CellSize_DB
    use CON_line_extract,  ONLY: line_init, line_collect, line_clean
    use ModCoordTransform, ONLY: xyz_to_sph
    use ModMessagePass,    ONLY: exchange_messages
    use ModElectricField,  ONLY: calc_inductive_e

    use BATL_lib,          ONLY: message_pass_cell, find_grid_block, &
         MinI, MaxI, MinJ, MaxJ, MinK, MaxK, iProc, iComm
    use ModMpi

    !INPUT ARGUMENTS:
    integer, intent(in):: nRadius, nLon
    real,    intent(in):: Radius_I(nRadius), Longitude_I(nLon)
    logical, intent(in):: DoMessagePass

    !DESCRIPTION:
    ! Follow field lines starting from a 2D polar grid on the
    ! magnetic equatorial plane in the SM(G) coordinate system.
    ! The grid parameters are given by the arguments.
    ! The subroutine extracts coordinates and state variables
    ! along the field lines going in both directions
    ! starting from the 2D equatorial grid.
    ! Fill in ghost cells if DoMessagePass is true.

    integer :: iR, iLon, iSide
    integer :: iProcFound, iBlockFound, iBlock, i, j, k, iError
    real    :: r, Phi, Xyz_D(3), b_D(3), b2

    real, allocatable:: b_DG(:,:,:,:)

    integer :: nStateVar

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'trace_field_equator'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)

    ! Extract grid info from plot_range (see set_parameters for plot_type eqr)
    if(DoTest)then
       write(*,*)NameSub,' starting on iProc=',iProc,&
            ' with nRadius, nLon=', nRadius, nLon
       write(*,*)NameSub,' Radius_I   =',Radius_I
       write(*,*)NameSub,' Longitude_I=',Longitude_I
    end if

    call timing_start(NameSub)

    ! Fill in all ghost cells
    call message_pass_cell(nVar, State_VGB)

    DoTestRay = .false.

    ! Initialize some basic variables
    DoIntegrateRay = .false.
    DoExtractRay   = .true.
    DoTraceRay     = .false.
    DoMapRay       = .true.

    if(DoExtractBGradB1)then
       allocate(bGradB1_DGB(3,0:nI+1,0:nJ+1,0:nK+1,nBlock))
       do iBlock = 1, nBlock
          if(Unused_B(iBlock)) CYCLE
          do k = 0, nK+1; do j = 0, nJ+1; do i = 0, nI+1;
             b_D = State_VGB(Bx_:Bz_,i,j,k,iBlock)
             if(UseB0) b_D = b_D +  B0_DGB(:,i,j,k,iBlock)
             b_D = b_D/sqrt(max(1e-30,sum(b_D**2)))

             bGradB1_DGB(:,i,j,k,iBlock) = &
                  0.5*b_D(1) *  &
                  ( State_VGB(Bx_:Bz_,i+1,j,k,iBlock)     &
                  - State_VGB(Bx_:Bz_,i-1,j,k,iBlock)) / &
                  CellSize_DB(x_,iBlock) &
                  + 0.5*b_D(2) *  &
                  ( State_VGB(Bx_:Bz_,i,j+1,k,iBlock)     &
                  - State_VGB(Bx_:Bz_,i,j-1,k,iBlock)) / &
                  CellSize_DB(y_,iBlock) &
                  + 0.5*b_D(3) * &
                  ( State_VGB(Bx_:Bz_,i,j,k+1,iBlock) &
                  - State_VGB(Bx_:Bz_,i,j,k+1,iBlock)) / &
                  CellSize_DB(z_,iBlock)

          end do; end do; end do
       end do
    end if

    if(DoExtractCurvatureB)then
       allocate(CurvatureB_GB(0:nI+1,0:nJ+1,0:nK+1,nBlock), &
            b_DG(3,MinI:MaxI,MinJ:MaxJ,MinK:MaxK))
       do iBlock = 1, nBlock
          if(Unused_B(iBlock)) CYCLE

          ! Calculate normalized magnetic field including B0
          do k = MinK, MaxK; do j=MinJ, MaxJ; do i = MinI,MaxI
             b_DG(:,i,j,k) = State_VGB(Bx_:Bz_,i,j,k,iBlock)
             if(UseB0) b_DG(:,i,j,k) = b_DG(:,i,j,k) + B0_DGB(:,i,j,k,iBlock)
             b2 = sum(b_DG(:,i,j,k)**2)
             if(b2 > 0)b_DG(:,i,j,k) = b_DG(:,i,j,k)/sqrt(b2)
          end do; end do; end do

          do k = 0, nK+1; do j = 0, nJ+1; do i = 0, nI+1;
             ! Calculate b.grad b
             b_D = 0.5*b_DG(1,i,j,k) *  &
                  ( b_DG(:,i+1,j,k) - b_DG(:,i-1,j,k)) / &
                  CellSize_DB(x_,iBlock) &
                  + 0.5*b_DG(2,i,j,k) *  &
                  ( b_DG(:,i,j+1,k) - b_DG(:,i,j-1,k)) / &
                  CellSize_DB(y_,iBlock) &
                  + 0.5*b_DG(3,i,j,k) * &
                  ( b_DG(:,i,j,k+1) - b_DG(:,i,j,k-1)) / &
                  CellSize_DB(z_,iBlock)

             b2 = sum(b_D**2)
             if(b2 > 0)then
                CurvatureB_GB(i,j,k,iBlock) = 1/sqrt(b2)
             else
                CurvatureB_GB(i,j,k,iBlock) = 1e30
             end if
          end do; end do; end do
       end do
    end if

    ! Calculate total, potential and inductive electric fields
    if(DoExtractEfield) call calc_inductive_e

    nRay_D  = [ 2, nRadius, nLon, 0 ]
    DoExtractState = .true.
    DoExtractUnitSi= .true.
    nStateVar = 4 + nVar
    if(DoExtractBGradB1)    nStateVar = nStateVar + 3
    if(DoExtractCurvatureB) nStateVar = nStateVar + 1
    if(DoExtractEfield)     nStateVar = nStateVar + 6
    call line_init(nStateVar)

    NameVectorField = 'B'

    ! (Re)initialize CON_ray_trace
    call ray_init(iComm)

    ! Copy magnetic field into Bxyz_DGB
    do iBlock = 1, nBlock; if(Unused_B(iBlock))CYCLE
       Bxyz_DGB(:,:,:,:,iBlock) = State_VGB(Bx_:Bz_,:,:,:,iBlock)
       ! Add B0
       if(UseB0) Bxyz_DGB(:,:,:,:,iBlock) = &
            Bxyz_DGB(:,:,:,:,iBlock) + B0_DGB(:,:,:,:,iBlock)
    end do

    ! Transformation matrix between the SM and GM coordinates
    if(UseSmg) GmSm_DD = transform_matrix(time_simulation, 'SMG', TypeCoordSystem)

    ! Integrate rays starting from the latitude-longitude pairs defined
    ! by the arrays Lat_I, Lon_I
    CpuTimeStartRay = MPI_WTIME()
    do iR = 1, nRadius

       r = Radius_I(iR)

       if(r < rBody*1.0001) CYCLE

       do iLon = 1, nLon

          Phi = Longitude_I(iLon)

          ! Convert polar coordinates to Cartesian coordinates in SM
          Xyz_D(x_) = r*cos(Phi)
          Xyz_D(y_) = r*sin(Phi)
          Xyz_D(z_) = 0.0

          ! Convert SM position to GM (Note: these are same for ideal axes)
          if(UseSmg) Xyz_D = matmul(GmSm_DD, Xyz_D)

          ! Find processor and block for the location
          call find_grid_block(Xyz_D,iProcFound,iBlockFound)

          ! If location is on this PE, follow and integrate ray
          if(iProc == iProcFound)then

             call follow_ray(1, [1, iR, iLon, iBlockFound], Xyz_D)
             call follow_ray(2, [2, iR, iLon, iBlockFound], Xyz_D)

          end if
       end do
    end do

    ! Do remaining rays obtained from other PE-s
    call finish_ray

    ! Collect all rays onto processor 0
    call line_collect(iComm,0)

    ! Clean data except on processor 0
    if(iProc /= 0)call line_clean

    ! Some procs never have their RayMap arrays allocated.
    if(.not.allocated(RayMap_DSII)) then
       allocate(RayMap_DSII(3,nRay_D(1),nRay_D(2),nRay_D(3)))
       allocate(RayMapLocal_DSII(3,nRay_D(1),nRay_D(2),nRay_D(3)))
       RayMapLocal_DSII = 0.0
       RayMap_DSII = 0.0
    end if

    ! Collect the ray mapping info to processor 0
    call MPI_reduce(RayMapLocal_DSII, RayMap_DSII, size(RayMap_DSII), MPI_REAL, &
         MPI_SUM, 0, iComm, iError)
    deallocate(RayMapLocal_DSII)

    if(iProc == 0)then
       do iLon = 1, nLon; do iR = 1, nRadius; do iSide = 1, 2
          if(RayMap_DSII(1,iSide,iR,iLon) < CLOSEDRAY) CYCLE
          Xyz_D = RayMap_DSII(:,iSide,iR,iLon)
          if(UseSmg) Xyz_D = matmul(Xyz_D,GmSm_DD)
          call xyz_to_sph(Xyz_D, RayMap_DSII(:,iSide,iR,iLon))
       end do; end do; end do
    else
       deallocate(RayMap_DSII)
    end if

    if(DoExtractBGradB1) deallocate(bGradB1_DGB)

    if(DoExtractCurvatureB) deallocate(CurvatureB_GB, b_DG)

    if(DoMessagePass)call exchange_messages

    call timing_stop(NameSub)

    call test_stop(NameSub, DoTest)
  end subroutine trace_field_equator
  !============================================================================

  subroutine extract_field_lines(nLine, IsParallel_I, Xyz_DI)

    ! Extract nLine ray lines parallel or anti_parallel according to
    ! IsParallel_I(nLine), starting from positions Xyz_DI(3,nLine).
    ! The results are stored by CON_line_extract.

    use CON_ray_trace, ONLY: ray_init
    use ModAdvance,  ONLY: State_VGB, RhoUx_, RhoUz_, Bx_, By_, Bz_
    use ModB0,       ONLY: B0_DGB
    use ModMain,     ONLY: nI, nJ, nK, nBlock, Unused_B, UseB0
    use ModGeometry, ONLY: CellSize_DB, x_, y_, z_
    use ModMpi,      ONLY: MPI_WTIME
    use BATL_lib,    ONLY: find_grid_block

    !INPUT ARGUMENTS:
    integer, intent(in) :: nLine
    logical, intent(in) :: IsParallel_I(nLine)
    real,    intent(in) :: Xyz_DI(3, nLine)

    ! EOP
    real    :: Xyz_D(3), Dx2Inv, Dy2Inv, Dz2Inv
    integer :: iProcFound, iBlockFound, iLine, iRay

    integer :: i, j, k, iBlock

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'extract_field_lines'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)

    ! Initialize trace parameters
    DoTraceRay     = .false.
    DoMapRay       = .false.
    DoIntegrateRay = .false.
    DoExtractRay   = .true.
    nRay_D = [ nLine, 0, 0, 0 ]

    ! (Re)initialize CON_ray_trace
    call ray_init(iComm)

    select case(NameVectorField)
    case('B')
       ! Copy magnetic field into Bxyz_DGB
       do iBlock = 1, nBlock; if(Unused_B(iBlock))CYCLE
          Bxyz_DGB(:,:,:,:,iBlock) = State_VGB(Bx_:Bz_,:,:,:,iBlock)
          ! Add B0
          if(UseB0) Bxyz_DGB(:,:,:,:,iBlock) = &
               Bxyz_DGB(:,:,:,:,iBlock) + B0_DGB(:,:,:,:,iBlock)
       end do
    case('U')
       ! Store momentum field (same as velocity field after normalization)
       do iBlock = 1, nBlock; if(Unused_B(iBlock))CYCLE
          Bxyz_DGB(:,:,:,:,iBlock) = State_VGB(RhoUx_:RhoUz_,:,:,:,iBlock)
       end do
    case('J')
       ! Store current
       ! !! this needs to be improved a lot:
       ! !! call get_current_D for cell centers
       ! !! call message_pass_cell(Bxyz_DGB...)
       ! !! outer boundaries???
       do iBlock = 1, nBlock; if(Unused_B(iBlock)) CYCLE
          Dx2Inv = 0.5/CellSize_DB(x_,iBlock)
          Dy2Inv = 0.5/CellSize_DB(y_,iBlock)
          Dz2Inv = 0.5/CellSize_DB(z_,iBlock)

          do k=0,nK+1; do j=0,nJ+1; do i=0,nI+1
             Bxyz_DGB(1,i,j,k,iBlock) = &
                  (State_VGB(Bz_,i,j+1,k,iBlock)-State_VGB(Bz_,i,j-1,k,iBlock)) &
                  *Dy2Inv - &
                  (State_VGB(By_,i,j,k+1,iBlock)-State_VGB(By_,i,j,k-1,iBlock)) &
                  *Dz2Inv
             Bxyz_DGB(2,i,j,k,iBlock) = &
                  (State_VGB(Bx_,i,j,k+1,iBlock)-State_VGB(Bx_,i,j,k-1,iBlock)) &
                  *Dz2Inv - &
                  (State_VGB(Bz_,i+1,j,k,iBlock)-State_VGB(Bz_,i-1,j,k,iBlock)) &
                  *Dx2Inv
             Bxyz_DGB(3,i,j,k,iBlock) = &
                  (State_VGB(By_,i+1,j,k,iBlock)-State_VGB(By_,i-1,j,k,iBlock)) &
                  *Dx2Inv - &
                  (State_VGB(Bx_,i,j+1,k,iBlock)-State_VGB(Bx_,i,j-1,k,iBlock)) &
                  *Dy2Inv
          end do; end do; end do
       end do
    case default
       call stop_mpi(NameSub//': invalid NameVectorField='//NameVectorField)
    end select

    ! Start extracting rays
    CpuTimeStartRay = MPI_WTIME()
    do iLine = 1, nLine
       Xyz_D = Xyz_DI(:,iLine)

       call find_grid_block(Xyz_D,iProcFound,iBlockFound)

       if(iProc == iProcFound)then
          if(DoTest)write(*,*)NameSub,' follows ray ',iLine,&
               ' from iProc,iBlock,i,j,k=',iProcFound, iBlockFound, i, j, k
          if(IsParallel_I(iLine))then
             iRay = 1
          else
             iRay = 2
          end if
          call follow_ray(iRay, [iLine, 0, 0, iBlockFound], Xyz_D)
       end if
    end do

    ! Do remaining rays obtained from other PE-s
    call finish_ray

    call test_stop(NameSub, DoTest)
  end subroutine extract_field_lines
  !============================================================================

  subroutine write_plot_line(iFile)

    use ModVarIndexes, ONLY: nVar
    use ModIO,       ONLY: StringDateOrTime,            &
         NamePlotDir, plot_type, plot_form, plot_dimensional, Plot_, &
         NameLine_I, nLine_I, XyzStartLine_DII, IsParallelLine_II, &
         IsSingleLine_I
    use ModWriteTecplot, ONLY: set_tecplot_var_string
    use ModMain,     ONLY: &
         n_step, time_accurate, time_simulation, NamePrimitive_V
    use ModIoUnit,   ONLY: UnitTmp_
    use ModUtilities, ONLY: open_file, close_file, join_string
    use CON_line_extract, ONLY: line_init, line_collect, line_get, line_clean

    integer, intent(in) :: iFile ! The file index of the plot file

    character(len=100) :: NameFile, NameStart, StringTitle
    character(len=1500):: NameVar, StringPrimitive
    integer            :: nLineFile, nStateVar, nPlotVar
    integer            :: iPoint, nPoint, iPointNext, nPoint1

    real, pointer :: PlotVar_VI(:,:)

    integer :: iPlotFile, iLine, nLine, nVarOut

    logical :: IsSingleLine, IsIdl

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'write_plot_line'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)

    ! Set the global ModFieldTrace variables for this plot file
    iPlotFile      = iFile - Plot_
    select case(NameLine_I(iPlotFile))
    case('A', 'B')
       NameVectorField = 'B'
    case('U','J')
       NameVectorField = NameLine_I(iPlotFile)
    case default
       write(*,*) NameSub//' WARNING invalid NameVectorField='// &
            NameVectorField//' for iPlotFile=',iPlotFile
       RETURN
    end select
    DoExtractState = index(plot_type(iFile),'pos')<1
    DoExtractUnitSi= plot_dimensional(iFile)

    ! Set the number lines and variables to be extracted
    nLine     = nLine_I(iPlotFile)
    nStateVar = 4
    if(DoExtractState) nStateVar = nStateVar + nVar

    ! Initialize CON_line_extract
    call line_init(nStateVar)

    ! Obtain the line data
    call extract_field_lines(nLine, IsParallelLine_II(1:nLine,iPlotFile), &
         XyzStartLine_DII(:,1:nLine,iPlotFile))

    ! Collect lines from all PE-s to Proc 0
    call line_collect(iComm,0)

    if(iProc==0)then
       call line_get(nVarOut, nPoint)
       if(nVarOut /= nStateVar)then
          write(*,*) NameSub,': nVarOut, nStateVar=', nVarOut, nStateVar
          call stop_mpi(NameSub//': nVarOut error')
       end if
       allocate(PlotVar_VI(0:nVarOut, nPoint))
       call line_get(nVarOut, nPoint, PlotVar_VI, DoSort=.true.)
    end if

    call line_clean

    ! Only iProc 0 works on writing the plot files
    if(iProc /= 0) RETURN

    ! Write the result into 1 or more plot files from processor 0

    IsSingleLine = IsSingleLine_I(iPlotFile)

    if(IsSingleLine)then
       nLineFile = nLine
    else
       nLineFile = 1
    end if

    if(iPlotFile < 10)then
       write(NameStart,'(a,i1,a)') &
            trim(NamePlotDir)//trim(plot_type(iFile))//'_',iPlotFile
    else
       write(NameStart,'(a,i2,a)') &
            trim(NamePlotDir)//trim(plot_type(iFile))//'_',iPlotFile
    end if
    NameStart = trim(NameStart)//'_'//NameLine_I(iPlotFile)

    if(time_accurate)call get_time_string

    ! Set the title
    if(IsSingleLine)then
       StringTitle = NameVectorField//' line'
    else
       StringTitle = NameVectorField//' lines'
    end if

    ! Add the string describing the units
    if(DoExtractUnitSi)then
       StringTitle = trim(StringTitle)//" in SI units"
    else
       StringTitle = trim(StringTitle)//" in normalized units"
    end if

    ! The Length is used as a coordinate in the IDL file, so it is not a plot var
    nPlotVar = nStateVar - 1
    ! Add 1 for the Index array if it is needed in the plot file
    if(.not. IsSingleLine)nPlotVar = nPlotVar + 1

    ! Set the name of the variables
    select case(plot_form(iFile))
    case('idl')
       IsIdl = .true.
       NameVar = 'Length x y z'
       if(DoExtractState) then
          call join_string(nVar,NamePrimitive_V,StringPrimitive)
          NameVar = trim(NameVar)//' '//StringPrimitive
       end if
       if(IsSingleLine)then
          NameVar = trim(NameVar)//' iLine'
       else
          NameVar = trim(NameVar)//' Index nLine'
       end if
    case('tec')
       IsIdl = .false.
       if(DoExtractState) then
          call set_tecplot_var_string(iFile, nVar, NamePrimitive_V, NameVar)
       else
          NameVar = '"X", "Y", "Z"'
       end if
       if(.not.IsSingleLine)NameVar = trim(NameVar)//', "Index"'
       NameVar = trim(NameVar)//', "Length"'
    case default
       call stop_mpi(NameSub//' ERROR invalid plot form='//plot_form(iFile))
    end select

    ! Write out plot files
    ! If IsSingleLine is true write a new file for every line,
    ! otherwise write a single file

    iPointNext = 1
    do iLine = 1, nLineFile

       ! Set the file name
       NameFile = NameStart
       if(IsSingleLine .and. nLine > 1)then
          if(nLine < 10)then
             write(NameFile,'(a,i1)') trim(NameFile),iLine
          else
             write(NameFile,'(a,i2)') trim(NameFile),iLine
          end if
       end if
       if(time_accurate) NameFile = trim(NameFile)// "_t"//StringDateOrTime
       write(NameFile,'(a,i7.7,a)') trim(NameFile) // '_n',n_step

       if(IsIdl)then
          NameFile = trim(NameFile) // '.out'
       else
          NameFile = trim(NameFile) // '.dat'
       end if

       ! Figure out the number of points for this ray
       if(IsSingleLine) nPoint1 = count(nint(PlotVar_VI(0,1:nPoint))==iLine)

       call open_file(FILE=NameFile)
       if(IsIdl)then
          write(UnitTmp_,'(a79)') trim(StringTitle)//'_var11'
          write(UnitTmp_,'(i7,1pe13.5,3i3)') &
               n_step,time_simulation,1,1,nPlotVar
          if(IsSingleLine)then
             write(UnitTmp_,'(i6)') nPoint1
             write(UnitTmp_,'(es13.5)') real(iLine)
          else
             write(UnitTmp_,'(i6)') nPoint
             write(UnitTmp_,'(es13.5)') real(nLine)
          end if
          write(UnitTmp_,'(a79)') NameVar
       else
          write(UnitTmp_,'(a)')'TITLE ="'//trim(StringTitle)//'"'
          write(UnitTmp_,'(a)')'VARIABLES='//trim(NameVar)
          if(IsSingleLine)then
             write(UnitTmp_,'(a,i2.2,a,i6)')'ZONE T="'// &
                  NameVectorField//' line ',iLine,'", '//'I=',nPoint1
          else
             write(UnitTmp_,'(a,i2.2,a,i6)')'ZONE T="'// &
                  NameVectorField//' ',nLine,' lines", '//'I=',nPoint
          end if
       end if

       ! Write out data
       if(IsSingleLine)then
          ! Write out the part corresponding to this line
          do iPoint = iPointNext, iPointNext + nPoint1 - 1
             if(IsIdl)then
                ! Write Length as the first variable: the 1D coordinate
                write(UnitTmp_,'(50es18.10)') PlotVar_VI(1:nStateVar,iPoint)
             else
                ! Write Length as the last variable, so that
                ! x,y,z can be used as 3D coordinates
                write(UnitTmp_,'(50es18.10)') PlotVar_VI(2:nStateVar,iPoint),&
                     PlotVar_VI(1,iPoint)
             end if
          end do
          iPointNext = iPointNext + nPoint1
       else
          do iPoint = 1, nPoint
             if(IsIdl)then
                ! Write Index as the last variable
                write(UnitTmp_, '(50es18.10)') &
                     PlotVar_VI(1:nStateVar, iPoint), PlotVar_VI(0,iPoint)
             else
                ! Write Index and Length as the last 2 variables
                write(UnitTmp_, '(50es18.10)') &
                     PlotVar_VI(2:nStateVar, iPoint), PlotVar_VI(0:1,iPoint)
             end if
          end do
       end if
       call close_file
    end do

    deallocate(PlotVar_VI)

    call test_stop(NameSub, DoTest)
  end subroutine write_plot_line
  !============================================================================

  subroutine xyz_to_ijk(XyzIn_D, IjkOut_D, iBlock, XyzRef_D, GenRef_D, dGen_D)

    use ModNumConst,  ONLY: cPi, cTwoPi
    use BATL_lib,     ONLY: Phi_, Theta_, x_, y_, &
         IsAnyAxis, IsLatitudeAxis, IsSphericalAxis, IsPeriodicCoord_D, &
         CoordMin_D, CoordMax_D, xyz_to_coord

    integer, intent(in) :: iBlock
    real,    intent(in) :: XyzIn_D(3), XyzRef_D(3), GenRef_D(3), dGen_D(3)
    real,    intent(out):: IjkOut_D(3)

    real:: Gen_D(3)

    character(len=*), parameter:: NameSub = 'xyz_to_ijk'
    !--------------------------------------------------------------------------
    call xyz_to_coord(XyzIn_D, Gen_D)

    ! Did the ray cross the pole?
    if(IsAnyAxis)then
       if( (XyzIn_D(x_)*XyzRef_D(x_) + XyzIn_D(y_)*XyzRef_D(y_)) < 0.)then
          ! Shift Phi by +/-pi (tricky, but works)
          ! E.g. PhiRef=  5deg, Phi=186deg -->   6deg
          ! or   PhiRef=185deg, Phi=  6deg --> 186deg
          Gen_D(Phi_) = Gen_D(Phi_) &
               + GenRef_D(Phi_) - modulo((cPi + GenRef_D(Phi_)), cTwoPi)

          if(IsLatitudeAxis .or. IsSphericalAxis)then
             if(Gen_D(Theta_) > &
                  0.5*(CoordMax_D(Theta_) + CoordMin_D(Theta_)))then
                ! Mirror theta/latitude to maximum coordinate
                ! E.g. Lat=85 deg --> 95 deg, Theta=175 deg --> 185 deg
                Gen_D(Theta_) = 2*CoordMax_D(Theta_) - Gen_D(Theta_)
             else
                ! Mirror theta/latitude to minimum coordinate
                ! E.g. Lat=-85 deg --> -95 deg, Theta = 5 deg --> -5 deg
                Gen_D(Theta_) = 2*CoordMin_D(Theta_) - Gen_D(Theta_)
             end if
          end if
       end if
    end if

    ! Did the ray cross the periodic Phi boundary?
    if(Phi_ > 1)then
       if(IsPeriodicCoord_D(Phi_))then
          if    (Gen_D(Phi_) - GenRef_D(Phi_) > cPi)then
             ! Crossed from small phi direction, make Gen_D negative
             ! E.g. PhiRef=5deg Phi=355deg -> -5deg
             Gen_D(Phi_) = Gen_D(Phi_) - cTwoPi
          elseif(GenRef_D(Phi_) - Gen_D(Phi_) > cPi)then
             ! Crossed from phi~2pi direction, make Gen_D larger than 2pi
             ! E.g. PhiRef=355deg Phi=5deg -> 365deg
             Gen_D(Phi_) = Gen_D(Phi_) + cTwoPi
          end if
       end if
    end if

    ! Gen_D is set, now compute normalized generalized coordinate IjkOut_D
    IjkOut_D = (Gen_D - GenRef_D)/dGen_D + 1.

  end subroutine xyz_to_ijk
  !============================================================================

  subroutine write_plot_lcb(iFile)

    use CON_line_extract,  ONLY: line_get, line_clean
    use CON_planet_field,  ONLY: map_planet_field
    use CON_axes,          ONLY: transform_matrix
    use ModIoUnit,         ONLY: UnitTmp_
    use ModUtilities,      ONLY: open_file, close_file
    use ModAdvance,        ONLY: nVar
    use ModMain,           ONLY: Time_Simulation, time_accurate, n_step
    use ModNumConst,       ONLY: cDegToRad
    use ModPhysics,        ONLY: &
         Si2No_V, No2Si_V, UnitX_, UnitRho_, UnitP_, UnitB_
    use ModIO,             ONLY: &
         StringDateOrTime, NamePlotDir, plot_range, plot_type, IsPlotName_n
    use ModNumConst,       ONLY: i_DD
    use ModMpi

    integer, intent(in) :: iFile

    character (len=80) :: FileName
    integer, parameter :: nPts=11, nD=6
    integer:: i,j,k, nLine, iStart,iMid,iEnd, jStart, jMid, jEnd
    integer:: iLon, nLon, iD, iLC
    integer :: iPoint, nPoint, nVarOut, iHemisphere, iError, nTP, iDirZ
    real :: PlotVar_V(0:4+nVar)
    real :: Radius, RadiusIono, Lon, zL,zU, zUs=40., xV,yV, Integrals(3)
    real :: XyzIono_D(3), Xyz_D(3)
    real :: Smg2Gsm_DD(3,3) = i_DD
    real, allocatable :: PlotVar_VI(:,:), XyzPt_DI(:,:), zPt_I(:)
    logical :: Map1, Map2, Odd, Skip, SaveIntegrals

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'write_plot_lcb'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)
    if(DoTest)write(*,*)NameSub, &
         ': starting for iFile=', iFile,' type=',plot_type(iFile)

    ! Extract grid info from plot_range (see set_parameters for lcb plots)
    Radius = plot_range(1,iFile)
    nLon   = plot_range(2,iFile)

    SaveIntegrals=.false.
    if(index(plot_type(iFile),'int')>0) SaveIntegrals=.true.

    if(DoTest)write(*,*)NameSub, 'Radius, nLon, SaveIntegrals=', &
         Radius, nLon, SaveIntegrals

    ! Use a value of 1. for these plots.
    RadiusIono = 1.
    nTP=int( (rBody-RadiusIono)/.1 )

    if(.not.allocated(XyzPt_DI)) allocate(XyzPt_DI(3,nPts), zPt_I(nPts))

    ! Transformation matrix from default (GM) to SM coordinates
    if(UseSmg) Smg2Gsm_DD = transform_matrix(time_simulation,'SMG','GSM')

    if(iProc == 0)then
       FileName=trim(NamePlotDir)//'LCB-GM'
       if(iFile <  10) write(FileName, '(a,i1)') trim(FileName)//"_",iFile
       if(iFile >= 10) write(FileName, '(a,i2)') trim(FileName)//"_",iFile
       if(time_accurate)then
          call get_time_string
          FileName = trim(FileName) // "_t" // StringDateOrTime
       end if
       if(IsPlotName_n) write(FileName,'(a,i7.7)') trim(FileName)//"_n",n_step
       FileName = trim(FileName)//".dat"

       call open_file(FILE=trim(FileName), STATUS="replace")
       write(UnitTmp_,'(a)')'TITLE="IE B traces (GM Coordinates)"'
       if(SaveIntegrals)then
          write(UnitTmp_,'(a)')'VARIABLES="X [R]", "Y [R]", "Z [R]", "1/B", "n", "p"'
       else
          write(UnitTmp_,'(a)')'VARIABLES="X [R]", "Y [R]", "Z [R]"'
       end if
    end if

    do iDirZ = -1,1,2
       ! compute the last closed points on cylinder for positive and negative Z values

       do iLon=1,nLon
          Lon = (360./nLon)*(iLon-1)
          xV = Radius*cos(cDegToRad*Lon)
          yV = Radius*sin(cDegToRad*Lon)

          zL=0.;  zU=zUs*iDirZ
          Skip=.false.
          do iD=1,nD
             if(Skip) CYCLE

             iLC=-9

             ! Create in SM coords
             XyzPt_DI(1,:) = xV
             XyzPt_DI(2,:) = yV
             do i=1,nPts
                XyzPt_DI(3,i) = zL + ((i-1)*((zU-zL)/(nPts-1)))
             end do
             zPt_I = XyzPt_DI(3,:)

             ! Convert to GM coords
             if(UseSmg) XyzPt_DI = matmul(Smg2Gsm_DD,XyzPt_DI)

             if(SaveIntegrals)then
                call integrate_field_from_points(&
                     nPts, XyzPt_DI, 'InvB,RhoInvB,pInvB,extract_I')
             else
                call integrate_field_from_points(nPts, XyzPt_DI, 'extract_I')
             endif

             if(iProc == 0)then

                if(SaveIntegrals) Integrals = -1.

                call line_get(nVarOut, nPoint)
                if(nPoint > 0)then
                   ! PlotVar_VI variables = 'iLine l x y z rho ux uy uz bx by bz p'
                   allocate(PlotVar_VI(0:nVarOut, nPoint))
                   call line_get(nVarOut, nPoint, PlotVar_VI, DoSort=.true.)

                   k = 0
                   do iPoint = 1, nPoint
                      nLine = PlotVar_VI(0,iPoint)
                      if(k == nLine) CYCLE
                      Odd=.true.;  if( (nLine/2)*2 == nLine )Odd=.false.

                      ! finish previous line
                      if(k /= 0)then
                         if(Odd)then
                            iEnd = iPoint-1
                            Map2 = .false.
                            Xyz_D=PlotVar_VI(2:4,iEnd) * Si2No_V(UnitX_)
                            if(norm2(Xyz_D) < 1.5*rBody) Map2 = .true.

                            if(Map1 .and. Map2)then
                               iLC = k/2
                               jStart = iStart; jMid = iMid; jEnd = iEnd
                               if(SaveIntegrals)then
                                  Integrals(1) = &
                                       sum(RayResult_VII(   InvB_,:,iLC)) * No2Si_V(UnitX_)/No2Si_V(UnitB_)
                                  Integrals(2) = &
                                       sum(RayResult_VII(RhoInvB_,:,iLC))/ &
                                       sum(RayResult_VII(   InvB_,:,iLC)) * No2Si_V(UnitRho_)
                                  Integrals(3) = &
                                       sum(RayResult_VII(  pInvB_,:,iLC))/ &
                                       sum(RayResult_VII(   InvB_,:,iLC)) * No2Si_V(UnitP_)
                               end if
                            end if
                         else
                            iEnd = iPoint-1
                            Map1 = .false.
                            Xyz_D=PlotVar_VI(2:4,iEnd) * Si2No_V(UnitX_)
                            if(norm2(Xyz_D) < 1.5*rBody) Map1 = .true.
                         end if
                      end if

                      ! start new line counters
                      k = nLine
                      if(Odd)then
                         iStart = iPoint
                      else
                         iMid = iPoint
                      end if
                   end do

                   ! finish last line
                   if(k/=0)then
                      iEnd = nPoint
                      Map2 = .false.
                      Xyz_D=PlotVar_VI(2:4,iEnd) * Si2No_V(UnitX_)
                      if(norm2(Xyz_D) < 1.5*rBody) Map2 = .true.

                      if(Map1 .and. Map2)then
                         iLC = k/2
                         jStart = iStart; jMid = iMid; jEnd = iEnd
                         if(SaveIntegrals)then
                            Integrals(1) = &
                                 sum(RayResult_VII(   InvB_,:,iLC)) * No2Si_V(UnitX_)/No2Si_V(UnitB_)
                            Integrals(2) = &
                                 sum(RayResult_VII(RhoInvB_,:,iLC))/ &
                                 sum(RayResult_VII(   InvB_,:,iLC)) * No2Si_V(UnitRho_)
                            Integrals(3) = &
                                 sum(RayResult_VII(  pInvB_,:,iLC))/ &
                                 sum(RayResult_VII(   InvB_,:,iLC)) * No2Si_V(UnitP_)
                         end if
                      end if
                   end if

                   ! write only last closed
                   if(iD == nD .and. iLC /= -9)then
                      j = (jEnd-jStart)+2*nTP
                      write(UnitTmp_,'(a,f7.2,a,a,i8,a)') 'ZONE T="LCB lon=',Lon,'"', &
                           ', I=',j,', J=1, K=1, ZONETYPE=ORDERED, DATAPACKING=POINT'
                      Xyz_D = PlotVar_VI(2:4,jMid-1) * Si2No_V(UnitX_)
                      do i=0,nTP-1
                         ! Map from the ionosphere to first point
                         call map_planet_field(time_simulation, Xyz_D, 'GSM NORM', &
                              RadiusIono+i*.1, XyzIono_D, iHemisphere)
                         if(SaveIntegrals)then
                            write(UnitTmp_, *) XyzIono_D,Integrals
                         else
                            write(UnitTmp_, *) XyzIono_D
                         end if
                      end do
                      do i=jMid-1,jStart+1,-1
                         PlotVar_V = PlotVar_VI(:, i)
                         Xyz_D = PlotVar_V(2:4) * Si2No_V(UnitX_)
                         if(SaveIntegrals)then
                            write(UnitTmp_, *) Xyz_D,Integrals
                         else
                            write(UnitTmp_, *) Xyz_D
                         end if
                      end do
                      do i=jMid,jEnd
                         PlotVar_V = PlotVar_VI(:, i)
                         Xyz_D = PlotVar_V(2:4) * Si2No_V(UnitX_)
                         if(SaveIntegrals)then
                            write(UnitTmp_, *) Xyz_D,Integrals
                         else
                            write(UnitTmp_, *) Xyz_D
                         end if
                      end do
                      do i=nTP-1,0,-1
                         ! Map from last point to the ionosphere
                         call map_planet_field(time_simulation, Xyz_D, 'GSM NORM', &
                              RadiusIono+i*.1, XyzIono_D, iHemisphere)
                         if(SaveIntegrals)then
                            write(UnitTmp_, *) XyzIono_D,Integrals
                         else
                            write(UnitTmp_, *) XyzIono_D
                         end if
                      end do
                   end if

                   deallocate(PlotVar_VI)
                end if
                call line_clean
             end if  ! iProc==0

             if(allocated(RayIntegral_VII)) deallocate(RayIntegral_VII)
             if(allocated(RayResult_VII))   deallocate(RayResult_VII)

             ! set new zL and zU
             call MPI_Bcast(iLC,1,MPI_INTEGER,0,iComm,iError)
             if(iLC == -9)then
                Skip=.true.
             elseif(iLC == nPts)then
                zL=   zUs*iDirZ
                zU=2.*zUs*iDirZ
             else
                zL = zPt_I(iLC)
                zU = zPt_I(iLC+1)
             end if

          end do  ! iD loop

       end do  ! iLon loop

    end do  ! iDirZ loop

    if(iProc == 0) call close_file

    if(DoTest)write(*,*)NameSub,': finished'
    call test_stop(NameSub, DoTest)
  end subroutine write_plot_lcb
  !============================================================================

  subroutine write_plot_ieb(iFile)

    use CON_line_extract,  ONLY: line_get, line_clean
    use CON_planet_field,  ONLY: map_planet_field
    use CON_axes,          ONLY: transform_matrix
    use ModIoUnit,         ONLY: UnitTmp_
    use ModUtilities,      ONLY: open_file, close_file
    use ModAdvance,        ONLY: nVar
    use ModMain,           ONLY: Time_Simulation, time_accurate, n_step
    use ModNumConst,       ONLY: cDegToRad
    use ModPhysics,        ONLY: Si2No_V, UnitX_
    use ModCoordTransform, ONLY: sph_to_xyz
    use ModIO,             ONLY: StringDateOrTime, NamePlotDir
    use ModNumConst,       ONLY: i_DD

    integer, intent(in) :: iFile

    character (len=80) :: FileName,stmp
    character (len=2) :: Coord
    character (len=1) :: NS
    integer :: i,j,k, nLat,nLon, nLine, nTP, iStart,iEnd, iLat,iLon, OC
    integer :: iPoint, nPoint, nVarOut, iHemisphere, nFile
    real :: PlotVar_V(0:4+nVar)
    real :: Radius, Lat,Lon, Theta,Phi, LonOC
    real :: XyzIono_D(3), Xyz_D(3)
    real :: Gsm2Smg_DD(3,3) = i_DD
    real :: Smg2Gsm_DD(3,3) = i_DD
    real, allocatable :: PlotVar_VI(:,:), IE_lat(:), IE_lon(:)
    logical :: MapDown

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'write_plot_ieb'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)

    if(DoTest)write(*,*)NameSub,': starting'

    nLat=181
    nLon=36
    if(.not.allocated(IE_lat)) allocate(IE_lat(nLat), IE_lon(nLon))

    ! Load grid and convert to lat-lon in degrees
    do i=1,nLat
       IE_lat(i) = 90.-1.*(i-1)
    end do
    do i=1,nLon
       IE_lon(i) = 10.*(i-1)
    end do
    Radius = (6378.+100.)/6378.
    nTP=int( (rBody-Radius)/.1 )

    call integrate_field_from_sphere(nLat, nLon, IE_lat, IE_lon, Radius, &
         'extract_I')

    if(iProc == 0)then

       ! Transformation matrix from default (GM) to SM coordinates
       Gsm2Smg_DD = transform_matrix(time_simulation,TypeCoordSystem,'SMG')
       Smg2Gsm_DD = transform_matrix(time_simulation,'SMG','GSM')

       call line_get(nVarOut, nPoint)
       if(nPoint>0)then
          ! PlotVar_VI variables = 'iLine l x y z rho ux uy uz bx by bz p'
          allocate(PlotVar_VI(0:nVarOut, nPoint))
          call line_get(nVarOut, nPoint, PlotVar_VI, DoSort=.true.)

          do nFile=1,4

             if(nFile==1)then
                Coord = 'SM';  NS = 'N'
             elseif(nFile==2)then
                Coord = 'GM';  NS = 'N'
             elseif(nFile==3)then
                Coord = 'SM';  NS = 'S'
             elseif(nFile==4)then
                Coord = 'GM';  NS = 'S'
             end if
             FileName=trim(NamePlotDir)//'IEB-'//trim(Coord)//'-'//trim(NS)
             if(time_accurate)then
                call get_time_string
                FileName = trim(FileName) // "_t" // StringDateOrTime
             end if
             write(FileName,'(a,i7.7,a)') trim(FileName)//"_n", n_step,".dat"

             call open_file(FILE=FileName)
             if(Coord == 'GM')then
                write(UnitTmp_,'(a)')'TITLE="IE B traces (GM Coordinates)"'
             else
                write(UnitTmp_,'(a)')'TITLE="IE B traces (SM Coordinates)"'
             end if
             write(UnitTmp_,'(a)')'VARIABLES="X [R]", "Y [R]", "Z [R]", "Lat", "Lon", "OC"'

             k = 0
             LonOC = -1.
             do iPoint = 1, nPoint
                nLine = PlotVar_VI(0,iPoint)
                if(k /= nLine)then

                   ! finish previous line
                   if(k/=0)then
                      iEnd = iPoint-1
                      MapDown = .false.
                      Xyz_D=PlotVar_VI(2:4,iEnd) * Si2No_V(UnitX_)
                      if(norm2(Xyz_D) < 1.5*rBody) MapDown = .true.
                      j = (1+iEnd-iStart) + (nTP+1)
                      if(MapDown) j = j + (nTP+1)
                      OC = -1; if(MapDown) OC = 2
                      if(MapDown .and. LonOC /= Lon) OC = 1

                      write(UnitTmp_,'(a,2f7.2,a,a,f7.2,a,i8,a)') 'ZONE T="IEB ll=',Lat,Lon,'"', &
                           ', STRANDID=1, SOLUTIONTIME=',Lon, &
                           ', I=',j,', J=1, K=1, ZONETYPE=ORDERED, DATAPACKING=POINT'
                      write(stmp,'(f8.2)')Lat
                      write(UnitTmp_,'(a,a,a)') 'AUXDATA LAT="',trim(adjustl(stmp)),'"'
                      write(stmp,'(f8.2)')Lon
                      write(UnitTmp_,'(a,a,a)') 'AUXDATA LON="',trim(adjustl(stmp)),'"'

                      ! Convert to SMG Cartesian coordinates on the surface of the ionosphere
                      Theta = cDegToRad*(90.0 - Lat)
                      Phi = cDegToRad*Lon
                      call sph_to_xyz(Radius, Theta, Phi, XyzIono_D)
                      Xyz_D=XyzIono_D
                      if(Coord == 'GM') Xyz_D = matmul(Smg2Gsm_DD,Xyz_D)
                      write(UnitTmp_, *) Xyz_D,Lat,Lon,OC
                      do i=1,nTP
                         ! Map from the ionosphere to rBody
                         call map_planet_field(time_simulation, XyzIono_D, &
                              'SMG NORM', &
                              Radius+i*.1, Xyz_D, iHemisphere)
                         if(Coord == 'GM') Xyz_D = matmul(Smg2Gsm_DD,Xyz_D)
                         write(UnitTmp_, *) Xyz_D,Lat,Lon,OC
                      end do
                      do i=iStart,iEnd
                         ! Convert vectors to SM coordinates
                         PlotVar_V = PlotVar_VI(:, i)
                         PlotVar_V(2:4) = matmul(Gsm2Smg_DD,PlotVar_V(2:4))
                         PlotVar_V(2:4) = PlotVar_V(2:4) * Si2No_V(UnitX_)
                         Xyz_D = PlotVar_V(2:4)
                         if(Coord == 'GM') Xyz_D = matmul(Smg2Gsm_DD,Xyz_D)
                         write(UnitTmp_, *) Xyz_D,Lat,Lon,OC
                      end do
                      if(MapDown)then
                         Xyz_D=PlotVar_V(2:4)
                         do i=nTP,0,-1
                            ! Map from rBody to the ionosphere
                            call map_planet_field(time_simulation, Xyz_D, &
                                 'SMG NORM', &
                                 Radius+i*.1, XyzIono_D, iHemisphere)
                            if(Coord == 'GM') &
                                 XyzIono_D = matmul(Smg2Gsm_DD, XyzIono_D)
                            write(UnitTmp_, *) XyzIono_D,Lat,Lon,OC
                         end do
                      end if
                   end if

                   ! start new line counters
                   k=nLine
                   iStart = iPoint
                   iLon=1+((nLine-1)/nLat)
                   iLat=nLine-(iLon-1)*nLat
                   Lon=IE_lon(iLon)
                   Lat=IE_lat(iLat)
                   if(NS == 'N')then
                      if(Lat<0.)k=0
                   else
                      if(Lat>0.)k=0
                   end if
                end if
             end do

             ! finish last line
             if(k/=0)then
                iEnd = nPoint
                MapDown = .false.
                Xyz_D = PlotVar_VI(2:4,iEnd) * Si2No_V(UnitX_)
                if(norm2(Xyz_D) < 1.5*rBody) MapDown = .true.
                j = (1+iEnd-iStart)+(nTP+1)
                if(MapDown) j = j + (nTP+1)
                OC = -1; if(MapDown) OC = 2
                if(MapDown .and. LonOC /= Lon) OC = 1
                !              write(UnitTmp_,'(a,2f7.2,a,a,i8,a)') 'ZONE T="IEB ll=',Lat,Lon,'"', &
                !                   ', I=',j,', J=1, K=1, ZONETYPE=ORDERED, DATAPACKING=POINT'
                !-
                write(UnitTmp_,'(a,2f7.2,a,a,f7.2,a,i8,a)') 'ZONE T="IEB ll=',Lat,Lon,'"', &
                     ', STRANDID=1, SOLUTIONTIME=',Lon, &
                     ', I=',j,', J=1, K=1, ZONETYPE=ORDERED, DATAPACKING=POINT'
                write(stmp,'(f8.2)')Lat
                write(UnitTmp_,'(a,a,a)') 'AUXDATA LAT="', &
                     trim(adjustl(stmp)),'"'
                write(stmp,'(f8.2)')Lon
                write(UnitTmp_,'(a,a,a)') 'AUXDATA LON="', &
                     trim(adjustl(stmp)),'"'

                ! Convert to SMG coordinates on the surface of the ionosphere
                Theta = cDegToRad*(90.0 - Lat)
                Phi = cDegToRad*Lon
                call sph_to_xyz(Radius, Theta, Phi, XyzIono_D)
                Xyz_D=XyzIono_D
                if(Coord == 'GM') Xyz_D = matmul(Smg2Gsm_DD,Xyz_D)
                write(UnitTmp_, *) Xyz_D,Lat,Lon,OC
                do i=1,nTP
                   ! Map from the ionosphere to rBody
                   call map_planet_field(time_simulation, XyzIono_D, &
                        'SMG NORM', &
                        Radius+i*.1, Xyz_D, iHemisphere)
                   if(Coord == 'GM') Xyz_D = matmul(Smg2Gsm_DD,Xyz_D)
                   write(UnitTmp_, *) Xyz_D,Lat,Lon,OC
                end do
                do i=iStart,iEnd
                   ! Convert vectors to SM coordinates
                   PlotVar_V = PlotVar_VI(:, i)
                   PlotVar_V(2:4) = matmul(Gsm2Smg_DD,PlotVar_V(2:4))
                   PlotVar_V(2:4) = PlotVar_V(2:4) * Si2No_V(UnitX_)
                   Xyz_D = PlotVar_V(2:4)
                   if(Coord == 'GM') Xyz_D = matmul(Smg2Gsm_DD,Xyz_D)
                   write(UnitTmp_, *) Xyz_D,Lat,Lon,OC
                end do
                if(MapDown)then
                   Xyz_D=PlotVar_V(2:4)
                   do i=nTP,0,-1
                      ! Map from the ionosphere to rBody
                      call map_planet_field(time_simulation, Xyz_D, &
                           'SMG NORM', &
                           Radius+i*.1, XyzIono_D, iHemisphere)
                      if(Coord == 'GM') XyzIono_D = &
                           matmul(Smg2Gsm_DD, XyzIono_D)
                      write(UnitTmp_, *) XyzIono_D,Lat,Lon,OC
                   end do
                end if
             end if

             call close_file
          end do

          deallocate(PlotVar_VI)
       end if
       call line_clean
    end if

    if(allocated(RayIntegral_VII)) deallocate(RayIntegral_VII)
    if(allocated(RayResult_VII))   deallocate(RayResult_VII)

    if(DoTest)write(*,*)NameSub,': finished'

    call test_stop(NameSub, DoTest)
  end subroutine write_plot_ieb
  !============================================================================

  subroutine trace_field_grid

    ! This parallel ray tracing algorithm was developed at the U.of M.
    ! by G. Toth and D. De Zeeuw. An overview of the scheme can be found in
    !
    ! D. L. De Zeeuw, S. Sazykin, R. A. Wolf, T. I. Gombosi,
    ! A. J. Ridley, G. T\'oth, 2004,
    ! Journal of Geophysical Research, 109, 12219,
    !
    ! Details of the algorithm are to be published later

    use ModMain,     ONLY: n_step, iNewGrid, iNewDecomposition, time_simulation
    use CON_axes,    ONLY: transform_matrix

    ! remember last call and the last grid number
    integer :: n_last=-1, iLastGrid=-1, iLastDecomposition=-1

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'trace_field_grid'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)

    if(DoTest)then
       write(*,*)'GM ray_trace: n_last,n_step         =',n_last,n_step
       write(*,*)'GM ray_trace: iLastGrid,iNewGrid    =',iLastGrid,iNewGrid
       write(*,*)'GM ray_trace: iLastDecomp,iNewDecomp=',&
            iLastDecomposition,iNewDecomposition
    end if

    if(  n_last + DnRaytrace > n_step   .and. &
         iLastGrid          == iNewGrid .and. &
         iLastDecomposition == iNewDecomposition) RETURN

    ! Remember this call
    n_last=n_step; iLastGrid = iNewGrid; iLastDecomposition = iNewDecomposition

    call timing_start(NameSub)

    call init_mod_field_trace

    ! Transformation matrix between the SM(G) and GM coordinates
    if(UseSmg) &
         GmSm_DD = transform_matrix(time_simulation,'SMG',TypeCoordSystem)

    if(UseAccurateTrace .or. .not.IsCartesianGrid)then
       call ray_trace_accurate
    else
       call ray_trace_fast
    end if

    call timing_stop(NameSub)

    call test_stop(NameSub, DoTest)
  end subroutine trace_field_grid
  !============================================================================

  subroutine ray_trace_fast

    use ModMain
    use ModAdvance,  ONLY: Bx_, Bz_, State_VGB
    use ModB0,       ONLY: get_b0
    use ModParallel, ONLY: NOBLK, neiLEV
    use ModGeometry, ONLY: R_BLK, Rmin_BLK, true_cell
    use BATL_lib, ONLY: Xyz_DGB, CellSize_DB
    use ModMpi

    use BATL_lib, ONLY: message_pass_cell, message_pass_node

    ! Iteration parameters
    integer, parameter :: ray_iter_max=150
    integer :: ray_iter
    logical :: done_me, done
    real    :: dray_min

    real :: qqray(3)

    ! Minimum value of B for which integration of field lines makes any sense
    real, parameter :: smallB=1.e-8

    ! True if Rmin_BLK < rTrace
    logical :: check_inside

    ! Face index for the final point of the ray
    integer :: iface

    ! Control volume limits in local coordinates
    real, dimension(3), parameter :: &
         xmin=[   0.5,   0.5,   0.5],&
         xmax=[nI+0.5,nJ+0.5,nK+0.5]

    ! Stride for ix
    integer :: i_stride

    ! Current position of ray in normalized and physical coordinates
    real, dimension(3) :: x, xx

    ! Radial distance and square of it: r2=sum(xx**2)
    real :: r2

    ! Cell indices corresponding to current or final x position
    integer :: i1,j1,k1,i2,j2,k2

    ! Distance between x and i1,j1,k1, and i2,j2,k2
    real :: dx1, dy1, dz1, dx2, dy2, dz2

    ! Weights for surface interpolation
    real :: weight(4)

    ! Cell indices
    integer :: i,j,k

    ! Indices corresponding to the starting point of the ray
    integer :: ix,iy,iz

    ! Current block and direction indices
    integer :: iBlock, iRay

    ! Testing and timing
    logical, parameter :: oktime = .false.
    integer :: loc(3)

    integer :: iError, iError1=-1

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'ray_trace_fast'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)
    if(oktime)call timing_reset('ray_pass',2)

    DoTestRay = .false.

    Bxyz_DGB(:,:,:,:,1:nBlock) = State_VGB(Bx_:Bz_,:,:,:,1:nBlock)
    ! Fill in ghost cells
    call message_pass_cell(3, Bxyz_DGB)

    ! Initial values !!! Maybe LOOPRAY would be better??

    rayface=NORAY
    ray=NORAY

    do iBlock = 1, nBlockMax
       if(Unused_B(iBlock))then
          ! rayface in unused blocks is assigned to NORAY-1.
          rayface(:,:,:,:,:,iBlock)=NORAY-1.
          CYCLE
       end if
       ! Inner points of rayface should never be used, assign them to OPEN
       ! so that checking for blocks with fully open rays becomes easy
       rayface(:,:,2:nI,2:nJ,2:nK,iBlock)=OPENRAY

       ! Set rayface=OPENRAY at outer boundaries
       if(neiLEV(1 ,iBlock)==NOBLK)rayface(:,:,   1,:,:,iBlock)=OPENRAY
       if(neiLEV(2 ,iBlock)==NOBLK)rayface(:,:,nI+1,:,:,iBlock)=OPENRAY
       if(neiLEV(3,iBlock)==NOBLK)rayface(:,:,:,   1,:,iBlock)=OPENRAY
       if(neiLEV(4,iBlock)==NOBLK)rayface(:,:,:,nJ+1,:,iBlock)=OPENRAY
       if(neiLEV(5  ,iBlock)==NOBLK)rayface(:,:,:,:,   1,iBlock)=OPENRAY
       if(neiLEV(6  ,iBlock)==NOBLK)rayface(:,:,:,:,nK+1,iBlock)=OPENRAY

    end do
    if(DoTest)write(*,*)'ray_trace initialized ray and rayface arrays'

    ! Interpolate the B1 field to the nodes
    do iBlock=1, nBlock
       if(Unused_B(iBlock))CYCLE

       do k=1,nK+1; do j=1,nJ+1; do i=1,nI+1;
          bb_x(i,j,k,iBlock)=sum(Bxyz_DGB(x_,i-1:i,j-1:j,k-1:k,iBlock))*0.125
          bb_y(i,j,k,iBlock)=sum(Bxyz_DGB(y_,i-1:i,j-1:j,k-1:k,iBlock))*0.125
          bb_z(i,j,k,iBlock)=sum(Bxyz_DGB(z_,i-1:i,j-1:j,k-1:k,iBlock))*0.125

          ! if(abs(bb_x(i,j,k,iBlock))<cTiny)bb_x(i,j,k,iBlock)=cTiny
          ! if(abs(bb_y(i,j,k,iBlock))<cTiny)bb_y(i,j,k,iBlock)=cTiny
          ! if(abs(bb_z(i,j,k,iBlock))<cTiny)bb_z(i,j,k,iBlock)=cTiny
       end do; end do; end do

    end do ! iBlock

    ! Average node values between shared faces
    call message_pass_node(1,bb_x)
    call message_pass_node(1,bb_y)
    call message_pass_node(1,bb_z)

    if(DoTest)write(*,*)'rayface normalized B'
    if(oktime.and.iProc==0)then
       write(*,'(a)',ADVANCE='NO') 'setup and normalization:'
       call timing_show('ray_trace',1)
    end if

    if(DoTest)write(*,*)'ray_trace starting iterations to obtain rayface'

    ! Iterate
    dray_min=rIonosphere*1.0e-6
    UsePreferredInterpolation = .false.
    ray_iter=0
    do

       if(DoTest)write(*,*)'ray_iter=',ray_iter

       if(ray_iter>=ray_iter_max)EXIT

       ! Store rayface into ray so we can see if there is any change
       ray(:,:,:,:,:,1:nBlockMax) = rayface(:,:,:,:,:,1:nBlockMax)

       do iBlock = 1, nBlock
          if(Unused_B(iBlock))CYCLE

          ! Flag cells inside the ionosphere if necessary
          check_inside=Rmin_BLK(iBlock)<rTrace

          do iz=1,nK+1
             ! Exclude outer boundaries
             if(neiLEV(5,iBlock)==NOBLK.and.iz==   1)CYCLE
             if(neiLEV(6,iBlock)==NOBLK.and.iz==nK+1)CYCLE
             do iy=1,nJ+1
                ! Exclude outer boundaries
                if(neiLEV(3,iBlock)==NOBLK.and.iy==   1)CYCLE
                if(neiLEV(4,iBlock)==NOBLK.and.iy==nJ+1)CYCLE

                ! Exclude inside points
                if(iz>1.and.iz<nK+1.and.iy>1.and.iy<nJ+1)then
                   ! iy and iz are inside, do endpoints only in ix
                   i_stride=nI
                else
                   ! iy or iz are on the surface, do all ix
                   i_stride=1
                end if

                do ix=1,nI+1,i_stride
                   ! Exclude outer boundaries
                   if(neiLEV(1,iBlock)==NOBLK.and.ix==   1)CYCLE
                   if(neiLEV(2,iBlock)==NOBLK.and.ix==nI+1)CYCLE

                   if(DoTestRay)write(*,*)'TESTING RAY: me,iBlock,ix,iy,iz,xx',&
                        iProc,iBlock,ix,iy,iz,&
                        Xyz_DGB(:,ix,iy,iz,iBlock)-0.5*CellSize_DB(:,iBlock)

                   if(ray_iter==0)then
                      do iray=1,2
                         ! Follow ray in direction iray
                         iface = follow_fast(.true.,ix-0.5,iy-0.5,iz-0.5)

                         ! Assign value to rayface
                         call assign_ray(.true.,rayface(:,iray,ix,iy,iz,iBlock))

                         ! Memorize ray integration results
                         rayend_ind(1,iray,ix,iy,iz,iBlock) = iface
                         if(iface>0)then
                            select case(iface)
                            case(1,2)
                               rayend_ind(2:3,iray,ix,iy,iz,iBlock) = [j1,k1]
                            case(3,4)
                               rayend_ind(2:3,iray,ix,iy,iz,iBlock) = [i1,k1]
                            case(6,5)
                               rayend_ind(2:3,iray,ix,iy,iz,iBlock) = [i1,j1]
                            end select
                            rayend_pos(:,iray,ix,iy,iz,iBlock) = weight
                         end if
                      end do

                      ! call print_test(0)

                   else
                      do iray=1,2
                         ! Use stored values
                         iface=rayend_ind(1,iray,ix,iy,iz,iBlock)
                         if(iface>0)then
                            select case(iface)
                            case(1)
                               i1=1; i2=1
                               j1=rayend_ind(2,iray,ix,iy,iz,iBlock); j2=j1+1
                               k1=rayend_ind(3,iray,ix,iy,iz,iBlock); k2=k1+1
                            case(2)
                               i1=nI+1; i2=i1
                               j1=rayend_ind(2,iray,ix,iy,iz,iBlock); j2=j1+1
                               k1=rayend_ind(3,iray,ix,iy,iz,iBlock); k2=k1+1
                            case(3)
                               j1=1; j2=1
                               i1=rayend_ind(2,iray,ix,iy,iz,iBlock); i2=i1+1
                               k1=rayend_ind(3,iray,ix,iy,iz,iBlock); k2=k1+1
                            case(4)
                               j1=nJ+1; j2=nJ+1
                               i1=rayend_ind(2,iray,ix,iy,iz,iBlock); i2=i1+1
                               k1=rayend_ind(3,iray,ix,iy,iz,iBlock); k2=k1+1
                            case(5)
                               k1=1; k2=1
                               i1=rayend_ind(2,iray,ix,iy,iz,iBlock); i2=i1+1
                               j1=rayend_ind(3,iray,ix,iy,iz,iBlock); j2=j1+1
                            case(6)
                               k1=nK+1; k2=k1
                               i1=rayend_ind(2,iray,ix,iy,iz,iBlock); i2=i1+1
                               j1=rayend_ind(3,iray,ix,iy,iz,iBlock); j2=j1+1
                            end select

                            call rayface_interpolate(&
                                 rayface(:,iray,i1:i2,j1:j2,k1:k2,iBlock),&
                                 rayend_pos(:,iray,ix,iy,iz,iBlock),4,&
                                 qqray)

                            rayface(:,iray,ix,iy,iz,iBlock)=qqray

                         end if
                      end do
                   end if ! ray_iter==0
                end do ! ix
             end do ! iy
          end do ! iz
       end do ! iBlock

       ! Exchange rayface information

       call timing_start('ray_pass')
       call ray_pass
       call timing_stop('ray_pass')

       ray_iter = ray_iter + 1

       if(oktime .and. iProc == 0 .and. ray_iter == 1)then
          write(*,'(a)',ADVANCE='NO') 'first iteration:'
          call timing_show('ray_trace',1)
       end if

       ! Check if we are done by checking for significant changes in rayface
       done_me = all(abs(ray(:,:,:,:,:,1:nBlock) - &
            rayface(:,:,:,:,:,1:nBlock)) < dray_min)

       call MPI_allreduce(done_me,done,1,MPI_LOGICAL,MPI_LAND,iComm,iError)

       if(Done)then
          Done_me = .true.
          do iBlock=1,nBlock
             if(Unused_B(iBlock))CYCLE
             Done_me = all(rayface(1,:,:,:,:,iBlock) > LOOPRAY) ! !! NORAY)
             if(.not.Done_me)EXIT
          end do
          call MPI_allreduce(Done_me,Done,1,MPI_LOGICAL,MPI_LAND,iComm,iError)
          if(Done) EXIT
          if(UsePreferredInterpolation)then
             if(iProc==0)call error_report('ray tracing, ray_iter=',&
                  ray_iter+0.0,iError1,.true.)
             EXIT
          endif
          if(DoTest)write(*,*)'Switching to UsePreferredInterpolation=.true.'
          UsePreferredInterpolation = .true.
       end if

    end do ! ray iteration

    ! Check for unassigned rayface in every used block
    if(DoTest)then
       write(*,*)'ray_trace finished after ',ray_iter,' iterations'
       do iBlock = 1, nBlock
          if(Unused_B(iBlock))CYCLE
          do iray=1,2
             if(any(rayface(1,iray,1:nI,1:nJ,1:nK,iBlock)<BODYRAY))then
                loc=minloc(rayface(1,iray,1:nI,1:nJ,1:nK,iBlock))
                write(*,*)'LOOPRAYFACE: iray,me,loc,value,x,y,z=',&
                     iray,iProc,loc,iBlock,&
                     minval(rayface(1,iray,1:nI,1:nJ,1:nK,iBlock)),&
                     Xyz_DGB(:,loc(1),loc(2),loc(3),iBlock)-0.5*CellSize_DB(:,iBlock)
             end if
          end do
       end do
       if(index(StringTest,'ray_debugger')>0)call ray_debugger
    end if

    if(oktime.and.iProc==0)then
       write(*,'(i5,a)') ray_iter,' iterations:'
       call timing_show('ray_trace',1)
       call timing_show('ray_pass',2)
    end if

    if(DoTest)write(*,*)'ray_trace starting cell center assignments'

    ! Assign face ray values to cell centers
    do iBlock = 1, nBlock

       if(Unused_B(iBlock))CYCLE

       ! Set flag if checking on the ionosphere is necessary
       check_inside=Rmin_BLK(iBlock)<rTrace

       do iray=1,2
          ! Some optimization for fully open blocks
          if(.not.check_inside)then
             if(all(rayface(1,iray,:,:,:,iBlock)==OPENRAY))then
                ray(:,iray,:,:,:,iBlock)=OPENRAY
                CYCLE
             end if
          end if

          do iz=1,nK; do iy=1,nJ; do ix=1,nI

             ! Short cuts for inner and false cells
             if(R_BLK(ix,iy,iz,iBlock) < rInner .or. &
                  .not.true_cell(ix,iy,iz,iBlock))then
                ray(:,iray,ix,iy,iz,iBlock)=BODYRAY
                if(DoTestRay)write(*,*)'BODYRAY'
                CYCLE
             end if

             if(DoTestRay)write(*,*)'calling follow_fast'

             ! Follow ray in direction iray
             iface=follow_fast(.false.,real(ix),real(iy),real(iz))

             if(DoTestRay)write(*,*)'calling assign_ray'

             ! Assign value to ray
             call assign_ray(.false.,ray(:,iray,ix,iy,iz,iBlock))

          end do; end do; end do ! ix, iy, iz
       end do ! iray
    end do ! iBlock

    if(DoTest)write(*,*)'ray_trace finished with ray=',&
         ray(:,:,iTest,jTest,kTest,iBlockTest)

    if(DoTest)then
       ! Check for unassigned cell centers
       do iBlock = 1, nBlock
          if(Unused_B(iBlock))CYCLE
          do iray=1,2
             if(any(ray(1,iray,1:nI,1:nJ,1:nK,iBlock)<BODYRAY))then
                loc=minloc(ray(1,iray,1:nI,1:nJ,1:nK,iBlock))
                write(*,*)'LOOPRAY: iray,me,loc,value,x,y,z=',&
                     iray,iProc,loc,iBlock,&
                     minval(ray(1,iray,1:nI,1:nJ,1:nK,iBlock)),&
                     Xyz_DGB(:,loc(1),loc(2),loc(3),iBlock)
             end if
          end do
       end do
    end if

    if(DoTest)write(*,*)'ray_trace starting conversion to lat/lon'

    ! Convert x, y, z to latitude and longitude, and status
    do iBlock = 1, nBlock
       if(Unused_B(iBlock)) CYCLE
       do k=1,nK; do j=1,nJ; do i=1,nI
          call xyz_to_latlonstatus(ray(:,:,i,j,k,iBlock))
       end do; end do; end do
    end do

    if(oktime.and.iProc==0)then
       write(*,'(a)',ADVANCE='NO') 'Total ray tracing time:'
       call timing_show('ray_trace',1)
    end if
    call barrier_mpi
    if(DoTest)write(*,*)'ray_trace completed.'

    call test_stop(NameSub, DoTest)
  contains
    !==========================================================================

    subroutine ray_debugger

      ! Debug rayface values

      integer :: iPos_D(3),jX,kX,jY,kY,jZ,kZ

      !------------------------------------------------------------------------
      do
         ! Read position
         write(*,'(a)',ADVANCE='NO')'Rayface x,y,z,iRay:'
         read(*,*) xTest,yTest,zTest,iRay
         if(xTest==0.0.and.yTest==0.0.and.zTest==0.0) EXIT

         ! Find position
         do iBlock = 1, nBlock
            if(Unused_B(iBlock))CYCLE
            do ix=1,nI+1
               if(abs(Xyz_DGB(x_,ix,1,1,iBlock)-0.5*CellSize_DB(x_,iBlock)-xTest)>0.01)CYCLE
               do iy=1,nJ+1
                  if(abs(Xyz_DGB(y_,1,iy,1,iBlock)-0.5*CellSize_DB(y_,iBlock)-yTest)>0.01)CYCLE
                  do iz=1,nK+1
                     if(abs(Xyz_DGB(z_,1,1,iz,iBlock)-0.5*CellSize_DB(z_,iBlock)-zTest)>0.01)&
                          CYCLE

                     ! Print information

                     write(*,*)'iProc,iBlock,ix,iy,iz=',iProc,iBlock,ix,iy,iz
                     write(*,*)' x,y,Xyz_DGB(z_,1,1,1),dx=',&
                          Xyz_DGB(:,1,1,1,iBlock), CellSize_DB(x_,iBlock)

                     iPos_D=rayend_ind(:,iray,ix,iy,iz,iBlock)
                     if(iPos_D(1)>0)then
                        write(*,*)' rayface   =',rayface(:,iray,ix,iy,iz,iBlock)
                        write(*,*)' rayend_ind=',rayend_ind(:,iray,ix,iy,iz,iBlock)
                        write(*,*)' rayend_pos=',rayend_pos(:,iray,ix,iy,iz,iBlock)
                        select case(iPos_D(1))
                        case(1,2)
                           jX = 1+nI*(iPos_D(1)-1); jY = iPos_D(2); jZ = iPos_D(3)
                           kX = jX; kY = jY+1; kZ = jZ+1
                        case(3,4)
                           jY = 1+nJ*(iPos_D(1)-3); jX = iPos_D(2); jZ = iPos_D(3)
                           kX = jX+1; kY = jY; kZ = jZ+1
                        case(5,6)
                           jZ = 1+nK*(iPos_D(1)-5); jX = iPos_D(2); jY = iPos_D(3)
                           kX = jX+1; kY = jY+1; kZ = jZ
                        end select
                        write(*,*)' rayface(1,end)=',&
                             rayface(1,iray,jX:kX,jY:kY,jZ:kZ,iBlock)
                        write(*,*)' jX,kX,jY,kY,jZ,kZ=',jX,kX,jY,kY,jZ,kZ
                        write(*,*)' x,y,z(End)=',&
                             Xyz_DGB(:,jx,jy,jz,iBlock)-0.5*CellSize_DB(:,iBlock)
                     else
                        write(*,*)' rayend_ind=',iPos_D
                     end if
                  end do
               end do
            end do
         end do
      end do

    end subroutine ray_debugger
    !==========================================================================

    subroutine print_test(inInt)
      integer, intent(in) :: inInt

      !------------------------------------------------------------------------
      if(  all(abs( [4.0,6.0,-6.5] &
           - Xyz_DGB(:,ix,iy,iz,iBlock) + 0.5*CellSize_DB(:,iBlock)) < 0.01))then
         write(*,'(i3,a,i3,a,i4,a,3i2,a,3f9.2,a,6i3,a,6f10.3)') inInt, &
              ' DEBUG LOOPRAYFACE: PE=',iProc,' BLK=',iBlock,' loc=',ix,iy,iz,&
              ' x,y,z=',Xyz_DGB(:,ix,iy,iz,iBlock)-0.5*CellSize_DB(:,iBlock), &
              '   rayend_ind=',rayend_ind(:,:,ix,iy,iz,iBlock), &
              '   rayface=',rayface(:,:,ix,iy,iz,iBlock)
      end if
    end subroutine print_test
    !==========================================================================

    function follow_fast(surface_point,x_0,y_0,z_0) result(qface)

      ! Follow ray starting at initial position x_0,y_0,z_0 in direction iray
      ! until we hit the wall of the control volume or the ionosphere.
      ! Return 1,2,3,4,5,6 if the ray hit the east,west,south,north,bot,top walls
      ! Return ray_iono_   if the ray hit the ionosphere
      ! Return ray_loop_   if the ray did not hit anything
      ! Return ray_out_    if the ray goes out of the box immediately
      ! Return ray_body_   if the ray goes into or is inside a body

      ! Arguments

      logical, intent(in):: surface_point
      real, intent(in)   :: x_0,y_0,z_0

      ! Result

      integer :: qface

      ! Local variables

      ! Initial and mid point coordinates and bb field
      real, dimension(3) :: x_ini, x_mid, b_ini, b_mid, xx_ini
      real :: r, r_ini

      ! dx is the difference between 1st and 2nd order RK to estimate accuracy
      ! dx_opt is the required accuracy, dx_rel=dx/dx_opt
      real :: dx_rel, dx_opt

      ! Ray length, max, step size, limits, next step size for backup to surface
      real :: l, lmax, dl, dl_max, dl_min, dl_next, dl_tiny, dl_back

      ! counter for ray integration
      integer :: nsegment

      ! Counter for entering follow_fast_iono
      integer :: n_iono

      !------------------------------------------------------------------------

      if(DoTestRay)&
           write(*,*)'follow_fast: me,iBlock,surface_point,x_0,y_0,z_0,iray=',&
           iProc,iBlock,surface_point,x_0,y_0,z_0,iray

      ! Step size limits
      dl_max=1.0
      dl_min=0.05
      dl_tiny=1.e-6

      ! Initial value
      dl_next=sign(dl_max,1.5-iray)

      ! Accuracy in terms of x in normalized coordinates
      dx_opt=0.01

      ! Length and maximum length of ray within control volume
      l=0
      lmax=10*maxval(xmax-xmin)
      nsegment=0
      n_iono=0

      ! Initial position
      x(1)=x_0
      x(2)=y_0
      x(3)=z_0

      ! Integration loop
      do
         ! Check if we are inside the ionosphere
         if(check_inside)then
            ! Convert x to real coordinates xx

            xx = Xyz_DGB(:,1,1,1,iBlock) + CellSize_DB(:,iBlock)*(x - 1.)

            r2 = sum(xx**2)

            if(r2 <= rTrace2)then

               if(DoTestRay)write(*,*)&
                    'Inside rTrace at me,iBlock,nsegment,x,xx=',&
                    iProc,iBlock,nsegment,x,xx

               if(NameVectorField /= 'B' .or. r2 <= rInner2)then
                  if(nsegment==0)then
                     qface = ray_body_
                     if(DoTestRay)write(*,*)&
                          'Initial point inside rInner at me,iBlock,xx=',&
                          iProc,iBlock,xx
                  else
                     r = sqrt(r2)
                     xx_ini = Xyz_DGB(:,1,1,1,iBlock) + &
                        CellSize_DB(:,iBlock)*(x_ini-1.)

                     r_ini = norm2(xx_ini)
                     ! Interpolate to the surface linearly along last segment
                     xx = (xx*(r_ini-rInner)+xx_ini*(rInner-r)) &
                          /(r_ini-r)
                     ! Normalize xx in radial direction
                     xx = rInner*xx/norm2(xx)
                     x = xx
                     qface = ray_iono_
                  end if
                  EXIT
               end if

               ! Try mapping down to rIonosphere if we haven't tried yet
               if(n_iono<1)then
                  if(follow_fast_iono())then
                     x=xx
                     qface=ray_iono_
                     EXIT
                  else
                     ! We did not hit the surface of the ionosphere
                     ! continue the integration
                     n_iono=n_iono+1
                  end if
               end if
            end if
         end if

         ! Integrate with 2nd order scheme
         dl=dl_next
         x_ini=x

         ! Half step
         call interpolate_bb_node(x_ini,b_ini)
         x_mid=x_ini+0.5*dl*b_ini

         ! Check if the ray is pointing outwards
         if(nsegment==0.and.surface_point)then
            if(DoTestRay)write(*,*)'me,iBlock,x_ini,b_ini=', &
                 iProc,iBlock,x_ini,b_ini

            if(any(x_mid<xmin) .or. any(x_mid>xmax))then
               qface=ray_out_
               if(DoTestRay)then
                  write(*,*)'me,iBlock,x_mid=',iProc,iBlock,x_mid
                  write(*,*)'ray points outwards: me,iBlock,dl,xx=', &
                       iProc,iBlock,dl,&
                       Xyz_DGB(:,1,1,1,iBlock) + CellSize_DB(:,iBlock)*(x_mid - 1.)
               end if
               RETURN
            end if
         end if

         do
            ! Full step
            call interpolate_bb_node(x_mid,b_mid)

            ! Calculate the difference between 1st and 2nd order integration
            ! and take ratio relative to dx_opt
            dx_rel=abs(dl)*maxval(abs(b_mid-b_ini))/dx_opt

            if(DoTestRay.and.okdebug)&
                 write(*,*)'me,iBlock,x_mid,b_mid,dx_rel=', &
                 iProc,iBlock,x_mid,b_mid,dx_rel

            ! Make sure that dl does not change more than a factor of 2 or 0.5
            dx_rel=max(0.5,min(2.,dx_rel))

            if(dx_rel>1.)then
               ! Not accurate enough, decrease dl if possible

               if(abs(dl)<=dl_min+dl_tiny)then
                  ! Cannot reduce dl further
                  dl_next=dl
                  EXIT
               end if

               dl = sign(max(dl_min,abs(dl)/(dx_rel+0.001)),dl)

               ! New mid point using the reduced dl
               x_mid=x_ini+0.5*dl*b_ini

               if(DoTestRay.and.okdebug)&
                    write(*,*)'new decreased dl: me,iBlock,dl=', &
                    iProc,iBlock,dl
            else
               ! Too accurate, increase dl if possible
               if(abs(dl)<dl_max-dl_tiny)then

                  dl_next = sign(min(dl_max,abs(dl)/sqrt(dx_rel)),dl)

                  if(DoTestRay.and.okdebug)&
                       write(*,*)'new increased dl_next: me,iBlock,dl_next=', &
                       iProc,iBlock,dl_next

               end if

               EXIT
            end if
         end do

         x=x_ini+b_mid*dl

         nsegment=nsegment+1
         l=l+abs(dl)

         if(DoTestRay.and.okdebug)&
              write(*,*)'me,iBlock,nsegment,l,x=', &
              iProc,iBlock,nsegment,l,x

         ! Check if the ray hit the wall of the control volume
         if(any(x<xmin) .or. any(x>xmax))then

            ! Hit the wall, backup so that x is almost exactly on the wall
            ! just a little bit outside. Only if nsegment is more than 1!
            if(nsegment > 1)then
               dl_back = dl*maxval(max(xmin-x,x-xmax)/(abs(x-x_ini)+dl_tiny))
               x=x-dl_back*b_mid
            end if

            ! Find out which wall the ray hit
            if    (x(1)<=xmin(1))then; qface=1
            elseif(x(2)<=xmin(2))then; qface=3
            elseif(x(3)<=xmin(3))then; qface=5
            elseif(x(1)>=xmax(1))then; qface=2
            elseif(x(2)>=xmax(2))then; qface=4
            elseif(x(3)>=xmax(3))then; qface=6
            else
               write(*,*)'Error in follow_fast for me,iBlock,ix,iy,iz=',&
                    iProc,iBlock,ix,iy,iz
               write(*,*)'nsegment,x,dl,dl_back=',nsegment,x,dl,dl_back
               call stop_mpi('GM_follow_fast: Hit wall but which one?')
            end if

            ! Make sure that x is not outside the control volume
            x=max(xmin+dl_tiny,x)
            x=min(xmax-dl_tiny,x)

            EXIT
         end if

         ! Check if we have integrated for too long
         if(l>lmax)then
            ! Seems to be a closed loop within a block
            if(DoTestRay)then
               write(*,*)'CLOSED LOOP at me,iBlock,ix,iy,iz,x,xx=',&
                    iProc,iBlock,ix,iy,iz,x,&
                    Xyz_DGB(:,1,1,1,iBlock) + CellSize_DB(:,iBlock)*(x - 1.)
            end if

            qface=ray_loop_
            EXIT
         end if

      end do

      if(DoTestRay)write(*,*)'Finished follow_fast at me,iBlock,nsegment,qface,x,xx=',&
           iProc,iBlock,nsegment,qface,x,&
           Xyz_DGB(:,1,1,1,iBlock) + CellSize_DB(:,iBlock)*(x - 1.)

    end function follow_fast
    !==========================================================================

    subroutine interpolate_bb(qx,qb)

      ! Obtain normalized bb field at normalized location qx and put it into qb

      real, intent(in) :: qx(3)
      real, intent(out):: qb(3)

      ! Determine cell indices corresponding to location qx

      !------------------------------------------------------------------------
      i1=floor(qx(1)); i2=i1+1
      j1=floor(qx(2)); j2=j1+1
      k1=floor(qx(3)); k2=k1+1

      if(i1<-1.or.i2>nI+2.or.j1<-1.or.j2>nJ+2.or.k1<-1.or.k2>nK+2)then
         write(*,*)'interpolate_bb: iProc, iBlock, qx=',iProc,iBlock, qx
         call stop_mpi('ERROR in interpolate_bb: location out of bounds')
      endif

      ! Distance relative to the cell centers

      dx1=qx(1)-i1; dx2=1.-dx1
      dy1=qx(2)-j1; dy2=1.-dy1
      dz1=qx(3)-k1; dz2=1.-dz1

      qb(1)=interpolate_bb1_node(bb_x)
      qb(2)=interpolate_bb1_node(bb_y)
      qb(3)=interpolate_bb1_node(bb_z)

    end subroutine interpolate_bb
    !==========================================================================

    real function interpolate_bb1(qbb)

      real, intent(in):: qbb(MinI:MaxI,MinJ:MaxJ,MinK:MaxK,MaxBlock)
      !------------------------------------------------------------------------

      ! Bilinear interpolation in 3D

      interpolate_bb1=&
           dx1*(   dy1*(   dz1*qbb(i2,j2,k2,iBlock)+&
           dz2*qbb(i2,j2,k1,iBlock))+&
           dy2*(   dz1*qbb(i2,j1,k2,iBlock)+&
           dz2*qbb(i2,j1,k1,iBlock)))+&
           dx2*(   dy1*(   dz1*qbb(i1,j2,k2,iBlock)+&
           dz2*qbb(i1,j2,k1,iBlock))+&
           dy2*(   dz1*qbb(i1,j1,k2,iBlock)+&
           dz2*qbb(i1,j1,k1,iBlock)))

    end function interpolate_bb1
    !==========================================================================
    function interpolate_bb_v(nVar,qbb)
      integer, intent(in):: nVar
      real,    intent(in):: qbb(nVar,MinI:MaxI,MinJ:MaxJ,MinK:MaxK,MaxBlock)
      real:: interpolate_bb_v(nVar)
      !------------------------------------------------------------------------

      ! Bilinear interpolation in 3D

      interpolate_bb_v=&
           dx1*(   dy1*(   dz1*qbb(:,i2,j2,k2,iBlock)+&
           dz2*qbb(:,i2,j2,k1,iBlock))+&
           dy2*(   dz1*qbb(:,i2,j1,k2,iBlock)+&
           dz2*qbb(:,i2,j1,k1,iBlock)))+&
           dx2*(   dy1*(   dz1*qbb(:,i1,j2,k2,iBlock)+&
           dz2*qbb(:,i1,j2,k1,iBlock))+&
           dy2*(   dz1*qbb(:,i1,j1,k2,iBlock)+&
           dz2*qbb(:,i1,j1,k1,iBlock)))

    end function interpolate_bb_v
    !==========================================================================

    subroutine interpolate_bb_node(qx,qb)

      ! Obtain normalized bb field at normalized location qx and put it into qb
      ! Interpolate B1 from nodes, take B0 from analytic expression

      real, intent(in) :: qx(3)
      real, intent(out):: qb(3)
      real :: qbD

      !------------------------------------------------------------------------

      ! Determine cell indices corresponding to location qx

      i1 = floor(qx(1)+0.5); i2 = i1 + 1
      j1 = floor(qx(2)+0.5); j2 = j1 + 1
      k1 = floor(qx(3)+0.5); k2 = k1 + 1

      if(i1<0.or.i2>nI+2.or.j1<0.or.j2>nJ+2.or.k1<0.or.k2>nK+2)then
         write(*,*)'interpolate_bb_node: iProc, iBlock, qx=',iProc,iBlock, qx
         call stop_mpi('ERROR in interpolate_bb_node: location out of bounds')
      endif

      ! Get B0 values for location

      xx = Xyz_DGB(:,1,1,1,iBlock) + CellSize_DB(:,iBlock)*(qx - 1.)

      if(UseB0)then
         call get_b0(xx, qb)
      else
         qb = 0.00
      end if

      ! Make sure that the interpolation uses inside indexes only

      i1 = max(1,i1)   ; j1 = max(1,j1);    k1 = max(1,k1)
      i2 = min(nI+1,i2); j2 = min(nJ+1,j2); k2 = min(nK+1,k2)

      ! Distances relative to the nodes

      dx1 = qx(1)+0.5-i1; dx2 = 1.-dx1
      dy1 = qx(2)+0.5-j1; dy2 = 1.-dy1
      dz1 = qx(3)+0.5-k1; dz2 = 1.-dz1

      ! Add in node interpolated B1 values and take aspect ratios into account

      qb(1) = (qb(1)+interpolate_bb1_node(bb_x))/CellSize_DB(x_,iBlock)
      qb(2) = (qb(2)+interpolate_bb1_node(bb_y))/CellSize_DB(y_,iBlock)
      qb(3) = (qb(3)+interpolate_bb1_node(bb_z))/CellSize_DB(z_,iBlock)

      ! Normalize
      qbD = norm2(qb)

      if(qbD > smallB)then
         qb = qb/qbD
      else
         qb = 0.
      end if

    end subroutine interpolate_bb_node
    !==========================================================================

    real function interpolate_bb1_node(qbb)

      real, intent(in):: qbb(1:nI+1,1:nJ+1,1:nK+1,MaxBlock)
      !------------------------------------------------------------------------

      ! Bilinear interpolation in 3D

      interpolate_bb1_node=&
           dx1*(   dy1*(   dz1*qbb(i2,j2,k2,iBlock)+&
           dz2*qbb(i2,j2,k1,iBlock))+&
           dy2*(   dz1*qbb(i2,j1,k2,iBlock)+&
           dz2*qbb(i2,j1,k1,iBlock)))+&
           dx2*(   dy1*(   dz1*qbb(i1,j2,k2,iBlock)+&
           dz2*qbb(i1,j2,k1,iBlock))+&
           dy2*(   dz1*qbb(i1,j1,k2,iBlock)+&
           dz2*qbb(i1,j1,k1,iBlock)))

    end function interpolate_bb1_node
    !==========================================================================

    logical function follow_fast_iono()

      ! Follow ray inside ionosphere starting from xx which is given in
      ! real coordinates and use analytic mapping.
      ! On return xx contains the final coordinates.
      ! Return true if it was successfully integrated down to rIonosphere,
      ! return false if the ray exited rTrace or too many integration
      ! steps were done

      use ModMain,     ONLY: Time_Simulation
      use ModPhysics,  ONLY: DipoleStrengthSi ! only the sign of dipole is needed
      use CON_planet_field, ONLY: map_planet_field

      integer :: iHemisphere
      real    :: x_D(3)

      !------------------------------------------------------------------------
      call map_planet_field(Time_Simulation, xx, TypeCoordSystem//' NORM', &
           rIonosphere, x_D, iHemisphere)

      if(iHemisphere==0)then
         write(*,*)'iHemisphere==0 for xx=',xx
         write(*,*)'iBlock, iRay=',iBlock,iRay
         call stop_mpi('ERROR in follow_fast_iono')
      end if

      if(iHemisphere*DipoleStrengthSi*sign(1.0,1.5-iray) < 0.0)then
         xx = x_D
         follow_fast_iono = .true.
      else
         follow_fast_iono = .false.
      end if

    end function follow_fast_iono
    !==========================================================================

    subroutine evaluate_bb(qx,qb)

      ! Obtain normalized bb field at true location qx and put it into qb

      real, intent(in) :: qx(3)
      real, intent(out):: qb(3)

      ! Get B0

      !------------------------------------------------------------------------
      call get_b0(qx, qb)

      ! Take aspect ratio of cells into account
      qb = qb / CellSize_DB(:,iBlock)

      if(sum(abs(qb)) == 0.0)then
         write(*,*)'GM_ERROR in ray_trace::evaluate_bb: qb==0 at qx=',qx
         call stop_mpi('GM_ERROR in ray_trace::evaluate_bb')
      end if

      ! Normalize
      qb = qb/norm2(qb)

    end subroutine evaluate_bb
    !==========================================================================

    subroutine assign_ray(surface_point,qray)

      ! Assign value to qray(3) based on ray intersection
      ! given by the global variables iface and position x(3)
      !
      ! iray is 1 if ray points in positive B direction and 2 otherwise
      !
      ! surface_point is true if the ray was started from the block face
      ! and false if it was started from a cell center

      logical, intent(in) :: surface_point
      ! Called with a segment of rayface array and it is used here to get qray
      real, intent(inout) :: qray(3)

      ! Temporary variable
      real :: qqray(3)

      ! Local variables

      ! Distances between x and the 4 grid points used for interpolation
      real :: d1,e1,d2,e2

      !------------------------------------------------------------------------

      if(DoTestRay)write(*,*)&
           'assign_ray starting with surface_point, iray, iface=',&
           surface_point,iray,iface

      select case(iface)
      case(ray_out_)
         ! The ray points outward
         qray=OUTRAY
         if(DoTestRay)write(*,*)'assign_ray finished with qray=OUTRAY'
         RETURN
      case(ray_loop_)
         ! The ray did not hit the wall of the block
         qray=LOOPRAY
         if(DoTestRay)write(*,*)'assign_ray finished with qray=LOOPRAY'
         RETURN
      case(ray_body_)
         ! The ray hit a body
         qray=BODYRAY
         if(DoTestRay)write(*,*)'assign_ray finished with qray=BODYRAY'
         RETURN
      case(ray_iono_)
         ! The ray hit the ionosphere
         qray=x
         if(DoTestRay)write(*,*)&
              'assign_ray finished with qray on ionosphere, qray=',qray
         RETURN
      case(1,2)
         if(iface==1)then
            i1=1
         else
            i1=nI+1
         endif
         i2=i1
         j1=floor(x(2)-xmin(2))+1; j2=j1+1
         k1=floor(x(3)-xmin(3))+1; k2=k1+1
         d1=x(2)-j1+0.5
         e1=x(3)-k1+0.5

      case(3,4)
         if(iface==3)then
            j1=1
         else
            j1=nJ+1
         endif
         j2=j1
         i1=floor(x(1)-xmin(1))+1; i2=i1+1
         k1=floor(x(3)-xmin(3))+1; k2=k1+1
         d1=x(1)-i1+0.5
         e1=x(3)-k1+0.5

      case(5,6)
         ! The ray hit the bot or top wall
         if(iface==5)then
            k1=1
         else
            k1=nK+1
         endif
         k2=k1
         i1=floor(x(1)-xmin(1))+1; i2=i1+1
         j1=floor(x(2)-xmin(2))+1; j2=j1+1
         d1=x(1)-i1+0.5
         e1=x(2)-j1+0.5

      case default
         write(*,*)'Impossible value for iface=',iface,' at ix,iy,iz,iBlock=',&
              ix,iy,iz,iBlock
         call stop_mpi('assign_ray')
      end select

      ! Calculate bilinear interpolation weights
      d2=1.-d1; e2=1.-e1
      weight(1)=d2*e2
      weight(2)=d1*e2
      weight(3)=d2*e1
      weight(4)=d1*e1

      if(DoTestRay)write(*,*)'weight=',weight

      ! Exclude the starting point if its among the 4 interpolated cells
      if(surface_point)then
         if((ix==i1.or.ix==i2).and.(iy==j1.or.iy==j2).and.(iz==k1.or.iz==k2))then
            select case(iface)
            case(1,2)
               weight(iy-j1+2*(iz-k1)+1)=0.
            case(3,4)
               weight(ix-i1+2*(iz-k1)+1)=0.
            case(5,6)
               weight(ix-i1+2*(iy-j1)+1)=0.
            end select
            ! Normalize weights
            weight=weight/sum(weight)
            if(DoTestRay)write(*,*)'Excluded point: me,iBlock,ix,iy,iz,weight=',&
                 iProc,iBlock,ix,iy,iz,weight
         end if
      end if

      if(DoTestRay)&
           write(*,*)'i1,j1,k1,i2,j2,k2,d1,e1=',i1,j1,k1,i2,j2,k2,d1,e1

      call rayface_interpolate(rayface(:,iray,i1:i2,j1:j2,k1:k2,iBlock),&
           weight,4,qqray)

      qray = qqray

      if(DoTestRay)write(*,*)'assign_ray finished qray=',qray

    end subroutine assign_ray
    !==========================================================================

  end subroutine ray_trace_fast
  !============================================================================

  subroutine rayface_interpolate(qrayface,weight,nvalue,qray)

    ! Collect weights for qrayface values that differ less than dray_max
    ! and interpolate the values corresponding to the largest weight
    ! The result is returned in qray.
    ! Note that qray and qrayface may overlap, so their intent must be inout!

    integer, intent(in)    :: nvalue
    real,    intent(inout) :: qrayface(3,nvalue)
    real,    intent(in)    :: weight(nvalue)
    real,    intent(inout) :: qray(3)

    ! Local variables

    ! Cumulated weights corresponding to various kinds of qrayface values
    real :: qweight(4), weight_sum(4), ray_first(3,4), ray_sum(3,4)

    ! Difference between qrayface values, maximum for interpolation
    real :: dray, dray_max, ValueMax

    ! Number and indices of (cummulated) qrayface values, max location
    integer :: n, i, j, loc(1)

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'rayface_interpolate'
    !--------------------------------------------------------------------------
    ! call test_start(NameSub, DoTest)

    if(.not.UsePreferredInterpolation .and. &
         maxval(weight)-minval(weight) > 0.0001)then
       qweight(1:nvalue)=weight
    else
       ValueMax = maxval(qrayface(1,:), MASK = weight > 0.0) ! 0.01)

       if(ValueMax < CLOSEDRAY)then
          !     if(ValueMax < OPENRAY-0.01)then
          qray = ValueMax
          RETURN
       end if

       where(qrayface(1,:)>=OPENRAY-0.01)
          qweight(1:nvalue)=weight
       elsewhere
          qweight(1:nvalue)=0.
       endwhere
    end if

    if(DoTestRay)then
       write(*,*)'rayface_interpolate'
       write(*,*)'qrayface(1,:)=',qrayface(1,:)
       write(*,*)'qrayface(2,:)=',qrayface(2,:)
       write(*,*)'qrayface(3,:)=',qrayface(3,:)
       write(*,*)'weight       =',weight
       write(*,*)'qweight      =',qweight
    end if

    ! Short cuts
    if(all(qrayface(1,:)==OPENRAY))then
       ! all surrounding rays are open
       qray=OPENRAY
       if(DoTestRay)write(*,*)'rayface_interpolate finished with fully OPENRAY'
       RETURN
    end if

    if(all(qrayface(1,:)==NORAY))then
       ! all surrounding rays are unknown
       qray=NORAY
       if(DoTestRay)write(*,*)'rayface_interpolate finished with fully NORAY'
       RETURN
    end if

    dray_max=0.2*rIonosphere
    n=0
    do j=1,nvalue
       i=1
       do
          if(i>n)then
             ! New type of ray
             n=i
             ray_first(:,i)=qrayface(:,j)
             weight_sum(i) =qweight(j)
             if(ray_first(1,i)>CLOSEDRAY)&
                  ray_sum(:,i)=qweight(j)*qrayface(:,j)
             EXIT
          end if

          ! Calculate difference between qrayface(:,j) and ray_first(:,i)
          dray=sum(abs(qrayface(:,j)-ray_first(:,i)))

          if(dray<dray_max)then
             ! Same type of ray, cummulate it

             weight_sum(i)=weight_sum(i)+qweight(j)
             if(ray_first(1,i)>CLOSEDRAY)&
                  ray_sum(:,i)=ray_sum(:,i)+qweight(j)*qrayface(:,j)
             EXIT
          end if
          ! Try next type
          i=i+1

          if(i>nvalue)call stop_mpi(&
               'Impossible value for i in rayface_interpolate')
       end do ! i
    end do ! j

    if(n==1)then
       ! Only one type of ray is interpolated
       if(ray_first(1,1)>CLOSEDRAY)then
          ! get result (weight_sum can be less than 1! )
          qray=ray_sum(:,1)/weight_sum(1)
       else
          ! identical rayface values, no need to average
          qray=ray_first(:,1)
       end if
    else
       ! Take the values corresponding to the largest cummulated weight
       loc=maxloc(weight_sum(1:n))
       i=loc(1)
       if(ray_first(1,i)>CLOSEDRAY)then
          ! take average
          qray=ray_sum(:,i)/weight_sum(i)
       else
          ! identical rayface values, no need to average
          qray=ray_first(:,i)
       end if
    end if

    if(DoTestRay)then
       write(*,*)'rayface_interpolate: weight_sum=',weight_sum(1:n)
       write(*,*)'rayface_interpolate finished with qray=',qray
    end if

    ! call test_stop(NameSub, DoTest)
  end subroutine rayface_interpolate
  !============================================================================
  subroutine ray_pass

    !  call ray_pass_new
    !--------------------------------------------------------------------------
    call ray_pass_old

  end subroutine ray_pass
  !============================================================================
  subroutine ray_pass_new

    use ModMain, ONLY : nBlock,Unused_B
    use ModParallel, ONLY : neiLEV
    use BATL_lib, ONLY: message_pass_node

    integer :: iBlock, iface

    !  do i=1,3; do j=1,2

    ! !     call pass_and_max_nodes(.false.,rayface(i,j,:,:,:,:))
    ! !     call pass_and_max_nodes(.true.,rayface(i,j,:,:,:,:))
    !  end do; end do

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'ray_pass_new'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)
    call message_pass_node(6, RayFace, 'max')

    do iBlock=1,nBlock
       if(Unused_B(iBlock))CYCLE
       do iface=1,6
          if(neiLEV(iface,iBlock)==1)call prolong_ray_after_pass(iface,iBlock)
       end do
    end do

    call test_stop(NameSub, DoTest)
  end subroutine ray_pass_new
  !============================================================================

  subroutine prolong_ray_after_pass(iface,iBlock)

    ! For faces that are shared with a coarser neighbor, interpolate
    ! for all points which are not coinciding and where the ray is going out.
    !
    ! a at odd  j and even k requires interpolation in direction k
    ! b at even j and odd  k requires interpolation in direction j
    ! c at even j and even k requires interpolation in both directions

    ! (1,5)           (5,5)
    !   O-- b --O-- b --O
    !   |   |   |   |   |
    !   |   |   |   |   |
    !   a - c - a - c - a
    !   |   |   |   |   |
    !   |   |   |   |   |
    !   O-- b --O-- b --O
    !   |   |   |   |   |
    !   |   |   |   |   |
    !   a - c - a - c - a
    !   |   |   |   |   |
    !   |   |   |   |   |
    !   O-- b --O-- b --O
    ! (1,1)           (5,1)

    integer, intent(in) :: iface,iBlock
    integer :: iray
    integer :: j, k, nFaceJ, nFaceK
    integer, parameter :: nFaceMax=max(nI+1,nJ+1,nK+1)
    real    :: qrayface(3,2,nFaceMax,nFaceMax)
    integer :: qrayend_ind(2,nFaceMax,nFaceMax)

    ! Interpolation weights
    real, dimension(4), parameter:: weight4=0.25
    real, dimension(2), parameter:: weight2=0.5

    ! Extract qrayface and qrayend_ind for the appropriate face
    ! NOTE: qrayend_ind assignment split to two lines to avoid reshaping compiler bug!
    logical:: DoTest
    character(len=*), parameter:: NameSub = 'prolong_ray_after_pass'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest, iBlock)
    select case(iface)
    case(1)
       nFaceJ=nJ+1; nFaceK=nK+1
       qrayface( :,:,1:nFaceJ,1:nFaceK)=rayface(   :,:,1,1:nJ+1,1:nK+1,iBlock)
       qrayend_ind(1,1:nFaceJ,1:nFaceK)=rayend_ind(1,1,1,1:nJ+1,1:nK+1,iBlock)
       qrayend_ind(2,1:nFaceJ,1:nFaceK)=rayend_ind(1,2,1,1:nJ+1,1:nK+1,iBlock)
    case(2)
       nFaceJ=nJ+1; nFaceK=nK+1
       qrayface( :,:,1:nFaceJ,1:nFaceK)=rayface(   :,:,nI+1,1:nJ+1,1:nK+1,iBlock)
       qrayend_ind(1,1:nFaceJ,1:nFaceK)=rayend_ind(1,1,nI+1,1:nJ+1,1:nK+1,iBlock)
       qrayend_ind(2,1:nFaceJ,1:nFaceK)=rayend_ind(1,2,nI+1,1:nJ+1,1:nK+1,iBlock)
    case(3)
       nFaceJ=nI+1; nFaceK=nK+1
       qrayface( :,:,1:nFaceJ,1:nFaceK)=rayface(   :,:,1:nI+1,1,1:nK+1,iBlock)
       qrayend_ind(1,1:nFaceJ,1:nFaceK)=rayend_ind(1,1,1:nI+1,1,1:nK+1,iBlock)
       qrayend_ind(2,1:nFaceJ,1:nFaceK)=rayend_ind(1,2,1:nI+1,1,1:nK+1,iBlock)
    case(4)
       nFaceJ=nI+1; nFaceK=nK+1
       qrayface( :,:,1:nFaceJ,1:nFaceK)=rayface(   :,:,1:nI+1,nJ+1,1:nK+1,iBlock)
       qrayend_ind(1,1:nFaceJ,1:nFaceK)=rayend_ind(1,1,1:nI+1,nJ+1,1:nK+1,iBlock)
       qrayend_ind(2,1:nFaceJ,1:nFaceK)=rayend_ind(1,2,1:nI+1,nJ+1,1:nK+1,iBlock)
    case(5)
       nFaceJ=nI+1; nFaceK=nJ+1
       qrayface( :,:,1:nFaceJ,1:nFaceK)=rayface(   :,:,1:nI+1,1:nJ+1,1,iBlock)
       qrayend_ind(1,1:nFaceJ,1:nFaceK)=rayend_ind(1,1,1:nI+1,1:nJ+1,1,iBlock)
       qrayend_ind(2,1:nFaceJ,1:nFaceK)=rayend_ind(1,2,1:nI+1,1:nJ+1,1,iBlock)
    case(6)
       nFaceJ=nI+1; nFaceK=nJ+1
       qrayface( :,:,1:nFaceJ,1:nFaceK)=rayface(   :,:,1:nI+1,1:nJ+1,nK+1,iBlock)
       qrayend_ind(1,1:nFaceJ,1:nFaceK)=rayend_ind(1,1,1:nI+1,1:nJ+1,nK+1,iBlock)
       qrayend_ind(2,1:nFaceJ,1:nFaceK)=rayend_ind(1,2,1:nI+1,1:nJ+1,nK+1,iBlock)
    case default
       call stop_mpi('Impossible value for iface in prolong_ray')
    end select

    do iray=1,2
       do k=1,nfaceK
          if(mod(k,2)==1)then
             do j=2,nfaceJ,2
                ! Case b: even j and odd k

                if(qrayend_ind(iray,j,k)/=ray_out_)CYCLE

                call rayface_interpolate(&
                     qrayface(:,iray,j-1:j+1:2,k),weight2,2,&
                     qrayface(:,iray,j,k))
             end do
          else
             do j=1,nJ+1,2
                ! Case a: odd j and even k

                if(qrayend_ind(iray,j,k)/=ray_out_)CYCLE

                call rayface_interpolate(&
                     qrayface(:,iray,j,k-1:k+1:2),weight2,2,&
                     qrayface(:,iray,j,k))
             end do
             do j=2,nJ,2
                ! Case c: even j and even k

                if(qrayend_ind(iray,j,k)/=ray_out_)CYCLE

                call rayface_interpolate(&
                     qrayface(:,iray,j-1:j+1:2,k-1:k+1:2),weight4,4,&
                     qrayface(:,iray,j,k))
             end do ! j
          end if ! mod(k,2)
       end do ! k
    end do ! iray

    ! Put back result into rayface
    select case(iface)
    case(1)
       rayface(:,:,     1,1:nJ+1,1:nK+1,iBlock)=qrayface(:,:,1:nFaceJ,1:nFaceK)
    case(2)
       rayface(:,:,  nI+1,1:nJ+1,1:nK+1,iBlock)=qrayface(:,:,1:nFaceJ,1:nFaceK)
    case(3)
       rayface(:,:,1:nI+1,     1,1:nK+1,iBlock)=qrayface(:,:,1:nFaceJ,1:nFaceK)
    case(4)
       rayface(:,:,1:nI+1,  nJ+1,1:nK+1,iBlock)=qrayface(:,:,1:nFaceJ,1:nFaceK)
    case(5)
       rayface(:,:,1:nI+1,1:nJ+1,     1,iBlock)=qrayface(:,:,1:nFaceJ,1:nFaceK)
    case(6)
       rayface(:,:,1:nI+1,1:nJ+1,  nK+1,iBlock)=qrayface(:,:,1:nFaceJ,1:nFaceK)
    end select

    call test_stop(NameSub, DoTest, iBlock)
  end subroutine prolong_ray_after_pass
  !============================================================================

  subroutine ray_pass_old

    ! Exchange and update rayface values between blocks direction by direction

    ! Notation: _o out        (cells to be sent for equal blocks)
    !           _g get        (cells to be received)
    !           _r restricted (to be sent to a coarser block)
    !           _s subface    (one quarter of a face)

    use ModMain, ONLY : nblockMax,okdebug,Unused_B,optimize_message_pass
    use BATL_lib, ONLY: iNode_B, iTree_IA, Coord0_
    use ModParallel, ONLY : NOBLK,neiLEV,neiBLK,neiPE
    use ModMpi

    ! Local variables

    ! idir=1,2,3 correspond to east-west, south-north, bot-top.
    integer :: idir, isweep

    ! Face (east..top), side (1 for east,south,bot, 2 for others)
    integer :: iface, otherface, iside

    ! number of subfaces (1 or 4), subface (1..nsubface) and child (1..8) index
    integer ::  nsubface, isubface

    ! Array ranges for outgoing, incoming, restricted and subfaces
    integer :: imin_o,imax_o,jmin_o,jmax_o,kmin_o,kmax_o
    integer :: imin_g,imax_g,jmin_g,jmax_g,kmin_g,kmax_g
    integer :: imin_r,imax_r,jmin_r,jmax_r,kmin_r,kmax_r
    integer :: imin_s,imax_s,jmin_s,jmax_s,kmin_s,kmax_s

    ! Block index
    integer :: iBlock

    ! Descriptors for neighbor
    integer :: neiP,neiB,neiL

    ! MPI variables
    integer :: itag, request, number_receive_requests, receive_requests(MaxBlock*6)
    integer :: status(MPI_STATUS_SIZE, MaxBlock*6)

    ! Maximum size of the RESTRICTED rayface layer to be received
    ! for the 6 ray variables (3 coord*2 ray dir.)
    integer, parameter :: maxsize_r = &
         6*max((nI/2+1)*(nJ/2+1),(nI/2+1)*(nK/2+1),(nJ/2+1)*(nK/2+1))

    ! Receive buffer to hold 4 incoming RESTRICTED rayface values
    ! for all blocks and for both sides
    real, dimension(maxsize_r,4,MaxBlock,2) :: buffer

    ! Actual size of messages: full, restricted/sparse and actual face
    integer :: isize, isize_r, isize1

    ! Equal and restricted values to be sent are stored in these buffers
    real, dimension(:,:,:,:,:), allocatable :: eq_buf, re_buf

    integer :: iError

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'ray_pass_old'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)
    if(DoTest)write(*,*)'ray_pass me=',iProc

    do idir=1,3
       select case(optimize_message_pass)
       case('face')
          ! Send messages face by face
          call ray_pass_faces(2*idir-1,2*idir-1,.true.,.true.,.true.)
          call ray_pass_faces(2*idir  ,2*idir  ,.true.,.true.,.true.)
       case('min')
          ! Send messages face by face and kind by kind
          do isweep=2*idir-1,2*idir
             ! Send equal
             call ray_pass_faces(isweep,isweep,.true.,.false.,.false.)
             ! Send restricted
             call ray_pass_faces(isweep,isweep,.false.,.true.,.false.)
             ! Send prolonged
             call ray_pass_faces(isweep,isweep,.false.,.false.,.true.)
          end do
       case default
          ! Send messages for both faces
          call ray_pass_faces(2*idir-1,2*idir,.true.,.true.,.true.)
       end select
    end do ! idir

    if(DoTest)write(*,*)'ray_pass starting prolongation'

    do iBlock=1,nBlockMax
       if(Unused_B(iBlock))CYCLE

       do iface=1,6
          if(neiLEV(iface,iBlock)==1)call prolong_ray
       end do
    end do

    if(DoTest)write(*,*)'ray_pass finished'

    call test_stop(NameSub, DoTest)
  contains
    !==========================================================================

    subroutine ray_pass_faces(&
         ifacemin,ifacemax,do_equal,do_restricted,do_prolonged)

      integer, intent(in):: ifacemin,ifacemax
      logical, intent(in):: do_equal,do_restricted,do_prolonged

      ! BATL related
      integer:: iNode, iDim, iSideFace
      !------------------------------------------------------------------------

      if(DoTest)write(*,*)&
           'ray_pass_faces:me,ifacemin,ifacemax,do_eq,do_re,do_pr=',&
           iProc,ifacemin,ifacemax,do_equal,do_restricted,do_prolonged

      ! Debug
      if(okdebug)buffer  =0.00

      number_receive_requests = 0
      receive_requests = MPI_REQUEST_NULL

      do iface=ifacemin,ifacemax

         ! Set index ranges for the face
         call setranges_ray

         if(okdebug.and.DoTest)then
            write(*,*)&
                 'setranges_ray for receive done: me,iface,isize,isize_r',&
                 iProc, iface, isize, isize_r
            write(*,*)'_o=',imin_o,imax_o,jmin_o,jmax_o,kmin_o,kmax_o
            write(*,*)'_g=',imin_g,imax_g,jmin_g,jmax_g,kmin_g,kmax_g
            write(*,*)'_r=',imin_r,imax_r,jmin_r,jmax_r,kmin_r,kmax_r
         end if

         do iBlock = 1,nBlockMax
            if(Unused_B(iBlock))CYCLE
            ! Post non-blocking receive for opposite face of neighbor block
            neiL=neiLEV(otherface,iBlock)
            select case(neiL)
            case(0)
               if(.not.do_equal)CYCLE
               nsubface=1
               isize1=isize
            case(1)
               if(.not.do_prolonged)CYCLE
               nsubface=1
               isize1=isize_r
            case(-1)
               if(.not.do_restricted)CYCLE
               nsubface=4
               isize1=isize_r
            case(NOBLK)
               ! Do nothing
               CYCLE
            case default
               write(*,*)'me,iBlock,otherface,neiL=',&
                    iProc,iBlock,otherface,neiL
               call stop_mpi(&
                    'Error in message pass: Invalid value for neiLEV')
            end select

            if(okdebug.and.DoTest)write(*,*)&
                 'receive: me,neiL,nsubface,isize1',&
                 iProc,neiL,nsubface,isize1

            do isubface=1,nsubface
               neiP=neiPE(isubface,otherface,iBlock)
               if(neiP/=iProc)then
                  ! Remote receive
                  itag = 100*iBlock+10*iface+isubface
                  if(DoTest.and.okdebug)write(*,*)&
                       'Remote receive, me,itag,neiL,neiP=',&
                       iProc,itag,neiL,neiP

                  call MPI_irecv(buffer(1,isubface,iBlock,iside),&
                       isize1,MPI_REAL,neiP,itag,iComm,request,iError)
                  number_receive_requests = number_receive_requests + 1
                  receive_requests(number_receive_requests) = request
               end if
            end do ! isubface
         end do ! iBlock
      end do ! iface

      ! Wait for all receive commands to be posted for all processors
      call barrier_mpi

      if(DoTest)write(*,*)'receives posted: me=',iProc

      ! Send blocking messages with Rsend (ready to receive)
      do iface=ifacemin,ifacemax

         ! Set index ranges for the face
         call setranges_ray

         if(okdebug.and.DoTest)write(*,*)&
              'setranges_ray for send done: me, iface=',iProc, iface

         if(do_equal)&
              allocate(eq_buf(3,2,imin_o:imax_o,jmin_o:jmax_o,kmin_o:kmax_o))
         if(do_restricted.or.do_prolonged)&
              allocate(re_buf(3,2,imin_r:imax_r,jmin_r:jmax_r,kmin_r:kmax_r))

         if(okdebug.and.DoTest)write(*,*)'allocation done, me,iface=',&
              iProc,iface

         do iBlock=1,nBlockMax
            if(Unused_B(iBlock))CYCLE
            neiL=neiLEV(iface,iBlock)

            if(okdebug.and.DoTest)write(*,*)&
                 'sending: me, iface,iBlock,neiL=',iProc,iface,iBlock,neiL
            select case(neiL)
            case(0)
               if(.not.do_equal)CYCLE

               neiP=neiPE(1,iface,iBlock)
               neiB=neiBLK(1,iface,iBlock)
               if(neiP==iProc)then
                  ! Local copy
                  if(okdebug.and.DoTest)write(*,*)&
                       'local equal copy: me,iface,iBlock=',iProc,iface,iBlock

                  ! Debug
                  ! write(*,*)'rayface(_o,iBlock)=',&
                  !  rayface(:,:,imin_o:imax_o,jmin_o:jmax_o,kmin_o:kmax_o,iBlock)
                  ! write(*,*)'before: rayface(_g,neiB)=',&
                  !  rayface(:,:,imin_g:imax_g,jmin_g:jmax_g,kmin_g:kmax_g,neiB)

                  rayface(:,:,imin_g:imax_g,jmin_g:jmax_g,kmin_g:kmax_g,neiB)=&
                       max(&
                       rayface(:,:,imin_g:imax_g,jmin_g:jmax_g,kmin_g:kmax_g,neiB),&
                       rayface(:,:,imin_o:imax_o,jmin_o:jmax_o,kmin_o:kmax_o,iBlock))

                  ! Debug
                  ! write(*,*)'after: rayface(_g,neiB)=',&
                  !  rayface(:,:,imin_g:imax_g,jmin_g:jmax_g,kmin_g:kmax_g,neiB)

               else
                  ! Remote send
                  itag = 100*neiB+10*iface+1
                  if(DoTest.and.okdebug)write(*,*)&
                       'Remote equal send, me,itag,neiP=',iProc,itag,neiP

                  eq_buf=&
                       rayface(:,:,imin_o:imax_o,jmin_o:jmax_o,kmin_o:kmax_o,iBlock)

                  call MPI_Rsend(eq_buf,&
                       isize,MPI_REAL,neiP,itag,iComm,iError)
               end if
            case(1)
               if(.not.do_restricted)CYCLE

               ! Restrict rayface in _o range into _r
               re_buf=&
                    rayface(:,:,imin_o:imax_o:2,jmin_o:jmax_o:2,kmin_o:kmax_o:2,iBlock)

               neiP=neiPE(1,iface,iBlock)
               neiB=neiBLK(1,iface,iBlock)
               ! Subface index =1,2,3, or 4 with respect to the coarse neighbor

               ! iSubFace = iSubFace_IA(iFace,iNode_B(iBlock))
               iNode = iNode_B(iBlock)
               iSubFace = 0
               do iDim = 1, nDim
                  iSideFace = modulo(iTree_IA(Coord0_+iDim,iNode) - 1,2)

                  if(iDim == (iFace+1)/2) CYCLE

                  if(iSubFace == 0) then
                     iSubFace = iSideFace + 1
                  else
                     iSubFace = iSubFace + 2*iSideFace
                  end if

               end do

               ! Swap subface 2 and 3 for iFace = 1..4 for BATSRUS tradition...
               if(iFace <= 4 .and. iSubFace >= 2 .and. iSubFace <= 3) &
                    iSubFace = 5 - iSubFace

               if(neiP==iProc)then
                  ! Local copy into appropriate subface
                  call setsubrange_ray(.false.)
                  if(okdebug.and.DoTest)write(*,*)&
                       'local restricted copy: me,iface,iBlock,_s=',&
                       iProc,iface,iBlock,&
                       imin_s,imax_s,jmin_s,jmax_s,kmin_s,kmax_s

                  rayface(:,:,imin_s:imax_s,jmin_s:jmax_s,kmin_s:kmax_s,neiB)=&
                       max(re_buf,&
                       rayface(:,:,imin_s:imax_s,jmin_s:jmax_s,kmin_s:kmax_s,neiB))
               else
                  ! Remote send
                  itag = 100*neiB+10*iface+isubface
                  if(DoTest.and.okdebug)write(*,*)&
                       'Remote restricted send, me,iface,itag=',&
                       iProc,iface,itag
                  call MPI_Rsend(re_buf,isize_r,&
                       MPI_REAL,neiP,itag,iComm,iError)
               end if
            case(-1)
               if(.not.do_prolonged)CYCLE

               do isubface=1,4
                  neiP=neiPE(isubface,iface,iBlock)
                  neiB=neiBLK(isubface,iface,iBlock)

                  call setsubrange_ray(.true.)

                  if(neiP==iProc)then
                     ! Local copy of appropriate subface

                     if(okdebug.and.DoTest)write(*,*)&
                          'local prolonged copy: me,isubface,iface,iBlock,_s=',&
                          iProc,isubface,iface,iBlock,&
                          imin_s,imax_s,jmin_s,jmax_s,kmin_s,kmax_s

                     rayface(:,:,imin_g:imax_g:2,&
                          jmin_g:jmax_g:2,&
                          kmin_g:kmax_g:2,neiB)=max(&
                          rayface(:,:,imin_g:imax_g:2,&
                          jmin_g:jmax_g:2,&
                          kmin_g:kmax_g:2,neiB),&
                          rayface(:,:,imin_s:imax_s,jmin_s:jmax_s,kmin_s:kmax_s,iBlock))
                  else
                     ! Remote send
                     re_buf=&
                          rayface(:,:,imin_s:imax_s,jmin_s:jmax_s,kmin_s:kmax_s,iBlock)

                     itag = 100*neiB+10*iface+1
                     if(DoTest.and.okdebug)write(*,*)&
                          'Remote prolong send, me,iface,itag=',&
                          iProc,iface,itag

                     call MPI_Rsend(re_buf,isize_r,&
                          MPI_REAL,neiP,itag,iComm,iError)
                  end if
               end do ! isubface

            case(NOBLK)
               ! There is no neighbor, do nothing
               CYCLE
            case default
               write(*,*)'me,iBlock,iface,neiL=',&
                    iProc,iBlock,iface,neiL
               call stop_mpi('Error in message pass: Invalid value for neiLEV')
            end select ! neiL
         end do ! iBlock

         if(do_equal)deallocate(eq_buf)
         if(do_restricted.or.do_prolonged)deallocate(re_buf)

         if(DoTest)write(*,*)'messages sent, me, iface=',iProc,iface
      end do ! iface

      ! WAIT FOR ALL MESSAGES TO BE RECEIVED
      if (number_receive_requests > 0) &
           call MPI_waitall(number_receive_requests,receive_requests,status,iError)

      if(DoTest)write(*,*)'messages received, me, idir=',iProc, idir

      ! Copy ghost cells received from non-local neigbors
      ! and stored in the buffer into sol_BLK

      do iface=ifacemin,ifacemax

         ! Set index ranges for the face
         call setranges_ray

         if(okdebug.and.DoTest)write(*,*)&
              'setranges_ray for buf2ray done: me, iface=',iProc, iface

         do iBlock = 1,nBlockMax
            if(Unused_B(iBlock))CYCLE
            select case(neiLEV(otherface,iBlock))
            case(0)
               if(okdebug.and.DoTest)&
                    write(*,*)'buf2rayface: me, iBlock=',iProc,iBlock
               if(do_equal.and.neiPE(1,otherface,iBlock)/=iProc)&
                    call buf2rayface(buffer(1,1,iBlock,iside),&
                    imin_g,imax_g,jmin_g,jmax_g,kmin_g,kmax_g)
            case(1)
               if(okdebug.and.DoTest)&
                    write(*,*)'buf2sparserayface: me, iBlock=',iProc,iBlock
               if(do_prolonged.and.neiPE(1,otherface,iBlock)/=iProc)&
                    call buf2sparserayface(buffer(1,1,iBlock,iside),&
                    imin_r,imax_r,jmin_r,jmax_r,kmin_r,kmax_r)
            case(-1)
               if(do_restricted)then
                  do isubface=1,4
                     if(okdebug.and.DoTest)&
                          write(*,*)'buf2subrayface: me, isubface, iBlock=',&
                          iProc,isubface,iBlock
                     if(neiPE(isubface,otherface,iBlock)/=iProc)&
                          call buf2subrayface(&
                          buffer(1,isubface,iBlock,iside),&
                          imin_r,imax_r,jmin_r,jmax_r,kmin_r,kmax_r)
                  end do
               end if
            end select ! neiL
         end do ! iBlock
      end do ! iface

      if(DoTest)write(*,*)'ray_pass_faces finished: me, ifacemin, ifacemax=',&
           iProc,ifacemin,ifacemax

    end subroutine ray_pass_faces
    !==========================================================================

    subroutine setranges_ray

      ! Set ranges orthogonal to idir based on the value of idir

      !------------------------------------------------------------------------
      if(idir/=1)then
         imin_g=1;  imax_g=nI+1
         imin_o=1;  imax_o=nI+1
         imin_r=1;  imax_r=nI/2+1
      end if

      if(idir/=2)then
         jmin_g=1;  jmax_g=nJ+1
         jmin_o=1;  jmax_o=nJ+1
         jmin_r=1;  jmax_r=nJ/2+1
      endif

      if(idir/=3)then
         kmin_g=1;  kmax_g=nK+1
         kmin_o=1;  kmax_o=nK+1
         kmin_r=1;  kmax_r=nK/2+1
      end if

      ! Set ranges in direction of idir based on the value of iface

      select case(iface)
      case(1)
         otherface=2; iside=1
         imin_o=1;    imax_o=1
         imin_g=nI+1; imax_g=nI+1
         imin_r=1;    imax_r=1
      case(3)
         otherface=4; iside=1
         jmin_o=1;    jmax_o=1
         jmin_g=nJ+1; jmax_g=nJ+1
         jmin_r=1;    jmax_r=1
      case(5)
         otherface=6; iside=1
         kmin_o=1;    kmax_o=1
         kmin_g=nK+1; kmax_g=nK+1
         kmin_r=1;    kmax_r=1
      case(2)
         otherface=1; iside=2
         imin_o=nI+1; imax_o=nI+1
         imin_g=1;    imax_g=1
         imin_r=1;    imax_r=1
      case(4)
         otherface=3; iside=2
         jmin_o=nJ+1; jmax_o=nJ+1
         jmin_g=1;    jmax_g=1
         jmin_r=1;    jmax_r=1
      case(6)
         otherface=5; iside=2
         kmin_o=nK+1; kmax_o=nK+1
         kmin_g=1;    kmax_g=1
         kmin_r=1;    kmax_r=1
      end select

      ! Size of full and restricted cell layers
      isize  =6*(imax_g-imin_g+1)*(jmax_g-jmin_g+1)*(kmax_g-kmin_g+1)
      isize_r=6*(imax_r-imin_r+1)*(jmax_r-jmin_r+1)*(kmax_r-kmin_r+1)

    end subroutine setranges_ray
    !==========================================================================

    subroutine setsubrange_ray(oksend)

      logical, intent(in) :: oksend

      ! Select appropriate quarter of ghost cell layer

      !------------------------------------------------------------------------
      select case(iface)
      case(1,2)
         if(oksend)then
            imin_s=imin_o; imax_s=imax_o
         else
            imin_s=imin_g; imax_s=imax_g
         end if

         select case(isubface)
            ! Beware, case(2) and case(3) are swapped
         case(1)
            jmin_s=jmin_r; jmax_s=jmax_r;
            kmin_s=kmin_r; kmax_s=kmax_r
         case(3)
            jmin_s=jmin_r+nJ/2; jmax_s=jmax_r+nJ/2;
            kmin_s=kmin_r; kmax_s=kmax_r
         case(2)
            jmin_s=jmin_r; jmax_s=jmax_r;
            kmin_s=kmin_r+nK/2; kmax_s=kmax_r+nK/2;
         case(4)
            jmin_s=jmin_r+nJ/2; jmax_s=jmax_r+nJ/2;
            kmin_s=kmin_r+nK/2; kmax_s=kmax_r+nK/2;
         end select
      case(3,4)
         if(oksend)then
            jmin_s=jmin_o; jmax_s=jmax_o
         else
            jmin_s=jmin_g; jmax_s=jmax_g
         end if
         select case(isubface)
            ! Beware, case(2) and case(3) are swapped
         case(1)
            imin_s=imin_r;      imax_s=imax_r;
            kmin_s=kmin_r;      kmax_s=kmax_r
         case(3)
            imin_s=imin_r+nI/2; imax_s=imax_r+nI/2;
            kmin_s=kmin_r;      kmax_s=kmax_r
         case(2)
            imin_s=imin_r;      imax_s=imax_r;
            kmin_s=kmin_r+nK/2; kmax_s=kmax_r+nK/2;
         case(4)
            imin_s=imin_r+nI/2; imax_s=imax_r+nI/2;
            kmin_s=kmin_r+nK/2; kmax_s=kmax_r+nK/2;
         end select
      case(5,6)
         if(oksend)then
            kmin_s=kmin_o; kmax_s=kmax_o
         else
            kmin_s=kmin_g; kmax_s=kmax_g
         end if
         select case(isubface)
            ! Beware, case(2) and case(3) are not swapped
         case(1)
            imin_s=imin_r;      imax_s=imax_r;
            jmin_s=jmin_r;      jmax_s=jmax_r
         case(2)
            imin_s=imin_r+nI/2; imax_s=imax_r+nI/2;
            jmin_s=jmin_r;      jmax_s=jmax_r
         case(3)
            imin_s=imin_r;      imax_s=imax_r;
            jmin_s=jmin_r+nJ/2; jmax_s=jmax_r+nJ/2;
         case(4)
            imin_s=imin_r+nI/2; imax_s=imax_r+nI/2;
            jmin_s=jmin_r+nJ/2; jmax_s=jmax_r+nJ/2;
         end select
      end select

    end subroutine setsubrange_ray
    !==========================================================================

    subroutine buf2rayface(&
         buf,imin,imax,jmin,jmax,kmin,kmax)

      integer, intent(in) :: imin,imax,jmin,jmax,kmin,kmax
      real, dimension(3,2,imin:imax,jmin:jmax,kmin:kmax),intent(inout) :: buf
      !------------------------------------------------------------------------

      ! Take maximum of rayface and buf (more positive values are more real)
      ! for the full face

      rayface(:,:,imin_g:imax_g,jmin_g:jmax_g,kmin_g:kmax_g,iBlock)=max(buf,&
           rayface(:,:,imin_g:imax_g,jmin_g:jmax_g,kmin_g:kmax_g,iBlock))

    end subroutine buf2rayface
    !==========================================================================

    subroutine buf2sparserayface(buf,imin,imax,jmin,jmax,kmin,kmax)

      integer, intent(in) :: imin,imax,jmin,jmax,kmin,kmax
      real, dimension(3,2,imin:imax,jmin:jmax,kmin:kmax),intent(inout) :: buf

      ! Take maximum of rayface and buf (more positive values are more real)
      ! for a factor of 2 coarser grid

      !------------------------------------------------------------------------
      rayface(:,:,imin_g:imax_g:2,jmin_g:jmax_g:2,kmin_g:kmax_g:2,iBlock)=max(buf,&
           rayface(:,:,imin_g:imax_g:2,jmin_g:jmax_g:2,kmin_g:kmax_g:2,iBlock))

    end subroutine buf2sparserayface
    !==========================================================================

    subroutine buf2subrayface(buf,imin,imax,jmin,jmax,kmin,kmax)

      integer, intent(in) :: imin,imax,jmin,jmax,kmin,kmax
      real, dimension(3,2,imin:imax,jmin:jmax,kmin:kmax),intent(inout) :: buf

      ! Set subface range to write into

      !------------------------------------------------------------------------
      call setsubrange_ray(.false.)

      ! Take maximum of rayface and buf (more positive values are more real)
      ! for the appropriate subface

      rayface(:,:,imin_s:imax_s,jmin_s:jmax_s,kmin_s:kmax_s,iBlock)=max(buf,&
           rayface(:,:,imin_s:imax_s,jmin_s:jmax_s,kmin_s:kmax_s,iBlock))

    end subroutine buf2subrayface
    !==========================================================================

    subroutine prolong_ray

      ! For faces that are shared with a coarser neighbor, interpolate
      ! for all points which are not coinciding and where the ray is going out.
      !
      ! a at odd  j and even k requires interpolation in direction k
      ! b at even j and odd  k requires interpolation in direction j
      ! c at even j and even k requires interpolation in both directions

      ! (1,5)           (5,5)
      !   O-- b --O-- b --O
      !   |   |   |   |   |
      !   |   |   |   |   |
      !   a - c - a - c - a
      !   |   |   |   |   |
      !   |   |   |   |   |
      !   O-- b --O-- b --O
      !   |   |   |   |   |
      !   |   |   |   |   |
      !   a - c - a - c - a
      !   |   |   |   |   |
      !   |   |   |   |   |
      !   O-- b --O-- b --O
      ! (1,1)           (5,1)

      integer :: iray
      integer :: j, k, nFaceJ, nFaceK
      integer, parameter :: nFaceMax=max(nI+1,nJ+1,nK+1)
      real    :: qrayface(3,2,nFaceMax,nFaceMax)
      integer :: qrayend_ind(2,nFaceMax,nFaceMax)

      ! Interpolation weights
      real, dimension(4), parameter:: weight4=0.25
      real, dimension(2), parameter:: weight2=0.5

      !------------------------------------------------------------------------

      if(DoTest)write(*,*)'Prolong_ray, me, iBlock, iface=',iProc, iBlock, iface

      ! Extract qrayface and qrayend_ind for the appropriate face
      ! NOTE: qrayend_ind assignment split to two lines to avoid reshaping compiler bug!
      select case(iface)
      case(1)
         nFaceJ=nJ+1; nFaceK=nK+1
         qrayface( :,:,1:nFaceJ,1:nFaceK)=rayface(   :,:,1,1:nJ+1,1:nK+1,iBlock)
         qrayend_ind(1,1:nFaceJ,1:nFaceK)=rayend_ind(1,1,1,1:nJ+1,1:nK+1,iBlock)
         qrayend_ind(2,1:nFaceJ,1:nFaceK)=rayend_ind(1,2,1,1:nJ+1,1:nK+1,iBlock)
      case(2)
         nFaceJ=nJ+1; nFaceK=nK+1
         qrayface( :,:,1:nFaceJ,1:nFaceK)=rayface(   :,:,nI+1,1:nJ+1,1:nK+1,iBlock)
         qrayend_ind(1,1:nFaceJ,1:nFaceK)=rayend_ind(1,1,nI+1,1:nJ+1,1:nK+1,iBlock)
         qrayend_ind(2,1:nFaceJ,1:nFaceK)=rayend_ind(1,2,nI+1,1:nJ+1,1:nK+1,iBlock)
      case(3)
         nFaceJ=nI+1; nFaceK=nK+1
         qrayface( :,:,1:nFaceJ,1:nFaceK)=rayface(   :,:,1:nI+1,1,1:nK+1,iBlock)
         qrayend_ind(1,1:nFaceJ,1:nFaceK)=rayend_ind(1,1,1:nI+1,1,1:nK+1,iBlock)
         qrayend_ind(2,1:nFaceJ,1:nFaceK)=rayend_ind(1,2,1:nI+1,1,1:nK+1,iBlock)
      case(4)
         nFaceJ=nI+1; nFaceK=nK+1
         qrayface( :,:,1:nFaceJ,1:nFaceK)=rayface(   :,:,1:nI+1,nJ+1,1:nK+1,iBlock)
         qrayend_ind(1,1:nFaceJ,1:nFaceK)=rayend_ind(1,1,1:nI+1,nJ+1,1:nK+1,iBlock)
         qrayend_ind(2,1:nFaceJ,1:nFaceK)=rayend_ind(1,2,1:nI+1,nJ+1,1:nK+1,iBlock)
      case(5)
         nFaceJ=nI+1; nFaceK=nJ+1
         qrayface( :,:,1:nFaceJ,1:nFaceK)=rayface(   :,:,1:nI+1,1:nJ+1,1,iBlock)
         qrayend_ind(1,1:nFaceJ,1:nFaceK)=rayend_ind(1,1,1:nI+1,1:nJ+1,1,iBlock)
         qrayend_ind(2,1:nFaceJ,1:nFaceK)=rayend_ind(1,2,1:nI+1,1:nJ+1,1,iBlock)
      case(6)
         nFaceJ=nI+1; nFaceK=nJ+1
         qrayface( :,:,1:nFaceJ,1:nFaceK)=rayface(   :,:,1:nI+1,1:nJ+1,nK+1,iBlock)
         qrayend_ind(1,1:nFaceJ,1:nFaceK)=rayend_ind(1,1,1:nI+1,1:nJ+1,nK+1,iBlock)
         qrayend_ind(2,1:nFaceJ,1:nFaceK)=rayend_ind(1,2,1:nI+1,1:nJ+1,nK+1,iBlock)
      case default
         call stop_mpi('Impossible value for iface in prolong_ray')
      end select

      do iray=1,2
         do k=1,nfaceK
            if(mod(k,2)==1)then
               do j=2,nfaceJ,2
                  ! Case b: even j and odd k

                  if(qrayend_ind(iray,j,k)/=ray_out_)CYCLE

                  call rayface_interpolate(&
                       qrayface(:,iray,j-1:j+1:2,k),weight2,2,&
                       qrayface(:,iray,j,k))
               end do
            else
               do j=1,nJ+1,2
                  ! Case a: odd j and even k

                  if(qrayend_ind(iray,j,k)/=ray_out_)CYCLE

                  call rayface_interpolate(&
                       qrayface(:,iray,j,k-1:k+1:2),weight2,2,&
                       qrayface(:,iray,j,k))
               end do
               do j=2,nJ,2
                  ! Case c: even j and even k

                  if(qrayend_ind(iray,j,k)/=ray_out_)CYCLE

                  call rayface_interpolate(&
                       qrayface(:,iray,j-1:j+1:2,k-1:k+1:2),weight4,4,&
                       qrayface(:,iray,j,k))
               end do ! j
            end if ! mod(k,2)
         end do ! k
      end do ! iray

      ! Put back result into rayface
      select case(iface)
      case(1)
         rayface(:,:,     1,1:nJ+1,1:nK+1,iBlock)=qrayface(:,:,1:nFaceJ,1:nFaceK)
      case(2)
         rayface(:,:,  nI+1,1:nJ+1,1:nK+1,iBlock)=qrayface(:,:,1:nFaceJ,1:nFaceK)
      case(3)
         rayface(:,:,1:nI+1,     1,1:nK+1,iBlock)=qrayface(:,:,1:nFaceJ,1:nFaceK)
      case(4)
         rayface(:,:,1:nI+1,  nJ+1,1:nK+1,iBlock)=qrayface(:,:,1:nFaceJ,1:nFaceK)
      case(5)
         rayface(:,:,1:nI+1,1:nJ+1,     1,iBlock)=qrayface(:,:,1:nFaceJ,1:nFaceK)
      case(6)
         rayface(:,:,1:nI+1,1:nJ+1,  nK+1,iBlock)=qrayface(:,:,1:nFaceJ,1:nFaceK)
      end select

    end subroutine prolong_ray
    !==========================================================================

  end subroutine ray_pass_old
  !============================================================================

end module ModFieldTrace
!==============================================================================
