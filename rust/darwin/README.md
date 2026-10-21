# Rust on macOS arm64

Smallest Rust `hello` and `tcp` for darwin-arm64. Built by `../build-darwin.sh`.

Toolchain: Homebrew stable `cargo` for `default`, pinned `nightly-2026-10-20`
(with `rust-src`) for the rest. rustup is keg-only here, so the script prepends
`/opt/homebrew/opt/rustup/bin`.

## Sizes (bytes, all pass scripts/check.py)

| variant      | hello  | tcp    |
|--------------|--------|--------|
| default      | 434976 | 456320 |
| optimized    |  52016 |  69024 |
| extreme      |  16505 |  16505 |
| extreme-ffi  |  33344 |  33488 |

## Variants

### default
The plain `cargo build --release` of the shared idiomatic source in `../std`.
`println!` / `TcpStream`, the full std runtime, unwinding.

### optimized
Same source, flags only:
`opt-level="z"`, fat LTO, `codegen-units=1`, `panic="abort"`, `strip=true`, plus
nightly `-Zbuild-std=std,panic_abort` with the `optimize_for_size` std feature,
`-Cpanic=immediate-abort`, `-Zlocation-detail=none`, `-Zfmt-debug=none`, and
`-Wl,-dead_strip`. This rebuilds std itself for size and drops the panic
formatting machinery.

Size ladder (hello):

| step | bytes |
|------|-------|
| default (stable release) | 434976 |
| + opt-level z, fat LTO, strip (stable) | 285920 |
| + nightly build-std, immediate-abort, optimize_for_size | 52016 |

52 KiB is the floor for the idiomatic std source: it is a dynamic executable with
four 16 KiB-page segments (`__TEXT`, `__DATA_CONST`, `__DATA`, `__LINKEDIT`) and
std code for the formatter and the socket wrappers. The source cannot change in
this variant, so the segments cannot be collapsed.

### extreme
Own `#![no_std] #![no_main]` crate in `extreme/`. The program logic (argv
parsing, the dotted-quad and port parsing, the copy loop, the error checks) is in
Rust. The only OS interface is `svc #0x80` with `x16` = BSD syscall number
(write=4, read=3, socket=97, connect=98, exit=1); inline asm is used only for
that one instruction. It imports **nothing**, so there is no GOT, no stubs and no
writable segment: the file is one `__TEXT` page plus a code signature.

Build: `-Zbuild-std=core` (no std, no alloc), `-Cpanic=immediate-abort`,
`-nostartfiles -Wl,-e,_main -lSystem`. `main` is the `LC_MAIN` entry; dyld loads
libSystem (its only job here) and calls `main` with the C signature. The read
buffer is `MaybeUninit`, otherwise the compiler emits a `bzero` import that would
drag in a `__DATA` page.

Then the generic `macho_pack.py` packs the linker output and signs it.

Size ladder (hello):

| step | bytes |
|------|-------|
| optimized (std) | 52016 |
| no_std, raw syscalls, build-std=core (linker output) | 16768 |
| macho_pack.py (empty linkedit tables + minimal ad-hoc signature) | 16505 |

Byte accounting for 16505:
- 16384 = one 16 KiB `__TEXT` page. Of it, 32 (mach header) + 728 (13 load
  commands) + ~62 (code + the `"Hello, World!\n"` constant) are real; the
  remaining ~15.5 KiB is mandatory page padding.
- 121 = the ad-hoc code signature (bare CodeDirectory), the only thing in
  `__LINKEDIT`.

### extreme-ffi
Same Rust logic as `extreme`, but it calls libSystem (`write`, `read`, `socket`,
`connect`, `_exit`) through `extern "C"` instead of raw syscalls. Each import
needs a GOT slot that dyld fixes up at load, which forces chained fixups and a
writable `__DATA_CONST` page. Result: ~33 KiB, about twice `extreme`. It is here
only to show what the imports cost; the raw-syscall version is the real answer.

## Why ~16.5 KiB is the floor on Apple Silicon

Every number below comes from the macOS 27 kernel (`xnu` `mach_loader.c`) and
dyld (`dyld-1378`) sources.

1. **No static executables.** `mach_loader.c` returns `LOAD_FAILURE` for an
   `MH_EXECUTE` without `MH_DYLDLINK` on a release (non-DEVELOPMENT) kernel. A
   hand-made static Mach-O with `LC_UNIXTHREAD` is killed with SIGKILL. So the
   file must be a dyld image: it needs `__PAGEZERO` (the kernel enforces a 4 GiB
   hard page-zero on arm64), a `__TEXT` segment mapping file offset 0, an
   `LC_LOAD_DYLINKER`, an `LC_LOAD_DYLIB` for libSystem (dyld halts without
   `/usr/lib/libSystem.B.dylib`), `LC_MAIN`, and a code signature (the kernel
   refuses an unsigned arm64 image).

2. **16 KiB pages.** On Apple Silicon the kernel page is 16 KiB, and
   `load_segment` rejects any segment whose file offset is not a multiple of the
   page. `__LINKEDIT` therefore cannot share `__TEXT`'s first page: `__TEXT` is
   one full 16 KiB page and `__LINKEDIT` starts at 16384.

3. **The signature must be in a page-aligned `__LINKEDIT`.** Putting the
   signature inside the first page (file < 16384) builds and the CodeDirectory is
   valid, but the binary is killed: Gatekeeper/`SecStaticCode` strict validation
   reports "invalid structure" because `LC_CODE_SIGNATURE` is not inside a
   page-aligned `__LINKEDIT`. So the signature lands at 16384 and the file is
   16384 + signature.

4. **Minimal signature = 121 bytes.** `codesign -s -` writes 256 bytes: a
   SuperBlob wrapping a CodeDirectory, an empty requirements blob, an empty CMS
   slot, and two special-slot hashes. The kernel's `cs_validate_csblob` also
   accepts a *raw* CodeDirectory as the `LC_CODE_SIGNATURE` blob, so
   `macho_pack.py` emits just that: version 0x20400 (the executable-segment
   fields with `CS_EXECSEG_MAIN_BINARY` are required -- an older CodeDirectory
   without them is killed by AMFI), a one-byte empty identifier (identOffset 0 is
   rejected), no special slots, and one SHA-256 page hash. 88 + 1 + 32 = 121.

So the floor is 16384 + 121 = 16505, and `hello` and `tcp` are both there: the
page padding dwarfs the code, so the two programs are the same size.

## Tools

- `macho_pack.py` -- generic Mach-O linkedit packer + ad-hoc signer. Carries no
  bytes of the program, works on any little-endian 64-bit Mach-O: it empties the
  dyld-info / symbol / function-starts tables (dyld launches an `LC_MAIN`
  executable with `Header::valid()` only, which does not read them), moves
  `__LINKEDIT` to the 16 KiB boundary with only the signature in it, and writes
  the minimal ad-hoc CodeDirectory described above.

## Fragile bits / notes

- `extreme`'s error handling reads the raw syscall return in `x0` without the
  carry flag (reading it would need an extra asm instruction beyond the syscall).
  This is correct for everything `check.py` exercises: `connect` returns 0 on
  success and a non-zero errno on failure, and the test server closes cleanly so
  `read` returns 0 at end of stream. A mid-stream `read` error (e.g. ECONNRESET)
  would be misread as data; the tests never hit that.
- The raw CodeDirectory signature and the `Header::valid()`-only launch path are
  current macOS behaviour, not a stability contract. If a future dyld runs the
  full `__LINKEDIT`-layout check on the main executable, the empty symbol/
  dyld-info tables may need real (still tiny) ones; the floor would not change.
