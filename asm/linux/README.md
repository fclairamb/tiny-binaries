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
| extreme | 116 | 132 | 227 | 304 |

The assembly entry is the floor the languages are measured against. Every extreme number here
is the smallest on the board: it beats V (the next smallest) on both programs and both arches
(amd64 hello 116 < 126, tcp 227 < 270; arm64 hello 132 < 140, tcp 304 < 332). The `hello`
margins are small because `hello` is so short that the ELF header dominates the file and every
language that golfs the header lands near the same floor; the `tcp` margins are wider because
there the hand-written code is meaningfully denser than a compiler's.

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
- **e_ident[8..15]** stays zero, but the reason is binfmt, not Rosetta. The host's
  `binfmt_misc` ELF registration matches part of `e_ident` with a magic/mask; bytes 11..15
  nonzero make the kernel refuse the file before it ever loads ("cannot execute binary file:
  Exec format error", ENOEXEC), while bytes 8..10 happen to be masked out and run either way.
  Zero is the safe choice across hosts, so all eight padding bytes stay zero.

### Header overlap

Two layouts are used, both standard ELF-golf overlaps:

- **o56** (`e_phoff = 56`): the program header starts at offset 56, so its first dword
  (`p_type = 1`) doubles as `e_phnum` (1) and `e_shentsize` (0). `e_shoff`, `e_flags` and
  `e_ehsize` (offsets 40..53) form a 14-byte hole, exactly the size of `"Hello, World!\n"`.
  `p_offset = 0`, `p_vaddr = 0x10000`. Used by `hello`.
- **o48** (`e_phoff = 48`): the program header starts at offset 48. `p_flags` is written as
  `0x00380005`, so its low half lands on `e_ehsize` (ignored) and its high half on
  `e_phentsize` (= 56, required). `p_offset = 1`, so its low word is `e_phnum` (= 1) and the
  segment maps from file offset 0 at `p_vaddr = 0x10001` (1 congruent to 1 mod any page size).
  The 6-byte request hides in the `e_shoff` hole (offset 40) and the `p_paddr` field (72..79)
  holds an 8-byte code fragment. Used by `tcp`.

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

**arm64 (132 bytes)** also uses o56. The code is split: `mov x0, #1` and a `b` to the tail live
in the `p_paddr` hole (80..87), and the remaining 7 instructions (the `adr`, the `write` setup
and `svc`, and the `exit` setup and `svc`) start at offset 104. arm64 never runs under Rosetta,
so there is no `p_filesz` floor; `p_filesz` is the real size. The registers are zero at entry
but every value is set explicitly.

A 128-byte arm64 variant exists (put a branch in the `p_filesz` low word so `p_memsz` becomes a
320 MB file-backed read-only mapping). It works but segfaults under `RLIMIT_AS < 320 MB`, so it
depends on the address-space limit and is rejected in favour of the robust 132-byte layout.

Both the 132-byte layout and the amd64 one rely only on fields `binfmt_elf.c` ignores, plus the
documented zero-fill of a mapping's last partial page (amd64) and the entry registers being zero
(`ELF_PLAT_INIT` / `start_thread`).

```
          total
hello amd64  116   (4 B in e_version + 8 B in p_paddr + 12 B tail at offset 104)
hello arm64  132   (8 B in p_paddr + 28 B at offset 104)
```

### tcp

Both arches use **o48** (request in the `e_shoff` hole, an 8-byte code fragment in `p_paddr`,
the rest from offset 96). The logic is the same on both: check `argc >= 3`, parse the dotted
quad and the port, build a 16-byte `sockaddr_in`, `socket`/`connect`/`write "hello\n"`, then a
read/write loop to stdout until EOF.

Techniques that keep the code small:

- **No partial-write loop.** The read buffer is 127 bytes (amd64) / 128 bytes (arm64), both
  below `PIPE_BUF` (4096), so a single `write` to the stdout pipe or file always completes. The
  copy loop is just read, then one write, then loop. This is the biggest single saving.
- **One merged error tail.** A clean EOF (`read` returns 0) and a failing syscall (`read`
  returns `-errno`, e.g. `-ECONNRESET` on the reset-mid-reply test) both branch to the same
  tail, which negates the value: `neg 0 = 0` exits 0, `neg -errno` exits the errno (1..125).
  This is what makes the reset test pass: a read error is a negative return, not a zero, so it
  never looks like EOF. The too-few-args case differs by arch: **amd64** jumps straight to
  `do_exit` with `argc` still in `edi`, so no args exits 1 and one arg exits 2; **arm64** loads
  `-2` and runs it through the same `neg`, so it always exits 2.
- **`connect` is the only checked call before the loop.** A refused connection must exit
  1..125; if the check is dropped and `connect`'s error ignored, the later `write` to the dead
  socket raises `SIGPIPE` and the process dies from a signal (fails the test), so the check
  stays. `socket`'s result is not checked: a negative fd just makes `connect` fail into the same
  tail.
- **fd kept in a register across syscalls.** The syscall ABI clobbers only `rax`/`rcx`/`r11`
  (amd64) or `x0` (arm64), so the fd stays in `ebx`/`x19` across `connect` and `write`; only the
  stdout write (which needs fd 1) forces a reload before the next read.
- **amd64 micro-encodings:** `push imm8`/`pop reg` for small syscall constants (3 bytes vs 5),
  `bswap` to put the port in network order in one instruction, `lodsb` in the decimal parser
  (it auto-advances the pointer past the `.` separator, so the octet loop needs no explicit
  step), `xchg eax, r32` (1 byte) for register moves, and `rdx` left at its entry value of 0 for
  `socket`'s protocol argument and the read length's high bits.
- **arm64:** the 4 address octets are parsed straight into `sockaddr+4..7` with a post-indexed
  `strb`, so there is no accumulate-and-byte-reverse; `rev` then builds `family | port<<16` in
  one instruction; `subs x2, x0, #0` both moves `read`'s result into the write length and sets
  the flags for the EOF/error branch.

Two deterministic-layout tricks, stated here because they are not in any ABI document (SPEC
requires it, and neither depends on luck: ASLR, environment size, uninitialized memory or
timing):

- **The port pointer is never loaded.** After the 4-octet parse, the parse pointer (`rsi` /
  `x19`) has advanced one byte past `argv[1]`'s NUL terminator. Linux lays the `argv` strings
  out contiguously (`argv[0]\0 argv[1]\0 argv[2]\0 ...`), so the pointer already addresses
  `argv[2]` and the port parse needs no reload. This is fixed kernel ABI layout; it is the same
  on the real kernel and under Rosetta.
- **The read buffer is the dead stack.** Neither source reserves a buffer with `sub rsp` /
  `sub sp`. The 16-byte `sockaddr` and the read buffer sit at the stack pointer, over the
  `argc`/`argv`/`envp`/`auxv` slots the kernel left there. Those are all consumed (parsed, or
  popped) before the read loop and never read again; the kernel-mapped initial stack always has
  far more than 128 bytes of room there, and `auxv` alone is over 300 bytes.

```
          total
tcp amd64     227   (8 B exit tail in p_paddr + 131 B from offset 96)
tcp arm64     304   (8 B entry glue in p_paddr + 208 B from offset 96)
```

The arm64 code is larger only because its instructions are a fixed 4 bytes; the amd64 code uses
1-to-3 byte encodings for the same logic.

### Page sizes

Every extreme binary has `p_offset` congruent to `p_vaddr` modulo 0x10000 (`p_offset` 0 and
`p_vaddr` 0x10000 for o56; `p_offset` 1 and `p_vaddr` 0x10001 for o48). Since 0x10000 is a
multiple of 4 KB, 16 KB and 64 KB, the congruence holds for all three page sizes, so none of
these binaries depends on 4 KB pages. The arm64 docker kernel uses 4 KB pages, but the layout
would also load on the 16 KB and 64 KB kernels real arm64 machines use.

## Files

- `hello-<arch>.s`, `tcp-<arch>.s` - sources for `default` and `optimized` (flags only differ).
- `hello-x86_64-extreme.asm`, `tcp-x86_64-extreme.asm` - flat ELF for amd64 (`nasm -f bin`).
- `hello-aarch64-extreme.s`, `tcp-aarch64-extreme.s` - ELF for arm64 (`as` + `ld` + `objcopy -O binary`).
