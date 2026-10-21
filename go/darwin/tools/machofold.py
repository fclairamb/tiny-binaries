#!/usr/bin/env python3
"""Fold an arm64 Mach-O executable into its first 16 KB page, plus a few bytes
of bind opcodes when it imports symbols.

Usage: machofold.py <in> <out>

At run time such an image needs from __LINKEDIT only its code signature and,
if it imports anything, the dyld bind opcodes. This tool:

  - keeps the header segment (__TEXT) byte for byte, as one page;
  - turns every other segment into zero-fill (file offset 0, no file bytes,
    section offsets 0), which only works because their file content is all
    zeros;
  - drops the load commands that describe __LINKEDIT data dyld does not need
    to start the program: symbol tables, export trie, function starts, data
    in code, the (empty) chained fixups header;
  - keeps a __LINKEDIT segment only for the bind opcodes, right after the
    first page, trimmed after the last real opcode and without the
    set-type opcodes when every bind is a pointer bind (see trim_binds);
  - writes a fresh ad-hoc signature into the free tail of the first page.
    It covers that page up to the signature, not the bind opcodes.

The symbols and the export trie are gone afterwards, so a program that looks
itself up at run time (dlsym on its own image, symbolicated backtraces) would
lose that.

It refuses (exits non-zero) unless all of these hold, so it never drops
anything the loader needs to run the program:
  - a thin arm64 MH_EXECUTE with only known load commands, and no weak
    definitions or weak binds (dyld finds weak symbols through the export
    trie);
  - no rebases, lazy or weak binds, no chained imports or fixup starts, no
    external or local relocations, and no undefined symbols unless there are
    bind opcodes;
  - every segment other than the header segment and __LINKEDIT has only zero
    bytes in the file (a classic bind writes its whole slot, so a slot that
    starts out zero-filled ends up the same);
  - every section of the header segment ends inside the first page, and the
    signature fits after them.
It holds no bytes of any program: it reads sizes and offsets out of the file.
"""
import os
import struct
import sys

from macho import (PAGE, LC_SEGMENT_64, LC_DYSYMTAB, LC_DYLD_INFO,
                   LC_DYLD_INFO_ONLY, LC_CODE_SIGNATURE, LC_DYLD_CHAINED_FIXUPS,
                   OFFSET_FIELDS, adhoc_sign, is_zerofill, parse, write_out)

DYLD_CHAINED_PTR_START_NONE = 0xFFFF
MH_WEAK_DEFINES, MH_BINDS_TO_WEAK = 0x8000, 0x10000


def check_chained(d, off, size):
    """Refuse if a chained-fixups blob has any import or any fixup start."""
    if size < 28:
        raise SystemExit("chained fixups header truncated")
    starts_off = struct.unpack_from("<I", d, off + 4)[0]
    imports_count = struct.unpack_from("<I", d, off + 16)[0]
    if imports_count:
        raise SystemExit("image has chained imports; not foldable")
    if not starts_off:
        return
    s = off + starts_off  # dyld_chained_starts_in_image
    for i in range(struct.unpack_from("<I", d, s)[0]):
        so = struct.unpack_from("<I", d, s + 4 + 4 * i)[0]
        if not so:
            continue
        seg = s + so  # dyld_chained_starts_in_segment
        for p in range(struct.unpack_from("<H", d, seg + 20)[0]):
            if struct.unpack_from("<H", d, seg + 22 + 2 * p)[0] != DYLD_CHAINED_PTR_START_NONE:
                raise SystemExit("image has chained fixups; not foldable")


def skip_uleb(b, i):
    while b[i] & 0x80:
        i += 1
    return i + 1


def trim_binds(b):
    """Shortest (non-lazy) bind opcode stream dyld reads the same way as b.

    - Everything from the first DONE opcode on is dropped: dyld stops at the
      end of the stream as well as at DONE, so DONE and the padding after it
      are not needed.
    - SET_TYPE_IMM(POINTER) is dropped when the stream sets no other type:
      dyld 4 binds a pointer whatever the type is (undocumented; observed on
      macOS 27.0.1).
    """
    ops = []  # (start, end) of each opcode with its operands
    i = 0
    while i < len(b) and b[i] & 0xF0:  # high nibble 0 is BIND_OPCODE_DONE
        start, op = i, b[i] & 0xF0
        i += 1
        if op in (0x20, 0x60, 0x70, 0x80, 0xA0):  # one ULEB/SLEB operand
            i = skip_uleb(b, i)
        elif op == 0x40:  # symbol name, NUL-terminated
            i = b.index(0, i) + 1
        elif op == 0xC0:  # count and skip
            i = skip_uleb(b, skip_uleb(b, i))
        elif op == 0xD0 and b[i - 1] & 0x0F == 0:  # threaded: table size
            i = skip_uleb(b, i)
        elif op not in (0x10, 0x30, 0x50, 0x90, 0xB0, 0xD0):
            raise SystemExit("unknown bind opcode 0x%x" % b[i - 1])
        ops.append((start, i))
    if i > len(b):
        raise SystemExit("bind opcodes truncated")
    types = {b[s] for s, _ in ops if b[s] & 0xF0 == 0x50}  # SET_TYPE_IMM
    if types == {0x51}:  # BIND_TYPE_POINTER only
        return b"".join(b[s:e] for s, e in ops if b[s] != 0x51)
    return b[:i]


def check_fixups(d, cmds):
    """Refuse what the fold cannot keep; return the bind opcodes to keep."""
    if struct.unpack_from("<I", d, 24)[0] & (MH_WEAK_DEFINES | MH_BINDS_TO_WEAK):
        raise SystemExit("image has weak symbols; not foldable")
    binds = b""
    undef = False
    for c, _, o in cmds:
        if c in (LC_DYLD_INFO, LC_DYLD_INFO_ONLY):
            (rebase_off, rebase_size, bind_off, bind_size, weak_off, weak_size,
             lazy_off, lazy_size) = struct.unpack_from("<8I", d, o + 8)
            if rebase_size or weak_size or lazy_size:
                raise SystemExit("image has rebases, weak or lazy binds; not foldable")
            stream = bytes(d[bind_off:bind_off + bind_size])
            binds = trim_binds(stream)
        elif c == LC_DYLD_CHAINED_FIXUPS:
            check_chained(d, *struct.unpack_from("<II", d, o + 8))
        elif c == LC_DYSYMTAB:
            nundefsym, nextrel, nlocrel = (struct.unpack_from("<I", d, o + f)[0] for f in (28, 68, 76))
            if nextrel or nlocrel:
                raise SystemExit("image has relocations; not foldable")
            undef = nundefsym > 0
    if undef and not binds:
        raise SystemExit("image has undefined symbols but no binds; not foldable")
    return binds


def fold(infile, outfile):
    d = bytearray(open(infile, "rb").read())
    cmds, segs = parse(d)
    sizeofcmds = struct.unpack_from("<I", d, 20)[0]
    binds = check_fixups(d, cmds)

    hdr = None
    for s in segs:
        if s.name == b"__LINKEDIT":
            continue
        if s.fileoff == 0 and s.filesize:
            hdr = s
        elif any(d[s.fileoff:s.fileoff + s.filesize]):
            raise SystemExit("segment %s has file content; not foldable" % s.name.decode())
    if hdr is None:
        raise SystemExit("no segment at file offset 0")
    content_end = 32 + sizeofcmds
    for _, foff, size, flags in hdr.sections(d):
        if not is_zerofill(flags):
            content_end = max(content_end, foff + size)
    if content_end > PAGE:
        raise SystemExit("header segment content ends past the first page; not foldable")

    # New load commands: the segments (every one but the header segment
    # without file bytes, __LINKEDIT only if there are binds), dyld info only
    # if there are binds, no other command that points into __LINKEDIT, and a
    # fresh LC_CODE_SIGNATURE. They are never larger than the old ones, so the
    # sections keep their offsets.
    blk = bytearray()
    ncmds = 0
    for c, size, o in cmds:
        cmd = bytearray(d[o:o + size])
        if c == LC_SEGMENT_64:
            name = bytes(cmd[8:24]).rstrip(b"\0")
            vmaddr, vmsize, fileoff, filesize = struct.unpack_from("<QQQQ", cmd, 24)
            if name == b"__LINKEDIT":
                if not binds:
                    continue
                fileoff, filesize = PAGE, len(binds)
            elif o == hdr.off:
                vmsize, filesize = max(vmsize, PAGE), PAGE
            else:
                fileoff, filesize = 0, 0  # zero-fill, like __PAGEZERO
                for i in range(struct.unpack_from("<I", cmd, 64)[0]):
                    struct.pack_into("<I", cmd, 72 + 80 * i + 48, 0)  # no file bytes, like ld's __bss
            struct.pack_into("<QQQQ", cmd, 24, vmaddr, vmsize, fileoff, filesize)
        elif c in (LC_DYLD_INFO, LC_DYLD_INFO_ONLY) and binds:
            cmd[8:48] = struct.pack("<10I", 0, 0, PAGE, len(binds), 0, 0, 0, 0, 0, 0)
        elif c in OFFSET_FIELDS:
            continue
        blk += cmd
        ncmds += 1
    cs_at = 32 + len(blk)
    blk += struct.pack("<IIII", LC_CODE_SIGNATURE, 16, 0, 0)
    ncmds += 1

    page = bytearray(bytes(d[:PAGE]).ljust(PAGE, b"\0"))
    page[32:32 + sizeofcmds] = bytes(sizeofcmds)  # wipe the old commands
    page[32:32 + len(blk)] = blk
    struct.pack_into("<II", page, 16, ncmds, len(blk))
    page[content_end:] = bytes(PAGE - content_end)  # only zeros after the content

    ident = os.path.basename(outfile)
    sig_len = len(adhoc_sign(bytes(content_end), ident, PAGE))
    if content_end + sig_len > PAGE:
        raise SystemExit("signature does not fit in the first page (%d bytes free)" % (PAGE - content_end))
    struct.pack_into("<II", page, cs_at + 8, content_end, sig_len)
    page[content_end:content_end + sig_len] = adhoc_sign(bytes(page[:content_end]), ident, PAGE)
    write_out(outfile, page + binds)
    return PAGE + len(binds)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: machofold.py <in> <out>")
    print(fold(sys.argv[1], sys.argv[2]))
