package main

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// gitRepo creates a repository with one commit, tagged with each given tag.
func gitRepo(t *testing.T, tags ...string) string {
	t.Helper()
	dir := t.TempDir()
	run := func(args ...string) {
		cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
		cmd.Env = append(os.Environ(),
			"GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@example.test",
			"GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@example.test",
			"GIT_CONFIG_NOSYSTEM=1")
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	run("init", "-q")
	run("commit", "-q", "--allow-empty", "-m", "c")
	for _, tag := range tags {
		run("tag", tag)
	}
	return dir
}

func writeFile(t *testing.T, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "instance.yaml")
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestRunOK(t *testing.T) {
	var out, errOut bytes.Buffer
	code := run([]string{"check", "-file", writeFile(t, valid), "-core", gitRepo(t, "v0.0.2")}, &out, &errOut)
	if code != 0 {
		t.Fatalf("exit %d, stderr %q", code, errOut.String())
	}
	if !strings.Contains(out.String(), "instance.yaml: ok (margince-default, core v0.0.2)") {
		t.Fatalf("stdout %q", out.String())
	}
}

func TestRunCoreMismatch(t *testing.T) {
	var out, errOut bytes.Buffer
	code := run([]string{"check", "-file", writeFile(t, valid), "-core", gitRepo(t, "v0.0.1")}, &out, &errOut)
	if code != 1 || !strings.Contains(errOut.String(), "v0.0.1") {
		t.Fatalf("exit %d, stderr %q; want 1 naming v0.0.1", code, errOut.String())
	}
}

func TestRunReportsEveryProblem(t *testing.T) {
	var out, errOut bytes.Buffer
	code := run([]string{"check", "-file", writeFile(t, "name: Bad\n"), "-core", gitRepo(t)}, &out, &errOut)
	if code != 1 {
		t.Fatalf("exit %d, want 1", code)
	}
	for _, want := range []string{"name:", "display_name: required", "core: required", "flavor: required"} {
		if !strings.Contains(errOut.String(), want) {
			t.Errorf("stderr %q lacks %q", errOut.String(), want)
		}
	}
}

func TestRunMissingFile(t *testing.T) {
	var out, errOut bytes.Buffer
	if code := run([]string{"check", "-file", filepath.Join(t.TempDir(), "none.yaml")}, &out, &errOut); code != 1 {
		t.Fatalf("exit %d, want 1", code)
	}
}

func TestRunUsage(t *testing.T) {
	var out, errOut bytes.Buffer
	if code := run(nil, &out, &errOut); code != 2 {
		t.Fatalf("no command: exit %d, want 2", code)
	}
	if code := run([]string{"frobnicate"}, &out, &errOut); code != 2 {
		t.Fatalf("unknown command: exit %d, want 2", code)
	}
}
