/* hello hole-packing. One output section from a 64 KB boundary so the single
   PT_LOAD starts at 0x10000. The 14-byte message sits at MSGOFF (the o56a
   14-byte header hole); the code starts at CODEOFF (the header size). Gaps are
   zero-filled (=0) so elfgolf.py can write the ELF + program headers over the
   first CODEOFF bytes, keeping the message in the hole. */
PHDRS { all PT_LOAD FLAGS(5); }
SECTIONS {
  .all 0x10000 : {
    . = MSGOFF;
    KEEP(*(.rodata.msg))
    . = CODEOFF;
    KEEP(*(.text.real_start))
    *(.text*) *(.rodata*) *(.data*)
  } :all =0
  .bss : { *(.bss*) } :all
  /DISCARD/ : { *(.note*) *(.comment*) *(.eh_frame*) *(.ARM.*) *(.gnu*) }
}
