!  Copyright (C) 2002 Regents of the University of Michigan,
!  portions used with permission
!  For more information, see http://csem.engin.umich.edu/tools/swmf
module ModCalcSource

  use BATL_lib, ONLY: &
       test_start, test_stop, StringTest, iTest, jTest, kTest, &
       iBlockTest, iVarTest
#ifdef OPENACC
  use ModUtilities, ONLY: norm2
#endif

  implicit none
  SAVE

  private ! except

  ! Public methods
  public :: calc_source

contains
  !============================================================================

  subroutine calc_source(iBlock)
    !$acc routine vector
    use ModMain,          ONLY: GravityDir, UseBody2, TypeCoordSystem, &
         UseB0, UseDivBsource, UseRadDiffusion, DoThinCurrentSheet, &
         UseUserSourceExpl, UseUserSourceImpl
    use ModAdvance
    use ModGeometry,      ONLY: R_BLK, R2_Blk, true_cell
    use ModPhysics
    use ModCoordTransform
    use ModElectricField, ONLY: get_efield_in_comoving_frame
    use ModImplicit,      ONLY: UseFullImplicit
    use ModRadDiffusion,  ONLY: calc_source_rad_diffusion
    use ModMultiFluid
    use ModPointImplicit, ONLY: UsePointImplicit
    use ModMultiIon,      ONLY: multi_ion_source_expl, multi_ion_source_impl
    use ModIonElectron,   ONLY: ion_electron_source_impl
    use ModWaves,         ONLY: UseWavePressure, GammaWave, DivU_C
    use ModCoronalHeating, ONLY: UseCoronalHeating, get_block_heating, &
         CoronalHeating_C, UseAlfvenWaveDissipation, WaveDissipation_VC, &
         apportion_coronal_heating, UseTurbulentCascade, get_wave_reflection, &
         UseAlignmentAngle, Cdiss_C
    use ModRadiativeCooling, ONLY: RadCooling_C,UseRadCooling, &
         get_radiative_cooling, add_chromosphere_heating
    use ModChromosphere,  ONLY: DoExtendTransitionRegion, extension_factor, &
         UseChromosphereHeating, get_tesi_c, TeSi_C
    use ModFaceFlux,      ONLY: Pe_G
    use ModHallResist,    ONLY: UseBiermannBattery, IonMassPerCharge_G
    use ModB0,            ONLY: set_b0_source, UseB0Source, UseCurlB0, &
         rCurrentFreeB0, DivB0_C, CurlB0_DC, B0_DGB, B0_DX, B0_DY, B0_DZ
    use BATL_lib,         ONLY: IsCartesian, IsRzGeometry, &
         Xyz_DGB, CellSize_DB, CellVolume_GB, x_, y_, z_, Dim1_, Dim2_, Dim3_,&
         correct_face_value
    use ModViscosity,     ONLY: &
         UseViscosity, set_visco_factor_cell, ViscoFactor_C
    use ModBorisCorrection, ONLY: UseBorisCorrection, add_boris_source

    use ModUserInterface, ONLY: user_calc_sources_expl, user_calc_sources_impl

    integer, intent(in):: iBlock

    integer :: i, j, k, iVar, iFluid
    integer:: iGang
    real :: Pe, Pwave, DivU
    real :: Coef

    ! Variable for B0 source term

    real :: CurlB0CrossB_D(3)

    ! Variables needed for Boris source terms also used for div(u)
    real :: RhoInv

    ! Variables needed for anisotropic pressure
    real :: b_D(MaxDim), GradU_DD(nDim,MaxDim), bDotGradparU

    ! Gravitational force towards body
    real :: ForcePerRho_D(3)

    ! Momentum index parallel with gravity direction
    integer:: iRhoUGrav

    ! For centrifugal force
    real :: Omega2

    ! Viscosity
    real, parameter:: cTwoThirds = 2.0/3.0
    real :: Visco, Tmp, ViscoCoeff

    ! Coronal Heating
    real :: QPerQtotal_I(IonFirst_:IonLast_)
    real :: QparPerQtotal_I(IonFirst_:IonLast_)
    real :: QePerQtotal

    ! Variables for multi-ion MHD
    real :: InvElectronDens, uPlus_D(3), U_D(3)

    ! Variables for Minimum radial speed
    real :: Ur, Rho, rUnit_D(3), Force_D(3)

    logical:: DoTestCell

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'calc_source'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest, iBlock)

    iGang = 1
#ifdef OPENACC
    iGang = iBlock
#endif

    !$acc loop vector collapse(4)
    do k = 1, nK; do j = 1, nJ; do i = 1, nI; do iVar = 1, nSource
       Source_VCI(iVar,i,j,k,iGang) = 0
    end do; end do; end do; end do

    !$acc loop vector collapse(4)
    do k = 1, nK; do j = 1, nJ; do i = 1, nI; do iVar = RhoUx_, RhoUz_
       SourceMhd_VCI(iVar,i,j,k,iGang) = 0
    end do; end do; end do; end do

#ifndef OPENACC
    ! Calculate source terms for ion pressure
    if(UseNonconservative .or. UseAnisoPressure)then
       do iFluid=1,nFluid
          if(nFluid > 1) call select_fluid(iFluid)

          if((UseAnisoPressure .and. IsIon_I(iFluid)) &
               .or. (UseViscosity .and. nFluid == 1))then

             if(UseViscosity)call set_visco_factor_cell(iBlock)

             ! Source terms for anisotropic pressure equations
             do k=1,nK; do j=1,nJ; do i=1,nI
                DoTestCell = DoTest .and. i==iTest .and. &
                     j==jTest .and. k==kTest

                if(.not.true_cell(i,j,k,iBlock)) CYCLE

                if(UseViscosity) then
                   ViscoCoeff = ViscoFactor_C(i,j,k)
                   if(.not. UseAnisoPressure .and. ViscoCoeff <= 0.0 ) CYCLE
                end if

                ! Calculate gradient tensor of velocity
                call calc_grad_U(GradU_DD, i, j, k, iBlock)

                if(UseAnisoPressure .and. IsIon_I(iFluid))then
                   ! Calculate bDotGradparU = b dot (b matmul GradU)

                   ! Calculate unit vector parallel with full B field
                   b_D = State_VGB(Bx_:Bz_,i,j,k,iBlock)
                   if(UseB0) b_D = b_D + B0_DGB(:,i,j,k,iBlock)
                   b_D = b_D/norm2(b_D)

                   ! Calculate b.grad u.b
                   bDotGradparU= dot_product(b_D, matmul(b_D(1:nDim),GradU_DD))

                   ! p parallel: -2*ppar*b.(b.(Grad U))
                   Source_VCI(iPpar,i,j,k,iGang) = Source_VCI(iPpar,i,j,k,iGang) &
                        - 2*State_VGB(iPpar,i,j,k,iBlock)*bDotGradparU

                   ! p : 2/3*(pperp - ppar)*b.(b.(GradU))
                   !     = (p - ppar)*b.(b.(GradU))
                   Source_VCI(iP,i,j,k,iGang) = Source_VCI(iP,i,j,k,iGang) &
                        + (State_VGB(iP,i,j,k,iBlock) -  &
                        State_VGB(iPpar,i,j,k,iBlock))*bDotGradparU
                end if

                if(UseViscosity) then

                   if(ViscoCoeff <= 0.0 ) CYCLE

                   ! Source(p) = (gamma - 1)*d_i u_j tau_ij
                   ! tau_ij = rho*nu*(d_i u_j + d_j u_i - 2/3 delta_ij div u)

                   ! Calculate first -2/3 (div u)^2
                   Visco              =         GradU_DD(Dim1_,1)
                   if(nDim > 1) Visco = Visco + GradU_DD(Dim2_,2)
                   if(nDim > 2) Visco = Visco + GradU_DD(Dim3_,3)
                   Visco = -cTwoThirds*Visco**2

                   ! Add 2*Sum_i (d_i u_i)^2
                   Visco              = Visco + 2.0*GradU_DD(Dim1_,1)**2
                   if(nDim > 1) Visco = Visco + 2.0*GradU_DD(Dim2_,2)**2
                   if(nDim > 2) Visco = Visco + 2.0*GradU_DD(Dim3_,3)**2

                   ! Add Sum_{i<j} (d_i u_j + d_j u_i)^2
                   Tmp              =       GradU_DD(Dim1_,2)
                   if(nDim > 1) Tmp = Tmp + GradU_DD(Dim2_,1)
                   Visco = Visco + Tmp**2

                   Tmp              =       GradU_DD(Dim1_,3)
                   if(nDim > 2) Tmp = Tmp + GradU_DD(Dim3_,1)
                   Visco = Visco + Tmp**2

                   if(nDim > 1)then
                      Tmp              =       GradU_DD(Dim2_,3)
                      if(nDim > 2) Tmp = Tmp + GradU_DD(Dim3_,2)
                      Visco = Visco + Tmp**2
                   end if

                   ! Source(p) = (gamma - 1)*tau:grad u
                   Source_VCI(p_,i,j,k,iGang) = Source_VCI(p_,i,j,k,iGang) + &
                        GammaMinus1*ViscoCoeff * &
                        State_VGB(Rho_,i,j,k,iBlock)*Visco
                end if
             end do; end do; end do

             if(DoTest .and. UseAnisoPressure .and. &
                  (iVarTest == iPparIon_I(IonFirst_) .or. iVarTest == p_)) &
                  call write_source('After bDotGradparU')

          end if

          ! Adiabatic heating: -(g-1)*P*Div(U)
          do k=1,nK; do j=1,nJ; do i=1,nI
             if(.not.true_cell(i,j,k,iBlock)) CYCLE

             DivU = uDotArea_XII(i+1,j,k,iFluid,iGang) - uDotArea_XII(i,j,k,iFluid,iGang)
             if(nJ > 1) DivU = DivU &
                  + uDotArea_YII(i,j+1,k,iFluid,iGang) - uDotArea_YII(i,j,k,iFluid,iGang)
             if(nK > 1) DivU = DivU &
                  + uDotArea_ZII(i,j,k+1,iFluid,iGang) - uDotArea_ZII(i,j,k,iFluid,iGang)
             DivU = DivU/CellVolume_GB(i,j,k,iBlock)
             if(UseAnisoPressure .and. IsIon_I(iFluid))then
                Source_VCI(iP,i,j,k,iGang) = Source_VCI(iP,i,j,k,iGang) &
                     - (State_VGB(iP,i,j,k,iBlock) &
                     - State_VGB(iPpar,i,j,k,iBlock)/3.0)*DivU
             else
                Source_VCI(iP,i,j,k,iGang) = Source_VCI(iP,i,j,k,iGang) &
                     - GammaMinus1_I(iFluid)*State_VGB(iP,i,j,k,iBlock)*DivU
             end if
          end do; end do; end do

          if(DoTest .and. iVarTest==iP)call write_source('After p div U')
       end do ! iFluid
    end if ! UseAnisoPressure.or.UseNonConservative

    if(UseSpeedMin)then
       ! push radial ion speed above SpeedMin outside rSpeedMin
       do k=1,nK; do j=1,nJ; do i=1,nI
          if(r_BLK(i,j,k,iBlock) < rSpeedMin) CYCLE
          rUnit_D = Xyz_DGB(:,i,j,k,iBlock)/r_BLK(i,j,k,iBlock)
          do iFluid = 1, nIonFluid
             if(nFluid > 1) call select_fluid(iFluid)
             Rho = State_VGB(iRho,i,j,k,iBlock)
             u_D = State_VGB(iRhoUx:iRhoUz,i,j,k,iBlock)/Rho
             Ur =  sum(u_D *rUnit_D)
             if (Ur < SpeedMin) then
                Force_D = rUnit_D * Rho*(SpeedMin - Ur)/TauSpeedMin
                Source_VCI(iRhoUx:iRhoUz,i,j,k,iGang) = &
                     Source_VCI(iRhoUx:iRhoUz,i,j,k,iGang) + Force_D
                Source_VCI(iEnergy,i,j,k,iGang) = Source_VCI(iEnergy,i,j,k,iGang) &
                     + sum(Force_D * u_D)
             end if
          end do; end do; end do
       end do
    end if ! UseSpeedMin

    if(UseWavePressure)then
       do k=1,nK; do j=1,nJ; do i=1,nI
          if(.not.true_cell(i,j,k,iBlock)) CYCLE

          if(UseMultiIon)then
             ! The following should be Div(Uplus). For zero Hall velocity
             ! this is the same as Div(Ue).
             DivU = uDotArea_XII(i+1,j,k,eFluid_,iGang) - uDotArea_XII(i,j,k,eFluid_,iGang)
             if(nJ > 1) DivU = DivU &
                  + uDotArea_YII(i,j+1,k,eFluid_,iGang) - uDotArea_YII(i,j,k,eFluid_,iGang)
             if(nK > 1) DivU = DivU &
                  + uDotArea_ZII(i,j,k+1,eFluid_,iGang) - uDotArea_ZII(i,j,k,eFluid_,iGang)
          else
             DivU = uDotArea_XII(i+1,j,k,1,iGang) - uDotArea_XII(i,j,k,1,iGang)
             if(nJ > 1) DivU = DivU &
                  + uDotArea_YII(i,j+1,k,1,iGang) - uDotArea_YII(i,j,k,1,iGang)
             if(nK > 1) DivU = DivU &
                  + uDotArea_ZII(i,j,k+1,1,iGang) - uDotArea_ZII(i,j,k,1,iGang)
          end if
          DivU = DivU/CellVolume_GB(i,j,k,iBlock)

          ! Store div U so it can be used in ModWaves
          DivU_C(i,j,k) = DivU

          do iVar = WaveFirst_, WaveLast_
             Source_VCI(iVar,i,j,k,iGang) = Source_VCI(iVar,i,j,k,iGang) &
                  - DivU*(GammaWave - 1)*State_VGB(iVar,i,j,k,iBlock)
          end do

          if(.not.UseMultiIon)then
             Pwave = (GammaWave - 1) &
                  *sum(State_VGB(WaveFirst_:WaveLast_,i,j,k,iBlock))

             ! The energy equation contains the work of the wave pressure
             ! -u.grad Pwave = -div(u Pwave) + Pwave div(u)
             ! The -div(u Pwave) is implemented as a flux in ModFaceFlux.
             ! Here we add the Pwave div(u) source term
             Source_VCI(Energy_,i,j,k,iGang) = Source_VCI(Energy_,i,j,k,iGang) + DivU*Pwave

             ! Add "geometrical source term" p/r to the radial momentum
             ! equation. The "radial" direction is along the Y axis
             ! NOTE: here we have to use signed radial distance!
             if(IsRzGeometry) Source_VCI(RhoUy_,i,j,k,iGang) = &
                  Source_VCI(RhoUy_,i,j,k,iGang) + Pwave/Xyz_DGB(Dim2_,i,j,k,iBlock)
          end if
       end do; end do; end do
    end if

    if(UseTurbulentCascade) call get_wave_reflection(iBlock)

    if(UseCoronalHeating .and. DoExtendTransitionRegion .or. UseRadCooling) &
         call get_tesi_c(iBlock, TeSi_C)

    if(UseCoronalHeating)then
       call get_block_heating(iBlock)

       if(UseChromosphereHeating.and. DoExtendTransitionRegion)then
          call add_chromosphere_heating(TeSi_C, iBlock)
          do k=1,nK; do j=1,nJ; do i=1,nI
             CoronalHeating_C(i,j,k) = &
                  CoronalHeating_C(i,j,k)/extension_factor(TeSi_C(i,j,k))
          end do; end do; end do
       end if

       if(UseAlfvenWaveDissipation)then
          if(DoExtendTransitionRegion)then
             ! Does not work together with UseChromosphereHeating
             do k = 1, nK; do j = 1, nJ; do i = 1, nI
                Coef = extension_factor(TeSi_C(i,j,k))
                WaveDissipation_VC(:,i,j,k) = WaveDissipation_VC(:,i,j,k)/Coef
                CoronalHeating_C(i,j,k) = CoronalHeating_C(i,j,k)/Coef
             end do; end do; end do
          end if

          if(UseAlignmentAngle)then
             do k = 1, nK; do j = 1, nJ; do i = 1, nI
                WaveDissipation_VC(:,i,j,k) = WaveDissipation_VC(:,i,j,k) &
                     *Cdiss_C(i,j,k)
                CoronalHeating_C(i,j,k) = CoronalHeating_C(i,j,k) &
                     *Cdiss_C(i,j,k)
             end do; end do; end do
          end if

          do k = 1, nK; do j = 1, nJ; do i = 1, nI
             Source_VCI(WaveFirst_:WaveLast_,i,j,k,iGang) = &
                  Source_VCI(WaveFirst_:WaveLast_,i,j,k,iGang) &
                  - WaveDissipation_VC(:,i,j,k)
          end do; end do; end do
       end if

       do k = 1, nK; do j = 1, nJ; do i = 1, nI
          if(UseElectronPressure)then
             call apportion_coronal_heating(i, j, k, iBlock, &
                  WaveDissipation_VC(:,i,j,k), CoronalHeating_C(i,j,k), &
                  QPerQtotal_I, QparPerQtotal_I, QePerQtotal)

             Source_VCI(Pe_,i,j,k,iGang) = Source_VCI(Pe_,i,j,k,iGang) &
                  + CoronalHeating_C(i,j,k)*GammaElectronMinus1*QePerQtotal

             Source_VCI(iPIon_I,i,j,k,iGang) = Source_VCI(iPIon_I,i,j,k,iGang) &
                  + CoronalHeating_C(i,j,k)*QPerQtotal_I &
                  *GammaMinus1_I(IonFirst_:IonLast_)
             Source_VCI(Energy_-1+IonFirst_:Energy_-1+IonLast_,i,j,k,iGang) = &
                  Source_VCI(Energy_-1+IonFirst_:Energy_-1+IonLast_,i,j,k,iGang) &
                  + CoronalHeating_C(i,j,k)*QPerQtotal_I

             if(UseAnisoPressure)then
                do iFluid = IonFirst_, IonLast_
                   Source_VCI(iPparIon_I(iFluid),i,j,k,iGang) = &
                        Source_VCI(iPparIon_I(iFluid),i,j,k,iGang) &
                        + CoronalHeating_C(i,j,k)*QparPerQtotal_I(iFluid)*2.0
                end do
             end if
          else
             Source_VCI(p_,i,j,k,iGang) = Source_VCI(p_,i,j,k,iGang) &
                  + CoronalHeating_C(i,j,k)*GammaMinus1
             Source_VCI(Energy_,i,j,k,iGang) = Source_VCI(Energy_,i,j,k,iGang) &
                  + CoronalHeating_C(i,j,k)
          end if
       end do; end do; end do

    end if

    if(UseRadCooling)then
       do k = 1, nK; do j = 1, nJ; do i = 1, nI
          call get_radiative_cooling(i, j, k, iBlock, TeSi_C(i,j,k), &
               RadCooling_C(i,j,k))

          if(UseElectronPressure)then
             Source_VCI(Pe_,i,j,k,iGang) = Source_VCI(Pe_,i,j,k,iGang) &
                  + RadCooling_C(i,j,k)*GammaElectronMinus1

          else
             Source_VCI(p_,i,j,k,iGang)  = Source_VCI(p_,i,j,k,iGang) &
                  + RadCooling_C(i,j,k)*GammaMinus1
             Source_VCI(Energy_,i,j,k,iGang) = Source_VCI(Energy_,i,j,k,iGang) &
                  + RadCooling_C(i,j,k)
          end if
       end do; end do; end do
    end if

    if(UseElectronPressure .and. &
         .not.(UseElectronEntropy .and. UseMultiIon))then
       ! Calculate DivU = div(U_e)
       do k = 1, nK; do j = 1, nJ; do i = 1, nI
          DoTestCell = DoTest .and. i==iTest .and. j==jTest .and. k==kTest

          if(.not.true_cell(i,j,k,iBlock)) CYCLE
          DivU = uDotArea_XII(i+1,j,k,eFluid_,iGang) - uDotArea_XII(i,j,k,eFluid_,iGang)
          if(nJ > 1) DivU = DivU &
               + uDotArea_YII(i,j+1,k,eFluid_,iGang) - uDotArea_YII(i,j,k,eFluid_,iGang)
          if(nK > 1) DivU = DivU &
               + uDotArea_ZII(i,j,k+1,eFluid_,iGang) - uDotArea_ZII(i,j,k,eFluid_,iGang)
          DivU = DivU/CellVolume_GB(i,j,k,iBlock)

          Pe = State_VGB(Pe_,i,j,k,iBlock)

          if (UseAnisoPe) then
             ! Calculate bDotGradparU = b dot (b matmul GradU)

             call calc_grad_uPlus(GradU_DD, i, j, k, iBlock)

             ! Calculate unit vector parallel with full B field
             b_D = State_VGB(Bx_:Bz_,i,j,k,iBlock)
             if(UseB0) b_D = b_D + B0_DGB(:,i,j,k,iBlock)
             b_D = b_D/norm2(b_D)

             ! Calculate b.grad u.b
             bDotGradparU = dot_product(b_D, matmul(b_D(1:nDim),GradU_DD))

             ! p parallel: -2*ppar*b.(b.(Grad U))
             Source_VCI(Pepar_,i,j,k,iGang) = Source_VCI(Pepar_,i,j,k,iGang) &
                  - 2*State_VGB(Pepar_,i,j,k,iBlock)*bDotGradparU

             ! p : 2/3*(pperp - ppar)*b.(b.(GradU))
             !     = (p - ppar)*b.(b.(GradU))
             Source_VCI(Pe_,i,j,k,iGang)    = Source_VCI(Pe_,i,j,k,iGang)      &
                  + (State_VGB(Pe_,i,j,k,iBlock) -               &
                  State_VGB(Pepar_,i,j,k,iBlock))*bDotGradparU

             if(DoTestCell) write(*,*) ' GradU_DD=', GradU_DD

             if(DoTestCell .and. (iVarTest == Pepar_ .or. iVarTest == pe_)) &
                  call write_source('After bDotGradparUplus')
          end if

          ! For electron entropy equation there is no such term
          if(.not.UseElectronEntropy .and. .not. UseAnisoPe) then
             ! Adiabatic heating for electron pressure: -(g-1)*Pe*Div(U)
             Source_VCI(Pe_,i,j,k,iGang) = &
                  Source_VCI(Pe_,i,j,k,iGang) - GammaElectronMinus1*Pe*DivU
          else if(.not.UseElectronEntropy .and. UseAnisoPe) then
             Source_VCI(Pe_,i,j,k,iGang) = Source_VCI(Pe_,i,j,k,iGang) &
                  - (State_VGB(Pe_,i,j,k,iBlock)      &
                  - State_VGB(Pepar_,i,j,k,iBlock)/3.0)*DivU
          end if

          if(.not.UseMultiIon)then
             ! The energy equation contains the work of the electron pressure
             ! -u.grad Pe = -div(u Pe) + Pe div(u)
             ! The -div(u Pe) is implemented as a flux in ModFaceFlux.
             ! Here we add the Pe div(u_e) source term
             Source_VCI(Energy_,i,j,k,iGang) = Source_VCI(Energy_,i,j,k,iGang) + Pe*DivU

             ! Add "geometrical source term" p/r to the radial momentum
             ! equation. The "radial" direction is along the Y axis
             ! NOTE: here we have to use signed radial distance!
             if(IsRzGeometry) Source_VCI(RhoUy_,i,j,k,iGang) = &
                  Source_VCI(RhoUy_,i,j,k,iGang) + Pe/Xyz_DGB(y_,i,j,k,iBlock)
          end if
       end do; end do; end do
       if(DoTest.and.iVarTest==Pe_)call write_source('After Pe div Ue')
    end if

    if(IsRzGeometry)then
       ! The following geometrical source terms are added for the MHD equations
       ! Source[mr]  =(p+B^2/2-Bphi**2+mphi**2/rho)/radius
       ! Source[mphi]=(-mphi*mr/rho+Bphi*Br)/radius(if no angular momentum fix)
       ! Source[Bphi]=((Bphi*mr-Br*mphi)/rho)/radius

       ! The cylindrical coordinates are renamed to X,Y,Z
       ! The cylindrical axis is along X
       ! The "radial" direction is along the Y axis
       ! The azimuthal direction is along the Z axis

       do k = 1, nK; do j = 1, nJ; do i = 1, nI
          if(.not.true_cell(i,j,k,iBlock)) CYCLE

          ! Source[mr] = (p+mphi**2/rho)/radius
          Source_VCI(iRhoUy_I,i,j,k,iGang) = Source_VCI(iRhoUy_I,i,j,k,iGang) &
               + (State_VGB(iP_I,i,j,k,iBlock) &
               +  State_VGB(iRhoUz_I,i,j,k,iBlock)**2 &
               /  State_VGB(iRho_I,i,j,k,iBlock)) &
               / Xyz_DGB(y_,i,j,k,iBlock)

          ! Source[mphi] = (-mphi*mr/rho)/radius
          Source_VCI(iRhoUz_I,i,j,k,iGang) = Source_VCI(iRhoUz_I,i,j,k,iGang) &
               - State_VGB(iRhoUz_I,i,j,k,iBlock) &
               * State_VGB(iRhoUy_I,i,j,k,iBlock) &
               /(State_VGB(iRho_I,i,j,k,iBlock)*Xyz_DGB(y_,i,j,k,iBlock))

          if(UseB)then
             ! Source[mr] = (B^2/2-Bphi**2)/radius
             Source_VCI(RhoUy_,i,j,k,iGang) = Source_VCI(RhoUy_,i,j,k,iGang) &
                  + (0.5*sum(State_VGB(Bx_:Bz_,i,j,k,iBlock)**2) &
                  -  State_VGB(Bz_,i,j,k,iBlock)**2) / Xyz_DGB(y_,i,j,k,iBlock)

             ! Source[mphi]=Bphi*Br/radius
             Source_VCI(RhoUz_,i,j,k,iGang) = Source_VCI(RhoUz_,i,j,k,iGang) &
                  + State_VGB(Bz_,i,j,k,iBlock)*State_VGB(By_,i,j,k,iBlock) &
                  / Xyz_DGB(y_,i,j,k,iBlock)

             ! Source[Bphi]=((Bphi*mr-Br*mphi)/rho)/radius
             Source_VCI(Bz_,i,j,k,iGang) = Source_VCI(Bz_,i,j,k,iGang) &
                  + (State_VGB(Bz_,i,j,k,iBlock) &
                  *   State_VGB(RhoUy_,i,j,k,iBlock) &
                  -  State_VGB(By_,i,j,k,iBlock) &
                  *   State_VGB(RhoUz_,i,j,k,iBlock))&
                  /State_VGB(Rho_,i,j,k,iBlock)/Xyz_DGB(y_,i,j,k,iBlock)
          end if
          if(UseB .and. UseB0)then
             ! Source[mr] = (B0.B1 - 2 B0phi * Bphi)/radius
             Source_VCI(RhoUy_,i,j,k,iGang) = Source_VCI(RhoUy_,i,j,k,iGang) &
                  + (sum(State_VGB(Bx_:Bz_,i,j,k,iBlock) &
                  *      B0_DGB(:,i,j,k,iBlock)) &
                  - 2.0*State_VGB(Bz_,i,j,k,iBlock)*B0_DGB(z_,i,j,k,iBlock)) &
                  / Xyz_DGB(y_,i,j,k,iBlock)

             ! Source[mphi] = (B0phi * Br + Bphi * B0r)/radius
             Source_VCI(RhoUz_,i,j,k,iGang) = Source_VCI(RhoUz_,i,j,k,iGang) &
                  + (B0_DGB(z_,i,j,k,iBlock)*State_VGB(By_,i,j,k,iBlock) &
                  +  B0_DGB(y_,i,j,k,iBlock)*State_VGB(Bz_,i,j,k,iBlock)) &
                  / Xyz_DGB(y_,i,j,k,iBlock)

             ! Source[Bphi]=((B0phi * mr - B0r * mphi)/rho)/radius
             Source_VCI(Bz_,i,j,k,iGang) = Source_VCI(Bz_,i,j,k,iGang) &
                  + (B0_DGB(z_,i,j,k,iBlock)*State_VGB(RhoUy_,i,j,k,iBlock) &
                  -  B0_DGB(y_,i,j,k,iBlock)*State_VGB(RhoUz_,i,j,k,iBlock))&
                  /State_VGB(Rho_,i,j,k,iBlock)/Xyz_DGB(y_,i,j,k,iBlock)
          end if
       end do; end do; end do

       ! For now, no Hall MHD implementation for rz-geometry
       if(UseB .and. UseBiermannBattery .and. &
            (UseElectronPressure .or. ElectronPressureRatio > 0.0 .or. &
            .not.UseIdealEos))then

          do k = 1, nK; do j = 1, nJ; do i = 1, nI
             if(.not.true_cell(i,j,k,iBlock)) CYCLE

             ! Source[Bphi] = [ 1/(q_e*n_e) * (dP_e/dZ) ] / radius
             Source_VCI(Bz_,i,j,k,iGang) = Source_VCI(Bz_,i,j,k,iGang) &
                  + IonMassPerCharge_G(i,j,k)/State_VGB(Rho_,i,j,k,iBlock) &
                  /Xyz_DGB(y_,i,j,k,iBlock) &
                  *0.5*(Pe_G(i+1,j,k) - Pe_G(i-1,j,k))/CellSize_DB(x_,iBlock)
          end do; end do; end do
       end if
    end if

    ! We consider two cases: curl(B0) is zero analytically or non-zero
    ! These are distinguished by UseCurlB0 being true or false.
    !
    ! Momentum equation has the Lorentz force J x B
    !     = (curl B1) x (B1 + B0)     if curl B0 = 0
    !     = (curl B1+B0) x (B1 + B0)  if curl B0 is not 0
    !
    ! Conservative fluxes add the divergence of the Maxwell tensor
    !     div(B1^2 + B1.B0 - B1 B1 - B1 B0 - B0 B1)
    !
    ! Deviations between these two are
    !   -B1 div(B1)       - usual div B source
    !   -B1 div(B0)       - div(B0) source
    !   -curl(B0) x B1    - remove this if curl B0 = 0
    !   +curl(B0) x B0    - add this if curl B0 is not 0

    if(UseB0) call set_b0_source(iBlock)
#endif

    if(UseB .and. UseDivbSource)then
       if(IsCartesian)then
          call calc_divb_source(iBlock)
       else
#ifndef OPENACC
          call calc_divb_source_gencoord
#endif
       end if

       if(DoTest)write(*,*)'divb=',DivB1_GB(iTest,jTest,kTest,iBlockTest)
       if(DoTest.and.iVarTest>=RhoUx_.and.iVarTest<=RhoUz_)&
            call write_source('After B0B1 source')

       ! Add contributions to other source terms
       !$acc loop vector collapse(3) private(U_D)
       do k = 1, nK; do j = 1, nJ; do i = 1, nI
          if(.not.true_cell(i,j,k,iBlock)) CYCLE

          if(UseMultiIon .or. UseEfield)then
             ! inv of electron charge density
             InvElectronDens = 1.0/sum(ChargePerMass_I(1:nTrueIon) &
                  *State_VGB(iRhoIon_I(1:nTrueIon),i,j,k,iBlock))

             ! charge average ion velocity
             uPlus_D(x_) = InvElectronDens*sum(ChargePerMass_I(1:nTrueIon) &
                  *State_VGB(iRhoUxIon_I(1:nTrueIon),i,j,k,iBlock))
             uPlus_D(y_) = InvElectronDens*sum(ChargePerMass_I(1:nTrueIon) &
                  *State_VGB(iRhoUyIon_I(1:nTrueIon),i,j,k,iBlock))
             uPlus_D(z_) = InvElectronDens*sum(ChargePerMass_I(1:nTrueIon) &
                  *State_VGB(iRhoUzIon_I(1:nTrueIon),i,j,k,iBlock))

             Source_VCI(Bx_:Bz_,i,j,k,iGang) = Source_VCI(Bx_:Bz_,i,j,k,iGang) &
                  -DivB1_GB(i,j,k,iBlock)*uPlus_D
          else
             RhoInv = 1.0/State_VGB(Rho_,i,j,k,iBlock)
             U_D = RhoInv*State_VGB(RhoUx_:RhoUz_,i,j,k,iBlock)

             Source_VCI(Bx_:Bz_,i,j,k,iGang) = Source_VCI(Bx_:Bz_,i,j,k,iGang) &
                  -DivB1_GB(i,j,k,iBlock)*U_D

             if(.not. UseMhdMomentumFlux) CYCLE

             ! -B1 div(B1)       - usual div B source
             SourceMhd_VCI(RhoUx_:RhoUz_,i,j,k,iGang) = &
                  SourceMhd_VCI(RhoUx_:RhoUz_,i,j,k,iGang)  &
                  -DivB1_GB(i,j,k,iBlock)*State_VGB(Bx_:Bz_,i,j,k,iBlock)

             if(.not. IsMhd) CYCLE
             Source_VCI(Energy_,i,j,k,iGang) = Source_VCI(Energy_,i,j,k,iGang) &
                  -DivB1_GB(i,j,k,iBlock)*sum(State_VGB(Bx_:Bz_,i,j,k,iBlock) &
                  *U_D)

          end if

       end do; end do; end do

       if(DoTest)call write_source('After divb source')
#ifndef OPENACC
       if(UseB0Source .and. UseMhdMomentumFlux)then

          !   -B1 div(B0)     - div(B0) source
          ! -curl(B0) x B1    - remove this term (in case curl B0 should be 0)
          !                     have to undo this if curl B0 is actually not 0

          do k = 1, nK; do j = 1, nJ; do i = 1, nI
             if(.not.true_cell(i,j,k,iBlock)) CYCLE
             SourceMhd_VCI(RhoUx_:RhoUz_,i,j,k,iGang) = &
                  SourceMhd_VCI(rhoUx_:rhoUz_,i,j,k,iGang) &
                  - State_VGB(Bx_:Bz_,i,j,k,iBlock)*DivB0_C(i,j,k) &
                  - cross_product( &
                  CurlB0_DC(:,i,j,k), State_VGB(Bx_:Bz_,i,j,k,iBlock))
          end do; end do; end do

          if(DoTest.and.iVarTest>=RhoUx_.and.iVarTest<=RhoUz_)then
             write(*,*)'DivB0_C  =',DivB0_C(iTest,jTest,kTest)
             write(*,*)'CurlB0_DC=',CurlB0_DC(:,iTest,jTest,kTest)
             call write_source('After B0 source')
          end if
       end if
#endif
    else
#ifndef OPENACC
       if(UseB)call calc_divb(iBlock)
#endif
    end if

#ifndef OPENACC
    if(UseB .and. UseCurlB0 .and. UseMhdMomentumFlux)then

       do k = 1, nK; do j = 1, nJ; do i = 1, nI
          if(.not.true_cell(i,j,k,iBlock)) CYCLE
          if(R_BLK(i,j,k,iBlock) < rCurrentFreeB0)CYCLE

          ! +curl(B0) x B1    - undo source term above
          ! +curl(B0) x B0    - add this since curl B0 is not 0
          CurlB0CrossB_D = cross_product( CurlB0_DC(:,i,j,k),&
               State_VGB(Bx_:Bz_,i,j,k,iBlock) + B0_DGB(:,i,j,k,iBlock))
          SourceMhd_VCI(rhoUx_:rhoUz_,i,j,k,iGang) = &
               SourceMhd_VCI(rhoUx_:rhoUz_,i,j,k,iGang) &
               + CurlB0CrossB_D
          ! Energy equation source term is u.(curl(B0)xB)
          Source_VCI(Energy_,i,j,k,iGang) = Source_VCI(Energy_,i,j,k,iGang) &
               + sum(CurlB0CrossB_D*State_VGB(rhoUx_:rhoUz_,i,j,k,iBlock))&
               /State_VGB(rho_,i,j,k,iBlock)
       end do; end do; end do

       if(DoTest .and. &
            (iVarTest==Energy_.or.iVarTest>=RhoUx_.and.iVarTest<=RhoUz_))&
            call write_source('After curl B0')
    end if

    if(UseB .and. UseBorisCorrection &
         .and. ClightFactor < 0.9999 &
         .and. index(StringTest,'nodivE')<1)then
       call add_boris_source(iBlock)
       if(DoTest.and.iVarTest>=RhoUx_.and.iVarTest<=RhoUz_) &
            call write_source('After E div E')
    end if
#endif

    if(IsMhd) then
       !$acc loop vector collapse(4)
       do k = 1, nK; do j = 1, nJ; do i = 1, nI; do iVar = RhoUx_, RhoUz_
          Source_VCI(iVar,i,j,k,iGang) = &
               Source_VCI(iVar,i,j,k,iGang) + SourceMhd_VCI(iVar,i,j,k,iGang)
       end do; end do; end do; end do
    endif

#ifndef OPENACC
    ! The electric field in the comoving frame is needed
    if(UseMhdMomentumFlux)&
         call get_efield_in_comoving_frame(iBlock)

    ! These source terms apply to all the fluids
    do iFluid = 1, nFluid
       if(nFluid > 1) call select_fluid(iFluid)
       if(UseGravity)then
          ! Add gravitational force
          if(GravityDir == 0)then
             ! Force is toward the body at the origin
             do k = 1, nK; do j = 1, nJ; do i = 1, nI
                if(.not.true_cell(i,j,k,iBlock)) CYCLE
                ForcePerRho_D = &
                     Gbody*Xyz_DGB(:,i,j,k,iBlock)/r_BLK(i,j,k,iBlock)**3
                Source_VCI(iRhoUx:iRhoUz,i,j,k,iGang) =Source_VCI(iRhoUx:iRhoUz,i,j,k,iGang)&
                     + State_VGB(iRho,i,j,k,iBlock)*ForcePerRho_D
                Source_VCI(iEnergy,i,j,k,iGang) = Source_VCI(iEnergy,i,j,k,iGang) + &
                     sum(State_VGB(iRhoUx:iRhoUz,i,j,k,iBlock)*ForcePerRho_D)
             end do; end do; end do

             if(UseBody2)then
                do k=1,nK; do j=1,nJ; do i=1,nI
                   if(.not.true_cell(i,j,k,iBlock)) CYCLE
                   ForcePerRho_D = Gbody2 &
                        * (Xyz_DGB(:,i,j,k,iBlock)-[xBody2,yBody2,zBody2]) &
                        / r2_BLK(i,j,k,iBlock)**3
                   Source_VCI(iRhoUx:iRhoUz,i,j,k,iGang) = &
                        Source_VCI(iRhoUx:iRhoUz,i,j,k,iGang) &
                        + State_VGB(iRho,i,j,k,iBlock)*ForcePerRho_D
                   Source_VCI(iEnergy,i,j,k,iGang) = Source_VCI(iEnergy,i,j,k,iGang) + &
                        sum(State_VGB(iRhoUx:iRhoUz,i,j,k,iBlock) &
                        *   ForcePerRho_D)
                end do; end do; end do
             end if
          else
             iRhoUGrav = iRhoUx - 1 + GravityDir
             do k=1,nK; do j=1,nJ; do i=1,nI
                if(.not.true_cell(i,j,k,iBlock)) CYCLE
                Source_VCI(iRhoUGrav,i,j,k,iGang) = Source_VCI(iRhoUGrav,i,j,k,iGang) &
                     + Gbody*State_VGB(iRho,i,j,k,iBlock)
                Source_VCI(iEnergy,i,j,k,iGang) = Source_VCI(iEnergy,i,j,k,iGang) &
                     + Gbody*State_VGB(iRhoUGrav,i,j,k,iBlock)
             end do; end do; end do
          end if
          if(DoTest.and. &
               (iVarTest==Energy_ .or. iVarTest>=iRhoUx.and.iVarTest<=iRhoUz))then
             call write_source('After gravity')
          end if
       end if

       ! Add Coriolis forces
       if(UseRotatingFrame)then
          ! Add centrifugal and Coriolis forces
          select case(TypeCoordSystem)
          case('HGC','HGR','GEO')
             ! This is a special case since Omega is parallel with the Z axis
             Omega2 = OmegaBody**2
             do k = 1, nK; do j = 1, nJ; do i = 1, nI
                if(.not.true_cell(i,j,k,iBlock)) CYCLE
                Source_VCI(iRhoUx,i,j,k,iGang) = Source_VCI(iRhoUx,i,j,k,iGang) &
                     + 2*OmegaBody*State_VGB(iRhoUy,i,j,k,iBlock) &
                     + State_VGB(iRho,i,j,k,iBlock) &
                     *Omega2 * Xyz_DGB(x_,i,j,k,iBlock)

                Source_VCI(iRhoUy,i,j,k,iGang) = Source_VCI(iRhoUy,i,j,k,iGang) &
                     - 2*OmegaBody*State_VGB(iRhoUx,i,j,k,iBlock) &
                     + State_VGB(iRho,i,j,k,iBlock) &
                     *Omega2 * Xyz_DGB(y_,i,j,k,iBlock)

                Source_VCI(iEnergy,i,j,k,iGang) = Source_VCI(iEnergy,i,j,k,iGang) &
                     + Omega2 * sum(State_VGB(iRhoUx:iRhoUy,i,j,k,iBlock) &
                     *                         Xyz_DGB(x_:y_,i,j,k,iBlock))
             end do; end do; end do
          case default
             call stop_mpi(NameSub // &
                  ' Inertial forces are not implemented for'// &
                  ' TypeCoordSystem='//TypeCoordSystem)
          end select
          if(DoTest.and.iVarTest>=iRhoUx .and. iVarTest<=iRhoUy) &
               call write_source('After Coriolis')
       end if
    end do

    if(UseMultiIon)then
       ! Add momentum source terms containing the gradient of electron pressure
       call multi_ion_source_expl(iBlock)

       if(DoTest) call write_source('After MultiIon sources explicit')

       ! Add stiff momentum source terms (uPlus - Uion) and artificial friction
       ! Explicit evaluation of these source terms is for code development only
       if(.not.UsePointImplicit) call multi_ion_source_impl(iBlock)
    end if

    if(UseEfield)then
       ! Add total charge density source term for HypE scalar: c/eps0 = c^3
       do k = 1, nK; do j = 1, nJ; do i = 1, nI
          if(.not.true_cell(i,j,k,iBlock)) CYCLE
          Source_VCI(HypE_,i,j,k,iGang) = Clight*C2light * &
               sum(State_VGB(iRhoIon_I,i,j,k,iBlock)*ChargePerMass_I)
       end do; end do; end do
    end if

    if(UseEfield .and. .not.UsePointImplicit)then
       ! Explicit evaluation of these source terms is for code development only
       call ion_electron_source_impl(iBlock)
       if(DoTest) call write_source('After IonElectron sources implicit')
    end if

    if(UseB .and. .not.IsMhd .and. .not.(UseMultiIon .or. UseEfield))then
       ! Add JxB term for nonconservative MHD scheme (like LFM)
       call multi_ion_source_expl(iBlock)

       if(DoTest) call write_source('After JxB term')
    end if

    if(UseRadDiffusion .and. UseFullImplicit) &
         call calc_source_rad_diffusion(iBlock)

    if(SignB_>1 .and. DoThinCurrentSheet)then
       do k=1,nK; do j=1,nJ; do i=1,nI
          if(.not.true_cell(i,j,k,iBlock)) CYCLE

          ! Note that the velocity of the first (and only) fluid is used
          DivU            =        uDotArea_XII(i+1,j,k,1,iGang) -uDotArea_XII(i,j,k,1,iGang)
          if(nJ > 1) DivU = DivU + uDotArea_YII(i,j+1,k,1,iGang) -uDotArea_YII(i,j,k,1,iGang)
          if(nK > 1) DivU = DivU + uDotArea_ZII(i,j,k+1,1,iGang) -uDotArea_ZII(i,j,k,1,iGang)
          DivU = DivU/CellVolume_GB(i,j,k,iBlock)

          Source_VCI(SignB_,i,j,k,iGang) = Source_VCI(SignB_,i,j,k,iGang) &
               + State_VGB(SignB_,i,j,k,iBlock)*DivU
       end do; end do; end do
    end if

    if(UseUserSourceExpl)then
       call user_calc_sources_expl(iBlock)
       if(DoTest) call write_source('After explicit user sources')
    end if

    if(.not.UsePointImplicit .and. UseUserSourceImpl)then
       call user_calc_sources_impl(iBlock)
       if(DoTest) call write_source( &
            'After implicit user source evaluated explicitly')
    end if

    if(DoTest) call write_source('final')
#endif

    call test_stop(NameSub, DoTest, iBlock)
  contains
    !==========================================================================
    subroutine calc_grad_u(GradU_DD, i, j, k, iBlock)

      use BATL_lib, ONLY: FaceNormal_DDFB, CellVolume_GB, Dim1_, Dim2_, Dim3_

      integer, intent(in) :: i, j, k, iBlock
      real,   intent(out) :: GradU_DD(nDim,MaxDim)

      integer :: iDir

      character(len=*), parameter:: NameSub = 'calc_grad_u'
      !------------------------------------------------------------------------
      GradU_DD = 0.0

      if (DoTestCell) then
         write(*,*) 'iFluid =', iFluid
         write(*,*) 'ux_D =', LeftState_VXI(iUx:iUz,i+1,j,  k,iGang)
         write(*,*) 'ux_D =', LeftState_VXI(iUx:iUz,i,  j,  k,iGang)
         write(*,*) 'uy_D =', LeftState_VYI(iUx:iUz,i,  j+1,k,iGang)
         write(*,*) 'uy_D =', LeftState_VYI(iUx:iUz,i,  j,  k,iGang)
         write(*,*) 'uz_D =', LeftState_VZI(iUx:iUz,i,  j,  k+1,iGang)
         write(*,*) 'uz_D =', LeftState_VZI(iUx:iUz,i,  j,  k,iGang)
      end if

      ! Calculate gradient tensor of velocity
      if(IsCartesian) then
         GradU_DD(Dim1_,:) = &
              ( LeftState_VXI(iUx:iUz,i+1,j,k,iGang)   &
              + RightState_VXI(iUx:iUz,i+1,j,k,iGang)  &
              - LeftState_VXI(iUx:iUz,i,j,k,iGang)     &
              - RightState_VXI(iUx:iUz,i,j,k,iGang) )  &
              /(2*CellSize_DB(Dim1_,iBlock))

         if(nJ > 1) GradU_DD(Dim2_,:) = &
              ( LeftState_VYI(iUx:iUz,i,j+1,k,iGang)   &
              + RightState_VYI(iUx:iUz,i,j+1,k,iGang)  &
              - LeftState_VYI(iUx:iUz,i,j,k,iGang)     &
              - RightState_VYI(iUx:iUz,i,j,k,iGang) )  &
              /(2*CellSize_DB(Dim2_,iBlock))

         if(nK > 1) GradU_DD(Dim3_,:) = &
              ( LeftState_VZI(iUx:iUz,i,j,k+1,iGang)   &
              + RightState_VZI(iUx:iUz,i,j,k+1,iGang)  &
              - LeftState_VZI(iUx:iUz,i,j,k,iGang)     &
              - RightState_VZI(iUx:iUz,i,j,k,iGang) )  &
              /(2*CellSize_DB(Dim3_,iBlock))

      else if(IsRzGeometry) then
         call stop_mpi(NameSub//': RZ geometry to be implemented')
      else
         do iDir = 1, MaxDim
            iVar = iUx - 1 + iDir

            GradU_DD(:,iDir) = &
                 0.5*(LeftState_VXI(iVar,i+1,j,k,iGang) &
                 + RightState_VXI(iVar,i+1,j,k,iGang))* &
                 FaceNormal_DDFB(:,1,i+1,j,k,iBlock) &
                 - 0.5*(LeftState_VXI(iVar,i,j,k,iGang) &
                 + RightState_VXI(iVar,i,j,k,iGang))* &
                 FaceNormal_DDFB(:,1,i,j,k,iBlock)

            if(nJ == 1) CYCLE

            GradU_DD(:,iDir) = GradU_DD(:,iDir) + &
                 0.5*(LeftState_VYI(iVar,i,j+1,k,iGang) &
                 + RightState_VYI(iVar,i,j+1,k,iGang))* &
                 FaceNormal_DDFB(:,2,i,j+1,k,iBlock) &
                 - 0.5*(LeftState_VYI(iVar,i,j,k,iGang) &
                 + RightState_VYI(iVar,i,j,k,iGang))* &
                 FaceNormal_DDFB(:,2,i,j,k,iBlock)

            if(nK == 1) CYCLE

            GradU_DD(:,iDir) = GradU_DD(:,iDir) + &
                 0.5*(LeftState_VZI(iVar,i,j,k+1,iGang) &
                 + RightState_VZI(iVar,i,j,k+1,iGang))* &
                 FaceNormal_DDFB(:,3,i,j,k+1,iBlock) &
                 - 0.5*(LeftState_VZI(iVar,i,j,k,iGang) &
                 + RightState_VZI(iVar,i,j,k,iGang))* &
                 FaceNormal_DDFB(:,3,i,j,k,iBlock)
         end do

         GradU_DD = GradU_DD / CellVolume_GB(i,j,k,iBlock)

      end if

    end subroutine calc_grad_u
    !==========================================================================
    subroutine calc_grad_uPlus(GradU_DD, i, j, k, iBlock)

      ! This routine calculates the gradient tensor of uPlus_D, which is used
      ! in anisotropic Pe.

      use BATL_lib, ONLY: Dim1_, Dim2_, Dim3_

      integer, intent(in) :: i, j, k, iBlock
      real,   intent(out) :: GradU_DD(nDim,MaxDim)

      ! uPlus_D on the left and right faces
      real :: uPlusLeft_D(3),  uPlusRight_D(3)
      real :: uPlusLeft1_D(3), uPlusRight1_D(3)

      character(len=*), parameter:: NameSub = 'calc_grad_uPlus'
      !------------------------------------------------------------------------
      GradU_DD = 0.0

      ! Obtain the uPlus_D on the corresponding faces
      call get_uPlus(LeftState_VXI( :,i+1,j,k,iGang), uPlusLeft1_D )
      call get_uPlus(LeftState_VXI( :,i,  j,k,iGang), uPlusLeft_D  )
      call get_uPlus(RightState_VXI(:,i+1,j,k,iGang), uPlusRight1_D)
      call get_uPlus(RightState_VXI(:,i,  j,k,iGang), uPlusRight_D )

      ! Calculate gradient tensor of u_plus
      if(IsCartesian) then
         GradU_DD(Dim1_,:) = &
              (uPlusLeft1_D + uPlusRight1_D - uPlusLeft_D - uPlusRight_D)  &
              /(2*CellSize_DB(Dim1_,iBlock))

         if(nJ > 1) then
            ! Obtain the uPlus_D on the corresponding faces
            call get_uPlus(LeftState_VYI( :,i,j+1,k,iGang), uPlusLeft1_D )
            call get_uPlus(LeftState_VYI( :,i,j,  k,iGang), uPlusLeft_D  )
            call get_uPlus(RightState_VYI(:,i,j+1,k,iGang), uPlusRight1_D)
            call get_uPlus(RightState_VYI(:,i,j,  k,iGang), uPlusRight_D )

            GradU_DD(Dim2_,:) = &
                 (uPlusLeft1_D + uPlusRight1_D - uPlusLeft_D - uPlusRight_D) &
                 /(2*CellSize_DB(Dim1_,iBlock))
         end if

         if(nK > 1) then
            ! Obtain the uPlus_D on the corresponding faces
            call get_uPlus(LeftState_VZI( :,i,j,k+1,iGang), uPlusLeft1_D )
            call get_uPlus(LeftState_VZI( :,i,j,k,  1), uPlusLeft_D  )
            call get_uPlus(RightState_VZI(:,i,j,k+1,iGang), uPlusRight1_D)
            call get_uPlus(RightState_VZI(:,i,j,k,  1), uPlusRight_D )

            GradU_DD(Dim3_,:) = &
                 (uPlusLeft1_D + uPlusRight1_D - uPlusLeft_D - uPlusRight_D) &
                 /(2*CellSize_DB(Dim1_,iBlock))
         end if

      else if(IsRzGeometry) then
         call stop_mpi(NameSub//': RZ geometry to be implemented')
      else
         call stop_mpi(NameSub//': spherical to be implemented')
      end if

    end subroutine calc_grad_uPlus
    !==========================================================================
    subroutine get_uPlus(StateIn_V, uPlus_D)

      ! This subroutine gets the uPlus_D at the corresponding face
      ! using the face state values StateIn_V

      use ModMultiFluid, ONLY: ChargeIon_I, MassIon_I, nIonFluid

      real,    intent(in)  :: StateIn_V(nVar)
      real,    intent(out) :: uPlus_D(3)

      real :: ChargeDens_I(nIonFluid)

      !------------------------------------------------------------------------

      ChargeDens_I    = ChargeIon_I*StateIn_V(iRhoIon_I)/MassIon_I
      InvElectronDens = 1.0/sum(ChargeDens_I)

      uPlus_D(x_) = InvElectronDens*sum( ChargeDens_I*StateIn_V(iUxIon_I) )
      uPlus_D(y_) = InvElectronDens*sum( ChargeDens_I*StateIn_V(iUyIon_I) )
      uPlus_D(z_) = InvElectronDens*sum( ChargeDens_I*StateIn_V(iUzIon_I) )

      if (DoTestCell) write(*,*) 'uPlus_D =', uPlus_D

    end subroutine get_uPlus
    !==========================================================================
    subroutine calc_divb_source(iBlock)
      !$acc  routine vector
      integer, intent(in):: iBlock

      integer::  i, j, k
      integer:: iGang

      ! Variables needed for div B source terms
      real:: DxInvHalf, DyInvHalf, DzInvHalf, DivBInternal_C(1:nI,1:nJ,1:nK)
      real:: dB1nFace1, dB1nFace2, dB1nFace3, dB1nFace4, dB1nFace5, dB1nFace6

      real:: BCorrect0, BCorrect1
      !------------------------------------------------------------------------
      iGang = 1
      DxInvHalf = 0.5/CellSize_DB(x_,iBlock)
      DyInvHalf = 0.5/CellSize_DB(y_,iBlock)
      DzInvHalf = 0.5/CellSize_DB(z_,iBlock)

      !$acc loop vector collapse(3)
      do k = 1, nK; do j = 1, nJ; do i = 1, nI
         if(.not.true_cell(i,j,k,iBlock)) CYCLE

#ifdef OPENACC
         iGang = iBlock
         DxInvHalf = 0.5/CellSize_DB(x_,iBlock)
         DyInvHalf = 0.5/CellSize_DB(y_,iBlock)
         DzInvHalf = 0.5/CellSize_DB(z_,iBlock)
#endif
         if((UseMhdMomentumFlux.and.UseB0) .or. (.not.DoCorrectFace)) then

            dB1nFace1 = DxInvHalf*&
                 (RightState_VXI(Bx_,i,j,k,iGang)-LeftState_VXI(Bx_,i,j,k,iGang))

            dB1nFace2 = DxInvHalf*&
                 (RightState_VXI(Bx_,i+1,j,k,iGang)-LeftState_VXI(Bx_,i+1,j,k,iGang))

            if(nJ > 1)then
               dB1nFace3 = DyInvHalf* &
                    (RightState_VYI(By_,i,j,k,iGang)-LeftState_VYI(By_,i,j,k,iGang))

               dB1nFace4 = DyInvHalf* &
                    (RightState_VYI(By_,i,j+1,k,iGang)-LeftState_VYI(By_,i,j+1,k,iGang))
            end if

            if(nK > 1)then
               dB1nFace5 = DzInvHalf * &
                    (RightState_VZI(Bz_,i,j,k,iGang)-LeftState_VZI(Bz_,i,j,k,iGang))

               dB1nFace6 = DzInvHalf * &
                    (RightState_VZI(Bz_,i,j,k+1,iGang)-LeftState_VZI(Bz_,i,j,k+1,iGang))
            end if

            DivBInternal_C(i,j,k) = &
                 2*DxInvHalf*(LeftState_VXI(Bx_,i+1,j,k,iGang) -RightState_VXI(Bx_,i,j,k,iGang))

            if(nJ > 1) DivBInternal_C(i,j,k) = DivBInternal_C(i,j,k) + &
                 2*DyInvHalf*(LeftState_VYI(By_,i,j+1,k,iGang) -RightState_VYI(By_,i,j,k,iGang))

            if(nK > 1) DivBInternal_C(i,j,k) = DivBInternal_C(i,j,k) + &
                 2*DzInvHalf*(LeftState_VZI(Bz_,i,j,k+1,iGang) -RightState_VZI(Bz_,i,j,k,iGang))

            ! Momentum source term from B0 only needed for div(B^2/2 - BB)
            ! discretization
            if(UseMhdMomentumFlux.and.UseB0) then
               SourceMhd_VCI(RhoUx_:RhoUz_,i,j,k,iGang) = &
                    SourceMhd_VCI(RhoUx_:RhoUz_,i,j,k,iGang) &
                    -B0_DX(:,i,j,k)*dB1nFace1    &
                    -B0_DX(:,i+1,j,k)*dB1nFace2

               if(nJ > 1) &
                    SourceMhd_VCI(RhoUx_:RhoUz_,i,j,k,iGang) = &
                    SourceMhd_VCI(RhoUx_:RhoUz_,i,j,k,iGang) &
                    -B0_DY(:,i,j,k)*dB1nFace3   &
                    -B0_DY(:,i,j+1,k)*dB1nFace4

               if(nK > 1) &
                    SourceMhd_VCI(RhoUx_:RhoUz_,i,j,k,iGang) = &
                    SourceMhd_VCI(RhoUx_:RhoUz_,i,j,k,iGang) &
                    -B0_DZ(:,i,j,k)*dB1nFace5     &
                    -B0_DZ(:,i,j,k+1)*dB1nFace6
            endif
         endif

         if(DoCorrectFace) then
            ! Correct the face value so that the first order derivate is
            ! high-order accurate.
            BCorrect0 = correct_face_value( &
                 0.5*(RightState_VXI(Bx_,i,j,k,iGang) + LeftState_VXI(Bx_,i,j,k,iGang)), &
                 State_VGB(Bx_,i-2:i+1,j,k,iBlock))

            BCorrect1 = correct_face_value( &
                 0.5*(LeftState_VXI(Bx_,i+1,j,k,iGang) + RightState_VXI(Bx_,i+1,j,k,iGang)), &
                 State_VGB(Bx_,i-1:i+2,j,k,iBlock))

            DivB1_GB(i,j,k,iBlock) = 2*DxInvHalf*(BCorrect1 - BCorrect0)

            if(nJ>1) then
               BCorrect0 = correct_face_value( &
                    0.5*(RightState_VYI(By_,i,j,k,iGang) + LeftState_VYI(By_,i,j,k,iGang)), &
                    State_VGB(By_,i,j-2:j+1,k,iBlock))

               BCorrect1 = correct_face_value( &
                    0.5*(LeftState_VYI(By_,i,j+1,k,iGang)+RightState_VYI(By_,i,j+1,k,iGang)),&
                    State_VGB(By_,i,j-1:j+2,k,iBlock))

               DivB1_GB(i,j,k,iBlock) = DivB1_GB(i,j,k,iBlock) + &
                    2*DyInvHalf*(BCorrect1 - BCorrect0)
            endif

            if(nK>1) then
               BCorrect0 = correct_face_value( &
                    0.5*(RightState_VZI(Bz_,i,j,k,iGang) + LeftState_VZI(Bz_,i,j,k,iGang)), &
                    State_VGB(Bz_,i,j,k-2:k+1,iBlock))

               BCorrect1 = correct_face_value( &
                    0.5*(LeftState_VZI(Bz_,i,j,k+1,iGang)+RightState_VZI(Bz_,i,j,k+1,iGang)),&
                    State_VGB(Bz_,i,j,k-1:k+2,iBlock))

               DivB1_GB(i,j,k,iBlock) = DivB1_GB(i,j,k,iBlock) + &
                    2*DzInvHalf*(BCorrect1 - BCorrect0)
            endif
         else
            DivB1_GB(i,j,k,iBlock)  = DivBInternal_C(i,j,k) &
                 + dB1nFace1 + dB1nFace2

            if(nJ > 1) DivB1_GB(i,j,k,iBlock) = DivB1_GB(i,j,k,iBlock) &
                 + dB1nFace3 + dB1nFace4

            if(nK > 1) DivB1_GB(i,j,k,iBlock) = DivB1_GB(i,j,k,iBlock) &
                 + dB1nFace5 + dB1nFace6
         endif

      end do; end do; end do

      ! Momentum source term from B0 only needed for true MHD equations
      if(.not.(UseMhdMomentumFlux .and. UseB0)) RETURN

      do k = 1, nK; do j = 1, nJ; do i = 1, nI
         if(.not.true_cell(i,j,k,iBlock)) CYCLE
         SourceMhd_VCI(RhoUx_:RhoUz_,i,j,k,iGang) = &
              SourceMhd_VCI(RhoUx_:RhoUz_,i,j,k,iGang) &
              - DivBInternal_C(i,j,k)*B0_DGB(:,i,j,k,iBlock)
      end do; end do; end do

    end subroutine calc_divb_source
    !==========================================================================
    subroutine calc_divb_source_gencoord

      use BATL_lib, ONLY: FaceNormal_DDFB

      real :: FaceArea_D(nDim), vInvHalf
      real :: B1nJumpL, B1nJumpR, DivBInternal_C(1:nI,1:nJ,1:nK)
      integer :: i, j, k

      character(len=*), parameter:: NameSub = 'calc_divb_source_gencoord'
      !------------------------------------------------------------------------
      do k = 1, nK; do j = 1, nJ; do i = 1, nI
         if(.not.true_cell(i,j,k,iBlock)) CYCLE

         VInvHalf = 0.5/CellVolume_GB(i,j,k,iBlock)
         FaceArea_D = FaceNormal_DDFB(:,1,i,j,k,iBlock)
         B1nJumpL =VInvHalf*&
              sum(FaceArea_D*(RightState_VXI(Bx_:B_+nDim,i,j,k,iGang) &
              -               LeftState_VXI(Bx_:B_+nDim,i,j,k,iGang)))
         DivBInternal_C(i,j,k) = &
              -sum(FaceArea_D*RightState_VXI(Bx_:B_+nDim,i,j,k,iGang))

         FaceArea_D = FaceNormal_DDFB(:,1,i+1,j,k,iBlock)
         B1nJumpR =  VInvHalf*&
              sum(FaceArea_D*(RightState_VXI(Bx_:B_+nDim,i+1,j,k,iGang) &
              -               LeftState_VXI(Bx_:B_+nDim,i+1,j,k,iGang)))

         DivBInternal_C(i,j,k) = DivBInternal_C(i,j,k) &
              + sum(FaceArea_D*LeftState_VXI(Bx_:B_+nDim,i+1,j,k,iGang))

         DivB1_GB(i,j,k,iBlock)  = B1nJumpL + B1nJumpR

         if(.not.(UseMhdMomentumFlux .and. UseB0)) CYCLE

         SourceMhd_VCI(RhoUx_:RhoUz_,i,j,k,iGang) = SourceMhd_VCI(RhoUx_:RhoUz_,i,j,k,iGang)&
              - B0_DX(:,i,j,k)*B1nJumpL   &
              - B0_DX(:,i+1,j,k)*B1nJumpR

      end do; end do; end do

      if(DoTest)write(*,*)NameSub,' after i divbint, divb1=', &
           DivBInternal_C(iTest,jTest,kTest), &
           DivB1_GB(iTest,jTest,kTest,iBlockTest)

      do k = 1, nK; do j = 1, nJ; do i = 1, nI
         if(.not.true_cell(i,j,k,iBlock)) CYCLE

         VInvHalf = 0.5/CellVolume_GB(i,j,k,iBlock)
         FaceArea_D = FaceNormal_DDFB(:,2,i,j,k,iBlock)
         B1nJumpL = VInvHalf*&
              sum(FaceArea_D*(RightState_VYI(Bx_:B_+nDim,i,j,k,iGang) &
              -               LeftState_VYI(Bx_:B_+nDim,i,j,k,iGang)))
         DivBInternal_C(i,j,k) = DivBInternal_C(i,j,k) &
              - sum(FaceArea_D*RightState_VYI(Bx_:B_+nDim,i,j,k,iGang))

         FaceArea_D =  FaceNormal_DDFB(:,2,i,j+1,k,iBlock)
         B1nJumpR = VInvHalf*&
              sum(FaceArea_D*(RightState_VYI(Bx_:B_+nDim,i,j+1,k,iGang) &
              -               LeftState_VYI(Bx_:B_+nDim,i,j+1,k,iGang)))

         DivBInternal_C(i,j,k) = DivBInternal_C(i,j,k) &
              + sum(FaceArea_D*LeftState_VYI(Bx_:B_+nDim,i,j+1,k,iGang))

         DivB1_GB(i,j,k,iBlock)  = DivB1_GB(i,j,k,iBlock) &
              + B1nJumpL + B1nJumpR

         if(.not.(UseMhdMomentumFlux .and. UseB0)) CYCLE

         SourceMhd_VCI(RhoUx_:RhoUz_,i,j,k,iGang) = SourceMhd_VCI(RhoUx_:RhoUz_,i,j,k,iGang)&
              -B0_DY(:,i,j,k)*B1nJumpL &
              -B0_DY(:,i,j+1,k)*B1nJumpR

      end do; end do; end do

      if(DoTest)write(*,*)NameSub,' after j divbint, divb1=', &
           DivBInternal_C(iTest,jTest,kTest), &
           DivB1_GB(iTest,jTest,kTest,iBlockTest)

      if(nK > 1)then
         do k = 1, nK; do j = 1, nJ; do i = 1, nI
            if(.not.true_cell(i,j,k,iBlock)) CYCLE

            VInvHalf = 0.5/CellVolume_GB(i,j,k,iBlock)
            FaceArea_D = FaceNormal_DDFB(:,3,i,j,k,iBlock)
            B1nJumpL = VInvHalf*&
                 sum(FaceArea_D*(RightState_VZI(Bx_:B_+nDim,i,j,k,iGang) &
                 -                LeftState_VZI(Bx_:B_+nDim,i,j,k,iGang)))

            DivBInternal_C(i,j,k) = DivBInternal_C(i,j,k) &
                 - sum(FaceArea_D*RightState_VZI(Bx_:B_+nDim,i,j,k,iGang))

            FaceArea_D = FaceNormal_DDFB(:,3,i,j,k+1,iBlock)
            B1nJumpR = VInvHalf*&
                 sum(FaceArea_D*(RightState_VZI(Bx_:B_+nDim,i,j,k+1,iGang) &
                 -               LeftState_VZI(Bx_:B_+nDim,i,j,k+1,iGang)))

            DivBInternal_C(i,j,k) = (DivBInternal_C(i,j,k) + &
                 sum(FaceArea_D*LeftState_VZI(Bx_:B_+nDim,i,j,k+1,iGang))) &
                 /CellVolume_GB(i,j,k,iBlock)

            DivB1_GB(i,j,k,iBlock)  = DivB1_GB(i,j,k,iBlock) &
                 + B1nJumpL + B1nJumpR

            if(.not.(UseMhdMomentumFlux .and. UseB0)) CYCLE

            SourceMhd_VCI(RhoUx_:RhoUz_,i,j,k,iGang) = &
                 SourceMhd_VCI(RhoUx_:RhoUz_,i,j,k,iGang)&
                 -B0_DZ(:,i,j,k)*B1nJumpL &
                 -B0_DZ(:,i,j,k+1)*B1nJumpR
         end do; end do; end do
      end if

      if(DoTest)write(*,*)NameSub,' after k divbint, divb1=', &
           DivBInternal_C(iTest,jTest,kTest), &
           DivB1_GB(iTest,jTest,kTest,iBlockTest)

      do k = 1, nK; do j = 1, nJ; do i = 1, nI
         if(.not.true_cell(i,j,k,iBlock)) CYCLE
         DivB1_GB(i,j,k,iBlock) = DivB1_GB(i,j,k,iBlock) +DivBInternal_C(i,j,k)
      end do; end do; end do

      if(DoTest)write(*,*)NameSub,' final divb1=', &
           DivB1_GB(iTest,jTest,kTest,iBlockTest)

      if(.not.(UseMhdMomentumFlux .and. UseB0)) RETURN

      do k = 1, nK; do j = 1, nJ; do i = 1, nI
         if(.not.true_cell(i,j,k,iBlock)) CYCLE
         SourceMhd_VCI(RhoUx_:RhoUz_,i,j,k,iGang) = SourceMhd_VCI(RhoUx_:RhoUz_,i,j,k,iGang)&
              - DivBInternal_C(i,j,k)*B0_DGB(:,i,j,k,iBlock)
      end do; end do; end do

    end subroutine calc_divb_source_gencoord
    !==========================================================================

    subroutine write_source(String)
      !$acc routine seq
      character(len=*), intent(in) :: String
      !------------------------------------------------------------------------
#ifndef OPENACC
      write(*,'(a,es13.5)') NameSub//": "//String//" S(iVarTest)=",&
           Source_VCI(iVarTest,iTest,jTest,kTest,iGang)
#endif
    end subroutine write_source
    !==========================================================================

  end subroutine calc_source
  !============================================================================

  subroutine calc_divb(iBlock)

    ! Calculate div B for a block and store result into DivB1_GB
    ! Compute divB using averaged and conservatively corrected
    ! left and right values

    use BATL_lib,      ONLY: CellSize_DB, x_, y_, z_
    use ModMain,       ONLY: nI, nJ, nK
    use ModVarIndexes, ONLY: Bx_, By_, Bz_
    use ModAdvance,    ONLY: DivB1_GB, &
         LeftState_VXI, RightState_VXI, &
         LeftState_VYI, RightState_VYI, &
         LeftState_VZI, RightState_VZI

    integer, intent(in) :: iBlock

    integer:: i, j, k
    integer:: iGang
    real   :: DivB, InvDx, InvDy, InvDz
    logical:: DoTest
    character(len=*), parameter:: NameSub = 'calc_divb'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest, iBlock)

    iGang = 1
#ifdef OPENACC
    iGang = iBlock
#endif

    InvDx            = 1/CellSize_DB(x_,iBlock)
    if(nJ > 1) InvDy = 1/CellSize_DB(y_,iBlock)
    if(nK > 1) InvDz = 1/CellSize_DB(z_,iBlock)

    do k = 1, nK; do j = 1, nJ; do i = 1, nI
       DivB = InvDx* &
            (  LeftState_VXI(Bx_,i+1,j,k,iGang)  &
            + RightState_VXI(Bx_,i+1,j,k,iGang)  &
            -  LeftState_VXI(Bx_,i,j,k,iGang)    &
            - RightState_VXI(Bx_,i,j,k,iGang) )

       if(nJ > 1) DivB = DivB + InvDy* &
            (  LeftState_VYI(By_,i,j+1,k,iGang)   &
            + RightState_VYI(By_,i,j+1,k,iGang)   &
            -  LeftState_VYI(By_,i,j,k,iGang)     &
            - RightState_VYI(By_,i,j,k,iGang) )

       if(nK > 1) DivB = DivB + InvDz* &
            (  LeftState_VZI(Bz_,i,j,k+1,iGang)    &
            + RightState_VZI(Bz_,i,j,k+1,iGang)    &
            -  LeftState_VZI(Bz_,i,j,k,iGang)      &
            - RightState_VZI(Bz_,i,j,k,iGang) )

       DivB1_GB(i,j,k,iBlock) = 0.5*DivB

    end do; end do; end do

    call test_stop(NameSub, DoTest, iBlock)
  end subroutine calc_divb
  !============================================================================

end module ModCalcSource
!==============================================================================
