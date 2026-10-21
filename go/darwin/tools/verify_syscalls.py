#!/usr/bin/env python3
"""Guard against a register clash in the extreme variant's syscall preamble.

sys.Call sets x16/x0/x1/x2 then traps with "svc #0x80". The argument values are
placed by the compiler's register allocator into whatever registers it likes,
and the inline asm then moves them into the four fixed ones. If the allocator
ever put one of those argument values into x0, x1, x2 or x16, an earlier move
could overwrite it before it is read, and the syscall would get a wrong
argument. With the current toolchain the allocator uses x8-x14, so the moves are
safe, but to keep that from silently breaking on a toolchain change this checks
every "svc #0x80" in the file: the moves feeding it must each read a register
outside {x0,x1,x2,x16}. It exits non-zero (and the build fails) otherwise.

It reads only the disassembly, so it works on any arm64 Mach-O. Usage:
  verify_syscalls.py <objdump-binary> <mach-o>
"""
import re
import subprocess
import sys

FIXED = {0, 1, 2, 16}
MOV = re.compile(r"mov\s+x(\d+),\s*x(\d+)")
SVC = re.compile(r"\bsvc\s+#0x80\b")


def reg(tok):
    return int(tok)


def main():
    objdump, path = sys.argv[1], sys.argv[2]
    out = subprocess.run([objdump, "-d", "--macho", path],
                         capture_output=True, text=True).stdout
    lines = out.splitlines()
    svc_count = 0
    for i, ln in enumerate(lines):
        if not SVC.search(ln):
            continue
        svc_count += 1
        # Walk backwards over the contiguous run of mov x?, x? feeding this svc.
        seen = {}
        j = i - 1
        while j >= 0:
            m = MOV.search(lines[j])
            if not m:
                break
            dst, src = reg(m.group(1)), reg(m.group(2))
            seen[dst] = src
            j -= 1
        # The four fixed destinations must be set, each from a non-fixed source.
        for d in FIXED:
            if d in seen and seen[d] in FIXED:
                print("unsafe svc preamble near:\n  " +
                      "\n  ".join(lines[j + 1:i + 1]), file=sys.stderr)
                print("mov into x%d reads x%d (a fixed syscall register)"
                      % (d, seen[d]), file=sys.stderr)
                sys.exit(1)
    if svc_count == 0:
        print("no svc #0x80 found in %s" % path, file=sys.stderr)
        sys.exit(1)
    print("ok: %d syscalls, register preambles safe" % svc_count)


if __name__ == "__main__":
    main()
