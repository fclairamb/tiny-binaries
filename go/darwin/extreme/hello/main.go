package main

import (
	"tinybinaries/darwin/extreme/sys"
	"unsafe"
)

// appmain is the program entry (ld -e _appmain -> LC_MAIN). dyld loads the
// image, then calls this with the C main() ABI; it never returns, it exits
// with the write(2)/exit(2) syscalls directly.
//
//export appmain
func appmain() {
	msg := "Hello, World!\n"
	sys.Call(4, 1, uintptr(unsafe.Pointer(unsafe.StringData(msg))), uintptr(len(msg)), 0, 0) // write(1, msg, 14)
	sys.Call(1, 0, 0, 0, 0, 0)                                                               // exit(0)
}

func main() {}
