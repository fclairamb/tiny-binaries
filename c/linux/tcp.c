/* tcp client, freestanding: raw syscalls, custom entry, no libc.
 * Inline asm is used only for the syscall instruction and the entry glue, as
 * SPEC.md allows. Parsing, the copy loop and the error checks are all C.
 *
 * Every error funnels through one `fail` label (exit 1) so there is a single
 * exit epilogue instead of one inlined copy per check (that alone saves about
 * 70 bytes on amd64, where clang had inlined the exit at each of seven sites).
 *
 * The address parse is written two ways because the two compilers favour
 * different shapes: clang (amd64) is smaller with a straight byte-by-byte
 * parse, gcc (arm64) is smaller with one loop that folds the port and the four
 * octets into a 64-bit value. Both are plain C. */

typedef unsigned long u64;
typedef unsigned int u32;
typedef unsigned char u8;

#if defined(__aarch64__)
#define SYS_socket 198
#define SYS_connect 203
#define SYS_read 63
#define SYS_write 64
#define SYS_exit 93
static long syscall3(long n, long a, long b, long c) {
    register long x8 asm("x8") = n;
    register long x0 asm("x0") = a;
    register long x1 asm("x1") = b;
    register long x2 asm("x2") = c;
    asm volatile("svc #0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2) : "memory");
    return x0;
}
/* Dedicated one-argument exit: only x8 and x0 are set, so arm64 does not spend
 * two instructions zeroing x1 and x2 the way syscall3(SYS_exit, c, 0, 0) would. */
__attribute__((noreturn)) static void sys_exit(long code) {
    register long x8 asm("x8") = SYS_exit;
    register long x0 asm("x0") = code;
    asm volatile("svc #0" : : "r"(x8), "r"(x0));
    __builtin_unreachable();
}
#elif defined(__x86_64__)
#define SYS_socket 41
#define SYS_connect 42
#define SYS_read 0
#define SYS_write 1
#define SYS_exit 60
static long syscall3(long n, long a, long b, long c) {
    long r;
    asm volatile("syscall" : "=a"(r) : "a"(n), "D"(a), "S"(b), "d"(c) : "rcx", "r11", "memory");
    return r;
}
/* Dedicated one-argument exit: only rax and rdi are set, so each call site is a
 * few bytes shorter than syscall3(SYS_exit, c, 0, 0) (no xor esi / xor edx). */
__attribute__((noreturn)) static void sys_exit(long code) {
    asm volatile("syscall" : : "a"(SYS_exit), "D"(code));
    __builtin_unreachable();
}
#else
#error unsupported arch
#endif

/* Entry glue: hand the initial stack pointer (argc, then argv) to real_start.
 * Allowed as entry glue by SPEC.md. */
asm(".global _start\n"
    "_start:\n"
#if defined(__aarch64__)
    "  mov x0, sp\n"
    "  b real_start\n"
#elif defined(__x86_64__)
    "  mov %rsp, %rdi\n"
    "  call real_start\n"
#endif
);

#if defined(__x86_64__)
/* Parse a decimal string, stop at the first non-digit. */
static u32 parse_uint(const char *s, const char **end) {
    u32 v = 0;
    while (*s >= '0' && *s <= '9') {
        v = v * 10 + (u32)(*s - '0');
        s++;
    }
    if (end)
        *end = s;
    return v;
}
#endif

__attribute__((noreturn)) void real_start(u64 *stack) {
    long argc = (long)stack[0];
    char **argv = (char **)(stack + 1);
    if (argc < 3)
        goto fail;

    /* sockaddr_in. Only the first 8 bytes matter: sin_family, sin_port,
     * sin_addr. sin_zero (bytes 8..15) is not interpreted by the kernel for
     * AF_INET, so it is left uninitialized. */
    union {
        u64 q[2];
        u8 b[16];
    } addr;

#if defined(__aarch64__)
    /* One loop parses the port (argv[2]) then the dotted quad (argv[1]). On
     * each separator ('.' or the terminating NUL) the running number shifts
     * into x; after both arguments x = port << 32 | a<<24|b<<16|c<<8|d.
     * Byte-swapping and or-ing 2 lays out the whole sockaddr in one store:
     * [02 00 port_hi port_lo a b c d] = family AF_INET, sin_port (network
     * order), sin_addr. */
    u64 x = 0;
    for (int k = 2; k >= 1; k--) {
        const char *p = argv[k];
        u32 cur = 0;
        for (;;) {
            u8 c = (u8)*p++;
            if (c < '0') {
                x = (x << 8) | cur;
                cur = 0;
                if (!c)
                    break;
            } else {
                cur = cur * 10 + (c - '0');
            }
        }
    }
    addr.q[0] = __builtin_bswap64(x) | 2;
#else
    addr.b[0] = 2; /* sin_family = AF_INET (little-endian u16, low byte) */
    addr.b[1] = 0; /* sin_family high byte */
    u32 port = parse_uint(argv[2], 0);
    addr.b[2] = (u8)(port >> 8); /* sin_port, network (big-endian) order */
    addr.b[3] = (u8)port;
    const char *p = argv[1];
    for (int i = 0; i < 4; i++) {
        const char *e;
        u32 oct = parse_uint(p, &e);
        addr.b[4 + i] = (u8)oct;
        p = e;
        if (*p == '.')
            p++;
    }
#endif

    long fd = syscall3(SYS_socket, 2 /*AF_INET*/, 1 /*SOCK_STREAM*/, 0);
    if (fd < 0)
        goto fail;
    if (syscall3(SYS_connect, fd, (long)&addr, 16) < 0)
        goto fail;
    if (syscall3(SYS_write, fd, (long) "hello\n", 6) != 6)
        goto fail;

    char buf[64];
    for (;;) {
        long n = syscall3(SYS_read, fd, (long)buf, sizeof buf);
        if (n < 0)
            goto fail; /* a reset mid-reply reaches here: read returns -ECONNRESET */
        if (n == 0)
            break;
        long off = 0;
        while (off < n) {
            long w = syscall3(SYS_write, 1, (long)(buf + off), n - off);
            if (w <= 0)
                goto fail;
            off += w;
        }
    }
    sys_exit(0);
fail:
    sys_exit(1);
}
