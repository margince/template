// Command cli is the template's own tooling. Run it with GOWORK=off: the
// editor go.work at the repository root does not list this module.
//
//	cli check [-file instance.yaml] [-core core]
//	cli get [-file instance.yaml] <key>
//	cli validate [-file instance.yaml]
package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
)

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

const usage = "usage: cli check [-file instance.yaml] [-core core] | cli get [-file instance.yaml] <key> | cli validate [-file instance.yaml]"

func run(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, usage)
		return 2
	}
	switch args[0] {
	case "check":
		return runCheck(args[1:], stdout, stderr)
	case "get":
		return runGet(args[1:], stdout, stderr)
	case "validate":
		return runValidate(args[1:], stdout, stderr)
	}
	fmt.Fprintln(stderr, usage)
	return 2
}

// runCheck validates instance.yaml and that core/ is at the tag it names.
func runCheck(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("check", flag.ContinueOnError)
	fs.SetOutput(stderr)
	file := fs.String("file", "instance.yaml", "path to instance.yaml")
	core := fs.String("core", "core", "path to the core submodule")
	if err := fs.Parse(args); err != nil {
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
	problems := append(in.Validate(), deployDirProblems(in, filepath.Dir(*file))...)
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

// runValidate validates instance.yaml and the deploy/<env>/ directories,
// without looking at core/: `make deploy` runs it, and a deployment does not
// depend on the core checkout. Exit 0 when valid, 1 with one line per problem.
func runValidate(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("validate", flag.ContinueOnError)
	fs.SetOutput(stderr)
	file := fs.String("file", "instance.yaml", "path to instance.yaml")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if fs.NArg() != 0 {
		fmt.Fprintln(stderr, "usage: cli validate [-file instance.yaml]")
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
	problems := append(in.Validate(), deployDirProblems(in, filepath.Dir(*file))...)
	if len(problems) > 0 {
		for _, p := range problems {
			fmt.Fprintf(stderr, "instance.yaml: %s\n", p)
		}
		return 1
	}
	fmt.Fprintln(stdout, "instance.yaml: valid")
	return 0
}

// deployDirProblems reports each well-named environment under deploy: that
// has no deploy/<env>/ directory beside instance.yaml (root). A malformed
// name is Validate's problem, and is not also looked up on disk.
func deployDirProblems(in Instance, root string) []string {
	envs := make([]string, 0, len(in.Deploy))
	for env := range in.Deploy {
		envs = append(envs, env)
	}
	sort.Strings(envs)
	var problems []string
	for _, env := range envs {
		if !namePattern.MatchString(env) {
			continue
		}
		if st, err := os.Stat(filepath.Join(root, "deploy", env)); err != nil || !st.IsDir() {
			problems = append(problems, fmt.Sprintf("deploy.%s: missing directory deploy/%s/", env, env))
		}
	}
	return problems
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
