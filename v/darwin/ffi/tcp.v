// tcp, extreme-ffi variant for darwin-arm64: no V runtime (-no-builtin), system calls
// through libSystem's syscall() (V's C interop) instead of svc. One import instead of
// four (socket, connect, read, write): shorter bind opcodes. Build with -enable-globals.
module main

#include <unistd.h>

// int syscall(int number, ...): variadic, so on arm64 Darwin the arguments go on the
// stack, one 8-byte slot each; the C prototype from <unistd.h> makes clang pass them that
// way. Every argument is a u64 or a pointer, so that no slot keeps stale upper bits.
fn C.syscall(n int, ...) int

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
	// syscall() returns -1 on failure (errno is set), the result otherwise.
	fd := u64(C.syscall(97, u64(2), u64(1), u64(0))) // socket(AF_INET, SOCK_STREAM, 0)
	if C.syscall(98, fd, &sa[0], u64(16)) != 0 { // connect
		return 1
	}
	C.syscall(4, fd, c'hello\n', u64(6)) // write
	for {
		n := C.syscall(3, fd, &buf[0], u64(sizeof(buf))) // read
		if n < 0 { // error, e.g. ECONNRESET: a truncated transfer is a failure
			return 1
		}
		if n == 0 { // the server closed the connection
			break
		}
		// write(1, ...) can be short: loop until every byte is out.
		mut off := 0
		for off < n {
			w := C.syscall(4, u64(1), u64(&buf[0]) + u64(off), u64(n - off))
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
