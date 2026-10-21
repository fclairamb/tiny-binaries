#!/usr/bin/env bash
# Go variants for linux-arm64 and linux-amd64. Usage: build-linux.sh <outdir>
#
# Variants built into <outdir> as <program>-<variant>:
#   default    plain `go build` (gc toolchain, the committed baseline)
#   optimized  same sources, flags only: gc flags, GOEXPERIMENT, a page-size-safe layout, strip
#   upx        the static gc build (CGO off, same gc flags and GOEXPERIMENT), then UPX --best --lzma
#   tinygo     the same idiomatic sources, built with TinyGo, then stripped
#   extreme    runtime-free sources, TinyGo, raw syscalls, one segment, golfed ELF header
#
# The same script serves both arches; it branches on uname -m. See go/linux/README.md.
# Every step builds into $tmp; a binary is moved into <outdir> only when all its steps succeeded.
set -uo pipefail
[[ $# -eq 1 && -d $1 ]] || { echo "usage: $0 <existing outdir>" >&2; exit 2; }
out=$(cd "$1" && pwd) || exit 1; here=$(cd "$(dirname "$0")" && pwd) || exit 1; status=0
# No VCS stamping, for every go build and for the go list TinyGo runs: it runs git, which exits 128
# ("dubious ownership") when the checkout belongs to another uid than the build (CI: checkout as
# runner, container as root), and it ties the bytes to the commit and the dirty state.
export GOFLAGS=-buildvcs=false
src="$here/src"; lx="$here/linux"; ext="$lx/extreme"
tmp=$(mktemp -d) || exit 1; trap 'rm -rf "$tmp"' EXIT
case $(uname -m) in
  aarch64) arch=arm64 ;;
  x86_64)  arch=amd64 ;;
  *) echo "unsupported arch: $(uname -m)" >&2; exit 1 ;;
esac
progs=(hello tcp)
# Drops the section header table and everything only it points to (binutils >= 2.41).
# Nothing reads section headers at run time.
strip_all() { strip --strip-section-headers "$1"; }

# default: the committed baseline, plain go build (with GOFLAGS=-buildvcs=false from above, so
# the bytes do not depend on git; they do depend on the checkout path, which is not trimmed).
# hello is static; tcp links glibc dynamically because net uses the cgo DNS resolver when cgo is
# available.
for p in "${progs[@]}"; do
  ( cd "$src" && go build -o "$tmp/$p-default" "./$p" ) && mv "$tmp/$p-default" "$out/" || status=1
done

# optimized: identical sources, flags only. -s -w drop the symbol table and DWARF, -buildid=
# the build id; -gcflags "-l -B" turn off inlining and remove bounds checks.
# GOEXPERIMENT turns off two runtime features that became the default in Go 1.26, the Green Tea
# GC and the size-specialized malloc functions, so the runtime is built with its previous GC and
# allocator: 40 KB (arm64) to 67 KB (amd64) less code. The toolchain documents GOEXPERIMENT as
# meant for its own development, so this is the least ordinary flag here.
# arm64: gc pads each segment to 64 KB in the file so the binary runs on 4, 16 and 64 KB page
# kernels. Linking externally with lld keeps each segment on its own 64 KB page in memory but
# packs them back to back in the file (p_offset only has to be congruent to p_vaddr), so the
# padding goes and the binary stays page-size independent. External linking needs cgo, so glibc
# is linked dynamically; netgo (tcp only, hello has no net code and the tag would only grow its
# build info) keeps the pure Go DNS resolver of the CGO_ENABLED=0 build, and the C flags shrink
# the small runtime/cgo glue. -z norelro, --no-rosegment and -z nognustack drop a program header
# each (hardening trade-offs, the same flags as the C slice; on arm64 the kernel and glibc both
# default to a non-executable stack without PT_GNU_STACK).
# amd64: Linux only has 4 KB pages there and gc already rounds to 4 KB; -funcalign=1 drops the
# 32-byte function alignment (the linker still spaces functions by 16 bytes for its pc lookup
# table, so this is only a speed trade-off).
exp=nogreenteagc,nosizespecializedmalloc
case $arch in
  arm64) lld="-fuse-ld=lld -Wl,--build-id=none -Wl,--gc-sections -Wl,--no-eh-frame-hdr"
         lld+=" -Wl,-z,norelro -Wl,--no-rosegment -Wl,-z,nognustack"
         opt=(env GOEXPERIMENT=$exp CC=clang CGO_ENABLED=1
              CGO_CFLAGS="-Os -fno-asynchronous-unwind-tables -fno-unwind-tables -ffunction-sections -fdata-sections"
              go build -trimpath -gcflags="all=-l -B"
              -ldflags="-s -w -buildid= -linkmode=external -extldflags '$lld'") ;;
  amd64) opt=(env GOEXPERIMENT=$exp CGO_ENABLED=0 go build -trimpath -gcflags="all=-l -B"
              -ldflags="-s -w -buildid= -funcalign=1") ;;
esac
for p in "${progs[@]}"; do
  tags=(); [[ $arch-$p == arm64-tcp ]] && tags=(-tags netgo)
  ( cd "$src" && "${opt[@]}" "${tags[@]}" -o "$tmp/$p-optimized" "./$p" ) && strip_all "$tmp/$p-optimized" &&
    mv "$tmp/$p-optimized" "$out/" || status=1
done

# upx: the plain static build (CGO off, -s -w, -l -B, the same GOEXPERIMENT, gc's default 64 KB /
# 4 KB layout), then UPX. The zero padding of the default layout costs nothing once compressed,
# and the layout flags of optimized (external link, -funcalign=1) make the compressed file larger,
# so upx starts here.
for p in "${progs[@]}"; do
  ( cd "$src" && GOEXPERIMENT=$exp CGO_ENABLED=0 go build -trimpath -gcflags="all=-l -B" -ldflags="-s -w -buildid=" \
      -o "$tmp/$p-static" "./$p" ) && strip_all "$tmp/$p-static" &&
    upx -qqq --best --lzma -o "$tmp/$p-upx" "$tmp/$p-static" >/dev/null && mv "$tmp/$p-upx" "$out/" || status=1
done

# tinygo: the same idiomatic sources, TinyGo's own small runtime, then strip (-no-debug drops
# DWARF but keeps the symbol table, whose file names also depend on the TinyGo cache path).
# -nobounds removes bounds checks, like gc's -B in optimized.
# GC: leaking (never frees) on amd64; on arm64 it does not link with scheduler=none (TinyGo 0.43's
# asm_arm64.S references tinygo_scanstack, which only the other GCs define), so conservative.
# Optimization level: hello is 6x smaller at -Os than at -Oz (at -Os LLVM inlines fmt.Println
# far enough that the type switch on its constant string argument folds and most of fmt's
# reflection goes); tcp prints a non-constant error, keeps that code anyway, and is smaller at -Oz.
case $arch in
  arm64) tgc=conservative ;;
  amd64) tgc=leaking ;;
esac
for p in "${progs[@]}"; do
  case $p in
    hello) topt=s ;;
    tcp)   topt=z ;;
  esac
  ( cd "$src" && tinygo build -opt=$topt -no-debug -panic=trap -nobounds -scheduler=none -gc=$tgc \
      -o "$tmp/$p-tinygo" "./$p" ) && strip_all "$tmp/$p-tinygo" && mv "$tmp/$p-tinygo" "$out/" || status=1
done

# extreme: runtime-free sources (go/linux/extreme). TinyGo compiles them to an LLVM IR module;
# TinyGo's own embedded clang (the same LLVM 22 backend) turns that module into an object with
# backend flags `tinygo build` does not expose; TinyGo's lld links one segment from a 64 KB
# boundary at 0x400000 (one.ld); elfgolf.py (copied from the Rust slice: it adds the arm64
# e_ident[4..15] hole and detects the program by its allocated sections) writes a minimal
# overlapping ELF header over the first bytes of that segment, keeping the pieces one.ld put in
# the header holes. one.ld places input sections named .holeN at header offset N (elfgolf.py -h
# lists the holes); the rest of the code starts at CODE (elfgolf.py -H). The segment flags come
# from one.ld's @FL@ placeholder: the low 3 bits are PF_R/W/X, the upper bits are ignored by the
# kernel (so hello arm64 passes 0x5d to leave the exit number 93 in p_flags, read by one ldp).
case $arch in
  # -disable-lsr: no loop strength reduction, so the parse loop keeps one pointer increment.
  arm64) triple=aarch64-unknown-linux-musl ccflags=(-mcmodel=tiny -mllvm -disable-lsr) ;;
  # -disable-machine-licm: no loop-invariant hoisting of constants: a hoisted constant can need
  # a callee-saved register, whose spill turns the red zone on, and with the red zone on LLVM
  # cannot use push imm8 / pop reg for small constants and falls back to 10-byte movabs.
  amd64) triple=x86_64-unknown-linux-musl ccflags=(-mllvm -disable-lsr -mllvm -disable-machine-licm) ;;
esac
for p in "${progs[@]}"; do
  # layout and segment flags per program. hello: o56a (14-byte string hole at 40). tcp: o48a.
  # Flags: R+X (5) everywhere except tcp arm64, which reads the reply into the request's hole in
  # the segment and so needs W (7); hello arm64 uses 0x5d (R+X plus the exit number in the
  # ignored upper bits of p_flags).
  case $arch-$p in
    arm64-hello) layout=o56a fl=0x5d ;;
    arm64-tcp)   layout=o48a fl=7 ;;
    *-hello)     layout=o56a fl=5 ;;
    *-tcp)       layout=o48a fl=5 ;;
  esac
  code=$(python3 "$lx/elfgolf.py" -l $layout -H) &&
  sed "s/@FL@/$fl/" "$ext/one.ld" > "$tmp/$p.ld" &&
  # TinyGo to a text IR module (not an executable): the clang step below needs backend flags
  # tinygo build hides, and amd64 needs two IR edits tinygo build cannot pass.
  ( cd "$ext" && tinygo build -target="target-$arch.json" -opt=z -no-debug -panic=trap -nobounds \
      -o "$tmp/$p.ll" "./$p" ) &&
  # amd64 only, both via the IR: 8-byte stack alignment (no SSE, so no 16-byte frame before a
  # call) as a module flag, and tune-cpu=k8 so LLVM folds `c + cur*10 - 48` into one lea.
  { [[ $arch != amd64 ]] ||
    sed -i -e 's/"target-cpu"="x86-64"/"target-cpu"="x86-64" "tune-cpu"="k8"/' \
           -e 's/^!llvm.module.flags = !{\(.*\)}/!llvm.module.flags = !{\1, !90001}\n!90001 = !{i32 1, !"override-stack-alignment", i32 8}/' \
           "$tmp/$p.ll"; } &&
  tinygo clang --target=$triple -c -Oz -fno-pic -ffunction-sections -fdata-sections "${ccflags[@]}" \
    -o "$tmp/$p.o" "$tmp/$p.ll" &&
  tinygo ld.lld -static -e _start --gc-sections --build-id=none -znorelro -T "$tmp/$p.ld" \
    --defsym=CODE="$code" -o "$tmp/$p.elf" "$tmp/$p.o" &&
  python3 "$lx/elfgolf.py" -l $layout "$tmp/$p.elf" "$tmp/$p-extreme" && mv "$tmp/$p-extreme" "$out/" || status=1
done

exit $status
