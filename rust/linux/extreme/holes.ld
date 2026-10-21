/* One loadable segment from a 64 KB boundary (it loads with 4, 16 and 64 KB pages), at
 * 0x400000, the usual base of a non-PIE executable, far above vm.mmap_min_addr (4096 to 65536).
 * elfgolf.py writes the ELF and program headers over its first CODE bytes and keeps the
 * bytes of the header holes (fields the loader ignores). Input sections named .holeN go
 * at offset N, so a program can put small pieces (a string, the entry glue, a short
 * function) in the holes; everything else starts at CODE (the header size, from
 * `elfgolf.py -H`). ld stops if a piece runs into the next one (the location counter
 * cannot move backwards) and elfgolf.py stops if one covers a header field.
 * The segment has no FLAGS: lld gives it the union of its sections' flags, so it is R+X,
 * or R+W+X when a program puts a writable static (`static mut`) in it.
 * Generic: nothing in here is specific to a program. lld treats `.` inside an output
 * section as an address, hence BASE + N. */
BASE = 0x400000;
PHDRS { all PT_LOAD; }
SECTIONS {
  .text BASE : {
    . = BASE + 4;  KEEP(*(.hole4 .hole4.*))
    . = BASE + 20; KEEP(*(.hole20 .hole20.*))
    . = BASE + 40; KEEP(*(.hole40 .hole40.*))
    . = BASE + 72; KEEP(*(.hole72 .hole72.*))
    . = BASE + 80; KEEP(*(.hole80 .hole80.*))
    . = BASE + CODE;
    *(.text .text.*)
    *(.rodata .rodata.*)
  } :all =0
  /DISCARD/ : {
    *(.comment) *(.note .note.*) *(.eh_frame .eh_frame_hdr) *(.gnu.*)
    *(.data .data.* .bss .bss.*)
  }
}
