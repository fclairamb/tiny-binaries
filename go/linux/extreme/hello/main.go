package main

import (
	"unsafe"

	"tinyextreme/sys"
)

const msg = "Hello, World!\n"

//export _start
func start() {
	sys.Syscall3(sys.WRITE, 1, uintptr(unsafe.Pointer(unsafe.StringData(msg))), uintptr(len(msg)))
	sys.Syscall1(sys.EXIT, 0)
}

func main() {}
