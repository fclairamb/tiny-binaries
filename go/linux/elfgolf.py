#!/usr/bin/env python3
"""Rewrite a static ELF64 executable with one PT_LOAD into a minimal header layout.

Derived from v/linux/elfgolf.py (the V slice). One difference: e_version is written as
EV_CURRENT (1) when the program leaves that hole unused, so readelf shows a normal header.

Usage: elfgolf.py [-l LAYOUT] in out          write the golfed binary
       elfgolf.py [-l LAYOUT] -H              print the header size of the layout
       elfgolf.py [-l LAYOUT] -h [aarch64]    print the holes of the layout (offset:size)

Generic: it takes the segment, the entry point and the machine from the input, writes a
new ELF header and program header, and drops the section headers and every other
program header. It contains no bytes of any program. Trailing zero bytes of the segment
become bss (memsz > filesz).

The segment keeps its virtual address. Two ways to link the input:
- the segment starts H bytes into a 64 KB aligned page (H = header size, -H): the
  headers are written in front of it;
- the segment starts on a 64 KB boundary and its first H bytes are left for the headers:
  the headers are written over them. The bytes of the holes (fields Linux and Rosetta
  ignore, -h) are kept, so the linker script can put small sections there; every other
  header byte must be zero in the input.
Either way p_offset is 0 (or 1) and p_vaddr is the page (or the page + 1), which any page
size accepts.

Layouts (H, bytes of header before the code):
  std   120  ELF header, then the program header.
  o56   112  program header at offset 56: p_type is e_phnum/e_shentsize (1, 0),
             p_flags is e_shnum/e_shstrndx.
  o48   104  program header at offset 48: p_type is e_flags (1), p_flags is
             e_ehsize/e_phentsize, p_offset is e_phnum.. (1), so p_vaddr = page + 1.
  A suffix "a" (o56a 104, o48a 96) starts the segment 8 bytes earlier, over p_align,
  which Linux ignores for ET_EXEC.
Holes: e_version (20..23), e_shoff (40..47), e_flags and e_ehsize when they are not
program header fields (48..53), p_paddr. Rosetta (which runs the x86_64 tests on a Mac)
rejects anything but zero in e_ident[7..15], so for x86_64 those are not holes. For
aarch64, which only a Linux kernel loads, e_ident[4..15] is a hole too: load_elf_binary
checks the 4-byte magic and e_machine, never the class, data, version or padding bytes.
"""
import os
import struct
import sys

PT_LOAD, PT_DYNAMIC, PT_INTERP = 1, 2, 3
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
    (e_type, e_machine, _, e_entry, e_phoff, _, _, _, e_phentsize, e_phnum) = \
        struct.unpack_from("<HHIQQQIHHH", b, 16)
    if e_type != ET_EXEC:
        die("not a static ET_EXEC executable")
    if e_phentsize != 56 or e_phoff + 56 * e_phnum > len(b):
        die("bad program header table")
    loads = []
    for i in range(e_phnum):
        p = struct.unpack_from("<IIQQQQQQ", b, e_phoff + 56 * i)
        if p[0] in (PT_INTERP, PT_DYNAMIC):
            die("dynamic executables are not supported")
        if p[0] == PT_LOAD:
            loads.append(p)
    if len(loads) != 1:
        die("need exactly one PT_LOAD, found %d" % len(loads))
    _, flags, off, vaddr, _, filesz, memsz, _ = loads[0]
    if off + filesz > len(b) or filesz > memsz:
        die("bad PT_LOAD")
    if not vaddr <= e_entry < vaddr + memsz:
        die("entry point outside the segment")
    return e_machine, e_entry, flags, vaddr, b[off:off + filesz], memsz


def golf(layout, machine, entry, flags, vaddr, data, memsz):
    phoff, hsize = LAYOUTS[layout]
    if vaddr % PAGE == hsize:  # headers go in front of the segment
        base, data, memsz = vaddr - hsize, bytes(hsize) + data, memsz + hsize
    elif vaddr % PAGE == 0:  # headers go over the first hsize bytes of the segment
        base = vaddr
        if len(data) < hsize:
            data += bytes(hsize - len(data))
    else:
        die("link the segment at a 64 KB boundary, or %d bytes after one (it is at %#x)"
            % (hsize, vaddr))
    data = bytearray(data.rstrip(b"\0"))  # trailing zeros become bss
    end = phoff + 56  # the program header must be in the file, even over p_align
    data += bytes(max(0, end - len(data)))
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
    # a hole the program does not use keeps the header bytes (e_ident's class, data and
    # version), so tools still read the file
    free = set(i for o, n in holes(phoff, machine) if any(data[o:o + n])
               for i in range(o, o + n))
    for i in range(min(hsize, end)):
        if i in free:
            continue
        if data[i]:
            die("segment byte %d is not zero but the header needs it" % i)
        data[i] = hdr[i]
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
