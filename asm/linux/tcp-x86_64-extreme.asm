; tcp client, x86_64 Linux, extreme: a hand-written flat ELF (nasm -f bin).
;
; The whole file IS the ELF image, mapped by one PT_LOAD. The 56-byte program
; header overlaps the ELF header from offset 48 (e_phoff = 48): the kernel reads
; p_type out of e_flags, finds e_phentsize (56) and e_phnum (1) inside p_flags
; and p_offset, and p_offset = 1 so the segment maps from file offset 0 at vaddr
; 0x10000 (p_vaddr = 0x10001, 1 congruent to 1 mod any page size). Code starts at
; offset 48 + 48 = 96, over the phdr's ignored p_align field. The 6-byte request
; lives in the e_shoff hole (offset 40), and the 8-byte exit tail lives in the
; p_paddr hole (offsets 72..79, ignored for ET_EXEC). asm/linux/README.md has the
; field-by-field account and what each loader checks.
;
; tcp <ipv4> <port>: connect, send "hello\n", copy the reply to stdout until EOF.
; Every failure (bad argc, connect error, reset mid-reply) ends in a 1..125 exit:
; a negative syscall return is negated into its errno (ECONNREFUSED 111,
; ECONNRESET 104); too few args exits with argc (1 or 2). Linux clobbers only rax,
; rcx, r11 across a syscall, so the fd lives in ebx/rdi, and the general registers
; are zero at entry (rdx stays 0 for socket's protocol arg).
;
; Two deterministic-layout tricks, both stated because they are not in any ABI
; document:
;   - The port pointer is never loaded. After the 4-octet parse, lodsb has left
;     rsi one byte past argv[1]'s NUL terminator. Linux lays the argv strings out
;     contiguously (argv[0]\0 argv[1]\0 argv[2]\0 ...), so rsi already points at
;     argv[2]. This is fixed kernel ABI layout, not luck: it does not depend on
;     ASLR, environment size or timing.
;   - The read buffer is rsp itself (no "sub rsp"). After the two pushes rsp
;     points at the dead 16-byte sockaddr; the 127 bytes read into it overwrite
;     the sockaddr and the dead argc/argv/envp/auxv slots just above, which are
;     never read again. 127 bytes always fit in the kernel-mapped initial stack.

BITS 64
org 0x10000

ehdr:
	db	0x7f, "ELF", 2, 1, 1, 0	; e_ident[0..7]
	dq	0			; e_ident[8..15] padding (kept 0: binfmt mask + Rosetta)
	dw	2			; e_type  = ET_EXEC
	dw	0x3e			; e_machine = EM_X86_64
	dd	1			; e_version (20..23, ignored)
	dq	_start			; e_entry
	dq	phdr - ehdr		; e_phoff = 48
req:	db	"hello", 0x0a		; 6-byte request in the e_shoff hole (40..45)
	dw	0			; 46..47

phdr:	dd	1			; p_type = PT_LOAD   (over e_flags, ignored)
	dd	0x00380005		; p_flags = R+X; e_phentsize = 56 at 54..55
	dq	1			; p_offset = 1; e_phnum = 1 at 56..57
	dq	0x10001			; p_vaddr
fail:					; p_paddr (72..79, ignored): the 8-byte exit tail
	neg	eax			; -errno -> errno, or EOF 0 -> exit 0
	xchg	eax, edi
do_exit:
	push	60
	pop	rax
	syscall
	dq	filesize - 1		; p_filesz (>= 120, so Rosetta is satisfied)
	dq	filesize - 1		; p_memsz
					; p_align (96..103) overlaps the first code bytes
_start:
	pop	rdi			; argc
	cmp	edi, 3
	jb	do_exit			; too few args: exit with argc (1 or 2)
	pop	rax			; argv[0]
	pop	rsi			; argv[1] = dotted quad

	mov	bl, 4			; parse the address into ebp (big-endian int)
.octet:
	call	parse			; returns the octet and steps rsi past the '.'
	shl	ebp, 8
	or	ebp, eax
	dec	bl
	jnz	.octet
	bswap	ebp			; -> s_addr (network order)
	shl	rbp, 32			; s_addr in the high half of the sockaddr qword

	call	parse			; parse the port; rsi already at argv[2] (see note)
	bswap	eax			; port -> network order at bits 16..31
	or	al, 2			; sin_family = AF_INET at bits 0..15
	or	rbp, rax
	push	rax			; sin_zero (contents ignored by connect)
	push	rbp			; sockaddr_in at rsp (16 bytes)

	push	41			; socket(AF_INET, SOCK_STREAM, 0); rdx = 0 at entry
	pop	rax
	push	2
	pop	rdi
	push	1
	pop	rsi
	syscall
	xchg	eax, edi		; fd -> edi (stays in rdi across connect and write)
	mov	ebx, edi		; fd also in ebx (restored before each read)

	push	42			; connect(fd, &sockaddr, 16)
	pop	rax
	push	rsp
	pop	rsi
	push	16
	pop	rdx
	syscall
	test	eax, eax
	js	fail			; a refused/failed connect exits 1..125

	push	1			; write(fd, "hello\n", 6)
	pop	rax
	mov	esi, req
	push	6
	pop	rdx
	syscall

	push	rsp
	pop	rsi			; buf = rsp: sockaddr + dead stack above (see note)
read_loop:
	mov	edi, ebx		; fd (restores it after the stdout write)
	mov	dl, 127			; read(fd, buf, 127); rdx high bits already 0
	xor	eax, eax
	syscall
	test	eax, eax
	jle	fail			; n<0 reset mid-reply, or n==0 EOF (neg 0 = exit 0)
	xchg	eax, edx		; write(1, buf, n): n <= PIPE_BUF so one write
	push	1			;   completes; stdout errors are unspecified
	pop	rdi
	mov	eax, edi
	syscall
	jmp	read_loop

parse:					; decimal at [rsi] -> eax; lodsb leaves rsi one past
	xor	ecx, ecx		;   the terminator (the '.' or the NUL)
.d:
	lodsb				; al = [rsi], rsi++
	sub	al, '0'
	cmp	al, 9
	ja	.done
	movzx	eax, al			; digit
	lea	ecx, [rcx+rcx*4]	; ecx *= 5
	lea	ecx, [rax+rcx*2]	; ecx = digit + 2*ecx
	jmp	.d
.done:
	xchg	eax, ecx
	ret
filesize equ	$ - ehdr
