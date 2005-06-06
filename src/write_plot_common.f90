!^CFG COPYRIGHT UM
!=============================================================================
subroutine write_plot_common(ifile)

  ! routine that loops over all blocks per processor and write the appropriate
  ! output files.

  use ModProcMH
  use ModMain
  use ModGeometry, ONLY : XyzMin_D,XyzMax_D,true_cell
  use ModGeometry, ONLY : TypeGeometry                   !^CFG IF NOT CARTESIAN
  use ModPhysics, ONLY : unitUSER_x, thetaTilt,Rbody
  use ModIO
  use ModIoUnit, ONLY : io_unit_new
  use ModNodes
  use ModNumConst, ONLY : cPi
  use ModMpi
  implicit none


  ! Arguments

  integer, intent(in) :: ifile

  ! Local variables

  integer :: iError

  ! Plot variables
  real :: PlotVar(-1:nI+2,-1:nJ+2,-1:nK+2,nplotvarmax)
  real :: PlotVar_inBody(nplotvarmax)
  logical :: PlotVar_useBody(nplotvarmax)
  real, allocatable :: PlotVarNodes(:,:,:,:,:)

  character (len=10) :: plotvarnames(nplotvarmax)
  integer :: nplotvar

  ! Equation parameters
  integer, parameter :: neqparmax=10
  real :: eqpar(neqparmax)
  character (len=10) :: eqparnames(neqparmax)
  integer :: neqpar

  character (LEN=79) :: allnames
  character (LEN=500) :: unitstr_TEC, unitstr_IDL
  character (LEN=4) :: file_extension
  character (LEN=40) :: file_format
  character (len=80) :: filename_n, filename_s
  character (len=1) :: NorthOrSouth

  ! Indices and coordinates
  integer :: iBLK,i,j,k,iVar
  integer :: ntheta, nphi
  real :: xmin,xmax,ymin,ymax,zmin,zmax
  real :: rplot
  real :: dxblk,dyblk,dzblk,dxblk_out

  real :: dxPEmin(3),dxGLOBALmin(3)
  integer :: nPEcells, nBLKcells, nGLOBALcells
  integer :: nPEcellsN,nPEcellsS,nBLKcellsN, nBLKcellsS
  integer :: nGLOBALcellsN,nGLOBALcellsS

  integer :: iTime_I(7)

  logical :: oktest,oktest_me
  !---------------------------------------------------------------------------

  ! Initialize stuff
  call set_oktest('write_plot_common',oktest,oktest_me)

  PlotVar = 0.0
  plotvar_inBody = 0.0
  plotvar_useBody = .false.

  unitstr_TEC = ''
  unitstr_IDL = ''

  plot_type1=plot_type(ifile)
  plot_vars1=plot_vars(ifile)
  plot_pars1=plot_pars(ifile)

  if(oktest_me)write(*,*)'ifile=',ifile,' plot_type=',plot_type1, &
       ' form = ',plot_form(ifile)

  call split_str(plot_vars1,nplotvarmax,plotvarnames,nplotvar)
  call split_str(plot_pars1,neqparmax,eqparnames,neqpar)
  call set_eqpar(ifile-plot_,neqpar,eqparnames,eqpar)

  allnames=trim(plot_vars1)//' '//plot_pars1

  if(oktest_me) then
     write(*,*) plot_vars1
     write(*,*) nplotvar,plotvarnames
     write(*,*) plot_dx(:,ifile)
     write(*,*) plot_range(:,ifile)
     write(*,*) plot_type1
     write(*,*) plot_form(ifile)
  end if

  ! Construct the file name
  if (ifile-plot_ > 9) then
     file_format='("' // trim(NamePlotDir) // '",a,i2,a,i7.7,a,i4.4,a)'
  else
     file_format='("' // trim(NamePlotDir) // '",a,i1,a,i7.7,a,i4.4,a)'
  end if

  ! For time accurate runs the file name will contain the StringTimeH4M2S2
  if(time_accurate)call get_time_string

  select case(plot_form(ifile))
  case('tec')
     file_extension='.tec'
  case('idl')
     file_extension='.idl'
  end select
  if(index(plot_type1,'sph')>0)then
     if(time_accurate)then
        ! do the northern hemisphere
        write(filename_n,file_format) &
             plot_type1(1:2)//"N"//plot_type1(4:len_trim(plot_type1))//"_",&
             ifile-plot_,"_t"//StringTimeH4M2S2//"_n",n_step,"_pe",iProc,&
             file_extension
        ! do the southern hemisphere
        write(filename_s,file_format) &
             plot_type1(1:2)//"S"//plot_type1(4:len_trim(plot_type1))//"_",&
             ifile-plot_,"_t"//StringTimeH4M2S2//"_n",n_step,"_pe",iProc,&
             file_extension
     else
        ! do the northern hemisphere
        write(filename_n,file_format) &
             plot_type1(1:2)//"N"//plot_type1(4:len_trim(plot_type1))//"_",&
             ifile-plot_,"_n",n_step,"_pe",iProc,file_extension
        ! do the southern hemisphere
        write(filename_s,file_format) &
             plot_type1(1:2)//"S"//plot_type1(4:len_trim(plot_type1))//"_",&
             ifile-plot_,"_n",n_step,"_pe",iProc,file_extension
     end if
     ! open the files
     unit_tmp2 = io_unit_new()
     if(save_binary .and. plot_form(ifile)=='idl') then
        open(unit_tmp ,file=filename_n,status="replace",err=999,&
             form="unformatted")
        open(unit_tmp2,file=filename_s,status="replace",err=999,&
             form="unformatted")
     else
        open(unit_tmp ,file=filename_n,status="replace",err=999)
        open(unit_tmp2,file=filename_s,status="replace",err=999)
     end if
  elseif(plot_form(ifile)=='tec')then
     if(time_accurate)then
        write(filename_n,file_format) &
             trim(plot_type1)//"_",&
             ifile-plot_,"_t"//StringTimeH4M2S2//"_n",n_step,"_1_pe",iProc,&
             file_extension
        write(filename_s,file_format) &
             trim(plot_type1)//"_",&
             ifile-plot_,"_t"//StringTimeH4M2S2//"_n",n_step,"_2_pe",iProc,&
             file_extension
     else
        write(filename_n,file_format) &
             trim(plot_type1)//"_",&
             ifile-plot_,"_n",n_step,"_1_pe",iProc,file_extension
        write(filename_s,file_format) &
             trim(plot_type1)//"_",&
             ifile-plot_,"_n",n_step,"_2_pe",iProc,file_extension
     end if
     unit_tmp2 = io_unit_new()
     ! Open files
     open(unit_tmp ,file=filename_n,status="replace",err=999)
     open(unit_tmp2,file=filename_s,status="replace",err=999)
  else
     if(time_accurate)then
        write(filename,file_format) &
             trim(plot_type1)//"_",&
             ifile-plot_,"_t"//StringTimeH4M2S2//"_n",n_step,"_pe",iProc,&
             file_extension
     else
        write(filename,file_format) &
             trim(plot_type1)//"_",&
             ifile-plot_,"_n",n_step,"_pe",iProc,file_extension
     end if
     ! Open file
     if(save_binary .and. plot_form(ifile)=='idl')then
        open(unit_tmp,file=filename,status="replace",err=999,&
             form="unformatted")
     else
        open(unit_tmp,file=filename,status="replace",err=999)
     end if
  end if

  if (index(plot_type1,'sph')>0) then
     ntheta = 1 + 180.0/plot_dx(2,ifile)
     nphi   = 360.0/plot_dx(3,ifile)
     rplot  = plot_range(1,ifile)
     if(oktest_me) then
        write(*,*) ntheta,nphi
     end if
  end if

  !! START IDL
  ! define from values used in the plotting, so that they don't
  ! have to be done inside the loop
  xmin=plot_range(1,ifile)
  xmax=plot_range(2,ifile)
  ymin=plot_range(3,ifile)
  ymax=plot_range(4,ifile)
  zmin=plot_range(5,ifile)
  zmax=plot_range(6,ifile)

  dxPEmin(:)=XyzMax_D(:)-XyzMin_D(:)

  dxblk=XyzMax_D(1)-XyzMin_D(1)
  dyblk=XyzMax_D(2)-XyzMin_D(2)
  dzblk=XyzMax_D(3)-XyzMin_D(3)
  nPEcells=0; nPEcellsN=0; nPEcellsS=0
  nBLKcells=0; nBLKcellsN=0; nBLKcellsS=0
  !! END IDL

  ! Get the headers that contain variables names and units
  select case(plot_form(ifile))
  case('tec')
     call get_tec_variables(ifile,nplotvar,plotvarnames,unitstr_TEC)
     if(oktest .and. iProc==0) write(*,*)unitstr_TEC
  case('idl')
     call get_idl_units(ifile,nplotvar,plotvarnames,unitstr_IDL)
     if(oktest .and. iProc==0) write(*,*)unitstr_IDL
  end select

  ! Compute the plot variables and write them to the disk
  do iBLK=1,nBlockMax
     if(unusedBLK(iBLK))CYCLE

     call set_plotvar(iBLK, &
          ifile-plot_,nplotvar,plotvarnames,plotvar,plotvar_inBody,plotvar_useBody)
     if (plot_dimensional(ifile)) call dimensionalize_plotvar(iBLK, &
          ifile-plot_,nplotvar,plotvarnames,plotvar,plotvar_inBody)

     if (index(plot_type1,'sph')>0) then
        call write_plot_sph(ifile,iBLK,nplotvar,plotvar, &
             ntheta,nphi,rplot,nBLKcellsN,nBLKcellsS)
   	dxblk=1.0
   	dyblk=180.0/real(ntheta-1)
   	dzblk=360.0/real(nphi)
     else
        select case(plot_form(ifile))
        case('tec')
           call plotvar_to_plotvarnodes
        case('idl')
           call write_plot_idl(ifile,iBLK,nplotvar,plotvar, &
                xmin,xmax,ymin,ymax,zmin,zmax, &
                dxblk,dyblk,dzblk,nBLKcells)
        end select
     end if

     if (plot_form(ifile)=='idl') then
   	! Update number of cells per processor
        if (.not. (index(plot_type1,'sph')>0)) then
      	   nPEcells = nPEcells + nBLKcells
        else
      	   nPEcellsN = nPEcellsN + nBLKcellsN
      	   nPEcellsS = nPEcellsS + nBLKcellsS
        end if

   	! Find smallest cell size in the plotting region
   	dxPEmin(1)=min(dxPEmin(1),dxblk)
   	dxPEmin(2)=min(dxPEmin(2),dyblk)
   	dxPEmin(3)=min(dxPEmin(3),dzblk)
     end if

  end do ! iBLK

  ! Write files for new tecplot format
  if(plot_form(ifile)=='tec' .and. .NOT.(index(plot_type1,'sph')>0) )then
     do i=1,nplotvar
        NodeValue_IIIB=plotvarnodes(:,:,:,:,i)
        call pass_and_average_nodes(.true.,NodeValue_IIIB)
        plotvarnodes(:,:,:,:,i)=NodeValue_IIIB
     end do
     call write_plot_tec(ifile,nplotvar,PlotVarNodes,unitstr_TEC, &
          xmin,xmax,ymin,ymax,zmin,zmax)
     deallocate(PlotVarNodes)
  end if

  close(unit_tmp)
  if( (index(plot_type1,'sph')>0) .or. plot_form(ifile)=='tec' )then
     close(unit_tmp2)
  end if

  !! START IDL
  if (plot_form(ifile)=='idl')then
     ! Find smallest cell size and total number of cells
     if (.not. (index(plot_type1,'sph')>0)) then
        call MPI_reduce(dxPEmin,dxGLOBALmin,3,MPI_REAL,MPI_MIN,0,iComm,iError)
        call MPI_reduce(nPEcells,nGLOBALcells,1,MPI_INTEGER,MPI_SUM,0,iComm,iError)
     else
        call MPI_reduce(nPEcellsN,nGLOBALcellsN,1,MPI_INTEGER,MPI_SUM,0,iComm,iError)
        call MPI_reduce(nPEcellsS,nGLOBALcellsS,1,MPI_INTEGER,MPI_SUM,0,iComm,iError)
        dxGLOBALmin = dxPEmin
     end if

     if(oktest_me) then
        if (.not. (index(plot_type1,'sph')>0)) then
           write(*,*)'dxPEmin,nPEcells=',dxPEmin,nPEcells
        else
           write(*,*)'North: nGLOBALcells=',nGLOBALcellsN
           write(*,*)'South: nGLOBALcells=',nGLOBALcellsS
        end if
     end if
  end if
  !! END IDL

  ! write header file
  if(iProc==0)then

     select case(plot_form(ifile))
     case('tec')
        if (index(plot_type1,'sph')>0) then
           file_extension='.S'
        else  
           file_extension='.T'
        end if
     case('idl')
        file_extension='.h'
     end select

     if (ifile-plot_ > 9) then
        file_format='("' // trim(NamePlotDir) // '",a,i2,a,i7.7,a)'
     else
        file_format='("' // trim(NamePlotDir) // '",a,i1,a,i7.7,a)'
     end if

     do i=1,2
        
        !For spherical plots there is a north and south files
        !For other cases, cycle when i=2.  This saves a lot of 
        !double coding.
        if (.not.(index(plot_type1,'sph')>0) .and. i==2) CYCLE

        if(index(plot_type1,'sph')>0)then
           if (i==1) then
              NorthOrSouth='N'   ! do the northern hemisphere
              nGLOBALcells = nGLOBALcellsN
           else
              NorthOrSouth='S'   ! do the southern hemisphere
              nGLOBALcells = nGLOBALcellsS
           end if
           if(time_accurate) then
              write(filename,file_format) &
                   plot_type1(1:2)//NorthOrSouth// &
                   plot_type1(4:len_trim(plot_type1))//"_",&
                   ifile-plot_,"_t"//StringTimeH4M2S2//"_n",&
                   n_step,file_extension
           else
              write(filename,file_format) &
                   plot_type1(1:2)//NorthOrSouth// &
                   plot_type1(4:len_trim(plot_type1))//"_",&
                   ifile-plot_,"_n",n_step,file_extension
           end if
        elseif(plot_form(ifile)=='tec')then
           if(time_accurate)then
              call get_time_string
              write(filename,file_format) &
                   trim(plot_type1)//"_",&
                   ifile-plot_,"_t"//StringTimeH4M2S2//"_n",&
                   n_step,file_extension
           else
              write(filename,file_format) &
                   trim(plot_type1)//"_",&
                   ifile-plot_,"_n",n_step,file_extension
           end if
        else
           if(time_accurate)then
              call get_time_string
              write(filename,file_format) &
                   trim(plot_type1)//"_",&
                   ifile-plot_,"_t"//StringTimeH4M2S2//"_n",&
                   n_step,file_extension
           else
              write(filename,file_format) &
                   trim(plot_type1)//"_",&
                   ifile-plot_,"_n",n_step,file_extension
           end if
        end if
        open(unit_tmp,file=filename,status="replace",err=999)

        write(unit_tmp,'(a)')filename
        write(unit_tmp,'(i8,a)')nProc,' nProc'
        write(unit_tmp,'(i8,a)')n_step,' n_step'
        write(unit_tmp,'(1pe13.5,a)')time_simulation,' t'
        select case(plot_form(ifile))
        case('tec')
           write(unit_tmp,'(a)')trim(unitstr_TEC)
           if(index(plot_type1,'sph')>0)  &
                write(unit_tmp,'(2(1pe13.5),a)') plot_dx(2:3,ifile),' plot_dx'
           call get_date_time(iTime_I)
           write(unit_tmp,*) iTime_I(1:7),' year mo dy hr mn sc msc'        
           write(unit_tmp,'(2(1pe13.5),a)') thetaTilt*180.0/cPi, 0.0,  &
                                            ' thetatilt[deg] phitilt[deg]'
        case('idl')
           if(plot_dimensional(ifile)) then
              write(unit_tmp,'(6(1pe13.5),a)')plot_range(:,ifile)*unitUSER_x,' plot_range'
              write(unit_tmp,'(6(1pe13.5),i8,a)') &
                   plot_dx(:,ifile)*unitUSER_x,dxGLOBALmin*unitUSER_x,nGLOBALcells,&
                   ' plot_dx, dxmin, ncell'
           else
              write(unit_tmp,'(6(1pe13.5),a)')plot_range(:,ifile),' plot_range'
              write(unit_tmp,'(6(1pe13.5),i8,a)') &
                   plot_dx(:,ifile),dxGLOBALmin,nGLOBALcells,&
                   ' plot_dx, dxmin, ncell'
           end if
           write(unit_tmp,'(i8,a)')nplotvar  ,' nplotvar'
           write(unit_tmp,'(i8,a)')neqpar,' neqpar'
           write(unit_tmp,'(10(1pe13.5))')eqpar(1:neqpar)
           write(unit_tmp,'(a)')allnames
           write(unit_tmp,'(a)')trim(unitstr_IDL)
           write(unit_tmp,'(l8,a)')save_binary,' save_binary'
           if(save_binary)write(unit_tmp,'(i8,a)')nByteReal,' nByteReal'
           write(unit_tmp,'(a)')TypeGeometry             !^CFG IF NOT CARTESIAN
        end select
        if (index(plot_type1,'sph')>0) then
           write(unit_tmp,'(1pe13.5,a)')rplot,' rplot'
           if (i==1) then
              write(unit_tmp,'(a)')'Northern Hemisphere'
           else 
              write(unit_tmp,'(a)')'Southern Hemisphere'
           end if
        end if
        close(unit_tmp)
     end do
  end if


  if(oktest_me)write(*,*)'write_plot_common finished'

  return

999 continue

  call stop_mpi("Error in opening or writing file in write_plot_common")

Contains

  subroutine plotvar_to_plotvarnodes
    integer :: ii,jj,kk
    integer, dimension(-1:nI+1, -1:nJ+1, -1:nK+1, nplotvarmax) :: nodeCount
    real,    dimension(-1:nI+1, -1:nJ+1, -1:nK+1, nplotvarmax) :: nodeV
    real :: rr

    if(.not.allocated(PlotVarNodes)) allocate(&
         PlotVarNodes(0:nI,0:nJ,0:nK,nBLK,nplotvarmax),stat=iError)
    call alloc_check(iError,'write_plot_common:PlotVarNodes')

    ! Initialize values
    nodeCount = 0; nodeV(:,:,:,:) = 0.00

    do k=0,nK+1; do j=0,nJ+1; do i=0,nI+1  ! Cell loop
       do iVar=1,nplotvar
          if ( true_cell(i,j,k,iBLK) .or. plotvar_useBody(iVar) )then
             do kk=-1,0; do jj=-1,0; do ii=-1,0
                nodeCount(i+ii,j+jj,k+kk,iVar) = nodeCount(i+ii,j+jj,k+kk,iVar) +1
                nodeV(i+ii,j+jj,k+kk,iVar) = nodeV(i+ii,j+jj,k+kk,iVar)+ &
                     plotvar(i,j,k,iVar)
             end do; end do; end do
          end if
       end do
    end do; end do; end do

    do k=0,nK; do j=0,nJ; do i=0,nI  ! Node loop
       rr=sqrt( &
            NodeX_IIIB(i,j,k,iBLK)**2+ &
            NodeY_IIIB(i,j,k,iBLK)**2+ &
            NodeZ_IIIB(i,j,k,iBLK)**2)
       do iVar=1,nplotvar
          if (nodeCount(i,j,k,iVar) > 0) then
             PlotVarNodes(i,j,k,iBLK,iVar) = &
                  nodeV(i,j,k,iVar)/real(nodeCount(i,j,k,iVar))
             ! This will zero out values otherwise true with plotvar_useBody
             ! The intent of plotvar_useBody is to fill nodes inside of the body
             !   with values for plotting.  However, when allowed to go all the
             !   way to the origin, B traces will continuously loop through the
             !   body and out.  Setting the values to zero inside of 0.51 fixes it.
             if(plotvar_useBody(iVar))then
                if(rr < 0.51*Rbody .and. rr < 0.51) then
                   PlotVarNodes(i,j,k,iBLK,iVar) = 0.00
                end if
             end if
          else
             PlotVarNodes(i,j,k,iBLK,iVar) = plotvar_inBody(iVar)
          end if
       end do
    end do; end do; end do

  end subroutine plotvar_to_plotvarnodes

end subroutine write_plot_common

!==============================================================================
subroutine set_eqpar(iplotfile,neqpar,eqparnames,eqpar)

  use ModProcMH
  use ModPhysics, ONLY : g,cLIGHT,rBody,unitUSER_U,unitUSER_x,unitUSER_rho
  use ModRaytrace, ONLY : R_raytrace                !^CFG  IF RAYTRACE
  use ModIO

  implicit none
  integer, intent(in)      :: iplotfile,neqpar
  character*10, intent(in) :: eqparnames(neqpar)
  real, intent(out)        :: eqpar(neqpar)

  integer :: ipar
  !---------------------------------------------------------------------------
  do ipar=1,neqpar
     select case(eqparnames(ipar))
     case('g')
        eqpar(ipar)=g
     case('c')
        if(plot_dimensional(plot_+iplotfile)) then
           eqpar(ipar)=cLIGHT*unitUSER_U
        else
           eqpar(ipar)=cLIGHT
        end if
     case('rbody','rBody','RBODY')
        eqpar(ipar)=rBody
        if(plot_dimensional(plot_+iplotfile))&
             eqpar(ipar)=eqpar(ipar)*unitUSER_x
     case('eta')
        eqpar(ipar)=0.
     case('unitx')
        eqpar(ipar)=unitUSER_x
     case('unitn','unitrho')
        eqpar(ipar)=unitUSER_rho
     case('unitv')
        eqpar(ipar)=unitUSER_U
     case('mu')
        eqpar(ipar)=mu_los
!!$!^CFG  IF RAYTRACE BEGIN
     case('R_ray')
        eqpar(ipar)=R_raytrace
!!$!^CFG END RAYTRACE
     case default
        eqpar(ipar)=-7777.
        if(iProc==0)write(*,*)'Error in set_eqpar: unknown eqparname=',&
             eqparnames(ipar),' for iplotfile=',iplotfile
     end select
  end do

end subroutine set_EqPar

!==============================================================================
subroutine set_plotvar(iBLK,iplotfile,nplotvar,plotvarnames,plotvar,&
     plotvar_inBody,plotvar_useBody)

  use ModProcMH
  use ModMain
  use ModVarIndexes
  use ModAdvance, ONLY : time_BLK,B0xCell_BLK,B0yCell_BLK,B0zCell_BLK, &
       State_VGB,E_BLK, DivB1_GB, IsConserv_CB, UseNonconservative, &
       Ex_CB, Ey_CB, Ez_CB
  use ModGeometry
  use ModParallel, ONLY : BLKneighborCHILD
  use ModImplicit, ONLY : implicitBLK                      !^CFG IF IMPLICIT
  use ModPhysics, ONLY : Body_rho,Body_p,OMEGAbody,CellState_VI
  use ModCT, ONLY : Bxface_BLK,Byface_BLK,Bzface_BLK       !^CFG IF CONSTRAINB
  use ModRayTrace, ONLY : ray,rayface                      !^CFG  IF RAYTRACE
  implicit none

  integer, intent(in) :: iBLK,iPlotFile,Nplotvar
  character (LEN=10), intent(in) :: plotvarnames(Nplotvar)
  real, intent(inout) :: plotVar(-1:nI+2,-1:nJ+2,-1:nK+2,nPlotVar)
  real, intent(out)   :: plotvar_inBody(nPlotVar)
  logical, intent(out) :: plotvar_useBody(nPlotVar)
  character (len=10)  :: s

  real, dimension(-1:nI+2,-1:nJ+2,-1:nK+2) :: tmp1Var, tmp2Var

  integer :: iVar,itmp,jtmp, jVar
  integer :: i,j,k, ip1,im1,jp1,jm1,kp1,km1
  real :: xfactor,yfactor,zfactor
  !-------------------------------------------------------------------------

  do iVar = 1, nPlotVar
     s = plotvarnames(iVar)
!!! call lower_case(s)

     ! Set plotvar_inBody to something reasonable for inside the body.
     ! Load zeros (0) for most values - load something better for rho, p, and T.
     ! We know that U,B,J are okay with zeroes, others should be changed if
     ! necessary.  Note that all variables not set to 0 should be loaded below.  
     ! Note that this is used for tecplot corner extrapolation and for nothing
     ! else.
     plotvar_inBody(iVar) = 0.0

     ! Set plotvar_useBody to false unless cell values inside of the body are
     ! to be used for plotting.
     plotvar_useBody(iVar) = .false.

     select case(s)

        ! BASIC MHD variables
     case('rho')
        PlotVar(:,:,:,iVar)=State_VGB(rho_,:,:,:,iBLK)
        plotvar_inBody(iVar) = Body_rho
     case('rhoUx','rhoux','mx')
        if (UseRotatingFrame) then
           PlotVar(:,:,:,iVar)=State_VGB(rhoUx_,:,:,:,iBLK) &
                - State_VGB(rho_,:,:,:,iBLK)*OMEGAbody*y_BLK(:,:,:,iBLK)
        else
           PlotVar(:,:,:,iVar)=State_VGB(rhoUx_,:,:,:,iBLK)
        end if
     case('rhoUy','rhouy','my')
        if (UseRotatingFrame) then
           PlotVar(:,:,:,iVar)=State_VGB(rhoUy_,:,:,:,iBLK) &
                + State_VGB(rho_,:,:,:,iBLK)*OMEGAbody*x_BLK(:,:,:,iBLK)
        else
           PlotVar(:,:,:,iVar)=State_VGB(rhoUy_,:,:,:,iBLK)
        end if
     case('rhoUz','rhouz','mz')
        PlotVar(:,:,:,iVar)=State_VGB(rhoUz_,:,:,:,iBLK)
     case('Bx','bx')
        plotvar_useBody(iVar) = NameThisComp/='SC'
        PlotVar(:,:,:,iVar)=State_VGB(Bx_,:,:,:,iBLK)+B0xCell_BLK(:,:,:,iBLK)
     case('By','by')
        plotvar_useBody(iVar) = NameThisComp/='SC'
        PlotVar(:,:,:,iVar)=State_VGB(By_,:,:,:,iBLK)+B0yCell_BLK(:,:,:,iBLK)
     case('Bz','bz')
        plotvar_useBody(iVar) = NameThisComp/='SC'
        PlotVar(:,:,:,iVar)=State_VGB(Bz_,:,:,:,iBLK)+B0zCell_BLK(:,:,:,iBLK)

     case('BxL','bxl')                           !^CFG IF CONSTRAINB BEGIN
        PlotVar(1:nI,1:nJ,1:nK,iVar)=BxFace_BLK(1:nI,1:nJ,1:nK,iBLK)
     case('BxR','bxr')
        PlotVar(1:nI,1:nJ,1:nK,iVar)=BxFace_BLK(2:nI+1,1:nJ,1:nK,iBLK)
     case('ByL','byl')
        PlotVar(1:nI,1:nJ,1:nK,iVar)=ByFace_BLK(1:nI,1:nJ,1:nK,iBLK)
     case('ByR','byr')
        PlotVar(1:nI,1:nJ,1:nK,iVar)=ByFace_BLK(1:nI,2:nJ+1,1:nK,iBLK)
     case('BzL','bzl')
        PlotVar(1:nI,1:nJ,1:nK,iVar)=BzFace_BLK(1:nI,1:nJ,1:nK,iBLK)
     case('BzR','bzr')
        PlotVar(1:nI,1:nJ,1:nK,iVar)=BzFace_BLK(1:nI,1:nJ,2:nK+1,iBLK)
        !                                        !^CFG END CONSTRAINB
     case('E','e')
        PlotVar(:,:,:,iVar)=E_BLK(:,:,:,iBLK)+0.5*(&
             (State_VGB(Bx_,:,:,:,iBLK)+B0xCell_BLK(:,:,:,iBLK))**2+&
             (State_VGB(By_,:,:,:,iBLK)+B0yCell_BLK(:,:,:,iBLK))**2+&
             (State_VGB(Bz_,:,:,:,iBLK)+B0zCell_BLK(:,:,:,iBLK))**2 &
             -State_VGB(Bx_,:,:,:,iBLK)**2 &
             -State_VGB(By_,:,:,:,iBLK)**2 &
             -State_VGB(Bz_,:,:,:,iBLK)**2)
     case('P','p','Pth','pth')
        PlotVar(:,:,:,iVar) = State_VGB(P_,:,:,:,iBLK)
        plotvar_inBody(iVar) = Body_p
!^CFG IF ALWAVES BEGIN
     case('Ew','ew')
!        PlotVar(:,:,:,iVar)=State_VGB(EnergyRL_,:,:,:,iBLK) !^CFG UNCOMMENT IF ALWAVES
!^CFG END ALWAVES

        ! EXTRA MHD variables

     case('Ux','ux')
        if (UseRotatingFrame) then
           PlotVar(:,:,:,iVar)=State_VGB(rhoUx_,:,:,:,iBLK)/State_VGB(rho_,:,:,:,iBLK) &
                - OMEGAbody*y_BLK(:,:,:,iBLK)
        else
           PlotVar(:,:,:,iVar)=State_VGB(rhoUx_,:,:,:,iBLK)/State_VGB(rho_,:,:,:,iBLK)
        end if
     case('Uy','uy')
        if (UseRotatingFrame) then
           PlotVar(:,:,:,iVar)=State_VGB(rhoUy_,:,:,:,iBLK)/State_VGB(rho_,:,:,:,iBLK) &
                + OMEGAbody*x_BLK(:,:,:,iBLK)
        else
           PlotVar(:,:,:,iVar) = &
                State_VGB(rhoUy_,:,:,:,iBLK) / State_VGB(rho_,:,:,:,iBLK)
        end if
     case('Uz','uz')
        PlotVar(:,:,:,iVar) = &
             State_VGB(rhoUz_,:,:,:,iBLK) / State_VGB(rho_,:,:,:,iBLK)
     case('B1x','b1x')
        PlotVar(:,:,:,iVar)=State_VGB(Bx_,:,:,:,iBLK)
     case('B1y','b1y')
        PlotVar(:,:,:,iVar)=State_VGB(By_,:,:,:,iBLK)
     case('B1z','b1z')
        PlotVar(:,:,:,iVar)=State_VGB(Bz_,:,:,:,iBLK)
     case('Jx','jx')
!^CFG IF CARTESIAN BEGIN
        if(true_BLK(iBLK))then
           PlotVar(0:nI+1,0:nJ+1,0:nK+1,iVar)=0.5*(&
                (State_VGB(Bz_, 0:nI+1, 1:nJ+2, 0:nK+1,iBLK) &
                -State_VGB(Bz_, 0:nI+1,-1:nJ  , 0:nK+1,iBLK)) / dy_BLK(iBLK) - &
                (State_VGB(By_, 0:nI+1, 0:nJ+1, 1:nK+2,iBLK) &
                -State_VGB(By_, 0:nI+1, 0:nJ+1,-1:nK  ,iBLK)) / dz_BLK(iBLK))
        else
           do k=0,nK+1; do j=0,nJ+1; do i=0,nI+1  ! Cell loop
              if( .not.true_cell(i,j,k,iBLK) ) CYCLE

              ip1=i+1; im1=i-1; jp1=j+1; jm1=j-1; kp1=k+1; km1=k-1
              if(.not.true_cell(ip1,j,k,iBLK)) ip1=i
              if(.not.true_cell(im1,j,k,iBLK)) im1=i
              if(.not.true_cell(i,jp1,k,iBLK)) jp1=j
              if(.not.true_cell(i,jm1,k,iBLK)) jm1=j
              if(.not.true_cell(i,j,kp1,iBLK)) kp1=k
              if(.not.true_cell(i,j,km1,iBLK)) km1=k
              if(ip1==im1 .or. jp1==jm1 .or. kp1==km1) CYCLE

              xfactor=1.; yfactor=1.; zfactor=1.
              if((ip1-im1)==1) xfactor=2.
              if((jp1-jm1)==1) yfactor=2.
              if((kp1-km1)==1) zfactor=2.

              PlotVar(i,j,k,iVar)=0.5*(&
                   (State_VGB(Bz_,i  ,jp1,k  ,iBLK) &
                   -State_VGB(Bz_,i  ,jm1,k  ,iBLK))*yfactor / dy_BLK(iBLK) - &
                   (State_VGB(By_,i  ,j  ,kp1,iBLK) &
                   -State_VGB(By_,i  ,j  ,km1,iBLK))*zfactor / dz_BLK(iBLK))
           end do; end do; end do
        end if
!^CFG END CARTESIAN
!       call covar_curlb_plotvar(x_,iBLK,PlotVar(:,:,:,iVar))  !^CFG IF NOT CARTESIAN         
     case('Jy','jy')
!^CFG IF CARTESIAN BEGIN
        if(true_BLK(iBLK))then
           PlotVar(0:nI+1,0:nJ+1,0:nK+1,iVar)=0.5*(&
                (State_VGB(Bx_, 0:nI+1, 0:nJ+1, 1:nK+2,iBLK) &
                -State_VGB(Bx_, 0:nI+1, 0:nJ+1,-1:nK  ,iBLK)) / dz_BLK(iBLK) - &
                (State_VGB(Bz_, 1:nI+2, 0:nJ+1, 0:nK+1,iBLK) &
                -State_VGB(Bz_,-1:nI  , 0:nJ+1, 0:nK+1,iBLK)) / dx_BLK(iBLK))
        else
           do k=0,nK+1; do j=0,nJ+1; do i=0,nI+1  ! Cell loop
              if( .not.true_cell(i,j,k,iBLK) ) CYCLE

              ip1=i+1; im1=i-1; jp1=j+1; jm1=j-1; kp1=k+1; km1=k-1
              if(.not.true_cell(ip1,j,k,iBLK)) ip1=i
              if(.not.true_cell(im1,j,k,iBLK)) im1=i
              if(.not.true_cell(i,jp1,k,iBLK)) jp1=j
              if(.not.true_cell(i,jm1,k,iBLK)) jm1=j
              if(.not.true_cell(i,j,kp1,iBLK)) kp1=k
              if(.not.true_cell(i,j,km1,iBLK)) km1=k
              if(ip1==im1 .or. jp1==jm1 .or. kp1==km1) CYCLE

              xfactor=1.; yfactor=1.; zfactor=1.
              if((ip1-im1)==1) xfactor=2.
              if((jp1-jm1)==1) yfactor=2.
              if((kp1-km1)==1) zfactor=2.

              PlotVar(i,j,k,iVar)=0.5*(&
                   (State_VGB(Bx_,i  ,j  ,kp1,iBLK) &
                   -State_VGB(Bx_,i  ,j  ,km1,iBLK))*zfactor / dz_BLK(iBLK) - &
                   (State_VGB(Bz_,ip1,j  ,k  ,iBLK) &
                   -State_VGB(Bz_,im1,j  ,k  ,iBLK))*xfactor / dx_BLK(iBLK))
           end do; end do; end do
        endif
!^CFG END CARTESIAN
!       call covar_curlb_plotvar(y_,iBLK,PlotVar(:,:,:,iVar))  !^CFG IF NOT CARTESIAN  
     case('Jz','jz')
!^CFG IF CARTESIAN BEGIN
        if(true_BLK(iBLK))then
           PlotVar(0:nI+1,0:nJ+1,0:nK+1,iVar)=0.5*(&
                (State_VGB(By_, 1:nI+2,0:nJ+1,0:nK+1,iBLK) &
                -State_VGB(By_,-1:nI  ,0:nJ+1,0:nK+1,iBLK)) / dx_BLK(iBLK) - &
                (State_VGB(Bx_,0:nI+1, 1:nJ+2,0:nK+1,iBLK) &
                -State_VGB(Bx_,0:nI+1,-1:nJ  ,0:nK+1,iBLK)) / dy_BLK(iBLK))
        else
           do k=0,nK+1; do j=0,nJ+1; do i=0,nI+1  ! Cell loop
              if( .not.true_cell(i,j,k,iBLK) ) CYCLE

              ip1=i+1; im1=i-1; jp1=j+1; jm1=j-1; kp1=k+1; km1=k-1
              if(.not.true_cell(ip1,j,k,iBLK)) ip1=i
              if(.not.true_cell(im1,j,k,iBLK)) im1=i
              if(.not.true_cell(i,jp1,k,iBLK)) jp1=j
              if(.not.true_cell(i,jm1,k,iBLK)) jm1=j
              if(.not.true_cell(i,j,kp1,iBLK)) kp1=k
              if(.not.true_cell(i,j,km1,iBLK)) km1=k
              if(ip1==im1 .or. jp1==jm1 .or. kp1==km1) CYCLE

              xfactor=1.; yfactor=1.; zfactor=1.
              if((ip1-im1)==1) xfactor=2.
              if((jp1-jm1)==1) yfactor=2.
              if((kp1-km1)==1) zfactor=2.

              PlotVar(i,j,k,iVar)=0.5*(&
                   (State_VGB(By_,ip1,j  ,k  ,iBLK) &
                   -State_VGB(By_,im1,j  ,k  ,iBLK))*xfactor / dx_BLK(iBLK) - &
                   (State_VGB(Bx_,i  ,jp1,k  ,iBLK) &
                   -State_VGB(Bx_,i  ,jm1,k  ,iBLK))*yfactor / dy_BLK(iBLK))
           end do; end do; end do
        end if
!^CFG END CARTESIAN
!       call covar_curlb_plotvar(z_,iBLK,PlotVar(:,:,:,iVar))  !^CFG IF NOT CARTESIAN  
     case('enumx')
        PlotVar(1:nI,1:nJ,1:nK,iVar)= Ex_CB(:,:,:,iBLK)
     case('enumy')
        PlotVar(1:nI,1:nJ,1:nK,iVar)= Ey_CB(:,:,:,iBLK)
     case('enumz')
        PlotVar(1:nI,1:nJ,1:nK,iVar)= Ez_CB(:,:,:,iBLK)
     case('ex','Ex','EX')
        PlotVar(:,:,:,iVar)= &
             ( State_VGB(rhoUz_,:,:,:,iBLK) &
             * ( State_VGB(By_,:,:,:,iBLK) + B0yCell_BLK(:,:,:,iBLK)) &
             - State_VGB(rhoUy_,:,:,:,iBLK) &
             * ( State_VGB(Bz_,:,:,:,iBLK) + B0zCell_BLK(:,:,:,iBLK)) &
             ) / State_VGB(rho_,:,:,:,iBLK) 
     case('ey','Ey','EY')
        PlotVar(:,:,:,iVar)= ( State_VGB(rhoUx_,:,:,:,iBLK)* &
             (State_VGB(Bz_,:,:,:,iBLK)+B0zCell_BLK(:,:,:,iBLK)) &
             -State_VGB(rhoUz_,:,:,:,iBLK)* &
             (State_VGB(Bx_,:,:,:,iBLK)+B0xCell_BLK(:,:,:,iBLK)))/ &
             State_VGB(rho_,:,:,:,iBLK) 
     case('ez','Ez','EZ')
        PlotVar(:,:,:,iVar)= ( State_VGB(rhoUy_,:,:,:,iBLK)* &
             (State_VGB(Bx_,:,:,:,iBLK)+B0xCell_BLK(:,:,:,iBLK)) &
             -State_VGB(rhoUx_,:,:,:,iBLK)* &
             (State_VGB(By_,:,:,:,iBLK)+B0yCell_BLK(:,:,:,iBLK)))/ &
             State_VGB(rho_,:,:,:,iBLK) 
     case('pvecx','Pvecx','PvecX','pvecX','PVecX','PVECX')
        PlotVar(:,:,:,iVar) = ( &
             ( (State_VGB(Bx_,:,:,:,iBLK)+ B0xCell_BLK(:,:,:,iBLK))**2  &
             + (State_VGB(By_,:,:,:,iBLK)+ B0yCell_BLK(:,:,:,iBLK))**2  &
             + (State_VGB(Bz_,:,:,:,iBLK)+ B0zCell_BLK(:,:,:,iBLK))**2) * &
             State_VGB(rhoUx_,:,:,:,iBLK) &
             -((State_VGB(Bx_,:,:,:,iBLK)+B0xCell_BLK(:,:,:,iBLK))* &
             State_VGB(rhoUx_,:,:,:,iBLK) + &
             (State_VGB(By_,:,:,:,iBLK)+B0yCell_BLK(:,:,:,iBLK))* &
             State_VGB(rhoUy_,:,:,:,iBLK) + &
             (State_VGB(Bz_,:,:,:,iBLK)+B0zCell_BLK(:,:,:,iBLK))* &
             State_VGB(rhoUz_,:,:,:,iBLK)) * &
             (State_VGB(Bx_,:,:,:,iBLK)+B0xCell_BLK(:,:,:,iBLK) ) )/State_VGB(rho_,:,:,:,iBLK)
     case('pvecy','Pvecy','PvecY','pvecY','PVecY','PVECY')
        PlotVar(:,:,:,iVar) = ( ((State_VGB(Bx_,:,:,:,iBLK)+ B0xCell_BLK(:,:,:,iBLK))**2 + &
             (State_VGB(By_,:,:,:,iBLK)+ B0yCell_BLK(:,:,:,iBLK))**2 + &
             (State_VGB(Bz_,:,:,:,iBLK)+ B0zCell_BLK(:,:,:,iBLK))**2) * &
             State_VGB(rhoUy_,:,:,:,iBLK) &
             -((State_VGB(Bx_,:,:,:,iBLK)+B0xCell_BLK(:,:,:,iBLK))* &
             State_VGB(rhoUx_,:,:,:,iBLK) + &
             (State_VGB(By_,:,:,:,iBLK)+B0yCell_BLK(:,:,:,iBLK))* &
             State_VGB(rhoUy_,:,:,:,iBLK) + &
             (State_VGB(Bz_,:,:,:,iBLK)+B0zCell_BLK(:,:,:,iBLK))* &
             State_VGB(rhoUz_,:,:,:,iBLK)) * &
             (State_VGB(By_,:,:,:,iBLK)+B0yCell_BLK(:,:,:,iBLK) ) )/State_VGB(rho_,:,:,:,iBLK)
     case('pvecz','Pvecz','PvecZ','pvecZ','PVecZ','PVECZ')
        PlotVar(:,:,:,iVar) = ( ((State_VGB(Bx_,:,:,:,iBLK)+ B0xCell_BLK(:,:,:,iBLK))**2 + &
             (State_VGB(By_,:,:,:,iBLK)+ B0yCell_BLK(:,:,:,iBLK))**2 + &
             (State_VGB(Bz_,:,:,:,iBLK)+ B0zCell_BLK(:,:,:,iBLK))**2) * &
             State_VGB(rhoUz_,:,:,:,iBLK) &
             -((State_VGB(Bx_,:,:,:,iBLK)+B0xCell_BLK(:,:,:,iBLK))* &
             State_VGB(rhoUx_,:,:,:,iBLK) + &
             (State_VGB(By_,:,:,:,iBLK)+B0yCell_BLK(:,:,:,iBLK))* &
             State_VGB(rhoUy_,:,:,:,iBLK) + &
             (State_VGB(Bz_,:,:,:,iBLK)+B0zCell_BLK(:,:,:,iBLK))* &
             State_VGB(rhoUz_,:,:,:,iBLK)) * &
             (State_VGB(Bz_,:,:,:,iBLK)+B0zCell_BLK(:,:,:,iBLK) ) )/State_VGB(rho_,:,:,:,iBLK)

        ! Radial component variables

     case('Ur','ur')
        PlotVar(:,:,:,iVar) = &
             ( State_VGB(rhoUx_,:,:,:,iBLK)*x_BLK(:,:,:,iBLK) & 
             + State_VGB(rhoUy_,:,:,:,iBLK)*y_BLK(:,:,:,iBLK) & 
             + State_VGB(rhoUz_,:,:,:,iBLK)*z_BLK(:,:,:,iBLK) &
             ) / (State_VGB(rho_,:,:,:,iBLK)*R_BLK(:,:,:,iBLK))
     case('rhoUr','rhour','mr')
        PlotVar(:,:,:,iVar) = &
             ( State_VGB(rhoUx_,:,:,:,iBLK)*x_BLK(:,:,:,iBLK) & 
             + State_VGB(rhoUy_,:,:,:,iBLK)*y_BLK(:,:,:,iBLK) & 
             + State_VGB(rhoUz_,:,:,:,iBLK)*z_BLK(:,:,:,iBLK) &
             ) / R_BLK(:,:,:,iBLK)
     case('Br','br')
        plotvar_useBody(iVar) = .true.
        PlotVar(:,:,:,iVar)=( &
             ( State_VGB(Bx_,:,:,:,iBLK)+B0xCell_BLK(:,:,:,iBLK)) &
             *X_BLK(:,:,:,iBLK)                         &  
             +(State_VGB(By_,:,:,:,iBLK)+B0yCell_BLK(:,:,:,iBLK)) &
             *Y_BLK(:,:,:,iBLK)                         &
             +(State_VGB(Bz_,:,:,:,iBLK)+B0zCell_BLK(:,:,:,iBLK)) &
             *Z_BLK(:,:,:,iBLK) ) / R_BLK(:,:,:,iBLK) 
     case('B1r','b1r')
        PlotVar(:,:,:,iVar)= &
             ( State_VGB(Bx_,:,:,:,iBLK)*x_BLK(:,:,:,iBLK) &
             + State_VGB(By_,:,:,:,iBLK)*y_BLK(:,:,:,iBLK) &
             + State_VGB(Bz_,:,:,:,iBLK)*z_BLK(:,:,:,iBLK) &
             ) / R_BLK(:,:,:,iBLK)                                 
     case('Jr','jr')
!^CFG IF CARTESIAN BEGIN
        PlotVar(0:nI+1,0:nJ+1,0:nK+1,iVar) = &
             0.5 / R_BLK(0:nI+1,0:nJ+1,0:nK+1,iBLK) * &
             ( ( &
             ( State_VGB(Bz_,0:nI+1, 1:nJ+2, 0:nK+1,iBLK) & 
             - State_VGB(Bz_,0:nI+1,-1:nJ  , 0:nK+1,iBLK)) / dy_BLK(iBLK) - &
             ( State_VGB(By_,0:nI+1, 0:nJ+1, 1:nK+2,iBLK) &
             - State_VGB(By_,0:nI+1, 0:nJ+1,-1:nK  ,iBLK)) / dz_BLK(iBLK)   &
             ) * x_BLK(0:nI+1,0:nJ+1,0:nK+1,iBLK) &
             + ( &
             ( State_VGB(Bx_, 0:nI+1,0:nJ+1, 1:nK+2,iBLK) &
             - State_VGB(Bx_, 0:nI+1,0:nJ+1,-1:nK  ,iBLK)) / dz_BLK(iBLK) - &
             ( State_VGB(Bz_, 1:nI+2,0:nJ+1, 0:nK+1,iBLK) &
             - State_VGB(Bz_,-1:nI  ,0:nJ+1, 0:nK+1,iBLK)) / dx_BLK(iBLK)   &
             ) * y_BLK(0:nI+1,0:nJ+1,0:nK+1,iBLK) &
             + ( &
             ( State_VGB(By_, 1:nI+2, 0:nJ+1,0:nK+1,iBLK) &
             - State_VGB(By_,-1:nI  , 0:nJ+1,0:nK+1,iBLK)) / dx_BLK(iBLK) - &
             ( State_VGB(Bx_, 0:nI+1, 1:nJ+2,0:nK+1,iBLK) &
             - State_VGB(Bx_, 0:nI+1,-1:nJ  ,0:nK+1,iBLK)) / dy_BLK(iBLK)   &
             ) * z_BLK(0:nI+1,0:nJ+1,0:nK+1,iBLK) )
!^CFG END CARTESIAN
!       call covar_curlbr_plotvar(iBLK,PlotVar(:,:,:,iVar))  !^CFG IF NOT CARTESIAN
     case('er','Er','ER')
        PlotVar(:,:,:,iVar)=( ( State_VGB(rhoUz_,:,:,:,iBLK)* &
             (State_VGB(By_,:,:,:,iBLK)+B0yCell_BLK(:,:,:,iBLK)) &
             -State_VGB(rhoUy_,:,:,:,iBLK)* &
             (State_VGB(Bz_,:,:,:,iBLK)+B0zCell_BLK(:,:,:,iBLK))) &
             *x_BLK(:,:,:,iBLK) &
             +( State_VGB(rhoUx_,:,:,:,iBLK)* &
             (State_VGB(Bz_,:,:,:,iBLK)+B0zCell_BLK(:,:,:,iBLK)) &
             -State_VGB(rhoUz_,:,:,:,iBLK)* &
             (State_VGB(Bx_,:,:,:,iBLK)+B0xCell_BLK(:,:,:,iBLK))) &
             *y_BLK(:,:,:,iBLK) &
             +( State_VGB(rhoUy_,:,:,:,iBLK)* &
             (State_VGB(Bx_,:,:,:,iBLK)+B0xCell_BLK(:,:,:,iBLK)) &
             -State_VGB(rhoUx_,:,:,:,iBLK)* &
             (State_VGB(By_,:,:,:,iBLK)+B0yCell_BLK(:,:,:,iBLK))) &
             *z_BLK(:,:,:,iBLK) )/State_VGB(rho_,:,:,:,iBLK) 
     case('pvecr','Pvecr','PvecR','pvecR','PVecR','PVECR')
        tmp1Var = &
             (State_VGB(Bx_,:,:,:,iBLK)+B0xCell_BLK(:,:,:,iBLK))**2 + &
             (State_VGB(By_,:,:,:,iBLK)+B0yCell_BLK(:,:,:,iBLK))**2 + &
             (State_VGB(Bz_,:,:,:,iBLK)+B0zCell_BLK(:,:,:,iBLK))**2 
        tmp2Var = &
             (State_VGB(Bx_,:,:,:,iBLK)+B0xCell_BLK(:,:,:,iBLK))* &
             State_VGB(rhoUx_,:,:,:,iBLK) + &
             (State_VGB(By_,:,:,:,iBLK)+B0yCell_BLK(:,:,:,iBLK))* &
             State_VGB(rhoUy_,:,:,:,iBLK) + &
             (State_VGB(Bz_,:,:,:,iBLK)+B0zCell_BLK(:,:,:,iBLK))* &
             State_VGB(rhoUz_,:,:,:,iBLK) 
        PlotVar(:,:,:,iVar)=( ( tmp1Var*State_VGB(rhoUx_,:,:,:,iBLK) &
             -tmp2Var*(State_VGB(Bx_,:,:,:,iBLK)+ &
             B0xCell_BLK(:,:,:,iBLK)))* &
             X_BLK(:,:,:,iBLK) &
             +( tmp1Var*State_VGB(rhoUy_,:,:,:,iBLK) &
             -tmp2Var*(State_VGB(By_,:,:,:,iBLK)+ &
             B0yCell_BLK(:,:,:,iBLK)))* &
             Y_BLK(:,:,:,iBLK) &  
             +( tmp1Var*State_VGB(rhoUz_,:,:,:,iBLK) &
             -tmp2Var*(State_VGB(Bz_,:,:,:,iBLK)+ &
             B0zCell_BLK(:,:,:,iBLK)))* &
             Z_BLK(:,:,:,iBLK) )&   
             /(State_VGB(rho_,:,:,:,iBLK)*R_BLK(:,:,:,iBLK))
     case('B2ur','B2Ur','b2ur')
        tmp1Var = &
             (State_VGB(Bx_,:,:,:,iBLK)+B0xCell_BLK(:,:,:,iBLK))**2 + &
             (State_VGB(By_,:,:,:,iBLK)+B0yCell_BLK(:,:,:,iBLK))**2 + &
             (State_VGB(Bz_,:,:,:,iBLK)+B0zCell_BLK(:,:,:,iBLK))**2  
        PlotVar(:,:,:,iVar)=0.5*( tmp1Var*State_VGB(rhoUx_,:,:,:,iBLK)* &
             X_BLK(:,:,:,iBLK) &
             +tmp1Var*State_VGB(rhoUy_,:,:,:,iBLK)* &
             Y_BLK(:,:,:,iBLK) &  
             +tmp1Var*State_VGB(rhoUz_,:,:,:,iBLK)* &
             Z_BLK(:,:,:,iBLK) )&   
             /(State_VGB(rho_,:,:,:,iBLK)*R_BLK(:,:,:,iBLK))
!^CFG IF CARTESIAN BEGIN
     case('DivB','divB','divb','divb_CD','divb_cd','divb_CT','divb_ct')
        if(s.eq.'divb_CD' .or. s.eq.'divb_cd' .or. &
             ((s.eq.'divb' .or. s.eq.'divB' .or. s.eq.'DivB') &
             .and..not.UseConstrainB &                  !^CFG IF CONSTRAINB
             ))then

           ! Div B from central differences
           PlotVar(0:nI+1,0:nJ+1,0:nK+1,iVar)=0.5*VolumeInverse_I(iBLK)*(  &
                fAx_BLK(iBLK)*(State_VGB(Bx_,1:nI+2,0:nJ+1,0:nK+1,iBLK)-  &
                State_VGB(Bx_,-1:nI,0:nJ+1,0:nK+1,iBLK))+ &
                fAy_BLK(iBLK)*(State_VGB(By_,0:nI+1,1:nJ+2,0:nK+1,iBLK)-  &
                State_VGB(By_,0:nI+1,-1:nJ,0:nK+1,iBLK))+ &
                fAz_BLK(iBLK)*(State_VGB(Bz_,0:nI+1,0:nJ+1,1:nk+2,iBLK)-  &
                State_VGB(Bz_,0:nI+1,0:nJ+1,-1:nK,iBLK)))
        else if(UseConstrainB)then                    !^CFG IF CONSTRAINB BEGIN
           ! Div B from face fluxes
           PlotVar(0:nI+1,0:nJ+1,0:nK+1,iVar)= &
                (Bxface_BLK(1:nI+2  ,0:nJ+1  ,0:nK+1  ,iBLK)              &
                -Bxface_BLK(0:nI+1  ,0:nJ+1  ,0:nK+1  ,iBLK))/dx_BLK(iBLK)&
                +(Byface_BLK(0:nI+1  ,1:nJ+2  ,0:nK+1  ,iBLK)              &
                -Byface_BLK(0:nI+1  ,0:nJ+1  ,0:nK+1  ,iBLK))/dy_BLK(iBLK)&
                +(Bzface_BLK(0:nI+1  ,0:nJ+1  ,1:nk+2  ,iBLK)              &
                -Bzface_BLK(0:nI+1  ,0:nJ+1  ,0:nK+1  ,iBLK))/dz_BLK(iBLK)
           !^CFG END CONSTRAINB
        else
           ! Cell corner centered div B from cell centers
           PlotVar(0:nI+1  ,0:nJ+1  ,0:nK+1,iVar)= 0.25*(&
                (State_VGB(Bx_,0:nI+1  ,0:nJ+1  ,0:nK+1  ,iBLK)  &
                +State_VGB(Bx_,0:nI+1  ,-1:nJ   ,0:nK+1  ,iBLK)  &
                +State_VGB(Bx_,0:nI+1  ,0:nJ+1  ,-1:nK   ,iBLK)  &
                +State_VGB(Bx_,0:nI+1  ,-1:nJ   ,-1:nK   ,iBLK)  &
                -State_VGB(Bx_,-1:nI   ,0:nJ+1  ,0:nK+1  ,iBLK)  &
                -State_VGB(Bx_,-1:nI   ,-1:nJ   ,0:nK+1  ,iBLK)  &
                -State_VGB(Bx_,-1:nI   ,0:nJ+1  ,-1:nK   ,iBLK)  &
                -State_VGB(Bx_,-1:nI   ,-1:nJ   ,-1:nK   ,iBLK))/dx_BLK(iBLK) &
                +(State_VGB(By_,0:nI+1  ,0:nJ+1  ,0:nK+1  ,iBLK)  &
                +State_VGB(By_,-1:nI   ,0:nJ+1  ,0:nK+1  ,iBLK)  &
                +State_VGB(By_,0:nI+1  ,0:nJ+1  ,-1:nK   ,iBLK)  &
                +State_VGB(By_,-1:nI   ,0:nJ+1  ,-1:nK   ,iBLK)  &
                -State_VGB(By_,0:nI+1  ,-1:nJ   ,0:nK+1  ,iBLK)  &
                -State_VGB(By_,-1:nI   ,-1:nJ   ,0:nK+1  ,iBLK)  &
                -State_VGB(By_,0:nI+1  ,-1:nJ   ,-1:nK   ,iBLK)  &
                -State_VGB(By_,-1:nI   ,-1:nJ   ,-1:nK   ,iBLK))/dy_BLK(iBLK) &
                +(State_VGB(Bz_,0:nI+1  ,0:nJ+1  ,0:nK+1  ,iBLK)  &
                +State_VGB(Bz_,-1:nI   ,0:nJ+1  ,0:nK+1  ,iBLK)  &
                +State_VGB(Bz_,0:nI+1  ,-1:nJ   ,0:nK+1  ,iBLK)  &
                +State_VGB(Bz_,-1:nI   ,-1:nJ   ,0:nK+1  ,iBLK)  &
                -State_VGB(Bz_,0:nI+1  ,0:nJ+1  ,-1:nK   ,iBLK)  &
                -State_VGB(Bz_,-1:nI   ,0:nJ+1  ,-1:nK   ,iBLK)  &
                -State_VGB(Bz_,0:nI+1  ,-1:nJ   ,-1:nK   ,iBLK)  &
                -State_VGB(Bz_,-1:nI   ,-1:nJ   ,-1:nK   ,iBLK))/dz_BLK(iBLK))
        endif
        if(.not.true_BLK(iBLK))then
           where(.not.true_cell(:,:,:,iBLK))PlotVar(:,:,:,iVar)=0.0
        endif
!^CFG END CARTESIAN
     case('absdivB','absdivb','ABSDIVB')
         PlotVar(0:nI+1,0:nJ+1,0:nK+1,iVar) = abs(DivB1_GB(:,:,:,iBLK))
         if(.not.true_BLK(iBLK))then
            where(.not.true_cell(:,:,:,iBLK)) PlotVar(:,:,:,iVar)=0.0
         endif
!!$!^CFG  IF RAYTRACE BEGIN
        ! BASIC RAYTRACE variables

     case('theta1','theta2','phi1','phi2','status')
        select case(s)
        case ('theta1')
           itmp = 1 ; jtmp = 1
        case ('theta2')
           itmp = 1 ; jtmp = 2
        case ('phi1')
           itmp = 2 ; jtmp = 1
        case ('phi2')
           itmp = 2 ; jtmp = 2
        case ('status')
           itmp = 3 ; jtmp = 1
        end select

        PlotVar(1:nI,1:nJ,1:nK,iVar)=ray(itmp,jtmp,1:nI,1:nJ,1:nK,iBLK)
        ! Now load the face ghost cells with the first computation 
        ! cell on each face.  This is a bad approximation but is 
        ! needed for Tecplot.  It will be fixed later using message 
        ! passing
        PlotVar(1:nI,1:nJ,0   ,iVar)=ray(itmp,jtmp,1:nI,1:nJ,1   ,iBLK)
        PlotVar(1:nI,1:nJ,nK+1,iVar)=ray(itmp,jtmp,1:nI,1:nJ,nK  ,iBLK)
        PlotVar(1:nI,0   ,1:nK,iVar)=ray(itmp,jtmp,1:nI,1   ,1:nK,iBLK)
        PlotVar(1:nI,nJ+1,1:nK,iVar)=ray(itmp,jtmp,1:nI,nJ  ,1:nK,iBLK)
        PlotVar(0   ,1:nJ,1:nK,iVar)=ray(itmp,jtmp,1   ,1:nJ,1:nK,iBLK)
        PlotVar(nI+1,1:nJ,1:nK,iVar)=ray(itmp,jtmp,nI  ,1:nJ,1:nK,iBLK)
        ! Do edges
        PlotVar(1:nI,0   ,0   ,iVar)=ray(itmp,jtmp,1:nI,1   ,1   ,iBLK)
        PlotVar(1:nI,nJ+1,nK+1,iVar)=ray(itmp,jtmp,1:nI,nJ  ,nK  ,iBLK)
        PlotVar(1:nI,nJ+1,0   ,iVar)=ray(itmp,jtmp,1:nI,nJ  ,1   ,iBLK)
        PlotVar(1:nI,0   ,nK+1,iVar)=ray(itmp,jtmp,1:nI,1   ,nK  ,iBLK)
        PlotVar(0   ,0   ,1:nK,iVar)=ray(itmp,jtmp,1   ,1   ,1:nK,iBLK)
        PlotVar(nI+1,nJ+1,1:nK,iVar)=ray(itmp,jtmp,nI  ,nJ  ,1:nK,iBLK)
        PlotVar(nI+1,0   ,1:nK,iVar)=ray(itmp,jtmp,nI  ,1   ,1:nK,iBLK)
        PlotVar(0   ,nJ+1,1:nK,iVar)=ray(itmp,jtmp,1   ,nJ  ,1:nK,iBLK)
        PlotVar(0   ,1:nJ,0   ,iVar)=ray(itmp,jtmp,1   ,1:nJ,1   ,iBLK)
        PlotVar(nI+1,1:nJ,nK+1,iVar)=ray(itmp,jtmp,nI  ,1:nJ,nK  ,iBLK)
        PlotVar(nI+1,1:nJ,0   ,iVar)=ray(itmp,jtmp,nI  ,1:nJ,1   ,iBLK)
        PlotVar(0   ,1:nJ,nK+1,iVar)=ray(itmp,jtmp,1   ,1:nJ,nK  ,iBLK)
        ! Do corners
        PlotVar(0   ,0   ,0   ,iVar)=ray(itmp,jtmp,1   ,1   ,1   ,iBLK)
        PlotVar(0   ,nJ+1,0   ,iVar)=ray(itmp,jtmp,1   ,nJ  ,1   ,iBLK)
        PlotVar(0   ,0   ,nK+1,iVar)=ray(itmp,jtmp,1   ,1   ,nK  ,iBLK)
        PlotVar(0   ,nJ+1,nK+1,iVar)=ray(itmp,jtmp,1   ,nJ  ,nK  ,iBLK)
        PlotVar(nI+1,0   ,0   ,iVar)=ray(itmp,jtmp,nI  ,1   ,1   ,iBLK)
        PlotVar(nI+1,nJ+1,0   ,iVar)=ray(itmp,jtmp,nI  ,nJ  ,1   ,iBLK)
        PlotVar(nI+1,0   ,nK+1,iVar)=ray(itmp,jtmp,nI  ,1   ,nK  ,iBLK)
        PlotVar(nI+1,nJ+1,nK+1,iVar)=ray(itmp,jtmp,nI  ,nJ  ,nK  ,iBLK)

        ! EXTRA RAYTRACE variables
     case('f1x')
        PlotVar(1:nI,1:nJ,1:nK,iVar)=rayface(1,1,1:nI,1:nJ,1:nK,iBLK)
     case('f1y')      	          		                   	   
        PlotVar(1:nI,1:nJ,1:nK,iVar)=rayface(2,1,1:nI,1:nJ,1:nK,iBLK)
     case('f1z')      	          		                   	   
        PlotVar(1:nI,1:nJ,1:nK,iVar)=rayface(3,1,1:nI,1:nJ,1:nK,iBLK)
     case('f2x')      	          		                   	   
        PlotVar(1:nI,1:nJ,1:nK,iVar)=rayface(1,2,1:nI,1:nJ,1:nK,iBLK)
     case('f2y')      	          		                   	   
        PlotVar(1:nI,1:nJ,1:nK,iVar)=rayface(2,2,1:nI,1:nJ,1:nK,iBLK)
     case('f2z')      	          		                   	   
        PlotVar(1:nI,1:nJ,1:nK,iVar)=rayface(3,2,1:nI,1:nJ,1:nK,iBLK)
!!$!^CFG END RAYTRACE

        ! GRID INFORMATION
     case('dx')
        PlotVar(:,:,:,iVar)=dx_BLK(iBLK)
     case('dt')
        PlotVar(1:nI,1:nJ,1:nK,iVar)=time_BLK(1:nI,1:nJ,1:nK,iBLK)
     case('dtBLK','dtblk')
        PlotVar(:,:,:,iVar)=dt_BLK(iBLK)
        if(.not.true_BLK(iBLK))then
           if(.not.any(true_cell(1:nI,1:nJ,1:nK,iBLK)))&
                PlotVar(:,:,:,iVar)=0.0
        end if
     case('impl','IMPL')                      !^CFG IF IMPLICIT BEGIN
        if(implicitBLK(iBLK))then
           PlotVar(:,:,:,iVar)=1.
        else
           PlotVar(:,:,:,iVar)=0.
        end if                                !^CFG END IMPLICIT
     case('cons','CONS')
        if(allocated(IsConserv_CB))then
           where(IsConserv_CB(:,:,:,iBLK))
              PlotVar(1:nI,1:nJ,1:nK,iVar)=1.
           elsewhere
              PlotVar(1:nI,1:nJ,1:nK,iVar)=0.
           end where
        else if(UseNonConservative)then
           PlotVar(1:nI,1:nJ,1:nK,iVar)=0.
        else
           PlotVar(1:nI,1:nJ,1:nK,iVar)=1.
        end if
     case('PE','pe','proc')
        PlotVar(:,:,:,iVar)=iProc
     case('blk','BLK')
        PlotVar(:,:,:,iVar)=iBLK
     case('blkall','BLKALL')
        PlotVar(:,:,:,iVar)=global_block_number(iBLK)
     case('child')
        PlotVar(:,:,:,iVar)=BLKneighborCHILD(0,0,0,1,iBLK)
     case default
        jVar = 1
        do while (jVar < nVar .and.trim(s).ne.trim(NameVar_V(jVar)) )
           jVar=jVar+1
        end do
        if(trim(s).eq.trim(NameVar_V(jVar))) then
           PlotVar(:,:,:,iVar)=State_VGB(jVar,:,:,:,iBLK)
           if(DefaultState_V(jVar)>cTiny)&
                plotvar_inBody(iVar)=CellState_VI(jVar,body1_)
        else
           PlotVar(:,:,:,iVar)=-7777.
           if(iProc==0.and.iBLK==1)write(*,*) &
                'Warning in set_plotvar: unknown plotvarname=',&
                plotvarnames(iVar),' for iplotfile=',iplotfile
        end if
     end select
  end do ! iVar
end subroutine set_plotvar


!==============================================================================
subroutine dimensionalize_plotvar(iBLK,iplotfile,nplotvar,plotvarnames, &
     plotvar,plotvar_inBody)

  use ModProcMH
  use ModMain, ONLY : nI,nJ,nK, BlkTest, ProcTest
  use ModPhysics
  use ModVarIndexes, ONLY : NameVar_V, DefaultState_V   
  implicit none

  integer, intent(in) :: iBLK,iPlotFile,Nplotvar
  character (LEN=10), intent(in) :: plotvarnames(Nplotvar)
  real, intent(inout) :: plotVar(-1:nI+2,-1:nJ+2,-1:nK+2,nPlotVar)
  real, intent(inout) :: plotVar_inBody(nPlotVar)
  character (len=10)  :: s

  integer :: iVar,i,j,k, jVar
  logical :: oktest,oktest_me
  !---------------------------------------------------------------------------
  if(iBLK==BlkTest.and.iProc==ProcTest)then
     call set_oktest('dimensionalize_plotvar',oktest,oktest_me)
  else
     oktest=.false.; oktest_me=.false.
  end if

  do iVar=1,nPlotVar
     s=plotvarnames(iVar)

     if (oktest_me)  write(*,*) 'iProc,plotvarnames,iVar,unitUSER_J', &
          iProc,plotvarnames(iVar),iVar,unitUSER_J

     ! Set plotvar_inBody to something reasonable for inside the body.
     ! Load zeros (0) for most values - load something better for rho, p, and T.
     ! We know that U,B,J are okay with zeroes, others should be changed if
     ! necessary.  Note that all variables not set to 0 in set_plotvar should be 
     ! loaded below. Note that this is used for tecplot corner extrapolation 
     ! and for nothing else.

     select case(s)

        ! BASIC MHD variables

     case('rho')
        PlotVar(:,:,:,iVar)=PlotVar(:,:,:,iVar)*unitUSER_rho
        plotvar_inBody(iVar)=plotvar_inBody(iVar)*unitUSER_rho
     case('rhoUx','rhoux','mx','rhoUy','rhouy','my','rhoUz','rhouz','mz', &
          'rhoUr','rhour','mr' )
        PlotVar(:,:,:,iVar)=PlotVar(:,:,:,iVar)*unitUSER_rhoU
     case('Bx','bx','By','by','Bz','bz','Br','br'&
          ,'BxL','bxl','BxR','bxr'               &         !^CFG IF CONSTRAINB
          ,'ByL','byl','ByR','byr'               &         !^CFG IF CONSTRAINB
          ,'BzL','bzl','BzR','bzr'               &         !^CFG IF CONSTRAINB
          )
        PlotVar(:,:,:,iVar)=PlotVar(:,:,:,iVar)*unitUSER_B
     case('E','e','E1','e1')
        PlotVar(:,:,:,iVar)=PlotVar(:,:,:,iVar)*unitUSER_energydens
     case('P','p','Pth','pth')
        PlotVar(:,:,:,iVar)=PlotVar(:,:,:,iVar)*unitUSER_p
        plotvar_inBody(iVar)=plotvar_inBody(iVar)*unitUSER_p
!^CFG IF ALWAVES BEGIN
     case('Ew','ew')
        PlotVar(:,:,:,iVar)=PlotVar(:,:,:,iVar)*unitUSER_energydens
!^CFG END ALWAVES

        ! EXTRA MHD variables

     case('Ux','ux','Uy','uy','Uz','uz')
        PlotVar(:,:,:,iVar)=PlotVar(:,:,:,iVar)*unitUSER_U
     case('B1x','b1x','B1y','b1y','B1z','b1z','B1r','b1r')
        PlotVar(:,:,:,iVar)=PlotVar(:,:,:,iVar)*unitUSER_B
     case('Jx','jx','Jy','jy','Jz','jz','Jr','jr')
        PlotVar(:,:,:,iVar)=PlotVar(:,:,:,iVar)*unitUSER_J   
     case('ex','Ex','ey','Ey','ez','Ez','er','Er','enumx','enumy','enumz')
        PlotVar(:,:,:,iVar)=PlotVar(:,:,:,iVar)*unitUSER_electric   
     case('pvecx','Pvecx','PvecX','pvecX','PVecX','PVECX', &
          'pvecy','Pvecy','PvecY','pvecY','PVecY','PVECY', &
          'pvecz','Pvecz','PvecZ','pvecZ','PVecZ','PVECZ', &
          'pvecr','Pvecr','PvecR','pvecR','PVecR','PVECR')
        PlotVar(:,:,:,iVar)=PlotVar(:,:,:,iVar)*unitUSER_Poynting
     case('B2ur','B2Ur','b2ur')
        PlotVar(:,:,:,iVar)=PlotVar(:,:,:,iVar)*unitUSER_Poynting
     case('DivB','divB','divb','divb_CD','divb_cd','divb_CT','divb_ct',&
          'absdivB','absdivb','ABSDIVB')
        PlotVar(:,:,:,iVar)=PlotVar(:,:,:,iVar)*unitUSER_DivB

        ! BASIC RAYTRACE variables

     case('theta1','phi1','theta2','phi2')
        PlotVar(:,:,:,iVar)=PlotVar(:,:,:,iVar)
     case('status')
        PlotVar(:,:,:,iVar)=PlotVar(:,:,:,iVar)

        ! EXTRA RAYTRACE variables
     case('f1x','f1y','f1z','f2x','f2y','f2z')
        PlotVar(:,:,:,iVar)=PlotVar(:,:,:,iVar)

        ! GRID INFORMATION
     case('dt','dtBLK','dtblk')
        PlotVar(:,:,:,iVar)=PlotVar(:,:,:,iVar)*unitUSER_t
     case('dx')
        PlotVar(:,:,:,iVar)=PlotVar(:,:,:,iVar)*unitUSER_x

        ! DEFAULT CASE
     case default
        jVar = 1
        do while (jVar < nVar .and.trim(s).ne.trim(NameVar_V(jVar)) )
           jVar=jVar+1
        end do
        if(trim(s).eq.trim(NameVar_V(jVar))) then
           PlotVar(:,:,:,iVar)=PlotVar(:,:,:,iVar)*&
                unitUSERVars_V(jVar)
           if(DefaultState_V(jVar)>cTiny)&
                plotvar_inBody(iVar)=plotvar_inBody(iVar)*&
                unitUSERVars_V(jVar)
        end if
        ! no normalization
     end select
  end do ! iVar
end subroutine dimensionalize_plotvar

!==============================================================================

subroutine get_tec_variables(iFile, nPlotVar, NamePlotVar_V, StringVarTec)

  use ModPhysics
  use ModUtilities,  ONLY: lower_case
  use ModIO,         ONLY: plot_type,plot_dimensional
  use ModVarIndexes, ONLY: NameVar_V
  implicit none

  ! Arguments

  integer, intent(in)              :: nPlotVar, iFile
  character (len=10), intent(in)   :: NamePlotVar_V(nPlotVar)
  character (len=500), intent(out) :: StringVarTec 

  character (len=10) :: NamePlotVar, NameVar, NameTecVar, NameUnit
  integer            :: iPlotVar, iVar

  !\
  ! This routine takes the plot_var information and loads the header file with
  ! the appropriate string of variable names and units
  !/

  ! Coordinate names and units
  if(index(plot_type(ifile),'sph')>0) then

     if (plot_dimensional(ifile)) then
        StringVarTec = 'VARIABLES ="X ' // trim(unitstr_TEC_x) &
             // '", "Y ' // trim(unitstr_TEC_x) &
             // '", "Z ' // trim(unitstr_TEC_x) &
             // '", "`q [degree]", "`f[degree]'
     else
   	StringVarTec = 'VARIABLES = "X", "Y", "Z", "`q", "`f'
     end if

  else

     if (plot_dimensional(ifile)) then
        StringVarTec = 'VARIABLES ="X ' // trim(unitstr_TEC_x) &
             // '", "Y ' // trim(unitstr_TEC_x) &
             // '", "Z ' // trim(unitstr_TEC_x)
     else
   	StringVarTec = 'VARIABLES = "X", "Y", "Z"'
     end if

  end if

  do iPlotVar = 1, nPlotVar

     NamePlotVar = NamePlotVar_V(iPlotVar)
     call lower_case(NamePlotVar)

     ! Default value for NameUnit is empty string
     NameUnit = ''

     select case(NamePlotVar)
     case('rho') 
        NameTecVar = '`r'
        NameUnit   = unitstr_TEC_rho
     case('rhoux','mx') 
        NameTecVar = '`r U_x'
        NameUnit   = unitstr_TEC_rhoU
     case('rhouy','my') 
        NameTecVar = '`r U_y'
        NameUnit   = unitstr_TEC_rhoU
     case('rhouz','mz') 
        NameTecVar = '`r U_z'
        NameUnit   = unitstr_TEC_rhoU
     case('bx') 
        NameTecVar = 'B_x'
        NameUnit   = unitstr_TEC_B
     case('by') 
        NameTecVar = 'B_y'
        NameUnit   = unitstr_TEC_B
     case('bz') 
        NameTecVar = 'B_z'
        NameUnit   = unitstr_TEC_B
        ! face centered magnetic field       !^CFG IF CONSTRAINB BEGIN
     case('bxl') ! east
        NameTecVar = 'B_e'
        NameUnit   = unitstr_TEC_B
     case('bxr') ! west
        NameTecVar = 'B_w'
        NameUnit   = unitstr_TEC_B
     case('byl') ! south
        NameTecVar = 'B_s'
        NameUnit   = unitstr_TEC_B
     case('byr') ! north
        NameTecVar = 'B_n'
        NameUnit   = unitstr_TEC_B
     case('bzl') ! bottom
        NameTecVar = 'B_b'
        NameUnit   = unitstr_TEC_B
     case('bzr') ! top
        NameTecVar = 'B_t'
        NameUnit   = unitstr_TEC_B
        !                                        !^CFG END CONSTRAINB
     case('e')
        NameTecVar = 'E'
        NameUnit   = unitstr_TEC_energydens
     case('p','pth')
        NameTecVar = 'p'
        NameUnit   = unitstr_TEC_p
     case('ew')                                  !^CFG IF ALWAVES BEGIN
        NameTecVar = 'Ew'
        NameUnit   = unitstr_TEC_energydens      !^CFG END ALWAVES
     case('ux') 
        NameTecVar = 'U_x'
        NameUnit   = unitstr_TEC_U
     case('uy') 
        NameTecVar = 'U_y'
        NameUnit   = unitstr_TEC_U
     case('uz') 
        NameTecVar = 'U_z'
        NameUnit   = unitstr_TEC_U
     case('ur') 
        NameTecVar = 'U_r'
        NameUnit   = unitstr_TEC_U
     case('rhour','mr') 
        NameTecVar = '`r U_r'
        NameUnit   = unitstr_TEC_rhoU
     case('br') 
        NameTecVar = 'B_r'
        NameUnit   = unitstr_TEC_B
     case('b1x') 
        NameTecVar = 'B1_x'
        NameUnit   = unitstr_TEC_B
     case('b1y')                                 
        NameTecVar = 'B1_y'
        NameUnit   = unitstr_TEC_B
     case('b1z')                                 
        NameTecVar = 'B1_z'
        NameUnit   = unitstr_TEC_B
     case('b1r')                                 
        NameTecVar = 'B1_r'
        NameUnit   = unitstr_TEC_B
     case('jx') 
        NameTecVar = 'J_x'
        NameUnit   = unitstr_TEC_J
     case('jy')                                 
        NameTecVar = 'J_y'
        NameUnit   = unitstr_TEC_J
     case('jz')                                 
        NameTecVar = 'J_z'
        NameUnit   = unitstr_TEC_J
     case('jr')                                 
        NameTecVar = 'J_r'
        NameUnit   = unitstr_TEC_J
     case('ex')
        NameTecVar = 'E_x'
        NameUnit   = unitstr_TEC_electric
     case('ey')
        NameTecVar = 'E_y'
        NameUnit   = unitstr_TEC_electric
     case('ez')                                 
        NameTecVar = 'E_z'
        NameUnit   = unitstr_TEC_electric
     case('er')                                 
        NameTecVar = 'E_r'
        NameUnit   = unitstr_TEC_electric                
     case('pvecx')
        NameTecVar = 'S_x'
        NameUnit   = unitstr_TEC_Poynting                
     case('pvecy')
        NameTecVar = 'S_y'
        NameUnit   = unitstr_TEC_Poynting                
     case('pvecz')
        NameTecVar = 'S_z'
        NameUnit   = unitstr_TEC_Poynting                
     case('pvecr')
        NameTecVar = 'S_r'
        NameUnit   = unitstr_TEC_Poynting                
     case('b2ur')
        NameTecVar = 'B^2/`u_0 U_r'
        NameUnit   = unitstr_TEC_Poynting                
     case('divb', 'divb_cd', 'divb_ct', 'absdivb')
        NameTecVar = '~Q~7B'
        NameUnit   = unitstr_TEC_DivB
     case('theta1')                              !^CFG  IF RAYTRACE BEGIN
        NameTecVar = '`q_1'
        NameUnit   = unitstr_TEC_angle
     case('phi1')
        NameTecVar = '`f_1'
        NameUnit   = unitstr_TEC_angle
     case('theta2')
        NameTecVar = '`q_2'
        NameUnit   = unitstr_TEC_angle
     case('phi2')
        NameTecVar = '`f_2'
        NameUnit   = unitstr_TEC_angle
     case('status')
        NameTecVar = 'Status'
     case('f1x','f1y','f1z','f2x','f2y','f2z')
        NameTecVar = NamePlotVar                 !^CFG END RAYTRACE
     case('dx')
        NameTecVar = 'dx'
        NameUnit   = unitstr_TEC_x
     case('dt')
        NameTecVar = 'dt'
        NameUnit   = unitstr_TEC_t
     case('dtblk')
        NameTecVar = 'dtblk'
        NameUnit   = unitstr_TEC_t
     case('impl')                                !^CFG IF IMPLICIT
        NameTecVar = 'impl'                      !^CFG IF IMPLICIT
     case('PE','pe','proc')
        NameTecVar = 'PE #'
     case('blk')
        NameTecVar = 'Block #'
     case('blkall')
        NameTecVar = 'blkall'
     case('child')
        NameTecVar = 'Child #'
     case default
        ! Use the plot variable name by default but unit is not known
        NameTecVar = NamePlotVar
        NameUnit   = 'Default'
        ! Try to find the plot variable among the basic variables to set unit
        do iVar = 1, nVar
           NameVar = NameVar_V(iVar)
           call lower_case(NameVar)
           if(NameVar == NamePlotVar)then
              NameUnit = TypeUnitVarsTec_V(iVar)
              EXIT
           end if
        end do
     end select

     StringVarTec = trim(StringVarTec) // '", "' // NameTecVar

     if (plot_dimensional(ifile)) &
          StringVarTec = trim(StringVarTec) // ' ' //NameUnit

  end do

  ! Append a closing double quote
  StringVarTec = trim(StringVarTec) // '"'

end subroutine get_TEC_variables

!==============================================================================

subroutine get_idl_units(iFile, nPlotVar, NamePlotVar_V, StringUnitIdl)

  use ModPhysics
  use ModUtilities,  ONLY: lower_case
  use ModIO,         ONLY: plot_type, plot_dimensional
  use ModVarIndexes, ONLY: NameVar_V
  implicit none

  ! Arguments

  integer, intent(in)             :: iFile, nPlotVar
  character (len=10), intent(in)  :: NamePlotVar_V(nPlotVar)
  character (len=79), intent(out) :: StringUnitIdl 


  character (len=10) :: NamePlotVar, NameVar, NameUnit
  integer            :: iPlotVar, iVar

  !\
  ! This routine takes the plot_var information and loads the header file with
  ! the appropriate string of unit values
  !/

  if(.not.plot_dimensional(iFile))then
     StringUnitIdl = 'normalized variables'
     RETURN
  end if

  if(index(plot_type(ifile),'sph')>0) then
     StringUnitIdl = trim(unitstr_IDL_x)//' deg deg'
  else
     StringUnitIdl = trim(unitstr_IDL_x)//' '//&
          trim(unitstr_IDL_x)//' '//trim(unitstr_IDL_x)
  end if

  do iPlotVar = 1, nPlotVar

     NamePlotVar = NamePlotVar_V(iPlotVar)
     call lower_case(NamePlotVar)

     select case(NamePlotVar)
     case('rho') 
        NameUnit = unitstr_IDL_rho
     case('rhoux','mx','rhouy','rhoUz','rhouz','mz','rhour','mr')
        NameUnit = unitstr_IDL_rhoU
     case('bx','by','bz','b1x','b1y','b1z','br','b1r')
        NameUnit = unitstr_IDL_B
     case('e')
        NameUnit = unitstr_IDL_energydens
     case('p','pth')
        NameUnit = unitstr_IDL_p
     case('ew')                                  !^CFG IF ALWAVES
        NameUnit = unitstr_IDL_energydens        !^CFG IF ALWAVES
     case('ux','uy','uz','ur')
        NameUnit = unitstr_IDL_U
     case('jx','jy','jz','jr') 
        NameUnit = unitstr_IDL_J
     case('ex','ey','ez','er','enumx','enumy','enumz')
        NameUnit = unitstr_IDL_electric
     case('pvecx','pvecy','pvecz','pvecr','b2ur')
        NameUnit = unitstr_IDL_Poynting
     case('divb','divb_cd','divb_ct','absdivb')
        NameUnit = unitstr_IDL_DivB
     case('theta1','phi1','theta2','phi2')       !^CFG  IF RAYTRACE BEGIN
        NameUnit = 'deg'
     case('status','f1x','f1y','f1z','f2x','f2y','f2z')
        NameUnit = '--'                          !^CFG END RAYTRACE
        ! GRID INFORMATION
     case('pe', 'proc','blk','blkall','child','impl')
        NameUnit = '1'
     case('dt', 'dtblk')
        NameUnit = unitstr_IDL_t
     case('dx')
        NameUnit = unitstr_IDL_x
     case default
        ! Unit is not known
        NameUnit = '?'
        ! Try to find the plot variable among the basic variables
        do iVar = 1, nVar
           NameVar = NameVar_V(iVar)
           call lower_case(NameVar)
           if(NameVar == NamePlotVar)then
              NameUnit = TypeUnitVarsIdl_V(iVar)
              EXIT
           end if
        end do
     end select
     ! Append the unit string for this variable to the output string
     StringUnitIdl = trim(StringUnitIdl)//' '//trim(NameUnit)
  end do

end subroutine get_idl_units
