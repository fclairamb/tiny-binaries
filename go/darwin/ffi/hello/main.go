// hello, extreme-ffi variant: the logic is in Go, the OS is reached through
// libSystem with FFI (//export declarations resolve to the C symbols at load),
// which SPEC allows ("Calling the OS (libc or syscalls) through FFI is fine").
// No inline assembly at all; the only non-Go part is dyld loading libSystem.
package main

import "unsafe"

// puts writes the string and a newline to stdout. It is the shortest import
// name that prints (one byte less than _write in the bind opcodes), and its
// stdio buffer is flushed by the exit() that dyld calls when appmain returns.
//
//export puts
func cPuts(s *byte) int32

// appmain is the program entry (ld -e _appmain -> LC_MAIN). dyld calls it as
// C main() and passes its return value to exit(), so no _exit import is needed.
//
//export appmain
func appmain() int32 {
	msg := "Hello, World!\x00"
	cPuts(unsafe.StringData(msg))
	return 0
}

func main() {}
