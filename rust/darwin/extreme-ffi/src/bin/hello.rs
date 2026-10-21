#![no_std]
#![no_main]

// Variant of hello-extreme that calls libSystem through FFI instead of raw
// syscalls. Each import is a GOT slot that dyld binds at load time; the GOT is
// a writable segment, but macho_pack.py makes it zero-fill, so the imports cost
// only their bind opcodes in the file.
//
// `main` is the LC_MAIN entry: returning from it hands the status to libdyld,
// which calls exit(), so no _exit import is needed.

use core::ffi::{c_int, c_void};

unsafe extern "C" {
    fn write(fd: c_int, buf: *const c_void, n: usize) -> isize;
    fn signal(sig: c_int, handler: usize) -> usize;
}

const SIGPIPE: c_int = 13;
const SIG_IGN: usize = 1;
const MSG: &[u8] = b"Hello, World!\n";

#[unsafe(no_mangle)]
pub extern "C" fn main(_argc: c_int, _argv: *const *const u8) -> c_int {
    unsafe {
        // A closed stdout pipe then gives EPIPE (exit 1), not a SIGPIPE kill.
        signal(SIGPIPE, SIG_IGN);
        (write(1, MSG.as_ptr() as *const c_void, MSG.len()) != MSG.len() as isize) as c_int
    }
}

#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! {
    unsafe extern "C" {
        fn _exit(code: c_int) -> !;
    }
    unsafe { _exit(1) }
}
