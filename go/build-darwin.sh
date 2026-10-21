#!/usr/bin/env bash
# Go variants for darwin-arm64. Usage: build-darwin.sh <outdir>
set -uo pipefail
out=$(cd "$1" && pwd); here=$(cd "$(dirname "$0")" && pwd); status=0
cd "$here/src"
for p in hello tcp; do
  go build -o "$out/$p-default" "./$p" || status=1
done
exit $status
