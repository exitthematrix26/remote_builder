package main

import (
	"fmt"
	"os"
	"runtime"
)

func main() {
	host, _ := os.Hostname()
	fmt.Printf("Hello from RBE!\n")
	fmt.Printf("  Built for:  %s/%s\n", runtime.GOOS, runtime.GOARCH)
	fmt.Printf("  Ran on:     %s\n", host)
	fmt.Printf("  Go version: %s\n", runtime.Version())
}
