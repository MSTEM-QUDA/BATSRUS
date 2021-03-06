!  Copyright (C) 2002 Regents of the University of Michigan,
!  portions used with permission
!  For more information, see http://csem.engin.umich.edu/tools/swmf

module ModAdvanceExplicit

  use BATL_lib, ONLY: &
       test_start, test_stop, iThread

  implicit none
  private ! except

  public:: advance_explicit ! advance state variables with explicit method

contains
  !============================================================================

  subroutine advance_explicit(DoCalcTimestep)

    use ModMain
    use ModFaceBoundary, ONLY: set_face_boundary
    use ModFaceFlux,   ONLY: calc_face_flux, calc_cell_flux
    use ModFaceValue,  ONLY: calc_face_value, calc_cell_norm_velocity, &
         set_low_order_face
    use ModAdvance,    ONLY: UseUpdateCheck, DoFixAxis, DoCalcElectricField, &
         DoInterpolateFlux, UseAdaptiveLowOrder, UseMhdMomentumFlux
    use ModCoarseAxis, ONLY: UseCoarseAxis, coarsen_axis_cells
    use ModB0,         ONLY: set_b0_face
    use ModParallel,   ONLY: neiLev
    use ModGeometry,   ONLY: Body_BLK, true_BLK
    use ModBlockData,  ONLY: set_block_data
    use ModImplicit,   ONLY: UsePartImplicit
    use ModPhysics,    ONLY: No2Si_V, UnitT_, UseBody2Orbit
    use ModCalcSource, ONLY: calc_source
    use ModConserveFlux, ONLY: save_cons_flux, apply_cons_flux, &
         nCorrectedFaceValues, CorrectedFlux_VXB, &
         CorrectedFlux_VYB, CorrectedFlux_VZB, DoConserveFlux
    use ModCoronalHeating, ONLY: get_coronal_heat_factor, UseUnsignedFluxModel
    use ModMessagePass, ONLY: exchange_messages
    use ModTimeStepControl, ONLY: calc_timestep
    use BATL_lib, ONLY: message_pass_face, message_pass_cell, IsAnyAxis
    use ModResistivity, ONLY: set_resistivity, UseResistivity
    use ModFieldLineThread, ONLY: &
         UseFieldLineThreads, advance_threads, Enthalpy_
    use ModUpdateState, ONLY: update_check, update_state
    use ModConstrainDivB, ONLY: Bface2Bcenter, get_vxb, bound_vxb, constrain_b
    use ModFixAxisCells, ONLY: fix_axis_cells
    use ModElectricField, ONLY: get_num_electric_field, correct_efield_block
    use ModParticleMover, ONLY: UseChargedParticles=>UseParticles, &
         UseHybrid, trace_particles, get_state_from_vdf, advance_ion_current
    use ModViscosity, ONLY: UseArtificialVisco
    use omp_lib

    logical, intent(in) :: DoCalcTimestep

    integer :: iBlock

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'advance_explicit'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)

    ! Perform multi-stage update of solution for this time (iteration) step
    call timing_start(NameSub)

    ! OPTIMIZE: Is there a better place to update true_BLK? --Yuxi
    !$acc update device(true_BLK)

    if(UseBody2Orbit) call update_secondbody

    STAGELOOP: do iStage = 1, nStage
       !$acc update device(iStage)
       if(DoTest) write(*,*)NameSub,' starting stage=',iStage

       ! If heating model depends on global B topology, update here
       if(UseUnsignedFluxModel) call get_coronal_heat_factor

       if(.not.UseOptimizeMpi) call barrier_mpi2('expl1')

       if(UseResistivity) call set_resistivity

       if(iStage==1)then
          if(UseArtificialVisco .or. UseAdaptiveLowOrder) &
               call calc_cell_norm_velocity
          call set_low_order_face
       endif

       if(DoConserveFlux)then
          !$omp parallel do
          do iBlock=1,nBlock
             if(Unused_B(iBlock)) CYCLE
             if(all(neiLev(:,iBlock)/=1)) CYCLE
             ! Calculate interface values for L/R states of each
             ! fine grid cell face at block edges with resolution changes
             ! and apply BCs for interface states as needed.
             call set_b0_face(iBlock)
             call timing_start('calc_face_bfo')
             call calc_face_value(iBlock, DoResChangeOnly = .true. , DoMonotoneRestrict = .true.)
             call timing_stop('calc_face_bfo')

             if(body_BLK(iBlock)) &
                  call set_face_boundary(iBlock, Time_Simulation, .true.)

             ! Compute interface fluxes for each fine grid cell face at
             ! block edges with resolution changes.

             call timing_start('calc_fluxes_bfo')
             call calc_face_flux(.true., iBlock)
             call timing_stop('calc_fluxes_bfo')

             ! Save conservative flux correction for this solution block
             call save_cons_flux(iBlock)

          end do
          !$omp end parallel do

          if(DoTest)write(*,*)NameSub,' done res change only'

          ! Message pass conservative flux corrections.
          call timing_start('send_cons_flux')
          call message_pass_face(nCorrectedFaceValues, CorrectedFlux_VXB, &
               CorrectedFlux_VYB, CorrectedFlux_VZB, DoSubtractIn=.false.)

          call timing_stop('send_cons_flux')

          if(DoTest)write(*,*)NameSub,' done message pass'

       endif

       ! Multi-block solution update.
       !$acc parallel
       !$acc loop gang
       !$omp parallel do
       do iBlock = 1,nBlock

          if(Unused_B(iBlock)) CYCLE

#ifndef OPENACC
          ! Calculate interface values for L/R states of each face
          ! and apply BCs for interface states as needed.
          call set_b0_face(iBlock)

          if(DoInterpolateFlux)then
             call timing_start('calc_fluxes')
             call calc_cell_flux(iBlock)
             call timing_stop('calc_fluxes')
          end if
#endif

#ifndef OPENACC
          call timing_start('calc_facevalues')
#endif

          call calc_face_value(iBlock, DoResChangeOnly= .false. , DoMonotoneRestrict = .true.)

#ifndef OPENACC
          call timing_stop('calc_facevalues')

          if(body_BLK(iBlock)) &
               call set_face_boundary(iBlock, Time_Simulation,.false.)
#endif

          if(.not.DoInterpolateFlux)then
             ! Compute interface fluxes for each cell.
#ifndef OPENACC
             call timing_start('calc_fluxes')
#endif
             call calc_face_flux(.false., iBlock)
#ifndef OPENACC
             call timing_stop('calc_fluxes')
#endif
          end if

#ifndef OPENACC
          ! Enforce flux conservation by applying corrected fluxes
          ! to each coarse grid cell face at block edges with
          ! resolution changes.
          if(DoConserveFlux) call apply_cons_flux(iBlock)
#endif

#ifndef OPENACC
          ! Compute source terms for each cell.
          call timing_start('calc_sources')
#endif
          call calc_source(iBlock)

#ifndef OPENACC
          call timing_stop('calc_sources')
#endif

#ifndef OPENACC
          ! With known magnetic field and electric field in the
          ! comoving frame update ion velocities at the half time-step
          if(UseFlic.and.iStage>=2)call advance_ion_current(iBlock)
          ! Electric field in the comoving frame is calculated
          ! and, probably used, in calc_sorces. Add -UxB, to get field
          ! in the global coordinate frame
          if(UseChargedParticles.and.UseMhdMomentumFlux)&
               call correct_efield_block(iBlock)
          ! In the course of second stage in the FLIC scheme nothing
          ! is updated instead of the (multi)ion currents, which are
          ! updated by advance_ion_current.
          if(UseFlic.and.iStage==2)CYCLE
          ! Calculate time step (both local and global
          ! for the block) used in multi-stage update
          ! for steady state calculations.
          ! Also calculate time step when UseDtLimit is true.
          if((.not.time_accurate .or. UseDtLimit).and. iStage == 1 &
               .and. DoCalcTimestep) call calc_timestep(iBlock)

          ! Update solution state in each cell.
          call timing_start('update_state')
#endif

          call update_state(iBlock)

#ifndef OPENACC
          call timing_stop('update_state')

          if(DoCalcElectricField .and. iStage == nStage) &
               call get_num_electric_field(iBlock)

          if(UseConstrainB .and. iStage == nStage)then
             call timing_start('constrain_B')
             call get_VxB(iBlock)
             call bound_VxB(iBlock)
             call timing_stop('constrain_B')
          end if
#endif

          ! Calculate time step (both local and global
          ! for the block) used in multi-stage update
          ! for time accurate calculations.
          ! For time accurate with UseDtLimit, do not
          ! calculate time step.
          if(time_accurate .and. .not.UseDtLimit .and. &
               iStage == nStage .and. DoCalcTimestep) &
               call calc_timestep(iBlock)

#ifndef OPENACC
          ! At this point the user has surely set all "block data"
          ! NOTE: The user has the option of calling set_block_data directly.
          call set_block_data(iBlock)
#endif
       end do ! Multi-block solution update loop.
       !$omp end parallel do
       !$acc end  parallel

       if(DoTest)write(*,*)NameSub,' done update blocks'

       if(.not.UseOptimizeMpi) call barrier_mpi2('expl2')

       if(IsAnyAxis .and. DoFixAxis) call fix_axis_cells
       if(UseCoarseAxis) call coarsen_axis_cells

       ! Check for allowable update percentage change.
       if(UseUpdateCheck)then
          call timing_start('update_check')
          call update_check
          call timing_stop('update_check')

          if(DoTest)write(*,*)NameSub,' done update check'
       end if

       if(UseConstrainB .and. iStage==nStage)then
          call timing_start('constrain_B')
          ! Correct for consistency at resolution changes
          ! call correct_VxB

          ! Update face centered and cell centered magnetic fields
          do iBlock = 1, nBlock
             if(Unused_B(iBlock))CYCLE
             call constrain_B(iBlock)
             call Bface2Bcenter(iBlock)
          end do
          call timing_stop('constrain_B')
          if(DoTest)write(*,*)NameSub,' done constrain B'
       end if

       if(DoCalcTimeStep)then
          ! Update check only works for half step 2 stages time integration.
          ! The final Dt is determined by the second stage if Dt changed by
          ! update_check subroutine.
          if(UseUpdateCheck .and. iStage==1) &
               Time_SimulationOld = Time_Simulation
          if(UseFlic)then
             ! Staging Dt/2; Dt/2; Dt
             if(iStage/=2)Time_Simulation = Time_Simulation + &
                  Dt*No2Si_V(UnitT_)/2
          else
             Time_Simulation = Time_Simulation + Dt*No2Si_V(UnitT_)/nStage
          end if
          if(UseUpdateCheck .and. iStage==nStage) &
               Time_Simulation = Time_SimulationOld + Dt*No2Si_V(UnitT_)
       endif
       ! If we have particle to move in the electromagnetic field,
       ! test or hybrid ones
       if(UseChargedParticles)then
          if(iStage==1)then
             ! Ballistically (with no change in particle velocity)
             ! propagate particles for a half time-step
             ! This step corresponds to Equation 16 of Moschou, Sokolov et al.
             ! 2019 Hybrid paper of ASTRONUM
             call trace_particles(Dt=Dt, DoBorisStepIn=.false.)
             if(UseHybrid)call get_state_from_vdf
          end if
          ! Calculate acceleration by the electromagnetic force.
          ! This step corresponds to Equation 7, 21 and Stage 2 in Figure 2
          ! of the Moschou, Sokolov et al. 2019 Hybrid paper of ASTRONUM
          ! Then ballistically (with no change in particle velocity)
          ! propagate them for a half time-step
          ! This step corresponds to Equation 16 of Moschou, Sokolov et al. 2019
          ! Hybrid paper of ASTRONUM
          if(UseFlic)then
             if(iStage==2)call trace_particles(&
                  Dt=Dt, DoBorisStepIn=.true.)
             if(iStage==3.and.UseHybrid)call get_state_from_vdf
          else
             if(iStage==nStage)call trace_particles(&
                  Dt=Dt, DoBorisStepIn=.true.)
          end if
       end if
       if(iStage < nStage)then
          if(UseFieldLineThreads) call advance_threads(Enthalpy_)
          call exchange_messages
       end if

       if(DoTest)write(*,*)NameSub,' finished stage=',istage

    end do STAGELOOP  ! Multi-stage solution update loop.

    call timing_stop(NameSub)

    if(DoTest)write(*,*)NameSub,' finished'

    call test_stop(NameSub, DoTest)
  end subroutine advance_explicit
  !============================================================================

  subroutine update_secondbody
    use ModMain,     ONLY: time_simulation, nBlock
    use ModConst,    ONLY: cTwoPi
    use ModPhysics,  ONLY: xBody2,yBody2,OrbitPeriod,PhaseBody2,DistanceBody2
    use ModMessagePass,      ONLY: exchange_messages
    use ModBoundaryGeometry, ONLY: fix_block_geometry

    integer :: iBlock

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'update_secondbody'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)

    ! Update second body coordinates
    xBody2 = DistanceBody2*cos(cTwoPi*Time_Simulation/OrbitPeriod + PhaseBody2)
    yBody2 = DistanceBody2*sin(cTwoPi*Time_Simulation/OrbitPeriod + PhaseBody2)

    do iBlock = 1, nBlock
       ! This might not work together with solid
       call fix_block_geometry(iBlock)
    end do

    ! call set_body_flag ! OLDAMR
    call exchange_messages

    call test_stop(NameSub, DoTest)
  end subroutine update_secondbody
  !============================================================================

end module ModAdvanceExplicit
!==============================================================================
