!  Copyright (C) 2002 Regents of the University of Michigan,
!  portions used with permission
!  For more information, see http://csem.engin.umich.edu/tools/swmf

module ModCoronalHeating

  use BATL_lib, ONLY: &
       test_start, test_stop
  use ModBatsrusUtility, ONLY: stop_mpi
#ifdef _OPENACC
  use ModUtilities, ONLY: norm2
#endif
  use ModMain,       ONLY: nI, nJ, nK
  use ModReadParam,  ONLY: lStringLine
  use ModVarIndexes, ONLY: WaveFirst_, WaveLast_, Z2SigmaD_
  use ModMultiFluid, ONLY: IonFirst_, IonLast_
  use omp_lib

  implicit none
  SAVE

  PRIVATE  ! except

  public :: get_coronal_heat_factor
  public :: get_coronal_heating
  public :: get_block_heating
  public :: apportion_coronal_heating
  public :: get_wave_reflection
  public :: init_coronal_heating
  public :: read_coronal_heating_param
  public :: turbulent_cascade

  ! The Poynting flux to magnetic field ratio (one of the input parameters
  ! in SI unins and diminsionless:
  real, public :: PoyntingFluxPerBSi = 1.0e6, PoyntingFluxPerB
  real, public :: ImbalanceMax = 2.0, ImbalanceMax2 = 4.0

  logical, public :: UseCoronalHeating = .false.
  ! Check if we use an extra equation for the energy difference
  ! ("Sigma_D" in a standard argo).
  logical, public, parameter :: &
       UseEquation4SigmaD = Z2SigmaD_ == WaveLast_ + 1
  character(len=lStringLine) :: NameModel, TypeCoronalHeating

  ! Exponential Model ---------
  ! Variables and parameters for various heating models

  ! quantitative parameters for exponential heating model
  real :: HeatingAmplitude, HeatingAmplitudeCgs = 6.07e-7
  real :: DecayLengthExp = 0.7  ! in Solar Radii units
  logical :: UseExponentialHeating = .false.

  ! parameters for high-B transition (in Gauss)
  ! idea is to grossly approx 'Active Region' heating values
  logical :: UseArComponent = .false.
  real :: ArHeatB0 = 30.0
  real :: DeltaArHeatB0 = 5.0
  real :: ArHeatFactorCgs = 4.03E-05  ! cgs energy density = [ergs cm-3 s-1]

  ! Abbett's model -------------

  ! Normalization constant for Abbett Model
  real :: HeatNormalization = 1.0

  ! Alfven wave dissipation
  logical,public :: UseAlfvenWaveDissipation = .false.
  real           :: LperpTimesSqrtBSi = 7.5e4 ! m T^(1/2)
  real,   public :: LperpTimesSqrtB
  real :: Crefl = 0.04

  logical,public :: UseTurbulentCascade = .false.
  logical,public :: UseWaveReflection = .true.
  real,   public :: rMinWaveReflection = 0.0

  ! long scale height heating (Ch = Coronal Hole)
  logical :: DoChHeat = .false.
  real :: HeatChCgs = 5.0e-7
  real :: DecayLengthCh = 0.7

  ! Arrays for the calculated heat function and dissipated wave energy
  real, public :: CoronalHeating_C(1:nI,1:nJ,1:nK)
  real, public :: WaveDissipation_VC(WaveFirst_:max(WaveLast_,Z2SigmaD_),&
       1:nI,1:nJ,1:nK)
  !$omp threadprivate( CoronalHeating_C, WaveDissipation_VC )

  character(len=lStringLine) :: TypeHeatPartitioning

  ! Switch whether to use uniform heat partition
  logical :: UseUniformHeatPartition = .false.
  real :: QionRatio_I(IonFirst_:IonLast_) = 0.6
  real :: QionParRatio_I(IonFirst_:IonLast_) = 0.0
  real, public :: QeRatio = 0.4

  ! Dimensionless parameters for stochastic heating
  logical :: UseStochasticHeating = .true.
  real :: StochasticExponent   = 0.21
  real :: StochasticAmplitude  = 0.18
  real :: StochasticExponent2  = 0.21
  real :: StochasticAmplitude2 = 0.0 ! 1.17

  ! Use a lookup table for linear Landau and transit-time damping of KAWs
  integer :: iTableHeatPartition = -1

  ! Switch whether or not to use Alignment angle between Zplus and Zminus
  ! Elsasser variables in the cascade rate
  logical, public :: UseAlignmentAngle = .false.
  real, public :: Cdiss_C(nI,nJ,nK) = 1.0
  !$omp threadprivate(Cdiss_C)

  logical :: DoInit = .true.

  ! Bill Abbet's model, if .true.
  logical, public :: UseUnsignedFluxModel = .false.

  ! Normalized value of Heating constant
  real :: HeatFactor = 0.0

  ! Cgs value of total power input from coronal heating
  real :: TotalCoronalHeatingCgs = 1.0e+28

  ! Exponential Scale height to truncate heating function
  real :: DecayLength = 1.0
  real, public :: DtUpdateFlux = -1.0
  real, public :: UnsignedFluxHeight = -99999.0

  ! Non-linear dissipation in the current sheet (if regular magnetic field is
  ! lower than the irregular one.
  logical :: UseNonLinearAWDissipation = .false.

  ! The normalized energy difference:
  ! SigmaD = (kinetic - magnetic)/(kinetic + magnetic)
  logical, public :: UseReynoldsDecomposition = .false.
  logical, public :: UseTransverseTurbulence = .true.
  real, public :: SigmaD = -1.0/3.0
  real, public :: KarmanTaylorAlpha = 1.0
  real, public :: KarmanTaylorBeta = 1.0

contains
  !============================================================================
  subroutine get_coronal_heat_factor

    use ModAdvance,     ONLY: State_VGB, Bz_
    use ModGeometry,    ONLY: IsNoBody_B, Used_GB, TypeGeometry
    use ModMagnetogram, ONLY: get_magnetogram_field
    use ModMain,        ONLY: nI, nJ, nK, nBlock, Unused_B, tSimulation,z_
    use ModMpi,         ONLY: MPI_REAL, MPI_SUM
    use ModNumConst,    ONLY: cHalfPi, cTwoPi
    use ModPhysics,     ONLY: Si2No_V, No2Si_V, UnitX_, UnitT_, &
         UnitEnergyDens_, rBody
    use BATL_lib,       ONLY: CellFace_DB, CellVolume_GB, nProc, iComm

    integer :: i, j, k, iBlock
    integer :: iTheta, iPhi, iError
    real :: UnsignedFluxCgs, dAreaCgs
    real :: HeatFunction, HeatFunctionVolume, HeatFunctionVolumePe
    real :: x, y, z, Theta, Phi, SinTheta, CosTheta, SinPhi, CosPhi
    real :: B0_D(3), BrSi, BrCgs, SumUnsignedBrCgs
    real :: BzCgs_II(1:nI,1:nJ), SumUnsignedBzCgs, UnsignedFluxCgsPe
    real    :: TotalCoronalHeating = -1.0, TimeUpdateLast = -1.0
    logical :: DoFirst = .true.
    !$omp threadprivate(TotalCoronalHeating, TimeUpdateLast, DoFirst)

    integer, parameter:: nTheta = 72, nPhi=90
    real, parameter:: dSinTheta = 2.0/nTheta, dPhi = cTwoPi/nPhi
    real, parameter:: HeatExponent = 1.1488, HeatCoef = 89.4

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'get_coronal_heat_factor'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)

    if(DoFirst .and. DtUpdateFlux <= 0.0)then

       ! uniform cell area on sphere
       dAreaCgs = rBody**2*dSinTheta*dPhi*No2Si_V(UnitX_)**2*1e4
       SumUnsignedBrCgs = 0.0

       do iTheta = 0, nTheta

          Theta = cHalfPi - asin((real(iTheta) + 0.5)*dSinTheta - 1.0)
          SinTheta = sin(Theta)
          CosTheta = cos(Theta)
          do iPhi = 1, nPhi
             Phi=(real(iPhi)-0.5)*dPhi
             SinPhi = sin(Phi)
             CosPhi = cos(Phi)

             x = rBody*SinTheta*CosPhi
             y = rBody*SinTheta*SinPhi
             z = rBody*CosTheta

             call get_magnetogram_field(x, y, z, B0_D)
             BrSi = (x*B0_D(1) + y*B0_D(2) + z*B0_D(3))/rBody
             BrCgs = BrSi*1e4
             SumUnsignedBrCgs = SumUnsignedBrCgs + abs(BrCgs)

          end do
       end do

       UnsignedFluxCgs = SumUnsignedBrCgs*dAreaCgs

       TotalCoronalHeatingCgs = HeatCoef*UnsignedFluxCgs**HeatExponent

       TotalCoronalHeating = TotalCoronalHeatingCgs*1e-7 &
            *Si2No_V(UnitEnergyDens_)*Si2No_V(UnitX_)**3/Si2No_V(UnitT_)

       DoFirst = .false.

    elseif( DtUpdateFlux > 0.0 .and. &
         tSimulation - TimeUpdateLast > DtUpdateFlux ) then

       UnsignedFluxCgs = 0.0
       if(TypeGeometry == 'spherical')then
          do iBlock = 1, nBlock
             if(Unused_B(iBlock)) CYCLE
             if(IsNoBody_B(iBlock)) then
                call get_photosphere_unsignedflux(iBlock, UnsignedFluxCgs)
             end if
          end do
       elseif(TypeGeometry == 'cartesian')then
          do iBlock = 1, nBlock
             if(Unused_B(iBlock)) CYCLE
             if(IsNoBody_B(iBlock)) then
                dAreaCgs = CellFace_DB(z_,iBlock)*No2Si_V(UnitX_)**2*1e4

                call get_photosphere_field(iBlock, &
                     State_VGB(Bz_,1:nI,1:nJ,0:nK+1,iBlock), BzCgs_II)

                SumUnsignedBzCgs = sum(abs(BzCgs_II))
                UnsignedFluxCgs = UnsignedFluxCgs +  SumUnsignedBzCgs*dAreaCgs
             end if
          end do
       else
          call stop_mpi(NameSub//': '//TypeGeometry// &
              ' geometry is not yet implemented')
       end if
       if(nProc>1)then
          UnsignedFluxCgsPe = UnsignedFluxCgs
          call MPI_allreduce(UnsignedFluxCgsPe, UnsignedFluxCgs, 1, &
               MPI_REAL, MPI_SUM, iComm, iError)
       end if
       TotalCoronalHeatingCgs = HeatCoef*UnsignedFluxCgs**HeatExponent

       TotalCoronalHeating = TotalCoronalHeatingCgs*1e-7 &
            *Si2No_V(UnitEnergyDens_)*Si2No_V(UnitX_)**3/Si2No_V(UnitT_)
       TimeUpdateLast = tSimulation

    end if

    HeatFunctionVolume = 0
    do iBlock = 1, nBlock
       if(Unused_B(iBlock)) CYCLE

       if(IsNoBody_B(iBlock)) then
          do k = 1, nK; do j = 1, nJ; do i = 1, nI
             call get_heat_function(i, j, k, iBlock, HeatFunction)
             HeatFunctionVolume = HeatFunctionVolume &
                  + HeatFunction*CellVolume_GB(i,j,k,iBlock)
          end do; end do; end do
       else
          do k = 1, nK; do j = 1, nJ; do i = 1, nI
             if(Used_GB(i,j,k,iBlock))then
                call get_heat_function(i, j, k, iBlock, HeatFunction)
                HeatFunctionVolume = HeatFunctionVolume &
                     + HeatFunction*CellVolume_GB(i,j,k,iBlock)
             end if
          end do; end do; end do
       end if
    end do

    if(nProc>1)then
       HeatFunctionVolumePe = HeatFunctionVolume
       call MPI_allreduce(HeatFunctionVolumePe, HeatFunctionVolume, 1, &
            MPI_REAL, MPI_SUM, iComm, iError)
    end if

    HeatFactor = TotalCoronalHeating/HeatFunctionVolume

    call test_stop(NameSub, DoTest)
  end subroutine get_coronal_heat_factor
  !============================================================================
  subroutine get_coronal_heating(i, j, k, iBlock, CoronalHeating)

    integer, intent(in) :: i, j, k, iBlock
    real, intent(out) :: CoronalHeating

    real :: HeatFunction
    character(len=*), parameter:: NameSub = 'get_coronal_heating'
    !--------------------------------------------------------------------------
    call get_heat_function(i, j, k, iBlock, HeatFunction)

    CoronalHeating = HeatFactor*HeatFunction

  end subroutine get_coronal_heating
  !============================================================================
  subroutine get_heat_function(i, j, k, iBlock, HeatFunction)

    use ModMain, ONLY: UseB0, z_
    use ModAdvance, ONLY: State_VGB, Bx_, Bz_
    use ModB0, ONLY: B0_DGB
    use ModGeometry, ONLY: r_GB
    use BATL_lib, ONLY: Xyz_DGB, IsCartesian

    integer, intent(in) :: i, j, k, iBlock
    real, intent(out) :: HeatFunction

    real :: Bmagnitude, B_D(3)

    character(len=*), parameter:: NameSub = 'get_heat_function'
    !--------------------------------------------------------------------------
    if(UseB0) then
       B_D = B0_DGB(:,i,j,k,iBlock) + State_VGB(Bx_:Bz_,i,j,k,iBlock)
    else
       B_D = State_VGB(Bx_:Bz_,i,j,k,iBlock)
    end if

    Bmagnitude = norm2(B_D)

    if(DtUpdateFlux <= 0.0)then
       HeatFunction = Bmagnitude*exp(-(r_GB(i,j,k,iBlock)-1.0)/DecayLength)
    else
       if(IsCartesian)then
          if(Xyz_DGB(z_,i,j,k,iBlock)<UnsignedFluxHeight)then
             HeatFunction = 0.0
          else
             HeatFunction = Bmagnitude
          end if
       else
          if(r_GB(i,j,k,iBlock)<UnsignedFluxHeight)then
             HeatFunction = 0.0
          else
             HeatFunction = Bmagnitude &
                  *exp(-(r_GB(i,j,k,iBlock)-1.0)/DecayLength)
          end if
       end if
    end if

  end subroutine get_heat_function
  !============================================================================
  subroutine get_photosphere_field(iBlock, Bz_C, BzCgs_II)

    use ModMain,      ONLY: nI, nJ, nK, z_
    use ModInterpolate, ONLY: find_cell
    use ModPhysics,   ONLY: No2Si_V, UnitB_
    use BATL_lib,     ONLY: CoordMin_DB, CoordMax_DB, CellSize_DB

    integer, intent(in) :: iBlock
    real, intent(in)    :: Bz_C(1:nI, 1:nJ, 0:nK+1) ! temporary array created
    real, intent(out)   :: BzCgs_II(1:nI, 1:nJ)
    real :: zMin, zMax, DxLeft, z
    integer :: iLeft

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'get_photosphere_field'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest, iBlock)

    zMin = CoordMin_DB(z_,iBlock)
    zMax = CoordMax_DB(z_,iBlock)

    BzCgs_II = 0.0
    if((UnsignedFluxHeight > zMax) .or. (UnsignedFluxHeight < zMin)) RETURN

    z = (UnsignedFluxHeight - zMin)/CellSize_DB(z_,iBlock) + 0.5
    call find_cell(0, nK+1, z, iLeft, DxLeft)

    BzCgs_II = ((1.0 - DxLeft)*Bz_C(1:nI, 1:nJ, iLeft) + &
         DxLeft*Bz_C(1:nI, 1:nJ, iLeft+1))*No2Si_V(UnitB_)*1e4

    call test_stop(NameSub, DoTest, iBlock)

  end subroutine get_photosphere_field
  !============================================================================
  subroutine get_photosphere_unsignedflux(iBlock, UnsignedFluxCgs)

    use ModAdvance,     ONLY: State_VGB
    use ModGeometry,    ONLY: r_GB
    use ModMain,        ONLY: nJ, nK, r_
    use ModInterpolate, ONLY: find_cell
    use ModPhysics,     ONLY: No2Si_V, UnitB_, UnitX_
    use ModVarIndexes,  ONLY: Bx_, Bz_
    use BATL_lib,       ONLY: CoordMin_DB, CoordMax_DB, CellSize_DB, &
         CellFace_DFB, Xyz_DGB

    integer, intent(in) :: iBlock
    real, intent(inout) :: UnsignedFluxCgs

    real :: rMin, rMax, r, DrLeft, BrLeft, BrRight, BrCgs, DrL, dAreaCgs
    integer :: iLeft, j, k, iL

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'get_photosphere_unsignedflux'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest, iBlock)
    rMin = CoordMin_DB(r_,iBlock)
    rMax = CoordMax_DB(r_,iBlock)

    if((UnsignedFluxHeight > rMax) .or. (UnsignedFluxHeight < rMin)) RETURN

    ! Cells used to interpolate Br
    r = (UnsignedFluxHeight - rMin)/CellSize_DB(r_,iBlock) + 0.5
    call find_cell(0, nI+1, r, iLeft, DrLeft)

    ! Cells used to interpolate face area
    r = r + 0.5
    call find_cell(0, nI+1, r, iL, DrL)
    ! Make sure that CellFace_DFB is never out of index range
    if(iL == 0)then
       iL = 1; DrL = 0.0
    else if(iL == nI+1)then
       iL = nI; DrL = 1.0
    end if

    do k = 1, nK; do j = 1, nJ
       BrLeft = sum(Xyz_DGB(:,iLeft,j,k,iBlock) &
            *State_VGB(Bx_:Bz_,iLeft,j,k,iBlock))/r_GB(iLeft,j,k,iBlock)
       BrRight = sum(Xyz_DGB(:,iLeft+1,j,k,iBlock) &
            *State_VGB(Bx_:Bz_,iLeft+1,j,k,iBlock))/r_GB(iLeft+1,j,k,iBlock)

       BrCgs = ((1.0 - DrLeft)*BrLeft + DrLeft*BrRight)*No2Si_V(UnitB_)*1e4

       dAreaCgs = ((1.0-DrL)*CellFace_DFB(r_,iL,j,k,iBlock) &
            +            DrL*CellFace_DFB(r_,iL+1,j,k,iBlock)) &
            *No2Si_V(UnitX_)**2*1e4

       UnsignedFluxCgs = UnsignedFluxCgs + abs(BrCgs)*dAreaCgs
    end do; end do

    call test_stop(NameSub, DoTest, iBlock)
  end subroutine get_photosphere_unsignedflux
  !============================================================================
  subroutine read_coronal_heating_param(NameCommand)

    use ModAdvance,    ONLY: UseAnisoPressure
    use ModReadParam,  ONLY: read_var

    integer :: iFluid

    character(len=*), intent(in):: NameCommand
    logical:: DoTest
    character(len=*), parameter:: NameSub = 'read_coronal_heating_param'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)
    select case(NameCommand)
    case("#CORONALHEATING")
       call read_var('TypeCoronalHeating', TypeCoronalHeating)

       ! Initialize logicals
       UseCoronalHeating = .true.
       UseUnsignedFluxModel = .false.
       UseExponentialHeating= .false.
       UseAlfvenWaveDissipation = .false.
       UseTurbulentCascade = .false.
       UseReynoldsDecomposition = .false.

       select case(TypeCoronalHeating)
       case('F','none')
          UseCoronalHeating = .false.
       case('exponential')
          DoInit = .true.
          UseExponentialHeating = .true.
          call read_var('DecayLengthExp', DecayLengthExp)
          call read_var('HeatingAmplitudeCgs', HeatingAmplitudeCgs)

       case('unsignedflux','Abbett')
          UseUnsignedFluxModel = .true.
          call read_var('DecayLength', DecayLength)
          call read_var('HeatNormalization', HeatNormalization)
       case('alfvenwavedissipation')
          UseAlfvenWaveDissipation = .true.
          DoInit = .true.
          call read_var('LperpTimesSqrtBSi', LperpTimesSqrtBSi)
          call read_var('Crefl', Crefl)
       case('turbulentcascade')
          UseAlfvenWaveDissipation = .true.
          UseTurbulentCascade = .true.
          DoInit = .true.
          call read_var('UseWaveReflection', UseWaveReflection)
          call read_var('LperpTimesSqrtBSi', LperpTimesSqrtBSi)
          if(UseWaveReflection)then
             call read_var('rMinWaveReflection', rMinWaveReflection)
             if(UseEquation4SigmaD)call read_var(&
                  'UseReynoldsDecomposition', UseReynoldsDecomposition)
          end if
       case('usmanov')
          UseAlfvenWaveDissipation = .true.
          UseReynoldsDecomposition = .true.
          call read_var('UseTransverseTurbulence', UseTransverseTurbulence)
          call read_var('SigmaD', SigmaD)
          call read_var('KarmanTaylorAlpha', KarmanTaylorAlpha)
          call read_var('KarmanTaylorBeta', KarmanTaylorBeta)
       case default
          call stop_mpi(NameSub//': unknown TypeCoronalHeating = ' &
               // TypeCoronalHeating)
       end select
    case('#LIMITIMBALANCE')
       call read_var('ImbalanceMax',ImbalanceMax)
       ImbalanceMax2 = ImbalanceMax**2

    case("#POYNTINGFLUX")
       DoInit = .true.
       call read_var('PoyntingFluxPerBSi', PoyntingFluxPerBSi)

    case("#ACTIVEREGIONHEATING")
       call read_var('UseArComponent', UseArComponent)
       if(UseArComponent) then
          call read_var('ArHeatFactorCgs', ArHeatFactorCgs)
          call read_var('ArHeatB0', ArHeatB0)
          call read_var('DeltaArHeatB0', DeltaArHeatB0)
       endif

    case("#LONGSCALEHEATING")
       call read_var('DoChHeat', DoChHeat)
       if(DoChHeat)then
          call read_var('HeatChCgs', HeatChCgs)
          call read_var('DecayLengthCh', DecayLengthCh)
       end if

    case("#HEATPARTITIONING")
       UseUniformHeatPartition = .false.
       UseStochasticHeating = .false.
       call read_var('TypeHeatPartitioning', TypeHeatPartitioning)
       select case(TypeHeatPartitioning)
       case('uniform')
          UseUniformHeatPartition = .true.
          do iFluid = IonFirst_, IonLast_
             call read_var('QionRatio', QionRatio_I(iFluid))
          end do
          if(UseAnisoPressure)then
             do iFluid = IonFirst_, IonLast_
                call read_var('QionParRatio', QionParRatio_I(iFluid))
             end do
          end if
          QeRatio = 1.0 - sum(QionRatio_I)
       case('stochasticheating')
          UseStochasticHeating = .true.
          ! Stochastic heating when Beta_proton is below 1
          call read_var('StochasticExponent', StochasticExponent)
          call read_var('StochasticAmplitude', StochasticAmplitude)
       case default
          call stop_mpi(NameSub//': unknown TypeHeatPartitioning = '&
               // TypeHeatPartitioning)
       end select

    case("#HIGHBETASTOCHASTIC")
       ! Correction for stochastic heating when Beta_proton is between 1 and 30
       ! KAWs are non-propagating for Beta_proton > 30.
       call read_var('StochasticExponent2', StochasticExponent2)
       call read_var('StochasticAmplitude2', StochasticAmplitude2)

    case("#ALIGNMENTANGLE")
       call read_var('UseAlignmentAngle', UseAlignmentAngle)
    case("#NONLINAWDISSIPATION")
       call read_var('UseNonLinearAWDissipation',UseNonLinearAWDissipation)
    case default
       call stop_mpi(NameSub//': unknown command = ' &
            // NameCommand)
    end select

    call test_stop(NameSub, DoTest)
  end subroutine read_coronal_heating_param
  !============================================================================
  subroutine init_coronal_heating

    use ModPhysics,     ONLY: Si2No_V, UnitEnergyDens_, UnitT_, UnitB_, &
         UnitX_, UnitU_
    use ModMultiFluid,  ONLY: UseMultiIon, nIonFluid
    use ModLookupTable, ONLY: i_lookup_table

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'init_coronal_heating'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)
    if(.not.DoInit) RETURN
    DoInit = .false.

    if(UseExponentialHeating)then
       HeatingAmplitude =  HeatingAmplitudeCgs*0.1 &
            *Si2No_V(UnitEnergyDens_)/Si2No_V(UnitT_)
    end if

    if(UseAlfvenWaveDissipation)then
       LperpTimesSqrtB = LperpTimesSqrtBSi &
            *Si2No_V(UnitX_)*sqrt(Si2No_V(UnitB_))
    end if

    PoyntingFluxPerB = PoyntingFluxPerBSi &
         *Si2No_V(UnitEnergyDens_)*Si2No_V(UnitU_)/Si2No_V(UnitB_)

    ! if multi-ion, then use lookup table to determine the linear Landau
    ! and transit-time damping of kinetic Alfven waves
    if(UseMultiIon .and. UseStochasticHeating)then
       iTableHeatPartition = i_lookup_table('heatpartition')
       if(.not. iTableHeatPartition > 0) &
            call stop_mpi('Heat partition table required for multi-ion')
       if(nIonFluid /= 2) &
            call stop_mpi('multi-ion heat partitioning only works for 2 ions')
    end if

    call test_stop(NameSub, DoTest)
  end subroutine init_coronal_heating
  !============================================================================
  subroutine get_block_heating(iBlock)

    use ModGeometry,       ONLY: r_GB
    use ModPhysics,        ONLY: Si2No_V, UnitEnergyDens_, UnitT_, &
         No2Io_V, UnitB_
    use ModMain,       ONLY: x_, z_, UseB0
    use ModVarIndexes, ONLY: Bx_, Bz_
    use ModAdvance,    ONLY: State_VGB
    use ModB0,         ONLY: B0_DGB

    integer, intent(in) :: iBlock

    integer             :: i, j, k
    real :: HeatCh

    real :: B_D(3)

    ! local variables for ArHeating (Active Region Heating)
    real :: FractionB, Bcell

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'get_block_heating'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest, iBlock)

    if(UseAlfvenWaveDissipation)then

       if(UseTurbulentCascade .or. UseReynoldsDecomposition)then
          do k = 1, nK; do j = 1, nJ; do i = 1, nI
             call turbulent_cascade(i, j, k, iBlock, &
                  WaveDissipation_VC(:,i,j,k), CoronalHeating_C(i,j,k))
          end do; end do; end do
       else
          do k = 1, nK; do j = 1, nJ; do i = 1, nI
             call calc_alfven_wave_dissipation(i, j, k, iBlock, &
                  WaveDissipation_VC(WaveFirst_:WaveLast_,i,j,k),&
                  CoronalHeating_C(i,j,k))
          end do; end do; end do
       end if

    elseif(UseUnsignedFluxModel)then

       do k=1,nK;do j=1,nJ; do i=1,nI

          call get_coronal_heating(i, j, k, iBlock, CoronalHeating_C(i,j,k))
          CoronalHeating_C(i,j,k) = CoronalHeating_C(i,j,k) * HeatNormalization

       end do; end do; end do

    elseif(UseExponentialHeating)then
       do k=1,nK;do j=1,nJ; do i=1,nI

          CoronalHeating_C(i,j,k) = HeatingAmplitude &
               *exp(- max(r_GB(i,j,k,iBlock) - 1.0, 0.0) / DecayLengthExp)

       end do; end do; end do
    else
       CoronalHeating_C = 0.0
    end if

    if(DoChHeat) then
       HeatCh = HeatChCgs * 0.1 * Si2No_V(UnitEnergyDens_)/Si2No_V(UnitT_)
       do k=1,nK; do j=1,nJ; do i=1,nI
          CoronalHeating_C(i,j,k) = CoronalHeating_C(i,j,k) + HeatCh &
               *exp(- max(r_GB(i,j,k,iBlock) - 1.0, 0.0) / DecayLengthCh)
       end do; end do; end do
    end if

    if(UseExponentialHeating.and.UseArComponent) then
       do k=1,nK; do j=1,nJ; do i=1,nI

          if(UseB0)then
             B_D = State_VGB(Bx_:Bz_,i,j,k,iBlock) + B0_DGB(x_:z_,i,j,k,iBlock)
          else
             B_D = State_VGB(Bx_:Bz_,i,j,k,iBlock)
          end if

          Bcell = No2Io_V(UnitB_) * norm2(B_D)

          FractionB = 0.5*(1.0+tanh((Bcell - ArHeatB0)/DeltaArHeatB0))
          CoronalHeating_C(i,j,k) = max(CoronalHeating_C(i,j,k), &
               FractionB * ArHeatFactorCgs * Bcell &
               * 0.1 * Si2No_V(UnitEnergyDens_)/Si2No_V(UnitT_))
       end do; end do; end do
    endif

    call test_stop(NameSub, DoTest, iBlock)
  end subroutine get_block_heating
  !============================================================================
  subroutine calc_alfven_wave_dissipation(i, j, k, iBlock, WaveDissipation_V, &
       CoronalHeating)

    use ModAdvance, ONLY: State_VGB
    use ModB0,      ONLY: B0_DGB
    use ModMain, ONLY: UseB0
    use ModVarIndexes, ONLY: Rho_, Bx_, Bz_

    integer, intent(in) :: i, j, k, iBlock
    real, intent(out)   :: WaveDissipation_V(WaveFirst_:WaveLast_), &
         CoronalHeating

    real :: EwavePlus, EwaveMinus, FullB_D(3), FullB, Coef
    character(len=*), parameter:: NameSub = 'calc_alfven_wave_dissipation'
    !--------------------------------------------------------------------------
    if(UseB0)then
       FullB_D = B0_DGB(:,i,j,k,iBlock) + State_VGB(Bx_:Bz_,i,j,k,iBlock)
    else
       FullB_D = State_VGB(Bx_:Bz_,i,j,k,iBlock)
    end if
    FullB = norm2(FullB_D)

    Coef = 2.0*sqrt(FullB/State_VGB(Rho_,i,j,k,iBlock))/LperpTimesSqrtB

    EwavePlus  = State_VGB(WaveFirst_,i,j,k,iBlock)
    EwaveMinus = State_VGB(WaveLast_,i,j,k,iBlock)

    WaveDissipation_V(WaveFirst_) = Coef*EwavePlus &
         *sqrt(max(EwaveMinus,Crefl**2*EwavePlus))

    WaveDissipation_V(WaveLast_) = Coef*EwaveMinus &
         *sqrt(max(EwavePlus,Crefl**2*EwaveMinus))

    CoronalHeating = sum(WaveDissipation_V)

  end subroutine calc_alfven_wave_dissipation
  !============================================================================
  subroutine turbulent_cascade(i, j, k, iBlock, WaveDissipation_V, &
       CoronalHeating)

    use ModAdvance, ONLY: State_VGB
    use ModB0, ONLY: B0_DGB
    use ModMain, ONLY: UseB0
    use ModVarIndexes, ONLY: Bx_, Bz_,Rho_,  Lperp_
    use ModMultiFluid, ONLY: iRho_I, IonFirst_, nIonFluid

    integer, intent(in) :: i, j, k, iBlock
    real, intent(out)   :: CoronalHeating, WaveDissipation_V(&
         WaveFirst_:max(WaveLast_,Z2SigmaD_))

    real :: FullB_D(3), FullB, Coef, Rho
    real :: EwavePlus, EwaveMinus

    character(len=*), parameter:: NameSub = 'turbulent_cascade'
    !--------------------------------------------------------------------------
    ! Low-frequency cascade due to small-scale nonlinearities

    if(Lperp_ > 1 .and. UseReynoldsDecomposition)then
       ! Note that Lperp is multiplied with the density
       if(nIonFluid > 1)then
          Rho = sum(State_VGB(iRho_I(IonFirst_:IonLast_),i,j,k,iBlock))
       else
          Rho = State_VGB(Rho_,i,j,k,iBlock)
       end if
       Coef = sqrt(Rho)*2.0*KarmanTaylorAlpha/State_VGB(Lperp_,i,j,k,iBlock)
    else
       if(UseB0)then
          FullB_D = B0_DGB(:,i,j,k,iBlock) + State_VGB(Bx_:Bz_,i,j,k,iBlock)
       else
          FullB_D = State_VGB(Bx_:Bz_,i,j,k,iBlock)
       end if
       if(UseNonLinearAWDissipation)then
          ! Account for a contribution from the wave field into their
          ! dissipation. A half of wave energy, w/2, is the magneic oscillation
          ! energy, deltaB^2/2. Hence, DeltaB+/-=sqrt(W+/-)
          FullB = sqrt(sum(FullB_D**2) + &
               sum(State_VGB(WaveFirst_:WaveLast_,i,j,k,iBlock)) )
       else
          FullB = norm2(FullB_D)
       end if
       Coef = 2.0*sqrt(FullB/State_VGB(iRho_I(IonFirst_),i,j,k,iBlock)) &
            /LperpTimesSqrtB
    end if

    EwavePlus  = State_VGB(WaveFirst_,i,j,k,iBlock)
    EwaveMinus = State_VGB(WaveLast_,i,j,k,iBlock)

    WaveDissipation_V(WaveFirst_) = Coef*sqrt(EwaveMinus)*EwavePlus
    WaveDissipation_V(WaveLast_) = Coef*sqrt(EwavePlus)*EwaveMinus

    CoronalHeating = sum(WaveDissipation_V)
    ! Dissipation rate for the energy difference
    if(UseReynoldsDecomposition.and. UseEquation4SigmaD)      &
         WaveDissipation_V(max(WaveLast_,Z2SigmaD_)) = Coef*  &
         0.50*(sqrt(EwaveMinus) + sqrt(EwaveMinus))*          &
         State_VGB(Z2SigmaD_,i,j,k,iBlock)

  end subroutine turbulent_cascade
  !============================================================================
  subroutine get_wave_reflection(iBlock, IsNewBlock)

    use BATL_size, ONLY: nDim, nI, nJ, nK
    use ModAdvance, ONLY: State_VGB, Source_VC
    use ModB0, ONLY: B0_DGB
    use ModChromosphere,  ONLY: DoExtendTransitionRegion, extension_factor, &
         get_tesi_c, TeSi_C
    use ModGeometry, ONLY: Used_GB, r_GB
    use ModMain, ONLY: UseB0
    use ModVarIndexes, ONLY: Bx_, Bz_
    use ModMultiFluid, ONLY: iRho_I, IonFirst_

    integer, intent(in) :: iBlock
    logical, optional, intent(inout):: IsNewBlock

    integer :: i, j, k
    real :: GradLogAlfven_D(nDim), CurlU_D(3), b_D(3), GradLogRho_D(nDim)
    real :: FullB_D(3), FullB, Rho, DissipationRateMax, ReflectionRate
    real :: EwavePlus, EwaveMinus
    real :: AlfvenGradRefl, ReflectionRateImb
    logical :: IsNewBlockAlfven

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'get_wave_reflection'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest, iBlock)

    if(DoExtendTransitionRegion) call get_tesi_c(iBlock, TeSi_C)

    if(present(IsNewBlock)) then
      IsNewBlockAlfven = IsNewBlock
    else
      IsNewBlockAlfven = .true.
    end if

    do k = 1, nK; do j = 1, nJ; do i = 1, nI
       if( (.not.Used_GB(i,j,k,iBlock)).or.&
            r_GB(i,j,k, iBlock) < rMinWaveReflection)CYCLE

       call get_grad_log_alfven_speed(i, j, k, iBlock, IsNewBlockAlfven, &
            GradLogAlfven_D, GradLogRho_D)
       call get_curl_u(i, j, k, iBlock, CurlU_D)

       if(UseB0)then
          FullB_D = B0_DGB(:,i,j,k,iBlock) + State_VGB(Bx_:Bz_,i,j,k,iBlock)
       else
          FullB_D = State_VGB(Bx_:Bz_,i,j,k,iBlock)
       end if
       FullB = norm2(FullB_D)
       b_D = FullB_D/max(1e-15, FullB)

       Rho = State_VGB(iRho_I(IonFirst_),i,j,k,iBlock)

       EwavePlus  = State_VGB(WaveFirst_,i,j,k,iBlock)
       EwaveMinus = State_VGB(WaveLast_,i,j,k,iBlock)

       DissipationRateMax = &
            2.0*sqrt(max(EwavePlus,EwaveMinus)*FullB/Rho)/LperpTimesSqrtB

       if(DoExtendTransitionRegion) DissipationRateMax = &
            DissipationRateMax/extension_factor(TeSi_C(i,j,k))

       AlfvenGradRefl = (sum(FullB_D(:nDim)*GradLogAlfven_D))**2/Rho

       ReflectionRateImb = sqrt( (sum(b_D*CurlU_D))**2 + AlfvenGradRefl )

       ! Clip the reflection rate from above with maximum dissipation rate
       ReflectionRate = min(ReflectionRateImb, DissipationRateMax)

       ! No reflection when turbulence is balanced (waves are then
       ! assumed to be uncorrelated)
       if(ImbalanceMax2*EwaveMinus < EwavePlus)then
          ReflectionRate = ReflectionRate*&
               (1.0 - ImbalanceMax*sqrt(EwaveMinus/EwavePlus))
       elseif(ImbalanceMax2*EwavePlus < EwaveMinus)then
          ReflectionRate = ReflectionRate*&
               (ImbalanceMax*sqrt(EwavePlus/EwaveMinus)-1.0)
       else
          ReflectionRate = 0.0
       end if

       Source_VC(WaveFirst_,i,j,k) = Source_VC(WaveFirst_,i,j,k) &
            - ReflectionRate*sqrt(EwavePlus*EwaveMinus)
       Source_VC(WaveLast_,i,j,k) = Source_VC(WaveLast_,i,j,k) &
            + ReflectionRate*sqrt(EwavePlus*EwaveMinus)

       ! Calculate sin(theta), where theta is the angle between Zplus
       ! and Zminus at the outer Lperp scale
       if(UseAlignmentAngle) Cdiss_C(i,j,k) = sqrt(1.0 - AlfvenGradRefl &
            *(ReflectionRate/ReflectionRateImb**2)**2)

    end do; end do; end do

    call test_stop(NameSub, DoTest, iBlock)
  end subroutine get_wave_reflection
  !============================================================================
  subroutine get_grad_log_alfven_speed(i, j, k, iBlock, IsNewBlockAlfven, &
       GradLogAlfven_D, GradLogRho_D)

    use BATL_lib, ONLY: IsCartesianGrid, &
         CellSize_DB, FaceNormal_DDFB, CellVolume_GB, &
         x_, y_, z_, Dim1_, Dim2_, Dim3_
    use BATL_size, ONLY: nDim, nI, j0_, nJp1_, k0_, nKp1_

    integer, intent(in) :: i, j, k, iBlock
    logical, intent(inout) :: IsNewBlockAlfven
    real, intent(out) :: GradLogAlfven_D(nDim), GradLogRho_D(nDim)

    real, save :: LogAlfven_FD(0:nI+1,j0_:nJp1_,k0_:nKp1_,nDim),&
         LogRho_FD(0:nI+1,j0_:nJp1_,k0_:nKp1_,nDim)
    !$omp threadprivate(LogAlfven_FD,LogRho_FD)

    character(len=*), parameter:: NameSub = 'get_grad_log_alfven_speed'
    !--------------------------------------------------------------------------
    if(IsNewBlockAlfven)then
       call get_log_alfven_speed
       IsNewBlockAlfven = .false.
    end if

    if(IsCartesianGrid)then
       GradLogAlfven_D(Dim1_) = 1.0/CellSize_DB(x_,iBlock) &
            *(LogAlfven_FD(i+1,j,k,Dim1_) - LogAlfven_FD(i,j,k,Dim1_))
       GradLogRho_D(Dim1_) = 1.0/CellSize_DB(x_,iBlock) &
            *(LogRho_FD(i+1,j,k,Dim1_) - LogRho_FD(i,j,k,Dim1_))
       if(nJ > 1) then
          GradLogAlfven_D(Dim2_) = 1.0/CellSize_DB(y_,iBlock) &
               *(LogAlfven_FD(i,j+1,k,Dim2_) - LogAlfven_FD(i,j,k,Dim2_))
          GradLogRho_D(Dim2_) = 1.0/CellSize_DB(y_,iBlock) &
               *(LogRho_FD(i,j+1,k,Dim2_) - LogRho_FD(i,j,k,Dim2_))
       end if
       if(nK > 1) then
          GradLogAlfven_D(Dim3_) = 1.0/CellSize_DB(z_,iBlock) &
            *(LogAlfven_FD(i,j,k+1,Dim3_) - LogAlfven_FD(i,j,k,Dim3_))
          GradLogRho_D(Dim3_) = 1.0/CellSize_DB(z_,iBlock) &
            *(LogRho_FD(i,j,k+1,Dim3_) - LogRho_FD(i,j,k,Dim3_))
       end if
    else
       GradLogAlfven_D = &
            LogAlfven_FD(i+1,j,k,Dim1_) &
            *FaceNormal_DDFB(:,Dim1_,i+1,j,k,iBlock) &
            - LogAlfven_FD(i,j,k,Dim1_) &
            *FaceNormal_DDFB(:,Dim1_,i,j,k,iBlock)
       GradLogRho_D = &
            LogRho_FD(i+1,j,k,Dim1_)*FaceNormal_DDFB(:,Dim1_,i+1,j,k,iBlock) &
            - LogRho_FD(i,j,k,Dim1_)*FaceNormal_DDFB(:,Dim1_,i,j,k,iBlock)
       if(nJ > 1)then
          GradLogAlfven_D = GradLogAlfven_D + &
               LogAlfven_FD(i,j+1,k,Dim2_) &
               *FaceNormal_DDFB(:,Dim2_,i,j+1,k,iBlock) &
               - LogAlfven_FD(i,j,k,Dim2_) &
               *FaceNormal_DDFB(:,Dim2_,i,j,k,iBlock)
          GradLogRho_D = GradLogRho_D + &
               LogRho_FD(i,j+1,k,Dim2_) &
               *FaceNormal_DDFB(:,Dim2_,i,j+1,k,iBlock) &
               - LogRho_FD(i,j,k,Dim2_)&
               *FaceNormal_DDFB(:,Dim2_,i,j,k,iBlock)
       end if
       if(nK > 1) then
          GradLogAlfven_D = GradLogAlfven_D + &
               LogAlfven_FD(i,j,k+1,Dim3_) &
               *FaceNormal_DDFB(:,Dim3_,i,j,k+1,iBlock) &
               - LogAlfven_FD(i,j,k,Dim3_) &
               *FaceNormal_DDFB(:,Dim3_,i,j,k,iBlock)
          GradLogRho_D = GradLogRho_D + &
               LogRho_FD(i,j,k+1,Dim3_) &
               *FaceNormal_DDFB(:,Dim3_,i,j,k+1,iBlock) &
               - LogRho_FD(i,j,k,Dim3_) &
               *FaceNormal_DDFB(:,Dim3_,i,j,k,iBlock)
       end if

       GradLogAlfven_D = GradLogAlfven_D/CellVolume_GB(i,j,k,iBlock)
       GradLogRho_D = GradLogRho_D/CellVolume_GB(i,j,k,iBlock)
    end if

  contains
    !==========================================================================
    subroutine get_log_alfven_speed

      use ModAdvance, ONLY: &
           LeftState_VX, LeftState_VY, LeftState_VZ,  &
           RightState_VX, RightState_VY, RightState_VZ
      use ModB0, ONLY: B0_DX, B0_DY, B0_DZ
      use ModMain, ONLY: UseB0
      use ModVarIndexes, ONLY: Bx_, Bz_
      use ModMultiFluid, ONLY: iRho_I, IonFirst_

      integer :: i, j, k
      real :: Rho, FullB_D(3)
      !------------------------------------------------------------------------
      do k = 1, nK; do j = 1, nJ; do i = 1, nI+1
         FullB_D = 0.5*(LeftState_VX(Bx_:Bz_,i,j,k) &
              + RightState_VX(Bx_:Bz_,i,j,k))
         if(UseB0) FullB_D = FullB_D + B0_DX(:,i,j,k)
         Rho = 0.5*(LeftState_VX(iRho_I(IonFirst_),i,j,k) &
              +     RightState_VX(iRho_I(IonFirst_),i,j,k))
         LogAlfven_FD(i,j,k,x_) = 0.50*log(max(sum(FullB_D**2), 1e-30)/Rho)
         LogRho_FD(i,j,k,x_) = 0.50*log(Rho)
      end do; end do; end do

      if(nJ > 1)then
         do k = 1, nK; do j = 1, nJ+1; do i = 1, nI
            FullB_D = 0.5*(LeftState_VY(Bx_:Bz_,i,j,k) &
                 + RightState_VY(Bx_:Bz_,i,j,k))
            if(UseB0) FullB_D = FullB_D + B0_DY(:,i,j,k)
            Rho = 0.5*(LeftState_VY(iRho_I(IonFirst_),i,j,k) &
                 +     RightState_VY(iRho_I(IonFirst_),i,j,k))
            LogAlfven_FD(i,j,k,Dim2_) = &
                 0.50*log(max(sum(FullB_D**2), 1e-30)/Rho)
            LogRho_FD(i,j,k,Dim2_) = 0.50*log(Rho)
         end do; end do; end do
      end if

      if(nK > 1)then
         do k = 1, nK+1; do j = 1, nJ; do i = 1, nI
            FullB_D = 0.5*(LeftState_VZ(Bx_:Bz_,i,j,k) &
                 + RightState_VZ(Bx_:Bz_,i,j,k))
            if(UseB0) FullB_D = FullB_D + B0_DZ(:,i,j,k)
            Rho = 0.5*(LeftState_VZ(iRho_I(IonFirst_),i,j,k) &
                 +     RightState_VZ(iRho_I(IonFirst_),i,j,k))
            LogAlfven_FD(i,j,k,Dim3_) = &
                 0.50*log(max(sum(FullB_D**2), 1e-30)/Rho)
            LogRho_FD(i,j,k,Dim3_) = 0.50*log(Rho)
         end do; end do; end do
      end if

    end subroutine get_log_alfven_speed
    !==========================================================================
  end subroutine get_grad_log_alfven_speed
  !============================================================================
  subroutine get_curl_u(i, j, k, iBlock, CurlU_D)

    use BATL_lib, ONLY: IsCartesianGrid, CellSize_DB, FaceNormal_DDFB, &
         CellVolume_GB, x_, y_, z_
    use ModAdvance, ONLY: &
         LeftState_VX, LeftState_VY, LeftState_VZ,  &
         RightState_VX, RightState_VY, RightState_VZ
    use ModCoordTransform, ONLY: cross_product
    use ModSize, ONLY: MaxDim
    use ModMultiFluid, ONLY: iUx_I, iUy_I, iUz_I, IonFirst_

    integer, intent(in) :: i, j, k, iBlock
    real, intent(out) :: CurlU_D(MaxDim)

    real :: DxInvHalf, DyInvHalf, DzInvHalf
    character(len=*), parameter:: NameSub = 'get_curl_u'
    !--------------------------------------------------------------------------
    if(IsCartesianGrid)then
       DxInvHalf = 0.5/CellSize_DB(x_,iBlock)
       DyInvHalf = 0.5/CellSize_DB(y_,iBlock)
       DzInvHalf = 0.5/CellSize_DB(z_,iBlock)

       CurlU_D(x_) = &
            DyInvHalf*(LeftState_VY(iUz_I(IonFirst_),i,j+1,k)  &
            +          RightState_VY(iUz_I(IonFirst_),i,j+1,k) &
            -          LeftState_VY(iUz_I(IonFirst_),i,j,k)    &
            -          RightState_VY(iUz_I(IonFirst_),i,j,k))  &
            - DzInvHalf*(LeftState_VZ(iUy_I(IonFirst_),i,j,k+1)  &
            +            RightState_VZ(iUy_I(IonFirst_),i,j,k+1) &
            -            LeftState_VZ(iUy_I(IonFirst_),i,j,k)    &
            -            RightState_VZ(iUy_I(IonFirst_),i,j,k))

       CurlU_D(y_) = &
            DzInvHalf*(LeftState_VZ(iUx_I(IonFirst_),i,j,k+1)  &
            +          RightState_VZ(iUx_I(IonFirst_),i,j,k+1) &
            -          LeftState_VZ(iUx_I(IonFirst_),i,j,k)    &
            -          RightState_VZ(iUx_I(IonFirst_),i,j,k))  &
            - DxInvHalf*(LeftState_VX(iUz_I(IonFirst_),i+1,j,k)  &
            +            RightState_VX(iUz_I(IonFirst_),i+1,j,k) &
            -            LeftState_VX(iUz_I(IonFirst_),i,j,k)    &
            -            RightState_VX(iUz_I(IonFirst_),i,j,k))

       CurlU_D(z_) = &
            DxInvHalf*(LeftState_VX(iUy_I(IonFirst_),i+1,j,k)  &
            +          RightState_VX(iUy_I(IonFirst_),i+1,j,k) &
            -          LeftState_VX(iUy_I(IonFirst_),i,j,k)    &
            -          RightState_VX(iUy_I(IonFirst_),i,j,k))  &
            - DyInvHalf*(LeftState_VY(iUx_I(IonFirst_),i,j+1,k)  &
            +            RightState_VY(iUx_I(IonFirst_),i,j+1,k) &
            -            LeftState_VY(iUx_I(IonFirst_),i,j,k)    &
            -            RightState_VY(iUx_I(IonFirst_),i,j,k))
    else
       CurlU_D(:) = &
            + cross_product( FaceNormal_DDFB(:,1,i+1,j,k,iBlock),       &
            LeftState_VX(iUx_I(IonFirst_):iUz_I(IonFirst_),i+1,j,k)     &
            + RightState_VX(iUx_I(IonFirst_):iUz_I(IonFirst_),i+1,j,k)) &
            - cross_product( FaceNormal_DDFB(:,1,i  ,j,k,iBlock),       &
            LeftState_VX(iUx_I(IonFirst_):iUz_I(IonFirst_),i  ,j,k)     &
            + RightState_VX(iUx_I(IonFirst_):iUz_I(IonFirst_),i  ,j,k)) &
            + cross_product( FaceNormal_DDFB(:,2,i,j+1,k,iBlock),       &
            LeftState_VY(iUx_I(IonFirst_):iUz_I(IonFirst_),i,j+1,k)     &
            + RightState_VY(iUx_I(IonFirst_):iUz_I(IonFirst_),i,j+1,k)) &
            - cross_product( FaceNormal_DDFB(:,2,i,j  ,k,iBlock),       &
            LeftState_VY(iUx_I(IonFirst_):iUz_I(IonFirst_),i,j  ,k)     &
            + RightState_VY(iUx_I(IonFirst_):iUz_I(IonFirst_),i,j  ,k)) &
            + cross_product( FaceNormal_DDFB(:,3,i,j,k+1,iBlock),       &
            LeftState_VZ(iUx_I(IonFirst_):iUz_I(IonFirst_),i,j,k+1)     &
            + RightState_VZ(iUx_I(IonFirst_):iUz_I(IonFirst_),i,j,k+1)) &
            - cross_product( FaceNormal_DDFB(:,3,i,j,k  ,iBlock),       &
            LeftState_VZ(iUx_I(IonFirst_):iUz_I(IonFirst_),i,j,k)     &
            + RightState_VZ(iUx_I(IonFirst_):iUz_I(IonFirst_),i,j,k))

       CurlU_D(:) = 0.5*CurlU_D(:)/CellVolume_GB(i,j,k,iBlock)
    end if

  end subroutine get_curl_u
  !============================================================================
  subroutine apportion_coronal_heating(i, j, k, iBlock, &
       State_V, WaveDissipation_V, CoronalHeating, &
       QPerQtotal_I, QparPerQtotal_I, QePerQtotal)

    ! Apportion the coronal heating to the electrons and protons based on
    ! how the Alfven waves dissipate at length scales << Lperp

    use ModVarIndexes, ONLY: nVar, Lperp_
    use ModMain, ONLY: UseB0
    use ModPhysics, ONLY: IonMassPerCharge, pMin_I, TMin_I
    use ModAdvance, ONLY: nVar, UseAnisoPressure, Bx_, Bz_, Pe_
    use ModB0, ONLY: B0_DGB
    use ModChromosphere,  ONLY: DoExtendTransitionRegion, extension_factor, &
         TeSi_C
    use ModMultiFluid, ONLY: ChargeIon_I, MassIon_I, UseMultiIon, &
         nIonFluid, iRhoIon_I, iRhoUxIon_I, iRhoUzIon_I, iPIon_I, &
         iPparIon_I, IonFirst_
    use ModLookupTable, ONLY: interpolate_lookup_table

    integer, intent(in) :: i, j, k, iBlock
    real, intent(in) :: State_V(nVar)
    real, intent(in) :: WaveDissipation_V(WaveFirst_:WaveLast_)
    real, intent(in) :: CoronalHeating
    real, intent(out) :: QPerQtotal_I(nIonFluid), &
         QparPerQtotal_I(nIonFluid), QePerQtotal

    integer :: iIon, iPrev, iFluid
    real :: Qtotal, Udiff_D(3), Upar, Valfven, Vperp
    real :: B_D(3), B, B2, InvGyroRadius, DeltaU, Epsilon, DeltaB, Delta
    real :: TeByTp, BetaElectron, BetaProton, Pperp, LperpInvGyroRad
    real :: pMin, P_I(nIonFluid), Ppar_I(nIonFluid)
    real :: Wmajor, Wminor, Wplus, Wminus, WmajorGyro, WminorGyro, Wgyro
    real :: DampingElectron, DampingPar_I(nIonFluid)
    real :: DampingPerp_I(nIonFluid), DampingProton
    real :: RhoProton, Ppar, SignMajor
    real :: QratioProton, ExtensionCoef, Qmajor, Qminor
    real, dimension(nIonFluid) :: QminorFraction_I, QmajorFraction_I, &
         CascadeTimeMajor_I, CascadeTimeMinor_I, Qmajor_I, Qminor_I, &
         QperpPerQtotal_I, GyroRadiusTimesB_I
    real :: BetaParProton, Np, Na, Ne, Tp, Ta, Te, Pp
    real :: Value_I(6)

#ifndef SCALAR
    character(len=*), parameter:: NameSub = 'apportion_coronal_heating'
    !--------------------------------------------------------------------------
    if(UseStochasticHeating)then

       if(DoExtendTransitionRegion)then
          ExtensionCoef = extension_factor(TeSi_C(i,j,k))
       else
          ExtensionCoef = 1.0
       end if
       Qtotal = max(CoronalHeating*ExtensionCoef, 1e-30)

       if(UseB0) then
          B_D = B0_DGB(:,i,j,k,iBlock) + State_V(Bx_:Bz_)
       else
          B_D = State_V(Bx_:Bz_)
       end if
       B2 = max(sum(B_D**2), 1e-30)
       B = sqrt(B2)

       RhoProton = State_V(iRhoIon_I(1))

       Valfven = B/sqrt(RhoProton)

       do iIon = 1, nIonFluid
          iFluid = IonFirst_ - 1 + iIon

          pMin = 0.0
          if(Tmin_I(iFluid) < 0.0)then
             if(pMin_I(iFluid) >= 0.0) pMin = pMin_I(iFluid)
          else
             pMin = State_V(iRhoIon_I(iIon))/MassIon_I(iIon)*Tmin_I(iFluid)
             if(pMin_I(iFluid) >= 0.0) pMin = max(pMin_I(iFluid), pMin)
          end if
          pMin = max(pMin, 1e-30)

          P_I(iIon) = max(pMin, State_V(iPIon_I(iIon)))
          if(UseAnisoPressure)then
             Ppar_I(iIon) = min(max(pMin, &
                  State_V(iPparIon_I(iFluid))), (3*P_I(iIon)-2*pMin))
          else
             Ppar_I(iIon) = P_I(iIon)
          end if
       end do

       BetaProton = 2.0*P_I(1)/B2

       Wplus  = State_V(WaveFirst_)
       Wminus = State_V(WaveLast_)

       Wmajor = max(Wplus, Wminus)
       Wminor = min(Wplus, Wminus)

       ! Sign of major wave
       SignMajor = sign(1.0, Wplus - Wminus)

       if(SignMajor > 0.0)then
          Qmajor = WaveDissipation_V(WaveFirst_)*ExtensionCoef
          Qminor = WaveDissipation_V(WaveLast_)*ExtensionCoef
       else
          Qmajor = WaveDissipation_V(WaveLast_)*ExtensionCoef
          Qminor = WaveDissipation_V(WaveFirst_)*ExtensionCoef
       end if

       ! Linear Landau damping and transit-time damping of kinetic Alfven
       ! waves contributes to electron and parallel ion heating
       if(UseMultiIon)then
          BetaParProton = 2.0*Ppar_I(1)/B2
          Np = RhoProton
          Na = State_V(iRhoIon_I(nIonFluid))/MassIon_I(nIonFluid)
          Ne = sum(State_V(iRhoIon_I)*ChargeIon_I/MassIon_I)
          Tp = P_I(1)/Np
          Ta = P_I(nIonFluid)/Na
          Te = State_V(Pe_)/Ne

          ! difference bulk speed between alphas and protons
          Udiff_D = State_V(iRhoUxIon_I(nIonFluid):iRhoUzIon_I(nIonFluid)) &
               /State_V(iRhoIon_I(nIonFluid)) &
               -State_V(iRhoUxIon_I(1):iRhoUzIon_I(1)) &
               /State_V(iRhoIon_I(1))
          Upar = sum(Udiff_D*B_D)/B

          ! The damping rates (divided by k_parallel V_Ap) in the lookup
          ! table are for both forward propagating Alfven modes (i.e. in
          ! same direction as the alpha-proton drift) as well as backward
          ! propagating modes. The sign in drift can break the symmetrical
          ! behavior of forward and backward modes. For steady state, the
          ! Alfven modes are mostly forward propagating.
          call interpolate_lookup_table(iTableHeatPartition, &
               BetaParProton, abs(Upar)/Valfven, Tp/Ta, Tp/Te, Na/Np, &
               Value_I, DoExtrapolate = .false.)

          if(SignMajor*Upar < 0.0)then
             ! Backward propagating
             DampingPar_I(1) = Value_I(4)
             DampingPar_I(nIonFluid) = Value_I(6)
             DampingElectron = Value_I(5)
          else
             ! Forward propagating
             DampingPar_I(1) = Value_I(1)
             DampingPar_I(nIonFluid) = Value_I(3)
             DampingElectron = Value_I(2)
          end if
       else
          Pp = P_I(1)
          TeByTp = State_V(Pe_)/Pp

          BetaElectron = 2.0*State_V(Pe_)/B2

          DampingElectron = 0.01*sqrt(TeByTp/BetaProton) &
               *(1.0 + 0.17*BetaProton**1.3) &
               /(1.0 +(2800.0*BetaElectron)**(-1.25))
          DampingPar_I(1) = 0.08*sqrt(sqrt(TeByTp))*BetaProton**0.7 &
               *exp(-1.3/BetaProton)
       end if

       ! Stochasting heating contributes to perpendicular ion heating.
       ! Loop in reverse order for cascade power subtraction.
       do iIon = nIonFluid, 1, -1

          Ppar = Ppar_I(iIon)
          Pperp = 0.5*(3*P_I(iIon) - Ppar)

          ! Perpendicular ion thermal speed
          Vperp = sqrt(2.0*Pperp/State_V(iRhoIon_I(iIon)))

          GyroRadiusTimesB_I(iIon) = Vperp &
               *IonMassPerCharge*MassIon_I(iIon)/ChargeIon_I(iIon)

          InvGyroRadius = B/GyroRadiusTimesB_I(iIon)

          if(iIon == nIonFluid)then
             Qmajor_I(iIon) = Qmajor
             Qminor_I(iIon) = Qminor

             if(Lperp_ > 1)then
                LperpInvGyroRad = InvGyroRadius*State_V(Lperp_)/RhoProton
             else
                LperpInvGyroRad = InvGyroRadius*LperpTimesSqrtB/sqrt(B)
             end if

             WmajorGyro = Wmajor/sqrt(LperpInvGyroRad)
             WminorGyro = Wminor/sqrt(LperpInvGyroRad)
          else
             iPrev = iIon + 1

             QmajorFraction_I(iPrev) = &
                  DampingPerp_I(iPrev)*CascadeTimeMajor_I(iPrev) &
                  /(1.0 + DampingPerp_I(iPrev)*CascadeTimeMajor_I(iPrev))
             QminorFraction_I(iPrev) = &
                  DampingPerp_I(iPrev)*CascadeTimeMinor_I(iPrev) &
                  /(1.0 + DampingPerp_I(iPrev)*CascadeTimeMinor_I(iPrev))

             ! Subtract what was used for stochastic heating of alphas
             Qmajor_I(iIon) = &
                  Qmajor_I(iPrev)*(1.0 - QmajorFraction_I(iPrev))
             Qminor_I(iIon) = &
                  Qminor_I(iPrev)*(1.0 - QminorFraction_I(iPrev))

             ! Reduce similarly the cascade power and exploit non-alignment
             ! (Boldyrev, 2005) of small-scale fluctuations to arrive at
             ! Wmajor and Wminor at the proton gyro-radius
             WmajorGyro = WmajorGyro &
                  *( (1.0 - QmajorFraction_I(iPrev))**2 &
                  /(1.0 - QminorFraction_I(iPrev)) )**(2.0/3.0) &
                  *sqrt(GyroRadiusTimesB_I(iIon)/GyroRadiusTimesB_I(iPrev))
             WminorGyro = WminorGyro &
                  *( (1.0 - QminorFraction_I(iPrev))**2 &
                  /(1.0 - QmajorFraction_I(iPrev)) )**(2.0/3.0) &
                  *sqrt(GyroRadiusTimesB_I(iIon)/GyroRadiusTimesB_I(iPrev))
          end if

          Wgyro = WmajorGyro + WminorGyro

          ! Cascade timescale at the gyroscale
          CascadeTimeMajor_I(iIon) = WmajorGyro/max(Qmajor_I(iIon),1e-30)
          CascadeTimeMinor_I(iIon) = WminorGyro/max(Qminor_I(iIon),1e-30)

          ! For protons the following would be DeltaU and DeltaB at ion gyro
          ! radius, except that we assumed that the Alfven ratio is one.
          DeltaU = sqrt(Wgyro/RhoProton)
          DeltaB = sqrt(Wgyro)

          Epsilon = DeltaU/Vperp
          Delta = DeltaB/B

          ! Damping rate for stochastic heating.
          ! It interpolates between the beta<1 and 1<beta<30 version.
          ! This formula is at the moment only suitable for protons.
          DampingPerp_I(iIon) = (StochasticAmplitude &
               *exp(-StochasticExponent/max(Epsilon,1e-15)) &
               + StochasticAmplitude2*sqrt(BetaProton) &
               *exp(-StochasticExponent2/max(Delta,1e-15))) &
               *State_V(iRhoIon_I(iIon))*DeltaU**3 &
               *InvGyroRadius/max(Wgyro,1e-15)
       end do

       ! Set k_parallel*V_Alfven = 1/t_minor (critical balance)
       DampingElectron = DampingElectron/max(CascadeTimeMinor_I(1), 1e-30)
       DampingPar_I = DampingPar_I/max(CascadeTimeMinor_I(1), 1e-30)

       ! Total damping rate around proton gyroscale
       DampingProton = DampingElectron + sum(DampingPar_I) &
            + DampingPerp_I(1)

       QmajorFraction_I(1) = DampingProton*CascadeTimeMajor_I(1) &
            /(1.0 + DampingProton*CascadeTimeMajor_I(1))
       QminorFraction_I(1) = DampingProton*CascadeTimeMinor_I(1) &
            /(1.0 + DampingProton*CascadeTimeMinor_I(1))

       QratioProton = (QmajorFraction_I(1)*Qmajor_I(1) &
            + QminorFraction_I(1)*Qminor_I(1))/Qtotal

       QparPerQtotal_I = DampingPar_I/DampingProton*QratioProton

       QperpPerQtotal_I(1) = DampingPerp_I(1)/DampingProton*QratioProton

       if(nIonFluid > 1) QperpPerQtotal_I(2:) = &
            (QmajorFraction_I(2:)*Qmajor_I(2:) &
            + QminorFraction_I(2:)*Qminor_I(2:))/Qtotal

       QPerQtotal_I = QperpPerQtotal_I + QparPerQtotal_I

       QePerQtotal = (DampingElectron/DampingProton - 1)*QratioProton &
            + (Qmajor_I(1) + Qminor_I(1))/Qtotal

    elseif(UseUniformHeatPartition)then
       QPerQtotal_I = QionRatio_I
       QparPerQtotal_I = QionParRatio_I
       QePerQtotal = QeRatio

    else
       call stop_mpi(NameSub//' Unknown energy partitioning')
    end if
#endif
  end subroutine apportion_coronal_heating
  !============================================================================
end module ModCoronalHeating
!==============================================================================
