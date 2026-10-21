package main

import (
	"unsafe"

	"tinyextreme/sys"
)

const request = "hello\n"

//export _start
func start() {
	sp := (*[4]uintptr)(sys.EntrySP())
	spa := uintptr(unsafe.Pointer(sp))
	// r is argc - 3: negative with fewer than 2 arguments, and the exit status is then -r,
	// 3 - argc: 2 with no arguments, 1 with one (3 if argc is 0, which kernels before 5.18 allow).
	r := sp[0] - 3
	if int(r) >= 0 {
		// parse builds the 8 sockaddr_in bytes (family, port, address) from argv[1] and argv[2].
		// Its inner loop is written per arch (parse_*.go) because the two backends lower the same
		// loop differently.
		sp[0] = uintptr(bswap(parse(spa, r+2)))
		fd, _ := sys.Syscall3(sys.SOCKET, 2, 1, 0)
		r, _ = sys.Syscall3(sys.CONNECT, fd, spa, 16)
		if r == 0 {
			dst := fd
			buf := uintptr(unsafe.Pointer(unsafe.StringData(request)))
			r = uintptr(len(request))
			for {
				sys.Syscall3(sys.WRITE, dst, buf, r)
				r, _ = sys.Syscall3(sys.READ, fd, spa, 64)
				if int(r) <= 0 {
					break
				}
				dst = 1
				buf = spa
			}
		}
	}
	// One exit for every path, with status -r: 0 on a clean close, errno when the connection
	// fails (ECONNREFUSED, 111) or is reset mid-reply (ECONNRESET, 104), 3 - argc on too few
	// arguments.
	sys.Exit(sys.Status(r))
}

func bswap(x uint64) uint64 {
	return x>>56 | x>>40&0xff00 | x>>24&0xff0000 | x>>8&0xff000000 |
		x<<8&0xff00000000 | x<<24&0xff0000000000 | x<<40&0xff000000000000 | x<<56
}

func main() {}
