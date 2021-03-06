!  Copyright (C) 2002 Regents of the University of Michigan,
!  portions used with permission
!  For more information, see http://csem.engin.umich.edu/tools/swmf

module ModMessagePass

  use BATL_lib, ONLY: &
       test_start, test_stop, iProc

  ! Message passing to fill in ghost cells.
  !
  ! Also methods related to the buffer grid that acts like
  ! ghost cells in a spherical shell.

  implicit none

  private ! except

  public:: exchange_messages   ! fill ghost cells and (re)calculate energies
  public:: fix_buffer_grid     ! restore old values in the buffer grid
  public:: fill_in_from_buffer ! set cells of the block covered by buffer grid

  ! Set to true if there is a need for extra message passing
  logical, public:: DoExtraMessagePass = .false.

  ! True if it is sufficient to fill in the fine ghost cells with a single
  ! layer of the coarse cell values. Set in ModSetParameters.
  logical, public:: DoOneCoarserLayer = .true.

contains
  !============================================================================
  subroutine exchange_messages(DoResChangeOnlyIn, UseOrder2In)

    use ModCellBoundary, ONLY: set_cell_boundary, set_edge_corner_ghost
    use ModBoundaryGeometry, ONLY: fix_boundary_ghost_cells
    use ModMain, ONLY : nBlock, Unused_B, &
         time_loop, &
         UseConstrainB, UseProjection, &
         nOrder, nOrderProlong, optimize_message_pass, &
         UseHighResChange, UseBufferGrid, UseResistivePlanet, CellBCType
    use ModVarIndexes
    use ModAdvance,  ONLY: State_VGB
    use ModGeometry, ONLY: far_field_BCs_BLK
    use ModPhysics,  ONLY: ShockSlope, nVectorVar, iVectorVar_I
    use ModFaceValue, ONLY: UseAccurateResChange
    use ModEnergy,   ONLY: calc_energy_ghost, correctP
    use ModCoordTransform, ONLY: rot_xyz_sph
    use ModParticleMover, ONLY:  UseBoundaryVdf, set_boundary_vdf

    use BATL_lib, ONLY: message_pass_cell, DiLevelNei_IIIB, nG, &
         MinI, MaxI, MinJ, MaxJ, MinK, MaxK, Xyz_DGB, &
         IsSpherical, IsRLonLat, IsPeriodic_D, IsPeriodicCoord_D
    use ModMpi

    ! Fill ghost cells at res. change only
    logical, optional, intent(in) :: DoResChangeOnlyIn

    ! Use 2nd order prolongation to fill
    logical, optional, intent(in) :: UseOrder2In

    logical :: UseOrder2
    logical :: DoResChangeOnly

    logical :: DoRestrictFace, DoTwoCoarseLayers, DoSendCorner
    integer :: nWidth, nCoarseLayer

    integer :: iBlock

    logical :: UseHighResChangeNow

    logical :: IsFound

    type(CellBCType) :: CBC

    !!! TO BE GENERALIZED
    logical:: IsPeriodicWedge = .false.
    integer:: iVector, iVar, i, j, k
    real   :: XyzSph_DD(3,3)

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'exchange_messages'
    !--------------------------------------------------------------------------

    call test_start(NameSub, DoTest)
    if(DoExtraMessagePass)then
       if(DoTest) write(*,*) NameSub,': doing extra message pass'
       ! Switch off request
       DoExtraMessagePass = .false.
    end if

    ! This way of doing periodic BC for wedge is not perfect.
    ! It does not work for AMR or semi-implicit scheme with vectors.
    ! But it works for a number of simple but useful applications.
    ! A periodic wedge BC is needed if there is a periodic boundary condition
    ! for a non-periodic angular coordinate.
    ! In this case the vector variables are convered to spherical components
    ! during the message passing.
    IsPeriodicWedge = (IsSpherical .or. IsRLonLat) .and. &
         (any(IsPeriodic_D(2:3) .and. .not. IsPeriodicCoord_D(2:3)))

    DoResChangeOnly = .false.
    if(present(DoResChangeOnlyIn)) DoResChangeOnly = DoResChangeOnlyIn

    UseOrder2=.false.
    if(present(UseOrder2In)) UseOrder2 = UseOrder2In

    DoRestrictFace = nOrderProlong==1
    if(UseConstrainB) DoRestrictFace = .false.

    DoTwoCoarseLayers = &
         nOrder>1 .and. nOrderProlong==1 .and. .not. DoOneCoarserLayer

    UseHighResChangeNow = nOrder==5 .and. UseHighResChange

    if(DoTest)write(*,*) NameSub, &
         ': DoResChangeOnly, UseOrder2, DoRestrictFace, DoTwoCoarseLayers=',&
         DoResChangeOnly, UseOrder2, DoRestrictFace, DoTwoCoarseLayers

    call timing_start('exch_msgs')

    ! Ensure that energy and pressure are consistent and positive in real cells
    if(.not.DoResChangeOnly) then
       do iBlock = 1, nBlock
          if (Unused_B(iBlock)) CYCLE
          if (far_field_BCs_BLK(iBlock) .and. &
               (nOrderProlong==2 .or. UseHighResChangeNow)) then
             call set_cell_boundary&
                  (nG, iBlock, nVar, State_VGB(:,:,:,:,iBlock))
             if(UseHighResChangeNow) &
                  call set_edge_corner_ghost&
                  (nG,iBlock,nVar,State_VGB(:,:,:,:,iBlock))
          endif
          if(UseConstrainB)call correctP(iBlock)
          if(UseProjection)call correctP(iBlock)
       end do
    end if

    if(IsPeriodicWedge)then
       do iBlock = 1, nBlock
          if (Unused_B(iBlock)) CYCLE
          ! Skip blocks not at the boundary !!!
          do k=MinK,MaxK; do j=MinJ,MaxJ; do i=MinI,MaxI
             XyzSph_DD = rot_xyz_sph(Xyz_DGB(:,i,j,k,iBlock))
             do iVector = 1, nVectorVar
                iVar = iVectorVar_I(iVector)
                State_VGB(iVar:iVar+2,i,j,k,iBlock) = &
                     matmul(State_VGB(iVar:iVar+2,i,j,k,iBlock), XyzSph_DD)
             end do
          end do; end do; enddo
       end do
    end if

    if (UseOrder2 .or. nOrderProlong > 1) then
       call message_pass_cell(nVar, State_VGB,&
            DoResChangeOnlyIn=DoResChangeOnlyIn)
    elseif (optimize_message_pass=='all') then
       ! If ShockSlope is not zero then even the first order scheme needs
       ! all ghost cell layers to fill in the corner cells at the sheared BCs.
       nWidth = nG; if(nOrder == 1 .and. ShockSlope == 0.0)  nWidth = 1
       nCoarseLayer = 1; if(DoTwoCoarseLayers) nCoarseLayer = 2
       call message_pass_cell(nVar, State_VGB, &
            nWidthIn=nWidth, nProlongOrderIn=1, &
            nCoarseLayerIn=nCoarseLayer, DoRestrictFaceIn = DoRestrictFace,&
            DoResChangeOnlyIn=DoResChangeOnlyIn, &
            UseHighResChangeIn=UseHighResChangeNow,&
            DefaultState_V=DefaultState_V, &
            UseOpenACCIn=.true.)
    else
       ! Pass corners if necessary
       DoSendCorner = nOrder > 1 .and. UseAccurateResChange
       ! Pass one layer if possible
       nWidth = nG;      if(nOrder == 1)       nWidth = 1
       nCoarseLayer = 1; if(DoTwoCoarseLayers) nCoarseLayer = 2
       call message_pass_cell(nVar, State_VGB, &
            nWidthIn=nWidth, &
            nProlongOrderIn=1, &
            nCoarseLayerIn=nCoarseLayer,&
            DoSendCornerIn=DoSendCorner, &
            DoRestrictFaceIn=DoRestrictFace,&
            DoResChangeOnlyIn=DoResChangeOnlyIn,&
            UseHighResChangeIn=UseHighResChangeNow,&
            DefaultState_V=DefaultState_V)
    end if

    ! If the grid changed, fix iBoundary_GB
    ! This could/should be done where the grid is actually being changed,
    ! for example in load_balance
    if(.not.DoResChangeOnly) call fix_boundary_ghost_cells

    if(IsPeriodicWedge)then
       do iBlock = 1, nBlock
          if (Unused_B(iBlock)) CYCLE
          ! Skip blocks not at the boundary !!!
          do k=MinK,MaxK; do j=MinJ,MaxJ; do i=MinI,MaxI
             XyzSph_DD = rot_xyz_sph(Xyz_DGB(:,i,j,k,iBlock))
             do iVector = 1, nVectorVar
                iVar = iVectorVar_I(iVector)
                State_VGB(iVar:iVar+2,i,j,k,iBlock) = &
                     matmul(XyzSph_DD, State_VGB(iVar:iVar+2,i,j,k,iBlock))
             end do
          end do; end do; enddo
       end do
    end if

    call timing_start('exch_energy')
    !$omp parallel do
    do iBlock = 1, nBlock
       if (Unused_B(iBlock)) CYCLE

       ! The corner ghost cells outside the domain are updated
       ! from the ghost cells inside the domain, so the outer
       ! boundary condition have to be reapplied.
       if(.not.DoResChangeOnly &
            .or. any(abs(DiLevelNei_IIIB(:,:,:,iBlock)) == 1) )then
          if (far_field_BCs_BLK(iBlock)) then
             call set_cell_boundary( &
                  nG, iBlock, nVar, State_VGB(:,:,:,:,iBlock))
             ! Fill in boundary cells with hybrid particles
             if(UseBoundaryVdf)call set_boundary_vdf(iBlock)
          end if
          if(time_loop.and.UseBufferGrid)&
               call fill_in_from_buffer(iBlock)
       end if

       call calc_energy_ghost(iBlock, DoResChangeOnlyIn=DoResChangeOnlyIn, UseOpenACCIn=.true.)

       if(UseResistivePlanet) then
          CBC%TypeBc = 'ResistivePlanet'
          call user_set_cell_boundary(iBlock,-1,CBC,IsFound)
       end if

    end do
    !$omp end parallel do

    if(.not.DoResChangeOnly)UseBoundaryVdf = .false.
    call timing_stop('exch_energy')

    call timing_stop('exch_msgs')
    if(DoTest)call timing_show('exch_msgs',1)

    if(DoTest)write(*,*) NameSub,' finished'

    call test_stop(NameSub, DoTest)
  end subroutine exchange_messages
  !============================================================================
  logical function is_buffered_point(i,j,k,iBlock)
    use ModGeometry, ONLY: R_BLK
    use ModMain,    ONLY: BufferMin_D, BufferMax_D
    integer, intent(in):: i, j, k, iBlock
    !--------------------------------------------------------------------------
    is_buffered_point =   R_BLK(i,j,k,iBlock) <= BufferMax_D(1) &
         .and.            R_BLK(i,j,k,iBlock) >= BufferMin_D(1)
  end function is_buffered_point
  !============================================================================
  subroutine fix_buffer_grid(iBlock)

    ! Do not update solution in the domain covered by the buffer grid

    use ModAdvance, ONLY: State_VGB, StateOld_VGB, Energy_GBI, EnergyOld_CBI
    use BATL_lib, ONLY: nI, nJ, nK

    integer, intent(in):: iBlock

    integer:: i, j, k
    logical:: DoTest
    character(len=*), parameter:: NameSub = 'fix_buffer_grid'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest, iBlock)

    do k = 1, nK; do j = 1, nJ; do i = 1, nI
       if(.not.is_buffered_point(i, j, k, iBlock))CYCLE
       State_VGB(:,i,j,k,iBlock) = &
            StateOld_VGB(:,i,j,k,iBlock)
       Energy_GBI(i, j, k, iBlock,:) = EnergyOld_CBI(i, j, k, iBlock,:)
    end do; end do; end do

    call test_stop(NameSub, DoTest, iBlock)
  end subroutine fix_buffer_grid
  !============================================================================
  subroutine fill_in_from_buffer(iBlock)
    use ModAdvance, ONLY: nVar, State_VGB, Rho_, RhoUx_, RhoUz_, Ux_, Uz_
    use BATL_lib,   ONLY: MinI, MaxI, MinJ, MaxJ, MinK, MaxK, Xyz_DGB
    integer,intent(in)::iBlock

    integer:: i, j, k
    logical:: DoWrite=.true.
    logical:: DoTest
    character(len=*), parameter:: NameSub = 'fill_in_from_buffer'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest, iBlock)

    if(DoWrite)then
       DoWrite=.false.
       if(iProc==0)then
          write(*,*)'Fill in the cells near the inner boundary from the buffer'
       end if
    end if

    do k = MinK, MaxK; do j = MinJ, MaxJ; do i = MinI, MaxI
       if(.not.is_buffered_point(i, j, k, iBlock)) CYCLE

       ! Get interpolated values from buffer grid:
       call get_from_spher_buffer_grid(&
            Xyz_DGB(:,i,j,k,iBlock), nVar, State_VGB(:,i,j,k,iBlock))

       ! Transform primitive variables to conservative ones:
       State_VGB(RhoUx_:RhoUz_,i,j,k,iBlock) = &
            State_VGB(Rho_,i,j,k,iBlock)*State_VGB(Ux_:Uz_,i,j,k,iBlock)

    end do; end do; end do

    call test_stop(NameSub, DoTest, iBlock)
  end subroutine fill_in_from_buffer
  !============================================================================

end module ModMessagePass
!==============================================================================
