# V on darwin-arm64

Built by `v/build-darwin.sh`, tested on macOS 27.0.1 (Apple M4, 16 KiB pages) with V 0.5.2,
Apple clang 21 and ld-prime.

| Variant | hello | tcp | What it is |
|---|---:|---:|---|
| `default` | 129616 | 236280 | `v -prod` |
| `optimized` | 33552 | 67856 | same sources, flags only |
| `extreme` | 16384 | 16384 | raw system calls, no V runtime, folded into one page |
| `libc` | 33320 | 33544 | no V runtime, libSystem calls, plain link |

## The floor is 16384 bytes

No arm64 executable smaller than 16384 bytes can run on this macOS, whatever the language:

- The kernel reads the Mach-O header and load commands in one read of `round_page(32 +
  sizeofcmds)` bytes, and a page is 16 KiB. A short read fails the exec with "Malformed
  Mach-o file" (`parse_machfile` in xnu `bsd/kern/mach_loader.c`). Checked: the same file
  runs at 16384 bytes and fails at 16383.
- Static executables are refused on arm64 outside development kernels (same function), so
  dyld is always involved. Checked: a signed static binary gets SIGKILL.
- Every segment must start at a 16 KiB aligned file offset, only one segment (R-X) may map
  offset 0, and a 4 GiB `__PAGEZERO` is required (`load_segment`, `load_machfile`).
- The code must be signed. Ad-hoc is enough, but only CodeDirectory version 0x20400 with
  SHA-256 is accepted (older versions and SHA-1 or truncated hashes got SIGKILL).

So `ld`'s smallest output is one 16 KiB `__TEXT` page plus `__LINKEDIT` (about 16.7 KB),
and any import from libSystem adds a 16 KiB data page for the GOT (about 33 KB). Both
`extreme` binaries are at the floor.

## optimized

Same `v/src` sources. Flags, cumulative (bytes):

| Step | hello | tcp |
|---|---:|---:|
| `v -prod` | 129616 | 236280 |
| `-gc none` (no Boehm GC linked in) | 34816 | 158000 |
| `-no-prod-options -cflags '-Oz -flto'` | 35000 | 131192 |
| `-fvisibility=hidden -fno-unwind-tables -fno-asynchronous-unwind-tables -fno-stack-protector` | 34880 | 130944 |
| `-nofloat -no-bounds-checking -d no_backtrace -d builtin_write_buf_to_fd_should_use_c_write` | 34448 | 111768 |
| ld: `-dead_strip -dead_strip_dylibs -x -exported_symbols_list /dev/null -no_function_starts -no_data_in_code_info -no_source_version` | 33648 | 101184 |
| ld: `-no_data_const` (one data segment instead of two) | 33648 | 84656 |
| ld: `-rename_section __TEXT __const __DATA __const` | 33648 | 68144 |
| `codesign -s - -f -i <name>` | 33552 | 67856 |

Sizes move in 16 KiB pages, so most flags only count when they free a page. `-nofloat` drops
the float formatting tables (tcp never formats a float). `__TEXT,__const` holds no pointers
(those go to `__DATA_CONST`), so moving it into the data page, which had room, takes tcp's
`__TEXT` from 4 pages to 3. ld signs with 4 KiB hash pages and the file name as identifier;
`codesign` uses 16 KiB pages and a short identifier. What is left is V's runtime: tcp's
string interpolation alone pulls in about 21 KB of Unicode tables (case mapping, grapheme
widths).

## extreme

`darwin/hello.v` and `darwin/tcp.v`: V compiled with `-no-builtin -gc none` (no V runtime,
no libc calls). Each system call is a V `asm arm64` block that loads x16 and x0..x2 and runs
`svc #0x80`. V's arm64 asm can't bind an operand to a register, so the block has the
`mov`s; the carry flag (set by the kernel on error) comes out through an `=@cccs`
constraint, not an instruction. The entry point is an exported V function `start`
(`ld -e _start`), which dyld calls like `main(argc, argv)`. tcp keeps its 4 KiB receive
buffer in a zero-fill global, so it costs no file bytes and no memset call.

The C that V generates is compiled with clang and linked with ld, then `machopack.py`
folds the result into one page. Bytes:

| Step | hello | tcp |
|---|---:|---:|
| V `-no-builtin` -> C, `clang -O2`, `ld -e _start` | 16968 | 33736 |
| `clang -Oz -fno-stack-protector -fno-unwind-tables` (stack protector imported `___stack_chk_guard`: a GOT page) | 16968 | 17064 |
| ld: `-dead_strip -x -no_function_starts -no_data_in_code_info -no_source_version`, no exports | 16744 | 16744 |
| `machopack.py` | 16384 | 16384 |

What is in the 16384 bytes of hello: the header and 8 load commands (520 bytes), 240 zero
bytes where ld's dropped commands were, 72 bytes of code (18 instructions), the 15-byte
string, a 160-byte signature, then 15376 zero bytes of padding. tcp: 672 bytes of header
and 9 commands, 240 zeros, 520 bytes of code, `hello\n`, the signature, 14784 zeros.

The padding is the kernel's minimum, so shrinking the content would not change the size. By
experiment, the loader needs less than ld keeps: `__PAGEZERO`, `__TEXT` without section
headers, `LC_LOAD_DYLINKER`, `LC_MAIN` and `LC_CODE_SIGNATURE` (248 bytes) are enough for a
program that never returns from its entry point; dyld accepted no `LC_LOAD_DYLIB`, no
platform command, no UUID and an empty signing identifier. `machopack.py` keeps those
commands anyway, since they change nothing in size and a generic tool can't know whether a
program returns into libSystem.

### machopack.py

A generic post-link tool for arm64 executables with no dyld fixups (no imports, no rebases)
and no file content outside `__TEXT`; it refuses anything else. It drops `__LINKEDIT` and
the load commands that point into it, keeps the `__TEXT` layout untouched (no code moves),
trims `__TEXT`'s file size to its last section, appends a fresh ad-hoc signature (one
CodeDirectory, SHA-256, 4 KiB pages) and pads the file to 16 KiB. It contains nothing
specific to these programs.

Two things it relies on, both checked on this machine:

- The signature now lives inside `__TEXT`'s page, and its hashes cover only the first bytes
  of that executable page. Normal binaries never do this: ld ends `__TEXT` on a page
  boundary. xnu's own page check marks such a page non-executable (`cs_validate_hash`,
  "partial page at end of segment"), yet it runs here, presumably because `vm_fault` leaves
  executable pages to the Apple Silicon code-signing monitor, which accepts it. Changing a
  signed byte still gets SIGKILL. Undocumented:
  where the kernel checks the page itself these binaries would be killed, and the valid
  layout costs one more page of file (about 16.7 KB, ld's own output above).
- Zero-fill segments (tcp's `__DATA`, bss only) get file offset 0, so they stay inside the
  smaller file. The kernel only forbids a second segment at offset 0 when it has file
  content.

`codesign -v` reports "failed strict validation" (no `__LINKEDIT`); `codesign -v --no-strict`
accepts the signature.

## libc

`darwin/libc/*.v`: no V runtime either, but `C.write`, `C.socket`, `C.connect` and `C.read`
from libSystem instead of system calls, linked normally. dyld has to bind those imports into
a writable GOT, and a writable segment needs its own 16 KiB page: 33 KB. That page is what
the raw system calls of `extreme` save; it also shows that V's runtime costs about 34 KB in
tcp (`optimized` 67856 against 33544).

## Tried and dropped

- UPX 5 (`--force-macos`): its output is a static executable (`LC_UNIXTHREAD`, no dyld),
  which arm64 macOS kills.
- The GOT in `__TEXT` (`-rename_section __DATA_CONST __got __TEXT __got`) to save the data
  page: "ld: Found illegal text-relocations". dyld could not write it anyway.
- `-ffreestanding` on the default sources: no `signal()` call, but the stack protector and
  `memcpy` come back as imports, bigger.
- `-no_uuid`: dyld refuses a binary that has fixups and no `LC_UUID` ("missing LC_UUID load
  command"), whatever the minimum OS version.
- V2 (`cmd/v2`, whose modules Homebrew ships as `vlib/v2_toberemoved`) has a native arm64
  backend with its own Mach-O writer: it works, but gives 403948 bytes for `src/hello.v`,
  and it silently drops `asm` blocks, so it can't make raw system calls.
