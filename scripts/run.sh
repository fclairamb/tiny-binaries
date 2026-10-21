#!/usr/bin/env bash
# Build and test binaries.
#
#   scripts/run.sh                          all languages, all platforms
#   scripts/run.sh -p linux-amd64 c rust    some languages on one platform
#   scripts/run.sh -p linux-arm64 -- sh     open a shell in the linux-arm64 build image
#
# Platforms: darwin-arm64 (this Mac), linux-arm64 and linux-amd64 (docker/Dockerfile image).
# Each <lang>/build.sh is called with its output directory, out/<platform>/<lang>, and runs in the
# target environment. scripts/check.py then tests that directory.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
platforms=()
command_mode=false
while [[ $# -gt 0 ]]; do
  case $1 in
    -p) platforms+=("$2"); shift 2 ;;
    --) command_mode=true; shift; break ;;
    -*) echo "unknown option: $1" >&2; exit 2 ;;
    *) break ;;
  esac
done
[[ ${#platforms[@]} -gt 0 ]] || platforms=(darwin-arm64 linux-arm64 linux-amd64)

# in_env <platform> <command...>: run a command in the repo root, natively or in the build image.
in_env() {
  local platform=$1
  shift
  case $platform in
    darwin-arm64)
      [[ $(uname -sm) == "Darwin arm64" ]] || { echo "darwin-arm64 needs an Apple Silicon Mac" >&2; return 1; }
      (cd "$root" && "$@")
      ;;
    linux-arm64 | linux-amd64)
      local arch=${platform#linux-} tty=()
      [[ -t 0 ]] && tty=(-it)
      docker run --rm "${tty[@]}" --platform "linux/$arch" \
        -v "$root:/src" -v "tiny-binaries-cache-$arch:/cache" -w /src \
        -e GOCACHE=/cache/go -e GOPATH=/cache/gopath -e VCACHE=/cache/v -e VMODULES=/cache/vmodules \
        -e XDG_CACHE_HOME=/cache/xdg \
        "tiny-binaries:$arch" "$@"
      ;;
    *)
      echo "unknown platform: $platform" >&2
      return 1
      ;;
  esac
}

if $command_mode; then
  for p in "${platforms[@]}"; do in_env "$p" "$@"; done
  exit
fi

langs=("$@")
[[ ${#langs[@]} -gt 0 ]] || langs=(c go rust v asm)

status=0
for p in "${platforms[@]}"; do
  for l in "${langs[@]}"; do
    out=out/$p/$l
    rm -rf "${root:?}/$out"
    mkdir -p "$root/$out"
    echo "== $l on $p"
    if ! in_env "$p" "$l/build.sh" "$out"; then
      echo "BUILD FAILED: $l on $p" >&2
      status=1
    fi
    in_env "$p" python3 scripts/check.py "$out" || status=1
  done
done
exit $status
