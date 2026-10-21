#!/usr/bin/env python3
"""Generic Mach-O compactor and ad-hoc (re)signer for arm64 executables.

It repacks a dynamically linked arm64 Mach-O so every segment after the
header segment takes the least file space the loader allows, then writes a
fresh ad-hoc code signature:

- The header segment (the one at file offset 0, normally __TEXT) is kept
  byte for byte, at its full linked size.
- Every other segment except __LINKEDIT loses its trailing zero bytes: the
  kernel zero-fills a segment's vm range past its file size, so those bytes
  come back at run time. A segment that is all zeros keeps no file bytes.
  Section file offsets are moved with their segment.
- Segment file offsets stay 16 KB aligned (the kernel maps file pages to vm
  pages), so the segments are laid back to back on page boundaries, in their
  original order.
- __LINKEDIT (symbol table, dyld info, function starts, signature) is data
  referenced by load commands through file offsets, so when it moves every
  such offset is shifted by the same delta.

It refuses (exits non-zero) on anything it does not understand: a fat or
non-arm64 file, an unknown load command, a layout where __LINKEDIT is not the
last segment in the file, or a __LINKEDIT reference that points outside it.
It contains no bytes of any program: it reads sizes and offsets out of the
file it is given and rewrites them.

Usage: machopack.py [-i identifier] <in> <out>
The signature identifier defaults to the output file name.
"""
import os
import struct
import sys

from macho import (PAGE, LC_CODE_SIGNATURE, OFFSET_FIELDS, adhoc_sign,
                   is_zerofill, parse, write_out)


def pack(infile, outfile, ident):
    d = bytearray(open(infile, "rb").read())
    cmds, segs = parse(d)

    filed = sorted((s for s in segs if s.filesize), key=lambda s: s.fileoff)
    if not filed or filed[0].fileoff != 0:
        raise SystemExit("no segment at file offset 0")
    hdr, le = filed[0], filed[-1]
    if le.name != b"__LINKEDIT" or len(filed) < 2:
        raise SystemExit("__LINKEDIT is not the last segment in the file")
    if hdr.filesize % PAGE:
        raise SystemExit("header segment size is not page aligned")

    sig = [o for c, _, o in cmds if c == LC_CODE_SIGNATURE]
    if len(sig) != 1:
        raise SystemExit("need exactly one LC_CODE_SIGNATURE (ld always writes one on arm64)")
    sig_lc = sig[0]
    old_sig = struct.unpack_from("<I", d, sig_lc + 8)[0]
    le_end = le.fileoff + le.filesize
    if not le.fileoff <= old_sig <= le_end:
        raise SystemExit("code signature is not in __LINKEDIT")

    # Every other __LINKEDIT reference must start inside __LINKEDIT, before
    # the old signature (which is dropped: we re-sign).
    refs = []
    for c, _, o in cmds:
        if c == LC_CODE_SIGNATURE:
            continue
        for fo in OFFSET_FIELDS.get(c, ()):
            v = struct.unpack_from("<I", d, o + fo)[0]
            if v:
                if not le.fileoff <= v < old_sig:
                    raise SystemExit("load command 0x%x points outside __LINKEDIT" % c)
                refs.append((o + fo, v))

    out = bytearray(d[:hdr.filesize])
    cur = hdr.filesize
    for s in filed[1:-1]:
        content = bytes(d[s.fileoff:s.fileoff + s.filesize]).rstrip(b"\0")
        delta = cur - s.fileoff
        for sh, foff, size, flags in s.sections(d):
            if foff and not is_zerofill(flags):
                struct.pack_into("<I", out, sh + 48, foff + delta)
        s.fileoff, s.filesize = (cur, len(content)) if content else (0, 0)
        if content:
            out += b"\0" * (cur - len(out)) + content
            cur += (len(content) + PAGE - 1) // PAGE * PAGE
    out += b"\0" * (cur - len(out))
    le_delta = cur - le.fileoff
    out += d[le.fileoff:old_sig]
    for at, v in refs:
        struct.pack_into("<I", out, at, v + le_delta)
    le.fileoff = cur

    # The signature covers everything before it, header included, so set its
    # offset and size (the size depends only on the page count) first.
    sig_off = len(out)
    sig_len = len(adhoc_sign(bytes(sig_off), ident, hdr.filesize))
    struct.pack_into("<II", out, sig_lc + 8, sig_off, sig_len)
    le.filesize = sig_off + sig_len - le.fileoff
    for s in segs:
        s.write(out)
    out += adhoc_sign(bytes(out), ident, hdr.filesize)
    write_out(outfile, out)
    return len(out)


def main():
    args = sys.argv[1:]
    ident = None
    if len(args) == 4 and args[0] == "-i":
        ident, args = args[1], args[2:]
    if len(args) != 2:
        raise SystemExit("usage: machopack.py [-i identifier] <in> <out>")
    print(pack(args[0], args[1], ident or os.path.basename(args[1])))


if __name__ == "__main__":
    main()
