package main

import (
	"unsafe"

	"tinyextreme/sys"
)

const req = "hello\n"

func load(p uintptr) byte    { return *(*byte)(unsafe.Pointer(p)) }
func store(p uintptr, b byte) { *(*byte)(unsafe.Pointer(p)) = b }
func word(p uintptr) uintptr { return *(*uintptr)(unsafe.Pointer(p)) }

//export _start
func start() {
	sys.Syscall1(sys.EXIT, run(uintptr(sys.EntrySP())))
}

func run(sp uintptr) uintptr {
	if word(sp) < 3 {
		return 1
	}
	// One anonymous page the kernel owns as read-write: the sockaddr_in (16 bytes at
	// mem+0) and the copy buffer (mem+16..). A fresh mmap page is writable by both the
	// program and the kernel on every loader, including Rosetta, which maps the file's
	// own segments read-only for an x86_64 binary and so rejects read() into them.
	mem, _ := sys.Syscall6(sys.MMAP, 0, 4096+16, 3, 0x22, ^uintptr(0), 0)
	if int(mem) <= 0 {
		return 1
	}
	buf := mem + 16

	// sockaddr_in: sin_family=AF_INET, sin_port (big endian), sin_addr, sin_zero.
	store(mem, 2)
	i := uintptr(4)
	for p := word(sp + 16); load(p) != 0; p++ {
		if c := load(p); c == '.' {
			i++
		} else {
			store(mem+i, load(mem+i)*10+c-'0')
		}
	}
	port := uint16(0)
	for p := word(sp + 24); load(p) != 0; p++ {
		port = port*10 + uint16(load(p)-'0')
	}
	store(mem+2, byte(port>>8))
	store(mem+3, byte(port))

	fd, _ := sys.Syscall3(sys.SOCKET, 2, 1, 0)
	if r, _ := sys.Syscall3(sys.CONNECT, fd, mem, 16); r != 0 {
		return 1
	}
	sys.Syscall3(sys.WRITE, fd, uintptr(unsafe.Pointer(unsafe.StringData(req))), uintptr(len(req)))
	for {
		n, _ := sys.Syscall3(sys.READ, fd, buf, 4096)
		if int(n) <= 0 {
			return 0
		}
		sys.Syscall3(sys.WRITE, 1, buf, n)
	}
}

func main() {}
