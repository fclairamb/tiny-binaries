package sys

// Exit is a separate function so that one.ld can put it in a header hole (.text.hole). Its
// argument is already in x0, the exit syscall's argument register, so the body is
// mov w8, #93; svc #0: 8 bytes, the size of a hole. Exported so that LLVM does not fold a
// constant argument into the body (which would no longer fit). A negation would not fit either,
// so on arm64 Status does it at the call site.
//
//export tinyexit
//go:section .text.hole
func Exit(code uintptr) {
	Syscall1(EXIT, code)
	Assume(false)
}

// Status turns a negative value (-errno, or a negative argument count check) into the exit
// status.
func Status(r uintptr) uintptr { return -r }
