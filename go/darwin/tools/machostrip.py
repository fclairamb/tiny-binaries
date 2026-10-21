#!/usr/bin/env python3
"""Rebuild an arm64 Mach-O executable's __LINKEDIT with only what dyld needs,
and re-sign it ad hoc.

Usage: machostrip.py <in> <out>

The post-link step of the optimized and tinygo variants, a deeper `strip`:

  - every segment but __LINKEDIT keeps its bytes, offsets and addresses;
  - __LINKEDIT keeps only the fixups, copied verbatim: the chained fixups
    blob, or the rebase, bind, weak bind and lazy bind opcode streams (a lazy
    stub finds its opcodes by offset into the lazy stream, which a verbatim
    copy keeps);
  - the symbol table, indirect symbol table, string table, export trie,
    function starts, data in code and the other tool-only tables are dropped.
    LC_SYMTAB and LC_DYSYMTAB stay with no entries, so `codesign --verify
    --strict` still accepts the file;
  - a new ad-hoc signature follows: SHA-256 truncated to 20 bytes, 16 KB
    pages, an empty identifier and no requirements blob.

Nothing can look symbols up in the result (dlsym on the main image,
symbolicated crash logs). It refuses an image it cannot handle safely: an
unknown load command, no code signature, __LINKEDIT not the last segment or
not page aligned, weak symbols (dyld coalesces them through the export trie),
classic relocations, or undefined symbols with no fixups to bind them.
It holds no bytes of any program: it reads sizes and offsets out of the file.
"""
import struct
import sys

from macho import (PAGE, LC_SEGMENT_64, LC_SYMTAB, LC_DYSYMTAB, LC_DYLD_INFO,
                   LC_DYLD_INFO_ONLY, LC_CODE_SIGNATURE, LC_DYLD_CHAINED_FIXUPS,
                   LINKEDIT_DATA, adhoc_sign, parse, write_out)

MH_WEAK_DEFINES, MH_BINDS_TO_WEAK = 0x8000, 0x10000
CD_MIN = 112  # rust/darwin measured that a shorter CodeDirectory is killed


def align(n, a):
    return (n + a - 1) // a * a


def strip(infile, outfile):
    d = bytearray(open(infile, "rb").read())
    cmds, segs = parse(d)
    sizeofcmds = struct.unpack_from("<I", d, 20)[0]
    if struct.unpack_from("<I", d, 24)[0] & (MH_WEAK_DEFINES | MH_BINDS_TO_WEAK):
        raise SystemExit("image has weak symbols; not strippable")
    le = segs[-1]
    if le.name != b"__LINKEDIT" or le.fileoff % PAGE:
        raise SystemExit("__LINKEDIT is not the last segment, page aligned")
    if any(s.fileoff + s.filesize > le.fileoff for s in segs[:-1]):
        raise SystemExit("a segment overlaps __LINKEDIT")
    hdr = next((s for s in segs if s.fileoff == 0 and s.filesize), None)
    if hdr is None:
        raise SystemExit("no segment at file offset 0")
    if not any(c == LC_CODE_SIGNATURE for c, _, _ in cmds):
        raise SystemExit("no LC_CODE_SIGNATURE to reuse")

    blobs = bytearray()  # the new __LINKEDIT content before the signature

    def keep(off, size):
        """Copy a blob into the new __LINKEDIT, 8-byte aligned; its new offset."""
        if not size:
            return 0
        blobs.extend(bytes(align(len(blobs), 8) - len(blobs)))
        at = le.fileoff + len(blobs)
        blobs.extend(d[off:off + size])
        return at

    fixups = undef = False
    blk = bytearray()
    ncmds = 0
    cs_at = le_at = None  # where the two commands land in the new list
    for c, size, o in cmds:
        cmd = bytearray(d[o:o + size])
        if o == le.off:
            le_at = len(blk)
        elif c in (LC_DYLD_INFO, LC_DYLD_INFO_ONLY):
            f = list(struct.unpack_from("<10I", cmd, 8))
            for k in range(4):  # rebase, bind, weak bind, lazy bind
                f[2 * k] = keep(f[2 * k], f[2 * k + 1])
                fixups |= f[2 * k + 1] > 0
            f[8:10] = 0, 0  # export trie
            struct.pack_into("<10I", cmd, 8, *f)
        elif c == LC_DYLD_CHAINED_FIXUPS:
            off, n = struct.unpack_from("<II", cmd, 8)
            struct.pack_into("<I", cmd, 8, keep(off, n))
            fixups = True
        elif c == LC_SYMTAB:
            cmd[8:24] = bytes(16)
        elif c == LC_DYSYMTAB:
            nundefsym, nextrel, nlocrel = (struct.unpack_from("<I", cmd, f)[0] for f in (28, 68, 76))
            if nextrel or nlocrel:
                raise SystemExit("image has classic relocations; not strippable")
            undef = nundefsym > 0
            cmd[8:80] = bytes(72)
        elif c == LC_CODE_SIGNATURE:
            cs_at = len(blk)
        elif c in LINKEDIT_DATA:
            continue  # function starts, data in code, export trie, ...
        blk += cmd
        ncmds += 1
    if undef and not fixups:
        raise SystemExit("image has undefined symbols but no fixups to bind them")

    sig_off = le.fileoff + align(len(blobs), 16)
    sig_len = len(adhoc_sign(bytes(sig_off), "", hdr.filesize, 20))
    if sig_len - 20 < CD_MIN:
        raise SystemExit("CodeDirectory would be shorter than %d bytes" % CD_MIN)
    le_size = sig_off + sig_len - le.fileoff
    struct.pack_into("<II", blk, cs_at + 8, sig_off, sig_len)
    struct.pack_into("<QQQ", blk, le_at + 32, align(le_size, PAGE), le.fileoff, le_size)

    out = bytearray(d[:le.fileoff])
    out[32:32 + sizeofcmds] = bytes(sizeofcmds)  # wipe the old commands
    out[32:32 + len(blk)] = blk
    struct.pack_into("<II", out, 16, ncmds, len(blk))
    out += blobs
    out += bytes(sig_off - len(out))
    out += adhoc_sign(bytes(out), "", hdr.filesize, 20)
    write_out(outfile, out)
    return len(out)


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: machostrip.py <in> <out>")
    print(strip(sys.argv[1], sys.argv[2]))
