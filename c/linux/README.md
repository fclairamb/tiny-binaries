# C on Linux (linux-arm64, linux-amd64)

Smallest C binaries for `hello` and `tcp` on Linux arm64 and amd64. Built by
`c/build-linux.sh` inside the `docker/Dockerfile` image. One build script serves
both arches; the only arch differences are the raw syscall numbers (in the
sources here, behind `__aarch64__` / `__x86_64__`) and the compiler flags.

All sizes below are bytes of a binary that passed `scripts/check.py` on its
platform, and (for amd64) `scripts/vm-amd64.sh` on a real x86_64 kernel.

## Variants

| Variant | hello arm64 | hello amd64 | tcp arm64 | tcp amd64 | What it is |
|---|--:|--:|--:|--:|---|
| default | 70432 | 15952 | 70952 | 16512 | glibc dynamic, `cc -O2`. The baseline. |
| optimized | 2144 | 1792 | 3400 | 2968 | glibc dynamic, size flags + lld + sstrip. Same `c/src` source. |
| static | 6948 | 5228 | 36148 | 23948 | musl static, size flags. Self-contained, no interpreter. |
| extreme | 136 | 126 | 316 | 281 | freestanding, raw syscalls, one R+X PT_LOAD, headers packed. |

`default`, `optimized` and `extreme` are the three the spec asks every language
for. `static` is an extra: it shows what a self-contained binary costs when the
libc goes inside the file instead of being resolved at load time.

## default

`cc -O2` on the idiomatic `c/src` source, dynamically linked to glibc. Nothing
touched. On amd64 it is 16 KB; on arm64 it is 70 KB because the arm64 linker
aligns segments to the 64 KB max page size by default, which pads the file.

## optimized

Same source as `default`. Only flags and post-link steps change, as the spec
requires. glibc dynamic beats musl static here by a wide margin, because a
dynamic binary keeps the libc in the system rather than inside the file.

- Compiler: `-Os -s -fno-asynchronous-unwind-tables -fno-unwind-tables
  -fno-stack-protector -fno-ident -ffunction-sections -fdata-sections
  -fomit-frame-pointer`.
- Linker (lld): `--gc-sections --build-id=none -z norelro --no-rosegment
  --no-eh-frame-hdr -z nognustack --hash-style=gnu -no-pie`, then `sstrip`.

lld packs tighter than GNU ld here: `--no-rosegment` drops the separate
read-only segment, `--no-eh-frame-hdr` drops the `PT_GNU_EH_FRAME` index, and
`-z nognustack` drops `PT_GNU_STACK` (a hardening trade-off, about 56 bytes).
What cuts the arm64 file from 70 KB to a few KB is **`-z norelro`**: without it
the linker splits off a 64 KB-aligned RELRO/RW segment and pads the file to it.
lld keeps the 64 KB max page size on arm64, so this variant is page-size
independent (loads on 4 KB, 16 KB and 64 KB page kernels); amd64 uses 4 KB
pages regardless.

Size ladder (hello / tcp):

```
                       arm64            amd64
cc -O2 (default)       70432 / 70952    15952 / 16512
-Os + flags + lld       4032 / 5288      3680 / 4856
+ sstrip                2144 / 3400      1792 / 2968
```

## static

musl static (`musl-gcc -static`) with the same size flags, `-z norelro`,
`-z noseparate-code`, `-z common-page-size=64` and `sstrip`. Self-contained: no
dynamic loader, no shared libraries. `hello` is 6.9 KB (arm64) / 5.2 KB (amd64)
because musl's static startup and the bits of libc it drags in are now in the
file. `tcp` is much larger (36 KB / 24 KB) because `inet_pton`, the socket calls
and their error paths pull a lot of static libc with them. `-z common-page-size=64`
drops the `DATA_SEGMENT_ALIGN` file padding before the RW segment without
touching the 64 KB max page size, so this stays page-size independent.

## extreme

The main event. No libc, no CRT, no runtime. Freestanding C with raw syscalls.
Inline assembly is used only for the syscall instruction and the entry glue, as
SPEC.md allows; the parsing, the copy loop and every error check are C.

### Technique

- `-nostdlib -static -ffreestanding -fno-pic -fno-pie -mgeneral-regs-only` plus
  the size flags. The entry point is our own `real_start` (hello) or `_start`
  (tcp), not `__libc_start_main`.
- Raw syscalls through a tiny inline-asm wrapper. arm64: `svc #0`, number in
  `x8`, args in `x0..x2`. amd64: `syscall`, number in `rax`, args in
  `rdi,rsi,rdx`. Numbers used: write 64/1, read 63/0, socket 198/41, connect
  203/42, exit 93/60.
- tcp reads `argc`/`argv` off the initial stack. At process entry the stack
  pointer points at `argc`, then the `argv` pointers, then a NULL. An 8-byte
  glue (`mov x0, sp; b real_start` / `mov %rsp,%rdi; jmp real_start`) hands `sp`
  to C, which reads `stack[0]` as `argc` and `stack+1` as `argv`. hello needs no
  argv, so the kernel enters `real_start` directly and there is no glue.
- The whole code goes in a single R+X `PT_LOAD`. A linker script (`pack-hello.ld`
  / `pack-tcp.ld`) links it from a 64 KB boundary; `elfgolf.py` then writes a
  minimal, overlapped ELF + program header over the first bytes of the segment,
  drops the section headers, and fits small pieces of the program into header
  fields the loaders ignore (see below).

### tcp: three space tricks in the C

The tcp source is written to reuse the process's own stack instead of carving
out a frame (the same shape V's extreme uses, ported to C):

- The 16-byte `sockaddr_in` is written **over** the stack's `argc`/`argv[0]`
  slots, which are dead once the address is parsed. No frame is reserved for it.
- The 64-byte read buffer **is** the initial stack (`sp`): argv/envp/auxv strings
  live there and are dead after parsing, so we read into them.
- One **computed exit status** replaces a branch per error. `r` holds the last
  syscall result: 0 after a clean EOF, or `-errno` after any failure. `exit(-r)`
  gives 0 on success, or the errno (ECONNREFUSED 111, ECONNRESET 104, EBADF from
  a failed socket, ...) all in 1..125, on failure. `argc < 3` sets `r = argc-3`,
  so exit 1 or 2. A reset mid-reply makes `read` return `-ECONNRESET`, so the
  copy loop breaks with a negative `r` and the process exits 104, not 0: the
  truncated transfer does not look like success.

The address and port are parsed by one fold loop (port then dotted quad) into a
64-bit value, byte-swapped and or-ed with 2 to lay out `[02 00 port a b c d]` in
a single store. Malformed addresses are **not** rejected: the parse wraps and
accepts junk. SPEC.md lists that as unspecified ("connecting to a wrong address
that takes minutes to time out is fine"), and `check.py` does not test it, so
validating would cost bytes for nothing.

### The header packing (elfgolf.py)

`elfgolf.py` is a generic post-link tool: it takes any static `ET_EXEC` with one
`PT_LOAD`, reads its segment, entry and machine, and rewrites the smallest header
that still loads. It contains no bytes of the program. Three ideas:

1. **Overlap the program header with the ELF header.** The 56-byte program
   header starts inside the 64-byte ELF header, so fields the Linux `ELF64`
   loader does not read for a static executable double as program-header fields.
   The o56a layout puts the phdr at offset 56 (`e_phnum`/`e_shentsize` become
   `p_type`); o48a puts it at 48, where `p_offset`'s low byte also lands in
   `e_phnum`, so the segment starts at page+1. A trailing `a` starts the segment
   8 bytes earlier, over `p_align`, which `ET_EXEC` ignores.
2. **Overlap the segment with the header and fill the holes.** The segment is
   linked from a 64 KB boundary and the header is written over its first bytes.
   The bytes of header *holes* (fields the loader ignores: `e_version`,
   `e_shoff`, `p_paddr`, and the `e_flags`/`e_ehsize`/`e_shentsize`/`e_shnum`/
   `e_shstrndx` not reused as phdr fields) are kept, so the linker script drops
   small program pieces into them. hello's 14-byte message fits the 14-byte hole
   of o56a exactly; tcp's 8-byte glue and 6-byte request fit two o48a holes.
3. **bss from trailing zeros.** Trailing zero bytes of the segment are not
   written to the file; `p_memsz > p_filesz` and the loader zero-fills them.

`elfgolf.py -l LAYOUT -H` prints the header size, `-h` prints the holes.

### Why it loads everywhere (probed, not assumed)

- **Headers inside the segment.** The single `PT_LOAD` starts at file offset 0
  and spans the ELF and program headers. Rosetta (amd64 under Rosetta on the
  build Mac) rejects a binary whose first load segment does not cover the
  headers; a real Linux kernel does not care, but the amd64 binary must pass
  both.
- **Page-size independence.** `p_offset` is 0 or 1 and `p_vaddr` is `0x400000`
  (+1 for o48a), a multiple of 64 KB. The kernel needs `p_offset` congruent to
  `p_vaddr` modulo the page size; with both ending in 16 zero bits that holds on
  4 KB, 16 KB and 64 KB page kernels, so these binaries do not depend on 4 KB
  pages. Documented `fs/binfmt_elf.c` behaviour.
- **Base 0x400000, not 0x10000.** 0x10000 equals the usual `vm.mmap_min_addr`
  (65536): loading exactly at the limit works but a host with a higher
  `mmap_min_addr` would refuse it. 0x400000 is also a 64 KB multiple and costs 0
  bytes (amd64 uses `imm32` for the message address, arm64 `adr`/PC-relative).
- **`e_phentsize == 56` is enforced** by both the arm64 and amd64 kernels; a zero
  there is "Exec format error". Rosetta ignores `e_phentsize` but rejects
  anything but zero in `e_ident[5]` and `e_ident[8..15]`, where a real kernel
  does not care. `e_shoff`, `e_flags`, `e_ehsize`, the section-count fields,
  `e_version` and `e_ident[6]` are ignored by all three loaders, which is why
  they can hold program bytes.
- **R+X, not RWX.** The segment is `FLAGS(5)`. tcp writes only to the stack
  (sockaddr and read buffer), which the kernel maps writable on its own, so the
  mapped segment needs no W. That loads under W^X policies and avoids the linker
  RWX warning.
- **Entry stack alignment.** `-mgeneral-regs-only` keeps the compiler off SSE, so
  no 16-byte-aligned stack access (`movaps`) is emitted. The kernel's documented
  16-byte-aligned entry `sp` is then enough, and hello's direct entry into C
  needs no realignment.

### Size ladder (hello / tcp)

```
                       arm64            amd64
clang, linked .elf     66280 / 66544    4760 / 4968
+ elfgolf.py             136 / 316       126 / 281
```

The arm64 `.elf` is 66 KB only because its data lands on a 64 KB page boundary;
elfgolf collapses that gap and the headers to nothing. clang wins on both arches
and both programs: gcc's arm64 output unrolls the 2-iteration parse loop (about
40 bytes). hello builds at `-Oz`; tcp is smaller at `-Oz` on amd64 and `-Os` on
arm64. amd64 adds `-mno-red-zone`, and amd64 tcp adds two LLVM-internal passes
off (`-disable-machine-licm`, `-machine-sink-split=false`, together -8 bytes);
those are `-mllvm` flags, so flags not source, but they can shift between clang
versions. arm64 adds `-mcmodel=tiny`.

## Files

- `hello.c`, `tcp.c` - freestanding sources for `extreme` (syscalls + entry glue).
- `pack-hello.ld`, `pack-tcp.ld` - linker scripts: one R+X PT_LOAD from a 64 KB
  boundary, program pieces placed in the header holes.
- `elfgolf.py` - generic ELF-header golf (overlap headers, fill holes, drop
  section headers, bss from trailing zeros). Contains no program bytes.
- The `default`, `optimized` and `static` variants build from the shared
  `c/src` sources, not from here.
