/* One PT_LOAD, R W X, with the ELF header and program headers mapped at the base.
   .bss lives in the same segment, so there is no second segment to remap the code
   page without execute permission. The kernel zero-fills the gap between file size
   and memory size of the segment. Generic ELF loader behaviour, no page-size assumption. */
PHDRS {
  all PT_LOAD FILEHDR PHDRS FLAGS(7);
}
SECTIONS {
  . = 0x10000 + SIZEOF_HEADERS;
  .text : { *(.text*) *(.rodata*) *(.data*) } :all
  .bss  : { *(.bss*) *(COMMON) } :all
  /DISCARD/ : { *(.comment) *(.note*) *(.eh_frame*) *(.ARM.*) *(.debug*) }
}
