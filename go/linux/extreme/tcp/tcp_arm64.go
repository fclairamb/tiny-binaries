package main

import (
	"unsafe"

	"tinyextreme/sys"
)

//go:section .hole72
var req = [6]byte{'h', 'e', 'l', 'l', 'o', '\n'}

//export exit
//go:section .hole40
//go:noinline
func exit(r uintptr) {
	sys.Syscall1(sys.EXIT, r)
	sys.Assume(false)
}


//export _start
//go:section .hole4
func start(_, _, c uintptr) { run(2, 1, c) }

//export run
//go:noinline
func run(fam, typ, _ uintptr) {
	sp := uintptr(sys.StackSave())
	argc := *(*uintptr)(unsafe.Pointer(sp))
	proto := argc - 3
	x := uint64(2 << 16)
	k := argc
	for {
		k--
		if k == 0 {
			break
		}
		p := *(*uintptr)(unsafe.Pointer(sp + k*8 + 8))
		cur := uint64(0)
		for {
			c := uint64(*(*byte)(unsafe.Pointer(p)))
			p++
			if c&16 == 0 {
				x = x<<8 | cur
				cur = 0
				if c == 0 {
					break
				}
			} else {
				cur = cur*10 + c - '0'
			}
		}
	}
	*(*uint64)(unsafe.Pointer(sp + 8)) = bswap(x)
	fd, _ := sys.Syscall3(sys.SOCKET, fam, typ, proto)
	r, _ := sys.Syscall3(sys.CONNECT, fd, sp+8, 16)
	fd |= r
	buf := uintptr(unsafe.Pointer(&req))
	r = 6
	dst := fd
	for {
		sys.Syscall3(sys.WRITE, dst, buf, r)
		r, _ = sys.Syscall3(sys.READ, fd, buf, r)
		if int(r) <= 0 {
			break
		}
		dst = 1
	}
	exit(-r)
}
