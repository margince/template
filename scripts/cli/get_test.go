package main

import (
	"bytes"
	"path/filepath"
	"strings"
	"testing"
)

func TestRunGetEachKey(t *testing.T) {
	file := writeFile(t, valid)
	for key, want := range map[string]string{
		"name":         "margince-default",
		"display_name": "Margince Default",
		"core":         "v0.0.2",
	} {
		var out, errOut bytes.Buffer
		if code := run([]string{"get", "-file", file, key}, &out, &errOut); code != 0 {
			t.Fatalf("get %s: exit %d, stderr %q", key, code, errOut.String())
		}
		if got := strings.TrimSpace(out.String()); got != want {
			t.Fatalf("get %s = %q, want %q", key, got, want)
		}
	}
}

func TestRunGetUnknownKey(t *testing.T) {
	var out, errOut bytes.Buffer
	if code := run([]string{"get", "-file", writeFile(t, valid), "units"}, &out, &errOut); code != 2 {
		t.Fatalf("exit %d, want 2", code)
	}
	if !strings.Contains(errOut.String(), `unknown key "units"`) {
		t.Fatalf("stderr %q", errOut.String())
	}
}

func TestRunGetEmptyValue(t *testing.T) {
	var out, errOut bytes.Buffer
	if code := run([]string{"get", "-file", writeFile(t, "name: a\n"), "core"}, &out, &errOut); code != 1 {
		t.Fatalf("exit %d, want 1", code)
	}
}

func TestRunGetMissingFile(t *testing.T) {
	var out, errOut bytes.Buffer
	if code := run([]string{"get", "-file", filepath.Join(t.TempDir(), "none.yaml"), "name"}, &out, &errOut); code != 1 {
		t.Fatalf("exit %d, want 1", code)
	}
}

func TestRunGetUsage(t *testing.T) {
	var out, errOut bytes.Buffer
	if code := run([]string{"get"}, &out, &errOut); code != 2 {
		t.Fatalf("no key: exit %d, want 2", code)
	}
}

func TestRunGetDataDataset(t *testing.T) {
	var out, errOut bytes.Buffer
	file := writeFile(t, valid+"data:\n  dataset: git@example.test:org/demo.git@v1.0.0\n")
	if code := run([]string{"get", "-file", file, "data.dataset"}, &out, &errOut); code != 0 {
		t.Fatalf("exit %d, stderr %q", code, errOut.String())
	}
	if got := strings.TrimSpace(out.String()); got != "git@example.test:org/demo.git@v1.0.0" {
		t.Fatalf("get data.dataset = %q", got)
	}
}

func TestRunGetDataDatasetAbsent(t *testing.T) {
	var out, errOut bytes.Buffer
	if code := run([]string{"get", "-file", writeFile(t, valid), "data.dataset"}, &out, &errOut); code != 2 {
		t.Fatalf("exit %d, want 2", code)
	}
}
