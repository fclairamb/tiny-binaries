# Assembly on Linux (linux-arm64, linux-amd64)

Hand-written assembly for `hello` and `tcp`, built by `asm/build-linux.sh` inside the
`docker/Dockerfile` image. One script serves both arches; it branches on `uname -m`. The
only per-arch difference in `default`/`optimized` is the raw syscall numbers; `extreme` is a
separate hand-built ELF per arch.

All sizes below are bytes of a binary that passed `scripts/check.py` on its platform, and for
amd64 also `scripts/vm-amd64.sh` on a real x86_64 kernel. amd64 has to pass both because the
Mac runs the amd64 container under Rosetta, a user-mode translator with its own ELF loader, and
Rosetta and the real kernel disagree on some ELF tricks.

| variant | hello amd64 | hello arm64 | tcp amd64 | tcp arm64 |
|---|--:|--:|--:|--:|
| default | 4704 | 936 | 5184 | 1440 |
| optimized | 167 | 166 | 432 | 454 |
| extreme | 116 | 124 | 227 | 276 |

The assembly entry is the floor the languages are measured against. On three of the four Linux
columns it is strictly the smallest on the board, with a margin: amd64 hello 116 (next is Rust
123), amd64 tcp 227 (next is V 237, with Rust at 234 but failing the single-argument tests),
and arm64 tcp 276 (next is Go 300). The fourth, arm64 hello, is 124, tied with Rust: 124 is the
information-theoretic floor for this program, so no language can go below it and assembly only
matches it (see the floor argument under `extreme`). The previous asm arm64 numbers (hello 132,
tcp 304) came from not using the two holes the arm64 kernel ignores that the compiled slices
had already found; this round adopts them.

The `hello` margins are small because `hello` is so short that the ELF header dominates the
file and every language that golfs the header lands at the same floor; the `tcp` margins are
wider because there the hand-written code is meaningfully denser than a compiler's.

Sources: `hello-<arch>.s` and `tcp-<arch>.s` for `default`/`optimized` (shared), and
`hello-<arch>-extreme.*` / `tcp-<arch>-extreme.*` for `extreme`.

## default

`as` then `ld`, both with defaults. Raw `write`/`exit` (hello) or the full socket sequence
(tcp) through syscalls, a custom `_start`, no libc. amd64 is larger than arm64 here only
because the two arches' default `ld` layouts pad differently.

## optimized

Same sources as `default`. Only link flags and post-link steps change:

- `ld -s` drops the symbol table, `--build-id=none` drops the build-id note, `-z
  noseparate-code` folds everything into one R+X segment with no page padding.
- `sstrip` then removes the section header table and section-header strings, which a loader
  never reads.

Nothing uses `-n`/`-N`: that would move the text out of the segment that spans the ELF header,
and Rosetta rejects an amd64 binary whose first load segment does not span the ELF header. The
real kernel accepts it, but amd64 has to pass both. The sources keep their only writable state
on the stack, so there is no data segment and one R+X segment at file offset 0 covers
everything. `-n`, `-N`, `--max-page-size=4096`, `-z norelro`, `-z noseparate-code` and `as
-O2/-Os` all land on the same bytes after `sstrip`; only stripping the symbols matters.

Size ladder (`ld` default, then the size flags, then `sstrip`):

```
                arm64            amd64
hello           936 -> 376 -> 166   4704 -> 376 -> 167
tcp            1440 -> 664 -> 454   5184 -> 648 -> 432
```

## extreme

The whole file is the ELF image: one `PT_LOAD`, the 56-byte program header overlapping the ELF
header, and the message/request plus some code hidden in header fields the kernel ignores. No
linker script and no post-link golf tool: the source already contains the final bytes.

- **x86_64** is assembled flat with `nasm -f bin`; the output is the image.
- **aarch64** cannot use `ld --oformat binary` ("cannot change output format whilst linking
  AArch64 binaries"), so the source is assembled, linked to an ordinary ELF with text based at
  `0x10000` (so `e_entry` and `adr` resolve) and `--build-id=none` (so no allocated note slips
  in front of the image), and `objcopy -O binary` strips that to the raw image we laid out. The
  build then checks the first four bytes are the ELF magic we hand-wrote. `objcopy -O binary` is
  generic and carries no bytes of the program.

### What each loader checks (relied on, not assumed)

The kernel's `fs/binfmt_elf.c` needs: the `e_ident` magic and class, `e_type == ET_EXEC`,
`e_machine` (the arch, checked by `elf_check_arch`: `EM_X86_64` 0x3e, `EM_AARCH64` 0xB7),
`e_phentsize == 56`, at least one program header fully inside the file, `p_type == PT_LOAD`,
`p_offset` congruent to `p_vaddr` modulo the page size, and `p_vaddr >= vm.mmap_min_addr`. It
ignores `e_version`, `e_shoff`, `e_flags`, `e_ehsize`, the section-header count fields,
`p_paddr`, and `p_align` for an `ET_EXEC`. Those ignored fields are where the data and the code
fragments live.

- **mmap_min_addr** is the `vm.mmap_min_addr` sysctl, commonly 65536 on x86 distros but 4096 on
  the OrbStack kernel the tests run on. `p_vaddr = 0x10000` (65536) is the safe minimum: it
  clears both.
- **Rosetta** has one extra constraint on the first `PT_LOAD`: its `p_filesz` must be at least
  `64 + e_phnum*56`, i.e. 120 bytes with a single program header (the assertion in Rosetta's
  `ElfMapper.cpp` `map_elf`: `segment_file_size >= size_of_elf_and_program_headers`). Rosetta
  does not care *where* `e_entry` points, so code sitting in `e_version` or `p_paddr` runs fine
  under it; a file shorter than 120 bytes just has to declare `p_filesz >= 120`. We set
  `p_filesz = p_memsz = 120` on amd64 `hello` while the file is 116 bytes. The 4 bytes past EOF
  fall in the last mapped page and read as zero, which is documented `mmap` behaviour: a file
  mapping's final partial page is zero-filled beyond the file's end.
- **e_ident[8..15]** stays zero on **amd64**, but the reason is binfmt, not Rosetta. The host's
  `binfmt_misc` ELF registration matches part of `e_ident` with a magic/mask; bytes 11..15
  nonzero make the kernel refuse the file before it ever loads ("cannot execute binary file:
  Exec format error", ENOEXEC), while bytes 8..10 happen to be masked out and run either way.
  Rosetta is stricter still and rejects a nonstandard `e_ident[4..15]`, so on amd64 the whole of
  `e_ident` is left standard.
- **e_ident[4..15] is a 12-byte hole on arm64.** `binfmt_elf` picks the ELF format from
  `e_machine` (`EM_AARCH64`), never from `EI_CLASS`, and after the 4-byte magic it checks only
  `e_type`, `e_machine`, `e_phentsize` and `e_phnum`. So `EI_CLASS`/`EI_DATA`/`EI_VERSION` and
  `e_ident[8..15]` carry code on arm64. `file` and `readelf` then misread the class (they go by
  `EI_CLASS`), but the kernel loads the binary. Both arm64 extreme binaries use this hole; it is
  the main thing that was missing from the earlier asm arm64 layouts. Not an ABI promise, it is
  how `binfmt_elf` reads the header.

### Header overlap

Two layouts are used, both standard ELF-golf overlaps:

- **o56** (`e_phoff = 56`): the program header starts at offset 56, so its first dword
  (`p_type = 1`) doubles as `e_phnum` (1) and `e_shentsize` (0). `e_shoff`, `e_flags` and
  `e_ehsize` (offsets 40..53) form a 14-byte hole, exactly the size of `"Hello, World!\n"`.
  `p_offset = 0`, `p_vaddr = 0x10000`. Used by `hello`.
- **o48** (`e_phoff = 48`): the program header starts at offset 48. `p_flags` is written as
  `0x00380005` (amd64, R+X) or `0x00380007` (arm64, R+W+X), so its low half lands on `e_ehsize`
  (ignored) and its high half on `e_phentsize` (= 56, required). `p_offset = 1`, so its low word
  is `e_phnum` (= 1) and the segment maps from file offset 0 at `p_vaddr = 0x10001` (1 congruent
  to 1 mod any page size). The 6-byte request hides in the `e_shoff` hole (offset 40) and the
  `p_paddr` field (72..79) holds an 8-byte code fragment. Used by `tcp`.

On **arm64** both layouts additionally put code in the 12-byte `e_ident[4..15]` hole (above),
which is what brings arm64 hello from 132 to 124 and arm64 tcp from 304 (before this round) down
toward its final size. amd64 cannot: Rosetta rejects a nonstandard `e_ident`.

### hello

**amd64 (116 bytes)** splits the code across the header holes the kernel ignores, linked by
short jumps:

- `e_version` (offsets 20..23): `inc edi` (fd = 1) then `jmp short` to the `p_paddr` fragment.
- `p_paddr` (80..87): `mov esi, msg` then `jmp short` to the tail.
- offset 104 (the `p_align` field): `mov dl, 14` / `mov al, 1` / `syscall` / `mov al, 60` /
  `xor edi, edi` / `syscall`.

The message hides in the 14-byte o56 hole (40..53). The file ends at 116. `p_filesz = p_memsz =
120` satisfies Rosetta's `64 + 56` floor while the file is shorter; this is the correction to an
earlier note that wrongly blamed a `SIGTRAP` on code placement and fixed the floor at 123. The
real constraint is the declared `p_filesz`, not where the code sits, so the code is free to live
in header holes and 116 passes both Rosetta and the real kernel.

`hello` assumes its one `write` succeeds. If stdout is closed, `write` returns `-EBADF`, the
following `mov al, 60` leaves `rax` as a large negative value rather than 60, that second
syscall fails with `-ENOSYS`, and execution runs off the image and dies by signal. SPEC leaves
stdout-write errors unspecified, so this is accepted rather than spent a byte on (`push 60` /
`pop rax` would make it robust at +1 byte).

**arm64 (124 bytes)** also uses o56, now across three holes the kernel ignores, linked by
branches:

- `e_ident[4..15]` (offsets 4..15, the entry): `mov x0, #1` (fd), `adr x1, msg` (buf), `b` to
  the `p_paddr` fragment.
- `p_paddr` (80..87): `mov x2, #14` (len), `b` to the tail.
- offset 104 (the `p_align` field): `mov x8, #64` / `svc` / `mov x0, #0` / `mov x8, #93` / `svc`.

The message is in the 14-byte o56 hole (40..53). arm64 never runs under Rosetta, so there is no
`p_filesz` floor; `p_filesz` is the real size. The registers are zero at entry but every value
is set explicitly. This is an 8-byte improvement on the earlier 132-byte layout, which did not
use `e_ident`; it ties Rust, the only compiled slice that had found the `e_ident` hole.

**124 is the floor for arm64 hello, not just the best found.** The program is 8 instructions
that cannot be fewer: `write` needs `x0=1, x1=&msg, x2=14, x8=64` then `svc`, and `exit` needs
`x0=0, x8=93` then `svc`; `svc` leaves `x0` holding 14, so `x0` must be reloaded for the exit,
and `x8` differs between the two calls, so none of the seven setup moves can be dropped. Those
8 instructions (32 bytes) plus the 14-byte message have to live in an ELF whose single program
header must lie fully in the file; with `e_phoff = 56` (the only overlap that leaves a
contiguous 14-byte hole for the message, because `e_phentsize` at 54..55 must read 56) the phdr
ends at offset 111, so the file is at least 112 bytes. The code holes inside that 112 bytes are
`e_ident` (3 instruction slots), `p_paddr` (2) and `p_align` onward (the tail); they are not
contiguous (required header fields sit between them), so chaining the three regions costs two
branches. 8 instructions + 2 branches = 10 slots; `e_ident` holds 3 and `p_paddr` 2, leaving 5
for the tail from offset 104, i.e. the file ends at 124. The one remaining ignored field,
`e_version` (4 bytes), is isolated between two required fields, so a non-terminal instruction
there needs a branch out that costs exactly what it saves. No arrangement does better, so Rust
and assembly both sit at 124.

A 120-byte arm64 variant exists: let the code fall through `p_filesz`/`p_memsz` by writing a
branch into the `p_filesz` low word, which removes one of the two branches. It makes `p_memsz` a
~320 MB file-backed mapping (every AArch64 branch encodes to a value above 300 MB), so it
segfaults under `RLIMIT_AS < 320 MB`. It depends on the address-space limit and is rejected in
favour of the robust 124-byte layout, as the earlier 128-byte variant was.

Both the 124-byte layout and the amd64 one rely only on fields `binfmt_elf.c` ignores (on arm64
including `e_ident[4..15]`), plus the documented zero-fill of a mapping's last partial page
(amd64) and the entry registers being zero (`ELF_PLAT_INIT` / `start_thread`).

```
          total
hello amd64  116   (104 B o56 header prefix + 12 B tail at offset 104; code hidden in e_version + p_paddr)
hello arm64  124   (104 B o56 header prefix + 20 B tail at offset 104; code hidden in e_ident[4..15] + p_paddr)
```

### tcp

Both arches use **o48**. The logic is the same on both: check `argc >= 3`, parse the dotted
quad and the port, build a 16-byte `sockaddr_in`, `socket`/`connect`, then a loop that sends
`"hello\n"` and copies the reply to stdout until EOF. The holes differ: **amd64** puts the
6-byte request in the `e_shoff` hole and an 8-byte exit tail in `p_paddr`, and the rest from
offset 96; **arm64** puts the request in `e_shoff`, the entry glue (`argc`, `argv[1]`) in
`e_ident[4..15]`, the octet-store pointer in `p_paddr`, and the rest from offset 96.

Techniques that keep the code small:

- **No partial-write loop.** On amd64 the read buffer is 127 bytes, below `PIPE_BUF` (4096), so
  a single `write` to the stdout pipe or file always completes. On arm64 the reads are at most 6
  bytes (see the R+W+X buffer trick below), also a single write. The copy loop is just read,
  then one write, then loop.
- **arm64: the request buffer is the read buffer (R+W+X segment, borrowed from V).** The
  `p_flags` are `0x00380007` (R+W+X), and the 6-byte `"hello\n"` at offset 40 is used as the
  read buffer too. So one loop sends the request (first write, to the socket) and then copies
  the reply (later writes, to stdout), and `x1` (the buffer) and the request length never need
  reloading. The read count is the previous chunk's length, so it is at most 6 and the reply
  arrives in <=6-byte reads: correct, and SPEC sets no speed limit. Reading into the now-dead
  request bytes needs `W` on the segment; Linux maps R+W+X as asked (no W^X for ELF segments
  unless a security module adds one). This merge is worth 16 bytes on arm64 (292 to 276). amd64
  cannot use it: Rosetta write-protects the page holding the translated code, so a `read` into
  the header faults with `EFAULT`; amd64 reads into the stack instead.
- **One merged error tail.** A clean EOF (`read` returns 0) and a failing syscall (`read`
  returns `-errno`, e.g. `-ECONNRESET` on the reset-mid-reply test) both branch to the same
  tail, which negates the value: `neg 0 = 0` exits 0, `neg -errno` exits the errno (1..125).
  This is what makes the reset test pass: a read error is a negative return, not a zero, so it
  never looks like EOF. The too-few-args case: **amd64** jumps straight to `do_exit` with `argc`
  still in `edi`, so no args exits 1 and one arg exits 2; **arm64** does `subs x0, x0, #3; b.mi
  fail`, so the same `neg` tail exits `3 - argc` (2 with no args, 1 with one), which merged the
  separate `usage` path away and saved a byte.
- **`connect` is the only checked call before the loop.** A refused connection must exit
  1..125; if the check is dropped and `connect`'s error ignored, the later `write` to the dead
  socket raises `SIGPIPE` and the process dies from a signal (fails the test), so the check
  stays. `socket`'s result is not checked: a negative fd just makes `connect` fail into the same
  tail.
- **fd kept in a register across syscalls.** The syscall ABI clobbers only `rax`/`rcx`/`r11`
  (amd64) or `x0` (arm64), so the fd stays in `ebx`/`x19` across `connect` and the writes; only
  the stdout write (which needs fd 1) forces a reload before the next read.
- **amd64 micro-encodings:** `push imm8`/`pop reg` for small syscall constants (3 bytes vs 5),
  `bswap` to put the port in network order in one instruction, `lodsb` in the decimal parser
  (it auto-advances the pointer past the `.` separator, so the octet loop needs no explicit
  step), `xchg eax, r32` (1 byte) for register moves, and `rdx` left at its entry value of 0 for
  `socket`'s protocol argument and the read length's high bits.
- **arm64:** the 4 address octets are parsed straight into `sockaddr+4..7` with a post-indexed
  `strb`, so there is no accumulate-and-byte-reverse; `rev` then builds `family | port<<16` in
  one instruction.

Two deterministic-layout tricks, stated here because they are not in any ABI document (SPEC
requires it, and neither depends on luck: ASLR, environment size, uninitialized memory or
timing):

- **The port pointer is never loaded.** After the 4-octet parse, the parse pointer (`rsi` /
  `x19`) has advanced one byte past `argv[1]`'s NUL terminator. Linux lays the `argv` strings
  out contiguously (`argv[0]\0 argv[1]\0 argv[2]\0 ...`), so the pointer already addresses
  `argv[2]` and the port parse needs no reload. This is fixed kernel ABI layout; it is the same
  on the real kernel and under Rosetta.
- **The `sockaddr` is the dead stack.** Neither source reserves a buffer with `sub rsp` /
  `sub sp`. The 16-byte `sockaddr` sits at the stack pointer, over the `argc`/`argv` slots the
  kernel left there, which are consumed before the socket call and never read again. On amd64
  the read buffer is the same dead stack (the kernel-mapped initial stack has far more than 127
  bytes of room there); on arm64 the read buffer is the request bytes, not the stack.

```
          total
tcp amd64     227   (96 B o48 header, exit tail in p_paddr, "hello\n" in e_shoff; 131 B from offset 96)
tcp arm64     276   (96 B o48 header, glue in e_ident, ptr setup in p_paddr, "hello\n" in e_shoff; 180 B from offset 96)
```

The arm64 code is larger only because its instructions are a fixed 4 bytes; the amd64 code uses
1-to-3 byte encodings for the same logic.

### Page sizes

Every extreme binary has `p_offset` congruent to `p_vaddr` modulo 0x10000 (`p_offset` 0 and
`p_vaddr` 0x10000 for o56; `p_offset` 1 and `p_vaddr` 0x10001 for o48). Since 0x10000 is a
multiple of 4 KB, 16 KB and 64 KB, the congruence holds for all three page sizes, so none of
these binaries depends on 4 KB pages. The arm64 docker kernel uses 4 KB pages, but the layout
would also load on the 16 KB and 64 KB kernels real arm64 machines use.

Two further caveats on arm64, both deterministic: the arm64 extreme binaries put code in
`e_ident[4..15]`, so `file`/`readelf` misread the ELF class (the kernel does not), and arm64
`tcp` maps its single segment R+W+X, so a host that forbids writable-executable mappings
(SELinux `execmem` denied, PaX MPROTECT) would refuse it. The test kernels do neither.

## Files

- `hello-<arch>.s`, `tcp-<arch>.s` - sources for `default` and `optimized` (flags only differ).
- `hello-x86_64-extreme.asm`, `tcp-x86_64-extreme.asm` - flat ELF for amd64 (`nasm -f bin`).
- `hello-aarch64-extreme.s`, `tcp-aarch64-extreme.s` - ELF for arm64 (`as` + `ld` + `objcopy -O binary`).
