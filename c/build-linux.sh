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

# --- extreme: freestanding, raw syscalls, one R+X PT_LOAD, header-packed -------
# The code goes in a single R+X PT_LOAD linked from a 64 KB boundary. elfgolf.py
# writes a minimal ELF + overlapped program header over the segment's first
# bytes, drops the section headers, and keeps the bytes of the header holes so
# the linker scripts (pack-hello.ld, pack-tcp.ld) can drop small pieces of the
# program into them: hello's 14-byte message into the o56a 14-byte hole; tcp's
# 8-byte entry glue and 6-byte request into the o48a holes.
#
# clang wins on size for both programs on both arches here (gcc's arm64 output
# unrolls the 2-iteration parse loop, ~40 bytes). hello uses -Oz; tcp is smaller
# at -Oz on amd64 and -Os on arm64 (its loops favour the lighter unroller).
# amd64 adds -mno-red-zone (push imm8; pop reg for small constants) and, for
# tcp, two LLVM-internal passes off: -disable-machine-licm (keeps loop-invariant
# constant loads out of the prologue) and -machine-sink-split=false (no critical-
# edge split when sinking); together -8 bytes. These are -mllvm flags, so they
# are flags, not source, but they can change meaning between clang versions.
# arm64 adds -mcmodel=tiny (one adr, not adrp+add).
# -mgeneral-regs-only keeps the compiler off SSE, so no 16-byte-aligned stack
# access is emitted and the kernel's 16-byte-aligned entry sp is enough.
EXT_CF="-ffreestanding -fno-pic -fno-pie -fno-asynchronous-unwind-tables \
  -fno-unwind-tables -fno-stack-protector -fno-ident -fomit-frame-pointer \
  -ffunction-sections -fdata-sections -mgeneral-regs-only -nostdlib -static"
case $arch in
  aarch64) EXT_CF="$EXT_CF -mcmodel=tiny";           HELLO_O="-Os"; TCP_O="-Os" ;;
  *)       EXT_CF="$EXT_CF -mno-red-zone";           HELLO_O="-Oz"; TCP_O="-Oz -mllvm -disable-machine-licm -mllvm -machine-sink-split=false" ;;
esac
EXT_LF="-Wl,--gc-sections -Wl,--build-id=none -Wl,-z,norelro"

# hello's entry is real_start directly (no argv); tcp's is the _start glue.
build_hello() {
  local elf="$tmp/hello.elf" H
  H=$(python3 "$lx/elfgolf.py" -l o56a -H) || { status=1; return; }
  if clang $HELLO_O $EXT_CF $EXT_LF -Wl,--defsym=MSG=40 -Wl,--defsym=CODE="$H" \
      -Wl,-T,"$lx/pack-hello.ld" -Wl,-e,real_start -o "$elf" "$lx/hello.c"; then
    python3 "$lx/elfgolf.py" -l o56a "$elf" "$out/hello-extreme" || status=1
  else status=1; fi
}
build_tcp() {
  local elf="$tmp/tcp.elf" H
  H=$(python3 "$lx/elfgolf.py" -l o48a -H) || { status=1; return; }
  if clang $TCP_O $EXT_CF $EXT_LF -Wl,--defsym=GLUE=40 -Wl,--defsym=REQ=72 \
      -Wl,--defsym=CODE="$H" -Wl,-T,"$lx/pack-tcp.ld" -Wl,-e,_start -o "$elf" "$lx/tcp.c"; then
    python3 "$lx/elfgolf.py" -l o48a "$elf" "$out/tcp-extreme" || status=1
  else status=1; fi
}
build_hello
build_tcp

exit $status
