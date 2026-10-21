#![no_std]
#![no_main]

// Minimal "Hello, World!" for macOS arm64.
//
// A dynamic Mach-O (the release kernel kills a static executable, see
// darwin/README.md), but it imports nothing: the kernel is reached directly
// with `svc #0x80`. With no imported symbols there is no GOT and no writable
// data, so the linked file is __PAGEZERO + __TEXT + __LINKEDIT, which
// macho_pack.py then folds into one 16 KiB page.
//
// `main` is the LC_MAIN entry; dyld calls it with the C main() signature.

#[path = "../sys.rs"]
mod sys;

const MSG: &[u8] = b"Hello, World!\n";

#[unsafe(no_mangle)]
pub extern "C" fn main(_argc: i32, _argv: *const *const u8) -> i32 {
    unsafe {
        // A closed stdout pipe then gives EPIPE (exit 1), not a SIGPIPE kill.
        sys::ignore_sigpipe();
        let n = sys::write(1, MSG.as_ptr(), MSG.len());
        sys::exit((n != MSG.len() as i64) as u64)
    }
}

#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! {
    unsafe { sys::exit(1) }
}
