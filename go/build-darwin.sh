#!/usr/bin/env bash
# Go variants for darwin-arm64. Usage: build-darwin.sh <outdir>
#
# Variants built:
#   default       go build, idiomatic source (go/src)                 baseline
#   optimized     same source, -trimpath -ldflags="-s -w -buildid="   flags only
#   tinygo        idiomatic hello built with TinyGo + llvm-strip       hello only
#   extreme       Go logic, raw svc syscalls, TinyGo, folded to 1 page smallest
#   extreme-ffi   Go logic, libSystem FFI, TinyGo, bind-at-load+packed clean sign
#
# Self-contained and reproducible from a clean checkout: the toolchains may fetch
# their own standard library, nothing else; everything is written under <outdir>
# or a private temp dir.
set -uo pipefail
out=$(cd "$1" && pwd)
here=$(cd "$(dirname "$0")" && pwd)
status=0

tmp=$(mktemp -d "${TMPDIR:-/tmp}/tiny-go-darwin.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

# Toolchain locations.
sdklib="$(xcrun --show-sdk-path)/usr/lib"
objdump=/opt/homebrew/opt/llvm/bin/llvm-objdump
strip=/opt/homebrew/opt/llvm/bin/llvm-strip
# TinyGo cannot autodetect its root from a symlinked binary on this setup, so
# derive it: $ROOT/bin/tinygo -> two dirnames up from the resolved binary.
if [[ -z "${TINYGOROOT:-}" ]]; then
  tgbin=$(command -v tinygo)
  TINYGOROOT=$(python3 -c "import os,sys;print(os.path.dirname(os.path.dirname(os.path.realpath(sys.argv[1]))))" "$tgbin")
  export TINYGOROOT
fi

tgflags=(-opt=z -no-debug -panic=trap -scheduler=none -gc=none)

fail() { echo "  FAIL: $1" >&2; status=1; }

# ---- default ---------------------------------------------------------------
( cd "$here/src" && for p in hello tcp; do
    go build -o "$out/$p-default" "./$p" || exit 1
  done ) || fail "default"

# ---- optimized -------------------------------------------------------------
( cd "$here/src" && for p in hello tcp; do
    go build -trimpath -ldflags="-s -w -buildid=" -o "$out/$p-optimized" "./$p" || exit 1
  done ) || fail "optimized"

# ---- tinygo (hello only; the idiomatic tcp needs net, which TinyGo's runtime
#      cannot dial on darwin: "Netdev not set") ------------------------------
if ( cd "$here/src" && tinygo build -opt=z -no-debug -panic=trap -scheduler=none \
       -gc=conservative -o "$tmp/hello-tinygo" ./hello ) 2>"$tmp/tg.log"; then
  "$strip" -x "$tmp/hello-tinygo" -o "$out/hello-tinygo" \
    && codesign -s - -f "$out/hello-tinygo" >/dev/null 2>&1 \
    || fail "tinygo (strip/sign)"
else
  cat "$tmp/tg.log" >&2; fail "tinygo"
fi

# ---- extreme: raw syscalls, folded into one 16 KB page ---------------------
for p in hello tcp; do
  if ( cd "$here/darwin/extreme" && tinygo build "${tgflags[@]}" -o "$tmp/$p-ex.o" "./$p" ) 2>"$tmp/ex.log" \
     && ld -e _appmain -dead_strip -o "$tmp/$p-ex" "$tmp/$p-ex.o" -lSystem -L"$sdklib" 2>>"$tmp/ex.log"; then
    python3 "$here/darwin/tools/verify_syscalls.py" "$objdump" "$tmp/$p-ex" >/dev/null 2>"$tmp/vs.log" \
      || { cat "$tmp/vs.log" >&2; fail "extreme $p (syscall preamble)"; continue; }
    python3 "$here/darwin/tools/machofold.py" "$tmp/$p-ex" "$out/$p-extreme" >/dev/null \
      || fail "extreme $p (fold)"
  else
    cat "$tmp/ex.log" >&2; fail "extreme $p"
  fi
done

# ---- extreme-ffi: libSystem FFI, bind-at-load, compacted -------------------
for p in hello tcp; do
  if ( cd "$here/darwin/ffi" && tinygo build "${tgflags[@]}" -o "$tmp/$p-ffi.o" "./$p" ) 2>"$tmp/ffi.log" \
     && ld -e _appmain -dead_strip -bind_at_load -o "$tmp/$p-ffi" "$tmp/$p-ffi.o" -lSystem -L"$sdklib" 2>>"$tmp/ffi.log"; then
    python3 "$here/darwin/tools/machopack.py" "$tmp/$p-ffi" "$out/$p-extreme-ffi" >/dev/null \
      || fail "extreme-ffi $p (pack)"
  else
    cat "$tmp/ffi.log" >&2; fail "extreme-ffi $p"
  fi
done

exit $status
