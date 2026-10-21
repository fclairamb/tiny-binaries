#!/usr/bin/env bash
# Test linux-amd64 binaries on a real x86_64 Linux kernel (qemu full-system emulation).
# Usage: scripts/vm-amd64.sh <dir>     e.g. scripts/vm-amd64.sh out/linux-amd64/c
# Runs the same checks as scripts/check.py (in busybox sh). Exit status 1 if any binary fails.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
dir=$(cd "$1" && pwd)
if ! docker image inspect tiny-binaries-vm >/dev/null 2>&1; then
  docker build -q -t tiny-binaries-vm "$root/scripts/vm" >/dev/null
fi
log=$(docker run --rm -v "$dir:/in:ro" tiny-binaries-vm sh -c '
  set -e
  mkdir -p /r/bin /r/t /r/proc /r/dev /r/tmp /r/sys
  cp -a /vm/rootfs/. /r/ && cp /vm/busybox /r/bin/busybox && cp /vm/tcpserver /r/tcpserver && cp /vm/init /r/init && chmod +x /r/init
  for f in /in/hello-* /in/tcp-*; do case $f in *.*) ;; *) [ -f "$f" ] && cp "$f" /r/t/ ;; esac; done
  chmod +x /r/t/* 2>/dev/null || true
  (cd /r && find . | cpio -o -H newc --quiet) > /initrd
  timeout 600 qemu-system-x86_64 -m 512 -nographic -no-reboot -kernel /vm/kernel -initrd /initrd \
    -append "console=ttyS0 quiet panic=-1 rdinit=/init" 2>&1 | tr -d "\r"
' 2>&1) || true
# The BIOS writes escape sequences on the serial console, so match anywhere in the line.
grep -o 'VMRESULT .*' <<<"$log" | sed 's/^VMRESULT //' || true
grep -q 'VMDONE' <<<"$log" || { echo "VM did not finish:" >&2; tail -30 <<<"$log" >&2; exit 1; }
! grep -q 'VMRESULT FAIL' <<<"$log"
