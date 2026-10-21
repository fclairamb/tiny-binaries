# Rust on darwin-arm64

Built by `rust/build-darwin.sh` on macOS 27.0.1 (Apple Silicon, 16 KiB pages). Every size is a
binary that passed `scripts/check.py`, and two builds from scratch give the same bytes.

| Variant | hello | tcp | What it is |
|---|---:|---:|---|
| `default` | 434976 | 456416 | `cargo build --release` of the idiomatic source (`darwin/std`) |
| `optimized` | 33625 | 33753 | same source, compiler and linker flags, then `macho_pack.py --strip` |
| `extreme` | 16384 | 16384 | `no_std`, raw system calls, folded into one page by `macho_pack.py` |
| `extreme-strict` | 16516 | 16516 | the same linker output in the normal layout (`macho_pack.py --strip`) |
| `extreme-ffi` | 16395 | 16398 | `no_std`, libSystem calls through FFI, folded like `extreme` |

`variants.json` here describes these variants, for `rust/variants.json` (which SPEC asks for and
which belongs to no single platform).

## Toolchains and network

- rustup, from Homebrew. It is keg-only, so the script prepends `/opt/homebrew/opt/rustup/bin`
  to `PATH`. Two pinned toolchains: `1.99.1` (stable) for `default`, `extreme`,
  `extreme-strict` and `extreme-ffi`, and `nightly-2026-10-20` for `optimized` only. rustup
  downloads a missing pinned toolchain by itself (network), but its auto-install leaves out
  `rust-src`, which `-Zbuild-std` needs. So the script runs `rustup component add rust-src
  --toolchain nightly-2026-10-20`, which does nothing, offline, when it is there.
- Cargo always runs `--offline --locked`. `-Zbuild-std` would fetch std's own crates (`cfg-if`,
  `hashbrown`, `libc`, ...) from crates.io, but `rust-src` ships them in `library/vendor`.
  Cargo reads that directory only when run from `library/`, so the script points crates.io at
  it. A build with a fresh `CARGO_HOME` and `TMPDIR` gives the same bytes.
- `python3`, `codesign` and `ld` from the Xcode command line tools.
- Cargo target dirs go under `$TMPDIR/tiny-binaries/darwin-arm64/rust`.

## default

`cargo +1.99.1 build --release`: `println!`, `TcpStream`, `io::copy`, the full std runtime with
unwinding.

`darwin/std` is `rust/std` with one line changed: tcp's `fail()` writes its message with
`let _ = writeln!(io::stderr(), ...)` instead of `eprintln!`. Rust ignores `SIGPIPE`, so a write
to a stderr pipe whose reader is gone fails with `EPIPE`, and `eprintln!` panics on a failed
write. The spec still wants exit 1 to 125 there. With the shared file, `default` exits 101 (the
panic unwinds) and `optimized` dies of `SIGTRAP` (an immediate-abort panic is a `brk`). With
the fix, every variant exits 1. hello is the shared file. `darwin/std` can go once `rust/std`
has the same fix.

## optimized

Same source as `default`. `optimized` also switches compiler release: only nightly has
`-Zbuild-std` and `-Cpanic=immediate-abort`, so it builds with the pinned `nightly-2026-10-20`
instead of `1.99.1`, and rebuilds std with other features (`optimize_for_size`, no default
features). That reads "compiler flags" broadly: the program source is the same, std's build
is not the shipped one. The ladder below shows the switch alone (same flags, other compiler):
tcp crosses a page boundary and gets 16 KiB bigger before build-std wins it back. With stable
1.99.1 only (the profile, the same linker flags, `macho_pack.py --strip`), the best is
263873 / 280389 bytes.

```
cargo +nightly-2026-10-20 build --release --target aarch64-apple-darwin
  -Zbuild-std=std,panic_abort -Zbuild-std-features=optimize_for_size
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
| profile: opt-level z, fat LTO, 1 codegen unit, panic=abort, strip (1.99.1) | 285920 | 286416 |
| same profile, built by nightly-2026-10-20 | 285952 | 302960 |
| `-Zbuild-std=std,panic_abort`, `optimize_for_size` | 86096 | 103152 |
| `-Cpanic=immediate-abort -Zlocation-detail=none -Zfmt-debug=none` | 52144 | 69264 |
| ld `-no_data_const` (one data segment instead of `__DATA_CONST` + `__DATA`) | 35632 | 52736 |
| ld `-rename_section __TEXT __const __DATA __const` (tcp's `__TEXT` fits in one page) | 35632 | 36224 |
| ld `-bind_at_load` (no lazy stubs), `-no_fixup_chains` | 35424 | 35968 |
| `macho_pack.py --strip` | 33625 | 33753 |

`-no_data_const` and `-rename_section` each save a whole 16 KiB page. The last two steps work
on `__LINKEDIT`. ld already picks classic bind opcodes for rustc's deployment target (macOS
11.0), so `-no_fixup_chains` changes no byte today: it pins the format. What is left: one
`__TEXT` page, one `__DATA` page (std's statics, the GOT, thread-local data), and
`__LINKEDIT`. In hello, `__LINKEDIT` is 857 bytes: 17 bytes of rebase
opcodes, 653 bytes of bind opcodes for 36 libSystem symbols (std's runtime: locks,
thread-local storage, the stack overflow handler, `write`), alignment, and the 169-byte
signature. tcp: 28 + 769 bytes of opcodes for 47 symbols, 985 bytes in all.

`macho_pack.py --strip` keeps every segment byte for byte and the normal layout. It rebuilds
`__LINKEDIT` with only the fixup opcodes and a new ad-hoc signature (16 KiB hash pages instead
of ld's 4 KiB, empty identifier, truncated SHA-256), and drops the symbol table and the export
trie. The result passes `codesign --verify --strict` (the build checks it) and `dyld_info`
reports no error. Without this tool, the best plain result is 35168 / 35648 bytes (ld's
`-x -exported_symbols_list /dev/null -no_function_starts -no_data_in_code_info`, 35264 /
35744, then `codesign -s - -i x`; a plain `codesign -s -` writes an identifier like
`hello-<40 hex digits>` and gives 35216 / 35696). The tool is generic: it also shrinks the C,
Go, V and asm `default` binaries of this repo, which still pass `check.py`.

With the strip step, `-fixup_chains` is 112 bytes bigger than classic bind opcodes (33737 /
33865), and lazy binding (no `-bind_at_load`) 160 / 208 bytes bigger (33785 / 33961), so
`-no_fixup_chains -bind_at_load` stays.

Not taken, because `optimized` should not lean on loader leniency: no 8-byte alignment
between the rebase and bind streams (33609 / 33737, `dyld_info` then warns "mis-aligned
LINKEDIT content"), and `LC_CODE_SIGNATURE` pointing at a bare CodeDirectory with no SuperBlob
(33605 / 33733, the kernel enforces its hashes but `codesign` calls the file unsigned). Both
pass `check.py`. `-Zon-broken-pipe=inherit` drops std's `signal(SIGPIPE, SIG_IGN)` and the
`_signal` import (33609 / 33737), but then a broken stderr pipe kills tcp with `SIGPIPE`.

## extreme

`darwin/extreme/`: one `#![no_std] #![no_main]` crate, no allocator, no runtime. Argv
parsing, the dotted-quad and port parsing, the copy loop and the error checks are Rust. The
only inline asm is in `sys.rs`: `svc #0x80` (number in x16, arguments in x0 to x2) and a
`cset` that turns the carry flag into a value. Rust then returns `-errno` when the carry is
set, so a reset in the middle of the reply makes `read` return a negative value and tcp exits
with status 1. x0 and x1 are both outputs (the kernel writes x1), so the compiler never
assumes a pointer in x1 survives the call.

`main` is the `LC_MAIN` entry: dyld calls it as `main(argc, argv)`, so argv arrives in
registers. The read buffer is `MaybeUninit` on the stack, otherwise the compiler calls
`bzero`, an import. Built with stable 1.99.1 and the crate's profile (opt-level z, LTO, one
codegen unit, panic=abort, strip), linked with `-lSystem -Wl,-no_fixup_chains
-Wl,-bind_at_load`. rustc links with `-nodefaultlibs`, and ld refuses a dynamic executable
without libSystem. The image imports nothing, so there is no GOT and no writable segment.

| Step | hello | tcp |
|---|---:|---:|
| `optimized` | 33625 | 33753 |
| no_std, raw syscalls (ld output: one `__TEXT` page and `__LINKEDIT`) | 16784 | 16784 |
| `macho_pack.py`: `__LINKEDIT` emptied, signature in the last bytes of the page | 16384 | 16384 |

The 16384 bytes of hello: header (32), 13 load commands (728), 80 zeros where ld's dropped
commands were (the code does not move), `__text` at 840 (132 bytes, 33 instructions),
`Hello, World!\n` at 972, zeros up to 16240, then the signature: 132 bytes (SuperBlob 20,
CodeDirectory 112) and 12 bytes of alignment that belong to it. tcp: 808 bytes of commands,
676 bytes of code (169 instructions) at 920, `hello\n`, 104 bytes of unwind info, the same
signature at 16240.

16384 is the floor for every language here: the kernel reads `round_page(32 + sizeofcmds)`
bytes of header in one go, and refuses a shorter file (see `asm/darwin/README.md` for the
measurements). Static executables are refused on arm64 release kernels, so dyld and libSystem
are always there.

## extreme-strict

The `extreme` linker output, through `macho_pack.py --strip`: the `__TEXT` page is hashed in
full and the signature sits in `__LINKEDIT` at 16384, as ld lays it out. 132 bytes: SuperBlob
(20) and a CodeDirectory padded to 112 bytes (header 88, empty identifier 1, 3 zeros, one
20-byte hash). It passes `codesign --verify --strict` and `dyld_info`. It is the fallback if
Apple stops running partly hashed pages (see below).

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
`syscall(2)`: one name costs 27 bytes of opcodes less than the four. `syscall` returns -1 on
failure, so a reset in the middle of the reply exits 1.

| Step | hello | tcp |
|---|---:|---:|
| ld output (`__TEXT` page, `__DATA_CONST` page for the GOT, `__LINKEDIT`) | 33344 | 33344 |
| `macho_pack.py`, bind opcodes copied as they are (12 / 15 bytes) | 16396 | 16399 |
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
   `__LINKEDIT`), yet dyld launches them.
3. **Raw system call numbers and the carry flag** (`extreme` only). Apple supports only
   libSystem as the system call interface. The numbers and the convention have not changed in
   decades.

`extreme-ffi` also relies on:

4. **Unsigned bind opcodes.** They sit in `__LINKEDIT` after the page, past `codeLimit`, so no
   hash covers them, and dyld uses them anyway (presumably the kernel insists only on signed
   executable pages). The imported names can be changed without breaking the signature:
   rewriting `_puts` as `_gets` still passes `codesign -v` and calls `gets`. A normal binary
   hashes `__LINKEDIT` too.
5. **A bind with no type.** Without `BIND_OPCODE_SET_TYPE_IMM`, dyld binds the slot as a
   pointer, the only type an arm64 binary uses.
6. **A GOT typed as zero-fill.** After folding, `__got` is `S_ZEROFILL` at file offset 0,
   not `S_NON_LAZY_SYMBOL_POINTERS`. dyld binds by segment and offset from the opcodes and
   accepts it. With ld's type kept, `strings -a` and `dyld_info` call the file malformed (a
   non-zero-fill section at offset 0, or one overlapping the bind opcodes).

`extreme-strict` relies only on 3.

Also measured for the signature: a CodeDirectory shorter than 112 bytes is killed (111 is
killed, 112 runs), and the plain SHA-256 type cut to 20 bytes is killed. Hence the truncated
type and the 3 bytes of padding.

## macho_pack.py

A generic post-link tool for arm64 executables, used by every variant but `default`. It reads
all offsets from the file and contains no bytes of any program. Both modes keep every segment
byte where the linker put it, keep only the fixups (dyld info opcodes or chained fixups,
copied verbatim, trailing `DONE` padding cut) from `__LINKEDIT`, empty `LC_SYMTAB` and
`LC_DYSYMTAB`, drop the export trie, function starts and data in code, and write a new ad-hoc
signature: a SuperBlob with one CodeDirectory (version 0x20400, `CS_EXECSEG_MAIN_BINARY`,
truncated SHA-256, 16 KiB hash pages, empty identifier, at least 112 bytes). It writes a new
inode, since the kernel caches a signature per vnode.

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

- Keeping `rust/std`'s `eprintln!` and fixing the broken-stderr case with flags only:
  `panic=unwind` in `optimized` (build-std with the `panic-unwind` feature) exits 101 like
  `default`, but costs 33208 / 49596 bytes (66833 / 83349). `-Cpanic=abort` without
  immediate-abort dies of `SIGABRT` (tcp 66705 bytes).
- A static Mach-O (`LC_UNIXTHREAD`, no dyld): SIGKILL. xnu refuses an `MH_EXECUTE` without
  `MH_DYLDLINK` on arm64 release kernels.
- The signature right after the code (the previous layout): same 16384 bytes, but most of
  the executable page was not hashed. At the end of the page, only the signature is left out.
- Chained fixups in `optimized`: 112 bytes more after the strip (above).
- `-no_fixup_chains` without `-bind_at_load`: lazy stubs, a stub helper and lazy pointers
  with content in `__DATA`. tcp-extreme-ffi links to 49936 bytes and cannot be folded.
- `read`, `write`, `socket`, `connect` imported by name in tcp-extreme-ffi: 27 bytes more
  than `syscall`.
- `-no_uuid`: dyld refuses the binary ("missing LC_UUID load command").
- In `optimized`, `-dead_strip` (rustc passes it already), `-x`, `-exported_symbols_list
  /dev/null`, `-no_function_starts` and `-no_data_in_code_info` change nothing once
  `macho_pack.py --strip` drops those tables.

Not tried: an `extreme-ffi` with no imports at all, finding `puts` at run time by walking from
dyld's return address to libSystem's export trie. It would be 16384 bytes, but it is a
hand-written dynamic linker, not FFI.
