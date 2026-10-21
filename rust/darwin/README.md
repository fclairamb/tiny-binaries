# Rust on darwin-arm64

Built by `rust/build-darwin.sh` on macOS 27.0.1 (Apple Silicon, 16 KiB pages) with rustc 1.99.1,
ld-27037.1 and the macOS 27.0 SDK (Xcode command line tools). Every size is a binary that passed `scripts/check.py`, and two builds
give the same bytes.

| Variant | hello | tcp | What it is |
|---|---:|---:|---|
| `default` | 434976 | 456416 | `cargo build --release` of the idiomatic source (`rust/std`) |
| `optimized` | 33561 | 33673 | same source and compiler, build-std and linker flags, then `macho_pack.py --strip` |
| `extreme` | 16384 | 16384 | `no_std`, raw system calls, folded into one page by `macho_pack.py` |
| `extreme-strict` | 16516 | 16516 | the same linker output in the normal layout (`macho_pack.py --strip`) |
| `extreme-ffi` | 16395 | 16398 | `no_std`, libSystem calls through FFI, folded like `extreme` |

`variants.json` here describes these variants. SPEC asks for `rust/variants.json`, which
`scripts/report.py` reads, but that path is outside this slice and does not exist yet: someone
has to merge this file and `rust/linux/variants.json` into it (`extreme-strict` and
`extreme-ffi` are darwin-only).

## Toolchains and network

- rustup, from Homebrew. It is keg-only, so the script prepends `/opt/homebrew/opt/rustup/bin`
  to `PATH`. One pinned toolchain, `1.99.1` (stable), for every variant. rustup downloads it by
  itself when it is missing (network), but its auto-install leaves out `rust-src`, which
  `-Zbuild-std` needs. So the script runs `rustup component add rust-src --toolchain 1.99.1`,
  which does nothing, offline, when it is there.
- Cargo always runs `--offline --locked`. `-Zbuild-std` would fetch std's own crates (`cfg-if`,
  `hashbrown`, `libc`, ...) from crates.io, but `rust-src` ships them in `library/vendor`.
  Cargo reads that directory only when run from `library/`, so the script points crates.io at
  it.
- `/usr/bin/python3`, `codesign`, `cc` and `ld` from the Xcode command line tools. The numbers
  here are for ld-27037.1 and the macOS 27.0 SDK. The build log prints the ld that `cc` runs
  (`cc -print-prog-name=ld`) and the SDK: another ld can lay files out differently.
- Every run builds from scratch in a fresh target dir and `CARGO_HOME`
  (`$TMPDIR/tiny-binaries/darwin-arm64/rust.XXXXXX`, removed at the end). Cargo's fingerprints
  do not track every input that changes the bytes (`MACOSX_DEPLOYMENT_TARGET`, the linker), so
  a kept cache could ship stale binaries. A full build takes about 30 s.
- Cargo reads `.cargo/config.toml` in every parent of its working directory, whatever
  `--manifest-path` and `CARGO_HOME` say. So the script runs it from `/`: the only config files
  left are `/.cargo/config.toml` and the empty `CARGO_HOME`. A `.cargo/config.toml` above the
  caller's cwd (`~/.cargo/config.toml` for a checkout under `$HOME`) with `opt-level = 0` and
  `[build] rustflags` gives the same bytes.
- The script drops the caller's `CARGO*` and `RUST*` variables (`RUSTFLAGS`,
  `CARGO_ENCODED_RUSTFLAGS`, `CARGO_PROFILE_*`, `RUSTC_BOOTSTRAP`, ...; `RUSTUP*` stays, and the
  `+1.99.1` on every call overrides `RUSTUP_TOOLCHAIN`), and `SDKROOT`, `DEVELOPER_DIR` and
  `TOOLCHAINS`, which pick the SDK and the Xcode tools. It puts `/usr/bin` first in `PATH`
  (Apple's `cc`), pins `MACOSX_DEPLOYMENT_TARGET=11.0`, rustc's default, and pins `SDKROOT` to
  `xcrun --sdk macosx --show-sdk-path`. A build with `SDKROOT` set to the 15.2 SDK,
  `DEVELOPER_DIR`, `TOOLCHAINS`, `MACOSX_DEPLOYMENT_TARGET=15.0`, `RUSTFLAGS`,
  `CARGO_ENCODED_RUSTFLAGS`, `CARGO_PROFILE_RELEASE_OPT_LEVEL`, `RUSTUP_TOOLCHAIN` and
  `RUSTC_BOOTSTRAP` set gives the same bytes. What still changes them is the system's Xcode
  selection (`xcode-select`) and the tools installed there.

## default

`cargo +1.99.1 build --release`: `println!`, `TcpStream`, `io::copy`, the full std runtime with
unwinding.

`default` and `optimized` build the shared `rust/std` crate. Its tcp writes `fail()`'s message
with `writeln!` and ignores the result. `eprintln!` would panic when stderr is a broken pipe
(Rust ignores `SIGPIPE`, so the write fails with `EPIPE`): exit 101 in `default`, `SIGTRAP` in
`optimized` (an immediate-abort panic is a `brk`). With `writeln!`, every variant exits 1.

## optimized

Same source and same compiler as `default`. `-Zbuild-std` and `-Cpanic=immediate-abort` are
unstable options, and `RUSTC_BOOTSTRAP=1` lets the stable 1.99.1 rustc and cargo take them (the
Linux kernel builds its Rust this way). std is rebuilt from 1.99.1's own `rust-src` with other
features: `optimize_for_size`, and `compiler-builtins-mem`, which links compiler-builtins'
own `memcpy`, `memmove` and `strlen` instead of importing libSystem's (36 imports become 33 in
hello, 46 become 43 in tcp; the code fits in the same `__TEXT` page). That reads
"compiler flags" broadly: the program source and the compiler are the same, std's build is
not the shipped one. With stable options only (the profile, the same linker flags,
`macho_pack.py --strip`), the best is 263857 / 280373 bytes.

```
RUSTC_BOOTSTRAP=1 cargo +1.99.1 build --release --target aarch64-apple-darwin
  -Zbuild-std=std,panic_abort -Zbuild-std-features=optimize_for_size,compiler-builtins-mem
  profile: opt-level="z" lto="fat" codegen-units=1 panic="abort" strip=true
  RUSTFLAGS: -Zunstable-options -Cpanic=immediate-abort -Zlocation-detail=none -Zfmt-debug=none
             -Wl,-no_data_const -Wl,-rename_section,__TEXT,__const,__DATA,__const
             -Wl,-no_fixup_chains -Wl,-bind_at_load
macho_pack.py --strip
```

Cumulative, bytes:

| Step | hello | tcp |
|---|---:|---:|
| `default` | 434976 | 456416 |
| profile: opt-level z, fat LTO, 1 codegen unit, panic=abort, strip | 285920 | 286416 |
| `RUSTC_BOOTSTRAP=1 -Zbuild-std=std,panic_abort`, `optimize_for_size` | 86112 | 103168 |
| `-Cpanic=immediate-abort -Zlocation-detail=none -Zfmt-debug=none` | 52144 | 69200 |
| `compiler-builtins-mem` | 52016 | 69072 |
| ld `-no_data_const` (one data segment instead of `__DATA_CONST` + `__DATA`) | 35488 | 52544 |
| ld `-rename_section __TEXT __const __DATA __const` (tcp's `__TEXT` fits in one page) | 35488 | 36032 |
| ld `-bind_at_load` (no lazy stubs), `-no_fixup_chains` | 35296 | 35792 |
| `macho_pack.py --strip`, bind opcodes copied | 33577 | 33689 |
| bind opcodes re-encoded | 33561 | 33673 |

`-no_data_const` and `-rename_section` each save a whole 16 KiB page. The last three steps work
on `__LINKEDIT`. ld already picks classic bind opcodes for rustc's deployment target (macOS
11.0), so `-no_fixup_chains` changes no byte today: it pins the format. What is left: one
`__TEXT` page, one `__DATA` page (std's statics, the GOT, thread-local data), and
`__LINKEDIT`. In hello, `__LINKEDIT` is 793 bytes: 15 bytes of rebase opcodes, 596 bytes of
bind opcodes for 33 libSystem symbols in 36 slots (std's runtime: locks, thread-local storage,
the stack overflow handler, `write`), alignment, and the 169-byte signature. tcp: 26 + 701
bytes of opcodes for 43 symbols in 46 slots, 905 bytes in all.

`macho_pack.py --strip` keeps every segment byte for byte and the normal layout. It rebuilds
`__LINKEDIT` with only the fixup opcodes and a new ad-hoc signature (16 KiB hash pages instead
of ld's 4 KiB, empty identifier, truncated SHA-256), and drops the symbol table and the export
trie. It also re-encodes the bind opcodes. ld sorts the binds by name, so after `___error` and
`__tlv_atexit` (both in the GOT) it jumps back 0x70 bytes in hello (0x80 in tcp) to the four
`__tlv_bootstrap` slots of the thread-local descriptors, with an 11-byte `ADD_ADDR_ULEB`, then
forward again. The tool groups the binds by symbol, orders the groups by address, folds each
forward gap into the bind opcode, and turns the four `__tlv_bootstrap` slots into one
`DO_BIND_ULEB_TIMES_SKIPPING_ULEB`: 610 bytes of opcodes become 596 in hello, 715 become 701
in tcp, 16 bytes of file each after the signature's 16-byte alignment. It decodes the new
stream, checks it binds the same slots to the same symbols, and keeps ld's stream when it is
not longer. The result passes `codesign --verify --strict` (the build checks it) and
`dyld_info` reports no error.

Without this tool, the best plain result is 35008 / 35456 bytes (ld's `-x
-exported_symbols_list /dev/null -no_function_starts -no_data_in_code_info`, 35120 / 35568,
then `codesign -s - -f -i x`; a plain `codesign -s - -f` writes an identifier like
`hello-<40 hex digits>` and gives 35056 / 35504). The tool is generic: it also shrinks the C, V
and asm `default` and `optimized` binaries and the Go `default` ones of this repo, `dyld_info
-fixups` lists the same fixups before and after, and they still pass `check.py`.

With the strip step, `-fixup_chains` is 112 / 128 bytes bigger than classic bind opcodes
(33673 / 33801), and lazy binding (no `-bind_at_load`) 176 / 224 bytes bigger (33737 / 33897),
so `-no_fixup_chains -bind_at_load` stays. The bind re-encoding only helps the classic binds
bound at load: lazy binds and chained fixups come out the same.

Not taken, because `optimized` should not lean on loader leniency: `LC_CODE_SIGNATURE`
pointing at a bare CodeDirectory with no SuperBlob (33541 / 33653, the kernel enforces its
hashes but `codesign` calls the format unsupported). It passes `check.py`. Dropping the 8-byte
alignment between the rebase and bind streams now saves nothing (the signature's 16-byte
alignment takes it back), and `dyld_info` warns "mis-aligned LINKEDIT content".
`-Zon-broken-pipe=inherit` drops std's `signal(SIGPIPE, SIG_IGN)` and the `_signal` import
(33545 / 33673), but then a broken stderr pipe kills tcp with `SIGPIPE`.

## extreme

`darwin/extreme/`: one `#![no_std] #![no_main]` crate, no allocator, no runtime. Argv
parsing, the dotted-quad and port parsing, the copy loop and the error checks are Rust. The
only inline asm is in `sys.rs`: `svc #0x80` (number in x16, arguments in x0 to x2) and a
`cset` that turns the carry flag into a value. Rust then returns `-errno` when the carry is
set, so a reset in the middle of the reply makes `read` return a negative value and tcp exits
with status 1. The block declares `clobber_abi("C")`: the compiler treats `svc` like a call to
libSystem's wrapper and keeps nothing in x0 to x17, lr or a vector register across it, because
nothing documents which registers the kernel restores. Rust's model clobbers v8 to v15 in full
(the C ABI keeps their low halves), so each function with a syscall saves d8 to d15. That costs
code, not file bytes: hello goes from 33 to 52 instructions, tcp from 169 to 178.

`main` is the `LC_MAIN` entry: dyld calls it as `main(argc, argv)`, so argv arrives in
registers. The read buffer is `MaybeUninit` on the stack, otherwise the compiler calls
`bzero`, an import. Built with stable 1.99.1 and the crate's profile (opt-level z, LTO, one
codegen unit, panic=abort, strip), linked with `-lSystem -Wl,-no_fixup_chains
-Wl,-bind_at_load`. rustc links with `-nodefaultlibs`, and ld refuses a dynamic executable
without libSystem. The image imports nothing, so there is no GOT and no writable segment.

| Step | hello | tcp |
|---|---:|---:|
| `optimized` | 33561 | 33673 |
| no_std, raw syscalls (ld output: one `__TEXT` page and `__LINKEDIT`) | 16784 | 16784 |
| `macho_pack.py`: `__LINKEDIT` emptied, signature in the last bytes of the page | 16384 | 16384 |

The 16384 bytes of hello: header (32), 13 load commands (728), 80 zeros where ld's dropped
commands were (the code does not move), `__text` at 840 (208 bytes, 52 instructions),
`Hello, World!\n` at 1048, zeros up to 16240, then the signature: 132 bytes (SuperBlob 20,
CodeDirectory 112) and 12 bytes of alignment that belong to it. tcp: 888 bytes of commands,
712 bytes of code (178 instructions) at 1000, `hello\n`, 112 bytes of unwind info and 80 of
`__eh_frame`, the same signature at 16240.

16384 is the floor for every language here: the kernel reads `round_page(32 + sizeofcmds)`
bytes of header in one go, and refuses a shorter file (see `asm/darwin/README.md` for the
measurements). Static executables are refused on arm64 release kernels, so dyld and libSystem
are always there.

## extreme-strict

The `extreme` linker output, through `macho_pack.py --strip`: the normal layout, the `__TEXT`
page hashed in full, and the signature in `__LINKEDIT` at 16384, as ld lays it out. 132 bytes:
SuperBlob (20) and a CodeDirectory padded to 112 bytes (header 88, empty identifier 1, 3 zeros,
one 20-byte hash). All the packed binaries pass `codesign --verify --strict` (the build checks
it). What sets this one apart: `dyld_info` reports no error (it calls the folded ones "LINKEDIT
overlap of unknown and unknown"), and no page is partly hashed. It is the fallback if Apple
stops running partly hashed pages (see below).

| Step | hello | tcp |
|---|---:|---:|
| ld output | 16784 | 16784 |
| `macho_pack.py --strip`: `__LINKEDIT` holds only the signature | 16516 | 16516 |

## extreme-ffi

`darwin/extreme-ffi/`: the same Rust logic, but the OS is reached through libSystem with
`extern "C"`, no inline asm. Each import is a GOT slot that dyld binds at load. With
`-no_fixup_chains -bind_at_load` the GOT has no file content, `macho_pack.py` makes its
segment zero-fill (and the `__got` section `S_ZEROFILL` at file offset 0, so Apple's tools
do not see it overlap the bind opcodes), and an import costs only its bind opcodes after the
page, which hold its name. So hello imports only `puts` (main returns 0 into libdyld's `exit`,
which flushes stdio), and tcp sends `socket`, `connect`, `read` and `write` through one function,
`syscall(2)` (deprecated, see "Relies on" item 4), with all seven of its argument slots set:
one name costs 27 bytes of opcodes less than the four. `syscall` returns -1 on failure, so a
reset in the middle of the reply exits 1.

| Step | hello | tcp |
|---|---:|---:|
| ld output (`__TEXT` page, `__DATA_CONST` page for the GOT, `__LINKEDIT`) | 33344 | 33344 |
| `macho_pack.py`, ld's bind opcodes (12 / 15 bytes; re-encoding finds nothing shorter) | 16396 | 16399 |
| without `BIND_OPCODE_SET_TYPE_IMM(POINTER)` (11 / 14 bytes) | 16395 | 16398 |

hello's opcodes: set dylib ordinal 1, set symbol `_puts`, set segment 2 offset 0, bind.
Putting them in the page itself fails (dyld: "Assertion failed: (range.fileOffset >=
_linkeditFileOffset)"), and so does mapping `__LINKEDIT` from file offset 0 over the whole
file (SIGKILL), so 16384 plus the opcodes is the floor for a binary that imports anything.

## Relies on

Undocumented behaviour each variant depends on. All of it is deterministic: 600 runs of the
ten binaries (8 rounds of an empty environment, the normal one, an 800 KB variable, 5000
variables, and a 100 KB `argv[0]`; tcp against a normal and a resetting server): all passed.

`default`, `optimized`: nothing. `optimized` uses the truncated SHA-256 hash type
(`CS_HASHTYPE_SHA256_TRUNCATED` in xnu's `cs_blobs.h`, shown as `sha256T` by `codesign`),
which `codesign` reads but never writes itself.

`extreme`, `extreme-ffi`:

1. **The signature is inside the executable `__TEXT` page.** `LC_CODE_SIGNATURE` points into
   `__TEXT`, not `__LINKEDIT`, and `codeLimit` is the signature's offset (16240), so the last
   page hash covers a partial page. The kernel, or the Apple Silicon code signing monitor,
   accepts that for an executable page. Every byte before the signature is hashed: flipping
   any of them (code, load commands or zero padding) gets SIGKILL. Flipping one of the 12
   alignment bytes after the blob still runs.
2. **dyld skips its `__LINKEDIT` layout check for the main executable.** `xcrun dyld_info`
   reports "LINKEDIT overlap of unknown and unknown" for these files (the signature is outside
   `__LINKEDIT`), yet dyld launches them. In `extreme` (no imports), `__LINKEDIT` is also
   empty: vmsize 0, filesize 0, at file offset 16384, the end of the file. dyld accepts that.
3. **Raw system call numbers and the carry flag** (`extreme`, and the numbers in
   `tcp-extreme-ffi`). Apple supports only libSystem as the system call interface. The numbers
   and the convention have not changed in decades. The asm treats `svc` like a C call, so it
   relies only on the kernel keeping x19 to x29 and sp, which a C callee keeps too and
   libSystem's own wrappers rely on.

`extreme-ffi` also relies on:

4. **`syscall(2)`** (tcp only). tcp reaches `socket`, `connect`, `read` and `write` through
   libSystem's `syscall(2)` with the raw numbers 97, 98, 3 and 4 (item 3). The SDK marks it
   deprecated since 10.12 ("syscall(2) is unsupported"), but libSystem still exports it. The
   `int` arguments travel in 64-bit variadic slots, and the kernel reads their low 32 bits.
   libSystem's arm64 `syscall` loads seven variadic stack slots into x1 to x7 whatever the
   call, and the kernel copies only as many arguments as the call takes (`sy_narg` in xnu's
   `sysent`). tcp passes all seven (the last four are zero), so no stale stack word reaches a
   register even if it is never read.
5. **Unsigned bind opcodes.** They sit in `__LINKEDIT` after the page, past `codeLimit`, so no
   hash covers them, and dyld uses them anyway (presumably the kernel insists only on signed
   executable pages). The imported names can be changed without breaking the signature:
   rewriting `_puts` as `_gets` still passes `codesign -v` and calls `gets`. A normal binary
   hashes `__LINKEDIT` too.
6. **A bind with no type.** Without `BIND_OPCODE_SET_TYPE_IMM`, dyld binds the slot as a
   pointer, the only type an arm64 binary uses.
7. **A GOT typed as zero-fill.** After folding, `__got` is `S_ZEROFILL` at file offset 0,
   not `S_NON_LAZY_SYMBOL_POINTERS`. dyld binds by segment and offset from the opcodes and
   accepts it. With ld's type kept, `strings -a` and `dyld_info` call the file malformed (a
   non-zero-fill section at offset 0, or one overlapping the bind opcodes).

`extreme-strict` relies only on 3. `tcp-extreme-ffi` relies on 3 and 4 because of
`syscall(2)`; `hello-extreme-ffi` calls `puts` and relies on neither.

Also measured for the signature: a CodeDirectory shorter than 112 bytes is killed (111 is
killed, 112 runs), and the plain SHA-256 type cut to 20 bytes is killed. Hence the truncated
type and the 3 bytes of padding.

## macho_pack.py

A generic post-link tool for arm64 executables, used by every variant but `default`. It reads
all offsets from the file and contains no bytes of any program. Both modes keep every segment
byte where the linker put it, keep only the fixups (dyld info opcodes or chained fixups,
trailing `DONE` padding cut) from `__LINKEDIT`, empty `LC_SYMTAB` and
`LC_DYSYMTAB`, drop the export trie, function starts and data in code, and write a new ad-hoc
signature: a SuperBlob with one CodeDirectory (version 0x20400, `CS_EXECSEG_MAIN_BINARY`,
truncated SHA-256, 16 KiB hash pages, empty identifier, at least 112 bytes). It writes a new
inode, since the kernel caches a signature per vnode. Fixups are copied as they are, except
the classic (non-lazy) bind opcodes: the tool decodes them the way dyld runs them and writes
them again, each symbol named once, groups in address order, forward gaps folded into the bind
opcodes, constant-stride runs as `DO_BIND_ULEB_TIMES_SKIPPING_ULEB`. It decodes its own output,
fails if it does not bind the same slots to the same symbols, and keeps the linker's stream
when that is not longer, or when it holds threaded binds, a slot bound twice or opcodes after
a `DONE`.

- `--strip`: normal layout, `__LINKEDIT` at its page-aligned offset with the fixups and the
  signature. Any arm64 executable with dyld info or chained fixups.
- default (fold): the image's only file content must be `__TEXT`. All-zero segments (a GOT
  bound at load, bss) become zero-fill, and their regular or non-lazy pointer sections
  `S_ZEROFILL` at offset 0. Imports must be classic dyld info, the signature goes in the last
  bytes of the last `__TEXT` page, and the bind opcodes (if any) follow the page in
  `__LINKEDIT`. It drops `BIND_OPCODE_SET_TYPE_IMM` when every bind is a pointer.

It refuses, with a non-zero exit, what it cannot handle: not a thin arm64 `MH_EXECUTE`, an
unknown load command, classic relocations, imports without dyld info or chained fixups,
`__LINKEDIT` not last, and in fold mode chained fixups with content, non-zero data outside
`__TEXT`, another section type outside `__TEXT` (thread-local variables, initializers, ...),
or a result that overflows `__TEXT`.

## Tried and dropped

- Fixing the broken-stderr case with flags instead of the source (before `rust/std` switched
  to `writeln!`, measured with the earlier nightly-2026-10-20 build): `panic=unwind` in
  `optimized` (build-std with the `panic-unwind` feature) exits 101 like `default`, but costs
  33208 / 49596 bytes (66833 / 83349). `-Cpanic=abort` without immediate-abort dies of
  `SIGABRT` (tcp 66705 bytes).
- `optimized` built by `nightly-2026-10-20` (which has the unstable options without
  `RUSTC_BOOTSTRAP`), as this variant was before: with the same flags, before
  `compiler-builtins-mem` and the bind re-encoding, 33625 / 33753 bytes where 1.99.1 gives
  33609 / 33721. It also switched compiler release between `default` and `optimized`.
- A static Mach-O (`LC_UNIXTHREAD`, no dyld): SIGKILL. xnu refuses an `MH_EXECUTE` without
  `MH_DYLDLINK` on arm64 release kernels.
- The signature right after the code (the previous layout): same 16384 bytes, but most of
  the executable page was not hashed. At the end of the page, only the signature is left out.
- Chained fixups in `optimized`: 112 / 128 bytes more after the strip (above).
- `-no_fixup_chains` without `-bind_at_load`: lazy stubs, a stub helper and lazy pointers
  with content in `__DATA`. tcp-extreme-ffi links to 49936 bytes and cannot be folded.
- `read`, `write`, `socket`, `connect` imported by name in tcp-extreme-ffi: 27 bytes more
  than `syscall`.
- `-no_uuid`: dyld refuses the binary ("missing LC_UUID load command").
- In `optimized`, `-dead_strip` (rustc passes it already), `-x`, `-exported_symbols_list
  /dev/null`, `-no_function_starts` and `-no_data_in_code_info` change nothing once
  `macho_pack.py --strip` drops those tables.
- Measured by the reviewer, for `extreme-ffi`: dropping `BIND_OPCODE_SET_DYLIB_ORDINAL_IMM`
  with `MH_TWOLEVEL` cleared fails (dyld: "Symbol not found: _puts"), and moving the GOT
  segment to index 0 to drop `SET_SEGMENT_AND_OFFSET_ULEB` fails (dyld: "segment
  '__PAGEZERO' vm address out of order"). So 16395 / 16398 is the floor of this approach.

Not tried: an `extreme-ffi` with no imports at all, finding `puts` at run time by walking from
dyld's return address to libSystem's export trie. It would be 16384 bytes, but it is a
hand-written dynamic linker, not FFI.
