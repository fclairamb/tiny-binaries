package main

import "unsafe"

// The message goes in the 14-byte header hole at offset 40.
//
//go:section .hole40
var msg = [14]byte{'H', 'e', 'l', 'l', 'o', ',', ' ', 'W', 'o', 'r', 'l', 'd', '!', '\n'}

func addr() uintptr { return uintptr(unsafe.Pointer(&msg)) }

func main() {}
