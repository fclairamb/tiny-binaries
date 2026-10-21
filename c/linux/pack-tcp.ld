/* tcp: one R+X PT_LOAD from a 64 KB boundary (0x400000). elfgolf.py writes the
 * ELF header and the single program header over the segment's first CODE bytes
 * and drops the section headers.
 *
 * Two pieces go in header holes of the o48a layout: the 8-byte _start glue at
 * GLUE (the e_shoff/e_flags/e_ehsize hole), and the 6-byte "hello\n" request at
 * REQ (the p_paddr hole). The rest of the code starts at CODE (the header size).
 * elfgolf.py keeps the holes' bytes, so glue and request survive inside the
 * headers; every other header byte must be zero, hence the =0 fill. 0x400000 is
 * a multiple of 64 KB (page-size independent, above vm.mmap_min_addr). */
PHDRS { all PT_LOAD FLAGS(5); }
SECTIONS {
  .all 0x400000 : {
    . = GLUE;
    KEEP(*(.text.glue))
    . = REQ;
    KEEP(*(.rodata.req))
    . = CODE;
    KEEP(*(.text.entry))
    *(.text*) *(.rodata*) *(.data*)
  } :all =0
  .bss : { *(.bss*) } :all
  /DISCARD/ : { *(.note*) *(.comment*) *(.eh_frame*) *(.ARM.*) *(.gnu*) }
}
