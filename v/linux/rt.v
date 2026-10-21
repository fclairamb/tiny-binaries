// Syscall layer for the extreme variant: no libc, no V builtin. The helpers take the
// syscall arguments in order, then the number: sys3(a, b, c, n).
// Inline asm is limited to the syscall instruction and getting the operands into place.
module main

$if amd64 {
	// fds, syscall numbers and results are 32-bit: no REX.W prefixes. The kernel
	// truncates int arguments; pointers and lengths stay 64-bit.
	type Word = int

	const nr_read = 0
	const nr_write = 1
	const nr_socket = 41
	const nr_connect = 42
	const nr_exit = 60

	// The register constraints ("a", "D", "S", "d") place the operands. r10 is listed as
	// clobbered although syscall leaves it alone (it is the 4th argument register, which
	// 3-argument calls ignore): that steers clang away from r10, which needs a REX prefix,
	// for a value that lives across syscalls, such as tcp's fd.
	@[inline]
	fn sys3(a Word, b i64, c i64, n Word) Word {
		mut res := n
		asm volatile amd64 {
			syscall
			; +a (res)
			; D (a)
			  S (b)
			  d (c)
			; rcx
			  r10
			  r11
			  memory
		}
		return res
	}

	// the same with r9 listed as clobbered too
	@[inline]
	fn sys3x(a Word, b i64, c i64, n Word) Word {
		mut res := n
		asm volatile amd64 {
			syscall
			; +a (res)
			; D (a)
			  S (b)
			  d (c)
			; rcx
			  r9
			  r10
			  r11
			  memory
		}
		return res
	}

	@[inline]
	fn exit(a Word) {
		mut res := Word(nr_exit)
		asm volatile amd64 {
			syscall
			; +a (res)
			; D (a)
			; rcx
			  r11
			  memory
		}
	}
	@[inline]
	fn exitm(a Word) {
		exit(a)
	}
} $else {
	// 64-bit everywhere: the asm operands are x registers.
	type Word = i64

	const nr_read = 63
	const nr_write = 64
	const nr_socket = 198
	const nr_connect = 203
	const nr_exit = 93

	// arm64 has no asm constraint for a given x register (C would use register variables,
	// which V cannot express). So the asm takes an operand as it is, "in place", and a
	// check makes sure the compiler put it in its register: the asm names a section after
	// the registers it got (.ck.ax0.bx1.cx2 when a, b and c are in x0, x1 and x2), and
	// link.ld discards the right names and stops the link on any other. The asm itself is
	// the svc and the move of the constant syscall number into x8 (the number is always a
	// constant here). x9..x18 are listed as clobbered although the kernel leaves them
	// alone: values that live across a syscall then stay out of them, and the allocator
	// picks x0..x7 for the operands. In a function whose parameters are the syscall
	// arguments, they are in place from the start.
	@[inline]
	fn sys3(a Word, b i64, c i64, n Word) Word {
		mut res := a
		asm volatile arm64 {
			.section '.ck.a%[res].b%[b].c%[c]'
			.byte 0
			.previous
			mov x8, n
			svc 0
			; +r (res)
			; r (b)
			  r (c)
			  rn (n)
			; x8
			  x9
			  x10
			  x11
			  x12
			  x13
			  x14
			  x15
			  x16
			  x17
			  x18
			  memory
		}
		return res
	}

	// the same with b moved into x1 by the asm (for a constant)
	@[inline]
	fn sys3b(a Word, b i64, c i64, n Word) Word {
		mut res := a
		asm volatile arm64 {
			.section '.ck.a%[res].c%[c]'
			.byte 0
			.previous
			mov x1, b
			mov x8, n
			svc 0
			; +r (res)
			; rn (b)
			  r (c)
			  rn (n)
			; x1
			  x8
			  x9
			  x10
			  x11
			  x12
			  x13
			  x14
			  x15
			  x16
			  x17
			  x18
			  memory
		}
		return res
	}

	// exit with the status moved into x0 by the asm (for a constant)
	@[inline]
	fn exitm(a Word) {
		asm volatile arm64 {
			mov x0, a
			mov x8, 93
			svc 0
			; ; rn (a)
			; x0
			  x8
			  memory
		}
	}

	@[inline]
	fn exit(a Word) {
		asm volatile arm64 {
			.section '.ck.a%[a]'
			.byte 0
			.previous
			mov x8, 93
			svc 0
			; ; r (a)
			; x8
			  x9
			  x10
			  x11
			  x12
			  x13
			  x14
			  x15
			  x16
			  x17
			  x18
			  memory
		}
	}
}

@[inline]
fn write(fd Word, buf voidptr, n i64) {
	$if amd64 {
		sys3x(fd, i64(buf), n, nr_write)
	} $else {
		sys3(fd, i64(buf), n, nr_write)
	}
}

@[inline]
fn read(fd Word, buf voidptr, n i64) Word {
	$if amd64 {
		return sys3x(fd, i64(buf), n, nr_read)
	} $else {
		return sys3(fd, i64(buf), n, nr_read)
	}
}

// C.__builtin_unreachable() after a call that never returns: no code follows it. exit is
// not @[noreturn], since clang does not inline calls to noreturn functions at -Oz.
@[noreturn]
fn C.__builtin_unreachable()

fn main() {}
