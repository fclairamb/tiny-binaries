package main

import "unsafe"

func parse(spa, k uintptr) uint64 {
	x := uint64(2 << 16)
	for {
		p := *(*uintptr)(unsafe.Pointer(spa + k*8 + 8))
		cur := uint64(0)
		for {
			c := uint64(*(*byte)(unsafe.Pointer(p)))
			p++
			if c < '0' {
				x = x<<8 | cur
				cur = 0
				if c == 0 {
					break
				}
			} else {
				cur = cur*10 + c - '0'
			}
		}
		k--
		if k == 0 {
			break
		}
	}
	return x
}
