# Go on Linux (arm64, amd64)

Five variants of each program. Sizes in bytes, measured with `scripts/run.sh -p linux-arm64 go`
and `-p linux-amd64 go`, every binary passing `scripts/check.py` and (amd64) `scripts/vm-amd64.sh`
on a real x86_64 kernel.

| variant   | hello arm64 | hello amd64 | tcp arm64 | tcp amd64 | how |
|-----------|-------------|-------------|-----------|-----------|-----|
| default   | 2341949     | 2342457     | 3332090   | 3455381   | plain `go build` |
| optimized | 1303840     | 1344594     | 1938080   | 2005682   | flags only: `-l -B`, GOEXPERIMENT, lld (arm64) or `-funcalign=1` (amd64), strip |
| upx       | 391724      | 450448      | 551588    | 632356    | static gc build, same flags, stripped, then UPX --best --lzma |
| tinygo    | 15392       | 13200       | 138184    | 162560    | same sources, TinyGo, `-nobounds`, stripped |
| extreme   | **132**     | **125**     | **300**   | **268**   | no runtime, raw syscalls, one PT_LOAD, golfed header |

## Reproducibility

Every build runs with `GOFLAGS=-buildvcs=false`, set once at the top of `build-linux.sh`. VCS
stamping runs git in the checkout, and git refuses (exit 128, "dubious ownership") when the
checkout belongs to another uid than the build: that is the CI setup, where `actions/checkout`
runs as the runner user and `scripts/run.sh` runs the container as root. With stamping on, every
Go and TinyGo build failed in that setup (TinyGo runs `go list`, which stamps too). Stamping also
wrote the commit hash, its time and the dirty flag into default, optimized and upx, so their bytes
changed with every commit.

Checked on both arches: optimized, upx, tinygo and extreme are byte-identical when built from a
checkout owned by uid 1001, before and after a commit, from a copy without `.git` at another path
(`/r`), with fresh Go and TinyGo caches, and offline (`docker run --network none`). default is
byte-identical for the same checkout path; it embeds the source paths (no `-trimpath`, as plain
`go build` does), so a build at another path differs (by 8 to 240 bytes in size here).

## Page sizes

amd64 Linux only has 4 KB pages. arm64 kernels also run with 16 KB pages (Raspberry Pi 5, Asahi)
and 64 KB pages, and every arm64 binary here is laid out for all three: no two PT_LOADs with
different permissions share a 64 KB page, and each `p_offset` is congruent to its `p_vaddr` modulo
64 KB. All 10 arm64 binaries pass the `scripts/vm/init` checks on a 16 KB kernel (Debian
`6.12.113+deb13-arm64-16k`) and a 64 KB kernel (Ubuntu `6.8.0-147-generic-64k`), booted with
`qemu-system-aarch64 -M virt -cpu max`, as well as on OrbStack's 4 KB kernel. The harness has no
arm64 VM, so this was a manual run. The UPX environment limit below is the same on all three
page sizes.

## default

`go build`, with `GOFLAGS=-buildvcs=false` (see Reproducibility). The committed baseline. hello is
statically linked (fmt needs no cgo); tcp links glibc dynamically, because `net` uses the cgo DNS
resolver when cgo is available.

## optimized

Same `go/src` sources, flags only. Size ladder (hello / tcp):

| step | arm64 | amd64 |
|------|-------|-------|
| `go build` (default) | 2341949 / 3332090 | 2342457 / 3455381 |
| `CGO_ENABLED=0` | 2341941 / 3244051 | 2342537 / 3383778 |
| `-trimpath` | 2341557 / 3243465 | 2338113 / 3374992 |
| `-ldflags "-s -w"` | 1573024 / 2162848 | 1507488 / 2216096 |
| `-ldflags -buildid=` | 1572988 / 2162812 | 1507452 / 2216060 |
| `-gcflags "all=-l -B"` | 1441916 / 2097276 | 1454204 / 2138236 |
| `GOEXPERIMENT=nogreenteagc,nosizespecializedmalloc` | 1376380 / 2031740 | 1392764 / 2068604 |
| arm64: external link with lld (`-tags netgo` for tcp) | 1311208 / 1945448 | |
| arm64: lld `--build-id=none --gc-sections --no-eh-frame-hdr` | 1308440 / 1942680 | |
| arm64: `CGO_CFLAGS` for size | 1306704 / 1941008 | |
| arm64: lld `-z norelro --no-rosegment -z nognustack` | 1306424 / 1940664 | |
| amd64: `-ldflags -funcalign=1` | | 1347708 / 2007164 |
| `strip --strip-section-headers` | **1303840** / **1938080** | **1344594** / **2005682** |

- `-s -w` drop the symbol table and DWARF, `-buildid=` the build id, `-trimpath` the file paths.
  With `-trimpath`, Go also leaves `-ldflags` and the `CGO_*` variables out of the embedded build
  info, so the long linker flags cost nothing; `-gcflags`, `-tags` and `GOEXPERIMENT` are recorded.
- `-gcflags "all=-l -B"`: `-l` turns inlining off (fewer copies of small functions), `-B` removes
  bounds checks entirely, so an out-of-range index no longer panics. Both are documented compiler
  flags. On amd64 `-l` alone saves 20 KB (hello) and `-B` alone 37 KB. The arm64 rows move in
  64 KB steps until the external link, because gc pads every segment to 64 KB there.
- `GOEXPERIMENT=nogreenteagc,nosizespecializedmalloc` turns off two runtime features that are on
  by default in Go 1.27: the Green Tea garbage collector and the malloc functions specialized per
  size class. The runtime is then built with the older GC and the generic allocator. On the final
  binaries it saves 40064 / 41440 bytes on arm64 and 62720 / 66816 on amd64 (`nogreenteagc` is
  the larger part on amd64; on arm64 the two are about equal). No source changes, but
  `go help environment` says GOEXPERIMENT is meant for the development of the toolchain and that
  other use is unsupported, so this is the least ordinary flag of the variant.
  `norandomizedheapbase64` would save 1408 / 1440 bytes more on arm64 (and cost 64 on amd64) by
  giving up heap address randomization; not taken.
- arm64, external link. gc's internal linker rounds both the address and the file offset of each
  segment up to 64 KB, so the file carries up to 64 KB of zeros per segment boundary. That padding
  is what lets the binary run on 64 KB page kernels. lld gets the same property without the
  padding: it starts each segment on a new 64 KB page in memory but packs the segments back to
  back in the file, which is allowed because the loader only needs `p_offset` congruent to
  `p_vaddr` modulo the page size (ELF gABI; this is lld's default, `-z noseparate-code`).
  External linking requires cgo, so the binary links glibc dynamically. `-tags netgo` keeps the
  pure Go resolver of the static build for tcp (30696 bytes smaller); on hello the tag only adds
  32 bytes of build info, so hello builds without it. `CC=clang` and `CGO_CFLAGS="-Os
  -fno-asynchronous-unwind-tables -fno-unwind-tables -ffunction-sections -fdata-sections"` shrink
  the small runtime/cgo C glue (gcc gives 32 / 64 bytes more).
- arm64, three hardening trade-offs, the same lld flags as the C slice. `-z norelro` (136 / 136
  bytes) leaves the GOT writable. `--no-rosegment` puts the read-only data in the executable
  segment and `-z nognustack` drops PT_GNU_STACK: 64 bytes each alone, 64 / 128 together (the
  text section is 64-byte aligned, so the 112 bytes of program headers they remove do not all
  turn into savings). Without PT_GNU_STACK the stack stays non-executable on arm64: the kernel
  only implies exec for 32-bit tasks there, and glibc 2.41 allocates thread stacks read-write
  (checked with strace).
- For comparison, after strip: gc's `-R 0x1000` gives 1299506 / 1936018, 4334 / 2062 bytes below
  optimized, but needs 4 KB pages: on a 16 or 64 KB kernel the first page of the read-only
  segment also covers the end of the text, which then loses execute permission. `-R 0x4000`
  gives 1315890 / 1960594.
- amd64, `-funcalign=1` (documented linker flag): gc aligns functions to 32 bytes on amd64. The
  linker still spaces functions at least 16 bytes apart (`abi.MINFUNC`, which its pc to function
  lookup table needs), so only the padding beyond that goes. Hot assembly loops lose their
  alignment: a speed cost, not a correctness one. No effect on arm64, where external linking
  is smaller anyway. An external lld link on amd64, with the arm64 flags, is much larger
  (1394128 / 2073168).
- `strip --strip-section-headers` (binutils 2.41 and later) removes the section header table and
  the sections only it points to. The kernel and ld.so read program headers only.

The Go runtime is the floor here: there is no way to drop it without changing compiler, so this
variant stays around 1.3 to 2 MB.

## upx

The static gc build (`CGO_ENABLED=0 -trimpath`, `-s -w -buildid=`, `-l -B`, the same
GOEXPERIMENT, gc's default layout), `strip --strip-section-headers`, then `upx --best --lzma`.
Self-extracts into memory at startup.

| step | hello arm64 | hello amd64 | tcp arm64 | tcp amd64 |
|------|-------------|-------------|-----------|-----------|
| static build | 1376380 | 1392764 | 2031740 | 2068604 |
| `strip --strip-section-headers` | 1348658 | 1389650 | 2009746 | 2067122 |
| `upx --best --lzma` | **391724** | **450448** | **551588** | **632356** |

Without the GOEXPERIMENT, upx gives 401264 / 465572 / 561412 / 648260. The zero padding of the
64 KB layout costs nothing once compressed, and the layout flags of optimized make the compressed
file larger (UPX of the optimized binaries gives 398660 / 559788 on arm64, 452028 / 635360 on
amd64), so upx starts from the plain static build. `--ultra-brute` gives no smaller file (391724
for hello on arm64, the same as `--best --lzma`). This is a file-size trick, not a memory trick:
the process is as big as the input once running.

**arm64 limit: about 8 KB of argv, envp and auxv.** UPX 4.2.4's arm64 stub fails when the
initial stack holds more than about 970 argument and environment pointers. Before it maps the
program, the stub adds an environment variable named `"   "` (three spaces) holding the path of
`/proc/self/exe`. To make room, it copies the whole block from `argc` to the end of auxv to a
fixed 8 KB below the end of auxv, front to back. A larger block overlaps its own copy, auxv is
corrupted, and the stub exits 127 (or crashes with SIGSEGV with a few thousand arguments). On the
OrbStack kernel (24 auxv entries counting AT_NULL), `env -i` with 971 variables runs and 972 exit
127, with 1-byte or 100-byte values and with any compression method; a static C hello packed the
same way behaves the same. The limit moves with the size of auxv: on the 16 KB and 64 KB kernels
above, 973 variables run and 974 fail. The other variants run with 3000 variables. The amd64 stub does not have this limit: 14500 variables run on the
real-kernel VM (under Rosetta it crashes from about 14100, where the other variants still run
with 30000; not analysed). It is a bug in the UPX release the image ships, deterministic for a
given argument and environment count, and normal environments are far below it. Found by reading
the decompressed stub (dumped with ptrace) and checked by bisecting the variable count.

## tinygo

The **same idiomatic sources** (`go/src`), built with TinyGo instead of gc: `-no-debug
-panic=trap -nobounds -scheduler=none`, then `strip --strip-section-headers`. TinyGo has a much
smaller runtime and its own `net` implementation, so `net.Dial` / `io.Copy` work unchanged for the
spec's addresses.

| step | hello arm64 | hello amd64 | tcp arm64 | tcp amd64 |
|------|-------------|-------------|-----------|-----------|
| `-opt=z -gc=conservative` | 189776 | 162632 | 300056 | 264784 |
| `-gc=leaking` (amd64) | | 159616 | | 261584 |
| `strip --strip-section-headers` | 89000 | 102784 | 141320 | 166984 |
| hello: `-opt=s` | 15464 | 13288 | | |
| `-nobounds` | **15392** | **13200** | **138184** | **162560** |

- GC: `-gc=leaking` never frees, which is fine for two short programs. On arm64 it does not link
  with `-scheduler=none` (TinyGo 0.43's `asm_arm64.S` calls `tinygo_scanstack`, which only the
  other GCs define), so arm64 keeps `conservative`. `-gc=none` refuses the idiomatic sources
  (they allocate), and `precise` is larger than `conservative` (arm64: 15680 against 15392 for
  hello, 139176 against 138184 for tcp).
- Optimization level per program. hello is 6 to 8 times smaller at `-opt=s` than at `-opt=z`:
  at `-Os` LLVM inlines `fmt.Println` far enough that the type switch on its constant string
  argument folds, and most of fmt's reflection goes. tcp prints a non-constant error, so it keeps
  that code anyway, and is smaller at `-opt=z` (`-opt=s` gives 160712 on arm64, 172672 on amd64,
  before `-nobounds`).
- `-nobounds` is TinyGo's counterpart of gc's `-B`: no bounds checks.
- `-no-debug` drops DWARF but keeps the symbol table; strip removes it. One local symbol in it
  carries a hash of its module's path in TinyGo's cache (`signal_handler.llvm.<hash>`), so before
  strip the output changed with the cache directory (`XDG_CACHE_HOME`). After strip it does not.
- The binaries are statically linked (TinyGo bundles musl). lld's 64 KB max page size on aarch64
  keeps them page-size independent.
- TinyGo's `net.DialTCP` refuses an unspecified address: `tcp-tinygo 0.0.0.0 <port>` exits 1 with
  "Sorry, localhost isn't available on Tinygo", where the gc variants and extreme connect (Linux
  sends a connect to 0.0.0.0 to the local host). The spec does not cover 0.0.0.0.
- UPX does not combine with TinyGo here: it refuses the TinyGo hello, and the packed tcp crashes
  (SIGSEGV) on arm64.

## extreme

The main event. Custom sources under `extreme/`, no runtime at all, built with TinyGo.

### How the language still does the work

TinyGo's compiler turns a call to a function linked to `golang.org/x/sys/unix.RawSyscallNoError*`
into the bare `syscall` / `svc #0` instruction with the right register constraints (see
`createRawSyscall` in TinyGo's `compiler/syscall.go`). So `sys/sys.go` declares two such functions
with `//go:linkname` and the rest is ordinary Go: the IP and port parsing, the sockaddr layout, the
copy loop, the error checks. No `.s` files, no machine code in byte arrays. The only non-logic piece
is reading the entry stack pointer, which uses an LLVM intrinsic, not hand-written asm:

- arm64: `llvm.sponentry.p0` (stack pointer on entry to `_start`, which points at `argc`).
- amd64: `llvm.addressofreturnaddress.p0`. At the ELF entry there is no pushed return address, so
  this is `rsp` itself, which points at `argc`.

`hello` needs neither: it only writes and exits.

### Exit status

`RawSyscallNoError3` returns the kernel's raw return value, so a failed `read` or `connect` comes
back as `-errno` (for example -104, `ECONNRESET`), not as a thrown error. Every path ends at one
exit with status `-r`:

- `r = argc - 3` first. It is negative with fewer than 2 arguments, so the status is `3 - argc`:
  2 with no arguments, 1 with one. With `argc == 0`, which kernels before 5.18 allow
  (`execve` with an empty argv), it is 3, so the binary does not depend on the kernel adding an
  empty `argv[0]`.
- `r = connect(...)`: 0 or `-errno` (111 when nothing listens).
- `r = read(...)` in the copy loop, which stops on `int(r) <= 0`: 0 is a clean EOF, a negative
  value an error, so a reset mid-reply exits 104 and a truncated transfer fails the test.

### The build pipeline, and why it is not plain `tinygo build`

`tinygo build` links straight to an executable and does not expose the LLVM backend flags that
save the last bytes. So the extreme build goes through the intermediate object:

1. `tinygo build -o x.bc`: TinyGo compiles the Go to an LLVM bitcode module (a `.bc` by extension).
2. `tinygo clang -c -Oz ... x.bc -o x.o`: TinyGo's own bundled clang (the same LLVM 22 backend)
   lowers the bitcode to an object, with two flags `tinygo build` hides:
   - amd64 `-mllvm -disable-machine-licm`: do not hoist loop-invariant constants out of the copy
     loop. A hoisted constant can need a callee-saved register, whose spill turns the red zone on,
     and with the red zone on LLVM stops using `push imm8; pop reg` (3 bytes) for small constants
     and falls back to 10-byte `movabs`. Saves 56 bytes on tcp (324 without it), none on hello.
   - arm64 `-mcmodel=tiny`: PC-relative `adr` for the one string address instead of `adrp; add`.
     Saves 4 bytes on each program.
3. `tinygo ld.lld ... -T one.ld`: link one read-execute `PT_LOAD` from a 64 KB boundary.
4. `elfgolf.py`: overlap the headers and strip the rest (below).

### Tricks in the source

- `sys.Assume(false)` after the arm64 exit syscall. `Assume` is `//export llvm.assume`, the LLVM
  intrinsic; `assume(false)` lowers to `unreachable`, so the compiler emits no `ret` or trap after
  the exit call.
- `sys.Exit` is a separate function placed in its own section `.text.hole`. The linker script
  drops that section into the unused 8-byte `p_paddr` field of the program header, so it costs
  zero file bytes. Its argument is already in the syscall's first argument register.
  - arm64: `mov w8, #93; svc #0`, exactly 8 bytes. `//export tinyexit` keeps LLVM from folding a
    constant argument into the body, which would no longer fit.
  - amd64: the body also negates its argument: `neg edi; push 60; pop rax; syscall; ret`, 8 bytes
    (the `ret` is dead but fits). With the negation in the hole the single exit site in tcp is
    `mov edi, eax; jmp Exit`. hello calls `Exit(0)`, which LLVM folds into the body
    (`push 60; pop rax; xor edi, edi; syscall; ret`). On arm64 the negation would not fit, so
    `sys.Status` does it at the call site there.
- The amd64 and arm64 backends lower the parse loop differently from the same Go, so the inner
  parse loop is written per arch in `tcp/parse_amd64.go` and `tcp/parse_arm64.go` (build-tagged).
  Both do the same thing; amd64 wants a plain load-then-advance, arm64 wants a pre-increment that
  becomes a post-indexed `ldrb`. With the other arch's loop tcp is 304 bytes on arm64 (4 more)
  and 271 on amd64 (3 more).

### The parse itself

One loop reads argv[argc-1] down to argv[1], folding each dotted-decimal field into a `uint64` at
every separator (`.` or the final NUL): `x = x<<8 | field`. `x` starts at `AF_INET<<16`, so after
the port and the four address bytes `x = AF_INET<<56 | port<<32 | a.b.c.d`. Its byte swap (`bswap`,
which LLVM folds to one `bswap`/`rev`) is the 8 meaningful bytes of the `sockaddr_in`, written over
`argc` on the stack. `connect` gets a length of 16, so the other 8 bytes, `sin_zero`, are whatever
follows `argc`: the `argv[0]` pointer, which changes with ASLR. That works because Linux does not
read `sin_zero` for an AF_INET connect (`tcp_v4_connect` checks only the length and the family);
this is kernel behaviour, not a documented promise, and the result does not depend on the value.
The read buffer is that same stack area (64 bytes at a time, far less than the
stack the kernel gives), so the program never writes into its own mapped segment and the segment
stays read-execute. Malformed arguments (extra octets, a huge IP) are unspecified by the spec; the
loop does not bound them.

### ELF layout (one.ld + elfgolf.py)

`one.ld` lays a single `PT_LOAD`, read-execute, from virtual address `0x10000`, and tucks the string
constant and the exit function into header holes. `elfgolf.py` (a copy of `c/linux/elfgolf.py`,
the C slice's generic tool, byte-identical when copied) then writes a minimal ELF header that
overlaps the program header into its own tail and drops the section headers:

- hello uses layout `o56a` (104-byte header): the 14-byte "Hello, World!\n" fills the 14-byte hole
  at offsets 40..53, the 8-byte exit fills the `p_paddr` hole at 80..87.
- tcp uses layout `o48a` (96-byte header): "hello\n" goes in the hole at 40..47, exit in the
  `p_paddr` hole at 72..79.

The undocumented loader rules this relies on (static `ET_EXEC`, header fields Linux ignores such
as `e_shoff`, `e_flags`, `p_paddr` and, for `ET_EXEC`, `p_align`; `p_offset` congruent to
`p_vaddr` modulo the page size) are listed in `elfgolf.py` and in `v/linux/README.md`. Rosetta is
stricter than the real kernel about `e_ident[8..15]`, so those bytes are never used as holes; the
amd64 binaries pass both Rosetta (`run.sh`) and the real kernel (`vm-amd64.sh`).

Size ladder:

| step | hello arm64 | hello amd64 | tcp arm64 | tcp amd64 |
|------|-------------|-------------|-----------|-----------|
| lld output | 113224 | 52416 | 114608 | 53704 |
| `strip` | 65880 | 4432 | 66048 | 4576 |
| `elfgolf.py` | **132** | **125** | **300** | **268** |

(lld places the segment at file offset 64 KB on arm64 and 4 KB on amd64, hence the big stripped
files.) The golfed file is the header plus the code: the header holes carry the string and the
exit, and trailing zeros become bss. hello amd64, 125 bytes: 104 bytes before the code (14 bytes
of string, 8 of exit, 4 free in `e_version` at 20..23, the other 78 header fields), then 21 bytes
of `_start`, the first 8 of which double as `p_align`. hello arm64 is the same 104 bytes plus 7
instructions (28 bytes). tcp: 96 bytes of header (6 of string, 8 of exit, 6 free: `e_version`
and 46..47), then 172 bytes of code on amd64 and 204 on arm64.

### Page-size independence

The single `PT_LOAD` starts at a 64 KB boundary (`p_vaddr` 0x10000 or 0x10001, `p_offset` 0 or 1),
so `p_vaddr - p_offset` is a multiple of 64 KB and the mapping is congruent on 4 KB, 16 KB and
64 KB page kernels alike.

## Rebuild

```bash
scripts/run.sh -p linux-arm64 go
scripts/run.sh -p linux-amd64 go
scripts/vm-amd64.sh out/linux-amd64/go
```
