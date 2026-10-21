package main

import (
	"fmt"
	"io"
	"net"
	"os"
)

func main() {
	if len(os.Args) < 3 {
		fmt.Fprintln(os.Stderr, "usage: tcp <ipv4> <port>")
		os.Exit(1)
	}
	conn, err := net.Dial("tcp4", net.JoinHostPort(os.Args[1], os.Args[2]))
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	defer conn.Close()
	if _, err := conn.Write([]byte("hello\n")); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	if _, err := io.Copy(os.Stdout, conn); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
