/* One PT_LOAD segment that includes the ELF header and the program headers
 * (FILEHDR PHDRS), mapped read+execute. Everything the program needs (.text,
 * .rodata, read-only data) lives in it; all metadata sections are discarded.
 * Base 0x10000 is the default vm.mmap_min_addr and a multiple of 64 KB, so the
 * single mapping is page-friendly on 4 KB, 16 KB and 64 KB kernels alike.
 */
ENTRY(_start)
PHDRS {
  text PT_LOAD FILEHDR PHDRS FLAGS(5);
}
SECTIONS {
  . = 0x10000 + SIZEOF_HEADERS;
  .text : { *(.text .text.*) } :text
  .rodata : { *(.rodata .rodata.* .srodata .srodata.*) } :text
  .data : { *(.data .data.* .sdata .sdata.*) } :text
  /DISCARD/ : {
    *(.eh_frame*) *(.eh_frame_hdr) *(.note*) *(.comment) *(.gnu*) *(.gnu.hash)
    *(.dynsym) *(.dynstr) *(.hash) *(.dynamic) *(.got) *(.got.plt) *(.plt*)
    *(.rela*) *(.interp) *(.ARM.*) *(.bss .bss.* .sbss*) *(.tbss*) *(.riscv*)
  }
}
