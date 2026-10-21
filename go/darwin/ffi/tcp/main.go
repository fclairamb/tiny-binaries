// tcp, extreme-ffi variant: Go logic, libSystem reached through FFI. No inline
// assembly; dyld loads libSystem and the //export symbol binds at load.
package main

import "unsafe"

// syscall is libSystem's syscall(2), the only import: one bind instead of
// five (socket, setsockopt, connect, write, read). Its C prototype is
// int syscall(int number, ...). On Apple arm64 the named argument goes in w0
// and every variadic argument goes on the stack in 8-byte slots (Apple's
// "Writing ARM64 code for Apple platforms"). TinyGo has no
// variadic FFI, so the declaration fills x1-x7 with seven unused arguments:
// a to e are then the 9th to 13th arguments, which the standard procedure
// call rules put at [sp] to [sp+32], where syscall reads its variadic ones.
// It returns -1 on error (errno is not read).
//
//export syscall
func cSyscall(n int32, _, _, _, _, _, _, _ uintptr, a, b, c, d, e uintptr) int32

// Darwin BSD syscall numbers, passed to syscall(2).
const (
	sysRead       = 3
	sysWrite      = 4
	sysSocket     = 97
	sysConnect    = 98
	sysSetsockopt = 105

	solSocket    = 0xffff
	soKeepalive  = 0x8
	ipprotoTCP   = 6
	tcpKeepalive = 0x10 // idle seconds before the first keepalive probe
	keepIdle     = 2
)

func call(n int32, a, b, c uintptr) int32 { return cSyscall(n, 0, 0, 0, 0, 0, 0, 0, a, b, c, 0, 0) }

var opt int32 // setsockopt option value

// setopt sets the int socket option level/name of fd to v.
func setopt(fd int32, level, name uintptr, v int32) bool {
	opt = v
	p := uintptr(unsafe.Pointer(&opt))
	return cSyscall(sysSetsockopt, 0, 0, 0, 0, 0, 0, 0, uintptr(fd), level, name, p, 4) >= 0
}

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
		r := int(call(sysWrite, uintptr(fd), uintptr(p), uintptr(n)))
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

	fd := call(sysSocket, 2, 1, 0) // socket(AF_INET, SOCK_STREAM, 0)
	if fd < 0 {
		return 1
	}
	// No SO_NOSIGPIPE: a server that resets before reading the request may
	// kill us with SIGPIPE, which SPEC allows, and it saves a syscall.
	// Keepalive after 2 idle seconds: when XNU loses the server's RST after a
	// long reply (a RST is never retransmitted), the probe makes the dead
	// peer answer with a new RST and read fails. A live server's kernel
	// answers the probe, so a slow transfer is never cut.
	if !setopt(fd, solSocket, soKeepalive, 1) || !setopt(fd, ipprotoTCP, tcpKeepalive, keepIdle) {
		return 1
	}
	if call(sysConnect, uintptr(fd), uintptr(unsafe.Pointer(&sa[0])), 16) < 0 {
		return 1
	}
	hello := "hello\n"
	if !writeAll(fd, unsafe.Pointer(unsafe.StringData(hello)), 6) {
		return 1
	}
	for {
		n := int(call(sysRead, uintptr(fd), uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf))))
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
