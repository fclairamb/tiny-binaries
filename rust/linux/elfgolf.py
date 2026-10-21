#!/usr/bin/env python3
"""Generic ELF64 header golf: overlap the program header table into the tail of
the ELF header.

Works on any 64-bit ELF executable that has exactly one program header, that
program header at the standard offset 64, and no section headers (run sstrip
first). It contains no bytes of any particular program; it only moves and
rewrites header fields.

The trick: the kernel reads e_phnum (2 bytes at file offset 56) and e_phentsize
(2 bytes at 54) from the ELF header, then reads the program headers at e_phoff.
If we set e_phoff = 56, the first program header starts exactly on e_phnum, and
its first field p_type = PT_LOAD = 1 is the little-endian bytes 01 00 .. -- which
is also the value e_phnum must hold for a single-segment file. e_phentsize stays
in the header at 54, untouched. So the 8 bytes that were e_phnum / e_shentsize /
e_shnum / e_shstrndx (all ignored by the loader, zero after sstrip) are reused as
the start of the program header, and the whole load image shifts up by 8 bytes.

Because the one PT_LOAD maps from p_offset 0 at a fixed p_vaddr, shrinking the
headers by 8 moves every byte of code and data 8 lower in both file offset and
virtual address by the same amount; all PC-relative code stays correct and only
e_entry, p_filesz and p_memsz change. Binaries with absolute self-references
would need those relocated, so this tool refuses anything with more than the one
segment or with a nonzero p_offset.

Usage: elfgolf.py <in> <out>
"""
import struct
import sys

PT_LOAD = 1


def golf(data: bytes) -> bytes:
    if data[:4] != b"\x7fELF" or data[4] != 2:
        raise SystemExit("not a 64-bit ELF")
    little = data[5] == 1
    en = "<" if little else ">"
    (e_entry,) = struct.unpack_from(en + "Q", data, 24)
    (e_phoff,) = struct.unpack_from(en + "Q", data, 32)
    (e_phentsize,) = struct.unpack_from(en + "H", data, 54)
    (e_phnum,) = struct.unpack_from(en + "H", data, 56)
    if e_phnum != 1:
        raise SystemExit("need exactly one program header, got %d" % e_phnum)
    if e_phentsize != 56:
        raise SystemExit("unexpected e_phentsize %d" % e_phentsize)
    if e_phoff != 64:
        raise SystemExit("program headers not at offset 64 (got %d)" % e_phoff)
    # The single program header.
    ph = data[64 : 64 + 56]
    p_type, p_flags, p_offset = struct.unpack_from(en + "IIQ", ph, 0)
    if p_type != PT_LOAD:
        raise SystemExit("the one segment is not PT_LOAD")
    if p_offset != 0:
        raise SystemExit("segment p_offset is not 0; cannot shift safely")

    new_phoff = 56
    shift = 64 - new_phoff  # 8
    body = data[64 + 56 :]  # everything after the original phdr

    out = bytearray()
    out += data[:new_phoff]  # ehdr bytes 0..56 (keeps e_phentsize at 54)
    out += ph  # phdr lands on 56..112, overlapping the 8 freed header bytes
    out += body  # code and data, now 8 bytes lower

    # Fix up the fields the shift changed.
    struct.pack_into(en + "Q", out, 32, new_phoff)  # e_phoff
    struct.pack_into(en + "Q", out, 24, e_entry - shift)  # e_entry
    # p_filesz / p_memsz shrink by the 8 reclaimed header bytes.
    pfz, pmz = struct.unpack_from(en + "QQ", out, new_phoff + 32)
    struct.pack_into(en + "QQ", out, new_phoff + 32, pfz - shift, pmz - shift)
    # Sanity: p_type still reads as PT_LOAD, and e_phnum reads as 1.
    (chk_type,) = struct.unpack_from(en + "I", out, new_phoff)
    (chk_phnum,) = struct.unpack_from(en + "H", out, 56)
    assert chk_type == PT_LOAD and chk_phnum == 1
    return bytes(out)


def main():
    if len(sys.argv) != 3:
        raise SystemExit("usage: elfgolf.py <in> <out>")
    with open(sys.argv[1], "rb") as f:
        data = f.read()
    out = golf(data)
    with open(sys.argv[2], "wb") as f:
        f.write(out)


if __name__ == "__main__":
    main()
