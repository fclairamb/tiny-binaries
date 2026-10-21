/* hello, freestanding: raw write + exit syscalls, custom entry, no libc.
 * Inline asm is used only for the syscall instruction, as SPEC.md allows. All
 * logic is C. There is no entry glue: the kernel enters real_start directly
 * (hello needs no argc/argv), so real_start is the ELF entry point.
 *
 * The 14-byte message sits in its own section (.rodata.msg) and the code in
 * .text.entry so the linker script (pack-hello.ld) can drop the message into a
 * header hole and start the code right after the headers. */

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
static inline void sys1v(long n, long a) {
    register long x8 asm("x8") = n;
    register long x0 asm("x0") = a;
    asm volatile("svc #0" : "+r"(x0) : "r"(x8) : "memory");
}
#elif defined(__x86_64__)
#define NR_write 1
#define NR_exit 60
static inline void sys3v(int n, int a, long b, long c) {
    asm volatile("syscall" : "+a"(n) : "D"(a), "S"(b), "d"(c) : "rcx", "r11", "memory");
}
static inline void sys1v(int n, int a) {
    asm volatile("syscall" : "+a"(n) : "D"(a) : "rcx", "r11", "memory");
}
#else
#error unsupported arch
#endif

/* 14 bytes, no NUL: the write length is sizeof msg, and the string fits exactly
 * the 14-byte header hole of the o56a layout. */
__attribute__((section(".rodata.msg"))) static const char msg[14] = "Hello, World!\n";

__attribute__((section(".text.entry"), noreturn)) void real_start(void) {
    sys3v(NR_write, 1, (long)msg, sizeof msg);
    sys1v(NR_exit, 0);
    __builtin_unreachable();
}
