#!/usr/bin/env bash
# V variants for darwin-arm64. Usage: build-darwin.sh <outdir>
# What each variant does, and why: darwin/README.md.
set -uo pipefail
out=$(cd "$1" && pwd); here=$(cd "$(dirname "$0")" && pwd); status=0
tmp=$(mktemp -d "${TMPDIR:-/tmp}/tiny-binaries-v.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT
export TMPDIR=$tmp # V writes its generated C there

# optimized: the default sources, flags only.
opt_v=(-prod -no-prod-options -gc none -no-bounds-checking -nofloat
  -d no_backtrace -d builtin_write_buf_to_fd_should_use_c_write)
opt_c="-Oz -flto -fvisibility=hidden -fno-unwind-tables -fno-asynchronous-unwind-tables -fno-stack-protector"
# __TEXT,__const holds no pointers (those go to __DATA_CONST), so it can move to the data
# page, which has room: tcp's __TEXT drops from 4 pages to 3.
opt_l="-Wl,-dead_strip -Wl,-dead_strip_dylibs -Wl,-x -Wl,-no_data_const -Wl,-exported_symbols_list,/dev/null \
-Wl,-no_function_starts -Wl,-no_data_in_code_info -Wl,-no_source_version \
-Wl,-rename_section,__TEXT,__const,__DATA,__const"

# extreme and libc: V without its runtime -> C -> clang -> ld.
cflags=(-Oz -fno-unwind-tables -fno-asynchronous-unwind-tables -fno-stack-protector -w)
ldflags=(-nostdlib -lSystem -Wl,-dead_strip -Wl,-x -Wl,-no_function_starts -Wl,-no_data_in_code_info
  -Wl,-no_source_version -Wl,-exported_symbols_list,/dev/null)

# nort <source.v> <output> [ld flags...]: compile a -no-builtin V program.
nort() {
  local src=$1 bin=$2 d
  shift 2
  d=$(mktemp -d "$tmp/nort.XXXXXX") &&
    v -no-builtin -gc none -enable-globals -o "$d/x.c" "$src" &&
    cc "${cflags[@]}" -c -o "$d/x.o" "$d/x.c" &&
    cc "${ldflags[@]}" "$@" -o "$bin" "$d/x.o"
}

for p in hello tcp; do
  v -prod -o "$out/$p-default" "$here/src/$p.v" || status=1

  # ld names the ad-hoc signature after the output file and hashes 4 KiB pages; codesign
  # with a short identifier hashes 16 KiB pages: about 100 bytes less.
  { v "${opt_v[@]}" -cflags "$opt_c" -ldflags "$opt_l" -o "$out/$p-optimized" "$here/src/$p.v" &&
    codesign -s - -f -i "$p" "$out/$p-optimized" 2>/dev/null; } || status=1

  # Raw system calls, entry point _start, then folded into __TEXT. extreme is the fully
  # hashed layout (one 16 KiB __TEXT page, signature at 16384): 16505 bytes, same as C and
  # Rust, no code-signing gap. extreme-partialpage trims __TEXT to its last section and
  # folds the signature inside the page (16384 bytes); it relies on an undocumented gap in
  # Apple Silicon code signing (darwin/README.md), kept as a curiosity only.
  mkdir -p "$tmp/$p" &&
    { nort "$here/darwin/$p.v" "$tmp/$p/$p-extreme" -Wl,-e,_start &&
      python3 "$here/darwin/machopack.py" "$tmp/$p/$p-extreme" "$out/$p-extreme" &&
      python3 "$here/darwin/machopack.py" --partial "$tmp/$p/$p-extreme" "$out/$p-extreme-partialpage"; } || status=1

  # libSystem calls instead of system calls: dyld has to bind them, which takes a data page.
  e=(); [[ $p == tcp ]] && e=(-Wl,-e,_start)
  nort "$here/darwin/libc/$p.v" "$out/$p-libc" ${e[@]+"${e[@]}"} || status=1
done
exit $status
