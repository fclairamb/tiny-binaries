# Go on darwin-arm64

Smallest passing binaries for the two programs, built on the macOS host.

| variant      | hello  | tcp    | how |
|--------------|-------:|-------:|-----|
| default      | 2,429,714 | 3,343,538 | `go build`, idiomatic source |
| optimized    | 1,571,202 | 2,205,266 | same source, `-trimpath -ldflags="-s -w -buildid="` |
| tinygo       |   117,248 | n/a       | idiomatic hello via TinyGo, then `llvm-strip -x` |
| extreme-ffi  |    16,830 |    17,068 | Go logic, libSystem FFI, bind-at-load, compacted |
| extreme      |    16,384 |    16,384 | Go logic, raw svc syscalls, folded into one page |

`extreme` hits the hardware floor: one 16 KB page, the smallest a Mach-O can be
and still run on Apple Silicon.

## The platform floor

Apple Silicon has 16 KB pages. The kernel maps an executable one segment at a
time, page granularity, and the segment that holds the Mach-O header (the first
`__TEXT`) has to be mapped as a whole page. Measured directly: a binary whose
`__TEXT` file size is anything below 16384 is killed with SIGKILL before it runs
(swept 1 KB, 4 KB, 8 KB, 12 KB -> all killed; 16384 -> runs). So no runnable
binary on this platform is smaller than 16384 bytes, in any language. Both
`extreme` programs sit exactly there; the real content is under 1 KB and the
rest is the zero padding the page needs.

A static executable (no dyld) is also killed on macOS 27 arm64 (confirmed), so
even the raw-syscall build must still carry `LC_LOAD_DYLINKER` + a
`LC_LOAD_DYLIB` for libSystem and let dyld start it, even though it then never
calls into libSystem.

Unsigned arm64 code is killed too, so every post-link edit is followed by a
fresh ad-hoc signature.

## extreme: Go logic, raw syscalls, one page

The logic (argv parsing, the dotted-quad parse, the copy loop, the error checks)
is ordinary Go in `extreme/hello` and `extreme/tcp`, compiled by TinyGo with
`-gc=none -scheduler=none -panic=trap -opt=z`. The OS is reached with the
`svc #0x80` trap through `extreme/sys`, whose only assembly is the trap plus the
register moves around it (`device.AsmFull`), which the rules allow.

The Darwin arm64 syscall ABI puts the call number in x16, three args in x0-x2,
and signals an error by setting the carry flag and returning the errno in x0 (a
positive number, not a negative return). The wrapper branches on the carry bit
and negates the result on error, so Go code can test `< 0` the Linux way. The
numbers used: write 4, read 3, exit 1, socket 97, connect 98.

TinyGo emits the four argument values into x8-x14, clear of x0/x1/x2/x16, so the
moves into the fixed registers never clobber a value before it is read.
`tools/verify_syscalls.py` disassembles the linked binary and fails the build if
any `svc` preamble ever reads one of the four fixed registers, so a toolchain
change that allocated differently would break the build, not ship a wrong binary.

Entry is the Go function `appmain`, used as `LC_MAIN` (`ld -e _appmain`). dyld
starts the image and calls it with the C `main(argc, argv)` ABI, so argv arrives
in a register and no stack-reading entry glue is needed.

`tools/machofold.py` then folds the linked binary into one page: it drops the
load commands a no-import image does not need (`LC_SYMTAB`, `LC_DYSYMTAB`,
`LC_DYLD_INFO`, function starts, data-in-code), removes the `__LINKEDIT`
segment, and places the ad-hoc signature in the free tail of the first page.
It refuses to run on any image that still has dyld binds, so it can never drop
information a program needs. It is generic: it reads sizes and offsets out of
the file, it carries no bytes of the program.

### size ladder, hello (darwin-arm64, bytes)

```
tinygo -gc=none object + ld, unstripped        16,824
  machopack.py (compact + re-sign)             16,726   -98
  machofold.py (drop LINKEDIT, sig in page 0)  16,384   -342  = one 16 KB page
```

Below 16,384 is not reachable: it is one hardware page. Of that page, 32 bytes
are the header, ~400 the 9 load commands, 92 the code (`__text`), ~440 rodata,
~150 the signature; the remaining ~15.2 KB is the zero padding the page must
have for the kernel to map it.

## extreme-ffi: Go logic, libSystem through FFI

Same logic, but the OS is reached by declaring `write`, `read`, `socket`,
`connect`, `_exit` as `//export` C imports (SPEC allows "calling the OS through
FFI"). No assembly at all; the only non-Go part is dyld binding those symbols.

The cost of FFI is the dynamic-binding apparatus: a `__got` / `__la_symbol_ptr`
needs a writable data segment, which would force a second mapped page. Linking
with `-bind_at_load` makes dyld resolve those pointers at load time, so their
file content is dead and `tools/machopack.py` trims both data segments to zero
file bytes. What is left is the one `__TEXT` page plus a small `__LINKEDIT` (the
symbol table and bind opcodes the imports still need, plus the signature).

`extreme-ffi` is ~450 bytes larger than `extreme` but passes `codesign --verify`
strict validation cleanly, where the folded `extreme` does not (see Caveats). It
is the more conservative of the two.

### size ladder, hello (darwin-arm64, bytes)

```
tinygo -gc=none object + ld -bind_at_load      ~50,000   (3 page-padded segments)
  machopack.py: trim data segs, pack, re-sign   16,830   = one __TEXT page + __LINKEDIT
```

## tinygo

The idiomatic `go/src/hello` built with TinyGo (`-gc=conservative
-scheduler=none -panic=trap -opt=z`) is 185,104 bytes; `llvm-strip -x` plus a
re-sign brings it to 117,248. This is the idiomatic source with no changes, just
a different compiler, so it is a fair "what does TinyGo give you for free" point.

The idiomatic `go/src/tcp` cannot be built this way: TinyGo's `net` package is
written for microcontrollers and `net.Dial` fails at runtime with "Netdev not
set" on darwin. So there is no `tcp-tinygo`.

## Caveats

- `extreme` (the 16,384 fold) runs and passes every test, but `codesign
  --verify --strict` reports "main executable failed strict validation" because
  the signature sits inside `__TEXT` and the symbol table is gone. The kernel
  and AMFI accept the ad-hoc signature at exec time (that is what runs the
  binary); strict validation is a stricter offline check that is not a SPEC
  requirement. `extreme-ffi` passes strict validation if you need that.
- The raw-syscall register safety depends on the compiler's allocation.
  `verify_syscalls.py` turns a bad allocation into a build failure rather than a
  silent miscompile, and the TCP tests exercise every syscall including the
  error paths, so a regression cannot pass unnoticed.
