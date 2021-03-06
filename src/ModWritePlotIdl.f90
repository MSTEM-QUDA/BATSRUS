!  Copyright (C) 2002 Regents of the University of Michigan,
!  portions used with permission
!  For more information, see http://csem.engin.umich.edu/tools/swmf
module ModWritePlotIdl

  use BATL_lib, ONLY: &
       test_start, test_stop, StringTest

  implicit none

  private ! except

  public:: write_plot_idl

contains
  !============================================================================
  subroutine write_plot_idl(iFile, iBlock, nPlotVar, PlotVar, &
       DoSaveGenCoord, xUnit, xMin, xMax, yMin, yMax, zMin, zMax, &
       DxBlock, DyBlock, DzBlock, nCell)

    ! Save all cells within plotting range, for each processor

    use ModGeometry, ONLY: x1, x2, y1, y2, z1, z2, XyzStart_BLK
    use ModIO,       ONLY: save_binary, plot_type1, plot_dx, plot_range, &
         nPlotVarMax
    use ModNumConst, ONLY: cPi, cTwoPi
    use ModKind,     ONLY: nByteReal
    use ModIoUnit,   ONLY: UnitTmp_
    use ModAdvance,  ONLY: State_VGB, Bx_
    use ModB0,       ONLY: B0_DGB
    use BATL_size,   ONLY: nGI, nGJ, nGK, nDim
    use BATL_lib,    ONLY: IsRLonLat, IsCylindrical, &
         CoordMin_D, CoordMax_D, CoordMin_DB, CellSize_DB, &
         nI, nJ, nK, MinI, MaxI, MinJ, MaxJ, MinK, MaxK, &
         Xyz_DGB, x_, y_, z_, Phi_
    use ModUtilities, ONLY: greatest_common_divisor

    ! Arguments

    integer, intent(in)   :: iFile, iBlock
    integer, intent(in)   :: nPlotVar
    real,    intent(in)   :: PlotVar(MinI:MaxI,MinJ:MaxJ,MinK:MaxK,nPlotVar)
    logical, intent(in)   :: DoSaveGenCoord      ! save gen. or x,y,z coords
    real,    intent(in)   :: xUnit               ! unit for coordinates
    real,    intent(in)   :: xMin, xMax, yMin, yMax, zMin, zMax
    real,    intent(inout):: DxBlock, DyBlock, DzBlock
    integer, intent(out)  :: nCell

    ! Local variables
    ! Indices and coordinates
    integer :: iVar, i, j, k, i2, j2, k2, iMin, iMax, jMin, jMax, kMin, kMax
    integer :: nRestrict, nRestrictX, nRestrictY, nRestrictZ
    real :: Coord_D(3), x, y, z, ySqueezed, Dx, Restrict
    real :: xMin1, xMax1, yMin1, yMax1, zMin1, zMax1
    real :: Plot_V(nPlotVar)
    logical:: IsBinary

    real:: cHalfMinusTiny

    logical:: DoTest
    character(len=*), parameter:: NameSub = 'write_plot_idl'
    !--------------------------------------------------------------------------
    call test_start(NameSub, DoTest, iBlock)

    if(nByteReal == 8)then
       cHalfMinusTiny = 0.5*(1.0 - 1e-9)
    else
       cHalfMinusTiny = 0.5*(1.0 - 1e-6)
    end if

    IsBinary = save_binary .and. plot_type1 /= 'cut_pic'

    ! Initialize number of cells saved from this block
    ! Note that if this is moved inside the if statement
    ! the NAG compiler with optimization on fails !
    nCell = 0

    if(index(StringTest,'SAVEPLOTALL')>0)then

       ! Save all cells of block including ghost cells
       DxBlock = CellSize_DB(x_,iBlock)
       DyBlock = CellSize_DB(y_,iBlock)
       DzBlock = CellSize_DB(z_,iBlock)

       plot_range(1,iFile) = CoordMin_D(1) - nGI*DxBlock
       plot_range(2,iFile) = CoordMax_D(1) + nGI*DxBlock
       plot_range(3,iFile) = CoordMin_D(2) - nGJ*DyBlock
       plot_range(4,iFile) = CoordMax_D(2) + nGJ*DyBlock
       plot_range(5,iFile) = CoordMin_D(3) - nGK*DzBlock
       plot_range(6,iFile) = CoordMax_D(3) + nGK*DzBlock
       plot_Dx(1,iFile) = DxBlock
       plot_Dx(2,iFile) = DyBlock
       plot_Dx(3,iFile) = DzBlock

       do k = MinK, MaxK; do j = MinJ, MaxJ; do i = MinI, MaxI
          nCell = nCell + 1
          if(DoSaveGenCoord)then
             Coord_D = CoordMin_DB(:,iBlock) &
                  + ([i,j,k] - 0.5)*CellSize_DB(:,iBlock)
          else
             Coord_D = Xyz_DGB(:,i,j,k,iBlock)*xUnit
          end if
          if(IsBinary)then
             Plot_V = PlotVar(i,j,k,1:nPlotVar)
             write(UnitTmp_) DxBlock*xUnit, Coord_D, Plot_V
          else
             do iVar=1,nPlotVar
                Plot_V(iVar) = PlotVar(i,j,k,iVar)
                if(abs(Plot_V(iVar))<1.0d-99)Plot_V(iVar)=0.0
             end do
             write(UnitTmp_,'(50(1pe13.5))') &
                  DxBlock*xUnit, Coord_D, Plot_V(1:nPlotVar)
          endif
       end do; end do; end do

       RETURN

    end if

    ! The range for the cell centers is Dx/2 wider
    xMin1 = xMin - cHalfMinusTiny*CellSize_DB(x_,iBlock)
    xMax1 = xMax + cHalfMinusTiny*CellSize_DB(x_,iBlock)
    yMin1 = yMin - cHalfMinusTiny*CellSize_DB(y_,iBlock)
    yMax1 = yMax + cHalfMinusTiny*CellSize_DB(y_,iBlock)
    zMin1 = zMin - cHalfMinusTiny*CellSize_DB(z_,iBlock)
    zMax1 = zMax + cHalfMinusTiny*CellSize_DB(z_,iBlock)

    if((IsRLonLat .or. IsCylindrical) .and. .not.DoSaveGenCoord)then
       ! Make sure that angles around 3Pi/2 are moved to Pi/2 for x=0 cut
       ySqueezed = mod(xyzStart_BLK(Phi_,iBlock),cPi)
       ! Make sure that small angles are moved to Pi degrees for y=0 cut
       if(ySqueezed < 0.25*cPi .and. &
            abs(yMin+yMax-cTwoPi) < 1e-6 .and. yMax-yMin < 0.01) &
            ySqueezed = ySqueezed + cPi
    else
       ySqueezed = xyzStart_BLK(y_,iBlock)
    end if

    if(DoTest)then
       write(*,*) NameSub, 'xMin1,xMax1,yMin1,yMax1,zMin1,zMax1=',&
            xMin1,xMax1,yMin1,yMax1,zMin1,zMax1
       write(*,*) NameSub, 'xyzStart_BLK=',iBlock,xyzStart_BLK(:,iBlock)
       write(*,*) NameSub, 'ySqueezed =',ySqueezed
       write(*,*) NameSub, 'xyzEnd=', &
            xyzStart_BLK(x_,iBlock)+(nI-1)*CellSize_DB(x_,iBlock),&
            ySqueezed + (nJ-1)*CellSize_DB(y_,iBlock),&
            xyzStart_BLK(z_,iBlock)+(nK-1)*CellSize_DB(z_,iBlock)
    end if

    ! If block is fully outside of cut then cycle
    if(  xyzStart_BLK(x_,iBlock) > xMax1.or.&
         xyzStart_BLK(x_,iBlock)+(nI-1)*CellSize_DB(x_,iBlock) < xMin1.or.&
         ySqueezed > yMax1.or.&
         ySqueezed+(nJ-1)*CellSize_DB(y_,iBlock) < yMin1.or.&
         xyzStart_BLK(z_,iBlock) > zMax1.or.&
         xyzStart_BLK(z_,iBlock)+(nK-1)*CellSize_DB(z_,iBlock) < zMin1)&
         RETURN

    Dx = plot_Dx(1,iFile)
    DxBlock = CellSize_DB(x_,iBlock)
    DyBlock = CellSize_DB(y_,iBlock)
    DzBlock = CellSize_DB(z_,iBlock)

    ! Calculate index limits of cells inside cut
    iMin = max(1 ,floor((xMin1-xyzStart_BLK(x_,iBlock))/DxBlock)+2)
    iMax = min(nI,floor((xMax1-xyzStart_BLK(x_,iBlock))/DxBlock)+1)

    jMin = max(1 ,floor((yMin1-ySqueezed)/DyBlock)+2)
    jMax = min(nJ,floor((yMax1-ySqueezed)/DyBlock)+1)

    kMin = max(1 ,floor((zMin1-xyzStart_BLK(z_,iBlock))/DzBlock)+2)
    kMax = min(nK,floor((zMax1-xyzStart_BLK(z_,iBlock))/DzBlock)+1)

    if(DoTest)then
       write(*,*) NameSub, 'iMin,iMax,jMin,jMax,kMin,kMax=',&
            iMin,iMax,jMin,jMax,kMin,kMax
       write(*,*) NameSub, 'DxBlock,x1,y1,z1',DxBlock,xyzStart_BLK(:,iBlock)
       write(*,*) NameSub, 'ySqueezed  =',ySqueezed
       write(*,*) NameSub, 'xMin1,xMax1=',xMin1,xMax1
       write(*,*) NameSub, 'yMin1,yMax1=',yMin1,yMax1
       write(*,*) NameSub, 'zMin1,zMax1=',zMin1,zMax1
    end if

    if(DxBlock >= Dx)then
       ! Cell is equal or coarser than Dx, save all cells in cut
       do k=kMin,kMax; do j=jMin,jMax; do i=iMin,iMax
          x = Xyz_DGB(x_,i,j,k,iBlock)
          y = Xyz_DGB(y_,i,j,k,iBlock)
          z = Xyz_DGB(z_,i,j,k,iBlock)

          ! Check if we are inside the Cartesian box
          if(x<x1 .or. x>x2 .or. y<y1 .or. y>y2 .or. z<z1 .or. z>z2) CYCLE

          ! if plot type is bx0
          if(index(plot_type1, 'bx0') > 0) then
             ! check if bx are the same sign in this block
             if( all(B0_DGB(x_,i,j,k-1:k+1,iBlock)+State_VGB(Bx_,i,j,k-1:k+1,iBlock)>0) .or.&
                  all(B0_DGB(x_,i,j,k-1:k+1,iBlock)+State_VGB(Bx_,i,j,k-1:k+1,iBlock)<0)) CYCLE
             ! exclude the edge points at the plot range boundary
             if( abs(Xyz_DGB(z_,i,j,k,iBlock) - plot_range(5,iFile))/DzBlock <= 3 .or.&
                  abs(Xyz_DGB(z_,i,j,k,iBlock) - plot_range(6,iFile))/DzBlock <= 3) CYCLE
          end if

          if(DoSaveGenCoord)then
             Coord_D = CoordMin_DB(:,iBlock) &
                  + ([i,j,k] - 0.5)*CellSize_DB(:,iBlock)
          else
             Coord_D = Xyz_DGB(:,i,j,k,iBlock)*xUnit
          end if

          if(IsBinary)then
             Plot_V = PlotVar(i,j,k,1:nPlotVar)
             write(UnitTmp_) DxBlock*xUnit, Coord_D, Plot_V
          else
             do iVar=1, nPlotVar
                Plot_V(iVar) = PlotVar(i,j,k,iVar)
                if(abs(Plot_V(iVar)) < 1.0d-99) Plot_V(iVar) = 0.0
             end do
             write(UnitTmp_,'(50es13.5)') &
                  DxBlock*xUnit, Coord_D, Plot_V(1:nPlotVar)
          endif
          nCell = nCell + 1
       end do; end do; end do
    else
       ! Block is finer then required resolution
       ! Calculate restriction factor
       nRestrict = greatest_common_divisor(nint(Dx/DxBlock), iMax-iMin+1)
       if(nDim > 1) nRestrict = greatest_common_divisor(nRestrict, jMax-jMin+1)
       if(nDim > 2) nRestrict = greatest_common_divisor(nRestrict, kMax-kMin+1)

       nRestrictX = nRestrict
       nRestrictY = 1; if(nDim > 1) nRestrictY = nRestrict
       nRestrictZ = 1; if(nDim > 2) nRestrictZ = nRestrict

       ! Calculate restricted cell size
       DxBlock    = nRestrictX*DxBlock
       DyBlock    = nRestrictY*DyBlock
       DzBlock    = nRestrictZ*DzBlock

       ! Factor for taking the average
       Restrict = 1./(nRestrict**nDim)

       if(DoTest) write(*,*) NameSub,': nRestrict, X, Y, Z, Restrict=',&
            nRestrict, nRestrictX, nRestrictY, nRestrictZ, Restrict

       ! Loop for the nRestrictX*nRestrictY*nRestrictZ bricks inside the cut
       do k = kMin, kMax, nRestrictZ
          k2 = k + nRestrictZ - 1
          do j = jMin, jMax, nRestrictY
             j2 = j + nRestrictY - 1
             do i = iMin, iMax, nRestrictX
                i2 = i + nRestrictX - 1
                x =0.5*(Xyz_DGB(x_,i,j,k,iBlock) + Xyz_DGB(x_,i2,j2,k2,iBlock))
                y =0.5*(Xyz_DGB(y_,i,j,k,iBlock) + Xyz_DGB(y_,i2,j2,k2,iBlock))
                z =0.5*(Xyz_DGB(z_,i,j,k,iBlock) + Xyz_DGB(z_,i2,j2,k2,iBlock))

                if(x<x1 .or. x>x2 .or. y<y1 .or. y>y2 .or. z<z1 .or. z>z2) &
                     CYCLE

                if(DoSaveGenCoord)then
                   Coord_D = CoordMin_DB(:,iBlock) &
                        + (0.5*[i+i2,j+j2,k+k2] - 0.5)*CellSize_DB(:,iBlock)
                else
                   Coord_D = [x, y, z]*xUnit
                end if

                do iVar=1,nPlotVar
                   Plot_V(iVar) = Restrict*sum(PlotVar(i:i2,j:j2,k:k2,iVar))
                end do
                if(IsBinary)then
                   write(UnitTmp_)DxBlock*xUnit, Coord_D, Plot_V(1:nPlotVar)
                else
                   do iVar = 1, nPlotVar
                      if(abs(Plot_V(iVar)) < 1.0d-99)Plot_V(iVar)=0.0
                   end do
                   write(UnitTmp_,'(50es13.5)') &
                        DxBlock*xUnit, Coord_D, Plot_V(1:nPlotVar)
                endif
                nCell = nCell + 1
             end do
          end do
       end do
    end if

    call test_stop(NameSub, DoTest, iBlock)
  end subroutine write_plot_idl
  !============================================================================

end module ModWritePlotIdl
!==============================================================================
