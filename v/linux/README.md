# V on Linux (arm64, amd64)

Tiny V binaries for `hello` and `tcp`, built by `../build-linux.sh`. Every size below is a
binary that passes `scripts/check.py` on its platform, and for amd64 also
`scripts/vm-amd64.sh` (a real x86_64 kernel).

| variant | hello amd64 | hello arm64 | tcp amd64 | tcp arm64 |
|---|--:|--:|--:|--:|
| default | 138456 | 152304 | 272872 | 307272 |
| optimized | 2912 | 3552 | 70080 | 71448 |
| extreme | 124 | 132 | 237 | 304 |

`default` and `optimized` build the shared, idiomatic sources in `../src`. `extreme` builds
the sources here: `rt.v` (syscalls), `entry.v` (entry glue, tcp only), `hello.v`, `tcp.v`.
The post-link tool is `elfgolf.py`, the linker script `link.ld`.

## default

`v -prod`. The plain V release build: a dynamically linked glibc executable carrying the V
runtime, the GC, `strconv`, backtrace support and `net` (for tcp).

## optimized

Same `../src` sources, flags and post-link steps only. Still dynamically linked to glibc.

- `-skip-unused -gc none -no-bounds-checking`: no garbage collector, no bounds checks, and
  the dead code the unused-symbol walker can prove out.
- `-d no_backtrace -d no_segfault_handler`: no `backtrace` support and no SIGSEGV handler,
  which pulls in a chunk of the runtime.
- `-d builtin_write_buf_to_fd_should_use_c_write`: stdout goes through `write()` instead of
  `fwrite`.
- `-cc gcc -cflags -Oz -flto`, plus `-fno-pie -fno-plt -fno-jump-tables -fomit-frame-pointer`,
  no stack protector, no unwind tables, no build id, `--gc-sections`, `-z norelro`,
  `-z noseparate-code` (no padding between segments), `--hash-style=gnu`.
- `strip`, then `sstrip` (drops the section header table).
- Extra flags per program and arch, only where they help (sizes after `sstrip`):
  - tcp amd64: `-fipa-pta -fno-inline-small-functions` (70976 to 70240), then
    `-Wl,--no-ld-generated-unwind-info` (70176), `-fno-signed-zeros` (70144) and
    `-ffinite-math-only` (70080).
  - tcp arm64: `-fipa-pta` (71992 to 71576), then `-fno-trapping-math` (71512) and
    `-fno-signed-zeros` (71448).
  - hello arm64: `-fno-inline-small-functions` (3568 to 3552). hello amd64: none.

  The math flags only touch floating-point code. V's string interpolation links in float
  formatting (`f64_str`, `strconv.format_fl`, and float branches that LTO inlines into
  `main`), which tcp never calls with a float, so they shrink code that does not run. `-fno-signed-zeros` and
  `-ffinite-math-only` would be wrong for a program that prints -0.0 or NaN; tcp prints
  neither.
- Left out where they do not help: `-fno-inline-small-functions` adds 8 to amd64 hello
  (2920) and 96 to arm64 tcp (71544). `-fipa-pta` adds 64 to arm64 hello (3616 with
  `-fno-inline-small-functions`; alone it changes nothing). On amd64 tcp,
  `-fno-trapping-math` adds 32 without the two other math flags (70208) and changes nothing
  with them; `-ffinite-math-only` changes nothing on arm64 tcp once the other two are in,
  `-fno-math-errno` nothing on either, and `-ffast-math` is bigger (arm64 tcp 71544 with `-fipa-pta`). The aarch64 ld
  rejects `--no-ld-generated-unwind-info`, and amd64 hello does not change with it.

| step | hello amd64 | hello arm64 | tcp amd64 | tcp arm64 |
|---|--:|--:|--:|--:|
| `v -prod` (default) | 138456 | 152304 | 272872 | 307272 |
| flags above | 6440 | 8656 | 85112 | 91640 |
| `strip` | 4376 | 5080 | 72648 | 73576 |
| `sstrip` | 2912 | 3568 | 70976 | 71992 |
| per-program flags | 2912 | 3552 | 70080 | 71448 |

With the per-program flags, before `strip` and `sstrip`: hello arm64 8728, tcp amd64 84200,
tcp arm64 91096.

gcc beats clang here (hello amd64: 2912 against 3056 bytes), and glibc-dynamic beats static
musl by far (the same hello, static with musl-gcc, stripped and sstripped: 33132 bytes on
amd64). `-z max-page-size=4096` makes no difference (same sizes on both arches, because of
`-z noseparate-code`), so it is not used.

Tried before the math and unwind flags were added, no gain: `-fno-semantic-interposition`,
`-fno-tree-loop-distribute-patterns`, `-z nognustack`, `--hash-style=sysv`, and for tcp
every mix of `-fmerge-all-constants`, `-fno-ipa-cp-clone` and `-finline-limit=0`. Bigger, on
top of the final flags: `-Os` on amd64 (hello 2952, tcp 71232; on arm64 it gives the `-Oz`
sizes), `-fno-builtin` (amd64 3144 / 70496, arm64 3760 / 71544), `-fno-inline` (amd64
3168 / 74928, arm64 3872 / 78040). Reviews also found no gain with `-d no_utf8`,
`-d no_float`, lld `--icf=all`, `-fwhole-program`, `-flto-partition=one`,
`-fvisibility=hidden`, `-fno-align-*`, `-fipa-ra`, `-fcf-protection=none`,
`-fno-stack-clash-protection`, `--disable-new-dtags` and `-z lazy`, and found that
`-Wl,--sort-section=alignment` loses against the unwind flag on amd64 tcp, and that lld
cannot link gcc's LTO objects (not re-measured).

## extreme

The logic is V. V generates C (`-no-builtin -d no_main`: no builtin module, no `main()`),
clang compiles it freestanding, the linker script lays out one segment, and `elfgolf.py`
writes minimal ELF headers over the start of it.

### Syscalls and entry (`rt.v`, `entry.v`)

- One V `fn` per syscall shape, each with one `asm` block. amd64: the register constraints
  (`a`, `D`, `S`, `d`) place the operands, the block is just `syscall`. arm64: V can only
  emit "r"-style constraints (C would use register variables), so the block also moves the
  operands into x0-x2 and x8 and the result out of x0. That costs about one instruction per
  syscall that hand-written code would not need, and is the main reason arm64 tcp is bigger.
- Syscall numbers are in the source. On amd64 the fd, number and result are `int`, which
  avoids REX.W prefixes.
- amd64: the 3-argument syscall asm lists r10 as clobbered. `syscall` leaves r10 alone (it is
  the 4th argument register, which these calls ignore), but the clobber keeps clang from
  parking tcp's fd there: r10 needs a REX prefix on every `mov edi, r10d`, and the fd lives
  in ebx instead. 3 bytes less in tcp: 4 bytes of prefixes, minus the `push rbx` that saves
  the callee-saved register (vmain never returns, but clang still saves it). The asm still
  emits only `syscall`.
- `exit` is not `@[noreturn]` (clang will not inline a call to a noreturn function at `-Oz`);
  callers follow it with `C.__builtin_unreachable()`.
- Entry glue (tcp only, asm, reads argc/argv and nothing else): amd64 `pop r9; mov r8,
  rsp`, so `vmain` gets &argv[0] as its 5th argument and argc as its 6th. The program's
  syscalls neither read nor clobber r8 and r9 (`syscall` clobbers rcx and r11), so argc
  survives the first syscall. These 5 bytes sit right before `vmain` and fall through into
  it; a linker script `ASSERT` checks that nothing comes between them. arm64 `mov x3, sp; ldr x4, [sp];
  add x5, sp, 8`, so `vmain` gets sp, argc and argv as arguments 4 to 6; it lives in two
  header holes, joined by branches. hello needs no argv: `vmain` is the entry point.
- clang `-Oz -nostdlib -ffreestanding -mgeneral-regs-only -fomit-frame-pointer
  -mllvm -disable-lsr` (without loop strength reduction the parse loop keeps one pointer
  increment instead of two). amd64 adds `-mstack-alignment=8` (no padding push before a
  call; there is no SSE code) and `-mtune=znver3` (allows the 3-operand `lea` that the
  generic tuning avoids; any x86-64 runs the result). arm64 adds `-mcmodel=tiny` (a single
  `adr` for an address).

### hello

`write(1, msg, 14)`, then `exit0()`. The 14-byte message (no NUL) sits in a header hole.
`exit0` is a separate `@[noinline]` function put in another hole with `@[_linker_section]`:
a call costs less than the inlined exit (amd64: a 5-byte call, the 7-byte exit sits in
p_paddr; arm64: one `bl`, the 3 instructions sit in e_ident[4..15]).

### tcp

- Argument check: the socket is `socket(AF_INET, SOCK_STREAM, argc - 3)`. With exactly 2
  arguments the protocol is 0, the default (TCP). With fewer it is negative, and socket()
  fails with EINVAL (`inet_create` rejects a protocol outside 0..IPPROTO_MAX-1, a check
  added in 4.4; before that no stream protocol matches a negative number, so it fails with
  EPROTONOSUPPORT, from reading the code, untested). socket(2) documents both errors for
  an unknown protocol. connect() on that
  negative "fd" then fails with EBADF, so every call with fewer than 2 arguments exits 9,
  whatever the argument holds, and never creates a socket. Tested with no argument and
  with one argument of `''`, `8080`, `1.2`, `1.2.3`, `1.2.3.4`, `localhost`, `1.2.3.4.5`,
  `0.0.0.0.0.0` and longer number lists: exit 9 on both arches, and on the real-kernel
  amd64 VM. The socket call comes
  before the parse loop, which counts argc down. Cost: 1 byte on amd64, 4 on arm64. With
  more than 2 arguments the protocol is positive (malformed arguments, unspecified by the
  spec).
- Parsing: one loop over argv[2] (the port) then argv[1] (the address). On each separator
  (any byte below '0', such as '.', or the final NUL) `x = x << 8 | number`; the digit
  arithmetic is 32-bit. The loop count comes from argc (unsigned: a decrement and a branch
  on zero, which needs argc >= 1, see below). The start value of `x`, 0x20000 (one
  instruction on both arches), has 0x02 at bits 16..23, which five numbers shift to bits
  56..63. After a byte swap, x is exactly sin_family = AF_INET, the port and the address in
  network order. It is stored in the initial stack, which is dead once parsed (over argc
  and argv[0] on arm64, argv[0] and argv[1] on amd64; sin_zero, the next 8 bytes, is not
  checked by Linux).
- One loop sends the request and copies the reply: the first `write` goes to the socket,
  the next ones to stdout. Every error exits with `-r`, the errno (ECONNREFUSED 111,
  ECONNRESET 104), which is always in 1..125; end of stream exits 0. On amd64 that exit is
  `die`, a function in the e_shoff hole (7 bytes): moving r to edi and the call take 7
  bytes, the inlined exit 11 (241 bytes with `-mno-red-zone`). Without that flag it is
  worse, 267: a function that makes no call may use the red zone, so clang can no longer
  load small constants with `push`/`pop` and uses `mov`.
- arm64: the request lives in p_paddr, and the reply is read 24 bytes at a time over
  p_paddr, p_filesz and p_memsz. The loaded headers are dead memory once the process runs,
  so the buffer address never changes.
- amd64: Rosetta write-protects the page that holds translated code, so a `read()` into the
  header fails there with EFAULT (the same binary passes on the real-kernel VM). The buffer
  is the argument area of the stack instead, and the read count is the previous length,
  still in rdx: 6 for the first read, then never more than the last chunk, and never 0.
  That saves loading a constant (a fixed count of 6 makes the binary 246 bytes, +9). The
  price is more, smaller reads: the 9911-byte test reply takes 2000 to 2300 reads (strace
  of the same loop built for arm64; strace does not work under Rosetta), against 416 with
  arm64's 24. The worst case is a server whose first chunk is 1 byte: every later read and
  write then moves 1 byte. Measured with a server that sends 1 byte, waits 100 ms, then
  sends 3 MB: tcp-extreme took 12 to 64 s on the real-kernel VM and 1.3 to 12 s under
  Rosetta over several runs (both emulate the CPU, so the time follows the load on the Mac),
  against 1 s or less for tcp-default and tcp-optimized. The output is still complete and
  the spec sets no time limit. arm64's 24-byte reads take 0.2 to 0.4 s for the same
  transfer (0.1 s for the other two).

### Size ladder

Build steps (`clang .elf` is the linked file before any post-link step):

| step | hello amd64 | hello arm64 | tcp amd64 | tcp arm64 |
|---|--:|--:|--:|--:|
| clang .elf | 5168 | 66792 | 5312 | 67008 |
| `strip` + `sstrip` (for comparison) | 4220 | 65668 | 4333 | 65840 |
| `elfgolf.py` | 124 | 132 | 237 | 304 |

The arm64 `.elf` is 66 KB only because ld puts the segment at a 64 KB aligned file offset;
`elfgolf.py` drops that gap, and `sstrip` alone cannot.

Techniques, measured one at a time from the round 1 sources:

| step | hello amd64 | hello arm64 | tcp amd64 | tcp arm64 |
|---|--:|--:|--:|--:|
| round 1 (o56a/o48a headers, glue and data in holes) | 126 | 140 | 270 | 332 |
| `-mllvm -disable-lsr` | 126 | 140 | 266 | 328 |
| parse loop driven by argc, family in the start value | | | 252 | 312 |
| 32-bit digit arithmetic | | | 249 | 312 |
| amd64: read count = previous length; arm64: read into the header | | | 246 | 308 |
| arm64: glue passes argc and argv, glue in e_ident[4..15] | | | | 304 |
| `-mtune=znver3` (amd64) | | | 245 | |
| `exit0` in a header hole | 125 | 132 | | |
| `-mstack-alignment=8` (amd64) | 124 | | | |
| amd64: glue falls through into vmain, `die` in e_shoff | | | 244 | |
| amd64 glue pops argc; unsigned argc counter | | | 239 | 300 |
| argument check as the socket protocol, start value 0x20000, amd64 glue pops into r9 | | | 240 | 304 |
| amd64: r10 listed as clobbered by the syscall asm (fd in ebx) | | | 237 | |

Round 1 also passed `-mno-red-zone -mllvm -disable-machine-licm` on amd64; with the final
sources they make no difference, so they are gone.

The row before last fixes one-argument calls. Before it, the family in the start value was the
only check: it caught no argument and a 4-number argument (the two cases the tests run),
but on arm64 an argument with 1 or 2 dots gave AF_UNSPEC (connect returns 0, then the
write dies of SIGPIPE) and one with no dot connected to an Internet address, and on both
arches a 5-number argument connected to the address it spelled. A start value with no zero byte in 3..6 (amd64's
-0xfe0000, 2 instructions on arm64) also gives 304 on arm64, but only covers arguments of
up to 4 numbers.

What is left: amd64 hello is 104 bytes of header and 20 of code, tcp 96 and 141. arm64
hello is 104 and 7 instructions, tcp 96 and 52 instructions.

## elfgolf.py (generic ELF header golf)

Takes a static `ET_EXEC` (no interpreter, no TLS) and rewrites it with one PT_LOAD and the
smallest header that still loads. It reads the segments, entry point, machine and section
headers from the input and contains no bytes of the program.

1. **One segment.** The PT_LOADs become one read+write+execute segment, from the start of
   the first to the end of the last, with zeros in the gaps. Every byte keeps its address,
   so nothing is relocated. The other program headers and the section headers go.
2. **Overlapping headers.** The 56-byte program header starts at offset 56 (`o56`) or 48
   (`o48`) of the 64-byte ELF header. binfmt_elf reads e_phoff, e_phentsize (must be 56)
   and e_phnum, never the section header fields, so e_phnum/e_shentsize double as p_type,
   and at 48 e_flags/e_ehsize too, with p_offset's low byte landing in e_phnum (so p_offset
   is 1 and p_vaddr the page + 1). The "a" layouts (`o56a` 104 bytes, `o48a` 96) start the
   code over p_align, which Linux only uses for ET_DYN. This is how the kernel code behaves
   (fs/binfmt_elf.c), not a documented guarantee.
3. **Header holes.** The headers are written over the first bytes of the 64 KB page the
   program starts in. The program is the contents of its allocated sections (for an input
   without section headers: its nonzero bytes, minus its own ELF and program headers), and
   it may only overlap the fields the loaders ignore: e_version, e_shoff, e_flags/e_ehsize
   when free, p_paddr, and on aarch64 e_ident[4..15]; elfgolf stops if a section covers any
   other header byte. `link.ld` puts the arm64 entry glue, the constants and the small
   `exit0`/`die` functions there, each in its own output section. Every other byte that is
   not the program (the input's own headers, padding) becomes a header byte or zero, so an
   unused e_version is 1 and an unused e_ident keeps its class, data and version bytes.
   Going by sections also keeps an all-zero piece in a hole intact (an earlier version took
   the nonzero bytes for the program, and would have written e_ident's 02 01 01 over it).
   Rosetta rejects any other value in e_ident[4..6] (class, data, version) and anything but
   zero in e_ident[8..15] (tested with 0xa5 in each byte; it accepts any EI_OSABI, e_ident[7],
   a 1-byte hole not worth using), so for x86_64 e_ident has no holes. Of e_ident, the arm64 kernel only checks the 4-byte magic (tested: garbage in
   e_ident[4..15] loads), again kernel behaviour rather than documentation. On arm64 both
   extreme binaries keep code in e_ident[4..15], EI_CLASS and EI_DATA included, so tools
   that go by those bytes cannot identify them: `file` prints "ELF invalid class invalid
   byte order" (hello) or "ELF, unknown class 227" (tcp), and readelf shows an unknown class. The kernel reads them as
   ELF64 (binfmt_elf picks the format from e_machine, EM_AARCH64, and never looks at
   EI_CLASS). The amd64 binaries keep a valid e_ident and e_version (`file`: "ELF 64-bit LSB
   executable, x86-64, version 1 (SYSV), statically linked").
4. **bss from trailing zeros.** Trailing zero bytes are not written; `p_memsz > p_filesz`.

It works on ordinary static links too. A small C program (clang `-static -nostdlib`) linked
by GNU ld (default, `-z separate-code`, `-N`) and lld (default, `-N`), and an `sstrip`ped
copy, all run after elfgolf on both arches (amd64: Rosetta and the real-kernel VM). They
keep the gaps between their segments: the GNU ld default link goes from 9296 to 8253 bytes
on amd64 (its `-N` link from 1616 to 573), and an lld link on arm64 grows from 1888 to
66300, as lld puts the code 64 KB after the headers. A program whose code starts at a page
boundary (`-Wl,-Ttext=0x10000`) is refused: the ELF header has to go there.

`elfgolf.py -l LAYOUT -H` prints the header size, `-h [aarch64]` the holes.

## Loader behaviour relied on, and limits

- One read+write+execute segment (the code page also holds the arm64 read buffer and is
  never written on amd64). A system that refuses W+X mappings (SELinux `execmem` denied,
  PaX MPROTECT) will not run these binaries.
- The segment starts on a 64 KB boundary with p_offset 0 or 1, so the layout loads on 4, 16
  and 64 KB page kernels. Tested on 4 KB pages (OrbStack arm64 kernel 7.2, Rosetta, the
  amd64 qemu VM with Debian 6.12.113+deb13-amd64), 16 KB pages (Debian
  6.12.113+deb13-arm64-16k) and 64 KB pages (Ubuntu 6.8.0-147-generic-64k), the last two
  under qemu-system-aarch64 (`-M virt -cpu max`, KernelPageSize read from
  /proc/self/smaps): all six arm64 binaries pass the spec tests on both, and again with an
  empty environment (`env -i`) and with 3 variables of 100 KB each.
- The extreme binaries load at 0x400000, the usual x86-64 base. vm.mmap_min_addr is 4096 on
  OrbStack (the arm64 and the Rosetta containers) and on the 16 KB VM, 32768 on the 64 KB VM
  and 65536 on the amd64 VM. 0x10000, the lowest 64 KB boundary above 0 and what an
  earlier version used, is exactly the lowest address a 65536 limit allows; 0x400000 costs
  the same bytes (amd64 loads addresses as 32-bit immediates either way, arm64 code is
  PC-relative).
- The exit status of a failed tcp is the errno of the failing call. Nothing relies on ASLR,
  the environment size, initial register values or timing.
- tcp needs argc >= 1. Since Linux 5.18 (commit dcd46d897adb, "exec: Force single empty
  string when argv is empty") the kernel inserts an empty argv[0] when execve gets an empty
  argv. On an older kernel, an exec with an empty argv would crash tcp (a signed counter
  avoids that for 4 to 5 bytes).

## Tried and dropped

- gcc instead of clang: bigger on both arches (amd64 132/330, arm64 224/528 against round 1).
- A 3-instruction `svc` stub called with the C ABI on arm64 (no operand moves): vmain then
  saves x19, x20 and x30, which costs more than the moves (348 against 332 in round 1).
- `adr` for the buffer address inside the arm64 asm ("S" constraint): clang only accepts it
  with the symbol named in the asm, which would make the asm program-specific.
- TCP Fast Open (`sendto` with MSG_FASTOPEN instead of connect + write): the 6-argument
  syscall needs r8-r10 / x3-x5 moves and loses on both arches.
- Reading the reply into the request's header hole on amd64: EFAULT under Rosetta (see tcp).
- amd64 tcp, a fixed read count of 120 (the stack above argv always holds at least the
  auxv): 246 bytes, as clang keeps the constant in r14.
- amd64 tcp, r9 listed as clobbered too, to get `dst` out of r9 (REX prefixes): 240, as
  argc then has to move out of r9 before the socket call.
- `@[callconv: 'preserve_none']` on vmain (no callee-saved registers, so no `push rbx`): V
  only accepts stdcall, fastcall and cdecl. `-mllvm -enable-ipra` does not drop the push.
- amd64 tcp, the parse loop's byte as `int` or `i64` instead of `u32`: 237 either way (clang
  compares the zero-extended byte as 64-bit in all three).
- Many other LLVM options (`regalloc=basic`, `-Os`, block placement, cmov, misched, LICM on
  arm64, `-mcpu` variants on arm64): no gain or worse.
- V's machine-code backends (`v -v2 -b x64`/`arm64`): not usable with the V install in the
  image (`vlib/v2` is missing).
