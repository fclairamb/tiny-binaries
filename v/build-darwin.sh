#!/usr/bin/env bash
# V variants for darwin-arm64. Usage: build-darwin.sh <outdir>
# What each variant does, and why: darwin/README.md.
set -uo pipefail
out=$(cd "$1" && pwd); here=$(cd "$(dirname "$0")" && pwd); status=0
tmp=$(mktemp -d "${TMPDIR:-/tmp}/tiny-binaries-v.XXXXXX") || exit 1
trap 'rm -rf "$tmp"' EXIT
# V writes its generated C under $VTMP (on macOS it ignores TMPDIR), clang under $TMPDIR.
export VTMP=$tmp TMPDIR=$tmp

# optimized: the default sources, flags and generic post-link steps only.
opt_v=(-prod -no-prod-options -gc none -no-bounds-checking -nofloat
  -d no_backtrace -d no_segfault_handler -d builtin_write_buf_to_fd_should_use_c_write)
opt_c="-Oz -flto -fvisibility=hidden -fno-unwind-tables -fno-asynchronous-unwind-tables -fno-stack-protector"
# __TEXT,__const holds no pointers (those go to __DATA_CONST), so it can move to the data
# page, which has room: tcp's __TEXT drops from 4 pages to 3.
opt_l="-Wl,-dead_strip -Wl,-dead_strip_dylibs -Wl,-x -Wl,-no_data_const -Wl,-exported_symbols_list,/dev/null \
-Wl,-no_function_starts -Wl,-no_data_in_code_info -Wl,-no_source_version \
-Wl,-rename_section,__TEXT,__const,__DATA,__const -Wl,-no_fixup_chains -Wl,-bind_at_load"

# extreme*: V without its runtime -> C -> clang -> ld.
cflags=(-Oz -fno-unwind-tables -fno-asynchronous-unwind-tables -fno-stack-protector -w)
ldflags=(-nostdlib -lSystem -Wl,-e,_start -Wl,-dead_strip -Wl,-x -Wl,-no_function_starts
  -Wl,-no_data_in_code_info -Wl,-no_source_version -Wl,-exported_symbols_list,/dev/null)

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

  # machostrip.py: __LINKEDIT keeps only the fixups, and a signature with 16 KiB hash
  # pages and an empty identifier replaces ld's.
  { v "${opt_v[@]}" -cflags "$opt_c" -ldflags "$opt_l" -o "$tmp/$p-optimized" "$here/src/$p.v" &&
    python3 "$here/darwin/machostrip.py" "$tmp/$p-optimized" "$out/$p-optimized" &&
    codesign --verify --strict "$out/$p-optimized"; } || status=1

  # Raw system calls, entry point _start, then folded into one page by machopack.py.
  # extreme: the signature sits inside the __TEXT page, which is only partly hashed (an
  # undocumented loader behaviour, darwin/README.md): 16384 bytes, the kernel's minimum.
  # extreme-strict: ld's layout, the whole page hashed and the signature in __LINKEDIT
  # after it, so that `codesign --verify --strict` accepts it: 16516.
  { nort "$here/darwin/$p.v" "$tmp/$p-extreme" &&
    python3 "$here/darwin/machopack.py" "$tmp/$p-extreme" "$out/$p-extreme" &&
    codesign --verify --no-strict "$out/$p-extreme" &&
    python3 "$here/darwin/machopack.py" --strict "$tmp/$p-extreme" "$out/$p-extreme-strict" &&
    codesign --verify --strict "$out/$p-extreme-strict"; } || status=1

  # libSystem calls instead of system calls: classic bind opcodes and a GOT that dyld fills
  # at load time, so the GOT page becomes zero-fill and the opcodes follow the folded page.
  { nort "$here/darwin/ffi/$p.v" "$tmp/$p-extreme-ffi" -Wl,-no_fixup_chains -Wl,-bind_at_load &&
    python3 "$here/darwin/machopack.py" "$tmp/$p-extreme-ffi" "$out/$p-extreme-ffi" &&
    codesign --verify --no-strict "$out/$p-extreme-ffi"; } || status=1
done
exit $status
