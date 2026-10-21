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
out=$(cd "$1" && pwd)
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

exit $status
