/* hello, freestanding: raw write + exit syscalls, custom entry, no libc.
 * Inline asm is used only for the syscall instruction, as SPEC.md allows. All logic is C.
 * There is no entry glue: hello needs no argc/argv, so _start is plain C.
 *
 * The program is split into small functions that tail-call each other, so the linker
 * script (holes.ld) can drop the first ones into ELF header bytes the kernel never reads:
 * a function in section .holeN goes at header offset N. Each function passes the
 * registers the next one needs as plain arguments, so a tail call is a lone branch and
 * passing a value along costs nothing. They are global (not static) so the compiler
 * cannot fold the constants into the last one, and noinline so it keeps them apart.
 * The 14-byte message (no NUL) fills the 14-byte hole at offset 40. */

#if defined(__aarch64__)
#define NR_write 64
#define NR_exit 93
static inline void sys3v(long n, long a, long b, long c) {
    register long x8 asm("x8") = n;
    register long x0 asm("x0") = a;
    register long x1 asm("x1") = b;
    register long x2 asm("x2") = c;
    asm volatile("svc #0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2) : "memory");
}
__attribute__((noreturn)) static inline void sys_exit(long a) {
    register long x8 asm("x8") = NR_exit;
    register long x0 asm("x0") = a;
    asm volatile("svc #0" : : "r"(x8), "r"(x0));
    __builtin_unreachable();
}
#elif defined(__x86_64__)
#define NR_write 1
#define NR_exit 60
static inline void sys3v(int n, int a, long b, long c) {
    asm volatile("syscall" : "+a"(n) : "D"(a), "S"(b), "d"(c) : "rcx", "r11", "memory");
}
__attribute__((noreturn)) static inline void sys_exit(int a) {
    asm volatile("syscall" : : "a"(NR_exit), "D"(a));
    __builtin_unreachable();
}
#else
#error unsupported arch
#endif

__attribute__((section(".hole40"))) static const char msg[14] = "Hello, World!\n";

#if defined(__aarch64__)
/* _start (e_ident[4..15], 12 bytes): adr x1, msg; mov w2, #14; b h2
 * h2 (p_paddr, 8 bytes): mov w0, #1; b h3
 * h3 (the code): the two syscalls, 5 instructions */
__attribute__((noinline)) void h3(long fd, const char *buf, long len) {
    sys3v(NR_write, fd, (long)buf, len);
    sys_exit(0);
}
__attribute__((noinline, section(".hole80"))) void h2(long fd, const char *buf, long len) {
    (void)fd;
    h3(1, buf, len);
}
__attribute__((section(".hole4"))) void _start(long fd, const char *buf, long len) {
    (void)buf, (void)len;
    h2(fd, msg, sizeof msg);
}
#else
/* _start (p_paddr, 8 bytes): push 14; pop rdx; jmp h2 (a rel32 jmp is 5 bytes, so the
 * hole holds one 3-byte constant load); h2 (the code) loads the rest and does the syscalls. */
__attribute__((noinline)) void h2(long fd, const char *buf, long len) {
    (void)fd, (void)buf;
    sys3v(NR_write, 1, (long)msg, len);
    sys_exit(0);
}
__attribute__((section(".hole80"))) void _start(long fd, const char *buf, long len) {
    (void)len;
    h2(fd, buf, sizeof msg);
}
#endif
