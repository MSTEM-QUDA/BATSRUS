!  Copyright (C) 2002 Regents of the University of Michigan,
!  portions used with permission
!  For more information, see http://csem.engin.umich.edu/tools/swmf
module ModEnergy

  use BATL_lib, ONLY: &
       test_start, test_stop, iTest, jTest, kTest, iBlockTest
  use ModExtraVariables, ONLY: Pepar_
  use ModVarIndexes, ONLY: nVar, Rho_, RhoUx_, RhoUy_, RhoUz_, Bx_, By_, Bz_, &
       Hyp_, p_, Pe_, IsMhd
  use ModMultiFluid, ONLY: nFluid, IonLast_, &
       iRho, iRhoUx, iRhoUy, iRhoUz, iP, iP_I, &
       UseNeutralFluid, DoConserveNeutrals, &
       select_fluid, MassFluid_I, iRho_I, iRhoIon_I, MassIon_I, ChargeIon_I
  use ModAdvance,    ONLY: State_VGB, StateOld_VGB, UseElectronPressure, &
       UseElectronEnergy
  use ModConservative, ONLY: UseNonConservative, nConservCrit, IsConserv_CB
  use ModPhysics, ONLY: &
       GammaMinus1_I, InvGammaMinus1_I, InvGammaMinus1, GammaElectronMinus1, &
       InvGammaElectronMinus1, pMin_I, PeMin, Tmin_I, TeMin
  use BATL_lib, ONLY: nI, nJ, nK, MinI, MaxI, MinJ, MaxJ, MinK, MaxK, &
       MaxBlock, Used_GB
  use ModChGL,     ONLY: UseChGL, rMinChGL
  use ModGeometry, ONLY: r_GB
  implicit none

  private ! except

  public:: energy_to_pressure       ! e -> p conditionally for explicit
  public:: energy_to_pressure_cell  ! e -> p in physical cells for implicit
  public:: pressure_to_energy       ! p -> e conditionally for explicit
  public:: pressure_to_energy_block ! p -> e in a block for part implicit
  public:: energy_i                 ! energy of fluid iFluid from State_V
  public:: get_fluid_energy_block   ! energy of fluid in a grid block
  public:: limit_pressure           ! Enforce minimum pressure and temperature

  ! It is possible to add the hyperbolic scalar energy to the total energy
  ! (Tricco & Price 2012, J. Comput. Phys. 231, 7214).
  ! Experiments so far do not show any benefit, but the code is preserved.
  logical, parameter:: UseHypEnergy = .false.

contains
  !============================================================================
  subroutine pressure_to_energy(iBlock, State_VGB)
    ! Calculate energy from pressure depending on
    ! the value of UseNonConservative and IsConserv_CB

    integer, intent(in):: iBlock
    real, intent(inout):: &
         State_VGB(nVar,MinI:MaxI,MinJ:MaxJ,MinK:MaxK,MaxBlock)

    integer:: i,j,k,iFluid
    logical:: DoTest
    character(len=*), parameter:: NameSub = 'pressure_to_energy'
    !--------------------------------------------------------------------------
#ifndef SCALAR
    ! Make sure pressure is larger than floor value
    ! write(*,*) NameSub,' !!! call limit_pressure'
    call limit_pressure(1, nI, 1, nJ, 1, nK, iBlock, 1, nFluid)

    ! Fully non-conservative scheme
    if(UseNonConservative .and. nConservCrit <= 0 .and. &
         .not. (UseNeutralFluid .and. DoConserveNeutrals)) RETURN

    call test_start(NameSub, DoTest, iBlock)

    if(DoTest)write(*,*)NameSub, &
         ': UseNonConservative, DoConserveNeutrals, nConservCrit=', &
         UseNonConservative, DoConserveNeutrals, nConservCrit

    ! A mix of conservative and non-conservative scheme (at least for the ions)
    FLUIDLOOP: do iFluid = 1, nFluid

       ! If all neutrals are non-conservative exit from the loop
       if(iFluid > IonLast_ .and. .not. DoConserveNeutrals) EXIT FLUIDLOOP

       if(nFluid > 1) call select_fluid(iFluid)

       do k = 1, nK; do j = 1, nJ; do i = 1, nI
          if(.not.Used_GB(i,j,k,iBlock)) CYCLE
          if(UseNonConservative .and. iFluid <= IonLast_)then
             if(.not.IsConserv_CB(i,j,k,iBlock)) CYCLE
          end if
          ! Convert to hydro energy density
          State_VGB(iP,i,j,k,iBlock) =                             &
               InvGammaMinus1_I(iFluid)*State_VGB(iP,i,j,k,iBlock) &
               + 0.5*sum(State_VGB(iRhoUx:iRhoUz,i,j,k,iBlock)**2) &
               /State_VGB(iRho,i,j,k,iBlock)

          ! Done with all fluids except first MHD fluid
          if(iFluid > 1 .or. .not. IsMhd) CYCLE
          if(UseChGL .and. r_GB(i,j,k,iBlock) > rMinChGL)CYCLE
          ! Add magnetic energy density
          State_VGB(iP,i,j,k,iBlock) = State_VGB(iP,i,j,k,iBlock) &
               + 0.5*sum(State_VGB(Bx_:Bz_,i,j,k,iBlock)**2)

          if(UseElectronPressure .and. UseElectronEnergy) &
               State_VGB(iP,i,j,k,iBlock) = State_VGB(iP,i,j,k,iBlock) &
               + State_VGB(Pe_,i,j,k,iBlock)*InvGammaElectronMinus1

          if(Hyp_ <=1 .or. .not. UseHypEnergy) CYCLE
          ! Add hyperbolic scalar energy density (idea of Daniel Price)
          State_VGB(iP,i,j,k,iBlock) = State_VGB(iP,i,j,k,iBlock) &
               + 0.5*State_VGB(Hyp_,i,j,k,iBlock)**2

       end do; end do; end do

    end do FLUIDLOOP

    call test_stop(NameSub, DoTest, iBlock)
#endif
  end subroutine pressure_to_energy
  !============================================================================
  real function energy_i(State_V, iFluid)

    ! Return energy of fluid iFluid from State_V

    real, intent(in):: State_V(nVar)
    integer, intent(in):: iFluid
#ifndef SCALAR
    !--------------------------------------------------------------------------
    if(iFluid == 1 .and. IsMhd) then
       ! MHD energy density
       energy_i = InvGammaMinus1*State_V(p_) + 0.5* &
            ( sum(State_V(RhoUx_:RhoUz_)**2)/State_V(Rho_) &
            + sum(State_V(Bx_:Bz_)**2) )
    else
       ! Hydro energy density
       if(nFluid > 1) call select_fluid(iFluid)
       energy_i = InvGammaMinus1_I(iFluid)*State_V(iP) &
            + 0.5*sum(State_V(iRhoUx:iRhoUz)**2)/State_V(iRho)
    end if
    if(UseElectronPressure .and. UseElectronEnergy .and. iFluid == 1) &
         energy_i = energy_i + State_V(Pe_)*InvGammaElectronMinus1
#endif
  end function energy_i
  !============================================================================
  subroutine get_fluid_energy_block(iBlock, iFluid, Energy_G)

    integer, intent(in):: iBlock, iFluid
    real, intent(inout):: Energy_G(MinI:MaxI,MinJ:MaxJ,MinK:MaxK)

    ! calculate the energy of fluid iFluid in physical cells of block iBlock

    integer:: i, j, k
    !--------------------------------------------------------------------------
    if(nFluid > 1) call select_fluid(iFluid)

    do k = 1, nK; do j = 1, nJ; do i = 1, nI
       if(State_VGB(iRho,i,j,k,iBlock) <= 0.0)then
          Energy_G(i,j,k) = 0.0
       else
          Energy_G(i,j,k) = &
               InvGammaMinus1*State_VGB(iP,i,j,k,iBlock)           &
               + 0.5*sum(State_VGB(iRhoUx:iRhoUz,i,j,k,iBlock)**2) &
               /State_VGB(iRho,i,j,k,iBlock)
       end if
       ! Add magnetic energy if needed
       if(IsMhd .and. iFluid == 1                                  &
            .and..not.(UseChGL.and.r_GB(i,j,k,iBlock) > rMinChGL) &
            ) Energy_G(i,j,k) = Energy_G(i,j,k) &
            + 0.5*sum(State_VGB(Bx_:Bz_,i,j,k,iBlock)**2)
       if(UseElectronPressure .and. UseElectronEnergy .and. iFluid == 1) &
            Energy_G(i,j,k) = Energy_G(i,j,k) &
            + State_VGB(Pe_,i,j,k,iBlock)*InvGammaElectronMinus1
    end do; end do; end do

  end subroutine get_fluid_energy_block
  !============================================================================
  subroutine pressure_to_energy_block(State_VG, &
       iMin, iMax, jMin, jMax, kMin, kMax)

    ! Convert pressure to energy in all cells of State_VG
    integer, intent(in)::  iMin, iMax, jMin, jMax, kMin, kMax
    real, intent(inout):: State_VG(nVar,iMin:iMax,jMin:jMax,kMin:kMax)

    integer:: i, j, k, iFluid
    !--------------------------------------------------------------------------
#ifndef SCALAR
    do iFluid = 1, nFluid

       if(nFluid > 1) call select_fluid(iFluid)

       do k = kMin, kMax; do j = jMin, jMax; do i = iMin, iMax

          ! Convert to hydro energy density
          State_VG(iP,i,j,k) =                             &
               InvGammaMinus1_I(iFluid)*State_VG(iP,i,j,k) &
               + 0.5*sum(State_VG(iRhoUx:iRhoUz,i,j,k)**2) &
               /State_VG(iRho,i,j,k)

          ! Add magnetic energy density
          if(iFluid == 1 .and. IsMhd)&
               State_VG(iP,i,j,k) = State_VG(iP,i,j,k) &
               + 0.5*sum(State_VG(Bx_:Bz_,i,j,k)**2)

          if(UseElectronPressure .and. UseElectronEnergy .and. iFluid == 1) &
               State_VG(iP,i,j,k) = State_VG(iP,i,j,k) &
               + State_VG(Pe_,i,j,k)*InvGammaElectronMinus1
       end do; end do; end do
    end do
#endif
  end subroutine pressure_to_energy_block
  !============================================================================
  subroutine energy_to_pressure(iBlock, State_VGB, IsOld)

    ! Convert energy to pressure in State_VGB depending on
    ! the value of UseNonConservative and IsConserv_CB
    ! Do not limit pressure if IsOld is present (argument is StateOld_VGB)

    integer, intent(in):: iBlock
    real, intent(inout):: &
         State_VGB(nVar,MinI:MaxI,MinJ:MaxJ,MinK:MaxK,MaxBlock)
    logical, intent(in), optional:: IsOld

    integer:: i, j, k, iFluid
    logical:: DoTest
    character(len=*), parameter:: NameSub = 'energy_to_pressure'
    !--------------------------------------------------------------------------
#ifndef SCALAR
    ! Fully non-conservative scheme
    if(UseNonConservative .and. nConservCrit <= 0 .and. &
         .not. (UseNeutralFluid .and. DoConserveNeutrals))then

       if(.not.present(IsOld))then
          ! Make sure pressure is larger than floor value
          ! write(*,*) NameSub,' !!! call limit_pressure'
          call limit_pressure(1, nI, 1, nJ, 1, nK, iBlock, 1, nFluid)
       end if
       RETURN
    end if

    call test_start(NameSub, DoTest, iBlock)

    if(DoTest)write(*,*)NameSub, &
         ': UseNonConservative, DoConserveNeutrals, nConservCrit=', &
         UseNonConservative, DoConserveNeutrals, nConservCrit

    FLUIDLOOP: do iFluid = 1, nFluid

       ! If all neutrals are non-conservative exit from the loop
       if(iFluid > IonLast_ .and. .not. DoConserveNeutrals) EXIT FLUIDLOOP

       if(nFluid > 1) call select_fluid(iFluid)

       do k = 1, nK; do j = 1, nJ; do i = 1, nI
          if(.not.Used_GB(i,j,k,iBlock)) CYCLE
          if(UseNonConservative .and. iFluid <= IonLast_)then
             ! Apply conservative criteria for the ions
             if(.not.IsConserv_CB(i,j,k,iBlock)) CYCLE
          end if

          if(iFluid == 1 .and. IsMhd                                 &
               .and..not.(UseChGL.and.r_GB(i,j,k,iBlock) > rMinChGL) &
               ) then
             ! Deal with first MHD fluid
             ! Subtract the magnetic energy density
             State_VGB(iP,i,j,k,iBlock) = State_VGB(iP,i,j,k,iBlock) &
                  - 0.5*sum(State_VGB(Bx_:Bz_,i,j,k,iBlock)**2)

             ! Subtract hyperbolic scalar energy density (from Daniel Price)
             if(Hyp_ > 1 .and. UseHypEnergy) &
                  State_VGB(iP,i,j,k,iBlock) = State_VGB(iP,i,j,k,iBlock) &
                  - 0.5*State_VGB(Hyp_,i,j,k,iBlock)**2
          end if

          if(UseElectronPressure .and. UseElectronEnergy .and. iFluid == 1) &
               State_VGB(iP,i,j,k,iBlock) = State_VGB(iP,i,j,k,iBlock) &
               - State_VGB(Pe_,i,j,k,iBlock)*GammaElectronMinus1
          
          ! Convert from hydro energy density to pressure
          State_VGB(iP,i,j,k,iBlock) =                             &
               GammaMinus1_I(iFluid)*(State_VGB(iP,i,j,k,iBlock) &
               - 0.5*sum(State_VGB(iRhoUx:iRhoUz,i,j,k,iBlock)**2) &
               /State_VGB(iRho,i,j,k,iBlock))
       end do; end do; end do

    end do FLUIDLOOP

    if(.not.present(IsOld))then
       ! Make sure final pressure is larger than floor value
       ! write(*,*) NameSub,' !!! call limit_pressure'
       call limit_pressure(1, nI, 1, nJ, 1, nK, iBlock, 1, nFluid)
    end if

    call test_stop(NameSub, DoTest, iBlock)
#endif
  end subroutine energy_to_pressure
  !============================================================================
  subroutine energy_to_pressure_cell(iBlock, State_VGB)

    ! Convert energy to pressure in physical cells of block iBlock of State_VGB

    integer, intent(in):: iBlock
    real, intent(inout):: &
         State_VGB(nVar,MinI:MaxI,MinJ:MaxJ,MinK:MaxK,MaxBlock)

    integer:: i, j, k, iFluid
    logical:: DoTest
    character(len=*), parameter:: NameSub = 'energy_to_pressure_cell'
    !--------------------------------------------------------------------------
#ifndef SCALAR
    call test_start(NameSub, DoTest, iBlock)

    FLUIDLOOP: do iFluid = 1, nFluid

       if(nFluid > 1) call select_fluid(iFluid)

       do k = 1, nK; do j = 1, nJ; do i = 1, nI
          ! Leave the body cells alone
          if(.not.Used_GB(i,j,k,iBlock)) CYCLE

          ! Subtract the magnetic energy density
          if(iFluid == 1 .and. IsMhd                                 &
               .and..not.(UseChGL.and.r_GB(i,j,k,iBlock) > rMinChGL)&
               ) then
             State_VGB(iP,i,j,k,iBlock) = State_VGB(iP,i,j,k,iBlock) &
                  - 0.5*sum(State_VGB(Bx_:Bz_,i,j,k,iBlock)**2)
          end if

          if(UseElectronPressure .and. UseElectronEnergy .and. iFluid == 1) &
               State_VGB(iP,i,j,k,iBlock) = State_VGB(iP,i,j,k,iBlock) &
               - State_VGB(Pe_,i,j,k,iBlock)*GammaElectronMinus1

          ! Convert from hydro energy density to pressure
          State_VGB(iP,i,j,k,iBlock) =                             &
               GammaMinus1_I(iFluid)*(State_VGB(iP,i,j,k,iBlock)   &
               - 0.5*sum(State_VGB(iRhoUx:iRhoUz,i,j,k,iBlock)**2) &
               /State_VGB(iRho,i,j,k,iBlock))
       end do; end do; end do

    end do FLUIDLOOP

    call test_stop(NameSub, DoTest, iBlock)
#endif
  end subroutine energy_to_pressure_cell
  !============================================================================
  subroutine limit_pressure(iMin, iMax, jMin, jMax, kMin, kMax, iBlock, &
       iFluidMin, iFluidMax)

    ! Keep pressure(s) in State_VGB above pMin_I limit

    use ModAdvance, ONLY: UseAnisoPressure, UseAnisoPe
    use ModMultiFluid, ONLY: IsIon_I, iPparIon_I

    integer, intent(in) :: iMin, iMax, jMin, jMax, kMin, kMax, iBlock
    integer, intent(in) :: iFluidMin, iFluidMax

    integer:: i, j, k, iFluid
    real :: NumDens, p, pMin, Ne

    character(len=*), parameter:: NameSub = 'limit_pressure'
    !--------------------------------------------------------------------------
    do iFluid = iFluidMin, iFluidMax
       if(pMin_I(iFluid) < 0.0) CYCLE
       pMin = pMin_I(iFluid)
       iP = iP_I(iFluid)
       do k = kMin, kMax; do j = jMin, jMax; do i = iMin, iMax
          State_VGB(iP,i,j,k,iBlock) = max(pMin, State_VGB(iP,i,j,k,iBlock))
          if(UseAnisoPressure .and. IsIon_I(iFluid))&
               State_VGB(iPparIon_I(iFluid),i,j,k,iBlock) = &
               min(max(pMin, State_VGB(iPparIon_I(iFluid),i,j,k,iBlock)), &
               (3*State_VGB(iP_I(iFluid),i,j,k,iBlock) - 2*pMin))
       end do; end do; end do
    end do

    do iFluid = iFluidMin, iFluidMax
       if(Tmin_I(iFluid) < 0.0) CYCLE
       iP = iP_I(iFluid)
       do k = kMin, kMax; do j = jMin, jMax; do i = iMin, iMax
          NumDens=State_VGB(iRho_I(iFluid),i,j,k,iBlock)/MassFluid_I(iFluid)
          pMin = NumDens*Tmin_I(iFluid)
          State_VGB(iP,i,j,k,iBlock) = max(pMin, State_VGB(iP,i,j,k,iBlock))
          if(UseAnisoPressure .and. IsIon_I(iFluid))&
               State_VGB(iPparIon_I(iFluid),i,j,k,iBlock) = &
               min(max(pMin, State_VGB(iPparIon_I(iFluid),i,j,k,iBlock)), &
               (3*State_VGB(iP_I(iFluid),i,j,k,iBlock) - 2*pMin))
       end do; end do; end do
    end do

    if(UseElectronPressure .and. iFluidMin == 1)then
       if(PeMin > 0.0)then
          do k = kMin, kMax; do j = jMin, jMax; do i = iMin, iMax
             State_VGB(Pe_,i,j,k,iBlock) = &
                  max(PeMin, State_VGB(Pe_,i,j,k,iBlock))
             if(UseAnisoPe) State_VGB(Pepar_,i,j,k,iBlock)  = &
                  max(peMin, State_VGB(Pepar_,i,j,k,iBlock))
          end do; end do; end do
       end if
       if(TeMin > 0.0)then
          do k = kMin, kMax; do j = jMin, jMax; do i = iMin, iMax
             Ne = sum(ChargeIon_I*State_VGB(iRhoIon_I,i,j,k,iBlock)/MassIon_I)
             State_VGB(Pe_,i,j,k,iBlock) = &
                  max(Ne*TeMin, State_VGB(Pe_,i,j,k,iBlock))
             if(UseAnisoPe) State_VGB(Pepar_,i,j,k,iBlock)  = &
                  max(Ne*TeMin, State_VGB(Pepar_,i,j,k,iBlock))
          end do; end do; end do
       end if
    end if

  end subroutine limit_pressure
  !============================================================================
end module ModEnergy
!==============================================================================

