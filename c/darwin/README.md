# C on darwin-arm64

Sizes below are bytes of a binary that passed `scripts/check.py` on this macOS 27
Apple Silicon host (16 KiB pages, Apple clang 21, ld-prime).

| program | default | optimized | extreme | extreme-codesign |
|---|--:|--:|--:|--:|
| hello | 33,440 | 33,424 | 16,505 | 16,525 |
| tcp   | 34,088 | 33,968 | 16,505 | 16,525 |

## Variants

- **default**: `cc -O2` of the idiomatic `c/src` (printf / BSD socket API). Baseline.
- **optimized**: same idiomatic source, flags and post-link only.
- **extreme**: no libc, raw syscalls, a from-scratch minimal Mach-O written by a
  generic post-link tool. Both programs hit the platform floor of 16,505 bytes.
- **extreme-codesign**: the same as extreme but with a real embedded-signature
  SuperBlob instead of a bare CodeDirectory, so `codesign` can parse and
  `--no-strict` verify it (the bare form it cannot parse at all). +20 bytes. Note
  that neither form passes `codesign`'s default strict validation: strict wants the
  signature inside a `__LINKEDIT` segment, which would add another 16 KiB page. The
  kernel and AMFI accept both at launch, so both pass the tests.

## optimized

Same source as default, only the toolchain changes:

```
-Oz -flto -fno-asynchronous-unwind-tables -fno-unwind-tables -fno-stack-protector
-Wl,-dead_strip -Wl,-no_function_starts -Wl,-no_data_in_code_info -Wl,-no_compact_unwind
```

then `strip -x` and `codesign -f -s -` (strip invalidates the linker signature).

Size ladder, hello (darwin-arm64):

```
33,440  default (cc -O2)
33,432  -Oz, drop unwind tables and __unwind_info
33,424  + strip -x, re-sign, -dead_strip / -no_function_starts / -no_data_in_code_info
```

The floor here is three 16 KiB segments: `__TEXT` (code), `__DATA_CONST` (the GOT
slot for `printf`), and `__LINKEDIT`. `printf` is reached through a stub and a GOT
entry, and the GOT is a writable segment, so it cannot share `__TEXT`'s page
(W^X). That is 2 x 16,384 = 32,768 bytes before a single instruction of ours, plus
the `__LINKEDIT` tail (fixups, symbol table, signature). You cannot drop below it
without dropping libc, which the `extreme` variant does.

## extreme

No libc. The logic (argv parse, dotted-quad parse, the read/write copy loop, the
error checks) is plain C in `darwin/src/`; inline asm is only the `svc #0x80`
instruction plus a `cset` to read the carry flag (the syscall error bit). The entry
`_start` is called by dyld through `LC_MAIN` as `main(argc, argv, ...)`, so no stack
glue is needed and returning hands the status back to libdyld's `exit`.

Build: `cc -Oz -nostdlib -fno-stack-protector -Wl,-e,__start -lSystem` produces a
valid but ~16.8 KB dyld-linked Mach-O. Then `machomin.py` re-lays it out into a
single `__TEXT` segment with a fresh ad-hoc signature.

Size ladder, hello (darwin-arm64):

```
33,440  default
16,840  -nostdlib, raw write(2) syscall, -Wl,-e,_start  (clang layout: __TEXT + __LINKEDIT)
16,525  machomin.py: one __TEXT page, minimal load commands, SuperBlob signature
16,505  bare CodeDirectory instead of the SuperBlob wrapper
```

### Why 16,505 is the floor

Two kernel rules set it, and both are load-time, not negotiable from a linker flag:

1. **arm64 cannot be a static executable.** `xnu/bsd/kern/mach_loader.c` only takes
   the `x86_64` static branch; an arm64 `MH_EXECUTE` without `MH_DYLDLINK` returns
   `LOAD_FAILURE` on a release kernel, and arm64 requires `MH_PIE`. So the file must
   be dyld-linked: it keeps `LC_LOAD_DYLINKER` (`/usr/lib/dyld`) and
   `LC_LOAD_DYLIB` (`/usr/lib/libSystem.B.dylib`) because dyld halts a launch that
   does not load libSystem. These load commands are tiny and sit inside the first
   page, so they cost nothing against the floor.

2. **Unsigned arm64 code is killed, and the whole code page is validated as a
   unit.** The one 16 KiB page that holds the code must pass code-signature
   validation. The signed region (`codeLimit`) is rounded up to the 16 KiB VM page:
   a smaller `codeLimit` (tested at 4 KiB, 8 KiB, 12 KiB) is SIGKILLed, because
   `vm_fault` validates the full hardware page and the sub-pages past `codeLimit`
   come back unvalidated. The signature itself must start at or after `codeLimit`
   (a signature cannot hash itself), so the file is at least 16,384 + the signature.

That makes `16,384 + signature` the floor. The signature is a single ad-hoc
`CodeDirectory`:

```
  88  CodeDirectory header, version 0x20400
      (0x20400 is the smallest version that carries execSegBase/Limit/Flags;
       AMFI needs CS_EXECSEG_MAIN_BINARY set on a main executable, so a shorter
       0x20000 CD is SIGKILLed)
   1  identifier: a single NUL
      (the kernel accepts a bare CD only when identOffset is non-zero; identOffset
       0 is SIGKILLed)
  32  one SHA-256 hash of the 16 KiB page
 ---
 121  total, pointed at directly by LC_CODE_SIGNATURE
```

`xnu/bsd/kern/ubc_subr.c` `cs_validate_csblob()` accepts a raw
`CSMAGIC_CODEDIRECTORY` as well as the usual `CSMAGIC_EMBEDDED_SIGNATURE`
SuperBlob, so the 20-byte SuperBlob wrapper (12-byte header + one 8-byte index) is
dropped. `codesign` cannot parse the bare form, but the kernel launches it; the
`extreme-codesign` variant keeps the wrapper for tools that need to read it. The `pageSize` field is `14` (log2 of 16 KiB) so one hash covers the whole
page; `pageSize 12` would need four 4 KiB hashes (+96 bytes). `16,384 + 121 =
16,505`, every byte accounted for:

```
     0..31     Mach-O header (32)
    32..351    load commands (sizeofcmds = 320)
   352..887    zero padding (payload is kept at its original file offset so the
               compiler's PC-relative adrp/add stay valid; the gap is free, it is
               inside the page)
   888..~940   code + the "Hello, World!\n" bytes
   ~940..16383 zero fill to the end of the page
 16384..16504  bare CodeDirectory signature (121)
```

Only the signature can still shrink (a SHA-1 hash would be 20 not 32 bytes, saving
12, but modern AMFI rejects a SHA-1-only main binary). 16 KiB pages are the real
cost: the same source on a 4 KiB-page system (Linux, or an Intel Mac) is about 4x
smaller.

## machomin.py

Generic Mach-O shrinker. It reads the `__TEXT` content sections and the `LC_MAIN`
entry out of any position-independent, import-free arm64 Mach-O and writes a minimal
single-segment layout with a fresh ad-hoc signature. It contains no bytes of any
program; the code and data come entirely from its input. It keeps the payload at the
same file offset it had in the input so the compiler's PC-relative references
(`adrp`/`add`, which resolve on 4 KiB page granularity) stay byte-for-byte valid;
when the input's offset is too low to fit the new load commands, it shifts the
payload by a whole 16 KiB page, which preserves those references. `machomin.py IN OUT
14 sb` emits the SuperBlob form instead of the bare CodeDirectory.
