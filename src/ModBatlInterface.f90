!  Copyright (C) 2002 Regents of the University of Michigan,
!  portions used with permission
!  For more information, see http://csem.engin.umich.edu/tools/swmf
module ModBatlInterface

  use BATL_lib, ONLY: test_start, test_stop
#ifdef OPENACC
  use ModUtilities, ONLY: norm2
#endif
  use BATL_grid, ONLY: BATL_interpolate => interpolate_grid_amr_gc
  implicit none

contains
  !============================================================================
  subroutine set_batsrus_grid

    use BATL_lib, ONLY: nBlock, Unused_B, Unused_BP, iProc, iComm, &
         IsNewDecomposition, IsNewTree, nLevelMin, nLevelMax, &
         DomainSize_D, nRoot_D, nI, CellSizeRoot

    use ModMain, ONLY: nBlockMax, iNewGrid, iNewDecomposition

    use ModPartSteady, ONLY: UsePartSteady

    use ModGeometry, ONLY: CellSize1Min, CellSize1Max, CellSizeMin, CellSizeMax

    use ModAdvance, ONLY: iTypeAdvance_B, iTypeAdvance_BP, &
         SkippedBlock_, ExplBlock_
    use ModMpi
    use ModIO, ONLY: restart

    integer:: iBlock, iError
    real   :: CellSize1Root

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'set_batsrus_grid'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)
    ! Tell if the grid and/or the tree has changed
    if(IsNewDecomposition) iNewDecomposition = mod(iNewDecomposition+1,10000)
    if(IsNewTree) iNewGrid = mod( iNewGrid+1, 10000)

    if(DoTest)write(*,*) NameSub, &
         ' starting with IsNewDecomposition, IsNewTree, restart=', &
         IsNewDecomposition, IsNewTree, restart

    if( IsNewDecomposition .or. IsNewTree .or. restart) then

       ! If regrid_batl is not called in each time step, we say that the
       ! grid/tree is not changed from the view of BATL
       IsNewDecomposition = .false.
       IsNewTree          = .false.

       call MPI_allreduce(nBlock, nBlockMax, 1, MPI_INTEGER, MPI_MAX, &
            iComm, iError)

       if(.not.UsePartSteady)then
          where(Unused_BP(1:nBlockMax,:))
             iTypeAdvance_BP(1:nBlockMax,:) = SkippedBlock_
          elsewhere
             iTypeAdvance_BP(1:nBlockMax,:) = ExplBlock_
          end where
          iTypeAdvance_B(1:nBlock) = iTypeAdvance_BP(1:nBlock,iProc)
       end if

       do iBlock = 1, nBlock
          if(Unused_B(iBlock)) CYCLE
          call set_batsrus_block(iBlock)
       end do

       ! Get the smallest and largest cell sizes in the current grid
       ! First coordinate
       CellSize1Root = DomainSize_D(1)/(nRoot_D(1)*nI)
       CellSize1Min = CellSize1Root*0.5**nLevelMax
       CellSize1Max = CellSize1Root*0.5**nLevelMin

       ! First or Phi coordinate in degrees
       CellSizeMin = CellSizeRoot*0.5**nLevelMax
       CellSizeMax = CellSizeRoot*0.5**nLevelMin

    end if

    call test_stop(NameSub, DoTest)
  end subroutine set_batsrus_grid
  !============================================================================
  subroutine set_batsrus_block(iBlock)

    use BATL_lib, ONLY: nDim, &
         MinI, MaxI, MinJ, MaxJ, MinK, MaxK, &
         Xyz_DGB, CellSize_DB, CoordMin_DB, &
         iNode_B, iNodeNei_IIIB, DiLevelNei_IIIB, &
         iTree_IA, Block_, Proc_, Unset_

    use ModBoundaryGeometry, ONLY: fix_block_geometry
    use ModGeometry, ONLY: &
         XyzStart_BLK, r_BLK, rMin_BLK

    use ModParallel, ONLY: neiLEV, neiBLK, neiPE, &
         neiLeast, neiLwest, neiLsouth, neiLnorth, neiLbot, neiLtop, &
         neiBeast, neiBwest, neiBsouth, neiBnorth, neiBbot, neiBtop, &
         neiPeast, neiPwest, neiPsouth, neiPnorth, neiPbot, neiPtop

    integer, intent(in):: iBlock

    ! Convert from BATL to BATSRUS ordering of subfaces.

    integer, parameter:: iOrder_I(4) = [1,3,2,4]
    integer:: iNodeNei, iNodeNei_I(4)
    integer:: i, j, k
    logical:: DoTest
    character(len=*), parameter:: NameSub = 'set_batsrus_block'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest, iBlock)
    neiLeast(iBlock)  = DiLevelNei_IIIB(-1,0,0,iBlock)
    neiLwest(iBlock)  = DiLevelNei_IIIB(+1,0,0,iBlock)
    neiLsouth(iBlock) = DiLevelNei_IIIB(0,-1,0,iBlock)
    neiLnorth(iBlock) = DiLevelNei_IIIB(0,+1,0,iBlock)
    neiLbot(iBlock)   = DiLevelNei_IIIB(0,0,-1,iBlock)
    neiLtop(iBlock)   = DiLevelNei_IIIB(0,0,+1,iBlock)

    neiLEV(1,iBlock)  = neiLeast(iBlock)
    neiLEV(2,iBlock)  = neiLwest(iBlock)
    neiLEV(3,iBlock)  = neiLsouth(iBlock)
    neiLEV(4,iBlock)  = neiLnorth(iBlock)
    neiLEV(5,iBlock)  = neiLbot(iBlock)
    neiLEV(6,iBlock)  = neiLtop(iBlock)

    ! neiBeast ... neiPbot are used in
    ! ModFaceValue::correct_monotone_restrict and
    ! ModConserveFlux::apply_cons_flux

    select case(DiLevelNei_IIIB(-1,0,0,iBlock))
    case(Unset_)
       neiBeast(:,iBlock)  = Unset_
       neiPeast(:,iBlock)  = Unset_
    case(-1)
       iNodeNei_I = pack(iNodeNei_IIIB(0,1:2,1:2,iBlock),.true.)
       iNodeNei_I = iNodeNei_I(iOrder_I)
       if(nDim < 3) where(iNodeNei_I == Unset_) iNodeNei_I = iNode_B(iBlock)
       neiBeast(:,iBlock)  = iTree_IA(Block_,iNodeNei_I)
       neiPeast(:,iBlock)  = iTree_IA(Proc_,iNodeNei_I)
    case default
       iNodeNei = iNodeNei_IIIB(0,1,1,iBlock)
       neiBeast(:,iBlock)  = iTree_IA(Block_,iNodeNei)
       neiPeast(:,iBlock)  = iTree_IA(Proc_,iNodeNei)
    end select

    select case(DiLevelNei_IIIB(+1,0,0,iBlock))
    case(Unset_)
       neiBwest(:,iBlock)  = Unset_
       neiPwest(:,iBlock)  = Unset_
    case(-1)
       iNodeNei_I = pack(iNodeNei_IIIB(3,1:2,1:2,iBlock),.true.)
       iNodeNei_I = iNodeNei_I(iOrder_I)
       if(nDim < 3) where(iNodeNei_I == Unset_) iNodeNei_I = iNode_B(iBlock)
       neiBwest(:,iBlock)  = iTree_IA(Block_,iNodeNei_I)
       neiPwest(:,iBlock)  = iTree_IA(Proc_,iNodeNei_I)
    case default
       iNodeNei = iNodeNei_IIIB(3,1,1,iBlock)
       neiBwest(:,iBlock)  = iTree_IA(Block_,iNodeNei)
       neiPwest(:,iBlock)  = iTree_IA(Proc_,iNodeNei)
    end select

    select case(DiLevelNei_IIIB(0,-1,0,iBlock))
    case(Unset_)
       neiBsouth(:,iBlock)  = Unset_
       neiPsouth(:,iBlock)  = Unset_
    case(-1)
       iNodeNei_I = pack(iNodeNei_IIIB(1:2,0,1:2,iBlock),.true.)
       iNodeNei_I = iNodeNei_I(iOrder_I)
       if(nDim < 3) where(iNodeNei_I == Unset_) iNodeNei_I = iNode_B(iBlock)
       neiBsouth(:,iBlock)  = iTree_IA(Block_,iNodeNei_I)
       neiPsouth(:,iBlock)  = iTree_IA(Proc_,iNodeNei_I)
    case default
       iNodeNei = iNodeNei_IIIB(1,0,1,iBlock)
       neiBsouth(:,iBlock)  = iTree_IA(Block_,iNodeNei)
       neiPsouth(:,iBlock)  = iTree_IA(Proc_,iNodeNei)
    end select

    select case(DiLevelNei_IIIB(0,+1,0,iBlock))
    case(Unset_)
       neiBnorth(:,iBlock)  = Unset_
       neiPnorth(:,iBlock)  = Unset_
    case(-1)
       iNodeNei_I = pack(iNodeNei_IIIB(1:2,3,1:2,iBlock),.true.)
       iNodeNei_I = iNodeNei_I(iOrder_I)
       if(nDim < 3) where(iNodeNei_I == Unset_) iNodeNei_I = iNode_B(iBlock)
       neiBnorth(:,iBlock)  = iTree_IA(Block_,iNodeNei_I)
       neiPnorth(:,iBlock)  = iTree_IA(Proc_,iNodeNei_I)
    case default
       iNodeNei = iNodeNei_IIIB(1,3,1,iBlock)
       neiBnorth(:,iBlock)  = iTree_IA(Block_,iNodeNei)
       neiPnorth(:,iBlock)  = iTree_IA(Proc_,iNodeNei)
    end select

    select case(DiLevelNei_IIIB(0,0,-1,iBlock))
    case(Unset_ )
       neiBbot(:,iBlock)  = Unset_
       neiPbot(:,iBlock)  = Unset_
    case(-1)
       iNodeNei_I = pack(iNodeNei_IIIB(1:2,1:2,0,iBlock),.true.)
       neiBbot(:,iBlock)  = iTree_IA(Block_,iNodeNei_I)
       neiPbot(:,iBlock)  = iTree_IA(Proc_,iNodeNei_I)
    case default
       iNodeNei = iNodeNei_IIIB(1,1,0,iBlock)
       neiBbot(:,iBlock)  = iTree_IA(Block_,iNodeNei)
       neiPbot(:,iBlock)  = iTree_IA(Proc_,iNodeNei)
    end select

    select case(DiLevelNei_IIIB(0,0,+1,iBlock))
    case(Unset_)
       neiBtop(:,iBlock)  = Unset_
       neiPtop(:,iBlock)  = Unset_
    case(-1)
       iNodeNei_I = pack(iNodeNei_IIIB(1:2,1:2,3,iBlock),.true.)
       neiBtop(:,iBlock)  = iTree_IA(Block_,iNodeNei_I)
       neiPtop(:,iBlock)  = iTree_IA(Proc_,iNodeNei_I)
    case default
       iNodeNei = iNodeNei_IIIB(1,1,3,iBlock)
       neiBtop(:,iBlock)  = iTree_IA(Block_,iNodeNei)
       neiPtop(:,iBlock)  = iTree_IA(Proc_,iNodeNei)
    end select

    ! neiBLK and neiPE are used in ray_pass, constrain_B, ModPartSteady
    neiBLK(:,1,iBlock) = neiBeast(:,iBlock)
    neiBLK(:,2,iBlock) = neiBwest(:,iBlock)
    neiBLK(:,3,iBlock) = neiBsouth(:,iBlock)
    neiBLK(:,4,iBlock) = neiBnorth(:,iBlock)
    neiBLK(:,5,iBlock) = neiBbot(:,iBlock)
    neiBLK(:,6,iBlock) = neiBtop(:,iBlock)

    neiPE(:,1,iBlock) = neiPeast(:,iBlock)
    neiPE(:,2,iBlock) = neiPwest(:,iBlock)
    neiPE(:,3,iBlock) = neiPsouth(:,iBlock)
    neiPE(:,4,iBlock) = neiPnorth(:,iBlock)
    neiPE(:,5,iBlock) = neiPbot(:,iBlock)
    neiPE(:,6,iBlock) = neiPtop(:,iBlock)

    XyzStart_BLK(:,iBlock) = CoordMin_DB(:,iBlock) + 0.5*CellSize_DB(:,iBlock)

    do k = MinK, MaxK; do j = MinJ, MaxJ; do i = MinI, MaxI
       r_BLK(i,j,k,iBlock) = norm2(Xyz_DGB(1:nDim,i,j,k,iBlock))
    end do; end do; end do

    Rmin_BLK(iBlock) = minval(r_BLK(:,:,:,iBlock))

    call fix_block_geometry(iBlock)

  !$acc update device(neiLtop, neiLbot)
  !$acc update device(neiLeast, neiLwest, neiLnorth, neiLsouth)
  !$acc update device(neiLEV)

    call test_stop(NameSub, DoTest, iBlock)
  end subroutine set_batsrus_block
  !============================================================================
  subroutine set_batsrus_state

    ! Here we should fix B0 and other things

    use ModMain, ONLY: UseB0
    use ModB0, ONLY: set_b0_reschange
    use ModFieldLineThread, ONLY: UseFieldLineThreads, set_threads
    use BATL_lib, ONLY: nBlock, iAmrChange_B, AmrMoved_, Unused_B,&
         set_amr_geometry
    use ModEnergy, ONLY: calc_energy_ghost
    use ModResistivity, ONLY: UseResistivity, set_resistivity
    use ModUserInterface ! user_specify_refinement

    integer:: iBlock

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'set_batsrus_state'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)

    do iBlock = 1, nBlock
       if(Unused_B(iBlock)) CYCLE

       ! If nothing happened to the block, no need to do anything
       if(iAmrChange_B(iBlock) < AmrMoved_) CYCLE

       ! Update all kinds of extra block variables
       call calc_other_vars(iBlock)
       call calc_energy_ghost(iBlock)
       call set_amr_geometry(iBlock)
    end do

    if(UseResistivity) call set_resistivity
    if(UseB0)call set_b0_reschange
    if(UseFieldLineThreads)call set_threads
    call test_stop(NameSub, DoTest)
  end subroutine set_batsrus_state
  !============================================================================
  subroutine calc_other_vars(iBlock)

    use ModAdvance,  ONLY: State_VGB, nVar, time_BLK
    use ModB0,       ONLY: set_b0_cell
    use ModPhysics,  ONLY: FaceState_VI, rBody2
    use ModGeometry, ONLY: body_BLK, true_blk, true_cell, R2_BLK
    use ModMain,     ONLY: TypeCellBC_I, body1_, UseB0, UseBody2, body2_, &
         dt_BLK, time_accurate, UseDtFixed, Dt
    use ModParallel, ONLY: neiLwest, NOBLK
    use ModMultiFluid

    use BATL_size, ONLY: nI, nJ, nK, MinI, MaxI, MinJ, MaxJ, MinK, MaxK

    integer, intent(in) :: iBlock

    integer:: i, j, k, iFluid
    logical:: DoTest
    character(len=*), parameter:: NameSub = 'calc_other_vars'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest, iBlock)

    ! Set B0
    if(UseB0) call set_b0_cell(iBlock)

    ! Set values inside body
    if(body_BLK(iBlock)) then
       do k = MinK, MaxK; do j = MinJ, MaxJ; do i = MinI, MaxI
          if(true_cell(i,j,k,iBlock)) CYCLE
          State_VGB(1:nVar,i,j,k,iBlock) = FaceState_VI(1:nVar,body1_)
          ! Convert velocity to momentum
          do iFluid = 1, nFluid
             if(nFluid > 1) call select_fluid(iFluid)
             State_VGB(iRhoUx,i,j,k,iBlock) = &
                  FaceState_VI(iUx,body1_)*FaceState_VI(iRho,body1_)
             State_VGB(iRhoUy,i,j,k,iBlock) = &
                  FaceState_VI(iUy,body1_)*FaceState_VI(iRho,body1_)
             State_VGB(iRhoUz,i,j,k,iBlock) = &
                  FaceState_VI(iUz,body1_)*FaceState_VI(iRho,body1_)
          end do
       end do;end do; end do
    end if

    if(UseBody2)then
       do k = MinK, MaxK; do j = MinJ, MaxJ; do i = MinI, MaxI
          if(R2_Blk(i,j,k,iBlock) > rBody2) CYCLE
          State_VGB(1:nVar,i,j,k,iBlock) = FaceState_VI(1:nVar,body2_)
          ! Convert velocity to momentum
          do iFluid = 1, nFluid
             if(nFluid > 1) call select_fluid(iFluid)
             State_VGB(iRhoUx,i,j,k,iBlock) = &
                  FaceState_VI(iUx,body2_)*FaceState_VI(iRho,body2_)
             State_VGB(iRhoUy,i,j,k,iBlock) = &
                  FaceState_VI(iUy,body2_)*FaceState_VI(iRho,body2_)
             State_VGB(iRhoUz,i,j,k,iBlock) = &
                  FaceState_VI(iUz,body2_)*FaceState_VI(iRho,body2_)
          end do
       end do;end do; end do
    end if

    ! For coupled (IH->GM) boundary condition fill in ghost cells
    ! with the first physical cell, because IH may not couple after AMR
    if(TypeCellBc_I(2)=='coupled' .and. neiLwest(iBlock)==NOBLK)then
       State_VGB(:,nI+1,:,:,iBlock) = State_VGB(:,nI,:,:,iBlock)
       State_VGB(:,nI+2,:,:,iBlock) = State_VGB(:,nI,:,:,iBlock)
    endif

    if(time_accurate)then
       if(UseDtFixed)then
          time_BLK(:,:,:,iBlock) = Dt
       else
          time_BLK(:,:,:,iBlock) = dt_BLK(iBlock)
       end if

       ! Reset time step to zero inside body.
       if(.not.true_BLK(iBlock))then
          where(.not.true_cell(1:nI,1:nJ,1:nK,iBlock)) &
               time_BLK(:,:,:,iBlock) = 0.0
       end if
    end if

    call test_stop(NameSub, DoTest, iBlock)
  end subroutine calc_other_vars
  !============================================================================

  subroutine interpolate_grid_amr_gc(XyzIn_D, iBlock, &
       nCell, iCell_II, Weight_I, IsBody)

    use BATL_lib, ONLY: MaxDim, nDim
    use ModGeometry, ONLY: body_BLK, true_cell
    ! Interpolation is performed using cells (including ghost) of single block,
    ! its index, iBlock, is provided at the call;
    !
    ! NOTE: it is assumed that iBlock is appropriate for interpolation
    ! that utilizes only 1 layer of ghost cells, i.e. the call
    !  call check_interpolate_amr_gc(XyzIn_D,iBlock,iPeOut,iBlockOut)! BATL_grid
    ! would result in iBlockOut==iBlock
    !
    ! difference from BATL_grid version: if a cell in the stencil is not
    ! a true cell (see ModGeometry) -> it's removed from the stencil

    real,    intent(in) :: XyzIn_D(MaxDim)
    integer, intent(in) :: iBlock
    integer, intent(out):: nCell
    integer, intent(out):: iCell_II(0:nDim,2**nDim)
    real,    intent(out):: Weight_I(2**nDim)
    logical, optional,intent(out):: IsBody

    integer:: i_D(MaxDim), iCell ! loop variables
    integer:: nCellNew
    real:: WeightTotal

    character(len=*), parameter:: NameSub = 'interpolate_grid_amr_gc'
    !--------------------------------------------------------------------------
    ! call interpolation routine from BATL_grid
    call BATL_interpolate(XyzIn_D, iBlock, nCell, iCell_II, Weight_I)

    ! check whether all cells in the stencil are true cells
    if(body_BLK(iBlock))then
       ! number of cells in the stencil may change, reset it
       nCellNew = 0
       ! reset total weight as well
       WeightTotal = 0.0
       do iCell = 1, nCell
          i_D = 1
          i_D(1:nDim) = iCell_II(1:nDim, iCell)
          if(true_cell(i_D(1),i_D(2),i_D(3),iBlock))then
             nCellNew = nCellNew + 1
             WeightTotal = WeightTotal + Weight_I(iCell)
             ! rearrange output if necessary
             if(nCellNew < iCell)then
                iCell_II(:,nCellNew) = iCell_II(:,iCell)
                Weight_I(  nCellNew) = Weight_I(  iCell)
             end if
          end if
       end do
       nCell = nCellNew
       if(nCell==0)then
          if(.not.present(IsBody))call stop_mpi(&
            'No true cell in the interpolation stencil')
       else
          ! Rescale weights to get their total equal 1
          Weight_I(1:nCell) = Weight_I(1:nCell)/WeightTotal
       end if
       if(present(IsBody))IsBody = WeightTotal < 0.5
    else
       if(present(IsBody)) IsBody = .false.
    end if

  end subroutine interpolate_grid_amr_gc
  !============================================================================

end module ModBatlInterface
!==============================================================================
