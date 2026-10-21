package sys

import "unsafe"

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
