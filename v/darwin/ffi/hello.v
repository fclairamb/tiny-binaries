// hello, extreme-ffi variant for darwin-arm64: no V runtime (-no-builtin), libSystem's
// puts() through V's C interop instead of a system call.
module main

#include <stdio.h>

fn C.puts(s &char) int

// Entry point (ld -e _start), called by dyld like main(); dyld passes the returned value
// to exit(), which flushes stdout.
@[export: 'start']
fn start() int {
	C.puts(c'Hello, World!') // puts adds the newline
	return 0
}

// V wants a main; it is never called and the linker drops it.
fn main() {}
