!  Copyright (C) 2002 Regents of the University of Michigan, 
!  portions used with permission 
!  For more information, see http://csem.engin.umich.edu/tools/swmf

module ModSemiImplicit

  use ModSemiImplVar
  use ModProcMH,   ONLY: iProc, iComm
  use ModImplicit, ONLY: LinearSolverParamType, nStencil

  implicit none
  save

  private ! except

  public:: read_semi_impl_param  ! Read parameters
  public:: init_mod_semi_impl    ! Initialize variables
  public:: advance_semi_impl     ! Advance semi implicit operator

  ! The index of the variable currently being solved for
  integer:: iVarSemi

  ! Total number of semi-implicit unknowns
  integer:: nSemi

  ! These arrays with *Semi_* and *SemiAll_* are indexed by compact iBlockSemi
  ! and have a single ghost cell at most.
  ! The SemiAll_ variables are indexed from 1..nVarSemiAll
  real, allocatable:: DconsDsemiAll_VCB(:,:,:,:,:) ! dCons/dSemi derivatives
  real, allocatable:: SemiAll_VGB(:,:,:,:,:)       ! Semi-implicit vars
  real, allocatable:: NewSemiAll_VCB(:,:,:,:,:)    ! Updated semi-impl var.
  real, allocatable:: ResSemi_VCB(:,:,:,:,:)       ! Result of Matrix(Semi)
  real, allocatable:: JacSemi_VVCIB(:,:,:,:,:,:,:) ! Jacobian/preconditioner

  ! This array is indexed with normal block index and has nG ghost cells
  real, allocatable:: SemiState_VGB(:,:,:,:,:)  ! Semi-implicit vars

  ! Linear arrays for RHS, unknowns, pointwise Jacobi preconditioner
  real, allocatable:: Rhs_I(:), x_I(:), JacobiPrec_I(:)

  ! How often reinitialize the HYPRE preconditioner
  integer:: DnInitHypreAmg = 1

  ! Parameters for the semi-implicit linear solver. Set defaults.
  type(LinearSolverParamType):: SemiParam = LinearSolverParamType( &
       .true., 'left', 'BILU', 1.0, .true., 'CG', 1e-5, 200, 200, .false.)

contains
  !============================================================================
  subroutine read_semi_impl_param(NameCommand)

    use ModImplicit, ONLY: UseNoOverlap

    use ModReadParam,     ONLY: read_var
    use ModLinearSolver,  ONLY: &
         Jacobi_, BlockJacobi_, GaussSeidel_, Dilu_, Bilu_

    character(len=*), intent(in) :: NameCommand

    integer :: i
    character(len=*), parameter:: NameSub = 'read_semi_impl_param'
    !--------------------------------------------------------------------------
    select case(NameCommand)
    case('#SEMIIMPLICIT', '#SEMIIMPL')
       call read_var('UseSemiImplicit', UseSemiImplicit)
       if(UseSemiImplicit)then
          call read_var('TypeSemiImplicit', TypeSemiImplicit)
          i = index(TypeSemiImplicit,'split')
          UseSplitSemiImplicit = i > 0
          if(UseSplitSemiImplicit) &
               TypeSemiImplicit = TypeSemiImplicit(1:i-1)
       end if

    case("#SEMIPRECOND")
       call read_var('DoPrecond',   SemiParam%DoPrecond)
       call read_var('TypePrecond', SemiParam%TypePrecond, IsUpperCase=.true.)
       select case(SemiParam%TypePrecond)
       case('HYPRE')
          UseNoOverlap = .false.
       case('JACOBI')
           SemiParam%PrecondParam = Jacobi_
       case('BLOCKJACOBI')
           SemiParam%PrecondParam = BlockJacobi_
       case('GS')
           SemiParam%PrecondParam = GaussSeidel_
       case('DILU')
           SemiParam%PrecondParam = Dilu_
       case('BILU')
           SemiParam%PrecondParam = Bilu_
       case('MBILU')
          call read_var('GustafssonPar', SemiParam%PrecondParam)
          SemiParam%PrecondParam = -SemiParam%PrecondParam
       case default
          call stop_mpi(NameSub//' invalid TypePrecond='// &
               SemiParam%TypePrecond)
       end select
    case("#SEMIKRYLOV")
       call read_var('TypeKrylov', SemiParam%TypeKrylov, IsUpperCase=.true.)
       call read_var('KrylovErrorMax', SemiParam%KrylovErrorMax)
       call read_var('MaxKrylovMatvec', SemiParam%MaxKrylovMatvec)
       SemiParam%nKrylovVector = SemiParam%MaxKrylovMatvec

    case('#SEMIKRYLOVSIZE')
       call read_var('nKrylovVector', SemiParam%nKrylovVector)
    case default
       call stop_mpi(NameSub//' invalid NameCommand='//NameCommand)
    end select

  end subroutine read_semi_impl_param
  !============================================================================
  subroutine init_mod_semi_impl

    use ModLinearSolver, ONLY: bilu_
    use BATL_lib, ONLY: MaxDim, nI, nJ, nK, nIJK, j0_, nJp1_, k0_, nKp1_, &
         MinI, MaxI, MinJ, MaxJ, MinK, MaxK, MaxBlock
    use ModVarIndexes, ONLY: nWave

    character(len=*), parameter:: NameSub = 'init_mod_semi_impl'
    !------------------------------------------------------------------------
    if(.not.allocated(iBlockFromSemi_I)) allocate(iBlockFromSemi_I(MaxBlock))

    select case(TypeSemiImplicit)
    case('radiation')
       if(nWave == 1 .or. UseSplitSemiImplicit)then
          ! Radiative transfer with point implicit temperature: I_w
          nVarSemiAll = nWave
       else
          ! Radiative transfer: (electron) temperature and waves
          nVarSemiAll = 1 + nWave
       end if
    case('cond', 'parcond')
       ! Heat conduction: T
       nVarSemiAll = 1
    case('radcond')
       ! Radiative transfer and heat conduction: I_w and T
       nVarSemiAll = nWave + 1
    case('resistivity')
       ! (Hall) resistivity: magnetic field
       nVarSemiAll = MaxDim
    case default
       call stop_mpi(NameSub//': nVarSemiAll unknown for'//TypeSemiImplicit)
    end select

    if(UseSplitSemiImplicit)then
       ! Split semi-implicit scheme solves 1 implicit variable at a time
       nVarSemi = 1
    else
       ! Unsplit (semi-)implicit scheme solves all impl. variables together
       nVarSemi = nVarSemiAll
    end if
    ! Set range of (semi-)implicit variables for unsplit scheme.
    ! For split scheme this will be overwritten.
    iVarSemiMin = 1
    iVarSemiMax = nVarSemi

    ! Fix preconditioner type from DILU to BILU for a single variable
    ! because BILU is optimized for scalar equation.
    if(nVarSemi == 1 .and. SemiParam%TypePrecond == 'DILU')then
       SemiParam%TypePrecond  = 'BILU'
       SemiParam%PrecondParam = Bilu_
    end if

    if(nVarSemi > 1 .and. SemiParam%TypePrecond == 'HYPRE' .and. iProc==0) &
         call stop_mpi( &
         'HYPRE preconditioner requires split semi-implicit scheme!')

    allocate(SemiAll_VGB(nVarSemiAll,0:nI+1,j0_:nJp1_,k0_:nKp1_,MaxBlock))
    allocate(NewSemiAll_VCB(nVarSemiAll,nI,nJ,nK,MaxBlock))
    allocate(DconsDsemiAll_VCB(nVarSemiAll,nI,nJ,nK,MaxBlock))

    allocate(SemiState_VGB(nVarSemi,MinI:MaxI,MinJ:MaxJ,MinK:MaxK,MaxBlock))
    allocate(ResSemi_VCB(nVarSemi,nI,nJ,nK,MaxBlock))
    allocate(JacSemi_VVCIB(nVarSemi,nVarSemi,nI,nJ,nK,nStencil,MaxBlock))

    ! Variables for the flux correction
    if(  TypeSemiImplicit == 'parcond' .or. &
         TypeSemiImplicit == 'resistivity' .or. UseAccurateRadiation)then
       allocate( &
            FluxImpl_VXB(nVarSemi,nJ,nK,2,MaxBlock), &
            FluxImpl_VYB(nVarSemi,nI,nK,2,MaxBlock), &
            FluxImpl_VZB(nVarSemi,nI,nJ,2,MaxBlock) )
       FluxImpl_VXB = 0.0
       FluxImpl_VYB = 0.0
       FluxImpl_VZB = 0.0
    end if

    ! Linear arrays
    allocate(Rhs_I(nVarSemi*nIJK*MaxBlock))
    allocate(x_I(nVarSemi*nIJK*MaxBlock))
    if(SemiParam%TypePrecond == 'JACOBI')then
       allocate(JacobiPrec_I(nVarSemi*nIJK*MaxBlock))
    else
       allocate(JacobiPrec_I(1))
    end if

  end subroutine init_mod_semi_impl
  !============================================================================
  subroutine advance_semi_impl

    ! Advance semi-implicit terms

    use ModMain, ONLY: NameThisComp, &
         iTest, jTest, kTest, BlkTest, ProcTest, VarTest
    use ModAdvance, ONLY: DoFixAxis
    use ModGeometry, ONLY: true_cell
    use ModImplHypre, ONLY: hypre_initialize
    use ModMessagePass, ONLY: exchange_messages
    use BATL_lib, ONLY: nI, nJ, nK, nIJK, nBlock, Unused_B

    use ModImplicit, ONLY: solve_implicit

    use ModRadDiffusion,   ONLY: &
         get_impl_rad_diff_state, set_rad_diff_range, update_impl_rad_diff
    use ModHeatConduction, ONLY: &
         get_impl_heat_cond_state, update_impl_heat_cond
    use ModResistivity,    ONLY: &
         get_impl_resistivity_state, update_impl_resistivity

    integer :: iBlockSemi, iBlock, iError, i, j, k, iVar, n

    logical :: DoTest, DoTestMe, DoTestKrylov, DoTestKrylovMe

    character(len=20) :: NameSub = 'MH_advance_semi_impl'
    !--------------------------------------------------------------------------
    NameSub(1:2) = NameThisComp
    call set_oktest(NameSub, DoTest, DoTestMe) 
    if(DoTestMe) write(*,*)NameSub,' starting'

    ! All used blocks are solved for with the semi-implicit scheme
    nBlockSemi = 0
    do iBlock = 1, nBlock
       if(Unused_B(iBlock)) CYCLE
       nBlockSemi = nBlockSemi + 1
       iBlockFromSemi_I(nBlockSemi) = iBlock
    end do

    ! Total number of semi-implicit unknowns
    nSemi = nBlockSemi*nVarSemi*nIJK

    ! Get current state and dCons/dSemi derivatives
    DconsDsemiAll_VCB(:,:,:,:,1:nBlockSemi) = 1.0
    select case(TypeSemiImplicit)
    case('radiation', 'radcond', 'cond')
       call get_impl_rad_diff_state(SemiAll_VGB, DconsDsemiAll_VCB)
    case('parcond')
       call get_impl_heat_cond_state(SemiAll_VGB, DconsDsemiAll_VCB)
    case('resistivity')
       call get_impl_resistivity_state(SemiAll_VGB)
    case default
       call stop_mpi(NameSub//': no get_impl_state implemented for' &
            //TypeSemiImplicit)
    end select

    ! Re-initialize HYPRE preconditioner
    if(SemiParam%TypePrecond == 'HYPRE') call hypre_initialize

    ! For nVarSemi = 1,  loop through all semi-implicit variables one-by-one
    ! For nVarSemi = nVarSemiAll, do all (semi-)implicit variables together
    do iVarSemi = 1, nVarSemiAll, nVarSemi

       if(UseSplitSemiImplicit)then
          iVarSemiMin = iVarSemi
          iVarSemiMax = iVarSemi
          call set_rad_diff_range(iVarSemi)
       end if

       ! Initialize right hand side and dw
       call get_semi_impl_rhs(SemiAll_VGB, Rhs_I)

       ! Calculate Jacobian matrix if required
       if(SemiParam%DoPrecond)then
          call timing_start('impl_jacobian')
          call get_semi_impl_jacobian
          call timing_stop('impl_jacobian')
       endif

       ! solve implicit system
       call solve_implicit(SemiParam, semi_impl_matvec, &
            nVarSemi, nBlockSemi, nSemi, Rhs_I, x_I, &
            JacSemi_VVCIB, JacobiPrec_I, cg_precond, iError)

       ! NewSemiAll_VCB = SemiAll_VGB + x
       n=0
       do iBlockSemi = 1, nBlockSemi; do k=1,nK; do j=1,nJ; do i=1,nI
          do iVar = iVarSemiMin, iVarSemiMax
             n = n + 1
             if(true_cell(i,j,k,iBlockFromSemi_I(iBlockSemi)))then
                NewSemiAll_VCB(iVar,i,j,k,iBlockSemi) = &
                     SemiAll_VGB(iVar,i,j,k,iBlockSemi) + x_I(n)
             else
                NewSemiAll_VCB(iVar,i,j,k,iBlockSemi) = &
                     SemiAll_VGB(iVar,i,j,k,iBlockSemi)
             end if
          enddo
       enddo; enddo; enddo; enddo

    end do ! Splitting

    ! Put back semi-implicit result into the explicit code
    do iBlockSemi = 1, nBlockSemi
       iBlock = iBlockFromSemi_I(iBlockSemi)
       select case(TypeSemiImplicit)
       case('radiation', 'radcond', 'cond')
          call update_impl_rad_diff(iBlock, iBlockSemi, &
               NewSemiAll_VCB(:,:,:,:,iBlockSemi), &
               SemiAll_VGB(:,1:nI,1:nJ,1:nK,iBlockSemi), &
               DconsDsemiAll_VCB(:,:,:,:,iBlockSemi))
       case('parcond')
          call update_impl_heat_cond(iBlock, iBlockSemi, &
               NewSemiAll_VCB(:,:,:,:,iBlockSemi), &
               SemiAll_VGB(:,1:nI,1:nJ,1:nK,iBlockSemi), &
               DconsDsemiAll_VCB(:,:,:,:,iBlockSemi))
       case('resistivity')
          call update_impl_resistivity(iBlock, &
               NewSemiAll_VCB(:,:,:,:,iBlockSemi))
       case default
          call stop_mpi(NameSub//': no update_impl implemented for' &
               //TypeSemiImplicit)
       end select
    end do

    if(DoFixAxis)call fix_axis_cells

    ! Exchange messages, so ghost cells of all blocks are updated
    call exchange_messages

  end subroutine advance_semi_impl

  !============================================================================
  subroutine get_semi_impl_rhs(SemiAll_VGB, RhsSemi_VCB)

    use ModGeometry,       ONLY: far_field_BCs_BLK
    use ModLinearSolver,   ONLY: UsePDotADotP
    use ModSize,           ONLY: nI, nJ, nK
    use ModRadDiffusion,   ONLY: get_rad_diffusion_rhs
    use ModHeatConduction, ONLY: get_heat_conduction_rhs
    use ModResistivity,    ONLY: get_resistivity_rhs
    use ModCellBoundary,   ONLY: set_cell_boundary
    use BATL_lib,          ONLY: message_pass_cell, message_pass_face, &
         apply_flux_correction_block, CellVolume_GB
    use BATL_size,         ONLY: j0_, nJp1_, k0_, nKp1_

    real, intent(in) :: &
         SemiAll_VGB(nVarSemiAll,0:nI+1,j0_:nJp1_,k0_:nKp1_,nBlockSemi)
    real, intent(out):: &
         RhsSemi_VCB(nVarSemi,nI,nJ,nK,nBlockSemi)

    integer :: iBlockSemi, iBlock, i, j, k

    character(len=*), parameter:: NameSub = 'get_semi_impl_rhs'
    !------------------------------------------------------------------------
    ! Fill in SemiState so it can be message passed
    do iBlockSemi = 1, nBlockSemi
       iBlock = iBlockFromSemi_I(iBlockSemi)
       do k = 1, nK; do j = 1, nJ; do i = 1, nI
          SemiState_VGB(:,i,j,k,iBlock) = &
               SemiAll_VGB(iVarSemiMin:iVarSemiMax,i,j,k,iBlockSemi)
       end do; end do; end do
    end do

    ! Message pass to fill in ghost cells 
    select case(TypeSemiImplicit)
    case('radiation', 'radcond', 'cond')
       if(UseAccurateRadiation)then
          call message_pass_cell(nVarSemi, SemiState_VGB, nWidthIn=2, &
               nProlongOrderIn=1, nCoarseLayerIn=2, DoRestrictFaceIn = .true.)
       else
          call message_pass_cell(nVarSemi, SemiState_VGB, nWidthIn=1, &
               nProlongOrderIn=1, DoSendCornerIn=.false., &
               DoRestrictFaceIn=.true.)
       end if
    case('parcond','resistivity')
       call message_pass_cell(nVarSemi, SemiState_VGB, nWidthIn=2, &
            nProlongOrderIn=1, nCoarseLayerIn=2, DoRestrictFaceIn = .true.)
    case default
       call stop_mpi(NameSub//': no get_rhs message_pass implemented for' &
            //TypeSemiImplicit)
    end select

    do iBlockSemi = 1, nBlockSemi
       iBlock = iBlockFromSemi_I(iBlockSemi)

       ! Apply boundary conditions (1 layer of outer ghost cells)
       if(far_field_BCs_BLK(iBlock))&
            call set_cell_boundary(1, iBlock, nVarSemi, &
            SemiState_VGB(:,:,:,:,iBlock), iBlockSemi, IsLinear=.false.)

       select case(TypeSemiImplicit)
       case('radiation', 'radcond', 'cond')
          UsePDotADotP = .false.
          call get_rad_diffusion_rhs(iBlock, SemiState_VGB(:,:,:,:,iBlock), &
               RhsSemi_VCB(:,:,:,:,iBlockSemi), IsLinear=.false.)
       case('parcond')
          call get_heat_conduction_rhs(iBlock, SemiState_VGB(:,:,:,:,iBlock), &
               RhsSemi_VCB(:,:,:,:,iBlockSemi), IsLinear=.false.)
       case('resistivity')
          call get_resistivity_rhs(iBlock, SemiState_VGB(:,:,:,:,iBlock), &
               RhsSemi_VCB(:,:,:,:,iBlockSemi), IsLinear=.false.)
       case default
          call stop_mpi(NameSub//': no get_rhs implemented for' &
               //TypeSemiImplicit)
       end select
    end do

    if(TypeSemiImplicit == 'parcond' .or. TypeSemiImplicit == 'resistivity' &
         .or. UseAccurateRadiation)then
       call message_pass_face(nVarSemi, &
            FluxImpl_VXB, FluxImpl_VYB, FluxImpl_VZB)

       do iBlockSemi = 1, nBlockSemi
          iBlock = iBlockFromSemi_I(iBlockSemi)

          ! there are no ghost cells for RhsSemi_VCB
          call apply_flux_correction_block(iBlock, nVarSemi, 0, 0, &
               RhsSemi_VCB(:,:,:,:,iBlockSemi), &
               Flux_VXB=FluxImpl_VXB, Flux_VYB=FluxImpl_VYB, &
               Flux_VZB=FluxImpl_VZB)
       end do
    end if

    ! Multiply with cell volume (makes matrix symmetric)
    do iBlockSemi = 1, nBlockSemi
       iBlock = iBlockFromSemi_I(iBlockSemi)
       do k = 1, nK; do j = 1, nJ; do i = 1, nI
          RhsSemi_VCB(:,i,j,k,iBlockSemi) = RhsSemi_VCB(:,i,j,k,iBlockSemi) &
               *CellVolume_GB(i,j,k,iBlock)
       end do; end do; end do
    end do

  end subroutine get_semi_impl_rhs
  !============================================================================
  subroutine semi_impl_matvec(x_I, y_I, MaxN)

    ! Calculate y_I = A.x_I where A is the linearized sem-implicit operator

    use ModAdvance,  ONLY: time_BLK
    use ModGeometry, ONLY: far_field_BCs_BLK
    use ModMain, ONLY: dt, time_accurate, Cfl
    use ModSize, ONLY: nI, nJ, nK
    use ModRadDiffusion,   ONLY: get_rad_diffusion_rhs
    use ModHeatConduction, ONLY: get_heat_conduction_rhs
    use ModResistivity,    ONLY: get_resistivity_rhs
    use ModGeometry,       ONLY: true_cell
    use ModLinearSolver,   ONLY: UsePDotADotP, pDotADotPPe
    use ModCellBoundary,   ONLY: set_cell_boundary
    use BATL_lib, ONLY: message_pass_cell, message_pass_face, &
         apply_flux_correction_block, CellVolume_GB

    integer, intent(in) :: MaxN
    real,    intent(in) :: x_I(MaxN)
    real,    intent(out):: y_I(MaxN)

    integer :: iBlockSemi, iBlock, i, j, k, iVar, n
    real :: Volume, DtLocal

    logical:: DoTest, DoTestMe
    character(len=*), parameter:: NameSub = 'semi_impl_matvec'
    !------------------------------------------------------------------------
    call set_oktest(NameSub, DoTest, DoTestMe)
    call timing_start(NameSub)

    ! Fill in StateSemi so it can be message passed
    n = 0
    do iBlockSemi = 1, nBlockSemi
       iBlock = iBlockFromSemi_I(iBlockSemi)
       do k = 1, nK; do j = 1, nJ; do i = 1, nI; do iVar = 1, nVarSemi
          n = n + 1
          SemiState_VGB(iVar,i,j,k,iBlock) = x_I(n)
       end do; end do; end do; end do
    end do

    ! Message pass to fill in ghost cells 
    select case(TypeSemiImplicit)
    case('radiation', 'radcond', 'cond')

       if(UseAccurateRadiation)then
          UsePDotADotP = .false.

          call message_pass_cell(nVarSemi, SemiState_VGB, nWidthIn=2, &
               nProlongOrderIn=1, nCoarseLayerIn=2, DoRestrictFaceIn = .true.)
       else
          ! Initialize the computation of (p . A . P) form
          UsePDotADotP = SemiParam%TypeKrylov == 'CG'

          pDotADotPPe = 0.0

          call message_pass_cell(nVarSemi, SemiState_VGB, nWidthIn=1, &
               nProlongOrderIn=1, DoSendCornerIn=.false., &
               DoRestrictFaceIn=.true.)
       end if
    case('parcond','resistivity')
       call message_pass_cell(nVarSemi, SemiState_VGB, nWidthIn=2, &
            nProlongOrderIn=1, nCoarseLayerIn=2, DoRestrictFaceIn = .true.)
    case default
       call stop_mpi(NameSub//': no get_rhs message_pass implemented for' &
            //TypeSemiImplicit)
    end select

    n = 0
    do iBlockSemi = 1, nBlockSemi
       iBlock = iBlockFromSemi_I(iBlockSemi)

       if(far_field_BCs_BLK(iBlock))call set_cell_boundary( &
            1, iBlock, nVarSemi, &
            SemiState_VGB(:,:,:,:,iBlock), iBlockSemi, IsLinear=.true.)

       select case(TypeSemiImplicit)
       case('radiation', 'radcond', 'cond')
          call get_rad_diffusion_rhs(iBlock, SemiState_VGB(:,:,:,:,iBlock), &
               ResSemi_VCB(:,:,:,:,iBlockSemi), IsLinear = .true.)
       case('parcond')
          call get_heat_conduction_rhs(iBlock, SemiState_VGB(:,:,:,:,iBlock), &
               ResSemi_VCB(:,:,:,:,iBlockSemi), IsLinear = .true.)
       case('resistivity')
          call get_resistivity_rhs(iBlock, SemiState_VGB(:,:,:,:,iBlock), &
               ResSemi_VCB(:,:,:,:,iBlockSemi), IsLinear = .true.)
       case default
          call stop_mpi(NameSub//': no get_rhs implemented for' &
               //TypeSemiImplicit)
       end select

       if(UsePDotADotP)then
          DtLocal = Dt
          if(UseSplitSemiImplicit)then
             do k = 1, nK; do j = 1, nJ; do i = 1, nI
                if(.not.time_accurate) &
                     DtLocal = max(1.0e-30,Cfl*time_BLK(i,j,k,iBlock))
                Volume = CellVolume_GB(i,j,k,iBlock)/DtLocal
                n = n + 1
                pDotADotPPe = pDotADotPPe +  &
                     Volume*x_I(n)**2 &
                     *DconsDsemiAll_VCB(iVarSemi,i,j,k,iBlockSemi) &
                     /(DtLocal * SemiImplCoeff)
             end do; enddo; enddo
          else
             do k = 1, nK; do j = 1, nJ; do i = 1, nI
                if(.not.time_accurate) &
                     DtLocal = max(1.0e-30,Cfl*time_BLK(i,j,k,iBlock))
                Volume = CellVolume_GB(i,j,k,iBlock) !!! /DtLocal ???
                do iVar = 1, nVarSemi
                   n = n + 1
                   pDotADotPPe = pDotADotPPe +  &
                        Volume*x_I(n)**2 &
                        *DconsDsemiAll_VCB(iVar,i,j,k,iBlockSemi) &
                        /(DtLocal * SemiImplCoeff)
                enddo
             enddo; enddo; enddo
          end if
       end if

    end do

    if(TypeSemiImplicit == 'parcond' .or. TypeSemiImplicit == 'resistivity' &
         .or. UseAccurateRadiation)then
       call message_pass_face(nVarSemi, &
            FluxImpl_VXB, FluxImpl_VYB, FluxImpl_VZB)

       do iBlockSemi = 1, nBlockSemi
          iBlock = iBlockFromSemi_I(iBlockSemi)

          ! zero ghost cells for ResSemi_VCB
          call apply_flux_correction_block(iBlock, nVarSemi,0, 0, &
               ResSemi_VCB(:,:,:,:,iBlockSemi), &
               Flux_VXB=FluxImpl_VXB, Flux_VYB=FluxImpl_VYB, &
               Flux_VZB=FluxImpl_VZB)
       end do
    end if

    n=0
    do iBlockSemi = 1, nBlockSemi
       iBlock = iBlockFromSemi_I(iBlockSemi)

       DtLocal = dt
       if(UseSplitSemiImplicit)then
          do k = 1, nK; do j = 1, nJ; do i = 1, nI
             if(.not.time_accurate) &
                  DtLocal = max(1.0e-30,Cfl*time_BLK(i,j,k,iBlock))
             Volume = CellVolume_GB(i,j,k,iBlock)
             n = n + 1
             y_I(n) = Volume* &
                  (x_I(n)*DconsDsemiAll_VCB(iVarSemi,i,j,k,iBlockSemi)/DtLocal&
                  - SemiImplCoeff * ResSemi_VCB(1,i,j,k,iBlockSemi))
          end do; enddo; enddo
       else
          do k = 1, nK; do j = 1, nJ; do i = 1, nI
             if(.not.time_accurate) &
                  DtLocal = max(1.0e-30,Cfl*time_BLK(i,j,k,iBlock))
             Volume = CellVolume_GB(i,j,k,iBlock)
             do iVar = 1, nVarSemi
                n = n + 1
                y_I(n) = Volume* &
                     (x_I(n)*DconsDsemiAll_VCB(iVar,i,j,k,iBlockSemi)/DtLocal &
                     - SemiImplCoeff * ResSemi_VCB(iVar,i,j,k,iBlockSemi))
             enddo
          enddo; enddo; enddo
       end if
    end do
    if (UsePDotADotP)then
       pDotADotPPe = pDotADotPPe * SemiImplCoeff
    else
       pDotADotPPe = 0.0
    end if

    ! Apply left preconditioning if required: y --> P_L.y
    if(SemiParam%DoPrecond .and. SemiParam%TypeKrylov /= 'CG') &
         call semi_precond(MaxN, y_I)

    call timing_stop(NameSub)

  end subroutine semi_impl_matvec
  !============================================================================
  subroutine cg_precond(Vec_I, PrecVec_I, MaxN)

    ! Set PrecVec = Prec.Vec where Prec is the preconditioner matrix. 
    ! This routine is used by the Preconditioned Conjugate Gradient method

    integer, intent(in) :: MaxN
    real,    intent(in) :: Vec_I(MaxN)
    real,    intent(out):: PrecVec_I(MaxN)
    !-------------------------------------------------------------------------
    PrecVec_I = Vec_I
    call semi_precond(MaxN, PrecVec_I)

  end subroutine cg_precond
  !============================================================================
  subroutine semi_precond(MaxN, Vec_I)

    ! Multiply Vec with the preconditioner matrix. 
    ! This routine is used by the Preconditioned Conjugate Gradient method

    use BATL_size,       ONLY: nDim, nI, nJ, nK, nIJK
    use ModLinearSolver, ONLY: multiply_left_precond
    use ModImplHypre,    ONLY: hypre_preconditioner

    integer, intent(in)   :: MaxN
    real,    intent(inout):: Vec_I(MaxN)

    integer :: iBlock, n
    !-------------------------------------------------------------------------
    select case(SemiParam%TypePrecond)
    case('HYPRE')
       call hypre_preconditioner(MaxN, Vec_I)
    case('JACOBI')
       Vec_I = JacobiPrec_I(1:MaxN)*Vec_I
    case default
       do iBlock = 1, nBlockSemi
          n = nVarSemi*nIJK*(iBlock-1) + 1
          call multiply_left_precond(SemiParam%TypePrecond, 'left',           &
               nVarSemi, nDim, nI, nJ, nK, JacSemi_VVCIB(1,1,1,1,1,1,iBlock), &
               Vec_I(n))
       end do
    end select

  end subroutine semi_precond
  !============================================================================

  subroutine test_semi_impl_jacobian(StateSemi_VG, dVar, get_rhs, Jac_VVI)

    ! Calculate the Jacobian Jac_VVI = d(RHS)/dVar for the test cell 
    ! using numerical derivatives of the RHS obtained with get_rhs

    use BATL_lib, ONLY: MinI, MaxI, MinJ, MaxJ, MinK, MaxK, nI, nJ, nK
    use ModMain, ONLY: iTest, jTest, kTest, BlkTest

    real, intent(in):: StateSemi_VG(nVarSemi,MinI:MaxI,MinJ:MaxJ,MinK:MaxK)
    real, intent(in):: dVar ! perturbation

    ! subroutine for getting the RHS
    interface
       subroutine get_rhs(iBlock, StateImpl_VG, Rhs_VC, IsLinear)
         use ModSemiImplVar, ONLY: nVarSemi
         use BATL_lib, ONLY: MinI, MaxI, MinJ, MaxJ, MinK, MaxK, nI, nJ, nK
         implicit none
         integer, intent(in) :: iBlock
         real, intent(inout) :: &
              StateImpl_VG(nVarSemi,MinI:MaxI,MinJ:MaxJ,MinK:MaxK)
         real, intent(out)   :: Rhs_VC(nVarSemi,nI,nJ,nK)
         logical, intent(in) :: IsLinear
       end subroutine get_rhs
    end interface

    real, intent(out):: Jac_VVI(nVarSemi,nVarSemi,nStencil)

    ! Local variables
    real, allocatable:: StatePert_VG(:,:,:,:), &
         Rhs_VC(:,:,:,:), RhsPert_VC(:,:,:,:)

    integer:: i, j, k, iPert, jPert, kPert, iBlock, iStencil, iVar

    character(len=*), parameter:: NameSub = 'test_semi_impl_jacobian'
    !--------------------------------------------------------------------------

    ! Use shorter variable names for indexes
    i = iTest; j = jTest; k = kTest; iBlock = BlkTest

    allocate( &
         StatePert_VG(nVarSemi,MinI:MaxI,MinJ:MaxJ,MinK:MaxK), &
         Rhs_VC(nVarSemi,nI,nJ,nK), RhsPert_VC(nVarSemi,nI,nJ,nK))

    ! Initialize perturbed state
    StatePert_VG = StateSemi_VG

    ! Get original RHS (use StatePert to keep compiler happy)
    call get_rhs(iBlock, StatePert_VG, Rhs_VC, IsLinear=.false.)

    ! Loop over stencil
    do iStencil = 1, nStencil

       ! Set indexes for perturbed cell
       iPert = i; jPert = j; kPert = k
       select case(iStencil)
       case(2)
          iPert = i - 1
       case(3)
          iPert = i + 1
       case(4)
          jPert = j - 1
       case(5)
          jPert = j + 1
       case(6)
          kPert = k - 1
       case(7)
          kPert = k + 1
       end select

       ! Loop over variables to be perturbed
       do iVar = 1, nVarSemi

          ! Perturb the variables
          StatePert_VG(iVar,iPert,jPert,kPert) &
               = StateSemi_VG(iVar,iPert,jPert,kPert) + dVar

          ! Calculate perturbed RHS
          call get_rhs(iBlock, StatePert_VG, RhsPert_VC, IsLinear=.false.)

          ! Calculate Jacobian elements
          Jac_VVI(:,iVar,iStencil) = &
               (RhsPert_VC(:,i,j,k) - Rhs_VC(:,i,j,k))/dVar

          ! Reset the variable to the original value
          StatePert_VG(iVar,iPert,jPert,kPert) = &
               StateSemi_VG(iVar,iPert,jPert,kPert)
       end do
    end do

    deallocate(StatePert_VG, Rhs_VC, RhsPert_VC)

  end subroutine test_semi_impl_jacobian
  !============================================================================
  subroutine get_semi_impl_jacobian

    use ModAdvance, ONLY: time_BLK
    use ModRadDiffusion,   ONLY: add_jacobian_rad_diff
    use ModHeatConduction, ONLY: add_jacobian_heat_cond
    use ModResistivity,    ONLY: add_jacobian_resistivity
    use ModMain, ONLY: nI, nJ, nK, Dt, n_step, time_accurate, Cfl
    use ModGeometry, ONLY: true_cell
    use ModImplHypre, ONLY: hypre_set_matrix_block, hypre_set_matrix, &
         DoInitHypreAmg
    use BATL_lib, ONLY: CellVolume_GB

    integer :: iBlockSemi, iBlock, i, j, k, iStencil, iVar
    real    :: Coeff, DtLocal

    integer:: nStepLast = -1

    character(len=*), parameter:: NameSub = 'get_semi_impl_jacobian'
    !--------------------------------------------------------------------------
    do iBlockSemi = 1, nBlockSemi
       iBlock = iBlockFromSemi_I(iBlockSemi)

       ! All elements have to be set
       JacSemi_VVCIB(:,:,:,:,:,:,iBlockSemi) = 0.0

       ! Get dR/dU
       select case(TypeSemiImplicit)
       case('radiation', 'radcond', 'cond')
          call add_jacobian_rad_diff(iBlock, nVarSemi, &
               JacSemi_VVCIB(:,:,:,:,:,:,iBlockSemi))
       case('parcond')
          call add_jacobian_heat_cond(iBlock, nVarSemi, &
               JacSemi_VVCIB(:,:,:,:,:,:,iBlockSemi))
       case('resistivity')
          call add_jacobian_resistivity(iBlock, nVarSemi, &
               JacSemi_VVCIB(:,:,:,:,:,:,iBlockSemi))
       case default
          call stop_mpi(NameSub//': no add_jacobian implemented for' &
               //TypeSemiImplicit)
       end select

       ! Form A = Volume*(1/dt - SemiImplCoeff*dR/dU) 
       !    symmetrized for sake of CG
       do iStencil = 1, nStencil; do k = 1, nK; do j = 1, nJ; do i = 1, nI
          if(.not.true_cell(i,j,k,iBlock)) CYCLE
          Coeff = -SemiImplCoeff*CellVolume_GB(i,j,k,iBlock)
          JacSemi_VVCIB(:, :, i, j, k, iStencil, iBlockSemi) = &
               Coeff * JacSemi_VVCIB(:, :, i, j, k, iStencil, iBlockSemi)
       end do; end do; end do; end do
       DtLocal = dt
       do k = 1, nK; do j = 1, nJ; do i = 1, nI
          if(.not.time_accurate) &
               DtLocal = max(1.0e-30, Cfl*time_BLK(i,j,k,iBlock))
          Coeff = CellVolume_GB(i,j,k,iBlock)/DtLocal
          if(UseSplitSemiImplicit)then
             JacSemi_VVCIB(1,1,i,j,k,1,iBlockSemi) = &
                  Coeff*DconsDsemiAll_VCB(iVarSemi,i,j,k,iBlockSemi) &
                  + JacSemi_VVCIB(1,1,i,j,k,1,iBlockSemi)
          else
             do iVar = 1, nVarSemi
                JacSemi_VVCIB(iVar,iVar,i,j,k,1,iBlockSemi) = &             
                     Coeff*DconsDsemiAll_VCB(iVar,i,j,k,iBlockSemi) &
                     + JacSemi_VVCIB(iVar,iVar,i,j,k,1,iBlockSemi) 
             end do
          end if
       end do; end do; end do

       if(SemiParam%TypePrecond == 'HYPRE') &
            call hypre_set_matrix_block(iBlockSemi, &
            JacSemi_VVCIB(1,1,1,1,1,1,iBlockSemi))
    end do

    if(SemiParam%TypePrecond == 'HYPRE')then
       if(nStepLast < 0 .or. n_step - nStepLast >= DnInitHypreAmg)then
          DoInitHypreAmg = .true.
          nStepLast = n_step
       end if
       call hypre_set_matrix
    end if

  end subroutine get_semi_impl_jacobian
  !===========================================================================

end module ModSemiImplicit

