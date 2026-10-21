// Syscall layer for the extreme variant: no libc, no V builtin.
// Inline asm is limited to the syscall instruction and moving the operands. On amd64 the
// register constraints ("a", "D", "S", "d") put the operands in place. On arm64, gcc and
// clang have no constraint for a given x register (C code would use register variables,
// which V cannot express), so the asm moves the operands into x0-x2 and x8 itself.
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

	@[inline]
	fn sys1v(n Word, a Word) {
		mut res := n
		asm volatile amd64 {
			syscall
			; +a (res)
			; D (a)
			; rcx
			  r11
			  memory
		}
	}

	// r10 is listed as clobbered although syscall leaves it alone (it is the 4th argument
	// register, which 3-argument calls ignore): that steers clang away from r10, which needs
	// a REX prefix, for a value that lives across syscalls, such as tcp's fd. It lands in
	// ebx instead (3 bytes less in tcp, after the push that saves rbx).
	@[inline]
	fn sys3(n Word, a Word, b i64, c i64) Word {
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

	@[inline]
	fn sys3v(n Word, a Word, b i64, c i64) {
		sys3(n, a, b, c)
	}
} $else {
	// 64-bit everywhere: the asm operands are x registers, so an int would need extending.
	type Word = i64

	const nr_read = 63
	const nr_write = 64
	const nr_socket = 198
	const nr_connect = 203
	const nr_exit = 93

	@[inline]
	fn sys1v(n Word, a Word) {
		asm volatile arm64 {
			mov x0, a
			mov x8, n
			svc 0
			; ; rn (n)
			  rn (a)
			; x0
			  x8
			  memory
		}
	}

	@[inline]
	fn sys3v(n Word, a Word, b i64, c i64) {
		asm volatile arm64 {
			mov x0, a
			mov x1, b
			mov x2, c
			mov x8, n
			svc 0
			; ; rn (n)
			  rn (a)
			  rn (b)
			  rn (c)
			; x0
			  x1
			  x2
			  x8
			  memory
		}
	}

	@[inline]
	fn sys3(n Word, a Word, b i64, c i64) Word {
		mut res := Word(0)
		asm volatile arm64 {
			mov x0, a
			mov x1, b
			mov x2, c
			mov x8, n
			svc 0
			mov res, x0
			; =r (res)
			; rn (n)
			  rn (a)
			  rn (b)
			  rn (c)
			; x0
			  x1
			  x2
			  x8
			  memory
		}
		return res
	}
}

// Syscalls whose result is not used go through sys3v, which on arm64 saves moving x0 out.
@[inline]
fn write(fd Word, buf voidptr, n i64) {
	sys3v(nr_write, fd, i64(buf), n)
}

@[inline]
fn read(fd Word, buf voidptr, n i64) Word {
	return sys3(nr_read, fd, i64(buf), n)
}

// exit is not @[noreturn]: clang does not inline calls to noreturn functions at -Oz (they
// count as cold). Callers follow it with C.__builtin_unreachable(), which only tells clang
// that control never gets past the syscall, so no code follows it.
@[inline]
fn exit(code Word) {
	sys1v(nr_exit, code)
}

@[noreturn]
fn C.__builtin_unreachable()

fn main() {}
