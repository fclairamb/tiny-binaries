# Go on Linux (arm64, amd64)

Five variants of each program. Sizes in bytes, measured with `scripts/run.sh -p linux-arm64 go`
and `-p linux-amd64 go`, every binary passing `scripts/check.py` and (amd64) `scripts/vm-amd64.sh`.

| variant   | hello arm64 | hello amd64 | tcp arm64 | tcp amd64 | how |
|-----------|-------------|-------------|-----------|-----------|-----|
| default   | 2341917     | 2342609     | 3332010   | 3455309   | plain `go build` |
| optimized | 1343612     | 1458300     | 1982588   | 2142332   | CGO off, strip, gc/link flags |
| upx       | 401856      | 466276      | 561908    | 648996    | optimized, then UPX --best --lzma |
| tinygo    | 189776      | 162632      | 300056    | 264784    | same sources, TinyGo runtime |
| extreme   | **170**     | **158**     | **450**   | **479**   | no runtime, raw syscalls, one PT_LOAD, sstrip |

The default row is the gc toolchain's plain build: a dynamically linked binary with the full Go
runtime, scheduler and garbage collector. Everything below keeps the same two programs and cuts
from there.

## default

`go build`. The committed baseline. Not reproducible to the byte (gc embeds a build id and module
metadata), which is why only the rows below are size-stable.

## optimized

Same `go/src` sources, flags only:

- `CGO_ENABLED=0`: static, no libc, no dynamic loader.
- `-trimpath`: no absolute paths in the binary.
- `-ldflags "-s -w -buildid="`: drop the symbol table, DWARF and the build id.
- `-ldflags "-R 0x1000"`: shrink the segment alignment rounding from 64 KB to 4 KB. Saves ~90 KB
  on arm64; a no-op on amd64 where gc already rounds tighter.
- `-gcflags "all=-l -B"`: no inlining metadata, no bounds-check id instrumentation.

Size ladder, arm64 hello: 2341917 (default) -> 1572988 (`-s -w`) -> 1441916 (`-l -B`) ->
1343612 (`-R 0x1000`). The Go runtime is the floor here: there is no way to drop it without
changing compiler, so this variant stays around 1.3-2.1 MB.

## upx

The optimized binary, compressed with `upx --best --lzma`. Self-extracts into an anonymous mapping
at startup. `--ultra-brute` was within 300 bytes of `--best` and much slower, so it is not used.
This is a file-size trick, not a memory trick: the process is as big as optimized once running.

## tinygo

The **same idiomatic sources** (`go/src`), built with TinyGo instead of gc. TinyGo has a much
smaller runtime and its own `net` implementation, so `net.Dial` / `io.Copy` work unchanged and the
binary is 7-20x smaller than optimized. `-opt=z -no-debug -panic=trap -scheduler=none`.

GC note: `-gc=none` refuses to link the idiomatic sources (they allocate in `fmt`/`reflect`), and
`-gc=leaking` fails to link with `scheduler=none` (undefined `tinygo_scanstack`, a TinyGo 0.43
packaging gap). `-gc=conservative` is the smallest GC that links, so that is what this variant uses.

## extreme

The main event. Custom sources under `extreme/`, no runtime at all, built with TinyGo.

### How the language still does the work

TinyGo's compiler turns a call to a function linked to `golang.org/x/sys/unix.RawSyscallNoError*`
into the bare `syscall` / `svc #0` instruction with the right register constraints (see
`compiler/syscall.go` in TinyGo). So `sys/sys.go` declares three such functions with `//go:linkname`
and the rest is ordinary Go: the IP/port parsing, the sockaddr layout, the copy loop, the error
checks. No `.s` files, no machine code in byte arrays. The only non-logic piece is reading the entry
stack pointer, which uses an LLVM intrinsic, not hand-written asm:

- arm64: `llvm.sponentry.p0` (stack pointer on entry to `_start`, which points at `argc`).
- amd64: `llvm.addressofreturnaddress.p0`. At the ELF entry there is no pushed return address, so
  this is `rsp` itself, which points at `argc`.

`hello` needs neither: it only writes and exits.

### ELF layout (one.ld)

`-gc=none -scheduler=none`, a custom target JSON (`target-<arch>.json`) that inherits nothing, sets
`libc`/`rtlib` empty, entry `_start`, static, `--build-id=none`. The linker script `one.ld` puts the
ELF header, the one program header and all code+rodata into a single `PT_LOAD` mapped from file
offset 0 at virtual address `0x10000`. One segment means there is no second mapping to fight over
page permissions.

`tcp` needs a writable buffer for the `read()` target and the sockaddr. It does **not** use a `.bss`
segment: it `mmap`s one anonymous page at run time (`MAP_PRIVATE|MAP_ANONYMOUS`, `PROT_READ|WRITE`).
That keeps the file to a single read-execute segment and sidesteps a Rosetta quirk (below).

### sstrip

TinyGo still emits a symbol table and section headers. `sstrip` (elfkickers, generic, contains no
bytes of the program) removes the section header table, `.symtab` and `.strtab`. That is the whole
post-link step.

Size ladder:

| step                       | hello arm64 | hello amd64 | tcp arm64 | tcp amd64 |
|----------------------------|-------------|-------------|-----------|-----------|
| TinyGo + one.ld            | 952         | 640         | 1232      | 960       |
| sstrip                     | 170         | 158         | 450       | 479       |

Accounting for `hello-extreme` amd64 (158 bytes): 64 (ELF header) + 56 (one program header) + 38
(`.text`, which is the 24-byte write+exit code and the 14-byte "Hello, World!\n"). That is the floor
for a standard, non-overlapping ELF64: the 120 header bytes are fixed and the rest is just the code.
arm64 is a little larger because every instruction is 4 bytes.

### Why the mmap page, and the Rosetta gotcha

On this Mac, `scripts/run.sh -p linux-amd64` runs the binary under Rosetta, Apple's user-mode x86_64
translator. Rosetta maps an executable ELF segment read-only in the real address space. An earlier
version kept the read buffer in `.bss` inside an RWX segment; it passed on the real kernel
(`vm-amd64.sh`) but `read()` returned `-EFAULT` under Rosetta because the real arm64 kernel saw that
page as non-writable. A separate page-aligned RW `.bss` segment fixed Rosetta but bloated the file to
4704 bytes (segment alignment padding). `mmap`ing a fresh page at run time is both smaller (the file
stays one segment) and correct everywhere: the kernel owns that page as read-write on every loader.
So the amd64 extreme binary passes both Rosetta and the real kernel.

### Page-size independence

The single `PT_LOAD` starts at virtual address `0x10000` (64 KB) with `p_offset 0`, so
`p_vaddr % pagesize == p_offset % pagesize == 0` for 4 KB, 16 KB and 64 KB page kernels. Nothing in
the layout assumes 4 KB pages, so these binaries are safe on the 16 KB and 64 KB arm64 kernels that
real hardware uses, not just the 4 KB test container.

## Rebuild

```bash
scripts/run.sh -p linux-arm64 go
scripts/run.sh -p linux-amd64 go
scripts/vm-amd64.sh out/linux-amd64/go
```
