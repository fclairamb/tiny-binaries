# Go on darwin-arm64

Built on the macOS host by `go/build-darwin.sh`. Sizes in bytes, every binary passes
`scripts/check.py`.

| variant      |     hello |       tcp | how |
|--------------|----------:|----------:|-----|
| default      | 2,429,714 | 3,343,538 | `go build`, idiomatic source (`go/src`) |
| optimized    | 1,445,105 | 2,019,453 | same source, gc and linker flags, `machostrip.py` |
| tinygo       |    49,757 |         - | idiomatic hello built with TinyGo, `machostrip.py` |
| extreme-ffi  |    16,395 |    16,398 | Go logic, libSystem through FFI, folded to one page + bind opcodes |
| extreme      |    16,384 |    16,384 | Go logic, raw `svc` syscalls, folded to one page |

Tools: Xcode command line tools (`ld`, `codesign`, `xcrun`), Go 1.27, TinyGo 0.43, python3.
No Homebrew LLVM. Tested on macOS 27.0.1 (26A434) only.

Reproducibility: two clean runs give bit-identical binaries, except that `default` embeds Go's
VCS stamp (`vcs.revision`, `vcs.time`, `vcs.modified`), so its bytes change with the commit and
with a dirty tree, and it has none when built outside git. Its size does not change.
`optimized` passes `-buildvcs=false` and is byte-stable. The other variants have no stamp.

Variant descriptions for `scripts/report.py` are in `darwin/variants.json`, a proposal for the
shared `go/variants.json` (see the end of this file).

## The floor: one 16 KB page

A Mach-O file shorter than 16,384 bytes is killed (SIGKILL) before it runs on this machine.
Measured by trimming `hello-extreme`: files of 1,280, 4,096 and 8,192 bytes are killed, a
16,384-byte file runs, even when its `__TEXT` segment claims only 8,192 bytes of file. A static
executable (`LC_UNIXTHREAD`, no dyld) and an unsigned arm64 binary are killed too, so even the
raw-syscall build loads dyld and libSystem and carries an ad-hoc signature. Both `extreme`
programs are exactly one page; the real content is 1,220 bytes for hello and 3,074 for tcp, the
rest is zeros.

## default

`go build` of `go/src`. Nothing else.

## optimized

Same source, flags and a generic post-link strip only:

```
go build -buildvcs=false -trimpath -gcflags="all=-l -B" -ldflags='-s -w -buildid=
  -linkmode=external -extldflags "-Wl,-dead_strip -Wl,-no_compact_unwind -Wl,-no_exported_symbols"'
python3 tools/machostrip.py
```

| step | hello | tcp |
|---|---:|---:|
| `-buildvcs=false -trimpath -ldflags="-s -w -buildid="` | 1,571,202 | 2,205,266 |
| `-gcflags="all=-l -B"` (no inlining, no bounds checks) | 1,474,098 | 2,074,962 |
| `-linkmode=external` + `-Wl,-dead_strip` | 1,463,314 | 2,060,066 |
| `-Wl,-no_compact_unwind` | 1,463,314 | 2,043,554 |
| `-Wl,-no_exported_symbols` | 1,462,018 | 2,042,226 |
| `machostrip.py` | 1,445,105 | 2,019,453 |

Go unwinds with its own pclntab, so `__unwind_info` (about 12 KB) is dead weight: dropping it
takes one 16 KB `__TEXT` page off tcp. hello's `__TEXT` keeps its page count (it would need
about 2.8 KB less). `-no_exported_symbols` also clears the `WEAK_DEFINES` and `BINDS_TO_WEAK`
header flags, which `machostrip.py` refuses.

`tools/machostrip.py` is a deeper `strip`. Every segment keeps its bytes and offsets.
`__LINKEDIT` keeps only the fixups (here ld's chained fixups blob, copied verbatim), then a new
ad-hoc signature: SHA-256 truncated to 20 bytes, 16 KB pages, empty identifier, no
requirements. The symbol table, indirect symbol table, string table and export trie go;
`LC_SYMTAB` and `LC_DYSYMTAB` stay with no entries, so `codesign --verify --strict` (run by the
build) accepts the result. hello's `__LINKEDIT` goes from 20,226 bytes (4,520 of function
starts, an 11,474-byte ld signature with 4 KB pages) to 3,313. The tool
refuses weak symbols, classic relocations, imports without fixups, an unknown load command,
and a `__LINKEDIT` that is not last. It holds no bytes of any program.

## tinygo

`go/src/hello` built with TinyGo, then `machostrip.py`.

| step | hello |
|---|---:|
| `-opt=z -gc=conservative` (round 1 setting) | 185,104 |
| `-opt=2 -gc=conservative` | 69,920 |
| `-opt=2 -gc=leaking` | 68,960 |
| `machostrip.py` | 49,757 |

All builds use `-no-debug -panic=trap -scheduler=none`. `-opt=z` is the worst setting here
(it keeps more of `fmt`); `-opt=1` gives the same size as `-opt=2`. `-gc=leaking` allocates and
never frees, which is fine for a program that prints one line. `-gc=leaking` with `-opt=z` does
not link (undefined `_tinygo_scanstack`). Xcode's `strip` plus a `codesign` re-sign gave
50,656; `machostrip.py` gives the same bytes with or without `strip` first. TinyGo's lld writes
classic dyld info, so here the tool keeps the rebase, bind and lazy bind opcodes (408 bytes).

There is no `tcp-tinygo`: TinyGo's real socket code (`src/net/netdev_native.go`) is built for
Linux only, so on darwin `net.Dial` fails at run time with "Netdev not set".

## extreme: Go logic, raw syscalls, one page

The logic (argv parsing, the dotted-quad parse, the copy loop, the error checks) is Go in
`extreme/hello` and `extreme/tcp`, compiled by TinyGo with `-gc=none -scheduler=none
-panic=trap -opt=z` into an object file. `ld -e _appmain -dead_strip` links it with
`appmain` as the `LC_MAIN` entry. dyld calls it like C `main(argc, argv)`, so argv arrives
in registers and there is no entry glue. Linking the object directly also avoids TinyGo's own
link, which fails with `-gc=none` (undefined `_tinygo_scanstack`).

The OS is reached through `sys.Call` (`extreme/sys/sys.go`), one `device/arm64.AsmFull`
block: syscall number in x16, five arguments in x0-x4, `svc #0x80`. XNU reports an error by
setting the carry flag, with the errno in x0. `cset`/`orr` copy the carry into bit 63 of the
result, so Go tests `int64(r) < 0`. `AsmFull` cannot declare clobbers, so the block stores its
inputs to the stack before writing any fixed register, saves and restores x0-x4, x16 and NZCV
around the trap, and loads the result last. It holds no logic.

Syscalls: exit 1, read 3, write 4, socket 97, connect 98, setsockopt 105 (`SO_NOSIGPIPE`, so a
write to a reset socket returns EPIPE instead of raising SIGPIPE). A failed read, including
ECONNRESET in the middle of the reply, exits 1. Buffers are package globals (zero-fill
`__DATA`), because with `-gc=none` there is no allocator for an escaping stack buffer.

`extreme/regtest` checks the wrapper at build time. `build-darwin.sh` builds it exactly like
the programs and runs it before building them; if it does not exit 0, `extreme` is not built.
Two scenarios load values from memory (so the compiler cannot rematerialize them), keep them
live across traps and hash them after, starting from the trap result (so nothing is computed
before). One holds 20 values with constant operands, the other 30 values, more than there are
registers, with six of them as the operands. With TinyGo 0.43 that puts a value in every
register LLVM allocates, x0-x17, x19-x28 and x30, across an executed trap, plus a comparison
whose NZCV is read after it, and it checks the EBADF error bit. A one-off mutation test
(inserting a write to one register after the trap, for each register) made `regtest` fail for
every one of them. Not checked: x18 (platform register, reserved) and x29 (frame pointer, never
allocated); no program keeps a value in them across a trap.

`tools/machofold.py` then folds the linked file into one page. It keeps `__TEXT` byte for
byte, drops `LC_SYMTAB`, `LC_DYSYMTAB`, the empty `LC_DYLD_CHAINED_FIXUPS`,
`LC_DYLD_EXPORTS_TRIE`, function starts and data in code, removes `__LINKEDIT`, turns the other
segments into zero-fill (file offset 0, no file bytes, section offsets 0 as ld writes for
`__bss`), and writes a fresh ad-hoc signature into the free tail of the page. It refuses an
image with rebases, chained fixups, relocations, weak symbols, segments with non-zero file
content or anything it does not know. It reads sizes and offsets from the file and holds no
bytes of any program.

| step | hello | tcp |
|---|---:|---:|
| TinyGo object + `ld` (one `__TEXT` page + `__LINKEDIT`) | 16,824 | 16,952 |
| `machofold.py` | 16,384 | 16,384 |

What is in the page, hello: 32 bytes of header, 9 load commands (504 bytes), zeros up to
840 where ld put the code, `__text` 212 bytes, `__const` 14 bytes, then the 154-byte signature
at 1,066, then 15,164 bytes of zeros. tcp: 10 load commands (656), `__text` 1,924 at 992 (the
wrapper is inlined at 15 call sites), `__const` 6, signature 152 at 2,922, 13,310 zeros.

## extreme-ffi: Go logic, libSystem through FFI

Same logic, but the OS is reached by declaring libSystem functions as `//export` imports
(SPEC allows calling the OS through FFI). No assembly. hello calls `puts` (one byte shorter
in the bind opcodes than `write`). `appmain` returns its status and dyld passes it to
`exit()`, so there is no `_exit` import.

tcp imports only `syscall(2)` and passes it the BSD numbers (read 3, write 4, socket 97,
connect 98): one bind instead of four, 14 bytes of opcodes instead of 41. Its prototype is
`int syscall(int, ...)`, and on Apple arm64 every variadic argument goes on the stack in an
8-byte slot (Apple's "Writing ARM64 code for Apple platforms"). TinyGo has no variadic FFI, so
the Go declaration has seven unused arguments that fill x1-x7: the three real ones are the 9th
to 11th, which the normal calling convention puts at `[sp]`, `[sp+8]` and `[sp+16]`, where
`syscall` reads its variadic ones. libSystem's `syscall` reads seven stack slots; the last four
are whatever the caller's frame holds, and read, write, socket and connect ignore them. tcp
sets no `SO_NOSIGPIPE`: a reset before the request is read may kill it with SIGPIPE, which
SPEC allows, and it saves a call.

`ld -bind_at_load` makes dyld bind the GOT at load time, so the GOT's file content is zeros and
`machofold.py` can zero-fill `__DATA_CONST` too. It keeps a `__LINKEDIT` segment after the page
holding only the bind opcodes: without ld's padding, and without the `SET_TYPE_IMM(POINTER)`
opcode when every bind is a pointer bind. ld 27037.1 warns that `-bind_at_load` "is deprecated
on macOS" when the deployment target is 12.0 or later; TinyGo's objects target 11.0, so this
build gets no warning. If a future ld drops the flag, the link fails or falls back to lazy
binds, which `machofold.py` refuses, so the build fails instead of shipping something else.

| step | hello | tcp |
|---|---:|---:|
| TinyGo object + `ld -bind_at_load` (`__TEXT`, `__DATA_CONST`, `__LINKEDIT`) | 33,384 | 33,528 |
| `machofold.py`: one page + bind opcodes (ld wrote 16 / 16 bytes, 11 / 14 kept) | 16,395 | 16,398 |

It passes `codesign -v` (it has a `__LINKEDIT`); `extreme` does not.

## Undocumented behaviour these binaries rely on

1. The BSD syscall ABI (`extreme`): `svc #0x80`, number in x16, arguments in x0-x4, carry
   flag set and errno in x0 on error, and the numbers 1, 3, 4, 97, 98, 105. tcp-extreme-ffi
   passes the numbers 3, 4, 97, 98 to libSystem's `syscall(2)`, which the SDK header marks
   deprecated since 10.12 ("syscall(2) is unsupported"). Apple documents only the libSystem
   functions as the stable interface.
2. XNU preserving every register except x0, x1 and NZCV across `svc` (`extreme`). The wrapper
   restores x0-x4, x16 and NZCV itself. What the programs keep live across a trap (read from
   the disassembly): hello x8 and x11, tcp x0-x2, x8, x9, x19-x24 and x30 (the return address
   of the leaf `writeAll`). `regtest` checks all of them (see above); XNU saves the whole user
   thread state on entry and its syscall return path writes only x0, x1 and the carry bit.
3. A signature that covers only part of the executable page (`extreme`, `extreme-ffi`). Its
   code limit is the end of the content (1,066 for hello-extreme, 2,922 for tcp-extreme), so
   the rest of the page is not hashed. ld never does this; the kernel accepts it on 27.0.1.
   Changing a hashed byte still gets SIGKILL; changing a zero byte past the code limit goes
   unnoticed (it is never executed).
4. dyld starting an image whose `LC_CODE_SIGNATURE` points inside `__TEXT`, with no
   `LC_SYMTAB`, no `LC_DYSYMTAB` and no `__LINKEDIT` (`extreme`). `codesign -v` reports
   "main executable failed strict validation"; `codesign -v --no-strict` accepts it.
5. dyld reading bind opcodes from a `__LINKEDIT` that the signature does not cover, and binding
   a pointer when no bind type was set (`extreme-ffi`).
6. The kernel allowing segments with file offset 0 and no file bytes besides `__TEXT` (tcp's
   `__DATA`, `__DATA_CONST` in `extreme-ffi`). Their sections say offset 0 too, but `__got`
   keeps its `S_NON_LAZY_SYMBOL_POINTERS` type and its index into an indirect symbol table that
   no longer exists: dyld binds by the segment and offset in the opcodes, not by section.
7. The kernel accepting a CodeDirectory with truncated SHA-256 hashes
   (`CS_HASHTYPE_SHA256_TRUNCATED` in xnu's `cs_blobs.h`, shown as `sha256T` by `codesign`,
   which reads it but never writes it) and an empty identifier (`optimized`, `tinygo`).
   dyld binding through the chained fixups or the opcodes alone, with empty symbol tables, is
   how dyld 4 works but is not a documented contract.

`LC_BUILD_VERSION` says minos 11.0, but only macOS 27.0.1 was tested.

## Tried and dropped

- Bind opcodes inside the page (`__LINKEDIT` at file offset 0, overlapping `__TEXT`, file of
  16,384): killed before dyld runs. `__LINKEDIT` must start at 16,384, so `extreme-ffi` cannot
  reach the floor.
- UPX 5.2.1 `--force-macos` on `hello-optimized`: 573,456 bytes, but its output is a static
  executable (`LC_UNIXTHREAD`), which arm64 macOS kills, re-signed or not.
- `codesign --pagesize 0` (one hash for the whole file): killed.
- `-ldflags=-funcalign=4` (or 8) in `optimized`: no change in size.
- `-Wl,-no_function_starts` in `optimized`: no change once `machostrip.py` drops that table,
  so the flag is gone.
- `codesign -s - -f -i a` (one-letter identifier): 48 to 64 bytes off `optimized` and
  `tinygo`, superseded by `machostrip.py`'s empty identifier.

## Caveats

- `regtest` checks the wrapper with one compiler output. A TinyGo change could move values to
  registers in a way the two scenarios no longer cover, but the wrapper saves every register
  its asm writes, so it does not depend on the allocation.
- `check.py` never makes socket, setsockopt or the socket write fail. Those paths exit 1 in the
  code but are untested.
- A server that resets right after filling the socket buffers (my stress test: 1 MB in 4 KB
  writes, then `SO_LINGER` 0) can leave the client's socket ESTABLISHED with no RST seen, so a
  blocking `read` waits forever. It happened to 1 to 3 runs in 40 for `tcp-extreme` and
  `tcp-extreme-ffi`, and the same way to the C, Rust and assembly `tcp-extreme` builds, never
  to `tcp-optimized`. It looks like the kernel dropping an out-of-window RST, not a client bug.
  `check.py`'s reset test (one chunk, a pause, then the RST) passes every time.

## variants.json

`go/variants.json` is shared with the Linux slice and outside this slice, so
`darwin/variants.json` holds the proposed content for it, with the Linux-only `upx` variant
described from `go/linux/README.md`. The orchestrator can move it to `go/variants.json` once
the Linux slice agrees.
