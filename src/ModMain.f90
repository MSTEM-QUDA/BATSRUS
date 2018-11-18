!  Copyright (C) 2002 Regents of the University of Michigan,
!  portions used with permission
!  For more information, see http://csem.engin.umich.edu/tools/swmf

module ModMain

  use ModKind
  use ModSize
  use ModVarIndexes
  use ModNumConst, ONLY: cPi, cTwoPi

  ! Total number of used blocks on all processors
  use BATL_lib, ONLY: nBlock, nBlockAll => nNodeUsed, Unused_B, lVerbose

  implicit none

  save

  !\
  ! Version of BATSRUS
  !/
  real, parameter :: CodeVersion = 9.20
  real            :: CodeVersionRead = -1.0

  !\
  ! Standalone and component information
  !/
  ! In stand alone mode this variable is set to true
  logical             :: IsStandAlone = .false.

  ! In the SWMF the BATSRUS may run as GM, SC or IH component
  character (len=2)   :: NameThisComp='GM'

  ! In hydro equations B_ = U_ is set.
  logical, parameter:: UseB = B_ /= U_

  !\
  ! Time stepping parameters and values.
  !/
  integer :: n_step, nOrder, iStage, nStage, iteration_number=0, nOrderOld
  logical :: UseHalfStep = .true. ! true for the Dt/2, Dt update scheme

  real :: dt
  real :: DtFixed
  real :: DtFixedOrig
  real :: DtFixedDim
  real :: Cfl
  real :: CflOrig
  real, allocatable :: dt_BLK(:)
  logical :: time_accurate = .true.,  time_loop = .false.

  ! Limiting speed in the numerical diffusive flux (for implicit scheme only)
  real :: Climit = -1.0

  ! Fixed time step (only for time accurate and for implicit scheme mostly)
  logical :: UseDtFixed

  ! Limited time step
  logical :: UseDtLimit
  real    :: DtLimit, DtLimitOrig, DtLimitDim

  ! Local time stepping (subcycling)
  logical:: UseLocalTimeStep    = .false.
  logical:: UseLocalTimeStepNew = .false. ! if just switched on

  !\
  ! Model Coupling variables
  !/
  ! Dimensions of the buffer grid between SC and IH
  logical :: UseBufferGrid    = .false.
  logical :: UseHelioBuffer3D = .false.
  integer :: nPhiBuff = 90,   nThetaBuff = 45, nRBuff = 2
  real    :: dSphBuff_D(3)
  real    :: BufferMin_D(3) = [ 19.0,    0.0, 0.0]
  real    :: BufferMax_D(3) = [ 21.0, cTwoPi, cPi]

  real, allocatable:: BufferState_VG(:,:,:,:)
  ! Named indexes for the spherical buffer (left handed coordinates!!! )
  integer, parameter :: BuffR_=1, BuffPhi_=2, BuffTheta_=3

  logical :: UseIe = .false.
  logical :: UsePw = .false.

  logical :: UseIm = .false.
  logical :: DoCoupleImPressure = .true.
  logical :: DoCoupleImDensity  = .false.
  logical :: DoFixPolarRegion   = .false.
  logical :: DoImSatTrace       = .false.
  logical :: DoRbSatTrace       = .false.
  real    :: rFixPolarRegion    = 5.0
  real    :: dLatSmoothIm       = -1.0
  real    :: TauCoupleIm        = 20.0
  real    :: RhoMinDimIm        = -1.0

  logical :: UseRaytrace            = UseB
  logical :: DoMultiFluidIMCoupling = &
       IonLast_ > IonFirst_ .or. SpeciesLast_ > SpeciesFirst_
  logical :: DoAnisoPressureIMCoupling = .false.

  ! Single space separated NameVar string containing all the variable
  ! names of NameVar_V (except for the fluid energies)
  character(len=500) :: NameVarCouple

  ! Intrinsic field B0 may or may not be used if UseB is true.
  logical :: UseB0        = UseB

  !\
  ! Coronal magnetic field (magnetogram + EE generator)
  !/

  logical :: UseMagnetogram=.false., UseNewMagnetogram = .false.
  real    :: tMagnetogram
  logical :: UseEmpiricalSW = .false.

  !\
  ! Inner and outer boundaries
  !/
  ! Indexes for boundaries
  integer, parameter :: body1_   = -1
  integer, parameter :: body2_   = -2
  integer, parameter :: ExtraBc_ =  0
  integer, parameter :: SolidBc_ = -3
  integer, parameter :: &
       Coord1MinBc_ = 1, Coord1MaxBc_ = 2, &
       Coord2MinBc_ = 3, Coord2MaxBc_ = 4, &
       Coord3MinBc_ = 5, Coord3MaxBc_ = 6, &
       xMinBc_ = 1, xMaxBc_ = 2, &
       yMinBc_ = 3, yMaxBc_ = 4, &
       zMinBc_ = 5, zMaxBc_ = 6

  ! Inner and outer boundary conditions
  character(len=20) :: TypeCellBc_I(Coord1MinBc_:Coord3MaxBc_)='none'
  character(len=20) :: TypeFaceBc_I(SolidBc_:zMaxBc_)='none'

  ! Logicals for bodies
  logical:: Body1    = .false.
  logical:: UseBody2 = .false.

  !\
  ! Block AMR grid parameters
  !/

  ! Identifiers for the grid and decomposition changes
  integer :: iNewGrid=0, iNewDecomposition=0

  ! Number of geometric based refinements performed
  ! (needed by the CCMC user module only! )
  integer :: nRefineLevel = 0

  ! nBlockMax is a maximum block index over all processors
  integer :: nBlockMax

  ! Number of explicitly and implicitly advanced blocks
  integer :: nBlockExplAll, nBlockImplAll

  ! Index limits for the cell faces (needed for the constrained trasnsport)
  integer, parameter :: nIFace=nI+1
  integer, parameter :: nJFace=nJ+1
  integer, parameter :: nKFace=nK+1

  ! Limits in the orthogonal directions. Default is no ghost cells,
  ! but this can be changed to 1 or 2 ghost cells depending on scheme
  integer:: &
       iMinFace = 1, iMaxFace = nI, iMinFace2 = 1, iMaxFace2 = nI, &
       jMinFace = 1, jMaxFace = nJ, jMinFace2 = 1, jMaxFace2 = nJ, &
       kMinFace = 1, kMaxFace = nK, kMinFace2 = 1, kMaxFace2 = nK

  !\
  ! How to deal with div B = 0
  !/
  logical :: UseDivbSource    = UseB
  logical :: UseDivbDiffusion = .false.
  logical :: UseProjection    = .false.
  logical :: UseConstrainB    = .false.
  logical :: UseHyperbolicDivb= .false.
  real    :: SpeedHypDim = -1.0, SpeedHyp = 1.0
  real    :: HypDecay = 0.1

  !\
  ! More numerical scheme parameters
  !/
  ! Prolongation order
  integer           :: nOrderProlong = 1

  ! Message passing mode ('all' or 'allopt' ...)
  character(len=10) :: optimize_message_pass = 'allopt'

  !\
  ! Source terms
  !/

  ! Logicals for adding radiation diffusion and heat conduction
  logical :: UseRadDiffusion = .false.
  logical :: UseHeatConduction = .false.
  logical :: UseIonHeatConduction = .false.

  ! Logical and type for gravity
  logical :: UseGravity = .false.
  integer :: GravityDir = 0
  real    :: GravitySi = 0.0

  !\
  ! Rotation and coordinate system
  !/

  ! Logical for rotating inner boundary
  logical          :: UseRotatingBc = .false.

  ! Coordinate system
  character(len=3) :: TypeCoordSystem = 'GSM'

  ! Rotating frame or (at least approximately) inertial frame
  logical :: UseRotatingFrame = .false.

  ! Transform initial condition between rotating and inertial frames
  integer:: iSignRotationIC = 0

  !\
  ! Variables for debugging.
  !/

  ! Shall we be strict about errors in the input parameter file
  logical :: UseStrict=.true.

  ! Debug logicals
  logical :: okdebug=.false., ShowGhostCells=.true.

  !\
  ! Time and timing variables
  !/
  real :: Time_Simulation = 0.0
  real :: Time_SimulationOld = 0.0

  ! This is the same default value as in the SWMF
  integer, dimension(7) :: iStartTime_I = [2000,3,21,10,45,0,0]
  real(Real8_)          :: StartTime

  !\
  ! Time to end
  !/
  logical :: UseEndTime = .false.

  integer,dimension(7)  :: iEndTime_I   = [2000,3,21,10,45,0,0]
  real(Real8_)          :: EndTime

  ! Timing variables
  logical:: UseTiming = .true.
  logical:: UseTimingAll = .false.
  integer:: iUnitTiming = 6
  character(len=30):: NameTimingFile
  integer:: dn_timing = -2

  ! Optimize MPI variables
  logical :: UseOptimizeMpi = .false.

  !\
  ! Stopping conditions. These variables are only used in stand alone mode.
  ! The only exeption is t_Max. It may be also used in the SWMF mode to control
  ! evolving B0 field with the use of two magnetograms, one at tSimulation=0,
  ! the other at tSimulation=t_Max.
  !/
  real    :: t_Max = -1.0, cputime_max = -1.0
  integer :: nIter = -1
  logical :: Check_Stopfile = .true.
  logical :: IsLastRead = .false.

  !\
  ! Controling the use of the features implemented in user files
  !/
  logical:: UseUserInnerBcs          = .false.
  logical:: UseUserSource            = .false.
  logical:: UseUserPerturbation      = .false.
  logical:: UseUserOuterBcs          = .false.
  logical:: UseUserICs               = .false.
  logical:: UseUserSpecifyRefinement = .false.
  logical:: UseUserLogFiles          = .false.
  logical:: UseUserWritePlot         = .false.
  logical:: UseUserAMR               = .false.
  logical:: UseUserEchoInput         = .false.
  logical:: UseUserB0                = .false.
  logical:: UseUserInitSession       = .false.
  logical:: UseUserUpdateStates      = .false.
  logical:: UseExtraBoundary         = .false.
  logical:: UseSolidState            = .false.

  !\
  ! Logical controlling the use of the laser heating.
  !/
  logical :: UseLaserHeating = .false.

  !\
  ! Logical, controlling NLTE computations and determining if
  ! these computations use ERad values OR their ratios to the the equalibrium
  ! values (ERad over B) for all energy groups.
  !/
  logical:: UseERadInput=.false.

  ! Logical for a thin heliospheric current sheet method similar to that
  ! in the ENLIL code of D. Odstril
  logical :: DoThinCurrentSheet = .false.

  !\
  ! Logicals for the use of the boundary condition at the surface
  ! well above the transition region, which in connected by the
  ! magnetic field line threads with the photosphere boundary.
  !/
  logical:: UseFieldLineThreads = .false., DoThreadRestart = .false.
  logical, public, allocatable :: DoThreads_B(:)

  ! Use high-order accurate ghost cells.
  logical :: UseHighResChange = .false.

  ! Use high-order accurate refined/coarsened cells.
  logical :: UseHighOrderAMR = .false.

  ! Use resistivity planetary interior. It may be set to true in the
  ! ModUserMercury.f90.
  logical :: UseResistivePlanet = .false.

  ! use particles in the simulation
  logical :: UseParticles = .false.
  
  ! Variables related to another component coupled directly with pointers
  integer           :: nVarComp2
  character(len=200):: NameVarComp2
  real, pointer     :: StateComp2_VGB(:,:,:,:,:)

  ! The lower case names of the variables and the primitive var names
  character(len=len(NameVar_V)) :: NameVarLower_V(nVar+nFluid)
  character(len=len(NameVar_V)) :: NamePrimitive_V(nVar)


contains
  !============================================================================
  subroutine init_mod_main
    if(.not.allocated(dt_BLK))then
       allocate(dt_BLK(MaxBlock))
       dt_BLK = 0.0
    end if
  end subroutine init_mod_main
  !============================================================================
  subroutine clean_mod_main
    if(allocated(dt_BLK)) deallocate(dt_BLK)

  end subroutine clean_mod_main
end module ModMain
