// Command cli is the template's own tooling. Run it with GOWORK=off: the
// editor go.work at the repository root does not list this module.
//
//	cli check [-file instance.yaml] [-core core]
package main

import (
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
)

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 || args[0] != "check" {
		fmt.Fprintln(stderr, "usage: cli check [-file instance.yaml] [-core core]")
		return 2
	}
	fs := flag.NewFlagSet("check", flag.ContinueOnError)
	fs.SetOutput(stderr)
	file := fs.String("file", "instance.yaml", "path to instance.yaml")
	core := fs.String("core", "core", "path to the core submodule")
	if err := fs.Parse(args[1:]); err != nil {
		return 2
	}

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
	problems := in.Validate()
	if in.Core != "" {
		tags, err := coreTags(*core)
		if err != nil {
			problems = append(problems, fmt.Sprintf("core: cannot read the tags of %s: %v", *core, err))
		} else if p := CheckCore(in.Core, tags); p != "" {
			problems = append(problems, p)
		}
	}
	if len(problems) > 0 {
		for _, p := range problems {
			fmt.Fprintf(stderr, "instance.yaml: %s\n", p)
		}
		return 1
	}
	fmt.Fprintf(stdout, "instance.yaml: ok (%s, core %s)\n", in.Name, in.Core)
	return 0
}

// coreTags lists the tags that point at HEAD of the core checkout.
func coreTags(dir string) ([]string, error) {
	out, err := exec.Command("git", "-C", dir, "tag", "--points-at", "HEAD").Output()
	if err != nil {
		return nil, err
	}
	return strings.Fields(string(out)), nil
}
