# V on Linux (arm64, amd64)

Tiny V binaries for `hello` and `tcp`, built by `../build-linux.sh`. Sizes below are the
bytes that pass `scripts/check.py` (and, for amd64, `scripts/vm-amd64.sh` on a real kernel).

| variant | hello amd64 | hello arm64 | tcp amd64 | tcp arm64 |
|---|--:|--:|--:|--:|
| default | 138456 | 152304 | 272872 | 307272 |
| optimized | 2912 | 3568 | 70848 | 71928 |
| extreme | 126 | 140 | 270 | 332 |

The sources live in `../src` for default and optimized (shared, idiomatic V), and here for
extreme (`rt.v`, `entry.v`, `hello.v`, `tcp.v`). Shared tools: `elfgolf.py`, `link.ld`.

## default

`v -prod`. The plain V release build: a dynamically linked glibc executable carrying the V
runtime, the GC headers, `strconv`, backtrace support and `net` (for tcp).

## optimized

Same `../src` sources, flags and post-link only. Dynamically linked against glibc (nothing
beyond a default install).

- `-skip-unused -gc none -no-bounds-checking`: drop the garbage collector, bounds checks and
  the dead code the unused-symbol walker can prove out.
- `-d no_backtrace -d no_segfault_handler`: no `backtrace`/`backtrace_symbols`, no `signal()`
  SIGSEGV handler. The segfault handler alone pulls in a chunk of the runtime; dropping it
  took hello from about 5.3 KB to 4.6 KB.
- `-d builtin_write_buf_to_fd_should_use_c_write`: V's stdout path calls `write()` instead of
  `fwrite`, a little less code.
- `-cc gcc -cflags -Oz -flto`, plus `-fno-pie -fno-plt -fno-jump-tables -fomit-frame-pointer`,
  no stack protector, no unwind tables, no build id, `--gc-sections`, `-z norelro`,
  `-z noseparate-code` (one RX segment, no separate code page), `--hash-style=gnu`.
- `strip` then `sstrip` (removes the section header table entirely).

Size ladder (amd64 hello): default 138456, `-prod` + the flags above 6440, `strip` 4376,
`sstrip` 2912. tcp amd64: 272872, 84984, 72520, 70848.

gcc beats clang here, and glibc-dynamic beats static musl by a lot: a static musl hello is
about 26 KB (the C startup and whatever of libc the program touches are copied in), against
2.9 KB when libc stays a shared library.

## extreme

V source only, no libc and no V builtin. The idea: write the logic in V, let V generate C,
compile that C freestanding with clang, put everything in one segment, and golf the ELF
headers with a generic post-link tool.

- `-no-builtin -d no_main`: V emits no builtin module and no `main()`. The program is one
  function tagged `@[export]` that the linker uses as the entry point.
- Syscalls (`rt.v`): a V `fn` per arity with one `asm` block whose only instruction is
  `syscall` (amd64) or `svc 0` (arm64). On amd64 the register constraints (`"a"`, `"D"`,
  `"S"`, `"d"`) put the arguments in place; on arm64 clang/gcc have no such constraints, so
  the block also `mov`s the arguments into x0-x2, x8. The parsing, the copy loop and the
  error checks are all in V. Syscall numbers are in the source (write 1/64, socket 41/198,
  connect 42/203, read 0/63, exit 60/93).
- Entry (`entry.v`, tcp only): the kernel starts the process with the stack pointer on
  `argc`. A tiny top-level `asm` block, `entry:`, copies `rsp`/`sp` into a register that none
  of the syscalls use (amd64 `r8`, the 5th argument register; arm64 `x3`, the 4th), then
  jumps to `vmain`. `vmain` reads that register as an unused leading parameter, so the stack
  pointer is already in hand with no spill. hello needs no argv, so its `vmain` is the entry
  directly.
- clang `-Oz -nostdlib -ffreestanding -mgeneral-regs-only -fomit-frame-pointer`. amd64 adds
  `-mno-red-zone` (so the compiler uses `push imm8; pop reg` for small constants, which is
  shorter than `mov`) and `-mllvm -disable-machine-licm` (keeps constant loads inside the
  copy loop out of the prologue, a few bytes). arm64 adds `-mcmodel=tiny`.
- `exit` is deliberately not `@[noreturn]`: clang treats noreturn calls as cold and will not
  inline them at `-Oz`. It is a plain `@[inline]` fn, and the caller follows it with
  `C.__builtin_unreachable()` so clang still drops the code after the syscall.
- One `PT_LOAD`, read+write+execute. `link.ld` lays the single segment from a 64 KB
  boundary; `elfgolf.py` writes the ELF and program headers over its first bytes and drops
  the section headers and all other program headers.

Size ladder: clang's freestanding `.elf`, then the same file `strip`ped and `sstrip`ped, then
`elfgolf.py`:

| | clang .elf | strip+sstrip | elfgolf |
|---|--:|--:|--:|
| hello amd64 | 4800 | 4222 | 126 |
| tcp amd64 | 4976 | 4366 | 270 |
| hello arm64 | 66336 | 65676 | 140 |
| tcp arm64 | 66584 | 65868 | 332 |

`sstrip` alone barely helps: the file is dominated by the gap between the code segment and the
page-aligned data, and by the headers. `elfgolf.py` removes both. The arm64 `.elf` is 66 KB
only because its data lands on a 64 KB page boundary; elfgolf collapses that to nothing.

### elfgolf.py (generic ELF header golf)

Takes any static `ET_EXEC` with one `PT_LOAD` and rewrites it with the smallest header that
still loads. It reads the segment, entry point and machine from the input and writes a fresh
64-byte-or-less header; it contains no bytes of the program. Three ideas:

1. **Overlap the program header with the ELF header.** The 56-byte program header can start
   at offset 56 (`o56`) or 48 (`o48`) inside the 64-byte ELF header, so fields that the Linux
   `ELF64` loader does not read for a static executable double as program-header fields:
   `e_phnum`/`e_shentsize` become `p_type`, and at offset 48 `e_flags`/`e_ehsize` do too, with
   `p_offset`'s low byte landing in `e_phnum` (so the segment starts at page+1).
2. **Overlap the segment with the header.** The segment is linked from a 64 KB boundary, and
   the header is written over its first bytes. The bytes of header *holes* (fields the loader
   ignores: `e_version`, `e_shoff`, `p_paddr`, and the `e_flags`/`e_ehsize`/`e_shentsize`/
   `e_shnum`/`e_shstrndx` that are not reused as program-header fields) are kept, so the
   linker script drops small pieces of the program into them. The 14-byte "Hello, World!\n"
   fits exactly in the 14-byte hole of the `o56a` layout; the 8-byte entry glue fits the
   `e_shoff` hole of the `o48a` layout. The `a` layouts start the segment 8 bytes earlier,
   over `p_align`, which `ET_EXEC` ignores.
3. **bss from trailing zeros.** Trailing zero bytes of the segment are not written to the
   file; `p_memsz > p_filesz` and the loader zero-fills them.

`elfgolf.py -l LAYOUT -H` prints the layout's header size, `-h` prints its holes. The loader
rules it relies on (static `ET_EXEC`, `p_offset` congruent to `p_vaddr` modulo the page size,
ignored header fields) are standard ELF/Linux behaviour, confirmed on the real-kernel VM; the
amd64 binaries pass both Rosetta and `scripts/vm-amd64.sh`. Rosetta is stricter than the real
kernel about `e_ident[8..15]` (it rejects nonzero there), so those bytes are not treated as
holes.

### Page sizes

The single segment starts on a 64 KB boundary with `p_offset` 0 or 1, so it loads under 4 KB,
16 KB and 64 KB page kernels. The amd64 tests run on both Rosetta (4 KB) and the qemu VM; the
arm64 tests run on OrbStack's 4 KB-page kernel. The layout does not depend on 4 KB pages.
