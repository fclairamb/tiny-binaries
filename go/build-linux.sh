#!/usr/bin/env bash
# Go variants for linux-arm64 and linux-amd64. Usage: build-linux.sh <outdir>
#
# Variants built into <outdir> as <program>-<variant>:
#   default    plain `go build` (gc toolchain, the committed baseline)
#   optimized  CGO off, -trimpath, strip, and gc/link flags; same sources, flags only
#   upx        the optimized binary, then UPX --best --lzma
#   tinygo     the same idiomatic sources, built with TinyGo (conservative GC)
#   extreme    custom runtime-free sources, TinyGo, raw syscalls, one-segment ELF, sstrip
#
# The same script serves both arches; it branches on uname -m. See go/linux/README.md.
set -uo pipefail
out=$(cd "$1" && pwd); here=$(cd "$(dirname "$0")" && pwd); status=0
src="$here/src"; ext="$here/linux/extreme"
case $(uname -m) in
  aarch64) arch=arm64 ;;
  x86_64)  arch=amd64 ;;
  *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac

# default: the committed baseline, plain go build (dynamic, full runtime).
( cd "$src" && for p in hello tcp; do go build -o "$out/$p-default" "./$p" || exit 1; done ) || status=1

# optimized: identical sources, flags only. CGO off makes it static (no libc); -s -w drops the
# symbol table and DWARF; -buildid= clears the build id; -R 0x1000 shrinks segment rounding;
# -gcflags "-l -B" turns off inlining metadata and bounds-check instrumentation ids.
optld="-s -w -buildid= -R 0x1000"
( cd "$src" && for p in hello tcp; do
    CGO_ENABLED=0 go build -trimpath -ldflags="$optld" -gcflags="all=-l -B" -o "$out/$p-optimized" "./$p" || exit 1
  done ) || status=1

# upx: compress the optimized binary. Self-extracting at run time.
for p in hello tcp; do
  if [ -f "$out/$p-optimized" ]; then
    cp "$out/$p-optimized" "$out/$p-upx"
    upx -qqq --best --lzma "$out/$p-upx" >/dev/null 2>&1 || status=1
  fi
done

# tinygo: the same idiomatic sources, TinyGo's own small runtime. gc=none/leaking do not link
# with scheduler=none here (missing tinygo_scanstack), so conservative is the smallest that works.
( cd "$src" && for p in hello tcp; do
    tinygo build -opt=z -no-debug -panic=trap -scheduler=none -gc=conservative -o "$out/$p-tinygo" "./$p" || exit 1
  done ) || status=1

# extreme: custom sources with no runtime. TinyGo lowers golang.org/x/sys/unix.RawSyscallNoError*
# calls to the bare syscall instruction, the LLVM sponentry/addressofreturnaddress intrinsics give
# the entry stack pointer, one.ld packs headers+code into a single PT_LOAD, and sstrip removes the
# section headers. See go/linux/README.md for the per-step size ladder and why each trick is safe.
( cd "$ext" && for p in hello tcp; do
    tinygo build -target="target-$arch.json" -opt=z -no-debug -panic=trap -nobounds -o "$out/$p-extreme" "./$p" || exit 1
    sstrip "$out/$p-extreme" || exit 1
  done ) || status=1

exit $status
