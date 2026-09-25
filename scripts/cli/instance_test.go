package main

import (
	"strings"
	"testing"
)

const valid = `name: margince-default
display_name: Margince Default
core: v0.0.2
flavor: margince/margince
`

func TestParseValid(t *testing.T) {
	in, err := Parse([]byte(valid))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	want := Instance{Name: "margince-default", DisplayName: "Margince Default", Core: "v0.0.2", Flavor: "margince/margince"}
	if in != want {
		t.Fatalf("Parse = %+v, want %+v", in, want)
	}
	if p := in.Validate(); len(p) != 0 {
		t.Fatalf("Validate = %v, want no problems", p)
	}
}

func TestParseRefusesUnknownKey(t *testing.T) {
	_, err := Parse([]byte(valid + "flavour: acme/margince\n"))
	if err == nil || !strings.Contains(err.Error(), "flavour") {
		t.Fatalf("Parse error = %v, want one naming the key flavour", err)
	}
}

func TestParseRefusesEmptyFile(t *testing.T) {
	if _, err := Parse(nil); err == nil {
		t.Fatal("Parse(empty) succeeded, want an error")
	}
}

func TestValidate(t *testing.T) {
	cases := []struct {
		name string
		in   Instance
		want string
	}{
		{"missing name", Instance{DisplayName: "D", Core: "v1", Flavor: "a/margince"}, "name: required"},
		{"upper-case name", Instance{Name: "Acme", DisplayName: "D", Core: "v1", Flavor: "a/margince"}, "name: \"Acme\""},
		{"long name", Instance{Name: strings.Repeat("a", 33), DisplayName: "D", Core: "v1", Flavor: "a/margince"}, "at most 32"},
		{"missing display name", Instance{Name: "a", Core: "v1", Flavor: "a/margince"}, "display_name: required"},
		{"blank display name", Instance{Name: "a", DisplayName: "  ", Core: "v1", Flavor: "a/margince"}, "display_name: required"},
		{"multi-line display name", Instance{Name: "a", DisplayName: "A\nB", Core: "v1", Flavor: "a/margince"}, "single line"},
		{"missing core", Instance{Name: "a", DisplayName: "D", Flavor: "a/margince"}, "core: required"},
		{"core is a branch, not a release tag", Instance{Name: "a", DisplayName: "D", Core: "main", Flavor: "a/margince"}, "release tag like v0.0.2"},
		{"core is a non-release tag", Instance{Name: "a", DisplayName: "D", Core: "archive/pr100-salvage", Flavor: "a/margince"}, "release tag like v0.0.2"},
		{"missing flavor", Instance{Name: "a", DisplayName: "D", Core: "v1"}, "flavor: required"},
		{"flavor without product", Instance{Name: "a", DisplayName: "D", Core: "v1", Flavor: "acme"}, "<vendor>/margince"},
		{"flavor with other product", Instance{Name: "a", DisplayName: "D", Core: "v1", Flavor: "acme/crm"}, "<vendor>/margince"},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			problems := strings.Join(c.in.Validate(), "\n")
			if !strings.Contains(problems, c.want) {
				t.Fatalf("Validate = %q, want a problem containing %q", problems, c.want)
			}
		})
	}
}

func TestCheckCore(t *testing.T) {
	if p := CheckCore("v0.0.2", []string{"v0.0.2"}); p != "" {
		t.Fatalf("matching tag: %q, want no problem", p)
	}
	if p := CheckCore("v0.0.2", []string{"latest", "v0.0.2"}); p != "" {
		t.Fatalf("one of several tags: %q, want no problem", p)
	}
	if p := CheckCore("v0.0.2", nil); !strings.Contains(p, "not at a tag") {
		t.Fatalf("no tag: %q, want 'not at a tag'", p)
	}
	if p := CheckCore("v0.0.2", []string{"v0.0.1"}); !strings.Contains(p, "v0.0.1") {
		t.Fatalf("other tag: %q, want it to name v0.0.1", p)
	}
}
