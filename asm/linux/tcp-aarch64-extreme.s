// tcp client, aarch64 Linux, extreme: a hand-written flat ELF.
// Assembled with GNU as, linked with ld, then objcopy -O binary strips the ELF
// container to the raw image we laid out.
//
// One PT_LOAD maps the whole file. The 56-byte program header overlaps the ELF
// header from offset 48 (e_phoff = 48): the kernel reads p_type out of e_flags,
// e_phentsize (56) and e_phnum (1) out of p_flags and p_offset, and p_offset = 1
// so the segment maps from file offset 0 at vaddr 0x10000 (p_vaddr = 0x10001).
// Code starts at offset 48 + 48 = 96, over the phdr's ignored p_align field; 96
// is 4-aligned. The 6-byte request lives in the e_shoff hole (offset 40), and the
// first two instructions sit in the p_paddr hole (offsets 72..79, ignored for
// ET_EXEC). p_offset 1 == p_vaddr mod page for 4/16/64 KB pages, so the layout is
// page-size independent.
//
// tcp <ipv4> <port>: connect, send "hello\n", copy the reply to stdout until EOF.
// Every failure (bad argc, connect error, reset mid-reply) ends in a 1..125 exit:
// a negative syscall return is negated into its errno; too few args exits 2. svc
// preserves every register except x0, so the fd lives in x19 across connect,
// write and read. x19 is also the parse pointer, but all parsing finishes before
// the socket call that produces the fd, so the two uses never overlap. At entry
// Linux zeroes x0..x30.
//
// Two deterministic-layout tricks, both stated because they are not in any ABI
// document:
//   - The port pointer is never loaded separately. After the 4-octet parse, x19
//     has advanced one byte past argv[1]'s NUL. Linux lays the argv strings out
//     contiguously, so x19 already points at argv[2]. Fixed kernel ABI layout,
//     not luck (independent of ASLR, environment size, timing).
//   - The sockaddr and the 128-byte read buffer sit at sp (no "sub sp"), over the
//     dead argc/argv/envp/auxv slots, which are never read again after parsing.
	.text
	.global _start
ehdr:
	.byte	0x7f, 'E', 'L', 'F', 2, 1, 1, 0	// e_ident[0..7]
	.quad	0			// e_ident[8..15]
	.short	2			// e_type = ET_EXEC
	.short	0xB7			// e_machine = EM_AARCH64
	.long	1			// e_version (20..23, ignored)
	.quad	_start			// e_entry
	.quad	phdr - ehdr		// e_phoff = 48
req:
	.ascii	"hello\n"		// 6-byte request in the e_shoff hole (40..45)
	.short	0			// 46..47
phdr:
	.long	1			// p_type = PT_LOAD   (over e_flags, ignored)
	.long	0x00380005		// p_flags = R+X; e_phentsize = 56 at 54..55
	.quad	1			// p_offset = 1; e_phnum = 1 at 56..57
	.quad	0x10001			// p_vaddr
_start:					// p_paddr (72..79, ignored): entry glue
	ldr	x0, [sp]		// argc
	b	p2
	.quad	filesize - 1		// p_filesz
	.quad	filesize - 1		// p_memsz
p2:					// offset 96 (the p_align field)
	cmp	x0, #3
	b.lo	usage
	ldr	x19, [sp, #16]		// argv[1] (parse ptr); argv[2] follows contiguously
	add	x7, sp, #4		// store the 4 address octets at sp+4..7
	mov	w5, #4
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

	mov	x0, x19			// write(fd, "hello\n", 6)
	adr	x1, req
	mov	x2, #6
	mov	x8, #64
	svc	#0

	mov	x1, sp			// buf = sp (read and write both keep x1)
read_loop:
	mov	x0, x19			// read(fd, buf, 128)
	mov	x2, #128
	mov	x8, #63
	svc	#0
	subs	x2, x0, #0		// n -> x2 for the write; set flags
	b.le	fail			// n<0 reset mid-reply, or n==0 EOF (neg 0 = exit 0)
	mov	x0, #1			// write(1, buf, n): n < PIPE_BUF so one write
	mov	x8, #64
	svc	#0
	b	read_loop

usage:
	mov	x0, #-2			// too few args: -2 -> neg -> exit 2
fail:
	neg	x0, x0			// -errno -> errno, or EOF 0 -> exit 0
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
