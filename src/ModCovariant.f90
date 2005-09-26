!^CFG COPYRIGHT UM
!^CFG FILE COVARIANT
module ModCovariant
  use ModSize
  use ModNumConst
  implicit none
  save
 
  real,dimension(nBLK) :: &
       FaceArea2MinI_B, FaceArea2MinJ_B,FaceArea2MinK_B
  
  logical::UseCovariant=.false.


  !For a vertex-based logically cartesian (spherical, cylindircal) grid 
  !(UseVertexBasedGrid=.true.) the node coordinates are defined
  !in terms of an arbitrary pointwide transformation of nodes of an 
  !original cartesian (spherical,cylindrical) block adaptive grid.
  !Advantage: the possiblity to use the arbitrary transformation.
  !Disadvantages: the cell center coordinates can not be definied unambigously
  !and the difference of the state variables across the face does not evaluate
  !the gradient in the direction, normal to this face (stricly speaking).
  !Cell-centered grids are used if UseVertexBasedGrid=.false. (default value)
  !Advantage: for some particular geometries (spherical, cylindrical) the 
  !control volumes are the Voronoy cells (any face is perpendicular to the line
  !connecting the centers of the neighboring cells). 
  !Disadvantages: even in these particular cases it is not easy to properly define 
  !the face area vectors at the resolution change. More general cell-centered grid 
  !either is not logically cartesian, or does not consist of the Voronoy cells only.
  !
  logical :: UseVertexBasedGrid=.false.
  character (len=20) ::TypeGeometry='cartesian'                            
  real,allocatable,dimension(:,:,:,:,:):: &            
        FaceAreaI_DFB,FaceAreaJ_DFB,FaceAreaK_DFB
  integer,allocatable,dimension(:,:,:,:)::OldLevel_IIIB
contains
  subroutine allocate_face_area_vectors
    if(allocated(FaceAreaI_DFB))return
    allocate(FaceAreaI_DFB(nDim,1:nI+1,1:nJ,1:nK,nBLK))
    allocate(FaceAreaJ_DFB(nDim,1:nI,1:nJ+1,1:nK,nBLK))
    allocate(FaceAreaK_DFB(nDim,1:nI,1:nJ,1:nK+1,nBLK))
    FaceAreaI_DFB=cOne; FaceAreaJ_DFB=cOne; FaceAreaK_DFB=cOne
  end subroutine allocate_face_area_vectors
!---------------------------------------------------------------------------------
  subroutine allocate_old_levels
    if(allocated(OldLevel_IIIB))return
    allocate(OldLevel_IIIB(-1:1,-1:1,-1:1,nBLK))
  end subroutine allocate_old_levels
!---------------------------------------------------------------------------------
  function cross_product(A_D,B_D)
    real,dimension(nDim)::cross_product
    real,dimension(nDim),intent(in)::A_D,B_D
    cross_product(1)=A_D(2)*B_D(3)-A_D(3)*B_D(2)
    cross_product(2)=A_D(3)*B_D(1)-A_D(1)*B_D(3)
    cross_product(3)=A_D(1)*B_D(2)-A_D(2)*B_D(1)
  end function cross_product
!---------------------------------------------------------------------------------
  subroutine get_face_area_i(&
       XyzNodes_DIII,&                      !(in) Cartesian coordinates of nodes
       iStart,iMax,jStart,jMax,kStart,kMax,&!(in) FACE indexes. 
       FaceAreaI_DF)                        !(out)Face area vectors
    !-----------------------------------------------------------------------------
    integer,intent(in)::iStart,iMax,jStart,jMax,kStart,kMax
    real,intent(in),dimension(nDim,iStart:iMax,jStart:jMax+1,kStart:kMax+1)::&
         XyzNodes_DIII
    real,intent(out),dimension(nDim,iStart:iMax,jStart:jMax,kStart:kMax)::&
         FaceAreaI_DF
    !-----------------------------------------------------------------------------
    integer::i,j,k
    do k=kStart,kMax; do j=jStart,jMax; do i=iStart,iMax
       FaceAreaI_DF(:,i,j,k)=cHalf*&
            cross_product(XyzNodes_DIII(:,i,j+1,k+1)-XyzNodes_DIII(:,i,j  ,k),&
                          XyzNodes_DIII(:,i,j  ,k+1)-XyzNodes_DIII(:,i,j+1,k))
    end do; end do; end do
  end subroutine get_face_area_i
!---------------------------------------------------------------------------------
  subroutine get_face_area_j(&
       XyzNodes_DIII,&                      !(in) Cartesian coordinates of nodes
       iStart,iMax,jStart,jMax,kStart,kMax,&!(in) FACE indexes. 
       FaceAreaJ_DF)                        !(out)Face area vectors
    !-----------------------------------------------------------------------------
    integer,intent(in)::iStart,iMax,jStart,jMax,kStart,kMax
    real,intent(in),dimension(nDim,iStart:iMax+1,jStart:jMax,kStart:kMax+1)::&
         XyzNodes_DIII
    real,intent(out),dimension(nDim,iStart:iMax,jStart:jMax,kStart:kMax)::&
         FaceAreaJ_DF
    !-----------------------------------------------------------------------------
    integer::i,j,k
    do k=kStart,kMax; do j=jStart,jMax; do i=iStart,iMax
       FaceAreaJ_DF(:,i,j,k)=cHalf*&
            cross_product(XyzNodes_DIII(:,i+1,j,k+1)-XyzNodes_DIII(:,i,j  ,k),&
                          XyzNodes_DIII(:,i+1,j  ,k)-XyzNodes_DIII(:,i,j,k+1))
    end do; end do; end do
  end subroutine get_face_area_j
!---------------------------------------------------------------------------------
  subroutine get_face_area_k(&
       XyzNodes_DIII,&                      !(in) Cartesian coordinates of nodes
       iStart,iMax,jStart,jMax,kStart,kMax,&!(in) FACE indexes. 
       FaceAreaK_DF)                        !(out)Face area vectors
    !-----------------------------------------------------------------------------
    integer,intent(in)::iStart,iMax,jStart,jMax,kStart,kMax
    real,intent(in),dimension(nDim,iStart:iMax+1,jStart:jMax+1,kStart:kMax)::&
         XyzNodes_DIII
    real,intent(out),dimension(nDim,iStart:iMax,jStart:jMax,kStart:kMax)::&
         FaceAreaK_DF
    !-----------------------------------------------------------------------------
    integer::i,j,k
    do k=kStart,kMax; do j=jStart,jMax; do i=iStart,iMax
       FaceAreaK_DF(:,i,j,k)=cHalf*&
            cross_product(XyzNodes_DIII(:,i+1,j+1,k)-XyzNodes_DIII(:,i,j  ,k),&
                          XyzNodes_DIII(:,i,j+1  ,k)-XyzNodes_DIII(:,i+1,j,k))
    end do; end do; end do
  end subroutine get_face_area_k
!-------------------------------------------------------------!
  
end module ModCovariant


