/* One PT_LOAD from a 64 KB boundary (0x400000). It has no FLAGS: ld gives it the union of
 * its sections' flags, R+X, or R+W+X when a program puts a writable variable in it. elfgolf.py writes the ELF and
 * program headers over the first CODE bytes (CODE = `elfgolf.py -l LAYOUT -H`) and keeps
 * the bytes of the header holes (fields the loaders ignore). An input section named
 * .holeN goes at header offset N, in its own output section so elfgolf.py can tell the
 * program bytes from the header bytes; everything else starts at CODE, .text.start
 * first. ld stops if two pieces overlap, elfgolf.py if a piece covers a header field.
 * Generic: nothing here is specific to a program.
 * 0x400000 is a multiple of 64 KB (p_offset stays congruent to p_vaddr on 4, 16 and
 * 64 KB page kernels) and sits far above any vm.mmap_min_addr. */
BASE = 0x400000;
PHDRS { all PT_LOAD; }
SECTIONS {
  .hole4 BASE + 4 : { KEEP(*(.hole4)) } :all =0
  .hole20 BASE + 20 : { KEEP(*(.hole20)) } :all =0
  .hole40 BASE + 40 : { KEEP(*(.hole40)) } :all =0
  .hole72 BASE + 72 : { KEEP(*(.hole72)) } :all =0
  .hole80 BASE + 80 : { KEEP(*(.hole80)) } :all =0
  .text BASE + CODE : {
    KEEP(*(.text.start))
    start_end = .;
    *(.text .text.*)
    *(.rodata .rodata.*)
  } :all =0
  /DISCARD/ : { *(.comment) *(.note .note.*) *(.eh_frame .eh_frame_hdr) *(.ARM.*) *(.gnu.*)
                *(.data .data.* .bss .bss.*) }
}
