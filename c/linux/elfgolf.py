#!/usr/bin/env python3
"""Rewrite a static ELF64 executable with one PT_LOAD into a minimal header layout.

Usage: elfgolf.py [-l LAYOUT] in out            write the golfed binary
       elfgolf.py [-l LAYOUT] -H                print the header size of the layout
       elfgolf.py [-l LAYOUT] -h [aarch64]      print the holes of the layout (offset:size)

Generic: it takes the segment, the entry point and the machine from the input, writes a
new ELF header and program header, and drops the section headers and every other
program header. It contains no bytes of any program. Trailing zero bytes of the segment
become bss (memsz > filesz).

Every byte keeps its virtual address. The segment is extended down to the start of its
64 KB page and the headers are written over the first H bytes of that page (H, the header
size of the layout, -H). Program bytes may sit in the holes (fields Linux and Rosetta
ignore, -h), so the linker script can put small sections there; elfgolf stops if a
program byte covers any other header field. The program bytes are the allocated
  sections of the input (its nonzero bytes if it has no section headers). A hole, or the
  part of one, that holds no program byte gets the normal header value (e_ident's class,
  data and version, e_version = 1), so tools still read the file when they can.
Either way p_offset is 0 (or 1) and p_vaddr is the page (or the page + 1), which any page
size accepts.

Layouts (H, bytes of header before the code):
  std   120  ELF header, then the program header.
  o56   112  program header at offset 56: p_type is e_phnum/e_shentsize (1, 0),
             p_flags is e_shnum/e_shstrndx.
  o48   104  program header at offset 48: p_type is e_flags (1), p_flags is
             e_ehsize/e_phentsize, p_offset is e_phnum.. (1), so p_vaddr = page + 1.
  A suffix "a" (o56a 104, o48a 96) starts the code 8 bytes earlier, over p_align,
  which Linux ignores for ET_EXEC.
Holes: e_version (20..23), e_shoff (40..47), e_flags and e_ehsize when they are not
program header fields (48..53), p_paddr. Rosetta (the x86_64 tests on a Mac) rejects
other values in e_ident[4..6] and anything but zero in e_ident[8..15], so x86_64 has no
e_ident hole. For aarch64, which only a Linux kernel loads, e_ident[4..15] is a hole:
load_elf_binary checks the 4-byte magic and e_machine, not the class, data, version or
padding bytes.
"""
import os
import struct
import sys

PT_LOAD, PT_DYNAMIC, PT_INTERP, PT_TLS = 1, 2, 3, 7
SHT_NOBITS, SHF_ALLOC = 8, 2
EM_AARCH64 = 183
ET_EXEC = 2
PAGE = 0x10000  # 64 KB: a valid page boundary for 4, 16 and 64 KB pages

LAYOUTS = {"std": (64, 120), "o56": (56, 112), "o48": (48, 104),
           "o56a": (56, 104), "o48a": (48, 96)}


def die(msg):
    sys.exit("elfgolf: " + msg)


def holes(phoff, machine):
    """Header bytes nobody reads: (offset, size)."""
    h = [(4, 12)] if machine == EM_AARCH64 else []  # e_ident[4..15]
    h.append((20, 4))  # e_version
    h.append((40, 14) if phoff >= 56 else (40, 8))  # e_shoff (+ e_flags, e_ehsize)
    if phoff == 64:
        h.append((58, 6))  # e_shentsize, e_shnum, e_shstrndx
    h.append((phoff + 24, 8))  # p_paddr
    return h


def read_input(path):
    b = open(path, "rb").read()
    if len(b) < 64 or b[:4] != b"\x7fELF" or b[4] != 2 or b[5] != 1:
        die("not a little-endian ELF64 file")
    (e_type, e_machine, _, e_entry, e_phoff, e_shoff, _, _, e_phentsize, e_phnum,
     e_shentsize, e_shnum) = struct.unpack_from("<HHIQQQIHHHHH", b, 16)
    if e_type != ET_EXEC:
        die("not a static ET_EXEC executable")
    if e_phentsize != 56 or e_phoff + 56 * e_phnum > len(b):
        die("bad program header table")
    loads = []
    for i in range(e_phnum):
        p = struct.unpack_from("<IIQQQQQQ", b, e_phoff + 56 * i)
        if p[0] in (PT_INTERP, PT_DYNAMIC, PT_TLS):
            die("dynamic and TLS executables are not supported")
        if p[0] == PT_LOAD:
            loads.append(p)
    if len(loads) != 1:
        die("need exactly one PT_LOAD, found %d" % len(loads))
    _, flags, off, vaddr, _, filesz, memsz, _ = loads[0]
    if off + filesz > len(b) or filesz > memsz:
        die("bad PT_LOAD")
    if not vaddr <= e_entry < vaddr + memsz:
        die("entry point outside the segment")
    data = b[off:off + filesz]
    if e_shoff and e_shnum:  # the program is what the allocated sections cover
        if e_shentsize != 64 or e_shoff + 64 * e_shnum > len(b):
            die("bad section header table")
        prog = bytearray(len(data))
        for i in range(e_shnum):
            _, sh_type, sh_flags, addr, _, size = struct.unpack_from("<IIQQQQ", b, e_shoff + 64 * i)
            if sh_flags & SHF_ALLOC and sh_type != SHT_NOBITS and size:
                lo = addr - vaddr
                if lo < 0 or lo + size > len(data):
                    die("section at %#x outside the segment's file contents" % addr)
                prog[lo:lo + size] = b"\1" * size
    else:
        prog = bytearray(int(x != 0) for x in data)
    return e_machine, e_entry, flags, vaddr, data, memsz, prog


def golf(layout, machine, entry, flags, vaddr, data, memsz, prog):
    phoff, hsize = LAYOUTS[layout]
    k = vaddr % PAGE  # the segment grows down to its 64 KB page, where the headers go
    base, memsz = vaddr - k, memsz + k
    data, prog = bytes(k) + data, bytes(k) + prog
    data = bytearray(bytes(x if p else 0 for x, p in zip(data, prog)).rstrip(b"\0"))
    end = phoff + 56  # the program header must be in the file, even over p_align
    data += bytes(max(0, end - len(data)))
    prog = bytes(prog) + bytes(max(0, len(data) - len(prog)))
    hdr = bytearray(end)
    struct.pack_into("<4sBBB", hdr, 0, b"\x7fELF", 2, 1, 1)
    struct.pack_into("<HHI", hdr, 16, ET_EXEC, machine, 1)  # e_version = EV_CURRENT
    struct.pack_into("<QQ", hdr, 24, entry, phoff)
    p_off, p_flags = 0, flags
    if phoff >= 56:
        struct.pack_into("<H", hdr, 54, 56)  # e_phentsize
    if phoff == 64:
        struct.pack_into("<H", hdr, 56, 1)  # e_phnum
    if phoff == 48:  # e_ehsize is the low half of p_flags, e_phnum the low byte of p_offset
        p_off, p_flags = 1, flags | 56 << 16
    struct.pack_into("<IIQQ", hdr, phoff, PT_LOAD, p_flags, p_off, base + p_off)
    struct.pack_into("<QQ", hdr, phoff + 32, len(data) - p_off, memsz - p_off)
    struct.pack_into("<Q", hdr, phoff + 48, PAGE)  # p_align, overwritten by an "a" layout
    assert struct.unpack_from("<HH", hdr, 54) == (56, 1)  # e_phentsize, e_phnum
    free = set(i for o, n in holes(phoff, machine) for i in range(o, o + n))
    free.update(range(hsize, end))  # an "a" layout: code over p_align
    for i in range(end):
        if not prog[i]:
            data[i] = hdr[i]
        elif i not in free:
            die("the program has a byte at offset %d, over a header field" % i)
    return bytes(data)


def main():
    args = sys.argv[1:]
    layout = "o48a"
    if len(args) >= 2 and args[0] == "-l":
        layout, args = args[1], args[2:]
    if layout not in LAYOUTS:
        die("unknown layout %s" % layout)
    if args == ["-H"]:
        print(LAYOUTS[layout][1])
        return
    if args[:1] == ["-h"] and args[1:] in ([], ["aarch64"]):
        machine = EM_AARCH64 if args[1:] else 0
        print(" ".join("%d:%d" % h for h in holes(LAYOUTS[layout][0], machine)))
        return
    if len(args) != 2:
        die("usage: elfgolf.py [-l LAYOUT] in out | -H | -h [aarch64]")
    out = golf(layout, *read_input(args[0]))
    with open(args[1], "wb") as f:
        f.write(out)
    os.chmod(args[1], 0o755)


if __name__ == "__main__":
    main()
