#!/usr/bin/env bash
# Rust variants for darwin-arm64. Usage: build-darwin.sh <outdir>
#
# Variants:
#   default         plain `cargo build --release` of the idiomatic source (darwin/std)
#   optimized       same source: size profile, nightly build-std, linker flags, macho_pack.py --strip
#   extreme         no_std raw-syscall crate in darwin/extreme, folded into one 16 KiB page
#   extreme-strict  the same linker output in the normal layout (macho_pack.py --strip)
#   extreme-ffi     same logic calling libSystem through FFI, folded like extreme
#
# darwin/std is rust/std with tcp's fail() writing with writeln! instead of
# eprintln!, which panics (a trap under immediate-abort) when stderr is a broken
# pipe. hello.rs is the shared file. Point both builds back at rust/std once it
# has the fix.
#
# Prerequisites: rustup (keg-only here, so its bin dir is prepended to PATH).
# It installs a missing pinned toolchain by itself (network), and the script adds
# rust-src to the nightly (a no-op, offline, when it is there). Cargo runs
# --offline --locked: `optimized` takes std's own dependencies from the copies
# vendored in rust-src. Output goes to <outdir> and the cargo target dirs under
# $TMPDIR.
set -uo pipefail
out=$(cd "$1" && pwd)
here=$(cd "$(dirname "$0")" && pwd)
status=0
note() { echo "[rust/build-darwin] $*" >&2; }

export PATH="/opt/homebrew/opt/rustup/bin:$PATH"
target=${TMPDIR:-/tmp}/tiny-binaries/darwin-arm64/rust
stable=1.99.1
nightly=nightly-2026-10-20
triple=aarch64-apple-darwin

# pack <macho_pack.py args...> <out file>: run the generic packer, then check the
# signature it wrote the way the system does.
pack() {
  python3 -I "$here/darwin/macho_pack.py" "$@" && codesign --verify --strict "${@: -1}" \
    || { note "macho_pack.py or codesign --verify failed: $*"; status=1; }
}

# ---- default: the toolchain's plain release build -------------------------------
if cargo "+$stable" build --release --offline --locked --manifest-path "$here/darwin/std/Cargo.toml" \
     --target-dir "$target/default"; then
  for p in hello tcp; do cp "$target/default/release/$p" "$out/$p-default" || status=1; done
else
  note "default build failed"; status=1
fi

# ---- optimized: same source, flags only ------------------------------------------
# Profile: opt-level z, fat LTO, 1 codegen unit, panic=abort, strip. The pinned
# nightly rebuilds std for size (optimize_for_size) with the immediate-abort panic
# strategy and no location or Debug formatting. Linker: one data segment instead
# of __DATA_CONST + __DATA, __TEXT's __const moved into it (then __TEXT fits in one
# page), classic dyld info bound at load (no lazy stubs, smaller than chained
# fixups). macho_pack.py --strip keeps the layout and rebuilds __LINKEDIT with
# only the fixups and a new ad-hoc signature. build-std needs rust-src, whose
# library/vendor holds std's dependencies (cfg-if, hashbrown, libc, ...): cargo
# reads it only when run from library/, so crates.io is pointed at it.
opt_rustflags="-Zunstable-options -Cpanic=immediate-abort -Zlocation-detail=none -Zfmt-debug=none"
for a in -no_data_const -rename_section,__TEXT,__const,__DATA,__const -no_fixup_chains -bind_at_load; do
  opt_rustflags+=" -Clink-arg=-Wl,$a"
done
if rustup component add rust-src --toolchain "$nightly" \
   && vendor=$(rustc "+$nightly" --print sysroot)/lib/rustlib/src/rust/library/vendor \
   && { [ -d "$vendor" ] || { note "no vendored crates in rust-src: $vendor"; false; }; } \
   && RUSTFLAGS="$opt_rustflags" cargo "+$nightly" build --release --offline --locked \
     --config "source.crates-io.replace-with='rust-src'" --config "source.rust-src.directory='$vendor'" \
     --manifest-path "$here/darwin/std/Cargo.toml" --target-dir "$target/optimized" --target "$triple" \
     -Zbuild-std=std,panic_abort -Zbuild-std-features=optimize_for_size \
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
  if RUSTFLAGS="$ex_rustflags" cargo "+$stable" build --release --offline --locked \
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
