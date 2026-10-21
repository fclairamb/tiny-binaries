# hello, x86_64 Linux: raw write + exit syscalls, custom entry, no libc.
# Source for the `default` and `optimized` variants (only flags differ).
	.text
	.global _start
_start:
	mov	$1, %edi		# fd = stdout
	lea	msg(%rip), %rsi		# buf
	mov	$14, %edx		# len
	mov	$1, %eax		# __NR_write
	syscall
	xor	%edi, %edi		# status = 0
	mov	$60, %eax		# __NR_exit
	syscall
msg:
	.ascii	"Hello, World!\n"
