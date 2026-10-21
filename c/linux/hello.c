/* hello, freestanding: raw write + exit syscalls, custom entry, no libc.
 * Inline asm is used only for the syscall instruction and the entry glue, as
 * SPEC.md allows. All logic is C. */

#if defined(__aarch64__)
static long sys_write(long fd, const void *buf, long n) {
    register long x8 asm("x8") = 64; /* __NR_write */
    register long x0 asm("x0") = fd;
    register long x1 asm("x1") = (long)buf;
    register long x2 asm("x2") = n;
    asm volatile("svc #0" : "+r"(x0) : "r"(x8), "r"(x1), "r"(x2) : "memory");
    return x0;
}
__attribute__((noreturn)) static void sys_exit(long code) {
    register long x8 asm("x8") = 93; /* __NR_exit */
    register long x0 asm("x0") = code;
    asm volatile("svc #0" : : "r"(x8), "r"(x0));
    __builtin_unreachable();
}
#elif defined(__x86_64__)
static long sys_write(long fd, const void *buf, long n) {
    long r;
    asm volatile("syscall" : "=a"(r) : "a"(1), "D"(fd), "S"(buf), "d"(n) : "rcx", "r11", "memory");
    return r;
}
__attribute__((noreturn)) static void sys_exit(long code) {
    asm volatile("syscall" : : "a"(60), "D"(code));
    __builtin_unreachable();
}
#else
#error unsupported arch
#endif

static const char msg[] = "Hello, World!\n";

__attribute__((noreturn)) void real_start(void) {
    sys_write(1, msg, sizeof msg - 1);
    sys_exit(0);
}
