package main

import "unsafe"

// parse reads argv[k] down to argv[1] (see parse_amd64.go for the folding). On arm64 the
// pre-increment walk lowers to a load with post-index addressing (ldrb [x],#1), which is
// smaller than the straight load/advance pair.
func parse(spa, k uintptr) uint64 {
	x := uint64(2 << 16)
	for {
		p := *(*uintptr)(unsafe.Pointer(spa + k*8 + 8)) - 1
		cur := uint64(0)
		for {
			p++
			c := uint64(*(*byte)(unsafe.Pointer(p)))
			if c >= '0' {
				cur = cur*10 + c - '0'
				continue
			}
			x = x<<8 | cur
			cur = 0
			if c == 0 {
				break
			}
		}
		k--
		if k == 0 {
			return x
		}
	}
}
