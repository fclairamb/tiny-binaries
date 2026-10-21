package main

import "tinyextreme/sys"

// _start is in the code region (an entry point in a header hole is accepted by Rosetta but
// faults on the real x86_64 kernel). The exit fragment sits in the p_paddr hole.
//
//export _start
func start() {
	sys.Syscall3(sys.WRITE, 1, addr(), 14)
	exit()
}

//export exit
//go:noinline
//go:section .hole80
func exit() {
	sys.Syscall1(sys.EXIT, 0)
	sys.Assume(false)
}
