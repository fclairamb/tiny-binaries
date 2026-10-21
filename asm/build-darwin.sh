#!/usr/bin/env bash
# Assembly variants for darwin-arm64. Usage: build-darwin.sh <outdir>
# Needs the Xcode command line tools (as, ld, segedit, otool) and python3, nothing else.
set -uo pipefail

src=$(cd "$(dirname "$0")/darwin" && pwd)
out=$1
mkdir -p "$out" || exit 1
sdk=$(xcrun --show-sdk-path) || exit 1
tmp=$(mktemp -d "${TMPDIR:-/tmp}/tiny-binaries-asm.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT

status=0
failed() {
  echo "asm/darwin: $1 failed" >&2
  status=1
}

# no_relocs <object>: segedit copies section bytes as they are, so the object must not
# need any relocation (all references are PC-relative inside the one section).
no_relocs() {
  local r
  r=$(otool -r "$1") || return 1
  if grep -q 'Relocation information' <<<"$r"; then
    echo "$1 has relocations" >&2
    return 1
  fi
}

for prog in hello tcp; do
  # default: the assembler and linker with no options beyond libSystem, which ld
  # requires for any dynamic executable (and arm64 executables must be dynamic).
  if ! { as -o "$tmp/$prog.o" "$src/$prog.s" &&
    ld -o "$out/$prog-default" "$tmp/$prog.o" -lSystem -syslibroot "$sdk"; }; then
    failed "$prog-default"
  fi

  # optimized: same object, linker flags only. ld signs the output and uses the file
  # name as the signing identifier, so it links to a one-letter name and is moved.
  mkdir -p "$tmp/opt" || exit 1
  short=$tmp/opt/${prog:0:1}
  if ! { [[ -f $tmp/$prog.o ]] &&
    ld -o "$short" "$tmp/$prog.o" -lSystem -syslibroot "$sdk" \
      -x -no_exported_symbols -no_fixup_chains -no_function_starts &&
    mv "$short" "$out/$prog-optimized"; }; then
    failed "$prog-optimized"
  fi

  # extreme: the source is the whole file, Mach-O header included. Assemble, take the
  # section bytes out of the object, then sign (sign.py pads to one 16 KiB page).
  if ! { as -I "$src/extreme" -o "$tmp/$prog-x.o" "$src/extreme/$prog.s" &&
    no_relocs "$tmp/$prog-x.o" &&
    segedit "$tmp/$prog-x.o" -extract __TEXT __text "$tmp/$prog.bin" &&
    python3 "$src/sign.py" "$tmp/$prog.bin" "$out/$prog-extreme" "$prog"; }; then
    failed "$prog-extreme"
  fi
done

exit $status
