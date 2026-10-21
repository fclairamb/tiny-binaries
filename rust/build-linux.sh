#!/usr/bin/env bash
# Rust variants for linux-arm64 and linux-amd64. Usage: build-linux.sh <outdir>
#
# Builds, into <outdir>:
#   hello-default   tcp-default    plain `cargo build --release` (idiomatic std)
#   hello-optimized tcp-optimized  same sources, size flags + build-std + sstrip
#   hello-extreme   tcp-extreme    no_std raw-syscall crate, linker script, sstrip, header golf
#
# Keeps building the remaining variants if one fails and exits non-zero at the end.
# Everything is written under <outdir> or the per-arch target dir in /cache; the repo
# is shared between the host and the containers, so each build gets its own target dir.
set -uo pipefail
out=$(cd "$1" && pwd)
here=$(cd "$(dirname "$0")" && pwd)
status=0
arch=$(uname -m)                      # aarch64 or x86_64
triple="$arch-unknown-linux-gnu"
nightly=nightly-2026-10-20
target=/cache/cargo-target/rust
mkdir -p "$target"

note() { echo "[rust/build-linux] $*" >&2; }

# ---- default: the toolchain's plain release build -------------------------------
cargo build --release --manifest-path "$here/std/Cargo.toml" \
  --target-dir "$target/default" || status=1
for p in hello tcp; do
  cp "$target/default/release/$p" "$out/$p-default" || status=1
done

# ---- optimized: same sources, only flags + post-link ----------------------------
# Rebuild std from source for the smallest possible libstd (optimize_for_size, panic
# that aborts immediately with no message machinery), drop unwind tables, relax the
# aarch64 outline-atomics startup ctor, then sstrip the section headers.
opt_rustflags="-Zunstable-options -Cpanic=immediate-abort -Zlocation-detail=none -Zfmt-debug=none"
opt_rustflags+=" -Crelocation-model=static -Cforce-unwind-tables=no"
opt_rustflags+=" -Clink-arg=-Wl,--build-id=none -Clink-arg=-Wl,-z,norelro -Clink-arg=-Wl,--gc-sections"
[ "$arch" = aarch64 ] && opt_rustflags+=" -Ctarget-feature=-outline-atomics"
if RUSTFLAGS="$opt_rustflags" cargo +"$nightly" build --release \
      --manifest-path "$here/std/Cargo.toml" --target-dir "$target/optimized" --target "$triple" \
      -Zbuild-std=std,panic_abort -Zbuild-std-features=optimize_for_size \
      --config 'profile.release.opt-level="z"' --config profile.release.lto=true \
      --config profile.release.codegen-units=1 --config 'profile.release.panic="abort"' \
      --config profile.release.strip=true; then
  for p in hello tcp; do
    cp "$target/optimized/$triple/release/$p" "$out/$p-optimized" \
      && sstrip "$out/$p-optimized" || status=1
  done
else
  note "optimized build failed"; status=1
fi

# ---- extreme: no_std, raw syscalls, one PT_LOAD, sstrip, header golf -------------
# The header golf shifts the whole load image down by 8 bytes, so the code must be
# position-independent. aarch64 is PC-relative under relocation-model=static (adr/
# adrp), but x86_64 under static bakes in absolute data addresses, so it needs pic
# (RIP-relative) to survive the shift. Both still link as a static ET_EXEC.
ext_reloc=static
[ "$arch" = x86_64 ] && ext_reloc=pic
ext_rustflags="-Cpanic=abort -Crelocation-model=$ext_reloc -Cforce-unwind-tables=no"
ext_rustflags+=" -Clink-arg=-nostartfiles -Clink-arg=-nostdlib -Clink-arg=-static"
ext_rustflags+=" -Clink-arg=-fuse-ld=lld -Clink-arg=-Wl,-T,$here/linux/extreme/tiny.ld"
ext_rustflags+=" -Clink-arg=-Wl,--build-id=none -Clink-arg=-Wl,-n"
if RUSTFLAGS="$ext_rustflags" cargo build --release \
      --manifest-path "$here/linux/extreme/Cargo.toml" --target-dir "$target/extreme" --target "$triple"; then
  for p in hello tcp; do
    src="$target/extreme/$triple/release/$p"
    if cp "$src" "$out/$p-extreme" && sstrip "$out/$p-extreme" \
         && python3 "$here/linux/elfgolf.py" "$out/$p-extreme" "$out/$p-extreme.g" \
         && mv "$out/$p-extreme.g" "$out/$p-extreme" && chmod +x "$out/$p-extreme"; then
      :
    else
      note "extreme $p failed"; status=1
    fi
  done
else
  note "extreme build failed"; status=1
fi

exit $status
