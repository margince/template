// Command cli is the template's own tooling. Run it with GOWORK=off: the
// editor go.work at the repository root does not list this module.
//
//	cli check [-file instance.yaml] [-core core]
package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
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
			var notCheckedOut *notCheckedOutError
			if errors.As(err, &notCheckedOut) {
				problems = append(problems, "core: "+err.Error())
			} else {
				problems = append(problems, fmt.Sprintf("core: cannot read the tags of %s: %v", *core, err))
			}
		} else if p := CheckCore(in.Core, tags); p != "" {
			// A shallow submodule checkout (actions/checkout with
			// submodules: recursive, or `git submodule update --init
			// --depth=1`) fetches core by commit SHA, not by tag: the
			// commit arrives, but no tag ref points at it locally, even
			// though core/ genuinely is at the pinned release. Fetch the
			// tag instance.yaml names and recheck before reporting a
			// problem, so this common shallow-clone shape is not
			// mistaken for core/ actually being unpinned.
			if ferr := fetchCoreTag(*core, in.Core); ferr != nil {
				problems = append(problems, fmt.Sprintf("core: cannot verify that core/ is at %s: fetching the tag failed: %v", in.Core, ferr))
			} else if tags, err = coreTags(*core); err != nil {
				problems = append(problems, fmt.Sprintf("core: cannot read the tags of %s: %v", *core, err))
			} else if p := CheckCore(in.Core, tags); p != "" {
				problems = append(problems, p)
			}
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
	if err := verifyCheckedOut(dir); err != nil {
		return nil, err
	}
	out, err := exec.Command("git", "-C", dir, "tag", "--points-at", "HEAD").Output()
	if err != nil {
		return nil, err
	}
	return strings.Fields(string(out)), nil
}

// notCheckedOutError reports that dir is not itself a checked-out git
// repository — for example an uninitialized submodule, whose directory
// exists but is empty. `git -C <dir>` would otherwise silently walk up to
// the enclosing repository and answer for THAT, giving a false pass.
type notCheckedOutError struct{ dir string }

func (e *notCheckedOutError) Error() string {
	return fmt.Sprintf("%s is not a checked-out git repository; run git submodule update --init", e.dir)
}

// verifyCheckedOut confirms that dir is the top level of its own git
// checkout, rather than a plain subdirectory of some enclosing repository.
func verifyCheckedOut(dir string) error {
	notCheckedOut := &notCheckedOutError{dir: dir}
	out, err := exec.Command("git", "-C", dir, "rev-parse", "--show-toplevel").Output()
	if err != nil {
		return notCheckedOut
	}
	wantAbs, err := filepath.Abs(dir)
	if err != nil {
		return err
	}
	if want, err := filepath.EvalSymlinks(wantAbs); err == nil {
		wantAbs = want
	}
	got := strings.TrimSpace(string(out))
	if resolved, err := filepath.EvalSymlinks(got); err == nil {
		got = resolved
	}
	if got != wantAbs {
		return notCheckedOut
	}
	return nil
}

// fetchCoreTag fetches a single tag from the core checkout's origin. Used
// when the tag instance.yaml names does not point at HEAD locally: a shallow
// submodule checkout fetches core by commit SHA and never receives the tag
// ref, even when the commit itself is exactly the pinned release.
func fetchCoreTag(dir, tag string) error {
	out, err := exec.Command("git", "-C", dir, "fetch", "--quiet", "--depth=1", "origin", "tag", tag).CombinedOutput()
	if err != nil {
		msg := strings.TrimSpace(string(out))
		if msg == "" {
			msg = err.Error()
		}
		return errors.New(msg)
	}
	return nil
}
