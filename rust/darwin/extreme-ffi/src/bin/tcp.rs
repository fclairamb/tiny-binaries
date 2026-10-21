#![no_std]
#![no_main]

// Variant of tcp-extreme that calls libSystem through FFI instead of raw
// syscalls (see hello.rs in this crate). Same Rust logic, minus the
// signal(SIGPIPE) call: the spec allows SIGPIPE on a stdout error or on a reset
// before the request is read. The status is the return value of `main`, which
// libdyld passes to exit().
//
// Every import costs its name in the bind opcodes, past the 16 KiB page. So
// the four calls go through one libSystem function, syscall(2): `_syscall`
// costs 15 bytes of opcodes where `_socket`, `_connect`, `_read` and `_write`
// cost 42. It returns -1 (errno set) on failure, like the named wrappers.

use core::ffi::{c_int, c_void};

unsafe extern "C" {
    fn syscall(number: c_int, ...) -> c_int;
}

// <sys/syscall.h>
const SYS_READ: c_int = 3;
const SYS_WRITE: c_int = 4;
const SYS_SOCKET: c_int = 97;
const SYS_CONNECT: c_int = 98;

unsafe fn socket(domain: c_int, ty: c_int, proto: c_int) -> c_int {
    unsafe { syscall(SYS_SOCKET, domain, ty, proto) }
}
unsafe fn connect(fd: c_int, addr: *const Sockaddr, len: u32) -> c_int {
    unsafe { syscall(SYS_CONNECT, fd, addr, len) }
}
unsafe fn write(fd: c_int, buf: *const c_void, n: usize) -> isize {
    unsafe { syscall(SYS_WRITE, fd, buf, n) as isize }
}
unsafe fn read(fd: c_int, buf: *mut c_void, n: usize) -> isize {
    unsafe { syscall(SYS_READ, fd, buf, n) as isize }
}

const AF_INET: c_int = 2;
const SOCK_STREAM: c_int = 1;

#[repr(C)]
struct Sockaddr {
    sin_len: u8,
    sin_family: u8,
    sin_port: u16,
    sin_addr: u32,
    sin_zero: [u8; 8],
}

unsafe fn clen(mut p: *const u8) -> usize {
    let mut n = 0;
    while unsafe { *p } != 0 {
        n += 1;
        p = unsafe { p.add(1) };
    }
    n
}

fn parse_uint(bytes: &[u8], max: u32) -> Option<u32> {
    if bytes.is_empty() {
        return None;
    }
    let mut v: u32 = 0;
    for &b in bytes {
        if !b.is_ascii_digit() {
            return None;
        }
        v = v.checked_mul(10)?.checked_add((b - b'0') as u32)?;
        if v > max {
            return None;
        }
    }
    Some(v)
}

fn parse_ipv4(s: &[u8]) -> Option<u32> {
    let mut out: u32 = 0;
    let mut parts = 0;
    for field in s.split(|&b| b == b'.') {
        if parts == 4 {
            return None;
        }
        let octet = parse_uint(field, 255)?;
        out = (out << 8) | octet;
        parts += 1;
    }
    if parts != 4 {
        return None;
    }
    Some(out.to_be())
}

// Everything after argc: None on any failure.
unsafe fn run(ip_ptr: *const u8, port_ptr: *const u8) -> Option<()> {
    let ip_s = unsafe { core::slice::from_raw_parts(ip_ptr, clen(ip_ptr)) };
    let port_s = unsafe { core::slice::from_raw_parts(port_ptr, clen(port_ptr)) };
    let addr = parse_ipv4(ip_s)?;
    let port = parse_uint(port_s, 65535).filter(|&p| p >= 1)? as u16;

    let sa = Sockaddr {
        sin_len: 16,
        sin_family: AF_INET as u8,
        sin_port: port.to_be(),
        sin_addr: addr,
        sin_zero: [0; 8],
    };

    unsafe {
        let fd = socket(AF_INET, SOCK_STREAM, 0);
        if fd < 0 || connect(fd, &sa, 16) < 0 {
            return None;
        }
        let req = b"hello\n";
        if write(fd, req.as_ptr() as *const c_void, req.len()) != req.len() as isize {
            return None;
        }
        // Uninitialised: read() fills it and only what it returns is written.
        let mut buf = core::mem::MaybeUninit::<[u8; 4096]>::uninit();
        let buf_ptr = buf.as_mut_ptr() as *mut u8;
        loop {
            let n = read(fd, buf_ptr as *mut c_void, 4096);
            if n < 0 {
                return None;
            }
            if n == 0 {
                return Some(());
            }
            let mut off = 0isize;
            while off < n {
                let w = write(1, buf_ptr.offset(off) as *const c_void, (n - off) as usize);
                if w <= 0 {
                    return None;
                }
                off += w;
            }
        }
    }
}

#[unsafe(no_mangle)]
pub extern "C" fn main(argc: c_int, argv: *const *const u8) -> c_int {
    if argc < 3 {
        return 1;
    }
    match unsafe { run(*argv.add(1), *argv.add(2)) } {
        Some(()) => 0,
        None => 1,
    }
}

#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! {
    unsafe extern "C" {
        fn _exit(code: c_int) -> !;
    }
    unsafe { _exit(1) }
}
