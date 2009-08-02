!^CFG COPYRIGHT UM
!^CFG FILE IMPLICIT
!==============================================================================
module ModHeatConduction

  implicit none
  save

  private ! except

  ! Public methods
  public :: read_heatconduction_param
  public :: init_heat_conduction
  public :: get_heat_flux
  public :: get_impl_heat_cond_state
  public :: get_heat_conduction_bc
  public :: get_heat_conduction_rhs
  public :: get_heat_cond_jacobian
  public :: update_impl_heat_cond

  ! Logical for adding field-aligned heat conduction
  logical, public :: IsNewBlockHeatConduction = .true.

  ! Variables for setting the field-aligned heat conduction coefficient
  character(len=20), public :: TypeHeatConduction = 'test'
  logical :: DoModifyHeatConduction, DoTestHeatConduction
  
  real :: HeatConductionParSi = 1.23e-11  ! taken from calc_heat_flux
  real :: TmodifySi = 3.0e5, DeltaTmodifySi = 2.0e4
  real :: HeatConductionPar, Tmodify, DeltaTmodify

  logical :: DoWeakFieldConduction = .false.
  real :: BmodifySi = 1.0e-7, DeltaBmodifySi = 1.0e-8 ! modify about 1 mG
  real :: Bmodify, DeltaBmodify

  ! electron temperature used for calculating heat flux
  real, allocatable :: Te_G(:,:,:)

  ! Heat flux for operator split scheme
  real, allocatable :: FluxImpl_X(:,:,:), FluxImpl_Y(:,:,:), FluxImpl_Z(:,:,:)

  ! Heat conduction dyad pre-multiplied by the face area
  real, allocatable :: HeatCond_DXB(:,:,:,:,:), HeatCond_DYB(:,:,:,:,:), &
       HeatCond_DZB(:,:,:,:,:)

contains

  !============================================================================

  subroutine read_heatconduction_param(NameCommand)

    use ModMain,      ONLY: UseParallelConduction
    use ModReadParam, ONLY: read_var

    character(len=*), intent(in) :: NameCommand

    character(len=*), parameter :: NameSub = 'read_heatconduction_param'
    !--------------------------------------------------------------------------

    select case(NameCommand)
    case("#PARALLELCONDUCTION")
       call read_var('UseParallelConduction', UseParallelConduction)
       if(UseParallelConduction)then
          call read_var('TypeHeatConduction', TypeHeatConduction)
          call read_var('HeatConductionParSi', HeatConductionParSi)

          select case(TypeHeatConduction)
          case('test','spitzer')
          case('modified')
             call read_var('TmodifySi', TmodifySi)
             call read_var('DeltaTmodifySi', DeltaTmodifySi)
          case default
             call stop_mpi(NameSub//': unknown TypeHeatConduction = ' &
                  //TypeHeatConduction)
          end select
       end if

    case("#WEAKFIELDCONDUCTION")
       call read_var('DoWeakFieldConduction', DoWeakFieldConduction)
       if(DoWeakFieldConduction)then
          call read_var('BmodifySi', BmodifySi)
          call read_var('DeltaBmodifySi', DeltaBmodifySi)
       end if

    case default
       call stop_mpi(NameSub//' invalid NameCommand='//NameCommand)
    end select

  end subroutine read_heatconduction_param

  !============================================================================

  subroutine init_heat_conduction

    use ModImplicit, ONLY: UseSemiImplicit, iTeImpl
    use ModMain,     ONLY: nI, nJ, nK, MaxBlock
    use ModPhysics,  ONLY: Si2No_V, UnitEnergyDens_, UnitTemperature_, &
         UnitU_, UnitX_, UnitB_

    character(len=*), parameter :: NameSub = 'init_heat_conduction'
    !--------------------------------------------------------------------------

    write(*,*) "The field aligned heat conduction is under construction"
    write(*,*) "It is currently guaranteed to give wrong results !!!"
    
    if(allocated(Te_G)) RETURN

    allocate(Te_G(-1:nI+2,-1:nJ+2,-1:nK+2))

    DoTestHeatConduction = .false.
    DoModifyHeatConduction = .false.

    if(TypeHeatConduction == 'test')then
       DoTestHeatConduction = .true.
    elseif(TypeHeatConduction == 'modified')then
       DoModifyHeatConduction = .true.
    end if

    ! unit HeatConductionParSi is W/(m*K^(7/2))
    HeatConductionPar = HeatConductionParSi &
         *Si2No_V(UnitEnergyDens_)/Si2No_V(UnitTemperature_)**3.5 &
         *Si2No_V(UnitU_)*Si2No_V(UnitX_)

    if(DoModifyHeatConduction)then
       Tmodify = TmodifySi*Si2No_V(UnitTemperature_)
       DeltaTmodify = DeltaTmodifySi*Si2No_V(UnitTemperature_)
    end if

    if(DoWeakFieldConduction)then
       Bmodify = BmodifySi*Si2No_V(UnitB_)
       DeltaBmodify = DeltaBmodifySi*Si2No_V(UnitB_)
    end if

    if(UseSemiImplicit)then
       allocate( &
            FluxImpl_X(nI+1,nJ,nK), &
            FluxImpl_Y(nI,nJ+1,nK), &
            FluxImpl_Z(nI,nJ,nK+1), &
            HeatCond_DXB(3,nI+1,nJ,nK,MaxBlock), &
            HeatCond_DYB(3,nI,nJ+1,nK,MaxBlock), &
            HeatCond_DZB(3,nI,nJ,nK+1,MaxBlock) )

       iTeImpl = 1
    end if

  end subroutine init_heat_conduction

  !============================================================================

  subroutine get_heat_flux(iDir, i, j, k, iBlock, State_V, Normal_D, &
       HeatCondCoefNormal, HeatFlux)

    use ModAdvance,      ONLY: State_VGB, UseIdealState
    use ModFaceGradient, ONLY: get_face_gradient
    use ModMain,         ONLY: nI, nJ, nK
    use ModMultiFluid,   ONLY: MassIon_I
    use ModPhysics,      ONLY: inv_gm1, Si2No_V, UnitTemperature_, &
         UnitEnergyDens_, ElectronTemperatureRatio, AverageIonCharge
    use ModUser,         ONLY: user_material_properties
    use ModVarIndexes,   ONLY: nVar, Rho_, p_

    integer, intent(in) :: iDir, i, j, k, iBlock
    real,    intent(in) :: State_V(nVar), Normal_D(3)
    real,    intent(out):: HeatCondCoefNormal, HeatFlux

    integer :: ii, jj, kk
    real :: FaceGrad_D(3), HeatCond_D(3), TeSi, Cv, CvSi
    real, save :: TeFraction

    character(len=*), parameter :: NameSub = 'get_heat_flux'
    !--------------------------------------------------------------------------

    if(IsNewBlockHeatConduction)then
       if(UseIdealState)then
          TeFraction = MassIon_I(1)*ElectronTemperatureRatio &
               /(1 + AverageIonCharge*ElectronTemperatureRatio)
          Te_G = State_VGB(p_,:,:,:,iBlock)/State_VGB(Rho_,:,:,:,iBlock) &
               *TeFraction
       else
          do kk = -1, nK+2; do jj = -1, nJ+2; do ii = -1, nI+2
             call user_material_properties( &
                  State_VGB(:,ii,jj,kk,iBlock), TeSiOut=TeSi)
             Te_G(ii,jj,kk) = TeSi*Si2No_V(UnitTemperature_)
          end do; end do; end do
       end if
    end if

    call get_face_gradient(iDir, i, j, k, iBlock, &
         IsNewBlockHeatConduction, Te_G, FaceGrad_D)

    call get_heat_conduction_coef(iDir, i, j, k, iBlock, State_V, &
         Normal_D, HeatCond_D)

    HeatFlux = -sum(HeatCond_D*FaceGrad_D)

    ! get the heat conduction coefficient normal to the face for
    ! time step restriction
    if(UseIdealState)then
       Cv = inv_gm1*State_V(Rho_)/TeFraction
    else
       call user_material_properties(State_V, CvSiOut = CvSi)
       Cv = CvSi*Si2No_V(UnitEnergyDens_)/Si2No_V(UnitTemperature_)
    end if
    HeatCondCoefNormal = sum(HeatCond_D*Normal_D)/Cv

  end subroutine get_heat_flux

  !============================================================================

  subroutine get_heat_conduction_coef(iDim, i, j, k, iBlock, State_V, &
       Normal_D, HeatCond_D)

    use ModAdvance,      ONLY: State_VGB, UseIdealState
    use ModB0,           ONLY: B0_DX, B0_DY, B0_DZ
    use ModMain,         ONLY: UseB0
    use ModMultiFluid,   ONLY: MassIon_I
    use ModNumConst,     ONLY: cTolerance
    use ModPhysics,      ONLY: Si2No_V, UnitTemperature_, &
         ElectronTemperatureRatio, AverageIonCharge
    use ModUser,         ONLY: user_material_properties
    use ModVarIndexes,   ONLY: nVar, Bx_, Bz_, Rho_, p_

    integer, intent(in) :: iDim, i, j, k, iBlock
    real, intent(in) :: State_V(nVar), Normal_D(3)
    real, intent(out):: HeatCond_D(3)

    real :: B_D(3), Bnorm, Bunit_D(3), TeSi, Te, TeFraction
    real :: HeatCoef, FractionSpitzer, FractionFieldAligned
    !--------------------------------------------------------------------------

    if(UseB0)then
       select case(iDim)
       case(1)
          B_D = State_V(Bx_:Bz_) + B0_DX(:,i,j,k)
       case(2)
          B_D = State_V(Bx_:Bz_) + B0_DY(:,i,j,k)
       case(3)
          B_D = State_V(Bx_:Bz_) + B0_DZ(:,i,j,k)
       end select
    else
       B_D = State_V(Bx_:Bz_)
    end if

    ! The magnetic field should nowhere be zero. The following fix will
    ! turn the magnitude of the field direction to zero.
    Bnorm = sqrt(sum(B_D**2))
    Bunit_D = B_D/max(Bnorm,cTolerance)

    if(UseIdealState)then
       TeFraction = MassIon_I(1)*ElectronTemperatureRatio &
            /(1 + AverageIonCharge*ElectronTemperatureRatio)
       Te = TeFraction*State_V(p_)/State_V(Rho_)
    else
       ! Note we assume that the heat conduction formula for the
       ! ideal state is still applicable for the non-ideal state
       call user_material_properties(State_V, TeSiOut=TeSi)
       Te = TeSi*Si2No_V(UnitTemperature_)
    end if

    if(DoTestHeatConduction)then
       HeatCoef = 1.0
    else

       if(DoModifyHeatConduction)then
          ! Artificial modified heat conduction for a smoother transition
          ! region, Linker et al. (2001)
          FractionSpitzer = 0.5*(1.0+tanh((Te-Tmodify)/DeltaTmodify))
          HeatCoef = HeatConductionPar*(FractionSpitzer*Te**2.5 &
               + (1.0 - FractionSpitzer)*Tmodify**2.5)
       else
          ! Spitzer form for collisional regime
          HeatCoef = HeatConductionPar*Te**2.5
       end if
    end if

    if(DoWeakFieldConduction)then
       FractionFieldAligned = 0.5*(1.0+tanh((Bnorm-Bmodify)/DeltaBmodify))

       HeatCond_D = HeatCoef*( &
            FractionFieldAligned*sum(Bunit_D*Normal_D)*Bunit_D &
            + (1.0 - FractionFieldAligned)*Normal_D )
    else
       HeatCond_D = HeatCoef*sum(Bunit_D*Normal_D)*Bunit_D
    end if

  end subroutine get_heat_conduction_coef

  !============================================================================
  ! Operator split, semi-implicit subroutines
  !============================================================================

  subroutine get_impl_heat_cond_state(StateImpl_VGB, DconsDsemi_VCB)

    use ModAdvance,    ONLY: State_VGB, UseIdealState, &
       LeftState_VX,  LeftState_VY,  LeftState_VZ,  &
       RightState_VX, RightState_VY, RightState_VZ
    use ModFaceValue,  ONLY: calc_face_value
    use ModGeometry,   ONLY: fAx_BLK, fAy_BLK, fAz_BLK
    use ModImplicit,   ONLY: nw, nImplBLK, impl2iBlk, iTeImpl
    use ModMain,       ONLY: nI, nJ, nK, MaxImplBlk, x_, y_, z_
    use ModMultiFluid, ONLY: MassIon_I
    use ModPhysics,    ONLY: Si2No_V, UnitTemperature_, UnitEnergyDens_, &
         AverageIonCharge, ElectronTemperatureRatio, inv_gm1
    use ModUser,       ONLY: user_material_properties
    use ModVarIndexes, ONLY: Rho_, p_

    real, intent(out) :: StateImpl_VGB(nw,0:nI+1,0:nJ+1,0:nK+1,MaxImplBlk)
    real, intent(inout) :: DconsDsemi_VCB(nw,nI,nJ,nK,MaxImplBlk)

    integer :: i, j, k, iBlock, iImplBlock
    real :: TeSi, CvSi, TeFraction
    real :: Normal_D(3), HeatCondL_D(3), HeatCondR_D(3)
    !--------------------------------------------------------------------------

    do iImplBlock = 1, nImplBLK
       iBlock = impl2iBLK(iImplBlock)

       if(UseIdealState)then
          TeFraction = MassIon_I(1)*ElectronTemperatureRatio &
               /(1 + AverageIonCharge*ElectronTemperatureRatio)
          do k = 1, nK; do j = 1, nJ; do i = 1, nI
             StateImpl_VGB(iTeImpl,i,j,k,iImplBlock) = &
                  TeFraction*State_VGB(p_,i,j,k,iBlock) &
                  /State_VGB(Rho_,i,j,k,iBlock)
             DconsDsemi_VCB(iTeImpl,i,j,k,iImplBlock) = &
                  inv_gm1*State_VGB(Rho_,i,j,k,iBlock)/TeFraction
          end do; end do; end do
       else
          do k = 1, nK; do j = 1, nJ; do i = 1, nI
             call user_material_properties( &
                  State_VGB(:,i,j,k,iBlock), TeSiOut=TeSi, CvSiOut = CvSi)
             StateImpl_VGB(iTeImpl,i,j,k,iImplBlock) = &
                  TeSi*Si2No_V(UnitTemperature_)
             DconsDsemi_VCB(iTeImpl,i,j,k,iImplBlock) = &
                  CvSi*Si2No_V(UnitEnergyDens_)/Si2No_V(UnitTemperature_)
          end do; end do; end do
       end if

       call calc_face_value(.false.,iBlock)

       Normal_D = (/ 1.0, 0.0, 0.0 /)
       do k = 1, nK; do j = 1, nJ; do i = 1, nI+1
          call get_heat_conduction_coef(x_, i, j, k, iBlock, &
               LeftState_VX(:,i,j,k), Normal_D, HeatCondL_D)
          call get_heat_conduction_coef(x_, i, j, k, iBlock, &
               RightState_VX(:,i,j,k), Normal_D, HeatCondR_D)
          HeatCond_DXB(:,i,j,k,iBlock) = 0.5*(HeatCondL_D + HeatCondR_D) &
               *fAx_BLK(iBlock)
       end do; end do; end do
       Normal_D = (/ 0.0, 1.0, 0.0 /)
       do k = 1, nK; do j = 1, nJ+1; do i = 1, nI
          call get_heat_conduction_coef(y_, i, j, k, iBlock, &
               LeftState_VY(:,i,j,k), Normal_D, HeatCondL_D)
          call get_heat_conduction_coef(y_, i, j, k, iBlock, &
               RightState_VY(:,i,j,k), Normal_D, HeatCondR_D)
          HeatCond_DYB(:,i,j,k,iBlock) = 0.5*(HeatCondL_D + HeatCondR_D) &
               *fAy_BLK(iBlock)
       end do; end do; end do
       Normal_D = (/ 0.0, 0.0, 1.0 /)
       do k = 1, nK+1; do j = 1, nJ; do i = 1, nI
          call get_heat_conduction_coef(z_, i, j, k, iBlock, &
               LeftState_VZ(:,i,j,k), Normal_D, HeatCondL_D)
          call get_heat_conduction_coef(z_, i, j, k, iBlock, &
               RightState_VZ(:,i,j,k), Normal_D, HeatCondR_D)
          HeatCond_DZB(:,i,j,k,iBlock) = 0.5*(HeatCondL_D + HeatCondR_D) &
               *fAz_BLK(iBlock)
       end do; end do; end do

    end do

  end subroutine get_impl_heat_cond_state

  !============================================================================

  subroutine get_heat_conduction_bc(iBlock, IsLinear)

    use ModImplicit, ONLY: StateSemi_VGB, nw
    use ModMain,     ONLY: nI, nJ, nK, TypeBc_I
    use ModParallel, ONLY: NOBLK, NeiLev
    use ModUser,     ONLY: user_set_outerbcs

    integer, intent(in) :: iBlock
    logical, intent(in) :: IsLinear

    logical :: IsFound
    character(len=20), parameter :: TypeUserBc = 'usersemi'
    character(len=20), parameter :: TypeUserBcLinear = 'usersemilinear'
    character(len=*),  parameter :: NameSub = 'get_heat_conduction_bc'
    !--------------------------------------------------------------------------

    if(NeiLev(1,iBlock) == NOBLK)then
       if(TypeBc_I(1) == 'outflow' .or. TypeBc_I(1) == 'float')then
          if(IsLinear)then
             StateSemi_VGB(:,0,:,:,iBlock) = 0.0
          else
             StateSemi_VGB(:,0,:,:,iBlock) = StateSemi_VGB(:,1,:,:,iBlock)
          end if
       elseif(TypeBc_I(1) == 'user')then
          if(IsLinear)then
             StateSemi_VGB(:,0,:,:,iBlock) = 0.0
             call user_set_outerbcs(iBlock,1,TypeUserBcLinear,IsFound)
          else
             IsFound = .false.
             call user_set_outerbcs(iBlock,1,TypeUserBc,IsFound)
             if(.not. IsFound) call stop_mpi(NameSub//': unknown TypeBc=' &
                  //TypeUserBc//' on iSide=1 in user_set_outerbcs')
          end if
       elseif(TypeBc_I(1) == 'reflect')then
          StateSemi_VGB(:,0,:,:,iBlock) = StateSemi_VGB(:,1,:,:,iBlock)
       else
          call stop_mpi(NameSub//': unknown TypeBc_I(1)='//TypeBc_I(1))
       end if
    end if
    if(NeiLev(2,iBlock) == NOBLK)then
       if(TypeBc_I(2) == 'outflow' .or. TypeBc_I(2) == 'float')then
          if(IsLinear)then
             StateSemi_VGB(:,nI+1,:,:,iBlock) = 0.0
          else
             StateSemi_VGB(:,nI+1,:,:,iBlock) = StateSemi_VGB(:,nI,:,:,iBlock)
          end if
       elseif(TypeBc_I(2) == 'user')then
          if(IsLinear)then
             StateSemi_VGB(:,nI+1,:,:,iBlock) = 0.0
             call user_set_outerbcs(iBlock,2,TypeUserBcLinear,IsFound)
          else
             IsFound = .false.
             call user_set_outerbcs(iBlock,2,TypeUserBc,IsFound)
             if(.not. IsFound) call stop_mpi(NameSub//': unknown TypeBc=' &
                  //TypeUserBc//' on iSide=2 in user_set_outerbcs')
          end if
       elseif(TypeBc_I(2) == 'reflect')then
          StateSemi_VGB(:,nI+1,:,:,iBlock) = StateSemi_VGB(:,nI,:,:,iBlock)
       else
          call stop_mpi(NameSub//': unknown TypeBc_I(2)='//TypeBc_I(2))
       end if
    end if
    if(NeiLev(3,iBlock) == NOBLK)then
       if(TypeBc_I(3) == 'outflow' .or. TypeBc_I(3) == 'float')then
          if(IsLinear)then
             StateSemi_VGB(:,:,0,:,iBlock) = 0.0
          else
             StateSemi_VGB(:,:,0,:,iBlock) = StateSemi_VGB(:,:,1,:,iBlock)
          end if
       elseif(TypeBc_I(3) == 'user')then
          if(IsLinear)then
             StateSemi_VGB(:,:,0,:,iBlock) =  0.0
             call user_set_outerbcs(iBlock,3,TypeUserBcLinear,IsFound)
          else
             IsFound = .false.
             call user_set_outerbcs(iBlock,3,TypeUserBc,IsFound)
             if(.not. IsFound) call stop_mpi(NameSub//': unknown TypeBc=' &
                  //TypeUserBc//' on iSide=3 in user_set_outerbcs')
          end if
       elseif(TypeBc_I(3) == 'reflect')then
          StateSemi_VGB(:,:,0,:,iBlock) = StateSemi_VGB(:,:,1,:,iBlock)
       else
          call stop_mpi(NameSub//': unknown TypeBc_I(3)='//TypeBc_I(3))
       end if
    end if
    if(NeiLev(4,iBlock) == NOBLK) then
       if(TypeBc_I(4) == 'outflow' .or. TypeBc_I(4) == 'float')then
          if(IsLinear)then
             StateSemi_VGB(:,:,nJ+1,:,iBlock) = 0.0
          else
             StateSemi_VGB(:,:,nJ+1,:,iBlock) = StateSemi_VGB(:,:,nJ,:,iBlock)
          end if
       elseif(TypeBc_I(4) == 'user')then
          if(IsLinear)then
             StateSemi_VGB(:,:,nJ+1,:,iBlock) = 0.0
             call user_set_outerbcs(iBlock,4,TypeUserBcLinear,IsFound)
          else
             IsFound = .false.
             call user_set_outerbcs(iBlock,4,TypeUserBc,IsFound)
             if(.not. IsFound) call stop_mpi(NameSub//': unknown TypeBc=' &
                  //TypeUserBc//' on iSide=4 in user_set_outerbcs')
          end if
       elseif(TypeBc_I(4) == 'reflect')then
          StateSemi_VGB(:,:,nJ+1,:,iBlock) = StateSemi_VGB(:,:,nJ,:,iBlock)
       else
          call stop_mpi(NameSub//': unknown TypeBc_I(4)='//TypeBc_I(4))
       end if
    end if
    if(NeiLev(5,iBlock) == NOBLK) then
       if(TypeBc_I(5) == 'outflow' .or. TypeBc_I(5) == 'float')then
          if(IsLinear)then
             StateSemi_VGB(:,:,:,0,iBlock) = 0.0
          else
             StateSemi_VGB(:,:,:,0,iBlock) = StateSemi_VGB(:,:,:,1,iBlock)
          end if
       elseif(TypeBc_I(5) == 'user')then
          if(IsLinear)then
             StateSemi_VGB(:,:,:,0,iBlock) = 0.0
             call user_set_outerbcs(iBlock,5,TypeUserBcLinear,IsFound)
          else
             IsFound = .false.
             call user_set_outerbcs(iBlock,5,TypeUserBc,IsFound)
             if(.not. IsFound) call stop_mpi(NameSub//': unknown TypeBc=' &
                  //TypeUserBc//' on iSide=5 in user_set_outerbcs')
          end if
       elseif(TypeBc_I(5) == 'reflect')then
          StateSemi_VGB(:,:,:,0,iBlock) = StateSemi_VGB(:,:,:,1,iBlock)
       else
          call stop_mpi(NameSub//': unknown TypeBc_I(5)='//TypeBc_I(5))
       end if
    end if
    if(NeiLev(6,iBlock) == NOBLK)then 
       if(TypeBc_I(6) == 'outflow' .or. TypeBc_I(6) == 'float')then
          if(IsLinear)then
             StateSemi_VGB(:,:,:,nK+1,iBlock) = 0.0
          else
             StateSemi_VGB(:,:,:,nK+1,iBlock) = StateSemi_VGB(:,:,:,nK,iBlock)
          end if
       elseif(TypeBc_I(6) == 'user')then
          if(IsLinear)then
             StateSemi_VGB(:,:,:,nK+1,iBlock) = 0.0
             call user_set_outerbcs(iBlock,6,TypeUserBcLinear,IsFound)
          else
             IsFound = .false.
             call user_set_outerbcs(iBlock,6,TypeUserBc,IsFound)
             if(.not. IsFound) call stop_mpi(NameSub//': unknown TypeBc=' &
                  //TypeUserBc//' on iSide=6 in user_set_outerbcs')
          end if
       elseif(TypeBc_I(6) == 'reflect')then
          StateSemi_VGB(:,:,:,nK+1,iBlock) = StateSemi_VGB(:,:,:,nK,iBlock)
       else
          call stop_mpi(NameSub//': unknown TypeBc_I(6)='//TypeBc_I(6))
       end if
    end if

  end subroutine get_heat_conduction_bc

  !============================================================================

  subroutine get_heat_conduction_rhs(iBlock, StateImpl_VG, Rhs_VC, IsLinear)

    use ModFaceGradient, ONLY: get_face_gradient
    use ModGeometry,     ONLY: vInv_CB
    use ModImplicit,     ONLY: nw, iTeImpl
    use ModMain,         ONLY: nI, nJ, nK, x_, y_, z_

    integer, intent(in) :: iBlock
    real, intent(inout) :: StateImpl_VG(nw,-1:nI+2,-1:nJ+2,-1:nK+2)
    real, intent(out)   :: Rhs_VC(nw,nI,nJ,nK)
    logical, intent(in) :: IsLinear

    integer :: i, j, k
    real :: FaceGrad_D(3)
    logical :: IsNewBlockHeatConduction
    !--------------------------------------------------------------------------

    IsNewBlockHeatConduction = .true.

    do k = 1, nK; do j = 1, nJ; do i = 1, nI+1
       call get_face_gradient(x_, i, j, k, iBlock, &
            IsNewBlockHeatConduction, StateImpl_VG, FaceGrad_D)
       FluxImpl_X(i,j,k) = -sum(HeatCond_DXB(:,i,j,k,iBlock)*FaceGrad_D)
    end do; end do; end do
    do k = 1, nK; do j = 1, nJ+1; do i = 1, nI
       call get_face_gradient(y_, i, j, k, iBlock, &
            IsNewBlockHeatConduction, StateImpl_VG, FaceGrad_D)
       FluxImpl_Y(i,j,k) = -sum(HeatCond_DYB(:,i,j,k,iBlock)*FaceGrad_D)
    end do; end do; end do
    do k = 1, nK+1; do j = 1, nJ; do i = 1, nI
       call get_face_gradient(z_, i, j, k, iBlock, &
            IsNewBlockHeatConduction, StateImpl_VG, FaceGrad_D)
       FluxImpl_Z(i,j,k) = -sum(HeatCond_DZB(:,i,j,k,iBlock)*FaceGrad_D)
    end do; end do; end do

    do k = 1, nK; do j = 1, nJ; do i = 1, nI
       Rhs_VC(:,i,j,k) = vInv_CB(i,j,k,iBlock) &
            *(FluxImpl_X(i,j,k) - FluxImpl_X(i+1,j,k) &
            + FluxImpl_Y(i,j,k) - FluxImpl_Y(i,j+1,k) &
            + FluxImpl_Z(i,j,k) - FluxImpl_Z(i,j,k+1) )
    end do; end do; end do

  end subroutine get_heat_conduction_rhs

  !============================================================================

  subroutine get_heat_cond_jacobian(iBlock, nVar, Jacobian_VVCI)

    use ModImplicit, ONLY: iTeImpl
    use ModMain,     ONLY: nI, nJ, nK, nDim

    integer, parameter:: nStencil = 2*nDim + 1

    integer, intent(in) :: iBlock, nVar
    real, intent(out) :: Jacobian_VVCI(nVar,nVar,nI,nJ,nK,nStencil)
    !--------------------------------------------------------------------------

    ! All elements have to be set
    Jacobian_VVCI(:,:,:,:,:,:) = 0.0

  end subroutine get_heat_cond_jacobian

  !============================================================================

  subroutine update_impl_heat_cond(iBlock, iImplBlock, StateImpl_VG)

    use ModAdvance,  ONLY: State_VGB, Energy_GBI, UseIdealState, p_, &
         ExtraEint_
    use ModEnergy,   ONLY: calc_energy_cell, calc_pressure_cell
    use ModImplicit, ONLY: nw, iTeImpl, DconsDsemi_VCB, ImplOld_VCB
    use ModMain,     ONLY: nI, nJ, nK
    use ModPhysics,  ONLY: inv_gm1, No2Si_V, Si2No_V, UnitEnergyDens_, &
         UnitP_
    use ModUser,     ONLY: user_material_properties

    integer, intent(in) :: iBlock, iImplBlock
    real, intent(in) :: StateImpl_VG(nw,nI,nJ,nK)

    integer :: i, j, k
    real :: Einternal, EinternalSi, PressureSi
    !--------------------------------------------------------------------------

    if(UseIdealState)then
       do k = 1, nK; do j = 1, nJ; do i = 1, nI
          Energy_GBI(i,j,k,iBlock,1) = Energy_GBI(i,j,k,iBlock,1) &
               + DconsDsemi_VCB(iTeImpl,i,j,k,iImplBlock) &
               *( StateImpl_VG(iTeImpl,i,j,k) &
               -  ImplOld_VCB(iTeImpl,i,j,k,iBlock) )
       end do; end do; end do

       call calc_pressure_cell(iBlock)
    else
       do k = 1, nK; do j = 1, nJ; do i = 1, nI
          Einternal = inv_gm1*State_VGB(p_,i,j,k,iBlock) &
               + State_VGB(ExtraEint_,i,j,k,iBlock) &
               + DconsDsemi_VCB(iTeImpl,i,j,k,iImplBlock) &
               *( StateImpl_VG(iTeImpl,i,j,k) &
               -  ImplOld_VCB(iTeImpl,i,j,k,iBlock) )

          EinternalSi = Einternal*No2Si_V(UnitEnergyDens_)

          call user_material_properties(State_VGB(:,i,j,k,iBlock), &
               EinternalSiIn = EinternalSi, PressureSiOut = PressureSi)

          State_VGB(p_,i,j,k,iBlock) = PressureSi*Si2No_V(UnitP_)
          State_VGB(ExtraEint_,i,j,k,iBlock) = &
               Einternal - inv_gm1*State_VGB(p_,i,j,k,iBlock)

       end do; end do; end do

       call calc_energy_cell(iBlock)
    end if

  end subroutine update_impl_heat_cond

end module ModHeatConduction
