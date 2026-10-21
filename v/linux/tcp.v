module main

// "hello\n", in the p_paddr header hole (link.ld, DATA)
const request = [u8(104), 101, 108, 108, 111, 10]!

// tcp <ipv4> <port>: send "hello\n", copy the reply to stdout.
//
// Both arches parse the same way. One loop over argv[2] (the port) then argv[1] (the
// address): on every separator (any byte below '0' such as '.', or the final NUL),
// x = x << 8 | number. Five numbers shift the start value up 40 bits, so its 0x02 at bits
// 16..23 lands on bits 56..63: after a byte swap, x is sin_family = AF_INET, the port and
// the address in network order. The argument check is the socket's protocol, argc - 3:
// 0 (the default, TCP) with exactly 2 arguments, negative with fewer, which socket()
// rejects (EINVAL); connect() on that -EINVAL "fd" then fails with EBADF, so the exit
// status is 9 whatever the one argument holds. Every error exits with the errno, end of
// stream with 0.

$if amd64 {
	// Entry glue: pop r9 = argc (6th argument), then r8 = the stack pointer, now &argv[0]
	// (5th argument). None of the syscalls reads r8 or r9, and syscall only clobbers rcx
	// and r11, so argc survives the socket call. The glue is in its own section, which
	// link.ld puts right before vmain: it falls through into it.
	asm amd64 {
		.section '.text.entry'
		.globl entry
		entry:
		pop r9
		mov r8, rsp
	}

	@[markused; noreturn]
	fn vmain(_ i64, _ i64, _ i64, _ i64, argv &&u8, argc i64) {
		// 16 bytes of the initial stack that are dead once argv is parsed: the sockaddr,
		// then the read buffer
		sp := unsafe { &i64(argv) }
		// the socket call comes before the loop, which counts argc down
		fd := sys3(2, 1, argc - 3, nr_socket)
		// argv[argc-1] down to argv[1], numbers folded into x (see the top). k counts
		// down to 0: unsigned, a decrement and a branch on zero (argc >= 1 since Linux 5.18).
		mut x := u64(0x20000)
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
				if c & 16 == 0 {
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
		unsafe {
			sp[0] = i64(bswap64(x))
		}
		mut r := sys3(fd, i64(sp), 16, nr_connect)
		// the first write sends the request, the next ones copy the reply to stdout. The
		// buffer is the stack at argv: Rosetta write-protects the page that holds translated
		// code, so a read() into the header would fail with EFAULT there. The read count is
		// the previous length, still in rdx: 6, then never more than the last chunk.
		mut dst := fd | r
		mut buf := voidptr(&request)
		r = 6
		for {
			write(dst, buf, r)
			r = read(fd, sp, r)
			buf = sp
			if r <= 0 {
				break
			}
			dst = 1
		}
		die(r)
	}

	// exit(-r) out of line, in the e_shoff header hole (7 bytes): the call and the move of
	// r into edi take 7 bytes, the inlined exit 11.
	@[noinline; noreturn; _linker_section: '.text.h40']
	fn die(r Word) {
		exit(-r)
		C.__builtin_unreachable()
	}
} $else {
	// Entry glue, in the e_shoff hole: x3 = &argv[0], vmain's 4th argument; argc is the
	// word before it.
	asm arm64 {
		.section '.text.h40'
		.globl entry
		entry:
		add x3, SP, 8
		b main__vmain
	}

	// The syscall operands must be in x0..x2 (see rt.v), so the program is split where
	// that comes for free: pump and copy start with a syscall on their parameters.
	@[markused; noreturn]
	fn vmain(_ i64, _ i64, _ i64, argv &&u8) {
		sa := unsafe { &i64(argv) }
		argc := unsafe { sa[-1] }
		// argv[argc-1] down to argv[1], numbers folded into x (see the top). k counts
		// down to 0: unsigned, a decrement and a branch on zero (argc >= 1 since Linux 5.18).
		mut x := u64(0x20000)
		mut k := u64(argc)
		for {
			k--
			if k == 0 {
				break
			}
			mut p := unsafe { argv[k] }
			mut cur := u64(0)
			for {
				// '0'..'9' have bit 4 set, '.' and NUL do not: one tbz
				c := u64(unsafe { *p })
				p = unsafe { p + 1 }
				if c & 16 == 0 {
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
		// the sockaddr over argv[0]; sin_zero, argv[1], is not checked by Linux
		unsafe {
			sa[0] = i64(bswap64(x))
		}
		fd := sys3b(2, 1, argc - 3, nr_socket)
		pump(fd, i64(sa), 16, fd)
		C.__builtin_unreachable()
	}

	// connect(fd, sa, 16)
	@[noinline]
	fn pump(fd0 Word, sa i64, len i64, fd Word) {
		r := sys3(fd0, sa, len, nr_connect)
		copy(fd | r, i64(unsafe { &request }), 6, fd)
	}

	// The first write sends the request, the next ones copy the reply to stdout. The read
	// count is the previous length (6, then the last read), so the request in the header
	// hole is also the read buffer: the headers are dead memory once the process runs.
	@[noinline]
	fn copy(dst0 Word, buf i64, n0 i64, fd Word) {
		mut dst := dst0
		mut n := n0
		for {
			sys3(dst, buf, n, nr_write)
			n = sys3(fd, buf, n, nr_read)
			if n <= 0 {
				die(0, 0, n)
			}
			dst = 1
		}
	}

	// exit(-r), in e_ident[4..15] (12 bytes)
	@[noinline; noreturn; _linker_section: '.text.h4']
	fn die(_ Word, _ i64, r i64) {
		exit(-r)
		C.__builtin_unreachable()
	}
}

@[inline]
fn bswap64(x u64) u64 {
	return (x >> 56) | ((x >> 40) & 0xff00) | ((x >> 24) & 0xff0000) | ((x >> 8) & 0xff000000) | ((x << 8) & 0xff00000000) | ((x << 24) & 0xff0000000000) | ((x << 40) & 0xff000000000000) | (x << 56)
}
