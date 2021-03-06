!  Copyright (C) 2002 Regents of the University of Michigan,
!  portions used with permission
!  For more information, see http://csem.engin.umich.edu/tools/swmf

module ModParticleFieldLine

  use BATL_lib, ONLY: &
       test_start, test_stop, iProc, nProc, iComm
#ifdef OPENACC
  use ModUtilities, ONLY: norm2
#endif
  ! This module contains subroutine for extracting magnetic field lines
  ! for passing to other codes;
  ! field line intergration is performed with use of BATL library including
  ! - continuous AMR interpolation
  ! - particle methods
  use BATL_lib, ONLY: &
       MaxDim, nDim, MaxBlock, nI, nJ, nK, nBlock,     &
       Xyz_DGB, CellVolume_GB, Unused_B, &
       Particle_I, trace_particles,                           &
       mark_undefined, check_particle_location, put_particles
  use ModParticles, ONLY: allocate_particles
  use ModBatlInterface, ONLY: interpolate_grid_amr_gc
  use ModAdvance, ONLY: State_VGB
  use ModVarIndexes, ONLY: Rho_, RhoUx_, RhoUz_, B_, Bx_, Bz_
  use ModMain, ONLY: NameThisComp
  use ModCellGradient, ONLY: calc_gradient_ghost, &
       GradCosBR_DGB => GradVar_DGB
  implicit none
  SAVE
  private ! except

  public:: read_particle_line_param
  public:: init_particle_line
  public:: extract_particle_line
  public:: advect_particle_line
  public:: get_particle_data
  public:: write_plot_particle

  ! Local variables ----------------------
  ! use particles in the simulation
  logical, public :: UseParticles = .false.
  ! kinds of particles used to generate a magnetic field line
  integer :: &
       KindEnd_ = -1, &
       KindReg_ = -1

  ! variable in the state vector of a particle
  integer, parameter:: &
       ! coordinates of a particle
       x_    = 1, y_    = 2, z_    = 3, &
       ! storage for particle's position at the beginning of the step
       XOld_ = 4, YOld_ = 5, ZOld_ = 6, &
       ! stepsize during line extraction
       Ds_   = 7, &
       ! grad CosBR at the beginning of extraction iteration
       GradCosBRX_= 8, GradCosBRZ_ = 10, &
       ! value of CosBR at the beginning of extraction iteration
       CosBR_   =  11, &
       ! previous direction
       DirX_ = 12, DirZ_ = 14

  ! indices of a particle
  integer, parameter:: &
       ! field line this particle lays on
       fl_        = 1, &
       ! index of the particle along this field line
       id_        = 2, &
       ! indicator for message passing in trace_particle_line
       Pass_      = 3, &
       ! alignment of particle numbering with direction of B field:
       ! ( -1 -> reversed, +1 -> aligned); important for radial ordering
       ! when magnetic field general direction may be inward
       Alignment_ = 4

  integer, parameter::    &
       Normal_ = 0       ,&
       HalfStep_ = 1     ,&
       DoneFromScratch_ = 2

  ! data that can be requested and returned to outside this module
  ! ORDER MUST CORRESPOND TO INDICES ABOVE
  integer, parameter:: nVarAvail = 3, nIndexAvail = 2, nDataMax = &
       nVarAvail + nIndexAvail +1
  character(len=2), parameter:: NameVarAvail_V(nVarAvail) = &
       ['xx', 'yy', 'zz']
  character(len=2), parameter:: NameIndexAvail_I(0:nIndexAvail) = &
       ['bk','fl', 'id']

  ! spatial step limits at the field line extraction
  real   :: SpaceStepMin = 0.0
  real   :: SpaceStepMax = HUGE(SpaceStepMin)

  ! ordering mode of particles along field lines
  integer:: iOrderMode = -1
  integer, parameter:: Field_ = 0, Radius_  = 1

  ! number of variables in the state vector
  integer, parameter:: nVarParticleReg = 6
  integer, parameter:: nVarParticleEnd = 14

  ! number of indices
  integer, parameter:: nIndexParticleReg = 3
  integer, parameter:: nIndexParticleEnd = 4

  ! maximum allowed number of field lines
  integer :: nFieldLineMax

  ! approximate number of particles per field line
  integer :: nParticlePerLine

  ! number of active field lines
  integer:: nFieldLine = 0

  ! soft radial boundary that may be set only once during the run;
  ! "soft" means that particles are allowed beyond this boundary BUT:
  ! - during extraction first particle that crosses it is kept but extraction
  !   of this line is stopped
  real:: RSoftBoundary = -1.0

  ! may need to apply corrections during line tracing
  logical:: UseCorrection=.false.
  real:: RCorrectionMin = 0.0, RCorrectionMax = Huge(1.0)

  ! field line random walk (FLRW)
  logical:: UseFLRW = .false.
  real:: DeltaPhiFLRW = 0.0

  ! initialization related info
  integer:: nLineInit
  real, allocatable:: XyzLineInit_DI(:,:)
  ! Shared variavles
  ! direction of tracing: -1 -> backward, +1 -> forward
  integer:: iDirTrace

  ! state and indexes for particles:
  real,    pointer::  StateEnd_VI(:,:), StateReg_VI(:,:)
  integer, pointer:: iIndexEnd_II(:,:),iIndexReg_II(:,:)
  public :: KindReg_, x_,y_, z_, fl_, id_, RSoftBoundary
contains
  !============================================================================
  subroutine read_particle_line_param(NameCommand)

    use ModReadParam, ONLY: read_var
    use ModNumConst,  ONLY: cPi

    character(len=*), intent(in) :: NameCommand

    character(len=100) :: StringInitMode
    character(len=100) :: StringOrderMode
    integer:: iLine, iDim ! loop variables

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'read_particle_line_param'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)
    select case(NameCommand)
    case("#PARTICLELINE")
       call read_var('UseParticles', UseParticles)
       if(UseParticles)then
          ! read info on size of the arrays to be allocated:
          ! max total number of field lines (on all procs)
          call read_var('nFieldLineMax', nFieldLineMax)
          ! number of particles per field line (average)
          call read_var('nParticlePerLine', nParticlePerLine)
          ! check correctness
          if(nFieldLineMax <= 0) call stop_mpi(&
               NameThisComp//':'//NameSub//&
               ': invalid max number of field lines')
          if(nParticlePerLine <= 0) call stop_mpi(&
               NameThisComp//':'//NameSub//&
               ': invalid number of particles per field lines')
          !--------------------------------------------------------------
          ! read min and max values for space step
          ! based on their values space step may be
          ! - both negative => automatic (defined by grid resolution)
          ! - otherwise     => restricted by min and/or max
          !                    whichever is positive
          call read_var('SpaceStepMin', SpaceStepMin)
          call read_var('SpaceStepMax', SpaceStepMax)
          ! negative value means "undefined"
          if(SpaceStepMin < 0) SpaceStepMin = 0
          if(SpaceStepMax < 0) SpaceStepMax = HUGE(SpaceStepMin)
          !--------------------------------------------------------------
          call read_var('InitMode', StringInitMode, IsLowerCase=.true.)
          ! Initialization modes:
          ! - preset: starting points are set from PARAM.in file
          if(index(StringInitMode, 'preset') > 0)then
             call read_var('nLineInit', nLineInit)
             if(nLineInit <= 0)&
                  call stop_mpi(&
                  NameThisComp//':'//NameSub // &
                  ": invalid number of initialized particle lines")
             allocate(XyzLineInit_DI(MaxDim, nLineInit))
             do iLine = 1, nLineInit; do iDim = 1, MaxDim
                call read_var('XyzLineInit_DI', XyzLineInit_DI(iDim, iLine))
             end do; end do
          elseif(index(StringInitMode, 'import') > 0)then
             ! do nothing: particles are imported from elsewhere
          else
             call stop_mpi(&
                  NameThisComp//':'//NameSub //": unknown initialization mode")
          end if
          !--------------------------------------------------------------
          call read_var('OrderMode', StringOrderMode, IsLowerCase=.true.)
          ! Ordering modes, particle index increases with:
          ! - radius:  distance from the center
          ! - field: along the direction of the magnetic field
          if(    index(StringOrderMode, 'field') > 0)then
             iOrderMode = Field_
          elseif(index(StringOrderMode, 'radius' ) > 0)then
             iOrderMode = Radius_
          else
             call stop_mpi(NameThisComp//':'//NameSub //&
                  ": unknown ordering mode")
          end if
          !--------------------------------------------------------------
          ! field lines may need to be corrected during tracing
          call read_var('UseCorrection', UseCorrection)
          if(UseCorrection)then
             ! use may specify the boundaries where the correction is applied
             call read_var('RCorrectionMin', RCorrectionMin)
             if(RCorrectionMin < 0.0) RCorrectionMin = 0.0
             call read_var('RCorrectionMax', RCorrectionMax)
             if(RCorrectionMax < 0.0) RCorrectionMax = Huge(1.0)
          end if
       end if
    case("#PARTICLELINERANDOMWALK")
       ! field line random walk may be enabled
       call read_var('UseFLRW', UseFLRW)
       if(UseFLRW)then
          ! read root-mean-square angle of field line diffusion coefficient
          call read_var('DeltaPhiFLRW [degree]', DeltaPhiFLRW)
          DeltaPhiFLRW = DeltaPhiFLRW * cPi / 180
       end if
    end select
    call test_stop(NameSub, DoTest)
  end subroutine read_particle_line_param
  !============================================================================

  subroutine init_particle_line
    ! allocate containers for particles
    logical, save:: DoInit = .true.
    logical:: DoTest
    character(len=*), parameter:: NameSub = 'init_particle_line'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)
    if(.not.DoInit) RETURN
    DoInit = .false.
    call allocate_particles(&
         iKindParticle = KindReg_,  &
         nVar   = nVarParticleReg,  &
         nIndex = nIndexParticleReg,&
         nParticleMax = nParticlePerLine * nFieldLineMax)
    call allocate_particles(&
         iKindParticle = KindEnd_  ,&
         nVar   = nVarParticleEnd  ,&
         nIndex = nIndexParticleEnd,&
         nParticleMax = nFieldLineMax)
    ! set pointers to parameters of end particles
    StateEnd_VI  => Particle_I(KindEnd_)%State_VI
    iIndexEnd_II => Particle_I(KindEnd_)%iIndex_II
    StateReg_VI  => Particle_I(KindReg_)%State_VI
    iIndexReg_II => Particle_I(KindReg_)%iIndex_II
    if(nLineInit > 0)&
         ! extract initial field lines
         call extract_particle_line(XyzLineInit_DI)
    call test_stop(NameSub, DoTest)
  end subroutine init_particle_line
  !============================================================================
  subroutine extract_particle_line(Xyz_DI, iTraceModeIn, &
       iIndex_II, UseInputInGenCoord)
    ! extract nFieldLineIn magnetic field lines starting at Xyz_DI;
    ! the whole field lines are extracted, i.e. they are traced forward
    ! and backward up until it reaches boundaries of the domain;
    ! requested coordinates may be different for different processor,
    ! if a certain line can't be started on a given processor, it is
    ! ignored, thus duplicates are avoided
    ! NOTE: different sets of lines may be request on different processors!
    real,            intent(in) ::Xyz_DI(:, :)
    ! mode of tracing (forward, backward or both ways)
    integer,optional,intent(in) ::iTraceModeIn
    ! initial particle indices for starting particles
    integer,optional,intent(in) :: iIndex_II(:,:)

    ! An input can be in generalized coordinates
    logical, optional,intent(in) :: UseInputInGenCoord
    integer :: nLineThisProc! number of new field lines initialized locally
    integer :: nLineAllProc ! number of new field lines initialized on all PEs
    integer :: nParticleOld ! number of already existing regular particles
    integer :: nParticleAll ! number of all particles on all PEs

    ! mode of tracing (see description below)
    integer:: iTraceMode

    ! Cosine between direction of the field and radial direction:
    ! for correcting the line's direction to prevent it from closing
    real, allocatable:: CosBR_CB(:,:,:,:)

    ! initialize field lines
    logical:: DoTest
    character(len=*), parameter:: NameSub = 'extract_particle_line'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)
    call  put_particles(&
         iKindParticle      = KindEnd_,          &
         StateIn_VI         = Xyz_DI,            &
         iLastIdIn          = nFieldLine,        &
         iIndexIn_II        = iIndex_II,         &
         UseInputInGenCoord = UseInputInGenCoord,&
         DoReplace          = .true.,            &
         nParticlePE        = nLineThisProc)

    ! how many lines have been started on all processors
    call count_new_lines() ! nLineAllProc = sum(nLineThisProc)
    nFieldLine    = nFieldLine + nLineAllProc
    if(nFieldLine > nFieldLineMax)&
         call stop_mpi(NameThisComp//':'//NameSub//&
         ': Limit for number of particle field lines exceeded')
    ! Save number of regular particles
    nParticleOld  = Particle_I(KindReg_)%nParticle
    ! Copy end points to regular points. Note, that new regular points
    ! have numbers nParticleOld+1:nParticleOld+nLineThisProc
    call copy_end_to_regular
    ! allocate containers for cosine of angle between B and radial direction
    allocate(CosBR_CB(1:nI, 1:nJ, 1:nK, MaxBlock)); CosBR_CB = 0
    call compute_cosbr
    call calc_gradient_ghost(CosBR_CB)
    ! free space
    deallocate(CosBR_CB)

    ! Trace field lines

    ! check if trace mode is specified
    if(present(iTraceModeIn))then
       if(abs(iTraceModeIn) > 1)&
            call stop_mpi(&
            NameThisComp//':'//NameSub//': incorrect tracing mode')
       iTraceMode = iTraceModeIn
    else
       iTraceMode = 0
    end if

    ! tracing modes are the following:,
    ! -1 -> trace lines backward only
    !       do iDirTrace = -1, -1, 2
    !  0 -> trace lines in both directions
    !       do iDirTrace = -1,  1, 2
    ! +1 -> trace lines forward only
    !       do iDirTracs =  1,  1, 2
    do iDirTrace = 2*max(iTraceMode,0)-1, 2*min(iTraceMode,0)+1, 2

       ! fix alignment of particle indexing with B field direction
       call get_alignment()

       call trace_particles(KindEnd_, particle_line)

       ! check that the allowed number of particles hasn't been exceeded
       call count_all_particles()
       if(nParticleAll > nParticlePerLine*nFieldLineMax)&
            call stop_mpi(&
            NameThisComp//':'//NameSub//': max number of particles exceeded')

       ! if just finished backward tracing and need to trace in both dirs
       ! => return to initial particles
       if(iDirTrace < 0 .and. iTraceMode == 0)then
          ! copy initial points to KindEnd_:
          ! the initial particles are currently right after the particles,
          ! that were in the list before the start of this subroutine,
          ! i.e. occupy positions from (nParticleOld+1)
          StateEnd_VI(x_:z_, 1:nLineThisProc) = &
               StateReg_VI(x_:z_, nParticleOld+1:nParticleOld+nLineThisProc)
          iIndexEnd_II(0:id_,1:nLineThisProc) = iIndexReg_II(&
               0:id_,nParticleOld+1:nParticleOld+nLineThisProc)
          Particle_I(KindEnd_)%nParticle = nLineThisProc
       end if
    end do
    ! Offset in id_
    call offset_id(nFieldLine - nLineAllProc + 1, nFieldLine)
    call test_stop(NameSub, DoTest)
  contains
    !==========================================================================
    subroutine count_new_lines()
      ! gather information from all processors on how many new field lines
      ! have been started
      use ModMpi
      integer:: iError

      !------------------------------------------------------------------------
      if(nProc>1)then
         call MPI_Allreduce(nLineThisProc, nLineAllProc, 1, &
              MPI_INTEGER, MPI_SUM, iComm, iError)
      else
         nLineAllProc = nLineThisProc
      end if
    end subroutine count_new_lines
    !==========================================================================
    subroutine count_all_particles()
      ! gather information from all processors on how many new field lines
      ! have been started
      use ModMpi
      integer:: iError

      !------------------------------------------------------------------------
      if(nProc>1)then
         call MPI_Allreduce(Particle_I(KindReg_)%nParticle, nParticleAll, 1, &
              MPI_INTEGER, MPI_SUM, iComm, iError)
      else
         nParticleAll = Particle_I(KindReg_)%nParticle
      end if
    end subroutine count_all_particles
    !==========================================================================
    subroutine compute_cosbr()
      use ModMain, ONLY: UseB0
      use ModB0, ONLY: B0_DGB
      use ModGeometry, ONLY: R_BLK

      integer :: iBlock, i, j, k ! loop variables
      real    :: XyzCell_D(nDim), BCell_D(nDim)

      ! precompute CosBR on the grid for all active blocks

      !------------------------------------------------------------------------
      do iBlock = 1, nBlock
         if(Unused_B(iBlock))CYCLE
         do k = 1, nK; do j = 1, nJ; do i = 1, nI
            XyzCell_D = Xyz_DGB(1:nDim,i,j,k,iBlock)
            Bcell_D = State_VGB(Bx_:B_+nDim,i,j,k,iBlock)
            if(UseB0)BCell_D = Bcell_D + B0_DGB(1:nDim,i,j,k,iBlock)
            if(any(BCell_D /= 0.0) .and. R_BLK(i,j,k,iBlock) > 0.0)then
               CosBR_CB(i,j,k,iBlock) = sum(Bcell_D*XyzCell_D) / &
                    (norm2(BCell_D)*R_BLK(i,j,k,iBlock))
            else
               CosBR_CB(i,j,k,iBlock) = 0.0
            end if
         end do; end do; end do
      end do
    end subroutine compute_cosbr
    !==========================================================================
    subroutine get_alignment()
      ! determine alignment of particle indexing with direction
      ! of the magnetic field
      integer:: iParticle
      real   :: DirB_D(MaxDim)

      !------------------------------------------------------------------------
      iIndexEnd_II(Pass_, 1:Particle_I(KindEnd_)%nParticle) = DoneFromScratch_
      if(iOrderMode == Field_)then
         iIndexEnd_II(Alignment_, 1:Particle_I(KindEnd_)%nParticle) = 1
         RETURN
      end if

      do iParticle = 1, Particle_I(KindEnd_)%nParticle
         call get_b_dir(iParticle, DirB_D)
         iIndexEnd_II(Alignment_, iParticle) = &
              nint( SIGN(1.0, sum(DirB_D*StateEnd_VI(x_:z_, iParticle)) ))
      end do
    end subroutine get_alignment
    !==========================================================================
    subroutine offset_id(iLineStart,iLineEnd)
      use ModMpi
      integer, intent(in) :: iLineStart, iLineEnd
      integer:: iParticle, nParticle, iLine, iError
      integer, allocatable:: iOffsetLocal_I(:), iOffset_I(:)
      !------------------------------------------------------------------------
      allocate(iOffsetLocal_I(1:nFieldLineMax))
      allocate(iOffset_I(     1:nFieldLineMax))
      iOffsetLocal_I = 0; iOffset_I = 0

      ! set a pointer to parameters of regular particles
      nParticle = Particle_I(KindReg_)%nParticle
      do iParticle = 1, nParticle
         iLine = iIndexReg_II(fl_,iParticle)

         ! Reset offset, if id_ is less than one
         iOffsetLocal_I(iLine) = max(iOffsetLocal_I(iLine),&
              1 - iIndexReg_II(id_,iParticle))
      end do
      ! find maximim offset from all processors
      if(nProc > 1) then
         call MPI_Allreduce(iOffsetLocal_I(iLineStart), &
              iOffset_I(iLineStart), 1 + iLineEnd - iLineStart, &
              MPI_INTEGER, MPI_MAX, iComm, iError)
      else
         iOffset_I(iLineStart:iLineEnd) = &
              iOffsetLocal_I(iLineStart:iLineEnd)
      end if
      do iParticle = 1, nParticle
         iLine = iIndexReg_II(fl_,iParticle)

         ! Apply offset
         iIndexReg_II(id_,iParticle) = iIndexReg_II(id_,iParticle) + &
              iOffset_I(iLine)
      end do
      deallocate(iOffsetLocal_I, iOffset_I)
    end subroutine offset_id
    !==========================================================================
  end subroutine extract_particle_line
  !============================================================================
  subroutine particle_line(iParticle, IsEndOfSegment)
    ! the subroutine is the tracing loop;
    ! tracing starts at KindEnd_ particles and proceeds in a given direction

    integer, intent(in) :: iParticle
    logical, intent(out):: IsEndOfSegment

    ! cosine of angle between direction of field and radial direction
    real:: CosBR

    ! whether to schedule a particle for message pass
    logical:: DoMove, IsGone

    ! direction of the magnetic field
    real :: DirB_D(MaxDim)
    ! direction of the tangent to the line: may be parallel or
    ! antiparallel to DirB. The direction may be corrected if needed
    real :: DirLine_D(MaxDim)

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'particle_line'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)
    select case(iIndexEnd_II(Pass_,iParticle))
    case(HalfStep_)

       ! change Pass_ field for particle passed after first stage
       iIndexEnd_II(Pass_,iParticle) = Normal_
       ! will continue tracing, can't be the end of segment
       IsEndOfSegment = .false.
       ! do not call the first stage, proceed to the second one

    case(DoneFromScratch_)

       ! Initialize the radial direction that corresponds
       ! to the previous step
       StateEnd_VI(DirX_:DirZ_,  iParticle) = iDirTrace * &
            StateEnd_VI(x_:z_,  iParticle) / &
            norm2(StateEnd_VI(x_:z_, iParticle))
       iIndexEnd_II(Pass_, iParticle) = Normal_

       call stage1

    case(Normal_)

       ! increase particle index & copy to regular
       iIndexEnd_II(id_,iParticle) = &
            iIndexEnd_II(id_,iParticle) + iDirTrace
       call copy_end_to_regular(iParticle)

       call stage1

    case default
       call stop_mpi(NameThisComp//':'//NameSub//': Unknown stage ID')
    end select

    if(IsEndOfSegment) RETURN
    call stage2
    call test_stop(NameSub, DoTest)
 contains
    !==========================================================================
    subroutine stage1
      !------------------------------------------------------------------------
      if(RSoftBoundary > 0.0)then
         if(sum(StateEnd_VI(1:nDim,iParticle)**2) &
              > RSoftBoundary**2)then
            call mark_undefined(KindEnd_, iParticle)
            IsEndOfSegment = .true.
            RETURN
         end if
      end if
      ! First stage of RK2 method
      ! copy last known coordinates to old coords
      StateEnd_VI(XOld_:ZOld_,iParticle) = &
           StateEnd_VI(x_:z_, iParticle)
      ! get the direction of the magnetic field at original location
      ! get and save gradient of cosine of angle between field and
      ! radial direction
      ! get and save step size
      call get_b_dir(iParticle, DirB_D,&
           Grad_D  = StateEnd_VI(GradCosBRX_:GradCosBRZ_,iParticle),&
           StepSize= StateEnd_VI(Ds_,iParticle),&
           IsBody  = IsEndOfSegment)
      ! particle's location may be inside central body
      if(IsEndOfSegment)RETURN
      ! get cosine of angle between field and radial direction
      !
      CosBR =  sum(StateEnd_VI(x_:z_, iParticle)*DirB_D) / &
           norm2(StateEnd_VI(x_:z_, iParticle))
      ! save cos(b,r) for the second stage
      StateEnd_VI(CosBR_, iParticle) = CosBR

      ! Limit the interpolated time step
      StateEnd_VI(Ds_, iParticle) = &
           MIN(SpaceStepMax, MAX(SpaceStepMin,&
           StateEnd_VI(Ds_, iParticle)))

      ! get line direction
      DirLine_D = DirB_D * &
           iDirTrace * iIndexEnd_II(Alignment_, iParticle)

      ! correct the direction to prevent the line from closing
      if(UseCorrection) &
           call correct(DirLine_D)

      ! get middle location
      StateEnd_VI(x_:z_, iParticle) = &
           StateEnd_VI(x_:z_, iParticle) + &
           0.50*StateEnd_VI(Ds_, iParticle)*DirLine_D

      ! check location, schedule for message pass, if needed
      call check_particle_location(  &
           iKindParticle = KindEnd_ ,&
           iParticle     = iParticle,&
           DoMove        = DoMove   ,&
           IsGone        = IsGone    )

      ! Particle may come beyond the boundary of computational
      ! domain. Otherwise, it may need to be marked as passed
      ! the first stage and be moved to different PE
      IsEndOfSegment = IsGone.or.DoMove
      if(DoMove) iIndexEnd_II(Pass_, iParticle) = HalfStep_
    end subroutine stage1
    !==========================================================================
    subroutine stage2
      ! radii and vector of radial direction
      real :: ROld, RNew, DirR_D(MaxDim)
      !------------------------------------------------------------------------
      ! get the direction of the magnetic field in the middle
      call get_b_dir(iParticle, DirB_D,&
           IsBody  = IsEndOfSegment)
      if(IsEndOfSegment) RETURN
      ! direction at the 2nd stage
      DirLine_D = DirB_D *&
           iDirTrace * iIndexEnd_II(Alignment_, iParticle)
      ! get cos of angle between b and r
      CosBR = StateEnd_VI(CosBR_, iParticle)
      ! correct the direction to prevent the line from closing
      if(UseCorrection) &
           call correct(DirLine_D)

      ! check whether direction reverses in a sharp turn:
      ! this is an indicator of a problem, break tracing of the line
      if(sum(StateEnd_VI(DirX_:DirZ_,  iParticle) * DirLine_D) < 0)then
         call mark_undefined(KindEnd_, iParticle)
         IsEndOfSegment = .true.
         RETURN
      end if

      ! save the direction to correct the next step
      StateEnd_VI(DirX_:DirZ_,  iParticle) = DirLine_D
      ! get final location
      StateEnd_VI(x_:z_,iParticle) = &
           StateEnd_VI(XOld_:ZOld_,iParticle) + &
           StateEnd_VI(Ds_, iParticle)*DirLine_D
      ! Achieve that the change in the radial distance
      ! equals StateEnd_VI(Ds_, iParticle)*sum(Dir_D*DirR_D)
      ROld = norm2(StateEnd_VI(XOld_:ZOld_,iParticle))
      DirR_D = StateEnd_VI(XOld_:ZOld_,iParticle)/ROld

      RNew = norm2(StateEnd_VI(x_:z_,iParticle))
      StateEnd_VI(x_:z_,iParticle) = StateEnd_VI(x_:z_,iParticle)/RNew*&
           ( ROld + StateEnd_VI(Ds_, iParticle)*sum(DirLine_D*DirR_D) )

      if(UseFLRW) call apply_random_walk(DirLine_D)

      ! update location and schedule for message pass
      call check_particle_location(  &
           iKindParticle = KindEnd_ ,&
           iParticle     = iParticle,&
           DoMove        = DoMove   ,&
           IsGone        = IsGone    )
      ! Particle may come beyond the boundary of
      ! computational domain or may need to be
      ! moved to different PE
      IsEndOfSegment = IsGone.or.DoMove
    end subroutine stage2
    !==========================================================================
    subroutine correct(Dir_D)
      ! corrects the direction to prevent the line from closing:
      ! if CosBR is far enough from the value of the alginment (+/-1),
      ! Dir_D is changed to a vector with max radial component
      ! \perp \nabla CosBR to avoid reaching region with opposite sign of CosBR

      ! current direction
      real, intent(inout):: Dir_D(MaxDim)
      ! deviation of outward directed line (iIndexEnd_II(Alignment_) = 1)
      ! from outward radial direction, OR
      ! deviation of inward directed line (iIndexEnd_II(Alignment_) = -1)
      ! from inward radial direction.
      real:: DCosBR
      ! threshold for such deviation to apply correction
      real:: DCosBRMax = 0.15
      ! Heliocentric distance
      real :: R
      ! unit vector of a radial direction
      real :: R_D(MaxDim)
      ! Unit vector parallel or antiparallel to GradCosBR
      real :: DirGradCosBR_D(MaxDim)
      ! Dot product of these two vestors
      real :: DirRDotDirGradCosBR
      ! scalars to define parameters of the correction
      ! to avoid exessive line curvature.
      ! Dot product of the old and new directions
      real :: DirOldDotDirNew
      real, parameter :: cDirOldDotDirNewMin = 0.995
      !------------------------------------------------------------------------
      ! deviation of outward directed line (iIndexEnd_II(Alignment_) = 1)
      ! from outward radial direction, OR
      ! deviation of inward directed line (iIndexEnd_II(Alignment_) = -1)
      ! from inward radial direction.
      DCosBR = abs(CosBR - iIndexEnd_II(Alignment_,iParticle))
      ! Heliocentric distance, to compare with RCorrection
      R = norm2(StateEnd_VI(x_:z_,iParticle))

      ! if the line deviates to0 much -> correct its direction
      ! to go along surface B_R = 0
      if(DCosBR > DCosBRMax .and. &
           R > RCorrectionMin .and. R < RCorrectionMax)then
         ! unit vector of a radial direction
         R_D = StateEnd_VI(x_:z_, iParticle)/R
         ! unit vector along gradient of cosBR
         DirGradCosBR_D = &
              StateEnd_VI(GradCosBRX_:GradCosBRZ_, iParticle)/ &
              norm2(StateEnd_VI(GradCosBRX_:GradCosBRZ_, iParticle))
         ! Change the direction of line for the unit vector, which
         ! (1) is perpendicular to GradCosBR (or, the same, is parallel
         !    to the current sheet surface, CosBR=0=const
         ! (2) has a maximum possible radial component
         ! First, calculate the cosine of angle between radial direction and
         ! the direction of GradCosBR:
         DirRDotDirGradCosBR = sum(DirGradCosBR_D*R_D)
         ! get the corrected line direction
         Dir_D = iDirTrace*(R_D - DirGradCosBR_D*DirRDotDirGradCosBR)/&
              sqrt(1 - DirRDotDirGradCosBR**2)
         ! Why???
         RETURN
      end if

      ! the line doesn't deviate much, but it may just have exited the region
      ! where the correction above has been applied;
      ! to prevent sharp changes in the direction -> limit line's curvature
      DirOldDotDirNew = sum(Dir_D*StateEnd_VI(DirX_:DirZ_, iParticle))
      ! Do not correct, if cosine of angle between old and new direction is
      ! close enough to 1:
      if(DirOldDotDirNew > cDirOldDotDirNewMin) RETURN
      ! Direction needs to be corrected
      ! eliminate the component of the current direction parallel
      ! to the one during the previous step;
      Dir_D = Dir_D - DirOldDotDirNew*StateEnd_VI(DirX_:DirZ_,iParticle)
      ! components \perp to it are scaled accordingly to keep ||Dir_D|| = 1
      Dir_D = Dir_D/sqrt(1 - DirOldDotDirNew**2)
      ! Floor the cosine of angle between the old and new direction
      Dir_D = cDirOldDotDirNewMin*StateEnd_VI(DirX_:DirZ_,iParticle) + &
           sqrt(1 - cDirOldDotDirNewMin**2)*Dir_D
    end subroutine correct
    !==========================================================================
    subroutine apply_random_walk(Dir_D)
      use ModCoordTransform, ONLY: cross_product
      use ModRandomNumber, ONLY: random_real
      use ModPhysics, ONLY: No2Si_V, UnitX_
      use ModConst, ONLY: cAu
      use ModNumConst, ONLY: cTwoPi
      ! add components perpendicular to the current direction of the line
      ! to achieve the effect of field line random walk
      real, intent(in) :: Dir_D(MaxDim)

      ! current radial distance
      real:: Radius

      ! 2 perpendicular directions to Dir_D
      real:: DirPerp1_D(MaxDim), DirPerp2_D(MaxDim)

      ! random numbers: 2 uniform and 2 normal (see Box-Muller algorithm)
      real:: RndUnif1, RndUnif2, RndGauss1, RndGauss2
      ! seed for random number generator
      integer, save:: iSeed=0
      !------------------------------------------------------------------------
      ! first, find perpendicular directions
      DirPerp1_D = cross_product([1.0,0.0,0.0],Dir_D)
      if(all(DirPerp1_D == 0.0))&
           DirPerp1_D = cross_product([0.0,1.0,0.0],Dir_D)
      DirPerp1_D = DirPerp1_D / norm2(DirPerp1_D)
      DirPerp2_D = cross_product(DirPerp1_D, Dir_D )

      ! find 2D gaussian
      RndUnif1  = random_real(iSeed)
      RndUnif2  = random_real(iSeed)
      RndGauss1 = sqrt(-2*log(RndUnif1)) * cos(cTwoPi*RndUnif2)
      RndGauss2 = sqrt(-2*log(RndUnif1)) * sin(cTwoPi*RndUnif2)

      ! displace the particle
      Radius = norm2(StateEnd_VI(x_:z_,iParticle))
      ! see Laitinen et al. (2016), doi:10.1051/0004-6361/201527801
      StateEnd_VI(x_:z_,iParticle) = StateEnd_VI(x_:z_,iParticle) + &
                  DeltaPhiFLRW * sqrt(Radius * StateEnd_VI(Ds_, iParticle)) * &
                  (DirPerp1_D * RndGauss1 + DirPerp2_D * RndGauss2)
    end subroutine apply_random_walk
    !==========================================================================
  end subroutine particle_line
  !============================================================================
  subroutine copy_end_to_regular(iParticleIn)
    integer, optional, intent(in) :: iParticleIn
    ! copies indicated variables of known end particles to regular particles
    integer, parameter:: iVarCopy_I(3)   = [x_, y_, z_]
    integer, parameter:: iIndexCopy_I(3) = [0, fl_, id_]
    integer:: iParticle, iParticleStart, iParticleEnd
    logical:: DoTest
    character(len=*), parameter:: NameSub = 'copy_end_to_regular'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)
    if(present(iParticleIn))then
       iParticleStart = iParticleIn
       iParticleEnd   = iParticleIn
    else
       iParticleStart = 1
       iParticleEnd   = Particle_I(KindEnd_)%nParticle
    end if
    do iParticle = iParticleStart, iParticleEnd
       if(Particle_I(KindReg_)%nParticle == nParticlePerLine*nFieldLineMax)&
            call stop_mpi(&
            NameThisComp//':'//NameSub//': max number of particles exceeded')
       Particle_I(KindReg_)%nParticle = Particle_I(KindReg_)%nParticle+1
       StateReg_VI(iVarCopy_I, Particle_I(KindReg_)%nParticle) =&
            StateEnd_VI(iVarCopy_I, iParticle)
       iIndexReg_II(iIndexCopy_I, Particle_I(KindReg_)%nParticle) =&
            iIndexEnd_II(iIndexCopy_I, iParticle)
    end do
    call test_stop(NameSub, DoTest)
  end subroutine copy_end_to_regular
  !============================================================================
  subroutine get_b_dir(iParticle, Dir_D, Grad_D, StepSize, IsBody)
    use ModMain, ONLY: UseB0
    use ModB0, ONLY: get_b0

    ! returns the direction of magnetic field for a given particle
    integer, intent(in):: iParticle
    real,    intent(out):: Dir_D(MaxDim)
    real,    optional, intent(out):: Grad_D(MaxDim)
    real,    optional, intent(out):: StepSize
    logical, optional, intent(out):: IsBody

    ! Coordinates and block #
    real     :: Xyz_D(MaxDim)
    integer  :: iBlock

    ! magnetic field
    real   :: B_D(MaxDim) = 0.0
    ! interpolation data: number of cells, cell indices, weights
    integer:: nCell, iCell_II(0:nDim, 2**nDim)
    real   :: Weight_I(2**nDim)
    integer:: iCell ! loop variable
    integer:: i_D(MaxDim)
    character(len=200):: StringError

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'get_b_dir'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)
    Dir_D = 0; B_D = 0
    if(present(Grad_D))Grad_D = 0
    if(present(StepSize))StepSize = 0.0
    ! Coordinates and block #
    Xyz_D   = StateEnd_VI(x_:z_, iParticle)
    iBlock  = iIndexEnd_II(0,iParticle)
    call interpolate_grid_amr_gc(Xyz_D, iBlock, nCell, iCell_II, Weight_I,&
         IsBody)
    if(present(IsBody))then
       if(IsBody)then
          call mark_undefined(KindEnd_,iParticle);RETURN
       end if
    end if
    ! get potential part of the magnetic field at the current location
    if(UseB0)call get_b0(Xyz_D, B_D)
    ! get the remaining part of the magnetic field
    do iCell = 1, nCell
       i_D = 1
       i_D(1:nDim) = iCell_II(1:nDim, iCell)
       B_D = B_D + &
            State_VGB(Bx_:Bz_,i_D(1),i_D(2),i_D(3),iBlock)*Weight_I(iCell)
    end do

    if(all(B_D==0))then
       write(StringError,'(a,es15.6,a,es15.6,a,es15.6)') &
            NameThisComp//':'//NameSub//&
            ': trying to extract line at region with zero magnetic field'//&
            ' at location X = ', &
            Xyz_D(1), ' Y = ', Xyz_D(2), ' Z = ', Xyz_D(3)
       call stop_mpi(StringError)
    end if
    ! normalize vector to unity
    Dir_D(1:nDim) = B_D(1:nDim) / sum(B_D(1:nDim)**2)**0.5
    if(present(Grad_D))then
       ! interpolate grad(cos b.r)
       do iCell = 1, nCell
          i_D = 1
          i_D(1:nDim) = iCell_II(1:nDim, iCell)
          Grad_D(1:nDim) = Grad_D(1:nDim) + &
               GradCosBR_DGB(:,i_D(1),i_D(2),i_D(3),iBlock)*Weight_I(iCell)
       end do
    end if
    if(present(StepSize))then
       ! interpolate cell sizes. For non-cartesian grids
       ! the metic tensor is used
       do iCell = 1, nCell
          i_D = 1
          i_D(1:nDim) = iCell_II(1:nDim, iCell)
          StepSize = StepSize + &
               CellVolume_GB(i_D(1),i_D(2),i_D(3),iBlock) * Weight_I(iCell)
       end do
       ! take a fraction of cubic root of inteprolated cell volume as step size
       StepSize = 0.1 * StepSize**(1.0/3.0)
    end if
    call test_stop(NameSub, DoTest)
  end subroutine get_b_dir
  !============================================================================

  subroutine advect_particle_line
    ! advect particles with the local plasma velocity
    use ModMain, ONLY: time_accurate

    ! particles can be advected only in the time accurate run
    logical:: DoTest
    character(len=*), parameter:: NameSub = 'advect_particle_line'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)
    if(.not.time_accurate) &
         RETURN

    ! reset particle's stage
    iIndexReg_II(Pass_,1:Particle_I(KindReg_)%nParticle) = DoneFromScratch_

    call trace_particles(KindReg_, advect_particle, check_done_advect)
    call test_stop(NameSub, DoTest)
  end subroutine advect_particle_line
  !============================================================================

  subroutine advect_particle(iParticle, IsEndOfSegment)
    use ModMain, ONLY: Dt
    ! advect an indiviudal particle using 2-stage integration

    integer, intent(in) :: iParticle
    logical, intent(out):: IsEndOfSegment

    ! whether to schedule a particle for message pass
    logical:: DoMove, IsGone

    ! local plasma velocity
    real :: V_D(MaxDim)

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'advect_particle'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)
    select case(iIndexReg_II(Pass_,iParticle))
    case(DoneFromScratch_)
       ! begin particle's advection
       ! copy last known coordinates to old coords
       StateReg_VI(XOld_:ZOld_,iParticle) = &
            StateReg_VI(x_:z_, iParticle)

       ! get the local plasma velocity
       call get_v
       if(IsEndOfSegment) RETURN
       ! get next location
       StateReg_VI(x_:z_, iParticle) = &
            StateReg_VI(x_:z_, iParticle) + 0.5 * Dt * V_D

       ! check location, schedule for message pass, if needed
       call check_particle_location(  &
            iKindParticle = KindReg_ ,&
            iParticle     = iParticle,&
            DoMove        = DoMove   ,&
            IsGone        = IsGone    )

       ! Particle may be beyond the boundary of computational domain
       ! or need to move particle to different PE
       IsEndOfSegment = IsGone .or. DoMove

       ! the first stage is done
       iIndexReg_II(Pass_, iParticle) = HalfStep_
    case(HalfStep_)
       ! stage 1 has been finished, proceed to the next one
       ! get the local plasma velocity
       call get_v
       if(IsEndOfSegment)RETURN
       ! get final location
       StateReg_VI(x_:z_,iParticle) = &
            StateReg_VI(XOld_:ZOld_,iParticle) + Dt * V_D

       ! update location and schedule for message pass
       call check_particle_location( &
            iKindParticle = KindReg_,&
            iParticle     = iParticle)
       ! Integration is done
       !
       iIndexReg_II(Pass_, iParticle) = Normal_
       IsEndOfSegment = .true.
    case(Normal_)
       ! do nothing, full time step has been finished
       IsEndOfSegment = .true.
    case default
       call stop_mpi(NameThisComp//':'//NameSub//': Unknown stage ID')
    end select
    call test_stop(NameSub, DoTest)
  contains
    !==========================================================================
    subroutine get_v
      ! get local plasma velocity
      ! Coordinates and block #
      real     :: Xyz_D(MaxDim)
      integer  :: iBlock

      ! variables for AMR interpolation
      integer:: nCell, iCell_II(0:nDim, 2**nDim)
      real   :: Weight_I(2**nDim)
      integer:: iCell ! loop variable
      integer:: i_D(MaxDim)
      !------------------------------------------------------------------------
      ! Coordinates and block #
      Xyz_D   = StateReg_VI(x_:z_, iParticle)
      iBlock  = iIndexReg_II(0,    iParticle)
      ! reset the interpoalted values
      V_D = 0
      ! get the velocity
      call interpolate_grid_amr_gc(Xyz_D, iBlock, nCell, iCell_II, Weight_I, &
           IsEndOfSegment)
      if(IsEndOfSegment)then
         call mark_undefined(KindReg_,iParticle);RETURN
      end if
      ! interpolate the local density and momentum
      do iCell = 1, nCell
         i_D = 1
         i_D(1:nDim) = iCell_II(1:nDim, iCell)
         if(State_VGB(Rho_,i_D(1),i_D(2),i_D(3),iBlock)*Weight_I(iCell) <= 0)&
              call stop_mpi(&
              NameThisComp//':'//NameSub//": zero or negative plasma density")
         ! convert momentum to velocity
         V_D = V_D + &
              State_VGB(RhoUx_:RhoUz_,i_D(1),i_D(2),i_D(3),iBlock) / &
              State_VGB(Rho_,         i_D(1),i_D(2),i_D(3),iBlock) * &
              Weight_I(iCell)
      end do
    end subroutine get_v
    !==========================================================================
  end subroutine advect_particle
  !============================================================================

  subroutine check_done_advect(Done)
    ! check whether all paritcles have been advected full time step
    logical, intent(out):: Done
    !--------------------------------------------------------------------------
    Done = all(iIndexReg_II(Pass_,1:Particle_I(KindReg_)%nParticle)==Normal_)
  end subroutine check_done_advect
  !============================================================================

  !================ACCESS TO THE PARTICLE DATA==============================

  subroutine get_particle_data(nSize, NameVar, DataOut_VI)
    use ModUtilities, ONLY: split=>split_string
    ! the subroutine gets variables specified in the string StringVar
    ! and writes them into DataOut_VI; data is for all particles otherwise
    integer, intent(in) :: nSize
    real,    intent(out):: DataOut_VI(nSize,Particle_I(KindReg_)%nParticle)
    character(len=*),intent(in) :: NameVar

    ! order of requested variables/indexes
    integer:: iOrderVar_V(nVarAvail), iOrderIndex_I(nIndexAvail + 1)
    ! number of variables/indices found in the request string
    integer:: nVarOut, nIndexOut
    ! order of data in the request
    integer:: iOrder_I(nDataMax)

    character(len=20)            :: Name_I(  nDataMax)
    integer                      :: iVar, iIndex, iOutput, nData

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'get_particle_data'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)
    nVarOut = 0  ; nIndexOut = 0
    call split(NameVar,  Name_I, nData)
    ! determine which variables are requested
    VAR:do iVar = 1, nVarAvail
       do iOutput = 1, nData
          if(index(Name_I(iOutput),NameVarAvail_V(iVar)) == 1)then
             ! The variable #iVar is present in the request at #iOutput
             nVarOut              = nVarOut + 1
             iOrderVar_V(nVarOut) = iVar
             iOrder_I(   nVarOut) = iOutput
             CYCLE VAR
          end if
       end do
    end do VAR
    IND:do iIndex = 0, nIndexAvail
       do iOutput = 1, nData
          if(index(Name_I(iOutput),NameIndexAvail_I(iIndex)) == 1)then
            ! The index #iIndex is present in the request at #iOutput
             nIndexOut                     = nIndexOut + 1
             iOrderIndex_I(nIndexOut)      = iIndex
             iOrder_I(nVarOut + nIndexOut) = iOutput
             CYCLE IND
          end if
       end do
    end do IND
    if(nData /= nVarOut + nIndexOut)call stop_mpi(&
         'Unrecognized some of the names: '//NameVar)
    DataOut_VI = 0
    ! store variables
    if(nVarOut   > 0) DataOut_VI(iOrder_I(1:nVarOut),:)                   = &
         StateReg_VI(iOrderVar_V(   1:nVarOut  ),&
         1:Particle_I(KindReg_)%nParticle)
    ! store indexes
    if(nIndexOut > 0) DataOut_VI(iOrder_I(nVarOut+1:nVarOut+nIndexOut),:) = &
         iIndexReg_II(iOrderIndex_I(1:nIndexOut),&
         1:Particle_I(KindReg_)%nParticle)
    call test_stop(NameSub, DoTest)
  end subroutine get_particle_data
  !============================================================================

  subroutine write_plot_particle(iFile)

    ! Save particle data

    use ModMain,    ONLY: n_step, time_accurate, time_simulation
    use ModIO,      ONLY: &
         StringDateOrTime, NamePlotDir, &
         TypeFile_I, plot_type, plot_form, Plot_
    use ModPlotFile, ONLY: save_plot_file

    integer, intent(in):: iFile

    character(len=100) :: NameFile, NameStart, NameVar
    character (len=80) :: NameProc
    ! container for data
    real, allocatable:: PlotVar_VI(:,:)

    logical:: IsIdl
    integer:: iPlotFile

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'write_plot_particle'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest)

    iPlotFile = iFile - Plot_

    ! Set the name of the variables based on plot form
    select case(plot_form(iFile))
    case('tec')
       IsIdl = .false.
       NameVar = '"X", "Y", "Z"'
       NameVar = trim(NameVar)//', "FieldLine"'
    case default
       call stop_mpi(&
            NameThisComp//':'//NameSub//' ERROR invalid plot form='//plot_form(iFile))
    end select

    ! name of output files
    if(iPlotFile < 10)then
       write(NameStart,'(a,i1,a)') &
            trim(NamePlotDir)//trim(plot_type(iFile))//'_',iPlotFile
    else
       write(NameStart,'(a,i2,a)') &
            trim(NamePlotDir)//trim(plot_type(iFile))//'_',iPlotFile
    end if

    NameFile = NameStart

    if(time_accurate)then
       call get_time_string
       NameFile = trim(NameFile)// "_t"//StringDateOrTime
    end if
    write(NameFile,'(a,i7.7,a)') trim(NameFile) // '_n',n_step

    ! String containing the processor index
    if(nProc < 10000) then
       write(NameProc, '(a,i4.4,a)') "_pe", iProc
    elseif(nProc < 100000) then
       write(NameProc, '(a,i5.5,a)') "_pe", iProc
    else
       write(NameProc, '(a,i6.6,a)') "_pe", iProc
    end if

    NameFile = trim(NameFile) // trim(NameProc)

    if(IsIdl)then
       NameFile = trim(NameFile) // '.out'
    else
       NameFile = trim(NameFile) // '.dat'
    end if

    ! get the data on this processor
    if(allocated(PlotVar_VI)) deallocate(PlotVar_VI)
    allocate(PlotVar_VI(5,Particle_I(KindReg_)%nParticle))
    call get_particle_data(5, 'xx yy zz fl id', PlotVar_VI)

    call save_plot_file(&
         NameFile, &
         TypeFileIn     = TypeFile_I(iFile), &
         StringHeaderIn = "TEMPORARY", &
         TimeIn         = time_simulation, &
         nStepIn        = n_step, &
         NameVarIn      = 'X Y Z FieldLine Index', &
         IsCartesianIn  = .false., &
         CoordIn_I      = PlotVar_VI(1, :), &
         VarIn_VI       = PlotVar_VI(2:,:))

    deallocate(PlotVar_VI)

    call test_stop(NameSub, DoTest)
  end subroutine write_plot_particle
  !============================================================================

end module ModParticleFieldLine
!==============================================================================
