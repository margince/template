package main

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"regexp"
	"strings"

	"gopkg.in/yaml.v3"
)

// Instance is the content of instance.yaml. Later issues add fields; an
// unknown key is refused so a misspelling is never silently ignored.
type Instance struct {
	Name        string `yaml:"name"`
	DisplayName string `yaml:"display_name"`
	Core        string `yaml:"core"`
	Flavor      string `yaml:"flavor"`
}

var (
	namePattern   = regexp.MustCompile(`^[a-z0-9]+(-[a-z0-9]+)*$`)
	flavorPattern = regexp.MustCompile(`^[a-z0-9]+(-[a-z0-9]+)*/margince$`)
)

// Parse decodes instance.yaml and refuses unknown keys.
func Parse(data []byte) (Instance, error) {
	var in Instance
	dec := yaml.NewDecoder(bytes.NewReader(data))
	dec.KnownFields(true)
	if err := dec.Decode(&in); err != nil {
		if errors.Is(err, io.EOF) {
			return in, errors.New("the file is empty")
		}
		return in, err
	}
	return in, nil
}

// Value returns the value of one instance.yaml key by its YAML name.
func (in Instance) Value(key string) (string, bool) {
	switch key {
	case "name":
		return in.Name, true
	case "display_name":
		return in.DisplayName, true
	case "core":
		return in.Core, true
	case "flavor":
		return in.Flavor, true
	}
	return "", false
}

// Validate returns one message per problem, or nil.
func (in Instance) Validate() []string {
	var problems []string
	switch {
	case in.Name == "":
		problems = append(problems, "name: required")
	case len(in.Name) > 32 || !namePattern.MatchString(in.Name):
		problems = append(problems, fmt.Sprintf("name: %q must match ^[a-z0-9]+(-[a-z0-9]+)*$ and be at most 32 characters", in.Name))
	}
	switch {
	case strings.TrimSpace(in.DisplayName) == "":
		problems = append(problems, "display_name: required")
	case strings.ContainsAny(in.DisplayName, "\r\n"):
		problems = append(problems, "display_name: must be a single line")
	}
	if in.Core == "" {
		problems = append(problems, "core: required")
	}
	switch {
	case in.Flavor == "":
		problems = append(problems, "flavor: required")
	case !flavorPattern.MatchString(in.Flavor):
		problems = append(problems, fmt.Sprintf("flavor: %q must have the form <vendor>/margince", in.Flavor))
	}
	return problems
}

// CheckCore compares the core version in instance.yaml with the tags that
// point at core/ HEAD. It returns a problem message, or "".
func CheckCore(want string, tags []string) string {
	for _, tag := range tags {
		if tag == want {
			return ""
		}
	}
	if len(tags) == 0 {
		return fmt.Sprintf("core: core/ is not at a tag, but instance.yaml says %q; pin it with make update-core REF=%s", want, want)
	}
	return fmt.Sprintf("core: instance.yaml says %q, but core/ is at %s", want, strings.Join(tags, ", "))
}
