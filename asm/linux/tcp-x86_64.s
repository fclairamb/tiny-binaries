# tcp client, x86_64 Linux: raw syscalls, custom entry, no libc.
# Source for the `default` and `optimized` variants (only flags differ).
#
# tcp <ipv4> <port>: connect, send "hello\n", copy the reply to stdout until
# EOF. Every failure (bad argc, socket/connect/read error, reset mid-reply)
# funnels through one exit tail. A negative syscall return is negated into the
# errno it carries (ECONNREFUSED 111, ECONNRESET 104), all inside 1..125.
#
# Registers held across syscalls (Linux clobbers only rax, rcx, r11):
#   rbx = argv   r12 = socket fd   r13 = bytes read   r14 = write offset
	.text
	.global _start
_start:
	mov	(%rsp), %rdi		# argc
	lea	8(%rsp), %rbx		# argv
	cmp	$3, %rdi
	jl	usage

	sub	$4112, %rsp		# sockaddr_in (16) + read buffer (4096)
	movq	$0, (%rsp)
	movq	$0, 8(%rsp)
	movw	$2, (%rsp)		# sin_family = AF_INET

	mov	16(%rbx), %rsi		# argv[2] = port
	call	parse_uint
	mov	%ah, 2(%rsp)		# sin_port, network (big-endian) order
	mov	%al, 3(%rsp)

	mov	8(%rbx), %rsi		# argv[1] = dotted quad
	lea	4(%rsp), %rdi		# -> sin_addr
	mov	$4, %r8d
.Loctet:
	call	parse_uint
	mov	%al, (%rdi)
	inc	%rdi
	cmpb	$'.', (%rsi)
	jne	1f
	inc	%rsi
1:	dec	%r8d
	jnz	.Loctet

	mov	$2, %edi		# socket(AF_INET, SOCK_STREAM, 0)
	mov	$1, %esi
	xor	%edx, %edx
	mov	$41, %eax
	syscall
	test	%rax, %rax
	js	fail
	mov	%rax, %r12		# fd

	mov	%r12, %rdi		# connect(fd, &sockaddr, 16)
	mov	%rsp, %rsi
	mov	$16, %edx
	mov	$42, %eax
	syscall
	test	%rax, %rax
	js	fail

	mov	%r12, %rdi		# write(fd, "hello\n", 6)
	lea	req(%rip), %rsi
	mov	$6, %edx
	mov	$1, %eax
	syscall
	cmp	$6, %rax
	jne	fail

read_loop:
	mov	%r12, %rdi		# read(fd, buf, 4096)
	lea	16(%rsp), %rsi
	mov	$4096, %edx
	xor	%eax, %eax
	syscall
	test	%rax, %rax
	js	fail			# n<0: reset mid-reply reaches here
	jz	done			# n==0: clean EOF
	mov	%rax, %r13		# total bytes read
	xor	%r14d, %r14d		# write offset
wloop:
	lea	16(%rsp), %rsi
	add	%r14, %rsi
	mov	%r13, %rdx
	sub	%r14, %rdx
	mov	$1, %edi		# write(1, buf+off, n-off)
	mov	$1, %eax
	syscall
	test	%rax, %rax
	jle	fail
	add	%rax, %r14
	cmp	%r13, %r14
	jl	wloop
	jmp	read_loop

done:
	xor	%edi, %edi
	jmp	do_exit
usage:
	mov	$2, %edi		# usage error: fixed code
	jmp	do_exit
fail:
	neg	%rax			# -errno -> errno (1..125)
	mov	%rax, %rdi
do_exit:
	mov	$60, %eax		# __NR_exit
	syscall

# parse_uint: read a decimal number at (%rsi), stop at the first non-digit.
# Returns the value in eax and leaves %rsi on the stopping character.
parse_uint:
	xor	%eax, %eax
.Lpu:
	movzbl	(%rsi), %ecx
	sub	$'0', %ecx
	cmp	$9, %ecx
	ja	.Lpu_done
	lea	(%rax,%rax,4), %eax	# eax *= 5
	lea	(%rcx,%rax,2), %eax	# eax = c + 2*eax
	inc	%rsi
	jmp	.Lpu
.Lpu_done:
	ret

req:
	.ascii	"hello\n"
