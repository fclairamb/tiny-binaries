// hello, aarch64 Linux: raw write + exit syscalls, custom entry, no libc.
// Source for the `default` and `optimized` variants (only flags differ).
	.text
	.global _start
_start:
	mov	x0, #1			// fd = stdout
	adr	x1, msg			// buf
	mov	x2, #14			// len
	mov	x8, #64			// __NR_write
	svc	#0
	mov	x0, #0			// status = 0
	mov	x8, #93			// __NR_exit
	svc	#0
msg:
	.ascii	"Hello, World!\n"
