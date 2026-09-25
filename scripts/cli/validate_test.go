package main

import (
	"bytes"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestRunValidateOK(t *testing.T) {
	file := writeFile(t, valid+"deploy:\n  staging: { adapter: hook }\n")
	if err := os.MkdirAll(filepath.Join(filepath.Dir(file), "deploy", "staging"), 0o755); err != nil {
		t.Fatal(err)
	}
	var out, errOut bytes.Buffer
	if code := run([]string{"validate", "-file", file}, &out, &errOut); code != 0 {
		t.Fatalf("exit %d, stderr %q", code, errOut.String())
	}
	if got := strings.TrimSpace(out.String()); got != "instance.yaml: valid" {
		t.Fatalf("stdout %q, want %q", got, "instance.yaml: valid")
	}
}

// validate never looks at core/: the file's directory has no core checkout,
// and a core tag that no checkout could confirm is still valid.
func TestRunValidateIgnoresCore(t *testing.T) {
	var out, errOut bytes.Buffer
	if code := run([]string{"validate", "-file", writeFile(t, valid)}, &out, &errOut); code != 0 {
		t.Fatalf("exit %d, stderr %q", code, errOut.String())
	}
}

func TestRunValidateReportsEachProblemOnItsOwnLine(t *testing.T) {
	body := "name: Bad\ndisplay_name: X\ncore: v0.0.2\nflavor: acme/margince\n" +
		"deploy:\n  staging: { adapter: d13 }\n  Prod: { adapter: hook }\n  qa: { adapter: hook }\n"
	var out, errOut bytes.Buffer
	if code := run([]string{"validate", "-file", writeFile(t, body)}, &out, &errOut); code != 1 {
		t.Fatalf("exit %d, want 1", code)
	}
	lines := strings.Split(strings.TrimSpace(errOut.String()), "\n")
	for _, want := range []string{
		`instance.yaml: name: "Bad"`,
		`instance.yaml: deploy: environment "Prod" must match`,
		"instance.yaml: deploy.staging.adapter: d13 is not available yet (issue D1)",
		"instance.yaml: deploy.qa: missing directory deploy/qa/",
		"instance.yaml: deploy.staging: missing directory deploy/staging/",
	} {
		found := false
		for _, l := range lines {
			if strings.HasPrefix(l, want) {
				found = true
			}
		}
		if !found {
			t.Errorf("stderr lines %q lack one starting %q", lines, want)
		}
	}
	if len(lines) != 5 {
		t.Errorf("got %d lines, want 5 (one per problem): %q", len(lines), lines)
	}
	if out.Len() != 0 {
		t.Errorf("stdout %q, want nothing on failure", out.String())
	}
}

func TestRunValidateUnreadable(t *testing.T) {
	var out, errOut bytes.Buffer
	if code := run([]string{"validate", "-file", filepath.Join(t.TempDir(), "none.yaml")}, &out, &errOut); code != 1 {
		t.Fatalf("missing file: exit %d, want 1", code)
	}
	errOut.Reset()
	if code := run([]string{"validate", "-file", writeFile(t, "name: a\n  bad: [x\n")}, &out, &errOut); code != 1 {
		t.Fatalf("malformed file: exit %d, want 1", code)
	}
	if !strings.HasPrefix(errOut.String(), "instance.yaml: ") {
		t.Fatalf("stderr %q", errOut.String())
	}
}

func TestRunValidateUsage(t *testing.T) {
	var out, errOut bytes.Buffer
	if code := run([]string{"validate", "extra"}, &out, &errOut); code != 2 {
		t.Fatalf("extra argument: exit %d, want 2", code)
	}
}
