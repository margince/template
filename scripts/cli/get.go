package main

import (
	"flag"
	"fmt"
	"io"
	"os"
)

// runGet prints one value from instance.yaml. Scripts read the file through
// this command, so there is one parser.
func runGet(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("get", flag.ContinueOnError)
	fs.SetOutput(stderr)
	file := fs.String("file", "instance.yaml", "path to instance.yaml")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if fs.NArg() != 1 {
		fmt.Fprintln(stderr, "usage: cli get [-file instance.yaml] <key>")
		return 2
	}
	key := fs.Arg(0)

	data, err := os.ReadFile(*file)
	if err != nil {
		fmt.Fprintf(stderr, "instance.yaml: %v\n", err)
		return 1
	}
	in, err := Parse(data)
	if err != nil {
		fmt.Fprintf(stderr, "instance.yaml: %v\n", err)
		return 1
	}
	value, ok := in.Value(key)
	if !ok {
		fmt.Fprintf(stderr, "instance.yaml: unknown key %q (want name, display_name, core, flavor, deploy.<env>.adapter)\n", key)
		return 2
	}
	if value == "" {
		fmt.Fprintf(stderr, "instance.yaml: %s is empty\n", key)
		return 1
	}
	fmt.Fprintln(stdout, value)
	return 0
}
