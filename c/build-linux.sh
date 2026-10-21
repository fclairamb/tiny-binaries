#!/usr/bin/env bash
# C variants for linux-arm64 and linux-amd64. Usage: build-linux.sh <outdir>
#
# One script serves both arches. The arch differences are the raw syscall numbers
# (in c/linux/*.c, behind __aarch64__ / __x86_64__) and the compiler flags. clang
# wins on size for the freestanding code on both arches.
#
# Variants:
#   default    glibc dynamic, cc -O2 (the baseline, source in c/src)
#   optimized  glibc dynamic, size flags + lld + strip + sstrip (same c/src)
#   static     musl static, size flags (self-contained, no interpreter)
#   extreme    freestanding, raw syscalls, one PT_LOAD, header-golfed (c/linux)
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

# --- extreme: freestanding, raw syscalls, one PT_LOAD, header-packed -------
# The code goes in a single PT_LOAD linked from a 64 KB boundary by holes.ld, which puts
# an input section named .holeN at header offset N and the rest at CODE (the header
# size). elfgolf.py then writes a minimal, overlapped ELF + program header over the first
# CODE bytes, keeps the program bytes that sit in header holes, and drops the section
# headers. hello uses layout o56a (its 14-byte message fits the 14-byte hole at 40), tcp
# o48a. Flags per program and arch are the smallest found (see c/linux/README.md):
#   -mstack-alignment=8 (amd64): no padding push before a call (no SSE code anywhere).
#   -mno-red-zone (amd64): small constants as push imm8; pop reg.
#   -mcmodel=tiny (arm64): one adr for an address, not adrp+add.
#   -mllvm -disable-lsr: the parse loop keeps one pointer increment, not two.
#   -mtune=znver3 (amd64): allows the 3-operand lea for the digit math; any x86-64 runs it.
#   -mllvm -regalloc=basic (tcp): the basic register allocator happens to pick better
#   registers here (amd64: the parsed byte lands in cl; arm64: one move less).
# The -mllvm flags are LLVM internals: they are flags, not source, but their effect can
# change between clang versions.
EXT_CF="-ffreestanding -fno-pic -fno-pie -fno-asynchronous-unwind-tables \
  -fno-unwind-tables -fno-stack-protector -fno-ident -fomit-frame-pointer \
  -ffunction-sections -fdata-sections -mgeneral-regs-only -nostdlib -static -Oz"
EXT_LF="-Wl,--gc-sections -Wl,--build-id=none -Wl,-z,norelro -Wl,-T,$lx/holes.ld -Wl,-e,_start"
case $arch in
  aarch64)
    HELLO_CF="-mcmodel=tiny"
    TCP_CF="-mcmodel=tiny -mllvm -disable-lsr -mllvm -regalloc=basic"
    # tcp reads into its request, which makes the segment R+W+X (see tcp.c)
    TCP_LF="-Wl,--no-warn-rwx-segments" ;;
  *)
    HELLO_CF="-mstack-alignment=8 -mno-red-zone"
    TCP_CF="-mstack-alignment=8 -mno-red-zone -mllvm -disable-lsr -mtune=znver3 -mllvm -regalloc=basic"
    TCP_LF="" ;;
esac

# extreme <program> <layout> <extra cflags> <extra ldflags>
extreme() {
  local p=$1 layout=$2 elf="$tmp/$1.elf" H
  H=$(python3 "$lx/elfgolf.py" -l "$layout" -H) || { status=1; return; }
  # shellcheck disable=SC2086  # the flag lists are meant to split
  if ! clang $EXT_CF $3 $EXT_LF $4 -Wl,--defsym=CODE="$H" -o "$elf" "$lx/$p.c"; then
    status=1; return
  fi
  python3 "$lx/elfgolf.py" -l "$layout" "$elf" "$out/$p-extreme" || status=1
}
extreme hello o56a "$HELLO_CF" ""
extreme tcp o48a "$TCP_CF" "$TCP_LF"

# amd64 tcp: the entry glue must fall through into tmain, with nothing in between.
if [[ $arch == x86_64 && -f $tmp/tcp.elf ]]; then
  glue=$(nm "$tmp/tcp.elf" | awk '$3 == "_start" {print $1}')
  main=$(nm "$tmp/tcp.elf" | awk '$3 == "tmain" {print $1}')
  if [[ -z $glue || -z $main ]] || (( 16#$main != 16#$glue + 5 )); then
    echo "tcp: entry glue does not fall through into tmain ($glue, $main)" >&2
    rm -f "$out/tcp-extreme"; status=1
  fi
fi

exit $status
