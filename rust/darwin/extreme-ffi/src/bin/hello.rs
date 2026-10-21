#![no_std]
#![no_main]

// Variant of hello-extreme that calls libSystem through FFI instead of raw
// syscalls. Each import is a GOT slot that dyld binds at load time; the GOT is
// a writable segment, but macho_pack.py makes it zero-fill, so an import costs
// only its bind opcodes, past the 16 KiB page, and those hold its name. So the
// one import is puts(), the shortest name that writes to stdout (it adds the
// newline). stdio flushes when `main` returns into libdyld's exit(). The spec
// leaves stdout errors unspecified, so there is no signal(SIGPIPE) call and the
// status is 0.

use core::ffi::{c_char, c_int};

unsafe extern "C" {
    fn puts(s: *const c_char) -> c_int;
}

#[unsafe(no_mangle)]
pub extern "C" fn main(_argc: c_int, _argv: *const *const u8) -> c_int {
    unsafe { puts(c"Hello, World!".as_ptr()) };
    0
}

#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! {
    unsafe extern "C" {
        fn _exit(code: c_int) -> !;
    }
    unsafe { _exit(1) }
}
