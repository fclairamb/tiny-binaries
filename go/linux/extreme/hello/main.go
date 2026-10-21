package main

import (
	"unsafe"

	"tinyextreme/sys"
)

// The string constant lands in .rodata.main$string, which one.ld puts in a header hole.
const msg = "Hello, World!\n"

//export _start
func start() {
	sys.Syscall3(sys.WRITE, 1, uintptr(unsafe.Pointer(unsafe.StringData(msg))), uintptr(len(msg)))
	sys.Exit(0)
}

func main() {}
