/* tcp client, freestanding: raw syscalls, custom entry, no libc.
 * Inline asm is used only for the syscall instruction (with its operands in registers)
 * and the entry glue (which only reads the initial stack pointer), as SPEC.md allows.
 * The parse, the copy loop and the error checks are all C.
 *
 * Small pieces go in ELF header bytes the kernel never reads (holes.ld puts a section
 * .holeN at header offset N): the request at 72 (p_paddr), die() at 40 (amd64) or 4
 * (arm64, e_ident[4..15]), the arm64 entry glue at 40.
 *
 * Exit status: 0 after a clean EOF, otherwise the errno of the call that failed (1..125):
 * ECONNREFUSED 111, ECONNRESET 104 for a reset mid-reply, EBADF 9 with fewer than two
 * arguments (see the socket call). Malformed arguments are not rejected (SPEC.md leaves
 * them unspecified): the parse accepts junk and connects wherever it points. */

typedef unsigned long u64;
typedef unsigned int u32;
typedef unsigned char u8;

#if defined(__aarch64__)
#define SYS_socket 198
#define SYS_connect 203
#define SYS_read 63
#define SYS_write 64
#define SYS_exit 93
static inline long sys3(long n, long a, long b, long c) {
    register long x8 asm("x8") = n;
    register long x0 asm("x0") = a;
    register long x1 asm("x1") = b;
    register long x2 asm("x2") = c;
    asm volatile("svc #0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2) : "memory");
    return x0;
}
__attribute__((noreturn)) static inline void sys_exit(long code) {
    register long x8 asm("x8") = SYS_exit;
    register long x0 asm("x0") = code;
    asm volatile("svc #0" : : "r"(x8), "r"(x0));
    __builtin_unreachable();
}
#define sys3l sys3
typedef long word;
#elif defined(__x86_64__)
#define SYS_socket 41
#define SYS_connect 42
#define SYS_read 0
#define SYS_write 1
#define SYS_exit 60
/* fds, numbers and results are 32-bit: no REX.W prefixes (the kernel truncates int
 * arguments, and every result here fits). The kernel clobbers only rcx and r11. The
 * extra clobbers only tell the compiler less: r10 keeps the socket fd out of a register
 * that needs a REX prefix, and in the copy loop (sys3l) r9 and r12..r15 do the same for
 * the constant 1 (stdout, and the write syscall number). */
static inline int sys3(int n, int a, long b, long c) {
    asm volatile("syscall" : "+a"(n) : "D"(a), "S"(b), "d"(c) : "rcx", "r10", "r11", "memory");
    return n;
}
static inline int sys3l(int n, int a, long b, long c) {
    asm volatile("syscall" : "+a"(n) : "D"(a), "S"(b), "d"(c)
                 : "rcx", "r9", "r10", "r11", "r12", "r13", "r14", "r15", "memory");
    return n;
}
__attribute__((noreturn)) static inline void sys_exit(int code) {
    asm volatile("syscall" : : "a"(SYS_exit), "D"(code));
    __builtin_unreachable();
}
typedef int word;
#else
#error unsupported arch
#endif

#if defined(__aarch64__)
/* The request is also the read buffer (reads ask for at most 6 bytes, see the loop), so
 * the buffer address never changes. Writable, so the segment is R+W+X. */
__attribute__((section(".hole72"))) static char req[6] = "hello\n";
#define RBUF req
/* exit(-r): neg, mov, svc, exactly the 12 bytes of e_ident[4..15]. */
__attribute__((noinline, noreturn, section(".hole4"))) void die(word r) {
    sys_exit(-r);
}
/* Entry glue in the e_shoff hole: x3 = &argv[0] (tmain's 4th argument), argc at x3 - 8. */
asm(".section .hole40,\"ax\",@progbits\n"
    ".globl _start\n"
    "_start:\n"
    "  add x3, sp, #8\n"
    "  b tmain\n");
__attribute__((noreturn)) void tmain(long a0, long a1, long a2, u64 *argv) {
    (void)a0, (void)a1;
    u64 argc = argv[-1];
    /* The argument check is the socket type, argc - 2: 1 (SOCK_STREAM) with two
     * arguments, 0 or negative with fewer, both of which socket() rejects without
     * creating anything; connect() on the error "fd" then fails with EBADF (exit 9).
     * The protocol is a2, which is x2: the kernel zeroes x0..x30 at entry (ELF_PLAT_INIT)
     * and the glue does not touch x2, so it is a deterministic 0 (the TCP default) and
     * costs no instruction. Idea from the V slice (which used argc - 3 as the protocol). */
    word fd = sys3(SYS_socket, 2 /*AF_INET*/, argc - 2, a2);
#else
/* Rosetta write-protects the page that holds translated code, so a read into the header
 * fails there with EFAULT: the read buffer is the stack at argv. */
__attribute__((section(".hole72"))) static const char req[6] = "hello\n";
#define RBUF argv
/* exit(-r): neg edi; push 60; pop rax; syscall, 7 bytes in the e_shoff hole. */
__attribute__((noinline, noreturn, section(".hole40"))) void die(word r) {
    sys_exit(-r);
}
/* Entry glue: argc in r9, &argv[0] in r8, tmain's 10th and 9th arguments under
 * preserve_none. It sits in tmain's own section, which module asm precedes, and falls
 * through into tmain (x86 code at -Oz is not aligned; the build checks the addresses). */
asm(".section .text.start,\"ax\",@progbits\n"
    ".globl _start\n"
    "_start:\n"
    "  pop %r9\n"
    "  mov %rsp, %r8\n");
/* preserve_none: no callee-saved registers but rbp, so no pushes for ebx. */
__attribute__((noreturn, preserve_none, section(".text.start"))) void tmain(
    long a0, long a1, long a2, long a3, long a4, long a5, long a6, long a7, u64 *argv,
    u64 argc) {
    (void)a0, (void)a1, (void)a2, (void)a3, (void)a4, (void)a5, (void)a6, (void)a7;
    /* The argument check is the socket protocol, argc - 3: 0 (TCP) with two arguments,
     * negative with fewer, which socket() rejects (EINVAL) without creating anything;
     * connect() on that "fd" then fails with EBADF. Idea from the V slice. */
    word fd = sys3(SYS_socket, 2 /*AF_INET*/, 1 /*SOCK_STREAM*/, argc - 3);
#endif
    /* One loop parses argv[2] (the port) then argv[1] (a.b.c.d). On every separator
     * (any byte with bit 4 clear: '.' and NUL; the digits have it set) x = x << 8 |
     * number. Five numbers shift the start value's 0x02 from bits 16..23 to 56..63, so
     * after the byte swap x is sin_family = AF_INET, the port and the address in network
     * order, and goes over argv[0], dead by now. sin_zero (the next 8 bytes, argv[1]) is
     * not checked by Linux. */
    u64 x = 0x20000;
    for (u64 k = argc; --k;) {
        const u8 *p = (const u8 *)argv[k];
        u32 c;
        do {
            u64 cur = 0;
            while ((c = *p++) & 16)
                cur = (u32)cur * 10 + c - '0';
            x = x << 8 | cur;
        } while (c);
    }
    *argv = __builtin_bswap64(x);
    word r = sys3(SYS_connect, fd, (long)argv, 16);
    if (r)
        die(r);
    /* The first write sends the request, the next ones copy the reply to stdout. The
     * read count is the previous length: 6, then the last read's result, so a read asks
     * for at most 6 bytes (down to 1 if the server ever sends 1 byte): still correct, and
     * it saves a constant. The last read returns 0 at the end of the stream (exit 0) or
     * -errno (a reset mid-reply gives ECONNRESET, exit 104). */
    word dst = fd;
    const void *buf = req;
    word n = 6;
    for (;;) {
        sys3l(SYS_write, dst, (long)buf, n);
        n = sys3l(SYS_read, fd, (long)RBUF, n);
        if (n <= 0)
            die(n);
        dst = 1;
        buf = RBUF;
    }
}
