; tcp client, x86_64 Linux, extreme: a hand-written flat ELF (nasm -f bin).
;
; Same hand-built header as hello-x86_64-extreme.asm: one PT_LOAD from file
; offset 0 at vaddr 0x10000, the 56-byte phdr overlapping the ELF header tail
; (e_phoff = 56), the 6-byte request hidden in an ignored header field, and the
; code starting at offset 104 (the phdr's p_align field). See that file for why
; each trick is valid on both the real kernel and Rosetta.
;
; tcp <ipv4> <port>: connect, send "hello\n", copy the reply to stdout until
; EOF. Every failure (bad argc, socket/connect/read error, reset mid-reply)
; funnels through one tail. A negative syscall return is negated into the errno
; it carries (ECONNREFUSED 111, ECONNRESET 104), all in 1..125.
;
; Registers held across syscalls (Linux clobbers only rax, rcx, r11):
;   rbx = argv base, then the socket fd   rsi = read/write pointer   rbp = count

BITS 64
org 0x10000

ehdr:
	db	0x7f, "ELF", 2, 1, 1, 0	; e_ident[0..7]
	dq	0			; e_ident[8..15] padding (Rosetta wants 0)
	dw	2			; e_type  = ET_EXEC
	dw	0x3e			; e_machine = EM_X86_64
	dd	1			; e_version
	dq	_start			; e_entry
	dq	phdr - ehdr		; e_phoff = 56
req:	db	"hello", 0x0a		; 6-byte request in e_shoff (offset 40..45)
	times 54-($-ehdr) db 0		; pad to e_phentsize
	dw	56			; e_phentsize = 56

phdr:	dd	1			; p_type = PT_LOAD; low word doubles as e_phnum = 1
	dd	5			; p_flags = R+X
	dq	0			; p_offset
	dq	0x10000			; p_vaddr (64 KB aligned)
	dq	0			; p_paddr (ignored)
	dq	filesize		; p_filesz
	dq	filesize		; p_memsz
					; p_align (104..111) overlaps the first code bytes
_start:
	mov	rbx, rsp		; &argc; argv[1] = [rbx+16], argv[2] = [rbx+24]
	cmp	qword [rbx], 3
	jl	usage

	sub	rsp, 4112		; sockaddr_in (16) + read buffer (4096)
	xor	eax, eax
	mov	[rsp], rax		; zero sockaddr
	mov	[rsp+8], rax
	mov	word [rsp], 2		; sin_family = AF_INET

	mov	rsi, [rbx+24]		; argv[2] = port
	call	parse_uint
	mov	[rsp+2], ah		; sin_port, network order
	mov	[rsp+3], al

	mov	rsi, [rbx+16]		; argv[1] = dotted quad
	lea	rdi, [rsp+4]		; -> sin_addr
	mov	ebx, 4			; octet counter (argv base no longer needed)
.octet:
	call	parse_uint
	mov	[rdi], al
	inc	rdi
	cmp	byte [rsi], '.'
	jne	.nodot
	inc	rsi
.nodot:
	dec	ebx
	jnz	.octet

	push	2			; socket(AF_INET, SOCK_STREAM, 0)
	pop	rdi
	push	1
	pop	rsi
	xor	edx, edx
	push	41
	pop	rax
	syscall
	test	rax, rax
	js	fail
	mov	rbx, rax		; fd

	mov	rdi, rbx		; connect(fd, &sockaddr, 16)
	mov	rsi, rsp
	push	16
	pop	rdx
	push	42
	pop	rax
	syscall
	test	rax, rax
	js	fail

	mov	rdi, rbx		; write(fd, "hello\n", 6)
	mov	esi, req
	push	6
	pop	rdx
	push	1
	pop	rax
	syscall
	cmp	rax, 6
	jne	fail

read_loop:
	mov	rdi, rbx		; read(fd, buf, 4096)
	lea	rsi, [rsp+16]
	mov	edx, 4096
	xor	eax, eax
	syscall
	test	rax, rax
	js	fail			; n<0: reset mid-reply reaches here
	jz	done			; n==0: clean EOF
	mov	rbp, rax		; bytes remaining to write
.wloop:
	push	1			; write(1, rsi, remaining)
	pop	rdi
	mov	rdx, rbp
	push	1
	pop	rax
	syscall
	test	rax, rax
	jle	fail
	add	rsi, rax		; advance pointer, drop remaining
	sub	rbp, rax
	jnz	.wloop
	jmp	read_loop

done:
	xor	edi, edi
	jmp	do_exit
usage:
	push	2			; usage error: fixed code
	pop	rdi
	jmp	do_exit
fail:
	neg	rax			; -errno -> errno (1..125)
	mov	rdi, rax
do_exit:
	push	60
	pop	rax
	syscall

; parse_uint: read a decimal number at [rsi], stop at the first non-digit.
; Returns the value in eax and leaves rsi on the stopping character.
parse_uint:
	xor	eax, eax
.lp:
	movzx	ecx, byte [rsi]
	sub	ecx, '0'
	cmp	ecx, 9
	ja	.done
	lea	eax, [rax+rax*4]	; eax *= 5
	lea	eax, [rcx+rax*2]	; eax = c + 2*eax
	inc	rsi
	jmp	.lp
.done:
	ret
filesize equ	$ - ehdr
