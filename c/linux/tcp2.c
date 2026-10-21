/* tcp client, freestanding, unified-parse variant. */
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
__attribute__((noreturn)) static void sys_exit(long code) {
    asm volatile("syscall" : : "a"(SYS_exit), "D"(code));
    __builtin_unreachable();
}
#else
#error unsupported arch
#endif

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

__attribute__((noreturn)) void real_start(u64 *stack) {
    long argc = (long)stack[0];
    char **argv = (char **)(stack + 1);
    if (argc < 3)
        goto fail;

    /* One loop parses the port (argv[2]) then the dotted quad (argv[1]). On
     * every separator ('.' or the terminating NUL) the running number is
     * shifted into x; after both arguments x = port << 32 | a<<24|b<<16|c<<8|d.
     * Byte-swapping and or-ing 2 lays out sockaddr_in in one store:
     * family=AF_INET, sin_port (network order), sin_addr. */
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
    u64 addr[2];
    addr[0] = __builtin_bswap64(x) | 2; /* [02 00 port_hi port_lo a b c d] */

    long fd = syscall3(SYS_socket, 2 /*AF_INET*/, 1 /*SOCK_STREAM*/, 0);
    if (fd < 0)
        goto fail;
    if (syscall3(SYS_connect, fd, (long)addr, 16) < 0)
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
