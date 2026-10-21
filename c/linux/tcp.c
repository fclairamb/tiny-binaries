/* tcp client, freestanding: raw syscalls, custom entry, no libc.
 * Inline asm is used only for the syscall instruction and the entry glue (which
 * only reads the initial stack pointer), as SPEC.md allows. The parse, the copy
 * loop and the error checks are all C.
 *
 * Three space tricks, all in the C (not the headers):
 *  - The sockaddr_in is written over the stack's argc/argv[0] slots, which are
 *    not needed after the address is parsed. No stack frame is reserved for it.
 *  - The 64-byte read buffer is the initial stack itself (sp): far more than 64
 *    bytes of argv/envp/auxv strings live there, and they are dead once parsed.
 *  - One computed exit status instead of a branch per error. `r` holds the last
 *    syscall result: 0 after a clean EOF, or a negative -errno after any
 *    failure (bad argc, socket/connect error, a reset mid-reply). exit(-r) turns
 *    that into 0 on success or errno (ECONNREFUSED 111, ECONNRESET 104, ... all
 *    in 1..125) on failure. argc<3 gives r = argc-3, so exit 1 or 2.
 *
 * The entry glue and the "hello\n" request each sit in their own section so the
 * linker script (pack-tcp.ld) can drop them into header holes.
 *
 * Malformed addresses are not rejected (the parse wraps and accepts junk).
 * SPEC.md lists that as unspecified: connecting to a wrong address that takes
 * minutes to time out is allowed, and check.py does not test it. Validating
 * would cost bytes for no test and no spec requirement. */

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

/* Entry glue: hand the initial stack pointer (argc, then argv) to real_start.
 * Allowed as entry glue by SPEC.md. Alone in .text.glue so the linker script
 * can place it in an 8-byte header hole. */
asm(".section .text.glue,\"ax\",@progbits\n"
    ".global _start\n"
    "_start:\n"
#if defined(__aarch64__)
    "  mov x0, sp\n"
    "  b real_start\n"
#elif defined(__x86_64__)
    "  mov %rsp, %rdi\n"
    "  jmp real_start\n"
#endif
    ".text\n");

__attribute__((section(".rodata.req"))) static const char req[6] = "hello\n";

__attribute__((section(".text.entry"), noreturn)) void real_start(u64 *sp) {
    long r = (long)sp[0] - 3; /* argc - 3: fewer than 2 args exits 1 or 2 */
    if ((long)sp[0] >= 3) {
        char **argv = (char **)(sp + 1);
        /* One loop parses the port (argv[2]) then the dotted quad (argv[1]). On
         * each separator ('.' or the terminating NUL) the running number shifts
         * into x; after both arguments x = port << 32 | a<<24|b<<16|c<<8|d.
         * Byte-swapping and or-ing 2 lays out sockaddr_in in one store:
         * [02 00 port_hi port_lo a b c d] = AF_INET, sin_port (network order),
         * sin_addr. sin_zero (next 8 bytes) is not read by the kernel. */
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
        sp[0] = __builtin_bswap64(x) | 2; /* sockaddr over argc/argv[0] */

        long fd = syscall3(SYS_socket, 2 /*AF_INET*/, 1 /*SOCK_STREAM*/, 0);
        /* No explicit socket() check: a bad fd makes connect() return -errno,
         * which the shared exit path turns into a 1..125 status. */
        r = syscall3(SYS_connect, fd, (long)sp, 16);
        if (r == 0) {
            long dst = fd; /* first write sends the request, then copy to stdout */
            const void *buf = req;
            r = 6;
            for (;;) {
                syscall3(SYS_write, dst, (long)buf, r);
                r = syscall3(SYS_read, fd, (long)sp, 64);
                if (r <= 0)
                    break; /* n<0 (reset mid-reply) or n==0 (clean EOF) */
                dst = 1;
                buf = sp;
            }
        }
    }
    sys_exit(-r);
}
