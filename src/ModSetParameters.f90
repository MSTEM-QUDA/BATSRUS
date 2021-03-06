!  Copyright (C) 2002 Regents of the University of Michigan,
!  portions used with permission
!  For more information, see http://csem.engin.umich.edu/tools/swmf
module ModSetParameters

  use BATL_lib, ONLY: &
       test_start, test_stop

  implicit none

  private ! except

  public:: set_parameters

contains
  !============================================================================

  subroutine set_parameters(TypeAction)

    ! Set input parameters for BATS-R-US!

    use ModMain
    use ModAdvance
    use ModB0, ONLY: UseB0Source, UseCurlB0, DoUpdateB0, DtUpdateB0, &
         read_b0_param, init_mod_b0
    use ModGeometry, ONLY: init_mod_geometry, TypeGeometry, nMirror_D, &
         x1,x2,y1,y2,z1,z2,XyzMin_D,XyzMax_D,RadiusMin,RadiusMax,&
         CoordDimMin_D, CoordDimMax_D, &
         read_gen_radial_grid, set_gen_radial_grid, NameGridFile
    use ModNodes, ONLY: init_mod_nodes
    use ModImplicit
    use ModSemiImplicit, ONLY: read_semi_impl_param, init_mod_semi_impl
    use ModPartImplicit, ONLY: read_part_impl_param, init_mod_part_impl
    use ModLinearSolver, ONLY: UseAccurateSum
    use ModImplHypre, ONLY: hypre_read_param
    use ModPhysics
    use ModProjectDivB, ONLY: read_project_divb_param, DivBMax
    use ModConstrainDivB, ONLY: init_mod_ct, DoInitConstrainB
    use ModBlockData, ONLY: init_mod_block_data, clean_block_data
    use BATL_lib, ONLY: &
         read_region_param, read_test_param, NameVarTest, iVarTest, &
         BetaProlong, init_mpi, IsCartesianGrid, IsCartesian, &
         IsRzGeometry, IsCylindrical, IsRLonLat, IsLogRadius, IsGenRadius, &
         iProc, nProc, iComm
    use ModAMR,           ONLY: init_mod_amr, read_amr_param, fix_amr_limits,&
         DoAmr
    use ModFieldTrace,    ONLY: init_mod_field_trace, read_field_trace_param,&
         DoMapEquatorRay
    use ModIO
    use CON_planet,       ONLY: read_planet_var, check_planet_var, NamePlanet
    use ModPlanetConst
    use CON_axes,         ONLY: init_axes, get_axes, &
         dLongitudeHgr, dLongitudeHgrDeg, dLongitudeHgi, dLongitudeHgiDeg
    use ModUtilities,     ONLY: fix_dir_name, check_dir, make_dir, DoFlush, &
         split_string, join_string, open_file, lower_case, &
         DoWriteCallSequence, StringTestSwmf => StringTest
    use CON_planet,       ONLY: get_planet
    use ModTimeConvert,   ONLY: time_int_to_real, time_real_to_int
    use ModReadParam
    use ModMessagePass,   ONLY: DoOneCoarserLayer
    use ModFaceValue,     ONLY: &
         UseTvdResChange, UseAccurateResChange, &
         UseVolumeIntegral4, UseFaceIntegral4, UseLimiter4, nGUsed, &
         DoLimitMomentum, BetaLimiter, TypeLimiter, read_face_value_param, &
         TypeLimiter5, UseCweno, &
         iVarSmooth_V, iVarSmoothIndex_I, &
         StringLowOrderRegion, iRegionLowOrder_I
    use ModPartSteady,    ONLY: UsePartSteady, MinCheckVar, MaxCheckVar, &
         RelativeEps_V, AbsoluteEps_V
    use ModBoundaryGeometry, ONLY: init_mod_boundary_cells, &
         read_boundary_geometry_param
    use ModPointImplicit, ONLY: read_point_implicit_param, UsePointImplicit, &
         init_mod_point_impl
    use ModRestartFile, ONLY: read_restart_parameters, init_mod_restart_file, &
         DoChangeRestartVariables, nVarRestart, UseRestartWithFullB,      &
         NameRestartInDir, NameRestartOutDir, DoSpecifyRestartVarMapping, &
         nVarRestartMapping, NameVarRestartFrom_V, NameVarRestartTo_V
    use ModHallResist,    ONLY: &
         UseHallResist, read_hall_param
    use ModParticleFieldLine, ONLY: read_particle_line_param
    use ModParticleMover, ONLY: read_charged_particle_param=>read_param, &
         normalize_particle_param=>normalize_param, &
         UseChargedParticles=>UseParticles, UseHybrid
    use ModHeatConduction, ONLY: read_heatconduction_param
    use ModHeatFluxCollisionless, ONLY: read_heatflux_param
    use ModRadDiffusion,   ONLY: read_rad_diffusion_param
    use ModResistivity, ONLY: UseResistivity, &
         read_resistivity_param, init_mod_resistivity
    use ModMultiFluid, ONLY: MassIon_I,ChargeIon_I,nIonFluid, &
         DoConserveNeutrals, DoOhNeutralBc, &
         uBcFactor_I, RhoBcFactor_I, RhoNeutralsISW_dim, &
         UxNeutralsISW_dim, UyNeutralsISW_dim, UzNeutralsISW_dim, &
         TNeutralsISW_dim, mProtonMass

    use ModMultiIon, ONLY: multi_ion_set_parameters, &
         multi_ion_init_point_impl
    use ModSolarwind, ONLY: UseSolarwindFile, read_solar_wind_param, &
         read_solar_wind_file, normalize_solar_wind_data
    use ModSatelliteFile, ONLY: nSatellite, FilenameSat_I, NameSat_I, &
         read_satellite_parameters, read_satellite_input_files
    use ModGroundMagPerturb, ONLY: read_magperturb_param, init_mod_magperturb
    use ModFaceFlux, ONLY: face_flux_set_parameters, init_mod_face_flux, &
         TypeFluxNeutral, UseClimit, DoBurgers
    use ModLookupTable,     ONLY: read_lookup_table_param, get_lookup_table, &
         i_lookup_table
    use ModIeCoupling,      ONLY: read_ie_velocity_param
    use ModTimeStepControl, ONLY: read_time_step_control_param
    use ModLaserHeating,    ONLY: read_laser_heating_param
    use ModLocalTimeStep,   ONLY: read_localstep_param
    use ModIoUnit, ONLY: io_unit_new
    use ModNumConst, ONLY: cDegToRad, cTiny, cHalfPi
    use ModConst, ONLY: CarringtonSynodicPeriod, tStartCarringtonRotation
    use ModSort, ONLY: sort_quick

    use ModViscosity, ONLY: UseViscosity, viscosity_read_param, viscosity_init
    use ModPIC, ONLY: pic_read_param
    use ModIonElectron, ONLY: read_ion_electron_param, iVarUseCmax_I, &
         ion_electron_init_point_impl
    use ModFaceBoundary, ONLY: read_face_boundary_param
    ! CORONA SPECIFIC PARAMETERS
    use EEE_ModMain, ONLY: EEE_set_parameters
    use ModMagnetogram, ONLY: read_magnetogram_param
    use ModCoronalHeating,  ONLY: read_coronal_heating_param, &
         init_coronal_heating, UseCoronalHeating, UseAlfvenWaveDissipation
    use ModFieldLineThread, ONLY: read_thread_param
    use ModThreadedLC,      ONLY: init_threaded_lc, read_threaded_bc_param
    use ModRadiativeCooling, ONLY: UseRadCooling,&
         read_cooling_param, check_cooling_param
    use ModChromosphere, ONLY: read_chromosphere_param
    use ModCoarseAxis, ONLY: read_coarse_axis_param
    use ModWaves, ONLY: read_waves_param, check_waves
    use ModLdem, ONLY: UseLdem, NameLdemFile, iRadiusLdem, read_ldem
    use ModBorisCorrection, ONLY: read_boris_param, UseBorisCorrection, &
         init_mod_boris_correction

    use ModUser, ONLY: NameUserModule, VersionUserModule
    use ModUserInterface ! user_read_inputs, user_init_session
    use ModConserveFlux, ONLY: init_mod_cons_flux, DoConserveFlux
    use ModVarIndexes, ONLY: MassSpecies_V, SpeciesFirst_, SpeciesLast_
    use BATL_lib, ONLY: Dim2_, Dim3_, &
         create_grid, set_high_geometry, get_region_indexes, &
         rRound0, rRound1, StringTest

    character (len=17) :: NameSub='MH_set_parameters'

    ! Arguments

    ! TypeAction determines if we read or check parameters
    character (len=*), intent(in) :: TypeAction

    ! Local variables
    integer :: iFile, i, iFluid
    logical :: IsUninitialized      = .true.

    ! local variables for the plot type 'INS'
    integer :: iTmp, iFileStart, iFileRead, iFileInstrument, nPlotFileRead
    integer :: iInstrument, nInstrument, iSat
    character(LEN=10)  :: NameSat, NameInstrument, StringInstrument_I(20) = ''
    character(LEN=200) :: StringsInstrument

    !  logical :: HdfUninitialized      = .true.
    logical :: DoReadSolarwindFile  = .false.
    logical :: DoReadSatelliteFiles = .false.
    logical :: IsMirrorX,  IsMirrorY,  IsMirrorZ

    ! The name of the command
    character (len=lStringLine) :: NameCommand, StringLine

    ! Temporary variables
    logical :: DoEcho=.false.
    integer :: nVarEquationRead = 0
    character (len=lStringLine) :: NameEquationRead="?"
    logical :: IsReadNameVarRestart = .false.
    character(len=lStringLine) :: NameVarRestartRead  =''
    character(len=lStringLine) :: NameVarsRestartFrom =''
    character(len=lStringLine) :: NameVarsRestartTo   =''
    integer :: nVarRestartMappingFrom, nVarRestartMappingTo

    character (len=50) :: plot_string,log_string, TypeCoordObs
    character (len=3)  :: plot_area, plot_var
    character (len=2)  :: NameCompRead="??"
    integer :: MinBlockAll, nIJKRead_D(3), nRootRead_D(3)=1

    integer            :: TimingDepth=-1
    character (len=10) :: TimingStyle='cumu'

    ! Variables for checking/reading #STARTTIME command
    real(Real8_)       :: StartTimeCheck   = -1.0_Real8_
    real               :: tSimulationCheck = -1.0

    ! Variable for #UNIFORMAXIS
    logical:: UseUniformAxis = .true.

    ! Variables for checking the user module
    character(len=lStringLine) :: NameUserModuleRead='?'
    real                       :: VersionUserModuleRead=0.0

    ! Variables for user switches
    character(len=lStringLine) :: StringSwitch
    integer                    :: iSwitch, nSwitch
    character(len=25)          :: NameSwitch_I(10), NameSwitch
    logical                    :: DoSwitchOn

    ! Variables related to sessions
    logical :: IsFirstSession = .true.
    integer :: iSession, iSessionFirst = 0

    ! Indexes
    integer :: iSpecies, iPlotFile, iVar, iDim

    ! Variables for #SAVEPLOT command, to replace some common used variables
    ! in VAR string
    character(len(plot_vars1)+2) :: NamePlotVar
    integer :: l1, l2

    ! Variables for #BOUNDARYSTATE command
    character(len=lStringLine) :: StringBoundary
    ! The enames of face and cell boundaries
    character(len=10) :: NameBoundary_I(zMaxBc_-SolidBc_+1+Coord3MaxBc_)
    integer :: iNameBoundary, nNameBoundary, iBoundaryState = 0
    real    :: BoundaryStateDim_V(1:nVar)

    character(len=30) :: NamePrimitiveNT_V(nVar)

    ! variables for LookUpTable
    integer:: nParam, iTableB0 = -1
    real(Real8_):: CarringtonRotationNumber
    character(len=500):: StringHeader
    real:: Param_I(4)

    !--------------------------------------------------------------------------
    NameSub(1:2) = NameThisComp

    iSession = i_session_read()
    ! First session when component is reading parameters
    if(iSessionFirst < 1) iSessionFirst = iSession

    ! Initialize BATL
    call init_mpi(iComm)

    if(IsUninitialized)then
       call set_namevar
       call set_defaults
       IsUninitialized=.false.
    end if

    ! restart in first session only
    if(.not.IsFirstSession) restart=.false.

    select case(TypeAction)
    case('CHECK')
       if(iProc==0)write(*,*) NameSub,': CHECK iSession =',iSession

       ! Make output and check input directories
       if(iProc==0) call make_dir(NamePlotDir)
       if(iProc==0 .and. save_restart_file) call make_dir(NameRestartOutDir)
       if(iProc==0 .and. restart) call check_dir(NameRestartInDir)

       ! Check if StartTime from PARAM.in and Carrington Map Time match
       iTableB0 = i_lookup_table('B0')
       if(iTableB0 > 0)then
          call get_lookup_table(1, StringDescription = StringHeader, &
               nParam=nParam, Param_I=Param_I)
          if(iProc==0 .and. nParam >= 4 )then
             CarringtonRotationNumber = (StartTime &
                  - tStartCarringtonRotation)/CarringtonSynodicPeriod
             ! If the User provided StartTime is off by over half of the
             ! Carrington Rotation, it stops
             if((abs(CarringtonRotationNumber - Param_I(4))) > 0.5)then
                write(*,*)NameSub,': Carrington Rotation number from '// &
                     'PARAM.in  = ', CarringtonRotationNumber
                write(*,*)NameSub,': Carrington Rotation number from '// &
                     'input map = ',Param_I(4)
                write(*,*)NameSub,': WARNING! #STARTTIME in PARAM.in '// &
                     'differs from Carrington Rotation of Central Meridian '//&
                     'of Input Map !!!'
                if(UseStrict) call stop_mpi('Fix #STARTTIME or use CORRECT Magnetogram')
             endif
          endif
       endif

       if(StartTimeCheck > 0.0 .and. tSimulationCheck > 0.0)then
          if(abs(StartTime+time_simulation - StartTimeCheck-tSimulationCheck)&
               > 0.001)then
             write(*,*)NameSub//' WARNING: '// &
                  NameThisComp//'::StartTimeCheck+tSimulationCheck=', &
                  StartTimeCheck + tSimulationCheck, &
                  ' differs from CON::StartTime+tSimulation=', &
                  StartTime + time_simulation,' !!!'
             if(UseStrict)then
                call stop_mpi('Fix #STARTTIME command in PARAM.in')
             else
                ! Fix iStartTime_I array
                call time_real_to_int(StartTime, iStartTime_I)
             end if
          end if
          StartTimeCheck   = -1.0
          tSimulationCheck = -1.0
       end if
       if(UseEndTime)then
          t_max = EndTime - StartTime
          nIter = -1
          if(IsStandAlone)then
             if(.not.time_accurate)call stop_mpi( &
                  '#ENDTIME command cannot be used in steady-state mode')
             if(.not.IsLastRead) call stop_mpi(&
                  '#ENDTIME command can be used in the last session only')
          end if
       end if
       ! Planet NONE in GM means that we do not use a body
       if (NameThisComp=='GM' .and. NamePlanet == 'NONE' &
            .and. IsFirstSession)then
          body1 = .false.
          ! Change the default conservative criteria when there is no planet
          ! and the #CONSERVATIVECRITERIA command did not occur
          if(i_line_command("#CONSERVATIVECRITERIA") < 0)then
             nConservCrit = 0
             deallocate(TypeConservCrit_I)
             if(i_line_command("#NONCONSERVATIVE") < 0) &
                  UseNonConservative = .false.
          end if
       end if

       ! Initialize axes (coordinate transformation matrices)
       call init_axes(StartTime)

       if(DoReadSatelliteFiles)then
          call read_satellite_input_files
          DoReadSatelliteFiles = .false.
       end if

       if(NameThisComp == 'GM') then
          ! Set and obtain GM specific parameters from CON_planet and CON_axes
          call get_axes(Time_Simulation, MagAxisTiltGsmOut = ThetaTilt)
          call get_planet(DipoleStrengthOut = DipoleStrengthSi)
       end if

       if(MonopoleStrengthSi /= 0.0)then
          UseB0       = .true.
          UseB0Source = .false.
          UseCurlB0   = .false.
          DoUpdateB0  = .false.
          DtUpdateB0  = -1.0
       elseif(IsStandAlone .and. NameThisComp=='GM') then
          ! Check and set some planet variables (e.g. DoUpdateB0)
          call check_planet_var(iProc==0, time_accurate)

          if(body1)then
             call get_planet(UseRotationOut = UseRotatingBc)
          else
             UseRotatingBc = .false.
          end if

          ! Obtain some planet parameters
          if(.not.UseB0 .or. &
               (DipoleStrengthSi == 0.0 .and. .not. UseUserB0))then
             UseB0       = .false.
             UseB0Source = .false.
             UseCurlB0   = .false.
             DoUpdateB0  = .false.
             DtUpdateB0  = -1.0
          else
             call get_planet( &
                  DoUpdateB0Out = DoUpdateB0, DtUpdateB0Out = DtUpdateB0)
          end if

       end if

       ! Set number and indexes of vector variables
       call init_vector_variables

       call correct_parameters

       ! initialize module variables
       call init_mod_main
       call init_mod_advance
       call init_mod_geometry
       call init_mod_boundary_cells
       call init_mod_nodes

       if(UseB .and. UseBorisCorrection) call init_mod_boris_correction
       if(UseB0)            call init_mod_b0
       if(UseRaytrace)      call init_mod_field_trace
       if(UseConstrainB)    call init_mod_ct
       if(UseImplicit)      call init_mod_part_impl
       if(UseSemiImplicit)  call init_mod_semi_impl

       if(UsePointImplicit)then
          if(UseEfield)then
             call init_mod_point_impl(ion_electron_init_point_impl)
          elseif(UseMultiIon)then
             call init_mod_point_impl(multi_ion_init_point_impl)
          elseif(UseUserSourceImpl)then
             call init_mod_point_impl(user_init_point_implicit)
          else
             ! call init_mod_point_impl
          end if
       end if

       call init_mod_face_flux
       if(DoConserveFlux)   call init_mod_cons_flux
       call init_mod_magperturb

       call get_region_indexes(StringLowOrderRegion, iRegionLowOrder_I)

       ! clean dynamic storage
       call init_mod_block_data
       call clean_block_data

       ! set physics uses dimensional solar wind data
       if (DoReadSolarwindFile) call read_solar_wind_file

       call set_physics_constants

       call user_action("initialize module")

       if(UseChargedParticles)then
          if(.not.time_accurate)then
             if(iProc==0)write(*,*)'To trace particles, use time-accurate!'
             call stop_mpi('Correct parameter file!!')
          end if
          if(.not.UseB)then
             if(iProc==0)write(*,*)'To trace particles use MHD!'
             call stop_mpi('Correct parameter file!!')
          end if
          if(IsMhd.and.UseHybrid)then
             if(iProc==0)write(*,*)'Single fluid MHD cant be hybrid'
             call stop_mpi('Correct parameter file or set IsMhd=.false.')
          end if
          if(UseHybrid.and..not.UseFlic)then
             if(iProc==0) &
                  write(*,*) NameSub,':UseHybrid=.true., set UseFlic=.true.'
          end if
          call normalize_particle_param
       end if
       if(UseFlic.and.nStage/=3)then
          if(iProc==0) &
               write(*,*) NameSub,':UseFlic=.true., set nStage to 3'
          nStage = 3
       end if

       ! Normalization of solar wind data requires normalization in set_physics
       if (DoReadSolarwindFile) call normalize_solar_wind_data

       call set_extra_parameters

       ! initialize ModEqution (e.g. variable units)
       call init_mhd_variables

       if(UseResistivity)call init_mod_resistivity
       if(UseViscosity) call viscosity_init

       if(UseCoronalHeating)call init_coronal_heating
       call check_cooling_param

       ! Initialize threaded field line module (lower corona)
       if(UseFieldLineThreads .and. IsFirstSession)call init_threaded_lc

       ! Initialize user module and allow user to modify things
       if(UseUserInitSession)call user_init_session

       call check_waves

       if((iProc==0 .or. UseTimingAll) .and. IsStandAlone)then
          call timing_active(UseTiming)
          if(IsFirstSession)then
             call timing_step(0)
             if(UseTimingAll)then
                iUnitTiming = io_unit_new()
                write(NameTimingFile,'(a,i6.6)') 'timing.pe', iProc
                call open_file(iUnitTiming, FILE=NameTimingFile)
                call timing_iounit(iUnitTiming)
                call timing_comp_proc("  ",iProc)
             end if
          end if
          call timing_depth(TimingDepth)
          call timing_report_style(TimingStyle)
       end if

       IsFirstSession = .false.

       RETURN
    case('read','Read','READ')
       if(iProc==0)then
          write(*,*) NameSub,': READ iSession =',iSession,&
               ' iLine=',i_line_read(),' nLine =',n_line_read()
       end if
    case default
       call stop_mpi(NameSub//': TypeAction='//TypeAction// &
            ' must be "CHECK" or "READ"!')
    end select

    ! Read solarwindfile if #SOLARWINDFILE command is in this session
    DoReadSolarwindFile = .false.

    ! Read parameters from the text
    READPARAM: do
       if(.not.read_line(StringLine) )then
          IsLastRead = .true.
          EXIT READPARAM
       end if

       if(.not.read_command(NameCommand)) CYCLE READPARAM

       select case(NameCommand)

       case("#BATLPROLONG")
          call read_var('BetaProlong', BetaProlong )

       case("#COMPONENT")
          call read_var('NameComp', NameCompRead)
          if(NameThisComp /= NameCompRead)then
             NameThisComp = NameCompRead
             call set_defaults
          end if

       case("#DESCRIPTION")
          call check_stand_alone

       case("#BEGIN_COMP","#END_COMP")
          call check_stand_alone
          i = len_trim(NameCommand)
          if(StringLine(i+2:i+3) /= NameThisComp)&
               call stop_mpi(NameSub//' ERROR: the component is not '// &
               NameThisComp//'in '//trim(StringLine))

       case("#END")
          call check_stand_alone
          IslastRead=.true.
          EXIT READPARAM

       case("#RUN")
          call check_stand_alone
          IslastRead=.false.
          EXIT READPARAM

       case("#STOP")
          call check_stand_alone
          call read_var('MaxIteration',nIter)
          call read_var('tSimulationMax',t_max)

       case("#CPUTIMEMAX")
          call check_stand_alone
          call read_var('CpuTimeMax',cputime_max)

       case("#CHECKSTOPFILE")
          call check_stand_alone
          call read_var('DoCheckStopfile',check_stopfile)

       case("#PROGRESS")
          call check_stand_alone
          call read_var('DnProgressShort',dn_progress1)
          call read_var('DnProgressLong',dn_progress2)

       case("#TIMEACCURATE")
          call check_stand_alone
          call read_var('DoTimeAccurate',time_accurate)

       case("#ECHO")
          call check_stand_alone
          call read_var('DoEcho', DoEcho)
          if(iProc==0)call read_echo_set(DoEcho)

       case("#FLUSH")
          call read_var('DoFlush', DoFlush)

       case("#TESTINFO")
          call read_var('DoWriteCallSequence', DoWriteCallSequence)

       case("#VERBOSE", "#TEST", "#TESTXYZ", "#TEST2XYZ", "#TESTIJK", &
            "#TEST2IJK", "#TESTVAR", "#TESTDIM")
          call read_test_param(NameCommand)
          if(NameCommand == "#TESTVAR") call get_iVar(NameVarTest, iVarTest)
          if(NameCommand == "#TEST" .and. IsStandAlone) &
               StringTestSwmf = StringTest

       case("#STRICT")
          call read_var('UseStrict',UseStrict)

       case("#DEBUG")
          call read_var('DoDebug',okdebug)
          call read_var('DoDebugGhost',ShowGhostCells)

       case("#TIMING")
          call read_var('UseTiming',UseTiming)
          if(UseTiming)then
             call read_var('DnTiming',dn_timing)
             call read_var('nDepthTiming',TimingDepth)
             call read_var('TypeTimingReport',TimingStyle)
             UseTimingAll = index(TimingStyle,'all') > 0
             TimingStyle  = TimingStyle(1:4)
          end if

       case("#OPTIMIZEMPI")
          call read_var('UseOptimizeMpi', UseOptimizeMpi)

       case("#OUTERBOUNDARY","#BOXBOUNDARY")
          call read_boundary_geometry_param(NameCommand)

       case("#TIMESTEPPING", "#RUNGEKUTTA", "#RK")
          call read_var('nStage',  nStage)
          call read_var('CflExpl', Cfl)
          CflOrig = Cfl
          ExplCfl = Cfl
          UseHalfStep = NameCommand == "#TIMESTEPPING" .and. nStage <= 2

       CASE('#USEFLIC')
          call read_var('UseFlic', UseFlic)

       case("#LOCALTIMESTEP", "#SUBCYCLING")
          call read_localstep_param(NameCommand, iSession)

       case( "#TIMESTEPLIMIT")
          call               read_var('UseDtLimit', UseDtLimit)
          if(UseDtLimit)call read_var('DtLimitDim', DtLimitDim)

       case("#FIXEDTIMESTEP")
          call               read_var('UseDtFixed', UseDtFixed)
          if(UseDtFixed)call read_var('DtFixedDim', DtFixedDim)

       case("#PARTSTEADY")
          call read_var('UsePartSteady',UsePartSteady)

       case("#PARTSTEADYCRITERIA","#STEADYCRITERIA")
          call read_var('MinCheckVar',MinCheckVar)
          call read_var('MaxCheckVar',MaxCheckVar)
          do iVar=MinCheckVar, MaxCheckVar
             call read_var('RelativeEps',RelativeEps_V(iVar))
             call read_var('AbsoluteEps',AbsoluteEps_V(iVar))
          end do

       case("#POINTIMPLICIT")
          call read_point_implicit_param

       case("#LINEARSOLVERACCURATESUM")
          call read_var('UseAccurateSum', UseAccurateSum)

       case("#IMPLICIT", "#GRIDBLOCKIMPL", "#GRIDBLOCKIMPLALL", &
            "#IMPLCRITERIA", "#IMPLICITCRITERIA", "#STEPPINGCRITERIA", &
            "#PARTIMPL", "#PARTIMPLICIT",     &
            "#IMPLSCHEME", "#IMPLICITSCHEME", &
            "#IMPLSTEP", "#IMPLICITSTEP",     &
            "#IMPLCHECK", "#IMPLICITCHECK",   &
            "#IMPLENERGY", "#IMPLICITENERGY", &
            "#NEWTON", "#JACOBIAN", "#PRECONDITIONER", &
            "#KRYLOV", "#KRYLOVSIZE")
          call read_part_impl_param(NameCommand)

       case("#SEMIIMPL", "#SEMIIMPLICIT", &
            "#SEMICOEFF", "#SEMIIMPLCOEFF", "#SEMIIMPLICITCOEFF", &
            "#SEMIPRECOND", "#SEMIPRECONDITIONER",&
            "#SEMIKRYLOV", "#SEMIKRYLOVSIZE","#SEMIIMPLICITSTABLE")
          call read_semi_impl_param(NameCommand)

       case("#HYPRE")
          call hypre_read_param

       case("#PICGRID", '#PICGRIDROTATE', "#PICUNIT", "#PICGRIDUNIT", &
            "#PICBALANCE", "#PICADAPT", "#PICPATCH", "#PICCRITERIA", &
            "#PICPATCHEXTEND", "#PICREGIONMIN", "#PICREGIONMAX", &
            "#RESTARTPICSTATUS")
          call pic_read_param(NameCommand)

       case("#VISCOSITY", "#VISCOSITYREGION","#ARTIFICIALVISCOSITY")
          call viscosity_read_param(NameCommand)

       case("#RESISTIVITY", "#RESISTIVITYOPTIONS", &
            "#RESISTIVITYREGION", "#RESISTIVEREGION",&
            '#MESSAGEPASSRESISTIVITY','#RESISTIVITYSCHEME')
          call read_resistivity_param(NameCommand)

       case("#HALLRESISTIVITY", "#HALLREGION", "#BIERMANNBATTERY")
          call read_hall_param(NameCommand)

       case("#MINIMUMDENSITY")
          do iFluid = IonFirst_, nFluid
             call read_var('RhoMinDim', RhoMinDim_I(iFluid))
          end do

       case("#MINIMUMPRESSURE")
          do iFluid = IonFirst_, nFluid
             call read_var('pMinDim', pMinDim_I(iFluid))
          end do
          if(UseElectronPressure) call read_var('PeMinDim', PeMinDim)

       case("#MINIMUMTEMPERATURE")
          do iFluid = IonFirst_, nFluid
             call read_var('TMinDim', TMinDim_I(iFluid))
          end do
          if(UseElectronPressure) call read_var('TeMinDim', TeMinDim)

       case("#MINIMUMRADIALSPEED")
          call    read_var('UseSpeedMin',   UseSpeedMin)
          if(UseSpeedMin)then
             call read_var('rSpeedMin',     rSpeedMin)
             call read_var('SpeedMinDim',   SpeedMinDim)
             call read_var('TauSpeedMinDim',TauSpeedMinDim)
          end if

       case("#ELECTRONPRESSURE")
          call read_var('PeMinSi', PeMinSi)

       case("#ELECTRONENTROPY")
          call read_var('UseElectronEntropy', UseElectronEntropy)

       case("#ANISOTROPICPRESSURE")
          do iFluid = IonFirst_, nFluid
             call read_var('UseConstantTau_I', UseConstantTau_I(iFluid))
             call read_var('TauInstabilitySi_I', TauInstabilitySi_I(iFluid))
             call read_var('TauGlobalSi_I', TauGlobalSi_I(iFluid))
          end do

       case("#EXTRAINTERNALENERGY")
          call read_var('ExtraEintMinSi', ExtraEintMinSi)

       case("#RADIATION", "#HEATFLUXLIMITER", "#ACCURATERADIATION")
          call read_rad_diffusion_param(NameCommand)

       case("#HEATCONDUCTION", "#WEAKFIELDCONDUCTION", "#IONHEATCONDUCTION")
          call read_heatconduction_param(NameCommand)

       case("#HEATFLUXREGION", "#HEATFLUXCOLLISIONLESS")
          call read_heatflux_param(NameCommand)

       case("#COULOMBLOG")
          call read_var('CoulombLog', CoulombLog)

       case("#PARTICLELINE","#PARTICLELINERANDOMWALK")
          call read_particle_line_param(NameCommand)

       case("#CHARGEDPARTICLES")
          call read_charged_particle_param(NameCommand)

       case("#SAVELOGFILE")
          call read_var('DoSaveLogfile',save_logfile)
          if(save_logfile)then
             nfile=max(nfile,logfile_)
             call read_var('StringLog',log_string)
             call read_var('DnSaveLogfile',dn_output(logfile_))
             call read_var('DtSaveLogfile',dt_output(logfile_))

             ! Log variables
             if(index(log_string,'VAR')>0 .or. index(log_string,'var')>0)then
                plot_dimensional(logfile_) = index(log_string,'VAR')>0
                log_time='step time'
                call read_var('log_vars',log_vars)
             elseif(index(log_string,'RAW')>0 &
                  .or. index(log_string,'raw')>0)then
                plot_dimensional(logfile_) = index(log_string,'RAW')>0
                log_time='step time'
                log_vars='dt '//NameConservativeVarPlot//' Pmin Pmax'
             elseif(index(log_string,'MHD')>0 &
                  .or. index(log_string,'mhd')>0)then
                plot_dimensional(logfile_) = index(log_string,'MHD')>0
                log_time='step date time'
                log_vars=NameConservativeVarPlot//' Pmin Pmax'
             elseif(index(log_string,'FLX')>0 &
                  .or. index(log_string,'flx')>0)then
                plot_dimensional(logfile_) = index(log_string,'FLX')>0
                log_time='step date time'
                log_vars='rho pmin pmax rhoflx pvecflx e2dflx'
             else
                call stop_mpi('Log variables (mhd,MHD,var,VAR,flx) missing'&
                     //' from log_string='//log_string)
             end if

             ! Determine the time output format to use in the logfile.
             ! This is loaded by default above, but can be input in the
             ! log_string line.
             if(index(log_string,'none')>0) then
                log_time = 'none'
             elseif((index(log_string,'step')>0) .or. &
                  (index(log_string,'date')>0) .or. &
                  (index(log_string,'time')>0)) then
                log_time = ''
                if(index(log_string,'step')>0) log_time = 'step'
                if(index(log_string,'date')>0) &
                     write(log_time,'(a)') log_time(1:len_trim(log_time))&
                     //' date'
                if(index(log_string,'time')>0) &
                     write(log_time,'(a)') log_time(1:len_trim(log_time))&
                     //' time'
             end if

             ! Recognize coordinate system names
             if (index(log_string,'GEO') > 0) TypeCoordPlot_I(logfile_) = 'GEO'
             if (index(log_string,'GSE') > 0) TypeCoordPlot_I(logfile_) = 'GSE'
             if (index(log_string,'GSM') > 0) TypeCoordPlot_I(logfile_) = 'GSM'
             if (index(log_string,'MAG') > 0) TypeCoordPlot_I(logfile_) = 'MAG'
             if (index(log_string,'SMG') > 0) TypeCoordPlot_I(logfile_) = 'SMG'
             if (index(log_string,'HGR') > 0) TypeCoordPlot_I(logfile_) = 'HGR'
             if (index(log_string,'HGI') > 0) TypeCoordPlot_I(logfile_) = 'HGI'
             if (index(log_string,'HGC') > 0) TypeCoordPlot_I(logfile_) = 'HGC'

             ! If any flux variables are used - input a list of radii
             ! at which to calculate the flux
             if (index(log_vars,'flx')>0) &
                  call read_var('log_R_str',log_R_str)

          end if

       case("#SAVEINITIAL")
          call read_var('DoSaveInitial',DoSaveInitial)

       case("#SAVETECPLOT")
          call read_var('DoSaveOneTecFile', DoSaveOneTecFileOrig)

       case("#SAVEPLOT")
          call read_var('nPlotFile', nPlotFileRead)
          nFile = max(nFile, plot_ + nPlotFileRead)
          if (nFile > MaxFile .or. nPlotFileRead > MaxPlotFile) call stop_mpi(&
               'The number of ouput files is too large in #SAVEPLOT:'&
               //' nPlotFile > MaxPlotFile .or. nFile > MaxFile')

          nPlotFile  = nPlotFileRead
          iFileStart = Plot_

          TypeSatPos_I       = 'none'

          do iFileRead = 1, nPlotFileRead
             ! reset nInstrument at the beginning
             nInstrument = 0

             iFile = iFileStart + iFileRead

             call read_var('StringPlot',plot_string)

             ! Plotting frequency
             call read_var('DnSavePlot',dn_output(iFile))
             call read_var('DtSavePlot',dt_output(iFile))

             ! Default resolution (original AMR grid)
             plot_dx(:,iFile) = -1.0

             ! Plotting area
             if(index(plot_string,'cut')>0)then
                plot_area='cut'
                call read_var('xMinCut',plot_range(1,iFile))
                call read_var('xMaxCut',plot_range(2,iFile))
                call read_var('yMinCut',plot_range(3,iFile))
                call read_var('yMaxCut',plot_range(4,iFile))
                call read_var('zMinCut',plot_range(5,iFile))
                call read_var('zMaxCut',plot_range(6,iFile))
             elseif(index(plot_string,'bx0')>0)then
                plot_area='bx0'
                call read_var('xMinCut',plot_range(1,iFile))
                call read_var('xMaxCut',plot_range(2,iFile))
                call read_var('yMinCut',plot_range(3,iFile))
                call read_var('yMaxCut',plot_range(4,iFile))
                call read_var('zMinCut',plot_range(5,iFile))
                call read_var('zMaxCut',plot_range(6,iFile))
             elseif(index(plot_string,'slc')>0)then
                plot_area='slc'
                call read_var('xMinCut',plot_range(1,iFile))
                call read_var('xMaxCut',plot_range(2,iFile))
                call read_var('yMinCut',plot_range(3,iFile))
                call read_var('yMaxCut',plot_range(4,iFile))
                call read_var('zMinCut',plot_range(5,iFile))
                call read_var('zMaxCut',plot_range(6,iFile))
                call read_var('xPoint',plot_point(1,iFile))
                call read_var('yPoint',plot_point(2,iFile))
                call read_var('zPoint',plot_point(3,iFile))
                call read_var('xNormal',plot_normal(1,iFile))
                call read_var('yNormal',plot_normal(2,iFile))
                call read_var('zNormal',plot_normal(3,iFile))
             elseif(index(plot_string,'dpl')>0)then
                plot_area='dpl'
                call read_var('xMinCut',plot_range(1,iFile))
                call read_var('xMaxCut',plot_range(2,iFile))
                call read_var('yMinCut',plot_range(3,iFile))
                call read_var('yMaxCut',plot_range(4,iFile))
                call read_var('zMinCut',plot_range(5,iFile))
                call read_var('zMaxCut',plot_range(6,iFile))
             elseif (index(plot_string,'blk')>0) then
                plot_area='blk'
                call read_var('xPoint',plot_point(1,iFile))
                call read_var('yPoint',plot_point(2,iFile))
                call read_var('zPoint',plot_point(3,iFile))
             elseif (index(plot_string,'pnt')>0) then
                plot_area='pnt'
             elseif(index(plot_string,'lin')>0)then
                iPlotFile = iFile - Plot_
                plot_area='lin'
                call read_var('NameLine', NameLine_I(iPlotFile), &
                     IsUpperCase=.true.)
                call read_var('IsSingleLine',IsSingleLine_I(iPlotFile))
                call read_var('nLine',nLine_I(iPlotFile))
                if(nLine_I(iPlotFile)==1)IsSingleLine_I(iPlotFile)=.true.
                if(nLine_I(iPlotFile) > MaxLine)then
                   if(iProc==0)then
                      write(*,*)NameSub,' WARNING: nLine=',nLine_I(iPlotFile),&
                           ' exceeds MaxLine=',MaxLine
                      write(*,*)NameSub,' WARNING reducing nLine to MaxLine'
                   end if
                   nLine_I(iPlotFile) = MaxLine
                end if
                do i = 1, nLine_I(iPlotFile)
                   call read_var('xStartLine',XyzStartLine_DII(1,i,iPlotFile))
                   call read_var('yStartLine',XyzStartLine_DII(2,i,iPlotFile))
                   call read_var('zStartLine',XyzStartLine_DII(3,i,iPlotFile))
                   call read_var('IsParallel',IsParallelLine_II(i,iPlotFile))
                end do
             elseif (index(plot_string,'eqr')>0)then
                plot_area='eqr'
                call read_var('nRadius',   plot_range(1,iFile))
                call read_var('nLon',      plot_range(2,iFile))
                call read_var('RadiusMin', plot_range(3,iFile))
                call read_var('RadiusMax', plot_range(4,iFile))
                plot_range(5,iFile) =   0.0
                plot_range(6,iFile) = 360.0
             elseif (index(plot_string,'eqb')>0)then
                plot_area='eqb'
                call read_var('nRadius',   plot_range(1,iFile))
                call read_var('nLon',      plot_range(2,iFile))
                call read_var('RadiusMin', plot_range(3,iFile))
                call read_var('RadiusMax', plot_range(4,iFile))
                call read_var('LongitudeMin', plot_range(5,iFile))
                call read_var('LongitudeMax', plot_range(6,iFile))
             elseif (index(plot_string,'ieb')>0)then
                plot_area='ieb'
             elseif (index(plot_string,'lcb')>0)then
                plot_area='lcb'
                call read_var('Radius', plot_range(1,iFile))
                call read_var('nLon',   plot_range(2,iFile))
             elseif (index(plot_string,'sph')>0)then
                plot_area='sph'
                call read_var('Radius',plot_range(1,iFile))
             elseif (index(plot_string, 'shl')>0)then
                plot_area = 'shl'
                call read_var('TypeCoord', TypeCoordPlot_I(iFile))
                call read_var('rMin',   plot_range(1,iFile))
                call read_var('rMax',   plot_range(2,iFile))
                if (plot_range(1, iFile) /= plot_range(2,iFile)) &
                     call read_var('dR',   plot_dx(1,iFile))
                call read_var('LonMin', plot_range(3,iFile))
                call read_var('LonMax', plot_range(4,iFile))
                if (plot_range(3, iFile) /= plot_range(4,iFile)) &
                     call read_var('dLon', plot_dx(2,iFile))
                call read_var('LatMin', plot_range(5,iFile))
                call read_var('LatMax', plot_range(6,iFile))
                if (plot_range(5, iFile) /= plot_range(6,iFile)) &
                     call read_var('dLat', plot_dx(3,iFile))
             elseif (index(plot_string, 'box')>0)then
                plot_area = 'box'
                call read_var('TypeCoord', TypeCoordObs)
                TypeCoordPlot_I(iFile) = TypeCoordObs(1:3)
                IsObsBox_I(iFile) = index(TypeCoordObs,'OBS')>0
                call read_var('x0',   plot_range(1,iFile))
                call read_var('y0',   plot_range(2,iFile))
                call read_var('z0',   plot_range(3,iFile))
                call read_var('xLen',   plot_range(4,iFile))
                if (plot_range(4, iFile) /= 0) &
                     call read_var('dX',   plot_dx(1,iFile))
                call read_var('yLen', plot_range(5,iFile))
                if (plot_range(5, iFile) /= 0) &
                     call read_var('dY', plot_dx(2,iFile))
                call read_var('zLen', plot_range(6,iFile))
                if (plot_range(6, iFile) /= 0) &
                     call read_var('dZ', plot_dx(3,iFile))
                if(IsObsBox_I(iFile)) then
                   call read_var('TiltAngle', plot_normal(1,iFile))
                   call read_var('ObsPosX_HGI',ObsPos_DI(1,iFile))
                   call read_var('ObsPosY_HGI',ObsPos_DI(2,iFile))
                   call read_var('ObsPosZ_HGI',ObsPos_DI(3,iFile))
                else
                   call read_var('xAngle', plot_normal(1,iFile))
                   call read_var('yAngle', plot_normal(2,iFile))
                   call read_var('zAngle', plot_normal(3,iFile))
                end if
             elseif (index(plot_string,'los')>0) then
                plot_area='los'
                ! Line of sight vector

                if(index(plot_string,'ins') == 0 .and.                      &
                     index(plot_string,'INS') == 0) then

                   ! original code witout 'ins' or 'INS'

                   ! Satellite position
                   if(NameThisComp == 'GM')then
                      call read_var('ObsPosX',ObsPos_DI(1,iFile))
                      call read_var('ObsPosY',ObsPos_DI(2,iFile))
                      call read_var('ObsPosZ',ObsPos_DI(3,iFile))
                   else
                      ! Coordinates of the observation point are in HGI
                      ! system
                      call read_var('ObsPosX_HGI',ObsPos_DI(1,iFile))
                      call read_var('ObsPosY_HGI',ObsPos_DI(2,iFile))
                      call read_var('ObsPosZ_HGI',ObsPos_DI(3,iFile))
                   end if
                   ! Offset angle
                   call read_var('OffsetAngle',offset_angle(iFile))
                   offset_angle(iFile) = offset_angle(iFile)*cDegToRad
                   ! read max dimensions of the 2d image plane
                   call read_var('rSizeImage',r_size_image(iFile))
                   ! read the position of image origin relative to grid origin
                   call read_var('xOffset',xoffset(iFile))
                   call read_var('yOffset',yoffset(iFile))
                   ! read the occulting radius
                   call read_var('rOccult',radius_occult(iFile))
                   ! read the limb darkening parameter
                   call read_var('MuLimbDarkening',mu_los)
                   ! read the number of pixels
                   call read_var('nPix',n_pix_r(iFile))
                   ! if it is an EUV plot using a long table then read in the
                   ! name of the specific lookup table (will be matched to the
                   ! name read in by the lookuptable command).
                   if (index(plot_string,'TBL')>0&
                        .or.index(plot_string,'tbl')>0) &
                        call read_var('NameLosTable',NameLosTable(iFile))
                else
                   ! if 'ins' or 'INS' exists
                   call read_var('StringsInstrument',  StringsInstrument, &
                        IsLowerCase=.true.)

                   call split_string(StringsInstrument, StringInstrument_I,   &
                        nInstrument)

                   ! each instrument adds another plot file
                   nPlotFile = nPlotFile + nInstrument - 1

                   ! adjust nFile
                   nFile = max(nFile, plot_ + nPlotFile)
                   if (nFile > MaxFile .or. nPlotFile > MaxPlotFile)          &
                        call stop_mpi(                                        &
                        'The number of ouput files is too large in #SAVEPLOT:'&
                        //' nPlotFile > MaxPlotFile .or. nFile > MaxFile')

                   ! setting each instrument info
                   do iInstrument = 1, nInstrument

                      iFileInstrument = iFile + iInstrument - 1

                      ! obtain the name of the satellite and instrument
                      iTmp    = index(StringInstrument_I(iInstrument),':')
                      NameSat = StringInstrument_I(iInstrument)(1:iTmp-1)
                      NameInstrument = StringInstrument_I(iInstrument)(iTmp+1:)

                      ! plotting frequency is the same as iFile
                      dn_output(iFileInstrument) = dn_output(iFile)
                      dt_output(iFileInstrument) = dt_output(iFile)
                      plot_type(iFileInstrument) = plot_area//'_'//          &
                           trim(NameSat)//'_'//trim(NameInstrument)
                      plot_dx(:,iFileInstrument) = -1

                      ! default values, which may be overwritten below
                      ObsPos_DI(:,iFileInstrument)   = [200.0, 0.0, 0.0]
                      offset_angle(iFileInstrument)  = 0.
                      r_size_image(iFileInstrument)  = 1.98
                      xoffset(iFileInstrument)       = 0.
                      yoffset(iFileInstrument)       = 0.
                      radius_occult(iFileInstrument) = 0.
                      mu_los                         = 0.
                      n_pix_r(iFileInstrument)       = 512
                      NameLosTable(iFileInstrument)  = ''

                      ! setting plot variables, which may be overwritten below
                      plot_dimensional(iFileInstrument) =                    &
                           index(plot_string,'INS')>0
                      plot_vars(iFileInstrument) = 'wl pb'
                      plot_pars(iFileInstrument) = 'obsx obsy obsz'

                      select case(trim(NameSat))
                      case('sta')
                         TypeSatPos_I(iFileInstrument) = 'sta'

                         select case(trim(NameInstrument))
                         case('euvi')
                            NameLosTable(iFileInstrument)  = 'EuviA'
                            plot_vars(iFileInstrument)     = 'tbl'
                         case('cor1')
                            r_size_image(iFileInstrument)  = 4.0
                            radius_occult(iFileInstrument) = 1.3
                            mu_los                         = 0.5
                            n_pix_r(iFileInstrument)       = 300
                         case('cor2')
                            r_size_image(iFileInstrument)  = 15.0
                            radius_occult(iFileInstrument) = 2.0
                            mu_los                         = 0.5
                            n_pix_r(iFileInstrument)       = 300
                         case default
                            call stop_mpi(NameSub//': unknown INS: '//       &
                                 StringInstrument_I(iInstrument))
                         end select
                      case('stb')
                         TypeSatPos_I(iFileInstrument) = 'stb'

                         select case(trim(NameInstrument))
                         case('euvi')
                            NameLosTable(iFileInstrument)  = 'EuviB'
                            plot_vars(iFileInstrument)     = 'tbl'
                         case('cor1')
                            r_size_image(iFileInstrument)  = 4.0
                            radius_occult(iFileInstrument) = 1.3
                            mu_los                         = 0.5
                            n_pix_r(iFileInstrument)       = 300
                         case('cor2')
                            r_size_image(iFileInstrument)  = 15.0
                            radius_occult(iFileInstrument) = 2.0
                            mu_los                         = 0.5
                            n_pix_r(iFileInstrument)       = 300
                         case default
                            call stop_mpi(NameSub//': unknown INS: '// &
                                 StringInstrument_I(iInstrument))
                         end select
                      case('sdo')
                         TypeSatPos_I(iFileInstrument) = 'earth'

                         select case(trim(NameInstrument))
                         case('aia')
                            NameLosTable(iFileInstrument)  = 'AiaXrt'
                            plot_vars(iFileInstrument)     = 'tbl'
                         case default
                            call stop_mpi(NameSub//': unknown INS: '// &
                                 StringInstrument_I(iInstrument))
                         end select
                      case('hinode')
                         TypeSatPos_I(iFileInstrument) = 'earth'

                         select case(trim(NameInstrument))
                         case('xrt')
                            NameLosTable(iFileInstrument)  = 'AiaXrt'
                            plot_vars(iFileInstrument)     = 'tbl'
                         case default
                            call stop_mpi(NameSub//': unknown INS: '// &
                                 StringInstrument_I(iInstrument))
                         end select
                      case('soho')
                         TypeSatPos_I(iFileInstrument) = 'earth'

                         n_pix_r(iFileInstrument)       = 300
                         mu_los                         = 0.5

                         select case(trim(NameInstrument))
                         case('c2')
                            r_size_image(iFileInstrument)  = 6.0
                            radius_occult(iFileInstrument) = 2.0
                         case('c3')
                            r_size_image(iFileInstrument)  = 32.0
                            radius_occult(iFileInstrument) = 2.5
                         case default
                            call stop_mpi(NameSub//': unknown INS: '//    &
                                 StringInstrument_I(iInstrument))
                         end select
                      case default
                         call stop_mpi(NameSub//': unknown satellite: '// &
                              StringInstrument_I(iInstrument))
                      end select

                      ! setting plot file format
                      if(index(plot_string,'idl') > 0)then
                         plot_form(iFileInstrument)='idl'

                         TypeFile_I(iFileInstrument) = 'real4'
                         if(index(plot_string,'idl_real8') > 0)      &
                              TypeFile_I(iFileInstrument) = 'real8'
                         if(index(plot_string,'idl_ascii') > 0)      &
                              TypeFile_I(iFileInstrument) = 'ascii'
                         if(index(plot_string,'idl_tec') > 0)        &
                              TypeFile_I(iFileInstrument) = 'tec'
                      elseif(index(plot_string,'tec')>0) then
                         plot_form(iFileInstrument)  = 'tec'
                         TypeFile_I(iFileInstrument) = 'tec'
                      else
                         call stop_mpi(NameSub//' for ins/INS type, only '// &
                              'idl or tec is supported.'//plot_string)
                      end if
                   end do

                   ! reset
                   StringInstrument_I = ''

                   ! adjust iFileStart
                   iFileStart = iFileStart + nInstrument - 1
                endif
             elseif (index(plot_string,'rfr')>0) then
                ! Refractive radiowave image
                plot_area='rfr'
                ! Observer position
                call read_var('ObsPosX', ObsPos_DI(1,iFile))
                call read_var('ObsPosY', ObsPos_DI(2,iFile))
                call read_var('ObsPosZ', ObsPos_DI(3,iFile))
                ! read number of radiowave frequencies, i.e. # of plots
                ! call read_var('nRadioFrequency', nRadioFrequency)
                call read_var('StringRadioFrequency', &
                     StringRadioFrequency_I(iFile))
                call read_var('xSizeImage', X_Size_Image(iFile))
                call read_var('ySizeImage', Y_Size_Image(iFile))
                ! read the number of pixels
                call read_var('nPixX', n_Pix_X(iFile))
                call read_var('nPixY', n_Pix_Y(iFile))
             elseif(index(plot_string,'buf')>0)then
                plot_area='buf'
             elseif(index(plot_string,'1d')>0)then
                plot_area='1d_'
             elseif(index(plot_string,'2d')>0)then
                plot_area='2d_'
             elseif(index(plot_string,'3d')>0)then
                plot_area='3d_'
             elseif(index(plot_string,'x=0') > 0)then
                plot_area = 'x=0'
             elseif(index(plot_string,'y=0') > 0)then
                plot_area = 'y=0'
             elseif(index(plot_string,'z=0') > 0)then
                plot_area = 'z=0'
             else
                call stop_mpi('Area (1d,2d,3d,x=0,y=0,z=0,cut,sph...) missing'&
                     //' from plot_string='//plot_string)
             end if

             ! Plot file format
             if(index(plot_string,'idl') > 0)then
                plot_form(iFile)='idl'
                if (       plot_area /= 'sph' &
                     .and. plot_area /= 'shl' &
                     .and. plot_area /= 'box' &
                     .and. plot_area /= 'los' &
                     .and. plot_area /= 'rfr' &
                     .and. plot_area /= 'lin' &
                     .and. plot_area /= 'eqr' &
                     .and. plot_area /= 'eqb' &
                     .and. plot_area /= 'buf' &
                     ) call read_var('DxSavePlot',plot_dx(1,iFile))

                ! Extract the type of idl plot file: default is real4
                TypeFile_I(iFile) = 'real4'
                if(index(plot_string,'idl_real8') > 0) &
                     TypeFile_I(iFile) = 'real8'
                if(index(plot_string,'idl_ascii') > 0) &
                     TypeFile_I(iFile) = 'ascii'
                if(index(plot_string,'idl_tec') > 0) &
                     TypeFile_I(iFile) = 'tec'
             elseif(index(plot_string, 'hdf') > 0) then
                ! With these values VisIt recognises the files as timesteps
                ! with the general defaults it does not.
                IsPlotName_n = .true.
                IsPlotName_t = .false.
                IsPlotName_e = .false.
                plot_form(iFile)='hdf'
                TypeFile_I(iFile) = 'hdf5'
             elseif(index(plot_string,'tec')>0)then
                plot_form(iFile)  = 'tec'
                TypeFile_I(iFile) = 'tec'
             elseif(index(plot_string,'tcp')>0)then
                if(nDim == 1)then
                   plot_form(iFile)  = 'idl'
                   TypeFile_I(iFile) = 'tec'
                   plot_dx(1,iFile)  = -1.0
                else
                   plot_form(iFile)  = 'tcp'
                   TypeFile_I(iFile) = 'tcp'
                end if
             else
                call stop_mpi('Format (idl,tec) missing from plot_string='&
                     //plot_string)
             end if

             ! Plot variables
             if(index(plot_string,'VAR')>0 .or. index(plot_string,'var')>0 )then
                plot_var='var'
                plot_dimensional(iFile) = index(plot_string,'VAR')>0
                call read_var('NameVars', NamePlotVar)
                call read_var('NamePars', plot_pars(iFile))
                l1 = index(NamePlotVar, '{')
                if (l1 > 0) then
                   l2 = index(NamePlotVar, '}')
                   if (l2 == 0) call stop_mpi(NameSub// &
                        ': error in #SAVEPLOT, missing } in NamePlotVar='//&
                        NamePlotVar)

                   select case(NamePlotVar(l1+1:l2-1))
                   case('MHD', 'mhd')
                      NamePlotVar = NamePlotVar(:l1-1)//NamePrimitiveVarPlot//&
                           ' jx jy jz ' //trim(NamePlotVar(l2+1:))
                   case('HD', 'hd')
                      NamePlotVar = NamePlotVar(:l1-1)//NamePrimitiveVarPlot//&
                           trim(NamePlotVar(l2+1:))
                   case default
                      call stop_mpi(NameSub// &
                           ': unknown {name} ='//NamePlotVar(l1:l2))
                   end select
                   if(len_trim(NamePlotVar) > len(plot_vars1)) &
                        call stop_mpi(NameSub// &
                        ': too long expanded variable list='//NamePlotVar)
                end if
                plot_vars(iFile) = NamePlotVar

             elseif(index(plot_string,'RAY')>0 &
                  .or.index(plot_string,'ray')>0)then
                plot_var = 'ray'
                plot_dimensional(iFile) = index(plot_string,'RAY')>0
                if(DoMapEquatorRay)then
                   plot_vars(iFile) = &
                        'bx by bz req1 phi1 req2 phi2 status blk'
                else
                   plot_vars(iFile) = &
                        'bx by bz theta1 phi1 theta2 phi2 status blk'
                end if
                plot_pars(iFile)='rbody'
             elseif(index(plot_string,'RAW')>0 .or. &
                  index(plot_string,'raw')>0)then
                plot_var='raw'
                plot_dimensional(iFile)=index(plot_string,'RAW')>0
                plot_vars(iFile) = NameConservativeVarPlot//  &
                     ' p b1x b1y b1z absdivB'
                plot_pars(iFile) = '{default}'
             elseif(index(plot_string,'MHD')>0.or.index(plot_string,'mhd')>0)then
                plot_var='mhd'
                plot_dimensional(iFile) = index(plot_string,'MHD')>0
                plot_vars(iFile) = NamePrimitiveVarPlot//' jx jy jz'
                plot_pars(iFile) = '{default}'
             elseif(index(plot_string,'HD')>0.or.index(plot_string,'hd')>0)then
                plot_var='hd'
                plot_dimensional(iFile) = index(plot_string,'HD')>0
                plot_vars(iFile) = NamePrimitiveVarPlot
                plot_pars(iFile) = '{default}'
             elseif(index(plot_string,'ALL')>0.or.index(plot_string,'all')>0)then
                ! This is intended for restart with a different dimensionality
                plot_var='all'
                plot_dimensional(iFile) = index(plot_string,'ALL')>0
                call join_string(nVar, NameVar_V(1:nVar), plot_vars(iFile))
                plot_pars(iFile)='g'
             elseif(index(plot_string,'FUL')>0.or.index(plot_string,'ful')>0)then
                plot_var='ful'
                plot_dimensional(iFile) = index(plot_string,'FUL')>0
                plot_vars(iFile) = NamePrimitiveVarPlot//' b1x b1y b1z e jx jy jz'
                plot_pars(iFile) = '{default}'
             elseif(index(plot_string,'FLX')>0.or.index(plot_string,'flx')>0)then
                plot_var='flx'
                plot_dimensional(iFile) = index(plot_string,'FLX')>0
                plot_vars(iFile) = 'rho mr br p jr pvecr'
                plot_pars(iFile) = '{default}'
             elseif(index(plot_string,'SOL')>0.or.index(plot_string,'sol')>0)then
                plot_var='sol'
                plot_dimensional(iFile) = index(plot_string,'SOL')>0
                plot_vars(iFile)='wl pb' ! white light
                plot_pars(iFile)='mu'
             elseif(index(plot_string,'EUV')>0.or.index(plot_string,'euv')>0)then
                plot_var='euv'
                plot_dimensional(iFile) = index(plot_string,'EUV')>0
                plot_vars(iFile)='euv171 euv195 euv284' ! main euv bands
                plot_pars(iFile)='mu'
             elseif(index(plot_string,'SXR')>0.or.index(plot_string,'sxr')>0)then
                plot_var='sxr'
                plot_dimensional(iFile) = index(plot_string,'SXR')>0
                plot_vars(iFile)='sxr' ! soft x-ray band
                plot_pars(iFile)='mu'
             elseif(index(plot_string,'TBL')>0.or.index(plot_string,'tbl')>0)then
                plot_var='tbl'
                plot_dimensional(iFile) = index(plot_string,'TBL')>0
                plot_vars(iFile)='tbl' ! will read a table in write_plot_los
                plot_pars(iFile)='mu'
             elseif(index(plot_string,'RWI')>0.or.index(plot_string,'rwi')>0)then
                plot_var='rwi'
                plot_dimensional(iFile) = .false.
                plot_vars(iFile)='' ! Intensity
                plot_pars(iFile)=''
             elseif(index(plot_string,'pos')>0.or.index(plot_string,'POS')>0)then
                plot_var='pos'
                plot_dimensional(iFile) = index(plot_string,'POS')>0
                if(plot_area /= 'lin')call stop_mpi(&
                     'Variable "pos" can only be used with area "lin" !')
             elseif(index(plot_string,'eqr')>0)then
                plot_var ='eqr'
                plot_dimensional(iFile) = .true.
             elseif(index(plot_string,'eqb')>0)then
                plot_var ='eqb'
                plot_dimensional(iFile) = .true.
             elseif(index(plot_string,'NUL')>0.or.index(plot_string,'nul')>0)then
                plot_var ='nul'
                plot_dimensional(iFile) = .true.
                plot_vars(iFile)=''
                plot_pars(iFile)=''
             elseif(index(plot_string,'INT')>0.or.index(plot_string,'int')>0)then
                plot_var ='int'
                plot_dimensional(iFile) = index(plot_string,'INT')>0
                plot_vars(iFile)=''
                plot_pars(iFile)=''
             elseif(index(plot_string,'BBK')>0.or.index(plot_string,'bbk')>0)then
                plot_var='blk'
                plot_dimensional(iFile) = index(plot_string,'BBK')>0
                plot_vars(iFile)='dx pe blk blkall'
             elseif(index(plot_string,'INS')>0.or.index(plot_string,'ins')>0)then
                ! do nothing
             else
                call stop_mpi('Variable definition missing from plot_string=' &
                     //plot_string)
             end if

             ! Set equation parameters for 3D unstructured IDL files
             ! to describe block structure and the dipole. Needed by CCMC.
             if(plot_area == '3d_' .and. plot_form(iFile) == 'idl' &
                  .and. plot_dx(1, iFile) < 0.0) &
                  plot_pars(iFile) = 'g c th p1 p2 p3 NX NY NZ R'

             if(nInstrument < 1) plot_type(iFile) = plot_area//'_'//plot_var
          end do

          ! write out the change if ins/INS is found
          if (nPlotFile > nPlotFileRead .and. iProc == 0) then
             write(*,*) ''
             write(*,*) '----------------------------------------'
             write(*,*) ' nPlotFile    =', nPlotFile
             write(*,*) ' use sta   =', any(TypeSatPos_I == 'sta')
             write(*,*) ' use stb   =', any(TypeSatPos_I == 'sta')
             write(*,*) ' use earth =', any(TypeSatPos_I == 'earth')
             do iFile = Plot_+ 1, Plot_+ nPlotFile
                write(*,*) '----------------------------------------'
                write(*,*) ' iFile        =', iFile
                write(*,*) ' dn_output    =', dn_output(iFile)
                write(*,*) ' dt_output    =', dt_output(iFile)
                write(*,*) ' plot_type    =', plot_type(iFile)
                write(*,*) ' plot_form    =', plot_form(iFile)
                write(*,*) ' TypeFile     =', TypeFile_I(iFile)
                write(*,*) ' dimensional  =', plot_dimensional(iFile)
                write(*,*) ' plot_vars    =', trim(plot_vars(iFile))
                write(*,*) ' plot_pars    =', trim(plot_pars(iFile))
                if (index(plot_type(iFile), 'los') >0) then
                   write(*,*) ' offset_angle =', offset_angle(iFile)
                   write(*,*) ' r_size_image =', r_size_image(iFile)
                   write(*,*) ' xoffset      =', xoffset(iFile)
                   write(*,*) ' yoffset      =', yoffset(iFile)
                   write(*,*) ' radius_occult=', radius_occult(iFile)
                   write(*,*) ' mu_los       =', mu_los
                   write(*,*) ' n_pix_r      =', n_pix_r(iFile)
                   write(*,*) ' NameLosTable =', NameLosTable(iFile)
                end if
             end do
             write(*,*) '----------------------------------------'
          end if

       case("#NOREFRACTION")
          call read_var('UseNoRefraction', UseNoRefraction)

       case("#SAVEPLOTNAME")
          call read_var('IsPlotName_n',IsPlotName_n)
          call read_var('IsPlotName_t',IsPlotName_t)
          call read_var('IsPlotName_e',IsPlotName_e)

       case("#PLOTFILENAME")
          call read_var('NameMaxTimeUnit', NameMaxTimeUnit)

       case("#LOSPLOT")
          call read_var('UseLosSimple', UseLosSimple)

       case("#SAVELOGNAME")
          call read_var('IsLogName_n',IsLogName_n)
          call read_var('IsLogName_e',IsLogName_e)
          ! Set _n true if _e is false.
          if(.not.IsLogName_e) IsLogName_n=.true.

       case("#SAVEPLOTSAMR")
          call read_var('DoSavePlotsAmr',save_plots_amr)

       case("#SAVEBINARY")
          call read_var('DoSaveBinary',save_binary)

       case("#SAVETECBINARY")
          call read_var('DoSaveTecBinary',DoSaveTecBinary)

       case("#GRIDRESOLUTION","#GRIDLEVEL","#REGION","#AMRREGION")
          call read_region_param(NameCommand, UseStrictIn=UseStrict)

       case("#AMR", "#DOAMR", &
            "#AMRLEVELS", "#AMRRESOLUTION", "#AMRLIMIT", "#AMRTYPE", &
            "#AMRCRITERIA", "#AMRCRITERIALEVEL","#AMRCRITERIARESOLUTION", &
            "#AMRCRITERIACELLSIZE", "#AMRPROFILE")
          call read_amr_param(NameCommand, iSession)

       case("#AMRINITPHYSICS")
          if(.not.is_first_session()) CYCLE READPARAM
          call read_amr_param(NameCommand, iSession)

       case('#CONSERVEFLUX')
          call read_var('DoConserveFlux', DoConserveFlux)

       case("#SCHEME")
          if(.not. IsFirstSession) nOrderOld = nOrder
          call read_var('nOrder', nOrder)
          ! Set default value for nStage. Can be overwritten if desired.
          nStage = nOrder
          ! Use RK3 for MP5 scheme
          if(nOrder > 4) nStage = 3
          UseHalfStep = nStage <= 2

          call read_var('TypeFlux',FluxType, IsUpperCase=.true.)
          ! For 5-moment equation all schemes are equivalent with Rusanov
          if(UseEfield) FluxType = 'RUSANOV'

          BetaLimiter = 1.0
          if(nOrder > 1 .and. FluxType /= "SIMPLE")then
             call read_var('TypeLimiter', TypeLimiter)
             if(TypeLimiter /= 'minmod') &
                  call read_var('LimiterBeta', BetaLimiter)
          else
             TypeLimiter = "no"
          end if

          if(nOrder == 5) then
             ! Some of the settings below can be overwritten by #SCHEME5
             UseFDFaceFlux    = .true.
             DoCorrectFace    = .true.
             UseCweno         = .false.
             ! HighResChange does not work for 1D, but works for 2D and 3D
             UseHighResChange = nDIm > 1
             UseHighOrderAMR  = .true.

             UseTvdReschange = .false.
             UseAccurateResChange = .false.
             DoConserveFlux = .false.
          endif

       case("#SCHEME4")
          if(.not.is_first_session())CYCLE READPARAM
          call read_var('UseVolumeIntegral4', UseVolumeIntegral4)
          call read_var('UseFaceIntegral4',   UseFaceIntegral4)
          call read_var('UseLimiter4',        UseLimiter4)
          ! There is no face integral in 1D
          if(nDim == 1) UseFaceIntegral4 = .false.

       case("#SCHEME5")
          ! If UseFDFaceFlux is true, use ECHO scheme, which is based on
          ! L. Del Zanna, O. Zanotti, N. Bucciantini, P. Londrillo,&
          ! Astronomy and Astrophysics, 473 (2007), pp.11-30.
          call read_var('UseFDFaceFlux', UseFDFaceFlux)
          call read_Var('TypeLimiter5', TypeLimiter5, IsLowerCase=.true.)
          call read_var('UseHighResChange', UseHighResChange)
          call read_var('UseHighOrderAMR',UseHighOrderAMR)
          if(UseFDFaceFlux) call read_var('DoCorrectFace',DoCorrectFace)
          if(.not.UseFDFaceFlux) DoCorrectFace = .false.

          ! If it is not 'cweno', mp5 scheme will be used.
          UseCweno = TypeLimiter5 == 'cweno'

          ! The following lines are related to cweno scheme, and it needs
          ! more tests.
          ! if(UseCweno) call read_var('UsePerVarLimiter', UsePerVarLimiter)
          ! if(UseCweno .and. .not. DoInterpolateFlux) then
          !    ! Density and velocity use density as smooth indicator.
          !    ! Other variables use themselves.
          !    iVarSmooth_V(1:Uz_) = Rho_
          !    do iVar = Uz_+1, nVar
          !       iVarSmooth_V(iVar) = iVar
          !    enddo
          !    call sort_smooth_indicator
          ! endif

          if(UseFDFaceFlux) DoConserveFlux   = .false.

          if(.not.UseHighResChange) then
             nOrderProlong  = 2
          end if

       case('#BURGERSEQUATION')
          call read_var('DoBurgers', DoBurgers)

       case('#LIMITER', '#RESCHANGE', '#RESOLUTIONCHANGE', '#TVDRESCHANGE', &
            '#LIMITPTOTAL', '#FLATTENING', '#LOWORDERREGION', '#ADAPTIVELOWORDER')
          call read_face_value_param(NameCommand)

       case("#NONCONSERVATIVE")
          call read_var('UseNonConservative',UseNonConservative)

       case("#CONSERVATIVECRITERIA")
          call read_var('nConservCrit',nConservCrit)
          if(nConservCrit > 0) then
             if(allocated(TypeConservCrit_I)) deallocate(TypeConservCrit_I)
             allocate( TypeConservCrit_I(nConservCrit) )
             do i=1,nConservCrit
                call read_var('TypeConservCrit',TypeConservCrit_I(i),&
                     IsLowerCase=.true.)
                select case(TypeConservCrit_I(i))
                   ! Geometry based criteria:
                case('r','radius')
                   !    non-conservative scheme is used for r < rConserv
                   TypeConservCrit_I(i) = 'r'
                   call read_var('rConserv',rConserv)
                case('parabola','paraboloid')
                   !    non-conservative scheme is used for
                   !    x < xParabolaConserv - (y**2+z**2)/yParabolaConserv
                   TypeConservCrit_I(i) = 'parabola'
                   call read_var('xParabolaConserv',xParabolaConserv)
                   call read_var('yParabolaConserv',yParabolaConserv)
                   ! Physics based criteria
                case('p')
                   ! Balsara/Ryu switch 1
                   call read_var('pCoeffConserv',pCoeffConserv)
                case('gradp','jumpp')
                   ! Balsara/Ryu switch 2
                   call read_var('GradPCoeffConserv',GradPCoeffConserv)
                case default
                   if(UseStrict)then
                      call stop_mpi(NameSub//&
                           ' ERROR: unknown TypeConservCrit_I=' &
                           //TypeConservCrit_I(i))
                   else
                      if(iProc==0)write(*,'(a)') NameSub // &
                           ' WARNING: ignoring unknown TypeConservCrit_I=',&
                           trim(TypeConservCrit_I(i))//' !!!'
                   end if
                end select
                ! Check if the same criterion has been used before
                if(any(TypeConservCrit_I(1:i-1)==TypeConservCrit_I(i)))then
                   if(iProc==0)write(*,'(a)')NameSub // &
                        ' WARNING: multiple use of criterion ',&
                        trim(TypeConservCrit_I(i))
                end if
             end do
          end if

       case("#TIMESTEPCONTROL", "#CONTROLTIMESTEP", "#CHECKTIMESTEP", &
            "#CONTROLDECREASE", "#CONTROLINCREASE", &
            "#CONTROLFACTOR", "#CONTROLVAR", "#CONTROLINIT")
          call read_time_step_control_param(NameCommand)

       case("#UPDATECHECK")
          call read_var("UseUpdateCheck",UseUpdateCheck)
          if(UseUpdateCheck)then
             call read_var("RhoMinPercent", percent_max_rho(1))
             call read_var("RhoMaxPercent", percent_max_rho(2))
             call read_var("pMinPercent",   percent_max_p(1))
             call read_var("pMaxPercent",   percent_max_p(2))
          end if

       case("#PROLONGATION")
          call read_var('nOrderProlong', nOrderProlong)
          UseTvdResChange = .false.
          UseAccurateResChange = .false.

       case("#MESSAGEPASS","#OPTIMIZE")
          call read_var('TypeMessagePass', optimize_message_pass)

       case('#CLIMIT', '#CLIGHTWARNING')
          call face_flux_set_parameters(NameCommand)

       case('#LIGHTSPEED')
          call read_var('ClightDim', ClightDim)

       case('#BORIS', '#BORISSIMPLE', '#BORISREGION')
          if(UseB) call read_boris_param(NameCommand)

       case("#DIVB")
          if(.not.UseB)CYCLE READPARAM
          call read_var('UseDivbSource'   ,UseDivbSource)
          call read_var('UseDivbDiffusion',UseDivbDiffusion)
          call read_var('UseProjection'   ,UseProjection)
          call read_var('UseConstrainB'   ,UseConstrainB)

          if (UseProjection.and.UseConstrainB.and.iProc==0) &
               call stop_mpi('Do not use projection and constrain B together!')
          if (UseProjection.and.UseDivbSource.and.iProc==0) then
             write(*,'(a)')NameSub // &
                  ' WARNING: using divbsource and projection together !!!'
             if (UseStrict) call stop_mpi('Correct PARAM.in')
          end if
          if (UseConstrainB.and.UseDivbSource.and.iProc==0) then
             write(*,'(a)')NameSub // &
                  ' WARNING: using divbsource and constrain B together !!!'
             if (UseStrict) call stop_mpi('Correct PARAM.in')
          end if

          if (iProc==0 .and. nDim > 1 &
               .and..not.UseHyperbolicDivb &
               .and..not.UseDivbSource &
               .and..not.UseProjection &
               .and..not.UseConstrainB &
               .and..not.UseDivbDiffusion) then
             write(*,'(a)') NameSub // &
                  ' WARNING: you should use some div B control method !!!'
             if (UseStrict) call stop_mpi('Correct PARAM.in!')
          end if
          ! Make sure that divbmax will be calculated
          DivbMax = -1.0
          ! reinitialize constrained transport if needed
          DoInitConstrainB = .true.

       case("#USEB0", "#DIVBSOURCE", "#USECURLB0", "#MONOPOLEB0")
          if(.not.is_first_session())CYCLE READPARAM
          call read_b0_param(NameCommand)

       case("#HYPERBOLICDIVE", "#CORRECTELECTRONFLUID", "#CORRECTEFIELD", &
            "#CMAXDIFFUSION")
          call read_ion_electron_param(NameCommand)

       case("#HYPERBOLICDIVB")
          if(.not.UseB)CYCLE READPARAM
          if(Hyp_ == 1)then
             if(iProc==0)then
                write(*,*) NameSub // 'WARNING: ',&
                     'there is no hyperbolic scalar in the equation module!'
                if (UseStrict) &
                     call stop_mpi('Correct PARAM.in or change equation!')
             end if
          else
             call read_var('UseHyperbolicDivB',UseHyperbolicDivB)
             if(UseHyperbolicDivB) then
                call read_var('SpeedHypDim',SpeedHypDim)
                call read_var('HypDecay'   ,HypDecay)
             end if
          endif

       case("#PROJECTION")
          if(.not.UseB)CYCLE READPARAM
          call read_project_divb_param(NameCommand)

       case("#CORRECTP")
          call read_var('pRatioLow',Pratio_lo)
          call read_var('pRatioHigh',Pratio_hi)
          if(Pratio_lo>=Pratio_hi)&
               call stop_mpi(NameSub//' ERROR: Pratio_lo>=Pratio_hi')

       case("#IOUNITS")
          if(.not.is_first_session())CYCLE READPARAM
          call read_var('TypeIoUnit',TypeIoUnit,IsUpperCase=.true.)

       case("#NORMALIZATION")
          if(.not.is_first_session())CYCLE READPARAM
          call read_var('TypeNormalization',TypeNormalization,IsUpperCase=.true.)
          select case(TypeNormalization)
          case('NONE')
             No2Si_V = 1.0
          case('READ')
             call read_var('No2SiUnitX',   No2Si_V(UnitX_))
             call read_var('No2SiUnitU',   No2Si_V(UnitU_))
             call read_var('No2SiUnitRho', No2Si_V(UnitRho_))
          case('PLANETARY', 'SOLARWIND', 'OUTERHELIO')
             ! Depends on other commands, defined in set_physics
          case('USER')
             ! Call user_normalization later in set_units (see set_physics.f90)
             ! to set the normalization units
          case default
             call stop_mpi(NameSub//' ERROR: unknown TypeNormalization=' &
                  //TypeNormalization)
          end select

       case("#UNIFORMSTATE")
          UseShockTube = .true.
          do i=1,nVar
             call read_var(NamePrimitive_V(i), ShockLeftState_V(i))
          end do
          ShockRightState_V = ShockLeftState_V

       case("#SHOCKTUBE")
          UseShockTube = .true.
          do i=1,nVar
             call read_var(NamePrimitive_V(i)//' left', ShockLeftState_V(i))
          end do
          do i=1,nVar
             call read_var(NamePrimitive_V(i)//' right', ShockRightState_V(i))
          end do

       case("#SHOCKPOSITION")
          call read_var('ShockPosition',ShockPosition)
          call read_var('ShockSlope',ShockSlope)

       case("#SOLARWINDFILE", "#UPSTREAM_INPUT_FILE", "#REFRESHSOLARWINDFILE")
          call read_solar_wind_param(NameCommand)
          DoReadSolarwindFile = UseSolarwindFile

       case("#MINIMUMSOLARWINDTEMP")
          call read_var('SwTminDim', SwTminDim)

       case("#TRACE", "#TRACELIMIT", "#TRACERADIUS", "#TRACEEQUATOR", &
            "#TRACEIE", &
            "#RAYTRACE", "#RAYTRACELIMIT", "#RAYTRACEEQUATOR", "#IE")
          call read_field_trace_param(NameCommand)
       case("#IECOUPLING")
          call read_ie_velocity_param
       case("#IMCOUPLING","#IM")
          call read_var('TauCoupleIm',TauCoupleIm)
          if(TauCoupleIm < 1.0)then
             TauCoupleIM = 1.0/TauCoupleIM
             if(iProc==0)then
                write(*,'(a)')NameSub//' WARNING: TauCoupleIm should be >= 1'
                if(UseStrict)call stop_mpi('Correct PARAM.in!')
                write(*,*)NameSub//' using the inverse:',TauCoupleIm
             end if
          end if
          call read_var('DoImSatTrace',DoImSatTrace)
          if(NameCommand == "#IMCOUPLING")then
             call read_var('DoCoupleImPressure', DoCoupleImPressure)
             call read_var('DoCoupleImDensity',  DoCoupleImDensity)
             if(DoCoupleImDensity) &
                  call read_var('DensityCoupleFloor', RhoMinDimIm)
             call read_var('DoFixPolarRegion',   DoFixPolarRegion)
             if(DoFixPolarRegion)then
                call read_var('rFixPolarRegion', rFixPolarRegion)
                do iFluid = IonFirst_, nFluid
                   call read_var('PolarNDim',  PolarNDim_I(iFluid))
                   call read_var('PolarTDim',  PolarTDim_I(iFluid))
                end do
             end if
          end if
       case("#IMCOUPLINGSMOOTH")
          call read_var('dLatSmoothIm', dLatSmoothIm)

       case("#MULTIFLUIDIM")
          if(.not.is_first_session())CYCLE READPARAM
          ! couple GM and IM in multi-fluid (all, Hp, Op) mode
          call read_var('DoMultiFluidIMCoupling', DoMultiFluidIMCoupling)

       case('#ANISOPRESSUREIM')
          if(.not.is_first_session())CYCLE READPARAM
          ! couple GM and IM in anisotropic pressure mode
          call read_Var('DoAnisoPressureIMCoupling', DoAnisoPressureIMCoupling)

       case('#PSCOUPLING')
          call read_var('TauCouplePs',TauCoupleIm)
          if(TauCoupleIm < 1.0)then
             TauCoupleIM = 1.0/TauCoupleIM
             if(iProc==0)then
                write(*,'(a)')NameSub//' WARNING: TauCoupleIm should be >= 1'
                if(UseStrict) call stop_mpi('Correct PARAM.in!')
                write(*,*)NameSub//' using the inverse:',TauCoupleIm
             end if
          end if
          call read_var('DoCouplePsPressure', DoCoupleImPressure)
          call read_var('DoCouplePsDensity',  DoCoupleImDensity)
          if(DoCoupleImDensity) &
               call read_var('DensityCoupleFloor', RhoMinDimIm)

       case("#RBSATCOUPLING")
          call read_var('DoRbSatTrace',DoRbSatTrace)
       case("#USERSWITCH", "#USERSWITCHES")
          call read_var('StringSwitch', StringSwitch, IsLowerCase=.true.)
          call split_string(StringSwitch, NameSwitch_I, nSwitch)
          do iSwitch = 1, nSwitch
             NameSwitch = NameSwitch_I(iSwitch)
             select case(NameSwitch(1:1))
             case('+')
                DoSwitchOn = .true.
             case('-')
                DoSwitchOn = .false.
             case default
                call stop_mpi(NameSub//': user switch ='//trim(NameSwitch)// &
                     ' should start with + or -')
             end select
             select case(NameSwitch(2:len(NameSwitch)))
             case('all')
                UseUserInitSession = DoSwitchOn
                UseUserICs           = DoSwitchOn
                UseUserPerturbation  = DoSwitchOn
                UseUserB0            = DoSwitchOn
                UseUserSourceExpl    = DoSwitchOn
                UseUserSourceImpl    = DoSwitchOn
                UseUserUpdateStates  = DoSwitchOn
                UseUserWriteProgress = DoSwitchOn
             case('init', 'init_session')
                UseUserInitSession   = DoSwitchOn
             case('ic', 'ics', 'initial_condition')
                UseUserICs = DoSwitchOn
             case('perturb', 'perturbation', 'initial_perturbation')
                UseUserPerturbation = DoSwitchOn
             case('b0', 'get_b0', 'set_b0', 'user_b0')
                UseUserB0 = DoSwitchOn
             case('source', 'calc_source', 'sources', 'calc_sources')
                UseUserSourceExpl = DoSwitchOn
                UseUserSourceImpl = DoSwitchOn
             case('sexpl', 'source_expl', 'sources_expl', 'source_explicit')
                UseUserSourceExpl = DoSwitchOn
             case('simpl', 'source_impl', 'sources_impl', 'source_implicit')
                UseUserSourceImpl = DoSwitchOn
             case('update', 'update_state', 'update_states')
                UseUserUpdateStates = DoSwitchOn
             case('progress', 'write_progress')
                UseUserWriteProgress = DoSwitchOn
             case default
                call stop_mpi(NameSub// &
                     ': unknown user switch='//trim(NameSwitch))
             end select
          end do
          if(iProc==0) write(*,*) &
               'Switches: Init,IC,Perturb,B0,SExpl,SImpl,Update,Progress=', &
               UseUserInitSession, UseUserICs, UseUserPerturbation, UseUserB0,&
               UseUserSourceExpl, UseUserSourceImpl, UseUserUpdateStates, &
               UseUserWriteProgress

       case("#USERINPUTBEGIN")
          call user_read_inputs
          ! Make sure that MassIon_I is consistent with MassFluid_I
          MassIon_I = MassFluid_I(IonFirst_:IonLast_)

       case("#CODEVERSION")
          if(.not.is_first_session())CYCLE READPARAM
          call read_var('CodeVersion',CodeVersionRead)
          if(abs(CodeVersionRead-CodeVersion)>0.005.and.iProc==0)&
               write(*,'(a,f6.3,a,f6.3,a)')NameSub//&
               ' WARNING: CodeVersion in file=',CodeVersionRead,&
               ' but '//NameThisComp//' version is ',CodeVersion,' !!!'

       case("#CHANGEVARIABLES")
          call read_var('DoChangeRestartVariables',DoChangeRestartVariables)
          if (DoChangeRestartVariables) UseStrict = .false.

       case("#SPECIFYRESTARTVARMAPPING")
          ! If user sets restart variables mapping, DoChangeRestartVariables
          ! should be set to true.
          call read_var('DoSpecifyRestartVarMapping', &
               DoSpecifyRestartVarMapping)
          if (DoSpecifyRestartVarMapping) then
             DoChangeRestartVariables = .true.
             UseStrict = .false.
             if (allocated(NameVarRestartFrom_V))  &
                  deallocate(NameVarRestartFrom_V)
             if (allocated(NameVarRestartTo_V))    &
                  deallocate(NameVarRestartTo_V)
             allocate(NameVarRestartFrom_V(max(nVar,nVarEquationRead)))
             allocate(NameVarRestartTo_V(max(nVar,nVarEquationRead)))
             call read_var('NameVarsRestartFrom', NameVarsRestartFrom, &
                  IsLowerCase=.true.)
             call read_var('NameVarsRestartTo',   NameVarsRestartTo,   &
                  IsLowerCase=.true.)
             call split_string(NameVarsRestartFrom, NameVarRestartFrom_V, &
                  nVarRestartMappingFrom)
             call split_string(NameVarsRestartTo,   NameVarRestartTo_V,   &
                  nVarRestartMappingTo)
             nVarRestartMapping = nVarRestartMappingFrom
             if (nVarRestartMappingFrom /= nVarRestartMappingTo) then
                if (iProc == 0) write(*,*) NameSub,                     &
                     ' nVarRestartMappingFrom, nVarRestartMappingTo =', &
                     nVarRestartMappingFrom, nVarRestartMappingTo
                call stop_mpi(NameSub //  &
                     ' Error: inconsistent nVar in SPECIFYRESTARTVARMAPPING')
             end if
          end if

       case("#EQUATION")
          if(.not.is_first_session())CYCLE READPARAM
          call read_var('NameEquation',NameEquationRead)
          call read_var('nVar',        nVarEquationRead)
          if(NameEquationRead /= NameEquation .and. iProc==0 &
               .and. .not. DoChangeRestartVariables)then
             write(*,'(a)')'BATSRUS was compiled with equation '// &
                  NameEquation//' which is different from '// &
                  NameEquationRead
             call stop_mpi(NameSub//' ERROR: incompatible equation names')

          end if
          if(nVarEquationRead /= nVar .and. iProc==0 .and. &
               .not. DoChangeRestartVariables)then
             write(*,'(a,i2,a,i2)')&
                  'BATSRUS was compiled with nVar=',nVar, &
                  ' which is different from nVarEquationRead=',nVarEquationRead
             call stop_mpi(NameSub//' ERROR: Incompatible number of variables')
          end if

       case("#NEWRESTART","#RESTARTINDIR","#RESTARTINFILE",&
            "#PRECISION","#BLOCKLEVELSRELOADED")
          if(.not.is_first_session())CYCLE READPARAM
          call read_restart_parameters(NameCommand)

       case("#SAVERESTART", "#RESTARTOUTDIR","#RESTARTOUTFILE")
          call read_restart_parameters(NameCommand)

       case('#RESTARTBLOCKDATA')
          call read_restart_parameters(NameCommand)

       case("#RESTARTVARIABLES")
          ! This reads the names of the variables saved in the input
          ! restart file.
          call read_var('NameVarRestartRead', NameVarRestartRead, &
               IsLowerCase=.true.)
          IsReadNameVarRestart = .true.

       case("#RESTARTWITHFULLB")
          UseRestartWithFullB = .true.

       case("#PLOTDIR")
          call read_var("NamePlotDir",NamePlotDir)
          call fix_dir_name(NamePlotDir)

       case("#SATELLITE")
          if(.not.is_first_session())CYCLE READPARAM
          call read_satellite_parameters(NameCommand)
          DoReadSatelliteFiles = nSatellite > 0

       case('#STEADYSTATESATELLITE')
          call read_satellite_parameters(NameCommand)

       case('#MAGPERTURBINTEGRAL')
          call read_magperturb_param(NameCommand)

       case('#GEOMAGINDICES')
          call read_magperturb_param(NameCommand)
          nFile = max(nFile, indexfile_)

       case("#MAGNETOMETER")
          call read_magperturb_param(NameCommand)
          nFile = max(nFile, magfile_)

       case("#MAGNETOMETERGRID")
          call read_magperturb_param(NameCommand)
          nFile = max(nFile, maggridfile_)

       case("#GRIDGEOMETRY", "#GRIDGEOMETRYLIMIT")
          if(.not.is_first_session())CYCLE READPARAM
          call read_var('TypeGeometry', TypeGeometry, IsLowerCase=.true.)
          ! need to read in the general grid file
          if(TypeGeometry == 'spherical_genr') then
             call read_var('NameGridFile',NameGridFile)
             call read_gen_radial_grid(NameGridFile)
          end if
          if(TypeGeometry == 'roundcube') then
             call read_var('rRound0',rRound0)
             call read_var('rRound1',rRound1)
          end if
          if(NameCommand == '#GRIDGEOMETRYLIMIT')then
             do iDim = 1, nDim
                call read_var('CoordDimMin_D', CoordDimMin_D(iDim))
                call read_var('CoordDimMax_D', CoordDimMax_D(iDim))
             end do
             XyzMin_D = CoordDimMin_D
             XyzMax_D = CoordDimMax_D
             if(TypeGeometry(1:9) == 'spherical')then
                RadiusMin = XyzMin_D(1)
                RadiusMax = XyzMax_D(1)
                XyzMin_D(Dim2_) = XyzMin_D(Dim2_)*cDegToRad
                XyzMax_D(Dim2_) = XyzMax_D(Dim2_)*cDegToRad
                XyzMin_D(Dim3_) = XyzMin_D(Dim3_)*cDegToRad
                XyzMax_D(Dim3_) = XyzMax_D(Dim3_)*cDegToRad
             elseif(TypeGeometry(1:11) == 'cylindrical')then
                RadiusMin = XyzMin_D(1)
                RadiusMax = XyzMax_D(1)
                XyzMin_D(Dim2_) = XyzMin_D(Dim2_)*cDegToRad
                XyzMax_D(Dim2_) = XyzMax_D(Dim2_)*cDegToRad
             end if
          end if

       case("#GRIDSYMMETRY")
          nMirror_D = 1
          call read_var('IsMirrorX', IsMirrorX)
          if(IsMirrorX) nMirror_D(1) = 2
          call read_var('IsMirrorY', IsMirrorY)
          if(IsMirrorY) nMirror_D(2) = 2
          call read_var('IsMirrorZ', IsMirrorZ)
          if(IsMirrorZ) nMirror_D(3) = 2

       case("#LIMITRADIUS")
          if(.not.is_first_session())CYCLE READPARAM
          call read_var('rMin', RadiusMin)
          call read_var('rMax', RadiusMax)

       case("#UNIFORMAXIS")
          if(.not.is_first_session())CYCLE READPARAM
          call read_var('UseUniformAxis', UseUniformAxis)

       case("#FIXAXIS")
          call read_var('DoFixAxis',DoFixAxis)
          call read_var('rFixAxis',rFixAxis)
          call read_var('r2FixAxis',r2FixAxis)

       case('#COARSEAXIS')
          call read_coarse_axis_param

       case("#GRID")
          if(.not.is_first_session())CYCLE READPARAM
          call read_var('nRootBlockX', nRootRead_D(1))
          call read_var('nRootBlockY', nRootRead_D(2))
          call read_var('nRootBlockZ', nRootRead_D(3))

          call read_var('xMin',x1)
          call read_var('xMax',x2)
          call read_var('yMin',y1)
          call read_var('yMax',y2)
          call read_var('zMin',z1)
          call read_var('zMax',z2)

       case("#GRIDBLOCK", "#GRIDBLOCKALL")
          if(.not.is_first_session())CYCLE READPARAM
          call read_var('MaxBlock',     MaxBlock)
          if(NameCommand == "#GRIDBLOCKALL") &
               MaxBlock   = 1 + (MaxBlock-1)/nProc

       case("#CHECKGRIDSIZE")
          if(.not.is_first_session())CYCLE READPARAM
          call read_var('nI', nIJKRead_D(1))
          call read_var('nJ', nIJKRead_D(2))
          call read_var('nK', nIJKRead_D(3))
          if(any(nIJK_D/=nIJKRead_D).and.iProc==0)then
             write(*,*)'Code is compiled with nI,nJ,nK=',nIJK_D
             call stop_mpi('Change nI,nJ,nK with Config.pl -g and recompile!')
          end if
          call read_var('MinBlockAll', MinBlockAll)
          ! Set MaxBlock large enough. Add 1 extra block for possible load balancing
          MaxBlock = max(MaxBlock, 2 + (MinBlockAll-1)/nProc)

       case("#USERMODULE")
          if(.not.is_first_session())CYCLE READPARAM
          call read_var('NameUserModule',NameUserModuleRead)
          call read_var('VersionUserModule',VersionUserModuleRead)
          if(NameUserModuleRead /= NameUserModule .or. &
               abs(VersionUserModule-VersionUserModuleRead)>0.001 .and. &
               .not. DoChangeRestartVariables) then
             if(iProc==0)write(*,'(4a,f5.2)') NameSub, &
                  ' WARNING: code is compiled with user module ', &
                  NameUserModule,' version',VersionUserModule
             if(UseStrict)call stop_mpi('Select the correct user module!')
          end if

       case("#GAMMA")
          if(.not.is_first_session())CYCLE READPARAM
          do iFluid = IonFirst_, nFluid
             call read_var('Gamma_I',Gamma_I(iFluid))
          end do
          Gamma_I(1) = Gamma_I(IonFirst_)
          ! Derived values for fluids
          GammaMinus1_I    = Gamma_I - 1.0
          where(GammaMinus1_I /= 0.0)
             InvGammaMinus1_I = 1.0 / GammaMinus1_I
          elsewhere
             ! This should not be used (isothermal case)
             InvGammaMinus1_I = 1.5
          end where

          ! Isothermal case (for ions?)
          if(any(Gamma_I == 1.0))then
             UseNonConservative = .true.
             nConservCrit = 0
             if(allocated(TypeConservCrit_I)) deallocate(TypeConservCrit_I)
             if(iProc==0) write(*,*) NameSub, &
                  ': for gamma=1 UseNonConservative is set to TRUE'
          endif

          ! Scalar values for the first fluid for simpler code
          Gamma          = Gamma_I(1)
          GammaMinus1    = GammaMinus1_I(1)
          InvGammaMinus1 = InvGammaMinus1_I(1)

          if(UseElectronPressure)then
             call read_var('GammaElectron', GammaElectron)
             ! Derived values for electron
             InvGammaElectron       = 1.0/GammaElectron
             GammaElectronMinus1    = GammaElectron - 1.0
             InvGammaElectronMinus1 = 1.0 / GammaElectronMinus1
          else
             ! Default values for electrons are the same as first fluid
             ! so ideal MHD works as expected
             GammaElectron          = Gamma
             InvGammaElectron       = 1.0/GammaElectron
             GammaElectronMinus1    = GammaMinus1
             InvGammaElectronMinus1 = InvGammaMinus1
          end if

       case("#LOOKUPTABLE")
          call read_lookup_table_param

       case("#PLASMA")
          if(UseMultiSpecies) then
             do iSpecies = SpeciesFirst_, SpeciesLast_
                call read_var('MassSpecies', MassSpecies_V(iSpecies))
             enddo
             do iSpecies = SpeciesFirst_, SpeciesLast_
                call read_var('ChargeSpecies', ChargeSpecies_I(iSpecies))
             enddo
          else
             do iFluid = IonFirst_, nFluid
                call read_var('MassFluid', MassFluid_I(iFluid))
             end do
             MassIon_I = MassFluid_I(IonFirst_:IonLast_)
             do iFluid = 1, nIonFluid
                call read_var('ChargeIon', ChargeIon_I(iFluid))
             end do
          endif

          call read_var('ElectronTemperatureRatio', ElectronTemperatureRatio)
          ElectronPressureRatio = ElectronTemperatureRatio

          ! AverageIonCharge is only useful when there is only one ion
          if(nIonFluid==1 .and. .not. UseMultiSpecies)then
             AverageIonCharge = ChargeIon_I(1)
             ElectronPressureRatio = ElectronTemperatureRatio*AverageIonCharge
          end if

          PePerPtotal = ElectronPressureRatio/(1 + ElectronPressureRatio)

       case("#MULTISPECIES")
          call read_var('DoReplaceDensity', DoReplaceDensity)
          call read_var('SpeciesPercentCheck',SpeciesPercentCheck)

       case("#NEUTRALFLUID")
          call read_var('DoConserveNeutrals', DoConserveNeutrals)
          call read_var('TypeFluxNeutral',    TypeFluxNeutral)

       case("#MULTIION", "#MHDIONS", "#COLLISION", "#MULTIIONSTATE")
          call multi_ion_set_parameters(NameCommand)

       case('#USERBOUNDARY', '#EXTRABOUNDARY')
          if(.not.is_first_session())CYCLE READPARAM
          call read_var('UseExtraBoundary', UseExtraBoundary)
          if(UseExtraBoundary)then
             call read_var('TypeFaceBc_I(ExtraBc_)', TypeFaceBc_I(ExtraBc_))
          end if

       case('#SOLIDSTATE')
          call read_boundary_geometry_param(NameCommand)

       case('#FACEBOUNDARY')
          if(iProc==0) &
               call stop_mpi('#FACEBOUNDARY command is no longer used!')

       case("#SOLARWIND")
          ! if(.not.is_first_session())CYCLE READPARAM
          call read_var('SwNDim',  SW_n_dim)
          call read_var('SwTDim'  ,SW_T_dim)
          call read_var('SwUxDim' ,SW_Ux_dim)
          call read_var('SwUyDim' ,SW_Uy_dim)
          call read_var('SwUzDim' ,SW_Uz_dim)
          call read_var('SwBxDim' ,SW_Bx_dim)
          call read_var('SwByDim' ,SW_By_dim)
          call read_var('SwBzDim' ,SW_Bz_dim)

       case("#OUTFLOWPRESSURE")
          call read_var('UseOutflowPressure', UseOutflowPressure)
          if(UseOutflowPressure) call read_var('pOutflowSi', pOutflowSi)

       case("#MAGNETOSPHERE","#BODY")
          if(.not.is_first_session())CYCLE READPARAM
          call read_var('UseBody',body1)
          if(body1)then
             call read_var('rBody', rBody)
             if(NameThisComp=='GM')&
                  call read_var('rCurrents' ,Rcurrents)
             if(UseMultiSpecies)then
                do iSpecies = 1, nSpecies
                   call read_var('BodyNDim', BodyNSpeciesDim_I(iSpecies))
                end do
                call read_var('BodyTDim', BodyTDim_I(IonFirst_))
             else
                do iFluid = IonFirst_, nFluid
                   call read_var('BodyNDim', BodyNDim_I(iFluid))
                   call read_var('BodyTDim', BodyTDim_I(iFluid))
                end do
             end if
          end if

       case("#INNERBOUNDARY", "#INNERBCPE", &
            "#POLARBOUNDARY", "#CPCPBOUNDARY", &
            "#MAGNETICINNERBOUNDARY", "#OUTFLOWCRITERIA", "#YOUNGBOUNDARY")
          call read_face_boundary_param(NameCommand)

       case("#GRAVITY")
          if(.not.is_first_session())CYCLE READPARAM
          call read_var('UseGravity',UseGravity)
          if(UseGravity)then
             call read_var('iDirGravity',GravityDir)
             if(GravityDir /= 0) call read_var('GravitySi', GravitySi)
          end if

       case("#SECONDBODY")
          if(.not.is_first_session())CYCLE READPARAM
          call read_var('UseBody2',UseBody2)
          if(UseBody2)then
             call read_var('rBody2',rBody2)
             call read_var('xBody2',xBody2)
             call read_var('yBody2',yBody2)
             call read_var('zBody2',zBody2)
             call read_var('rCurrentsBody2',rCurrentsBody2)
             call read_var('RhoDimBody2',RhoDimBody2)
             call read_var('tDimBody2'  ,tDimBody2)
             call read_var('UseBody2Orbit', UseBody2Orbit)
             if(UseBody2Orbit)then
                call read_var('OrbitPeriod [days]', OrbitPeriod)
                ! Convert orbit period from days to seconds
                OrbitPeriod = OrbitPeriod*cSecondPerDay
             end if
          end if

       case("#BOUNDARYSTATE", "#BOUNDARYSTATE_NT")
          ! Read boundary states for multiple boundaries.
          call read_var('StringBoundary', StringBoundary, IsLowerCase=.true.)
          do iVar = 1, nVar
             if (NameCommand == '#BOUNDARYSTATE')  then
                call read_var(NamePrimitive_V(iVar), BoundaryStateDim_V(iVar))
                iBoundaryState = 1
             else
                call read_var(NamePrimitiveNT_V(iVar),BoundaryStateDim_V(iVar))
                iBoundaryState = 2
             end if
          end do

          call split_string(StringBoundary, NameBoundary_I, nNameBoundary)

          do iNameBoundary = 1, nNameBoundary
             select case(NameBoundary_I(iNameBoundary))

             case('solid','-3')
                iFaceBoundaryState_I(SolidBc_) = iBoundaryState
                FaceStateDim_VI(:,SolidBc_)    = BoundaryStateDim_V
             case('body2','-2')
                iFaceBoundaryState_I(body2_) = iBoundaryState
                FaceStateDim_VI(:,body2_)    = BoundaryStateDim_V
             case('body1','-1')
                iFaceBoundaryState_I(body1_) = iBoundaryState
                FaceStateDim_VI(:,body1_)    = BoundaryStateDim_V
             case('extra','0')
                iFaceBoundaryState_I(ExtraBc_) = iBoundaryState
                FaceStateDim_VI(:,ExtraBc_)    = BoundaryStateDim_V
             case('xminbox')
                iFaceBoundaryState_I(xMinBc_) = iBoundaryState
                FaceStateDim_VI(:,xMinBc_)    = BoundaryStateDim_V
             case('xmaxbox')
                iFaceBoundaryState_I(xMaxBc_) = iBoundaryState
                FaceStateDim_VI(:,xMaxBc_)    = BoundaryStateDim_V
             case('yminbox')
                iFaceBoundaryState_I(yMinBc_) = iBoundaryState
                FaceStateDim_VI(:,yMinBc_)    = BoundaryStateDim_V
             case('ymaxbox')
                iFaceBoundaryState_I(yMaxBc_) = iBoundaryState
                FaceStateDim_VI(:,yMaxBc_)    = BoundaryStateDim_V
             case('zminbox')
                iFaceBoundaryState_I(zMinBc_) = iBoundaryState
                FaceStateDim_VI(:,zMinBc_)    = BoundaryStateDim_V
             case('zmaxbox')
                iFaceBoundaryState_I(zMaxBc_) = iBoundaryState
                FaceStateDim_VI(:,zMaxBc_)    = BoundaryStateDim_V

             case('coord1min','1')
                iCellBoundaryState_I(Coord1MinBc_) = iBoundaryState
                CellStateDim_VI(:,Coord1MinBc_)    = BoundaryStateDim_V
             case('coord1max','2')
                iCellBoundaryState_I(Coord1MaxBc_) = iBoundaryState
                CellStateDim_VI(:,Coord1MaxBc_)    = BoundaryStateDim_V
             case('coord2min','3')
                iCellBoundaryState_I(Coord2MinBc_) = iBoundaryState
                CellStateDim_VI(:,Coord2MinBc_)    = BoundaryStateDim_V
             case('coord2max','4')
                iCellBoundaryState_I(Coord2MaxBc_) = iBoundaryState
                CellStateDim_VI(:,Coord2MaxBc_)    = BoundaryStateDim_V
             case('coord3min','5')
                iCellBoundaryState_I(Coord3MinBc_) = iBoundaryState
                CellStateDim_VI(:,Coord3MinBc_)    = BoundaryStateDim_V
             case('coord3max','6')
                iCellBoundaryState_I(Coord3MaxBc_) = iBoundaryState
                CellStateDim_VI(:,Coord3MaxBc_)    = BoundaryStateDim_V

             case default
                call stop_mpi(NameSub//' ERROR: incorrect boundary name='//&
                     NameBoundary_I(iNameBoundary))
             end select
          end do

       case("#DIPOLEBODY2")
          if(.not.is_first_session())CYCLE READPARAM
          call read_var('BdpDimBody2x',BdpDimBody2_D(1))
          call read_var('BdpDimBody2y',BdpDimBody2_D(2))
          call read_var('BdpDimBody2z',BdpDimBody2_D(3))

       case('#PLANET','#MOON','#COMET','#IDEALAXES','#ROTATIONAXIS',&
            '#MAGNETICAXIS','#MAGNETICCENTER','#ROTATION','#DIPOLE', &
            '#NONDIPOLE','#UPDATEB0', '#MULTIPOLEB0')

          call check_stand_alone
          if(.not.is_first_session())CYCLE READPARAM

          call read_planet_var(NameCommand)

       case("#ROTATEHGR")
          call check_stand_alone
          if(.not.is_first_session())CYCLE READPARAM
          call read_var('dLongitudeHgr', dLongitudeHgrDeg)
          dLongitudeHgr = dLongitudeHgrDeg * cDegToRad

       case("#ROTATEHGI")
          call check_stand_alone
          if(.not.is_first_session())CYCLE READPARAM
          call read_var('dLongitudeHgi', dLongitudeHgiDeg)
          dLongitudeHgi = dLongitudeHgiDeg * cDegToRad

       case("#COORDSYSTEM","#COORDINATESYSTEM")
          if(.not.is_first_session())CYCLE READPARAM
          call read_var('TypeCoordSystem',TypeCoordSystem,IsUpperCase=.true.)
          select case(NameThisComp)
          case('GM')
             if (TypeCoordSystem == 'GEO') UseRotatingFrame = .true.
             if(TypeCoordSystem /= 'GSM' .and. TypeCoordSystem /= 'GSE' &
                  .and. TypeCoordSystem /= 'GEO' ) &
                  call stop_mpi(NameSub// &
                  ' ERROR: cannot handle coordinate system '//TypeCoordSystem)
          case('IH','OH')
             select case(TypeCoordSystem)
             case('HGI')
                ! If rotating frame was on in the previous session then
                ! we need to transform from HGR/HGC to HGI system.
                ! Note: This only works if the twoo coordinate systems
                ! are aligned at the initial time (i.e. HGR = HGC).
                if(UseRotatingFrame) iSignRotationIC = +1
                UseRotatingFrame = .false.
             case('HGC','HGR')
                UseRotatingFrame = .true.
             case default
                call stop_mpi(NameSub// &
                     ' ERROR: cannot handle coordinate system '&
                     //TypeCoordSystem)
             end select
          case('SC')
             select case(TypeCoordSystem)
             case('HGR','HGC')
                UseRotatingFrame = .true.
                if(iProc==0)then
                   write(*,*)NameSub//' setting .UseRotatingFrame = T'
                end if
             case('HGI')
                if(iProc==0) write(*,*) NameSub,&
                     ' WARNING: inertial SC is less accurate'
                UseRotatingFrame = .false.
             case default
                call stop_mpi(NameSub// &
                     ' ERROR: cannot handle coordinate system '&
                     //TypeCoordSystem)
             end select
          case('EE')
             select case(TypeCoordSystem)
             case('HGR','HGC')
                UseRotatingFrame = .true.
             case('HGI','GSM')
                UseRotatingFrame = .false.
             case default
                call stop_mpi(NameSub// &
                     ' ERROR: cannot handle coordinate system '&
                     //TypeCoordSystem)
             end select
          end select

       case("#ROTATINGINITIALCONDITION")
          call read_var('iSignRotationIC', iSignRotationIC)

       case("#NSTEP")
          if(.not.is_first_session())CYCLE READPARAM
          call read_var('nStep',n_step)

       case("#NPREVIOUS")
          if(.not.is_first_session())CYCLE READPARAM
          call read_var('nPrev',n_prev)
          call read_var('DtPrev',dt_prev)

       case("#STARTTIME", "#SETREALTIME")
          if(.not.is_first_session())CYCLE READPARAM
          call read_var('iYear'  ,iStartTime_I(1))
          call read_var('iMonth' ,iStartTime_I(2))
          call read_var('iDay'   ,iStartTime_I(3))
          call read_var('iHour'  ,iStartTime_I(4))
          call read_var('iMinute',iStartTime_I(5))
          call read_var('iSecond',iStartTime_I(6))
          iStartTime_I(7) = 0
          if(IsStandAlone)then
             call time_int_to_real(iStartTime_I, StartTime)
          else
             ! Check if things work out or not
             call time_int_to_real(iStartTime_I, StartTimeCheck)
          end if

       case("#TIMEEND", "#ENDTIME")
          UseEndTime = .true.
          call read_var('iYear'  ,iEndTime_I(1))
          call read_var('iMonth' ,iEndTime_I(2))
          call read_var('iDay'   ,iEndTime_I(3))
          call read_var('iHour'  ,iEndTime_I(4))
          call read_var('iMinute',iEndTime_I(5))
          call read_var('iSecond',iEndTime_I(6))
          iEndTime_I(7) = 0
          call time_int_to_real(iEndTime_I, EndTime)

       case("#TIMESIMULATION")
          if(.not.is_first_session())CYCLE READPARAM
          if(IsStandAlone)then
             call read_var('tSimulation',time_simulation)
          else
             call read_var('tSimulation',tSimulationCheck)
          end if

       case("#HELIOUPDATEB0")
          if(.not.UseB0)CYCLE READPARAM
          call read_var('DtUpdateB0', DtUpdateB0)
          DoUpdateB0 = DtUpdateB0 > 0.0

       case("#HELIODIPOLE")
          if(.not.is_first_session())CYCLE READPARAM
          if(.not.UseB0)CYCLE READPARAM
          call read_var('HelioDipoleStrengthSi',DipoleStrengthSi)
          call read_var('HelioDipoleTilt'      ,ThetaTilt)
          ThetaTilt = ThetaTilt * cDegToRad

       case("#HELIOROTATION", "#INERTIAL")
          if(iProc==0)write(*,*) NameSub, ' WARNING: ',&
               ' #HELIOROTATION / #INERTIAL command is obsolete and ignored'

       case("#HELIOBUFFERGRID")
          if(.not.is_first_session())CYCLE READPARAM
          if(NameThisComp == 'SC') &
               call stop_mpi(NameSub//' ERROR:'// &
               ' #HELIOBUFFERGRID can be used in IH and OH components only')
          call read_var('rBuffMin',   BufferMin_D(BuffR_))
          call read_var('rBuffMax',   BufferMax_D(BuffR_))
          call read_var('nThetaBuff', nThetaBuff)
          call read_var('nPhiBuff',   nPhiBuff)

       case("#BUFFERGRID")
          if(.not.is_first_session())CYCLE READPARAM
          call read_var('nRBuff',      nRBuff)
          call read_var('nPhiBuff',    nPhiBuff)
          call read_var('nThetaBuff',  nThetaBuff)
          call read_var('rBuffMin',    BufferMin_D(BuffR_))
          call read_var('rBuffMax',    BufferMax_D(BuffR_))
          call read_var('PhiBuffMin',  BufferMin_D(BuffPhi_))
          call read_var('PhiBuffMax',  BufferMax_D(BuffPhi_))
          call read_var('LatBuffMin',  BufferMin_D(BuffTheta_))
          call read_var('LatBuffMax',  BufferMax_D(BuffTheta_))

          ! Convert degrees to radians, latitude to co-latitude
          BufferMin_D(BuffPhi_)   = BufferMin_D(BuffPhi_) * cDegToRad
          BufferMax_D(BuffPhi_)   = BufferMax_D(BuffPhi_) * cDegToRad
          BufferMin_D(BuffTheta_) = cHalfPi - BufferMin_D(BuffTheta_)*cDegToRad
          BufferMax_D(BuffTheta_) = cHalfPi - BufferMax_D(BuffTheta_)*cDegToRad

       case("#THINCURRENTSHEET")
          call read_var('DoThinCurrentSheet', DoThinCurrentSheet)

          ! OUTERHELIOSPHERE SPECIFIC COMMANDS

       case("#OHNEUTRALS")
          call read_var('RhoNeutralsISW_dim' ,RhoNeutralsISW_dim)
          call read_var('TNeutralsISW_dim' ,TNeutralsISW_dim)
          call read_var('UxNeutralsISW_dim' ,UxNeutralsISW_dim)
          call read_var('UyNeutralsISW_dim' ,UyNeutralsISW_dim)
          call read_var('UzNeutralsISW_dim' ,UzNeutralsISW_dim)
          call read_var('mProtonMass',mProtonMass)

       case("#OHBOUNDARY")
          call read_var('DoOhNeutralBc',DoOhNeutralBc)
          if(DoOhNeutralBc)then
             do iFluid = IonLast_+1, nFluid
                call read_var('RhoBcFactor', RhoBcFactor_I(iFluid))
                call read_var('uBcFactor'  , uBcFactor_I(iFluid))
             end do
          end if

          ! CORONA SPECIFIC COMMANDS

       case("#HARMONICSFILE", "#NEWHARMONICSFILE", "#HARMONICSGRID", &
            "#FACTORB0", "#MAGNETOGRAM") ! last one kept for compatibility only
          call read_magnetogram_param(NameCommand)

       case('#LDEM')
          call read_var('UseLdem', UseLdem)
          if(UseLdem) then
             call read_var('NameLdemFile', NameLdemFile)
             call read_var('iRadiusLdem', iRadiusLdem)
             call read_ldem(NamePlotDir)
          end if

       case("#CORONALHEATING", "#LONGSCALEHEATING", "#ACTIVEREGIONHEATING", &
            "#LIMITIMBALANCE","#HEATPARTITIONING", "#POYNTINGFLUX", &
            "#HIGHBETASTOCHASTIC", "#ALIGNMENTANGLE")
          call read_coronal_heating_param(NameCommand)

       case("#RADIATIVECOOLING")
          call read_var('UseRadCooling', UseRadCooling)

       case("#CHROMOSPHERE")
          call read_chromosphere_param

       case("#TRANSITIONREGION")
          call read_cooling_param

       case("#FIELDLINETHREAD", '#PLOTTHREADS')
          call read_thread_param(NameCommand, iSession)

       case("#THREADEDBC")
          call read_threaded_bc_param

       case('#THREADRESTART')
          call read_var('DoThreadRestart', DoThreadRestart)

       case("#ADVECTWAVES", "#ALFVENWAVES", "#WAVEPRESSURE", &
            "#FREQUENCY", "#SPECTRUM", "#WAVEREFLECTION")
          call read_waves_param(NameCommand)

       case("#LASERPULSE", "#LASERBEAM", "#LASERBEAMS", "#LASERBEAMPROFILE", &
            "#LASERRAYTEST")
          call read_laser_heating_param(NameCommand)

       case("#CME", "#ARCH", "#TD99FLUXROPE", "#GL98FLUXROPE", "#SHEARFLOW", &
            "#CMS")
          call EEE_set_parameters(NameCommand)

       case("#STAR")
          UseStar=.true.
          call read_var('RadiusStar',         RadiusStar)
          call read_var('MassStar',           MassStar)
          call read_var('RotationPeriodStar', RotationPeriodStar)

       case default
          if(iProc==0) then
             write(*,*) NameSub // ' WARNING: unknown #COMMAND ' // &
                  trim(NameCommand),' !!!'
             if(UseStrict)call stop_mpi('Correct PARAM.in!')
          end if
       end select
    end do READPARAM

    ! end reading parameters

  contains
    !==========================================================================

    subroutine check_stand_alone

      !------------------------------------------------------------------------
      if(IsStandAlone) RETURN
      if(iProc==0) write(*,*) NameSub,' WARNING:'// &
           ' command '//trim(NameCommand)//&
           ' is allowed in stand alone mode only !!!'
      if(UseStrict)call stop_mpi(NameSub//' Correct PARAM.in')

    end subroutine check_stand_alone
    !==========================================================================

    logical function is_first_session()

      !------------------------------------------------------------------------
      is_first_session = IsFirstSession

      if(.not.IsFirstSession .and. iProc==0)then
         write(*,*)NameSub//' WARNING: command '//trim(NameCommand)// &
              ' can be used in the first session only !!!'
         if(UseStrict)call stop_mpi('Correct PARAM.in')
      end if

    end function is_first_session
    !==========================================================================

    subroutine set_namevar

      use ModMultiFluid, ONLY: extract_fluid_name
      use ModUtilities,  ONLY: join_string

      integer :: iWave, iMaterial, iFluid, lConservative, lPrimitive
      character(len=3)  :: NameWave
      character(len=2)  :: NameMaterial
      character(len=50) :: NamePrimitive, NamePrimitivePlot, NameConservative
      character(len=50) :: NamePrimitiveNT
      character(len=50) :: String, NameFluid
      character(len=500):: StringConservative, StringPrimitivePlot
      character(len=500):: StringPrimitiveOrig
      integer           :: iVar, iElement, iChargeState
      character(len=4)  :: NameChargestate
      !------------------------------------------------------------------------

      ! Fix the NameVar_V string for waves
      if(WaveLast_ > 1)then
         do iWave = 1, nWave
            write(NameWave,'(a,i2.2)') 'I',iWave
            NameVar_V(WaveFirst_+iWave-1) = NameWave
         end do
      end if

      ! Fix the NameVar_V string for material levels
      if(MaterialLast_ > 1)then
         do iMaterial = 1, nMaterial
            write(NameMaterial,'(a,i1.1)') 'M',iMaterial
            NameVar_V(MaterialFirst_+iMaterial-1) = NameMaterial
         end do
      end if

      ! Fix the NameVar_V string for charge states
      if(ChargeStateLast_ > 1)then
         iVar = ChargeStateFirst_
         do iElement = 1, nElement
            do iChargeState = 1, nChargeState_I(iElement)
               if(nChargeState_I(iElement) < 10) then
                  write(NameChargestate,'(a,i1.1)')&
                       trim(NameElement_I(iElement)),iChargeState
               else
                  write(NameChargestate,'(a,i2.2)')&
                       trim(NameElement_I(iElement)),iChargeState
               end if
               NameVar_V(iVar) = NameChargeState
               iVar = iVar + 1
            end do
         end do
      end if

      ! space separated NameVar string containing all variable names
      call join_string(nVar, NameVar_V, NameVarCouple)

      ! convert NameVar_V to NameVarLower_V (lower case)
      do iVar = 1, nVar+nFluid
         NameVarLower_V(iVar) = NameVar_V(iVar)
         call lower_case(NameVarLower_V(iVar))
      end do

      ! initialize the two strings to be empty strings
      StringConservative  = ''
      StringPrimitivePlot = ''

      ! Only loop through nVar (e is taken care by setting NameConservative)
      do iVar = 1, nVar
         ! extract_fluid_name only checks fluid names in lower case
         String  = NameVarLower_V(iVar)
         call extract_fluid_name(String,iFluid)

         ! no need to add the fluid name for the first fluid, this is needed
         ! for non fluid variables
         if (iFluid ==1) then
            NameFluid = ''
         else
            NameFluid = NameFluid_I(iFluid)
         end if

         ! capitalize the first letter (to make the name look better)
         String(1:1) = char(ichar(String(1:1)) + ichar('A')-ichar('a'))

         ! set the three strings to NameFluid+String by default, which might be
         ! overwritten later
         NameConservative  = trim(NameFluid)//trim(String)
         NamePrimitive     = trim(NameFluid)//trim(String)
         NamePrimitivePlot = trim(NameFluid)//trim(String)
         NamePrimitiveNT   = trim(NameFluid)//trim(String)

         select case(String)
         case('Rho')
            NamePrimitiveNT   = trim(NameFluid)//'NumDens'
         case('Mx')
            NamePrimitive     = trim(NameFluid)//'Ux'
            NamePrimitivePlot = trim(NameFluid)//'Ux'
            NamePrimitiveNT   = trim(NameFluid)//'Ux'
         case('My')
            NamePrimitive     = trim(NameFluid)//'Uy'
            NamePrimitivePlot = trim(NameFluid)//'Uy'
            NamePrimitiveNT   = trim(NameFluid)//'Uy'
         case('Mz')
            NamePrimitive     = trim(NameFluid)//'Uz'
            NamePrimitivePlot = trim(NameFluid)//'Uz'
            NamePrimitiveNT   = trim(NameFluid)//'Uz'
         case('Ppar')
            ! for anisotropic pressure, the primitive var is Ppar, while
            ! typically Pperp is added for plotting purpose
            NamePrimitivePlot = trim(NameFluid)//'Ppar '// &
                 trim(NameFluid)//'Pperp'
         case('P')
            NameConservative  = trim(NameFluid)//'E'
            NamePrimitiveNT   = trim(NameFluid)//'Temperature'
         case('Pe')
            NamePrimitiveNT   = 'Te'
         case('Hype')
            ! also tries to make HypE look better.
            NameConservative  = trim(NameFluid)//'HypE'
            NamePrimitive     = trim(NameFluid)//'HypE'
            NamePrimitivePlot = trim(NameFluid)//'HypE'
            NamePrimitiveNT   = trim(NameFluid)//'HypE'
         case('Pepar')
            ! for anisotropic Pe, the primitive var is PpPpar, while
            ! typically Peperp is added for plotting purpose
            NamePrimitivePlot = trim(NameFluid)//'Pepar '// &
                 trim(NameFluid)//'Peperp '
         end select

         ! NamePrimitive is the primitive variable names without any additional
         ! variable names (i.e. Pperp) for plotting purposes
         NamePrimitive_V(iVar)   = trim(NamePrimitive)
         NamePrimitiveNT_V(iVar) = trim(NamePrimitiveNT)

         ! overwrite the wave vars, trying to be consistent with previous
         ! equation files
         if (iVar >= WaveFirst_ .and. iVar <= WaveLast_ .and. WaveLast_ >1)then
            if (iVar == WaveFirst_) then
               NameConservative = 'Ew'
               write(NamePrimitivePlot,'(a,i2.2,a)') 'I(',nWave,')'
            else
               NameConservative  = ''
               NamePrimitivePlot = ''
            end if
         end if

         ! overwrite the material vars, trying to be consistent with previous
         ! equation files
         if (iVar >= MaterialFirst_ .and. iVar <= MaterialLast_ .and. &
              MaterialLast_ > 1) then
            if (iVar == MaterialFirst_) then
               NameConservative = ''
               write(NamePrimitivePlot,'(a,i1.1,a)') 'M(',nMaterial,')'
            else
               NameConservative  = ''
               NamePrimitivePlot = ''
            end if
         end if

         ! Overwrite the charge state vars, trying to be consistent with
         ! previous equation files
         do iElement = 1, nElement
            if (iVar >= ChargeStateFirst_+sum(nChargeState_I(1:iElement-1))&
                 .and. iVar <= ChargeStateFirst_ + &
                 sum(nChargeState_I(1:iElement))-1 .and. &
                 ChargeStateLast_ > 1) then
               if(iVar == ChargeStateFirst_+sum(nChargeState_I(1:iElement-1)))&
                    then
                  if(nChargeState_I(iElement) < 10) then
                     write(NamePrimitivePlot,'(a,i1.1,a)')&
                          trim(NameElement_I(iElement))//'(', &
                          nChargeState_I(iElement),')'
                  else
                     write(NamePrimitivePlot,'(a,i2.2,a)')&
                          trim(NameElement_I(iElement))//'(',&
                          nChargeState_I(iElement),')'
                  end if
                  NameConservative = NamePrimitivePlot
               else
                  NameConservative  = ''
                  NamePrimitivePlot = ''
               end if
            end if
         end do

         ! only add to string if it is not an empty string
         if (len_trim(NameConservative) >0) &
              StringConservative  = trim(StringConservative) //' '//  &
              trim(NameConservative)
         if (len_trim(NamePrimitivePlot) > 0)   &
              StringPrimitivePlot = trim(StringPrimitivePlot) //' '// &
              trim(NamePrimitivePlot)
      end do

      ! Combine the string array into a space separated list of nVar primitive
      ! variables
      call join_string(nVar, NamePrimitive_V, StringPrimitiveOrig)

      if(allocated(NameConservativeVarPlot))deallocate(NameConservativeVarPlot)
      if(allocated(NamePrimitiveVarPlot))   deallocate(NamePrimitiveVarPlot)
      if(allocated(NamePrimitiveVarOrig))   deallocate(NamePrimitiveVarOrig)

      ! The first character of StringConservative/StringPrimitivePlot is
      ! a space...
      lConservative = len_trim(StringConservative)-1
      lPrimitive    = len_trim(StringPrimitivePlot)-1

      allocate(character(lConservative) ::NameConservativeVarPlot)
      allocate(character(lPrimitive)    ::NamePrimitiveVarPlot)

      ! The first character of StringPrimitiveOrig is not a space
      allocate(character(len_trim(StringPrimitiveOrig)):: NamePrimitiveVarOrig)

      ! Remove leading/tailing spaces
      NameConservativeVarPlot = adjustl(trim(StringConservative))
      NamePrimitiveVarPlot    = adjustl(trim(StringPrimitivePlot))

      ! Remove tailing spaces
      NamePrimitiveVarOrig    = trim(StringPrimitiveOrig)

    end subroutine set_namevar
    !==========================================================================

    subroutine set_defaults

      use ModHeatFluxCollisionless, ONLY: UseHeatFluxCollisionless, &
           UseHeatFluxRegion
      use ModSemiImplVar, ONLY: UseSemiImplicit, TypeSemiImplicit
      use ModSemiImplicit, ONLY: SemiParam
      use ModResistivity, ONLY: UseResistivity, TypeResistivity, Eta0Si, &
           DoResistiveFlux, UseJouleHeating, UseHeatExchange

      ! Default plot and restart directories depend on NameThisComp
      !------------------------------------------------------------------------
      NamePlotDir(1:2) = NameThisComp

      ! Set defaults for restart files
      call init_mod_restart_file

      CodeVersionRead = -1.

      ! Default coordinate systems
      select case(NameThisComp)
      case('IH','OH')
         UseRotatingFrame  = .false.
         UseRotatingBc     = .false.
         TypeCoordSystem   = 'HGI'
      case('SC','EE')
         UseRotatingFrame  = .true.
         UseRotatingBc     = .false.
         TypeCoordSystem   = 'HGR'
      case('GM')
         UseRotatingFrame  = .false.
         UseRotatingBc     = .true.
         TypeCoordSystem   = 'GSM'
      end select

      ! Do not set B0 field in IH and OH
      if(NameThisComp/='IH'.and.NameThisComp/='OH')then
         UseB0=UseB
      else
         UseB0=.false.
      end if

      ! Do not update B0 except in GM
      if(NameThisComp /= 'GM')then
         DoUpdateB0 = .false.
         DtUpdateB0 = -1.0
      end if

      ! Initialize StartTime to the default values
      ! For SWMF it is set during 'CHECK'
      if(IsStandAlone)call time_int_to_real(iStartTime_I, StartTime)

      nStage        = 2
      Cfl           = 0.8
      CflOrig       = 0.8
      UseDtFixed    = .false.
      UseDtLimit    = .false.
      dt            = 0.0

      nOrder = 2
      FluxType = 'RUSANOV'

      ! Default implicit parameters
      UseImplicit      = .false.
      ImplCritType     = 'dt'

      UseDivbSource   =  UseB .and. nDim > 1
      UseDivbDiffusion= .false.
      UseProjection   = .false.
      UseConstrainB   = .false.

      UseB0Source     = UseB0 .and. nDim > 1

      optimize_message_pass = 'all'

      plot_dimensional      = .true.

      restart           = .false.

      ! Give some "reasonable" default values

      DipoleStrengthSi = 0.0

      UseBody2 = .false.
      RBody2 =-1.0
      xBody2 = 0.0
      yBody2 = 0.0
      zBody2 = 0.0
      BdpBody2_D  = 0.0
      rCurrentsBody2 = 0.0
      RhoDimBody2 = 1.0    ! n/cc
      TDimBody2   = 10000.0! K

      MassIon_I = MassFluid_I(IonFirst_:IonLast_) ! Ion masses

      call init_mod_amr

      ! Set component dependent defaults

      GravityDir=0
      if(allocated(TypeConservCrit_I)) deallocate(TypeConservCrit_I)

      select case(NameThisComp)
      case('SC','IH','OH','EE')
         ! Body parameters
         UseGravity = .true.
         body1      = .true.
         if(NameThisComp == 'EE') body1 = .false.
         Rbody      = 1.0
         Rcurrents  =-1.0

         ! Non Conservative Parameters
         UseNonConservative   = .false.
         nConservCrit         = 0
         rConserv             = -1.

         ! Boundary Conditions
         ! Default boundary type is 'none'.

         BodyTDim_I            = 2.85E06    ! K
         BodyNDim_I(IonFirst_) = 1.50E8     ! /cc  protons
         BodyNDim_I(IonFirst_+1:nFluid) = BodyNDim_I(IonFirst_)*cTiny

         ! Normalization and I/O units
         TypeNormalization     = "SOLARWIND"
         TypeIoUnit            = "HELIOSPHERIC"

         if(NameThisComp == "OH")then
            TypeNormalization = "OUTERHELIO"
            TypeIoUnit        = "OUTERHELIO"
         end if

         ! Some defaults for AWSoM and AWSoM-R
         ! If Ehot_>1, then we assume we use these models
         if(Ehot_ > 1)then
            UseHeatFluxCollisionless = .true.
            if(NameThisComp == 'SC')then
               UseHeatFluxRegion = .true.
               UseHeatConduction = .true.

               ! defaults for semi-implicit heat conduction
               UseSemiImplicit = .true.
               TypeSemiImplicit = "parcond"

               SemiParam%TypeKrylov = "GMRES"
               SemiParam%ErrorMax = 1.0e-5
               SemiParam%MaxMatvec = 20
               SemiParam%nKrylovVector = SemiParam%MaxMatvec
            end if
         end if

         ! Set anisotropic pressure instability defaults for first ion fluid
         if(NameThisComp == 'SC' .or. NameThisComp == 'IH')then
            if(UseAnisoPressure)then
               UseConstantTau_I(IonFirst_) = .false.
               TauInstabilitySi_I(IonFirst_) = -1.0
               TauGlobalSi_I(IonFirst_) = 1e5
            end if
         end if

         ! Set heat exchange for IH (it shouldn't do much)
         if(NameThisComp == 'IH')then
            if(UseElectronPressure .and. nIonFluid == 1)then
               UseResistivity = .true.
               TypeResistivity = 'user'
               Eta0Si = 0.0
               DoResistiveFlux = .false.
               UseJouleHeating = .false.
               UseHeatExchange = .true.
            end if
         end if

      case('GM')
         ! Body Parameters
         UseGravity = .false.
         body1      = .true.
         Rbody      = 3.0
         Rcurrents  = 4.0

         ! Non Conservative Parameters
         UseNonConservative   = .true.
         nConservCrit         = 1
         allocate( TypeConservCrit_I(nConservCrit) )
         TypeConservCrit_I(1) = 'r'
         rConserv             = 2*rBody

         ! Boundary Conditions and Normalization
         ! Default BC type is 'none'.

         BodyTDim_I    = 25000.0          ! K
         BodyNDim_I    = 5.0              ! /cc

         ! Normalization and I/O units
         TypeNormalization = "PLANETARY"
         TypeIoUnit        = "PLANETARY"

      end select

      TypeFaceBc_I(SolidBc_) = 'reflectall'

    end subroutine set_defaults
    !==========================================================================

    subroutine correct_parameters

      use ModMultiFluid, ONLY: UseMultiIon
      use ModWaves, ONLY: UseAlfvenWaves, UseWavePressure
      use ModRestartFile, ONLY: NameVarRestart_V
      use ModFieldLineThread, ONLY: DoPlotThreads

      ! option and module parameters
      character (len=40) :: Name
      real               :: Version
      logical            :: IsOn

      real    :: BetaProlongOrig = 0.0
      logical :: IsFirstCheck = .true.
      character(len(NameVarRestart_V)) :: NameVarTemp_V(100) = ''
      !------------------------------------------------------------------------
      ! Check for some combinations of things that cannot be accepted as input
      if (iProc==0) write (*,*) ' '

      if(IsFirstCheck)then
         call correct_grid_geometry

         if( (.not.IsCartesian .or. &
              i_line_command("#BOXBOUNDARY", iSessionIn=iSessionFirst) < 0 ) &
              .and. (UseVolumeIntegral4 .or. UseFaceIntegral4))then
            if(iProc==0)then
               if(.not. IsCartesian) write(*,'(a)')NameSub//&
                    ': UseVolumeIntegral4/UseFaceIntegral4 are implemented ', &
                    'for Cartesian grid only!'

               if(i_line_command("#BOXBOUNDARY", iSessionIn=iSessionFirst)<0) &
                    write(*,'(a)')NameSub//&
                    ': UseVolumeIntegral4/UseFaceIntegral4 are implemented ', &
                    'for cell based boundaries only!'

               if (UseStrict) call stop_mpi('Correct PARAM.in!')
               write(*,*)NameSub//' Setting Use*Integral4 = .false.'
            end if
            UseVolumeIntegral4 = .false.
            UseFaceIntegral4   = .false.
         end if

         if(UseConstrainB .or. UseFaceIntegral4) then
            ! Extend face index range in the orthogonal direction
            ! The CT scheme needs 1 extra layers
            ! the 4th order face integrals need 1 and 2 ghost layers
            iMinFace = 0; iMaxFace = nI+1
            jMinFace = 1 - min(1,nJ-1); jMaxFace = nJ + min(1,nJ-1)
            kMinFace = 1 - min(1,nK-1); kMaxFace = nK + min(1,nK-1)
            if(UseFaceIntegral4)then
               iMinFace2 = -1; iMaxFace2 = nI+2
               jMinFace2 = 1 - 2*min(1,nJ-1); jMaxFace2 = nJ + 2*min(1,nJ-1)
               kMinFace2 = 1 - 2*min(1,nK-1); kMaxFace2 = nK + 2*min(1,nK-1)
            else
               iMinFace2 = iMinFace; iMaxFace2 = iMaxFace
               jMinFace2 = jMinFace; jMaxFace2 = jMaxFace
               kMinFace2 = kMinFace; kMaxFace2 = kMaxFace
            end if
         end if
      else if(nOrderOld /=5 .and. nOrder==5 .and. UseFDFaceFlux) then
         ! calculate high-order geometry coefficients
         call set_high_geometry(UseFDFaceFluxIn=UseFDFaceFlux)
         call create_grid
         nOrderOld = 5
      endif ! IsFirstCheck

      ! Get the number of used ghost cell layers
      select case(nOrder)
      case(1, 2)
         nGUsed = nOrder
      case(4)
         ! 4th order interpolation formula needs 2 ghost cells
         nGUsed = 2
         ! Volume integral needs an extra ghost cell layer
         if(UseVolumeIntegral4) nGUsed = nGUsed + 1
         if(TypeLimiter /= 'no')then
            ! PPM limiter needs another 1 or 2 ghost cell layers
            nGUsed = nGUsed + 1
            if(UseLimiter4) nGUsed = nGUsed + 1
         end if
      case(5)
         ! MP5 scheme needs 3 ghost cell layers
         nGUsed = 3
      case default
         if(iProc==0)then
            write(*,*)'ERROR: nOrder=', nOrder
            call stop_mpi(NameSub//': Invalid value for nOrder')
         end if
      end select

      ! Check if there are enough ghost cells
      ! We could dynamically (re)allocate State_VGB etc. with nGUsed ?!
      if(nGUsed /= nG .and. iProc==0)then
         write(*,*)'The code is configured with nG=',nG,' ghost cell layers.'
         write(*,*)'The selected scheme requires nGUsed=',nGUsed,' layers!'
         if(nGUsed > nG)then
            write(*,*)'Either change settings or reconfigure and recompile!'
            call stop_mpi(NameSub//': insufficient number of ghost cells')
         end if
      end if

      ! This depends on the grid geometry set above
      if(i_line_command("#SAVEPLOT") > 0) call correct_plot_range

      if(UseTiming)then
         call timing_version(IsOn,Name,Version)
         if(.not.IsOn)then
            if(iProc==0)then
               write(*,'(a)')NameSub//' WARNING: TIMING module is OFF !!!'
               if(UseStrict)call stop_mpi( &
                    'Correct PARAM.in or switch TIMING ON')
               write(*,*)'setting UseTiming=.false.'
            end if
            UseTiming=.false.
         end if
      end if

      ! Check flux type selection
      select case(FluxType)
      case('SIMPLE','Simple')
         FluxType='Simple'
      case('ROE','Roe')
         FluxType='Roe'
      case('ROEOLD','RoeOld')
         FluxType='RoeOld'
      case('RUSANOV','TVDLF','Rusanov')
         FluxType='Rusanov'
      case('LINDE','HLLEL','Linde')
         FluxType='Linde'
      case('SOKOLOV','AW','Sokolov')
         FluxType='Sokolov'
      case('GODUNOV','Godunov')
         FluxType='Godunov'
      case('HLLD', 'HLLDW', 'LFDW', 'HLLC')
      case default
         if(iProc==0)then
            write(*,'(a)')NameSub // &
                 'WARNING: unknown value for FluxType=' // trim(FluxType)
            if(UseStrict) &
                 call stop_mpi('Correct PARAM.in!')
            write(*,*)'setting FluxType=Rusanov'
         end if
         FluxType='Rusanov'
      end select

      ! Set flux type for neutral fluids
      select case(TypeFluxNeutral)
      case('default')
         select case(FluxType)
         case('Rusanov','Linde','Sokolov','Godunov','HLLDW','LFDW','HLLC')
            TypeFluxNeutral = FluxType
         case default
            TypeFluxNeutral = 'Linde'
         end select
      case('RUSANOV','TVDLF','Rusanov')
         TypeFluxNeutral = 'Rusanov'
      case('LINDE','HLLE','Linde')
         TypeFluxNeutral = 'Linde'
      case('SOKOLOV','AW','Sokolov')
         TypeFluxNeutral = 'Sokolov'
      case('GODUNOV','Godunov')
         TypeFluxNeutral = 'Godunov'
      case('HLLDW', 'LFDW', 'HLLC')
      case default
         if(iProc==0)then
            write(*,'(a)')NameSub// &
                 ' WARNING: Unknown value for TypeFluxNeutral='// &
                 trim(TypeFluxNeutral)//' !!!'
            if(UseStrict)call stop_mpi('Correct PARAM.in!')
            write(*,*)NameSub//' setting TypeFluxNeutral=Linde'
         end if
         TypeFluxNeutral = 'Linde'
      end select

      ! Check flux type selection for implicit
      select case(FluxTypeImpl)
      case('default')
         FluxTypeImpl = FluxType
      case('ROE','Roe')
         FluxTypeImpl='Roe'
      case('ROEOLD','RoeOld')
         FluxTypeImpl='RoeOld'
      case('RUSANOV','TVDLF','Rusanov')
         FluxTypeImpl='Rusanov'
      case('LINDE','HLLEL','Linde')
         FluxTypeImpl='Linde'
      case('SOKOLOV','AW','Sokolov')
         FluxTypeImpl='Sokolov'
      case('GODUNOV','Godunov')
         FluxTypeImpl='Godunov'
      case('HLLD', 'HLLDW', 'LFDW', 'HLLC')
      case default
         if(iProc==0)then
            write(*,'(a)')NameSub// &
                 ' WARNING: Unknown value for FluxTypeImpl='// &
                 trim(FluxTypeImpl)//' !!!'
            if(UseStrict)call stop_mpi('Correct PARAM.in!')
            write(*,*)NameSub//' setting FluxTypeImpl=',trim(FluxType)
         end if
         FluxTypeImpl=FluxType
      end select

      ! Check flux types
      if( (FluxType(1:3)=='Roe' .or. FluxTypeImpl(1:3)=='Roe' .or. &
           FluxType=='HLLD' .or.  FluxTypeImpl=='HLLD') .and. &
           (UseMultiIon .or. UseAlfvenWaves .or. UseWavePressure &
           .or. .not.UseB) )then
         if (iProc == 0) then
            write(*,'(a)')NameSub//' WARNING: '// &
                 'HLLD/Roe(Old) flux only works for single fluid MHD !!!'
            if(UseStrict)call stop_mpi('Correct PARAM.in!')
            write(*,*)NameSub//' Setting TypeFlux(Impl) = Linde'
         end if
         if(FluxType(1:3)=='Roe' .or. FluxType=='HLLD') &
              FluxType     = 'Linde'
         if(FluxTypeImpl(1:3)=='Roe' .or. FluxTypeImpl=='HLLD') &
              FluxTypeImpl = 'Linde'
      end if

      if((FluxType=='Godunov' .or. FluxTypeImpl=='Godunov') &
           .and. UseB)then
         if (iProc == 0) then
            write(*,'(a)')NameSub//&
                 ' WARNING: Godunov flux is only implemented for HD !!!'
            if(UseStrict)call stop_mpi('Correct PARAM.in!')
            write(*,*)NameSub//' Setting TypeFlux(Impl) = Linde'
         end if
         if(FluxType=='Godunov')     FluxType     = 'Linde'
         if(FluxTypeImpl=='Godunov') FluxTypeImpl = 'Linde'
      end if

      if(i_line_command("#IMPLSTEP") < 0) &
           UseBdf2 = nStage > 1 .and. time_accurate

      ! Make sure periodic boundary conditions are symmetric
      do i=Coord1MinBc_,Coord3MinBc_,2
         if(any(TypeCellBc_I(i:i+1) == 'periodic')) &
              TypeCellBc_I(i:i+1) = 'periodic'
      end do

      ! Set UseBufferGrid logical
      UseBufferGrid = any(TypeFaceBc_I=='buffergrid')

      if(UseConstrainB .and. .not.time_accurate)then
         if(iProc==0)then
            write(*,'(a)')NameSub//&
                 ' WARNING: constrain_B works for time accurate run only !!!'
            if(UseStrict)call stop_mpi('Correct PARAM.in!')
            write(*,*)NameSub//' setting UseConstrainB=F UseDivbSource=T'
         end if
         UseConstrainB=.false.
         UseDivbSource=.true.
      end if
      if(UseConstrainB .and. (UseTvdReschange .or. UseAccurateResChange))then
         if(iProc==0)write(*,'(a)')NameSub//&
              ' WARNING: cannot use TVD or accurate schemes at res. change'// &
              ' with ConstrainB'
         ! if(UseStrict)call stop_mpi('Correct PARAM.in!')
         if(iProc==0)write(*,*)NameSub// &
              ' setting UseTvdReschange=F UseAccurateResChange=F'
         UseTvdReschange      = .false.
         UseAccurateResChange = .false.
      end if
      if (UseConstrainB) optimize_message_pass = 'all'
      if (UseConstrainB .and. DoAmr)then
         if(iProc==0)write(*,'(a)')NameSub//&
              ' WARNING: cannot use AMR with constrained transport'
         if(UseStrict)call stop_mpi('Correct PARAM.in!')
         if(iProc==0)write(*,*)NameSub//' setting DoAmr=F'
         DoAmr = .false.
      end if

      if (UseHallResist .or. UseResistivity .or. UseViscosity) &
           optimize_message_pass = 'all'

      if (UseRadDiffusion .and. (UseFullImplicit .or. UseSemiImplicit)) &
           optimize_message_pass = 'all'

      ! Check for magnetogram

      if(nOrder == 1)then
         BetaProlongOrig = BetaProlong
         BetaProlong = 0.0
      else
         BetaProlong = max(BetaProlong, BetaProlongOrig)
      end if

      if(nK == 1 .and. UseTvdResChange) then
         ! in 1D and 2D only accurate reschange is implemented
         UseTvdResChange      = .false.
         UseAccurateResChange = .true.
      end if

      ! Accurate res change algorithm and 4th order finite volume scheme
      ! both need corners and edges
      if (UseAccurateResChange .or. nOrder == 4) &
           optimize_message_pass = 'all'

      if(IsRzGeometry .and. UseB)then
         if(UseMultiIon) &
              call stop_mpi('RZ geometry is not implemented for multi-ion')
         if(UseHallResist) &
              call stop_mpi('RZ geometry is not implemented for Hall-MHD')
      end if

      if(.not.IsCartesian)then
         if(UseProjection)call stop_mpi(&
              'Only Cartesian works with projection')
         if(UseConstrainB)call stop_mpi(&
              'Only Cartesian works with constrain B')
         if(UseDivBDiffusion)call stop_mpi(&
              'Only Cartesian works with divB diffusion')
      end if

      if(UseHyperbolicDivb)then
         if(UseDivbDiffusion .or. UseConstrainB .or. UseProjection )then
            if(iProc==0)then
               write(*,'(a)')NameSub// &
                    ' WARNING: Hyperbolic cleaning can only be combined', &
                    ' with 8-wave scheme, not any other div B scheme'
               if (UseStrict) call stop_mpi('Correct PARAM.in!')
               write(*,*)NameSub//' Setting UseHyperbolicDivb = .false.'
            end if
            UseHyperbolicDivb = .false.
         end if
      end if

      ! Check CFL number
      if(.not.time_accurate .and. iProc==0)then
         if(UseBorisCorrection)then
            if(Cfl > 0.65) then
               write(*,'(a)')NameSub// &
                    ' WARNING: CFL number above 0.65 may be unstable'// &
                    ' for local timestepping with Boris correction !!!'
               if (UseStrict) call stop_mpi('Correct PARAM.in!')
            end if
         else
            if(Cfl > 0.85)then
               write(*,'(a)')NameSub// &
                    ' WARNING: CFL number above 0.85 may be unstable'// &
                    ' for local timestepping !!!'
               if (UseStrict) call stop_mpi('Correct PARAM.in!')
            end if
         end if
      end if

      ! Boris correction checks
      if((FluxType(1:3)=='Roe' .or. FluxTypeImpl(1:3)=='Roe') &
           .and. UseBorisCorrection)then
         if (iProc == 0) then
            write(*,'(a)')NameSub//&
                 ' WARNING: Boris correction not available for Roe flux !!!'
            if(UseStrict)call stop_mpi('Correct PARAM.in!')
            write(*,*)NameSub//' Setting UseBoris = .false.'
         end if
         UseBorisCorrection = .false.
         ClightFactor = 1.0
      end if

      if(UseBorisCorrection .and. UseHallResist .and. &
           TypeSemiImplicit /= 'resisthall' .and. &
           TypeSemiImplicit /= 'resistivity')then
         if(iProc==0)then
            write(*,'(a)') NameSub//' WARNING: '//&
                 'Boris correction only works with semi-implicit Hall MHD!!!'
            if (UseStrict) call stop_mpi('Correct PARAM.in!')
            write(*,*)NameSub//' Setting UseBoris = .false.'
         end if
         UseBorisCorrection = .false.
         ClightFactor = 1.0
      end if

      ! Check parameters for implicit
      if(UseImplicit .and. UseSemiImplicit .and. nStage > 1)then
         if(iProc==0)write(*,'(a)') NameSub//&
              ' WARNING: Full/part implicit + semi implicit schemes with'//&
              ' nStage=2 (BDF2) scheme is inconsistent if there is overlap!!!'
         if(UseStrict)then
            if(iProc == 0)write(*,*)NameSub//' setting nStage=1'
            nStage = 1
         endif
      end if

      if(UseClimit .and. .not. UseImplicit)then
         if(iProc==0)then
            write(*,'(a)')'UseClimit=T requires (part) implicit scheme'
            call stop_mpi('Correct PARAM.in')
         end if
      end if

      if(UsePartImplicit .and. ImplCritType=='dt' .and.&
           (.not.time_accurate .or. .not.UseDtFixed))then
         if(iProc==0)then
            write(*,'(a)')'Part implicit scheme with ImplCritType=dt'
            write(*,'(a)')'requires time accurate run with fixed time step'
            call stop_mpi('Correct PARAM.in')
         end if
      end if

      if(.not.time_accurate .and. UseDtFixed)then
         if(iProc==0)then
            write(*,'(a)')'Steady state Run can not use fixed time step'
            write(*,'(a)')'Use limited time step instead'
            call stop_mpi('Correct PARAM.in')
         end if
      end if

      if(UseDtLimit .and. UseDtFixed)then
         if(iProc==0)then
            write(*,'(a)') &
                 'Limited and fixed time steps cannot be used together'
            call stop_mpi('Correct PARAM.in')
         end if
      end if

      if(.not.time_accurate.and.UseBDF2)then
         if(iProc==0)then
            write(*,'(a)') NameSub//&
                 ' WARNING: BDF2 is only available for time accurate run !!!'
            if(UseStrict)call stop_mpi('Correct PARAM.in!')
            write(*,*)NameSub//' setting UseBDF2=.false.'
         end if
         UseBDF2=.false.
      end if

      if(UseImplicit .and. UsePartSteady)then
         if(iProc==0)then
            write(*,'(a)') NameSub//&
                 ' WARNING: Implicit and part steady schemes do not'//&
                 ' work together !!!'
            if(UseStrict)call stop_mpi('Correct PARAM.in!')
            write(*,*) NameSub//' setting UsePartSteady=F'
         endif
         UsePartSteady = .false.
      end if

      if(UsePointImplicit .and. UseFullImplicit)then
         if(iProc==0)then
            write(*,'(a)') NameSub//&
                 ' WARNING: Full and point implicit schemes do not'//&
                 ' work together !!!'
            if(UseStrict)call stop_mpi('Correct PARAM.in!')
            write(*,*) NameSub//' setting UsePointImplicit=F'
         endif
         UsePointImplicit = .false.
      end if

      ! Finish checks for implicit

      ! Set min_block_level and max_block_level for #AMRRESOLUTION in session 1
      if(i_line_command("#AMRRESOLUTION", iSessionIn=iSessionFirst) > 0) &
           call fix_amr_limits( &
           (XyzMax_D(x_)-XyzMin_D(x_))/real(nRootRead_D(1)*nI))

      if(TypeGeometry == 'cartesian')then
         if(DoFixAxis)then
            DoFixAxis = .false.
            if(iProc == 0) write(*,*) NameSub// &
                 ' setting DoFixAxis to FALSE'
         end if
      end if

      if(DoFixAxis .and. .not. UseUniformAxis) &
           call stop_mpi("DoFixAxis=T only works with UseUniformAxis=T!")

      if(UseLocalTimeStep)then
         if(DoFixAxis)then
            if(iProc == 0)then
               write(*,'(a)') NameSub//&
                    ' WARNING: Subcycling and fix axis are incompatible!'
               if(UseStrict)call stop_mpi('Correct PARAM.in!')
               write(*,*) NameSub//' setting DoFixAxis to false'
            end if
            DoFixAxis = .false.
         end if

         if(nStage > 2)then
            if(iProc == 0)then
               write(*,'(a)') NameSub//&
                    ' WARNING: Subcycling works with 1 and 2 stage schemes only!'
               if(UseStrict)call stop_mpi('Correct PARAM.in!')
               write(*,*) NameSub//' setting nStage=2'
            end if
            nStage = 2
         end if
      end if

      if(NameThisComp == 'SC' .and. TypeCoordSystem == 'HGI')then
         if(iProc == 0)then
            write(*,'(a)') NameSub//&
                 ' WARNING: SC only works with rotating frame!'
            if(UseStrict)call stop_mpi('Correct PARAM.in!')
            write(*,*) NameSub//' setting TypeCoordSystem = HGC'
         end if
         TypeCoordSystem  = 'HGC'
         iSignRotationIC = 0
         UseRotatingFrame = .true.
      end if

      if(TypeCoordSystem == 'HGI' .and. NameThisComp /= 'OH' &
           .and. .not.time_accurate)then
         if(iProc == 0)then
            write(*,'(a)') NameSub//&
                 ' WARNING: there is no steady state solution in HGI system!'
            if(UseStrict)call stop_mpi('Correct PARAM.in!')
            write(*,*) NameSub//' setting TypeCoordSystem = HGC'
         end if
         TypeCoordSystem  = 'HGC'
         iSignRotationIC = 0
         UseRotatingFrame = .true.
      end if

      ! Update check does not work with Runge-Kutta explicit schemes
      ! because the final update is a linear combination of all stages.
      if(.not.UseHalfStep .and. .not.UseImplicit) UseUpdateCheck = .false.

      ! Use first order prolongation for the first stage of high
      ! resolution change.
      if(UseHighResChange) nOrderProlong = 1

      ! If the state variables are changed when restarting, the names of the
      ! state variables saved in the restart file must be specified, so they
      ! can be properly copied into State_VGB.
      if(DoChangeRestartVariables .and. .not. IsReadNameVarRestart &
           .and. NameEquationRead /= NameEquation) then
         if(iProc == 0)then
            write(*,'(a)') NameSub//&
                 ' : Could not find  #RESTARTVARIABLES command, needed '// &
                 'when changing state variables at restart.'
         end if
         call stop_mpi('Correct PARAM.in')
      end if

      ! Check that the number of variables listed in #RESTARTVARIABLES
      ! matches the number appearing in the #EQUATION command
      ! (this check is useful if the #RESTARTVARIABLES command is added
      ! manually to older restart header files, but might become redundant
      ! in the future).
      if(IsReadNameVarRestart) then
         call split_string(NameVarRestartRead, NameVarTemp_V, nVarRestart)
         if (nVarRestart /= nVarEquationRead) then
            write(*,*)'Number of variables in #EQUATION command differs'//&
                 ' from the number of variables listed in #RESTARTVARIABLES.'
            call stop_mpi(NameSub//': Correct PARAM.in file!')
         else
            ! Save array of variable names
            if (allocated(NameVarRestart_V)) deallocate(NameVarRestart_V)
            allocate(NameVarRestart_V(nVarRestart))
            NameVarRestart_V = NameVarTemp_V(1:nVarRestart)
         end if
      end if

      UseHighOrderAMR = UseHighOrderAMR .and. DoAmr
      IsFirstCheck = .false.

      if (.not. allocated(iVarUseCmax_I) .and. UseEfield) then
         allocate(iVarUseCmax_I(4))
         ! The electric field should diffuse with Cmax by default in the five
         ! moment simulation.
         iVarUseCmax_I = [Ex_, Ey_, Ez_, HypE_]
      end if

      if (UseEfield .and. UseHyperbolicDivb .and. ClightDim > 0 &
           .and. SpeedHypDim > ClightDim) then
         SpeedHypDim = ClightDim
         if (iProc ==0)  write(*,*) NameSub //                &
              ' SpeedHypDim is larger than cLightDim. '//     &
              'Reduce SpeedHypDim to ClightDimSpeedHypDim =', &
              SpeedHypDim, ' ClightDim =', ClightDim, ''
      end if

      if (UseAnisoPe .and. .not. UseAnisoPressure)  call stop_mpi(NameSub//  &
           ' UseAnisoPe cannot be applied without UseAnisoPressure')

      if (UseAnisoPe .and. UseHallResist) call stop_mpi(NameSub// &
           ': UseAnisoPe is not implemented for Hall Mhd.')

      if (UseAnisoPe .and. UseAlfvenWaveDissipation) call stop_mpi(NameSub// &
           ' AnisoPe for coronal heating is not implemented yet')

      if (UseAnisoPe .and. UseRadCooling) call stop_mpi(NameSub// &
           ' AnisoPe for radiative cooling is not implemented yet')

      ! Fix NameSat_I if needed
      NameSat_I = 'none'
      do iSat = 1, nSatellite
         if (index(FilenameSat_I(iSat), 'sta') > 0 .or.  &
              index(FilenameSat_I(iSat), 'stereoa') > 0) &
              NameSat_I(iSat) = 'sta'
         if (index(FilenameSat_I(iSat), 'stb') > 0 .or.  &
              index(FilenameSat_I(iSat), 'stereob') > 0) &
              NameSat_I(iSat) = 'stb'
         if (index(FilenameSat_I(iSat), 'earth') > 0)    &
              NameSat_I(iSat) = 'earth'
      end do

      ! stop the code if there are two stereo a/b, earth traj files
      if (sum(index(NameSat_I, 'sta')) > 1) &
           call stop_mpi(NameSub//' two stereo A traj files???')
      if (sum(index(NameSat_I, 'stb')) > 1) &
           call stop_mpi(NameSub//' two stereo B traj files???')
      if (sum(index(NameSat_I, 'earth')) > 1) &
           call stop_mpi(NameSub//' two earth traj files???')

      ! stop the code if no stereo a/b, earth traj files are found when
      ! using 'sta'/'stb'/'earth' in TypeSatPos_I
      if (.not.all(TypeSatPos_I /= 'sta') .and. all(NameSat_I /= 'sta')) &
           call stop_mpi(NameSub//' missing stereo A traj file.')
      if (.not.all(TypeSatPos_I /= 'stb') .and. all(NameSat_I /= 'stb')) &
           call stop_mpi(NameSub//' missing stereo B traj file.')
      if (.not.all(TypeSatPos_I /= 'earth') .and. all(NameSat_I /= 'earth')) &
           call stop_mpi(NameSub//' missing earth traj file.')

      ! Disable thread-related logicals, if UseFieldLineThreads=.false.
      if(.not.UseFieldLineThreads)then
         DoPlotThreads = .false.; DoThreadRestart = .false.
      end if

      !$acc update device(nOrder, nStage, UseHalfStep, time_accurate, UseDtFixed)
      !$acc update device(DoCorrectFace, UseFDFaceFlux)

      !$acc update device(UseDivbSource)

      !$acc update device(DoConserveNeutrals, UseNonConservative, nConservCrit)

      !$acc update device(iMinFace, iMaxFace, iMinFace2, iMaxFace2)
      !$acc update device(jMinFace, jMaxFace, jMinFace2, jMaxFace2)
      !$acc update device(kMinFace, kMaxFace, kMinFace2, kMaxFace2)

      !$acc update device(UseUserUpdateStates)

    end subroutine correct_parameters
    !==========================================================================

    subroutine correct_grid_geometry

      use ModGeometry, ONLY: LogRGen_I
      use BATL_lib, ONLY: init_batl, CoordMin_D, CoordMax_D, &
           IsRotatedCartesian

      character(len=20):: TypeGeometryBatl
      character(len=20) :: TypeCellBcTmp_D(nDim)='none'

      character(len=*), parameter:: NameSub = 'correct_grid_geometry'
      !------------------------------------------------------------------------
      if(i_line_command("#GRID", iSessionIn=iSessionFirst) < 0) &
           call stop_mpi(NameSub // &
           ' #GRID command must be specified in the first session!')

      if(  i_line_command("#OUTERBOUNDARY", iSessionIn=iSessionFirst)<0 .and. &
           i_line_command("#BOXBOUNDARY", iSessionIn=iSessionFirst) < 0 ) &
           call stop_mpi(NameSub // &
           ' #OUTERBOUNDARY or #BOXBOUNDARY command must be specified &
           &in the first session!')

      if(product(nRootRead_D) > MaxBlock*nProc .and. iProc==0)then
         write(*,*)'Not enough grid blocks allocated for root blocks'
         write(*,*)'Number of root blocks=',product(nRootRead_D)
         write(*,*)'MaxBlock, nProc, MaxBlock*nProc=', &
              MaxBlock, nProc, MaxBlock*nProc
         call stop_mpi(NameSub//': insufficient number of grid blocks')
      end if

      ! Set XyzMin_D, XyzMax_D based on
      ! #GRID, #GRIDGEOMETRY, and #LIMITRADIUS
      ! #GRIDGEOMETRYLIMIT already sets XyzMin_D, XyzMax_D so that it does not
      ! have to be reset here
      if(.not.i_line_command("#GRIDGEOMETRYLIMIT", &
           iSessionIn=iSessionFirst) > 0) then
         select case(TypeGeometry)
         case('cartesian' ,'rotatedcartesian')
            XyzMin_D = [x1, y1, z1]
            XyzMax_D = [x2, y2, z2]
         case('rz')
            z1 = -0.5
            z2 = +0.5
            XyzMin_D = [x1, y1, z1]
            XyzMax_D = [x2, y2, z2]
         case('spherical', 'spherical_lnr', 'spherical_genr')
            !             R,   Phi, Latitude
            XyzMin_D = [ 0.0, 0.0, -cHalfPi]
            XyzMax_D = [ &
                 sqrt(max(x1**2,x2**2)+max(y1**2,y2**2) + max(z1**2,z2**2)), &
                 cTwoPi, cHalfPi ]
         case('cylindrical', 'cylindrical_lnr', 'cylindrical_genr')
            !            R,   Phi, Z
            XyzMin_D = [0.0, 0.0, z1]
            XyzMax_D = [sqrt(max(x1**2,x2**2)+max(y1**2,y2**2)), cTwoPi, z2]
         case('roundcube')
            if(rRound0 > rRound1)then
               ! Cartesian outside, so use x1..z2
               XyzMin_D = [x1, y1, z1]
               XyzMax_D = [x2, y2, z2]
            else
               ! Round outside, so fit this inside x1..z2
               if(nDim==2) XyzMax_D = &
                    min(abs(x1), abs(x2), abs(y1), abs(y2)) &
                    /sqrt(2.0)
               if(nDim==3) XyzMax_D = &
                    min(abs(x1), abs(x2), abs(y1), abs(y2), abs(z1), abs(z2)) &
                    /sqrt(3.0)
               XyzMin_D = -XyzMax_D
            end if

         case default
            call stop_mpi(NameSub//': unknown TypeGeometry='//TypeGeometry)
         end select

         if(i_line_command("#LIMITRADIUS", iSessionIn=iSessionFirst) > 0) then
            XyzMin_D(1) = RadiusMin
            XyzMax_D(1) = RadiusMax
            if(TypeGeometry == 'roundcube' .and. rRound1 > rRound0) &
                 XyzMax_D = RadiusMax/sqrt(real(nDim))
         else
            if(Body1 .and. rBody > 0.0)then
               ! Set inner boundary to match rBody for spherical coordinates
               if(TypeGeometry(1:3)=='sph' .or. TypeGeometry(1:3)=='cyl') &
                    XyzMin_D(1) = rBody
            end if
            RadiusMin = XyzMin_D(1)
            RadiusMax = XyzMax_D(1)
         end if
      end if

      if(index(TypeGeometry,'_genr') < 1) call set_gen_radial_grid

      ! Initialize BATL
      if(TypeGeometry(1:9)=='spherical') then
         TypeGeometryBatl = 'rlonlat'//TypeGeometry(10:20)
      else
         TypeGeometryBatl = TypeGeometry
      end if

      ! PGI can not handle "TypeCellBc_I(1:2*nDim-1:2) == 'periodic' " correctly.
      TypeCellBcTmp_D = TypeCellBc_I(1:2*nDim-1:2)

      call init_batl(XyzMin_D(1:nDim), XyzMax_D(1:nDim), MaxBlock, &
           TypeGeometryBatl, TypeCellBcTmp_D == 'periodic', &
           nRootRead_D(1:nDim), UseRadiusIn=.true., UseDegreeIn=.false.,&
           RgenIn_I = exp(LogRGen_I), UseUniformAxisIn=UseUniformAxis,&
           UseFDFaceFluxIn=UseFDFaceFlux, iVectorVarIn_I=iVectorVar_I)

      if(IsRotatedCartesian)then
         ! Fix x1, x2 .. z2 to include the full rotated domain
         x2 = sum(abs(CoordMin_D)) + sum(abs(CoordMax_D)); y2 = x2; z2 = x2
         x1 = -x2; y1 = x1; z1 = x1
      end if

      if(IsLogRadius .or. IsGenRadius)then
         ! Overwrite radial coordinates if necessary
         XyzMin_D(1) = CoordMin_D(1)
         XyzMax_D(1) = CoordMax_D(1)
      end if

      ! Fix grid size in ignored directions
      if(nDim == 1)then
         y1 = -0.5; XyzMin_D(2) = -0.5
         y2 = +0.5; XyzMax_D(2) = +0.5
      end if
      if(nDim < 3)then
         z1 = -0.5; XyzMin_D(3) = -0.5
         z2 = +0.5; XyzMax_D(3) = +0.5
      end if

    end subroutine correct_grid_geometry
    !==========================================================================

    subroutine correct_plot_range

      use BATL_lib,     ONLY: radius_to_gen, Phi_, Theta_, nRoot_D, &
           CoordMin_D, CoordMax_D, nIJK_D
      use ModKind,      ONLY: nByteReal
      use ModWritePlot, ONLY: adjust_plot_range
      use ModIO

      integer :: iFile
      real    :: Ratio, PlotRes_D(3)

      real    :: CellSizeMax_D(3), Cut
      real    :: SmallSize_D(3)   ! Used for 2D plot areas

      logical:: DoTest
      character(len=*), parameter:: NameSub = 'correct_plot_range'
      !------------------------------------------------------------------------
      call test_start(NameSub, DoTest)

      if(DoTest)write(*,*) NameSub,' CoordMin_D, CoordMax_D=', &
           CoordMin_D, CoordMax_D

      ! Largest cell size and a much smaller distance for 2D cuts
      CellSizeMax_D = (CoordMax_D - CoordMin_D)/(nIJK_D*nRoot_D)

      if(DoTest)write(*,*)NameSub,' CellSizeMax_D=',CellSizeMax_D

      PLOTFILELOOP: do iFile = Plot_+1, Plot_ + nPlotFile

         plot_area = plot_type(iFile)(1:3)

         if(plot_form(iFile) == 'tcp')then
            SmallSize_D = 0.0
         elseif(nByteReal == 8)then
            SmallSize_D   = 1e-9*CellSizeMax_D
         else
            SmallSize_D   = 1e-6*CellSizeMax_D
         end if

         if(DoTest)write(*,*)'iFile, plot_form, plot_area=',&
              iFile, plot_form(iFile), plot_area

         ! Fix plot range for various plot areas
         select case(plot_area)
         case('shl', 'box', 'eqb', 'eqr', 'lcb')
            ! These plot areas read all ranges from PARAM.in
            CYCLE PLOTFILELOOP
         case('cut')
            if(IsLogRadius) plot_range(1:2,iFile) = log(plot_range(1:2,iFile))
            if(IsGenRadius) then
               call radius_to_gen(plot_range(1,iFile))
               call radius_to_gen(plot_range(2,iFile))
            end if
            if(Phi_ > 0) plot_range(2*Phi_-1:2*Phi_,iFile) = &
                 cDegToRad*plot_range(2*Phi_-1:2*Phi_,iFile)
            if(Theta_ > 0) plot_range(2*Theta_-1:2*Theta_,iFile) = &
                 cDegToRad*plot_range(2*Theta_-1:2*Theta_,iFile)
            do iDim = 1, nDim
               if(plot_range(2*iDim-1,iFile) < plot_range(2*iDim,iFile)) CYCLE
               Cut =0.5*(plot_range(2*iDim-1,iFile) + plot_range(2*iDim,iFile))
               plot_range(2*iDim-1,iFile) = Cut - SmallSize_D(iDim)
               plot_range(2*iDim,iFile)   = Cut + SmallSize_D(iDim)
            end do
         case('sph')
            if(IsCartesianGrid)then
               plot_dx(1,iFile) = 1.0    ! set to match write_plot_sph
               plot_dx(2:3,iFile) = 1.0  ! angular resolution in degrees
               plot_range(2,iFile)= plot_range(1,iFile) + 1.e-4 ! so that R/=0
               plot_range(3,iFile)= 0.   - 0.5*plot_dx(2,iFile)
               plot_range(4,iFile)= 90.0 + 0.5*plot_dx(2,iFile)
               plot_range(5,iFile)= 0.   - 0.5*plot_dx(3,iFile)
               plot_range(6,iFile)= 360.0- 0.5*plot_dx(3,iFile)
            elseif(IsRLonLat)then
               plot_dx(1,iFile) = -1.0
               if(IsLogRadius) plot_range(1,iFile) = log(plot_range(1,iFile))
               if(IsGenRadius) call radius_to_gen(plot_range(1,iFile))
               plot_range(2,iFile)= plot_range(1,iFile) + 1.e-4 ! so that R/=0
               do i=Phi_,Theta_
                  plot_range(2*i-1,iFile) = CoordMin_D(i)
                  plot_range(2*i,iFile)   = CoordMax_D(i)
               end do
               plot_area='r=r' ! to disable the write_plot_sph routine
            else
               call stop_mpi(NameSub// &
                    ' Sph-plot is not implemented for geometry= '&
                    //TypeGeometry)
            end if

            ! There is nothing else to do for sph area
            CYCLE PLOTFILELOOP

         case('x=0')
            plot_range(1:5:2, iFile) = CoordMin_D
            plot_range(2:6:2, iFile) = CoordMax_D
            if( plot_form(iFile)=='tec' .or. IsCartesianGrid )then
               ! Limit plot range along x direction to be very small
               plot_range(1, iFile) = -SmallSize_D(x_)
               plot_range(2, iFile) = +SmallSize_D(x_)
               if(IsRlonLat) then
                  plot_range(1, iFile) = CoordMin_D(x_)
                  plot_range(2, iFile) = CoordMin_D(x_)+SmallSize_D(x_)
               end if
            else
               ! Limit Phi direction around cHalfPi
               plot_range(3, iFile) = cHalfPi - SmallSize_D(Phi_)
               plot_range(4, iFile) = cHalfPi + SmallSize_D(Phi_)
            end if

         case('y=0')
            plot_range(1:5:2, iFile) = CoordMin_D
            plot_range(2:6:2, iFile) = CoordMax_D
            if((plot_form(iFile) == 'idl' .or. plot_form(iFile) == 'tcp') &
                 .and. (IsRLonLat .or. IsCylindrical) &
                 .and. CoordMin_D(2) < cPi .and. CoordMax_D(2) > cPi) then
               ! Limit plot range in Phi direction to be small around 180 degs
               plot_range(3, iFile) = cPi - SmallSize_D(y_)
               plot_range(4, iFile) = cPi + SmallSize_D(y_)
            else
               ! Limit plot range along y (or Phi) direction to be very small
               plot_range(3, iFile) = -SmallSize_D(y_)
               plot_range(4, iFile) = +SmallSize_D(y_)
            end if

         case('z=0', '2d_')
            ! Limit plot range along z direction to be very small
            plot_range(1:5:2, iFile) = CoordMin_D
            plot_range(2:6:2, iFile) = CoordMax_D
            plot_range(5, iFile) = -SmallSize_D(z_)
            plot_range(6, iFile) = +SmallSize_D(z_)

         case('1d_')
            ! Limit plot range along 2nd and 3rd directions to be very small
            plot_range(1, iFile) = CoordMin_D(1)
            plot_range(2, iFile) = CoordMax_D(1)
            plot_range(3:5:2, iFile) = -SmallSize_D(y_:z_)
            plot_range(4:6:2, iFile) = +SmallSize_D(y_:z_)

         case('3d_')
            plot_range(1:5:2, iFile) = CoordMin_D
            plot_range(2:6:2, iFile) = CoordMax_D

         end select

         ! Reduce plot range in ignored dimensions
         if(nJ == 1) plot_range(3,iFile) = -SmallSize_D(y_)
         if(nJ == 1) plot_range(4,iFile) = +SmallSize_D(y_)
         if(nK == 1) plot_range(5,iFile) = -SmallSize_D(z_)
         if(nK == 1) plot_range(6,iFile) = +SmallSize_D(z_)

         if(DoTest)write(*,*)'For file ',iFile-plot_,&
              ' original range   =',plot_range(:,iFile)

         plot_range(1:5:2, iFile) = max(plot_range(1:5:2, iFile), CoordMin_D)
         plot_range(2:6:2, iFile) = min(plot_range(2:6:2, iFile), CoordMax_D)

         if(DoTest)write(*,*)'For file ',iFile-plot_,&
              ' limited range   =',plot_range(:,iFile)

         ! For plot_dx = 0.0 or -1.0 there is no need to adjust cut range
         if(plot_dx(1, iFile) <= cTiny)then

            plot_dx(:, iFile) = plot_dx(1, iFile) ! Define y and z

            CYCLE PLOTFILELOOP

         end if

         ! Make sure that plot resolution is a power of 2 fraction of cell size
         Ratio     = CellSizeMax_D(x_)/plot_dx(1, iFile)
         Ratio     = 2.0**nint(log(Ratio)/log(2.0))
         PlotRes_D = CellSizeMax_D / Ratio
         plot_dx(1:3, iFile) = PlotRes_D

         ! Make sure that plotting range is placed at an integer multiple of dx
         call adjust_plot_range(PlotRes_D(1), plot_range(:,iFile))
         if(DoTest)write(*,*)'For file ',iFile-plot_,&
              ' adjusted range   =',plot_range(:,iFile)

      end do PLOTFILELOOP

      call test_stop(NameSub, DoTest)
    end subroutine correct_plot_range
    !==========================================================================

    subroutine set_extra_parameters

      use ModMultiFluid, ONLY: UseMultiIon
      use ModTimeStepControl, ONLY: UseTimeStepControl,TimeStepControlInit

      integer:: l
      character(len=500):: StringParam
      !------------------------------------------------------------------------
      ! We need normalization for dt
      if(UseDtFixed)then
         DtFixed     = DtFixedDim * Io2No_V(UnitT_)
         DtFixedOrig = DtFixed   ! Store the initial setting
         Dt          = DtFixed
         Cfl         = 1.0       ! UseDtFixed only works with time accurate
      end if

      if(UseDtLimit .or. UseLocalTimeStep)then
         DtLimit     = DtLimitDim * Io2No_V(UnitT_)
         ! Store the initial setting
         DtLimitOrig = DtLimit
         ! Dt = 0 in steady state
         if(time_accurate .and. UseDtLimit) Dt  = DtLimit
      end if

      if(UseTimeStepControl)then
         ! Reduce initial time step / Cfl number.
         ! The original values are stored in DtFixedOrig and CflOrig
         if(UseDtFixed)then
            DtFixed = TimeStepControlInit*DtFixed
         else if(UseDtLimit) then
            DtLimit = TimeStepControlInit*DtLimit
         else
            Cfl     = TimeStepControlInit*Cfl
         end if
         TimeStepControlInit = 1.0
      else
         if(UseDtFixed)then
            DtFixed = DtFixedOrig
         else if(UseDtLimit) then
            DtLimit = DtLimitOrig
         else
            Cfl     = CflOrig
         end if
      end if

      DoOneCoarserLayer = .not. (nOrder>1 .and. &
           (UseTvdResChange .or. UseAccurateResChange))
      if(UseHighResChange) DoOneCoarserLayer = .false.

      DoLimitMomentum = UseBorisCorrection .and. DoOneCoarserLayer

      if(UseMultiIon)DoLimitMomentum = .false.

      ! Set default scalar parameters for plot files
      do iFile = plot_+1, plot_+nPlotFile
         l = index(plot_pars(iFile), '{default}')
         if(l < 1) CYCLE

         ! Set the name of default scalar parameters for plotting
         StringParam = ''
         if(plot_dimensional(iFile))then
            if(Io2Si_V(UnitX_)   /= 1)StringParam = 'xSI'
            if(Io2Si_V(UnitT_)   /= 1)StringParam = trim(StringParam)//' tSI'
         else
            if(No2Si_V(UnitX_)   /= 1)StringParam = 'xSI'
            if(No2Si_V(UnitT_)   /= 1)StringParam = trim(StringParam)//' tSI'
            if(No2Si_V(UnitRho_) /= 1)StringParam = trim(StringParam)//' rhoSI'
         end if
         if(rBody > 0) StringParam = trim(StringParam)//' r'
         if(any(Gamma_I /= Gamma))then
            do iFluid = IonFirst_, nFluid
               write(StringParam,'(a,i1)') trim(StringParam)//' g', &
                    iFluid - IonFirst_ + 1
            end do
         else
            StringParam = trim(StringParam)//' g'
         end if
         if(GammaElectron /= Gamma) StringParam = trim(StringParam)//' ge'
         if(any(MassFluid_I /= 1))then
            do iFluid = IonFirst_, nFluid
               if(UseEfield .and. iFluid == nIonFluid)then
                  ! Last fluid is assumed to be the electrons
                  StringParam = trim(StringParam)//' me'
               else
                  write(StringParam,'(a,i1)') trim(StringParam)//' m', &
                       iFluid - IonFirst_ + 1
               end if
            end do
         end if
         if(any(ChargeIon_I /= 1))then
            do iFluid = 1, nIonFluid
               if(UseEfield .and. iFluid == nIonFluid)then
                  ! Last fluid is assumed to be the electrons
                  StringParam = trim(StringParam)//' qe'
               else
                  write(StringParam,'(a,i1)') trim(StringParam)//' q',iFluid
               end if
            end do
         end if

         if (ClightFactor /=1 .or. ClightDim > 0) &
              StringParam = trim(StringParam)//' clight'

         ! Replace '{default}' with StringParam
         plot_pars1 = plot_pars(iFile)
         plot_pars(iFile) = plot_pars1(1:l-1)//trim(adjustl(StringParam))// &
              plot_pars1(l+9:len_trim(plot_pars1))
      end do

      !$acc update device(Dt, DtFixed, Cfl)

    end subroutine set_extra_parameters
    !==========================================================================
    subroutine sort_smooth_indicator

      ! The variables using the same smooth indicator should be
      ! calculated one by one. The smooth indicator
      ! itself is calculated first.
      ! iVarSmoothIndex_I is the calculation order.

      real:: iVarSmoothReal_V(nVar)
      integer:: iVar

      !------------------------------------------------------------------------
      do iVar = 1, nVar
         if(iVarSmooth_V(iVar) == iVar) then
            iVarSmoothReal_V(iVar) = real(iVar) - 0.5
         else
            iVarSmoothReal_V(iVar) = real(iVarSmooth_V(iVar))
         endif
      enddo

      call sort_quick(nVar,iVarSmoothReal_V,iVarSmoothIndex_I)

    end subroutine sort_smooth_indicator
    !==========================================================================

  end subroutine set_parameters
  !============================================================================

end module ModSetParameters
!==============================================================================
