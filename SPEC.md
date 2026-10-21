# Spec

Two programs, implemented in each language. Every binary must pass `scripts/test.sh`.

## `hello`

- Writes exactly `Hello, World!\n` (14 bytes) to stdout (fd 1).
- Exits with status 0.

## `tcp`

Usage: `tcp <ipv4> <port>`, for example `tcp 127.0.0.1 8080`.

- Parses `<ipv4>` as a dotted quad and `<port>` as a decimal number (1-65535).
  Behaviour on malformed values is unspecified, but the program must not hang.
- Opens a TCP connection to that address.
- Sends exactly the 6 bytes `hello\n`.
- Copies everything the server sends to stdout until the server closes the connection.
  The test server sends its reply in several chunks with pauses, so a single `read` is not enough.
- Exits with status 0.
- Exits with a status between 1 and 125 (not killed by a signal) when:
  - fewer than 2 arguments are given,
  - the connection fails (nothing listening on the port).

## Variants

Each language builds the same variant names, so the results are comparable:

| Variant | Rules |
|---|---|
| `default` | Idiomatic source, the toolchain's plain release build. The baseline. |
| `optimized` | Same idiomatic source as `default`. Only compiler, linker and post-link flags change (size optimization, LTO, strip). No source changes. |
| `extreme` | Anything goes, as long as the program logic is written in the language and compiled by one of its compilers: no runtime, no libc, raw syscalls, custom entry points, linker scripts, header surgery after the link. |

Limits on `extreme`, so it stays a contest between languages and not between assembly programs:

- Inline assembly is allowed only for the syscall instruction itself and for entry glue (reading
  `argc`/`argv` from the initial stack, setting up the stack). The logic (parsing, the copy loop,
  error checks) is in the language.
- No machine code in byte arrays, no separate `.s` files, no C or assembly files pulled into a
  non-C language through FFI to do the work. Calling the OS (libc or syscalls) through FFI is fine.
- Post-link tools (strip, `sstrip`, a script that rewrites ELF/Mach-O headers) must be generic:
  they work on any binary and contain no bytes of the program.
- Any compiler of the language counts (TinyGo for Go, for example).

A language may add extra variants (for example `upx`, or `tinygo` for Go) when they show something
the three main ones don't. Each language documents its variants in `<lang>/variants.json`.

## Binaries

- A native executable for the platform: a 64-bit ELF (`EM_X86_64` or `EM_AARCH64`) on Linux, an
  arm64 Mach-O on macOS. No `#!` scripts, no i386 or x32 ELF, no x86_64 Mach-O run by Rosetta.
- Self-contained: it may link to the system libc (`libc.so`, `libSystem`), nothing else that isn't
  part of a default OS install.

## Platforms

- `darwin-arm64`: built and tested on the macOS host.
- `linux-arm64`, `linux-amd64`: built and tested in the `docker/Dockerfile` image (amd64 runs emulated).

A binary only counts for a platform if it passes the tests on that platform.
