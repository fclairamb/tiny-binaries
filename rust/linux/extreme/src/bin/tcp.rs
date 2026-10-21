// tcp, extreme Rust variant: no_std, no libc, raw socket/connect/read/write/exit syscalls.
// All parsing, the copy loop and the error checks are Rust; the assembly is the syscall
// instruction and the two-instruction entry glue that hands argc/argv over.
//
// Exit status: 0 after a clean EOF, otherwise the negated errno of the failing syscall:
// connect refused 111, reset mid-reply 104, 9 (EBADF) with fewer than 2 arguments. All
// within 1..125.
//
// Argument count: the socket is socket(AF_INET, SOCK_STREAM, argc - 3). With exactly two
// arguments the protocol is 0 (TCP); with fewer it is negative, socket() fails with
// EINVAL before anything else (inet_create checks the range first), and the connect() on
// that negative "fd" fails with EBADF: exit 9, whatever the one argument holds, with no
// socket and no packet. The same trick as the V slice. It costs no instruction: the
// protocol was a register set to 0 anyway.
//
// The parse, on both arches: one loop over argv[argc-1] down to argv[1], so the port
// (argv[2]) then a.b.c.d (argv[1]). On every separator ('.' or the final NUL)
// x = x << 8 | number, so with two arguments x ends as 0x20000 << 40 | port << 32 |
// a.b.c.d: the 0x02 of the start value lands in bits 56..63 and its zero bits 0..15 in
// 40..55. After a byte swap x is the 8 bytes sin_family = AF_INET, the port and the
// address, in network order.
// Malformed calls are unspecified by SPEC.md: a bad address or port connects somewhere
// else or fails; more than 2 arguments make the protocol positive (see the README).
// It needs argc >= 1, which Linux guarantees since 5.18 (an empty argv gets "").
// Anything below '0' is a separator (x86_64), any byte with bit 4 clear (aarch64).
#![no_std]
#![no_main]
#![cfg_attr(target_arch = "x86_64", feature(rust_preserve_none_cc))]

#[path = "../sc.rs"]
mod sc;

// The request lives in the 8-byte hole at offset 72 (p_paddr), see ../../README.md.
// On aarch64 it is also the read buffer: `static mut` makes the section writable, so lld
// makes the one segment R+W+X. Not on x86_64: Rosetta, which runs the amd64 tests on the
// Mac, maps the header page read-only (the read fails with EFAULT).
#[cfg(target_arch = "x86_64")]
#[unsafe(link_section = ".hole72")]
static REQ: [u8; 6] = *b"hello\n";
#[cfg(target_arch = "aarch64")]
#[unsafe(link_section = ".hole72")]
static mut REQ: [u8; 6] = *b"hello\n";

// x86_64 entry glue: the kernel starts the process with rsp on argc, argv[0], argv[1], ...
// `pop r9; mov r8, rsp` leaves argc in r9 and &argv[0] in r8, main's 10th and 9th
// arguments. The glue is in main's own section, emitted before main (module asm comes
// first), so it falls through into main with no jump; x86 code at opt-level z is not
// aligned, so nothing comes between them. That frees the e_shoff hole for die.
#[cfg(target_arch = "x86_64")]
core::arch::global_asm!(
    ".section .text.start,\"ax\"", ".global _start", "_start:", "pop r9", "mov r8, rsp",
);

// x86_64: exit(-r) in the 8-byte hole at offset 40 (e_shoff): neg edi, push 60, pop rax,
// syscall, 7 bytes. A call to it (mov edi, eax; call: 7 bytes) beats the inlined exit (11).
// The call needs no stack alignment push: the build sets override-stack-alignment to 8.
#[cfg(target_arch = "x86_64")]
#[inline(never)]
#[unsafe(no_mangle)]
#[unsafe(link_section = ".hole40")]
extern "C" fn die(r: i32) -> ! {
    sc::exit(r.wrapping_neg() as usize)
}

// x86_64 main uses the preserve_none convention: it saves no callee-saved register but
// rbp (main never returns, but with the C convention LLVM still pushes rbx and rbp). Its
// 9th and 10th arguments are r8 and r9, where the glue leaves argv and argc. argc stays in
// r9 across the socket call (plain sys3, which leaves r9 alone) and is the loop counter.
#[cfg(target_arch = "x86_64")]
#[unsafe(no_mangle)]
#[unsafe(link_section = ".text.start")]
extern "rust-preserve-none" fn main(
    _: usize, _: usize, _: usize, _: usize, _: usize, _: usize, _: usize, _: usize,
    argv: *mut usize, argc: usize,
) -> ! {
    unsafe {
        let fd = sc::sys3(sc::nr::SOCKET, 2, 1, argc.wrapping_sub(3)) as usize;
        let mut x: u64 = 0x2_0000;
        let mut k = argc;
        loop {
            k -= 1;
            if k == 0 {
                break;
            }
            let mut p = *argv.add(k) as *const u8;
            let mut cur: u64 = 0;
            loop {
                let c = *p as u32;
                p = p.add(1);
                if c < 48 {
                    x = x << 8 | cur;
                    cur = 0;
                    if c == 0 {
                        break;
                    }
                } else {
                    cur = (cur as u32 * 10 + c - 48) as u64;
                }
            }
        }
        // sockaddr_in over argv[0], which is not needed any more. sin_zero is the next 8
        // bytes, argv[1], not zero: Linux does not check it for connect.
        *argv = x.swap_bytes() as usize;
        let r = sc::sys3(sc::nr::CONNECT, fd, argv as usize, 16);
        if r != 0 {
            die(r as i32)
        }
        // The first write sends the request, the next ones copy the reply to stdout. The
        // read buffer is the stack at argv (argv[0], argv[1]: 16 bytes, more than any read).
        // The last read returns 0 at the end of the stream, or -errno: the exit status.
        // The read count is the previous write length: 6 for the request, then whatever
        // the last read returned, so it is the smallest read so far (6 at most, 1 byte per
        // read and write in the worst case). Correct (everything is copied, in order, until
        // EOF or error) and it saves loading a buffer size.
        let mut dst = fd;
        let mut buf = REQ.as_ptr();
        let mut n = REQ.len() as isize;
        loop {
            sc::sys3x(sc::nr::WRITE, dst, buf as usize, n as usize);
            n = sc::sys3x(sc::nr::READ, fd, argv as usize, n as usize);
            if n <= 0 {
                die(n as i32)
            }
            dst = 1;
            buf = argv as *const u8;
        }
    }
}

// aarch64 entry glue, in the hole at offset 40 (e_shoff): x4 = &argv[0] (sp + 8), main's
// 5th argument, a register the syscalls leave alone; argc is at x4 - 8.
#[cfg(target_arch = "aarch64")]
core::arch::global_asm!(
    ".section .hole40,\"ax\"", ".global _start", "_start:", "add x4, sp, 8", "b {m}",
    m = sym main,
);

// aarch64 has a 12-byte hole at offset 4 (e_ident[4..15], ignored by the arm64 kernel),
// exactly the size of exit(-r): neg, mov, svc. Every error path branches there.
#[cfg(target_arch = "aarch64")]
#[inline(never)]
#[unsafe(no_mangle)]
#[unsafe(link_section = ".hole4")]
extern "C" fn die(r: isize) -> ! {
    sc::exit(r.wrapping_neg() as usize)
}

#[cfg(target_arch = "aarch64")]
#[unsafe(no_mangle)]
extern "C" fn main(_: usize, _: usize, _: usize, _: usize, argv: *mut usize) -> ! {
    unsafe {
        // Same parse as x86_64. The digits '0'..'9' have bit 4 set and the separators '.'
        // and NUL do not: one tbz.
        let mut k = *argv.sub(1);
        let fd = sc::sys3(sc::nr::SOCKET, 2, 1, k.wrapping_sub(3)) as usize;
        let mut x: u64 = 0x2_0000;
        loop {
            k -= 1;
            if k == 0 {
                break;
            }
            let mut p = *argv.add(k) as *const u8;
            let mut cur: u64 = 0;
            loop {
                let c = *p as u64;
                p = p.add(1);
                if c & 16 == 0 {
                    x = x << 8 | cur;
                    cur = 0;
                    if c == 0 {
                        break;
                    }
                } else {
                    cur = cur * 10 + c - 48;
                }
            }
        }
        // sockaddr_in over argv[0], sin_zero over argv[1] (see x86_64). The fd rides
        // through connect in x3 (sys3k), so it is copied out of x0 once.
        *argv = x.swap_bytes() as usize;
        let (r, fd) = sc::sys3k(sc::nr::CONNECT, fd, argv as usize, 16, fd);
        if r != 0 {
            die(r)
        }
        // The read count is the previous write length (6, then the last read), so each
        // read is at most 6 bytes and fits in REQ, which is both the request and the
        // read buffer: one pointer for every write and read.
        let buf = &raw mut REQ as usize;
        let mut dst = fd;
        let mut n = 6;
        loop {
            sc::sys3(sc::nr::WRITE, dst, buf, n as usize);
            n = sc::sys3(sc::nr::READ, fd, buf, n as usize);
            if n <= 0 {
                die(n)
            }
            dst = 1;
        }
    }
}
