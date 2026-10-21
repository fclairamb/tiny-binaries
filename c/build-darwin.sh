#!/usr/bin/env bash
# C variants for darwin-arm64. Usage: build-darwin.sh <outdir>
#
#   default    cc -O2 of the idiomatic source in c/src (shared baseline)
#   optimized  same idiomatic source, size flags + strip + re-sign only
#   extreme    no libc, raw syscalls (c/darwin/src), then c/darwin/machomin.py
#              re-lays out the Mach-O into a single signed 16 KiB page
#
# Self-contained: writes only into <outdir> and a private temp dir.
set -uo pipefail
out=$(cd "$1" && pwd)
here=$(cd "$(dirname "$0")" && pwd)
src="$here/src"
dsrc="$here/darwin/src"
status=0
tmp=$(mktemp -d "${TMPDIR:-/tmp}/tiny-c-darwin.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# --- default: idiomatic source, plain -O2 ---
for p in hello tcp; do
  cc -O2 -o "$out/$p-default" "$src/$p.c" || status=1
done

# --- optimized: same idiomatic source, flags + strip + re-sign only ---
optflags=(-Oz -flto -fno-asynchronous-unwind-tables -fno-unwind-tables -fno-stack-protector
          -Wl,-dead_strip -Wl,-no_function_starts -Wl,-no_data_in_code_info -Wl,-no_compact_unwind)
for p in hello tcp; do
  if cc "${optflags[@]}" -o "$out/$p-optimized" "$src/$p.c"; then
    strip -x "$out/$p-optimized" 2>/dev/null
    codesign -f -s - "$out/$p-optimized" 2>/dev/null
  else
    status=1
  fi
done

# --- extreme: no-libc raw-syscall source, then generic Mach-O shrinker ---
# Compile with no runtime, custom entry, no stack protector (keeps the code
# free of any implicit libcalls / GOT so there is nothing to fix up).
#   extreme           smallest: bare CodeDirectory the kernel accepts directly
#   extreme-codesign  +19 bytes: SuperBlob form that `codesign` can verify
exflags=(-Oz -nostdlib -fno-stack-protector -Wl,-e,__start -lSystem)
for p in hello tcp; do
  if cc "${exflags[@]}" -o "$tmp/$p.pre" "$dsrc/$p.c"; then
    python3 "$here/darwin/machomin.py" "$tmp/$p.pre" "$out/$p-extreme" 14 >/dev/null || status=1
    python3 "$here/darwin/machomin.py" "$tmp/$p.pre" "$out/$p-extreme-codesign" 14 sb >/dev/null || status=1
  else
    status=1
  fi
done

exit $status
