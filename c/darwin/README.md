# C on darwin-arm64

Built by `c/build-darwin.sh` on macOS 27.0.1 (Apple M4, 16 KiB pages) with Apple clang 21 and
ld-prime. No Homebrew tool is needed: `cc`, `codesign` and `python3` come with the Xcode
command line tools. Every size is a binary that passed `scripts/check.py`.

| program | default | optimized | extreme | extreme-strict |
|---|--:|--:|--:|--:|
| hello | 33,440 | 33,232 | 16,384 | 16,516 |
| tcp   | 34,088 | 33,776 | 16,384 | 16,516 |

- **default**: `cc -O2` of the idiomatic `c/src` (printf, BSD sockets).
- **optimized**: same source, compiler and linker flags, then `codesign`.
- **extreme**: no libc, raw syscalls, folded by `machomin.py` into one 16 KiB page with the code
  signature inside it. 16,384 bytes is the smallest file this macOS runs.
- **extreme-strict**: the same program, laid out the way `ld` does it: the whole page is hashed
  and the signature sits in a `__LINKEDIT` segment after it, so it does not need the
  partly hashed page and passes `codesign --verify --strict`. It costs the 132-byte signature.

## optimized

```
-Oz -fno-stack-protector -Wl,-no_function_starts -Wl,-no_exported_symbols -Wl,-x
codesign -f -s - -i x
```

Size ladder (bytes, darwin-arm64, binary named `<program>-optimized`):

| step | hello | tcp |
|---|--:|--:|
| `cc -O2` | 33,440 | 34,096 |
| `-Oz` | 33,440 | 34,096 |
| `-fno-stack-protector` (no `___stack_chk_*` imports) | 33,440 | 33,984 |
| `-Wl,-no_function_starts` | 33,424 | 33,984 |
| `-Wl,-no_exported_symbols` (empty exports trie) | 33,392 | 33,936 |
| `-Wl,-x` (no local symbols) | 33,328 | 33,872 |
| `codesign -f -s - -i x` | 33,232 | 33,776 |

tcp-default is 34,088, not 34,096: `ld` uses the file name as the signing identifier, and
`tcp-default` is two letters shorter. `codesign` re-signs with 16 KiB hash pages (3 hashes
instead of `ld`'s 9 hashes of 4 KiB) and a one-letter identifier. `-flto`, `-Wl,-dead_strip`,
`-Wl,-no_data_in_code_info`, `-Wl,-no_compact_unwind` and the unwind table flags change
nothing here, so they are not used. `strip` makes the file 32 bytes bigger, and `codesign`
has no option to leave out its empty requirements blob.

Every gain is in `__LINKEDIT`. The rest is two 16 KiB pages: `__TEXT`, and `__DATA_CONST`
for the GOT slot `printf` (or `puts`) is called through. dyld writes the GOT, so it cannot
share the executable page. Only dropping libc removes that page.

## extreme

The logic (argv, the dotted-quad parse, the copy loop, the error checks) is plain C in
`darwin/src/`. `syscall.h` holds the only inline asm: the `svc #0x80` instruction. The XNU
arm64 ABI puts the number in x16 and the arguments in x0 to x5. On return the kernel writes
x0 and x1 (the second return value), and sets the carry flag on error with errno in x0. So x0
and x1 are both in/out operands, and the carry comes out through the `"=@cccs"` flag-output
constraint, with no extra instruction. A read error (a reset in the middle of the reply)
returns a negative value and the program exits 1.

The entry `_start` is `LC_MAIN`: dyld calls it as `main(argc, argv)`, so argv arrives in
registers and no stack glue is needed. Returning hands the status to libdyld, which calls
`exit`. tcp builds its `sockaddr_in` byte by byte and keeps a 1 KiB stack buffer, so the
compiler emits no `memset` or `___chkstk_darwin` call (an import would bring back the GOT
page).

`cc -Oz -nostdlib -fno-stack-protector -Wl,-no_compact_unwind -Wl,-e,__start -lSystem` gives
a normal two-segment file (`__TEXT` + `__LINKEDIT`). Then `machomin.py` shrinks it.

Size ladder (bytes, darwin-arm64):

| step | hello | tcp |
|---|--:|--:|
| default | 33,440 | 34,088 |
| no libc, raw syscalls (`ld` output: `__TEXT` page + `__LINKEDIT`) | 16,840 | 16,832 |
| `machomin.py --strict`: `__LINKEDIT` holds only a 132-byte signature | 16,516 | 16,516 |
| `machomin.py`: `__LINKEDIT` dropped, signature inside the page | 16,384 | 16,384 |

What the 16,384 bytes of hello hold:

```
     0..31     Mach-O header
    32..535    9 load commands (504 bytes)
   536..807    zeros where ld's dropped commands were (the code does not move)
   808..839    __text, 8 instructions
   840..854    "Hello, World!\n"
   864..1005   signature (142): SuperBlob, CodeDirectory, identifier "hello-extreme", 1 hash
  1006..16383  zeros
```

tcp is the same with 508 bytes of code (808..1315), `"hello\n"`, and a 140-byte signature at
1328.

### The undocumented behaviour extreme relies on

The page is only partly hashed. `codeLimit` stops where the signature starts (byte 864 in
hello), and the bytes after it are never checked: changing a byte after the signature still
runs, changing a byte before it gets SIGKILL. xnu's own page check (`cs_validate_hash`,
"partial page at end of segment") would mark such a page non-executable, yet it executes on
this machine, presumably because Apple Silicon leaves executable pages to its code signing
monitor, which accepts it. This is not documented, and Apple could close it. Go's darwin
slice uses the same layout. `codesign --verify --no-strict` accepts the signature (the build
checks it), `--strict` does not (no `__LINKEDIT`). If it stops working, `extreme-strict` is
the fallback.

dyld also accepts an image with no `LC_SYMTAB`, `LC_DYSYMTAB` or `LC_DYLD_CHAINED_FIXUPS`
when there is nothing to bind (and, for extreme, no `__LINKEDIT`). That is undocumented too,
and extreme-strict relies on it as well.

### Why 16,384 is the floor

Tested on this machine, all SIGKILL before the first instruction:

- a file shorter than 16,384 bytes, whatever `__TEXT`'s file size says (tested 2,000, 8,192
  and 16,383 bytes with `__TEXT` R-X, and 2,000 bytes with RW and RWX),
- a static executable (no dyld): xnu refuses it for arm64 on release kernels,
- unsigned code, or a CodeDirectory shorter than 112 bytes (see below).

The page that holds the Mach-O header must be in the file in full, so it alone is 16,384
bytes. Everything that is not code fits inside it.

## extreme-strict

`machomin.py --strict --ident ""`: `__TEXT` keeps its whole page, one hash covers all of it,
and the signature goes in a `__LINKEDIT` segment at offset 16,384, as `ld` would lay it out.
132 bytes: SuperBlob header (12), one index entry (8), and a 112-byte CodeDirectory (the
0x20400 header, 88; an empty identifier, 1; 3 bytes of padding; one truncated SHA-256 hash,
20). `codesign --verify --strict` accepts it, and the build checks that.

The kernel (or the code signing monitor) SIGKILLs a CodeDirectory shorter than 112 bytes.
112 is the size of the version 0x20600 header, so it is probably a `sizeof` check. Measured
with version 0x20400 and a 20-byte hash: 111 bytes is killed, 112 runs. Versions 0x20000 to
0x20300, and SHA-1, SHA-256 or truncated SHA-256, all run once padded to 112 bytes and are
all killed without the padding. Round 1 concluded that SHA-1, truncated hashes and versions
below 0x20400 were refused, but those CodeDirectories were all shorter than 112 bytes. With a
20-byte hash the 0x20400 CodeDirectory fits in 109 bytes, so 3 bytes of padding reach 112,
where a full SHA-256 hash would make it 121. That saves 9 bytes. Older versions need more
padding, and `codesign` refuses version 0x20000.

## machomin.py

A generic post-link tool for arm64 executables that import nothing. It keeps the linker's
`__TEXT` layout and every load command that does not point into `__LINKEDIT` (dylinker, UUID,
build version, main, the libSystem dylib), drops `__LINKEDIT` and the commands that point into
it, gives zero-fill segments file offset 0, and writes a new ad-hoc signature (SuperBlob, one
CodeDirectory 0x20400 of at least 112 bytes, truncated SHA-256, 16 KiB hash pages, identifier =
output file name unless `--ident` is given).

It refuses, with a non-zero exit, any input it would break: not a thin arm64 PIE executable,
an unknown load command, chained-fixup imports or fixups, dyld rebases or binds, undefined
symbols, relocations, stub or pointer sections, any file content outside `__TEXT`, or non-zero
bytes in `__TEXT` outside its sections. It holds no bytes of any program.

## Tried and dropped

- A bare CodeDirectory without the SuperBlob (round 1, 16,505): 121 bytes more than the fold,
  and `codesign` cannot read it. Overlapping the identifier or the hash with the CodeDirectory
  header (16,504 and 16,502 in the round 1 review) is useless now: the signature is in the
  padding for extreme, and extreme-strict is held at 112 bytes by the minimum length anyway.
- `strip` on optimized: 32 bytes bigger than leaving the symbols to `-Wl,-x`.
- `codesign -i ""`: falls back to the default identifier (bigger). `codesign -r=`: refused.
- SIGPIPE when the server resets the connection before reading the request: SPEC lists it as
  unspecified, so tcp does not set `SO_NOSIGPIPE`.
