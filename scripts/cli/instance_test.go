package main

import (
	"reflect"
	"strings"
	"testing"
)

const valid = `name: margince-default
display_name: Margince Default
core: v0.0.2
`

func TestParseValid(t *testing.T) {
	in, err := Parse([]byte(valid))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	want := Instance{Name: "margince-default", DisplayName: "Margince Default", Core: "v0.0.2"}
	if !reflect.DeepEqual(in, want) {
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

// flavor is gone: an instance.yaml still naming it is refused as an unknown
// key, the same as any other misspelling.
func TestParseRefusesFlavorAsUnknownKey(t *testing.T) {
	_, err := Parse([]byte(valid + "flavor: a/margince\n"))
	if err == nil || !strings.Contains(err.Error(), "flavor") {
		t.Fatalf("Parse error = %v, want one naming the key flavor", err)
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
		{"missing name", Instance{DisplayName: "D", Core: "v1"}, "name: required"},
		{"upper-case name", Instance{Name: "Acme", DisplayName: "D", Core: "v1"}, "name: \"Acme\""},
		{"long name", Instance{Name: strings.Repeat("a", 33), DisplayName: "D", Core: "v1"}, "at most 32"},
		{"missing display name", Instance{Name: "a", Core: "v1"}, "display_name: required"},
		{"blank display name", Instance{Name: "a", DisplayName: "  ", Core: "v1"}, "display_name: required"},
		{"multi-line display name", Instance{Name: "a", DisplayName: "A\nB", Core: "v1"}, "single line"},
		{"missing core", Instance{Name: "a", DisplayName: "D"}, "core: required"},
		{"core is a branch, not a release tag", Instance{Name: "a", DisplayName: "D", Core: "main"}, "release tag like v0.0.2"},
		{"core is a non-release tag", Instance{Name: "a", DisplayName: "D", Core: "archive/pr100-salvage"}, "release tag like v0.0.2"},
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

func TestParseDeploy(t *testing.T) {
	in, err := Parse([]byte(valid + "deploy:\n  staging: { adapter: hook }\n"))
	if err != nil {
		t.Fatalf("Parse: %v", err)
	}
	if got, ok := in.Value("deploy.staging.adapter"); !ok || got != "hook" {
		t.Fatalf("Value(deploy.staging.adapter) = %q, %v", got, ok)
	}
	if _, ok := in.Value("deploy.production.adapter"); ok {
		t.Fatal("Value for an absent environment reported ok")
	}
	if p := in.Validate(); len(p) != 0 {
		t.Fatalf("Validate = %v", p)
	}
}

func TestValidateDeploy(t *testing.T) {
	base := Instance{Name: "a", DisplayName: "A", Core: "v0.0.2"}
	cases := []struct {
		name   string
		deploy map[string]DeployTarget
		want   string
	}{
		{"bad environment name", map[string]DeployTarget{"Prod": {Adapter: "hook"}}, `deploy: environment "Prod"`},
		{"missing adapter", map[string]DeployTarget{"prod": {}}, "deploy.prod.adapter: required"},
		{"ftp refused by the generic adapter message", map[string]DeployTarget{"prod": {Adapter: "ftp"}}, `deploy.prod.adapter: "ftp" is not an adapter (want hook or host)`},
		{"unknown adapter", map[string]DeployTarget{"prod": {Adapter: "ssh"}}, `deploy.prod.adapter: "ssh" is not an adapter (want hook or host)`},
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			in := base
			in.Deploy = c.deploy
			if got := strings.Join(in.Validate(), "\n"); !strings.Contains(got, c.want) {
				t.Fatalf("Validate = %q, want %q", got, c.want)
			}
		})
	}
}

func TestValidateAcceptsHostAdapter(t *testing.T) {
	in := Instance{Name: "a", DisplayName: "A", Core: "v0.0.2", Deploy: map[string]DeployTarget{"prod": {Adapter: "host"}}}
	if p := in.Validate(); len(p) != 0 {
		t.Fatalf("Validate = %v, want no problems for adapter: host", p)
	}
}

func TestParseRefusesUnknownDeployKey(t *testing.T) {
	if _, err := Parse([]byte(valid + "deploy:\n  staging: { adaptor: hook }\n")); err == nil {
		t.Fatal("Parse accepted deploy.staging.adaptor")
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
