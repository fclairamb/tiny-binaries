// Package sys is the whole "runtime" of the extreme variant: raw Linux system calls, the
// initial stack pointer and an "unreachable" hint. Nothing here is assembly written by hand:
// TinyGo turns calls to functions named golang.org/x/sys/unix.RawSyscallNoError* into the
// syscall instruction (with the right register constraints, see createRawSyscall in TinyGo's
// compiler/syscall.go), and the llvm.* names are LLVM intrinsics.
package sys

import "unsafe"

//go:linkname Syscall1 golang.org/x/sys/unix.RawSyscallNoError1
func Syscall1(nr, a1 uintptr) (r1, r2 uintptr)

//go:linkname Syscall3 golang.org/x/sys/unix.RawSyscallNoError3
func Syscall3(nr, a1, a2, a3 uintptr) (r1, r2 uintptr)

// Assume(false) after exit tells LLVM that control never gets there: llvm.assume of a false
// condition becomes `unreachable`, so no `ret` or trap is emitted after the exit syscall, and
// _start becomes a noreturn function.
//
//export llvm.assume
func Assume(c bool)

// The import of unsafe is what makes the //go:linkname directives legal.
var _ unsafe.Pointer
