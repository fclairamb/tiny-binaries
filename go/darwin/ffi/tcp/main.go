// tcp, extreme-ffi variant: Go logic, libSystem reached through FFI. No inline
// assembly; dyld loads libSystem and the //export symbols bind at load.
package main

import "unsafe"

//export socket
func cSocket(dom, typ, proto int32) int32

//export connect
func cConnect(fd int32, addr unsafe.Pointer, l uint32) int32

//export write
func cWrite(fd int32, buf unsafe.Pointer, n uintptr) int

//export read
func cRead(fd int32, buf unsafe.Pointer, n uintptr) int

var sa [16]byte    // struct sockaddr_in
var buf [4096]byte // copy buffer

func next(p *byte) *byte { return (*byte)(unsafe.Add(unsafe.Pointer(p), 1)) }

// num parses the decimal field at p, which must end with the byte stop, and
// returns its value and the position after stop. ok is false for an empty
// field, a byte that is neither a digit nor stop (so a NUL ends the parse
// early), or a value above max.
func num(p *byte, stop byte, max uint32) (v uint32, rest *byte, ok bool) {
	for n := 0; ; n++ {
		c := *p
		p = next(p)
		if c == stop {
			return v, p, n > 0
		}
		d := uint32(c) - '0'
		v = v*10 + d
		if d > 9 || v > max {
			return 0, p, false
		}
	}
}

// writeAll writes n bytes at p to fd, retrying short writes. Any error,
// EAGAIN included, is a failure: SPEC leaves stdout errors unspecified, and
// checking errno would cost one more import.
func writeAll(fd int32, p unsafe.Pointer, n int) bool {
	for n > 0 {
		r := cWrite(fd, p, uintptr(n))
		if r < 0 {
			return false
		}
		p = unsafe.Add(p, r)
		n -= r
	}
	return true
}

// appmain is the program entry (ld -e _appmain -> LC_MAIN). dyld calls it as
// C main(argc, argv) and passes its return value to exit().
//
//export appmain
func appmain(argc int32, argv **byte) int32 {
	if argc < 3 {
		return 1
	}
	p := *(**byte)(unsafe.Add(unsafe.Pointer(argv), 8))
	portp := *(**byte)(unsafe.Add(unsafe.Pointer(argv), 16))

	stop := byte('.')
	for k := 4; k < 8; k++ {
		if k == 7 {
			stop = 0
		}
		b, rest, ok := num(p, stop, 255)
		if !ok {
			return 1
		}
		sa[k] = byte(b)
		p = rest
	}
	port, _, ok := num(portp, 0, 65535)
	if !ok {
		return 1
	}
	sa[0] = 16 // sin_len
	sa[1] = 2  // sin_family = AF_INET
	sa[2] = byte(port >> 8)
	sa[3] = byte(port)

	fd := cSocket(2, 1, 0)
	if fd < 0 {
		return 1
	}
	// No SO_NOSIGPIPE: a server that resets before reading the request may
	// kill us with SIGPIPE, which SPEC allows, and it saves an import.
	if cConnect(fd, unsafe.Pointer(&sa[0]), 16) < 0 {
		return 1
	}
	hello := "hello\n"
	if !writeAll(fd, unsafe.Pointer(unsafe.StringData(hello)), 6) {
		return 1
	}
	for {
		n := cRead(fd, unsafe.Pointer(&buf[0]), uintptr(len(buf)))
		if n < 0 {
			return 1
		}
		if n == 0 {
			return 0
		}
		if !writeAll(1, unsafe.Pointer(&buf[0]), n) {
			return 1
		}
	}
}

func main() {}
