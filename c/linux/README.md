# C on Linux (linux-arm64, linux-amd64)

Smallest C binaries for `hello` and `tcp` on Linux arm64 and amd64. Built by
`c/build-linux.sh` inside the `docker/Dockerfile` image. One build script serves
both arches; the only arch differences are the raw syscall numbers (in the
sources here, behind `__aarch64__` / `__x86_64__`) and which compiler wins on
size for the freestanding code.

All sizes below are bytes of a binary that passed `scripts/check.py` on its
platform, and (for amd64) `scripts/vm-amd64.sh` on a real x86_64 kernel.

## Variants

| Variant | hello arm64 | hello amd64 | tcp arm64 | tcp amd64 | What it is |
|---|---|---|---|---|---|
| default | 70432 | 15952 | 70952 | 16512 | glibc dynamic, `cc -O2`. The baseline. |
| optimized | 2480 | 2088 | 3712 | 3272 | glibc dynamic, size flags + strip + sstrip. Same `c/src` source. |
| static | 8612 | 5228 | 37556 | 25164 | musl static, size flags. Self-contained, no interpreter. |
| extreme | 171 | 158 | 507 | 502 | freestanding, raw syscalls, one R+X PT_LOAD, sstripped. |

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

Compiler: `-Os -fno-asynchronous-unwind-tables -fno-unwind-tables
-fno-stack-protector -fno-ident -ffunction-sections -fdata-sections
-fomit-frame-pointer`.
Linker: `--gc-sections --build-id=none -z norelro -z noseparate-code
-z max-page-size=4096 --hash-style=gnu -no-pie`, then `strip -s`, then `sstrip`.

`-z max-page-size=4096` is what cuts the arm64 file from 70 KB to a few KB: it
packs the segments to 4 KB instead of 64 KB. That ties this variant to kernels
with a page size of 4 KB or less. The test arm64 kernel uses 4 KB pages, so it
passes; on a 16 KB or 64 KB page kernel a multi-segment binary packed this
tightly may not load. The `extreme` variant below does not have this limit.

Size ladder (hello / tcp):

```
                       arm64            amd64
cc -O2 (default)       70432 / 70952    15952 / 16512
-Os + size flags        4336 / 5568      4024 / 5208
+ sstrip                2480 / 3712      2088 / 3272
```

## static

musl static (`musl-gcc -static`) with the same size flags. Self-contained: it
needs no dynamic loader and no shared libraries. `hello` is 8.6 KB (arm64) /
5.2 KB (amd64) because musl's static startup and the bits of libc it drags in
are now in the file. `tcp` is much larger (37 KB / 25 KB) because `inet_pton`,
the socket calls and their error paths pull a lot of static libc with them.
This is the price of a static libc; the `extreme` variant pays none of it by
not using libc at all.

## extreme

The main event. No libc, no CRT, no runtime. Freestanding C with raw syscalls.
Inline assembly is used only for the syscall instruction and the entry glue, as
SPEC.md allows; the parsing, the copy loop and every error check are C.

Techniques:

- `-nostdlib -nostartfiles -ffreestanding -static -fno-pic -no-pie` plus the
  size flags. The entry point is our own `real_start` (hello) or `_start`
  (tcp), not `__libc_start_main`.
- Raw syscalls through a tiny inline-asm wrapper. arm64: `svc #0`, number in
  `x8`, args in `x0..x2`. amd64: `syscall`, number in `rax`, args in
  `rdi,rsi,rdx`. Numbers used: write 64/1, read 63/0, socket 198/41, connect
  203/42, exit 93/60.
- tcp reads `argc`/`argv` off the initial stack. At process entry the stack
  pointer points at `argc`, then the `argv` pointers, then a NULL. The glue
  copies `sp` into the first argument register and jumps into C, which reads
  `stack[0]` as `argc` and `stack+1` as `argv`.
- The IPv4 dotted quad and the port are parsed in C into a 16-byte
  `sockaddr_in` built byte by byte in network order. The read loop copies to
  stdout until EOF, looping on partial writes.
- One linker script (`one-segment.ld`) puts the ELF header, the single program
  header and all code and data into one `PT_LOAD`. `sstrip` then removes the
  section headers and the section-header string table, which a loader never
  reads.

Size ladder (hello / tcp):

```
                       arm64            amd64
freestanding, linked    696 / 1064       632 / 1008
+ sstrip                171 / 507        158 / 502
```

The compiler differs by arch: `gcc -Os` is smallest on arm64, `clang -Oz` on
amd64 (arm64 clang made tcp 100+ bytes bigger; amd64 clang made hello and tcp a
few bytes smaller than gcc).

### The one segment and why it loads everywhere

The single `PT_LOAD` has `p_offset = 0`, `p_vaddr = 0x10000`,
`p_flags = R+X (5)`. Three things to know:

- **Headers inside the segment.** The linker's `FILEHDR PHDRS` keywords put the
  ELF header and program header at the start of the segment, so the segment
  spans them from file offset 0. This is required by Rosetta: when amd64
  containers run under Rosetta on this Mac, Rosetta's own ELF loader rejects a
  binary whose first load segment does not cover the ELF and program headers
  (`first load segment does not span the elf header size`). A real Linux kernel
  does not care, but the amd64 binary has to pass both.
- **Page-size independence.** `p_offset` is 0 and `p_vaddr` is `0x10000`, a
  multiple of 64 KB. The kernel requires `p_offset` congruent to `p_vaddr`
  modulo the page size; with both ending in 16 zero bits that holds for 4 KB,
  16 KB and 64 KB page kernels. So these binaries do not depend on 4 KB pages
  (unlike `optimized`). This is documented `fs/binfmt_elf.c` behaviour.
- **R+X, not RWX.** We never write into the mapped segment (tcp's buffer and
  sockaddr are on the stack, which the kernel maps writable on its own), so the
  segment is R+X. That drops the linker's RWX warning and loads under W^X
  policies that reject writable-and-executable segments.

### What the kernels check (probed, not assumed)

Mutating a working binary field by field and running it on each loader showed:

- The **arm64 kernel and the amd64 kernel enforce `e_phentsize == 56`** (the
  program-header entry size). A zero there is rejected with "Exec format
  error".
- **Rosetta** is lax about `e_phentsize` but strict about the `e_ident` bytes
  7..15 (OS/ABI and padding) and `e_ident[5]` (data encoding): garbage there is
  rejected, where a real kernel ignores it.
- `e_shoff`, `e_flags`, `e_ehsize`, the section-header count fields, `e_version`
  and `e_ident[6]` are ignored by all three loaders.

### Why there is no header overlap (the ambitious thing that does not pay off)

The file is 120 bytes of header (64-byte ELF header + 56-byte program header)
plus the code. The obvious next move is to overlap the two header tables, or to
pack code into header fields the kernel ignores. On 64-bit, across this
loader matrix, it does not work:

- The program header's `p_offset` must be 0 (Rosetta needs the headers inside
  the first segment, so the segment starts at file offset 0). `p_offset` is an
  8-byte zero field. Wherever the program header overlaps the ELF header, that
  zero run lands on `e_type` and `e_machine`, which must be non-zero, or on
  `e_entry` / `e_phoff`, which must be non-zero. `p_vaddr` and `e_phoff` also
  collide. Every overlap placement breaks a field one of the three loaders
  checks.
- Packing compiler-generated code into the scattered free fields (`e_ident`
  padding, `e_shoff`, `p_paddr`) would need a non-generic tool that understands
  the code's jumps and relocations. SPEC.md requires post-link tools to be
  generic and to contain no bytes of the program, so that is out.

So 120 bytes of header plus the compiled code is the floor for a straight
C-compiled single-segment ELF here. The remaining fat is the code itself, which
is already close to minimal (hello is ~40-50 bytes of code plus the 14-byte
string; tcp is ~380 bytes of parsing, the syscalls and the copy loop).

## Files

- `hello.c`, `tcp.c` - freestanding sources for `extreme` (syscalls + entry glue).
- `one-segment.ld` - linker script: one R+X PT_LOAD, headers at offset 0.
- The `default`, `optimized` and `static` variants build from the shared
  `c/src` sources, not from here.
