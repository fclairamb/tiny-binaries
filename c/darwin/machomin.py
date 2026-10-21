#!/usr/bin/env python3
"""machomin.py [--strict] [--ident ID] IN OUT

Shrink a linked arm64 macOS executable that imports nothing (no dyld fixups,
no file content outside its header segment) to the smallest file the kernel
runs, with a fresh ad-hoc code signature.

Such a program needs nothing from __LINKEDIT at run time except its code
signature. The tool keeps every other load command and the whole layout of
the header segment (__TEXT) as the linker made it, so no code or data moves,
and it:

  - drops __LINKEDIT and the load commands that only point into it (symbol
    tables, exports trie, empty chained fixups, function starts, data in
    code, the old signature),
  - gives zero-fill segments (bss) file offset 0, so they stay valid in the
    shorter file,
  - writes a new ad-hoc signature: one CodeDirectory (version 0x20400,
    truncated SHA-256, 16 KiB hash pages, at least 112 bytes long) in a
    SuperBlob, so `codesign` can read and verify it.

Two layouts:

  default   The signature goes inside the last page of __TEXT, right after
            the last section. codeLimit stops at the signature, so that page
            is only partly hashed. The file is __TEXT rounded up to 16 KiB:
            16384 bytes for a small program. The kernel runs it, but this
            relies on undocumented behaviour (see c/darwin/README.md), and
            `codesign --verify --strict` rejects it.
  --strict  __TEXT keeps whole 16 KiB pages and every byte of them is hashed.
            The signature lives in a minimal __LINKEDIT segment after them,
            the layout ld itself produces. `codesign --verify --strict`
            accepts it. Costs the signature size on top of the pages.

It refuses (exits non-zero) any input it cannot shrink without changing
what the program does. It holds no bytes of any program.
"""
import hashlib
import os
import struct
import sys

PAGE = 0x4000  # arm64 macOS VM page
PAGE_SHIFT = 14
HASH_SIZE = 20  # SHA-256 truncated to 160 bits
CD_MIN = 112    # smaller CodeDirectories are SIGKILLed
MH_MAGIC_64, CPU_TYPE_ARM64, MH_EXECUTE = 0xFEEDFACF, 0x0100000C, 2
MH_DYLDLINK, MH_PIE = 0x4, 0x200000
LC_SEGMENT_64, LC_SYMTAB, LC_DYSYMTAB = 0x19, 0x2, 0xB
LC_CODE_SIGNATURE, LC_FUNCTION_STARTS, LC_DATA_IN_CODE = 0x1D, 0x26, 0x29
LC_DYLD_INFO, LC_DYLD_INFO_ONLY = 0x22, 0x80000022
LC_DYLD_EXPORTS_TRIE, LC_DYLD_CHAINED_FIXUPS = 0x80000033, 0x80000034
# Commands that hold no file offset: dylinker, uuid, build version, macOS
# version min, source version, main (its entryoff is in __TEXT, which never
# moves), load dylib, load weak dylib, rpath.
KEEP = {0xE, 0x1B, 0x32, 0x24, 0x2A, 0x80000028, 0xC, 0x80000018, 0x8000001C}
# Commands whose data lives in __LINKEDIT and that a program without fixups
# does not need once its contents have been checked.
DROP = {LC_SYMTAB, LC_DYSYMTAB, LC_CODE_SIGNATURE, LC_FUNCTION_STARTS, LC_DATA_IN_CODE,
        LC_DYLD_INFO, LC_DYLD_INFO_ONLY, LC_DYLD_EXPORTS_TRIE, LC_DYLD_CHAINED_FIXUPS}
ZEROFILL = {0x1, 0xC, 0x12}           # S_ZEROFILL, S_GB_ZEROFILL, S_THREAD_LOCAL_ZEROFILL
IMPORT_SECTIONS = {0x6, 0x7, 0x8, 0x10, 0x11, 0x13, 0x14, 0x15}  # GOT, lazy ptrs, stubs, TLV


def fail(msg):
    sys.exit("machomin: refusing input: " + msg)


def u32(b, o):
    return struct.unpack_from("<I", b, o)[0]


def align(x, a):
    return (x + a - 1) // a * a


def check_chained_fixups(b, off, size):
    if size < 28 or off + size > len(b):
        fail("truncated chained fixups")
    starts, imports_count = u32(b, off + 4), u32(b, off + 16)
    if imports_count:
        fail("it imports symbols (chained fixups)")
    if not starts:
        return
    s = off + starts                        # dyld_chained_starts_in_image
    for i in range(u32(b, s)):
        so = u32(b, s + 4 + 4 * i)
        if not so:
            continue
        seg = s + so                        # dyld_chained_starts_in_segment
        for p in range(struct.unpack_from("<H", b, seg + 20)[0]):
            if struct.unpack_from("<H", b, seg + 22 + 2 * p)[0] != 0xFFFF:
                fail("it has chained fixups (rebases or binds)")


def check_symtab(b, off):
    symoff, nsyms = u32(b, off + 8), u32(b, off + 12)
    for i in range(nsyms):
        n_type = b[symoff + 16 * i + 4]
        if not n_type & 0xE0 and n_type & 0xE == 0 and n_type & 1:  # N_UNDF | N_EXT
            fail("it has undefined symbols")


def parse(b):
    if len(b) < 32 or u32(b, 0) != MH_MAGIC_64:
        fail("not a thin 64-bit Mach-O")
    cputype, _, filetype, ncmds, sizeofcmds, flags = struct.unpack_from("<IIIIII", b, 4)
    if cputype != CPU_TYPE_ARM64 or filetype != MH_EXECUTE:
        fail("not an arm64 executable")
    if flags & (MH_DYLDLINK | MH_PIE) != MH_DYLDLINK | MH_PIE:
        fail("not a dyld-linked PIE executable")
    cmds, off = [], 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", b, off)
        if size < 8 or off + size > 32 + sizeofcmds:
            fail("malformed load command at offset %d" % off)
        if cmd not in KEEP and cmd not in DROP and cmd != LC_SEGMENT_64:
            fail("unknown load command 0x%x" % cmd)
        cmds.append((cmd, off, size))
        off += size
    return cmds, sizeofcmds


def check_no_fixups(b, cmds):
    for cmd, off, _ in cmds:
        if cmd == LC_DYLD_CHAINED_FIXUPS:
            check_chained_fixups(b, u32(b, off + 8), u32(b, off + 12))
        elif cmd in (LC_DYLD_INFO, LC_DYLD_INFO_ONLY):
            if any(u32(b, off + f) for f in (12, 20, 28, 36)):  # rebase, bind, weak, lazy sizes
                fail("it has dyld rebases or binds")
        elif cmd == LC_DYSYMTAB:
            if any(u32(b, off + f) for f in (28, 60, 68, 76)):  # nundefsym, nindirect, nextrel, nlocrel
                fail("it has undefined symbols, indirect symbols or relocations")
        elif cmd == LC_SYMTAB:
            check_symtab(b, off)


def segments(b, cmds):
    """Return (header segment, other segment commands), checking file content."""
    header, others = None, []
    for cmd, off, size in cmds:
        if cmd != LC_SEGMENT_64:
            continue
        name = b[off + 8:off + 24].rstrip(b"\0")
        fileoff, filesize = struct.unpack_from("<QQ", b, off + 40)
        nsects = u32(b, off + 64)
        for i in range(nsects):
            s = off + 72 + 80 * i
            sflags = u32(b, s + 64)
            if sflags & 0xFF in IMPORT_SECTIONS or u32(b, s + 60):  # type, nreloc
                fail("section %s has stubs, pointers or relocations"
                     % b[s:s + 16].rstrip(b"\0").decode())
        if name == b"__LINKEDIT":
            continue
        if fileoff == 0 and filesize:
            header = (off, nsects)
        elif filesize:
            fail("segment %s has file content outside the header segment" % name.decode())
        others.append(off)
    if header is None:
        fail("no segment maps the header")
    return header, others


def code_directory(code, code_limit, exec_limit, ident):
    """Ad-hoc CodeDirectory over code[:code_limit]: version 0x20400, 16 KiB pages,
    SHA-256 truncated to 20 bytes (CS_HASHTYPE_SHA256_TRUNCATED), padded to the
    112 bytes the kernel wants at least (sizeof the 0x20600 CodeDirectory)."""
    hashes = b"".join(hashlib.sha256(code[i:min(i + PAGE, code_limit)]).digest()[:HASH_SIZE]
                      for i in range(0, code_limit, PAGE))
    ident = ident.encode() + b"\0"
    hash_off = max(88 + len(ident), CD_MIN - len(hashes))
    cd = struct.pack(">IIIIIIIIIBBBBI", 0xFADE0C02, hash_off + len(hashes), 0x20400,
                     0x2,                                # flags: adhoc
                     hash_off, 88, 0, len(hashes) // HASH_SIZE, code_limit,
                     HASH_SIZE, 3, 0, PAGE_SHIFT, 0)     # SHA-256 truncated, platform, page
    cd += struct.pack(">IIIQ", 0, 0, 0, 0)               # scatter, team, spare3, codeLimit64
    cd += struct.pack(">QQQ", 0, exec_limit, 1)          # execSeg base, limit, MAIN_BINARY
    return (cd + ident).ljust(hash_off, b"\0") + hashes


def signature(code, code_limit, exec_limit, ident):
    cd = code_directory(code, code_limit, exec_limit, ident)
    # SuperBlob with one index entry: CSSLOT_CODEDIRECTORY at offset 20.
    return struct.pack(">IIIII", 0xFADE0CC0, 20 + len(cd), 1, 0, 20) + cd


def shrink(b, strict, ident):
    cmds, sizeofcmds = parse(b)
    check_no_fixups(b, cmds)
    (hoff, nsects), others = segments(b, cmds)

    # New load commands: the kept ones, in order, then a fresh LC_CODE_SIGNATURE
    # (and in strict mode a __LINKEDIT segment for it). __LINKEDIT's own command is
    # reused in strict mode, so the block never outgrows the old one.
    linkedit = next((off for cmd, off, _ in cmds if cmd == LC_SEGMENT_64
                     and b[off + 8:off + 24].rstrip(b"\0") == b"__LINKEDIT"), None)
    blk, ncmds, seg_at, le_at = bytearray(), 0, {}, None
    for cmd, off, size in cmds:
        if cmd in DROP or (cmd == LC_SEGMENT_64 and off == linkedit and not strict):
            continue
        if cmd == LC_SEGMENT_64:
            seg_at[off] = len(blk)
            if off == linkedit:
                le_at = len(blk)
        blk += b[off:off + size]
        ncmds += 1
    cs_at = len(blk)
    blk += struct.pack("<IIII", LC_CODE_SIGNATURE, 16, 0, 0)
    ncmds += 1
    if strict and le_at is None:
        fail("no __LINKEDIT segment to hold the signature")
    if len(blk) > sizeofcmds:
        fail("new load commands do not fit")

    # End of what the header segment really holds: the load commands and its
    # non-zero-fill sections. Everything after it must be zero, since it is dropped.
    end = 32 + len(blk)
    for i in range(nsects):
        s = hoff + 72 + 80 * i
        size, foff, sflags = struct.unpack_from("<Q", b, s + 40)[0], u32(b, s + 48), u32(b, s + 64)
        if sflags & 0xFF not in ZEROFILL:
            end = max(end, foff + size)
    hfilesize = struct.unpack_from("<Q", b, hoff + 48)[0]
    if hfilesize > len(b) or any(b[max(end, 32 + sizeofcmds):hfilesize]):
        fail("header segment has bytes outside its sections")

    out = bytearray(b[:end])
    out[32:32 + sizeofcmds] = bytes(sizeofcmds)
    out[32:32 + len(blk)] = blk
    struct.pack_into("<II", out, 16, ncmds, len(blk))
    for off in others:                               # zero-fill segments: file offset 0
        if off != hoff:
            struct.pack_into("<Q", out, 32 + seg_at[off] + 40, 0)

    if strict:
        code_limit = align(end, PAGE)
        sig_len = len(signature(bytes(code_limit), code_limit, code_limit, ident))
        o = 32 + le_at
        vmaddr = struct.unpack_from("<Q", out, o + 24)[0]
        struct.pack_into("<QQQQ", out, o + 24, vmaddr, align(sig_len, PAGE), code_limit, sig_len)
        hsize = code_limit
    else:
        code_limit = align(end, 16)
        sig_len = len(signature(bytes(code_limit), code_limit, 0, ident))
        hsize = align(code_limit + sig_len, PAGE)
    o = 32 + seg_at[hoff]
    if hsize > struct.unpack_from("<Q", out, o + 32)[0]:
        fail("no room for the signature inside the header segment")
    struct.pack_into("<QQ", out, o + 40, 0, hsize)   # fileoff, filesize
    struct.pack_into("<II", out, 32 + cs_at + 8, code_limit, sig_len)
    out += bytes(code_limit - len(out))
    sig = signature(bytes(out), code_limit, hsize, ident)
    out += sig
    out += bytes(hsize - len(out)) if not strict else b""
    return bytes(out)


def main():
    args, strict, ident = sys.argv[1:], False, None
    while args and args[0].startswith("--"):
        if args[0] == "--strict":
            strict, args = True, args[1:]
        elif args[0] == "--ident" and len(args) > 1:
            ident, args = args[1], args[2:]
        else:
            break
    if len(args) != 2:
        sys.exit(__doc__.split("\n")[0])
    src, dst = args
    out = shrink(open(src, "rb").read(), strict, os.path.basename(dst) if ident is None else ident)
    with open(dst, "wb") as f:
        f.write(out)
    os.chmod(dst, 0o755)
    print(len(out))


if __name__ == "__main__":
    main()
