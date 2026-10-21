#!/usr/bin/env bash
# Rust variants for linux-arm64 and linux-amd64. Usage: build-linux.sh <outdir>
set -uo pipefail
out=$(cd "$1" && pwd); here=$(cd "$(dirname "$0")" && pwd); status=0
# Each platform gets its own target dir: the repo is shared between the host and the containers.
target=/cache/cargo-target/rust
cargo build --release --manifest-path "$here/std/Cargo.toml" --target-dir "$target/default" || status=1
for p in hello tcp; do
  cp "$target/default/release/$p" "$out/$p-default" || status=1
done
exit $status
