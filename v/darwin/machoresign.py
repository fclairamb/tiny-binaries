#!/usr/bin/env python3
"""Replace an arm64 Mach-O's embedded code signature with a bare CodeDirectory.

Usage: machoresign.py <file>   (rewrites the file in place)

For a dyld-linked executable that keeps its __LINKEDIT (it has imports or rebases, so it
can't be folded by machopack.py), the smallest valid ad-hoc signature is a single bare
CodeDirectory: version 0x20400 (carries the exec-segment range AMFI needs on a main
binary), SHA-256, and 16 KiB hash pages so one hash covers each VM page. `codesign -s -`
instead emits an embedded-signature SuperBlob that also wraps an internal requirements
blob and an empty CMS slot, which the kernel does not need. This tool keeps everything
else byte for byte and only swaps the signature, then trims __LINKEDIT and the file.

It expects an existing LC_CODE_SIGNATURE (run `codesign -s - -f -i x` first so the load
command and __LINKEDIT layout are already in place); it changes no load-command sizes, so
nothing moves. It is generic: it reads the signed range, the exec segment and the
__LINKEDIT bounds from the file and contains no bytes of any program. The kernel accepts a
raw CSMAGIC_CODEDIRECTORY as well as the SuperBlob form (xnu ubc_subr.c cs_validate_csblob),
but Apple's codesign tool can only parse the SuperBlob, so a re-signed file no longer
verifies with `codesign -v` even though it launches.
"""
import hashlib
import os
import struct
import sys

MH_MAGIC_64 = 0xFEEDFACF
LC_SEGMENT_64, LC_CODE_SIGNATURE = 0x19, 0x1D
PAGE_SHIFT = 14  # 16 KiB hash pages


def fail(msg):
    sys.exit("machoresign: " + msg)


def cd_length(code_limit):
    """Byte length of the bare CodeDirectory for this signed range (no hashing needed)."""
    n = (code_limit + (1 << PAGE_SHIFT) - 1) >> PAGE_SHIFT
    return 88 + 1 + 32 * n  # header + 1-byte NUL identifier + one SHA-256 per 16 KiB page


def bare_cd(data, code_limit, exec_base, exec_limit):
    page = 1 << PAGE_SHIFT
    n = (code_limit + page - 1) // page
    hashes = b"".join(hashlib.sha256(data[i * page:(i + 1) * page]).digest() for i in range(n))
    ident = b"\0"  # identOffset must be non-zero; one NUL is the shortest the kernel accepts
    hdr = 88
    cd_len = hdr + len(ident) + len(hashes)
    cd = struct.pack(">IIIIIIIIIBBBBIIIIQQQQ",
                     0xFADE0C02, cd_len, 0x20400, 0x2,
                     hdr + len(ident), hdr,       # hashOffset, identOffset
                     0, n, code_limit,            # nSpecialSlots, nCodeSlots, codeLimit
                     32, 2, 0, PAGE_SHIFT,        # hashSize, SHA-256, platform, pageSize
                     0, 0, 0, 0, 0,               # spare2, scatter, team, spare3, codeLimit64
                     exec_base, exec_limit, 1)    # execSegBase, execSegLimit, MAIN_BINARY
    return cd + ident + hashes


def resign(path):
    data = bytearray(open(path, "rb").read())
    magic, _, _, _, ncmds = struct.unpack_from("<IiiII", data, 0)
    if magic != MH_MAGIC_64:
        fail("not a 64-bit Mach-O")
    sig_lc = linkedit = text = None
    o = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, o)
        if cmd == LC_CODE_SIGNATURE:
            sig_lc = o
        elif cmd == LC_SEGMENT_64:
            name = data[o + 8:o + 24].rstrip(b"\0")
            if name == b"__LINKEDIT":
                linkedit = o
            elif name == b"__TEXT":
                text = o
        o += size
    if sig_lc is None or linkedit is None or text is None:
        fail("need LC_CODE_SIGNATURE, __TEXT and __LINKEDIT (run codesign -s - first)")

    dataoff, datasize = struct.unpack_from("<II", data, sig_lc + 8)
    text_fileoff, text_filesize = struct.unpack_from("<QQ", data, text + 40)
    le_vmaddr, le_vmsize, le_fileoff, le_filesize = struct.unpack_from("<QQQQ", data, linkedit + 24)

    # The LC_CODE_SIGNATURE and __LINKEDIT load commands sit in page 0, inside the signed
    # range [0, dataoff). Edit them to their final values BEFORE hashing, or page 0's hash
    # will not match the launched header. The new signature length is fixed by the range.
    sig_len = cd_length(dataoff)
    end = dataoff + sig_len
    signed = bytearray(data[:dataoff])
    struct.pack_into("<II", signed, sig_lc + 8, dataoff, sig_len)
    new_fsize = end - le_fileoff
    new_vsize = (new_fsize + 0x3FFF) & ~0x3FFF
    struct.pack_into("<QQ", signed, linkedit + 32, new_vsize, le_fileoff)
    struct.pack_into("<Q", signed, linkedit + 48, new_fsize)

    sig = bare_cd(signed, dataoff, text_fileoff, text_filesize)
    assert len(sig) == sig_len, (len(sig), sig_len)
    out = bytes(signed) + sig

    tmp = path + ".resign.tmp"
    with open(tmp, "wb") as f:
        f.write(out)
    os.chmod(tmp, 0o755)
    os.replace(tmp, path)  # a fresh inode: the kernel caches signatures per vnode


def main():
    if len(sys.argv) != 2:
        sys.exit(__doc__.split("\n\n")[1])
    resign(sys.argv[1])


if __name__ == "__main__":
    main()
