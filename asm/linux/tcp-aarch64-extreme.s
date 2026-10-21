// tcp client, aarch64 Linux, extreme: a hand-written flat ELF.
// Assembled with GNU as, linked with ld, then objcopy -O binary strips the ELF
// container to the raw image we laid out.
//
// One PT_LOAD maps the whole file. The 56-byte program header overlaps the ELF
// header from offset 48 (e_phoff = 48): the kernel reads p_type out of e_flags,
// e_phentsize (56) and e_phnum (1) out of p_flags and p_offset, and p_offset = 1
// so the segment maps from file offset 0 at vaddr 0x10000 (p_vaddr = 0x10001).
// Code starts at offset 48 + 48 = 96, over the phdr's ignored p_align field; 96
// is 4-aligned. The program lives in three code holes the kernel ignores, linked
// by branches, plus the tail:
//   - e_ident[4..15] (offsets 4..15): the entry glue (argc, argv[1]) + a branch.
//   - p_paddr        (offsets 72..79): the octet-store pointer + a branch.
//   - offset 96      (the p_align field) onward: the rest of the code.
// The 6-byte request lives in the e_shoff hole (offset 40). p_offset 1 == p_vaddr
// mod page for 4/16/64 KB pages, so the layout is page-size independent.
//
// e_ident[4..15] is a hole only on aarch64: binfmt_elf checks the 4-byte magic,
// e_type, e_machine, e_phentsize and e_phnum, and picks ELF64 from e_machine, not
// from EI_CLASS, so EI_CLASS/EI_DATA/EI_VERSION carry code (tools misread the
// class; the kernel loads it). Rosetta rejects a nonstandard e_ident, so the
// amd64 source never uses this hole.
//
// tcp <ipv4> <port>: connect, send "hello\n", copy the reply to stdout until EOF.
// Every failure (bad argc, connect error, reset mid-reply) ends in a 1..125 exit:
// a negative syscall return is negated into its errno; too few args exit 3-argc
// (2 or 1). svc preserves every register except x0, so the fd lives in x19 across
// connect, write and read. x19 is also the parse pointer, but all parsing
// finishes before the socket call that produces the fd, so the two uses never
// overlap. At entry Linux zeroes x0..x30.
//
// The segment is R+W+X (p_flags = 7): the 6-byte request at offset 40 doubles as
// the read buffer, so one loop sends the request (first write to the socket) and
// then copies the reply (later writes to stdout), with x1 (buf) and the request
// length never reloaded. The read count is the previous chunk's length, at most
// 6, so the reply arrives in <=6-byte reads: correct, and SPEC sets no speed.
// Reading into the dead request bytes needs W on the segment; Linux maps R+W+X as
// asked (no W^X for ELF segments unless a security module adds one). The idea and
// the layout are the V slice's.
//
// Two deterministic-layout tricks, both stated because they are not in any ABI
// document:
//   - The port pointer is never loaded separately. After the 4-octet parse, x19
//     has advanced one byte past argv[1]'s NUL. Linux lays the argv strings out
//     contiguously, so x19 already points at argv[2]. Fixed kernel ABI layout,
//     not luck (independent of ASLR, environment size, timing).
//   - The 16-byte sockaddr sits at sp (no "sub sp"), over the dead argc/argv slots,
//     which are never read again after parsing.
	.text
	.global _start
ehdr:
	.byte	0x7f, 'E', 'L', 'F'	// e_ident[0..3] magic (only this is checked)
_start:					// e_ident[4..15]: entry glue, ignored by the kernel
	ldr	x0, [sp]		// @4  argc
	ldr	x19, [sp, #16]		// @8  argv[1] (parse ptr); argv[2] follows it
	b	g2			// @12 -> p_paddr hole
	.short	2			// @16 e_type = ET_EXEC
	.short	0xB7			// @18 e_machine = EM_AARCH64
	.long	1			// @20 e_version (ignored)
	.quad	_start			// @24 e_entry = 0x10004
	.quad	phdr - ehdr		// @32 e_phoff = 48
req:
	.ascii	"hello\n"		// @40..45 request in the e_shoff hole
	.short	0			// @46..47
phdr:
	.long	1			// @48 p_type = PT_LOAD  (over e_flags, ignored)
	.long	0x00380007		// @52 p_flags = R+W+X; e_phentsize = 56 at 54..55
	.quad	1			// @56 p_offset = 1; e_phnum = 1 at 56..57
	.quad	0x10001			// @64 p_vaddr
g2:					// @72..79 p_paddr, ignored for ET_EXEC
	add	x7, sp, #4		// @72 store the 4 address octets at sp+4..7
	b	p2			// @76 -> tail
	.quad	filesize - 1		// @80 p_filesz
	.quad	filesize - 1		// @88 p_memsz
p2:					// @96 the p_align field, onward
	subs	x0, x0, #3		// argc - 3; negative with fewer than 2 arguments
	b.mi	fail			// too few args: x0 = argc-3, neg -> 3-argc (1..125)
	mov	w5, #4			// argc is dead after this (socket clobbers x0)
.octet:
	bl	parse
	strb	w0, [x7], #1
	subs	w5, w5, #1
	b.ne	.octet

	bl	parse			// parse the port; x19 already at argv[2] (see note)
	rev	w0, w0			// port -> network order at bits 16..31
	orr	w0, w0, #2		// sin_family = AF_INET at bits 0..15
	str	w0, [sp]		// sockaddr: family + port (octets already at +4)

	mov	x0, #2			// socket(AF_INET, SOCK_STREAM, 0); x2 = 0 at entry
	mov	x1, #1
	mov	x8, #198
	svc	#0
	mov	x19, x0			// fd

	mov	x1, sp			// connect(fd, &sockaddr, 16); x0 still = fd
	mov	x2, #16
	mov	x8, #203
	svc	#0
	tbnz	x0, #63, fail		// a refused/failed connect exits 1..125

	adr	x1, req			// buf = &req: the request IS the read buffer,
	mov	x2, #6			//   so x1 and the length never need reloading
	mov	x0, x19			// first write goes to the socket (dst = fd)
read_loop:				// one loop sends the request, then copies the reply
	mov	x8, #64			// write(dst, buf, len): dst=fd first, then stdout
	svc	#0
	mov	x0, x19			// read(fd, buf, len): len is the last chunk size
	mov	x8, #63
	svc	#0
	subs	x2, x0, #0		// len = n for the next write; set flags
	b.le	fail			// n<0 reset mid-reply, or n==0 EOF (neg 0 = exit 0)
	mov	x0, #1			// dst = stdout for every chunk after the request
	b	read_loop

fail:
	neg	x0, x0			// -errno -> errno, 3-argc on too few, or EOF 0 -> exit 0
	mov	x8, #93
	svc	#0

parse:					// decimal at [x19] -> w0; x19 steps past terminator
	mov	w0, #0
0:
	ldrb	w3, [x19], #1		// w3 = *x19++, post-increment
	sub	w3, w3, #'0'
	cmp	w3, #9
	b.hi	1f
	add	w0, w0, w0, lsl #2	// w0 *= 5
	add	w0, w3, w0, lsl #1	// w0 = digit + 2*w0
	b	0b
1:
	ret
	.set	filesize, . - ehdr
