#!/usr/bin/env bash
# V variants for linux-arm64 and linux-amd64. Usage: build-linux.sh <outdir>
# Notes and size ladders: v/linux/README.md
set -uo pipefail
out=$(cd "$1" && pwd); here=$(cd "$(dirname "$0")" && pwd); status=0
lx=$here/linux
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
arch=$(uname -m)

for p in hello tcp; do
  v -prod -o "$out/$p-default" "$here/src/$p.v" || status=1
done

# optimized: the same sources, flags and post-link steps only.
vopt=(-prod -no-prod-options -skip-unused -gc none -no-bounds-checking
  -d no_backtrace -d no_segfault_handler -d builtin_write_buf_to_fd_should_use_c_write)
cflags="-Oz -flto -fno-pie -fno-plt -fno-jump-tables -fomit-frame-pointer -fno-stack-protector
  -fno-asynchronous-unwind-tables -fno-unwind-tables -fno-ident -ffunction-sections -fdata-sections"
ldflags="-no-pie -flto -Wl,--gc-sections -Wl,-O1 -Wl,--as-needed -Wl,-z,norelro -Wl,-z,noseparate-code
  -Wl,--hash-style=gnu -Wl,--build-id=none -Wl,--no-eh-frame-hdr"
# extra flags per program and arch, kept only where they shrink the binary (README)
case $arch in
  x86_64) ohello="" otcp="-fipa-pta -fno-inline-small-functions -fno-signed-zeros -ffinite-math-only"
    otcpld="-Wl,--no-ld-generated-unwind-info" ;;
  aarch64) ohello="-fno-inline-small-functions" otcp="-fipa-pta -fno-trapping-math -fno-signed-zeros"
    otcpld="" ;;
  *) echo "unsupported arch: $arch" >&2; exit 1 ;;
esac
for p in hello tcp; do
  b=$out/$p-optimized
  case $p in hello) extra=$ohello extrald="" ;; tcp) extra=$otcp extrald=$otcpld ;; esac
  v "${vopt[@]}" -cc gcc -cflags "$cflags $extra" -ldflags "$ldflags $extrald" -o "$b" "$here/src/$p.v" &&
    strip -s -R .comment -R .note.gnu.build-id -R .note.ABI-tag -R .gnu.version "$b" &&
    sstrip "$b" || { status=1; rm -f "$b"; }
done

# extreme: V source with raw syscalls, compiled to C by V, then clang without libc, one
# segment, and elfgolf.py for the headers. Per program and arch: the header layout, where
# the V constants go (DATA, a header hole), the entry symbol and extra clang flags. Pieces
# of the program go in other header holes by section name (v/linux/link.ld; elfgolf.py -h
# lists the holes).
xflags=(-Oz -mgeneral-regs-only -fomit-frame-pointer -mllvm -disable-lsr)
case $arch in
  x86_64)
    xflags+=(-mstack-alignment=8 -mtune=znver3)
    hello=(o56a 40 main__vmain) tcp=(o48a 72 entry -mllvm -regalloc=basic) ;;
  aarch64)
    xflags+=(-mcmodel=tiny)
    hello=(o56a 40 main__vmain) tcp=(o48a 72 entry) ;;
  *) echo "unsupported arch: $arch" >&2; exit 1 ;;
esac
for p in hello tcp; do
  case $p in
    hello) spec=("${hello[@]}") ;;
    tcp) spec=("${tcp[@]}") ;;
  esac
  layout=${spec[0]} data=${spec[1]} entry=${spec[2]} extra=("${spec[@]:3}")
  code=$(python3 "$lx/elfgolf.py" -l "$layout" -H) &&
    v -w -n -no-builtin -d no_main -skip-unused -gc none -o "$tmp/$p.c" -file-list "$lx/rt.v" "$lx/$p.v" &&
    clang "${xflags[@]}" "${extra[@]}" -static -nostdlib -fno-pie -no-pie -ffreestanding -fno-stack-protector \
      -fno-asynchronous-unwind-tables -fno-unwind-tables -fno-ident -ffunction-sections -fdata-sections -w \
      -Wl,--gc-sections -Wl,--build-id=none -Wl,-z,norelro -Wl,--no-warn-rwx-segments -Wl,-T,"$lx/link.ld" \
      -Wl,--defsym=DATA="$data" -Wl,--defsym=CODE="$code" -Wl,-e,"$entry" -o "$tmp/$p.elf" "$tmp/$p.c" &&
    python3 "$lx/elfgolf.py" -l "$layout" "$tmp/$p.elf" "$out/$p-extreme" || status=1
done
exit $status
