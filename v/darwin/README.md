# V on darwin-arm64

Built by `v/build-darwin.sh`, tested on macOS 27.0.1 (Apple M4, 16 KiB pages) with V 0.5.2
(Homebrew `vlang`), Apple clang 21, ld-prime, `codesign` and python3. Sizes in bytes; two
builds from scratch give identical files.

| Variant | hello | tcp | What it is |
|---|---:|---:|---|
| `default` | 129616 | 236280 | `v -prod` |
| `optimized` | 33069 | 66301 | same sources, flags, then `machostrip.py` |
| `extreme` | 16384 | 16384 | no V runtime, raw system calls, folded into one page |
| `extreme-strict` | 16516 | 16516 | same program, ld's layout: every byte hashed |
| `extreme-ffi` | 16395 | 16398 | no V runtime, libSystem calls, folded into one page |

## The floor is 16384 bytes

No arm64 executable smaller than 16384 bytes runs on this macOS, whatever the language:

- The kernel reads the Mach-O header and load commands in one read of `round_page(32 +
  sizeofcmds)` bytes, and a page is 16 KiB. A short read fails the exec ("Malformed Mach-o
  file", `parse_machfile` in xnu `bsd/kern/mach_loader.c`). The same file runs at 16384
  bytes and fails at 16383.
- Static executables are refused on arm64 outside development kernels (same function), so
  dyld is always involved. A signed static binary gets SIGKILL.
- Every segment with file content starts at a 16 KiB aligned file offset, only one segment
  (R-X) may map offset 0, and a 4 GiB `__PAGEZERO` is required.
- The code must be signed. Ad-hoc is enough, with a CodeDirectory of at least 112 bytes:
  with the same file, 109 and 111 bytes got SIGKILL and 112 ran.

ld's output has a 16 KiB `__TEXT` page, then `__LINKEDIT` (16744 bytes for tcp). An import
from libSystem adds a 16 KiB page for the GOT (33248). `machopack.py` turns that GOT page
into zero-fill memory, so an import costs only its bind opcodes (11 bytes for `_puts`).

## default

`v -prod` on `v/src`: V's runtime with the Boehm GC, `-O3 -flto`, ld's defaults.

## optimized

Same `v/src` sources. Flags, cumulative:

| Step | hello | tcp |
|---|---:|---:|
| `v -prod` | 129616 | 236280 |
| `-gc none` (no Boehm GC) | 34816 | 158000 |
| `-no-prod-options -cflags '-Oz -flto'` | 35008 | 131168 |
| `-fvisibility=hidden -fno-unwind-tables -fno-asynchronous-unwind-tables -fno-stack-protector` | 34880 | 130864 |
| `-nofloat -no-bounds-checking -d no_backtrace -d no_segfault_handler -d builtin_write_buf_to_fd_should_use_c_write` | 34304 | 111792 |
| ld: `-dead_strip -dead_strip_dylibs -x -exported_symbols_list /dev/null -no_function_starts -no_data_in_code_info -no_source_version` | 33600 | 101152 |
| ld: `-no_data_const` (one data segment instead of two) | 33600 | 84608 |
| ld: `-rename_section __TEXT __const __DATA __const` | 33600 | 68096 |
| ld: `-no_fixup_chains -bind_at_load` | 33520 | 67968 |
| `machostrip.py` | 33069 | 66301 |

Sizes move in 16 KiB pages until `__LINKEDIT`, so most flags only count when they free a
page. The V defines and `-nofloat` take out runtime code (tcp: 19 KB). `__TEXT,__const`
holds no pointers (those go to `__DATA_CONST`), so moving it into the data page, which had
room, takes tcp's `__TEXT` from 4 pages to 3. Classic bind opcodes take less room than the
chained fixups header for this few fixups. `codesign -s - -f -i <name>` in
place of `machostrip.py` gives 33424 and 67680.

What is left is V's runtime. tcp still carries about 21 KB of Unicode tables (grapheme
ranges, case mapping) and 10 KB of float formatting tables (`strconv`), which V's string
formatting code references (link map). tcp's `__TEXT` holds 47515 bytes of content and its
data page 16232, so 4 pages is the minimum for this code.

Trade-off: with `-gc none` nothing is ever freed, and `net.TcpConn.read` takes the connection
by value, so V copies it to the heap three times per read (`read`, `read_ptr`,
`wait_for_read`), about 330 bytes per read. Max RSS with stdout to `/dev/null`: 6048 KiB
for a 50 MiB reply, 18752 KiB for 200 MiB (`tcp-default` stays near 5690 KiB, the extreme
variants near 1620 KiB). SPEC sets no memory limit. `-autofree` does not free these copies.
The fix belongs in the shared source or in V's `net`, not in flags.

### machostrip.py

A generic post-link step, like `strip` followed by `codesign`: it keeps every segment and
section byte for byte, rebuilds `__LINKEDIT` with only the fixups (copied verbatim) and signs
again with one CodeDirectory (SHA-256, 16 KiB hash pages, empty identifier) in a SuperBlob.
It drops the symbol table and export trie, so crash logs show no symbol names. Nothing
undocumented: `codesign --verify --strict` accepts the result, and the build checks it.

## extreme

`darwin/hello.v` and `darwin/tcp.v`: V compiled with `-no-builtin -gc none` (no V runtime,
no libc calls). Each system call is a V `asm arm64` block that loads x16 and x0..x2 and runs
`svc #0x80`. V's arm64 asm can't bind an operand to a register, so the block has the
`mov`s; the carry flag (set by the kernel on error) comes out through an `=@cccs` output,
which clang turns into a `cset`. tcp exits with 1 when `read` fails, so a reset in the middle
of the reply is not a success. The entry point is an exported V function `start`
(`ld -e _start`), which dyld calls like `main(argc, argv)`. tcp's 4 KiB receive buffer is a
zero-fill global: no file bytes, no memset.

The C that V generates is compiled with clang and linked with ld, then `machopack.py`
folds the result into one page:

| Step | hello | tcp |
|---|---:|---:|
| V `-no-builtin` -> C, `cc -O2`, `ld -e _start` | 16976 | 33736 |
| `-Oz` | 16976 | 33736 |
| `-fno-stack-protector -fno-unwind-tables -fno-asynchronous-unwind-tables` (the stack protector imports `___stack_chk_guard`: a GOT page) | 16976 | 17064 |
| ld: `-dead_strip -x -no_function_starts -no_data_in_code_info -no_source_version`, no exports | 16752 | 16744 |
| `machopack.py` | 16384 | 16384 |

hello's 16384 bytes: the header and 8 load commands (520 bytes), 240 zero bytes where ld's
dropped commands were, 72 bytes of code (18 instructions), the 15-byte string, 1 byte of
alignment, a 154-byte signature, then 15382 zero bytes. tcp: header and 9 commands (672),
240 zeros, 632 bytes of code, `hello\n` and its NUL, 1 byte of alignment, a 152-byte
signature, 14680 zeros. The signature is a SuperBlob (20 bytes) holding a CodeDirectory (88)
with ld's identifier (`hello-extreme`, 14 bytes with its NUL) and one SHA-256 hash (32).

The zeros are the kernel's minimum, so shrinking the content would not change the size.

Undocumented behaviour it relies on, checked on this machine:

- The signature lives inside `__TEXT`'s page, after its last section, and its hashes cover
  only the bytes before it (`codeLimit` 848 for hello, 1552 for tcp). ld always ends
  `__TEXT` on a page boundary, so normal binaries never have a partly hashed code page.
  xnu's own check marks such a page non-executable (`cs_validate_hash`, "partial page at
  end of segment"), yet it runs here, presumably because executable pages are validated by
  the Apple Silicon code signing monitor instead, which accepts it. Changing a signed byte
  still gets SIGKILL. Where the kernel does check the page itself, these binaries would be
  killed; `extreme-strict` is the fallback.
- dyld launches a main executable with no `__LINKEDIT`, no `LC_SYMTAB`, `LC_DYSYMTAB` or
  `LC_DYLD_CHAINED_FIXUPS`, when there is nothing to bind. `codesign --verify --no-strict`
  accepts the signature (the build checks it); `--strict` does not (no `__LINKEDIT`).

tcp's bss-only `__DATA` has file offset 0 and file size 0, which is what ld writes.

By experiment the loader needs even less (`__PAGEZERO`, `__TEXT` without section headers,
`LC_LOAD_DYLINKER`, `LC_MAIN`, `LC_CODE_SIGNATURE`), but that changes nothing in size and a
generic tool can't know whether a program returns into libSystem, so the other commands stay.

## extreme-strict

`machopack.py --strict` on the same linked file: ld's layout. `__TEXT` keeps its whole
16 KiB page and one hash covers all of it; the signature sits in a `__LINKEDIT` segment at
16384. It is 132 bytes: SuperBlob header and one index entry (20), a CodeDirectory (88), an
empty identifier (1), 3 bytes of padding to reach the 112-byte minimum, and one SHA-256 hash
truncated to 20 bytes (`CS_HASHTYPE_SHA256_TRUNCATED`, a hash type in Apple's headers).
`codesign --verify --strict` accepts it, and the build checks that. 16516 bytes for both
programs. The only undocumented behaviour left is dyld accepting no `LC_SYMTAB`,
`LC_DYSYMTAB` or fixups command, as above.

## extreme-ffi

`darwin/ffi/hello.v` and `darwin/ffi/tcp.v`: no V runtime either, but libSystem calls
through V's C interop instead of system calls. hello calls `puts` and returns 0 from
`start`; dyld passes that to `exit()`, which flushes stdout. tcp calls `syscall()` (one
import) for `socket`, `connect`, `read` and `write`; `syscall` is variadic, so its
arguments go on the stack, and each is passed as a 64-bit value.

ld writes a GOT that dyld fills at load time. With `-no_fixup_chains -bind_at_load`, ld
describes the imports with classic bind opcodes and leaves the GOT bytes zero (chained
fixups would store the import info in the GOT itself). `machopack.py` then turns the GOT
segment into zero-fill memory and keeps only the bind opcodes:

| Step | hello | tcp |
|---|---:|---:|
| same C flags, link `-nostdlib -lSystem -e _start` | 33536 | 33584 |
| same ld flags as `extreme` | 33328 | 33328 |
| ld: `-no_fixup_chains -bind_at_load` | 33248 | 33248 |
| `machopack.py` | 16395 | 16398 |

The file is the folded page (signed up to 1120 bytes for hello, 1600 for tcp), then the
bind opcodes in a `__LINKEDIT` segment at 16384: `11 40 "_puts\0" 72 00 90` for hello
(dylib 1, symbol, segment 2 offset 0, bind), 14 bytes with `_syscall` for tcp. dyld insists
that the opcodes lie inside `__LINKEDIT`, and `__LINKEDIT` can't start inside page 0: with
the opcodes in the page and an empty `__LINKEDIT`, dyld fails an assertion (`Image.cpp`,
`linkeditBytes`); with `__LINKEDIT` at file offset 0 the exec gets SIGKILL. So 16384 plus
the opcodes is the floor, and only fewer or shorter imports help: tcp with four imports
(`_socket`, `_connect`, `_read`, `_write`) was 16425.

Undocumented behaviour it relies on, checked on this machine:

- The partly hashed code page, as in `extreme`.
- The bind opcodes are outside the signed range: the signature, inside page 0, stops before
  them, and nothing else covers them. The kernel only checks hashes of pages it maps
  executable, and dyld reads `__LINKEDIT` without asking that it be signed. So the imports
  can be changed without breaking the signature (renaming `_puts` to `_atoi` in the file
  still runs and still passes `codesign --verify --no-strict`).
- The opcodes are cut down to what dyld acts on: no `BIND_OPCODE_SET_TYPE_IMM` and no
  `BIND_OPCODE_DONE`. dyld starts with type 0, stops at the end of the buffer, and writes a
  pointer whatever the type. The open-source dyld's opcode interpreter works that way, but
  mach-o/loader.h does not promise it.
- The GOT segment (`__DATA_CONST`) has file size 0 and file offset 0: the kernel maps zero
  pages, dyld writes the address of `puts` into them and makes them read-only.

## machopack.py

A generic post-link tool for arm64 executables whose only file content is `__TEXT`, plus,
optionally, plain pointer binds into an all-zero GOT. It drops the load commands dyld
doesn't use to launch a main executable, turns all-zero segments into zero-fill, keeps the
`__TEXT` layout untouched (no code moves) and writes a fresh ad-hoc signature, in one of the
two layouts above (folded by default, `--strict` for ld's layout). It refuses rebases, lazy
or weak binds, chained fixups with imports, data segments with non-zero bytes, content in
`__TEXT` outside its sections, fat or non-arm64 files. It contains nothing specific to these
programs.

## Tried and dropped

- UPX 5 (`--force-macos`): its output is a static executable (`LC_UNIXTHREAD`, no dyld),
  which arm64 macOS kills.
- The GOT in `__TEXT` (`-rename_section __DATA_CONST __got __TEXT __got`) to save the data
  page: "ld: Found illegal text-relocations". dyld could not write it anyway.
- `-ffreestanding` on the default sources: no `signal()` call, but the stack protector and
  `memcpy` come back as imports, bigger.
- `-no_uuid`: dyld refuses a binary that has fixups and no `LC_UUID` ("missing LC_UUID load
  command"), whatever the minimum OS version.
- `-autofree` in `optimized`, against the per-read leak: 84480 bytes for tcp, and the leak
  is the same.
- V2 (`cmd/v2`, whose modules Homebrew ships as `vlib/v2_toberemoved`) has a native arm64
  backend with its own Mach-O writer: it works, but gives 403948 bytes for `src/hello.v`,
  and it silently drops `asm` blocks, so it can't make raw system calls.
