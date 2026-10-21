// tcp, extreme-ffi variant for darwin-arm64: no V runtime (-no-builtin), libSystem calls
// through V's C interop instead of system calls. Build with -enable-globals.
module main

#include <unistd.h>
#include <sys/socket.h>

fn C.socket(domain int, typ int, protocol int) int
fn C.connect(fd int, addr voidptr, len u32) int
fn C.read(fd int, buf voidptr, n usize) isize
fn C.write(fd int, buf voidptr, n usize) isize

// Parses a decimal number, stopping at the first non-digit. Returns the number and the
// address of that character.
fn number(s &u8) (u32, &u8) {
	mut p := unsafe { s }
	mut n := u32(0)
	for *p >= u8(`0`) && *p <= u8(`9`) {
		n = n * 10 + u32(*p - u8(`0`))
		p = unsafe { p + 1 }
	}
	return n, p
}

// A global, so it is zero-fill: no bzero() and no stack probe (___chkstk_darwin) to import.
__global buf [4096]u8

// Entry point (ld -e _start), called by dyld like main(argc, argv); dyld passes the
// returned value to exit().
@[export: 'start']
fn start(argc int, argv &&u8) int {
	if argc < 3 {
		return 1
	}
	// Dotted quad, first byte lowest: that is network order once stored little endian.
	mut ip := u32(0)
	mut p := unsafe { argv[1] }
	for i in 0 .. 4 {
		n, end := number(p)
		ip |= (n & 0xff) << (8 * i)
		// Stop at the NUL (or any non-dot): never step past the end of argv[1].
		if unsafe { *end } != `.` {
			break
		}
		p = unsafe { end + 1 }
	}
	port, _ := number(unsafe { argv[2] })
	// struct sockaddr_in: sin_len 16, sin_family AF_INET, sin_port (big endian), sin_addr.
	sa := [u32(0x0210) | ((port & 0xff) << 24) | (((port >> 8) & 0xff) << 16), ip, 0, 0]!
	fd := C.socket(2, 1, 0) // AF_INET, SOCK_STREAM
	if C.connect(fd, &sa[0], 16) != 0 {
		return 1
	}
	C.write(fd, c'hello\n', 6)
	for {
		n := C.read(fd, &buf[0], sizeof(buf))
		if n < 0 { // error, e.g. ECONNRESET: a truncated transfer is a failure
			return 1
		}
		if n == 0 { // the server closed the connection
			break
		}
		// write(1, ...) can be short: loop until every byte is out.
		mut off := isize(0)
		for off < n {
			w := C.write(1, voidptr(usize(&buf[0]) + usize(off)), usize(n - off))
			if w <= 0 {
				return 1
			}
			off += w
		}
	}
	return 0
}

// V wants a main; it is never called and the linker drops it.
fn main() {}
