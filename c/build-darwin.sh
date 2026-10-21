#!/usr/bin/env bash
# C variants for darwin-arm64. Usage: build-darwin.sh <outdir>
set -uo pipefail
out=$(cd "$1" && pwd); here=$(cd "$(dirname "$0")" && pwd); status=0
for p in hello tcp; do
  cc -O2 -o "$out/$p-default" "$here/src/$p.c" || status=1
done
exit $status
