#!/usr/bin/env bash
# C variants for darwin-arm64. Usage: build-darwin.sh <outdir>
#
#   default         cc -O2 of the idiomatic source in c/src (shared baseline)
#   optimized       same idiomatic source, size flags, re-signed with codesign
#   extreme         no libc, raw syscalls (c/darwin/src), then c/darwin/machomin.py
#                   folds it into one 16 KiB page with the signature inside it
#   extreme-strict  same program, machomin.py --strict: the whole page is hashed and
#                   the signature sits in a minimal __LINKEDIT, so it passes
#                   codesign --verify --strict
#
# Self-contained: writes only into <outdir> and a private temp dir.
set -uo pipefail
out=$(cd "$1" && pwd) || exit 1
here=$(cd "$(dirname "$0")" && pwd)
src="$here/src"
dsrc="$here/darwin/src"
minify="$here/darwin/machomin.py"
status=0
tmp=$(mktemp -d "${TMPDIR:-/tmp}/tiny-c-darwin.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT

fail() {
  echo "c/build-darwin.sh: $*" >&2
  status=1
}

# --- default: idiomatic source, plain -O2 ---
for p in hello tcp; do
  cc -O2 -o "$out/$p-default" "$src/$p.c" || fail "$p-default: cc"
done

# --- optimized: same idiomatic source, flags and re-sign only ---
# Only flags that change the file size are kept (see c/darwin/README.md).
# codesign re-signs with 16 KiB hash pages (ld signs with 4 KiB ones) and a
# one-letter identifier (ld uses the file name).
optflags=(-Oz -fno-stack-protector -Wl,-no_function_starts -Wl,-x -Wl,-no_exported_symbols)
for p in hello tcp; do
  f="$out/$p-optimized"
  if ! cc "${optflags[@]}" -o "$f" "$src/$p.c"; then
    fail "$p-optimized: cc"
  elif ! codesign -f -s - -i x "$f"; then
    fail "$p-optimized: codesign"
  fi
done

# --- extreme: no-libc raw-syscall source, then the generic Mach-O shrinker ---
# No runtime, custom entry, no stack protector: the code imports nothing, so
# __LINKEDIT holds nothing the program needs at run time.
exflags=(-Oz -nostdlib -fno-stack-protector -Wl,-no_compact_unwind -Wl,-e,__start -lSystem)
for p in hello tcp; do
  if ! cc "${exflags[@]}" -o "$tmp/$p" "$dsrc/$p.c"; then
    fail "$p-extreme: cc"
    continue
  fi
  python3 "$minify" "$tmp/$p" "$out/$p-extreme" >/dev/null &&
    codesign --verify --no-strict "$out/$p-extreme" ||
    fail "$p-extreme: machomin.py or signature check"
  python3 "$minify" --strict --ident "" "$tmp/$p" "$out/$p-extreme-strict" >/dev/null &&
    codesign --verify --strict "$out/$p-extreme-strict" ||
    fail "$p-extreme-strict: machomin.py or strict signature check"
done

exit $status
