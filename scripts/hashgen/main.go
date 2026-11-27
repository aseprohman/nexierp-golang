// hashgen — util dev: argon2id hash untuk seed user bukti/debug
// (parameter sama dengan lib argon2 NestJS; verifikasi lintas-runtime).
package main

import (
	"fmt"
	"os"

	"nexierp/internal/core/auth"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "pemakaian: hashgen <password>")
		os.Exit(1)
	}
	fmt.Println(auth.HashPassword(os.Args[1]))
}
