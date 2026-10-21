/* One loadable segment, read+execute, from a 64 KB boundary, so it works with 4, 16 and
   64 KB pages. elfgolf.py writes the ELF and program headers over the first CODE bytes of the
   segment and keeps the bytes of the header holes (fields the loaders ignore): the string
   constant goes at DATA and the exit function (.text.hole) at HOLE, both inside holes; the
   rest of the code starts at CODE, after the header. The build script passes the three offsets
   (elfgolf.py -H gives CODE, -h the holes).

   lld reads a bare location counter inside an output section as an absolute address, so each
   offset is written 0x10000 + N. ld stops if a piece runs into the next one ("unable to move
   location counter backward"); elfgolf.py stops if a kept byte lands on a header field it
   needs. Nothing is ever written to the segment: both programs keep their only writable state
   on the stack. */
PHDRS { all PT_LOAD FLAGS(5); }
SECTIONS {
  .text 0x10000 : {
    . = 0x10000 + DATA;
    *(.rodata .rodata.*)
    . = 0x10000 + HOLE;
    KEEP(*(.text.hole))
    . = 0x10000 + CODE;
    KEEP(*(.text._start))
    *(.text .text.*)
    *(.data .data.*)
  } :all =0
  .bss : { *(.bss .bss.* COMMON) } :all
  /DISCARD/ : { *(.comment) *(.note .note.*) *(.eh_frame .eh_frame_hdr) *(.ARM.*) }
}
