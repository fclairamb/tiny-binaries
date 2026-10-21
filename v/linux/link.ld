/* One loadable segment in the 64 KB page at 0x400000. elfgolf.py writes the ELF and program
   headers over its first CODE bytes and keeps the bytes of the header holes, so small pieces
   of a program go there: a section named .text.hN lands at offset N (4, 20, 40, 72, 80), the
   V constants at DATA. Everything else starts at CODE, with .text.entry (amd64 tcp glue)
   first, falling through into vmain. ld stops if two pieces overlap, elfgolf.py if one
   covers a header field. */
PHDRS { all PT_LOAD FLAGS(7); }
SECTIONS {
  .h4 0x400004 : { KEEP(*(.text.h4)) } :all
  .h20 0x400014 : { KEEP(*(.text.h20)) } :all
  .h40 0x400028 : { KEEP(*(.text.h40)) } :all
  .h72 0x400048 : { KEEP(*(.text.h72)) } :all
  .h80 0x400050 : { KEEP(*(.text.h80)) } :all
  .const 0x400000 + DATA : { *(.data._const_* .rodata._const_*) } :all
  .text 0x400000 + CODE : {
    KEEP(*(.text.entry))
    glue_end = .;
    KEEP(*(.text.main__vmain))
    *(.text .text.*)
    *(.rodata .rodata.* .data .data.*)
  } :all =0
  .bss : { *(.bss .bss.* COMMON) } :all
  /* register checks (rt.v, arm64): a check section is named after the registers the
     compiler gave the syscall operands; those with every operand in its ABI register go */
  /DISCARD/ : {
    *(.comment) *(.note .note.*) *(.eh_frame .eh_frame_hdr) *(.gnu.*)
    *(.ck.ax0 .ck.ax0.bx1 .ck.ax0.cx2 .ck.ax0.bx1.cx2)
  }
  .ck 0 (INFO) : { *(.ck.*) }
}
ASSERT(SIZEOF(.ck) == 0, "a syscall operand is not in its register (see the checks in rt.v)")
/* the amd64 tcp glue falls through into vmain: nothing may come between them */
ASSERT(glue_end == ADDR(.text) || main__vmain == glue_end, "vmain does not follow .text.entry")
