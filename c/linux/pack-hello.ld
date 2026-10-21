/* hello: one R+X PT_LOAD from a 64 KB boundary (0x400000). elfgolf.py writes
 * the ELF header and the single program header over the segment's first CODE
 * bytes and drops the section headers.
 *
 * The 14-byte message is placed at MSG (a header hole), and the code at CODE
 * (the header size). elfgolf.py keeps the bytes of the holes, so the message
 * survives inside the headers; every other header byte must be zero, hence the
 * =0 fill. 0x400000 is a multiple of 64 KB, so p_offset stays congruent to
 * p_vaddr on 4, 16 and 64 KB page kernels, and it sits well above
 * vm.mmap_min_addr. */
PHDRS { all PT_LOAD FLAGS(5); }
SECTIONS {
  .all 0x400000 : {
    . = MSG;
    KEEP(*(.rodata.msg))
    . = CODE;
    KEEP(*(.text.entry))
    *(.text*) *(.rodata*) *(.data*)
  } :all =0
  .bss : { *(.bss*) } :all
  /DISCARD/ : { *(.note*) *(.comment*) *(.eh_frame*) *(.ARM.*) *(.gnu*) }
}
