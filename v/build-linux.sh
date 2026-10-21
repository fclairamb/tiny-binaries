#!/usr/bin/env bash
# V variants for linux-arm64 and linux-amd64. Usage: build-linux.sh <outdir>
set -uo pipefail
out=$(cd "$1" && pwd); here=$(cd "$(dirname "$0")" && pwd); status=0
for p in hello tcp; do
  v -prod -o "$out/$p-default" "$here/src/$p.v" || status=1
done
exit $status
