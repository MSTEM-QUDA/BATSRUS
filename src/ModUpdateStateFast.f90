!  Copyright (C) 2002 Regents of the University of Michigan,
!  portions used with permission
!  For more information, see http://csem.engin.umich.edu/tools/swmf

module ModUpdateStateFast

  use ModVarIndexes
  use ModFaceFlux,  ONLY: DoLf
  use ModFaceValue, ONLY: BetaLimiter
  use ModMain, ONLY: iStage, Cfl, Dt, nOrder
  use ModAdvance, ONLY: nFlux, State_VGB, Energy_GBI
!!!  time_BLK, StateOld_VGB, State_VGB, EnergyOld_CBI, Energy_GBI
  use BATL_lib, ONLY: nDim, nI, nJ, nK, &
       nBlock, Unused_B, x_, y_, z_, CellVolume_B, CellFace_DB, &
       test_start, test_stop, iTest, jTest, kTest, iBlockTest
#ifndef OPENACC
  use BATL_lib, ONLY: IsCartesianGrid, CellFace_DFB, FaceNormal_DDFB
#endif
  use ModPhysics, ONLY: Gamma, InvGammaMinus1, GammaMinus1_I
  use ModMain, ONLY: UseB, UseHyperbolicDivb, SpeedHyp
  use ModNumConst, ONLY: cUnit_DD

  implicit none

  private ! except

  public:: update_state_cpu ! optimal for CPU, does not work on GPU
  public:: update_state_gpu ! optimal for GPU but works on CPU too

  logical:: DoTestCell= .false.

contains
  !============================================================================
  subroutine update_state_cpu

    ! optimal for CPU (face value and face flux calculated only once)

    integer:: i, j, k, iBlock

    real:: DtPerDv, Change_V(nFlux)
    real:: Flux_VX(nFlux,nI+1,nJ,nK)
    real:: Flux_VY(nFlux,nI,nJ+1,nK)
    real:: Flux_VZ(nFlux,nI,nJ,nK+1)

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'update_state_cpu'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)

    do iBlock = 1, nBlock
       if(Unused_B(iBlock)) CYCLE

       do k = 1, nK; do j = 1, nJ; do i = 1, nI+1

          DoTestCell = DoTest .and. (i == iTest .or. i == iTest+1) .and. &
               j == jTest .and. k == kTest .and. iBlock == iBlockTest

          call get_flux_x(i, j, k, iBlock, Flux_VX(:,i,j,k))

       end do; end do; end do

       if(nDim > 1)then
          do k = 1, nK; do j = 1, nJ+1; do i = 1, nI

             DoTestCell = DoTest .and. iBlock == iBlockTest .and. i == iTest &
                  .and. (j == jTest .or. j==jTest+1) .and. k == kTest

             call get_flux_y(i, j, k, iBlock, Flux_VY(:,i,j,k))

          end do; end do; end do
       end if

       if(nDim > 2)then
          do k = 1, nK+1; do j = 1, nJ; do i = 1, nI

             DoTestCell = DoTest .and. iBlock == iBlockTest .and. i == iTest &
                  .and. j == jTest .and. (k == kTest .or. k == kTest+1)

             call get_flux_z(i, j, k, iBlock, Flux_VZ(:,i,j,k))

          end do; end do; end do
       end if

       ! Update
       do k = 1, nK; do j = 1, nJ; do i = 1, nI

          Change_V =  Flux_VX(:,i,j,k) - Flux_VX(:,i+1,j,k)
          if(nDim > 1) Change_V = Change_V &
               + Flux_VY(:,i,j,k) - Flux_VY(:,i,j+1,k)
          if(nDim > 2) Change_V = Change_V &
               + Flux_VZ(:,i,j,k) - Flux_VZ(:,i,j,k+1)

          ! Time step divided by cell volume
!!!       DtPerDv = Cfl*time_BLK(i,j,k,iBlock)/CellVolume_GB(i,j,k,iBlock)
          DtPerDv = Dt/CellVolume_B(iBlock)

          ! Update state
          State_VGB(:,i,j,k,iBlock) = State_VGB(:,i,j,k,iBlock) &
               + DtPerDv*Change_V(1:nVar)
          Energy_GBI(i,j,k,iBlock,1) = Energy_GBI(i,j,k,iBlock,1) &
               + DtPerDv*Change_V(nVar+1)

          call set_energy_pressure(i,j,k,iBlock)

          DoTestCell = DoTest .and. i==iTest .and. j==jTest .and. k==kTest &
               .and. iBlock == iBlockTest
          if(DoTestCell)then
             write(*,*)'State_VGB =', State_VGB(:,i,j,k,iBlock)
             write(*,*)'Energy_GBI=', Energy_GBI(i,j,k,iBlock,:)
             write(*,*)'Change_V  =', Change_V
             write(*,*)'DtPerDv   =', DtPerDv
          end if

       enddo; enddo; enddo

    end do

    call test_stop(NameSub, DoTest, iBlock)

  end subroutine update_state_cpu
  !============================================================================
  subroutine get_flux_x(i, j,  k, iBlock, Flux_V)

    integer, intent(in):: i, j, k, iBlock
    real,    intent(out):: Flux_V(nFlux)

    real :: Area, NormalX, NormalY, NormalZ
    real :: StateLeft_V(nVar), StateRight_V(nVar)
    !--------------------------------------------------------------------------
    call get_normal(1, i, j, k, iBlock, NormalX, NormalY, NormalZ, Area)

    call get_face_x(i, j, k, iBlock, StateLeft_V, StateRight_V)

    call get_numerical_flux(NormalX, NormalY, NormalZ, Area, &
         StateLeft_V, StateRight_V, Flux_V)

  end subroutine get_flux_x
  !============================================================================
  subroutine get_flux_y(i, j, k, iBlock, Flux_V)

    integer, intent(in):: i, j, k, iBlock
    real,    intent(out):: Flux_V(nFlux)

    real :: Area, NormalX, NormalY, NormalZ
    real :: StateLeft_V(nVar), StateRight_V(nVar)
    !--------------------------------------------------------------------------
    call get_normal(2, i, j, k, iBlock, NormalX, NormalY, NormalZ, Area)

    call get_face_y(i, j, k, iBlock, StateLeft_V, StateRight_V)

    call get_numerical_flux(NormalX, NormalY, NormalZ, Area, &
         StateLeft_V, StateRight_V, Flux_V)

  end subroutine get_flux_y
  !============================================================================
  subroutine get_flux_z(i, j, k, iBlock, Flux_V)

    integer, intent(in):: i, j, k, iBlock
    real,    intent(out):: Flux_V(nFlux)

    real :: Area, NormalX, NormalY, NormalZ
    real :: StateLeft_V(nVar), StateRight_V(nVar)
    !--------------------------------------------------------------------------
    call get_normal(3, i, j, k, iBlock, NormalX, NormalY, NormalZ, Area)

    call get_face_z(i, j, k, iBlock, StateLeft_V, StateRight_V)

    call get_numerical_flux(NormalX, NormalY, NormalZ, Area, &
         StateLeft_V, StateRight_V, Flux_V)

  end subroutine get_flux_z
  !============================================================================
  subroutine update_state_gpu

    ! optimal for GPU, but also works with CPU

    integer:: i, j, k, iBlock

    real:: Change_V(nFlux), Change_VC(nFlux,nI,nJ,nK), DtPerDv
    !$acc declare create (Change_V, Change_VC, DtPerDv)

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'update_state_gpu'
    !--------------------------------------------------------------------------
#ifndef OPENACC
    call test_start(NameSub, DoTest)
#endif

    !$acc parallel
    !$acc loop gang private(Change_VC) independent
    do iBlock = 1, nBlock
       if(Unused_B(iBlock)) CYCLE

       !$acc loop vector collapse(3) private(Change_V) independent
       do k = 1, nK; do j = 1, nJ; do i = 1, nI

#ifndef OPENACC
          DoTestCell = DoTest .and. i==iTest .and. j==jTest .and. k==kTest &
               .and. iBlock == iBlockTest
#endif

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

       !$acc loop vector collapse(3) private(DtPerDv) independent
       do k = 1, nK; do j = 1, nJ; do i = 1, nI

          ! Time step divided by cell volume
!!!       DtPerDv = Cfl*time_BLK(i,j,k,iBlock)/CellVolume_GB(i,j,k,iBlock)
          DtPerDv = Dt/CellVolume_B(iBlock)

          ! Update state
          State_VGB(:,i,j,k,iBlock) = State_VGB(:,i,j,k,iBlock) &
               + DtPerDv*Change_VC(1:nVar,i,j,k)
          Energy_GBI(i,j,k,iBlock,1) = Energy_GBI(i,j,k,iBlock,1) &
               + DtPerDv*Change_VC(nVar+1,i,j,k)

          call set_energy_pressure(i,j,k,iBlock)

#ifndef OPENACC
          DoTestCell = DoTest .and. i==iTest .and. j==jTest .and. k==kTest &
               .and. iBlock == iBlockTest
          if(DoTestCell)then
             write(*,*)'State_VGB =', State_VGB(:,i,j,k,iBlock)
             write(*,*)'Energy_GBI=', Energy_GBI(i,j,k,iBlock,:)
             write(*,*)'Change_V  =', Change_VC(:,i,j,k)
             write(*,*)'DtPerDv   =', DtPerDv
          end if
#endif

       enddo; enddo; enddo

    end do
    !$acc end parallel

#ifndef OPENACC
    call test_stop(NameSub, DoTest, iBlock)
#endif
  end subroutine update_state_gpu
  !============================================================================

  subroutine do_face(iFace, i, j, k, iBlock, Change_V)
    !$acc routine seq

    integer, intent(in):: iFace, i, j, k, iBlock
    real, intent(inout):: Change_V(nFlux)

    real :: Area, NormalX, NormalY, NormalZ
    real :: StateLeft_V(nVar), StateRight_V(nVar), Flux_V(nFlux)
    !--------------------------------------------------------------------------
    select case(iFace)
    case(1)
       call get_normal(1, i, j, k, iBlock, NormalX, NormalY, NormalZ, Area)
       call get_face_x(   i, j, k, iBlock, StateLeft_V, StateRight_V)
    case(2)
       call get_normal(1, i+1, j, k, iBlock, NormalX, NormalY, NormalZ, Area)
       Area = -Area
       call get_face_x(   i+1, j, k, iBlock, StateLeft_V, StateRight_V)
    case(3)
       call get_normal(2, i, j, k, iBlock, NormalX, NormalY, NormalZ, Area)
       call get_face_y(   i, j, k, iBlock, StateLeft_V, StateRight_V)
    case(4)
       call get_normal(2, i, j+1, k, iBlock, NormalX, NormalY, NormalZ, Area)
       Area = -Area
       call get_face_y(   i, j+1, k, iBlock, StateLeft_V, StateRight_V)
    case(5)
       call get_normal(3, i, j, k, iBlock, NormalX, NormalY, NormalZ, Area)
       call get_face_z(   i, j, k, iBlock, StateLeft_V, StateRight_V)
    case(6)
       call get_normal(3, i, j, k+1, iBlock, NormalX, NormalY, NormalZ, Area)
       Area = -Area
       call get_face_z(   i, j, k+1, iBlock, StateLeft_V, StateRight_V)
    end select

    call get_numerical_flux(NormalX, NormalY, NormalZ, &
         Area,  StateLeft_V, StateRight_V, Flux_V)

    Change_V = Change_V + Flux_V

  end subroutine do_face
  !============================================================================
  subroutine get_physical_flux(State_V, NormalX, NormalY, NormalZ, &
       StateCons_V, Flux_V)
    !$acc routine seq

    real, intent(in) :: State_V(nVar)      ! primitive state vector
    real, intent(in) :: NormalX, NormalY, NormalZ ! face normal
    real, intent(out):: StateCons_V(nFlux) ! conservative state vector
    real, intent(out):: Flux_V(nFlux)      ! conservative flux

    real:: Rho, Ux, Uy, Uz, Bx, By, Bz, Hyp, p, e, Un, Bn, pB, pTot
    !--------------------------------------------------------------------------
    Rho = State_V(Rho_)
    Ux  = State_V(Ux_)
    Uy  = State_V(Uy_)
    Uz  = State_V(Uz_)
    Bx  = State_V(Bx_)
    By  = State_V(By_)
    Bz  = State_V(Bz_)
    if(Hyp_ > 1) Hyp = State_V(Hyp_)
    p   = State_V(p_)

    ! Convenient variables
    Un  = Ux*NormalX + Uy*NormalY + Uz*NormalZ
    Bn  = Bx*NormalX + By*NormalY + Bz*NormalZ
    pB  = 0.5*(Bx**2 + By**2 + Bz**2)

    ! Hydro energy density
    e   = InvGammaMinus1*p + 0.5*Rho*(Ux**2 + Uy**2 + Uz**2)

    ! Conservative state for the Rusanov solver
    StateCons_V(Rho_)    = Rho
    StateCons_V(RhoUx_)  = Rho*Ux
    StateCons_V(RhoUy_)  = Rho*Uy
    StateCons_V(RhoUz_)  = Rho*Uz
    StateCons_V(Bx_)     = Bx
    StateCons_V(By_)     = By
    StateCons_V(Bz_)     = Bz
    if(Hyp_ > 1) StateCons_V(Hyp_) = Hyp
    StateCons_V(p_)      = p
    StateCons_V(Energy_) = e + pB  ! Add magnetic energy density

    ! Physical flux
    pTot = p + pB
    Flux_V(Rho_)    = Rho*Un
    Flux_V(RhoUx_)  = Un*Rho*Ux - Bn*Bx + NormalX*pTot
    Flux_V(RhoUy_)  = Un*Rho*Uy - Bn*By + NormalY*pTot
    Flux_V(RhoUz_)  = Un*Rho*Uz - Bn*Bz + NormalZ*pTot
    if(Hyp_ > 1)then
       Flux_V(Bx_)  =  Un*Bx - Ux*Bn + NormalX*SpeedHyp*Hyp
       Flux_V(By_)  =  Un*By - Uy*Bn + NormalY*SpeedHyp*Hyp
       Flux_V(Bz_)  =  Un*Bz - Uz*Bn + NormalZ*SpeedHyp*Hyp
       Flux_V(Hyp_) =  SpeedHyp*Bn
    else
       Flux_V(Bx_)  =  Un*Bx - Ux*Bn
       Flux_V(By_)  =  Un*By - Uy*Bn
       Flux_V(Bz_)  =  Un*Bz - Uz*Bn
    end if
    Flux_V(p_)      =  Un*p
    Flux_V(Energy_) =  Un*(e + p) &
         + Flux_V(Bx_)*Bx + Flux_V(By_)*By + Flux_V(Bz_)*Bz ! Poynting flux

  end subroutine get_physical_flux
  !============================================================================
  subroutine get_speed_max(State_V, NormalX, NormalY, NormalZ, &
       Un, Cmax, Cleft, Cright)
    !$acc routine seq

    ! Using primitive variable State_V and normal direction get
    ! normal velocity and wave speeds.

    real, intent(in) :: State_V(nVar), NormalX, NormalY, NormalZ
    real, intent(out):: Un              ! normal velocity (signed)
    real, intent(out), optional:: Cmax  ! maximum speed (positive)
    real, intent(out), optional:: Cleft ! fastest left wave (usually negative)
    real, intent(out), optional:: Cright! fastest right wave (usually positive)

    real:: InvRho, p, Bx, By, Bz, Bn, B2
    real:: Sound2, Alfven2, Alfven2Normal, Fast2, Discr, Fast

    !--------------------------------------------------------------------------
    InvRho = 1.0/State_V(Rho_)
    Bx  = State_V(Bx_)
    By  = State_V(By_)
    Bz  = State_V(Bz_)
    p   = State_V(p_)
    Bn  = Bx*NormalX + By*NormalY + Bz*NormalZ
    B2  = Bx**2 + By**2 + Bz**2

    Sound2        = InvRho*p*Gamma
    Alfven2       = InvRho*B2
    Alfven2Normal = InvRho*Bn**2
    Fast2 = Sound2 + Alfven2
    Discr = sqrt(max(0.0, Fast2**2 - 4*Sound2*Alfven2Normal))
    Fast  = sqrt( 0.5*(Fast2 + Discr) )

    Un = State_V(Ux_)*NormalX + State_V(Uy_)*NormalY + State_V(Uz_)*NormalZ
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
            ' Sound2, Alfven2       =', Sound2, Alfven2
       write(*,*) &
            ' FullBn, Alfven2Normal =', Bn, Alfven2Normal
       write(*,*) &
            ' FullBx, FullBy, FullBz=', Bx, By, Bz
    end if
#endif

  end subroutine get_speed_max
  !============================================================================
  subroutine get_normal(iDir, i, j, k, iBlock, NormalX, NormalY, NormalZ, Area)
    !$acc routine seq
    integer, intent(in) :: i, j, k, iBlock, iDir
    real,    intent(out):: NormalX, NormalY, NormalZ, Area
#ifndef OPENACC
    !--------------------------------------------------------------------------
    if(IsCartesianGrid)then
#endif
       Area = CellFace_DB(iDir,iBlock)
       NormalX = cUnit_DD(iDir,1)
       NormalY = cUnit_DD(iDir,2)
       NormalZ = cUnit_DD(iDir,3)
#ifndef OPENACC
    else
       Area = CellFace_DFB(iDir,i,j,k,iBlock)
       if(Area == 0.0)then
          NormalX = 1.0; NormalY = 0.0; NormalZ = 0.0
          RETURN
       end if
       NormalX = FaceNormal_DDFB(1,1,i,j,k,iBlock)/Area
       NormalY = FaceNormal_DDFB(2,1,i,j,k,iBlock)/Area
       NormalZ = FaceNormal_DDFB(3,1,i,j,k,iBlock)/Area
    end if
#endif

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
  subroutine get_numerical_flux(NormalX, NormalY, NormalZ, &
       Area,  StateLeft_V, StateRight_V, Flux_V)
    !$acc routine seq

    real, intent(in)   :: NormalX, NormalY, NormalZ, Area
    real, intent(inout):: StateLeft_V(nVar), StateRight_V(nVar)
    real, intent(out)  :: Flux_V(nFlux)

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

       call get_speed_max(State_V, NormalX, NormalY, NormalZ, &
            Un, Cmax)
       call get_physical_flux(StateLeft_V, NormalX, NormalY, NormalZ, &
            StateLeftCons_V, FluxLeft_V)
       call get_physical_flux(StateRight_V, NormalX, NormalY, NormalZ, &
            StateRightCons_V, FluxRight_V)

       ! Lax-Friedrichs flux
       Flux_V = Area*0.5*((FluxLeft_V + FluxRight_V) &
            +             Cmax*(StateLeftCons_V - StateRightCons_V))
    else
       ! Linde scheme
       if(UseB)then
          ! Sokolov's algorithm
          ! Calculate the jump in the normal magnetic field vector
          DiffBn = 0.5* &
               ( NormalX*(StateRight_V(Bx_) - StateLeft_V(Bx_)) &
               + NormalY*(StateRight_V(By_) - StateLeft_V(By_)) &
               + NormalZ*(StateRight_V(Bz_) - StateLeft_V(Bz_)) )

          ! Remove the jump in the normal magnetic field
          StateLeft_V(Bx_)  =  StateLeft_V(Bx_)  + DiffBn*NormalX
          StateLeft_V(By_)  =  StateLeft_V(By_)  + DiffBn*NormalY
          StateLeft_V(Bz_)  =  StateLeft_V(Bz_)  + DiffBn*NormalZ
          StateRight_V(Bx_) =  StateRight_V(Bx_) - DiffBn*NormalX
          StateRight_V(By_) =  StateRight_V(By_) - DiffBn*NormalY
          StateRight_V(Bz_) =  StateRight_V(Bz_) - DiffBn*NormalZ

       end if

       ! This implementation is for non-relativistic MHD only
       ! Left speed of left state
       call get_speed_max(StateLeft_V, NormalX, NormalY, NormalZ, &
            Un, Cleft=Cleft)

       ! Right speed of right state
       call get_speed_max(StateRight_V, NormalX, NormalY, NormalZ, &
            Un, Cright=Cright)

       ! Speeds of average state
       State_V = 0.5*(StateLeft_V + StateRight_V)
       call get_speed_max(State_V, NormalX, NormalY, NormalZ, &
            Un, Cmax, CleftAverage, CrightAverage)

       ! Limited left and right speeds
       Cleft  = min(0.0, Cleft,  CleftAverage)
       Cright = max(0.0, Cright, CrightAverage)

       ! Physical flux
       call get_physical_flux(StateLeft_V, NormalX, NormalY, NormalZ, &
            StateLeftCons_V, FluxLeft_V)
       call get_physical_flux(StateRight_V, NormalX, NormalY, NormalZ, &
            StateRightCons_V, FluxRight_V)

       CMulti = Cright*Cleft
       CInvDiff = 1./(Cright - Cleft)       
       ! HLLE flux
       Flux_V = &
            ( Cright*FluxLeft_V - Cleft*FluxRight_V  &
            + CMulti*(StateRightCons_V - StateLeftCons_V) ) &
            *CInvDiff

       if(UseB)then
          if(Hyp_ > 1 .and. UseHyperbolicDivb) then
             ! Overwrite the flux of the Hyp field with the Lax-Friedrichs flux
             Cmax = max(Cmax, SpeedHyp)
             Flux_V(Hyp_) = 0.5*(FluxLeft_V(Hyp_) + FluxRight_V(Hyp_) &
                  - Cmax*(StateRight_V(Hyp_) - StateLeft_V(Hyp_)))
          end if

          ! Linde scheme: use Lax-Friedrichs flux for Bn
          ! The original jump was removed, now we add it with Cmax
          Flux_V(Bx_) = Flux_V(Bx_) - Cmax*DiffBn*NormalX
          Flux_V(By_) = Flux_V(By_) - Cmax*DiffBn*NormalY
          Flux_V(Bz_) = Flux_V(Bz_) - Cmax*DiffBn*NormalZ

          ! Fix the energy diffusion
          ! The energy jump is also modified by
          ! 1/2(Br^2 - Bl^2) = 1/2(Br-Bl)*(Br+Bl)
          Flux_V(Energy_) = Flux_V(Energy_) - Cmax*0.5*DiffBn* &
               ( NormalX*(StateRight_V(Bx_) + StateLeft_V(Bx_)) &
               + NormalY*(StateRight_V(By_) + StateLeft_V(By_)) &
               + NormalZ*(StateRight_V(Bz_) + StateLeft_V(Bz_)) )
       end if

       Flux_V = Area*Flux_V

    end if

  end subroutine get_numerical_flux
  !============================================================================
  subroutine set_energy_pressure(i, j, k, iBlock)
    !$acc routine seq

    ! Calculate energy from pressure or vice-versa

    integer, intent(in):: i, j, k, iBlock
    !--------------------------------------------------------------------------
    ! Calculate pressure from energy
    State_VGB(p_,i,j,k,iBlock) = &
         GammaMinus1_I(1)*( Energy_GBI(i,j,k,iBlock,1) - &
         0.5*( &
         ( State_VGB(RhoUx_,i,j,k,iBlock)**2 &
         + State_VGB(RhoUy_,i,j,k,iBlock)**2 &
         + State_VGB(RhoUz_,i,j,k,iBlock)**2 &
         )/State_VGB(Rho_,i,j,k,iBlock)      &
         + State_VGB(Bx_,i,j,k,iBlock)**2    &
         + State_VGB(By_,i,j,k,iBlock)**2    &
         + State_VGB(Bz_,i,j,k,iBlock)**2    &
         )          )
  end subroutine set_energy_pressure
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
  real function minmodhalf(a, b)
    !$acc routine seq
    real, intent(in):: a, b
    !--------------------------------------------------------------------------
    minmodhalf = (sign(0.25, a) + sign(0.25, b))*min(abs(a), abs(b))
  end function minmodhalf
  !============================================================================
  subroutine limiter2(Var1, Var2, Var3, Var4, VarLeft, VarRight)
    !$acc routine seq

    ! Second order limiter on a 4 point stencil
    real, intent(in) :: Var1, Var2, Var3, Var4  ! cell center values at i=1..4
    real, intent(out):: VarLeft, VarRight       ! face values at i=2.5
    !--------------------------------------------------------------------------
!    if(BetaLimiter == 1.0)then
       ! minmod limiter
       VarLeft  = Var2 + minmodhalf(Var2-Var1, Var3-Var2)
       VarRight = Var3 - minmodhalf(Var3-Var2, Var4-Var3)
!    else
!       ! mc3 limiter
!       
!    end if
  end subroutine limiter2
  !============================================================================

end module ModUpdateStateFast
!==============================================================================
