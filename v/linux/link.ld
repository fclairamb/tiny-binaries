/* One loadable segment from a 64 KB boundary, so it works with 4, 16 and 64 KB pages.
   elfgolf.py writes the ELF and program headers over its first CODE bytes, and keeps the
   bytes of the header holes (fields the kernel ignores): the entry glue (the top-level asm,
   alone in .text with -ffunction-sections) goes at GLUE, the V constants at DATA. The
   build script passes the three offsets (elfgolf.py -H and -h give them). ld stops if a
   piece runs into the next one; elfgolf.py stops if it overlaps a header field. */
PHDRS { all PT_LOAD FLAGS(7); }
SECTIONS {
  .text 0x10000 : {
    . = GLUE;
    KEEP(*(.text))
    . = DATA;
    *(.data._const_* .rodata._const_*)
    . = CODE;
    KEEP(*(.text.main__vmain))
    *(.text.*)
    *(.rodata .rodata.*)
    *(.data .data.*)
  } :all =0
  .bss : { *(.bss .bss.* COMMON) } :all
  /DISCARD/ : { *(.comment) *(.note .note.*) *(.eh_frame .eh_frame_hdr) *(.gnu.*) }
}
