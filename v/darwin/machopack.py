#!/usr/bin/env python3
"""Shrink a linked arm64 Mach-O executable to a single signed __TEXT page.

Usage: machopack.py [--partial] <in> <out>

ld always ends an executable with a __LINKEDIT segment (symbols, fixups, code signature)
that starts on a new 16 KiB page. When the program needs no dyld fixups (no imported
symbols, no rebases) and its only segment with file content is __TEXT, nothing in
__LINKEDIT is needed at run time except the code signature. This tool:

- drops __LINKEDIT and the load commands that point into it (symbol tables, exports trie,
  function starts, data in code, empty chained fixups, old signature),
- keeps every other load command and the __TEXT layout as is (no code or data moves),
- writes a fresh ad-hoc code signature and pads the file to the kernel's minimum.

Two layouts, both producing a file the kernel launches on arm64 macOS:

- default (fully hashed): __TEXT keeps the whole 16 KiB page ld gave it, and the
  signature sits right after it at offset 16384 with pageSize 14, so the one SHA-256 hash
  covers the entire executable page. This is the layout the C and Rust slices use; the
  file is 16384 + 121 = 16505 bytes. It relies only on documented behaviour: the kernel
  validates the whole code page and every byte of it is hashed.

- --partial (folded): __TEXT's file size is trimmed to the end of its last section and the
  signature is folded inside the executable page, with codeLimit far below 16 KiB. The
  file is exactly 16384 bytes. This is 121 bytes smaller, but the bytes of the page past
  codeLimit are never hashed yet still execute: an undocumented gap in Apple Silicon code
  signing (see darwin/README.md). Kept as the `extreme-partialpage` variant only.

It refuses inputs it can't fold without changing their behaviour. It contains nothing
specific to any program.
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
# Load commands whose payload lives in __LINKEDIT and that dyld doesn't need without fixups.
LINKEDIT_ONLY = {LC_SYMTAB, LC_DYSYMTAB, LC_CODE_SIGNATURE, LC_FUNCTION_STARTS, LC_DATA_IN_CODE,
                 LC_DYLD_EXPORTS_TRIE, LC_SEGMENT_SPLIT_INFO, LC_LINKER_OPTIMIZATION_HINT,
                 LC_ATOM_INFO, LC_DYLD_CHAINED_FIXUPS, LC_DYLD_INFO, LC_DYLD_INFO_ONLY}
S_ZEROFILL_TYPES = {0x1, 0xC, 0x12}  # S_ZEROFILL, S_GB_ZEROFILL, S_THREAD_LOCAL_ZEROFILL
PAGE = 0x4000            # arm64 VM page: the kernel reads this much of the header at once
FULL_PAGE_SHIFT = 14     # one SHA-256 hash covers the whole 16 KiB page (documented layout)
PARTIAL_PAGE_SHIFT = 12  # 4 KiB hash pages, as ld uses (folded layout only)


def fail(msg):
    sys.exit("machopack: " + msg)


def u32(b, o):
    return struct.unpack_from("<I", b, o)[0]


def check_no_fixups(data, cmd, body):
    """Fail unless the fixup information in this load command is empty."""
    if cmd == LC_DYLD_CHAINED_FIXUPS:
        off, size = struct.unpack_from("<II", body, 8)
        if size == 0:
            return
        _, starts, _, _, imports_count = struct.unpack_from("<IIIII", data, off)
        seg_count = u32(data, off + starts)
        seg_offsets = struct.unpack_from("<%dI" % seg_count, data, off + starts + 4)
        if imports_count or any(seg_offsets):
            fail("the program has dyld fixups (imports or rebases)")
    elif cmd in (LC_DYLD_INFO, LC_DYLD_INFO_ONLY):
        f = struct.unpack_from("<10I", body, 8)
        if f[1] or f[3] or f[5] or f[7]:  # rebase, bind, weak bind, lazy bind sizes
            fail("the program has dyld fixups (imports or rebases)")


def code_signature(data, ident, exec_limit, page_shift, flags, superblob):
    """Ad-hoc CodeDirectory (v0x20400, SHA-256) over all of data. Bare by default; wrapped
    in a SuperBlob when superblob is set (the only form codesign can parse)."""
    page = 1 << page_shift
    n = (len(data) + page - 1) // page
    hashes = b"".join(hashlib.sha256(data[i * page:(i + 1) * page]).digest() for i in range(n))
    ident = ident.encode() + b"\0"
    hdr = 88
    cd_len = hdr + len(ident) + len(hashes)
    cd = struct.pack(">IIIIIIIIIBBBBIIIIQQQQ",
                     0xFADE0C02, cd_len, 0x20400,
                     flags,                    # flags: adhoc (+ linker-signed for the fold)
                     hdr + len(ident), hdr,    # hashOffset, identOffset
                     0, n, len(data),          # nSpecialSlots, nCodeSlots, codeLimit
                     32, 2, 0, page_shift,     # hashSize, hashType SHA-256, platform, pageSize
                     0, 0, 0, 0, 0,            # spare2, scatter, team, spare3, codeLimit64
                     0, exec_limit, 1)         # execSegBase, execSegLimit, CS_EXECSEG_MAIN_BINARY
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


def pack(data, name, partial=False):
    magic, cputype, _, filetype, ncmds, sizeofcmds, _, _ = struct.unpack_from("<IiiIIIII", data, 0)
    if magic != MH_MAGIC_64 or cputype != CPU_TYPE_ARM64 or filetype != MH_EXECUTE:
        fail("not an arm64 Mach-O executable")
    cmds, off = [], 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, off)
        cmds.append((cmd, data[off:off + size]))
        off += size

    out_cmds, text, content_end, text_file = [], None, 0, 0
    for cmd, body in cmds:
        if cmd == LC_ENCRYPTION_INFO_64:
            fail("encrypted binaries are not supported")
        if cmd in LINKEDIT_ONLY:
            check_no_fixups(data, cmd, body)
            continue
        if cmd == LC_SEGMENT_64:
            name16 = body[8:24].rstrip(b"\0")
            fileoff, filesize = struct.unpack_from("<QQ", body, 40)
            nsects = u32(body, 64)
            if name16 == b"__LINKEDIT":
                continue
            if fileoff == 0 and filesize:
                if text is not None:
                    fail("more than one segment maps the file header")
                text = len(out_cmds)
                text_file = filesize
                content_end = max(content_end, 32 + sizeofcmds)
                for i in range(nsects):
                    s = 72 + 80 * i
                    size, offset = struct.unpack_from("<QI", body, s + 40)
                    if u32(body, s + 64) & 0xFF not in S_ZEROFILL_TYPES:
                        content_end = max(content_end, offset + size)
            elif filesize:
                fail("segment %s has file content outside __TEXT" % name16.decode())
            else:
                # Zero-fill only (bss): nothing to read from the file, so point it at offset 0
                # to keep fileoff + filesize inside the smaller file.
                body = body[:40] + struct.pack("<Q", 0) + body[48:]
        out_cmds.append((cmd, body))
    if text is None:
        fail("no __TEXT segment")

    # The signature goes right after __TEXT's content: make sure nothing else is there
    # (ld puts all of __TEXT's content in sections; a hand-made file may not).
    tail = bytearray(data[content_end:text_file])
    for cmd, body in cmds:
        if cmd == LC_CODE_SIGNATURE:
            off, size = struct.unpack_from("<II", body, 8)
            lo, hi = max(off - content_end, 0), max(off + size - content_end, 0)
            tail[lo:hi] = b"\0" * len(tail[lo:hi])
    if any(tail):
        fail("__TEXT has content after its last section")

    if partial:
        ident = old_identifier(data, cmds) or name
        page_shift, flags, superblob = PARTIAL_PAGE_SHIFT, 0x20002, True
        sig_off = (content_end + 15) & ~15
        text_fsize = sig_off
    else:
        # Fully hashed: keep ld's full 16 KiB __TEXT page and sign the whole of it.
        # A bare CodeDirectory with a one-byte NUL identifier, matching C and Rust.
        ident = ""
        page_shift, flags, superblob = FULL_PAGE_SHIFT, 0x2, False
        sig_off = max(text_file, PAGE)
        text_fsize = sig_off

    sig_size = len(code_signature(b"\0" * sig_off, ident, 0, page_shift, flags, superblob))
    # __TEXT's file part now ends where the signature begins; vmsize keeps its page.
    tcmd, tbody = out_cmds[text]
    vmsize, = struct.unpack_from("<Q", tbody, 32)
    vmsize = max(vmsize, sig_off)
    out_cmds[text] = (tcmd, tbody[:32] + struct.pack("<QQ", vmsize, 0) + struct.pack("<Q", text_fsize) + tbody[56:])
    out_cmds.append((LC_CODE_SIGNATURE, struct.pack("<IIII", LC_CODE_SIGNATURE, 16, sig_off, sig_size)))

    new_cmds = b"".join(body for _, body in out_cmds)
    hdr = bytearray(data[:32])
    struct.pack_into("<II", hdr, 16, len(out_cmds), len(new_cmds))
    end_cmds = 32 + len(new_cmds)
    body = bytearray(data[:sig_off].ljust(sig_off, b"\0"))
    body[:end_cmds] = hdr + new_cmds
    body[end_cmds:32 + sizeofcmds] = b"\0" * (32 + sizeofcmds - end_cmds)
    sig = code_signature(bytes(body), ident, sig_off, page_shift, flags, superblob)
    out = bytes(body) + sig
    return out + b"\0" * max(0, PAGE - len(out))


def main():
    args = sys.argv[1:]
    partial = False
    if args and args[0] == "--partial":
        partial = True
        args = args[1:]
    if len(args) != 2:
        sys.exit(__doc__.split("\n\n")[1])
    src, dst = args
    with open(src, "rb") as f:
        data = f.read()
    out = pack(data, os.path.basename(dst), partial)
    # A new inode: the kernel caches code signatures per vnode, so rewriting a signed file
    # in place can get the new one killed.
    if os.path.exists(dst):
        os.unlink(dst)
    with open(dst, "wb") as f:
        f.write(out)
    os.chmod(dst, 0o755)


if __name__ == "__main__":
    main()
