/* Minimal raw-syscall glue for arm64 macOS. The inline asm is the `svc`
 * instruction alone; all program logic lives in C. */
#ifndef MINI_SYSCALL_H
#define MINI_SYSCALL_H

/* XNU arm64 BSD syscall ABI: number in x16, args in x0..x5, `svc #0x80`.
 * On return the kernel writes x0 (rval[0]) and x1 (rval[1], 0 for most calls)
 * and sets the carry flag on error, with errno in x0. So x0 and x1 are both
 * in/out operands. The carry is read with the AArch64 flag-output constraint
 * "=@cccs", so the asm body needs no extra instruction. */
#define SYS_exit       1
#define SYS_read       3
#define SYS_write      4
#define SYS_close      6
#define SYS_socket     97
#define SYS_connect    98
#define SYS_setsockopt 105

__attribute__((always_inline))
static inline long sys5(long n, long a0, long a1, long a2, long a3, long a4) {
    register long x16 __asm__("x16") = n;
    register long x0 __asm__("x0") = a0;
    register long x1 __asm__("x1") = a1;
    register long x2 __asm__("x2") = a2;
    register long x3 __asm__("x3") = a3;
    register long x4 __asm__("x4") = a4;
    int carry;
    __asm__ volatile("svc #0x80"
                     : "+r"(x0), "+r"(x1), "=@cccs"(carry)
                     : "r"(x2), "r"(x3), "r"(x4), "r"(x16)
                     : "memory");
    return carry ? -x0 : x0;
}

__attribute__((always_inline))
static inline long sys(long n, long a0, long a1, long a2) {
    register long x16 __asm__("x16") = n;
    register long x0 __asm__("x0") = a0;
    register long x1 __asm__("x1") = a1;
    register long x2 __asm__("x2") = a2;
    int carry;
    __asm__ volatile("svc #0x80"
                     : "+r"(x0), "+r"(x1), "=@cccs"(carry)
                     : "r"(x2), "r"(x16)
                     : "memory");
    return carry ? -x0 : x0;
}

#endif
