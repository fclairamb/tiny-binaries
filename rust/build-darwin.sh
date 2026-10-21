#!/usr/bin/env bash
# Rust variants for darwin-arm64. Usage: build-darwin.sh <outdir>
#
# Variants:
#   default         plain `cargo build --release` of the idiomatic source (rust/std)
#   optimized       same source and compiler: size profile, build-std, linker flags, macho_pack.py --strip
#   extreme         no_std raw-syscall crate in darwin/extreme, folded into one 16 KiB page
#   extreme-strict  the same linker output in the normal layout (macho_pack.py --strip)
#   extreme-ffi     same logic calling libSystem through FFI, folded like extreme
#
# Prerequisites: rustup (keg-only here, so its bin dir is prepended to PATH).
# Every variant uses the one pinned toolchain. rustup installs it by itself when
# it is missing (network), and the script adds its rust-src component (a no-op,
# offline, when it is there). Cargo runs --offline --locked: `optimized` takes
# std's own dependencies from the copies vendored in rust-src.
#
# Reproducible: every run builds from scratch in a fresh target dir and CARGO_HOME
# under $TMPDIR/tiny-binaries/darwin-arm64 (removed on exit), because cargo's
# fingerprints miss inputs that change the bytes (MACOSX_DEPLOYMENT_TARGET, the
# linker). Cargo runs from /, so the only config files it reads are
# /.cargo/config.toml and the empty CARGO_HOME, not ~/.cargo/config.toml or any
# other .cargo/config.toml above the caller's cwd. The caller's CARGO*, RUST*
# (but RUSTUP*), SDKROOT, DEVELOPER_DIR and TOOLCHAINS are dropped, /usr/bin
# comes first in PATH (Apple's cc), the deployment target is pinned to rustc's
# default and SDKROOT to xcrun's default SDK. What is left is the system's Xcode
# selection (xcode-select), which the log prints as the ld and SDK versions.
set -uo pipefail
out=$(cd "${1:?usage: build-darwin.sh <outdir>}" && pwd) || exit 1
here=$(cd "$(dirname "$0")" && pwd)
status=0
note() { echo "[rust/build-darwin] $*" >&2; }

for v in $(compgen -e); do
  case $v in RUSTUP*) ;; CARGO* | RUST* | SDKROOT | DEVELOPER_DIR | TOOLCHAINS) unset "$v" ;; esac
done
export PATH="/opt/homebrew/opt/rustup/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
export MACOSX_DEPLOYMENT_TARGET=11.0
SDKROOT=$(xcrun --sdk macosx --show-sdk-path) && sdkver=$(xcrun --sdk macosx --show-sdk-version) \
  && ld=$(cc -print-prog-name=ld) && ldver=$("$ld" -v 2>&1 | head -1) \
  || { note "cannot find the macOS SDK or the linker"; exit 1; }
export SDKROOT
note "linker $ld: $ldver"
note "SDK $SDKROOT ($sdkver)"
mkdir -p "${TMPDIR:-/tmp}/tiny-binaries/darwin-arm64" \
  && tmp=$(mktemp -d "${TMPDIR:-/tmp}/tiny-binaries/darwin-arm64/rust.XXXXXX") \
  || { note "cannot create a temp dir"; exit 1; }
trap 'rm -rf "$tmp"' EXIT
cd / || exit 1
export CARGO_HOME=$tmp/cargo-home
target=$tmp/target
toolchain=1.99.1
triple=aarch64-apple-darwin

# pack <macho_pack.py args...> <out file>: run the generic packer, then check the
# signature it wrote the way the system does.
pack() {
  /usr/bin/python3 -I "$here/darwin/macho_pack.py" "$@" && codesign --verify --strict "${@: -1}" \
    || { note "macho_pack.py or codesign --verify failed: $*"; status=1; }
}

# ---- default: the toolchain's plain release build -------------------------------
if cargo "+$toolchain" build --release --offline --locked --manifest-path "$here/std/Cargo.toml" \
     --target-dir "$target/default"; then
  for p in hello tcp; do cp "$target/default/release/$p" "$out/$p-default" || status=1; done
else
  note "default build failed"; status=1
fi

# ---- optimized: same source, same compiler, flags only ---------------------------
# Profile: opt-level z, fat LTO, 1 codegen unit, panic=abort, strip. Then std
# is rebuilt from the toolchain's own rust-src for size (optimize_for_size, the
# mem functions from compiler-builtins instead of libSystem's) with the
# immediate-abort panic strategy and no location or Debug formatting. These
# are unstable options: RUSTC_BOOTSTRAP=1 lets the stable compiler and cargo
# take them (the Linux kernel builds its Rust the same way). Linker: one data
# segment instead of __DATA_CONST + __DATA, __TEXT's __const moved into it
# (then __TEXT fits in one page), classic dyld info bound at load (no lazy
# stubs, smaller than chained fixups). macho_pack.py --strip keeps the layout
# and rebuilds __LINKEDIT with only the fixups (binds re-encoded) and a new
# ad-hoc signature. rust-src's library/vendor holds std's dependencies
# (cfg-if, hashbrown, libc, ...): cargo reads it only when run from library/,
# so crates.io is pointed at it.
opt_rustflags="-Zunstable-options -Cpanic=immediate-abort -Zlocation-detail=none -Zfmt-debug=none"
for a in -no_data_const -rename_section,__TEXT,__const,__DATA,__const -no_fixup_chains -bind_at_load; do
  opt_rustflags+=" -Clink-arg=-Wl,$a"
done
if rustup component add rust-src --toolchain "$toolchain" \
   && vendor=$(rustc "+$toolchain" --print sysroot)/lib/rustlib/src/rust/library/vendor \
   && { [ -d "$vendor" ] || { note "no vendored crates in rust-src: $vendor"; false; }; } \
   && RUSTC_BOOTSTRAP=1 RUSTFLAGS="$opt_rustflags" cargo "+$toolchain" build --release --offline --locked \
     --config "source.crates-io.replace-with='rust-src'" --config "source.rust-src.directory='$vendor'" \
     --manifest-path "$here/std/Cargo.toml" --target-dir "$target/optimized" --target "$triple" \
     -Zbuild-std=std,panic_abort -Zbuild-std-features=optimize_for_size,compiler-builtins-mem \
     --config 'profile.release.opt-level="z"' --config 'profile.release.lto="fat"' \
     --config 'profile.release.codegen-units=1' --config 'profile.release.panic="abort"' \
     --config 'profile.release.strip=true'; then
  for p in hello tcp; do pack --strip "$target/optimized/$triple/release/$p" "$out/$p-optimized"; done
else
  note "optimized build failed"; status=1
fi

# ---- extreme, extreme-strict, extreme-ffi: no_std crates + macho_pack.py ---------
# LC_MAIN entry `main`; rustc links with -nodefaultlibs, and ld wants libSystem in
# any dynamic executable. Classic dyld info bound at load, so imports (extreme-ffi)
# are plain bind opcodes and the GOT has no file content.
ex_rustflags="-Clink-arg=-lSystem -Clink-arg=-Wl,-no_fixup_chains -Clink-arg=-Wl,-bind_at_load"
for v in extreme extreme-ffi; do
  if RUSTFLAGS="$ex_rustflags" cargo "+$toolchain" build --release --offline --locked \
       --manifest-path "$here/darwin/$v/Cargo.toml" --target-dir "$target/$v"; then
    for p in hello tcp; do
      pack "$target/$v/release/$p" "$out/$p-$v"
      if [ "$v" = extreme ]; then pack --strip "$target/$v/release/$p" "$out/$p-extreme-strict"; fi
    done
  else
    note "$v build failed"; status=1
  fi
done

exit $status
