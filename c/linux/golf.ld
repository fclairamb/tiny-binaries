/* One R+X PT_LOAD holding just the code and data, linked HSIZE bytes into a
   64 KB page. elfgolf.py writes the minimal ELF + program header into the HSIZE
   bytes in front of the code. No FILEHDR/PHDRS here: elfgolf writes fresh ones.
   p_vaddr = 0x10000 + HSIZE keeps p_offset congruent to p_vaddr on 4, 16 and
   64 KB page kernels. */
PHDRS { all PT_LOAD FLAGS(5); }
SECTIONS {
  . = 0x10000 + HSIZE;
  .all : { *(.text*) *(.rodata*) *(.data*) } :all
  .bss : { *(.bss*) } :all
  /DISCARD/ : { *(.note*) *(.comment*) *(.eh_frame*) *(.ARM.*) *(.gnu*) }
}
