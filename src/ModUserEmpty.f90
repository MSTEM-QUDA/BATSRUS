!  Copyright (C) 2002 Regents of the University of Michigan,
!  portions used with permission
!  For more information, see http://csem.engin.umich.edu/tools/swmf
module ModUserEmpty

  use BATL_lib, ONLY: &
       test_start, test_stop

  ! This module contains empty user routines.  They should be "used"
  ! (included) in the srcUser/ModUser*.f90 files for routines that the user
  ! does not wish to implement.

  ! These constants are provided for convenience
  use ModSize, ONLY: x_, y_, z_, MinI, MaxI, MinJ, MaxJ, MinK, MaxK

  implicit none

  private :: stop_user

contains
  !============================================================================

  subroutine user_set_boundary_cells(iBlock)

    integer,intent(in)::iBlock

    character(len=*), parameter:: NameSub = 'user_set_boundary_cells'
    !--------------------------------------------------------------------------
    call stop_user(NameSub)
  end subroutine user_set_boundary_cells
  !============================================================================

  subroutine user_set_face_boundary(VarsGhostFace_V)

    use ModAdvance, ONLY: nVar

    real, intent(out):: VarsGhostFace_V(nVar)

    character(len=*), parameter:: NameSub = 'user_set_face_boundary'
    !--------------------------------------------------------------------------
    call stop_user(NameSub)
  end subroutine user_set_face_boundary
  !============================================================================

  subroutine user_set_cell_boundary(iBlock, iSide, TypeBc, IsFound)

    integer,          intent(in)  :: iBlock, iSide
    character(len=*), intent(in)  :: TypeBc
    logical,          intent(out) :: IsFound

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'user_set_cell_boundary'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest, iBlock)
    IsFound = .false.
    call stop_user(NameSub)
    call test_stop(NameSub, DoTest, iBlock)
  end subroutine user_set_cell_boundary
  !============================================================================

  subroutine user_initial_perturbation
    use ModMain, ONLY: nBlockMax
    integer::iBlock
    logical:: DoTest
    character(len=*), parameter:: NameSub = 'user_initial_perturbation'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)
    ! The routine is called once and should be applied for all blocks, the
    ! do-loop should be present. Another distinction from user_set_ics is that
    ! user_initial_perturbation can be applied after restart, while
    ! user_set_ICs cannot.

    do iBlock = 1, nBlockMax

       call stop_user(NameSub)
    end do
    call test_stop(NameSub, DoTest)
  end subroutine user_initial_perturbation
  !============================================================================

  subroutine user_set_ics(iBlock)

    integer, intent(in) :: iBlock

    character(len=*), parameter:: NameSub = 'user_set_ics'
    !--------------------------------------------------------------------------
    call stop_user(NameSub)
  end subroutine user_set_ics
  !============================================================================

  subroutine user_init_session

    character(len=*), parameter:: NameSub = 'user_init_session'
    !--------------------------------------------------------------------------
    call stop_user(NameSub)
  end subroutine user_init_session
  !============================================================================

  subroutine user_action(NameAction)

    character(len=*), intent(in):: NameAction

    ! select case(NameAction)
    ! case('initial condition done')
    !  ...
    ! case('write progress')
    !  ...
    ! end select

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'user_action'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)
    call test_stop(NameSub, DoTest)
  end subroutine user_action
  !============================================================================
  subroutine user_specify_region(iArea, iBlock, nValue, NameLocation, &
       IsInside, IsInside_I, Value_I)

    ! geometric criteria

    integer,   intent(in):: iArea        ! area index in BATL_region
    integer,   intent(in):: iBlock       ! block index
    integer,   intent(in):: nValue       ! number of output values
    character, intent(in):: NameLocation ! c, g, x, y, z, or n

    logical, optional, intent(out) :: IsInside
    logical, optional, intent(out) :: IsInside_I(nValue)
    real,    optional, intent(out) :: Value_I(nValue)

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'user_specify_region'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest, iBlock)
    call stop_user(NameSub)

    call test_stop(NameSub, DoTest, iBlock)
  end subroutine user_specify_region
  !============================================================================

  subroutine user_amr_criteria(iBlock, UserCriteria, TypeCriteria, IsFound)

    integer, intent(in)          :: iBlock
    real, intent(out)            :: UserCriteria
    character(len=*), intent(in) :: TypeCriteria
    logical, intent(inout)       :: IsFound

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'user_amr_criteria'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest, iBlock)
    call stop_user(NameSub//'(TypeCrit='//TypeCriteria//')')

    call test_stop(NameSub, DoTest, iBlock)
  end subroutine user_amr_criteria
  !============================================================================

  subroutine user_read_inputs

    character(len=*), parameter:: NameSub = 'user_read_inputs'
    !--------------------------------------------------------------------------
    call stop_user(NameSub)
  end subroutine user_read_inputs
  !============================================================================

  subroutine user_get_log_var(VarValue, NameVar, Radius)

    real, intent(out)            :: VarValue
    character(len=*), intent(in) :: NameVar
    real, intent(in), optional   :: Radius

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'user_get_log_var'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)
    call stop_user(NameSub//'(NameVar='//NameVar//')')

    call test_stop(NameSub, DoTest)
  end subroutine user_get_log_var
  !============================================================================

  subroutine user_set_plot_var(iBlock, NameVar, IsDimensional, &
       PlotVar_G, PlotVarBody, UsePlotVarBody, &
       NameTecVar, NameTecUnit, NameIdlUnit, IsFound)

    use ModSize, ONLY: nI, nJ, nK

    integer,          intent(in)   :: iBlock
    character(len=*), intent(in)   :: NameVar
    logical,          intent(in)   :: IsDimensional
    real,             intent(out)  :: PlotVar_G(MinI:MaxI,MinJ:MaxJ,MinK:MaxK)
    real,             intent(out)  :: PlotVarBody
    logical,          intent(out)  :: UsePlotVarBody
    character(len=*), intent(inout):: NameTecVar
    character(len=*), intent(inout):: NameTecUnit
    character(len=*), intent(inout):: NameIdlUnit
    logical,          intent(out)  :: IsFound

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'user_set_plot_var'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest, iBlock)
    call stop_user(NameSub//'(NameVar='//NameVar//')')

    call test_stop(NameSub, DoTest, iBlock)
  end subroutine user_set_plot_var
  !============================================================================

  subroutine user_calc_sources(iBlock)

    integer, intent(in) :: iBlock

    character(len=*), parameter:: NameSub = 'user_calc_sources'
    !--------------------------------------------------------------------------
    call stop_user(NameSub)
  end subroutine user_calc_sources
  !============================================================================

  subroutine user_init_point_implicit

    character(len=*), parameter:: NameSub = 'user_init_point_implicit'
    !--------------------------------------------------------------------------
    call stop_user(NameSub)

  end subroutine user_init_point_implicit
  !============================================================================

  subroutine user_get_b0(x, y, z, B0_D)

    real, intent(in)   :: x, y, z
    real, intent(inout):: B0_D(3)

    character(len=*), parameter:: NameSub = 'user_get_b0'
    !--------------------------------------------------------------------------
    call stop_user(NameSub)
  end subroutine user_get_b0
  !============================================================================

  subroutine user_update_states(iBlock)

    integer,intent(in):: iBlock

    character(len=*), parameter:: NameSub = 'user_update_states'
    !--------------------------------------------------------------------------
    call stop_user(NameSub)
  end subroutine user_update_states
  !============================================================================

  subroutine user_normalization
    use ModPhysics

    character(len=*), parameter:: NameSub = 'user_normalization'
    !--------------------------------------------------------------------------
    call stop_user(NameSub)
  end subroutine user_normalization
  !============================================================================

  subroutine user_io_units
    use ModPhysics

    character(len=*), parameter:: NameSub = 'user_io_units'
    !--------------------------------------------------------------------------
    call stop_user(NameSub)
  end subroutine user_io_units
  !============================================================================

  subroutine user_set_resistivity(iBlock, Eta_G)
    ! This subrountine set the eta for every block
    use ModSize

    integer, intent(in) :: iBlock
    real,    intent(out):: Eta_G(MinI:MaxI,MinJ:MaxJ,MinK:MaxK)

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'user_set_resistivity'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest, iBlock)
    call stop_user(NameSub)

    call test_stop(NameSub, DoTest, iBlock)
  end subroutine user_set_resistivity
  !============================================================================

  subroutine user_material_properties(State_V, i, j, k, iBlock, iDir, &
       EinternalIn, TeIn, NatomicOut, AverageIonChargeOut, &
       EinternalOut, TeOut, PressureOut, &
       CvOut, GammaOut, HeatCondOut, IonHeatCondOut, TeTiRelaxOut, &
       OpacityPlanckOut_W, OpacityEmissionOut_W, OpacityRosselandOut_W, &
       PlanckOut_W)

    ! The State_V vector is in normalized units, all other physical
    ! quantities are in SI.
    !
    ! If the electron energy is used, then EinternalIn, EinternalOut,
    ! PressureOut, CvOut refer to the electron internal energies,
    ! electron pressure, and electron specific heat, respectively.
    ! Otherwise they refer to the total (electron + ion) internal energies,
    ! total (electron + ion) pressure, and the total specific heat.

    use ModAdvance,    ONLY: nWave
    use ModVarIndexes, ONLY: nVar

    real, intent(in) :: State_V(nVar)
    integer, optional, intent(in):: i, j, k, iBlock, iDir  ! cell/face index
    real, optional, intent(in)  :: EinternalIn             ! [J/m^3]
    real, optional, intent(in)  :: TeIn                    ! [K]
    real, optional, intent(out) :: NatomicOut              ! [1/m^3]
    real, optional, intent(out) :: AverageIonChargeOut     ! dimensionless
    real, optional, intent(out) :: EinternalOut            ! [J/m^3]
    real, optional, intent(out) :: TeOut                   ! [K]
    real, optional, intent(out) :: PressureOut             ! [Pa]
    real, optional, intent(out) :: CvOut                   ! [J/(K*m^3)]
    real, optional, intent(out) :: GammaOut                ! dimensionless
    real, optional, intent(out) :: HeatCondOut             ! [J/(m*K*s)]
    real, optional, intent(out) :: IonHeatCondOut          ! [J/(m*K*s)]
    real, optional, intent(out) :: TeTiRelaxOut            ! [1/s]
    real, optional, intent(out) :: &
         OpacityPlanckOut_W(nWave)                         ! [1/m]
    real, optional, intent(out) :: &
         OpacityEmissionOut_W(nWave)                       ! [1/m]
    real, optional, intent(out) :: &
         OpacityRosselandOut_W(nWave)                      ! [1/m]

    ! Multi-group specific interface. The variables are respectively:
    !  Group Planckian spectral energy density
    real, optional, intent(out) :: PlanckOut_W(nWave)      ! [J/m^3]

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'user_material_properties'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest, iBlock)
    call stop_user(NameSub)

    call test_stop(NameSub, DoTest, iBlock)
  end subroutine user_material_properties
  !============================================================================
  integer function user_block_type(iBlock)
    integer, intent(in), optional:: iBlock
    !--------------------------------------------------------------------------
    user_block_type = 0
  end function user_block_type
  !============================================================================
  subroutine stop_user(NameSub)
    ! Note that this routine is not a user routine but just a routine
    ! which warns the user if they try to use an unimplemented user routine.

    character(len=*), intent(in) :: NameSub
    !--------------------------------------------------------------------------
    call stop_mpi('You are trying to call the empty user routine '//   &
         NameSub//'. Please implement the routine in src/ModUser.f90')
  end subroutine stop_user
  !============================================================================

end module ModUserEmpty
!==============================================================================
