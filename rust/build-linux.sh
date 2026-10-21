#!/usr/bin/env bash
# Rust variants for linux-arm64 and linux-amd64. Usage: build-linux.sh <outdir>
# Notes and size ladders: rust/linux/README.md
#
#   hello-default   tcp-default    plain `cargo build --release` (idiomatic std, rust/linux/std:
#                                  rust/std with tcp's fail() fixed, see its Cargo.toml)
#   hello-optimized tcp-optimized  same sources, size flags + build-std + lld flags + sstrip
#   hello-extreme   tcp-extreme    no_std raw-syscall crate (rust/linux/extreme), one
#                                  segment, pieces in ELF header holes, elfgolf.py
#
# Keeps building the remaining variants if one fails and exits non-zero at the end.
# Writes only to <outdir> and the per-arch cache volume (/cache). No network: build-std
# takes the standard library's dependencies from the copies vendored in rust-src.
set -uo pipefail
out=$(cd "$1" && pwd) || { echo "[rust/build-linux] no output directory: $1" >&2; exit 1; }
here=$(cd "$(dirname "$0")" && pwd)
lx=$here/linux
src=$lx/std                           # default and optimized: rust/std with the stderr fix
status=0
arch=$(uname -m)                      # aarch64 or x86_64
stable=1.99.1                         # the image's `stable`; the sizes in the notes are for it
nightly=nightly-2026-10-20
target=/cache/cargo-target/rust
mkdir -p "$target"
export CARGO_HOME=/cache/cargo-home
mkdir -p "$CARGO_HOME"

note() { echo "[rust/build-linux] $*" >&2; }

# ---- default: the toolchain's plain release build -------------------------------
v=$(rustc +stable --version) || { note "no stable toolchain"; status=1; }
case $v in
  "rustc $stable "*) ;;
  *) note "warning: stable is '$v', not $stable: default sizes will differ from the notes" ;;
esac
if cargo +stable build --release --offline --locked --manifest-path "$src/Cargo.toml" \
      --target-dir "$target/default"; then
  for p in hello tcp; do
    cp "$target/default/release/$p" "$out/$p-default" || { note "default $p failed"; status=1; }
  done
else
  note "default build failed"; status=1
fi

# build-std resolves the sysroot's Cargo.lock against crates.io. rust-src ships those
# crates in library/vendor (with a .cargo/config.toml that cargo only reads when run from
# library/), so point crates.io at that directory and build offline. Our crates have no
# dependencies, so the replacement only affects the sysroot.
vendor=$(rustc +"$nightly" --print sysroot)/lib/rustlib/src/rust/library/vendor
[ -d "$vendor" ] || { note "no vendored crates in rust-src: $vendor"; status=1; }
offline=(--offline --config "source.crates-io.replace-with='rust-src'"
         --config "source.rust-src.directory='$vendor'")

# ---- optimized: same sources, only flags + post-link ----------------------------
# Rebuild std from source for size (optimize_for_size), panics that abort with no message
# machinery, no unwind tables; aarch64 also drops the outline-atomics startup constructor.
# Link with lld (rust-lld is already the default on x86_64): one R+X segment instead of a
# separate read-only one, identical code folding, no .eh_frame_hdr. Then sstrip removes
# the section headers.
triple=$arch-unknown-linux-gnu
opt_rustflags="-Zunstable-options -Cpanic=immediate-abort -Zlocation-detail=none -Zfmt-debug=none"
opt_rustflags+=" -Crelocation-model=static -Cforce-unwind-tables=no"
opt_rustflags+=" -Cllvm-args=-enable-machine-outliner=always"
opt_rustflags+=" -Clink-arg=-Wl,--build-id=none -Clink-arg=-Wl,-z,norelro -Clink-arg=-Wl,--gc-sections"
opt_rustflags+=" -Clink-arg=-Wl,--no-rosegment -Clink-arg=-Wl,--icf=all -Clink-arg=-Wl,--no-eh-frame-hdr"
[ "$arch" = aarch64 ] && opt_rustflags+=" -Ctarget-feature=-outline-atomics -Clink-arg=-fuse-ld=lld"
if RUSTFLAGS="$opt_rustflags" cargo +"$nightly" build --release "${offline[@]}" \
      --manifest-path "$src/Cargo.toml" --target-dir "$target/optimized" --target "$triple" \
      -Zbuild-std=std,panic_abort -Zbuild-std-features=optimize_for_size \
      --config 'profile.release.opt-level="z"' --config profile.release.lto=true \
      --config profile.release.codegen-units=1 --config 'profile.release.panic="abort"' \
      --config profile.release.strip=true; then
  for p in hello tcp; do
    { cp "$target/optimized/$triple/release/$p" "$out/$p-optimized" \
      && sstrip "$out/$p-optimized"; } || { note "optimized $p failed"; status=1; }
  done
else
  note "optimized build failed"; status=1
fi

# ---- extreme: no_std, raw syscalls, one segment, header holes, elfgolf -------------
# <arch>-unknown-none: no red zone on x86_64 (so -Oz can load small constants with
# push imm8 / pop), no forced frame pointers on aarch64; core is rebuilt from rust-src.
# Static relocation model: absolute addresses, which elfgolf.py never moves.
# extreme/build.rs links with holes.ld (and makes cargo relink when it changes); per
# program, the header layout (elfgolf.py) and where the code starts (holes.ld CODE).
xtriple=$arch-unknown-none
ext_rustflags="-Cpanic=abort -Crelocation-model=static -Cforce-unwind-tables=no -Ztrap-unreachable=no"
case $arch in
  x86_64)
    # small code model: 5-byte `mov esi, imm32` addresses (the target defaults to kernel).
    # tune-cpu=k8: LLVM folds `c + cur*10 - 48` into one lea; same x86-64 ISA.
    # override-stack-alignment=8: no padding push before a call (there is no SSE code).
    ext_rustflags+=" -Ccode-model=small -Ztune-cpu=k8 -Cllvm-args=-disable-lsr"
    ext_rustflags+=" -Zllvm-module-flag=override-stack-alignment:u32:8:override" ;;
  aarch64)
    # adr instead of adrp+add. elfgolf.py also uses e_ident[4..15] as a hole on aarch64
    # (the arm64 kernel ignores it, Rosetta does not, so not on x86_64).
    ext_rustflags+=" -Ccode-model=tiny -Cllvm-args=-disable-lsr" ;;
esac
for p in hello tcp; do
  case $p in hello) layout=o56a ;; tcp) layout=o48a ;; esac
  elf=$target/extreme/$xtriple/release/$p
  if code=$(python3 -I "$lx/elfgolf.py" -l $layout -H) \
     && RUSTFLAGS="$ext_rustflags" cargo +"$nightly" rustc --release --bin "$p" "${offline[@]}" \
          --manifest-path "$lx/extreme/Cargo.toml" --target-dir "$target/extreme" \
          --target "$xtriple" -Zbuild-std=core -- \
          -Clink-arg=--defsym=CODE="$code" \
          -Clink-arg=--build-id=none -Clink-arg=-n -Clink-arg=--no-rosegment -Clink-arg=-static \
     && python3 -I "$lx/elfgolf.py" -l $layout "$elf" "$out/$p-extreme"; then
    :
  else
    note "extreme $p failed"; status=1
  fi
done

exit $status
