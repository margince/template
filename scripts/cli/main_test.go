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

// gitCmd runs a git command with a fixed identity, failing the test on error.
func gitCmd(t *testing.T, dir string, args ...string) string {
	t.Helper()
	cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
	cmd.Env = append(os.Environ(),
		"GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@example.test",
		"GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@example.test",
		"GIT_CONFIG_NOSYSTEM=1")
	out, err := cmd.CombinedOutput()
	if err != nil {
		t.Fatalf("git %v: %v\n%s", args, err, out)
	}
	return strings.TrimSpace(string(out))
}

// remoteRepoWithTagThenCommit creates an origin repository with one commit
// tagged `tag`, followed by a second commit on the default branch — the
// shape of an upstream that has moved past the tag a downstream repo pins.
// It returns the origin directory and the SHA of the tagged commit.
func remoteRepoWithTagThenCommit(t *testing.T, tag string) (origin, taggedSHA string) {
	t.Helper()
	origin = t.TempDir()
	gitCmd(t, origin, "init", "-q")
	gitCmd(t, origin, "commit", "-q", "--allow-empty", "-m", "a")
	taggedSHA = gitCmd(t, origin, "rev-parse", "HEAD")
	gitCmd(t, origin, "tag", tag)
	gitCmd(t, origin, "commit", "-q", "--allow-empty", "-m", "b")
	return origin, taggedSHA
}

// shallowCloneAtCommit reproduces what `actions/checkout` with
// `submodules: recursive` (and `git submodule update --init --depth=1`) does
// to a submodule: a shallow clone, then fetched and checked out AT A SPECIFIC
// SHA rather than by tag or branch — so the tag pointing at that commit never
// arrives locally, even though the checkout is genuinely at that commit.
func shallowCloneAtCommit(t *testing.T, origin, sha string) string {
	t.Helper()
	clone := filepath.Join(t.TempDir(), "core")
	// --no-tags on both steps: this is what makes the SHA-pinned fetch not
	// bring the tag along, the way actions/checkout's own submodule fetch
	// does not. Without it, git's tag-following can auto-fetch a tag that
	// happens to point at a commit it already has, defeating the repro.
	cmd := exec.Command("git", "clone", "-q", "--depth=1", "--no-tags", origin, clone)
	if out, err := cmd.CombinedOutput(); err != nil {
		t.Fatalf("git clone: %v\n%s", err, out)
	}
	gitCmd(t, clone, "fetch", "-q", "--depth=1", "--no-tags", "origin", sha)
	gitCmd(t, clone, "checkout", "-q", sha)
	return clone
}

func TestRunFetchesTagMissingFromShallowClone(t *testing.T) {
	origin, sha := remoteRepoWithTagThenCommit(t, "v0.0.2")
	core := shallowCloneAtCommit(t, origin, sha)

	// Sanity: the shallow checkout by SHA really did not bring the tag.
	if tags, err := coreTags(core); err != nil || len(tags) != 0 {
		t.Fatalf("coreTags = %v, %v; want no tags before the fetch", tags, err)
	}

	var out, errOut bytes.Buffer
	code := run([]string{"check", "-file", writeFile(t, valid), "-core", core}, &out, &errOut)
	if code != 0 {
		t.Fatalf("exit %d, stderr %q, want 0 after fetching the missing tag", code, errOut.String())
	}
}

func TestRunReportsWhenOriginLacksTheTag(t *testing.T) {
	// The origin never had v0.0.2 at all, so the fetch this repo attempts to
	// recover the tag fails — distinct from a genuine mismatch.
	origin, sha := remoteRepoWithTagThenCommit(t, "v9.9.9")
	core := shallowCloneAtCommit(t, origin, sha)

	var out, errOut bytes.Buffer
	code := run([]string{"check", "-file", writeFile(t, valid), "-core", core}, &out, &errOut)
	if code != 1 {
		t.Fatalf("exit %d, want 1", code)
	}
	if !strings.Contains(errOut.String(), "cannot verify") {
		t.Fatalf("stderr %q, want it to say core: cannot verify ... fetching the tag failed", errOut.String())
	}
	if strings.Contains(errOut.String(), "not at a tag") {
		t.Fatalf("stderr %q, want the fetch-failure wording, not the stale 'not at a tag' hint", errOut.String())
	}
}

func TestCoreTagsRefusesUncheckedOutSubdirectory(t *testing.T) {
	parent := gitRepo(t, "v0.0.2")
	sub := filepath.Join(parent, "core")
	if err := os.Mkdir(sub, 0o755); err != nil {
		t.Fatal(err)
	}
	// A plain, empty subdirectory: `git -C sub` resolves to the ENCLOSING
	// repository, which is tagged — a false pass unless coreTags rejects it.
	if _, err := coreTags(sub); err == nil || !strings.Contains(err.Error(), "not a checked-out git repository") {
		t.Fatalf("coreTags(empty subdir) = %v, want an error naming it not checked out", err)
	}
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
	// core/ has an origin, and a fetch of the wanted tag would succeed
	// against it (v0.0.2 exists there, at a different commit) — the
	// point of this case is that the fetch does not paper over a REAL
	// mismatch: core/ is genuinely checked out at v0.0.1.
	origin, _ := remoteRepoWithTagThenCommit(t, "v0.0.1")
	gitCmd(t, origin, "tag", "v0.0.2")

	core := filepath.Join(t.TempDir(), "core")
	if out, err := exec.Command("git", "clone", "-q", "--branch", "v0.0.1", origin, core).CombinedOutput(); err != nil {
		t.Fatalf("git clone: %v\n%s", err, out)
	}

	var out, errOut bytes.Buffer
	code := run([]string{"check", "-file", writeFile(t, valid), "-core", core}, &out, &errOut)
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
