; hello, x86_64 Linux, extreme: a hand-written flat ELF (nasm -f bin).
;
; The whole file IS the ELF image, mapped by one PT_LOAD from file offset 0 at
; vaddr 0x10000. Two space tricks, both relying only on documented loader
; behaviour:
;   1. The 56-byte program header overlaps the tail of the 64-byte ELF header:
;      e_phoff = 56, so the phdr's first dword (p_type = 1) doubles as e_phnum
;      (= 1) and e_shentsize (= 0). Saves 8 bytes.
;   2. The 14-byte message and the code live in ELF-header bytes the kernel
;      never reads: the message in e_shoff/e_flags/e_ehsize (offsets 40..53),
;      the code from offset 104 onward, which is the phdr's p_align field. A
;      bogus p_align is fine: the kernel only needs p_offset congruent to
;      p_vaddr modulo the page size, and both are 0 mod 0x10000.
;
; At process entry Linux clears the general-purpose registers (rax=rdx=rdi=0),
; which this code uses to shorten the register setup. This is documented kernel
; behaviour (fs/binfmt_elf.c, ELF_PLAT_INIT / start_thread on x86_64).

BITS 64
org 0x10000

ehdr:
	db	0x7f, "ELF", 2, 1, 1, 0	; e_ident[0..7]: magic, 64-bit, LE, v1, SysV
	dq	0			; e_ident[8..15] padding (Rosetta checks these = 0)
	dw	2			; e_type  = ET_EXEC
	dw	0x3e			; e_machine = EM_X86_64
	dd	1			; e_version
	dq	_start			; e_entry
	dq	phdr - ehdr		; e_phoff = 56
msg:	db	"Hello, World!", 0x0a	; 14 bytes in e_shoff/e_flags/e_ehsize (40..53)
	dw	56			; e_phentsize (54..55) = 56, enforced by the kernel

phdr:	dd	1			; p_type = PT_LOAD; low word (56..57) is e_phnum = 1
	dd	5			; p_flags = R+X
	dq	0			; p_offset
	dq	0x10000			; p_vaddr (64 KB aligned: loads on 4/16/64 KB pages)
	dq	0			; p_paddr (ignored)
	dq	filesize		; p_filesz
	dq	filesize		; p_memsz
					; p_align (104..111) is the first 8 bytes of code
_start:
	mov	esi, msg		; buf (zero-extends to rsi)
	mov	dl, 14			; len (rdx = 0 at entry)
	inc	edi			; fd = 1 (rdi = 0 at entry)
	mov	al, 1			; __NR_write (rax = 0 at entry)
	syscall
	mov	al, 60			; __NR_exit
	xor	edi, edi		; status 0
	syscall
filesize equ	$ - ehdr
