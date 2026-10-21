// Package sys is the whole "runtime" of the extreme variant: raw Linux system calls and the
// initial stack pointer. Nothing here is assembly written by hand: TinyGo turns calls to
// functions named golang.org/x/sys/unix.RawSyscall* into the syscall instruction (with the
// right register constraints), and llvm.* names are LLVM intrinsics.
package sys

import "unsafe"

// Syscall1/3/6 link to names TinyGo lowers to the raw syscall instruction, with no errno
// wrapping (see createRawSyscallNoError in TinyGo's compiler/syscall.go). The import of unsafe
// is what makes the //go:linkname directives legal; the blank var below keeps it "used".

//go:linkname Syscall1 golang.org/x/sys/unix.RawSyscallNoError1
func Syscall1(nr, a1 uintptr) (r1, r2 uintptr)

//go:linkname Syscall3 golang.org/x/sys/unix.RawSyscallNoError3
func Syscall3(nr, a1, a2, a3 uintptr) (r1, r2 uintptr)

//go:linkname Syscall6 golang.org/x/sys/unix.RawSyscallNoError6
func Syscall6(nr, a1, a2, a3, a4, a5, a6 uintptr) (r1, r2 uintptr)

var _ unsafe.Pointer
