// Shared no_std glue for the extreme Rust variant on Linux: raw syscalls, an entry
// macro that reads argc/argv off the initial stack, and a panic handler that exits.
//
// Syscall numbers (Linux): x86_64 read 0 write 1 socket 41 connect 42 exit 60;
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

#[cfg(target_arch = "x86_64")]
#[inline(always)]
pub unsafe fn sys3(n: usize, a: usize, b: usize, c: usize) -> usize {
    let r;
    unsafe {
        asm!("syscall", inlateout("rax") n => r, in("rdi") a, in("rsi") b, in("rdx") c,
             lateout("rcx") _, lateout("r11") _, options(nostack));
    }
    r
}
#[cfg(target_arch = "aarch64")]
#[inline(always)]
pub unsafe fn sys3(n: usize, a: usize, b: usize, c: usize) -> usize {
    let r;
    unsafe {
        asm!("svc #0", in("x8") n, inlateout("x0") a => r, in("x1") b, in("x2") c,
             options(nostack));
    }
    r
}

// A dedicated exit: the syscall never returns, so options(noreturn) lets the
// compiler emit nothing after it (no trap, no self-branch loop).
#[cfg(target_arch = "x86_64")]
#[inline(always)]
pub fn exit(code: usize) -> ! {
    unsafe {
        asm!("syscall", in("rax") nr::EXIT, in("rdi") code, options(noreturn, nostack));
    }
}
#[cfg(target_arch = "aarch64")]
#[inline(always)]
pub fn exit(code: usize) -> ! {
    unsafe {
        asm!("svc #0", in("x8") nr::EXIT, in("x0") code, options(noreturn, nostack));
    }
}

#[inline(always)]
pub unsafe fn write(fd: usize, buf: *const u8, len: usize) -> usize {
    unsafe { sys3(nr::WRITE, fd, buf as usize, len) }
}
#[inline(always)]
pub unsafe fn read(fd: usize, buf: *mut u8, len: usize) -> usize {
    unsafe { sys3(nr::READ, fd, buf as usize, len) }
}

// A syscall that fails returns -errno as an unsigned word; errno is < 4096.
#[inline(always)]
pub fn is_err(r: usize) -> bool {
    (r as isize) < 0 && (r as isize) > -4096
}

#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! {
    exit(101)
}

// Entry glue. The kernel starts us with the stack pointing at argc, then the argv
// pointers, a NULL, then envp. We hand that pointer to the per-binary `rust_main`,
// which never returns. Only stack reading and the jump are in assembly; all logic is
// in Rust.
#[macro_export]
macro_rules! entry {
    ($main:ident) => {
        #[cfg(target_arch = "x86_64")]
        core::arch::global_asm!(
            ".global _start", "_start:", "mov rdi, rsp", "and rsp, -16", "call {m}",
            m = sym $main,
        );
        #[cfg(target_arch = "aarch64")]
        core::arch::global_asm!(
            ".global _start", "_start:", "mov x0, sp", "b {m}",
            m = sym $main,
        );
    };
}
