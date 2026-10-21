#!/usr/bin/env bash
# Rust variants for darwin-arm64. Usage: build-darwin.sh <outdir>
#
# Variants:
#   default      plain `cargo build --release` of the shared idiomatic source (rust/std)
#   optimized    same source: size profile, nightly build-std, linker flags, strip, codesign
#   extreme      no_std raw-syscall crate in darwin/extreme, folded into one 16 KiB page
#   extreme-ffi  same logic calling libSystem through FFI, folded the same way
#
# Prerequisites: rustup (keg-only here, so its bin dir is prepended to PATH) with
#   rustup toolchain install 1.99.1 --profile minimal
#   rustup toolchain install nightly-2026-10-20 --profile minimal --component rust-src
# rustup downloads a missing pinned toolchain by itself. `optimized` rebuilds std
# with -Zbuild-std, so on the first build cargo also fetches std's own crates
# (cfg-if, hashbrown, libc, ...) from crates.io into $CARGO_HOME. Everything else
# is written to <outdir> and to the cargo target dirs under $TMPDIR.
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

# ---- default: the toolchain's plain release build -------------------------------
if cargo "+$stable" build --release --manifest-path "$here/std/Cargo.toml" \
     --target-dir "$target/default"; then
  for p in hello tcp; do cp "$target/default/release/$p" "$out/$p-default" || status=1; done
else
  note "default build failed"; status=1
fi

# ---- optimized: same source, flags only ------------------------------------------
# Profile: opt-level z, fat LTO, 1 codegen unit, panic=abort, strip. Nightly rebuilds
# std for size (optimize_for_size) with the immediate-abort panic strategy and no
# location or Debug formatting. Linker: no separate __DATA_CONST segment, __TEXT's
# __const moved into __DATA (it then fits in one __TEXT page), chained fixups (no
# lazy-binding stubs), no exports, no function starts, data-in-code or source
# version. codesign re-signs with 16 KiB hash pages and a short identifier.
opt_rustflags="-Zunstable-options -Cpanic=immediate-abort -Zlocation-detail=none -Zfmt-debug=none"
for a in -dead_strip -no_data_const -rename_section,__TEXT,__const,__DATA,__const -fixup_chains \
         -exported_symbols_list,/dev/null -x -no_function_starts -no_data_in_code_info -no_source_version; do
  opt_rustflags+=" -Clink-arg=-Wl,$a"
done
if RUSTFLAGS="$opt_rustflags" cargo "+$nightly" build --release \
     --manifest-path "$here/std/Cargo.toml" --target-dir "$target/optimized" --target "$triple" \
     -Zbuild-std=std,panic_abort -Zbuild-std-features=optimize_for_size \
     --config 'profile.release.opt-level="z"' --config 'profile.release.lto="fat"' \
     --config 'profile.release.codegen-units=1' --config 'profile.release.panic="abort"' \
     --config 'profile.release.strip=true'; then
  for p in hello tcp; do
    cp "$target/optimized/$triple/release/$p" "$out/$p-optimized" \
      && codesign -s - -f -i "$p" "$out/$p-optimized" 2>/dev/null || status=1
  done
else
  note "optimized build failed"; status=1
fi

# ---- extreme, extreme-ffi: no_std crates, folded by the generic macho_pack.py -----
# No crt, LC_MAIN entry `main`, libSystem linked only because dyld requires it.
# Classic dyld info (-no_fixup_chains) and bind-at-load, so imports (extreme-ffi)
# are plain bind opcodes and the GOT has no file content; macho_pack.py refuses
# anything it cannot fold safely.
ex_rustflags=""
for a in -nostartfiles -Wl,-e,_main -lSystem -Wl,-dead_strip -Wl,-no_fixup_chains -Wl,-bind_at_load \
         -Wl,-no_function_starts -Wl,-no_data_in_code_info; do
  ex_rustflags+=" -Clink-arg=$a"
done
for v in extreme extreme-ffi; do
  if RUSTFLAGS="$ex_rustflags" cargo "+$stable" build --release \
       --manifest-path "$here/darwin/$v/Cargo.toml" --target-dir "$target/$v"; then
    for p in hello tcp; do
      python3 -I "$here/darwin/macho_pack.py" "$target/$v/release/$p" "$out/$p-$v" \
        || { note "macho_pack.py failed on $v $p"; status=1; }
    done
  else
    note "$v build failed"; status=1
  fi
done

exit $status
