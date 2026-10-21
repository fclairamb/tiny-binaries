// hello, extreme Rust variant: no_std, no libc, raw write/exit syscalls, custom entry.
#![no_std]
#![no_main]

#[path = "../sc.rs"]
mod sc;

entry!(rust_main);

#[unsafe(no_mangle)]
extern "C" fn rust_main(_stack: *const usize) -> ! {
    const MSG: &[u8] = b"Hello, World!\n";
    unsafe {
        sc::write(1, MSG.as_ptr(), MSG.len());
        sc::exit(0)
    }
}
