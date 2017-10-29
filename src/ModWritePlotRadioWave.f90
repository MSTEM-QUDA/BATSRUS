!  Copyright (C) 2002 Regents of the University of Michigan, portions used with permission 
!  For more information, see http://csem.engin.umich.edu/tools/swmf
!^GFG COPYRIGHT UM
!============================================================================
subroutine write_plot_radiowave(iFile)

  !
  ! Purpose:  creates radio telescope images of the radiowaves at several
  !     frequencies by inegrating the plasma emissivity along the refracting
  !     rays.
  !     The plasma emissivity is considered here a function or the plasma 
  !     density only.
  ! Written by Leonid Benkevitch.
  !

  use ModProcMH, ONLY: iProc
  use ModMain, ONLY: Time_Accurate, n_Step, Time_Simulation
  use ModIO, ONLY: StringRadioFrequency_I, plot_type1, &
       plot_type, plot_form, plot_, filename, ObsPos_DI, &
       n_Pix_X, n_Pix_Y, X_Size_Image, Y_Size_Image, &
       NamePlotDir, StringDateOrTime, nPlotRfrFreqMax
  use ModUtilities, ONLY: open_file, close_file
  use ModIoUnit, ONLY: UnitTmp_
  use ModCellGradient, ONLY: get_grad_dgb
  use ModAdvance, ONLY: State_VGB
  use ModVarIndexes, ONLY: Rho_
  use BATL_lib, ONLY:  nI, nJ, nK
  implicit none

  !
  ! Arguments
  !
  integer, intent(in) :: iFile

  !\
  ! Local variables
  !/
  !\
  ! Observer lacation
  !/
  real :: XyzObserv_D(3)                     
  real :: ImageRange_I(4)    
  ! Image plane: XLower, YLower, XUpper, YUpper
  real :: HalfImageRangeX, HalfImageRangeY
  !\
  ! Radius of "integration sphere"
  !/
  real :: rIntegration           
  !\
  ! Dimensions of the raster in pixels
  !/
  integer ::  nXPixel, nYPixel

  !\
  !  Number of frequencies read from StringRadioFrequency_I(iFile)
  !/
  integer :: nFreq
  !\
  ! Frequencies in Hertz:
  !/
  real               :: RadioFrequency_I(nPlotRfrFreqMax)
  !\
  ! 

  character (LEN=20) :: NameVar_I(nPlotRfrFreqMax)

  !\
  ! The result of the emissivity integration
  !/
  real, allocatable, dimension(:,:,:) :: Intensity_III

  integer :: iFreq, iPixel, jPixel
  real :: XPixel, XPixelSize, YPixel, YPixelSize
  real :: XLower, YLower, XUpper, YUpper
  real :: ImagePlaneDiagRadius

  character (LEN=120) :: NameVarAll
  character (LEN=4)   :: NameDelimiter
  character (LEN=500) :: unitstr_TEC
  character (LEN=4)   :: NameFileExtension
  character (LEN=40)  :: NameFileFormat
  logical             :: DoTest, DoTestMe
  !--------------------------------------------------------

  !
  ! Initialize
  !
  call set_oktest('write_plot_radiowave', DoTest,DoTestMe)
  call timing_start('write_plot_radiowave')

  !
  ! Set file specific parameters 
  !
  XyzObserv_D = ObsPos_DI(:,iFile)
  nXPixel = n_Pix_X(iFile)
  nYPixel = n_Pix_Y(iFile)
  HalfImageRangeX = 0.5*X_Size_Image(iFile)
  HalfImageRangeY = 0.5*Y_Size_Image(iFile)
  ImageRange_I = (/-HalfImageRangeX, -HalfImageRangeY, &
       HalfImageRangeX, HalfImageRangeY/)
  !
  ! Determine the image plane inner coordinates of pixel centers
  !
  XLower = ImageRange_I(1)
  YLower = ImageRange_I(2)
  XUpper = ImageRange_I(3)
  YUpper = ImageRange_I(4)
  XPixelSize = (XUpper - XLower)/nXPixel
  YPixelSize = (YUpper - YLower)/nYPixel

  ImagePlaneDiagRadius = sqrt(HalfImageRangeX**2 + HalfImageRangeY**2)
  rIntegration = ceiling(max(ImagePlaneDiagRadius+1.0, 5.0))

  if (DoTestMe) write(*,*) 'rIntegration = ', rIntegration

  call parse_freq_string(StringRadioFrequency_I(iFile), RadioFrequency_I, &
       NameVar_I, nFreq) 

  if (iProc .eq. 0) then
     if(DoTest)then
        write(*,*) 'XyzObserv_D     =', XyzObserv_D
        write(*,*) 'ImageRange_I   =', ImageRange_I, &
             '(XLower, YLower, XUpper, YUpper)'
        write(*,*) 'nXPixel        =', nXPixel
        write(*,*) 'nYPixel        =', nYPixel
     end if
     select case(plot_form(ifile))
     case('tec')
        NameVarAll    = '"'
        NameDelimiter = '", "'
        NameFileExtension='.dat'
     case('idl')
        NameVarAll    = ''
        NameDelimiter = '    '
        NameFileExtension='.out'
     end select
     do iFreq = 1, nFreq
        NameVarAll = &
             trim(NameVarAll)//NameDelimiter//trim(adjustl(NameVar_I(iFreq)))
     end do

     plot_type1=plot_type(ifile)

     write(*,*) 'iFile = ', iFile
     write(*,*) 'nFreq = ', nFreq
     write(*,*) 'StringRadioFrequency_I(iFile) = ', &
          StringRadioFrequency_I(iFile)
     write(*,*) 'NameVar_I:'
     do iFreq = 1, nFreq
        write(*,*) NameVar_I(iFreq)
     end do
     write(*,*) 'NameVarAll = ', NameVarAll
     write(*,*) 'RadioFrequency_I = '
     do iFreq = 1, nFreq
        write(*,*) RadioFrequency_I(iFreq)
     end do

     ! Get the headers that contain variable names and units
     select case(plot_form(ifile))
     case('tec')
        unitstr_TEC = 'VARIABLES = "X", "Y",'//NameVarAll//'"'
        if(DoTest) write(*,*) unitstr_TEC
     end select
  end if
  allocate(Intensity_III(nXPixel,nYPixel,nFreq))
  Intensity_III = 0.0
  !\
  !Get density gradient
  call get_grad_dgb(State_VGB(Rho_,1:nI,1:nJ,1:nK,:))
  do iFreq = 1, nFreq
     ! Calculate approximate radius of the  critical surface around the sun
     ! from the frequency
     if (iProc .eq. 0) write(*,*) 'RAYTRACE START: RadioFrequency = ', &
          RadioFrequency_I(iFreq)
     if (iProc .eq. 0) write(*,*) 'RAYTRACE START: ImagePlaneDiagRadius = ', &
          ImagePlaneDiagRadius 
     if (iProc .eq. 0) write(*,*) 'RAYTRACE START: rIntegration = ', &
          rIntegration

     call get_ray_bunch_intensity(XyzObserv_D, RadioFrequency_I(iFreq), &
          ImageRange_I, rIntegration, &
          nXPixel, nYPixel, Intensity_III(:,:,iFreq))

     if (iProc .eq. 0) write(*,*) 'RAYTRACE END'
  end do

  if (iProc==0) then
     if (ifile-plot_ > 9) then
        NameFileFormat='("' // trim(NamePlotDir) // '",a,i2,a,i7.7,a)'
     else
        NameFileFormat='("' // trim(NamePlotDir) // '",a,i1,a,i7.7,a)'
     end if

     if(time_accurate)then
        call get_time_string
        write(filename,NameFileFormat) &
             trim(plot_type1)//"_",&
             ifile-plot_,"_t"//trim(StringDateOrTime)//"_n",n_step,&
             NameFileExtension
     else
        write(filename,NameFileFormat) &
             trim(plot_type1)//"_",&
             ifile-plot_,"_n",n_step,NameFileExtension
     end if

     write(*,*) 'filename = ', filename

     call open_file(FILE=filename)

     !
     ! Write the file header
     !
     select case(plot_form(ifile))
     case('tec')
        write(UnitTmp_,*) 'TITLE="BATSRUS: Radiotelescope Image"'
        write(UnitTmp_,'(a)') trim(unitstr_TEC)
        write(UnitTmp_,*) 'ZONE T="RFR Image"', &
             ', I=',nXPixel,', J=',nYPixel,', F=POINT'
        ! Write point values
        do jPixel = 1, nYPixel
           YPixel = YLower + (real(jPixel) - 0.5)*YPixelSize
           do iPixel = 1, nXPixel
              XPixel = XLower + (real(iPixel) - 0.5)*XPixelSize
 
              write(UnitTmp_,fmt="(30(E14.6))") XPixel, YPixel, &
                   Intensity_III(iPixel,jPixel,1:nFreq)
           end do
        end do

     case('idl')
        ! description of file contains units, physics and dimension
        write(UnitTmp_,"(a)") 'RFR Radiorelescope Image'

        ! 2 in the next line means 2 dimensional plot, 1 in the next line
        !  is for a 2D cut, in other words one dimension is left out)
        write(UnitTmp_,"(i7,1pe13.5,3i3)") &
             n_step, time_simulation, 2, 0, nFreq

        ! Grid size
        write(UnitTmp_,"(2i4)") nXPixel, nYPixel

        ! Coordinate, variable and equation parameter names
        write(UnitTmp_,"(a)")  '  X  Y '//trim(NameVarAll)

        ! Data
        do jPixel = 1, nYPixel
           YPixel = YLower + (real(jPixel) - 0.5)*YPixelSize

           do iPixel = 1, nXPixel
              XPixel = XLower + (real(iPixel) - 0.5)*XPixelSize
              write(UnitTmp_,fmt="(30(1pe13.5))") &
                   XPixel, YPixel, Intensity_III(iPixel,jPixel,1:nFreq)
           end do
        end do
     end select

     call close_file

  end if  !iProc ==0

  deallocate(Intensity_III)

  if (DoTestMe) write(*,*) 'write_plot_radiowave finished'

  call timing_stop('write_plot_radiowave')

end subroutine write_plot_radiowave

!==========================================================================

subroutine parse_freq_string(NameVarAll, Frequency_I, NameVar_I, nFreq)
  use ModIO, ONLY: nPlotRfrFreqMax
  implicit none
  !\
  ! INPUT
  !/
  ! String read from PARAM.in, like '1500kHz, 11MHz, 42.7MHz, 1.08GHz'
  character(len=*), intent(in) :: NameVarAll
  real,    intent(out) :: Frequency_I(nPlotRfrFreqMax)
  integer, intent(out) :: nFreq
  character(len=*), intent(out) :: NameVar_I(nPlotRfrFreqMax)
  character(len=50) :: cTmp, NameFreqUnit
  integer :: iFreq, lNameVarAll, iChar, iTmp


  lNameVarAll = len(trim(NameVarAll))
  nFreq = 1
  iChar = 1

  ! Skip spaces, commas, or semicolons
  if (is_delim(NameVarAll(1:1))) then
     do while(is_delim(NameVarAll(iChar:iChar)) &
          .and. (iChar .le. lNameVarAll))
        iChar = iChar + 1
     end do
  end if

  do while (iChar .le. lNameVarAll)

     iTmp = 0
     do while(is_num(NameVarAll(iChar:iChar)) &
          .and. (iChar .le. lNameVarAll))
        iTmp = iTmp + 1
        cTmp(iTmp:iTmp) = NameVarAll(iChar:iChar)
        iChar = iChar + 1
     end do

     read(cTmp(1:iTmp),*) Frequency_I(nFreq)

     do while(is_delim(NameVarAll(iChar:iChar)) &
          .and. (iChar .le. lNameVarAll))
        iChar = iChar + 1
     end do

     iTmp = 0
     do while((.not. is_delim(NameVarAll(iChar:iChar))) &
          .and. (iChar .le. lNameVarAll))
        iTmp = iTmp + 1
        cTmp(iTmp:iTmp) = NameVarAll(iChar:iChar)
        iChar = iChar + 1
     end do

     read(cTmp(1:iTmp),*) NameFreqUnit

     select case(trim(NameFreqUnit))
     case('Hz', 'HZ', 'hz')
        ! Do not scale
     case('kHz', 'kHZ', 'khz', 'KHz', 'Khz')
        Frequency_I(nFreq) = 1e3*Frequency_I(nFreq)
     case('MHz', 'MHZ', 'Mhz')
        Frequency_I(nFreq) = 1e6*Frequency_I(nFreq)
     case('GHz', 'GHZ', 'Ghz')
        Frequency_I(nFreq) = 1e9*Frequency_I(nFreq)
     case default
        write(*,*) '+++ Unrecognized frequency unit "'//trim(NameFreqUnit) &
             //'". Use only Hz, kHz, MHz, or GHz'
        stop
     end select

     do while(is_delim(NameVarAll(iChar:iChar)) &
          .and. (iChar .le. lNameVarAll))
        iChar = iChar + 1
     end do

     nFreq = nFreq + 1

  end do
  nFreq = nFreq - 1
  !\
  ! Just in case: make all the frequencies positive
  !/
  Frequency_I = abs(Frequency_I)    

  !
  ! Create standard frequency value array
  !
  do iFreq = 1, nFreq
     if ((Frequency_I(iFreq) > 0.0) .and. (Frequency_I(iFreq)<1e3)) then
        write(NameVar_I(iFreq),'(a,f6.2,a)') Frequency_I(iFreq), '_Hz' 
     else if ((Frequency_I(iFreq)>=1e3) .and. (Frequency_I(iFreq)<1e6)) then
        write(NameVar_I(iFreq),'(a,f6.2,a)') Frequency_I(iFreq)/1e3, '_kHz' 
     else if ((Frequency_I(iFreq) >= 1e6) .and. (Frequency_I(iFreq)<1e9)) then
        write(NameVar_I(iFreq),'(f6.2,a)') Frequency_I(iFreq)/1e6, '_MHz' 
     else if ((Frequency_I(iFreq) >= 1e9).and.(Frequency_I(iFreq)< 1e12)) then
        write(NameVar_I(iFreq),'(f6.2,a)') Frequency_I(iFreq)/1e9, '_GHz' 
     else if ((Frequency_I(iFreq) >= 1e12).and.(Frequency_I(iFreq)< 1e15))then
        write(NameVar_I(iFreq),'(f6.2,a)') Frequency_I(iFreq)/1e12, '_THz' 
     end if
  end do

  do iFreq = 1, nFreq
     NameVar_I(iFreq) = 'f='//trim(adjustl(NameVar_I(iFreq)))
  end do

contains 
  !==============================
  function is_num(c) result(yesno)
    character(len=1) :: c
    logical :: yesno
    yesno = (lge(c, '0') .and. lle(c, '9')) .or. (c .eq. '.') &
         .or. (c .eq. 'e') .or. (c .eq. 'E') &
         .or. (c .eq. 'd') .or. (c .eq. 'D') &
         .or. (c .eq. '+') .or. (c .eq. '-')
  end function is_num
  !==============================
  function is_delim(c) result(yesno)
    character(len=1) :: c
    logical :: yesno
    yesno = (c .eq. ' ') .or. (c .eq. ',') .or. (c .eq. ';')
  end function is_delim
  !==============================
end subroutine parse_freq_string
