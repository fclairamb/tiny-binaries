module main

// "Hello, World!\n" without the C string NUL: 14 bytes, the size of a header hole
const msg = [u8(72), 101, 108, 108, 111, 44, 32, 87, 111, 114, 108, 100, 33, 10]!

@[markused; noreturn]
fn vmain() {
	write(1, &msg, 14)
	exit(0)
	C.__builtin_unreachable()
}
