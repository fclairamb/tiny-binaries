// hello, extreme Rust variant: no_std, no libc, raw write/exit syscalls.
//
// The program is split into small functions that tail-call each other (`become`), so the
// linker script can drop the first ones into ELF header bytes the kernel never reads (see
// ../../README.md): the message in one hole, the entry function in another. Each function
// takes the registers the next one needs as plain arguments, so a tail call is a lone
// branch and passing a value along costs nothing. They are `no_mangle` so that LTO keeps
// their signatures as written instead of folding the constants into the last one.
#![no_std]
#![no_main]
#![feature(explicit_tail_calls)]
#![allow(incomplete_features, unreachable_code)]

#[path = "../sc.rs"]
mod sc;

// 14 bytes, the size of the hole at offset 40 (e_shoff, e_flags, e_ehsize).
#[unsafe(link_section = ".hole40")]
static MSG: [u8; 14] = *b"Hello, World!\n";

// aarch64: three functions, write(1, MSG, 14) then exit(0).
//   _start (hole at 4, 12 bytes): adr x1, MSG; mov w2, #14; b h2
//   h2     (hole at 80,  8 bytes): mov w0, #1; b h3
//   h3     (code): the two syscalls
#[cfg(target_arch = "aarch64")]
#[unsafe(no_mangle)]
#[unsafe(link_section = ".hole4")]
extern "C" fn _start(fd: usize, _: *const u8, _: usize) -> ! {
    become h2(fd, MSG.as_ptr(), MSG.len());
}
#[cfg(target_arch = "aarch64")]
#[inline(never)]
#[unsafe(no_mangle)]
#[unsafe(link_section = ".hole80")]
extern "C" fn h2(_: usize, buf: *const u8, len: usize) -> ! {
    become h3(1, buf, len);
}
#[cfg(target_arch = "aarch64")]
#[inline(never)]
#[unsafe(no_mangle)]
extern "C" fn h3(fd: usize, buf: *const u8, len: usize) -> ! {
    unsafe { sc::sys3(sc::nr::WRITE, fd, buf as usize, len) };
    sc::exit(0)
}

// x86_64: two functions. A rel32 jump is 5 bytes, so the 8-byte hole at 80 holds only
// `push 14; pop rdx; jmp h2`; h2 loads the address (mov esi, imm32) and does the syscalls.
#[cfg(target_arch = "x86_64")]
#[unsafe(no_mangle)]
#[unsafe(link_section = ".hole80")]
extern "C" fn _start(fd: usize, buf: *const u8, _: usize) -> ! {
    become h2(fd, buf, MSG.len());
}
#[cfg(target_arch = "x86_64")]
#[inline(never)]
#[unsafe(no_mangle)]
extern "C" fn h2(_: usize, _: *const u8, len: usize) -> ! {
    unsafe { sc::sys3(sc::nr::WRITE, 1, MSG.as_ptr() as usize, len) };
    sc::exit(0)
}
