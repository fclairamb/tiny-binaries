; hello, x86_64 Linux, extreme: a hand-written flat ELF (nasm -f bin).
;
; The whole file IS the ELF image, mapped by one PT_LOAD from file offset 0 at
; vaddr 0x10000. Three space tricks, all relying only on documented loader
; behaviour:
;   1. The 56-byte program header overlaps the tail of the 64-byte ELF header:
;      e_phoff = 56, so the phdr's first dword (p_type = 1) doubles as e_phnum
;      (= 1) and e_shentsize (= 0).
;   2. The message lives in ELF-header bytes the kernel never reads:
;      e_shoff/e_flags/e_ehsize (offsets 40..53), 14 bytes.
;   3. The code is split across the two header holes the kernel ignores, linked
;      by short jumps: 4 bytes in e_version (20..23), 8 bytes in p_paddr (80..87),
;      the 12-byte tail at offset 104 (the p_align field). The file ends at 116.
;
; Why the code may sit in header holes under Rosetta (the amd64 translator on this
; Mac): Rosetta's only size check on the first PT_LOAD is
;   p_filesz >= 64 + e_phnum*56   (= 120 here, ElfMapper.cpp map_elf).
; It does not care where e_entry points. So we set p_filesz = p_memsz = 120 while
; the file is 116 bytes; the 4 bytes past EOF (116..119) fall in the last mapped
; page and read as zero, which is documented mmap behaviour (a partial final page
; is zero-filled). The real 6.12 kernel accepts the same file, so it passes both.
;
; e_ident[8..15] stay zero: the host's binfmt_misc registration matches part of
; e_ident, and zero is the safe choice (see asm/linux/README.md).
;
; At process entry Linux clears the general-purpose registers (rax=rdx=rdi=0),
; which this code uses to shorten the register setup. Documented kernel behaviour
; (fs/binfmt_elf.c, ELF_PLAT_INIT / start_thread on x86_64). hello assumes its one
; write succeeds; if stdout is closed the second syscall runs off the image and
; the process dies by signal. SPEC leaves stdout-write errors unspecified.

BITS 64
org 0x10000

ehdr:
	db	0x7f, "ELF", 2, 1, 1, 0	; e_ident[0..7]: magic, 64-bit, LE, v1, SysV
	dq	0			; e_ident[8..15] padding (kept 0: binfmt mask + Rosetta)
	dw	2			; e_type  = ET_EXEC
	dw	0x3e			; e_machine = EM_X86_64
_start:					; e_version (20..23), ignored by the kernel
	inc	edi			; fd = 1 (rdi = 0 at entry)
	jmp	short p2		; -> p_paddr
	dq	_start			; e_entry
	dq	phdr - ehdr		; e_phoff = 56
msg:	db	"Hello, World!", 0x0a	; 14 bytes in e_shoff/e_flags/e_ehsize (40..53)
	dw	56			; e_phentsize (54..55) = 56, enforced by the kernel

phdr:	dd	1			; p_type = PT_LOAD; low word (56..57) is e_phnum = 1
	dd	5			; p_flags = R+X
	dq	0			; p_offset
	dq	0x10000			; p_vaddr (64 KB aligned: loads on 4/16/64 KB pages)
p2:					; p_paddr (80..87), ignored by the kernel
	mov	esi, msg		; buf (zero-extends to rsi)
	jmp	short p3
	db	0			; pad p_paddr out to 8 bytes
	dq	120			; p_filesz >= 64 + 56 for Rosetta; file is 116
	dq	120			; p_memsz
p3:					; offset 104 (the p_align field)
	mov	dl, 14			; len (rdx = 0 at entry)
	mov	al, 1			; __NR_write (rax = 0 at entry)
	syscall
	mov	al, 60			; __NR_exit (see header note on stdout errors)
	xor	edi, edi		; status 0
	syscall
filesize equ	$ - ehdr
