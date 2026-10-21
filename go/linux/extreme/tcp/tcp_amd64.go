package main

import (
	"unsafe"

	"tinyextreme/sys"
)

//go:section .hole72
var req = [6]byte{'h', 'e', 'l', 'l', 'o', '\n'}

// die exits with status -r, in the 7-byte e_shoff hole at offset 40.
//
//export die
//go:section .hole40
//go:noinline
func die(r sys.Word) {
	sys.Syscall1(sys.EXIT, -r)
	sys.Assume(false)
}

//export _start
func start() {
	sp := uintptr(sys.EntrySP())
	argc := *(*uintptr)(unsafe.Pointer(sp))
	proto := sys.Word(argc) - 3
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
			if c < '0' {
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
	*(*uint64)(unsafe.Pointer(sp)) = bswap(x)
	fdr, _ := sys.Syscall3(sys.SOCKET, 2, 1, uintptr(proto))
	fd := sys.Word(fdr)
	r, _ := sys.Syscall3(sys.CONNECT, fd, sp, 16)
	fd |= sys.Word(r)
	dst := fd
	buf := uintptr(unsafe.Pointer(&req))
	n := uintptr(6)
	for {
		sys.Syscall3(sys.WRITE, dst, buf, n)
		n, _ = sys.Syscall3(sys.READ, fd, sp, n)
		if int(n) <= 0 {
			break
		}
		dst = 1
		buf = sp
	}
	die(sys.Word(n))
}
