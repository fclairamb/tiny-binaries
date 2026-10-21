#!/usr/bin/env python3
"""Strip an arm64 Mach-O executable's __LINKEDIT down to what dyld needs, and re-sign it.

Usage: machostrip.py <in> <out>

ld's __LINKEDIT holds, besides the fixups dyld applies at launch, a symbol table, an
indirect symbol table, an export trie and ld's own signature (4 KiB hash pages, the file
name as identifier). A main executable needs none of the tables to run. This tool keeps
every segment and section byte for byte and rebuilds __LINKEDIT at the same file offset
with only:

- the fixups: the dyld info opcodes (rebase, bind, weak bind, lazy bind) or the chained
  fixups blob, copied verbatim,
- a new ad-hoc signature: a SuperBlob holding one CodeDirectory (version 0x20400,
  SHA-256, 16 KiB hash pages, a one-byte empty identifier), the same form as ld's own
  signature with shorter pages and no file name. `codesign --verify --strict` accepts it.

It drops LC_SYMTAB, LC_DYSYMTAB, the export trie, function starts and data in code, so
nothing can dlsym() into the result and crash logs show no symbol names. It refuses load
commands it doesn't know, fat or non-arm64 files, and a __LINKEDIT that is not the last
segment. It contains nothing specific to any program.
"""
import hashlib
import os
import struct
import sys

MH_MAGIC_64, CPU_TYPE_ARM64, MH_EXECUTE = 0xFEEDFACF, 0x0100000C, 2
LC_SEGMENT_64, LC_SYMTAB, LC_DYSYMTAB, LC_CODE_SIGNATURE = 0x19, 0x2, 0xB, 0x1D
LC_DYLD_INFO, LC_DYLD_INFO_ONLY = 0x22, 0x80000022
LC_FUNCTION_STARTS, LC_DATA_IN_CODE = 0x26, 0x29
LC_DYLD_EXPORTS_TRIE, LC_DYLD_CHAINED_FIXUPS = 0x80000033, 0x80000034
DROP = {LC_SYMTAB, LC_DYSYMTAB, LC_CODE_SIGNATURE, LC_FUNCTION_STARTS, LC_DATA_IN_CODE,
        LC_DYLD_EXPORTS_TRIE}
# Commands with no __LINKEDIT payload: dylinker, uuid, build version, version min, source
# version, main, (weak/reexport/upward) load dylib, rpath, linker option.
KEEP = {LC_SEGMENT_64, 0xE, 0x1B, 0x32, 0x24, 0x2A, 0x80000028, 0xC, 0x80000018, 0x8000001F,
        0x80000023, 0x8000001C, 0x2D}
PAGE, PAGE_SHIFT = 0x4000, 14


def fail(msg):
    sys.exit("machostrip: " + msg)


def signature(data, exec_base, exec_limit):
    n = (len(data) + PAGE - 1) // PAGE
    hashes = b"".join(hashlib.sha256(data[i * PAGE:(i + 1) * PAGE]).digest() for i in range(n))
    cd = struct.pack(">IIIIIIIIIBBBBIIIIQQQQ",
                     0xFADE0C02, 89 + len(hashes), 0x20400, 0x2,  # magic, length, version, adhoc
                     89, 88,                      # hashOffset, identOffset (one NUL)
                     0, n, len(data),             # nSpecialSlots, nCodeSlots, codeLimit
                     32, 2, 0, PAGE_SHIFT,        # hashSize, SHA-256, platform, pageSize
                     0, 0, 0, 0, 0,               # spare2, scatter, team, spare3, codeLimit64
                     exec_base, exec_limit, 1)    # execSegBase, execSegLimit, MAIN_BINARY
    cd += b"\0" + hashes
    return struct.pack(">IIIII", 0xFADE0CC0, 20 + len(cd), 1, 0, 20) + cd  # one slot: the CD


def strip(data):
    magic, cputype, _, filetype, ncmds, sizeofcmds = struct.unpack_from("<IiIIII", data, 0)
    if magic != MH_MAGIC_64 or cputype != CPU_TYPE_ARM64 or filetype != MH_EXECUTE:
        fail("not an arm64 Mach-O executable")
    cmds, off = [], 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, off)
        cmds.append((cmd, bytearray(data[off:off + size])))
        off += size

    segs = [(i, bytes(b[8:24]).rstrip(b"\0")) for i, (c, b) in enumerate(cmds) if c == LC_SEGMENT_64]
    if not segs or segs[-1][1] != b"__LINKEDIT":
        fail("__LINKEDIT is not the last segment")
    le = cmds[segs[-1][0]][1]
    le_off, le_size = struct.unpack_from("<QQ", le, 40)
    for i, name in segs[:-1]:
        fo, fs = struct.unpack_from("<QQ", cmds[i][1], 40)
        if fs and fo + fs > le_off:
            fail("segment %s ends after __LINKEDIT starts" % name.decode())
    text = [cmds[i][1] for i, name in segs if name == b"__TEXT"]
    if len(text) != 1:
        fail("need exactly one __TEXT segment")
    text_off, text_size = struct.unpack_from("<QQ", text[0], 40)

    # New __LINKEDIT: the fixups, each 8-byte aligned, then the signature.
    linkedit = bytearray()

    def keep(o, n):
        if n == 0:
            return 0
        if o < le_off or o + n > le_off + le_size:
            fail("fixups outside __LINKEDIT")
        linkedit.extend(b"\0" * (-len(linkedit) % 8))
        at = le_off + len(linkedit)
        linkedit.extend(data[o:o + n])
        return at

    out_cmds = []
    for cmd, body in cmds:
        if cmd in DROP:
            continue
        if cmd in (LC_DYLD_INFO, LC_DYLD_INFO_ONLY):
            f = list(struct.unpack_from("<10I", body, 8))
            for k in range(4):  # rebase, bind, weak bind, lazy bind; not the export trie
                f[2 * k] = keep(f[2 * k], f[2 * k + 1])
            f[8] = f[9] = 0
            body[8:48] = struct.pack("<10I", *f)
        elif cmd == LC_DYLD_CHAINED_FIXUPS:
            o, n = struct.unpack_from("<II", body, 8)
            body[8:12] = struct.pack("<I", keep(o, n))
        elif cmd not in KEEP:
            fail("unknown load command 0x%x" % cmd)
        out_cmds.append((cmd, body))

    linkedit.extend(b"\0" * (-len(linkedit) % 16))
    sig_off = le_off + len(linkedit)
    sig_len = len(signature(bytes(sig_off), 0, 0))
    out_cmds.append((LC_CODE_SIGNATURE, bytearray(struct.pack("<IIII", LC_CODE_SIGNATURE, 16, sig_off, sig_len))))
    le_fsize = len(linkedit) + sig_len
    le[40:56] = struct.pack("<QQ", le_off, le_fsize)
    le[32:40] = struct.pack("<Q", (le_fsize + PAGE - 1) // PAGE * PAGE)

    new_cmds = b"".join(b for _, b in out_cmds)
    if len(new_cmds) > sizeofcmds:
        fail("load commands grew")
    out = bytearray(data[:le_off])
    struct.pack_into("<II", out, 16, len(out_cmds), len(new_cmds))
    out[32:32 + sizeofcmds] = new_cmds.ljust(sizeofcmds, b"\0")
    out += linkedit
    return bytes(out) + signature(bytes(out), text_off, text_size)


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__.split("\n\n")[1])
    with open(sys.argv[1], "rb") as f:
        out = strip(f.read())
    dst = sys.argv[2]
    # A new inode: the kernel caches code signatures per vnode, so rewriting a signed file
    # in place can get the new one killed.
    if os.path.exists(dst):
        os.unlink(dst)
    with open(dst, "wb") as f:
        f.write(out)
    os.chmod(dst, 0o755)


if __name__ == "__main__":
    main()
