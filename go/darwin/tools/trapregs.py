#!/usr/bin/env python3
"""List the registers a program keeps live across each sys.Call trap.

Usage: objdump -d --no-show-raw-insn <binary> > x.dis; trapregs.py x.dis

Not part of the build: it backs the register list in README.md. Each sys.Call
block (from "sub sp, sp, #0xf0" to "add sp, sp, #0xf0") counts as one
instruction that reads its inputs (the registers of its first three stp) and
writes its output (the ldr just before the add). A backward liveness pass over
the whole __text (bl goes to the callee, ret to every return site of its
function) then gives, for each block, the registers live after it, minus its
output: the values the compiler expects the block to keep. The decoding is a
small arm64 subset (what TinyGo emits here); an unknown branch-like mnemonic
would be read as "first operand written, the others read", so check new
mnemonics before trusting the output. The compiler does not know that exit
never returns, so registers live only on paths after the exit trap show up too.
"""
import re
import sys

BLOCK_START, BLOCK_END = "sp, sp, #0xf0", "sp, sp, #0xf0"


def regs(s):
    out = {"x" + n for _, n in re.findall(r"\b([xw])(\d+)\b", s)}
    if "NZCV" in s:
        out.add("nzcv")
    return out


def target(ops):
    return int(re.search(r"0x([0-9a-f]+)\s*<", ops).group(1), 16)


def main(path):
    ins = []
    for line in open(path).read().splitlines():
        m = re.match(r"\s*([0-9a-f]+):\s+(\S+)\s*(.*)$", line)
        if m:
            ins.append((int(m.group(1), 16), m.group(2), re.sub(r"\s*;.*$", "", m.group(3)).strip()))
    at = {a: i for i, (a, _, _) in enumerate(ins)}

    blocks = {}  # index of the sub -> index of the add
    i = 0
    while i < len(ins):
        if ins[i][1] == "sub" and ins[i][2].startswith(BLOCK_START):
            j = i
            while not (ins[j][1] == "add" and ins[j][2].startswith(BLOCK_END)):
                j += 1
            blocks[i] = j
            i = j
        i += 1
    inside = {k for b, e in blocks.items() for k in range(b + 1, e + 1)}

    uses, defs, succ, calls = [], [], [], {}
    for i, (_, mn, ops) in enumerate(ins):
        parts = [p.strip() for p in re.split(r",(?![^\[]*\])", ops)] if ops else []
        mem = re.search(r"\[([^\]]*)\]", ops)
        base = regs(mem.group(1)) if mem else set()
        wb = "!" in ops or re.search(r"\],\s*#", ops)
        u, d, s = set(), set(), [i + 1]
        if i in blocks:
            e = blocks[i]
            for k in (1, 2, 3):
                u |= regs(ins[i + k][2].split("[")[0])
            d = regs(ins[e - 1][2].split(",")[0])
            s = [e + 1]
        elif i in inside:
            s = []
        elif mn in ("stp", "str", "strb", "strh", "stur", "sturb", "sturh"):
            u = regs(ops)
            d = base if wb else set()
        elif mn in ("ldp", "ldr", "ldrb", "ldrh", "ldur", "ldurb", "ldurh", "ldrsw"):
            d = regs(",".join(parts[:2] if mn == "ldp" else parts[:1])) | (base if wb else set())
            u = base
        elif mn in ("cmp", "cmn", "tst"):
            u, d = regs(ops), {"nzcv"}
        elif mn in ("ccmp", "ccmn"):
            u, d = regs(ops) | {"nzcv"}, {"nzcv"}
        elif mn in ("cbz", "cbnz", "tbz", "tbnz"):
            u, s = regs(parts[0]), [i + 1, at[target(ops)]]
        elif mn == "b":
            s = [at[target(ops)]]
        elif mn.startswith("b."):
            u, s = {"nzcv"}, [i + 1, at[target(ops)]]
        elif mn == "bl":
            t = at[target(ops)]
            calls.setdefault(t, []).append(i + 1)
            d, s = {"x30"}, [t]
        elif mn == "ret":
            u, s = {"x30"}, []
        elif mn in ("brk", "udf"):
            s = []
        elif mn in ("cset", "csetm", "csel", "csinc", "csinv", "csneg", "cinc"):
            d, u = regs(parts[0]), regs(",".join(parts[1:])) | {"nzcv"}
        elif mn == "movk":
            d = u = regs(parts[0])
        elif mn == "msr":
            u, d = regs(parts[1]), regs(parts[0])
        else:  # mov, add, sub, orr, and, lsl, lsr, madd, adrp, mrs, ...
            d, u = regs(parts[0]) if parts else set(), regs(",".join(parts[1:]))
        u.discard("x31"), d.discard("x31")
        uses.append(u), defs.append(d), succ.append([k for k in s if k < len(ins)])

    entries = sorted(set(calls) | {0})
    for i, (_, mn, _) in enumerate(ins):
        if mn == "ret" and i not in inside:
            f = max(e for e in entries if e <= i)
            succ[i] = calls.get(f, [])

    live = [set() for _ in ins]
    changed = True
    while changed:
        changed = False
        for i in reversed(range(len(ins))):
            new = uses[i] | (set().union(*(live[k] for k in succ[i])) - defs[i])
            if new != live[i]:
                live[i], changed = new, True

    order = lambda r: (r == "nzcv", int(r[1:]) if r != "nzcv" else 0)
    union = set()
    for b, e in sorted(blocks.items()):
        across = set().union(*(live[k] for k in succ[b])) - defs[b]
        union |= across
        print("%x: %s" % (ins[b][0], " ".join(sorted(across, key=order)) or "-"))
    print("all:", " ".join(sorted(union, key=order)))


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: trapregs.py <objdump -d output>")
    main(sys.argv[1])
