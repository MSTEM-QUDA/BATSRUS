!  Copyright (C) 2002 Regents of the University of Michigan,
!  portions used with permission
!  For more information, see http://csem.engin.umich.edu/tools/swmf

module ModUpdateStateFast

  ! Calculate each face twice

  use ModUpdateParamFast, ONLY: &
       DoLf, LimiterBeta, nStage, iStage, nOrder, &
       IsCartesian, IsCartesianGrid, UseNonConservative, &
       UseHyperbolicDivB, IsTimeAccurate
  use ModVarIndexes
  use ModMultiFluid, ONLY: iUx_I, iUy_I, iUz_I, iP_I
  use ModAdvance, ONLY: nFlux, State_VGB, StateOld_VGB, &
       Flux_VXI, Flux_VYI, Flux_VZI, Primitive_VGI, &
       uDotArea_IXI, uDotArea_IYI, uDotArea_IZI, &
       time_BLK
  use BATL_lib, ONLY: nDim, nI, nJ, nK, MinI, MaxI, MinJ, MaxJ, MinK, MaxK, &
       nBlock, Unused_B, x_, y_, z_, CellVolume_B, CellFace_DB, &
       test_start, test_stop, iTest, jTest, kTest, iBlockTest
  use BATL_lib, ONLY: CellVolume_GB, CellFace_DFB, FaceNormal_DDFB
  use ModPhysics, ONLY: Gamma, GammaMinus1, InvGammaMinus1, &
       GammaMinus1_I, InvGammaMinus1_I
  use ModMain, ONLY: UseB, SpeedHyp, Dt, Cfl
  use ModNumConst, ONLY: cUnit_DD

  implicit none

  private ! except

  public:: update_state_cpu      ! save flux, recalculate primitive vars
  public:: update_state_gpu      ! recalculate flux and primitive vars
  public:: update_state_cpu_prim ! save flux and primitive vars
  public:: update_state_gpu_prim ! recalculate flux, save primitive vars

  logical:: DoTestCell= .false.

contains
  !============================================================================
  subroutine update_state_cpu

    ! optimal for CPU (face value and face flux calculated only once)

    integer:: i, j, k, iBlock, iGang, iFluid, iP

    real:: DtPerDv, DivU, Change_V(nFlux)
    !$acc declare create (Change_V)

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'update_state_cpu'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)

    !$acc parallel
    !$acc loop gang private(iGang) independent
    do iBlock = 1, nBlock
       if(Unused_B(iBlock)) CYCLE

#ifdef OPENACC
       iGang = iBlock
#else
       iGang = 1
#endif

       if(iStage == 1 .and. nStage == 2) call set_old_state(iBlock)

       !$acc loop vector collapse(3) independent
       do k = 1, nK; do j = 1, nJ; do i = 1, nI+1
          call get_flux_x(i, j, k, iBlock)
       end do; end do; end do

       if(nDim > 1)then
          !$acc loop vector collapse(3) independent
          do k = 1, nK; do j = 1, nJ+1; do i = 1, nI
             call get_flux_y(i, j, k, iBlock)
          end do; end do; end do
       end if

       if(nDim > 2)then
          !$acc loop vector collapse(3) independent
          do k = 1, nK+1; do j = 1, nJ; do i = 1, nI
             call get_flux_z(i, j, k, iBlock)
          end do; end do; end do
       end if

       ! Update
       !$acc loop vector collapse(3) private(Change_V, DtPerDv) independent
       do k = 1, nK; do j = 1, nJ; do i = 1, nI

          Change_V =  Flux_VXI(:,i,j,k,iGang) - Flux_VXI(:,i+1,j,k,iGang)
          if(nDim > 1) Change_V = Change_V &
               + Flux_VYI(:,i,j,k,iGang) - Flux_VYI(:,i,j+1,k,iGang)
          if(nDim > 2) Change_V = Change_V &
               + Flux_VZI(:,i,j,k,iGang) - Flux_VZI(:,i,j,k+1,iGang)

          if(UseNonConservative)then
             ! Add -(g-1)*p*div(u) source term
             do iFluid = 1, nFluid
                iP = iP_I(iFluid)
                DivU = uDotArea_IXI(iFluid,i+1,j,k,iGang) &
                     - uDotArea_IXI(iFluid,i  ,j,k,iGang)
                if(nJ > 1) DivU = DivU + uDotArea_IYI(iFluid,i,j+1,k,iGang) &
                     -                   uDotArea_IYI(iFluid,i,j,k,iGang)
                if(nK > 1) DivU = DivU + uDotArea_IZI(iFluid,i,j,k+1,iGang) &
                     -                   uDotArea_IZI(iFluid,i,j,k,iGang)
                Change_V(iP) = Change_V(iP) &
                     - GammaMinus1_I(iFluid)*State_VGB(iP,i,j,k,iBlock)*DivU
             end do
          end if

          ! Time step divided by cell volume
          if(IsTimeAccurate)then
             DtPerDv = iStage*Dt
          else
             DtPerDv = iStage*Cfl*time_BLK(i,j,k,iBlock)
          end if
          if(IsCartesian)then
             DtPerDv = DtPerDv/(nStage*CellVolume_B(iBlock))
          else
             DtPerDv = DtPerDv/(nStage*CellVolume_GB(i,j,k,iBlock))
          end if

          ! Update state
          if(iStage == 1)then
             if(.not.UseNonConservative)then
                ! Overwrite pressure and change with energy
                call pressure_to_energy(State_VGB(:,i,j,k,iBlock))
                Change_V(iP_I) = Change_V(Energy_:)
             end if
             State_VGB(:,i,j,k,iBlock) = State_VGB(:,i,j,k,iBlock) &
                  + DtPerDv*Change_V(1:nVar)
          else
             if(.not.UseNonConservative)then
                ! Overwrite old pressure and change with energy
                call pressure_to_energy(StateOld_VGB(:,i,j,k,iBlock))
                Change_V(iP_I) = Change_V(Energy_:)
             end if
             State_VGB(:,i,j,k,iBlock) = StateOld_VGB(:,i,j,k,iBlock) &
                  + DtPerDv*Change_V(1:nVar)
          end if
          ! Convert energy back to pressure
          if(.not.UseNonConservative) &
               call energy_to_pressure(State_VGB(:,i,j,k,iBlock))

#ifndef OPENACC
          DoTestCell = DoTest .and. i==iTest .and. j==jTest .and. k==kTest &
               .and. iBlock == iBlockTest
          if(DoTestCell)then
             write(*,*)'State_VGB =', State_VGB(:,i,j,k,iBlock)
             write(*,*)'Change_V  =', Change_V
             write(*,*)'DtPerDv   =', DtPerDv
          end if
#endif

       enddo; enddo; enddo

    end do
    !$acc end parallel

    call test_stop(NameSub, DoTest, iBlock)

  end subroutine update_state_cpu
  !============================================================================
  subroutine get_flux_x(i, j,  k, iBlock)
    !$acc routine seq

    integer, intent(in):: i, j, k, iBlock

    real :: Area, Normal_D(3)
    real :: StateLeft_V(nVar), StateRight_V(nVar)
    integer:: iGang
    !--------------------------------------------------------------------------
#ifdef OPENACC
       iGang = iBlock
#else
       iGang = 1
#endif
    call get_normal(1, i, j, k, iBlock, Normal_D, Area)

    call get_face_x(i, j, k, iBlock, StateLeft_V, StateRight_V)

    call get_numerical_flux(Normal_D, Area, &
         StateLeft_V, StateRight_V, Flux_VXI(:,i,j,k,iGang), &
         uDotArea_IXI(1,i,j,k,iGang))

  end subroutine get_flux_x
  !============================================================================
  subroutine get_flux_y(i, j, k, iBlock)
    !$acc routine seq

    integer, intent(in):: i, j, k, iBlock

    real :: Area, Normal_D(3)
    real :: StateLeft_V(nVar), StateRight_V(nVar)
    integer:: iGang
    !--------------------------------------------------------------------------
#ifdef OPENACC
       iGang = iBlock
#else
       iGang = 1
#endif
    call get_normal(2, i, j, k, iBlock, Normal_D, Area)

    call get_face_y(i, j, k, iBlock, StateLeft_V, StateRight_V)

    call get_numerical_flux(Normal_D, Area, &
         StateLeft_V, StateRight_V, Flux_VYI(:,i,j,k,iGang), &
         uDotArea_IYI(1,i,j,k,iGang))

  end subroutine get_flux_y
  !============================================================================
  subroutine get_flux_z(i, j, k, iBlock)
    !$acc routine seq

    integer, intent(in):: i, j, k, iBlock

    real :: Area, Normal_D(3)
    real :: StateLeft_V(nVar), StateRight_V(nVar)
    integer:: iGang
    !--------------------------------------------------------------------------
#ifdef OPENACC
       iGang = iBlock
#else
       iGang = 1
#endif
    call get_normal(3, i, j, k, iBlock, Normal_D, Area)

    call get_face_z(i, j, k, iBlock, StateLeft_V, StateRight_V)

    call get_numerical_flux(Normal_D, Area, &
         StateLeft_V, StateRight_V, Flux_VZI(:,i,j,k,iGang), &
         uDotArea_IZI(1,i,j,k,iGang))

  end subroutine get_flux_z
  !============================================================================
  subroutine update_state_gpu

    ! optimal for GPU, but also works with CPU

    integer:: i, j, k, iBlock

    real:: Change_V(nFlux), Change_VC(nFlux,nI,nJ,nK), DtPerDv
    !$acc declare create (Change_V, Change_VC)

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'update_state_gpu'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)

    !$acc parallel
    !$acc loop gang private(Change_VC) independent
    do iBlock = 1, nBlock
       if(Unused_B(iBlock)) CYCLE

       if(iStage == 1 .and. nStage == 2) call set_old_state(iBlock)

       !$acc loop vector collapse(3) private(Change_V) independent
       do k = 1, nK; do j = 1, nJ; do i = 1, nI

#ifndef OPENACC
          DoTestCell = DoTest .and. i==iTest .and. j==jTest .and. k==kTest &
               .and. iBlock == iBlockTest
#endif

          ! Set StateOld here?

          ! Initialize change in State_VGB
          Change_V = 0.0

          call do_face(1, i, j, k, iBlock, Change_V)
          call do_face(2, i, j, k, iBlock, Change_V)

          if(nDim > 1)then
             call do_face(3, i, j, k, iBlock, Change_V)
             call do_face(4, i, j, k, iBlock, Change_V)
          end if

          if(nDim > 2)then
             call do_face(5, i, j, k, iBlock, Change_V)
             call do_face(6, i, j, k, iBlock, Change_V)
          end if

          Change_VC(:,i,j,k) = Change_V

       enddo; enddo; enddo

       ! Update state
       if(iStage == 1)then
          !$acc loop vector collapse(3) private(DtPerDv) independent
          do k = 1, nK; do j = 1, nJ; do i = 1, nI

             ! Time step divided by cell volume
             if(IsTimeAccurate)then
                DtPerDv = Dt
             else
                DtPerDv = Cfl*time_BLK(i,j,k,iBlock)
             end if
             if(IsCartesian)then
                DtPerDv = DtPerDv/(nStage*CellVolume_B(iBlock))
             else
                DtPerDv = DtPerDv/(nStage*CellVolume_GB(i,j,k,iBlock))
             end if

             if(.not.UseNonConservative)then
                ! Overwrite pressure and change with energy
                call pressure_to_energy(State_VGB(:,i,j,k,iBlock))
                Change_VC(iP_I,i,j,k) = Change_VC(Energy_:,i,j,k)
             end if
             ! Update
             State_VGB(:,i,j,k,iBlock) = State_VGB(:,i,j,k,iBlock) &
                  + DtPerDv*Change_VC(1:nVar,i,j,k)

             ! Convert energy back to pressure
             if(.not.UseNonConservative) &
                  call energy_to_pressure(State_VGB(:,i,j,k,iBlock))

#ifndef OPENACC
             DoTestCell = DoTest .and. i==iTest .and. j==jTest .and. k==kTest &
                  .and. iBlock == iBlockTest
             if(DoTestCell)then
                write(*,*)'iStage    =', iStage
                write(*,*)'State_VGB =', State_VGB(:,i,j,k,iBlock)
                write(*,*)'Change_V  =', Change_VC(:,i,j,k)
                write(*,*)'DtPerDv   =', DtPerDv
             end if
#endif

          enddo; enddo; enddo
       else
          !$acc loop vector collapse(3) private(DtPerDv) independent
          do k = 1, nK; do j = 1, nJ; do i = 1, nI

             ! Time step divided by cell volume
             if(IsTimeAccurate)then
                DtPerDv = Dt
             else
                DtPerDv = Cfl*time_BLK(i,j,k,iBlock)
             end if
             if(IsCartesian)then
                DtPerDv = DtPerDv/CellVolume_B(iBlock)
             else
                DtPerDv = DtPerDv/CellVolume_GB(i,j,k,iBlock)
             end if

             if(.not.UseNonConservative)then
                ! Overwrite pressure and change with energy
                call pressure_to_energy(StateOld_VGB(:,i,j,k,iBlock))
                Change_VC(iP_I,i,j,k) = Change_VC(Energy_:,i,j,k)
             end if
             ! Update state
             State_VGB(:,i,j,k,iBlock) = StateOld_VGB(:,i,j,k,iBlock) &
                  + DtPerDv*Change_VC(1:nVar,i,j,k)
             ! Convert energy back to pressure
             if(.not.UseNonConservative) &
                  call energy_to_pressure(State_VGB(:,i,j,k,iBlock))

#ifndef OPENACC
             DoTestCell = DoTest .and. i==iTest .and. j==jTest .and. k==kTest &
                  .and. iBlock == iBlockTest
             if(DoTestCell)then
                write(*,*)'iStage    =', iStage
                write(*,*)'State_VGB =', State_VGB(:,i,j,k,iBlock)
                write(*,*)'Change_V  =', Change_VC(:,i,j,k)
                write(*,*)'DtPerDv   =', DtPerDv
             end if
#endif
          enddo; enddo; enddo
       end if
    end do
    !$acc end parallel

    call test_stop(NameSub, DoTest, iBlock)

  end subroutine update_state_gpu
  !============================================================================
  subroutine do_face(iFace, i, j, k, iBlock, Change_V)
    !$acc routine seq

    integer, intent(in):: iFace, i, j, k, iBlock
    real, intent(inout):: Change_V(nFlux)

    real:: Area, Normal_D(3)
    real:: StateLeft_V(nVar), StateRight_V(nVar), Flux_V(nFlux)
    real:: Unormal_I(nFluid+1)
    !--------------------------------------------------------------------------
    select case(iFace)
    case(1)
       call get_normal(1, i, j, k, iBlock, Normal_D, Area)
       call get_face_x(   i, j, k, iBlock, StateLeft_V, StateRight_V)
    case(2)
       call get_normal(1, i+1, j, k, iBlock, Normal_D, Area)
       Area = -Area
       call get_face_x(   i+1, j, k, iBlock, StateLeft_V, StateRight_V)
    case(3)
       call get_normal(2, i, j, k, iBlock, Normal_D, Area)
       call get_face_y(   i, j, k, iBlock, StateLeft_V, StateRight_V)
    case(4)
       call get_normal(2, i, j+1, k, iBlock, Normal_D, Area)
       Area = -Area
       call get_face_y(   i, j+1, k, iBlock, StateLeft_V, StateRight_V)
    case(5)
       call get_normal(3, i, j, k, iBlock, Normal_D, Area)
       call get_face_z(   i, j, k, iBlock, StateLeft_V, StateRight_V)
    case(6)
       call get_normal(3, i, j, k+1, iBlock, Normal_D, Area)
       Area = -Area
       call get_face_z(   i, j, k+1, iBlock, StateLeft_V, StateRight_V)
    end select

    call get_numerical_flux(Normal_D, &
         Area, StateLeft_V, StateRight_V, Flux_V, Unormal_I)

    Change_V = Change_V + Flux_V

    if(UseNonConservative) Change_V(iP_I) = Change_V(iP_I) &
         + GammaMinus1_I*State_VGB(iP_I,i,j,k,iBlock)*Unormal_I(1:nFluid)

  end subroutine do_face
  !============================================================================
  subroutine set_old_state(iBlock)
    !$acc routine vector

    integer, intent(in):: iBlock

    integer:: i, j, k

    !$acc loop vector collapse(3) independent
    !--------------------------------------------------------------------------
    do k = 1, nK; do j = 1, nJ; do i = 1, nI
       StateOld_VGB(:,i,j,k,iBlock)  = State_VGB(:,i,j,k,iBlock)
    end do; end do; end do

  end subroutine set_old_state
  !============================================================================
  subroutine get_physical_flux(State_V, Normal_D, StateCons_V, Flux_V)
    !$acc routine seq

    real, intent(in) :: State_V(nVar)      ! primitive state vector
    real, intent(in) :: Normal_D(3)        ! face normal
    real, intent(out):: StateCons_V(nFlux) ! conservative state vector
    real, intent(out):: Flux_V(nFlux)      ! conservative flux

    real:: Rho, Un, Bn, pB, e
    ! Convenient variables
    !--------------------------------------------------------------------------
    Rho = State_V(Rho_)
    Un  = sum(State_V(Ux_:Uz_)*Normal_D)
    Bn  = sum(State_V(Bx_:Bz_)*Normal_D)
    pB  = 0.5*sum(State_V(Bx_:Bz_)**2)
    e   = InvGammaMinus1*State_V(p_) + 0.5*Rho*sum(State_V(Ux_:Uz_)**2)

    ! Conservative state for the Rusanov solver
    StateCons_V(1:nVar) = State_V
    StateCons_V(RhoUx_:RhoUz_) = State_V(Rho_)*State_V(Ux_:Uz_)
    StateCons_V(Energy_) = e + pB ! Add magnetic energy density

    ! Physical flux
    Flux_V(Rho_) = Rho*Un
    Flux_V(RhoUx_:RhoUz_) = Un*Rho*State_V(Ux_:Uz_) - Bn*State_V(Bx_:Bz_) &
         + Normal_D*(State_V(p_) + pB)
    if(Hyp_ > 1)then
       Flux_V(Bx_:Bz_) = Un*State_V(Bx_:Bz_) - State_V(Ux_:Uz_)*Bn &
            + Normal_D*SpeedHyp*State_V(Hyp_)
       Flux_V(Hyp_) = SpeedHyp*Bn
    else
       Flux_V(Bx_:Bz_) = Un*State_V(Bx_:Bz_) - State_V(Ux_:Uz_)*Bn
    end if
    Flux_V(p_)      =  Un*State_V(p_)
    Flux_V(Energy_) =  Un*(e + State_V(p_)) &
         + sum(Flux_V(Bx_:Bz_)*State_V(Bx_:Bz_)) ! Poynting flux

  end subroutine get_physical_flux
  !============================================================================
  subroutine get_speed_max(State_V, Normal_D, &
       Un, Cmax, Cleft, Cright)
    !$acc routine seq

    ! Using primitive variable State_V and normal direction get
    ! normal velocity and wave speeds.

    real, intent(in) :: State_V(nVar), Normal_D(3)
    real, intent(out):: Un              ! normal velocity (signed)
    real, intent(out), optional:: Cmax  ! maximum speed (positive)
    real, intent(out), optional:: Cleft ! fastest left wave (usually negative)
    real, intent(out), optional:: Cright! fastest right wave (usually positive)

    real:: InvRho, Bn, B2
    real:: Sound2, Fast2, Discr, Fast
    !--------------------------------------------------------------------------
    InvRho = 1.0/State_V(Rho_)
    Bn  = sum(State_V(Bx_:Bz_)*Normal_D)
    B2  = sum(State_V(Bx_:Bz_)**2)

    Sound2= InvRho*State_V(p_)*Gamma
    Fast2 = Sound2 + InvRho*B2
    Discr = sqrt(max(0.0, Fast2**2 - 4*Sound2*InvRho*Bn**2))
    Fast  = sqrt( 0.5*(Fast2 + Discr) )

    Un = sum(State_V(Ux_:Uz_)*Normal_D)
    if(present(Cmax))   Cmax   = abs(Un) + Fast
    if(present(Cleft))  Cleft  = Un - Fast
    if(present(Cright)) Cright = Un + Fast

#ifndef OPENACC
    if(DoTestCell)then
       write(*,*) &
            ' iFluid, rho, p(face)   =', 1, State_V(Rho_), State_V(p_)
       ! if(UseAnisoPressure) write(*,*) &
       !     ' Ppar, Perp             =', Ppar, Pperp
       ! if(UseElectronPressure) write(*,*) &
       !     ' State_V(Pe_)           =', State_V(Pe_)
       ! if(UseAnisoPe) write(*,*) &
       !     ' State_V(Pepar_)        =', State_V(Pepar_)
       ! if(UseWavePressure) write(*,*) &
       !     ' GammaWave, State(Waves)=', &
       !     GammaWave, State_V(WaveFirst_:WaveLast_)
       write(*,*) &
            ' Fast2, Discr          =', Fast2, Discr
       write(*,*) &
            ' Sound2, Alfven2       =', Sound2, InvRho*B2
       write(*,*) &
            ' FullBn, Alfven2Normal =', Bn, InvRho*Bn**2
       write(*,*) &
            ' FullBx, FullBy, FullBz=', State_V(Bx_:Bz_)
    end if
#endif

  end subroutine get_speed_max
  !============================================================================
  subroutine get_normal(iDir, i, j, k, iBlock, Normal_D, Area)
    !$acc routine seq
    integer, intent(in) :: i, j, k, iBlock, iDir
    real,    intent(out):: Normal_D(3), Area
    !--------------------------------------------------------------------------
    if(IsCartesian)then
       Area = CellFace_DB(iDir,iBlock)
    else
       Area = CellFace_DFB(iDir,i,j,k,iBlock)
       if(Area == 0.0)then
          Normal_D = [1.0, 0.0, 0.0]
          RETURN
       end if
    end if
    if(IsCartesianGrid)then
       Normal_D = cUnit_DD(:,iDir)
    else
       Normal_D = FaceNormal_DDFB(:,iDir,i,j,k,iBlock)/Area
    end if

  end subroutine get_normal
  !============================================================================
  subroutine get_face_x(i, j, k, iBlock, StateLeft_V, StateRight_V)
    !$acc routine seq

    integer, intent(in) :: i, j, k, iBlock
    real,    intent(out):: StateLeft_V(nVar), StateRight_V(nVar)

    integer:: iVar
    !--------------------------------------------------------------------------
    if(nOrder == 1)then
       call get_primitive(State_VGB(:,i-1,j,k,iBlock), StateLeft_V)
       call get_primitive(State_VGB(:,i,j,k,iBlock),   StateRight_V)
    else
       ! Do it per variable to reduce memory use
       do iVar = 1, nVar
          ! Single fluid conversion to primitive variables
          if(iVar < Ux_ .or. iVar > Uz_)then
             call limiter2( &
                  State_VGB(iVar,i-2,j,k,iBlock), &
                  State_VGB(iVar,i-1,j,k,iBlock), &
                  State_VGB(iVar,  i,j,k,iBlock), &
                  State_VGB(iVar,i+1,j,k,iBlock), &
                  StateLeft_V(iVar), StateRight_V(iVar))
          else
             call limiter2( &
                  State_VGB(iVar,i-2,j,k,iBlock)/ &
                  State_VGB(Rho_,i-2,j,k,iBlock), &
                  State_VGB(iVar,i-1,j,k,iBlock)/ &
                  State_VGB(Rho_,i-1,j,k,iBlock), &
                  State_VGB(iVar,  i,j,k,iBlock)/ &
                  State_VGB(Rho_,  i,j,k,iBlock), &
                  State_VGB(iVar,i+1,j,k,iBlock)/ &
                  State_VGB(Rho_,i+1,j,k,iBlock), &
                  StateLeft_V(iVar), StateRight_V(iVar))
          end if
       end do
    end if

  end subroutine get_face_x
  !============================================================================
  subroutine get_face_y(i, j, k, iBlock, StateLeft_V, StateRight_V)
    !$acc routine seq

    integer, intent(in) :: i, j, k, iBlock
    real,    intent(out):: StateLeft_V(nVar), StateRight_V(nVar)

    integer:: iVar
    !--------------------------------------------------------------------------
    if(nOrder == 1)then
       call get_primitive(State_VGB(:,i,j-1,k,iBlock), StateLeft_V)
       call get_primitive(State_VGB(:,i,j,k,iBlock),   StateRight_V)
    else
       ! Do it per variable to reduce memory use
       do iVar = 1, nVar
          ! Single fluid conversion to primitive variables
          if(iVar < Ux_ .or. iVar > Uz_)then
             call limiter2( &
                  State_VGB(iVar,i,j-2,k,iBlock), &
                  State_VGB(iVar,i,j-1,k,iBlock), &
                  State_VGB(iVar,i,j  ,k,iBlock), &
                  State_VGB(iVar,i,j+1,k,iBlock), &
                  StateLeft_V(iVar), StateRight_V(iVar))
          else
             call limiter2( &
                  State_VGB(iVar,i,j-2,k,iBlock)/ &
                  State_VGB(Rho_,i,j-2,k,iBlock), &
                  State_VGB(iVar,i,j-1,k,iBlock)/ &
                  State_VGB(Rho_,i,j-1,k,iBlock), &
                  State_VGB(iVar,i,j  ,k,iBlock)/ &
                  State_VGB(Rho_,i,j  ,k,iBlock), &
                  State_VGB(iVar,i,j+1,k,iBlock)/ &
                  State_VGB(Rho_,i,j+1,k,iBlock), &
                  StateLeft_V(iVar), StateRight_V(iVar))
          end if
       end do
    end if
  end subroutine get_face_y
  !============================================================================
  subroutine get_face_z(i, j, k, iBlock, StateLeft_V, StateRight_V)
    !$acc routine seq

    integer, intent(in) :: i, j, k, iBlock
    real,    intent(out):: StateLeft_V(nVar), StateRight_V(nVar)

    integer:: iVar
    !--------------------------------------------------------------------------
    if(nOrder == 1)then
       call get_primitive(State_VGB(:,i,j,k-1,iBlock), StateLeft_V)
       call get_primitive(State_VGB(:,i,j,k,iBlock),   StateRight_V)
    else
       ! Do it per variable to reduce memory use
       do iVar = 1, nVar
          ! Single fluid conversion to primitive variables
          if(iVar < Ux_ .or. iVar > Uz_)then
             call limiter2( &
                  State_VGB(iVar,i,j,k-2,iBlock), &
                  State_VGB(iVar,i,j,k-1,iBlock), &
                  State_VGB(iVar,i,j,k  ,iBlock), &
                  State_VGB(iVar,i,j,k+1,iBlock), &
                  StateLeft_V(iVar), StateRight_V(iVar))
          else
             call limiter2( &
                  State_VGB(iVar,i,j,k-2,iBlock)/ &
                  State_VGB(Rho_,i,j,k-2,iBlock), &
                  State_VGB(iVar,i,j,k-1,iBlock)/ &
                  State_VGB(Rho_,i,j,k-1,iBlock), &
                  State_VGB(iVar,i,j,k  ,iBlock)/ &
                  State_VGB(Rho_,i,j,k  ,iBlock), &
                  State_VGB(iVar,i,j,k+1,iBlock)/ &
                  State_VGB(Rho_,i,j,k+1,iBlock), &
                  StateLeft_V(iVar), StateRight_V(iVar))
          end if
       end do
    end if

  end subroutine get_face_z
  !============================================================================
  subroutine get_numerical_flux(Normal_D, &
       Area,  StateLeft_V, StateRight_V, Flux_V, Unormal_I)
    !$acc routine seq

    real, intent(in)   :: Normal_D(3), Area
    real, intent(inout):: StateLeft_V(nVar), StateRight_V(nVar)
    real, intent(out)  :: Flux_V(nFlux)
    real, intent(out)  :: Unormal_I(nFluid+1)

    ! Average state
    real:: State_V(nVar)

    ! Conservative variables
    real :: StateLeftCons_V(nFlux), StateRightCons_V(nFlux)

    ! Left and right fluxes
    real :: FluxLeft_V(nFlux), FluxRight_V(nFlux)

    ! Left, right and maximum speeds, normal velocity, jump in Bn
    real :: Cleft, Cright, Cmax, Un, DiffBn, CleftAverage, CrightAverage

    real :: CInvDiff, CMulti
    !--------------------------------------------------------------------------
    if(DoLf)then
       ! Rusanov scheme

       ! average state
       State_V = 0.5*(StateLeft_V + StateRight_V)

       call get_speed_max(State_V, Normal_D, Un, Cmax)
       call get_physical_flux(StateLeft_V, Normal_D, &
            StateLeftCons_V, FluxLeft_V)
       call get_physical_flux(StateRight_V, Normal_D, &
            StateRightCons_V, FluxRight_V)

       ! Lax-Friedrichs flux
       Flux_V = Area*0.5*((FluxLeft_V + FluxRight_V) &
            +             Cmax*(StateLeftCons_V - StateRightCons_V))

       if(UseNonConservative) Unormal_I(1:nFluid) = Area*0.5* &
               ( (StateLeft_V(iUx_I) + StateRight_V(iUx_I))*Normal_D(1) &
               + (StateLeft_V(iUy_I) + StateRight_V(iUy_I))*Normal_D(2) &
               + (StateLeft_V(iUz_I) + StateRight_V(iUz_I))*Normal_D(3) )
    else
       ! Linde scheme
       if(UseB)then
          ! Sokolov's algorithm
          ! Calculate the jump in the normal magnetic field vector
          DiffBn = &
               0.5*sum(Normal_D*(StateRight_V(Bx_:Bz_) - StateLeft_V(Bx_:Bz_)))

          ! Remove the jump in the normal magnetic field
          StateLeft_V(Bx_:Bz_)  = StateLeft_V(Bx_:Bz_)  + DiffBn*Normal_D
          StateRight_V(Bx_:Bz_) = StateRight_V(Bx_:Bz_) - DiffBn*Normal_D
       end if

       ! This implementation is for non-relativistic MHD only
       ! Left speed of left state
       call get_speed_max(StateLeft_V, Normal_D, Un, Cleft=Cleft)

       ! Right speed of right state
       call get_speed_max(StateRight_V, Normal_D, Un, Cright=Cright)

       ! Speeds of average state
       State_V = 0.5*(StateLeft_V + StateRight_V)
       call get_speed_max(State_V, Normal_D, &
            Un, Cmax, CleftAverage, CrightAverage)

       ! Limited left and right speeds
       Cleft  = min(0.0, Cleft,  CleftAverage)
       Cright = max(0.0, Cright, CrightAverage)

       ! Physical flux
       call get_physical_flux(StateLeft_V, Normal_D, &
            StateLeftCons_V, FluxLeft_V)
       call get_physical_flux(StateRight_V, Normal_D, &
            StateRightCons_V, FluxRight_V)

       CMulti = Cright*Cleft
       CInvDiff = 1./(Cright - Cleft)
       ! HLLE flux
       Flux_V = &
            ( Cright*FluxLeft_V - Cleft*FluxRight_V  &
            + CMulti*(StateRightCons_V - StateLeftCons_V) ) &
            *CInvDiff

       if(UseNonConservative) Unormal_I(1:nFluid) = Area*CInvDiff*  &
            ( (Cright*StateLeft_V(iUx_I)              &
            -  Cleft*StateRight_V(iUx_I))*Normal_D(1) &
            + (Cright*StateLeft_V(iUy_I)              &
            -  Cleft*StateRight_V(iUy_I))*Normal_D(2) &
            + (Cright*StateLeft_V(iUz_I)              &
            -  Cleft*StateRight_V(iUz_I))*Normal_D(3) )

       if(UseB)then
          if(Hyp_ > 1 .and. UseHyperbolicDivb) then
             ! Overwrite the flux of the Hyp field with the Lax-Friedrichs flux
             Cmax = max(Cmax, SpeedHyp)
             Flux_V(Hyp_) = 0.5*(FluxLeft_V(Hyp_) + FluxRight_V(Hyp_) &
                  - Cmax*(StateRight_V(Hyp_) - StateLeft_V(Hyp_)))
          end if

          ! Linde scheme: use Lax-Friedrichs flux for Bn
          ! The original jump was removed, now we add it with Cmax
          Flux_V(Bx_:Bz_) = Flux_V(Bx_:Bz_) - Cmax*DiffBn*Normal_D

          ! Fix the energy diffusion
          ! The energy jump is also modified by
          ! 1/2(Br^2 - Bl^2) = 1/2(Br-Bl)*(Br+Bl)
          Flux_V(Energy_) = Flux_V(Energy_) - Cmax*0.5*DiffBn* &
               sum( Normal_D*(StateRight_V(Bx_:Bz_) + StateLeft_V(Bx_:Bz_)))
       end if

       Flux_V = Area*Flux_V

    end if

  end subroutine get_numerical_flux
  !============================================================================
  subroutine energy_to_pressure(State_V)
    !$acc routine seq

    ! Calculate pressure from energy density
    real, intent(inout):: State_V(nVar)
    !--------------------------------------------------------------------------

    ! Subtract magnetic energy from the first fluid for MHD
    if(IsMhd) State_V(p_) = State_V(p_) -  0.5*sum(State_V(Bx_:Bz_)**2)

    ! Convert hydro energy density to pressure
    State_V(iP_I) = GammaMinus1_I*( State_V(iP_I) - 0.5* &
         ( State_V(iRhoUx_I)**2 &
         + State_V(iRhoUy_I)**2 &
         + State_V(iRhoUz_I)**2 ) / State_V(iRho_I) )

  end subroutine energy_to_pressure
  !============================================================================
  subroutine pressure_to_energy(State_V)
    !$acc routine seq

    ! Calculate energy density from pressure
    real, intent(inout):: State_V(nVar)
    !--------------------------------------------------------------------------

    ! Calculy hydro energy density
    State_V(iP_I) = State_V(iP_I)*InvGammaMinus1_I + 0.5* &
         ( State_V(iRhoUx_I)**2 &
         + State_V(iRhoUy_I)**2 &
         + State_V(iRhoUz_I)**2 ) / State_V(iRho_I)

    ! Add magnetic energy to first fluid for MHD
    if(IsMhd) State_V(p_) = State_V(p_) + 0.5*sum(State_V(Bx_:Bz_)**2)

  end subroutine pressure_to_energy
  !============================================================================
  subroutine get_primitive(State_V, Primitive_V)
    !$acc routine seq

    real, intent(in) :: State_V(nVar)
    real, intent(out):: Primitive_V(nVar)
    !--------------------------------------------------------------------------
    Primitive_V(1:Ux_-1)    = State_V(1:RhoUx_-1)
    Primitive_V(Ux_:Uz_)    = State_V(RhoUx_:RhoUz_)/State_V(Rho_)
    Primitive_V(Uz_+1:nVar) = State_V(RhoUz_+1:nVar)

  end subroutine get_primitive
  !============================================================================
  subroutine limiter2(Var1, Var2, Var3, Var4, VarLeft, VarRight)
    !$acc routine seq

    ! Second order limiter on a 4 point stencil
    real, intent(in) :: Var1, Var2, Var3, Var4  ! cell center values at i=1..4
    real, intent(out):: VarLeft, VarRight       ! face values at i=2.5

    real, parameter:: cThird = 1./3.
    real:: Slope21, Slope32, Slope43
    !--------------------------------------------------------------------------
    Slope21 = LimiterBeta*(Var2 - Var1)
    Slope32 = LimiterBeta*(Var3 - Var2)
    Slope43 = LimiterBeta*(Var4 - Var3)

    VarLeft  = Var2 + (sign(0.25,Slope32) + sign(0.25,Slope21))*&
         min(abs(Slope32), abs(Slope21), cThird*abs(2*Var3-Var1-Var2))
    VarRight = Var3 - (sign(0.25,Slope32) + sign(0.25,Slope43))*&
         min(abs(Slope32), abs(Slope43), cThird*abs(Var3+Var4-2*Var2))

  end subroutine limiter2
  !============================================================================

! end module ModUpdateStateFast
!!==============================================================================
!
! module ModUpdateStatePrim
!
!  ! Save Primitive_VG array
!
!  ! Calculate each face twice
!
!  use ModUpdateParamFast, ONLY: &
!       DoLf, LimiterBeta, nStage, iStage, nOrder, IsCartesian, &
!       UseNonConservative, IsTimeAccurate
!  use ModVarIndexes
!  use ModMultiFluid, ONLY: iUx_I, iUy_I, iUz_I
!  use ModAdvance, ONLY: nFlux, State_VGB, StateOld_VGB, &
!       Flux_VXI, Flux_VYI, Flux_VZI, &
!       uDotArea_IXI, uDotArea_IYI, uDotArea_IZI, &
!       time_BLK
!  use ModAdvance, ONLY: Primitive_VGI
!  use ModMain, ONLY: Cfl, Dt
!  use BATL_lib, ONLY: nDim, nI, nJ, nK, MinI, MaxI, MinJ, MaxJ, MinK, MaxK, &
!       nBlock, Unused_B, x_, y_, z_, CellVolume_B, CellVolume_GB, &
!       CellFace_DB, CellFace_DFB, FaceNormal_DDFB, &
!       test_start, test_stop, iTest, jTest, kTest, iBlockTest
!
!  use ModPhysics, ONLY: Gamma, InvGammaMinus1, GammaMinus1_I
!  use ModMain, ONLY: UseB, SpeedHyp
!  use ModNumConst, ONLY: cUnit_DD
!
!  use ModUpdateStateFast, ONLY: &
!       pressure_to_energy, energy_to_pressure, &
!       get_normal, get_primitive, get_numerical_flux, &
!       limiter2, set_old_state
!
!  implicit none
!
!  private ! except
!
!  public:: update_state_cpu_prim ! optimal for CPU
!  public:: update_state_gpu_prim ! optimal for GPU
!
!  logical:: DoTestCell= .false.
!
! contains
  subroutine update_state_cpu_prim

    ! optimal for CPU (face value and face flux calculated only once)

    integer:: i, j, k, iBlock, iGang, iFluid, iP

    real:: DivU, DtPerDv, Change_V(nFlux)
    !$acc declare create (Change_V)

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'update_state_cpu_prim'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)

    !$acc parallel
    !$acc loop gang private(iGang) independent
    do iBlock = 1, nBlock
       if(Unused_B(iBlock)) CYCLE

#ifdef OPENACC
       iGang = iBlock
#else
       iGang = 1
#endif

       if(iStage == 1 .and. nStage == 2) call set_old_state(iBlock)

       ! Calculate the primitive variables
       !$acc loop vector collapse(3) independent
       do k = MinK, MaxK; do j = MinJ, MaxJ; do i = MinI, MaxI
          call get_primitive(State_VGB(:,i,j,k,iBlock), Primitive_VGI(:,i,j,k,iGang))
       end do; end do; end do

       !$acc loop vector collapse(3) independent
       do k = 1, nK; do j = 1, nJ; do i = 1, nI+1

          ! DoTestCell = DoTest .and. (i == iTest .or. i == iTest+1) .and. &
          !     j == jTest .and. k == kTest .and. iBlock == iBlockTest

          call get_flux_x_prim(i, j, k, iBlock, Flux_VXI(:,i,j,k,iGang), &
               uDotArea_IXI(1,i,j,k,iGang))

       end do; end do; end do

       if(nDim > 1)then
          !$acc loop vector collapse(3) independent
          do k = 1, nK; do j = 1, nJ+1; do i = 1, nI

             ! DoTestCell = DoTest .and. iBlock==iBlockTest .and. i==iTest &
             !     .and. (j==jTest .or. j==jTest+1) .and. k==kTest

             call get_flux_y_prim(i, j, k, iBlock, Flux_VYI(:,i,j,k,iGang), &
                  uDotArea_IYI(1,i,j,k,iGang))

          end do; end do; end do
       end if

       if(nDim > 2)then
          !$acc loop vector collapse(3) independent
          do k = 1, nK+1; do j = 1, nJ; do i = 1, nI

             ! DoTestCell = DoTest .and. iBlock==iBlockTest .and. i==iTest &
             !     .and. j==jTest .and. (k==kTest .or. k==kTest+1)

             call get_flux_z_prim(i, j, k, iBlock, Flux_VZI(:,i,j,k,iGang), &
                  uDotArea_IZI(1,i,j,k,iGang))

          end do; end do; end do
       end if

       ! Update
       !$acc loop vector collapse(3) private(Change_V, DtPerDv) independent
       do k = 1, nK; do j = 1, nJ; do i = 1, nI

          Change_V =  Flux_VXI(:,i,j,k,iGang) - Flux_VXI(:,i+1,j,k,iGang)
          if(nDim > 1) Change_V = Change_V &
               + Flux_VYI(:,i,j,k,iGang) - Flux_VYI(:,i,j+1,k,iGang)
          if(nDim > 2) Change_V = Change_V &
               + Flux_VZI(:,i,j,k,iGang) - Flux_VZI(:,i,j,k+1,iGang)

          if(UseNonConservative)then
             ! Add -(g-1)*p*div(u) source term
             do iFluid = 1, nFluid
                iP = iP_I(iFluid)
                DivU = uDotArea_IXI(iFluid,i+1,j,k,iGang) &
                     - uDotArea_IXI(iFluid,i  ,j,k,iGang)
                if(nJ > 1) DivU = DivU + uDotArea_IYI(iFluid,i,j+1,k,iGang) &
                     -                   uDotArea_IYI(iFluid,i,j,k,iGang)
                if(nK > 1) DivU = DivU + uDotArea_IZI(iFluid,i,j,k+1,iGang) &
                     -                   uDotArea_IZI(iFluid,i,j,k,iGang)
                Change_V(iP) = Change_V(iP) &
                     - GammaMinus1_I(iFluid)*State_VGB(iP,i,j,k,iBlock)*DivU
             end do
          end if

          ! Time step divided by cell volume
          if(IsTimeAccurate)then
             DtPerDv = iStage*Dt
          else
             DtPerDv = iStage*Cfl*time_BLK(i,j,k,iBlock)
          end if
          if(IsCartesian)then
             DtPerDv = DtPerDv/(nStage*CellVolume_B(iBlock))
          else
             DtPerDv = DtPerDv/(nStage*CellVolume_GB(i,j,k,iBlock))
          end if

          ! Update state
          if(iStage == 1)then
             if(.not.UseNonConservative)then
                ! Overwrite pressure and change with energy
                call pressure_to_energy(State_VGB(:,i,j,k,iBlock))
                Change_V(iP_I) = Change_V(Energy_:)
             end if
             State_VGB(:,i,j,k,iBlock) = State_VGB(:,i,j,k,iBlock) &
                  + DtPerDv*Change_V(1:nVar)
          else
             if(.not.UseNonConservative)then
                ! Overwrite old pressure and change with energy
                call pressure_to_energy(StateOld_VGB(:,i,j,k,iBlock))
                Change_V(iP_I) = Change_V(Energy_:)
             end if
             State_VGB(:,i,j,k,iBlock) = StateOld_VGB(:,i,j,k,iBlock) &
                  + DtPerDv*Change_V(1:nVar)
          end if
          ! Convert energy back to pressure
          if(.not.UseNonConservative) &
               call energy_to_pressure(State_VGB(:,i,j,k,iBlock))

#ifndef OPENACC
          DoTestCell = DoTest .and. i==iTest .and. j==jTest .and. k==kTest &
               .and. iBlock == iBlockTest
          if(DoTestCell)then
             write(*,*)'State_VGB =', State_VGB(:,i,j,k,iBlock)
             write(*,*)'Change_V  =', Change_V
             write(*,*)'DtPerDv   =', DtPerDv
          end if
#endif
       enddo; enddo; enddo

    end do
    !$acc end parallel

    call test_stop(NameSub, DoTest, iBlock)

  end subroutine update_state_cpu_prim
  !============================================================================
  subroutine get_flux_x_prim(i, j,  k, iBlock, Flux_V, Unormal_I)
    !$acc routine seq

    integer, intent(in) :: i, j, k, iBlock
    real,    intent(out):: Flux_V(nFlux)
    real,    intent(out):: Unormal_I(nFluid+1)

    real :: Area, Normal_D(3)
    real :: StateLeft_V(nVar), StateRight_V(nVar)
    !--------------------------------------------------------------------------
    call get_normal(1, i, j, k, iBlock, Normal_D, Area)

    call get_face_x_prim(i, j, k, iBlock, StateLeft_V, StateRight_V)

    call get_numerical_flux(Normal_D, Area, &
         StateLeft_V, StateRight_V, Flux_V, Unormal_I)

  end subroutine get_flux_x_prim
  !============================================================================
  subroutine get_flux_y_prim(i, j, k, iBlock, Flux_V, Unormal_I)
    !$acc routine seq

    integer, intent(in) :: i, j, k, iBlock
    real,    intent(out):: Flux_V(nFlux)
    real,    intent(out):: Unormal_I(nFluid+1)

    real :: Area, Normal_D(3)
    real :: StateLeft_V(nVar), StateRight_V(nVar)
    !--------------------------------------------------------------------------
    call get_normal(2, i, j, k, iBlock, Normal_D, Area)

    call get_face_y_prim(i, j, k, iBlock, StateLeft_V, StateRight_V)

    call get_numerical_flux(Normal_D, Area, &
         StateLeft_V, StateRight_V, Flux_V, Unormal_I)

  end subroutine get_flux_y_prim
  !============================================================================
  subroutine get_flux_z_prim(i, j, k, iBlock, Flux_V, Unormal_I)
    !$acc routine seq

    integer, intent(in) :: i, j, k, iBlock
    real,    intent(out):: Flux_V(nFlux)
    real,    intent(out):: Unormal_I(nFluid+1)

    real :: Area, Normal_D(3)
    real :: StateLeft_V(nVar), StateRight_V(nVar)
    !--------------------------------------------------------------------------
    call get_normal(3, i, j, k, iBlock, Normal_D, Area)

    call get_face_z_prim(i, j, k, iBlock, StateLeft_V, StateRight_V)

    call get_numerical_flux(Normal_D, Area, &
         StateLeft_V, StateRight_V, Flux_V, Unormal_I)

  end subroutine get_flux_z_prim
  !============================================================================
  subroutine update_state_gpu_prim

    ! optimal for GPU, store primitive variables

    integer:: i, j, k, iBlock, iGang

    real:: Change_V(nFlux), DtPerDv
    !$acc declare create (Change_V)

#ifndef OPENACC
    logical:: DoTest
    character(len=*), parameter:: NameSub = 'update_state_gpu_prim'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)
#endif

    !$acc parallel
    !$acc loop gang independent
    do iBlock = 1, nBlock
       if(Unused_B(iBlock)) CYCLE

#ifdef OPENACC
       iGang = iBlock
#else
       iGang = 1
#endif
       if(iStage == 1 .and. nStage == 2) call set_old_state(iBlock)

       !$acc loop vector collapse(3) independent
       do k = MinK, MaxK; do j = MinJ, MaxJ; do i = MinI, MaxI
          call get_primitive(State_VGB(:,i,j,k,iBlock), Primitive_VGI(:,i,j,k,iGang))
       end do; end do; end do

       !$acc loop vector collapse(3) private(Change_V, DtPerDv) independent
       do k = 1, nK; do j = 1, nJ; do i = 1, nI

          ! DoTestCell = DoTest .and. i==iTest .and. j==jTest .and. k==kTest &
          !     .and. iBlock == iBlockTest

          ! Initialize change in State_VGB
          Change_V = 0.0

          call do_face_prim(1, i, j, k, iBlock, Change_V)
          call do_face_prim(2, i, j, k, iBlock, Change_V)

          if(nDim > 1)then
             call do_face_prim(3, i, j, k, iBlock, Change_V)
             call do_face_prim(4, i, j, k, iBlock, Change_V)
          end if

          if(nDim > 2)then
             call do_face_prim(5, i, j, k, iBlock, Change_V)
             call do_face_prim(6, i, j, k, iBlock, Change_V)
          end if

          ! Time step divided by cell volume
          if(IsTimeAccurate)then
             DtPerDv = iStage*Dt
          else
             DtPerDv = iStage*Cfl*time_BLK(i,j,k,iBlock)
          end if
          if(IsCartesian)then
             DtPerDv = DtPerDv/(nStage*CellVolume_B(iBlock))
          else
             DtPerDv = DtPerDv/(nStage*CellVolume_GB(i,j,k,iBlock))
          end if

          ! Update state
          if(iStage == 1)then
             if(.not.UseNonConservative)then
                ! Overwrite pressure and change with energy
                call pressure_to_energy(State_VGB(:,i,j,k,iBlock))
                Change_V(iP_I) = Change_V(Energy_:)
             end if
             State_VGB(:,i,j,k,iBlock) = State_VGB(:,i,j,k,iBlock) &
                  + DtPerDv*Change_V(1:nVar)
          else
             if(.not.UseNonConservative)then
                ! Overwrite old pressure and change with energy
                call pressure_to_energy(StateOld_VGB(:,i,j,k,iBlock))
                Change_V(iP_I) = Change_V(Energy_:)
             end if
             State_VGB(:,i,j,k,iBlock) = StateOld_VGB(:,i,j,k,iBlock) &
                  + DtPerDv*Change_V(1:nVar)
          end if
          ! Convert energy back to pressure
          if(.not.UseNonConservative) &
               call energy_to_pressure(State_VGB(:,i,j,k,iBlock))

#ifndef OPENACC
          ! DoTestCell = DoTest .and. i==iTest .and. j==jTest .and. k==kTest &
          !     .and. iBlock == iBlockTest
          ! if(DoTestCell)then
          !   write(*,*)'State_VGB =', State_VGB(:,i,j,k,iBlock)
          !   write(*,*)'Change_V  =', Change_V
          !   write(*,*)'DtPerDv   =', DtPerDv
          ! end if
#endif
       enddo; enddo; enddo
    end do
    !$acc end parallel

#ifndef OPENACC
    call test_stop(NameSub, DoTest, iBlock)
#endif
  end subroutine update_state_gpu_prim
  !============================================================================
  subroutine do_face_prim(iFace, i, j, k, iBlock, Change_V)
    !$acc routine seq

    integer, intent(in):: iFace, i, j, k, iBlock
    real, intent(inout):: Change_V(nFlux)

    real:: Area, Normal_D(3)
    real:: StateLeft_V(nVar), StateRight_V(nVar), Flux_V(nFlux)
    real:: Unormal_I(nFluid+1)
    !--------------------------------------------------------------------------
    select case(iFace)
    case(1)
       call get_normal(1, i, j, k, iBlock, Normal_D, Area)
       call get_face_x_prim(   i, j, k, iBlock, StateLeft_V, StateRight_V)
    case(2)
       call get_normal(1, i+1, j, k, iBlock, Normal_D, Area)
       Area = -Area
       call get_face_x_prim(   i+1, j, k, iBlock, StateLeft_V, StateRight_V)
    case(3)
       call get_normal(2, i, j, k, iBlock, Normal_D, Area)
       call get_face_y_prim(   i, j, k, iBlock, StateLeft_V, StateRight_V)
    case(4)
       call get_normal(2, i, j+1, k, iBlock, Normal_D, Area)
       Area = -Area
       call get_face_y_prim(   i, j+1, k, iBlock, StateLeft_V, StateRight_V)
    case(5)
       call get_normal(3, i, j, k, iBlock, Normal_D, Area)
       call get_face_z_prim(   i, j, k, iBlock, StateLeft_V, StateRight_V)
    case(6)
       call get_normal(3, i, j, k+1, iBlock, Normal_D, Area)
       Area = -Area
       call get_face_z_prim(   i, j, k+1, iBlock, StateLeft_V, StateRight_V)
    end select

    call get_numerical_flux(Normal_D, Area, StateLeft_V, StateRight_V, &
         Flux_V, Unormal_I)

    Change_V = Change_V + Flux_V

    if(UseNonConservative) Change_V(iP_I) = Change_V(iP_I) &
         + GammaMinus1_I*State_VGB(iP_I,i,j,k,iBlock)*Unormal_I(1:nFluid)

  end subroutine do_face_prim
  !============================================================================
  subroutine get_face_x_prim(i, j, k, iBlock, StateLeft_V, StateRight_V)
    !$acc routine seq

    integer, intent(in) :: i, j, k, iBlock
    real,    intent(out):: StateLeft_V(nVar), StateRight_V(nVar)

    integer:: iVar, iGang
    !--------------------------------------------------------------------------
#ifdef OPENACC
    iGang = iBlock
#else
    iGang = 1
#endif

    if(nOrder == 1)then
       StateLeft_V  = Primitive_VGI(:,i-1,j,k,iGang)
       StateRight_V = Primitive_VGI(:,i  ,j,k,iGang)
    else
       ! Do it per variable to reduce memory use
       do iVar = 1, nVar
          ! Single fluid conversion to primitive variables
          call limiter2( &
               Primitive_VGI(iVar,i-2,j,k,iGang), &
               Primitive_VGI(iVar,i-1,j,k,iGang), &
               Primitive_VGI(iVar,  i,j,k,iGang), &
               Primitive_VGI(iVar,i+1,j,k,iGang), &
               StateLeft_V(iVar), StateRight_V(iVar))
       end do
    end if

  end subroutine get_face_x_prim
  !============================================================================
  subroutine get_face_y_prim(i, j, k, iBlock, StateLeft_V, StateRight_V)
    !$acc routine seq

    integer, intent(in) :: i, j, k, iBlock
    real,    intent(out):: StateLeft_V(nVar), StateRight_V(nVar)

    integer:: iVar, iGang
    !--------------------------------------------------------------------------
#ifdef OPENACC
    iGang = iBlock
#else
    iGang = 1
#endif

    if(nOrder == 1)then
       StateLeft_V  = Primitive_VGI(:,i,j-1,k,iGang)
       StateRight_V = Primitive_VGI(:,i,j  ,k,iGang)
    else
       ! Do it per variable to reduce memory use
       do iVar = 1, nVar
          ! Single fluid conversion to primitive variables
          call limiter2( &
               Primitive_VGI(iVar,i,j-2,k,iGang), &
               Primitive_VGI(iVar,i,j-1,k,iGang), &
               Primitive_VGI(iVar,i,j  ,k,iGang), &
               Primitive_VGI(iVar,i,j+1,k,iGang), &
               StateLeft_V(iVar), StateRight_V(iVar))
       end do
    end if

  end subroutine get_face_y_prim
  !============================================================================
  subroutine get_face_z_prim(i, j, k, iBlock, StateLeft_V, StateRight_V)
    !$acc routine seq

    integer, intent(in) :: i, j, k, iBlock
    real,    intent(out):: StateLeft_V(nVar), StateRight_V(nVar)

    integer:: iVar, iGang
    !--------------------------------------------------------------------------
#ifdef OPENACC
    iGang = iBlock
#else
    iGang = 1
#endif

    if(nOrder == 1)then
       StateLeft_V   = Primitive_VGI(:,i,j,k-1,iGang)
       StateRight_V  = Primitive_VGI(:,i,j,k  ,iGang)
    else
       ! Do it per variable to reduce memory use
       do iVar = 1, nVar
          ! Single fluid conversion to primitive variables
          call limiter2( &
               Primitive_VGI(iVar,i,j,k-2,iGang), &
               Primitive_VGI(iVar,i,j,k-1,iGang), &
               Primitive_VGI(iVar,i,j,k  ,iGang), &
               Primitive_VGI(iVar,i,j,k+1,iGang), &
               StateLeft_V(iVar), StateRight_V(iVar))
       end do
    end if

  end subroutine get_face_z_prim
  !============================================================================
end module ModUpdateStateFast
!==============================================================================
