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
for p in hello tcp; do
  b=$out/$p-optimized
  v "${vopt[@]}" -cc gcc -cflags "$cflags" -ldflags "$ldflags" -o "$b" "$here/src/$p.v" &&
    strip -s -R .comment -R .note.gnu.build-id -R .note.ABI-tag -R .gnu.version "$b" &&
    sstrip "$b" || { status=1; rm -f "$b"; }
done

# extreme: V source with raw syscalls, compiled to C by V, then clang without libc, one
# segment, and elfgolf.py for the headers. Per program: header layout, and the offsets of
# the header holes for the entry glue and the V constants (see v/linux/link.ld).
xflags=(-Oz -mgeneral-regs-only -fomit-frame-pointer)
case $arch in
  x86_64) xflags+=(-mno-red-zone -mllvm -disable-machine-licm) ;;
  aarch64) xflags+=(-mcmodel=tiny) ;;
esac
for p in hello tcp; do
  case $p in
    hello) files=$lx/rt.v entry=main__vmain layout=o56a glue=40 data=40 ;;
    tcp) files=$lx/rt.v,$lx/entry.v entry=entry layout=o48a glue=40 data=72 ;;
  esac
  code=$(python3 "$lx/elfgolf.py" -l $layout -H)
  v -w -n -no-builtin -d no_main -skip-unused -gc none -o "$tmp/$p.c" -file-list "$files" "$lx/$p.v" &&
    clang "${xflags[@]}" -static -nostdlib -fno-pie -no-pie -ffreestanding -fno-stack-protector \
      -fno-asynchronous-unwind-tables -fno-unwind-tables -fno-ident -ffunction-sections -fdata-sections -w \
      -Wl,--gc-sections -Wl,--build-id=none -Wl,-z,norelro -Wl,--no-warn-rwx-segments -Wl,-T,"$lx/link.ld" \
      -Wl,--defsym=GLUE=$glue -Wl,--defsym=DATA=$data -Wl,--defsym=CODE="$code" -Wl,-e,$entry \
      -o "$tmp/$p.elf" "$tmp/$p.c" &&
    python3 "$lx/elfgolf.py" -l $layout "$tmp/$p.elf" "$out/$p-extreme" || status=1
done
exit $status
