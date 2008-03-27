!^CFG COPYRIGHT UM

subroutine set_outer_BCs(iBlock, time_now, DoSetEnergy)

  ! Set ghost cells values rho, U, B, and P for iBLK. 
  ! Set E if DoSetEnergy is true.
  use ModSetOuterBC
  use ModProcMH
  use ModMain
  use ModVarIndexes
  use ModAdvance, ONLY: State_VGB
  use ModParallel, ONLY: NOBLK, NeiLev
  use ModGeometry, ONLY: far_field_BCs_BLK, MaxBoundary, TypeGeometry, XyzMin_D
  use ModPhysics
  use ModUser, ONLY: user_set_outerBCs
  use ModMultiFluid, ONLY: iFluid, nFluid, iRhoUx_I, iRhoUy_I, iRhoUz_I
  use ModEnergy, ONLY: calc_energy
  implicit none

  integer, intent(in) :: iBlock
  real,    intent(in) :: time_now
  logical, intent(in) :: DoSetEnergy

  integer :: iStart, iVar, iSide

  integer :: iGhost, jGhost, kGhost, iGhost2, jGhost2, kGhost2

  logical :: DoTest, DoTestMe, IsFound

  character(len=*), parameter :: NameSub = 'set_outer_bcs'
  !--------------------------------------------------------------------------
  iBLK=iBlock
  if(iBLK==BLKtest.and.iProc==PROCtest)then
     call set_oktest(NameSub, DoTest, DoTestMe)
  else
     DoTest=.false.; DoTestMe=.false.
  endif

  if(.not.far_field_BCs_BLK(iBLK))then
     write(*,*) NameSub,' warning: iBLK=',iBLK,' is not far_field block'
     RETURN
  end if

  if(DoTestMe)write(*,*)NameSub,': iBLK, set_E, neiLEV=',&
       iBLK,DoSetEnergy,neiLEV(:,iBLK)

  if(DoTestMe)then
     Ighost =Itest; Jghost=Jtest;  Kghost=Ktest
     Ighost2=Itest; Jghost2=Jtest; Kghost2=Ktest
     select case(DimTest)
     case(x_)
        if(iTest== 1)then; iGhost=0;    iGhost2 = -1;   endif
        if(iTest==nI)then; iGhost=nI+1; iGhost2 = nI+2; endif
     case(y_)
        if(jTest== 1)then; jGhost=0;    jGhost2 = -1;   endif
        if(jTest==nJ)then; jGhost=nJ+1; jGhost2 = nJ+2; endif
     case(z_)
        if(kTest== 1)then; kGhost=0;    kGhost2 = -1;   endif
        if(kTest==nK)then; kGhost=nK+1; kGhost2 = nK+2; endif
     end select

     write(*,*)'iTest,  jTest,  kTest   =',iTest,  jTest,  kTest
     write(*,*)'iGhost, jGhost, kGhost  =',iGhost, jGhost, kGhost
     write(*,*)'iGhost2,jGhost2,kGhost2 =',iGhost2,jGhost2,kGhost2
     do iVar=1,nVar
        write(*,*)'initial',NameVar_V(iVar),   'cell,ghost,ghost2=',&
             State_VGB(iVar,Itest,Jtest,Ktest,iBLK),&
             State_VGB(iVar,Ighost,Jghost,Kghost,iBLK), &
             State_VGB(iVar,Ighost2,Jghost2,Kghost2,iBLK)
     end do
  end if

  iStart=max(MaxBoundary+1,1)
  do iSide = iStart, Top_

     ! Check if this side of the block is indeed an outer boundary
     if(neiLEV(iSide,iBLK)/=NOBLK) CYCLE

     ! Do not apply cell boundary conditions at the pole 
     ! This is either handled by message passing or supercell
     if(TypeGeometry(1:9) == 'spherical' .and. iSide >= Bot_) CYCLE
     if(TypeGeometry      == 'cylindrical' .and. &
          XyzMin_D(1) == 0.0 .and. iSide == 1) CYCLE

     ! Set index limits
     imin1g=-1; imax1g=nI+2; imin2g=-1; imax2g=nI+2
     jmin1g=-1; jmax1g=nJ+2; jmin2g=-1; jmax2g=nJ+2
     kmin1g=-1; kmax1g=nK+2; kmin2g=-1; kmax2g=nK+2

     imin1p=-1; imax1p=nI+2; imin2p=-1; imax2p=nI+2
     jmin1p=-1; jmax1p=nJ+2; jmin2p=-1; jmax2p=nJ+2
     kmin1p=-1; kmax1p=nK+2; kmin2p=-1; kmax2p=nK+2

     select case(iside)
     case(east_)
        imin1g=0; imax1g=0; imin2g=-1; imax2g=-1
        imin1p=1; imax1p=1; imin2p= 2; imax2p= 2
     case(west_)
        imin1g=nI+1; imax1g=nI+1; imin2g=nI+2; imax2g=nI+2
        imin1p=nI  ; imax1p=nI  ; imin2p=nI-1; imax2p=nI-1
     case(south_)
        jmin1g=0; jmax1g=0; jmin2g=-1; jmax2g=-1
        jmin1p=1; jmax1p=1; jmin2p= 2; jmax2p= 2
     case(north_)
        jmin1g=nJ+1; jmax1g=nJ+1; jmin2g=nJ+2; jmax2g=nJ+2
        jmin1p=nJ  ; jmax1p=nJ  ; jmin2p=nJ-1; jmax2p=nJ-1
     case(bot_)
        kmin1g=0; kmax1g=0; kmin2g=-1; kmax2g=-1
        kmin1p=1; kmax1p=1; kmin2p= 2; kmax2p= 2
     case(top_)
        kmin1g=nK+1; kmax1g=nK+1; kmin2g=nK+2; kmax2g=nK+2
        kmin1p=nK  ; kmax1p=nK  ; kmin2p=nK-1; kmax2p=nK-1
     end select

     select case(TypeBc_I(iside))
     case('coupled')
        ! For SC-IH coupling the extra wave energy variable needs a BC
        if(NameThisComp == 'SC') call BC_cont(ScalarFirst_, ScalarLast_)
     case('periodic')
        call stop_mpi('The neighbors are not deifned at the periodic boundary')
     case('float','outflow')       
        call BC_cont(1,nVar)
     case('raeder')
        call BC_cont(1,nVar)
        if(iSide==north_.or.iSide==south_)then
           call BC_fixed(By_,By_,DefaultState_V)
        elseif(iSide==bot_.or.iSide==top_)then
           call BC_fixed(Bz_,Bz_,DefaultState_V)
        end if
     case('reflect')
        ! Scalars are symmetric
        call BC_symm(1,nVar)
        ! Normal vector components are mirror symmetric
        if(iSide==east_.or.iSide==west_)then
           do iFluid = 1, nFluid
              call BC_asymm(iRhoUx_I(iFluid), iRhoUx_I(iFluid))
           end do
           call BC_asymm(Bx_,Bx_)
        endif
        if(iSide==south_.or.iSide==north_)then
           do iFluid = 1, nFluid
              call BC_asymm(iRhoUy_I(iFluid), iRhoUy_I(iFluid))
           end do
           call BC_asymm(By_,By_)
        endif
        if(iSide==bot_.or.iSide==top_)then
           do iFluid = 1, nFluid
              call BC_asymm(iRhoUz_I(iFluid), iRhoUz_I(iFluid))
           end do
           call BC_asymm(Bz_,Bz_)
        endif
     case('linetied')
        call BC_symm(rho_,rho_)
        call BC_asymm(rhoUx_,rhoUz_)
        call BC_cont(rhoUz_+1,nVar)
     case('fixed','inflow','vary','ihbuffer')
        if(time_accurate &
             .and. (TypeBc_I(iSide)=='vary'.or.TypeBc_I(iSide)=='inflow'))then
           call BC_solar_wind(time_now)
        else if(TypeBc_I(iSide)=='ihbuffer'.and.time_loop)then
           call BC_solar_wind_buffer
        else
           call BC_fixed(1,nVar,CellState_VI(:,iSide))
           call BC_fixed_B
        end if
     case('fixedB1','fixedb1')
        call BC_fixed(1,nVar,CellState_VI(:,iSide))
     case('shear')
        call BC_shear(1,nVar,iSide)
     case('none')
     case default
        IsFound=.false.
        if(UseUserOuterBcs .or. TypeBc_I(iSide) == 'user')&
           call user_set_outerBCs(iBLK,iside,TypeBc_I(iside),IsFound)

        if(.not. IsFound) call stop_mpi( &
             NameSub // ': unknown TypeBc_I=' //TypeBc_I(iside))
     end select

     if(DoSetEnergy)then
        call calc_energy(imin1g,imax1g,jmin1g,jmax1g,kmin1g,kmax1g,iBLK,&
             1,nFluid)
        call calc_energy(imin2g,imax2g,jmin2g,jmax2g,kmin2g,kmax2g,iBLK,&
             1,nFluid)
     end if
  end do

  if(DoTestMe)then
     do iVar=1,nVar
        write(*,*)'final',NameVar_V(iVar),'   cell,ghost,ghost2=',&
             State_VGB(iVar,Itest,Jtest,Ktest,iBLK),&
             State_VGB(iVar,Ighost,Jghost,Kghost,iBLK),&
             State_VGB(iVar,Ighost2,Jghost2,Kghost2,iBLK)
     end do
  end if

end subroutine set_outer_BCs

!==========================================================================  
subroutine BC_cont(iVarStart,iVarLast)
  use ModVarIndexes
  use ModAdvance, ONLY : State_VGB
  use ModSetOuterBC

  ! Continuous: q_BLK(ghost)= q_BLK(phys1)

  integer, intent(in) :: iVarStart,iVarLast

  State_VGB(iVarStart:iVarLast,imin1g:imax1g,jmin1g:jmax1g,kmin1g:kmax1g,iBLK)=&
       State_VGB(iVarStart:iVarLast,imin1p:imax1p,jmin1p:jmax1p,kmin1p:kmax1p,iBLK)
  State_VGB(iVarStart:iVarLast,imin2g:imax2g,jmin2g:jmax2g,kmin2g:kmax2g,iBLK)=&
       State_VGB(iVarStart:iVarLast,imin1p:imax1p,jmin1p:jmax1p,kmin1p:kmax1p,iBLK)

end subroutine BC_cont

!==========================================================================
subroutine BC_shear(iVarStart, iVarLast ,iSide)
  use ModVarIndexes
  use ModAdvance, ONLY : State_VGB
  use ModSetOuterBC
  use ModSize
  use ModPhysics
  implicit none
  ! Shear: q_BLK(ghost)= q_BLK(phys1+shear)

  integer, intent(in) :: iVarStart, iVarLast, iSide
  integer :: iVar, Dn
  !------------------------------------------------------------------------
  ! For the corners or bot_ and top_ fill with unsheared data first
  call BC_cont(iVarStart,iVarLast)

  ! If the shock is not tilted, there is nothing to do
  if(abs(ShockSlope)<cTiny) RETURN

  do iVar = iVarStart, iVarLast
     ! Shear according to ShockSlope
     if(ShockSlope < -cTiny)then
        call stop_mpi('ShockSlope must be positive!')
     elseif(ShockSlope >= cOne)then
        Dn = nint(ShockSlope)
        if(abs(Dn-ShockSlope)>cTiny)&
             call stop_mpi('ShockSlope > 1 should be a round number!')
        select case(iside)
           ! Shift parallel to Y by 1 but copy from distance Dn in X
        case(east_)
           State_VGB(iVar,     imin1g,    jmin1g+1:jmax1g,   kmin1g:kmax1g,iBLK)=&
                State_VGB(iVar,imin1g+Dn, jmin1p  :jmax1p-1, kmin1p:kmax1p,iBLK)

           State_VGB(iVar,     imin2g,    jmin2g+1:jmax2g,   kmin2g:kmax2g,iBLK)=&
                State_VGB(iVar,imin2g+Dn, jmin1p  :jmax1p-1, kmin1p:kmax1p,iBLK)
        case(west_)
           State_VGB(iVar,     imin1g,    jmin1g  :jmax1g-1, kmin1g:kmax1g,iBLK)=&
                State_VGB(iVar,imin1g-Dn, jmin1p+1:jmax1p,   kmin1p:kmax1p,iBLK)

           State_VGB(iVar,     imin2g,    jmin2g  :jmax2g-1, kmin2g:kmax2g,iBLK)=&
                State_VGB(iVar,imin2g-Dn, jmin1p+1:jmax1p,   kmin1p:kmax1p,iBLK)

           ! Shift parallel to X by Dn and 2*Dn
        case(south_)
           State_VGB(iVar,     imin1g+Dn:imax1g,   jmin1g, kmin1g:kmax1g,iBLK)=&
                State_VGB(iVar,imin1p:imax1p-Dn,   jmin1p, kmin1p:kmax1p,iBLK)
           State_VGB(iVar,     imin2g+2*Dn:imax2g, jmin2g, kmin2g:kmax2g,iBLK)=&
                State_VGB(iVar,imin1p:imax1p-2*Dn, jmin1p, kmin1p:kmax1p,iBLK)
        case(north_)
           State_VGB(iVar,     imin1g:imax1g-Dn,   jmin1g, kmin1g:kmax1g,iBLK)=&
                State_VGB(iVar,imin1p+Dn:imax1g,   jmin1p, kmin1p:kmax1p,iBLK)
           State_VGB(iVar,     imin2g:imax2g-2*Dn, jmin2g, kmin2g:kmax2g,iBLK)=&
                State_VGB(iVar,imin1p+2*Dn:imax1p, jmin1p, kmin1p:kmax1p,iBLK)
        end select
     else
        ! ShockSlope < 1
        Dn = nint(cOne/ShockSlope)
        if(abs(Dn-cOne/ShockSlope)>cTiny)call stop_mpi( &
             'ShockSlope < 1 should be the inverse of a round number!')
        select case(iside)
           ! Shift parallel to Y by Dn
        case(east_)
           State_VGB(iVar,     imin1g, jmin1g+Dn:jmax1g,   kmin1g:kmax1g,iBLK)=&
                State_VGB(iVar,imin1p, jmin1p:jmax1p-Dn,   kmin1p:kmax1p,iBLK)

           State_VGB(iVar,     imin2g, jmin2g+2*Dn:jmax2g, kmin2g:kmax2g,iBLK)=&
                State_VGB(iVar,imin1p, jmin1p:jmax1p-2*Dn, kmin1p:kmax1p,iBLK)
        case(west_)
           State_VGB(iVar,    imin1g,  jmin1g:jmax1g-Dn,   kmin1g:kmax1g,iBLK)=&
                State_VGB(iVar,imin1p, jmin1p+Dn:jmax1p,   kmin1p:kmax1p,iBLK)
           State_VGB(iVar,     imin2g, jmin2g:jmax2g-2*Dn, kmin2g:kmax2g,iBLK)=&
                State_VGB(iVar,imin1p, jmin1p+2*Dn:jmax1p, kmin1p:kmax1p,iBLK)

           ! Shift parallel to X by 1, but copy from distance Dn in Y
        case(south_)
           State_VGB(iVar,     imin1g+1:imax1g,   jmin1g,    kmin1g:kmax1g,iBLK)=&
                State_VGB(iVar,imin1p  :imax1p-1, jmin1g+Dn, kmin1p:kmax1p,iBLK)
           State_VGB(iVar,     imin2g+1:imax2g,   jmin2g,    kmin2g:kmax2g,iBLK)=&
                State_VGB(iVar,imin1p  :imax1p-1, jmin2g+Dn, kmin1p:kmax1p,iBLK)
        case(north_)
           State_VGB(iVar,     imin1g  :imax1g-1, jmin1g,    kmin1g:kmax1g,iBLK)=&
                State_VGB(iVar,imin1p+1:imax1p,   jmin1g-Dn, kmin1p:kmax1p,iBLK)
           State_VGB(iVar,     imin2g  :imax2g-1, jmin2g,    kmin2g:kmax2g,iBLK)=&
                State_VGB(iVar,imin1p+1:imax1p,   jmin2g-Dn, kmin1p:kmax1p,iBLK)
        end select
     end if
  end do
end subroutine BC_shear

subroutine BC_symm(iVarStart,iVarLast)
  use ModSetOuterBC
  use ModVarIndexes
  use ModAdvance, ONLY : State_VGB
  implicit none
  ! Mirror symmetry: q_BLK(ghost)= -q_BLK(phys)

  integer, intent(in) :: iVarStart,iVarLast

  State_VGB(iVarStart:iVarLast, imin1g:imax1g,jmin1g:jmax1g,kmin1g:kmax1g,iBLK)=&
       State_VGB(iVarStart:iVarLast,imin1p:imax1p,jmin1p:jmax1p,kmin1p:kmax1p,iBLK)
  State_VGB(iVarStart:iVarLast,imin2g:imax2g,jmin2g:jmax2g,kmin2g:kmax2g,iBLK)=&
       State_VGB(iVarStart:iVarLast,imin2p:imax2p,jmin2p:jmax2p,kmin2p:kmax2p,iBLK)

end subroutine BC_symm

!==========================================================================  
subroutine BC_asymm(iVarStart,iVarLast)
  use ModSetOuterBC
  use ModVarIndexes
  use ModAdvance, ONLY : State_VGB
  ! Mirror symmetry with sign change: q_BLK(ghost)= -q_BLK(phys)

  integer, intent(in) :: iVarStart,iVarLast

  State_VGB(iVarStart:iVarLast, imin1g:imax1g,jmin1g:jmax1g,kmin1g:kmax1g,iBLK)=&
       - State_VGB(iVarStart:iVarLast, imin1p:imax1p,jmin1p:jmax1p,kmin1p:kmax1p,iBLK)
  State_VGB(iVarStart:iVarLast,imin2g:imax2g,jmin2g:jmax2g,kmin2g:kmax2g,iBLK)=&
       -  State_VGB(iVarStart:iVarLast,imin2p:imax2p,jmin2p:jmax2p,kmin2p:kmax2p,iBLK)

end subroutine BC_asymm

!==========================================================================  
subroutine BC_fixed(iVarStart,iVarLast,q)
  use ModVarIndexes
  use ModAdvance, ONLY : State_VGB
  use ModSetOuterBC
  ! Set q_B=q in ghost cells

  integer, intent(in) :: iVarStart,iVarLast
  real,dimension(nVar), intent(in)    :: q
  integer::i,j,k
  do k=kmin1g,kmax1g; do j=jmin1g,jmax1g; do i=imin1g,imax1g
     State_VGB(iVarStart:iVarLast,i,j,k,iBLK)=&
          q(iVarStart:iVarLast)
  end do;end do;end do
  do k=kmin2g,kmax2g; do j=jmin2g,jmax2g; do i=imin2g,imax2g
     State_VGB(iVarStart:iVarLast,i,j,k,iBLK)=&
          q(iVarStart:iVarLast)
  end do;end do;end do

end subroutine BC_fixed

!==========================================================================  
subroutine BC_fixed_B
  use ModSetOuterBC
  use ModVarIndexes
  use ModAdvance, ONLY : State_VGB,B0xCell_BLK,B0yCell_BLK,B0zCell_BLK
  ! Set q_B=q-q_B0 in ghost cells

  State_VGB(Bx_,imin1g:imax1g,jmin1g:jmax1g,kmin1g:kmax1g,iBLK)= &
       State_VGB(Bx_,imin1g:imax1g,jmin1g:jmax1g,kmin1g:kmax1g,iBLK)&
       - B0xCell_BLK(imin1g:imax1g,jmin1g:jmax1g,kmin1g:kmax1g,iBLK)
  State_VGB(By_,imin1g:imax1g,jmin1g:jmax1g,kmin1g:kmax1g,iBLK)= &
       State_VGB(By_,imin1g:imax1g,jmin1g:jmax1g,kmin1g:kmax1g,iBLK)&
       - B0yCell_BLK(imin1g:imax1g,jmin1g:jmax1g,kmin1g:kmax1g,iBLK)
  State_VGB(Bz_,imin1g:imax1g,jmin1g:jmax1g,kmin1g:kmax1g,iBLK)= &
       State_VGB(Bz_,imin1g:imax1g,jmin1g:jmax1g,kmin1g:kmax1g,iBLK)&
       - B0zCell_BLK(imin1g:imax1g,jmin1g:jmax1g,kmin1g:kmax1g,iBLK)
  State_VGB(Bx_,imin2g:imax2g,jmin2g:jmax2g,kmin2g:kmax2g,iBLK)= &
       State_VGB(Bx_,imin2g:imax2g,jmin2g:jmax2g,kmin2g:kmax2g,iBLK)&
       - B0xCell_BLK(imin2g:imax2g,jmin2g:jmax2g,kmin2g:kmax2g,iBLK)
  State_VGB(By_,imin2g:imax2g,jmin2g:jmax2g,kmin2g:kmax2g,iBLK)= &
       State_VGB(By_,imin2g:imax2g,jmin2g:jmax2g,kmin2g:kmax2g,iBLK)&
       - B0yCell_BLK(imin2g:imax2g,jmin2g:jmax2g,kmin2g:kmax2g,iBLK)
  State_VGB(Bz_,imin2g:imax2g,jmin2g:jmax2g,kmin2g:kmax2g,iBLK)= &
       State_VGB(Bz_,imin2g:imax2g,jmin2g:jmax2g,kmin2g:kmax2g,iBLK)&
       - B0zCell_BLK(imin2g:imax2g,jmin2g:jmax2g,kmin2g:kmax2g,iBLK)

end subroutine BC_fixed_B

!==========================================================================  

subroutine BC_solar_wind(time_now)
  use ModGeometry,ONLY:z_BLK,y_BLK
  use ModVarIndexes
  use ModAdvance, ONLY : State_VGB, B0xCell_BLK, B0yCell_BLK, B0zCell_BLK
  use ModSetOuterBC
  use ModMultiFluid, ONLY: select_fluid, iFluid, &
       iRho, iRhoUx, iRhoUy, iRhoUz, iP, MassIon_I
  use ModPhysics, ONLY: LowDensityRatio

  implicit none

  ! Current simulation time in seconds
  real, intent(in) :: time_now 

  ! index and location of a single point
  integer :: i,j,k
  real :: y,z
  ! Varying solar wind parameters
  real :: rho, Ux, Uy, Uz, p, Bx, By, Bz
  !-----------------------------------------------------------------------
  do k=kmin1g,kmax1g 
     z = z_BLK(1,1,k,iBLK)
     do j=jmin1g,jmax2g
        y = y_BLK(1,j,1,iBLK)
        do i=imin1g,imax2g,sign(1,imax2g-imin1g)
           call get_solar_wind_point(time_now, y, z, &
                Rho, Ux, Uy, Uz, Bx, By, Bz, p)
           State_VGB(rho_,i,j,k,iBLK)   = Rho
           State_VGB(rhoUx_,i,j,k,iBLK) = Rho*Ux
           State_VGB(rhoUy_,i,j,k,iBLK) = Rho*Uy
           State_VGB(rhoUz_,i,j,k,iBLK) = Rho*Uz
           State_VGB(Bx_,i,j,k,iBLK)    = Bx - B0xCell_BLK(i,j,k,iBLK)
           State_VGB(By_,i,j,k,iBLK)    = By - B0yCell_BLK(i,j,k,iBLK)
           State_VGB(Bz_,i,j,k,iBLK)    = Bz - B0zCell_BLK(i,j,k,iBLK)
           State_VGB(P_,i,j,k,iBLK)     = p
           do iFluid = IonFirst_+1, nFluid
              call select_fluid
              State_VGB(iRho,   i,j,k,iBLK) = Rho   *LowDensityRatio
              State_VGB(iRhoUx, i,j,k,iBLK) = Rho*Ux*LowDensityRatio
              State_VGB(iRhoUy, i,j,k,iBLK) = Rho*Uy*LowDensityRatio
              State_VGB(iRhoUz, i,j,k,iBLK) = Rho*Uz*LowDensityRatio
              State_VGB(iP,     i,j,k,iBLK) = p     *LowDensityRatio &
                   *MassIon_I(1)/MassFluid_I(iFluid)
           end do

        end do
     end do
  end do

end subroutine BC_solar_wind

!==========================================================================  

subroutine BC_solar_wind_buffer

  use ModGeometry, ONLY: z_BLK, y_BLK
  use ModVarIndexes, ONLY: Bx_, By_, Bz_
  use ModAdvance, ONLY : State_VGB, B0xCell_BLK,B0yCell_BLK,B0zCell_BLK
  use ModSetOuterBC

  implicit none

  ! index and location of a single point
  integer :: i, j, k
  real    :: y, z
  !-----------------------------------------------------------------------
  do k=kmin1g,kmax1g 
     z = z_BLK(1,1,k,iBLK)
     do j=jmin1g,jmax2g
        y = y_BLK(1,j,1,iBLK)
        do i=imin1g,imax2g,sign(1,imax2g-imin1g)
           call read_ih_buffer(y,z,State_VGB(:,i,j,k,iBlk))
           ! Subtract B0
           State_VGB(Bx_,i,j,k,iBLK) = State_VGB(Bx_,i,j,k,iBLK) &
                - B0xCell_BLK(i,j,k,iBLK)
           State_VGB(By_,i,j,k,iBLK) = State_VGB(By_,i,j,k,iBLK) &
                - B0yCell_BLK(i,j,k,iBLK)
           State_VGB(Bz_,i,j,k,iBLK) = State_VGB(Bz_,i,j,k,iBLK) &
                - B0zCell_BLK(i,j,k,iBLK)
        end do
     end do
  end do

end subroutine BC_solar_wind_buffer
!==========================================================================


