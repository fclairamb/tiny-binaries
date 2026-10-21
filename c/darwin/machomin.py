#!/usr/bin/env python3
"""machomin.py IN OUT [pageshift] -- shrink an arm64 Mach-O to a minimal signed layout.

Generic: it reads whatever __TEXT content and entry point the input holds, lays
them out under a fresh minimal set of load commands, and writes its own ad-hoc
code signature. It contains no bytes of any particular program; the code and
data come entirely from IN. Works on any dyld-linked arm64 Mach-O whose code is
position independent and imports nothing (so there is nothing to fix up).

On Apple Silicon the VM page is 16 KiB and the whole executable page must pass
code-signature validation, so the signed region is rounded up to a 16 KiB page.
"""
import hashlib, os, struct, sys

LC_SEGMENT_64, LC_LOAD_DYLINKER, LC_LOAD_DYLIB = 0x19, 0xe, 0xc
LC_UUID, LC_BUILD_VERSION, LC_MAIN, LC_CODE_SIGNATURE = 0x1b, 0x32, 0x80000028, 0x1d
MH_MAGIC_64, CPU_ARM64 = 0xfeedfacf, 0x0100000c
MH_EXECUTE, MH_NOUNDEFS, MH_DYLDLINK, MH_PIE = 2, 0x1, 0x4, 0x200000
VM_R, VM_X = 1, 4
VMPAGE = 0x4000  # 16 KiB


def align(x, a):
    return (x + a - 1) & ~(a - 1)


def read_macho(path):
    b = open(path, 'rb').read()
    magic, cput, csub, ftype, ncmds, scmds, flags, _ = struct.unpack_from('<IIIIIIII', b, 0)
    assert magic == MH_MAGIC_64, "not a 64-bit mach-o"
    secs, entry, o = [], None, 32
    for _ in range(ncmds):
        cmd, sz = struct.unpack_from('<II', b, o)
        if cmd == LC_SEGMENT_64:
            name = struct.unpack_from('<16s', b, o + 8)[0].rstrip(b'\0')
            nsects = struct.unpack_from('<I', b, o + 8 + 56)[0]
            so = o + 8 + 64
            for _ in range(nsects):
                sn, sgn, addr, size, offset = struct.unpack_from('<16s16sQQI', b, so)
                flg = struct.unpack_from('<I', b, so + 64)[0]
                if name == b'__TEXT' and (flg & 0xff) != 1:  # skip zerofill
                    secs.append((addr, offset, size, sn.rstrip(b'\0')))
                so += 80
        elif cmd == LC_MAIN:
            entry = struct.unpack_from('<Q', b, o + 8)[0]
        o += sz
    assert entry is not None, "no LC_MAIN in input"
    assert secs, "no __TEXT content sections in input"
    return b, secs, entry


def make_cd(body, code_limit, exec_limit, pageshift):
    # ad-hoc CodeDirectory, version 0x20400 (carries exec-segment range, which
    # AMFI requires for a main executable: execSegFlags = CS_EXECSEG_MAIN_BINARY).
    # A one-byte NUL identifier is kept: the kernel accepts a bare CD only when
    # identOffset is non-zero.
    psize = 1 << pageshift
    nslots = (code_limit + psize - 1) // psize
    hdr_len = 88
    ident_off = hdr_len
    hash_off = ident_off + 1
    cd_len = hash_off + 32 * nslots
    cd = struct.pack('>IIIIIIIIIBBBBI', 0xfade0c02, cd_len, 0x20400, 0x2,
                     hash_off, ident_off, 0, nslots, code_limit,
                     32, 2, 0, pageshift, 0)
    cd += struct.pack('>IIIQ', 0, 0, 0, 0)               # scatter, team, spare3, codeLimit64
    cd += struct.pack('>QQQ', 0, exec_limit, 1)          # execSegBase/Limit/Flags(MAIN_BINARY)
    assert len(cd) == hdr_len, len(cd)
    cd += b'\0'                                          # 1-byte identifier
    if body is None:
        cd += b'\0' * (32 * nslots)
    else:
        for i in range(nslots):
            cd += hashlib.sha256(body[i * psize:(i + 1) * psize]).digest()
    return cd


def make_sig(body, code_limit, exec_limit, pageshift, superblob=False):
    cd = make_cd(body, code_limit, exec_limit, pageshift)
    if not superblob:
        # Point LC_CODE_SIGNATURE straight at a bare CodeDirectory. The kernel's
        # cs_validate_csblob() accepts a raw CSMAGIC_CODEDIRECTORY, saving the
        # 20-byte SuperBlob wrapper. Apple userspace tools (codesign) only parse
        # the SuperBlob form, so pass superblob=True for a tool-verifiable file.
        return cd
    sb = struct.pack('>III', 0xfade0cc0, 12 + 8 + len(cd), 1)   # SuperBlob
    sb += struct.pack('>II', 0, 20)                             # one index: CSSLOT_CODEDIRECTORY
    sb += cd
    return sb


def build(inpath, outpath, pageshift=14, superblob=False,
          dylinker=b'/usr/lib/dyld', dylib=b'/usr/lib/libSystem.B.dylib',
          minos=(11, 0), sdk=(11, 0)):
    b, secs, entry = read_macho(inpath)
    secs = [s for s in secs if s[3] != b'__unwind_info']
    secs.sort()
    first_off = secs[0][1]
    end_off = max(s[1] + s[2] for s in secs)
    payload = b[first_off:end_off]
    entry_delta = entry - first_off

    def seg(name, vmaddr, vmsize, foff, fsize, maxp, initp):
        return struct.pack('<II16sQQQQiiII', LC_SEGMENT_64, 72, name.ljust(16, b'\0'),
                           vmaddr, vmsize, foff, fsize, maxp, initp, 0, 0)

    def lc_str(cmd, stroff, s):
        sz = align(stroff + len(s) + 1, 8)
        return struct.pack('<III', cmd, sz, stroff) + (s + b'\0').ljust(sz - stroff, b'\0')

    pagezero = seg(b'__PAGEZERO', 0, 0x100000000, 0, 0, 0, 0)
    dylinker_lc = lc_str(LC_LOAD_DYLINKER, 12, dylinker)
    dylib_lc = (struct.pack('<IIIIII', LC_LOAD_DYLIB, align(24 + len(dylib) + 1, 8), 24, 0,
                            0x10000, 0x10000) + (dylib + b'\0').ljust(align(24 + len(dylib) + 1, 8) - 24, b'\0'))
    buildver = struct.pack('<IIIIII', LC_BUILD_VERSION, 24, 1,
                           (minos[0] << 16) | (minos[1] << 8), (sdk[0] << 16) | (sdk[1] << 8), 0)
    uuid_lc = struct.pack('<II', LC_UUID, 24) + b'machomin.uuid.01'
    tail = dylinker_lc + dylib_lc + buildver + uuid_lc

    # size the load commands (text seg + main + codesig are fixed-size)
    fixed = len(pagezero) + 72 + len(tail) + 24 + 16
    hdr_len = 32 + fixed

    payoff = first_off
    while payoff < hdr_len:
        payoff += VMPAGE           # keep congruent mod page so adrp/add stay valid
    pay_end = payoff + len(payload)
    code_limit = align(max(pay_end, VMPAGE), VMPAGE)
    sig_off = code_limit
    sig_size = len(make_sig(None, code_limit, code_limit, pageshift, superblob))
    text_fsize = sig_off           # signature sits just past __TEXT's file range; kernel reads it directly
    text_vmsize = align(text_fsize, VMPAGE)
    entryoff = payoff + entry_delta

    text_seg = seg(b'__TEXT', 0x100000000, text_vmsize, 0, text_fsize, VM_R | VM_X, VM_R | VM_X)
    main_lc = struct.pack('<IIQQ', LC_MAIN, 24, entryoff, 0)
    codesig_lc = struct.pack('<IIII', LC_CODE_SIGNATURE, 16, sig_off, sig_size)
    sizeofcmds = len(pagezero + text_seg + tail + main_lc + codesig_lc)
    header = struct.pack('<IIIIIIII', MH_MAGIC_64, CPU_ARM64, 0, MH_EXECUTE,
                         8, sizeofcmds, MH_NOUNDEFS | MH_DYLDLINK | MH_PIE, 0)
    hdr = header + pagezero + text_seg + tail + main_lc + codesig_lc
    assert len(hdr) <= payoff, (len(hdr), payoff)

    body = bytearray(code_limit)
    body[0:len(hdr)] = hdr
    body[payoff:pay_end] = payload
    sig = make_sig(bytes(body), code_limit, text_vmsize, pageshift, superblob)
    assert len(sig) == sig_size
    out = bytes(body) + sig
    open(outpath, 'wb').write(out)
    os.chmod(outpath, 0o755)
    return len(out)


if __name__ == '__main__':
    ps = int(sys.argv[3]) if len(sys.argv) > 3 else 14
    sb = len(sys.argv) > 4 and sys.argv[4] == 'sb'
    n = build(sys.argv[1], sys.argv[2], pageshift=ps, superblob=sb)
    print("wrote", sys.argv[2], n, "bytes")
