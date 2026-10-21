#!/usr/bin/env python3
"""Fold a linked arm64 Mach-O executable into one signed 16 KiB __TEXT page.

Usage: machopack.py [--full-hash] <in> <out>

ld ends every executable with a __LINKEDIT segment (symbols, fixups, code signature) that
starts on a new 16 KiB page, and gives every writable segment its own page. When the
program's only file content is __TEXT, most of that is dead weight at run time. This tool:

- drops the load commands dyld doesn't use to launch a main executable (symbol tables,
  export trie, function starts, data in code, empty chained fixups, the old signature),
- turns every other segment into zero-fill (file size 0) once it has checked that its file
  bytes are all zero (bss, or a GOT that dyld fills at load time),
- keeps dyld's bind opcodes, verbatim, when the program imports symbols: link with
  `-no_fixup_chains -bind_at_load`, so that ld writes classic opcodes and leaves the GOT
  zero (chained fixups store the import info in the GOT slots themselves),
- keeps __TEXT's layout as is (no code or data moves) and writes a fresh ad-hoc signature.

Two layouts:

- default (folded): __TEXT's file size is cut to the end of its last section and the
  signature goes right after it, inside the executable page. Its hashes cover the file up
  to the signature only. A program without imports is then exactly 16384 bytes (the
  kernel reads a whole page of header); one with imports adds its bind opcodes in a
  __LINKEDIT segment that starts at 16384. This relies on undocumented kernel behaviour:
  the bytes of the page past the signed range are mapped and executable but not hashed
  (darwin/README.md).

- --full-hash: __TEXT keeps its whole 16 KiB page and every byte of it is hashed. The bind
  opcodes (if any) and a bare CodeDirectory follow in __LINKEDIT at 16384, as ld lays them
  out. 16505 bytes without imports.

It refuses inputs it can't fold without changing their behaviour: rebases, lazy or weak
binds, chained fixups with imports, data segments with non-zero bytes, content in __TEXT
outside its sections, fat or non-arm64 files. It contains nothing specific to any program.
"""
import hashlib
import os
import struct
import sys

MH_MAGIC_64, CPU_TYPE_ARM64, MH_EXECUTE = 0xFEEDFACF, 0x0100000C, 2
LC_SEGMENT_64, LC_SYMTAB, LC_DYSYMTAB = 0x19, 0x2, 0xB
LC_CODE_SIGNATURE, LC_FUNCTION_STARTS, LC_DATA_IN_CODE = 0x1D, 0x26, 0x29
LC_DYLD_INFO, LC_DYLD_INFO_ONLY = 0x22, 0x80000022
LC_DYLD_EXPORTS_TRIE, LC_DYLD_CHAINED_FIXUPS = 0x80000033, 0x80000034
LC_SEGMENT_SPLIT_INFO, LC_LINKER_OPTIMIZATION_HINT, LC_ATOM_INFO = 0x1E, 0x2E, 0x36
LC_ENCRYPTION_INFO_64 = 0x2C
# Load commands whose payload lives in __LINKEDIT and that dyld doesn't read to launch a
# main executable (the dyld info is rebuilt separately).
DROP = {LC_SYMTAB, LC_DYSYMTAB, LC_CODE_SIGNATURE, LC_FUNCTION_STARTS, LC_DATA_IN_CODE,
        LC_DYLD_EXPORTS_TRIE, LC_SEGMENT_SPLIT_INFO, LC_LINKER_OPTIMIZATION_HINT,
        LC_ATOM_INFO, LC_DYLD_CHAINED_FIXUPS}
S_ZEROFILL_TYPES = {0x1, 0xC, 0x12}  # S_ZEROFILL, S_GB_ZEROFILL, S_THREAD_LOCAL_ZEROFILL
PAGE = 0x4000  # arm64 VM page: the kernel reads this much of the header at once
CS_ADHOC, CS_LINKER_SIGNED = 0x2, 0x20000


def fail(msg):
    sys.exit("machopack: " + msg)


def u32(b, o):
    return struct.unpack_from("<I", b, o)[0]


def uleb(b, i):
    v = s = 0
    while True:
        if i >= len(b):
            fail("truncated bind opcodes")
        c = b[i]
        i += 1
        v |= (c & 0x7F) << s
        s += 7
        if c < 0x80:
            return v, i


def bind_stream(blob):
    """The (non-lazy) bind opcodes dyld acts on, re-encoded: everything before the first
    BIND_OPCODE_DONE (dyld also stops at the end of the buffer, so the DONE and ld's zero
    padding can go), without the SET_TYPE_IMM(POINTER) opcodes. dyld starts with type 0
    and binds a pointer whatever the type (an undocumented quirk, darwin/README.md)."""
    out, i = bytearray(), 0
    while i < len(blob):
        op, imm = blob[i] & 0xF0, blob[i] & 0x0F
        start, i = i, i + 1
        if op == 0x00:                                # DONE
            break
        if op == 0x40:                                # SET_SYMBOL_TRAILING_FLAGS_IMM
            j = blob.find(b"\0", i)
            if j < 0:
                fail("truncated bind opcodes")
            i = j + 1
        elif op in (0x20, 0x60, 0x70, 0x80, 0xA0):    # one ULEB/SLEB operand
            _, i = uleb(blob, i)
        elif op == 0xC0:                              # DO_BIND_ULEB_TIMES_SKIPPING_ULEB
            _, i = uleb(blob, i)
            _, i = uleb(blob, i)
        elif op == 0x50:                              # SET_TYPE_IMM
            if imm != 1:
                fail("bind type %d is not BIND_TYPE_POINTER" % imm)
            continue
        elif op not in (0x10, 0x30, 0x90, 0xB0):      # immediate-only opcodes
            fail("unknown bind opcode 0x%02x" % blob[start])
        out += blob[start:i]
    return bytes(out)


def fixups(data, cmd, body):
    """Check the fixups this load command describes; return the bind opcodes to keep."""
    if cmd == LC_DYLD_CHAINED_FIXUPS:
        off, size = struct.unpack_from("<II", body, 8)
        if size == 0:
            return b""
        _, starts, _, _, imports_count = struct.unpack_from("<IIIII", data, off)
        seg_count = u32(data, off + starts)
        seg_offsets = struct.unpack_from("<%dI" % seg_count, data, off + starts + 4)
        if imports_count or any(seg_offsets):
            fail("chained fixups with imports or rebases: link with -no_fixup_chains -bind_at_load")
        return b""
    f = struct.unpack_from("<10I", body, 8)
    names = ("rebase", "bind", "weak bind", "lazy bind")
    streams = [bytes(data[f[2 * k]:f[2 * k] + f[2 * k + 1]]) for k in range(4)]
    for k in (0, 2, 3):
        if streams[k].rstrip(b"\0"):
            fail("the program has %s opcodes (only plain binds are supported)" % names[k])
    return bind_stream(streams[1])


def code_signature(data, ident, exec_limit, superblob):
    """Ad-hoc CodeDirectory (v0x20400: it carries the exec segment fields the kernel wants
    on a main binary, SHA-256, 16 KiB hash pages) over all of data. Bare, or wrapped in a
    SuperBlob, the only form `codesign` can parse."""
    n = (len(data) + PAGE - 1) // PAGE
    hashes = b"".join(hashlib.sha256(data[i * PAGE:(i + 1) * PAGE]).digest() for i in range(n))
    ident = ident.encode() + b"\0"
    cd = struct.pack(">IIIIIIIIIBBBBIIIIQQQQ",
                     0xFADE0C02, 88 + len(ident) + len(hashes), 0x20400,
                     CS_ADHOC | (CS_LINKER_SIGNED if superblob else 0),
                     88 + len(ident), 88,      # hashOffset, identOffset
                     0, n, len(data),          # nSpecialSlots, nCodeSlots, codeLimit
                     32, 2, 0, 14,             # hashSize, SHA-256, platform, pageSize 2^14
                     0, 0, 0, 0, 0,            # spare2, scatter, team, spare3, codeLimit64
                     0, exec_limit, 1)         # execSegBase, execSegLimit, MAIN_BINARY
    cd += ident + hashes
    if not superblob:
        return cd
    return struct.pack(">IIIII", 0xFADE0CC0, 20 + len(cd), 1, 0, 20) + cd


def old_identifier(data, cmds):
    for cmd, body in cmds:
        if cmd == LC_CODE_SIGNATURE:
            off = u32(body, 8)
            if struct.unpack_from(">I", data, off)[0] == 0xFADE0CC0:
                for i in range(struct.unpack_from(">I", data, off + 8)[0]):
                    typ, boff = struct.unpack_from(">II", data, off + 12 + 8 * i)
                    if typ == 0:
                        cd = off + boff
                        ident = cd + struct.unpack_from(">I", data, cd + 20)[0]
                        return data[ident:data.index(b"\0", ident)].decode()
    return None


def pack(data, name, full_hash=False):
    magic, cputype, _, filetype, ncmds, sizeofcmds, _, _ = struct.unpack_from("<IiiIIIII", data, 0)
    if magic != MH_MAGIC_64 or cputype != CPU_TYPE_ARM64 or filetype != MH_EXECUTE:
        fail("not an arm64 Mach-O executable")
    cmds, off = [], 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, off)
        cmds.append((cmd, bytearray(data[off:off + size])))
        off += size

    out_cmds, text, linkedit, info, binds = [], None, None, None, b""
    content_end, text_file = 32 + sizeofcmds, 0
    for cmd, body in cmds:
        if cmd == LC_ENCRYPTION_INFO_64:
            fail("encrypted binaries are not supported")
        if cmd in (LC_DYLD_CHAINED_FIXUPS, LC_DYLD_INFO, LC_DYLD_INFO_ONLY):
            binds = fixups(data, cmd, body) or binds
        if cmd in DROP:
            continue
        if cmd in (LC_DYLD_INFO, LC_DYLD_INFO_ONLY):
            info = len(out_cmds)
        elif cmd == LC_SEGMENT_64:
            segname = bytes(body[8:24]).rstrip(b"\0")
            fileoff, filesize = struct.unpack_from("<QQ", body, 40)
            if segname == b"__LINKEDIT":
                linkedit = len(out_cmds)
            elif fileoff == 0 and filesize:
                if text is not None:
                    fail("more than one segment maps the file header")
                text, text_file = len(out_cmds), filesize
                for i in range(u32(body, 64)):
                    s = 72 + 80 * i
                    size, offset = struct.unpack_from("<QI", body, s + 40)
                    if u32(body, s + 64) & 0xFF not in S_ZEROFILL_TYPES:
                        content_end = max(content_end, offset + size)
            elif filesize:
                if any(data[fileoff:fileoff + filesize]):
                    fail("segment %s has non-zero file content" % segname.decode())
                # All zero (a GOT bound at load time, bss): the kernel's zero fill gives the
                # same bytes. File offset 0 keeps fileoff + filesize inside the smaller file.
                body[40:56] = struct.pack("<QQ", 0, 0)
                for i in range(u32(body, 64)):  # no file bytes left for its sections
                    body[72 + 80 * i + 48:72 + 80 * i + 52] = struct.pack("<I", 0)
            else:
                body[40:48] = struct.pack("<Q", 0)
        out_cmds.append((cmd, body))
    if text is None:
        fail("no __TEXT segment")
    segs = [i for i, (cmd, _) in enumerate(out_cmds) if cmd == LC_SEGMENT_64]
    if binds and linkedit != segs[-1]:
        fail("__LINKEDIT is not the last segment")  # bind opcodes name segments by index

    # The folded signature goes right after __TEXT's content: make sure nothing else is
    # there (ld puts all of __TEXT's content in sections; a hand-made file may not).
    tail = bytearray(data[content_end:text_file])
    for cmd, body in cmds:
        if cmd == LC_CODE_SIGNATURE:
            off, size = struct.unpack_from("<II", body, 8)
            lo, hi = max(off - content_end, 0), max(off + size - content_end, 0)
            tail[lo:hi] = b"\0" * len(tail[lo:hi])
    if any(tail):
        fail("__TEXT has content after its last section")

    # Without imports, dyld needs neither the dyld info nor __LINKEDIT.
    if not binds:
        out_cmds = [c for i, c in enumerate(out_cmds) if i not in (info, linkedit)]
        text -= sum(1 for i in (info, linkedit) if i is not None and i < text)
        info = linkedit = None
    elif info is None or linkedit is None:
        fail("bind opcodes without LC_DYLD_INFO or __LINKEDIT")

    if full_hash:
        ident, superblob = "", False          # one NUL: the shortest identifier accepted
        text_fsize = max(text_file, PAGE)
        le_off = text_fsize
        sig_off = le_off + ((len(binds) + 15) & ~15 if binds else 0)
    else:
        ident, superblob = old_identifier(data, cmds) or name, True
        sig_off = (content_end + 15) & ~15
        text_fsize = sig_off
        le_off = PAGE
    sig_size = len(code_signature(b"\0" * sig_off, ident, 0, superblob))
    if not full_hash and sig_off + sig_size > PAGE:
        fail("__TEXT content and signature don't fit in one page")

    out_cmds.append((LC_CODE_SIGNATURE, bytearray(struct.pack("<IIII", LC_CODE_SIGNATURE, 16, sig_off, sig_size))))
    tbody = out_cmds[text][1]
    vmsize, = struct.unpack_from("<Q", tbody, 32)
    tbody[32:56] = struct.pack("<QQQ", max(vmsize, PAGE), 0, text_fsize)
    if binds:
        le_end = sig_off + sig_size if full_hash else le_off + len(binds)
        out_cmds[linkedit][1][40:56] = struct.pack("<QQ", le_off, le_end - le_off)
        out_cmds[info][1][8:48] = struct.pack("<10I", 0, 0, le_off, len(binds), 0, 0, 0, 0, 0, 0)

    new_cmds = b"".join(body for _, body in out_cmds)
    if 32 + len(new_cmds) > 32 + sizeofcmds:
        fail("load commands grew")
    head = bytearray(data[:32])
    struct.pack_into("<II", head, 16, len(out_cmds), len(new_cmds))
    page = bytearray(data[:content_end])
    page[:32 + sizeofcmds] = (head + new_cmds).ljust(32 + sizeofcmds, b"\0")
    if full_hash:
        body = page.ljust(text_fsize, b"\0")
        if binds:
            body += binds
    else:
        body = page
    body = bytes(body.ljust(sig_off, b"\0"))
    out = body + code_signature(body, ident, text_fsize, superblob)
    if not full_hash:
        out = out.ljust(PAGE, b"\0") + binds
    return out


def main():
    args = sys.argv[1:]
    full_hash = bool(args) and args[0] == "--full-hash"
    if full_hash:
        args = args[1:]
    if len(args) != 2:
        sys.exit(__doc__.split("\n\n")[1])
    src, dst = args
    with open(src, "rb") as f:
        data = f.read()
    out = pack(data, os.path.basename(dst), full_hash)
    # A new inode: the kernel caches code signatures per vnode, so rewriting a signed file
    # in place can get the new one killed.
    if os.path.exists(dst):
        os.unlink(dst)
    with open(dst, "wb") as f:
        f.write(out)
    os.chmod(dst, 0o755)


if __name__ == "__main__":
    main()
