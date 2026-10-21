module main

// "hello\n"
const request = [u8(104), 101, 108, 108, 111, 10]!

// tcp <ipv4> <port>: send "hello\n", copy the reply to stdout.
// The entry glue (entry.v) passes argc, argv and a pointer into the initial stack (the
// argc slot on arm64, argv[0] on amd64) as register arguments.
@[markused; noreturn]
fn vmain(_ i64, _ i64, _ i64, a4 i64, a5 i64, a6 i64) {
	argc := $if amd64 { a6 } $else { a5 }
	argv := unsafe {
		$if amd64 { &&u8(a5) } $else { &&u8(a6) }
	}
	// 16 bytes of the initial stack that are dead once argv is parsed: the sockaddr, and on
	// amd64 the read buffer
	sp := unsafe {
		$if amd64 { &i64(a5) } $else { &i64(a4) }
	}
	// The argument check is the socket's protocol, argc - 3: 0 (the default, TCP) with
	// exactly 2 arguments, negative with fewer, which socket() rejects (EINVAL). connect()
	// on that -EINVAL "fd" then fails with EBADF (exit status 9), whatever the one argument
	// holds: no socket, no traffic. The call comes before the loop, which counts argc down.
	fd := sys3(nr_socket, 2, 1, argc - 3)
	// One loop parses the port (argv[2]) and then a.b.c.d (argv[1]): on every separator
	// ('.' or the final NUL), x = x << 8 | number. Five numbers shift the start value up 40
	// bits, so its 0x02 at bits 16..23 lands on bits 56..63: after the byte swap below
	// that is sin_family = AF_INET, followed by the port and the address in network order.
	mut x := u64(0x20000)
	// unsigned: argc is at least 1 (Linux 5.18 and later put an empty argv[0] when execve
	// gets an empty argv), and the loop test is then a plain decrement and branch on zero
	mut k := u64(argc)
	for {
		k--
		if k == 0 {
			break
		}
		mut p := unsafe { argv[k] }
		mut cur := u64(0)
		for {
			c := u32(unsafe { *p })
			p = unsafe { p + 1 }
			if c < 48 {
				x = (x << 8) | cur
				cur = 0
				if c == 0 {
					break
				}
			} else {
				cur = u64(u32(cur) * 10 + c - 48)
			}
		}
	}
	// sin_zero, the 8 bytes after it, is not checked by the kernel
	unsafe {
		sp[0] = i64(bswap64(x))
	}
	mut r := sys3(nr_connect, fd, i64(sp), 16)
	if r == 0 {
		// the first write sends the request, the next ones copy the reply to stdout; the
		// last read returns 0 at the end of the stream (exit status 0) or -errno
		mut dst := fd
		mut buf := voidptr(&request)
		r = 6
		for {
			write(dst, buf, r)
			$if amd64 {
				// the argument area of the stack is the buffer (6 bytes at most are asked
				// for). Rosetta write-protects the page that holds translated code, so a
				// read() into the request's header hole would fail with EFAULT there. The
				// count is the previous length, still in rdx: 6, then never more than the
				// last chunk (always at least 1). It saves loading a constant, but one
				// 1-byte read makes every later read 1 byte (see the README).
				r = read(fd, sp, r)
				buf = sp
			} $else {
				// the request sits in a header hole (p_paddr, p_filesz and p_memsz, 24
				// bytes before the code). The headers are dead memory once the process
				// runs, so the reply is read over them: the buffer never moves.
				r = read(fd, &request, 24)
			}
			if r <= 0 {
				break
			}
			dst = 1
		}
	}
	$if amd64 {
		die(r)
	} $else {
		exit(-r)
	}
	C.__builtin_unreachable()
}

$if amd64 {
	// exit(-r) out of line, in the e_shoff header hole (7 bytes): the call and the move of
	// r into edi take 7 bytes, the inlined exit 11.
	@[noinline; noreturn; _linker_section: '.text.hole']
	fn die(r Word) {
		exit(-r)
		C.__builtin_unreachable()
	}
}

@[inline]
fn bswap64(x u64) u64 {
	return (x >> 56) | ((x >> 40) & 0xff00) | ((x >> 24) & 0xff0000) | ((x >> 8) & 0xff000000) | ((x << 8) & 0xff00000000) | ((x << 24) & 0xff0000000000) | ((x << 40) & 0xff000000000000) | (x << 56)
}
