"""Helpers for machofold.py: parse an arm64 Mach-O executable, classify its
load commands, and write an ad-hoc code signature.

Nothing here holds bytes of any program; everything is read from the file.
"""
import hashlib
import os
import struct

PAGE = 0x4000  # arm64 macOS page size: segments are mapped at this granularity

MH_MAGIC_64 = 0xFEEDFACF
CPU_TYPE_ARM64 = 0x0100000C
MH_EXECUTE = 2

LC_SEGMENT_64 = 0x19
LC_SYMTAB = 0x02
LC_DYSYMTAB = 0x0B
LC_DYLD_INFO = 0x22
LC_DYLD_INFO_ONLY = 0x80000022
LC_CODE_SIGNATURE = 0x1D
LC_DYLD_CHAINED_FIXUPS = 0x80000034

# linkedit_data_command (dataoff at +8, datasize at +12), all pointing into
# __LINKEDIT: code signature, split info, function starts, data in code,
# dylib code sign DRs, linker optimization hints, exports trie, chained
# fixups, atom info.
LINKEDIT_DATA = {0x1D, 0x1E, 0x26, 0x29, 0x2B, 0x2E, 0x80000033, 0x80000034, 0x36}

# Load commands that hold no file offset, or only offsets into the header
# segment (LC_MAIN entryoff, LC_ENCRYPTION_INFO_64 cryptoff), which the tools
# never move: dylinker, uuid, build/min version, source version, main, the
# dylib and rpath commands, dyld environment, unixthread, linker option,
# encryption info.
NO_OFFSETS = {0x0E, 0x1B, 0x32, 0x24, 0x2A, 0x80000028, 0x0C, 0x80000018,
              0x8000001F, 0x20, 0x80000023, 0x8000001C, 0x27, 0x05, 0x2D, 0x2C}

# File-offset fields (byte offset inside the command) of the commands that
# point into __LINKEDIT.
OFFSET_FIELDS = {
    LC_SYMTAB: (8, 16),                         # symoff, stroff
    LC_DYSYMTAB: (32, 40, 48, 56, 64, 72),      # toc, modtab, extrefsym, indirectsym, extrel, locrel
    LC_DYLD_INFO: (8, 16, 24, 32, 40),          # rebase, bind, weak_bind, lazy_bind, export
    LC_DYLD_INFO_ONLY: (8, 16, 24, 32, 40),
}
for _c in LINKEDIT_DATA:
    OFFSET_FIELDS[_c] = (8,)


class Segment:
    def __init__(self, d, off):
        self.off = off  # offset of the load command
        self.name = bytes(d[off + 8:off + 24]).rstrip(b"\0")
        self.vmaddr, self.vmsize, self.fileoff, self.filesize = struct.unpack_from("<QQQQ", d, off + 24)
        self.nsects = struct.unpack_from("<I", d, off + 64)[0]

    def sections(self, d):
        """(header offset, file offset, size, flags) of each section."""
        out = []
        for i in range(self.nsects):
            s = self.off + 72 + 80 * i
            size = struct.unpack_from("<Q", d, s + 40)[0]
            foff = struct.unpack_from("<I", d, s + 48)[0]
            flags = struct.unpack_from("<I", d, s + 64)[0]
            out.append((s, foff, size, flags))
        return out


def is_zerofill(flags):
    return (flags & 0xFF) in (0x1, 0xC, 0x12)  # S_ZEROFILL, S_GB_ZEROFILL, S_THREAD_LOCAL_ZEROFILL


def parse(d):
    """Check this is a thin arm64 MH_EXECUTE and return (commands, segments).

    commands is a list of (cmd, cmdsize, offset). Exits with an error on any
    load command the tools do not know, rather than guessing.
    """
    if len(d) < 32 or struct.unpack_from("<I", d, 0)[0] != MH_MAGIC_64:
        raise SystemExit("not a thin 64-bit Mach-O")
    cputype, _, filetype, ncmds, sizeofcmds = struct.unpack_from("<IIIII", d, 4)
    if cputype != CPU_TYPE_ARM64 or filetype != MH_EXECUTE:
        raise SystemExit("not an arm64 executable")
    cmds, segs = [], []
    off = 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", d, off)
        if size < 8 or off + size > 32 + sizeofcmds:
            raise SystemExit("malformed load command at %d" % off)
        if cmd == LC_SEGMENT_64:
            segs.append(Segment(d, off))
        elif cmd not in NO_OFFSETS and cmd not in OFFSET_FIELDS:
            raise SystemExit("unsupported load command 0x%x" % cmd)
        cmds.append((cmd, size, off))
        off += size
    return cmds, segs


def adhoc_sign(data, ident, execseg_limit, hash_size=32):
    """Ad-hoc signature blob (16 KB pages) covering all of `data`: one
    CodeDirectory, no requirements. hash_size 32 is SHA-256; 20 is SHA-256
    truncated to 20 bytes (CS_HASHTYPE_SHA256_TRUNCATED in xnu's cs_blobs.h,
    which codesign reads as "sha256T" but never writes)."""
    hash_type = {32: 2, 20: 3}[hash_size]
    hashes = b"".join(hashlib.sha256(data[i:i + PAGE]).digest()[:hash_size]
                      for i in range(0, len(data), PAGE))
    ident_b = ident.encode() + b"\0"
    hdrlen = 88  # CodeDirectory header, version 0x20400 (has execSeg fields)
    hashoff = hdrlen + len(ident_b)
    cdlen = hashoff + len(hashes)
    cd = struct.pack(">IIIIIIIIIBBBBI", 0xFADE0C02, cdlen, 0x20400,
                     0x20002,  # flags: adhoc | linker-signed
                     hashoff, hdrlen, 0, len(hashes) // hash_size, len(data),
                     hash_size, hash_type, 0, 14, 0)  # platform, log2(page), spare
    cd += struct.pack(">IIIQ", 0, 0, 0, 0)  # scatter, team, spare3, codeLimit64
    cd += struct.pack(">QQQ", 0, execseg_limit, 1)  # execSeg base, limit, MAIN_BINARY
    cd += ident_b + hashes
    return struct.pack(">IIIII", 0xFADE0CC0, 20 + cdlen, 1, 0, 20) + cd


def write_out(path, data):
    if os.path.exists(path):
        os.unlink(path)  # a fresh inode: the kernel caches signatures per vnode
    with open(path, "wb") as f:
        f.write(data)
    os.chmod(path, 0o755)
