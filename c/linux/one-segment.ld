/* One RWX PT_LOAD that starts at file offset 0 and contains the ELF header
 * (FILEHDR), the program header (PHDRS) and all code and data. p_offset is 0
 * and p_vaddr is 0x10000, a multiple of 64 KB, so the segment loads on 4 KB,
 * 16 KB and 64 KB page kernels. Covering the headers from offset 0 also keeps
 * Rosetta's own ELF loader happy (it insists the first load segment span the
 * ELF and program headers). */
/* FLAGS(5) = R+X. We never write into the mapped segment (tcp's buffers and
 * sockaddr live on the stack, which the kernel maps writable separately), so
 * the segment needs no W. R+X also avoids the linker's RWX warning and loads
 * under W^X policies that reject writable-and-executable segments. */
PHDRS { all PT_LOAD FILEHDR PHDRS FLAGS(5); }
SECTIONS {
    . = 0x10000 + SIZEOF_HEADERS;
    .all : {
        *(.text*)
        *(.rodata*)
        *(.data*)
        *(.bss*)
    } :all
    /DISCARD/ : { *(.note*) *(.comment*) *(.eh_frame*) *(.ARM.*) *(.gnu*) }
}
