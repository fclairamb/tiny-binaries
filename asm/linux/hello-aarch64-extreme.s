// hello, aarch64 Linux, extreme: a hand-written flat ELF.
// Assembled with GNU as, linked with ld, then objcopy -O binary strips the ELF
// container to the raw image we laid out (ld --oformat binary is refused on
// AArch64: "cannot change output format whilst linking AArch64 binaries").
//
// One PT_LOAD maps the whole file from offset 0 at vaddr 0x10000. The 56-byte
// program header overlaps the ELF header tail (e_phoff = 56), so the phdr's
// first word doubles as e_phnum (1) / e_shentsize (0). Three code holes the
// kernel ignores carry the program, linked by branches:
//   - e_ident[4..15] (offsets 4..15): the first 2 instructions and a branch.
//   - p_paddr        (offsets 80..87): 1 instruction and a branch.
//   - offset 104     (the p_align field) onward: the 5-instruction tail.
// The 14-byte message sits in the e_shoff/e_flags/e_ehsize hole (40..53). The
// file ends at 124.
//
// e_ident[4..15] is a hole only on aarch64: binfmt_elf checks just the 4-byte
// magic (e_ident[0..3]), e_type, e_machine, e_phentsize and e_phnum, and picks
// ELF64 from e_machine (EM_AARCH64), never from EI_CLASS. So EI_CLASS/EI_DATA/
// EI_VERSION hold code here; `file` and readelf then misread the class, but the
// kernel loads it. (Rosetta, which runs the amd64 tests, rejects a nonstandard
// e_ident, so the amd64 source never uses this hole.) Documented kernel
// behaviour is fs/binfmt_elf.c; the hole is how that code reads the header, not
// an ABI promise.
//
// aarch64 instructions are fixed 4-byte and must be 4-aligned; 4, 8, 12, 80 and
// 104 are multiples of 4. p_offset 0 with p_vaddr a multiple of 64 KB keeps it
// page-size independent (loads under 4/16/64 KB page kernels). At entry Linux
// zeroes x0..x30, but every value here is set explicitly.
	.text
	.global _start
ehdr:
	.byte	0x7f, 'E', 'L', 'F'	// e_ident[0..3] magic (only this is checked)
_start:					// e_ident[4..15]: EI_CLASS..e_ident[15], ignored
	mov	x0, #1			// @4  fd = stdout
	adr	x1, msg			// @8  buf
	b	p2			// @12 -> p_paddr hole
	.short	2			// @16 e_type = ET_EXEC
	.short	0xB7			// @18 e_machine = EM_AARCH64
	.long	1			// @20 e_version
	.quad	_start			// @24 e_entry = 0x10004
	.quad	phdr - ehdr		// @32 e_phoff = 56
msg:
	.ascii	"Hello, World!\n"	// @40..53 in e_shoff/e_flags/e_ehsize
	.short	56			// @54 e_phentsize = 56

phdr:
	.long	1			// @56 p_type = PT_LOAD; low half = e_phnum = 1
	.long	5			// @60 p_flags = R+X
	.quad	0			// @64 p_offset
	.quad	0x10000			// @72 p_vaddr (64 KB aligned)
p2:					// @80..87 p_paddr, ignored for ET_EXEC
	mov	x2, #14			// @80 len
	b	p3			// @84 -> tail
	.quad	filesize		// @88 p_filesz
	.quad	filesize		// @96 p_memsz
p3:					// @104 the p_align field, onward
	mov	x8, #64			// @104 __NR_write
	svc	#0			// @108
	mov	x0, #0			// @112 status = 0
	mov	x8, #93			// @116 __NR_exit
	svc	#0			// @120
	.set	filesize, . - ehdr	// 124
