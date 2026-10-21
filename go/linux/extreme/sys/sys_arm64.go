package sys

import "unsafe"

// Word is the type of the first syscall argument (an fd or a status).
type Word = uintptr

const (
	READ    = 63
	WRITE   = 64
	SOCKET  = 198
	CONNECT = 203
	EXIT    = 93
)

// EntrySP returns the stack pointer on entry to the calling function. Called from _start, it
// points at argc (the kernel's initial process stack).
//
//export llvm.sponentry.p0
func EntrySP() unsafe.Pointer

// StackSave returns the current stack pointer (llvm.stacksave).
//
//export llvm.stacksave.p0
func StackSave() unsafe.Pointer
