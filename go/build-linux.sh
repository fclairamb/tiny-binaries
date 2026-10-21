#!/usr/bin/env bash
# Go variants for linux-arm64 and linux-amd64. Usage: build-linux.sh <outdir>
set -uo pipefail
out=$(cd "$1" && pwd); here=$(cd "$(dirname "$0")" && pwd); status=0
cd "$here/src"
for p in hello tcp; do
  go build -o "$out/$p-default" "./$p" || status=1
done
exit $status
