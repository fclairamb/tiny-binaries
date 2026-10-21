// tcp, extreme Rust variant: no_std, no libc, raw socket/connect/read/write/exit
// syscalls, custom entry. All parsing and the copy loop are in Rust.
#![no_std]
#![no_main]

#[path = "../sc.rs"]
mod sc;

entry!(rust_main);

// Every error path jumps here: one exit site instead of one per check. Exit 1 is
// in the 1..125 range the spec requires for a bad argc or a failed connect; parse
// failures are unspecified but must still exit in range, so 1 serves them all.
#[inline(never)]
#[cold]
fn fail() -> ! {
    sc::exit(1)
}

// Read a C string one byte at a time until NUL; parse a dotted-quad IPv4.
unsafe fn parse_ip(mut p: *const u8) -> Option<[u8; 4]> {
    let mut out = [0u8; 4];
    let mut i = 0;
    loop {
        let (val, next, seen) = unsafe { parse_num(p, 255) };
        if !seen {
            return None;
        }
        out[i] = val as u8;
        p = next;
        let c = unsafe { *p };
        i += 1;
        if c == b'.' {
            if i == 4 {
                return None;
            }
            p = unsafe { p.add(1) };
        } else if c == 0 {
            return if i == 4 { Some(out) } else { None };
        } else {
            return None;
        }
    }
}

// Parse decimal digits at p into a value capped at `max`, returning (value, pointer
// past the digits, whether at least one digit was read). Stops at any non-digit or
// as soon as the value would exceed `max`.
unsafe fn parse_num(mut p: *const u8, max: u32) -> (u32, *const u8, bool) {
    let mut v: u32 = 0;
    let mut seen = false;
    loop {
        let c = unsafe { *p };
        let d = c.wrapping_sub(b'0');
        if d < 10 {
            v = v * 10 + d as u32;
            if v > max {
                return (v, p, seen);
            }
            seen = true;
            p = unsafe { p.add(1) };
        } else {
            return (v, p, seen);
        }
    }
}

unsafe fn parse_port(p: *const u8) -> Option<u16> {
    let (v, end, seen) = unsafe { parse_num(p, 65535) };
    if seen && unsafe { *end } == 0 && v >= 1 {
        Some(v as u16)
    } else {
        None
    }
}

#[unsafe(no_mangle)]
extern "C" fn rust_main(stack: *const usize) -> ! {
    unsafe {
        let argc = *stack;
        if argc < 3 {
            fail();
        }
        let argv = stack.add(1) as *const *const u8;
        let ip = match parse_ip(*argv.add(1)) {
            Some(v) => v,
            None => fail(),
        };
        let port = match parse_port(*argv.add(2)) {
            Some(v) => v,
            None => fail(),
        };

        // sockaddr_in as two 8-byte words (the struct is 16 bytes, 8-aligned here),
        // built with shifts so the whole thing is two stores and no memset.
        // Low word, little-endian bytes: [AF_INET=2, 0, port_hi, port_lo, ip0..ip3].
        let ipw = u32::from_ne_bytes(ip) as u64;
        let w0 = 2u64
            | (((port >> 8) & 0xff) as u64) << 16
            | ((port & 0xff) as u64) << 24
            | ipw << 32;
        let mut addr = core::mem::MaybeUninit::<[u64; 2]>::uninit();
        let a = addr.as_mut_ptr() as *mut u64;
        a.write(w0);
        a.add(1).write(0);

        let fd = sc::sys3(sc::nr::SOCKET, 2, 1, 0);
        if sc::is_err(fd) {
            fail();
        }
        let r = sc::sys3(sc::nr::CONNECT, fd, a as usize, 16);
        if sc::is_err(r) {
            fail();
        }

        const REQ: &[u8] = b"hello\n";
        write_all(fd, REQ.as_ptr(), REQ.len());

        let mut buf = core::mem::MaybeUninit::<[u8; 4096]>::uninit();
        let bp = buf.as_mut_ptr() as *mut u8;
        loop {
            let n = sc::read(fd, bp, 4096);
            if n == 0 {
                break;
            }
            if sc::is_err(n) {
                fail();
            }
            write_all(1, bp, n);
        }
        sc::exit(0)
    }
}

// Write every byte, retrying on short writes. Any error ends the program.
unsafe fn write_all(fd: usize, mut buf: *const u8, mut len: usize) {
    while len > 0 {
        let n = unsafe { sc::write(fd, buf, len) };
        if sc::is_err(n) || n == 0 {
            fail();
        }
        buf = unsafe { buf.add(n) };
        len -= n;
    }
}
