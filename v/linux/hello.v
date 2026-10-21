module main

// "Hello, World!\n" without the C string NUL: 14 bytes, the size of the header hole at 40
const msg = [u8(72), 101, 108, 108, 111, 44, 32, 87, 111, 114, 108, 100, 33, 10]!

// The program is split into functions that call each other with the registers the next one
// needs as arguments, so that the first ones fit in header holes (link.ld).
$if amd64 {
	// entry, in p_paddr (8 bytes): push 14; pop rdx; call h2. a and b are whatever the
	// kernel left in rdi and rsi; h2 ignores them, they are passed so no code moves them.
	@[markused; noreturn; _linker_section: '.text.h80']
	fn vmain(a Word, b i64) {
		h2(a, b, 14)
		C.__builtin_unreachable()
	}

	@[noinline; noreturn]
	fn h2(_ Word, _ i64, n i64) {
		write(1, &msg, n)
		exit(0)
		C.__builtin_unreachable()
	}
} $else {
	// entry, in e_ident[4..15] (12 bytes): mov x0, #1; adr x1, msg; bl h2
	@[markused; noreturn; _linker_section: '.text.h4']
	fn vmain() {
		h2(1, i64(&msg))
		C.__builtin_unreachable()
	}

	// in p_paddr (8 bytes): mov x2, #14; bl h3
	@[noinline; noreturn; _linker_section: '.text.h80']
	fn h2(fd Word, buf i64) {
		h3(fd, buf, 14)
		C.__builtin_unreachable()
	}

	// the two syscalls, operands in place
	@[noinline; noreturn]
	fn h3(fd Word, buf i64, n i64) {
		sys3(fd, buf, n, nr_write)
		exitm(0)
		C.__builtin_unreachable()
	}
}
