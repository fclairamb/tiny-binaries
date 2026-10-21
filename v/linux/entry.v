// Entry glue for programs that need argc/argv: the kernel starts the process with the
// stack pointer on argc. This copies it into an argument register and jumps to vmain.
// The register is vmain's first argument that no syscall uses (x86_64 r8, the 5th;
// arm64 x3, the 4th), so it can stay there. With -ffunction-sections this top-level asm
// is alone in .text, which the linker script puts in a header hole.
module main

$if amd64 {
	asm amd64 {
		.globl entry
		entry:
		mov r8, rsp
		jmp main__vmain
	}
} $else {
	asm arm64 {
		.globl entry
		entry:
		mov x3, SP
		b main__vmain
	}
}
