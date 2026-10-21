// Raw XNU system calls for macOS arm64, shared by hello.rs and tcp.rs.
//
// ABI (xnu osfmk/arm64 + bsd/dev/arm64/systemcalls.c): the BSD syscall number
// goes in x16, arguments in x0..x5, then `svc #0x80`. On return the kernel sets
// the carry flag on error with the errno in x0, clears it on success with the
// result in x0, and writes x1 in both cases (0 on error, the second result
// word on success). So x1 is an output, not just an input: declaring it
// `in("x1")` would let the compiler assume the buffer pointer survives the
// call, and a second write with the same buffer would pass NULL.
//
// The only instructions in the asm block are the syscall and a `cset` that
// copies the carry flag into a register (Rust has no flag-output operand). The
// error test and the negation are Rust.

use core::arch::asm;

const SYS_EXIT: u64 = 1;
const SYS_READ: u64 = 3;
const SYS_WRITE: u64 = 4;
const SYS_SIGACTION: u64 = 46;
#[allow(dead_code)]
const SYS_SOCKET: u64 = 97;
#[allow(dead_code)]
const SYS_CONNECT: u64 = 98;

/// Returns the result, or -errno when the kernel set the carry flag.
#[inline(always)]
pub unsafe fn sys3(n: u64, a0: u64, a1: u64, a2: u64) -> i64 {
    let ret: i64;
    let carry: u64;
    unsafe {
        asm!(
            "svc #0x80",
            "cset {c}, cs",
            c = lateout(reg) carry,
            // x0 and x1 are written by the kernel. x2 and x16 are preserved by
            // XNU, but nothing documents that, so they are declared clobbered
            // too: it costs nothing here.
            inlateout("x16") n => _,
            inlateout("x0") a0 => ret,
            inlateout("x1") a1 => _,
            inlateout("x2") a2 => _,
            options(nostack),
        );
    }
    if carry != 0 { -ret } else { ret }
}

pub unsafe fn exit(code: u64) -> ! {
    unsafe { sys3(SYS_EXIT, code, 0, 0) };
    loop {}
}

#[allow(dead_code)]
pub unsafe fn read(fd: i64, buf: *mut u8, len: usize) -> i64 {
    unsafe { sys3(SYS_READ, fd as u64, buf as u64, len as u64) }
}

pub unsafe fn write(fd: i64, buf: *const u8, len: usize) -> i64 {
    unsafe { sys3(SYS_WRITE, fd as u64, buf as u64, len as u64) }
}

#[allow(dead_code)]
pub unsafe fn socket(domain: u64, ty: u64, proto: u64) -> i64 {
    unsafe { sys3(SYS_SOCKET, domain, ty, proto) }
}

#[allow(dead_code)]
pub unsafe fn connect(fd: i64, addr: *const u8, len: u64) -> i64 {
    unsafe { sys3(SYS_CONNECT, fd as u64, addr as u64, len) }
}

// struct __sigaction from <sys/signal.h>: handler, trampoline, mask, flags.
#[repr(C)]
struct SigAction {
    handler: u64,
    tramp: u64,
    mask: u32,
    flags: i32,
}

/// sigaction(SIGPIPE, SIG_IGN): a write to a closed pipe or reset socket then
/// fails with EPIPE instead of killing the process (Rust's std does the same).
pub unsafe fn ignore_sigpipe() {
    const SIGPIPE: u64 = 13;
    const SIG_IGN: u64 = 1;
    let sa = SigAction { handler: SIG_IGN, tramp: 0, mask: 0, flags: 0 };
    unsafe { sys3(SYS_SIGACTION, SIGPIPE, &sa as *const SigAction as u64, 0) };
}
