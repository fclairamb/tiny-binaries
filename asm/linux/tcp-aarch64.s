// tcp client, aarch64 Linux: raw syscalls, custom entry, no libc.
// Source for the `default` and `optimized` variants (only flags differ).
//
// tcp <ipv4> <port>: connect, send "hello\n", copy the reply to stdout until
// EOF. Every failure (bad argc, socket/connect/read error, reset mid-reply)
// funnels through one exit tail. A negative syscall return is negated into the
// errno it carries (ECONNREFUSED 111, ECONNRESET 104), all inside 1..125.
//
// svc #0 returns in x0 and preserves every other register, so values live in
// registers across syscalls: x19 = argv, x20 = fd, x21 = n, x22 = offset.
	.text
	.global _start
_start:
	ldr	x0, [sp]		// argc
	cmp	x0, #3
	b.lt	usage
	add	x19, sp, #8		// argv
	sub	sp, sp, #4096		// read buffer (4096)
	sub	sp, sp, #16		// + sockaddr_in (16); #4112 is not a valid imm
	stp	xzr, xzr, [sp]
	mov	w0, #2
	strh	w0, [sp]		// sin_family = AF_INET

	ldr	x0, [x19, #16]		// argv[2] = port
	bl	parse_uint
	rev16	w1, w1			// -> network (big-endian) order
	strh	w1, [sp, #2]		// sin_port

	ldr	x0, [x19, #8]		// argv[1] = dotted quad
	add	x5, sp, #4		// -> sin_addr
	mov	w6, #4
.Loctet:
	bl	parse_uint
	strb	w1, [x5], #1
	ldrb	w7, [x0]
	cmp	w7, #'.'
	b.ne	1f
	add	x0, x0, #1
1:	subs	w6, w6, #1
	b.ne	.Loctet

	mov	w0, #2			// socket(AF_INET, SOCK_STREAM, 0)
	mov	w1, #1
	mov	w2, #0
	mov	x8, #198
	svc	#0
	tbnz	x0, #63, fail
	mov	x20, x0			// fd

	mov	x0, x20			// connect(fd, &sockaddr, 16)
	mov	x1, sp
	mov	x2, #16
	mov	x8, #203
	svc	#0
	tbnz	x0, #63, fail

	mov	x0, x20			// write(fd, "hello\n", 6)
	adr	x1, req
	mov	x2, #6
	mov	x8, #64
	svc	#0
	cmp	x0, #6
	b.ne	fail

read_loop:
	mov	x0, x20			// read(fd, buf, 4096)
	add	x1, sp, #16
	mov	x2, #4096
	mov	x8, #63
	svc	#0
	tbnz	x0, #63, fail		// n<0: reset mid-reply reaches here
	cbz	x0, done		// n==0: clean EOF
	mov	x21, x0			// total bytes read
	mov	x22, #0			// write offset
wloop:
	add	x1, sp, #16
	add	x1, x1, x22
	mov	x0, #1			// write(1, buf+off, n-off)
	sub	x2, x21, x22
	mov	x8, #64
	svc	#0
	cmp	x0, #1
	b.lt	fail
	add	x22, x22, x0
	cmp	x22, x21
	b.lt	wloop
	b	read_loop

done:
	mov	x0, #0
	b	do_exit
usage:
	mov	x0, #2
	b	do_exit
fail:
	neg	x0, x0			// -errno -> errno (1..125)
do_exit:
	mov	x8, #93			// __NR_exit
	svc	#0

// parse_uint: read a decimal number at [x0], stop at the first non-digit.
// Returns the value in x1 and leaves x0 on the stopping character.
parse_uint:
	mov	w1, #0
	mov	w4, #10
.Lpu:
	ldrb	w3, [x0]
	sub	w3, w3, #'0'
	cmp	w3, #9
	b.hi	.Lpu_done
	madd	w1, w1, w4, w3
	add	x0, x0, #1
	b	.Lpu
.Lpu_done:
	ret

req:
	.ascii	"hello\n"
