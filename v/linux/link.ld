/* One loadable segment in the 64 KB page at 0x400000 (the usual x86-64 base, far above
   any vm.mmap_min_addr), so it works with 4, 16 and 64 KB pages. elfgolf.py writes the ELF
   and program headers over the first CODE bytes of the page, and keeps the bytes of the
   sections that sit in the header holes (fields the kernel ignores), so small pieces of the
   program go there, each in its own output section: the entry glue (the top-level asm,
   alone in .text with -ffunction-sections) at GLUE, its second half (.text.glue2, arm64)
   at GLUE2, a small function (.text.hole) at HOLE, the V constants at DATA, another small
   function (.text.hole2) at HOLE2. The build script passes the offsets (elfgolf.py -H and
   -h give them); a piece a program does not have is an empty section. elfgolf.py stops if
   a piece covers a header field, ld if two sections overlap. The code starts at CODE with
   the amd64 entry glue (.text.entry), which falls through into vmain. */
PHDRS { all PT_LOAD FLAGS(7); }
SECTIONS {
  .glue 0x400000 + GLUE : { KEEP(*(.text)) } :all =0
  .glue2 0x400000 + GLUE2 : { KEEP(*(.text.glue2)) } :all
  .hole 0x400000 + HOLE : { KEEP(*(.text.hole)) } :all
  .const 0x400000 + DATA : { *(.data._const_* .rodata._const_*) } :all
  .hole2 0x400000 + HOLE2 : { KEEP(*(.text.hole2)) } :all
  .text 0x400000 + CODE : {
    KEEP(*(.text.entry))
    glue_end = .;
    KEEP(*(.text.main__vmain))
    *(.text.*)
    *(.rodata .rodata.*)
    *(.data .data.*)
  } :all =0
  .bss : { *(.bss .bss.* COMMON) } :all
  /DISCARD/ : { *(.comment) *(.note .note.*) *(.eh_frame .eh_frame_hdr) *(.gnu.*) }
}
/* amd64 entry glue falls through into vmain: no padding may come between them */
ASSERT(main__vmain == glue_end, "vmain does not follow .text.entry")
