!> This module defines three typical string sizes
!! that will be employed regularly, and provides
!! easy case manipulation.
module string
  implicit none
  
  ! Shorthand notation for useful string lengths
  integer, public, parameter :: str_short  = 8     !< This is a short string
  integer, public, parameter :: str_medium = 64    !< This is a medium string size
  integer, public, parameter :: str_long   = 8192  !< This is a long string size
  
  ! Function visibility
  public :: lowercase,uppercase,compress
  
  ! Upper/lower case letters
  character(*), private, parameter :: lower_case = 'abcdefghijklmnopqrstuvwxyz'
  character(*), private, parameter :: upper_case = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 
  
contains
  
  !> This function converts a string to lower case
  function lowercase(str_in) result(str_out)
    character(*), intent(in) :: str_in !< Input string (any case)
    character(len(str_in)) :: str_out  !< Output string, all lower case
    integer :: i,n
    str_out=str_in
    do i=1,len(str_out)
       n=index(upper_case,str_out(i))
       if (n.ne.0) str_out(i)=lower_case(n)
    end do
  end function lowercase
  
  !> This function converts a string to upper case
  function uppercase(str_in) result(str_out)
    character(*), intent(in) :: str_in !< Input string (any case)
    character(len(str_in)) :: str_out  !< Output string, all upper case
    integer :: i,n
    str_out=str_in
    do i=1,len(str_out)
       n=index(lower_case,str_out(i))
       if (n.ne.0) str_out(i)=upper_case(n)
    end do
  end function uppercase
  
  !> This function compresses a string by removing all spaces/tabs
  function compress(str_in,n) result(str_out)
    ! Inputs/outputs
    character(*), intent(in) :: str_in  !< Input string
    integer, optional, intent(out) :: n !< Size of the compressed output
    character(len(str_in)) :: str_out   !< Output string, no more spaces and tabs
    ! Local variables
    integer, parameter :: iachar_space = 32
    integer, parameter :: iachar_tab = 9
    integer :: i,j,my_iachar
    j=0; str_out=' '
    do i=1,len(str_in)
       my_iachar=iachar(str_in(i))
       if (my_iachar.ne.iachar_space .and. my_iachar.ne.iachar_tab) then
          j=j+1; str_out(j)=str_in(i)
       end if
    end do
    if (present(n)) n=j
  end function compress
  
end module string
