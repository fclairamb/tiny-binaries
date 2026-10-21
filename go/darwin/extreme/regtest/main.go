// regtest checks that sys.Call keeps the promise of its empty clobber list.
// build-darwin.sh builds it exactly like the extreme programs and runs it
// first; a non-zero exit fails the extreme variant, so a toolchain change that
// broke the wrapper fails the build. Exit status 0 means pass; 41-46 name the
// check that failed.
//
// Two scenarios load values from memory, keep them live across two traps,
// and hash them after, starting from the trap results: low keeps 20 values
// with constant operands, high keeps 30 (more than the allocator has
// registers) and passes six of them as the operands. The values are loads, so
// the compiler cannot rematerialize them after a trap, and the hash starts
// from the results, so it cannot be computed before. With TinyGo 0.43 the two
// scenarios hold a value in each of x0-x17, x19-x28 and x30 across an executed
// trap, which covers every register the extreme programs keep live across one
// (README.md lists them). A comparison emitted before a trap and branched on
// after it checks NZCV, and a failing call checks the error bit.
package main

import (
	"tinybinaries/darwin/extreme/sys"
	"unsafe"
)

var tab [30]uintptr
var msg = "x"

// fill writes the operands of write(1, msg, 0) to tab[0:4], then values the
// compiler cannot know.
//
//go:noinline
func fill() {
	tab[0], tab[1], tab[2] = 4, 1, uintptr(unsafe.Pointer(unsafe.StringData(msg)))
	for i := 3; i < len(tab); i++ {
		tab[i] = uintptr(i-3) * 0x9E3779B97F4A7C15
	}
}

// mix is the hash step. The multiply and the xor stop LLVM from factoring the
// trap result out of the chain.
func mix(h, v uintptr) uintptr { return (h*31 ^ v) + v>>7 }

// expect is the same hash over tab[from:], read from memory in a separate
// function, so it shares no register with the values held across the trap.
//
//go:noinline
func expect(from int) uintptr {
	h := uintptr(0)
	for _, v := range tab[from:] {
		h = mix(h, v)
	}
	return h
}

func fail(code uintptr) { sys.Call(1, code, 0, 0, 0, 0) }

//go:noinline
func low() {
	a0, a1, a2, a3, a4, a5, a6, a7, a8, a9 := tab[10], tab[11], tab[12], tab[13], tab[14], tab[15], tab[16], tab[17], tab[18], tab[19]
	b0, b1, b2, b3, b4, b5, b6, b7, b8, b9 := tab[20], tab[21], tab[22], tab[23], tab[24], tab[25], tab[26], tab[27], tab[28], tab[29]
	p := uintptr(unsafe.Pointer(unsafe.StringData(msg)))
	r := sys.Call(4, 1, p, 0, a0, a1)  // write(1, msg, 0)
	s := a0 + a1 + a2 + a3             // does not depend on r: the cmp is emitted before the svc
	r2 := sys.Call(4, 1, p, 0, a2, a3) // again, with r live across it
	if s < 1000 {
		fail(41)
	}
	if r|r2 != 0 {
		fail(42)
	}
	h := r*3 ^ r2
	for _, v := range [...]uintptr{a0, a1, a2, a3, a4, a5, a6, a7, a8, a9, b0, b1, b2, b3, b4, b5, b6, b7, b8, b9} {
		h = mix(h, v)
	}
	if h != expect(10) {
		fail(43)
	}
}

//go:noinline
func high() {
	a0, a1, a2, a3, a4, a5, a6, a7, a8, a9 := tab[0], tab[1], tab[2], tab[3], tab[4], tab[5], tab[6], tab[7], tab[8], tab[9]
	b0, b1, b2, b3, b4, b5, b6, b7, b8, b9 := tab[10], tab[11], tab[12], tab[13], tab[14], tab[15], tab[16], tab[17], tab[18], tab[19]
	c0, c1, c2, c3, c4, c5, c6, c7, c8, c9 := tab[20], tab[21], tab[22], tab[23], tab[24], tab[25], tab[26], tab[27], tab[28], tab[29]
	r := sys.Call(a0, a1, a2, a3, a4, a5)  // write(1, msg, 0)
	r2 := sys.Call(a0, a1, a2, a3, a4, a5) // again, with r live across it
	if r|r2 != 0 {
		fail(44)
	}
	h := r*3 ^ r2
	for _, v := range [...]uintptr{a0, a1, a2, a3, a4, a5, a6, a7, a8, a9,
		b0, b1, b2, b3, b4, b5, b6, b7, b8, b9, c0, c1, c2, c3, c4, c5, c6, c7, c8, c9} {
		h = mix(h, v)
	}
	if h != expect(0) {
		fail(45)
	}
}

//export appmain
func appmain() {
	fill()
	low()
	high()
	if e := sys.Call(4, ^uintptr(0), tab[2], 1, 0, 0); e != sys.Err|9 { // write(-1): EBADF
		fail(46)
	}
	sys.Call(1, 0, 0, 0, 0, 0)
}

func main() {}
