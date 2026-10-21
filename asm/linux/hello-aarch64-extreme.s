// hello, aarch64 Linux, extreme: a hand-written flat ELF.
// Assembled with GNU as, linked with ld, then objcopy -O binary strips the ELF
// container to the raw image we laid out (ld --oformat binary is refused on
// AArch64: "cannot change output format whilst linking AArch64 binaries").
//
// One PT_LOAD maps the whole file from offset 0 at vaddr 0x10000. The 56-byte
// program header overlaps the ELF header tail (e_phoff = 56), so the phdr's
// first word doubles as e_phnum (1) / e_shentsize (0). The 14-byte message sits
// in the e_shoff/e_flags/e_ehsize hole (offsets 40..53). The code is split:
// 8 bytes in the p_paddr hole (offsets 80..87, ignored for ET_EXEC), the rest at
// offset 104 (the p_align field), linked by a branch. The file ends at 132.
//
// aarch64 instructions are fixed 4-byte and must be 4-aligned; 80 and 104 are
// multiples of 4. p_offset 0 with p_vaddr a multiple of 64 KB keeps it page-size
// independent (loads under 4/16/64 KB page kernels). At entry Linux zeroes
// x0..x30, but every value here is set explicitly. aarch64 never runs under
// Rosetta, so there is no p_filesz floor to satisfy here (contrast the amd64
// source); p_filesz is just the real file size.
	.text
	.global _start
ehdr:
	.byte	0x7f, 'E', 'L', 'F', 2, 1, 1, 0	// e_ident[0..7]
	.quad	0			// e_ident[8..15] padding
	.short	2			// e_type = ET_EXEC
	.short	0xB7			// e_machine = EM_AARCH64
	.long	1			// e_version
	.quad	_start			// e_entry
	.quad	phdr - ehdr		// e_phoff = 56
msg:
	.ascii	"Hello, World!\n"	// 14 bytes in e_shoff/e_flags/e_ehsize (40..53)
	.short	56			// e_phentsize (54..55) = 56

phdr:
	.long	1			// p_type = PT_LOAD; low half (56..57) = e_phnum = 1
	.long	5			// p_flags = R+X
	.quad	0			// p_offset
	.quad	0x10000			// p_vaddr (64 KB aligned)
_start:					// p_paddr (80..87), ignored for ET_EXEC
	mov	x0, #1			// fd = stdout
	b	p3
	.quad	filesize		// p_filesz
	.quad	filesize		// p_memsz
p3:					// offset 104 (the p_align field)
	adr	x1, msg			// buf
	mov	x2, #14			// len
	mov	x8, #64			// __NR_write
	svc	#0
	mov	x0, #0			// status = 0
	mov	x8, #93			// __NR_exit
	svc	#0
	.set	filesize, . - ehdr
