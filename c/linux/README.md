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
| extreme | 124 | 123 | 264 | 232 | freestanding, raw syscalls, one PT_LOAD, headers packed. |

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

- `-nostdlib -static -ffreestanding -fno-pic -fno-pie -mgeneral-regs-only -Oz`
  plus the size flags. The entry point is our own `_start`, not
  `__libc_start_main`. `-mgeneral-regs-only` keeps the compiler off SSE, so no
  16-byte stack access is emitted and the kernel's 16-byte-aligned entry `sp` is
  enough; amd64 adds `-mstack-alignment=8` so clang never pads the stack before a
  call.
- Raw syscalls through a tiny inline-asm wrapper. arm64: `svc #0`, number in
  `x8`, args in `x0..x2`. amd64: `syscall`, number in `rax`, args in
  `rdi,rsi,rdx`. Numbers used: write 64/1, read 63/0, socket 198/41, connect
  203/42, exit 93/60.
- The whole program is one `PT_LOAD` linked from a 64 KB boundary (0x400000) by
  `holes.ld`, then `elfgolf.py` writes a minimal, overlapped ELF + program header
  over its first bytes and drops the section headers. Small pieces of the program
  live in header fields the loaders ignore (see below).
- clang wins over gcc on both arches and both programs (gcc's arm64 output
  unrolls the parse loop; gcc amd64 tcp is 260). `-mllvm` flags shave the last
  bytes of tcp: `-disable-lsr` keeps one pointer increment in the parse loop,
  `-regalloc=basic` happens to pick registers that encode shorter here (amd64:
  the parsed byte lands in `cl`, so `test cl,0x10` is 3 bytes; arm64: one move
  fewer), and amd64 adds `-mtune=znver3` (the 3-operand `lea` for the digit math;
  any x86-64 runs it). These are LLVM internals: flags, not source, but their
  effect can shift between clang versions. arm64 adds `-mcmodel=tiny` (one `adr`,
  not `adrp`+`add`).

### The header holes (holes.ld + elfgolf.py)

`holes.ld` is a generic linker script: an input section named `.holeN` is placed
at header offset N, each in its own output section, and the rest of the code
starts at `CODE` (the header size, from `elfgolf.py -l LAYOUT -H`). `elfgolf.py`
is a generic post-link tool: it takes a static `ET_EXEC` with one `PT_LOAD`,
writes the smallest header that still loads, and keeps the bytes of the holes so
the pieces `holes.ld` put there survive. It contains no bytes of any program.
Three ideas:

1. **Overlap the program header with the ELF header.** The 56-byte program
   header starts inside the 64-byte ELF header, so fields the Linux `ELF64`
   loader does not read for a static executable double as program-header fields.
   `hello` uses the o56a layout (phdr at 56, which frees a 14-byte hole at 40
   exactly the size of the message); `tcp` uses o48a (phdr at 48, so
   `p_offset`'s low byte lands in `e_phnum` and the segment maps from file offset
   0 at `p_vaddr = 0x400001`). A trailing `a` starts the code 8 bytes earlier,
   over `p_align`, which `ET_EXEC` ignores.
2. **Fill the holes with program pieces.** The holes are `e_version` (20..23),
   `e_shoff`/`e_flags`/`e_ehsize` (40..53, as far as they are not phdr fields),
   `p_paddr`, and on arm64 `e_ident[4..15]` (the arm64 kernel checks only the
   4-byte magic). The 14-byte message and the 6-byte request go in holes; so do
   the small `_start`/`die`/entry-glue functions, each in its own `.holeN`
   section. A hole the program leaves empty keeps the normal header value, so
   `readelf` still reads the amd64 files (the arm64 files keep code in
   `e_ident`, so tools that trust `EI_CLASS` cannot; the kernel picks the format
   from `e_machine`).
3. **bss from trailing zeros.** Trailing zero bytes are not written;
   `p_memsz > p_filesz` and the loader zero-fills them.

`elfgolf.py -l LAYOUT -H` prints the header size, `-h [aarch64]` the holes.

### hello

Split into small functions that tail-call each other so each can live in a
different hole. The 14-byte message fills the 14-byte hole at 40.

- **amd64 (123):** o56a header (104 bytes). `_start` in `p_paddr` (80, 6 bytes):
  `push 14; pop rdx; jmp h2` (a rel32 `jmp` is 5 bytes, so the hole holds one
  constant load and the jump). `h2` at CODE (19 bytes): `push 1; pop rax;
  mov esi,&msg; mov edi,eax; syscall; push 60; pop rax; xor edi,edi; syscall`.
- **arm64 (124):** o56a header. `_start` in `e_ident[4..15]` (4, 12 bytes):
  `adr x1,msg; mov w2,#14; b h2`. `h2` in `p_paddr` (80, 8 bytes): `mov w0,#1;
  b h3`. `h3` at CODE (20 bytes): the two syscalls.

`hello` assumes its one `write` succeeds (SPEC leaves stdout errors unspecified).

### tcp

The source is one file for both arches (`tcp.c`), branching on the arch only for
the syscall ABI, the socket-argument check and which register the entry glue
uses. Three space ideas, all ported from the V and Rust slices:

- **The argument check is the socket call, no `if (argc < 2)`.** On arm64 the
  socket *type* is `argc - 2`: 1 (SOCK_STREAM) with two arguments, 0 or negative
  with fewer, both of which `socket()` rejects, and `connect()` on the error fd
  then fails with `EBADF` (exit 9). The protocol argument is `x2`, which the
  kernel zeroes at entry and the glue does not touch, so it is a deterministic 0
  (TCP) and costs no instruction. On amd64 the socket *protocol* is `argc - 3`
  (same effect, 0 with two arguments, negative with fewer). Either way fewer than
  two arguments exits 9 whatever the one argument holds, and no socket is
  created, which covers the one-argument tests `check.py` added. Checked with
  strace across `''`, `8080`, `1.2`, `1.2.3`, `1.2.3.4.5`, `localhost` and more:
  exit 9, no connection, on both arches.
- **One fold loop parses the port then the dotted quad into a 64-bit value.** The
  start value `0x20000` has `0x02` at bits 16..23; five fields shift it to bits
  56..63, so after `bswap` the value is `sin_family = AF_INET`, the port and the
  address in network order, written in one store over `argv[0]` (dead by then).
  `sin_zero`, the next 8 bytes, is `argv[1]`, which Linux does not read for an
  `AF_INET` connect. A digit is tested with `& 16` (bit 4: set on `'0'..'9'`,
  clear on `.` and NUL), which is one `tbz`/`test`.
- **No partial-read frame and one computed exit.** The read count is the previous
  write length (6, then the last read's result), so each read is at most 6 bytes.
  On arm64 the read buffer is the request itself (a writable `static` in the
  `p_paddr` hole, so the segment is R+W+X): one pointer for every write and read.
  On amd64 the buffer is the stack at `argv` (Rosetta write-protects the header
  page, so a read into it would `EFAULT`). `r` holds the last syscall result: a
  clean EOF (0) exits 0, a failure (`-errno`, e.g. `ECONNRESET` 104 for a reset
  mid-reply) exits the errno (1..125), so a truncated transfer never looks like
  success. `die()` (the negate + exit) lives in a header hole.

amd64 adds `__attribute__((preserve_none))` on `tmain` so it saves no
callee-saved register (bar one `push rbp` clang still emits), and its entry glue
(`pop r9; mov r8,rsp`, argc and &argv as `tmain`'s 10th and 9th preserve_none
arguments) sits in `tmain`'s own section and falls through into it with no jump;
the build checks that `tmain` starts 5 bytes after `_start`. The amd64 syscall
wrappers list extra clobbers (`r10`; and in the copy loop `r9`, `r12..r15`) that
the kernel does not touch, which only tells the compiler less and keeps the fd
and the constant 1 in registers whose moves need no REX prefix.

### Size ladder (hello / tcp)

```
                       arm64            amd64
clang, linked .elf     66280 / 66544    4760 / 4968
+ elfgolf.py             124 / 264       123 / 232
```

Byte accounting of the final files:

- hello amd64 (123): 104-byte o56a header (14 of message, 6 of `_start` in
  `p_paddr`) + 19 bytes of `h2`.
- hello arm64 (124): 104-byte header (12 of `_start` in `e_ident`, 14 of message,
  8 of `h2` in `p_paddr`) + 20 bytes of `h3`.
- tcp amd64 (232): 96-byte o48a header (7 of `die` in `e_shoff`, 6 of request in
  `p_paddr`) + 5 of glue + 131 of code.
- tcp arm64 (264): 96-byte header (12 of `die` in `e_ident`, 8 of glue in
  `e_shoff`, 6 of request in `p_paddr`) + 168 bytes of code.

The arm64 `.elf` is 66 KB only because its data lands on a 64 KB page boundary;
elfgolf collapses that gap and the headers to nothing.

### What each loader checks (relied on, not assumed)

- **Headers inside the segment.** The single `PT_LOAD` starts at file offset 0
  (o56a) or 1 (o48a) and spans the ELF and program headers. Rosetta rejects an
  amd64 binary whose first load segment does not cover the headers; a real Linux
  kernel does not care, but the amd64 binary passes both (`run.sh` under Rosetta
  and `vm-amd64.sh` on a real 6.12 kernel).
- **`e_phentsize == 56` is enforced** by both kernels; `e_shoff`, `e_flags`,
  `e_ehsize`, the section-count fields, `e_version`, `p_paddr` and `p_align` (for
  `ET_EXEC`) are ignored by all loaders, which is why they can hold program
  bytes. This is how `fs/binfmt_elf.c` reads the header, not a documented ABI
  guarantee. Rosetta rejects anything but the standard bytes in `e_ident[4..15]`,
  so amd64 never uses that hole; the arm64 kernel ignores `e_ident[4..15]`
  (it keeps only the 4-byte magic), so arm64 puts code there and the binaries do
  not depend on Rosetta.
- **Base 0x400000, not 0x10000.** 0x400000 is where ld puts a non-PIE executable
  and is far above any `vm.mmap_min_addr` (0x10000 is exactly the common 65536
  limit); it is also a 64 KB multiple and costs 0 bytes. Same choice as the V,
  Rust and Go slices.
- **R+X, except arm64 tcp.** hello (both arches) and amd64 tcp are `R+X`. arm64
  tcp reads into its request, so its segment is `R+W+X`; a system that refuses
  W+X mappings (SELinux `execmem` denied, PaX MPROTECT) would not run it. Linux
  itself has no W^X rule for ELF segments.
- **Entry registers.** arm64 tcp reads the socket protocol from `x2`, which
  `ELF_PLAT_INIT` / `start_thread` zero at entry. amd64 hello and tcp set every
  register they use.

### Page sizes

`p_offset` is 0 or 1 and `p_vaddr` is `0x400000` (+1 for o48a), so
`p_vaddr - p_offset` is a multiple of 64 KB and the mapping is congruent on 4 KB,
16 KB and 64 KB page kernels alike: these binaries do not depend on 4 KB pages.
Tested on 4 KB pages (OrbStack arm64 kernel 7.2, Rosetta, the amd64 qemu VM). The
layout is the same one the V, Rust, Go and asm slices documented as passing on
16 KB and 64 KB arm64 kernels under qemu; the harness has no arm64 VM, so the
16/64 KB claim here rests on that shared congruence, not a fresh run in this
slice.

## Files

- `hello.c`, `tcp.c` - freestanding sources for `extreme` (syscalls + entry glue).
- `holes.ld` - generic linker script: one `PT_LOAD` from a 64 KB boundary, a
  `.holeN` section placed at header offset N, the rest at `CODE`.
- `elfgolf.py` - generic ELF-header golf (overlap headers, fill holes, drop
  section headers, bss from trailing zeros). Contains no program bytes. The Go
  slice copied this tool; the aarch64-hole logic here matches the V and Rust
  copies.
- The `default`, `optimized` and `static` variants build from the shared
  `c/src` sources, not from here.
