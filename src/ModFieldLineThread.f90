!  Copyright (C) 2002 Regents of the University of Michigan,
!  portions used with permission
!  For more information, see http://csem.engin.umich.edu/tools/swmf
module ModFieldLineThread

  use BATL_lib, ONLY: &
       test_start, test_stop, jTest, kTest, iBlockTest, iProc, nProc, iComm,&
       nJ, nK, jDim_, kDim_
!  use ModUtilities, ONLY: norm2
  use ModMain, ONLY: UseFieldLineThreads, DoThreads_B
  use ModB0,   ONLY: get_b0

  implicit none
  save

  PRIVATE ! Except
  integer, parameter:: jMin_ = 1 - jDim_, jMax_ = nJ + jDim_
  integer, parameter:: kMin_ = 1 - kDim_, kMax_ = nK + jDim_
  logical, public, allocatable:: IsAllocatedThread_B(:)
  ! Named indexes for local use only

  ! In the boundary blocks the physical cells near the boundary are connected
  ! to the photosphere with these threads
  type BoundaryThreads
     !\
     ! The thread length, \int{ds}, from the photoshere to the given point
     ! Renamed and revised: in meters
     !/
     real,pointer :: LengthSi_III(:,:,:)
     !\
     ! The integral, \int{B ds}, from the photoshere to the given point
     ! Renamed and revised: only the value BDsInv_III(0,j,k) keeps this
     ! sense and used for calculating TMax_II(j,k). The values of
     ! BDsInv_III(negative iPoint,j,k) are equal to
     ! ds[m]/(B[T]*PoyntingFluxPerBSi). Are used to calculate
     ! the dimensionless heat flux as (Cons_I(iPoint)-Cons_I(iPoint+1))*BDsInv
     !/
     real,pointer :: BDsInvSi_III(:,:,:)
     !\
     ! Dimensionless TMax, such that the ingoing heat flux to the TR at this
     ! temperature equals the Poynting flux (which is not realistic and means
     ! that the input tempreture exceeding TMax assumes that something is
     ! going wrong.
     !/
     real,pointer :: TMax_II(:,:)

     !\
     ! Ds[m]/(B[T]*PoyntingFluxPerBSi)
     ! By multiplying this by 2*(3/2Pe) we obtain the internal energy in the
     ! interval between two grid points, in seconds. The physical meanin is
     ! how soon a plasma may be heated by this internal energy in the cell
     ! volume with having a BC for the Poynting flux at the left boundary
     ! and zero flux at the right boundary: In Si system
     !/
     real,pointer :: DsOverBSi_III(:,:,:)

     !\
     ! The integral, sqrt(PoyntingFluxPerB/LPerp**2)*\int{1/sqrt(B) ds}
     ! Dimensionless.
     !/
     real,pointer :: Xi_III(:,:,:)
     !\
     ! Magnetic field intensity, the inverse of heliocentric distance,
     ! and the gen coord over the radial direction
     ! Dimensionless.
     !/
     real,pointer :: B_III(:,:,:),RInv_III(:,:,:), Coord1_III(:,:,:)
     !\
     ! The use:
     ! PeSi_I(iPoint) = PeSi_I(iPoint-1)*exp(-TGrav_III(iPoint)/TeSi_I(iPoint))
     !/
     real, pointer:: TGrav_III(:,:,:)
     !\
     ! The type of last update for the thread solution
     !/
     integer :: iAction

     !\
     !  Thread solution: temperature and pressure SI
     !/
     real,pointer :: TeSi_III(:,:,:),TiSi_III(:,:,:),PSi_III(:,:,:)
     !\
     ! number of points
     !/
     integer,pointer :: nPoint_II(:,:)
     !\
     ! Distance between the true and ghost cell centers.
     !/
     real, pointer :: DeltaR_II(:,:)
     !\
     ! For visualization: 
     !/
     !\ Index of the last cell in radial direction
     integer :: iMin
     !/
     !\ Ne and Te for iMin:1,0:nJ+1,0:nK+1 as the first step
     real, pointer :: State_VIII(:,:,:,:)
  end type BoundaryThreads
  integer, parameter :: NeSi_=1, TeSi_=2
  type(BoundaryThreads), public, pointer :: BoundaryThreads_B(:)

  !
  integer,public :: nPointThreadMax = 45
  real           :: DsThreadMin = 0.002

  !\
  ! Normalization as used in the radcool table
  !/
  real, parameter :: RadNorm = 1.0E+22
  !\
  ! Correction coefficient to transform the units as used in the radcool
  ! table to SI system.
  !/
  real, parameter :: Cgs2SiEnergyDens = &
       1.0e-7&   ! erg = 1e-7 J
       /1.0e-6    ! cm3 = 1e-6 m3
  !\
  ! To find the volumetric radiative cooling rate in J/(m^3 s)
  ! the value found from radcool table should be multiplied by
  ! RadcoolSi and by n_e[m^{-3}]*n_i[m^{-3}]
  !/
  real, public, parameter :: Radcool2Si = 1.0e-12 & ! (cm-3=>m-3)**2
                          *Cgs2SiEnergyDens/RadNorm
  !\
  ! A constant factor to calculate the electron heat conduction
  !/
  real, public :: HeatCondParSi

  real, public :: cExchangeRateSi

  real, parameter:: TeGlobalMaxSi = 1.80e7

  !\
  ! Logical from ModMain.
  !/
  public:: UseFieldLineThreads

  public:: BoundaryThreads
  public:: read_threads      ! Read parameters of threads
  public:: check_tr_table    ! Calculate a table for transition region
  !\
  ! Correspondent named indexes: meaning of the columns in the table
  !/
  integer,public,parameter:: LengthPAvrSi_ = 1, UHeat_ = 2
  integer,public,parameter:: HeatFluxLength_ = 3, DHeatFluxXOverU_ = 4
  integer,public,parameter:: LambdaSi_=5, DLogLambdaOverDLogT_ = 6
  !\
  ! Global arrays used in calculating the tables
  !/
  real,dimension(1:500):: TeSi_I, LambdaSi_I, &
       LPe_I, UHeat_I, dFluxXLengthOverDU_I, DLogLambdaOverDLogT_I

  public:: set_threads       ! (Re)Sets threads in the inner boundary blocks

  !\
  ! Called prior to different invokes of set_cell_boundary, to determine
  ! how the solution on the thread should be (or not be) advanced:
  ! after hydro stage or after the heat conduction stage etc
  !/
  public:: advance_threads
  !\
  ! Saves restart
  !/
  public :: save_thread_restart
  !\
  ! Correspondent named indexes
  !/
  integer,public,parameter:: DoInit_=-1, Done_=0, Enthalpy_=1, Heat_=2

  !\
  ! The number of grid spaces which are covered by the TR model
  ! the smaller is this number, the better the TR assumption work
  ! However, 1 is not recommended, as long as the length of the
  ! last interval is not controlled (may be too small)
  !/
  integer, parameter:: nIntervalTR = 2
  !\
  !   Hydrostatic equilibrium in an isothermal corona:
  !    d(N_i*k_B*(Z*T_e +T_i) )/dr=G*M_sun*N_I*M_i*d(1/r)/dr
  ! => N_i*Te\propto exp(cGravPot/TeSi*(M_i[amu]/(1+Z))*\Delta(R_sun/r))
  !/
  !\
  ! The plasma properties dependent coefficient needed to evaluate the
  ! eefect of gravity on the hydrostatic equilibrium
  !/
  real,public :: GravHydroStat != cGravPot*MassIon_I(1)/(AverageIonCharge + 1)
  character(len=100) :: NameRestartFile
contains
  !============================================================================
  subroutine read_threads(iSession)
    use ModSize, ONLY: MaxBlock
    use ModReadParam, ONLY: read_var
    integer, intent(in):: iSession
    integer :: iBlock
    logical:: DoTest
    character(len=*), parameter:: NameSub = 'read_threads'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)

    call read_var('UseFieldLineThreads', UseFieldLineThreads)
    if(UseFieldLineThreads)then
       if(iSession/=1)call stop_mpi(&
            'UseFieldLineThreads can only be set ON during the first session')
       if(.not.allocated(DoThreads_B))then
          allocate(        DoThreads_B(MaxBlock))
          allocate(IsAllocatedThread_B(MaxBlock))
          DoThreads_B = .false.
          IsAllocatedThread_B = .false.
          allocate(BoundaryThreads_B(1:MaxBlock))
          do iBlock = 1, MaxBlock
             call nullify_thread_b(iBlock)
          end do
       end if
       call read_var('nPointThreadMax', nPointThreadMax)
       call read_var('DsThreadMin', DsThreadMin)
    else
       if(allocated(DoThreads_B))then
          deallocate(DoThreads_B)
          do iBlock = 1, MaxBlock
             if(IsAllocatedThread_B(iBlock))&
                  call deallocate_thread_b(iBlock)
          end do
          deallocate(IsAllocatedThread_B)
          deallocate(  BoundaryThreads_B)
       end if
    end if
    call test_stop(NameSub, DoTest)
  end subroutine read_threads
  !============================================================================
  subroutine nullify_thread_b(iBlock)
    integer, intent(in) :: iBlock
    logical:: DoTest
    character(len=*), parameter:: NameSub = 'nullify_thread_b'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest, iBlock)
    nullify(BoundaryThreads_B(iBlock) % LengthSi_III)
    nullify(BoundaryThreads_B(iBlock) % BDsInvSi_III)
    nullify(BoundaryThreads_B(iBlock) % DsOverBSi_III)
    nullify(BoundaryThreads_B(iBlock) % TMax_II)
    nullify(BoundaryThreads_B(iBlock) % Xi_III)
    nullify(BoundaryThreads_B(iBlock) % B_III)
    nullify(BoundaryThreads_B(iBlock) % RInv_III)
    nullify(BoundaryThreads_B(iBlock) % Coord1_III)
    nullify(BoundaryThreads_B(iBlock) % TGrav_III)
    nullify(BoundaryThreads_B(iBlock) % TeSi_III)
    nullify(BoundaryThreads_B(iBlock) % TiSi_III)
    nullify(BoundaryThreads_B(iBlock) % PSi_III)
    nullify(BoundaryThreads_B(iBlock) % nPoint_II)
    nullify(BoundaryThreads_B(iBlock) % DeltaR_II)
    nullify(BoundaryThreads_B(iBlock) % State_VIII)
    call test_stop(NameSub, DoTest, iBlock)
  end subroutine nullify_thread_b
  !============================================================================
  subroutine deallocate_thread_b(iBlock)
    integer, intent(in) :: iBlock
    logical:: DoTest
    character(len=*), parameter:: NameSub = 'deallocate_thread_b'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest, iBlock)
    deallocate(BoundaryThreads_B(iBlock) % LengthSi_III)
    deallocate(BoundaryThreads_B(iBlock) % BDsInvSi_III)
    deallocate(BoundaryThreads_B(iBlock) % DsOverBSi_III)
    deallocate(BoundaryThreads_B(iBlock) % TMax_II)
    deallocate(BoundaryThreads_B(iBlock) % Xi_III)
    deallocate(BoundaryThreads_B(iBlock) % B_III)
    deallocate(BoundaryThreads_B(iBlock) % RInv_III)
    deallocate(BoundaryThreads_B(iBlock) % Coord1_III)
    deallocate(BoundaryThreads_B(iBlock) % TGrav_III)
    deallocate(BoundaryThreads_B(iBlock) % TeSi_III)
    deallocate(BoundaryThreads_B(iBlock) % TiSi_III)
    deallocate(BoundaryThreads_B(iBlock) % PSi_III)
    deallocate(BoundaryThreads_B(iBlock) % nPoint_II)
    deallocate(BoundaryThreads_B(iBlock) % DeltaR_II)
    deallocate(BoundaryThreads_B(iBlock) % State_VIII)
    IsAllocatedThread_B(iBlock) = .false.
    call nullify_thread_b(iBlock)
    call test_stop(NameSub, DoTest, iBlock)
  end subroutine deallocate_thread_b
  !============================================================================
  subroutine set_threads
    use BATL_lib,     ONLY: MaxBlock, Unused_B
    use ModParallel, ONLY: NeiLev, NOBLK
    use ModMpi
    integer:: iBlock, nBlockSet, nBlockSetAll, nPointMin, nPointMinAll, j, k
    integer:: iError
    logical:: DoTest
    character(len=*), parameter:: NameSub = 'set_threads'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)
    nBlockSet = 0
    nPointMin = nPointThreadMax
    do iBlock = 1, MaxBlock
       if(Unused_B(iBlock))then
          DoThreads_B(iBlock) = .false.
          if(IsAllocatedThread_B(iBlock))&
               call deallocate_thread_b(iBlock)
          CYCLE
       end if
       if(.not.DoThreads_B(iBlock))CYCLE
       DoThreads_B(iBlock) = .false.
       !\
       ! Check if the block is at the inner boundary
       ! Otherwise CYCLE
       !/
       if(NeiLev(1,iBlock)/=NOBLK)then
          if(IsAllocatedThread_B(iBlock))&
               call deallocate_thread_b(iBlock)
          CYCLE
       end if
       !\
       ! Allocate threads if needed
       !/
       if(.not.IsAllocatedThread_B(iBlock))then
          allocate(BoundaryThreads_B(iBlock) % LengthSi_III(&
               -nPointThreadMax:0,jMin_:jMax_, kMin_:kMax_))
          allocate(BoundaryThreads_B(iBlock) % BDsInvSi_III(&
               -nPointThreadMax:0,jMin_:jMax_, kMin_:kMax_))
          allocate(BoundaryThreads_B(iBlock) % DsOverBSi_III(&
               -nPointThreadMax:0,jMin_:jMax_, kMin_:kMax_))
          allocate(BoundaryThreads_B(iBlock) % TMax_II(&
               jMin_:jMax_, kMin_:kMax_))
          allocate(BoundaryThreads_B(iBlock) % Xi_III(&
               -nPointThreadMax:0,jMin_:jMax_, kMin_:kMax_))
          allocate(BoundaryThreads_B(iBlock) % B_III(&
               -nPointThreadMax:0,jMin_:jMax_, kMin_:kMax_))
          allocate(BoundaryThreads_B(iBlock) % RInv_III(&
               -nPointThreadMax:0,jMin_:jMax_, kMin_:kMax_))
          allocate(BoundaryThreads_B(iBlock) % Coord1_III(&
               -nPointThreadMax:0,jMin_:jMax_, kMin_:kMax_))
          allocate(BoundaryThreads_B(iBlock) % TGrav_III(&
               -nPointThreadMax:0,jMin_:jMax_, kMin_:kMax_))
          allocate(BoundaryThreads_B(iBlock) % TeSi_III(&
               -nPointThreadMax:0,jMin_:jMax_, kMin_:kMax_))
          allocate(BoundaryThreads_B(iBlock) % TiSi_III(&
               -nPointThreadMax:0,jMin_:jMax_, kMin_:kMax_))
          allocate(BoundaryThreads_B(iBlock) % PSi_III(&
               -nPointThreadMax:0,jMin_:jMax_, kMin_:kMax_))
          allocate(BoundaryThreads_B(iBlock) % nPoint_II(&
               jMin_:jMax_, kMin_:kMax_))
          allocate(BoundaryThreads_B(iBlock) % DeltaR_II(&
               jMin_:jMax_, kMin_:kMax_))
          allocate(BoundaryThreads_B(iBlock) % State_VIII(&
               NeSi_:TeSi_, BoundaryThreads_B(iBlock) % iMin:1,&
               jMin_:jMax_, kMin_:kMax_))
          BoundaryThreads_B(iBlock) % iMin = i_min(iBlock)
          IsAllocatedThread_B(iBlock) = .true.
       end if
       !\
       ! The threads are now set in a just created block, or
       ! on updating B_0 field
       !/
       call set_threads_b(iBlock)
       nBlockSet = nBlockSet + 1
       do k = kMin_, kMax_; do j = jMin_, jMax_
          nPointMin = min(nPointMin, BoundaryThreads_B(iBlock)%nPoint_II(j,k))
       end do; end do
    end do
    if(nProc==1)then
       nBlockSetAll = nBlockSet
       nPointMinAll = nPointMin
    else
       call MPI_REDUCE(nBlockSet, nBlockSetAll, 1, MPI_INTEGER, MPI_SUM,&
            0, iComm, iError)
       call MPI_REDUCE(nPointMin, nPointMinAll, 1, MPI_INTEGER, MPI_MIN,&
            0, iComm, iError)
    end if
    if(nBlockSetAll > 0.and.iProc==0)then
       write(*,*)'Set threads in ',nBlockSetAll,' blocks'
       write(*,*)'nPointMin = ',nPointMinAll
    end if
    call test_stop(NameSub, DoTest)
  contains
    integer function i_min(iBlock)
      use BATL_lib, ONLY: MaxDim, xyz_to_coord, coord_to_xyz, &
           CoordMin_DB, CellSize_DB, r_
      integer, intent(in) :: iBlock
      real :: Coord_D(MaxDim), Xyz_D(MaxDim)
      !----------------
      !\
      ! Gen coords for the low block corner
      !/
      call coord_to_xyz(CoordMin_DB(:, iBlock), Xyz_D)
      !\
      ! Projection onto the photosphere level
      !/
      Xyz_D = Xyz_D/norm2(Xyz_D)
      !\
      ! Generalized coords of the latter.
      !/
      call xyz_to_coord(Xyz_D, Coord_D)
      !\
      ! Minimal index of the ghost cells, in radial direction
      ! (equals 0 if there is only 1 ghost cell)
      !/
      i_min = 1 - floor( (CoordMin_DB(r_, iBlock) - Coord_D(r_))/&
           CellSize_DB(r_, iBlock) )
    end function i_min
  end subroutine set_threads
  !============================================================================
  subroutine set_threads_b(iBlock)
    use EEE_ModCommonVariables, ONLY: UseCme
    use EEE_ModMain,            ONLY: EEE_get_state_BC
    use ModMain,       ONLY: n_step, iteration_number, time_simulation, &
         DoThreadRestart
    use ModGeometry, ONLY: Xyz_DGB
    use ModPhysics,  ONLY: Si2No_V, No2Si_V,&
                           UnitTemperature_, UnitX_, UnitB_
    use ModNumConst, ONLY: cTolerance
    use ModCoronalHeating, ONLY:PoyntingFluxPerBSi, PoyntingFluxPerB, &
         LPerpTimesSqrtB
    use BATL_lib,    ONLY: MaxDim, xyz_to_coord, r_
    integer, intent(in) :: iBlock
    !\
    ! Locals:
    !/
    ! Loop variable: (j,k) enumerate the cells at which
    ! the threads starts, iPoint starts from negative
    ! values at the photospheric end and the maximal
    ! value of this index is 0 for the thread point
    ! at the physical cell center.
    integer :: j, k, iPoint, nTrial, iInterval, nPoint

    !\
    ! rBody here is set to one keeping a capability to set
    ! the face-formulated boundary condition by modifying
    ! rBody
    !/
    real, parameter :: rBody = 1.0

    ! Length interval, !Heliocentric distance
    real :: Ds, R, RStart
    ! coordinates, field vector and modulus
    real :: Xyz_D(MaxDim), Coord_D(MaxDim), B0_D(MaxDim), B0
    ! Same stored for the starting point
    real :: XyzStart_D(MaxDim), B0Start_D(MaxDim),  B0Start
    ! 1 for ourward directed field, -1 otherwise
    real ::SignBr
    ! Coordinates and magnetic field in the midpoint
    ! within the framework of the Runge-Kutta scheme
    real :: XyzAux_D(MaxDim), B0Aux_D(MaxDim)
    !\
    ! CME parameters, if needed
    !/
    real:: RhoCme, Ucme_D(MaxDim), Bcme_D(MaxDim), pCme
    ! Aux
    real :: ROld, Aux, CoefXi
    real :: DirB_D(MaxDim), DirR_D(MaxDim), XyzOld_D(MaxDim)
    real:: CosBRMin = 1.0
    integer, parameter::nCoarseMax = 2

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'set_threads_b'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest, iBlock)

    !\
    ! Initialize threads
    !/
    BoundaryThreads_B(iBlock) % iAction = DoInit_
    BoundaryThreads_B(iBlock) % LengthSi_III = 0.0
    BoundaryThreads_B(iBlock) % BDsInvSi_III = 0.0
    BoundaryThreads_B(iBlock) % DsOverBSi_III = 0.0
    BoundaryThreads_B(iBlock) % TMax_II = 1.0e8*Si2No_V(UnitTemperature_)
    BoundaryThreads_B(iBlock) % Xi_III = 0.0
    BoundaryThreads_B(iBlock) % B_III = 0.0
    BoundaryThreads_B(iBlock) % RInv_III = 0.0
    BoundaryThreads_B(iBlock) % Coord1_III = 0.0
    BoundaryThreads_B(iBlock) % TGrav_III = 0.0
    BoundaryThreads_B(iBlock) % TeSi_III = -1.0
    BoundaryThreads_B(iBlock) % TiSi_III = -1.0
    BoundaryThreads_B(iBlock) % PSi_III = 0.0
    BoundaryThreads_B(iBlock) % nPoint_II = 0
    BoundaryThreads_B(iBlock) % DeltaR_II = 1.0
    !\
    ! sqrt(CoefXi/VAlfven[NoDim]) is dXi/ds[NoDim]
    ! While setting thread,  we calculate only the thread-dependent
    ! sqrt(CoefXi/B[NoDim]). In ModThreadedLC DXi will be multiplied
    ! by RhoNoDim**0.25
    !/
    CoefXi = PoyntingFluxPerB/LperpTimesSqrtB**2

    ! Loop over the thread starting points
    do k = kMin_, kMax_; do j = jMin_, jMax_
       !\
       ! First, take magnetic field in the ghost cell
       !/
       !\
       ! Starting points for all threads are in the centers
       ! of  physical cells near the boundary
       !/
       XyzStart_D = Xyz_DGB(:, 1, j, k, iBlock)
       !\
       ! Calculate a field in the starting point
       !/
       call get_b0(XyzStart_D, B0Start_D)
       if(UseCME)then
          call EEE_get_state_BC(XyzStart_D, RhoCme, Ucme_D, Bcme_D, pCme, &
               time_simulation, n_step, iteration_number)
          Bcme_D = Bcme_D*Si2No_V(UnitB_)
          B0Start_D = B0Start_D + Bcme_D
       end if

       SignBr = sign(1.0, sum(XyzStart_D*B0Start_D) )

       B0Start = norm2(B0Start_D)
       BoundaryThreads_B(iBlock) % B_III(0, j, k) = B0Start

       RStart = norm2(XyzStart_D)
       BoundaryThreads_B(iBlock) % RInv_III(0, j, k) = 1/RStart
       call xyz_to_coord(XyzStart_D, Coord_D)
       BoundaryThreads_B(iBlock) % Coord1_III(0, j, k) = Coord_D(r_)

       Ds = 0.50*DsThreadMin ! To enter the grid coarsening loop
       COARSEN: do nTrial=1,nCoarseMax ! Ds is increased to 0.002 or 0.016
          !\
          ! Set initial Ds or increase Ds, if previous trial fails
          !/
          Ds = Ds * 2
          iPoint = 0
          Xyz_D = XyzStart_D
          B0 = B0Start
          B0_D = B0Start_D
          R = RStart
          if(nTrial==nCoarseMax)then
             CosBRMin = ( (RStart**2-rBody**2)/nPointThreadMax +Ds**2)/&
                  (2*rBody*Ds)
             if(CosBRMin>0.9)call stop_mpi('Increase nPointThreadMax')
          end if
          POINTS: do
             iPoint = iPoint + 1
             !\
             ! If the number of gridpoints in the theads is too
             ! high, coarsen the grid
             !/
             if(iPoint > nPointThreadMax)CYCLE COARSEN
             !\
             ! For the previous point given are Xyz_D, B0_D, B0
             ! R is only used near the photospheric end.
             !/
             ! Two stage Runge-Kutta
             ! 1. Point at the half of length interval:
             DirR_D = Xyz_D/R
             DirB_D = SignBr*B0_D/max(B0, cTolerance)
             if(nTrial==nCoarseMax)call limit_cosBR
             XyzAux_D = Xyz_D - 0.50*Ds*DirB_D

             ! 2. Magnetic field in this point:
             call get_b0(XyzAux_D, B0Aux_D)
             if(UseCME)then
                call EEE_get_state_BC(XyzAux_D, RhoCme, Ucme_D, Bcme_D, pCme, &
                     time_simulation, n_step, iteration_number)
                Bcme_D = Bcme_D*Si2No_V(UnitB_)
                B0Aux_D = B0Aux_D + Bcme_D
             end if
             DirB_D = SignBr*B0Aux_D/max(norm2(B0Aux_D), cTolerance**2)
             if(nTrial==nCoarseMax)call limit_cosBR
             ! 3. New grid point:
             Xyz_D = Xyz_D - Ds*DirB_D
             R = norm2(Xyz_D)
             if(R <= rBody)EXIT COARSEN
             if(R > RStart)CYCLE COARSEN
             !\
             ! Store a point
             !/
             XyzOld_D = Xyz_D
             BoundaryThreads_B(iBlock) % RInv_III(-iPoint, j, k) = 1/R
             call xyz_to_coord(Xyz_D, Coord_D)
             BoundaryThreads_B(iBlock) % Coord1_III(-iPoint, j, k) = Coord_D(r_)
             call get_b0(Xyz_D, B0_D)
             if(UseCME)then
                call EEE_get_state_BC(Xyz_D, RhoCme, Ucme_D, Bcme_D, pCme, &
                     time_simulation, n_step, iteration_number)
                Bcme_D = Bcme_D*Si2No_V(UnitB_)
                B0_D = B0_D + Bcme_D
             end if
             B0 = norm2(B0_D)
             BoundaryThreads_B(iBlock) % B_III(-iPoint, j, k) = B0
          end do POINTS
       end do COARSEN
       if(R > rBody)then
          write(*,*)'iPoint, R=', iPoint, R
          call stop_mpi('Thread did not reach the photosphere!')
       end if

       ! Calculate more accurately the intersection point
       ! with the photosphere surface
       ROld = 1/BoundaryThreads_B(iBlock) % RInv_III(1-iPoint, j, k)
       Aux = (ROld - RBody) / (ROld -R)
       Xyz_D =(1 - Aux)*XyzOld_D +  Aux*Xyz_D
       !\
       ! Store the last point
       !/
       BoundaryThreads_B(iBlock) % RInv_III(-iPoint, j, k) = 1/RBody
       call get_b0(Xyz_D, B0_D)
       B0 = norm2(B0_D)
       BoundaryThreads_B(iBlock) % B_III(-iPoint, j, k) = B0
       !\
       ! Store the number of points. This will be the number of temperature
       ! nodes such that the first one is on the top of the TR, the last
       ! one is in the center of physical cell
       !/
       nPoint = iPoint + 1 - nIntervalTR
       BoundaryThreads_B(iBlock) % nPoint_II(j,k) = nPoint
       BoundaryThreads_B(iBlock)%TGrav_III(2-nPoint:0,j,k) = &
            GravHydroStat*&
            (-BoundaryThreads_B(iBlock)%RInv_III(2-nPoint:0,j,k) + &
            BoundaryThreads_B(iBlock)%RInv_III(1-nPoint:-1,j,k))

       !\
       ! Store the lengths
       !/
       BoundaryThreads_B(iBlock) % LengthSi_III(1-iPoint, j, k) = &
            Ds*Aux*No2Si_V(UnitX_)
       BoundaryThreads_B(iBlock) % BDsInvSi_III(1-iPoint, j, k) = &
            Ds*Aux*0.50*(                                         &
            BoundaryThreads_B(iBlock) % B_III(-iPoint, j, k) +    &
            BoundaryThreads_B(iBlock) % B_III(1-iPoint, j, k) )
       iPoint = iPoint - 1
       !\
       !     |           |
       !-iPoint-1      -iPoint
       !/
       iInterval = 1
       do while(iInterval < nIntervalTR)
          BoundaryThreads_B(iBlock) % LengthSi_III(1-iPoint, j, k) =     &
               BoundaryThreads_B(iBlock) % LengthSi_III(-iPoint, j, k) + &
               Ds*No2Si_V(UnitX_)
          BoundaryThreads_B(iBlock) % BDsInvSi_III(1-iPoint, j, k) =     &
               BoundaryThreads_B(iBlock) % BDsInvSi_III(-iPoint, j, k) + &
               Ds*0.50*(&
               BoundaryThreads_B(iBlock) % B_III( -iPoint, j, k) +       &
               BoundaryThreads_B(iBlock) % B_III(1-iPoint, j, k) )
          iPoint = iPoint - 1
          iInterval = iInterval + 1
       end do
       !\
       !     |            |...........|           Temperature nodes
       !-iPoint-nInterval          -iPoint
       !                        x           x            Flux nodes
       !                    -iPoint-1    -iPoint
       ! Here, iPoint is the current value, equal to nPoint-1, nPoint being the
       ! stored value. Now, LengthSi = Ds*(nInterval - 1 + Aux), as long as the
       ! first interval is shorter than Ds. Then, BDsInvSi is the
       ! dimensionless and not inverted integral of Bds over the first
       ! intervals.
       !/

       BoundaryThreads_B(iBlock) % BDsInvSi_III(-1-iPoint, j, k) = 1/  &
            (BoundaryThreads_B(iBlock) % LengthSi_III(-iPoint, j, k)*  &
            BoundaryThreads_B(iBlock) % B_III(-iPoint, j, k)*          &
            No2Si_V(UnitB_)*PoyntingFluxPerBSi)

       !\
       ! The flux node -iPoint-1=-nPoint is placed to the same position
       ! as the temperature node with the same number
       !/
       BoundaryThreads_B(iBlock) % Xi_III(-iPoint, j, k) =             &
            0.50*Ds*sqrt(CoefXi/                                       &
            BoundaryThreads_B(iBlock) % B_III(-iPoint, j, k))
       !\
       ! As long as the flux node is placed as discussed above, the
       ! first computational cell is twice shorter
       !/
       BoundaryThreads_B(iBlock) % DsOverBSi_III(-iPoint, j, k) =      &
            0.50*Ds*No2Si_V(UnitX_)/                                   &
            ( BoundaryThreads_B(iBlock) % B_III(-iPoint, j, k)&
            *PoyntingFluxPerBSi*No2Si_V(UnitB_) )

       do while(iPoint>0)
          !\
          ! Just the length of Thread in meters
          !/
          BoundaryThreads_B(iBlock) % LengthSi_III(1-iPoint, j, k) =      &
               BoundaryThreads_B(iBlock) % LengthSi_III(-iPoint, j, k ) + &
               Ds*No2Si_V(UnitX_)
          !\
          ! Sum up the integral of Bds, dimensionless, to calculate TMax
          !/
          BoundaryThreads_B(iBlock) % BDsInvSi_III(1-iPoint, j, k) =      &
               BoundaryThreads_B(iBlock) % BDsInvSi_III(-iPoint, j, k) +  &
               Ds*0.50*(&
               BoundaryThreads_B(iBlock) % B_III(-iPoint, j, k) +&
               BoundaryThreads_B(iBlock) % B_III(1-iPoint, j, k) )
          !\
          ! 1/(ds*B*Poynting-flux-over-field ratio)
          ! calculated in the flux point, so that the averaged magnetic field
          ! is used. Calculated in SI units. While multiplied by the difference
          ! in the conservative variable, 2/7*kappa*\Delta T^{7/2} gives the
          ! ratio of the heat flux to the effective Poynting flux.
          !/
          BoundaryThreads_B(iBlock) % BDsInvSi_III(-iPoint, j, k) =   1/  &
               (PoyntingFluxPerBSi*No2Si_V(UnitB_)*&
               No2Si_V(UnitX_)*Ds*0.50*(&
               BoundaryThreads_B(iBlock) % B_III(-iPoint, j, k) +&
               BoundaryThreads_B(iBlock) % B_III(1-iPoint, j, k) ) )
          !\
          ! The distance between the flux points (as well as the AW amplitude
          ! nodes multiplied by the coefficient to find dimensionless
          ! wave damping per the unit of length. Calculated in terms of
          ! the magnetic field in the midpoint. Should be multiplied by the
          ! dimensionless density powered 1/4. Dimensionless.
          !/
          BoundaryThreads_B(iBlock) % Xi_III(1-iPoint, j, k) =            &
               BoundaryThreads_B(iBlock) % Xi_III(-iPoint, j, k)        + &
               Ds*sqrt(CoefXi/               &
               BoundaryThreads_B(iBlock) % B_III(1-iPoint, j, k))
          !\
          ! Distance between the flux points (faces) divided by
          ! the magnetic field in the temperature point (or, same,
          ! multiplied by the crosssection of the flux tube)
          ! and divided by the Poynting-flux-to-field ratio.
          !/
          BoundaryThreads_B(iBlock) % DsOverBSi_III(1-iPoint, j, k) =     &
               Ds*No2Si_V(UnitX_)/                                        &
               (BoundaryThreads_B(iBlock) % B_III(1-iPoint, j, k)         &
               *PoyntingFluxPerBSi*No2Si_V(UnitB_))
          iPoint = iPoint - 1
       end do
       !\
       !          |       |           Temperature nodes
       !         -1       0
       !              x       x       Flux nodes
       !             -1       0
       !/

       !\
       ! Correct the effective length of the last flux node
       !          |       |           Temperature nodes
       !         -1       0
       !              x   <---x       Flux nodes
       !             -1       0
       !
       !/
       BoundaryThreads_B(iBlock) % Xi_III(0, j, k) =         &
            BoundaryThreads_B(iBlock) % Xi_III(0, j, k) -    &
            0.50*Ds*sqrt(CoefXi/                             &
            BoundaryThreads_B(iBlock) % B_III(0, j, k))

       BoundaryThreads_B(iBlock) % DeltaR_II(j,k) = &
            norm2(Xyz_DGB(:,1,j,k,iBlock) - Xyz_DGB(:,0,j,k,iBlock) )

       call limit_temperature(BoundaryThreads_B(iBlock) % BDsInvSi_III(&
               0, j, k), BoundaryThreads_B(iBlock) % TMax_II(j, k))

    end do; end do
    if(DoThreadRestart)call read_thread_restart(iBlock)

    if(DoTest.and.iBlock==iBlockTest)then
       write(*,'(a,3es18.10)')'Thread starting at the point  ',&
            Xyz_DGB(:,1,jTest,kTest,iBlock)
       write(*,'(a,3es18.10)')'DeltaR=  ',&
            BoundaryThreads_B(iBlock) % DeltaR_II(jTest,kTest)
       write(*,'(a)')&
            'B[NoDim] RInv[NoDim] LengthSi BDsInvSi Xi[NoDim]'
       do iPoint = 0, -BoundaryThreads_B(iBlock) % nPoint_II(jTest,kTest),-1
          write(*,'(5es18.10)')&
               BoundaryThreads_B(iBlock) % B_III(&
               iPoint, jTest,kTest),&
               BoundaryThreads_B(iBlock) % RInv_III(&
               iPoint, jTest,kTest),&
               BoundaryThreads_B(iBlock) % LengthSi_III(&
               iPoint, jTest, kTest),&
               BoundaryThreads_B(iBlock) % BDsInvSi_III(&
               iPoint, jTest, kTest),&
               BoundaryThreads_B(iBlock) % Xi_III(&
               iPoint, jTest, kTest)
       end do
    end if
    call test_stop(NameSub, DoTest, iBlock)
  contains
    !==========================================================================
    subroutine limit_cosbr
      real::CosBR
      !------------------------------------------------------------------------
      CosBR = sum(DirB_D*DirR_D)
      if(CosBR>=CosBRMin)RETURN
      DirB_D = (DirB_D - CosBR*DirR_D)*&      ! Tangential componenets
           sqrt((1 - CosBRMin**2)/(1 - CosBR**2))+& ! Reduced in magnitude
           DirR_D*CosBRMin          ! Plus increased radial comp
    end subroutine limit_cosbr
    !==========================================================================
    subroutine limit_temperature(BLength, TMax)
      use ModPhysics,      ONLY: UnitX_, Si2No_V, UnitB_
      use ModLookupTable,  ONLY: i_lookup_table, interpolate_lookup_table
      real, intent(in)  :: BLength
      real, intent(out) :: TMax
      real :: HeatFluxXLength, Value_V(6)
      integer:: iTable
      !------------------------------------------------------------------------
      iTable = i_lookup_table('TR')
      if(iTable<=0)call stop_mpi('TR table is not set')

      HeatFluxXLength = 2*PoyntingFluxPerBSi*&
           BLength*No2Si_V(UnitX_)*No2Si_V(UnitB_)
      call interpolate_lookup_table(iTable=iTable,&
                                    iVal=HeatFluxLength_,       &
                                    ValIn=HeatFluxXLength,&
                                    Arg2In=1.0e8, &
                                    Value_V=Value_V,      &
                                    Arg1Out=TMax,  &
                                    DoExtrapolate=.false.)
      !\
      ! Version Easter 2015
      ! Globally limiting the temparture is mot much
      ! physical, however, at large enough timerature
      ! the existing semi-implicit solver is unstable
      !/
      TMax = min(TMax,TeGlobalMaxSi)*Si2No_V(UnitTemperature_)
    end subroutine limit_temperature
    !==========================================================================
  end subroutine set_threads_b
  !============================================================================
  subroutine check_tr_table(TypeFileIn)
    use ModConst,      ONLY: cBoltzmann, cElectronMass, &
         cEps, cElectronCharge, cTwoPi, cProtonMass
    use ModLookupTable, ONLY: &
         i_lookup_table, init_lookup_table, make_lookup_table

    character(LEN=*),optional,intent(in)::TypeFileIn

    integer:: iTable
    real,parameter:: CoulombLog = 20.0
    character(len=5)::TypeFile

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'check_tr_table'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)
    if(present(TypeFileIn))then
       TypeFile = TypeFileIn
    else
       TypeFile = 'ascii'
    end if
    ! electron heat conduct coefficient for single charged ions
    ! = 9.2e-12 W/(m*K^(7/2))
    HeatCondParSi = 3.2*3.0*cTwoPi/CoulombLog &
         *sqrt(cTwoPi*cBoltzmann/cElectronMass)*cBoltzmann &
         *((cEps/cElectronCharge)*(cBoltzmann/cElectronCharge))**2

    !\
    ! In hydrogen palsma, the electron-ion heat exchange is described by
    ! the equation as follows:
    ! dTe/dt = -(Te-Ti)/(tau_{ei})
    ! dTi/dt = +(Te-Ti)/(tau_{ei})
    ! The expression for 1/tau_{ei} may be found in
    ! Lifshitz&Pitaevskii, Physical Kinetics, Eq.42.5
    ! note that in the Russian edition they denote k_B T as Te and
    ! the factor 3 is missed in the denominator:
    ! 1/tau_ei = 2* CoulombLog * sqrt{m_e} (e^2/cEps)**2* Z**2 *Ni /&
    ! ( 3 * (2\pi k_B Te)**1.5 M_p). This exchange rate scales linearly
    ! with the plasma density, therefore, we introduce its ratio to
    ! the particle concentration. We calculate the temperature exchange
    ! rate by multiplying the expression for electron-ion effective
    ! collision rate,
    ! \nu_{ei} = CoulombLog/sqrt(cElectronMass)*  &
    !            ( cElectronCharge**2 / cEps)**2 /&
    !            ( 3 *(cTwoPi*cBoltzmann)**1.50 )* Ne/Te**1.5
    !  and then multiply in by the energy exchange coefficient
    !            (2*cElectronMass/cProtonMass)
    ! The calculation of the effective electron-ion collision rate is
    ! re-usable and can be also applied to calculate the resistivity:
    ! \eta = m \nu_{ei}/(e**2 Ne)
    !/
    cExchangeRateSi = &
         CoulombLog/sqrt(cElectronMass)*  &!\
         ( cElectronCharge**2 / cEps)**2 /&! effective ei collision frequency
         ( 3 *(cTwoPi*cBoltzmann)**1.50 ) &!/
         *(2*cElectronMass/cProtonMass)  /&! *energy exchange per ei collision
         cBoltzmann
    !\
    ! an ultimate energy density equals
    ! Z/(\gamma -1)*cExchangeRateSi*(Te -Ti)/Te^{7/2}Pe^2
    !/

    iTable =  i_lookup_table('TR')
    if(iTable < 0)then

       ! initialize the TR table
       call init_lookup_table(                                      &
            NameTable = 'TR',                                       &
            NameCommand = 'save',                                   &
            NameVar =                                               &
            'logTe logNe '//                                        &
            'LPe UHeat FluxXLength dFluxXLegthOverDU Lambda dLogLambdaOverDLogT',&
            nIndex_I = [500,2],                                   &
            IndexMin_I = [1.0e4, 1.0e8],                           &
            IndexMax_I = [1.0e8, 1.0e18],                          &
            NameFile = 'TR.dat',                                    &
            TypeFile = TypeFile,                                    &
            StringDescription = &
            'Model for transition region: [K] [1/m3] [N/m] [m/s] [W/m] [1]')

       iTable = i_lookup_table('TR')

       ! The table is now initialized.

       ! Fill in the table
       call make_lookup_table(iTable, calc_tr_table)
    end if
    call test_stop(NameSub, DoTest)
  end subroutine check_tr_table
  !============================================================================
  subroutine calc_tr_table(iTableIn, Arg1, Arg2, Value_V)
    use ModLookupTable, ONLY: interpolate_lookup_table, i_lookup_table
    use ModConst,      ONLY: cBoltzmann
    integer, intent(in):: iTableIn
    real, intent(in)   :: Arg1, Arg2
    real, intent(out)  :: Value_V(:)
    integer:: iTable, iTe
    real   :: DeltaLogTe, LambdaCgs_V(1)

    logical, save:: IsFirstCall = .true.
    ! at the moment, radcool not a function of Ne, but need a dummy 2nd
    ! index, and might want to include Ne dependence in table later.
    ! Table variable should be normalized to radloss_cgs * 10E+22
    ! since we don't want to deal with such tiny numbers
    ! real, parameter :: RadNorm = 1.0E+22
    ! real, parameter :: Cgs2SiEnergyDens = &
    !     1.0e-7&   ! erg = 1e-7 J
    !     /1.0e-6    ! cm3 = 1e-6 m3
    ! real, parameter :: Radcool2Si = 1.0e-12 & ! (cm-3=>m-3)**2
    !     /RadNorm*Cgs2SiEnergyDens

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'calc_tr_table'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)
    DeltaLogTe = log(1.0e8/1.0e4)/499 ! Log(MaxTe/MinTe)/(nPoint-1)
    if(IsFirstCall)then
       IsFirstCall=.false.
       iTable = i_lookup_table('radcool')
       if(iTable<=0)&
            call stop_mpi('Transition region table needs radcool table')

       TeSi_I(1) = 1.0e4; LPe_I(1) = 0.0; UHeat_I(1) = 0.0
       do iTe = 2,500
          TeSi_I(iTe) = TeSi_I(iTe-1)*exp(DeltaLogTe)
       end do

       do iTe = 2,500
          call interpolate_lookup_table(iTable,&
               TeSi_I(iTe), 1.0e2, LambdaCgs_V)
          LambdaSi_I(iTe) = LambdaCgs_V(1)*Radcool2Si
          if(iTe==1)CYCLE
          !\
          ! Integrate \sqrt{2\int{\kappa_0\Lambda Te**1.5 d(log T)}}/k_B
          !/
          UHeat_I(iTe) = UHeat_I(iTe-1) + &
               (LambdaSi_I(iTe-1)*TeSi_I(iTe-1)**1.50 + &
               LambdaSi_I(iTe)*TeSi_I(iTe)**1.50)*DeltaLogTe
       end do
       UHeat_I = sqrt(HeatCondParSi*UHeat_I)/cBoltzmann

       !\
       ! Temporary fix to avoid a singularity in the first point
       !/
       UHeat_I(1) = UHeat_I(2)
       do iTe = 2,500
          !\
          ! Integrate \int{\kappa_0\Lambda Te**3.5 d(log T)/UHeat}
          !/
          LPe_I(iTe) = LPe_I(iTe-1) + 0.5*DeltaLogTe* &
               ( TeSi_I(iTe-1)**3.50/UHeat_I(iTe-1) + &
               TeSi_I(iTe)**3.50/UHeat_I(iTe) )
          !\
          ! Not multiplied by \lappa_0
          !/
       end do
       dFluxXLengthOverDU_I(1) = &
            (LPe_I(2)*UHeat_I(2) - LPe_I(1)*UHeat_I(1))/&
            (DeltaLogTe*TeSi_I(1)**3.50)
       do iTe = 2,499
          dFluxXLengthOverDU_I(iTe) = &
               (LPe_I(iTe+1)*UHeat_I(iTe+1) - LPe_I(iTe-1)*UHeat_I(iTe-1))/&
               (2*DeltaLogTe*TeSi_I(iTe)**3.50)
       end do
       dFluxXLengthOverDU_I(500) = &
            (LPe_I(500)*UHeat_I(500) - LPe_I(499)*UHeat_I(499))/&
            (DeltaLogTe*TeSi_I(500)**3.50)

       LPe_I = LPe_I*HeatCondParSi
       UHeat_I(1) = 0.0
       !\
       ! Calculate dLogLambda/DLogTe
       !/
       DLogLambdaOverDLogT_I(1) = log(LambdaSi_I(2)/LambdaSi_I(1))/&
            DeltaLogTe
       do iTe = 2,499
          DLogLambdaOverDLogT_I(iTe) = log(LambdaSi_I(iTe+1)/LambdaSi_I(iTe-1))/&
            (2*DeltaLogTe)
       end do
       DLogLambdaOverDLogT_I(500) = log(LambdaSi_I(500)/LambdaSi_I(499))/&
            DeltaLogTe
    end if
    iTe = 1 + nint(log(Arg1/1.0e4)/DeltaLogTe)
    Value_V(LengthPAvrSi_:DLogLambdaOverDLogT_) = [ LPe_I(iTe), UHeat_I(iTe), &
         LPe_I(iTe)*UHeat_I(iTe), dFluxXLengthOverDU_I(iTe), &
         LambdaSi_I(iTe)/cBoltzmann**2, DLogLambdaOverDLogT_I(iTe)]

    call test_stop(NameSub, DoTest)
  end subroutine calc_tr_table
  !============================================================================
  subroutine advance_threads(iAction)

    use BATL_lib, ONLY: nBlock, Unused_B

    integer, intent(in)::iAction

    integer:: iBlock
    logical:: DoTest
    character(len=*), parameter:: NameSub = 'advance_threads'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)
    do iBlock = 1, nBlock
       if(Unused_B(iBlock))CYCLE
       if(.not.IsAllocatedThread_B(iBlock))CYCLE
       if(BoundaryThreads_B(iBlock)%iAction /= Done_)&
            call stop_mpi('An attempt to readvance not advanced threads')
       BoundaryThreads_B(iBlock)%iAction = iAction
    end do

    call test_stop(NameSub, DoTest)
  end subroutine advance_threads
  !============================================================================
  subroutine read_thread_restart(iBlock)
    use ModMain,       ONLY: NameThisComp
    use ModIoUnit,     ONLY: UnitTmp_
    use ModUtilities,  ONLY: open_file, close_file
    integer, intent(in) :: iBlock
    !\
    ! loop variables
    !/
    integer :: j, k
    !\
    ! Misc:
    integer :: nPoint, iError
    real    :: RealNPoint
    logical:: DoTest
    character(len=*), parameter:: NameSub = 'read_thread_restart'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest, iBlock)
    call get_restart_file_name(iBlock, NameThisComp//'/restartIN/')
    call open_file(file=NameRestartFile, status='old', &
         form='UNFORMATTED', NameCaller=NameSub)
    do k = 1,nK; do j = 1, nJ
       read(UnitTmp_, iostat = iError)RealNPoint
       if(iError>0)then
          write(*,*)'Error in reading nPoint in Block=', iBlock
          call close_file
          RETURN
       end if
       nPoint = nint(RealNPoint)
       if(BoundaryThreads_B(iBlock) % nPoint_II(j,k)/=nPoint)then
          write(*,*)'Incorrest nPoint in Block=', iBlock
          call close_file
          RETURN
       end if
       read(UnitTmp_, iostat = iError) &
            BoundaryThreads_B(iBlock) % TeSi_III(1-nPoint:0,j,k), &
            BoundaryThreads_B(iBlock) % TiSi_III(1-nPoint:0,j,k), &
            BoundaryThreads_B(iBlock) % PSi_III(1-nPoint:0,j,k)
    end do; end do
    call close_file
    BoundaryThreads_B(iBlock) % iAction = Enthalpy_
    call test_stop(NameSub, DoTest, iBlock)
  end subroutine read_thread_restart
  !============================================================================
  subroutine save_thread_restart
    use ModMain,       ONLY: NameThisComp
    use BATL_lib, ONLY: nBlock, Unused_B
    use ModIoUnit,     ONLY: UnitTmp_
    use ModUtilities,  ONLY: open_file, close_file
    integer :: j, k, iBlock, nPoint
    logical:: DoTest
    character(len=*), parameter:: NameSub = 'save_thread_restart'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)
    do iBlock = 1, nBlock
       if(Unused_B(iBlock))CYCLE
       if(.not.IsAllocatedThread_B(iBlock))CYCLE
       call get_restart_file_name(iBlock, NameThisComp//'/restartOUT/')
       call open_file(file=NameRestartFile, form='UNFORMATTED',&
            NameCaller=NameSub)
       do k = 1,nK; do j = 1, nJ
          nPoint = BoundaryThreads_B(iBlock) % nPoint_II(j,k)
          write(UnitTmp_)real(nPoint)
          write(UnitTmp_)&
               BoundaryThreads_B(iBlock) % TeSi_III(1-nPoint:0,j,k),&
               BoundaryThreads_B(iBlock) % TiSi_III(1-nPoint:0,j,k),&
               BoundaryThreads_B(iBlock) % PSi_III(1-nPoint:0,j,k)
       end do; end do
       call close_file
    end do
    call test_stop(NameSub, DoTest)
  end subroutine save_thread_restart
  !============================================================================
  subroutine get_restart_file_name(iBlock, NameRestartDir)
    use BATL_lib,      ONLY: iMortonNode_A, iNode_B

    integer, intent(in)          :: iBlock
    character(len=*), intent(in) :: NameRestartDir

    integer  :: iBlockRestart
    character:: StringDigit

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'get_restart_file_name'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest, iBlock)
    iBlockRestart = iMortonNode_A(iNode_B(iBlock))

    write(StringDigit,'(i1)') max(5,int(1+alog10(real(iBlockRestart))))

    write(NameRestartFile,'(a,i'//StringDigit//'.'//StringDigit//',a)')&
         trim(NameRestartDir)//'thread_',iBlockRestart,'.blk'
    call test_stop(NameSub, DoTest, iBlock)
  end subroutine get_restart_file_name
  !============================================================================
end module ModFieldLineThread
!==============================================================================
