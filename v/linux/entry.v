// Entry glue for tcp: the kernel starts the process with the stack pointer on argc, then
// the argv pointers. The glue puts what vmain needs in argument registers; vmain takes
// them as parameters.
// - amd64: pop r9 = argc (6th argument), then r8 = the stack pointer, now &argv[0] (5th
//   argument). None of the program's syscalls reads r8 or r9, and the syscall instruction
//   only clobbers rcx and r11, so argc survives the socket call in vmain. The 5 bytes are
//   in their own section, which the linker script puts right before vmain, so they fall
//   through into it: no jmp, and the e_shoff hole is free for die (tcp.v).
// - arm64: x3 = sp, x4 = argc, x5 = argv (4th to 6th arguments; syscalls use x0-x2 and
//   x8). The first three instructions fill e_ident[4..15], which the arm64 kernel never
//   reads, the last two the e_shoff hole (.text.glue2).
module main

$if amd64 {
	asm amd64 {
		.section '.text.entry'
		.globl entry
		entry:
		pop r9
		mov r8, rsp
	}
} $else {
	asm arm64 {
		.globl entry
		entry:
		mov x3, SP
		ldr x4, [SP]
		b glue2
		.section '.text.glue2'
		glue2:
		add x5, SP, 8
		b main__vmain
	}
}
