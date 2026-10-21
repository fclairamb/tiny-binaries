#!/usr/bin/env python3
"""Fold an arm64 macOS executable into its __TEXT pages and re-sign it ad hoc.

Usage: macho_pack.py <in> <out>

A generic post-link tool: it reads offsets and sizes out of the file it is given
and contains no bytes of any program. It works on an arm64 MH_EXECUTE that uses
classic dyld info (link with -Wl,-no_fixup_chains if it has imports) and whose
segments other than __TEXT have no file content, or only zero bytes (a GOT bound
at load time, bss). It refuses anything else rather than writing a broken file:
chained fixups with content, classic relocations, an imported symbol that no bind
opcode covers, a data segment with non-zero content, an unknown load command, or
a result that does not fit in __TEXT's vmsize.

Output layout:
  * __TEXT keeps its bytes where they are (no instruction moves) and is cut to
    its last section; the load commands lose the symbol table, export trie,
    function starts, data-in-code and the old signature.
  * A fresh ad-hoc signature (a SuperBlob holding one SHA-256 CodeDirectory
    with 16 KiB pages) goes in the zero tail of the last __TEXT page. Its
    hashes cover the file up to the signature, so the page is only partly
    hashed. __TEXT is then padded to a whole page.
  * __LINKEDIT starts right after __TEXT and holds only the dyld bind and
    rebase opcodes, copied verbatim (nothing at all for an image without
    imports). They sit past the signed range.
  * Every all-zero data segment becomes zero-fill (file size 0): the kernel maps
    anonymous zero pages, which is what the file bytes said anyway.

For a small program the file is exactly one 16 KiB page, plus the opcodes when
it imports symbols. The partly hashed page and the unsigned opcodes rely on
current kernel behaviour, not on a documented format; darwin/README.md says
which rules make them work.
"""
import hashlib
import os
import struct
import sys

PAGE = 0x4000
MH_MAGIC_64 = 0xFEEDFACF
CPU_TYPE_ARM64 = 0x0100000C
MH_EXECUTE = 2

LC_REQ_DYLD = 0x80000000
LC_SYMTAB = 0x02
LC_DYSYMTAB = 0x0B
LC_LOAD_DYLIB = 0x0C
LC_LOAD_DYLINKER = 0x0E
LC_SEGMENT_64 = 0x19
LC_UUID = 0x1B
LC_CODE_SIGNATURE = 0x1D
LC_LOAD_WEAK_DYLIB = 0x18 | LC_REQ_DYLD
LC_DYLD_INFO = 0x22
LC_DYLD_INFO_ONLY = 0x22 | LC_REQ_DYLD
LC_VERSION_MIN_MACOSX = 0x24
LC_FUNCTION_STARTS = 0x26
LC_MAIN = 0x28 | LC_REQ_DYLD
LC_DATA_IN_CODE = 0x29
LC_SOURCE_VERSION = 0x2A
LC_RPATH = 0x1C | LC_REQ_DYLD
LC_BUILD_VERSION = 0x32
LC_DYLD_EXPORTS_TRIE = 0x33 | LC_REQ_DYLD
LC_DYLD_CHAINED_FIXUPS = 0x34 | LC_REQ_DYLD

KEEP = {LC_SEGMENT_64, LC_LOAD_DYLINKER, LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_UUID,
        LC_BUILD_VERSION, LC_VERSION_MIN_MACOSX, LC_SOURCE_VERSION, LC_MAIN, LC_RPATH,
        LC_DYLD_INFO, LC_DYLD_INFO_ONLY, LC_CODE_SIGNATURE}
# Tables only tools read for a main executable (nothing can dlsym() into the
# packed file afterwards: its export trie is gone).
DROP = {LC_SYMTAB, LC_DYSYMTAB, LC_FUNCTION_STARTS, LC_DATA_IN_CODE,
        LC_DYLD_EXPORTS_TRIE, LC_DYLD_CHAINED_FIXUPS}

S_ZEROFILL = (0x1, 0xC, 0x12)  # S_ZEROFILL, S_GB_ZEROFILL, S_THREAD_LOCAL_ZEROFILL


def fail(msg):
    raise SystemExit("macho_pack: " + msg)


def uleb(d, i):
    v = s = 0
    while True:
        b = d[i]
        i += 1
        v |= (b & 0x7F) << s
        s += 7
        if b < 0x80:
            return v, i


def bound_names(blob):
    """Symbol names named by a bind opcode stream (bind, weak or lazy)."""
    names, i = set(), 0
    while i < len(blob):
        op, imm = blob[i] & 0xF0, blob[i] & 0x0F
        i += 1
        if op == 0x40:                      # SET_SYMBOL_TRAILING_FLAGS_IMM
            j = blob.index(0, i)
            names.add(bytes(blob[i:j]))
            i = j + 1
        elif op in (0x20, 0x60, 0x70, 0x80, 0xA0):  # one ULEB/SLEB operand
            _, i = uleb(blob, i)
        elif op == 0xC0:                    # DO_BIND_ULEB_TIMES_SKIPPING_ULEB
            _, i = uleb(blob, i)
            _, i = uleb(blob, i)
        elif op == 0xD0:                    # THREADED
            if imm == 0:
                _, i = uleb(blob, i)
        elif op not in (0x00, 0x10, 0x30, 0x50, 0x90, 0xB0):
            fail("unknown bind opcode 0x%02x" % blob[i - 1])
    return names


def chained_fixups_empty(d, off, size):
    if size == 0:
        return True
    _, starts_off, _, _, imports_count = struct.unpack_from("<5I", d, off)
    if imports_count:
        return False
    base = off + starts_off
    seg_count = struct.unpack_from("<I", d, base)[0]
    for k in range(seg_count):
        so = struct.unpack_from("<I", d, base + 4 + 4 * k)[0]
        if so == 0:
            continue
        page_count = struct.unpack_from("<H", d, base + so + 20)[0]
        starts = struct.unpack_from("<%dH" % page_count, d, base + so + 22)
        if any(s != 0xFFFF for s in starts):
            return False
    return True


def code_signature(data, ident, exec_limit):
    """SuperBlob with one ad-hoc CodeDirectory (v0x20400, SHA-256, 16 KiB pages)."""
    n = (len(data) + PAGE - 1) // PAGE
    ident = ident.encode() + b"\0"
    hash_off = 88 + len(ident)
    cd_len = hash_off + 32 * n
    cd = struct.pack(">IIIIIIIIIBBBBI", 0xFADE0C02, cd_len, 0x20400, 0x2,  # CS_ADHOC
                     hash_off, 88, 0, n, len(data), 32, 2, 0, 14, 0)
    cd += struct.pack(">IIIQ", 0, 0, 0, 0)            # scatter, team, spare3, codeLimit64
    cd += struct.pack(">QQQ", 0, exec_limit, 0x1)      # execSeg base, limit, MAIN_BINARY
    cd += ident
    cd += b"".join(hashlib.sha256(data[i:i + PAGE]).digest() for i in range(0, len(data), PAGE))
    assert len(cd) == cd_len
    return struct.pack(">IIIII", 0xFADE0CC0, 20 + cd_len, 1, 0, 20) + cd


def align(x, a):
    return (x + a - 1) & ~(a - 1)


def main():
    if len(sys.argv) != 3:
        fail("usage: macho_pack.py <in> <out>")
    src, dst = sys.argv[1], sys.argv[2]
    d = bytearray(open(src, "rb").read())
    magic, cputype, _, filetype, ncmds, sizeofcmds = struct.unpack_from("<6I", d, 0)
    if magic != MH_MAGIC_64 or cputype != CPU_TYPE_ARM64 or filetype != MH_EXECUTE:
        fail("not an arm64 MH_EXECUTE")

    cmds, off = [], 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", d, off)
        cmds.append((cmd, bytearray(d[off:off + size])))
        off += size

    text = linkedit = dyld_info = None
    undefined = set()
    for cmd, lc in cmds:
        if cmd not in KEEP and cmd not in DROP:
            fail("unknown load command 0x%x" % cmd)
        if cmd == LC_SEGMENT_64:
            name = lc[8:24].rstrip(b"\0")
            if name == b"__TEXT":
                text = lc
            elif name == b"__LINKEDIT":
                linkedit = lc
        elif cmd in (LC_DYLD_INFO, LC_DYLD_INFO_ONLY):
            dyld_info = lc
        elif cmd == LC_DYLD_CHAINED_FIXUPS:
            if not chained_fixups_empty(d, *struct.unpack_from("<II", lc, 8)):
                fail("chained fixups present; relink with -Wl,-no_fixup_chains")
        elif cmd == LC_DYSYMTAB:
            if struct.unpack_from("<I", lc, 68)[0] or struct.unpack_from("<I", lc, 76)[0]:
                fail("classic relocations present")
        elif cmd == LC_SYMTAB:
            symoff, nsyms, stroff, _ = struct.unpack_from("<4I", lc, 8)
            for k in range(nsyms):
                strx, ntype, nsect = struct.unpack_from("<IBB", d, symoff + 16 * k)
                if (ntype & 0xEE) == 0 and (ntype & 0x01):  # not a stab, N_UNDF, N_EXT
                    undefined.add(bytes(d[stroff + strx:d.index(0, stroff + strx)]))
    if text is None or struct.unpack_from("<Q", text, 40)[0] != 0:
        fail("no __TEXT segment at file offset 0")

    # dyld info: keep every fixup stream (rebase, bind, weak bind, lazy bind)
    # verbatim, drop the export trie.
    blobs = []
    if dyld_info is not None:
        f = struct.unpack_from("<10I", dyld_info, 8)
        names = set()
        for k in range(4):
            o, n = f[2 * k], f[2 * k + 1]
            # Trailing zeros are DONE opcodes and padding: dyld stops at the end.
            blobs.append(bytes(d[o:o + n]).rstrip(b"\0"))
            if k:
                names |= bound_names(blobs[-1])
        if undefined - names:
            fail("undefined symbols not bound by dyld info: %s" % sorted(undefined - names))
    elif undefined:
        fail("undefined symbols but no dyld info")
    segs = [lc for cmd, lc in cmds if cmd == LC_SEGMENT_64]
    if linkedit is None or segs[-1] is not linkedit:
        fail("__LINKEDIT is not the last segment")

    # Data segments: only zero content may stay, and it becomes zero-fill.
    # Anything below __TEXT must be an unmapped __PAGEZERO.
    tv, tvsize = struct.unpack_from("<QQ", text, 24)
    for lc in segs:
        if lc is text or lc is linkedit:
            continue
        va, _, fo, fs, _, initprot = struct.unpack_from("<QQQQII", lc, 24)
        if va < tv and (fs or initprot):
            fail("mapped segment below __TEXT")
        if any(d[fo:fo + fs]):
            fail("segment %s has file content" % lc[8:24].rstrip(b"\0").decode())

    # End of the real __TEXT content: header + commands, or the last section.
    end = 0
    nsects = struct.unpack_from("<I", text, 64)[0]
    for k in range(nsects):
        o = 72 + 80 * k
        size, offset, _, _, _, flags = struct.unpack_from("<QIIIII", text, o + 40)
        if flags & 0xFF not in S_ZEROFILL:
            end = max(end, offset + size)

    # New load commands, same order. __LINKEDIT, when kept, stays the last
    # segment (dyld's bind opcodes must name a segment before it).
    new = []
    for cmd, lc in cmds:
        if cmd in DROP or (cmd in (LC_DYLD_INFO, LC_DYLD_INFO_ONLY) and not any(blobs)):
            continue
        if cmd == LC_SEGMENT_64 and lc is linkedit:
            pass  # file offset and size set below
        elif cmd == LC_SEGMENT_64 and lc is not text and struct.unpack_from("<Q", lc, 24)[0] >= tv:
            struct.pack_into("<QQ", lc, 40, 0, 0)  # zero-fill; file offset set below
        new.append((cmd, lc))
    if not any(c == LC_CODE_SIGNATURE for c, _ in new):
        new.append((LC_CODE_SIGNATURE, bytearray(struct.pack("<IIII", LC_CODE_SIGNATURE, 16, 0, 0))))
    lcs = b"".join(lc for _, lc in new)
    end = max(end, 32 + len(lcs))
    first = min([struct.unpack_from("<I", text, 72 + 80 * k + 48)[0] for k in range(nsects)
                 if struct.unpack_from("<Q", text, 72 + 80 * k + 40)[0]
                 and struct.unpack_from("<I", text, 72 + 80 * k + 64)[0] & 0xFF not in S_ZEROFILL]
                or [end])
    if 32 + len(lcs) > first:
        fail("load commands do not fit before the first section")

    out = bytearray(d[:end])
    out[32:32 + sizeofcmds] = bytes(sizeofcmds)
    out[32:32 + len(lcs)] = lcs
    struct.pack_into("<II", out, 16, len(new), len(lcs))
    if any(d[end:min(len(d), align(end, PAGE))]):
        fail("__TEXT has bytes past its last section")

    # Signature in the __TEXT tail, hashing everything before it.
    sig_off = align(len(out), 16)
    out += bytes(sig_off - len(out))
    ident = os.path.basename(dst)
    sig_len = len(code_signature(bytes(sig_off), ident, 0))
    text_fs = align(sig_off + sig_len, PAGE)
    if text_fs > tvsize:
        fail("result does not fit in __TEXT (%d > %d)" % (text_fs, tvsize))

    # Fixup opcodes in __LINKEDIT, right after __TEXT, 8-byte aligned.
    le = bytearray()
    fields = [0] * 10
    for k, blob in enumerate(blobs):
        if blob:
            le += bytes(align(len(le), 8) - len(le))
            fields[2 * k], fields[2 * k + 1] = text_fs + len(le), len(blob)
            le += blob

    off = 32
    for cmd, lc in new:
        if cmd in (LC_DYLD_INFO, LC_DYLD_INFO_ONLY):
            struct.pack_into("<10I", out, off + 8, *fields)
        elif cmd == LC_CODE_SIGNATURE:
            struct.pack_into("<II", out, off + 8, sig_off, sig_len)
        elif cmd == LC_SEGMENT_64 and lc is text:
            struct.pack_into("<Q", out, off + 48, text_fs)
        elif cmd == LC_SEGMENT_64 and lc is linkedit:
            struct.pack_into("<QQ", out, off + 40, text_fs, len(le))
        elif cmd == LC_SEGMENT_64 and struct.unpack_from("<Q", lc, 24)[0] >= tv:
            struct.pack_into("<Q", out, off + 40, text_fs)  # zero-fill, just past __TEXT
        off += len(lc)
    sig = code_signature(bytes(out), ident, text_fs)
    assert len(sig) == sig_len
    out += sig
    out += bytes(text_fs - len(out))
    out += le

    if os.path.exists(dst):
        os.unlink(dst)
    with open(dst, "wb") as f:
        f.write(out)
    os.chmod(dst, 0o755)


if __name__ == "__main__":
    main()
