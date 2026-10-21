// hello, extreme variant for darwin-arm64: no V runtime (-no-builtin), no libSystem calls.
module main

// Darwin arm64 system call: number in x16, arguments in x0..x2, `svc #0x80`.
// V's arm64 asm can't bind an operand to a given register, hence the moves.
@[inline]
fn syscall3(n u64, a u64, b u64, c u64) {
	asm volatile arm64 {
		mov x16, n
		mov x0, a
		mov x1, b
		mov x2, c
		svc 0x80
		; ; r (n)
		  r (a)
		  r (b)
		  r (c)
		; x0
		  x1
		  x2
		  x16
		  memory
	}
}

// Entry point (ld -e _start), called by dyld like main().
@[export: 'start']
fn start() {
	syscall3(4, 1, u64(c'Hello, World!\n'), 14) // write(1, msg, 14)
	syscall3(1, 0, 0, 0) // exit(0)
}

// V wants a main; it is never called and the linker drops it.
fn main() {}
