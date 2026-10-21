/* tcp client, freestanding: raw syscalls, custom entry, no libc.
 * Inline asm is used only for the syscall instruction and the entry glue, as
 * SPEC.md allows. Parsing, the copy loop and the error checks are all C. */

typedef unsigned long u64;
typedef unsigned int u32;
typedef unsigned short u16;
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
#else
#error unsupported arch
#endif

__attribute__((noreturn)) static void sys_exit(long code) {
    syscall3(SYS_exit, code, 0, 0);
    __builtin_unreachable();
}

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

__attribute__((noreturn)) void real_start(u64 *stack) {
    long argc = (long)stack[0];
    char **argv = (char **)(stack + 1);
    if (argc < 3)
        sys_exit(1);

    /* sockaddr_in, built byte by byte in network order where needed. */
    u8 addr[16] = {0};
    addr[0] = 2; /* sin_family = AF_INET (little-endian u16, so byte 0 = 2) */
    u32 port = parse_uint(argv[2], 0);
    addr[2] = (u8)(port >> 8); /* sin_port, network (big-endian) order */
    addr[3] = (u8)port;

    /* dotted quad -> 4 bytes in network order (addr[4..7]) */
    const char *p = argv[1];
    for (int i = 0; i < 4; i++) {
        const char *e;
        u32 oct = parse_uint(p, &e);
        addr[4 + i] = (u8)oct;
        p = e;
        if (*p == '.')
            p++;
    }

    long fd = syscall3(SYS_socket, 2 /*AF_INET*/, 1 /*SOCK_STREAM*/, 0);
    if (fd < 0)
        sys_exit(1);
    if (syscall3(SYS_connect, fd, (long)addr, 16) < 0)
        sys_exit(1);
    if (syscall3(SYS_write, fd, (long) "hello\n", 6) != 6)
        sys_exit(1);

    char buf[2048];
    for (;;) {
        long n = syscall3(SYS_read, fd, (long)buf, sizeof buf);
        if (n < 0)
            sys_exit(1);
        if (n == 0)
            break;
        long off = 0;
        while (off < n) {
            long w = syscall3(SYS_write, 1, (long)(buf + off), n - off);
            if (w <= 0)
                sys_exit(1);
            off += w;
        }
    }
    sys_exit(0);
}
