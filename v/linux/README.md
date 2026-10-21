# V on Linux (arm64, amd64)

Tiny V binaries for `hello` and `tcp`, built by `../build-linux.sh`. Every size below is a
binary that passes `scripts/check.py` on its platform, and for amd64 also
`scripts/vm-amd64.sh` (a real x86_64 kernel).

| variant | hello amd64 | hello arm64 | tcp amd64 | tcp arm64 |
|---|--:|--:|--:|--:|
| default | 138456 | 152304 | 272872 | 307272 |
| optimized | 2912 | 3552 | 70080 | 71448 |
| extreme | 123 | 124 | 231 | 268 |

`default` and `optimized` build the shared, idiomatic sources in `../src`. `extreme` builds
the sources here: `rt.v` (syscalls), `hello.v`, `tcp.v`. The post-link tool is `elfgolf.py`,
the linker script `link.ld`.

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

### Syscalls and entry (`rt.v`)

The syscall helpers take the arguments in order and then the number: `sys3(a, b, c, n)`.
Inline asm is limited to the syscall instruction and getting the operands into place.

- **amd64** uses the register constraints (`a`, `D`, `S`, `d`), so the asm block is just
  `syscall`. The fd, number and result are `int`, which avoids REX.W prefixes. The
  3-argument asm lists r10 as clobbered (and r9 too in the read/write helper, which tcp
  uses in its loop). `syscall` leaves r10 and r9 alone, but the clobber keeps clang from
  parking a value that lives across a syscall there (tcp's fd, the write number): r10 and
  r9 need a REX prefix on every move, lower registers do not.
- **arm64** has no asm constraint for a given x register (C would use register variables,
  which V cannot express). The old code solved this by moving the operands into x0-x2
  inside the asm, one extra instruction per argument. The new helper takes an operand "in
  place" and makes the compiler prove it is in the right register: the asm names a section
  after the registers it got (`.section '.ck.ax0.bx1.cx2'` when a, b and c are in x0, x1,
  x2), `link.ld` discards exactly those names and an `ASSERT` stops the link on any other.
  So the asm is only `mov x8, <number>; svc 0` (the number is always a constant), and the
  operands cost no moves at all when the code is arranged so they already sit in x0-x2. To
  arrange that, the program is split into small functions whose parameters are the syscall
  arguments (a function's first three arguments arrive in x0-x2), and the per-arch shapes
  that still need a constant moved (`sys3b`, protocol in x2 but 1 moved to x1; `exitm`,
  status moved to x0) have their own helper with the matching check. This is the main
  saving on arm64 this round: the operand moves are gone.
- `exit` is not `@[noreturn]` (clang will not inline a call to a noreturn function at `-Oz`);
  callers follow it with `C.__builtin_unreachable()`.
- Entry glue is the top-level `asm` block in `tcp.v`, which reads argc/argv and nothing
  else. amd64 `pop r9; mov r8, rsp`, so `vmain` gets &argv[0] as its 5th argument and argc
  as its 6th. The program's syscalls neither read nor clobber r8 and r9 (`syscall` clobbers
  rcx and r11), so argc survives the socket call. These 5 bytes sit right before `vmain`
  and fall through into it; a linker script `ASSERT` checks that nothing comes between them.
  arm64 `add x3, sp, 8; b vmain`, so `vmain` gets &argv[0] as its 4th argument (a register
  the 3-argument syscalls leave alone) and reads argc from the word before it; the glue
  lives in the e_shoff hole. hello needs no argv: `vmain` is the entry point.
- clang `-Oz -nostdlib -ffreestanding -mgeneral-regs-only -fomit-frame-pointer
  -mllvm -disable-lsr` (without loop strength reduction the parse loop keeps one pointer
  increment instead of two). amd64 adds `-mstack-alignment=8` (no padding push before a
  call; there is no SSE code) and `-mtune=znver3` (allows the 3-operand `lea` that the
  generic tuning avoids; any x86-64 runs the result). amd64 tcp also adds
  `-mllvm -regalloc=basic` (the basic register allocator, 2 bytes less here; it changes
  only which registers the parse loop uses). arm64 adds `-mcmodel=tiny` (a single `adr` for
  an address).

### hello

`write(1, msg, 14)`, then `exit(0)`. The program is split into functions that call each
other with the registers the next one needs as plain arguments, so the first ones fit in
header holes. The 14-byte message (no NUL) sits in the 14-byte hole at offset 40. On amd64
`vmain` (`push 14; pop rdx; call`) is in the p_paddr hole and its callee does the two
syscalls at `CODE`. On arm64 `vmain` (`adr x1, msg; mov w0, #1; bl`) is in e_ident[4..15],
a second function (`mov w2, #14; bl`) in p_paddr, and the two syscalls at `CODE`. A chained
call costs less than inlining, because each piece can then live in a hole.

### tcp

- Argument check: the socket is `socket(AF_INET, SOCK_STREAM, argc - 3)`. With exactly 2
  arguments the protocol is 0, the default (TCP). With fewer it is negative, and socket()
  fails with EINVAL (`inet_create` rejects a protocol outside 0..IPPROTO_MAX-1, a check
  added in 4.4; before that no stream protocol matches a negative number, so it fails with
  EPROTONOSUPPORT, from reading the code, untested). socket(2) documents both errors for an
  unknown protocol. The socket fd is then negative, and the copy loop's read on it fails
  with EBADF, so every call with fewer than 2 arguments exits 9, whatever the argument
  holds, and never connects. Tested with no argument and with one argument of `127.0.0.1`,
  `8080`, `8080.127.0.0.1`, `1.2.3`: exit 9 on both arches, and on the real-kernel amd64 VM.
  With more than 2 arguments the protocol is positive (malformed arguments, unspecified by
  the spec).
- Parsing: one loop over argv[2] (the port) then argv[1] (the address). On each separator
  (amd64: any byte below '0', such as '.', or the final NUL; arm64: any byte with bit 4
  clear, one `tbz`, true of '.' and NUL and false of the digits) `x = x << 8 | number`. The
  loop count comes from argc (unsigned: a decrement and a branch on zero, which needs
  argc >= 1, see below). The start value of `x`, 0x20000 (one instruction on both arches),
  has 0x02 at bits 16..23, which five numbers shift to bits 56..63. After a byte swap, x is
  exactly sin_family = AF_INET, the port and the address in network order. It is stored in
  the initial stack over argv[0], which is dead once parsed; sin_zero, the next 8 bytes
  (argv[1]), is not checked by Linux.
- One loop sends the request and copies the reply: the first `write` goes to the socket, the
  next ones to stdout. The connect result is folded into the first write's fd
  (`write(fd | r, ...)`): when connect fails, r is -errno (high bits set), so the fd is bad
  and the write is ignored, but the loop's read is still on the real socket fd and returns
  the error, which the exit path negates. A clean EOF (read returns 0) exits 0, any error
  exits with its errno (ECONNREFUSED 111, ECONNRESET 104, EBADF 9, ENOTCONN 107), always in
  1..125. The exit is a separate function in a header hole: amd64 `die` in the e_shoff hole
  (7 bytes: `neg edi; push 60; pop rax; syscall`), arm64 `die` in e_ident[4..15] (12 bytes).
- arm64: the request lives in p_paddr, and the reply is read 6 bytes at a time over it (the
  read count is the previous length: 6 for the request, then the last read, so at most 6).
  The loaded headers are dead memory once the process runs, so the buffer address never
  changes.
- amd64: Rosetta write-protects the page that holds translated code, so a `read()` into the
  header fails there with EFAULT (the same binary passes on the real-kernel VM). The buffer
  is the argument area of the stack instead, and the read count is the previous length,
  still in rdx: 6 for the first read, then never more than the last chunk, and never 0. That
  saves loading a constant. The price is more, smaller reads: the worst case is a server
  whose first chunk is 1 byte, which then makes every later read and write move 1 byte. The
  output is still complete and the spec sets no time limit. arm64 is the same: at most 6
  bytes per read.

### Size ladder

Build steps (`clang .elf` is the linked file before any post-link step):

| step | hello amd64 | hello arm64 | tcp amd64 | tcp arm64 |
|---|--:|--:|--:|--:|
| clang .elf | ~5100 | ~66800 | ~5200 | ~66900 |
| `elfgolf.py` | 123 | 124 | 231 | 268 |

The arm64 `.elf` is 66 KB only because ld puts the segment at a 64 KB aligned file offset;
`elfgolf.py` drops that gap, and `sstrip` alone cannot.

Techniques this round, from the previous sizes (124 / 132 / 237 / 304):

| step | hello amd64 | hello arm64 | tcp amd64 | tcp arm64 |
|---|--:|--:|--:|--:|
| previous round | 124 | 132 | 237 | 304 |
| arm64: in-place syscall operands, checked by section name | 124 | 124 | 237 | 288 |
| arm64: exit status folded into the write fd, errno in a 3rd arg | | | | 280 |
| hello split into hole-resident functions (both arches) | 123 | 124 | | |
| amd64 tcp: read/write helper clobbers r9 (write number out of r9) | | | 235 | |
| amd64 tcp: separator test on bit 4 (`test sil, 16`), as on arm64 | | | 232 | |
| amd64 tcp: `-mllvm -regalloc=basic` | | | 231 | |

The in-place operand trick (arm64) replaced the per-argument `mov` the old asm emitted, and
also let the connect and the copy loop become small functions whose parameters already sit
in x0-x2. Folding the exit status into the first write's fd removed the explicit connect
check (`if r != 0 { die(r) }`), since a failed connect leaves the socket readable only into
the same error path.

What is left: amd64 hello is 104 bytes of header and 19 of code, tcp 96 and 135. arm64
hello is 104 and 5 instructions (plus 5 in holes), tcp 96 and 43 instructions.

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
   other header byte. `link.ld` puts the entry glue, the constants and the small `die` /
   second-stage `hello` functions there, each in its own named output section (`.text.hN`
   placed at header offset N). Every other byte that is
   not the program (the input's own headers, padding) becomes a header byte or zero, so an
   unused e_version is 1 and an unused e_ident keeps its class, data and version bytes.
   Going by sections also keeps an all-zero piece in a hole intact (an earlier version took
   the nonzero bytes for the program, and would have written e_ident's 02 01 01 over it).
   Rosetta rejects any other value in e_ident[4..6] (class, data, version) and anything but
   zero in e_ident[8..15] (tested with 0xa5 in each byte; it accepts any EI_OSABI, e_ident[7],
   a 1-byte hole not worth using), so for x86_64 e_ident has no holes. Of e_ident, the arm64 kernel only checks the 4-byte magic (tested: garbage in
   e_ident[4..15] loads), again kernel behaviour rather than documentation. On arm64 both
   extreme binaries keep code in e_ident[4..15], EI_CLASS and EI_DATA included (the first
   byte is 0x21 for hello, 0xe0 for tcp), so tools that go by those bytes cannot identify
   them: `file` reports an invalid class and `readelf` an unknown class. The kernel reads
   them as ELF64 (binfmt_elf picks the format from e_machine, EM_AARCH64, and never looks at
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

- One read+write+execute segment (the code page also holds the arm64 read buffer and the
  request, and is never written on amd64, where the read buffer is the stack). A system that
  refuses W+X mappings (SELinux `execmem` denied, PaX MPROTECT) will not run these binaries.
- The segment starts on a 64 KB boundary with p_offset 0 or 1, so the layout loads on 4, 16
  and 64 KB page kernels. The ELF layout (p_offset, p_vaddr, p_align, the o48a/o56a overlap
  and the 0x400000 base) is unchanged from the previous round, which was tested on 4 KB
  pages (OrbStack arm64 kernel 7.2, Rosetta, the amd64 qemu VM with Debian
  6.12.113+deb13-amd64), 16 KB pages (Debian 6.12.113+deb13-arm64-16k) and 64 KB pages
  (Ubuntu 6.8.0-147-generic-64k), the last two under qemu-system-aarch64 (`-M virt -cpu
  max`): all arm64 binaries passed on both. This round changed only the code bytes inside
  the segment, not the layout, so that conclusion carries over; the harness has no arm64 VM,
  so the 16/64 KB runs were not re-done this round. The 4 KB OrbStack kernel and the amd64
  VM are run by `scripts/run.sh` and `scripts/vm-amd64.sh` every build.
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

- arm64 tcp, inlining connect into `vmain` to drop the `bl` that falls into the next
  function (4 bytes): the register allocator then scrambles the socket's operands and the
  section-name check fails the link. The function split keeps the operands in x0-x2 for
  free, which is worth more.
- arm64 tcp, socket call before the parse loop (so argc is consumed once): the socket fd
  must then survive the loop, which forces it into a callee-saved register and a prologue
  save, or scrambles the operands; the link fails. Same 268 when it does build.
- amd64 tcp, passing argc in rdx/rcx/rsi/rdi instead of r9: all 239 (the glue pop then needs
  a byte, or the value moves before the socket call).
- amd64 tcp, clobbering the callee-saved registers (rbx, rbp, r12-r15) in the syscall asm to
  force the fd into a caller-saved register that survives the syscall (r8-r10): clang then
  spills the buffer pointer and saves six registers, much bigger.
- amd64 tcp, `-mllvm -disable-machine-licm`, `-mno-red-zone`, `-machine-sink-split=false`,
  `-regalloc=basic` without the bit-4 parse change, and several `-mtune` CPUs: 231 to 233,
  none below 231.
- amd64 tcp parse loop as `u8`, `u32`, `i64` or `(c & 15)`: 232 to 237; the `u64` byte with
  the bit-4 separator test is the smallest (232 before `-regalloc=basic`).
- gcc instead of clang: bigger on both arches.
- TCP Fast Open (`sendto` with MSG_FASTOPEN instead of connect + write): the 6-argument
  syscall needs r8-r10 / x3-x5 moves and loses on both arches.
- `@[callconv: 'preserve_none']` on vmain (no callee-saved registers, so no `push`): V only
  accepts stdcall, fastcall and cdecl. `-mllvm -enable-ipra` does not drop the push either.
- V's machine-code backends (`v -v2 -b x64`/`arm64`): not usable with the V install in the
  image (`vlib/v2` is missing).
