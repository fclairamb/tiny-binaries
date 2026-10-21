// tcp, extreme variant for darwin-arm64: no V runtime (-no-builtin), no libSystem calls.
// Build with -enable-globals (for the zero-filled receive buffer).
module main

// Darwin arm64 system call: number in x16, arguments in x0..x2, `svc #0x80`.
// On failure the kernel sets the carry flag and returns errno in x0; the flag comes
// out through the "=@cccs" constraint. V's arm64 asm can't bind an operand to a given
// register, hence the moves. Returns the result, or -errno.
@[inline]
fn syscall3(n u64, a u64, b u64, c u64) i64 {
	mut r := i64(0)
	mut failed := false
	asm volatile arm64 {
		mov x16, n
		mov x0, a
		mov x1, b
		mov x2, c
		svc 0x80
		mov r, x0
		; =r (r)
		  =@cccs (failed)
		; r (n)
		  r (a)
		  r (b)
		  r (c)
		; x0
		  x1
		  x2
		  x16
		  memory
	}
	return if failed { -r } else { r }
}

fn exit(code u64) {
	syscall3(1, code, 0, 0)
}

// Parses a decimal number, stopping at the first non-digit. Returns the number and the
// address of that character.
fn number(s &u8) (u64, &u8) {
	mut p := unsafe { s }
	mut n := u64(0)
	for *p >= u8(`0`) && *p <= u8(`9`) {
		n = n * 10 + u64(*p - u8(`0`))
		p = unsafe { p + 1 }
	}
	return n, p
}

__global buf [4096]u8

// Entry point (ld -e _start), called by dyld like main(argc, argv).
@[export: 'start']
fn start(argc int, argv &&u8) {
	if argc < 3 {
		exit(1)
	}
	// Ignore SIGPIPE so a reader that quits early turns a write into -EPIPE, not a
	// signal. struct __sigaction = { sa_handler, sa_tramp, sa_mask|sa_flags }; SIG_IGN
	// is 1, and the trampoline is never used for SIG_IGN.
	act := [u64(1), 0, 0]!
	syscall3(46, 13, u64(&act[0]), 0) // sigaction(SIGPIPE, &act, 0)
	// Dotted quad, first byte lowest: that is network order once stored little endian.
	mut ip := u64(0)
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
	sa := [u64(0x0210) | ((port & 0xff) << 24) | (((port >> 8) & 0xff) << 16) | (ip << 32), 0]!
	fd := u64(syscall3(97, 2, 1, 0)) // socket(AF_INET, SOCK_STREAM, 0)
	if syscall3(98, fd, u64(&sa[0]), 16) != 0 { // connect
		exit(1)
	}
	syscall3(4, fd, u64(c'hello\n'), 6) // write
	for {
		n := syscall3(3, fd, u64(&buf[0]), sizeof(buf)) // read
		if n < 0 { // error, e.g. ECONNRESET: a truncated transfer is a failure
			exit(1)
		}
		if n == 0 { // the server closed the connection
			break
		}
		// write(1, ...) can be short; loop until every byte is out, fail on -EPIPE.
		base := u64(&buf[0])
		total := u64(n)
		mut off := u64(0)
		for off < total {
			w := syscall3(4, 1, base + off, total - off)
			if w <= 0 {
				exit(1)
			}
			off += u64(w)
		}
	}
	exit(0)
}

// V wants a main; it is never called and the linker drops it.
fn main() {}
