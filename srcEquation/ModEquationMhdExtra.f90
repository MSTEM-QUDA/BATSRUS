module ModVarIndexes

  use ModSingleFluid
  use ModExtraVariables, ONLY : NameNumber_I
  implicit none

  save

  ! This equation module contains the standard MHD equations plus one
  ! extra wave energy of a single frequency w, Iw that carries the extra energy.
  character (len=*), parameter :: NameEquation='MHD Extra Waves'



  ! loop variable over spectrum
  integer :: iWave

  ! Number of frequency bins in spectrum
  integer, parameter :: nWave =1
  integer, parameter :: nVar = 9 + nWave
  
  ! Array of strings for plotting
  character(len=3)   :: NameWaveVar_I(nWave)

  ! Named indexes for State_VGB and other variables
  ! These indexes should go subsequently, from 1 to nVar+1.
  ! The energy is handled as an extra variable, so that we can use
  ! both conservative and non-conservative scheme and switch between them.

  ! The variables numbered from 1 to nVar are:
  !
  ! 1. defined in set_ICs.
  ! 2. prolonged and restricted in AMR
  ! 3. saved into the restart file
  ! 4. sent and recieved in the exchange message
  ! 5. filled in the outer ghostcells by the program set_outer_BCs
  ! 5. integrated by subroutine integrate_all for saving to logfile
  ! 6. should be updated by advance_*

  integer, parameter :: &
       Rho_   = 1,    &
       RhoUx_ = 2,    &
       RhoUy_ = 3,    &
       RhoUz_ = 4,    &
       Bx_    = 5,    &
       By_    = 6,    &
       Bz_    = 7,    &
       Ew_    = 8,    &
       WaveFirst_ = 9, &
       WaveLast_  = WaveFirst_+nWave-1, &
       p_     = nVar, &
       Energy_= nVar+1  

  ! This allows to calculate rhoUx_ as rhoU_+x_ and so on.
  integer, parameter :: RhoU_ = RhoUx_-1, B_ = Bx_-1

  ! These arrays are useful for multifluid
  integer, parameter :: iRho_I(nFluid)   = (/Rho_/)
  integer, parameter :: iRhoUx_I(nFluid) = (/RhoUx_/)
  integer, parameter :: iRhoUy_I(nFluid) = (/RhoUy_/)
  integer, parameter :: iRhoUz_I(nFluid) = (/RhoUz_/)
  integer, parameter :: iP_I(nFluid)     = (/p_/)

  ! The default values for the state variables:
  ! Variables which are physically positive should be set to 1,
  ! variables that can be positive or negative should be set to 0:
  real, parameter :: DefaultState_V(nVar+1) = (/ & 
       1.0, & ! Rho_
       0.0, & ! RhoUx_
       0.0, & ! RhoUy_
       0.0, & ! RhoUz_
       0.0, & ! Bx_
       0.0, & ! By_
       0.0, & ! Bz_
       0.0, & ! Ew_ 
       (0.0, iWave=WaveFirst_,WaveLast_) & 
       1.0, & ! p_
       1.0 /) ! Energy_ 
 
  ! The names of the variables used in i/o
  character(len=*), parameter :: NameVar_V(nVar+1) = (/ &
       'Rho', & ! Rho_
       'Mx ', & ! RhoUx_
       'My ', & ! RhoUy_
       'Mz ', & ! RhoUz_
       'Bx ', & ! Bx_
       'By ', & ! By_
       'Bz ', & ! Bz_
       'Ew ', & ! Ew_  
       ('I'//NameNumber_I(iWave-1), iWave=1,nWave) & ! Waves
       'p  ', & ! p_
       'e  '/) ! Energy_        
  
  ! The space separated list of nVar conservative variables for plotting
  character(len=*), parameter :: NameConservativeVarPref = &
       'rho mx my mz bx by bz Ew' 
     
  character(len=*), parameter :: NameConservativeVarSuff = &
       ' e'

  character(len=4*nWave+len(NameConservativeVarPref) + &
       len(NameConservativeVarSuff))      :: NameConservativeVar = &
       trim(NameConservativeVarPref)         ! updated below

  ! The space separated list of nVar primitive variables for plotting
  character(len=*), parameter :: NamePrimitiveVarPref = &
       'rho ux uy uz bx by bz Ew' 
  character(len=*), parameter :: NamePrimitiveVarSuff = &
       ' p'
  character(len=4*nWave+len(NamePrimitiveVarPref)+len(NamePrimitiveVarSuff)) :: &
       NamePrimitiveVar = trim(NamePrimitiveVarPref)

! The space separated list of nVar primitive variables for TECplot output
  character(len=*), parameter :: NamePrimitiveVarTec = &
       '"`r", "U_x", "U_y", "U_z", "B_x", "B_y", "B_z", "E_w", ' //&
       '"I01", "I02", "I03", "I04", "I05", "I06", "I07", "I08", "I09", "I10", '// & 
       '"I11", "I12", "I13", "I14", "I15", "I16", "I17", "I18", "I19", "I20", '//&
       '"I21", "I22", "I23", "I24", "I25", "I26", "I27", "I28", "I29", "I30", '//&
       '"I31", "I32", "I33", "I34", "I35", "I36", "I37", "I38", "I39", "I40", '//&
       '"I41", "I42", "I43", "I44", "I45", "I46", "I47", "I48", "I49", "I50"  '//&
       '"p" '

  ! Names of the user units for IDL and TECPlot output
  character(len=20) :: &
       NameUnitUserIdl_V(nVar+1) = '', NameUnitUserTec_V(nVar+1) = ''

  ! The user defined units for the variables
  real :: UnitUser_V(nVar+1) = 1.0

  ! Primitive variable names
  integer, parameter :: U_ = RhoU_, Ux_ = RhoUx_, Uy_ = RhoUy_, Uz_ = RhoUz_

  ! Specify scalar to be advected
  integer, parameter :: ScalarFirst_ = Ew_, ScalarLast_ = WaveLast_

  ! There are no multi-species
  logical, parameter :: UseMultiSpecies = .false.

  ! Declare the following variables to satisfy the compiler
  integer, parameter :: SpeciesFirst_ = 1, SpeciesLast_ = 1
  real               :: MassSpecies_V(SpeciesFirst_:SpeciesLast_)

contains
  subroutine init_mod_equation
    ! Initialize usre units and names for the MHD variables

    call init_mhd_variables

    ! Create variable name strings for plotting
    
    do iWave=i,nWave
       write(NameWaveVar_I(iWave),'(a,i2.2)') ' I'//iWave
       NameConservativeVar=trim(NameConservativeVar)//NameWaveVar_I(iWave)
       NamePrimitiveVar=trim(NamePrimitiveVar)//NameWaveVar_I(iWave)
    end do
    NameConservativeVar=trim(NameConservativeVar)//trim(NameConservativeVarSuff)
    NamePrimitiveVar=trim(NamePrimitiveVar)//trim(NamePrimitiveVarSuff)

    ! Set the unit and unit name for the wave energy variable
    UnitUser_V(Ew_)        = UnitUser_V(Energy_)
    NameUnitUserTec_V(Ew_) = NameUnitUserTec_V(Energy_)
    NameUnitUserIdl_V(Ew_) = NameUnitUserIdl_V(Energy_)
   
    UnitUser_V(I01_:I50_)        = UnitUser_V(Energy_)
    NameUnitUserTec_V(I01_:I50_) = NameUnitUserTec_V(Energy_)
    NameUnitUserIdl_V(I01_:I50_) = NameUnitUserIdl_V(Energy_)
    
   end subroutine init_mod_equation

end module ModVarIndexes


