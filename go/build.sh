#!/usr/bin/env bash
# Builds every variant of this language into $1 (an empty directory), for the current platform.
# Called by scripts/run.sh, natively on macOS or inside the docker/Dockerfile image on Linux.
here=$(cd "$(dirname "$0")" && pwd)
case $(uname -s) in
  Darwin) exec "$here/build-darwin.sh" "$1" ;;
  Linux) exec "$here/build-linux.sh" "$1" ;;
  *) echo "unsupported OS: $(uname -s)" >&2; exit 1 ;;
esac
