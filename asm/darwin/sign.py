#!/usr/bin/env python3
"""Ad-hoc sign an arm64 Mach-O executable, putting the signature at the end of its last page.

Usage: sign.py <in> <out> [identifier]

<in> is a complete arm64 MH_EXECUTE image with an LC_CODE_SIGNATURE load command whose
dataoff and datasize are placeholders. The tool pads the image with zeros to the next 16 KiB
boundary that leaves room for the signature, writes the signature in the last bytes of that
page, and points LC_CODE_SIGNATURE at it. The signature is one CodeDirectory (version
0x20400, SHA-256, 16 KiB hash pages, no special slots) in a SuperBlob, the smallest form
both the kernel and codesign can read. codeLimit is where the signature starts, so every
byte before it is hashed, including the zero padding.

It reads every offset from the file and contains nothing specific to any program. It is
the same signature `codesign -s -` makes, minus the requirements and special slots, and
with the blob moved inside the last page instead of a separate __LINKEDIT segment.
"""
import hashlib
import os
import struct
import sys

PAGE = 0x4000  # arm64 macOS page: the kernel reads round_page(32 + sizeofcmds) bytes
PAGE_SHIFT = 14
LC_SEGMENT_64, LC_CODE_SIGNATURE = 0x19, 0x1D
VM_PROT_EXECUTE = 4


def fail(msg):
    sys.exit("sign.py: " + msg)


def signature_size(ident, nslots):
    return 20 + 88 + len(ident) + 32 * nslots  # SuperBlob + CodeDirectory + ident + hashes


def sign(data, ident):
    magic, cputype, _, filetype, ncmds, sizeofcmds = struct.unpack_from("<IiiIII", data)
    if magic != 0xFEEDFACF or cputype != 0x0100000C or filetype != 2:
        fail("not an arm64 Mach-O executable")
    if 32 + sizeofcmds > len(data):
        fail("load commands run past the end of the file")
    sig_cmd, segments, off = None, [], 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, off)
        if size < 8 or off + size > 32 + sizeofcmds:
            fail("bad load command size")
        if cmd == LC_CODE_SIGNATURE:
            if sig_cmd is not None:
                fail("more than one LC_CODE_SIGNATURE")
            sig_cmd = off
        elif cmd == LC_SEGMENT_64:
            segments.append(struct.unpack_from("<QQQQII", data, off + 24))
        off += size
    if sig_cmd is None:
        fail("no LC_CODE_SIGNATURE")
    exec_seg = [s for s in segments if s[2] == 0 and s[3] and s[5] & VM_PROT_EXECUTE]
    if len(exec_seg) != 1:
        fail("need exactly one executable segment mapping the header")
    exec_limit = exec_seg[0][3]

    ident = ident.encode() + b"\0"
    total = (len(data) + signature_size(ident, 1) + PAGE - 1) // PAGE * PAGE
    nslots = total // PAGE
    size = signature_size(ident, nslots)
    if size > PAGE - 16:
        fail("identifier too long")
    sig_off = (total - size) & ~15  # 16-byte aligned, ends within the last 16 bytes
    if sig_off < len(data):
        total += PAGE
        nslots += 1
        size = signature_size(ident, nslots)
        sig_off = (total - size) & ~15
    for vmaddr, vmsize, fileoff, filesize, _, _ in segments:
        if fileoff + filesize > total:
            fail("a segment maps bytes past the end of the signed file")

    body = bytearray(data.ljust(sig_off, b"\0"))
    struct.pack_into("<II", body, sig_cmd + 8, sig_off, size)
    hashes = b"".join(hashlib.sha256(body[i * PAGE:(i + 1) * PAGE]).digest() for i in range(nslots))
    cd_len = 88 + len(ident) + len(hashes)
    cd = struct.pack(">9I4B4I4Q",
                     0xFADE0C02, cd_len, 0x20400,
                     0x2,                         # flags: CS_ADHOC
                     88 + len(ident), 88,         # hashOffset, identOffset
                     0, nslots, sig_off,          # nSpecialSlots, nCodeSlots, codeLimit
                     32, 2, 0, PAGE_SHIFT,        # hashSize, SHA-256, platform, pageSize
                     0, 0, 0, 0, 0,               # spare2, scatter, team, spare3, codeLimit64
                     0, exec_limit, 1)            # execSegBase, Limit, CS_EXECSEG_MAIN_BINARY
    blob = struct.pack(">5I", 0xFADE0CC0, 20 + cd_len, 1, 0, 20) + cd + ident + hashes
    return bytes(body + blob).ljust(total, b"\0")


def main():
    if len(sys.argv) not in (3, 4):
        sys.exit(__doc__.split("\n\n")[1])
    with open(sys.argv[1], "rb") as f:
        data = f.read()
    out = sign(data, sys.argv[3] if len(sys.argv) == 4 else "")
    # A new inode: the kernel caches a signature per vnode, so a signed file rewritten in
    # place can be killed.
    if os.path.exists(sys.argv[2]):
        os.unlink(sys.argv[2])
    with open(sys.argv[2], "wb") as f:
        f.write(out)
    os.chmod(sys.argv[2], 0o755)


if __name__ == "__main__":
    main()
