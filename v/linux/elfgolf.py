#!/usr/bin/env python3
"""Rewrite a static ELF64 executable into one PT_LOAD with a minimal header layout.

Usage: elfgolf.py [-l LAYOUT] in out          write the golfed binary
       elfgolf.py [-l LAYOUT] -H              print the header size of the layout
       elfgolf.py [-l LAYOUT] -h [aarch64]    print the holes of the layout (offset:size)

Generic: it reads the PT_LOAD segments, the entry point, the machine and the section
headers of the input, writes a new ELF header and one program header, and drops the
section headers and every other program header. It contains no bytes of the program.

1. The PT_LOAD segments become one read+write+execute segment, from the start of the first
   to the end of the last, with zeros in the gaps. Every byte keeps its virtual address, so
   nothing is relocated.
2. That segment starts in the 64 KB page of the program's first byte (what comes before,
   such as an input's own headers linked far below its code, goes), and the headers are
   written over the first H bytes of that page (H, the header size of the layout, -H). The
   program is the contents of the allocated sections; the input's own headers and the
   padding between sections are not, and become zeros or header bytes. A program byte may sit in a header
   hole (a field Linux and Rosetta ignore, -h), so a linker script can put small sections
   there; elfgolf stops if a section covers any other header field. Without section
   headers, the nonzero bytes outside the input's own headers count as the program.
3. Trailing zero bytes become bss (memsz > filesz).
p_offset is 0 (or 1) and p_vaddr the page (or the page + 1), which any page size accepts.
A program linked with its first section H bytes or more into a 64 KB page (an ordinary
static link starts at 0x400000 with its own headers) needs nothing else.

Layouts (H, bytes of header before the code):
  std   120  ELF header, then the program header.
  o56   112  program header at offset 56: p_type is e_phnum/e_shentsize (1, 0),
             p_flags is e_shnum/e_shstrndx.
  o48   104  program header at offset 48: p_type is e_flags (1), p_flags is
             e_ehsize/e_phentsize, p_offset is e_phnum.. (1), so p_vaddr = page + 1.
  A suffix "a" (o56a 104, o48a 96) lets the code start 8 bytes earlier, over p_align,
  which Linux ignores for ET_EXEC.
Holes: e_version (20..23), e_shoff (40..47), e_flags and e_ehsize when they are not
program header fields (48..53), p_paddr. Rosetta (which runs the x86_64 tests on a Mac)
rejects other values in e_ident[4..6] and anything but zero in e_ident[8..15], so for
x86_64 e_ident has no holes (EI_OSABI alone is free, one byte). For aarch64, which only a
Linux kernel loads, e_ident[4..15] is a hole too: load_elf_binary checks the 4-byte magic
and e_machine, never the class, data, version or padding bytes.
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
    """The loadable image of the input, and which of its bytes are the program."""
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
        if p[0] == PT_LOAD and p[6]:
            loads.append(p)
    if not loads:
        die("no PT_LOAD")
    loads.sort(key=lambda p: p[3])
    start = end = loads[0][3]
    image, flags = bytearray(), 0
    headers = bytearray()  # 1 for the bytes that map the input's own ELF and program headers
    hend = max(64, e_phoff + 56 * e_phnum)
    for _, f, off, vaddr, _, filesz, memsz, _ in loads:
        if filesz > memsz or filesz and off + filesz > len(b):
            die("bad PT_LOAD")
        if vaddr < end:
            die("PT_LOAD segments overlap")
        pad = vaddr - start - len(image)
        image += bytes(pad) + b[off:off + filesz]
        headers += bytes(pad) + bytes(int(off + i < hend) for i in range(filesz))
        flags, end = flags | f, vaddr + memsz
    if e_shoff and e_shnum:
        if e_shentsize != 64 or e_shoff + 64 * e_shnum > len(b):
            die("bad section header table")
        prog = bytearray(len(image))
        for i in range(e_shnum):
            _, sh_type, sh_flags, addr, _, size = struct.unpack_from("<IIQQQQ", b, e_shoff + 64 * i)
            if sh_flags & SHF_ALLOC and sh_type != SHT_NOBITS and size:
                lo = addr - start
                if lo < 0 or lo + size > len(image):
                    die("section at %#x outside the segments' file contents" % addr)
                prog[lo:lo + size] = b"\1" * size
    else:
        prog = bytearray(int(x != 0 and not h) for x, h in zip(image, headers))
    # the segment starts in the 64 KB page of the program's first byte: what comes before
    # goes (an input linked with its own headers far below its code)
    skip = max(0, (start + prog.find(1)) // PAGE * PAGE - start) if 1 in prog else 0
    del image[:skip], prog[:skip]
    start += skip
    if not start <= e_entry < end:
        die("entry point outside the segments")
    return e_machine, e_entry, flags, start, image, end - start, prog


def golf(layout, machine, entry, flags, start, image, memsz, prog):
    phoff, hsize = LAYOUTS[layout]
    k = start % PAGE
    base, memsz = start - k, memsz + k
    data = bytearray(x if p else 0 for x, p in zip(bytes(k) + image, bytes(k) + prog))
    data = data.rstrip(b"\0")  # trailing zeros become bss
    end = phoff + 56  # the program header must be in the file, even over p_align
    data += bytes(max(0, end - len(data)))
    prog = bytes(k) + prog + bytes(max(0, len(data) - k - len(prog)))
    hdr = bytearray(end)
    struct.pack_into("<4sBBB", hdr, 0, b"\x7fELF", 2, 1, 1)
    struct.pack_into("<HHI", hdr, 16, ET_EXEC, machine, 1)  # e_version 1 when it is free
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
    struct.pack_into("<Q", hdr, phoff + 48, PAGE)  # p_align: code may start over it ("a")
    assert struct.unpack_from("<HH", hdr, 54) == (56, 1)  # e_phentsize, e_phnum
    free = set(i for o, n in holes(phoff, machine) for i in range(o, o + n))
    free.update(range(hsize, end))
    for i in range(end):
        if not prog[i]:
            data[i] = hdr[i]
        elif i not in free:
            die("the program has a byte at %#x, over a header field: link it at least %d bytes"
                " into its 64 KB page, or put only small sections in the holes (-h)" % (base + i, hsize))
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
