/* One loadable segment from the 64 KB page at 0x400000 (loads on 4, 16 and 64 KB pages),
   the usual base of a non-PIE executable, far above any vm.mmap_min_addr. elfgolf.py writes
   the ELF and program headers over the first CODE bytes of the page and keeps the bytes of
   the header holes (fields the loader ignores); input sections named .holeN go at offset N,
   so a program can drop small pieces (a string, the entry glue, a short function) there, and
   the rest of the code starts at CODE (elfgolf.py -H gives it, -h the holes). ld stops if a
   piece runs into the next one; elfgolf.py stops if one covers a header field it needs.
   @FL@ is the segment flags: the low 3 bits are PF_R/W/X (5 = R+X, 7 = R+W+X), the upper
   bits are ignored by the kernel, so hello arm64 passes 0x5d to leave the exit number 93 in
   p_flags for an ldp to read. Generic: nothing here is program specific; lld reads a bare
   location counter in an output section as an absolute address, hence 0x400000 + N. */
PHDRS { all PT_LOAD FLAGS(@FL@); }
SECTIONS {
  .text 0x400000 : {
    . = 0x400000 + 4;  KEEP(*(.hole4 .hole4.*))
    . = 0x400000 + 20; KEEP(*(.hole20 .hole20.*))
    . = 0x400000 + 40; KEEP(*(.hole40 .hole40.*))
    . = 0x400000 + 72; KEEP(*(.hole72 .hole72.*))
    . = 0x400000 + 80; KEEP(*(.hole80 .hole80.*))
    . = 0x400000 + CODE;
    KEEP(*(.text._start))
    *(.text .text.*)
    *(.rodata .rodata.*)
    *(.data .data.*)
  } :all =0
  .bss : { *(.bss .bss.* COMMON) } :all
  /DISCARD/ : { *(.comment) *(.note .note.*) *(.eh_frame .eh_frame_hdr) *(.ARM.*) *(.gnu.*) }
}
