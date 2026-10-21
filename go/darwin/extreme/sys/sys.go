// Package sys makes macOS arm64 kernel calls directly with the svc instruction.
package sys

import "device/arm64"

// Err is the bit Call sets in its result when the kernel reports an error.
// The rest of the result is then the errno.
const Err = 1 << 63

// Call issues a Darwin arm64 BSD syscall: number in x16, arguments in x0-x4,
// trap with "svc #0x80". The kernel returns the result in x0 and reports an
// error by setting the carry flag (x0 is then the errno). Call returns x0 with
// the carry copied into bit 63 (Err), so callers test int64(r) < 0 in Go.
//
// device.AsmFull gives the operands plain "r" constraints and cannot declare
// clobbers, so the asm keeps every promise that an empty clobber list makes:
//   - the inputs can be in any register, x0-x4 and x16 included, so they are
//     all stored to the stack before any fixed register is written, then
//     loaded from there into x16 and x0-x4;
//   - x0-x4, x16 and NZCV are saved first and restored after the trap, so the
//     compiler can keep values (or a pending comparison) in them across Call;
//   - the result is loaded into the output register last, so it wins if the
//     compiler picked one of the restored registers for it.
//
// The slots sit 128 bytes below sp, which leaves a red zone alone if the
// caller uses one. The asm is only the trap, the register moves around it,
// and a cset/orr that moves the carry flag into a register: no branch, no
// logic. What it still assumes from XNU (not a documented ABI): the trap
// changes only x0, x1 and the flags, and preserves every other register
// (osfmk saves the whole user state on entry, bsd/dev/arm/systemcalls.c
// writes only x0, x1 and the carry bit on return).
func Call(num, a0, a1, a2, a3, a4 uintptr) uintptr {
	return arm64.AsmFull(
		"sub sp, sp, #240\n"+
			"stp {n}, {a}, [sp]\n"+
			"stp {b}, {c}, [sp, #16]\n"+
			"stp {d}, {e}, [sp, #32]\n"+
			"stp x0, x1, [sp, #48]\n"+
			"stp x2, x3, [sp, #64]\n"+
			"stp x4, x16, [sp, #80]\n"+
			"mrs x0, nzcv\n"+
			"str x0, [sp, #96]\n"+
			"ldp x16, x0, [sp]\n"+
			"ldp x1, x2, [sp, #16]\n"+
			"ldp x3, x4, [sp, #32]\n"+
			"svc #0x80\n"+
			"cset x1, cs\n"+
			"orr x0, x0, x1, lsl #63\n"+
			"str x0, [sp]\n"+
			"ldr x0, [sp, #96]\n"+
			"msr nzcv, x0\n"+
			"ldp x0, x1, [sp, #48]\n"+
			"ldp x2, x3, [sp, #64]\n"+
			"ldp x4, x16, [sp, #80]\n"+
			"ldr {}, [sp]\n"+
			"add sp, sp, #240",
		map[string]interface{}{"n": num, "a": a0, "b": a1, "c": a2, "d": a3, "e": a4},
	)
}
