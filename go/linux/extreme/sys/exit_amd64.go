package sys

// Exit exits with status -code (the low 8 bits of it). It is a separate function so that one.ld
// can put it in a header hole (.text.hole). Its argument is already in edi, the exit syscall's
// argument register, so the body is neg edi; push 60; pop rax; syscall; ret: 8 bytes, the size
// of the hole. Doing the negation here, in the hole, instead of at the call site saves 3 bytes of
// code. It is not marked noreturn: a call to it at the end of _start is then a tail call (jmp),
// with no stack realignment before it.
//
//go:noinline
//go:section .text.hole
func Exit(code uint32) {
	Syscall1(EXIT, uintptr(-code))
}

// Status turns a negative value (-errno, or a negative argument count check) into the argument
// of Exit. Exit negates it itself on amd64.
func Status(r uintptr) uint32 { return uint32(r) }
