#![no_std]
#![no_main]

// Minimal TCP client for macOS arm64: `tcp <ipv4> <port>`.
//
// A dynamic Mach-O that imports nothing (see hello.rs and darwin/README.md).
// All logic (argv parsing, the dotted quad and port parsing, the copy loop, the
// error checks) is in Rust; the kernel is reached directly with `svc #0x80`
// through sys.rs, which turns the carry flag into a negative errno.

#[path = "../sys.rs"]
mod sys;

const AF_INET: u64 = 2;
const SOCK_STREAM: u64 = 1;

// macOS sockaddr_in, 16 bytes, built on the stack.
#[repr(C)]
struct Sockaddr {
    sin_len: u8,
    sin_family: u8,
    sin_port: u16, // network byte order
    sin_addr: u32, // network byte order
    sin_zero: [u8; 8],
}

fn die() -> ! {
    unsafe { sys::exit(1) }
}

unsafe fn clen(mut p: *const u8) -> usize {
    let mut n = 0;
    while unsafe { *p } != 0 {
        n += 1;
        p = unsafe { p.add(1) };
    }
    n
}

// Parse a run of ASCII decimal digits into a u32, failing on a non-digit, an
// empty run, or a value past `max`.
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

// Parse a dotted quad "a.b.c.d" into a network-byte-order u32.
fn parse_ipv4(s: &[u8]) -> Option<u32> {
    let mut out: u32 = 0;
    let mut parts = 0;
    for field in s.split(|&b| b == b'.') {
        if parts == 4 {
            return None;
        }
        let octet = parse_uint(field, 255)?;
        out = (out << 8) | octet; // first octet in the high byte
        parts += 1;
    }
    if parts != 4 {
        return None;
    }
    Some(out.to_be())
}

#[unsafe(no_mangle)]
pub extern "C" fn main(argc: i32, argv: *const *const u8) -> i32 {
    if argc < 3 {
        die();
    }
    let (ip_ptr, port_ptr) = unsafe { (*argv.add(1), *argv.add(2)) };
    let ip_s = unsafe { core::slice::from_raw_parts(ip_ptr, clen(ip_ptr)) };
    let port_s = unsafe { core::slice::from_raw_parts(port_ptr, clen(port_ptr)) };

    let Some(addr) = parse_ipv4(ip_s) else { die() };
    let port = match parse_uint(port_s, 65535) {
        Some(p) if p >= 1 => p as u16,
        _ => die(),
    };

    let sa = Sockaddr {
        sin_len: 16,
        sin_family: AF_INET as u8,
        sin_port: port.to_be(),
        sin_addr: addr,
        sin_zero: [0; 8],
    };

    unsafe {
        // A reset socket or a closed stdout pipe then fails with EPIPE (exit 1)
        // instead of killing the process with SIGPIPE.
        sys::ignore_sigpipe();
        let fd = sys::socket(AF_INET, SOCK_STREAM, 0);
        if fd < 0 {
            die();
        }
        if sys::connect(fd, &sa as *const Sockaddr as *const u8, 16) < 0 {
            die();
        }
        let req = b"hello\n";
        if sys::write(fd, req.as_ptr(), req.len()) != req.len() as i64 {
            die();
        }
        // Uninitialised: read() fills it, and only the bytes it returns are
        // written out. Zeroing it would pull in an imported bzero/memset.
        let mut buf = core::mem::MaybeUninit::<[u8; 4096]>::uninit();
        let buf_ptr = buf.as_mut_ptr() as *mut u8;
        loop {
            let n = sys::read(fd, buf_ptr, 4096);
            if n < 0 {
                die(); // ECONNRESET and friends
            }
            if n == 0 {
                break; // orderly close
            }
            let mut off = 0i64;
            while off < n {
                let w = sys::write(1, buf_ptr.add(off as usize), (n - off) as usize);
                if w <= 0 {
                    die();
                }
                off += w;
            }
        }
        sys::exit(0)
    }
}

#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! {
    die()
}
