#!/usr/bin/env bash
# C variants for linux-arm64 and linux-amd64. Usage: build-linux.sh <outdir>
#
# One script serves both arches. The only arch differences are the raw syscall
# numbers (in c/linux/*.c, behind __aarch64__ / __x86_64__) and which compiler
# wins on size for the freestanding code (gcc on arm64, clang on amd64).
#
# Variants:
#   default    glibc dynamic, cc -O2 (the baseline, source in c/src)
#   optimized  glibc dynamic, size flags + strip + sstrip (same c/src source)
#   static     musl static, size flags (self-contained, no interpreter)
#   extreme    freestanding, raw syscalls, one RWX PT_LOAD, sstripped (c/linux)
set -uo pipefail
out=$(cd "$1" && pwd)
here=$(cd "$(dirname "$0")" && pwd)
src="$here/src"
lx="$here/linux"
status=0

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# --- default: the baseline, exactly as the shared build had it ----------------
for p in hello tcp; do
  cc -O2 -o "$out/$p-default" "$src/$p.c" || status=1
done

# Shared size flags (compiler + linker) for the two libc-linked variants.
SZ_CF="-Os -s -fno-asynchronous-unwind-tables -fno-unwind-tables -fno-stack-protector \
  -fno-ident -ffunction-sections -fdata-sections -fomit-frame-pointer"
SZ_LF="-Wl,--gc-sections -Wl,--build-id=none -Wl,-z,norelro -Wl,-z,noseparate-code \
  -Wl,-z,max-page-size=4096 -Wl,--hash-style=gnu -no-pie"

# --- optimized: same c/src source, flags + strip + sstrip only ----------------
# glibc dynamic wins here: the libc lives in the system, not in the file.
for p in hello tcp; do
  if cc $SZ_CF $SZ_LF -o "$out/$p-optimized" "$src/$p.c"; then
    sstrip "$out/$p-optimized" || true
  else status=1; fi
done

# --- static: musl static, size optimized (self-contained, for comparison) -----
for p in hello tcp; do
  if musl-gcc -static $SZ_CF $SZ_LF -o "$out/$p-static" "$src/$p.c" 2>/dev/null; then
    sstrip "$out/$p-static" || true
  else status=1; fi
done

# --- extreme: freestanding, raw syscalls, one RWX PT_LOAD at file offset 0 -----
EXT_CF="-ffreestanding -fno-pic -fno-pie -fno-asynchronous-unwind-tables \
  -fno-unwind-tables -fno-stack-protector -fno-ident -fomit-frame-pointer \
  -nostdlib -nostartfiles -static"
EXT_LF="-Wl,-T,$lx/one-segment.ld -Wl,--build-id=none -Wl,-n -no-pie"
case $(uname -m) in
  aarch64) EXT_CC="gcc";   EXT_O="-Os" ;;  # gcc -Os is smallest on arm64
  *)       EXT_CC="clang"; EXT_O="-Oz" ;;  # clang -Oz is smallest on amd64
esac
# hello needs no argv, so its entry is real_start directly; tcp needs the glue.
if $EXT_CC $EXT_O $EXT_CF $EXT_LF -Wl,-e,real_start -o "$out/hello-extreme" "$lx/hello.c" 2>/dev/null; then
  sstrip "$out/hello-extreme" || true
else status=1; fi
if $EXT_CC $EXT_O $EXT_CF $EXT_LF -Wl,-e,_start -o "$out/tcp-extreme" "$lx/tcp.c" 2>/dev/null; then
  sstrip "$out/tcp-extreme" || true
else status=1; fi

exit $status
