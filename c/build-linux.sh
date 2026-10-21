#!/usr/bin/env bash
# C variants for linux-arm64 and linux-amd64. Usage: build-linux.sh <outdir>
#
# One script serves both arches. The only arch differences are the raw syscall
# numbers (in c/linux/*.c, behind __aarch64__ / __x86_64__), which compiler wins
# on size for the freestanding code (gcc on arm64, clang on amd64), and the
# arm64-only -mcmodel=tiny (one adr instead of adrp+add).
#
# Variants:
#   default    glibc dynamic, cc -O2 (the baseline, source in c/src)
#   optimized  glibc dynamic, size flags + lld + strip + sstrip (same c/src)
#   static     musl static, size flags (self-contained, no interpreter)
#   extreme    freestanding, raw syscalls, one R+X PT_LOAD, header-golfed (c/linux)
#
# Build failures of one variant do not stop the others; the script exits non-zero
# if any step failed. Nothing is written outside <outdir> and a private temp dir.
set -uo pipefail
out=$(cd "$1" && pwd)
here=$(cd "$(dirname "$0")" && pwd)
src="$here/src"
lx="$here/linux"
arch=$(uname -m)
status=0

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --- default: the baseline, exactly as the shared build had it ----------------
for p in hello tcp; do
  cc -O2 -o "$out/$p-default" "$src/$p.c" || status=1
done

# Shared size flags (compiler) for the two libc-linked variants.
# No -z max-page-size: the aarch64 linker default is 64 KB, so these load on
# 4 KB, 16 KB and 64 KB page kernels (amd64 is 4 KB regardless). It costs 0 bytes.
SZ_CF="-Os -s -fno-asynchronous-unwind-tables -fno-unwind-tables -fno-stack-protector \
  -fno-ident -ffunction-sections -fdata-sections -fomit-frame-pointer"

# --- optimized: same c/src source, flags + strip + sstrip only ----------------
# glibc dynamic wins here: the libc lives in the system, not in the file. lld
# with --no-rosegment (no separate RO segment), --no-eh-frame-hdr (drop the
# PT_GNU_EH_FRAME index) and -z nognustack (no PT_GNU_STACK) packs it tighter
# than GNU ld. lld keeps the 64 KB max page size on arm64, so this stays
# page-size independent.
OPT_LF="-fuse-ld=lld -Wl,--gc-sections -Wl,--build-id=none -Wl,-z,norelro \
  -Wl,--no-rosegment -Wl,--no-eh-frame-hdr -Wl,-z,nognustack -Wl,--hash-style=gnu -no-pie"
for p in hello tcp; do
  if cc $SZ_CF $OPT_LF -o "$out/$p-optimized" "$src/$p.c"; then
    sstrip "$out/$p-optimized" || status=1
  else status=1; fi
done

# --- static: musl static, size optimized (self-contained, for comparison) -----
# -z common-page-size=64 drops the DATA_SEGMENT_ALIGN file padding before the RW
# segment; -z max-page-size stays at the 64 KB default, so this is page-size
# independent too.
STAT_LF="-Wl,--gc-sections -Wl,--build-id=none -Wl,-z,norelro -Wl,-z,noseparate-code \
  -Wl,-z,common-page-size=64 -Wl,--hash-style=gnu -no-pie"
for p in hello tcp; do
  if musl-gcc -static $SZ_CF $STAT_LF -o "$out/$p-static" "$src/$p.c"; then
    sstrip "$out/$p-static" || status=1
  else status=1; fi
done

# --- extreme: freestanding, raw syscalls, one R+X PT_LOAD, header-golfed -------
# The code goes in a single R+X PT_LOAD; elfgolf.py then writes a minimal ELF +
# program header (overlapped, layout o48a = 96 bytes) in front of it and drops
# the section headers. golf.ld links the code HSIZE bytes into a 64 KB page.
EXT_CF="-ffreestanding -fno-pic -fno-pie -fno-asynchronous-unwind-tables \
  -fno-unwind-tables -fno-stack-protector -fno-ident -fomit-frame-pointer \
  -nostdlib -nostartfiles -static"
case $arch in
  aarch64) EXT_CC="gcc";   EXT_O="-Os"; EXT_CF="$EXT_CF -mcmodel=tiny -no-pie" ;;
  *)       EXT_CC="clang"; EXT_O="-Oz" ;;  # clang: -no-pie is unused here and warns
esac
LAYOUT=o48a
if ! H=$(python3 "$lx/elfgolf.py" -l "$LAYOUT" -H); then
  echo "elfgolf.py -H failed" >&2; status=1; H=120
fi
EXT_LF="-Wl,-T,$lx/golf.ld -Wl,--defsym=HSIZE=$H -Wl,--build-id=none"

build_extreme() {  # <prog> <entry-symbol>
  local p=$1 e=$2 elf="$tmp/$p.elf"
  if $EXT_CC $EXT_O $EXT_CF $EXT_LF -Wl,-e,"$e" -o "$elf" "$lx/$p.c"; then
    python3 "$lx/elfgolf.py" -l "$LAYOUT" "$elf" "$out/$p-extreme" || status=1
  else
    status=1
  fi
}
# hello needs no argv, so its entry is real_start directly; tcp needs the glue.
build_extreme hello real_start
build_extreme tcp _start

exit $status
