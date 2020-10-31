!> Incompressible flow solver class:
!> Provides support for various BC, RHS calculation,
!> implicit solver, and pressure solution
!> Assumes constant viscosity and density.
module incomp_class
   use precision,      only: WP
   use string,         only: str_medium
   use config_class,   only: config
   use ils_class,      only: ils
   use iterator_class, only: iterator
   implicit none
   private
   
   ! Expose type/constructor/methods
   public :: incomp
   
   ! List of known available bcond for this solver
   integer, parameter, public :: dirichlet=1
   integer, parameter, public :: neumann  =2
   
   
   !> Boundary conditions for the incompressible solver
   type :: bcond
      type(bcond), pointer :: next                        !< Linked list of bcs
      character(len=str_medium) :: name='UNNAMED_BCOND'   !< Bcond name (default=UNNAMED_BCOND)
      integer :: type                                     !< Boundary condition type
      type(iterator) :: itr                               !< This is the iterator for the bcond
   end type bcond
   
   
   !> Incompressible solver object definition
   type :: incomp
      
      ! This is our config
      class(config), pointer :: cfg                       !< This is the config the solver is build for
      
      ! This is the name of the solver
      character(len=str_medium) :: name='UNNAMED_INCOMP'  !< Solver name (default=UNNAMED_INCOMP)
      
      ! Constant property fluid
      real(WP) :: rho                                     !< This is our constant fluid density
      real(WP) :: visc                                    !< These is our constant fluid dynamic viscosity
      
      ! Boundary condition list
      type(bcond), pointer :: first_bc                    !< List of bcond for our solver
      
      ! Flow variables
      real(WP), dimension(:,:,:), allocatable :: U        !< U velocity array
      real(WP), dimension(:,:,:), allocatable :: V        !< V velocity array
      real(WP), dimension(:,:,:), allocatable :: W        !< W velocity array
      real(WP), dimension(:,:,:), allocatable :: P        !< Pressure array
      
      ! Old flow variables
      real(WP), dimension(:,:,:), allocatable :: Uold     !< Uold velocity array
      real(WP), dimension(:,:,:), allocatable :: Vold     !< Vold velocity array
      real(WP), dimension(:,:,:), allocatable :: Wold     !< Wold velocity array
      
      ! Pressure solver
      type(ils) :: psolv                                  !< Iterative linear solver object for the pressure Poisson equation
      
      ! Metrics
      real(WP), dimension(:,:,:,:), allocatable :: itpu_x,itpu_y,itpu_z   !< Interpolation for U
      real(WP), dimension(:,:,:,:), allocatable :: itpv_x,itpv_y,itpv_z   !< Interpolation for V
      real(WP), dimension(:,:,:,:), allocatable :: itpw_x,itpw_y,itpw_z   !< Interpolation for W
      real(WP), dimension(:,:,:,:), allocatable :: divp_x,divp_y,divp_z   !< Divergence for P-cell
      real(WP), dimension(:,:,:,:), allocatable :: divu_x,divu_y,divu_z   !< Divergence for U-cell
      real(WP), dimension(:,:,:,:), allocatable :: divv_x,divv_y,divv_z   !< Divergence for V-cell
      real(WP), dimension(:,:,:,:), allocatable :: divw_x,divw_y,divw_z   !< Divergence for W-cell
      real(WP), dimension(:,:,:,:), allocatable :: grdu_x,grdu_y,grdu_z   !< Velocity gradient for U
      real(WP), dimension(:,:,:,:), allocatable :: grdv_x,grdv_y,grdv_z   !< Velocity gradient for V
      real(WP), dimension(:,:,:,:), allocatable :: grdw_x,grdw_y,grdw_z   !< Velocity gradient for W
      
   contains
      procedure :: print=>incomp_print                    !< Output solver to the screen
      procedure :: add_bcond                              !< Add a boundary condition
      procedure :: init_metrics                           !< Initialize metrics
      procedure :: get_dmomdt                             !< Calculate dmom/dt
      procedure :: get_divergence                         !< Calculate velocity divergence
   end type incomp
   
   
   !> Declare incompressible solver constructor
   interface incomp
      procedure constructor
   end interface incomp
   
contains
   
   
   !> Default constructor for incompressible flow solver
   function constructor(cfg,name) result(self)
      implicit none
      type(incomp) :: self
      class(config), target, intent(in) :: cfg
      character(len=*), optional :: name
      integer :: i,j,k
      
      ! Set the name for the iterator
      if (present(name)) self%name=trim(adjustl(name))
      
      ! Point to pgrid object
      self%cfg=>cfg
      
      ! Nullify bcond list
      self%first_bc=>NULL()
      
      ! Prepare metrics
      call self%init_metrics()
      
      ! Allocate flow variables
      allocate(self%U(self%cfg%imino_:self%cfg%imaxo_,self%cfg%jmino_:self%cfg%jmaxo_,self%cfg%kmino_:self%cfg%kmaxo_)); self%U=0.0_WP
      allocate(self%V(self%cfg%imino_:self%cfg%imaxo_,self%cfg%jmino_:self%cfg%jmaxo_,self%cfg%kmino_:self%cfg%kmaxo_)); self%V=0.0_WP
      allocate(self%W(self%cfg%imino_:self%cfg%imaxo_,self%cfg%jmino_:self%cfg%jmaxo_,self%cfg%kmino_:self%cfg%kmaxo_)); self%W=0.0_WP
      allocate(self%P(self%cfg%imino_:self%cfg%imaxo_,self%cfg%jmino_:self%cfg%jmaxo_,self%cfg%kmino_:self%cfg%kmaxo_)); self%P=0.0_WP
      
      ! Allocate old flow variables
      allocate(self%Uold(self%cfg%imino_:self%cfg%imaxo_,self%cfg%jmino_:self%cfg%jmaxo_,self%cfg%kmino_:self%cfg%kmaxo_)); self%Uold=0.0_WP
      allocate(self%Vold(self%cfg%imino_:self%cfg%imaxo_,self%cfg%jmino_:self%cfg%jmaxo_,self%cfg%kmino_:self%cfg%kmaxo_)); self%Vold=0.0_WP
      allocate(self%Wold(self%cfg%imino_:self%cfg%imaxo_,self%cfg%jmino_:self%cfg%jmaxo_,self%cfg%kmino_:self%cfg%kmaxo_)); self%Wold=0.0_WP
      
      ! Create pressure solver object
      self%psolv=ils(self%cfg,"Pressure Poisson Solver")
      
      ! Set 7-pt stencil map
      self%psolv%stc(1,:)=[ 0, 0, 0]
      self%psolv%stc(2,:)=[+1, 0, 0]
      self%psolv%stc(3,:)=[-1, 0, 0]
      self%psolv%stc(4,:)=[ 0,+1, 0]
      self%psolv%stc(5,:)=[ 0,-1, 0]
      self%psolv%stc(6,:)=[ 0, 0,+1]
      self%psolv%stc(7,:)=[ 0, 0,-1]
      
      ! Setup the scaled Laplacian operator from incomp metrics: lap(*)=-vol*div(grad(*))
      do k=self%cfg%kmin_,self%cfg%kmax_
         do j=self%cfg%jmin_,self%cfg%jmax_
            do i=self%cfg%imin_,self%cfg%imax_
               ! Set Laplacian
               self%psolv%opr(1,i,j,k)=self%divp_x(1,i,j,k)*self%divu_x(-1,i+1,j,k)+&
               &                       self%divp_x(0,i,j,k)*self%divu_x( 0,i  ,j,k)+&
               &                       self%divp_y(1,i,j,k)*self%divv_y(-1,i,j+1,k)+&
               &                       self%divp_y(0,i,j,k)*self%divv_y( 0,i,j  ,k)+&
               &                       self%divp_z(1,i,j,k)*self%divw_z(-1,i,j,k+1)+&
               &                       self%divp_z(0,i,j,k)*self%divw_z( 0,i,j,k  )
               self%psolv%opr(2,i,j,k)=self%divp_x(1,i,j,k)*self%divu_x( 0,i+1,j,k)
               self%psolv%opr(3,i,j,k)=self%divp_x(0,i,j,k)*self%divu_x(-1,i  ,j,k)
               self%psolv%opr(4,i,j,k)=self%divp_y(1,i,j,k)*self%divv_y( 0,i,j+1,k)
               self%psolv%opr(5,i,j,k)=self%divp_y(0,i,j,k)*self%divv_y(-1,i,j  ,k)
               self%psolv%opr(6,i,j,k)=self%divp_z(1,i,j,k)*self%divw_z( 0,i,j,k+1)
               self%psolv%opr(7,i,j,k)=self%divp_z(0,i,j,k)*self%divw_z(-1,i,j,k  )
               ! Scale it by the cell volume
               self%psolv%opr(:,i,j,k)=-self%psolv%opr(:,i,j,k)*self%cfg%vol(i,j,k)
            end do
         end do
      end do
      
   end function constructor
   
   
   !> Metric initialization that accounts for VF
   subroutine init_metrics(this)
      implicit none
      class(incomp), intent(inout) :: this
      integer :: i,j,k
      real(WP) :: delta
      
      ! Allocate finite difference velocity interpolation coefficients
      allocate(this%itpu_x( 0:+1,this%cfg%imino_+1:this%cfg%imaxo_-1,this%cfg%jmino_+1:this%cfg%jmaxo_-1,this%cfg%kmino_+1:this%cfg%kmaxo_-1)) !< Cell-centered
      allocate(this%itpv_y( 0:+1,this%cfg%imino_+1:this%cfg%imaxo_-1,this%cfg%jmino_+1:this%cfg%jmaxo_-1,this%cfg%kmino_+1:this%cfg%kmaxo_-1)) !< Cell-centered
      allocate(this%itpw_z( 0:+1,this%cfg%imino_+1:this%cfg%imaxo_-1,this%cfg%jmino_+1:this%cfg%jmaxo_-1,this%cfg%kmino_+1:this%cfg%kmaxo_-1)) !< Cell-centered
      allocate(this%itpu_y(-1: 0,this%cfg%imino_+1:this%cfg%imaxo_  ,this%cfg%jmino_+1:this%cfg%jmaxo_  ,this%cfg%kmino_  :this%cfg%kmaxo_  )) !< Edge-centered (xy)
      allocate(this%itpv_x(-1: 0,this%cfg%imino_+1:this%cfg%imaxo_  ,this%cfg%jmino_+1:this%cfg%jmaxo_  ,this%cfg%kmino_  :this%cfg%kmaxo_  )) !< Edge-centered (xy)
      allocate(this%itpv_z(-1: 0,this%cfg%imino_  :this%cfg%imaxo_  ,this%cfg%jmino_+1:this%cfg%jmaxo_  ,this%cfg%kmino_+1:this%cfg%kmaxo_  )) !< Edge-centered (yz)
      allocate(this%itpw_y(-1: 0,this%cfg%imino_  :this%cfg%imaxo_  ,this%cfg%jmino_+1:this%cfg%jmaxo_  ,this%cfg%kmino_+1:this%cfg%kmaxo_  )) !< Edge-centered (yz)
      allocate(this%itpw_x(-1: 0,this%cfg%imino_+1:this%cfg%imaxo_  ,this%cfg%jmino_  :this%cfg%jmaxo_  ,this%cfg%kmino_+1:this%cfg%kmaxo_  )) !< Edge-centered (zx)
      allocate(this%itpu_z(-1: 0,this%cfg%imino_+1:this%cfg%imaxo_  ,this%cfg%jmino_  :this%cfg%jmaxo_  ,this%cfg%kmino_+1:this%cfg%kmaxo_  )) !< Edge-centered (zx)
      ! Create velocity interpolation coefficients to cell center [xm,ym,zm]
      do k=this%cfg%kmino_+1,this%cfg%kmaxo_-1
         do j=this%cfg%jmino_+1,this%cfg%jmaxo_-1
            do i=this%cfg%imino_+1,this%cfg%imaxo_-1
               this%itpu_x(:,i,j,k)=0.5_WP*this%cfg%VF(i,j,k)*[minval(this%cfg%VF(i-1:i,j,k)),minval(this%cfg%VF(i:i+1,j,k))] !< Linear interpolation in x of U from [x ,ym,zm]
               this%itpv_y(:,i,j,k)=0.5_WP*this%cfg%VF(i,j,k)*[minval(this%cfg%VF(i,j-1:j,k)),minval(this%cfg%VF(i,j:j+1,k))] !< Linear interpolation in y of V from [xm,y ,zm]
               this%itpw_z(:,i,j,k)=0.5_WP*this%cfg%VF(i,j,k)*[minval(this%cfg%VF(i,j,k-1:k)),minval(this%cfg%VF(i,j,k:k+1))] !< Linear interpolation in z of W from [xm,ym,z ]
            end do
         end do
      end do
      ! Create velocity interpolation coefficients to cell edge [x ,y ,zm]
      do k=this%cfg%kmino_  ,this%cfg%kmaxo_
         do j=this%cfg%jmino_+1,this%cfg%jmaxo_
            do i=this%cfg%imino_+1,this%cfg%imaxo_
               this%itpu_y(:,i,j,k)=minval(this%cfg%VF(i-1:i,j-1:j,k))*this%cfg%dymi(j)*[this%cfg%ym(j)-this%cfg%y(j),this%cfg%y(j)-this%cfg%ym(j-1)] !< Linear interpolation in y of U from [x ,ym,zm]
               this%itpv_x(:,i,j,k)=minval(this%cfg%VF(i-1:i,j-1:j,k))*this%cfg%dxmi(i)*[this%cfg%xm(i)-this%cfg%x(i),this%cfg%x(i)-this%cfg%xm(i-1)] !< Linear interpolation in x of V from [xm,y ,zm]
            end do
         end do
      end do
      ! Create velocity interpolation coefficients to cell edge [xm,y ,z ]
      do k=this%cfg%kmino_+1,this%cfg%kmaxo_
         do j=this%cfg%jmino_+1,this%cfg%jmaxo_
            do i=this%cfg%imino_  ,this%cfg%imaxo_
               this%itpv_z(:,i,j,k)=minval(this%cfg%VF(i,j-1:j,k-1:k))*this%cfg%dzmi(k)*[this%cfg%zm(k)-this%cfg%z(k),this%cfg%z(k)-this%cfg%zm(k-1)] !< Linear interpolation in z of V from [xm,y ,zm]
               this%itpw_y(:,i,j,k)=minval(this%cfg%VF(i,j-1:j,k-1:k))*this%cfg%dymi(j)*[this%cfg%ym(j)-this%cfg%y(j),this%cfg%y(j)-this%cfg%ym(j-1)] !< Linear interpolation in y of W from [xm,ym,z ]
            end do
         end do
      end do
      ! Create velocity interpolation coefficients to cell edge [x ,ym,z ]
      do k=this%cfg%kmino_+1,this%cfg%kmaxo_
         do j=this%cfg%jmino_  ,this%cfg%jmaxo_
            do i=this%cfg%imino_+1,this%cfg%imaxo_
               this%itpw_x(:,i,j,k)=minval(this%cfg%VF(i-1:i,j,k-1:k))*this%cfg%dxmi(i)*[this%cfg%xm(i)-this%cfg%x(i),this%cfg%x(i)-this%cfg%xm(i-1)] !< Linear interpolation in x of W from [xm,ym,z ]
               this%itpu_z(:,i,j,k)=minval(this%cfg%VF(i-1:i,j,k-1:k))*this%cfg%dzmi(k)*[this%cfg%zm(k)-this%cfg%z(k),this%cfg%z(k)-this%cfg%zm(k-1)] !< Linear interpolation in z of U from [x ,ym,zm]
            end do
         end do
      end do
      
      ! Allocate finite volume divergence operators
      allocate(this%divp_x( 0:+1,this%cfg%imino_+1:this%cfg%imaxo_-1,this%cfg%jmino_+1:this%cfg%jmaxo_-1,this%cfg%kmino_+1:this%cfg%kmaxo_-1)) !< Cell-centered
      allocate(this%divp_y( 0:+1,this%cfg%imino_+1:this%cfg%imaxo_-1,this%cfg%jmino_+1:this%cfg%jmaxo_-1,this%cfg%kmino_+1:this%cfg%kmaxo_-1)) !< Cell-centered
      allocate(this%divp_z( 0:+1,this%cfg%imino_+1:this%cfg%imaxo_-1,this%cfg%jmino_+1:this%cfg%jmaxo_-1,this%cfg%kmino_+1:this%cfg%kmaxo_-1)) !< Cell-centered
      allocate(this%divu_x(-1: 0,this%cfg%imino_+1:this%cfg%imaxo_  ,this%cfg%jmino_  :this%cfg%jmaxo_  ,this%cfg%kmino_  :this%cfg%kmaxo_  )) !< Face-centered (x)
      allocate(this%divu_y( 0:+1,this%cfg%imino_+1:this%cfg%imaxo_  ,this%cfg%jmino_  :this%cfg%jmaxo_  ,this%cfg%kmino_  :this%cfg%kmaxo_  )) !< Face-centered (x)
      allocate(this%divu_z( 0:+1,this%cfg%imino_+1:this%cfg%imaxo_  ,this%cfg%jmino_  :this%cfg%jmaxo_  ,this%cfg%kmino_  :this%cfg%kmaxo_  )) !< Face-centered (x)
      allocate(this%divv_x( 0:+1,this%cfg%imino_  :this%cfg%imaxo_  ,this%cfg%jmino_+1:this%cfg%jmaxo_  ,this%cfg%kmino_  :this%cfg%kmaxo_  )) !< Face-centered (y)
      allocate(this%divv_y(-1: 0,this%cfg%imino_  :this%cfg%imaxo_  ,this%cfg%jmino_+1:this%cfg%jmaxo_  ,this%cfg%kmino_  :this%cfg%kmaxo_  )) !< Face-centered (y)
      allocate(this%divv_z( 0:+1,this%cfg%imino_  :this%cfg%imaxo_  ,this%cfg%jmino_+1:this%cfg%jmaxo_  ,this%cfg%kmino_  :this%cfg%kmaxo_  )) !< Face-centered (y)
      allocate(this%divw_x( 0:+1,this%cfg%imino_  :this%cfg%imaxo_  ,this%cfg%jmino_  :this%cfg%jmaxo_  ,this%cfg%kmino_+1:this%cfg%kmaxo_  )) !< Face-centered (z)
      allocate(this%divw_y( 0:+1,this%cfg%imino_  :this%cfg%imaxo_  ,this%cfg%jmino_  :this%cfg%jmaxo_  ,this%cfg%kmino_+1:this%cfg%kmaxo_  )) !< Face-centered (z)
      allocate(this%divw_z(-1: 0,this%cfg%imino_  :this%cfg%imaxo_  ,this%cfg%jmino_  :this%cfg%jmaxo_  ,this%cfg%kmino_+1:this%cfg%kmaxo_  )) !< Face-centered (z)
      ! Create divergence operator to cell center [xm,ym,zm]
      do k=this%cfg%kmino_+1,this%cfg%kmaxo_-1
         do j=this%cfg%jmino_+1,this%cfg%jmaxo_-1
            do i=this%cfg%imino_+1,this%cfg%imaxo_-1
               this%divp_x(:,i,j,k)=this%cfg%VF(i,j,k)*this%cfg%dxi(i)*[-1.0_WP,+1.0_WP] !< FV divergence from [x ,ym,zm]
               this%divp_y(:,i,j,k)=this%cfg%VF(i,j,k)*this%cfg%dyi(j)*[-1.0_WP,+1.0_WP] !< FV divergence from [xm,y ,zm]
               this%divp_z(:,i,j,k)=this%cfg%VF(i,j,k)*this%cfg%dzi(k)*[-1.0_WP,+1.0_WP] !< FV divergence from [xm,ym,z ]
            end do
         end do
      end do
      ! Create divergence operator to cell face [x ,ym,zm]
      do k=this%cfg%kmino_  ,this%cfg%kmaxo_
         do j=this%cfg%jmino_  ,this%cfg%jmaxo_
            do i=this%cfg%imino_+1,this%cfg%imaxo_
               this%divu_x(:,i,j,k)=minval(this%cfg%VF(i-1:i,j,k))*this%cfg%dxmi(i)*[-1.0_WP,+1.0_WP] !< FV divergence from [xm,ym,zm]
               this%divu_y(:,i,j,k)=minval(this%cfg%VF(i-1:i,j,k))*this%cfg%dyi (j)*[-1.0_WP,+1.0_WP] !< FV divergence from [x ,y ,zm]
               this%divu_z(:,i,j,k)=minval(this%cfg%VF(i-1:i,j,k))*this%cfg%dzi (k)*[-1.0_WP,+1.0_WP] !< FV divergence from [x ,ym,z ]
            end do
         end do
      end do
      ! Create divergence operator to cell face [xm,y ,zm]
      do k=this%cfg%kmino_  ,this%cfg%kmaxo_
         do j=this%cfg%jmino_+1,this%cfg%jmaxo_
            do i=this%cfg%imino_  ,this%cfg%imaxo_
               this%divv_x(:,i,j,k)=minval(this%cfg%VF(i,j-1:j,k))*this%cfg%dxi (i)*[-1.0_WP,+1.0_WP] !< FV divergence from [x ,y ,zm]
               this%divv_y(:,i,j,k)=minval(this%cfg%VF(i,j-1:j,k))*this%cfg%dymi(j)*[-1.0_WP,+1.0_WP] !< FV divergence from [xm,ym,zm]
               this%divv_z(:,i,j,k)=minval(this%cfg%VF(i,j-1:j,k))*this%cfg%dzi (k)*[-1.0_WP,+1.0_WP] !< FV divergence from [xm,y ,z ]
            end do
         end do
      end do
      ! Create divergence operator to cell face [xm,ym,z ]
      do k=this%cfg%kmino_+1,this%cfg%kmaxo_
         do j=this%cfg%jmino_  ,this%cfg%jmaxo_
            do i=this%cfg%imino_  ,this%cfg%imaxo_
               this%divw_x(:,i,j,k)=minval(this%cfg%VF(i,j,k-1:k))*this%cfg%dxi (i)*[-1.0_WP,+1.0_WP] !< FV divergence from [x ,ym,z ]
               this%divw_y(:,i,j,k)=minval(this%cfg%VF(i,j,k-1:k))*this%cfg%dyi (j)*[-1.0_WP,+1.0_WP] !< FV divergence from [xm,y ,z ]
               this%divw_z(:,i,j,k)=minval(this%cfg%VF(i,j,k-1:k))*this%cfg%dzmi(k)*[-1.0_WP,+1.0_WP] !< FV divergence from [xm,ym,zm]
            end do
         end do
      end do
      
      ! Allocate finite difference velocity gradient operators
      allocate(this%grdu_x( 0:+1,this%cfg%imino_+1:this%cfg%imaxo_-1,this%cfg%jmino_+1:this%cfg%jmaxo_-1,this%cfg%kmino_+1:this%cfg%kmaxo_-1)) !< Cell-centered
      allocate(this%grdv_y( 0:+1,this%cfg%imino_+1:this%cfg%imaxo_-1,this%cfg%jmino_+1:this%cfg%jmaxo_-1,this%cfg%kmino_+1:this%cfg%kmaxo_-1)) !< Cell-centered
      allocate(this%grdw_z( 0:+1,this%cfg%imino_+1:this%cfg%imaxo_-1,this%cfg%jmino_+1:this%cfg%jmaxo_-1,this%cfg%kmino_+1:this%cfg%kmaxo_-1)) !< Cell-centered
      allocate(this%grdu_y(-1: 0,this%cfg%imino_+1:this%cfg%imaxo_  ,this%cfg%jmino_+1:this%cfg%jmaxo_  ,this%cfg%kmino_  :this%cfg%kmaxo_  )) !< Edge-centered (xy)
      allocate(this%grdv_x(-1: 0,this%cfg%imino_+1:this%cfg%imaxo_  ,this%cfg%jmino_+1:this%cfg%jmaxo_  ,this%cfg%kmino_  :this%cfg%kmaxo_  )) !< Edge-centered (xy)
      allocate(this%grdv_z(-1: 0,this%cfg%imino_  :this%cfg%imaxo_  ,this%cfg%jmino_+1:this%cfg%jmaxo_  ,this%cfg%kmino_+1:this%cfg%kmaxo_  )) !< Edge-centered (yz)
      allocate(this%grdw_y(-1: 0,this%cfg%imino_  :this%cfg%imaxo_  ,this%cfg%jmino_+1:this%cfg%jmaxo_  ,this%cfg%kmino_+1:this%cfg%kmaxo_  )) !< Edge-centered (yz)
      allocate(this%grdw_x(-1: 0,this%cfg%imino_+1:this%cfg%imaxo_  ,this%cfg%jmino_  :this%cfg%jmaxo_  ,this%cfg%kmino_+1:this%cfg%kmaxo_  )) !< Edge-centered (zx)
      allocate(this%grdu_z(-1: 0,this%cfg%imino_+1:this%cfg%imaxo_  ,this%cfg%jmino_  :this%cfg%jmaxo_  ,this%cfg%kmino_+1:this%cfg%kmaxo_  )) !< Edge-centered (zx)
      ! Create gradient coefficients to cell center [xm,ym,zm]
      do k=this%cfg%kmino_+1,this%cfg%kmaxo_-1
         do j=this%cfg%jmino_+1,this%cfg%jmaxo_-1
            do i=this%cfg%imino_+1,this%cfg%imaxo_-1
               this%grdu_x(:,i,j,k)=this%cfg%VF(i,j,k)*this%cfg%dxi(i)*[-minval(this%cfg%VF(i-1:i,j,k)),+minval(this%cfg%VF(i:i+1,j,k))] !< FD gradient in x of U from [x ,ym,zm]
               this%grdv_y(:,i,j,k)=this%cfg%VF(i,j,k)*this%cfg%dyi(i)*[-minval(this%cfg%VF(i,j-1:j,k)),+minval(this%cfg%VF(i,j:j+1,k))] !< FD gradient in y of V from [xm,y ,zm]
               this%grdw_z(:,i,j,k)=this%cfg%VF(i,j,k)*this%cfg%dzi(i)*[-minval(this%cfg%VF(i,j,k-1:k)),+minval(this%cfg%VF(i,j,k:k+1))] !< FD gradient in z of W from [xm,ym,z ]
            end do
         end do
      end do
      ! Create gradient coefficients to cell edge [x ,y ,zm]
      do k=this%cfg%kmino_  ,this%cfg%kmaxo_
         do j=this%cfg%jmino_+1,this%cfg%jmaxo_
            do i=this%cfg%imino_+1,this%cfg%imaxo_
               ! FD gradient in y of U from [x ,ym,zm]
               delta=minval(this%cfg%VF(i-1:i,j  ,k))*(this%cfg%ym(j)-this%cfg%y (j  )) &
               &    +minval(this%cfg%VF(i-1:i,j-1,k))*(this%cfg%y (j)-this%cfg%ym(j-1))
               if (delta.gt.0.0_WP) then
                  this%grdu_y(:,i,j,k)=[-minval(this%cfg%VF(i-1:i,j-1,k)),+minval(this%cfg%VF(i-1:i,j,k))]/delta
               else
                  this%grdu_y(:,i,j,k)=0.0_WP
               end if
               ! FD gradient in x of V from [xm,y ,zm]
               delta=minval(this%cfg%VF(i  ,j-1:j,k))*(this%cfg%xm(i)-this%cfg%x (i  )) &
               &    +minval(this%cfg%VF(i-1,j-1:j,k))*(this%cfg%x (i)-this%cfg%xm(i-1))
               if (delta.gt.0.0_WP) then
                  this%grdv_x(:,i,j,k)=[-minval(this%cfg%VF(i-1,j-1:j,k)),+minval(this%cfg%VF(i,j-1:j,k))]/delta
               else
                  this%grdv_x(:,i,j,k)=0.0_WP
               end if
            end do
         end do
      end do
      ! Create gradient coefficients to cell edge [xm,y ,z ]
      do k=this%cfg%kmino_+1,this%cfg%kmaxo_
         do j=this%cfg%jmino_+1,this%cfg%jmaxo_
            do i=this%cfg%imino_  ,this%cfg%imaxo_
               ! FD gradient in z of V from [xm,y ,zm]
               delta=minval(this%cfg%VF(i,j-1:j,k  ))*(this%cfg%zm(k)-this%cfg%z (k  )) &
               &    +minval(this%cfg%VF(i,j-1:j,k-1))*(this%cfg%z (k)-this%cfg%zm(k-1))
               if (delta.gt.0.0_WP) then
                  this%grdv_z(:,i,j,k)=[-minval(this%cfg%VF(i,j-1:j,k-1)),+minval(this%cfg%VF(i,j-1:j,k))]/delta
               else
                  this%grdv_z(:,i,j,k)=0.0_WP
               end if
               ! FD gradient in y of W from [xm,ym,z ]
               delta=minval(this%cfg%VF(i,j  ,k-1:k))*(this%cfg%ym(j)-this%cfg%y (j  )) &
               &    +minval(this%cfg%VF(i,j-1,k-1:k))*(this%cfg%y (j)-this%cfg%ym(j-1))
               if (delta.gt.0.0_WP) then
                  this%grdw_y(:,i,j,k)=[-minval(this%cfg%VF(i,j-1,k-1:k)),+minval(this%cfg%VF(i,j,k-1:k))]/delta
               else
                  this%grdw_y(:,i,j,k)=0.0_WP
               end if
            end do
         end do
      end do
      ! Create gradient coefficients to cell edge [x ,ym,z ]
      do k=this%cfg%kmino_+1,this%cfg%kmaxo_
         do j=this%cfg%jmino_  ,this%cfg%jmaxo_
            do i=this%cfg%imino_+1,this%cfg%imaxo_
               ! FD gradient in x of W from [xm,ym,z ]
               delta=minval(this%cfg%VF(i  ,j,k-1:k))*(this%cfg%xm(i)-this%cfg%x (i  )) &
               &    +minval(this%cfg%VF(i-1,j,k-1:k))*(this%cfg%x (i)-this%cfg%xm(i-1))
               if (delta.gt.0.0_WP) then
                  this%grdw_x(:,i,j,k)=[-minval(this%cfg%VF(i-1,j,k-1:k)),+minval(this%cfg%VF(i,j,k-1:k))]/delta
               else
                  this%grdw_x(:,i,j,k)=0.0_WP
               end if
               ! FD gradient in z of U from [x ,ym,zm]
               delta=minval(this%cfg%VF(i-1:i,j,k  ))*(this%cfg%zm(k)-this%cfg%z (k  )) &
               &    +minval(this%cfg%VF(i-1:i,j,k-1))*(this%cfg%z (k)-this%cfg%zm(k-1))
               if (delta.gt.0.0_WP) then
                  this%grdu_z(:,i,j,k)=[-minval(this%cfg%VF(i-1:i,j,k-1)),+minval(this%cfg%VF(i-1:i,j,k))]/delta
               else
                  this%grdu_z(:,i,j,k)=0.0_WP
               end if
            end do
         end do
      end do
      
      ! Here, we assume that we need Neumann on pressure all around anyway,
      ! so all peripheral velocities need to be given by BC:
      if (.not.this%cfg%xper) then
         if (this%cfg%iproc.eq.           1) this%divu_x(:,this%cfg%imin  ,:,:)=0.0_WP
         if (this%cfg%iproc.eq.this%cfg%npx) this%divu_x(:,this%cfg%imax+1,:,:)=0.0_WP
      end if
      if (.not.this%cfg%yper) then
         if (this%cfg%jproc.eq.           1) this%divv_y(:,:,this%cfg%jmin  ,:)=0.0_WP
         if (this%cfg%jproc.eq.this%cfg%npy) this%divv_y(:,:,this%cfg%jmax+1,:)=0.0_WP
      end if
      if (.not.this%cfg%zper) then
         if (this%cfg%kproc.eq.           1) this%divw_z(:,:,:,this%cfg%kmin  )=0.0_WP
         if (this%cfg%kproc.eq.this%cfg%npz) this%divw_z(:,:,:,this%cfg%kmax+1)=0.0_WP
      end if
      
   end subroutine init_metrics
   
   
   !> Add a boundary condition
   subroutine add_bcond(this,name,type,locator)
      implicit none
      class(incomp), intent(inout) :: this
      character(len=*), intent(in) :: name
      integer, intent(in) :: type
      interface
         logical function locator(pargrid,ind1,ind2,ind3)
            use pgrid_class, only: pgrid
            class(pgrid), intent(in) :: pargrid
            integer, intent(in) :: ind1,ind2,ind3
         end function locator
      end interface
      type(bcond), pointer :: new_bc
      
      ! Prepare new bcond
      allocate(new_bc)
      new_bc%name=trim(adjustl(name))
      new_bc%type=type
      new_bc%itr =iterator(this%cfg,new_bc%name,locator)
      
      ! Insert it up front
      new_bc%next=>this%first_bc
      this%first_bc=>new_bc
      
   end subroutine add_bcond
   
   
   !> Calculate the explicit momentum time derivative based on U/V/W/P
   subroutine get_dmomdt(this,drhoUdt,drhoVdt,drhoWdt)
      implicit none
      class(incomp), intent(inout) :: this
      real(WP), dimension(this%cfg%imino_:,this%cfg%jmino_:,this%cfg%kmino_:), intent(out) :: drhoUdt !< Needs to be (imino_:imaxo_,jmino_:jmaxo_,kmino_:kmaxo_)
      real(WP), dimension(this%cfg%imino_:,this%cfg%jmino_:,this%cfg%kmino_:), intent(out) :: drhoVdt !< Needs to be (imino_:imaxo_,jmino_:jmaxo_,kmino_:kmaxo_)
      real(WP), dimension(this%cfg%imino_:,this%cfg%jmino_:,this%cfg%kmino_:), intent(out) :: drhoWdt !< Needs to be (imino_:imaxo_,jmino_:jmaxo_,kmino_:kmaxo_)
      integer :: i,j,k,ii,jj,kk
      real(WP), dimension(:,:,:), allocatable :: FX,FY,FZ
      
      ! Allocate flux arrays
      allocate(FX(this%cfg%imino_:this%cfg%imaxo_,this%cfg%jmino_:this%cfg%jmaxo_,this%cfg%kmino_:this%cfg%kmaxo_))
      allocate(FY(this%cfg%imino_:this%cfg%imaxo_,this%cfg%jmino_:this%cfg%jmaxo_,this%cfg%kmino_:this%cfg%kmaxo_))
      allocate(FZ(this%cfg%imino_:this%cfg%imaxo_,this%cfg%jmino_:this%cfg%jmaxo_,this%cfg%kmino_:this%cfg%kmaxo_))
      
      ! Flux of rhoU
      do kk=this%cfg%kmin_,this%cfg%kmax_+1
         do jj=this%cfg%jmin_,this%cfg%jmax_+1
            do ii=this%cfg%imin_,this%cfg%imax_+1
               ! Fluxes on x-face
               i=ii-1; j=jj; k=kk
               FX(i,j,k)=-this%rho * sum(this%itpu_x(:,i,j,k)*this%U(i:i+1,j,k))*sum(this%itpu_x(:,i,j,k)*this%U(i:i+1,j,k)) &
               &         +this%visc*(sum(this%grdu_x(:,i,j,k)*this%U(i:i+1,j,k))+sum(this%grdu_x(:,i,j,k)*this%U(i:i+1,j,k)))&
               &         -this%P(i,j,k)
               ! Fluxes on y-face
               i=ii  ; j=jj; k=kk
               FY(i,j,k)=-this%rho * sum(this%itpu_y(:,i,j,k)*this%U(i,j-1:j,k))*sum(this%itpv_x(:,i,j,k)*this%V(i-1:i,j,k)) &
               &         +this%visc*(sum(this%grdu_y(:,i,j,k)*this%U(i,j-1:j,k))+sum(this%grdv_x(:,i,j,k)*this%V(i-1:i,j,k)))
               ! Fluxes on z-face
               i=ii  ; j=jj; k=kk
               FZ(i,j,k)=-this%rho * sum(this%itpu_z(:,i,j,k)*this%U(i,j,k-1:k))*sum(this%itpw_x(:,i,j,k)*this%W(i-1:i,j,k)) &
               &         +this%visc*(sum(this%grdu_z(:,i,j,k)*this%U(i,j,k-1:k))+sum(this%grdw_x(:,i,j,k)*this%W(i-1:i,j,k)))
            end do
         end do
      end do
      ! Time derivative of rhoU
      do k=this%cfg%kmin_,this%cfg%kmax_
         do j=this%cfg%jmin_,this%cfg%jmax_
            do i=this%cfg%imin_,this%cfg%imax_
               drhoUdt(i,j,k)=sum(this%divu_x(:,i,j,k)*FX(i-1:i,j,k))+&
               &              sum(this%divu_y(:,i,j,k)*FY(i,j:j+1,k))+&
               &              sum(this%divu_z(:,i,j,k)*FZ(i,j,k:k+1))
            end do
         end do
      end do
      
      ! Flux of rhoV
      do kk=this%cfg%kmin_,this%cfg%kmax_+1
         do jj=this%cfg%jmin_,this%cfg%jmax_+1
            do ii=this%cfg%imin_,this%cfg%imax_+1
               ! Fluxes on x-face
               i=ii; j=jj  ; k=kk
               FX(i,j,k)=-this%rho * sum(this%itpv_x(:,i,j,k)*this%V(i-1:i,j,k))*sum(this%itpu_y(:,i,j,k)*this%U(i,j-1:j,k)) &
               &         +this%visc*(sum(this%grdv_x(:,i,j,k)*this%V(i-1:i,j,k))+sum(this%grdu_y(:,i,j,k)*this%U(i,j-1:j,k)))
               ! Fluxes on y-face
               i=ii; j=jj-1; k=kk
               FY(i,j,k)=-this%rho * sum(this%itpv_y(:,i,j,k)*this%V(i,j:j+1,k))*sum(this%itpv_y(:,i,j,k)*this%V(i,j:j+1,k)) &
               &         +this%visc*(sum(this%grdv_y(:,i,j,k)*this%V(i,j:j+1,k))+sum(this%grdv_y(:,i,j,k)*this%V(i,j:j+1,k)))&
               &         -this%P(i,j,k)
               ! Fluxes on z-face
               i=ii; j=jj  ; k=kk
               FZ(i,j,k)=-this%rho * sum(this%itpv_z(:,i,j,k)*this%V(i,j,k-1:k))*sum(this%itpw_y(:,i,j,k)*this%W(i,j-1:j,k)) &
               &         +this%visc*(sum(this%grdv_z(:,i,j,k)*this%V(i,j,k-1:k))+sum(this%grdw_y(:,i,j,k)*this%W(i,j-1:j,k)))
            end do
         end do
      end do
      ! Time derivative of rhoV
      do k=this%cfg%kmin_,this%cfg%kmax_
         do j=this%cfg%jmin_,this%cfg%jmax_
            do i=this%cfg%imin_,this%cfg%imax_
               drhoVdt(i,j,k)=sum(this%divv_x(:,i,j,k)*FX(i:i+1,j,k))+&
               &              sum(this%divv_y(:,i,j,k)*FY(i,j-1:j,k))+&
               &              sum(this%divv_z(:,i,j,k)*FZ(i,j,k:k+1))
            end do
         end do
      end do
      
      ! Flux of rhoW
      do kk=this%cfg%kmin_,this%cfg%kmax_+1
         do jj=this%cfg%jmin_,this%cfg%jmax_+1
            do ii=this%cfg%imin_,this%cfg%imax_+1
               ! Fluxes on x-face
               i=ii; j=jj; k=kk
               FX(i,j,k)=-this%rho * sum(this%itpw_x(:,i,j,k)*this%W(i-1:i,j,k))*sum(this%itpu_z(:,i,j,k)*this%U(i,j,k-1:k)) &
               &         +this%visc*(sum(this%grdw_x(:,i,j,k)*this%W(i-1:i,j,k))+sum(this%grdu_z(:,i,j,k)*this%U(i,j,k-1:k)))
               ! Fluxes on y-face
               i=ii; j=jj; k=kk
               FY(i,j,k)=-this%rho * sum(this%itpw_y(:,i,j,k)*this%W(i,j-1:j,k))*sum(this%itpv_z(:,i,j,k)*this%V(i,j,k-1:k)) &
               &         +this%visc*(sum(this%grdw_y(:,i,j,k)*this%W(i,j-1:j,k))+sum(this%grdv_z(:,i,j,k)*this%V(i,j,k-1:k)))
               ! Fluxes on z-face
               i=ii; j=jj; k=kk-1
               FZ(i,j,k)=-this%rho * sum(this%itpw_z(:,i,j,k)*this%W(i,j,k:k+1))*sum(this%itpw_z(:,i,j,k)*this%W(i,j,k:k+1)) &
               &         +this%visc*(sum(this%grdw_z(:,i,j,k)*this%W(i,j,k:k+1))+sum(this%grdw_z(:,i,j,k)*this%W(i,j,k:k+1)))&
               &         -this%P(i,j,k)
            end do
         end do
      end do
      ! Time derivative of rhoW
      do k=this%cfg%kmin_,this%cfg%kmax_
         do j=this%cfg%jmin_,this%cfg%jmax_
            do i=this%cfg%imin_,this%cfg%imax_
               drhoWdt(i,j,k)=sum(this%divw_x(:,i,j,k)*FX(i:i+1,j,k))+&
               &              sum(this%divw_y(:,i,j,k)*FY(i,j:j+1,k))+&
               &              sum(this%divw_z(:,i,j,k)*FZ(i,j,k-1:k))
            end do
         end do
      end do
      
      ! Deallocate flux arrays
      deallocate(FX,FY,FZ)
      
   end subroutine get_dmomdt
   
   
   !> Calculate the velocity divergence based on U/V/W
   subroutine get_divergence(this,div)
      implicit none
      class(incomp), intent(inout) :: this
      real(WP), dimension(this%cfg%imino_:,this%cfg%jmino_:,this%cfg%kmino_:), intent(out) :: div !< Needs to be (imino_:imaxo_,jmino_:jmaxo_,kmino_:kmaxo_)
      integer :: i,j,k
      do k=this%cfg%kmin_,this%cfg%kmax_
         do j=this%cfg%jmin_,this%cfg%jmax_
            do i=this%cfg%imin_,this%cfg%imax_
               div(i,j,k)=sum(this%divp_x(:,i,j,k)*this%U(i:i+1,j,k))+&
               &          sum(this%divp_y(:,i,j,k)*this%V(i,j:j+1,k))+&
               &          sum(this%divp_z(:,i,j,k)*this%W(i,j,k:k+1))
            end do
         end do
      end do
   end subroutine get_divergence
   
   
   !> Print out info for incompressible flow solver
   subroutine incomp_print(this)
      use, intrinsic :: iso_fortran_env, only: output_unit
      implicit none
      class(incomp), intent(in) :: this
      
      ! Output
      if (this%cfg%amRoot) then
         write(output_unit,'("Incompressible solver [",a,"] for config [",a,"]")') trim(this%name),trim(this%cfg%name)
         write(output_unit,'(" >   density = ",es12.5)') this%rho
         write(output_unit,'(" > viscosity = ",es12.5)') this%visc
      end if
      
   end subroutine incomp_print
   
   
end module incomp_class