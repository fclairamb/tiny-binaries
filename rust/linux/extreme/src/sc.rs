// Shared no_std glue for the extreme Rust variant on Linux: raw syscalls and a panic
// handler. The only assembly is the syscall instruction with its operands in registers.
//
// Syscall numbers: x86_64 read 0 write 1 socket 41 connect 42 exit 60;
// aarch64 read 63 write 64 socket 198 connect 203 exit 93.
#![allow(dead_code)]
use core::arch::asm;

#[cfg(target_arch = "x86_64")]
pub mod nr {
    pub const READ: usize = 0;
    pub const WRITE: usize = 1;
    pub const SOCKET: usize = 41;
    pub const CONNECT: usize = 42;
    pub const EXIT: usize = 60;
}
#[cfg(target_arch = "aarch64")]
pub mod nr {
    pub const READ: usize = 63;
    pub const WRITE: usize = 64;
    pub const SOCKET: usize = 198;
    pub const CONNECT: usize = 203;
    pub const EXIT: usize = 93;
}

// x86_64: the number and the first argument (always an fd here) go in as 32-bit values,
// so the compiler can use `mov edi, eax` instead of `mov rdi, rax` (no REX.W). The kernel
// reads the number as an int and truncates int arguments, and a 32-bit write zeroes the
// upper half anyway. The result is the 32-bit eax: fds, byte counts and -errno all fit.
// The kernel clobbers only rcx and r11; r9 and r10 are declared clobbered too, which is
// safe (it only tells the compiler less) and steers values that live across syscalls (the
// socket fd, the constant 1) into ebx and ebp, whose moves need no REX prefix.
#[cfg(target_arch = "x86_64")]
#[inline(always)]
pub unsafe fn sys3(n: usize, a: usize, b: usize, c: usize) -> isize {
    let r: i32;
    unsafe {
        asm!("syscall", inlateout("eax") n as u32 => r, in("edi") a as u32, in("rsi") b,
             in("rdx") c, lateout("rcx") _, lateout("r11") _, lateout("r9") _,
             lateout("r10") _, options(nostack));
    }
    r as isize
}
#[cfg(target_arch = "aarch64")]
#[inline(always)]
pub unsafe fn sys3(n: usize, a: usize, b: usize, c: usize) -> isize {
    let r;
    unsafe {
        asm!("svc #0", in("x8") n, inlateout("x0") a => r, in("x1") b, in("x2") c,
             options(nostack));
    }
    r
}

// exit never returns: options(noreturn) plus -Ztrap-unreachable=no means nothing at all is
// emitted after the syscall instruction.
#[cfg(target_arch = "x86_64")]
#[inline(always)]
pub fn exit(code: usize) -> ! {
    unsafe {
        asm!("syscall", in("eax") nr::EXIT as u32, in("edi") code as u32,
             options(noreturn, nostack));
    }
}
#[cfg(target_arch = "aarch64")]
#[inline(always)]
pub fn exit(code: usize) -> ! {
    unsafe {
        asm!("svc #0", in("x8") nr::EXIT, in("x0") code, options(noreturn, nostack));
    }
}

#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! {
    exit(101)
}
