#!/usr/bin/env python3
"""Fold an arm64 Mach-O executable that needs nothing from __LINKEDIT into a
single 16 KB page.

A program with no imports, no rebases and no relocations (for example one
that reaches the kernel with svc and never calls into a dylib) needs nothing
from __LINKEDIT to run except its code signature. This tool:

  - drops the load commands that only describe __LINKEDIT data such an image
    does not use at run time (symbol table, dynamic symbol table, dyld info,
    function starts, data in code, exports trie, chained fixups header),
  - removes the __LINKEDIT segment,
  - places a fresh ad-hoc signature in the free tail of the first page, so
    the whole file is one page.

The symbols are gone afterwards, so a program that looks itself up at run
time (dlsym on its own image, symbolicated backtraces) would lose that.

It refuses (exits non-zero) unless all of these hold, so it never drops
anything the loader needs to run the program:
  - a thin arm64 MH_EXECUTE with only known load commands;
  - no rebases, binds, weak or lazy binds (dyld info), no chained imports or
    chained fixup starts, no external or local relocations, no undefined
    symbols;
  - no segment other than the header segment and __LINKEDIT has file
    content (zero-fill segments are fine);
  - every section of the header segment ends inside the first page, and the
    signature fits after them.
It holds no bytes of any program.

Usage: machofold.py <in> <out>
"""
import os
import struct
import sys

from macho import (PAGE, LC_SEGMENT_64, LC_DYSYMTAB, LC_DYLD_INFO,
                   LC_DYLD_INFO_ONLY, LC_CODE_SIGNATURE, LC_DYLD_CHAINED_FIXUPS,
                   OFFSET_FIELDS, adhoc_sign, is_zerofill, parse, write_out)

DYLD_CHAINED_PTR_START_NONE = 0xFFFF


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


def check_no_fixups(d, cmds):
    for c, _, o in cmds:
        if c in (LC_DYLD_INFO, LC_DYLD_INFO_ONLY):
            # rebase_size, bind_size, weak_bind_size, lazy_bind_size
            if any(struct.unpack_from("<I", d, o + f)[0] for f in (12, 20, 28, 36)):
                raise SystemExit("image has dyld rebases or binds; not foldable")
        elif c == LC_DYLD_CHAINED_FIXUPS:
            check_chained(d, *struct.unpack_from("<II", d, o + 8))
        elif c == LC_DYSYMTAB:
            # nundefsym, nextrel, nlocrel
            if any(struct.unpack_from("<I", d, o + f)[0] for f in (28, 68, 76)):
                raise SystemExit("image has undefined symbols or relocations; not foldable")


def fold(infile, outfile):
    d = bytearray(open(infile, "rb").read())
    cmds, segs = parse(d)
    sizeofcmds = struct.unpack_from("<I", d, 20)[0]
    check_no_fixups(d, cmds)

    hdr = None
    for s in segs:
        if s.name == b"__LINKEDIT":
            continue
        if s.fileoff == 0 and s.filesize:
            hdr = s
        elif s.filesize:
            raise SystemExit("segment %s has file content; not foldable" % s.name.decode())
    if hdr is None:
        raise SystemExit("no segment at file offset 0")
    content_end = 32 + sizeofcmds
    for _, foff, size, flags in hdr.sections(d):
        if not is_zerofill(flags):
            content_end = max(content_end, foff + size)
    if content_end > PAGE:
        raise SystemExit("header segment content ends past the first page; not foldable")

    # New load commands: everything but the __LINKEDIT segment and the
    # commands that point into it, plus a fresh LC_CODE_SIGNATURE. They are
    # never larger than the old ones, so the sections keep their offsets.
    blk = bytearray()
    ncmds = 0
    for c, size, o in cmds:
        if c in OFFSET_FIELDS:
            continue
        if c == LC_SEGMENT_64:
            if bytes(d[o + 8:o + 24]).rstrip(b"\0") == b"__LINKEDIT":
                continue
            vmaddr, vmsize, fileoff, filesize = struct.unpack_from("<QQQQ", d, o + 24)
            if o == hdr.off:
                vmsize, filesize = max(vmsize, PAGE), PAGE
            elif not filesize:
                fileoff = 0  # zero-fill only: point it at offset 0 like __PAGEZERO
            seg = bytearray(d[o:o + size])
            struct.pack_into("<QQQQ", seg, 24, vmaddr, vmsize, fileoff, filesize)
            blk += seg
        else:
            blk += d[o:o + size]
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
    write_out(outfile, page)
    return len(page)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: machofold.py <in> <out>")
    print(fold(sys.argv[1], sys.argv[2]))
