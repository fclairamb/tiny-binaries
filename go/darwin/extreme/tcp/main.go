package main

import (
	"tinybinaries/darwin/extreme/sys"
	"unsafe"
)

// Darwin arm64 BSD syscall numbers (the kernel reads the number from x16).
const (
	sysExit       = 1
	sysRead       = 3
	sysWrite      = 4
	sysSocket     = 97
	sysConnect    = 98
	sysSetsockopt = 105

	solSocket    = 0xffff
	soKeepalive  = 0x8
	soNoSigpipe  = 0x1022
	ipprotoTCP   = 6
	tcpKeepalive = 0x10 // idle seconds before the first keepalive probe
	keepIdle     = 2
	eagain       = 35
)

// Package globals live in the zero-filled __DATA segment (no file bytes)
// instead of forcing a heap allocation: with -gc=none there is no allocator,
// and a stack buffer whose address escapes to a syscall would be moved to the
// heap by escape analysis.
var sa [16]byte    // struct sockaddr_in
var buf [4096]byte // copy buffer
var opt int32      // setsockopt option value

func exit(code uintptr) { sys.Call(sysExit, code, 0, 0, 0, 0) }

func failed(r uintptr) bool { return int64(r) < 0 }

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

// setopt sets the int socket option level/name of fd to v, or exits 1.
func setopt(fd, level, name uintptr, v int32) {
	opt = v
	if failed(sys.Call(sysSetsockopt, fd, level, name, uintptr(unsafe.Pointer(&opt)), 4)) {
		exit(1)
	}
}

// writeAll writes n bytes at p to fd, retrying short writes and EAGAIN.
func writeAll(fd, p, n uintptr) bool {
	for n > 0 {
		r := sys.Call(sysWrite, fd, p, n, 0, 0)
		if failed(r) {
			if r == sys.Err|eagain {
				continue
			}
			return false
		}
		p += r
		n -= r
	}
	return true
}

// appmain is the program entry (ld -e _appmain -> LC_MAIN). dyld calls it
// with the C main(argc, argv) ABI; it never returns, it exits with the exit
// syscall.
//
//export appmain
func appmain(argc int32, argv **byte) {
	if argc < 3 {
		exit(1)
	}
	// argv is char*[]; entry 1 is the ip, entry 2 the port.
	p := *(**byte)(unsafe.Add(unsafe.Pointer(argv), 8))
	portp := *(**byte)(unsafe.Add(unsafe.Pointer(argv), 16))

	stop := byte('.')
	for k := 4; k < 8; k++ {
		if k == 7 {
			stop = 0
		}
		b, rest, ok := num(p, stop, 255)
		if !ok {
			exit(1)
		}
		sa[k] = byte(b)
		p = rest
	}
	port, _, ok := num(portp, 0, 65535)
	if !ok {
		exit(1)
	}
	sa[0] = 16 // sin_len
	sa[1] = 2  // sin_family = AF_INET
	sa[2] = byte(port >> 8)
	sa[3] = byte(port)

	fd := sys.Call(sysSocket, 2, 1, 0, 0, 0) // socket(AF_INET, SOCK_STREAM, 0)
	if failed(fd) {
		exit(1)
	}
	// SO_NOSIGPIPE: a write to a reset connection returns EPIPE instead of
	// killing the process with SIGPIPE.
	setopt(fd, solSocket, soNoSigpipe, 1)
	// Keepalive after 2 idle seconds. A RST is sent once and never
	// retransmitted; when XNU loses the server's RST after a long reply, the
	// socket stays ESTABLISHED and read blocks forever. The probe makes the
	// dead peer answer with a new RST, so read fails with ECONNRESET. A live
	// server's kernel answers the probe, so a slow transfer is never cut.
	setopt(fd, solSocket, soKeepalive, 1)
	setopt(fd, ipprotoTCP, tcpKeepalive, keepIdle)
	if failed(sys.Call(sysConnect, fd, uintptr(unsafe.Pointer(&sa[0])), 16, 0, 0)) {
		exit(1)
	}
	hello := "hello\n"
	if !writeAll(fd, uintptr(unsafe.Pointer(unsafe.StringData(hello))), 6) {
		exit(1)
	}
	for {
		n := sys.Call(sysRead, fd, uintptr(unsafe.Pointer(&buf[0])), uintptr(len(buf)), 0, 0)
		if failed(n) {
			exit(1)
		}
		if n == 0 {
			break
		}
		if !writeAll(1, uintptr(unsafe.Pointer(&buf[0])), n) {
			exit(1)
		}
	}
	exit(0)
}

func main() {}
