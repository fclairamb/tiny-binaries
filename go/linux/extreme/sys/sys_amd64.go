package sys

import "unsafe"

const (
	READ    = 0
	WRITE   = 1
	SOCKET  = 41
	CONNECT = 42
	EXIT    = 60
)

// EntrySP returns the address of the return address slot of the calling function, which is
// the stack pointer on entry. At the ELF entry point nothing was pushed, so called from
// _start it points at argc.
//
//export llvm.addressofreturnaddress.p0
func EntrySP() unsafe.Pointer
