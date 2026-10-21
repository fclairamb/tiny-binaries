// hello, extreme-ffi variant: the logic is in Go, the OS is reached through
// libSystem with FFI (//export declarations resolve to the C symbols at load),
// which SPEC allows ("Calling the OS (libc or syscalls) through FFI is fine").
// No inline assembly at all; the only non-Go part is dyld loading libSystem.
package main

import "unsafe"

//export write
func cWrite(fd int32, buf unsafe.Pointer, n uintptr) int

// appmain is the program entry (ld -e _appmain -> LC_MAIN). dyld calls it as
// C main() and passes its return value to exit(), so no _exit import is needed.
//
//export appmain
func appmain() int32 {
	msg := "Hello, World!\n"
	cWrite(1, unsafe.Pointer(unsafe.StringData(msg)), uintptr(len(msg)))
	return 0
}

func main() {}
