package main

import (
	"unsafe"

	"tinyextreme/sys"
)

//export _start
//go:section .hole4
func start(_, _, n uintptr) { h2(1, addr(), n) }

//export h2
//go:noinline
//go:section .hole80
func h2(fd, buf, _ uintptr) { h3(fd, buf, 14) }

//export h3
//go:noinline
func h3(fd, buf, n uintptr) {
	sys.Syscall3(sys.WRITE, fd, buf, n)
	h := (*[2]uint32)(unsafe.Pointer(buf + 20))
	sys.Syscall1(uintptr(h[0]), sys.Word(h[1]))
	sys.Assume(false)
}
