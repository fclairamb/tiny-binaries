// hello, libc variant: no V runtime (-no-builtin), libSystem's write(2) through V's C interop.
module main

#include <unistd.h>

fn C.write(fd int, buf voidptr, n usize) isize

fn main() {
	C.write(1, c'Hello, World!\n', 14)
}
