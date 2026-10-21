module main

// "Hello, World!\n" without the C string NUL: 14 bytes, the size of a header hole
const msg = [u8(72), 101, 108, 108, 111, 44, 32, 87, 111, 114, 108, 100, 33, 10]!

@[markused; noreturn]
fn vmain() {
	write(1, &msg, 14)
	exit0()
}

// exit(0) as a separate function, so the linker script can put its code in a header hole:
// the call costs less than the inlined syscall (amd64: a 5-byte call for 7 bytes in
// p_paddr; arm64: one bl for 3 instructions in e_ident[4..15]).
$if amd64 {
	@[noinline; noreturn; _linker_section: '.text.hole2']
	fn exit0() {
		exit(0)
		C.__builtin_unreachable()
	}
} $else {
	@[noinline; noreturn; _linker_section: '.text.hole']
	fn exit0() {
		exit(0)
		C.__builtin_unreachable()
	}
}
