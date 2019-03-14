!  Copyright (C) 2002 Regents of the University of Michigan,
!  portions used with permission
!  For more information, see http://csem.engin.umich.edu/tools/swmf

module ModParticleMover
  use BATL_lib, ONLY: &
       test_start, test_stop
  use BATL_lib, ONLY: nDim, nI, nJ, nK, nIJK, nG, &
       MinI, MaxI, MinJ, MaxJ, MinK, MaxK, MaxDim, &
       nBlock, MaxBlock, Unused_B, &
       iProc, iComm, message_pass_cell

  use ModAdvance,      ONLY: Efield_DGB
  use ModMain,         ONLY: n_step
  use ModGeometry,     ONLY: far_field_bcs_blk, true_cell
  use ModCellBoundary, ONLY: set_cell_boundary
  use ModParticles,    ONLY: allocate_particles, message_pass_particles
  use BATL_particles,  ONLY: Particle_I, remove_undefined_particles, &
       mark_undefined, check_particle_location, put_particles, &
       set_pointer_to_particles, trace_particles
  implicit none
  SAVE
  !\
  !Parameters
  !/
  ! number of particles with different charge-to-mass ratios
  integer :: nKindChargedParticles = 0 
  !\
  ! The order number of this kind of particle in the whole 
  ! BATL_particle repository
  !/
  integer, allocatable :: iKindParticle_I(:)
  !\
  !Charge to mass ratio, same for all particles of a given 
  !kind
  !/
  real,    allocatable :: Charge2Mass_I(:)
  !\
  ! Named indexes
  !/
  integer, parameter :: nVar = 2*nDim +1, x_ = 1, y_ = 2, z_=nDim,  &
       Ux_ = nDim + x_, Uy_= nDim + y_, Uz_ = 2*nDim, Mass = Uz_ +1,&
       Status_ = 1, DoAll_ = 1, DoCollect_ = 2, Done_= 3 
  logical :: DoInit = .true.
  real, allocatable :: Mass_I(:), Charge_I(:)
  integer, allocatable:: nParticleMax_I(:)
  real,    pointer :: Coord_DI(:,:)
  integer, pointer :: Index_II(:,:)
  !\
  ! Global variables to be shared by more than one routine
  real    :: Dt          !Time step
  integer :: iKind       !Sort of particles
  real    :: Charge2Mass !For a given sort of particles
contains
  !=============read_param=============================!
  !subroutine read the following paramaters from the PARAM.in file:
  !#CHARGEDPARTICLES
  !3                      nKindChargedParticles
  !4.0                    Mass
  !2.0                    Charge
  !1000000                nParticleMax
  !16.0                   Mass
  !6.0                    Charge
  !500000                 nParticleMax
  !16.0                   Mass
  !7.0                    Charge
  !500000                 nParticleMax
  !--------------------------------------------------------------------------
  subroutine read_param(NameCommand)

    use ModMain,      ONLY: NameThisComp
    use ModParticles, ONLY: deallocate_particles
    use ModReadParam, ONLY: read_var

    character(len=*), intent(in) :: NameCommand

    logical:: DoTest, UseParticles = .false.
    integer :: iKind
    character(len=*), parameter:: NameSub = 'read_charged_particle_param'
    !--------------------------------------------------------------------
    call test_start(NameSub, DoTest)
    select case(NameCommand)
    case("#CHARGEDPARTICLES")
       call read_var('nKindChargedParticles', nKindChargedParticles)
       if(nKindChargedParticles<= 0) then
          if(UseParticles)then
             !\
             ! Deallocate particles used in the previous session
             !/
             do iKind = 1, size(iKindParticle_I)
                call deallocate_particles(&
                      iKindParticle_I(iKind))
             end do
          end if
          UseParticles = .false.
          RETURN
       end if
       UseParticles = .true.
       allocate(  Mass_I(nKindChargedParticles))
       allocate(Charge_I(nKindChargedParticles))
       allocate(nParticleMax_I(nKindChargedParticles))
       do iKind = 1, nKindChargedParticles 
          call read_var('Mass_I', Mass_I(iKind))
          if(Mass_I(iKind)<= 0) call stop_mpi(&
               NameThisComp//':'//NameSub//&
               ': invalid mass of charged particle kind')
          call read_var('Charge_I', Charge_I(iKind))
          call read_var('nParticleMax_I', nParticleMax_I(iKind))
          if(nParticleMax_I(iKind)<= 0) call stop_mpi(&
               NameThisComp//':'//NameSub//&
               ': invalid number of charged particles for ikind')
       end do
    case default
       call stop_mpi(&
            NameThisComp//':'//NameSub//&
            ': Unknown command '//NameCommand//' in PARAM.in')
    end select
    call allocate_charged_particles(Mass_I, Charge_I, nParticleMax_I)
    deallocate(Mass_I, Charge_I, nParticleMax_I)
    call test_stop(NameSub, DoTest)
  end subroutine read_param
  !====================================================
  subroutine allocate_charged_particles(Mass_I, Charge_I, nParticleMax_I)
    real,    intent(in)    :: Mass_I(nKindChargedParticles) 
    real,    intent(in)    :: Charge_I(nKindChargedParticles)
    integer, intent(in)    :: nParticleMax_I(nKindChargedParticles)
    integer :: iKind
    logical:: DoTest
    character(len=*), parameter:: NameSub = 'allocate_charged_particles'
    !-----------------------------!
    call test_start(NameSub, DoTest)
    if(.not.DoInit) RETURN
    DoInit = .false.
    !Allocate enough arrays for all Charged Particle Types
    allocate(iKindParticle_I(nKindChargedParticles)) 
    allocate(Charge2Mass_I(nKindChargedParticles))
    Charge2Mass_I = Charge_I/Mass_I
    iKindParticle_I = -1
    do iKind = 1, nKindChargedParticles 
       call allocate_particles(&
            iKindParticle = iKindParticle_I(iKind), &
            nVar          = nVar    , &
            nIndex        = 1  , &
            nParticleMax  = nParticleMax_I(iKind)    )
    end do
    call test_stop(NameSub, DoTest)
  end subroutine allocate_charged_particles
  !===============================================!
  subroutine trace_charged_particles(DtIn)
    real, intent(in) :: DtIn
    integer :: iLoop, nParticle
    !----------------------
    Dt = DtIn
    do iLoop = 1, nKindChargedParticles
       iKind = iKindParticle_I(iKind)
       call set_pointer_to_particles(&
            iKind, Coord_DI, Index_II, &
            nParticle=nParticle)
       Index_II(Status_,1:nParticle) = DoAll_
       call trace_particles(iKind, boris_scheme, check_done)
    end do

  end subroutine trace_charged_particles
  !=====================================
  subroutine boris_scheme(iParticle, EndOfSegment)
    use ModBatlInterface, ONLY: interpolate_grid_amr_gc
    integer, intent(in)  :: iParticle
    logical, intent(out) :: EndOfSegment
    !\
    ! Coords
    !/
    real :: Xyz_D(MaxDim)
    integer  :: iBlock
    ! interpolation data: number of cells, cell indices, weights
    integer:: nCell, iCell_II(0:nDim, 2**nDim)
    real   :: Weight_I(2**nDim)
    logical :: IsGone, DoMove
    !---------------------
    EndOfSegment = .true. !Do not repeat
    if(Index_II(Status_, iParticle) == Done_)RETURN
    if(Index_II(Status_, iParticle) == DoAll_)then
       ! Coordinates and block #
       Xyz_D   = 0.0
       Xyz_D(1:nDim)   = Coord_DI(x_:z_, iParticle)
       iBlock          = Index_II(0,iParticle)
       call interpolate_grid_amr_gc(&
            Xyz_D, iBlock, nCell, iCell_II, Weight_I)
       !\
       ! Interpolate field with obtained weight coefficients
       !/
       !\
       ! Update velocity
       !/
       !.................
       !\
       ! Update coordinates
       !/
       Coord_DI(x_:z_, iParticle) = Coord_DI(x_:z_, iParticle) + &
            Dt*Coord_DI(Ux_:Uz_,iParticle)
       ! check location, schedule for message pass, if needed
       call check_particle_location(       &
            iKindParticle = iKind         ,&
            iParticle     = iParticle,     &
            DoMove        = DoMove        ,&
            IsGone        = IsGone    )
       if(IsGone)then
          !\
          ! Particle left the computational domain, schedule for 
          ! removal
          !/
          call mark_undefined(iKind, iParticle)
          RETURN
       elseif(DoMove)then
          !\
          ! Particle will be send to other processor, the current
          ! will be collected there
          !/
          Index_II(Status_,iParticle) = DoCollect_
          RETURN
       end if
    end if
    ! Coordinates and block #
    Xyz_D   = 0.0
    Xyz_D(1:nDim)   = Coord_DI(x_:z_, iParticle)
    iBlock          = Index_II(0,iParticle)
    call interpolate_grid_amr_gc(&
         Xyz_D, iBlock, nCell, iCell_II, Weight_I)
    !\
    ! Collect current with updated weight coefficients
    !/
    !..................................
    Index_II(Status_, iParticle) = Done_
  end subroutine boris_scheme
  !==========================
  subroutine check_done(Done)
    ! check whether all paritcles have been advanced through 
    ! full time step
    logical, intent(out):: Done
    !--------------------------------------------------------------------------
    Done = all(Index_II(Status_,1:Particle_I(iKind)%nParticle)==Done_)
  end subroutine check_done
end module ModParticleMover
