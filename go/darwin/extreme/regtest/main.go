// regtest checks that sys.Call keeps the promise of its empty clobber list:
// many values live in registers across the trap, a comparison made before
// the trap is consumed after it, and the error bit is set on a failing call.
// build-darwin.sh builds and runs it before shipping the extreme variant, so
// a toolchain change that broke the wrapper fails the build. Exit status 0
// means pass; 42-45 name the check that failed.
package main

import (
	"tinybinaries/darwin/extreme/sys"
	"unsafe"
)

var tab [20]uintptr

//go:noinline
func fill() {
	for i := range tab {
		tab[i] = uintptr(i + 1)
	}
}

//export appmain
func appmain() {
	fill()
	a0, a1, a2, a3, a4, a5, a6, a7 := tab[0], tab[1], tab[2], tab[3], tab[4], tab[5], tab[6], tab[7]
	a8, a9, a10, a11, a12, a13, a14, a15 := tab[8], tab[9], tab[10], tab[11], tab[12], tab[13], tab[14], tab[15]
	a16, a17, a18, a19 := tab[16], tab[17], tab[18], tab[19]
	msg := "x"
	p := uintptr(unsafe.Pointer(unsafe.StringData(msg)))
	r := sys.Call(4, 1, p, 0, a0, a1) // write(1, p, 0): succeeds, returns 0
	s := a0*1 + a1*2 + a2*3 + a3*4 + a4*5 + a5*6 + a6*7 + a7*8 + a8*9 + a9*10 + a10*11 + a11*12 + a12*13 + a13*14 + a14*15 + a15*16
	s += a16*17 + a17*18 + a18*19 + a19*20
	if s < 1000 { // s is 2870: the compiler emits the cmp before the svc
		sys.Call(1, 42, 0, 0, 0, 0)
	}
	if r != 0 {
		sys.Call(1, 43, 0, 0, 0, 0)
	}
	if e := sys.Call(4, 99, p, 1, a2, a3); e != sys.Err|9 { // write to a bad fd: EBADF
		sys.Call(1, 44, 0, 0, 0, 0)
	}
	t := a0 + a1*a2 + a3*a4 + a5*a6 + a7*a8 + a9*a10 + a11*a12 + a13*a14 + a15*a16 + a17*a18 + a19
	if t != 1+2*3+4*5+6*7+8*9+10*11+12*13+14*15+16*17+18*19+20 {
		sys.Call(1, 45, 0, 0, 0, 0)
	}
	sys.Call(1, 0, 0, 0, 0, 0)
}

func main() {}
