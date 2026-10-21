# Rust on Linux (arm64, amd64)

Smallest Rust binaries for `hello` and `tcp` on `linux-arm64` and `linux-amd64`.
Built by `rust/build-linux.sh` (dispatched from `rust/build.sh` on Linux). Three
variants per program (`variants.json`), plus the tools in this directory.

## Results (bytes, all PASS on run.sh and, for amd64, on the real-kernel VM)

| variant   | hello arm64 | tcp arm64 | hello amd64 | tcp amd64 |
|-----------|------------:|----------:|------------:|----------:|
| default   |     468872  |   473512  |     444768  |   458736  |
| optimized |      10648  |    18848  |        9872 |    17432  |
| extreme   |        124  |      264  |        123  |      234  |

## Toolchains, network, caches

- `default` uses the image's `stable`, which the Dockerfile does not pin. The sizes
  above are for rustc 1.99.1 (58cf8f9c3 2026-10-13); the script warns when `stable`
  is another version. `optimized` and `extreme` use the pinned `nightly-2026-10-20`.
- No network. `-Zbuild-std` resolves the standard library's own dependencies (libc,
  hashbrown, addr2line, ...) from crates.io. rust-src ships those crates in
  `library/vendor`, but cargo only uses them when it runs from inside `library/`. The
  script passes `--offline` and points crates.io at that directory with
  `--config source.crates-io.replace-with`. Our crates have no dependencies, so the
  replacement only touches the sysroot. A fresh `/cache` volume under
  `docker run --network none`, with `/src` mounted read-only, builds every variant
  byte-identical to a warm build, in 1 min 38 s (arm64) and 2 min 14 s (amd64 under
  Rosetta).
- Cargo does not track linker scripts. `extreme/build.rs` passes `-T holes.ld` and prints
  `rerun-if-changed=holes.ld`, so an edit to it relinks on a warm `/cache`.

## The source: `std/`, a fork of `rust/std`

`default` and `optimized` build `std/`, which is the shared `rust/std` with one line changed
in tcp's `fail()`: `let _ = writeln!(io::stderr(), ...)` instead of `eprintln!`. hello is the
shared file (`std/Cargo.toml` points at it). `rust/darwin/std` is the same fork, byte for byte.

`eprintln!` panics when the write to stderr fails. Rust ignores `SIGPIPE`, so stderr on a
pipe whose reader is gone gives `EPIPE`, and `/dev/full` gives `ENOSPC`. SPEC.md exempts only
stdout errors, so the required failure paths (no arguments, connection refused, reset) must
still exit 1 to 125. With the shared file, `default` exits 101 there (the panic unwinds) and
`optimized` dies of `SIGTRAP` on arm64 or `SIGILL` on amd64 (an immediate-abort panic is a
`brk` or `ud2`). With the fork, both exit 1. Delete `std/` once `rust/std` has the fix.

The flags-only alternative was measured and dropped: unwinding panics in `optimized`
(`-Zbuild-std=std,panic_unwind`, the `panic-unwind` feature, `.eh_frame_hdr` kept,
`-Zpanic-in-drop=abort`) also exits 101, but tcp grows from 18896 to 53112 bytes on arm64 and
from 17432 to 51896 on amd64: the panic message, hook and unwinder glue come back.
`-Cpanic=abort` without immediate-abort dies of `SIGABRT` (tcp 38208 bytes on arm64). LLVM's
`-trap-func` option is accepted by rustc but ignored.

## default

Plain `cargo build --release` of `std/`. Dynamically linked glibc (and `libgcc_s.so.1` for
the unwinder, which glibc itself loads for thread cancellation: Debian's libc6 depends on
libgcc-s1), full `std`, unwinding panics. The baseline.

## optimized

Same source, flags only. The win is rebuilding `std` from source for size:

- `-Zbuild-std=std,panic_abort -Zbuild-std-features=optimize_for_size` (nightly):
  `std` compiled with its size-optimized algorithms, not the distributed build.
- `-Cpanic=immediate-abort`: panic calls lower to a bare trap instruction, which drops
  all the formatting and backtrace machinery. With the fixed `fail()`, the tcp spec paths
  never panic, even with stderr unwritable. hello panics only when stdout cannot be
  written, which SPEC.md leaves unspecified.
- `-Zlocation-detail=none -Zfmt-debug=none`: no `file:line:col`, no `Debug` bodies.
- `opt-level=z`, `lto=true`, `codegen-units=1`, `panic=abort`, `strip=true`.
- `-Crelocation-model=static`, `-Cforce-unwind-tables=no`, `-Wl,--gc-sections`,
  `-Wl,-z,norelro`, `-Wl,--build-id=none`.
- aarch64 only: `-Ctarget-feature=-outline-atomics` removes the startup
  constructor that enables LSE atomics (a `.init_array` entry plus its code).
- lld: `-fuse-ld=lld` on aarch64 (x86_64 already links with rust-lld by default),
  then `--no-rosegment` (read-only data shares the R+X segment: 3 `PT_LOAD`s become
  2), `--icf=all` (identical functions folded) and `--no-eh-frame-hdr` (nothing
  unwinds under immediate-abort).
- `-Cllvm-args=-enable-machine-outliner=always`: repeated instruction sequences become
  shared functions.
- `sstrip` after the link removes the section headers.

Size ladder (hello / tcp, each step adds to the previous one, sizes after `sstrip`):

| step | arm64 | amd64 |
|---|--:|--:|
| link + strip, before sstrip | 12912 / 21304 | 12304 / 20040 |
| sstrip | 10868 / 19256 | 10080 / 17816 |
| `-fuse-ld=lld` (arm64 only) | 10856 / 19216 | |
| `--no-rosegment` | 10792 / 19152 | 10032 / 17768 |
| `--icf=all` | 10792 / 18976 | 10032 / 17544 |
| `--no-eh-frame-hdr` | 10664 / 18848 | 9936 / 17448 |
| machine outliner | 10648 / 18848 | 9872 / 17432 |

With every flag, the file before `sstrip` is 12728 / 20928 (arm64) and 12016 / 19576
(amd64). With the shared source, tcp is 18896 on arm64 (the fork saves 48 bytes) and the
same 17432 on amd64.

Dynamically linked glibc, like `default`, so it stays a fair "same program,
better flags" comparison. Linking system libc is allowed by SPEC.md. lld keeps the
64 KB segment alignment on arm64, so nothing depends on 4 KB pages.

## extreme

A separate `#![no_std] #![no_main]` crate (`extreme/`). No libc, no runtime. The
logic (argv reading, IPv4 and port parsing, the sockaddr, the copy loop, error
checks) is Rust; assembly is limited to the `svc`/`syscall` instruction and the entry
glue, as SPEC.md allows.

The layout is borrowed from the V slice: one `PT_LOAD` segment written from a 64 KB
boundary (0x400000, the usual base of a non-PIE executable), the ELF and program headers
overlapped and packed into the smallest form the loader accepts, and small pieces of the
program dropped into the header bytes the loader never reads. The code is built for
`<arch>-unknown-none` (so `core` is rebuilt from source and there is no glibc startup to
fight), with `relocation-model=static` so every address is absolute and `elfgolf.py` never
has to move one.

### The header holes

`elfgolf.py` (derived from `v/linux`, see below) writes a minimal ELF64 header over
the first bytes of the single segment. Some header fields are never read by the
Linux loader for a static `ET_EXEC`, so the linker script `holes.ld` drops program
pieces into them and they cost nothing:

- offset 40..53 (`e_shoff`, `e_flags`, `e_ehsize`): 14 bytes. Holds the 14-byte
  `"Hello, World!\n"` (hello). Only 40..47 is a hole in the `o48` layouts; 48..53 are
  program header fields there. tcp puts the entry glue (arm64, 8 bytes) or `die`, its
  `exit(-r)` (amd64, 7 bytes) in it.
- offset 72..79 or 80..87 (`p_paddr`): 8 bytes. The 6-byte `"hello\n"` request (tcp),
  a hello fragment (`h2` on arm64, `_start` on amd64).
- offset 4..15 (`e_ident[4..15]`, aarch64 only): 12 bytes. `_start` (hello) or
  `die` (tcp). The arm64 kernel checks only the 4-byte ELF magic of `e_ident`;
  Rosetta, which runs the amd64 tests on the Mac, rejects anything but the standard
  bytes there, so `elfgolf.py` uses this hole only when `e_machine` is `EM_AARCH64`.
- `p_align`: the "a" layouts start the code over it (Linux ignores it for `ET_EXEC`).

Left unused: `e_version` (20..23, 4 bytes, between two fields that are not holes, so
code there costs more in jumps than it saves; `elfgolf.py` writes `EV_CURRENT` there), the
2 bytes after `"hello\n"` and, in tcp amd64, 1 byte after `die`.

Layouts: hello uses `o56a` (104-byte header) because it needs the 14-byte string
hole at 40; `o48` only has an 8-byte hole there. tcp uses `o48a` (96-byte header).
Both are documented in `elfgolf.py`.

`holes.ld` gives the segment no `FLAGS`: lld then uses the union of the section flags,
R+X, or R+W+X when a program puts a `static mut` in it (tcp on arm64).

### hello: tail-called fragments

hello is split into small functions that tail-call each other (`become`, the
`explicit_tail_calls` nightly feature), so each one can live in a different header
hole: the message in one, `_start` in another. Each takes the registers the next
needs as plain `extern "C"` arguments, so a tail call is a lone branch and passing
a value along is free. They are `#[no_mangle]` and `#[inline(never)]` so LTO keeps
the fragments split instead of folding everything into the leaf. On aarch64 that is
three fragments (`_start` -> `h2` -> `h3`); on amd64 two, because a rel32 `jmp` is 5
bytes and only just fits the 8-byte hole next to the `push`/`pop` that sets the
length.

### tcp

- No argc check. One loop parses `argv[argc-1]` down to `argv[1]` (the port, then
  a.b.c.d), folding each number into a 64-bit `x = x << 8 | n` that starts at a value S
  with 0x02 in bits 16..23. After the five shifts of a well-formed call and a byte swap,
  x is exactly `sin_family = AF_INET`, the port and the address in network order. With
  no argument or one dotted quad (4 shifts), the family comes out as S's top bytes or as
  0x02nn, and `connect` fails with `EAFNOSUPPORT` (exit 97) without sending a packet. A
  zero family would be `AF_UNSPEC`, which `connect` accepts on a TCP socket, so the top
  bytes matter. S is one instruction: a sign-extended imm32 on amd64
  (0xffffffffff020000), a logical immediate on arm64 (0x0002000000020000). Idea from
  the V slice. Saved 9 bytes on amd64, 8 on arm64.
- Malformed calls, which SPEC.md leaves unspecified, can end badly. 6 or more numbers in
  all (extra arguments such as `tcp 127.0.0.1 8080 x`, or one argument like
  `1.2.3.4.5.6`) shift S's zero low bytes into the family: `AF_UNSPEC`, `connect`
  returns 0 and the first write dies of `SIGPIPE`, on both arches. A single argument
  with 1 to 3 numbers gets `EAFNOSUPPORT` on amd64, but on arm64 S's sparse bytes give
  `AF_INET` for 1 number (`tcp 8080` connects to 2.0.31.144 port 0: `ENETUNREACH`
  without a route, a SYN timeout of minutes with one) and `AF_UNSPEC` then `SIGPIPE`
  for 2 or 3 (`tcp 1.2`). No arm64 logical immediate has bits 0..15 zero, 0x02 in bits
  16..23 and no zero family for 1 to 3 shifts, so fixing those costs a second `mov`
  (4 bytes), and 6 numbers still could not be caught. Checked with strace.
- The `sockaddr_in` is stored over `argv[0]`, which is dead by then; `sin_zero` is
  `argv[1]`, not zero.
- One loop sends the request and copies the reply: the first `write` goes to the
  socket, the next ones to stdout. A read error (`-ECONNRESET` 104 when the server
  resets mid-reply) exits with `-n`; a clean EOF exits 0.
- The read count is the previous write length: 6 for the request, then the last read
  result. So each read asks for the smallest read result so far, at most 6 bytes, and
  down to 1 byte per read and write if the server ever delivers a single byte. Still
  correct (everything is copied in order until EOF or an error), and SPEC.md sets no
  speed. Measured with strace on arm64: check.py's 9911-byte reply takes 1983 reads
  and 1983 writes; a 1-byte chunk then 1 MB takes 1048578 of each (1.4 s on arm64).

amd64:

- The entry glue `pop rcx; mov r8, rsp` (argc in rcx, &argv[0] in r8: main's 4th and
  5th arguments) is in main's own section, emitted just before it, and falls through
  into main with no jump. That frees the `e_shoff` hole for `die` (`neg edi; push 60;
  pop rax; syscall`, 7 bytes): `mov edi, eax; call die` is 7 bytes, the inlined exit
  was 11. Same layout as the V slice. Saved 8 bytes.
- `-Zllvm-module-flag=override-stack-alignment:u32:8:override` (what clang's
  `-mstack-alignment=8` sets): without it LLVM pushes a register to align the stack
  for the call to `die`. The target has no SSE, so nothing needs 16 bytes. Saved 1.
- `sys3` declares r9 and r10 clobbered, which the kernel does not do. That only tells
  the compiler less, and it moves the socket fd and the constant 1 (stdout, and the
  write syscall number) from r9/r10 into ebx/ebp, whose moves need no REX prefix.
  Saved 5 (7, minus the two pushes that save ebx and ebp).
- The read buffer is the stack at `argv`: Rosetta write-protects the page that holds
  translated code, so a read into the header fails there with `EFAULT`.

arm64:

- `REQ` is a `static mut`, so the segment is R+W+X, and it is also the read buffer
  (reads are at most 6 bytes): the same pointer for every write and read. Saved 4.
- The glue `add x3, sp, 8; b main` (in the `e_shoff` hole) hands over &argv[0]; argc is
  `[x3, -8]`. With x3 = argv the loop index needs one register, not two. Saved 4.
- Digits are tested with one `tbz` on bit 4 (set on `'0'..'9'`, clear on `.` and NUL),
  and every error path branches to `die` in the `e_ident[4..15]` hole.

Size ladder for tcp (hello did not change):

| step | tcp arm64 | tcp amd64 |
|---|--:|--:|
| argc check, separate read buffer | 280 | 257 |
| arm64: REQ is the read buffer (R+W+X segment) | 276 | |
| no argc check, family from S | 268 | 248 |
| amd64: fall-through glue, `die` in `e_shoff` | | 240 |
| amd64: `override-stack-alignment` 8 | | 239 |
| amd64: r9/r10 clobbers | | 234 |
| arm64: x3 = argv | 264 | |

This round changed no code byte: the segment moved from 0x10000 to 0x400000 (same
sizes, see below) and `e_version` became 1.

The linked `.elf` (`strip=true`, before `elfgolf.py`) is 456 bytes for hello on both
arches, 600 (arm64) and 568 (amd64) for tcp: the ELF and program headers, the one
segment (packed right after them by `-n`, its first bytes left for elfgolf's header)
and the section headers. elfgolf keeps only the segment.

Flags: `-Cpanic=abort -Crelocation-model=static -Cforce-unwind-tables=no
-Ztrap-unreachable=no`, build-std=core, linked with `holes.ld`, `--build-id=none`,
`-n`, `--no-rosegment`, `-static`. amd64 adds `-Ccode-model=small` (the target
defaults to the kernel model: `mov esi, imm32` is 5 bytes, its sign-extended form 7),
`-Ztune-cpu=k8` (LLVM folds the digit math `c + cur*10 - 48` into one `lea`; same
x86-64 ISA), `-Cllvm-args=-disable-lsr` and the stack alignment flag. aarch64 adds
`-Ccode-model=tiny` (one `adr`, not `adrp`+`add`) and `-Cllvm-args=-disable-lsr`.

### Byte accounting

- hello amd64 (123): 104-byte `o56a` header (with the 14-byte message at 40 and the
  8-byte `_start` at 80 inside it) + 19 bytes of tail (`push 1; pop rax;
  mov esi,&msg; mov edi,eax; syscall; push 60; pop rax; xor edi,edi; syscall`).
- hello arm64 (124): 104-byte header (12-byte `_start` in the `e_ident` hole,
  message at 40, 8-byte `h2` at 80) + 20 bytes of tail (`h3`: the two syscalls).
- tcp amd64 (234): 96-byte `o48a` header (7-byte `die` at 40, `"hello\n"` at 72) +
  138 bytes: 4 of glue, then parse, sockaddr, socket, connect, the write/read loop.
- tcp arm64 (264): 96-byte header (12-byte `die` in the `e_ident` hole, 8-byte glue
  at 40, `"hello\n"` at 72) + 168 bytes of code.

### Behaviour these binaries rely on

- Linux ignores `e_ident[4..15]` on arm64 (binfmt_elf checks the magic, `e_type`,
  `e_machine`, `e_phentsize` and `e_phnum`), and `e_shoff`, `e_flags`, `e_ehsize`,
  `p_paddr` and `p_align` for a static `ET_EXEC`. Not documented as an ABI; it is how
  binfmt_elf reads the header. Rosetta accepts the fields the amd64 binaries use (all of
  these but `e_ident`, which they leave standard). `e_version` holds `EV_CURRENT` in
  every binary.
- `connect` does not check `sin_zero` (`tcp_v4_connect` checks only the length and
  `sin_family`). ip(7) does not document this. A family other than `AF_INET` or
  `AF_UNSPEC` fails with `EAFNOSUPPORT`, which connect(2) documents.
- argc >= 1: since Linux 5.18 the kernel turns an empty argv into one empty string
  (commit "exec: Force single empty string when argv is empty"). Checked with an empty
  argv on both arches: exit 97. On an older kernel an empty argv would crash tcp.
- arm64 tcp: the kernel maps an R+W+X segment as asked (Linux has no W^X rule for ELF
  segments, unless a security module adds one: SELinux `execmem` denied or PaX MPROTECT
  would refuse it).
- amd64 tcp: the glue falls through into main because LLVM emits module asm before the
  functions of the same section and does not align code at opt-level z. If that
  changed, the tests would fail, not pass by luck.
- The segment is at 0x400000. Until this round it was at 0x10000 (65536), which only
  maps when `vm.mmap_min_addr` is at most 65536: that is the usual distribution default
  on x86 (Debian, Ubuntu, Fedora), right at the limit, and the test environments have
  4096. 0x400000 is where ld puts non-PIE executables by default, far above any such
  setting, and the code is the same size: amd64 loads addresses with `mov esi, imm32`
  either way and arm64 uses pc-relative `adr`.

### Page sizes

The single segment starts on a 64 KB boundary (`p_offset` 0 or 1 under `o48a`), so
`p_vaddr - p_offset` is a multiple of 64 KB and it loads under 4 KB, 16 KB and
64 KB page kernels alike. `optimized` keeps lld's 64 KB segment alignment on arm64.
Nothing depends on 4 KB pages. Tested on 4 KB kernels (OrbStack arm64, Rosetta, the amd64
qemu VM), and all six arm64 binaries of this round pass under qemu-system-aarch64 with
Debian's 6.12 `arm64-16k` kernel (KernelPageSize 16 kB) and Ubuntu's 6.8 `generic-64k`
kernel (64 kB): a 1.5 MB reply as pipe and file, 3000 small chunks, an empty reply, a
reset after 800 KB, ports 1024 and 65535, 127.255.255.254 and 127.1.2.3, `env -i` and a
120 KB environment variable, 20 runs each.

## Generic tools in this directory

- `elfgolf.py`: rewrites a static one-`PT_LOAD` ELF64 into a minimal overlapped
  header, putting program bytes into loader-ignored fields. Derived from
  `v/linux/elfgolf.py` (the current one: `e_ident[4..15]` is a hole when `e_machine` is
  `EM_AARCH64`, and a hole the program leaves empty keeps the standard header bytes). One
  difference: it writes `e_version = EV_CURRENT`, where the V copy leaves 0. It takes the
  segment, entry and machine from the input and contains no bytes of any program.
- `extreme/holes.ld`: generic one-`PT_LOAD` linker script that places `.holeN`
  input sections at header offset N and the rest of the code at `CODE`
  (`elfgolf.py -H`). Nothing program specific.
