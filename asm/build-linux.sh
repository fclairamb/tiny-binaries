#!/usr/bin/env bash
# Assembly variants for linux-arm64 and linux-amd64. Usage: build-linux.sh <outdir>
#
# One script serves both arches. It branches on uname -m to pick the per-arch
# sources in asm/linux. The extreme limits in SPEC.md do not apply to assembly,
# so the extreme variant hand-writes the whole ELF (flat binary from nasm -f bin
# on x86_64, GNU as + objcopy -O binary on aarch64).
#
# Variants:
#   default    straightforward asm, as + ld with defaults.
#   optimized  same source, size link flags (-s -n -z noseparate-code) + sstrip.
#   extreme    hand-built ELF header, overlapping program header, code in fields
#              the kernel ignores. Flat binary, chmod +x.
set -uo pipefail
[ $# -ge 1 ] || { echo "usage: build-linux.sh <outdir>" >&2; exit 2; }
out=$(cd "$1" && pwd) || { echo "output dir does not exist: $1" >&2; exit 2; }
here=$(cd "$(dirname "$0")" && pwd)
lx="$here/linux"
status=0

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

case $(uname -m) in
  aarch64) arch=aarch64 ;;
  x86_64)  arch=x86_64 ;;
  *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac

# --- default: as + ld, defaults only -----------------------------------------
for p in hello tcp; do
  if as -o "$tmp/$p.o" "$lx/$p-$arch.s"; then
    ld -o "$out/$p-default" "$tmp/$p.o" || status=1
  else status=1; fi
done

# --- optimized: same source, size link flags + sstrip ------------------------
# -s strips the symbol table, -z noseparate-code folds everything into one R+X
# segment with no page padding, --build-id=none drops the note. sstrip then
# removes the section headers a loader never reads. The sources keep their only
# writable state on the stack, so there is no data segment: one segment at file
# offset 0 that spans the ELF header, which Rosetta's loader requires on amd64.
# (-n / -N would move text out of the header-spanning segment and Rosetta then
# rejects the amd64 binary with "first load segment does not span the elf
# header"; the real kernel accepts it, but amd64 must pass both.)
for p in hello tcp; do
  if as -o "$tmp/$p.o" "$lx/$p-$arch.s" && \
     ld -s --build-id=none -z noseparate-code -o "$out/$p-optimized" "$tmp/$p.o"; then
    sstrip "$out/$p-optimized" || status=1
  else status=1; fi
done

# --- extreme: hand-built ELF -------------------------------------------------
# The whole file is the ELF image: one PT_LOAD, the program header overlapping
# the ELF header, and the message/request plus (on both arches) some code hidden
# in fields the kernel ignores. On x86_64 nasm -f bin emits the flat image
# directly. On aarch64 ld --oformat binary is refused, so we link a normal ELF
# (text based at 0x10000, so e_entry and labels resolve) and objcopy -O binary
# strips it to the raw image we laid out. --build-id=none keeps ld from inserting
# an allocated note that objcopy would prepend to the image, and we then check the
# result still begins with the ELF magic we hand-wrote. Both are chmod +x; no
# post-link golf tool is needed since the sources already contain the final bytes.
# See asm/linux/README.md.
for p in hello tcp; do
  case $arch in
    x86_64)
      if nasm -f bin -o "$out/$p-extreme" "$lx/$p-x86_64-extreme.asm"; then
        chmod +x "$out/$p-extreme" || status=1
      else status=1; fi
      ;;
    aarch64)
      if as -o "$tmp/$p-ext.o" "$lx/$p-aarch64-extreme.s" && \
         ld --build-id=none -Ttext 0x10000 -e _start -o "$tmp/$p-ext.elf" "$tmp/$p-ext.o" && \
         objcopy -O binary "$tmp/$p-ext.elf" "$out/$p-extreme" && \
         [ "$(head -c 4 "$out/$p-extreme")" = "$(printf '\177ELF')" ]; then
        chmod +x "$out/$p-extreme" || status=1
      else echo "aarch64 extreme $p: build or ELF-magic check failed" >&2; status=1; fi
      ;;
  esac
done

exit $status
