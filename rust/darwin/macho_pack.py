#!/usr/bin/env python3
"""Shrink an arm64 macOS executable's __LINKEDIT and re-sign it ad hoc.

Usage: macho_pack.py [--strip] <in> <out>

A generic post-link tool: it reads offsets and sizes out of the file it is given
and contains no bytes of any program. Both modes keep every byte of every
segment where the linker put it (no instruction moves) and keep only what dyld
needs from __LINKEDIT: the fixups (dyld info opcodes or the chained fixups blob)
and a new ad-hoc signature, a SuperBlob holding one CodeDirectory (version
0x20400, truncated SHA-256, 16 KiB hash pages, empty identifier). The symbol table, export trie, function starts and data-in-code
go, so nothing can dlsym() into the result. LC_SYMTAB and LC_DYSYMTAB stay,
with zero entries. The fixups are copied as they are, except the classic bind
opcodes: they are decoded and written again in a shorter form when there is
one (each symbol named once, groups in address order, gaps folded into the
bind opcodes), and the tool checks the new stream binds exactly the same slots
to the same symbols.

--strip: the normal Mach-O layout. __LINKEDIT stays at its page-aligned offset
  after the last segment and holds the fixups, then the signature, which hashes
  every byte before it. `codesign --verify --strict` and `dyld_info` accept the
  result. Works with chained fixups.

default (fold): for an image whose only file content is __TEXT. Every other
  segment must be all zero bytes (a GOT bound at load time, bss) and becomes
  zero-fill, its sections too (S_ZEROFILL, file offset 0). Imports must use
  classic dyld info (-Wl,-no_fixup_chains). The signature goes in the last
  bytes of the last __TEXT page and hashes every byte before it, so the file is
  just the __TEXT pages, plus the bind opcodes in __LINKEDIT after them when
  there are imports. BIND_OPCODE_SET_TYPE_IMM opcodes are dropped when every
  bind is a pointer. This relies on undocumented kernel and dyld behaviour,
  listed in darwin/README.md ("Relies on").

It refuses, with a non-zero exit, anything it cannot handle safely: not a thin
arm64 MH_EXECUTE, an unknown load command, classic relocations, imports
without dyld info or chained fixups, __LINKEDIT not last, and in fold mode
chained fixups with content, non-zero data outside __TEXT, a section type
other than regular, non-lazy pointers or zero-fill outside __TEXT, or a result
that overflows __TEXT.
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

# Commands with no __LINKEDIT payload, kept as they are.
PLAIN = {LC_LOAD_DYLINKER, LC_LOAD_DYLIB, LC_LOAD_WEAK_DYLIB, LC_UUID, LC_BUILD_VERSION,
         LC_VERSION_MIN_MACOSX, LC_SOURCE_VERSION, LC_MAIN, LC_RPATH}
# Tables only tools read for a main executable: dropped.
DROP = {LC_FUNCTION_STARTS, LC_DATA_IN_CODE, LC_DYLD_EXPORTS_TRIE}
LINKEDIT = {LC_SYMTAB, LC_DYSYMTAB, LC_DYLD_INFO, LC_DYLD_INFO_ONLY, LC_DYLD_CHAINED_FIXUPS,
            LC_CODE_SIGNATURE} | DROP

S_ZEROFILL = (0x1, 0xC, 0x12)  # S_ZEROFILL, S_GB_ZEROFILL, S_THREAD_LOCAL_ZEROFILL
# Section types fold mode turns into S_ZEROFILL when their segment loses its
# file content: S_REGULAR and S_NON_LAZY_SYMBOL_POINTERS (a GOT bound by opcodes).
TO_ZEROFILL = (0x0, 0x6) + S_ZEROFILL
BIND_TYPE_POINTER = 1
CD_MIN = 112  # shorter CodeDirectories are killed at exec (measured)


def fail(msg):
    raise SystemExit("macho_pack: " + msg)


def align(x, a):
    return (x + a - 1) & ~(a - 1)


def uleb(d, i):
    v = s = 0
    while True:
        if i >= len(d):
            fail("truncated opcode stream")
        b = d[i]
        i += 1
        v |= (b & 0x7F) << s
        s += 7
        if b < 0x80:
            return v, i


def walk_opcodes(blob, bind):
    """Yield (offset, opcode byte) for each rebase or bind opcode, checking the
    stream is well formed."""
    i = 0
    while i < len(blob):
        start, op, imm = i, blob[i] & 0xF0, blob[i] & 0x0F
        i += 1
        if bind and op == 0x40:                         # SET_SYMBOL_TRAILING_FLAGS_IMM
            i = blob.find(0, i) + 1
            if i == 0:
                fail("unterminated symbol name in bind opcodes")
        elif bind and op in (0x20, 0x60, 0x70, 0x80, 0xA0):  # one ULEB/SLEB operand
            _, i = uleb(blob, i)
        elif bind and op == 0xC0:                       # DO_BIND_ULEB_TIMES_SKIPPING_ULEB
            _, i = uleb(blob, i)
            _, i = uleb(blob, i)
        elif bind and op == 0xD0:                       # THREADED
            if imm == 0:
                _, i = uleb(blob, i)
        elif not bind and op in (0x20, 0x30, 0x60, 0x70):
            _, i = uleb(blob, i)
        elif not bind and op == 0x80:                   # DO_REBASE_ULEB_TIMES_SKIPPING_ULEB
            _, i = uleb(blob, i)
            _, i = uleb(blob, i)
        elif op not in ((0x00, 0x10, 0x30, 0x50, 0x90, 0xB0) if bind else (0x00, 0x10, 0x40, 0x50)):
            fail("unknown %s opcode 0x%02x" % ("bind" if bind else "rebase", blob[start]))
        if i > len(blob):
            fail("truncated opcode stream")
        yield start, blob[start]


def trim_opcodes(blob, bind):
    """Cut trailing DONE opcodes and padding: dyld stops at the end of the stream."""
    end = 0
    for start, byte in walk_opcodes(blob, bind):
        if byte & 0xF0:
            end = None
        elif end is None:
            end = start
    return blob if end is None else blob[:end]


def sleb(d, i):
    v, j = uleb(d, i)
    bits = 7 * (j - i)
    return (v - (1 << bits) if d[j - 1] & 0x40 else v), j


def uleb_bytes(v):
    out = bytearray()
    while True:
        b, v = v & 0x7F, v >> 7
        out.append(b | (0x80 if v else 0))
        if not v:
            return bytes(out)


def sleb_bytes(v):
    out = bytearray()
    while True:
        b, v = v & 0x7F, v >> 7
        done = (v == 0 and not b & 0x40) or (v == -1 and b & 0x40)
        out.append(b | (0 if done else 0x80))
        if done:
            return bytes(out)


ADDR_MASK = (1 << 64) - 1


def decode_binds(blob):
    """The binds of a classic (non-lazy) bind opcode stream, in stream order,
    as (segment, offset, ordinal, symbol, flags, type, addend), the way dyld
    runs it: no ordinal, segment or symbol until an opcode sets it, type and
    addend 0. None when the stream holds something this tool does not
    re-encode: threaded binds, a bind before the ordinal, segment or symbol is
    set, or opcodes after a DONE."""
    binds, seg, off, ordinal, sym, flags, typ, addend = [], None, 0, None, None, 0, 0, 0
    i = 0
    try:
        while i < len(blob):
            op, imm = blob[i] & 0xF0, blob[i] & 0x0F
            i += 1
            times, skip = 0, 0
            if op == 0x00:                                  # DONE
                return binds if not any(blob[i:]) else None
            elif op == 0x10:                                # SET_DYLIB_ORDINAL_IMM
                ordinal = imm
            elif op == 0x20:                                # SET_DYLIB_ORDINAL_ULEB
                ordinal, i = uleb(blob, i)
            elif op == 0x30:                                # SET_DYLIB_SPECIAL_IMM
                ordinal = imm - 16 if imm else 0
            elif op == 0x40:                                # SET_SYMBOL_TRAILING_FLAGS_IMM
                j = blob.index(0, i)
                flags, sym, i = imm, bytes(blob[i:j]), j + 1
            elif op == 0x50:                                # SET_TYPE_IMM
                typ = imm
            elif op == 0x60:                                # SET_ADDEND_SLEB
                addend, i = sleb(blob, i)
            elif op == 0x70:                                # SET_SEGMENT_AND_OFFSET_ULEB
                seg, (off, i) = imm, uleb(blob, i)
            elif op == 0x80:                                # ADD_ADDR_ULEB
                v, i = uleb(blob, i)
                off = (off + v) & ADDR_MASK
            elif op == 0x90:                                # DO_BIND
                times = 1
            elif op == 0xA0:                                # DO_BIND_ADD_ADDR_ULEB
                times, (skip, i) = 1, uleb(blob, i)
            elif op == 0xB0:                                # DO_BIND_ADD_ADDR_IMM_SCALED
                times, skip = 1, 8 * imm
            elif op == 0xC0:                                # DO_BIND_ULEB_TIMES_SKIPPING_ULEB
                times, i = uleb(blob, i)
                skip, i = uleb(blob, i)
            else:                                           # THREADED
                return None
            if times and (ordinal is None or seg is None or sym is None):
                return None
            for _ in range(times):
                binds.append((seg, off, ordinal, sym, flags, typ, addend))
                off = (off + skip + 8) & ADDR_MASK
    except ValueError:                                      # unterminated symbol name
        return None
    return binds


def encode_binds(binds):
    """A short opcode stream for these binds. Binds that share a symbol, dylib,
    type and addend are emitted together (a name is written once), groups in
    order of their lowest address, addresses ascending within a group. A gap
    to the next address is folded into the bind opcode when it is forward, a
    run with a constant stride becomes DO_BIND_ULEB_TIMES_SKIPPING_ULEB when
    that is shorter, and a move backwards or to another segment is a
    SET_SEGMENT_AND_OFFSET_ULEB."""
    groups = {}
    for seg, off, *key in binds:
        groups.setdefault(tuple(key), []).append((seg, off))
    order = []
    for key, addrs in sorted(groups.items(), key=lambda g: min(g[1])):
        order += [(key, a) for a in sorted(addrs)]

    def move(cur, to):
        """Opcodes that take the cursor from cur to `to` (None: not needed)."""
        if to is None or cur == to:
            return b""
        if cur is not None and cur[0] == to[0] and to[1] > cur[1]:
            return b"\x80" + uleb_bytes(to[1] - cur[1])
        return bytes([0x70 | to[0]]) + uleb_bytes(to[1])

    def single(at, nxt):
        """One bind at `at`, and where it leaves the cursor: on nxt when that
        is forward in the same segment."""
        gap = nxt[1] - at[1] - 8 if nxt is not None and nxt[0] == at[0] else -1
        if gap <= 0:
            return b"\x90", (at[0], at[1] + 8)
        if gap % 8 == 0 and gap // 8 < 16:
            return bytes([0xB0 | gap // 8]), nxt
        return b"\xA0" + uleb_bytes(gap), nxt

    def addr(k):
        return order[k][1] if k < len(order) else None

    out = bytearray()
    state = (None, None, 0, 0, 0)         # ordinal, symbol, flags, type, addend: dyld's start
    cur = None
    i = 0
    while i < len(order):
        key, at = order[i]
        ordinal, sym, flags, typ, addend = key
        if ordinal != state[0]:
            if ordinal <= 0:
                out.append(0x30 | (ordinal & 0x0F))
            elif ordinal < 16:
                out.append(0x10 | ordinal)
            else:
                out += b"\x20" + uleb_bytes(ordinal)
        if (sym, flags) != state[1:3]:
            out += bytes([0x40 | flags]) + sym + b"\0"
        if typ != state[3]:
            out.append(0x50 | typ)
        if addend != state[4]:
            out += b"\x60" + sleb_bytes(addend)
        state = key
        out += move(cur, at)
        # The run of this group's binds with one stride, from i.
        n, stride = 1, 0
        if i + 1 < len(order) and order[i + 1][0] == key and order[i + 1][1][0] == at[0]:
            stride = order[i + 1][1][1] - at[1]
            while (i + n < len(order) and order[i + n][0] == key and order[i + n][1][0] == at[0]
                   and order[i + n][1][1] - order[i + n - 1][1][1] == stride):
                n += 1
        if n > 1 and stride >= 8:
            end = (at[0], at[1] + n * stride)
            times = b"\xC0" + uleb_bytes(n) + uleb_bytes(stride - 8)
            one_by_one, c = 0, None
            for j in range(i, i + n):
                b, c = single(addr(j), addr(j + 1))
                one_by_one += len(b)
            if len(times) + len(move(end, addr(i + n))) < one_by_one + len(move(c, addr(i + n))):
                out += times
                cur = end
                i += n
                continue
        b, cur = single(at, addr(i + 1))
        out += b
        i += 1
    return bytes(out)


def shorter_binds(blob):
    """The bind stream re-encoded by encode_binds when that is shorter and
    binds the same slots to the same symbols, else the stream as it is."""
    binds = decode_binds(blob)
    if not binds or len({(s, o) for s, o, *_ in binds}) < len(binds):
        return blob                       # nothing to bind, or a slot bound twice: order matters
    new = encode_binds(binds)
    if sorted(decode_binds(new) or []) != sorted(binds):
        fail("bind re-encoding changed the binds")
    return new if len(new) < len(blob) else blob


def chained_used(d, off, size):
    """Whether a chained fixups blob has any import or fixup chain."""
    if size == 0:
        return False
    _, starts_off, _, _, imports_count = struct.unpack_from("<5I", d, off)
    base = off + starts_off
    for k in range(struct.unpack_from("<I", d, base)[0]):
        so = struct.unpack_from("<I", d, base + 4 + 4 * k)[0]
        if so:
            page_count = struct.unpack_from("<H", d, base + so + 20)[0]
            starts = struct.unpack_from("<%dH" % page_count, d, base + so + 22)
            if any(s != 0xFFFF for s in starts):
                return True
    return imports_count > 0


def code_signature(data, exec_limit):
    """SuperBlob with one ad-hoc CodeDirectory over `data`: version 0x20400,
    truncated SHA-256 (20-byte hashes), 16 KiB pages, empty identifier,
    execSeg = __TEXT with CS_EXECSEG_MAIN_BINARY, zero padding between the
    identifier and the hashes so the CodeDirectory is at least 112 bytes."""
    n = (len(data) + PAGE - 1) // PAGE
    hash_off = max(89, CD_MIN - 20 * n)
    cd = struct.pack(">9I4B4I4Q",
                     0xFADE0C02, hash_off + 20 * n, 0x20400, 0x2,  # magic, length, version, ADHOC
                     hash_off, 88,                      # hashOffset, identOffset
                     0, n, len(data),                   # nSpecialSlots, nCodeSlots, codeLimit
                     20, 3, 0, 14,                      # hashSize, SHA256_TRUNCATED, platform, 2^14
                     0, 0, 0, 0, 0,                     # spare2, scatter, team, spare3, codeLimit64
                     0, exec_limit, 1)                  # execSegBase, execSegLimit, MAIN_BINARY
    cd += bytes(hash_off - 88) + b"".join(hashlib.sha256(data[i:i + PAGE]).digest()[:20]
                                          for i in range(0, len(data), PAGE))
    return struct.pack(">5I", 0xFADE0CC0, 20 + len(cd), 1, 0, 20) + cd


def sig_size(n):
    return 20 + max(89 + 20 * n, CD_MIN)


def parse(d):
    magic, cputype, _, filetype, ncmds, sizeofcmds = struct.unpack_from("<6I", d, 0)
    if magic != MH_MAGIC_64 or cputype != CPU_TYPE_ARM64 or filetype != MH_EXECUTE:
        fail("not a thin arm64 MH_EXECUTE")
    cmds, off = [], 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", d, off)
        if size < 8 or off + size > 32 + sizeofcmds:
            fail("bad load command size")
        if cmd not in PLAIN and cmd not in LINKEDIT and cmd != LC_SEGMENT_64:
            fail("unknown load command 0x%x" % cmd)
        cmds.append([cmd, bytearray(d[off:off + size])])
        off += size
    return cmds, sizeofcmds


def seg_name(lc):
    return lc[8:24].rstrip(b"\0")


def main():
    args = sys.argv[1:]
    fold = True
    if args[:1] == ["--strip"]:
        fold, args = False, args[1:]
    if len(args) != 2:
        fail("usage: macho_pack.py [--strip] <in> <out>")
    src, dst = args
    d = bytearray(open(src, "rb").read())
    cmds, sizeofcmds = parse(d)

    segs = [lc for cmd, lc in cmds if cmd == LC_SEGMENT_64]
    text = next((lc for lc in segs if seg_name(lc) == b"__TEXT"), None)
    linkedit = next((lc for lc in segs if seg_name(lc) == b"__LINKEDIT"), None)
    if text is None or struct.unpack_from("<Q", text, 40)[0] != 0:
        fail("no __TEXT segment at file offset 0")
    if linkedit is None or segs[-1] is not linkedit:
        fail("__LINKEDIT is not the last segment")
    tv, tvsize, _, tfs = struct.unpack_from("<4Q", text, 24)
    le_off = struct.unpack_from("<Q", linkedit, 40)[0]
    if le_off % PAGE:
        fail("__LINKEDIT is not page aligned")

    # Fixups to keep.
    dyld_info = next((lc for cmd, lc in cmds if cmd in (LC_DYLD_INFO, LC_DYLD_INFO_ONLY)), None)
    chained = next((lc for cmd, lc in cmds if cmd == LC_DYLD_CHAINED_FIXUPS), None)
    streams, chained_blob = [b""] * 4, b""
    if dyld_info is not None:
        f = struct.unpack_from("<10I", dyld_info, 8)
        for k in range(4):  # rebase, bind, weak bind, lazy bind
            blob = bytes(d[f[2 * k]:f[2 * k] + f[2 * k + 1]])
            # Lazy binds end each entry with DONE and are entered at an offset: keep as is.
            streams[k] = blob if k == 3 else trim_opcodes(blob, k > 0)
        streams[1] = shorter_binds(streams[1])
    if chained is not None:
        o, n = struct.unpack_from("<II", chained, 8)
        if chained_used(d, o, n):
            if fold:
                fail("chained fixups present; relink with -Wl,-no_fixup_chains")
            chained_blob = bytes(d[o:o + n])

    # dyld binds imports only through those fixups. Without them (a pre-10.6
    # style image), it would need the symbol tables this tool drops.
    for cmd, lc in cmds:
        if cmd == LC_DYSYMTAB and (struct.unpack_from("<I", lc, 68)[0]
                                   or struct.unpack_from("<I", lc, 76)[0]):
            fail("classic relocations present")
        if cmd == LC_SYMTAB and dyld_info is None and chained is None:
            symoff, nsyms = struct.unpack_from("<2I", lc, 8)
            if any(struct.unpack_from("<B", d, symoff + 16 * k + 4)[0] & 0xEF == 0x01
                   for k in range(nsyms)):  # N_UNDF | N_EXT, not a stab
                fail("undefined symbols but no dyld info or chained fixups")

    if fold:
        # Anything below __TEXT must be an unmapped __PAGEZERO; every other
        # segment must hold only zero bytes.
        for lc in segs:
            if lc is text or lc is linkedit:
                continue
            va, _, fo, fs, _, initprot = struct.unpack_from("<QQQQII", lc, 24)
            if va < tv and (fs or initprot):
                fail("mapped segment below __TEXT")
            if any(d[fo:fo + fs]):
                fail("segment %s has file content" % seg_name(lc).decode())
            for k in range(struct.unpack_from("<I", lc, 64)[0]):
                sect = 72 + 80 * k
                if struct.unpack_from("<I", lc, sect + 64)[0] & 0xFF not in TO_ZEROFILL:
                    fail("section %s cannot become zero-fill"
                         % lc[sect:sect + 16].rstrip(b"\0").decode())
        # dyld binds a slot whose type was never set as a pointer.
        types = {i: b & 0x0F for i, b in walk_opcodes(streams[1], True) if b & 0xF0 == 0x50}
        if all(t == BIND_TYPE_POINTER for t in types.values()):
            streams[1] = bytes(b for i, b in enumerate(streams[1]) if i not in types)
        # Real __TEXT content ends at the header and commands or the last section.
        content = 0
        for k in range(struct.unpack_from("<I", text, 64)[0]):
            size, offset, _, _, _, flags = struct.unpack_from("<QIIIII", text, 72 + 80 * k + 40)
            if flags & 0xFF not in S_ZEROFILL:
                content = max(content, offset + size)
        if any(d[max(content, 32 + sizeofcmds):tfs]):
            fail("__TEXT has bytes past its last section")
    else:
        for lc in segs:
            fo, fs = struct.unpack_from("<QQ", lc, 40)
            if lc is not linkedit and fo + fs > le_off:
                fail("segment %s overlaps __LINKEDIT" % seg_name(lc).decode())

    # New load commands, same order, the dropped ones removed.
    new = []
    for cmd, lc in cmds:
        if cmd in DROP:
            continue
        if cmd == LC_DYLD_CHAINED_FIXUPS and not chained_blob:
            continue
        if cmd == LC_SYMTAB:
            lc[8:24] = bytes(16)
        elif cmd == LC_DYSYMTAB:
            lc[8:80] = bytes(72)
        new.append([cmd, lc])
    if not any(c == LC_CODE_SIGNATURE for c, _ in new):
        new.append([LC_CODE_SIGNATURE, bytearray(struct.pack("<4I", LC_CODE_SIGNATURE, 16, 0, 0))])
    lcs_len = sum(len(lc) for _, lc in new)
    if lcs_len > sizeofcmds:
        fail("load commands grew")

    if fold:
        # The signature ends at the end of the last __TEXT page (16-byte
        # aligned; the alignment padding is part of the declared blob), so it
        # hashes every other byte of the page.
        end = max(content, 32 + lcs_len)
        text_fs = align(end, PAGE)
        while text_fs - align(sig_size(text_fs // PAGE), 16) < end:
            text_fs += PAGE
        sig_len = align(sig_size(text_fs // PAGE), 16)
        sig_off = text_fs - sig_len
        if text_fs > tvsize:
            fail("result does not fit in __TEXT (%d > %d)" % (text_fs, tvsize))
        le_off = text_fs
    else:
        text_fs = tfs

    # __LINKEDIT: the fixups, 8-byte aligned, then (strip) the signature.
    le = bytearray()
    info_fields, chained_fields = [0] * 10, [0, 0]
    for k, blob in enumerate(streams):
        if blob:
            le += bytes(align(len(le), 8) - len(le))
            info_fields[2 * k:2 * k + 2] = le_off + len(le), len(blob)
            le += blob
    if chained_blob:
        le += bytes(align(len(le), 8) - len(le))
        chained_fields = [le_off + len(le), len(chained_blob)]
        le += chained_blob
    if not fold:
        sig_off = le_off + align(len(le), 16)
        sig_len = sig_size((sig_off + PAGE - 1) // PAGE)

    # Segment bytes before __LINKEDIT, or the folded __TEXT: its content, zeros
    # (checked above) up to the signature.
    out = bytearray(d[:le_off] if not fold else d[:end])
    out[32:32 + sizeofcmds] = bytes(sizeofcmds)
    if fold:
        out += bytes(text_fs - len(out))
    struct.pack_into("<II", out, 16, len(new), lcs_len)
    off = 32
    for cmd, lc in new:
        if cmd in (LC_DYLD_INFO, LC_DYLD_INFO_ONLY):
            struct.pack_into("<10I", lc, 8, *info_fields)
        elif cmd == LC_DYLD_CHAINED_FIXUPS:
            struct.pack_into("<II", lc, 8, *chained_fields)
        elif cmd == LC_CODE_SIGNATURE:
            struct.pack_into("<II", lc, 8, sig_off, sig_len)
        elif cmd == LC_SEGMENT_64 and lc is linkedit:
            le_end = sig_off + sig_len if not fold else le_off + len(le)
            struct.pack_into("<4Q", lc, 24, struct.unpack_from("<Q", lc, 24)[0],
                             align(le_end - le_off, PAGE), le_off, le_end - le_off)
        elif fold and lc is text:
            struct.pack_into("<Q", lc, 48, text_fs)
        elif fold and cmd == LC_SEGMENT_64 and struct.unpack_from("<Q", lc, 24)[0] >= tv:
            struct.pack_into("<QQ", lc, 40, text_fs, 0)  # zero-fill, just past __TEXT
            for k in range(struct.unpack_from("<I", lc, 64)[0]):
                sect = 72 + 80 * k
                flags = struct.unpack_from("<I", lc, sect + 64)[0]
                if flags & 0xFF not in S_ZEROFILL:  # no indirect symbols left to index
                    struct.pack_into("<II", lc, sect + 64, flags & ~0xFF | 0x1, 0)
                struct.pack_into("<I", lc, sect + 48, 0)  # zero-fill: no file offset
        out[off:off + len(lc)] = lc
        off += len(lc)

    if fold:
        sig = code_signature(bytes(out[:sig_off]), text_fs)
        out[sig_off:sig_off + len(sig)] = sig
        out += le
    else:
        out += le
        out += bytes(sig_off - len(out))
        out += code_signature(bytes(out), text_fs)
        assert len(out) == sig_off + sig_len

    # A new inode: the kernel caches a signature per vnode.
    if os.path.exists(dst):
        os.unlink(dst)
    with open(dst, "wb") as f:
        f.write(out)
    os.chmod(dst, 0o755)


if __name__ == "__main__":
    main()
