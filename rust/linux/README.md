# Rust on Linux (arm64, amd64)

Smallest Rust binaries for `hello` and `tcp` on `linux-arm64` and `linux-amd64`.
Built by `rust/build-linux.sh` (dispatched from `rust/build.sh` on Linux). Three
variants per program, plus the tools in this directory.

## Results (bytes, all PASS on run.sh and, for amd64, on the real-kernel VM)

| variant   | hello arm64 | tcp arm64 | hello amd64 | tcp amd64 |
|-----------|------------:|----------:|------------:|----------:|
| default   |     468872  |   473600  |     444768  |   459312  |
| optimized |      10868  |    19320  |      10080  |    17816  |
| extreme   |        174  |      626  |        165  |      589  |

## default

Plain `cargo build --release` of the shared idiomatic sources in `rust/std`.
Dynamically linked glibc, full `std`, unwinding panics. The baseline.

## optimized

Same sources, flags only. The win is rebuilding `std` from source for size:

- `-Zbuild-std=std,panic_abort -Zbuild-std-features=optimize_for_size` (nightly):
  `std` compiled with its size-optimized algorithms, not the distributed build.
- `-Cpanic=immediate-abort`: panic calls lower to a bare abort, which drops all
  the formatting and backtrace machinery. The spec paths never panic, so behaviour
  on them is unchanged; only the panic path differs.
- `-Zlocation-detail=none -Zfmt-debug=none`: no `file:line:col` strings, no
  `derive(Debug)` bodies.
- `opt-level=z`, `lto=true`, `codegen-units=1`, `panic=abort`, `strip=true`.
- `-Crelocation-model=static`, `-Cforce-unwind-tables=no`, `-Wl,--gc-sections`,
  `-Wl,-z,norelro`, `-Wl,--build-id=none`.
- aarch64 only: `-Ctarget-feature=-outline-atomics` removes the startup
  constructor that enables LSE atomics (a `.init_array` entry plus its code).
- `sstrip` after the link removes the section headers.

Size ladder (hello / tcp):

- arm64: link+strip 12912 / 21368, then sstrip 10868 / 19320.
- amd64: link+strip 12304 / 20040, then sstrip 10080 / 17816.

Dynamically linked glibc, like `default`, so it stays a fair "same program,
better flags" comparison. Linking system libc is allowed by SPEC.md.

## extreme

A separate `#![no_std] #![no_main]` crate (`extreme/`). No libc, no runtime. The
logic (argv reading off the stack, IPv4 and port parsing, the sockaddr, the copy
loop, error checks) is Rust; assembly is limited to the `svc`/`syscall`
instruction and the entry glue, as SPEC.md allows.

- `src/sc.rs`: raw syscalls via `core::arch::asm!` (aarch64 `svc #0`, x86_64
  `syscall`), an `entry!` macro whose `global_asm!` reads the stack pointer into
  the first argument register and jumps to `rust_main`, and a `#[panic_handler]`
  that exits. `exit` uses `options(noreturn)` so nothing (no trap, no self-branch)
  is emitted after it.
- `src/bin/hello.rs`, `src/bin/tcp.rs`: the two programs. `tcp` funnels every
  error through one cold `fail()` (exit 1), so there is a single exit epilogue
  instead of one per check. The read buffer and the sockaddr are built in
  `MaybeUninit`, so the compiler emits no `memset` (which would otherwise need a
  `compiler_builtins` symbol the `nostdlib` link does not provide). The sockaddr
  is two `u64` stores built with shifts, not a byte loop.
- `tiny.ld`: one `PT_LOAD` segment that includes the ELF header and program
  headers (`FILEHDR PHDRS`), mapped read+execute, base `0x10000`. All metadata
  sections (`.eh_frame`, `.note`, `.comment`, `.dynamic`, GOT, PLT, `.bss`, ...)
  are discarded. Built with stable Rust and the precompiled `core`, no build-std.
- `elfgolf.py`: generic header golf, run after `sstrip` (below).

Flags: `-Cpanic=abort`, `-Cforce-unwind-tables=no`, `-nostartfiles -nostdlib
-static`, `-fuse-ld=lld`, `-Wl,-T,tiny.ld`, `-Wl,--build-id=none`, `-Wl,-n`.
Relocation model is `static` on aarch64 and `pic` on x86_64 (see golf, below).

Size ladder (hello / tcp):

- arm64: linked 464 / 920, sstrip 182 / 634, golf 174 / 626.
- amd64: linked 456 / 880, sstrip 173 / 597, golf 165 / 589.

### The header golf (elfgolf.py)

After `sstrip` removes the section headers, a 64-bit ELF with one segment still
carries a 64-byte ELF header followed by a 56-byte program header: 120 bytes
before the first instruction. The golf reclaims 8 of them.

The kernel reads `e_phnum` (2 bytes at file offset 56) and `e_phentsize` (at 54)
from the ELF header, then reads the program headers at `e_phoff`. Set
`e_phoff = 56`: the single program header now starts exactly on `e_phnum`, and its
first field `p_type = PT_LOAD = 1` is the little-endian bytes `01 00`, which is
also the value `e_phnum` must hold for a one-segment file. `e_phentsize` stays at
54, untouched. The 8 bytes that were `e_phnum`/`e_shentsize`/`e_shnum`/
`e_shstrndx` (ignored by the loader, zero after sstrip) become the start of the
program header, and the whole load image shifts 8 bytes lower.

Because the one `PT_LOAD` maps from `p_offset 0` at a fixed `p_vaddr`, shrinking
the headers by 8 moves every byte of code and data 8 lower in both file offset and
virtual address by the same amount. On a position-independent binary that is
transparent: only `e_entry`, `p_filesz` and `p_memsz` change. This relies only on
documented ELF loading (the loader uses `e_phoff`/`e_phnum`/`e_phentsize` and does
not require `e_phoff == 64`); it is verified on OrbStack's arm64 kernel and on the
real x86_64 kernel in `scripts/vm-amd64.sh`.

The position-independence is why aarch64 uses `relocation-model=static` (its data
access is PC-relative `adr`/`adrp` anyway) but x86_64 uses `pic`: under `static`,
x86_64 bakes absolute data addresses into the code, and the shift would leave them
pointing 8 bytes too high (the string prints as "orld!"). `pic` gives RIP-relative
access, 2 bytes larger per reference but correct after the shift. Both still link
as a static `ET_EXEC` with no interpreter.

After golf, `readelf` reports a bogus "5 section headers": `e_shnum` (offset 60)
now aliases the program header's `p_flags = 5`. `e_shoff` is 0, so nothing is
read there; the kernel and the loader ignore all of `e_shoff`/`e_shnum`/
`e_shentsize`/`e_shstrndx`.

### Page-size note

Base `0x10000` is a multiple of 64 KB and `p_offset` is 0, so `p_vaddr - p_offset`
is a multiple of 64 KB and the single mapping is congruent on 4 KB, 16 KB and
64 KB page kernels alike. Nothing here depends on 4 KB pages. Tested on 4 KB
kernels only (OrbStack arm64, the amd64 VM); the layout is designed for the others
but not run on them.

## Generic tools in this directory

- `elfgolf.py <in> <out>`: the header golf above. Generic: it checks the ELF is
  64-bit, has exactly one program header at offset 64, that header is `PT_LOAD`
  with `p_offset 0`, and refuses otherwise. It contains no bytes of either program.
- `extreme/tiny.ld`: a generic one-`PT_LOAD` linker script; nothing program
  specific.
