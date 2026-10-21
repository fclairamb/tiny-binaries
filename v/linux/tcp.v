module main

// "hello\n"
const request = [u8(104), 101, 108, 108, 111, 10]!

// tcp <ipv4> <port>: send "hello\n", copy the reply to stdout.
// sp points at the initial stack: argc, argv[0], argv[1], argv[2], ... (see entry.v)
@[markused; noreturn]
fn vmain(_ i64, _ i64, _ i64, sp4 &i64, sp5 &i64) {
	sp := unsafe {
		$if amd64 { sp5 } $else { sp4 }
	}
	// exit status 1 or 2 without two arguments (r = argc - 3 is smaller code on arm64)
	mut r := unsafe {
		$if amd64 { Word(-1) } $else { Word(sp[0]) - 3 }
	}
	if unsafe { sp[0] } >= 3 {
		argv := unsafe { &&u8(sp + 1) }
		// One loop parses the port (argv[2]) and then a.b.c.d (argv[1]): on every separator
		// ('.' or the final NUL), x = x << 8 | number. After the port x is the port, and the
		// four address bytes shift it up 32 bits: x = port << 32 | a.b.c.d in big endian.
		mut x := u64(0)
		for k := 2; k > 0; k-- {
			mut p := unsafe { argv[k] }
			mut cur := u64(0)
			for {
				c := unsafe { *p }
				p = unsafe { p + 1 }
				if c < 48 {
					x = (x << 8) | cur
					cur = 0
					if c == 0 {
						break
					}
				} else {
					cur = cur * 10 + c - 48
				}
			}
		}
		// over argc and argv[0], which are not needed any more; the 8 bytes after it
		// (sin_zero) are not checked by the kernel
		unsafe {
			// byte swapped: 0, 0, port, address; the low 16 bits are the family, AF_INET
			sp[0] = i64(bswap64(x) | 2)
		}
		fd := sys3(nr_socket, 2, 1, 0)
		r = sys3(nr_connect, fd, i64(sp), 16)
		if r == 0 {
			// the first write sends the request, the next ones copy the reply to stdout; the
			// argument area of the stack is the read buffer (it is far larger than 64 bytes),
			// the last read returns 0 at the end of the stream, the exit status
			mut dst := fd
			mut buf := voidptr(&request)
			r = 6
			for {
				write(dst, buf, r)
				r = read(fd, sp, 64)
				if r <= 0 {
					break
				}
				dst = 1
				buf = sp
			}
		}
	}
	exit(-r)
	C.__builtin_unreachable()
}

@[inline]
fn bswap64(x u64) u64 {
	return (x >> 56) | ((x >> 40) & 0xff00) | ((x >> 24) & 0xff0000) | ((x >> 8) & 0xff000000) | ((x << 8) & 0xff00000000) | ((x << 24) & 0xff0000000000) | ((x << 40) & 0xff000000000000) | (x << 56)
}
