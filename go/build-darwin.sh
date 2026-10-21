#!/usr/bin/env bash
# Go variants for darwin-arm64. Usage: build-darwin.sh <outdir>
#
# Variants built:
#   default       go build, idiomatic source (go/src)                    baseline
#   optimized     same source, gc and linker flags, then machostrip.py
#   tinygo        idiomatic hello built with TinyGo, then machostrip.py   hello only
#   extreme       Go logic, raw svc syscalls, TinyGo, folded to one page  smallest
#   extreme-ffi   Go logic, libSystem FFI, TinyGo, folded + bind opcodes
#
# Needs: Xcode command line tools (ld, codesign, xcrun), Go 1.27, TinyGo,
# python3. Self-contained and reproducible from a clean checkout, no network:
# the modules have no dependencies, and GOTOOLCHAIN=local makes an older Go
# fail on the go.mod "go 1.27" line instead of downloading a newer toolchain.
# Everything is written under <outdir>, a private temp dir, or the Go and
# TinyGo caches.
set -uo pipefail
export GOTOOLCHAIN=local
out=$(cd "$1" && pwd)
here=$(cd "$(dirname "$0")" && pwd)
dar="$here/darwin"
status=0

tmp=$(mktemp -d "${TMPDIR:-/tmp}/tiny-go-darwin.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

sdklib="$(xcrun --show-sdk-path)/usr/lib"
# TinyGo cannot autodetect its root from a symlinked binary on this setup, so
# derive it: $ROOT/bin/tinygo -> two dirnames up from the resolved binary.
if [[ -z "${TINYGOROOT:-}" ]]; then
  tgbin=$(command -v tinygo)
  TINYGOROOT=$(python3 -c "import os,sys;print(os.path.dirname(os.path.dirname(os.path.realpath(sys.argv[1]))))" "$tgbin")
  export TINYGOROOT
fi

fail() { echo "  FAIL: $1" >&2; status=1; }

# run <log> <cmd...>: run a step, keep its output out of the way, and print it
# if the step fails (machostrip.py prints the new size on success).
run() {
  local log=$1; shift
  "$@" >"$log" 2>&1 || { cat "$log" >&2; return 1; }
}

# ---- default ---------------------------------------------------------------
( cd "$here/src" && for p in hello tcp; do
    go build -o "$out/$p-default" "./$p" || exit 1
  done ) || fail "default"

# strip_sign <in> <out>: the generic __LINKEDIT strip and ad-hoc re-sign, then
# codesign's own strict check of the result.
strip_sign() {
  run "$tmp/strip.log" python3 -B "$dar/tools/machostrip.py" "$1" "$2" \
    && run "$tmp/verify.log" codesign --verify --strict "$2"
}

# ---- optimized -------------------------------------------------------------
# Same source, flags only. -buildvcs=false: no VCS stamp, so the bytes do not
# depend on the git state. -l -B: no inlining, no bounds checks. -s -w: no
# symbol table, no DWARF. External link through ld so it can -dead_strip, drop
# __unwind_info (Go unwinds with its own pclntab) and export nothing (which
# also clears the weak-symbol flags machostrip.py refuses). machostrip.py then
# keeps only the chained fixups in __LINKEDIT and re-signs with short hashes.
optld='-s -w -buildid= -linkmode=external -extldflags "-Wl,-dead_strip -Wl,-no_compact_unwind -Wl,-no_exported_symbols"'
( cd "$here/src" && for p in hello tcp; do
    go build -buildvcs=false -trimpath -gcflags="all=-l -B" -ldflags="$optld" -o "$tmp/$p-optimized" "./$p" \
      && strip_sign "$tmp/$p-optimized" "$out/$p-optimized" || exit 1
  done ) || fail "optimized"

# ---- tinygo (hello only; the idiomatic tcp needs net, which TinyGo's runtime
#      cannot dial on darwin: "Netdev not set") ------------------------------
# -opt=2 is smaller than -opt=z here (z keeps more of fmt), and -gc=leaking
# (allocate, never free) is the smallest collector that links.
if run "$tmp/tg.log" bash -c 'cd "$1" && tinygo build -opt=2 -no-debug -panic=trap -scheduler=none -gc=leaking -o "$2" ./hello' \
     _ "$here/src" "$tmp/hello-tinygo"; then
  strip_sign "$tmp/hello-tinygo" "$out/hello-tinygo" || fail "tinygo (strip/sign)"
else
  fail "tinygo"
fi

# ---- extreme and extreme-ffi -----------------------------------------------
# TinyGo compiles the Go package to an object; ld links it with appmain as the
# LC_MAIN entry; machofold.py folds the result into one 16 KB page (plus the
# dyld bind opcodes for the FFI imports).
tgflags=(-opt=z -no-debug -panic=trap -scheduler=none -gc=none)

# tgld <module dir> <package> <output> [ld flags...]
tgld() {
  local dir=$1 pkg=$2 o=$3; shift 3
  run "$o.log" bash -c 'cd "$1" && shift && tinygo build "$@"' _ "$dir" "${tgflags[@]}" -o "$o.o" "./$pkg" \
    && run "$o.log" ld -e _appmain -dead_strip "$@" -o "$o" "$o.o" -lSystem -L"$sdklib"
}

# The syscall wrapper's register-safety test, built the same way. If it does
# not exit 0, the wrapper is broken and extreme is not shipped.
if ! tgld "$dar/extreme" regtest "$tmp/regtest"; then
  fail "extreme (regtest build)"
elif "$tmp/regtest"; then
  for p in hello tcp; do
    tgld "$dar/extreme" "$p" "$tmp/$p-ex" \
      && run "$tmp/fold.log" python3 -B "$dar/tools/machofold.py" "$tmp/$p-ex" "$out/$p-extreme" \
      || fail "extreme $p"
  done
else
  fail "extreme (regtest exit $?)"
fi

for p in hello tcp; do
  tgld "$dar/ffi" "$p" "$tmp/$p-ffi" -bind_at_load \
    && run "$tmp/fold.log" python3 -B "$dar/tools/machofold.py" "$tmp/$p-ffi" "$out/$p-extreme-ffi" \
    || fail "extreme-ffi $p"
done

exit $status
