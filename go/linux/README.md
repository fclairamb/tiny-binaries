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
| extreme   | **120**     | **125**     | **264**   | **248**   | no runtime, raw syscalls, one PT_LOAD, golfed header |

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
64 KB. The optimized, upx and tinygo binaries keep lld's or gc's 64 KB segment alignment, and the
extreme binaries put their one segment at `p_vaddr` 0x400000 (or 0x400001 under o48a) with
`p_offset` 0 (or 1), so `p_vaddr - p_offset` is a multiple of 64 KB. Nothing in the extreme layout
depends on 4 KB-specific behaviour, so it loads under 4, 16 and 64 KB page kernels alike.

Verified this round on OrbStack's 4 KB arm64 kernel (`scripts/run.sh -p linux-arm64`, which the
task notes is authoritative for arm64). The harness has no arm64 16/64 KB VM, so the extreme
binaries were not re-run on those this round; the Rust and V slices, whose extreme binaries use the
same one-segment-at-0x400000 layout, were manually checked on `6.12.113+deb13-arm64-16k` and
`6.8.0-147-generic-64k` under `qemu-system-aarch64 -M virt -cpu max`. The UPX environment limit
below is the same on all three page sizes.

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

The main event. Custom sources under `extreme/`, no runtime at all, built with TinyGo. This round
rewrote all four: hello arm64 went from 132 to 120, tcp arm64 from 300 to 264, tcp amd64 from 268
to 248; hello amd64 stays 125.

### How the language still does the work

TinyGo's compiler turns a call to a function linked to `golang.org/x/sys/unix.RawSyscallNoError*`
into the bare `syscall` / `svc #0` instruction with the right register constraints (see
`createRawSyscall` in TinyGo's `compiler/syscall.go`). So `sys/sys.go` declares two such functions
with `//go:linkname` and the rest is ordinary Go: the IP and port parsing, the sockaddr layout, the
copy loop, the error checks. No `.s` files, no machine code in byte arrays. The only non-logic
pieces are LLVM intrinsics for the initial stack pointer, not hand-written asm:

- arm64 tcp: `llvm.stacksave.p0`. At `_start` it is the entry stack pointer, which points at `argc`;
  it lowers to `mov x9, sp` and the first `ldr x8, [x9], #8` reads `argc` and advances to `&argv[0]`
  in one post-indexed load (4 bytes less than `sponentry` plus a separate add).
- amd64 tcp: `llvm.addressofreturnaddress.p0`. At the ELF entry nothing was pushed, so this is `rsp`
  itself, which points at `argc`.
- hello needs neither: it only writes and exits.

### Exit status and the argument check

`RawSyscallNoError3` returns the kernel's raw return value, so a failed `read` or `connect` comes
back as `-errno` (for example -104, `ECONNRESET`), not a thrown error. tcp ends at one exit with
status `-r`, where `r` is the last syscall result: 0 after a clean EOF, `-errno` on failure.

The argument check is the socket's protocol, `argc - 3` (the V slice's idea), computed before the
socket call:

- exactly 2 arguments: protocol 0, the default (TCP).
- fewer than 2: protocol negative, which `socket()` rejects (`EINVAL`; on kernels before 4.4,
  `EPROTONOSUPPORT`). The bad fd then makes `connect()` fail, so every call with fewer than 2
  arguments exits non-zero whatever the one argument holds, and no packet is sent. This is what the
  new one-argument tests need (`<port>`, `<port>.127.0.0.1`, `1.2.3`): the arg count decides, not
  the content. Checked with no argument and with `''`, `8080`, `1.2`, `1.2.3`, `8080.127.0.0.1`:
  exit 9 on both arches, under Rosetta and on the real amd64 kernel.
- more than 2: protocol positive, malformed arguments (unspecified by the spec).

`connect`'s result is folded into the fd with `fd |= r`: on success `r` is 0 and the fd is
unchanged; on failure the fd becomes garbage, the first write fails, the read fails, and the exit
status is that `-errno`, all in 1..125. That single merged exit replaces a branch per error.

### The build pipeline, and why it is not plain `tinygo build`

`tinygo build` links straight to an executable and does not expose the LLVM backend flags, or the
two IR edits, that save the last bytes. So the extreme build goes through a text IR module:

1. `tinygo build -o x.ll`: TinyGo compiles the Go to an LLVM IR module (text, so step 2 can edit it).
2. amd64 only, two edits to `x.ll` with `sed`:
   - `tune-cpu=k8` on every function: LLVM then folds the digit math `cur*10 + c - 48` into one
     `lea`. Same x86-64 ISA, a tuning hint only. Saves 2 bytes on tcp.
   - an `override-stack-alignment` module flag set to 8 (what clang's `-mstack-alignment=8` sets,
     which does not apply to IR input): without it LLVM assumes a 16-byte stack and pushes a
     register to realign before a `call`. There is no SSE code, so 8 is enough. hello segfaults
     without it on the real kernel.
3. `tinygo clang -c -Oz ... x.ll -o x.o`: TinyGo's own bundled clang (the same LLVM 22 backend)
   lowers the IR to an object, with backend flags `tinygo build` hides:
   - both arches `-mllvm -disable-lsr`: no loop strength reduction, so the parse loop keeps one
     pointer increment instead of two. 8 bytes on arm64 tcp.
   - amd64 `-mllvm -disable-machine-licm`: do not hoist loop-invariant constants out of the copy
     loop (a hoisted constant can need a callee-saved register, whose spill turns the red zone on,
     and with the red zone on LLVM stops using `push imm8; pop reg` for small constants).
   - arm64 `-mcmodel=tiny`: PC-relative `adr` for the one address instead of `adrp; add`.
4. `tinygo ld.lld ... -T x.ld`: link one `PT_LOAD` from 0x400000. `x.ld` is `one.ld` with its
   `@FL@` placeholder replaced by the segment flags (per program, below).
5. `elfgolf.py`: overlap the headers, fill the holes, strip the rest (below).

### Tricks in the source

- `sys.Assume(false)` after an exit syscall. `Assume` is `//export llvm.assume`; `assume(false)`
  lowers to `unreachable`, so no `ret` or trap follows the syscall and the function is noreturn.
- The exit function is placed in its own section (`.hole40` / `.hole80`) and one.ld drops it into a
  header hole, so it costs zero file bytes. Its argument is already in the syscall's first argument
  register.
  - arm64 tcp `exit`: `mov w8, #93; svc #0`, 8 bytes, in the `e_shoff` hole (40..47). `//export`
    keeps LLVM from folding the constant status into the body. The negation `-r` is done at the one
    call site.
  - amd64 tcp `die`: `neg edi; push 60; pop rax; syscall`, 7 bytes, in the `e_shoff` hole. The
    negation is in the hole, so the call site is `mov edi, eax; call die`.
- hello arm64 is split into three functions that tail-chain through header holes, so each lives in a
  different hole and only the last costs file bytes: `_start` (`adr x1, msg; mov w0, #1; bl h3`, the
  12-byte `e_ident[4..15]` hole), `h2` (`mov w2, #14; b h3`, the 8-byte `p_paddr` hole), and `h3`
  in the code (the two syscalls). The exit syscall number is **read out of `p_flags`**: the segment
  flags are linked as `0x5d`, whose low 3 bits are `PF_R | PF_X` (what the kernel reads) and whose
  upper bits hold `93`, the exit number, which the kernel ignores. `ldp w8, w0, [x1, #20]` loads
  that 93 into `w8` and the adjacent `p_offset` (0) into `w0`, so one load sets up `exit(0)`. Saves
  4 bytes over two `mov`s. Relies on the kernel ignoring the upper bits of `p_flags` (standard: only
  `PF_R/W/X` are read); documented here as the one exotic dependency.
- hello amd64 keeps `_start` in the code region: an entry point in a header hole is accepted by
  Rosetta but faults on the real x86_64 kernel (the exit fragment it *jumps* to may sit in a hole,
  only the entry may not). It calls `exit` (in the `p_paddr` hole).

### The parse itself

One loop reads argv[argc-1] down to argv[1], folding each dotted-decimal field into a `uint64` at
every separator (any byte below `'0'` on amd64, any byte with bit 4 clear on arm64, which covers
`.` and NUL): `x = x<<8 | field`. `x` starts at `AF_INET<<16` (`2<<16`), so after the port and the
four address bytes its byte swap (`bswap`/`rev`, one instruction) is the 8 `sockaddr_in` bytes
(family, port, address) in network order, written over `argv[0]` on the stack (dead by then).
`connect` gets a length of 16, so `sin_zero`, the next 8 bytes, is whatever follows: Linux does not
read it for an AF_INET connect (`tcp_v4_connect` checks only the length and the family). The read
buffer is a stack slot (amd64) or the 6-byte request hole (arm64), each far larger than needed, and
the read count is the previous write length (6, then the last read), so a read is at most 6 bytes.
Malformed arguments (extra octets, a huge IP) are unspecified by the spec; the loop does not bound
them.

### ELF layout (one.ld + elfgolf.py)

`one.ld` lays a single `PT_LOAD` from 0x400000 (the usual non-PIE base, far above any
`vm.mmap_min_addr`) and places input sections named `.holeN` at header offset N, so the string
constant, the entry glue and the small exit functions go into the header holes. `elfgolf.py` is a
copy of `rust/linux/elfgolf.py` (the Rust slice's generic tool; it adds the arm64 `e_ident[4..15]`
hole and detects the program by its allocated sections, both of which this round needs, where the
old `c/linux` copy did neither). It writes a minimal ELF header that overlaps the program header
into its own tail, keeps the hole bytes, and drops the section headers. It contains no bytes of any
program.

- hello uses layout `o56a` (104-byte header): "Hello, World!
" in the 14-byte hole at 40..53, and
  a fragment in `p_paddr` (80..87). arm64 also uses the `e_ident[4..15]` hole for `_start`.
- tcp uses layout `o48a` (96-byte header): the exit function in the `e_shoff` hole (40..47),
  "hello
" in `p_paddr` (72..77). arm64 also uses `e_ident[4..15]` for `_start`.

The undocumented loader rules this relies on (static `ET_EXEC`; header fields Linux ignores:
`e_shoff`, `e_flags`, `p_paddr`, the upper bits of `p_flags`, `p_align` for `ET_EXEC`, and on arm64
`e_ident[4..15]`; `p_offset` congruent to `p_vaddr` modulo the page size) are listed in `elfgolf.py`
and in `rust/linux/README.md` and `v/linux/README.md`. Rosetta is stricter than the real kernel
about `e_ident`, so the amd64 binaries keep a standard `e_ident` and pass both Rosetta (`run.sh`)
and the real kernel (`vm-amd64.sh`).

Size ladder (there is no separate strip step; elfgolf.py drops the section headers and the gap lld
leaves before the code):

| step | hello arm64 | hello amd64 | tcp arm64 | tcp amd64 |
|------|-------------|-------------|-----------|-----------|
| lld output | 113936 | 52184 | 115024 | 53888 |
| `elfgolf.py` | **120** | **125** | **264** | **248** |

(lld places the segment at file offset 64 KB on arm64 and 4 KB on amd64, hence the big lld files.)

Byte accounting (header + code):

- hello arm64 (120): 104-byte o56a header (12-byte `_start` in `e_ident`, 14-byte string at 40,
  8-byte `h2` in `p_paddr`, exit number 93 in `p_flags`), then 16 bytes of `h3` (4 instructions).
- hello amd64 (125): 104-byte header (14-byte string at 40, 7-byte `exit` in `p_paddr`), then 21
  bytes of `_start` in the code region.
- tcp arm64 (264): 96-byte o48a header (12-byte `_start` in `e_ident`, 8-byte `exit` in `e_shoff`,
  6-byte "hello\n" in `p_paddr`), then 168 bytes of code.
- tcp amd64 (248): 96-byte header (7-byte `die` in `e_shoff`, 6-byte "hello\n" in `p_paddr`), then
  152 bytes of code.

### Page-size independence

The single `PT_LOAD` starts at `p_vaddr` 0x400000 (o56a, `p_offset` 0) or 0x400001 (o48a,
`p_offset` 1), so `p_vaddr - p_offset` is a multiple of 64 KB and the mapping is congruent on 4 KB,
16 KB and 64 KB page kernels alike. See Page sizes above for what was and was not re-run this round.


## Rebuild

```bash
scripts/run.sh -p linux-arm64 go
scripts/run.sh -p linux-amd64 go
scripts/vm-amd64.sh out/linux-amd64/go
```
