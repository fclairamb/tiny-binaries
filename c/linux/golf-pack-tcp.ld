/* tcp hole-packing. One output section from a 64 KB boundary so the single
   PT_LOAD starts at 0x10000. Two pieces go in the o48a header holes: the
   8-byte _start glue (plain .text) at GLUEOFF (the e_shoff/e_flags/e_ehsize
   hole), and the "hello\n" string (.rodata) at STROFF (the p_paddr hole). The
   rest of the code starts at CODEOFF (the header size). Gaps are zero-filled
   (=0) so elfgolf.py writes the ELF + program headers over the first CODEOFF
   bytes while keeping the two holes. */
PHDRS { all PT_LOAD FLAGS(5); }
SECTIONS {
  .all 0x10000 : {
    . = GLUEOFF;
    KEEP(*(.text))
    . = STROFF;
    KEEP(*(.rodata*))
    . = CODEOFF;
    KEEP(*(.text.real_start))
    *(.text*) *(.data*)
  } :all =0
  .bss : { *(.bss*) } :all
  /DISCARD/ : { *(.note*) *(.comment*) *(.eh_frame*) *(.ARM.*) *(.gnu*) }
}
