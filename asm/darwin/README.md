# Assembly on darwin-arm64

Hand-written arm64 assembly, built by `asm/build-darwin.sh` on macOS 27.0.1 (Apple M4, xnu-13432,
16 KiB pages) with the Xcode command line tools only: `as`, `ld`, `segedit`, `otool`, and
`python3` for the signer. No Homebrew tool is needed.

| Variant | hello | tcp | What it is |
|---|---:|---:|---|
| `default` | 16864 | 16984 | `as`, then `ld -lSystem`, no other options |
| `optimized` | 16672 | 16672 | same object, `ld` flags only |
| `extreme` | 16384 | 16384 | the whole Mach-O written in assembly, signed by `sign.py` |

All three use raw BSD system calls (`svc #0x80`, number in x16, arguments in x0-x2) and no
libSystem function. A failed call sets the carry flag and returns the errno in x0, so tcp
checks `b.cs` after every call and exits with that errno: 61 for a refused connection, 54 for
a reset in the middle of the reply. Fewer than two arguments exit with 1. A successful call
also overwrites x1 (measured: it comes back 0), x2 and up are kept.

## The floor is 16384 bytes

No arm64 executable shorter than 16384 bytes can start on this kernel. `parse_machfile`
(xnu `bsd/kern/mach_loader.c`) reads `round_page(32 + sizeofcmds)` bytes of the file in one
read and fails with `LOAD_BADMACHO` if the read is short. A page is 16 KiB, so that is at
least 16384 bytes, whatever the headers say. Measured with the signed `extreme` hello image
cut to different sizes:

| File size | Result |
|---:|---|
| 450 (header, code and signature, no padding) | killed |
| 4096, 8192, 16383 | killed |
| 16384 | runs |
| 32767, with 16,616 bytes of load commands | killed |
| 32768, same commands | runs |

The last two rows show the limit is the header read, not the size of the code page. With
`execve` (a shell, Python's `subprocess`) the failure is a SIGKILL, because xnu turns a
failed `load_machfile` into a kill (`badtoolate` in `exec_mach_imgact`); `posix_spawn`
returns the real error, `EBADMACHO` ("Malformed Mach-o file"). This is the open-source xnu
behaviour, not something Apple documents elsewhere.

Everything else the kernel and dyld require fits inside that page, so it costs nothing more
(see `extreme`). Both `extreme` binaries are at this floor.

## default

`hello.s` and `tcp.s`: plain assembly in the Mach-O assembler syntax, `_main` called by dyld
through `LC_MAIN`. `as` and `ld` with no options except `-lSystem`, which `ld` requires for
any dynamic executable (and `-syslibroot` to find it in the SDK). tcp keeps its sockaddr and
a 16 KiB read buffer on the stack, loops on short writes, and prints a usage line to stderr.

The file is one 16 KiB `__TEXT` page (header, 16 load commands, the code) and a `__LINKEDIT`
segment with the chained-fixups header, the export trie (`_main`), the symbol table, function
starts and `ld`'s ad-hoc signature (4 KiB hash pages, the file name as identifier).

## optimized

Same object as `default`. Only `ld` options and the output name change. Cumulative, bytes:

| Step | hello | tcp |
|---|---:|---:|
| `default` | 16864 | 16984 |
| `-x` (no local symbols) | 16848 | 16848 |
| `-no_exported_symbols` (`_main` leaves the export trie and the symbol table: `LC_MAIN` needs no export) | 16752 | 16752 |
| `-no_fixup_chains` (an empty `LC_DYLD_INFO_ONLY` instead of a 56-byte chained-fixups header) | 16704 | 16704 |
| link to a one-letter file name, then `mv` (ld uses the name as signing identifier) | 16688 | 16688 |
| `-no_function_starts` | 16672 | 16672 |

What is left in `__LINKEDIT` (288 bytes): 8 bytes of export trie and 8 of string table that
`ld` always writes, and its 272-byte signature with five 4 KiB page hashes. Steps that only
save a few bytes show up when they cross the 16-byte alignment of the signature, so
`-no_function_starts` (8 bytes) counts only at the end.

`-dead_strip` and `-no_data_in_code_info` change nothing here. Re-signing with `codesign`
makes it bigger: `codesign -s - --pagesize 16384` gives 16688 (two 16 KiB page hashes
instead of five 4 KiB ones, but a requirements blob and two special-slot hashes more), and
`--pagesize 0` is killed by the kernel.
`-no_uuid` gives a binary dyld refuses ("missing LC_UUID load command", see below).

## extreme

`extreme/hello.s` and `extreme/tcp.s` include `extreme/macho.inc`, the Mach-O header and load
commands as `.long`/`.quad`/`.ascii`. `as` assembles everything into one section, `segedit`
copies that section's bytes out of the object (the build checks there are no relocations),
and `sign.py` pads it to one page and signs it. Bytes:

| Step | hello | tcp |
|---|---:|---:|
| assembled image: header and 5 load commands (248), code, strings | 294 | 498 |
| `sign.py`: zeros to the end of the page, signature in its last bytes | 16384 | 16384 |

Layout of hello: header (32), load commands (216), code (8 instructions, 32 bytes), the
14-byte string, zeros up to 16224, the signature (146 bytes), 14 zeros. tcp: 61 instructions
(244 bytes) and `hello\n`, the signature (144 bytes) ends exactly at 16384.

The five load commands are all that the kernel and dyld need. Each change below was tried on
hello (`posix_spawn` shows the kernel's error, the dyld messages are its own):

| Change | Result |
|---|---|
| no `__PAGEZERO`, or a 16 KiB one | kernel: Malformed Mach-o file (it wants 4 GiB) |
| `__PAGEZERO` with an empty name | runs (the kernel goes by address and protection) |
| `__TEXT` with an empty name | dyld: missing __TEXT segment |
| `__TEXT` mapped rwx | dyld: __TEXT segment permissions is not 'r-x' |
| no `MH_PIE`, no `LC_LOAD_DYLINKER`, or static with `LC_UNIXTHREAD` | kernel: Bad executable |
| `LC_UNIXTHREAD` instead of `LC_MAIN`, with dyld | dyld: main executable has no entry point |
| `MH_NOUNDEFS` and `MH_TWOLEVEL` flags dropped | runs (only `MH_DYLDLINK` and `MH_PIE` are set) |
| no signature | SIGKILL |
| CodeDirectory version 0x20100 or 0x20300 | SIGKILL (0x20400 needed) |
| `execSegFlags` 0 instead of `CS_EXECSEG_MAIN_BINARY` | runs |
| bare CodeDirectory, no SuperBlob | runs |
| `LC_BUILD_VERSION` minos 26 or 27, no `LC_UUID` | dyld: missing LC_UUID load command |
| minos 15.4 to 27, no libSystem import | dyld: missing LC_LOAD_DYLIB (must link with at least libSystem.dylib) |
| minos 11 to 15.3, no `LC_UUID`, no libSystem import | runs |
| one byte changed anywhere before the signature (code or zero padding) | SIGKILL |
| one byte changed in the 14 zeros after hello's signature | runs (not hashed) |
| signature right after the code instead, one byte of the padding after it changed | runs |

### Undocumented behaviour it relies on

- **The signature is inside the executable page.** `codeLimit` is the signature's offset, so
  the one SHA-256 hash covers every byte of the page before the signature (the zero padding
  included) and the page is only partly hashed. xnu's open-source page check
  (`cs_validate_hash`) marks such a "partial page at end of segment" non-executable, yet it
  runs on this M4, so the check that applies here is a different one. Not documented. With
  every page fully hashed, the signature has to follow the page: 16384 + 146 bytes, the
  layout of the C and Rust slices. `sign.py` puts the signature at the end of the page
  rather than right after the code, so only the signature and its alignment padding (at
  most 15 bytes) are left unhashed.
- **No platform load command.** dyld demands a libSystem import only from binaries built
  for macOS 15.4 or later, and `LC_UUID` only from macOS 26 or later (table above). A binary
  without `LC_BUILD_VERSION` passes both checks. Without libSystem nothing in the process
  can return through dyld, so both programs end with `SYS_exit`, never `ret`.
- **The system call numbers and the carry-flag convention** are not a public ABI on macOS
  (Apple supports only libSystem), but they have not changed in decades. This applies to all
  three variants.

`codesign -dv` reads the signature (ad-hoc, identifier `hello` or `tcp`); `codesign -v`
reports "main executable failed strict validation" (no `__LINKEDIT`), `--no-strict` accepts
it. When the parent process is provenance-tracked (as under Claude Code), `syspolicyd`
assesses every new binary on its first run, logs that same strict-validation error and lets
it run.

## sign.py

A generic ad-hoc signer for arm64 Mach-O executables whose `LC_CODE_SIGNATURE` is a
placeholder. It pads the file to the next 16 KiB boundary that leaves room for the
signature, writes a SuperBlob with one CodeDirectory (version 0x20400, SHA-256, 16 KiB hash
pages, no special slots, `execSegLimit` from the segment that maps the header) in the last
bytes of that page, and fills in `LC_CODE_SIGNATURE`. It reads all offsets from the file and
contains no bytes of any program. It writes a new file (new inode), since the kernel caches
signatures per vnode. Written for this slice; the CodeDirectory fields follow the ones the
C, Go and V slices worked out.

## Tried and dropped

- Any file below 16384 bytes, including a bare CodeDirectory or a SuperBlob, signatures with
  4 KiB or 16 KiB hash pages: killed (see the floor).
- The bare CodeDirectory (no SuperBlob) is 20 bytes shorter and runs, but the file is the
  same 16384 bytes and `codesign` can't read it, so the SuperBlob stays.
- `llvm-strip` on the `optimized` output re-signs it bigger (16688).
- A writable read buffer in a zero-fill `__DATA` segment: the stack is free and needs no
  load command.
