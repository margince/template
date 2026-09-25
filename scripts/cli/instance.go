package main

import (
	"bytes"
	"errors"
	"fmt"
	"io"
	"regexp"
	"sort"
	"strings"

	"gopkg.in/yaml.v3"
)

// Instance is the content of instance.yaml. Later issues add fields; an
// unknown key is refused so a misspelling is never silently ignored.
type Instance struct {
	Name        string                  `yaml:"name"`
	DisplayName string                  `yaml:"display_name"`
	Core        string                  `yaml:"core"`
	Flavor      string                  `yaml:"flavor"`
	Deploy      map[string]DeployTarget `yaml:"deploy"`
}

// DeployTarget is one environment under deploy: in instance.yaml.
type DeployTarget struct {
	Adapter string `yaml:"adapter"`
}

var (
	namePattern    = regexp.MustCompile(`^[a-z0-9]+(-[a-z0-9]+)*$`)
	flavorPattern  = regexp.MustCompile(`^[a-z0-9]+(-[a-z0-9]+)*/margince$`)
	coreTagPattern = regexp.MustCompile(`^v[0-9]+\.[0-9]+\.[0-9]+$`)
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
	if env, ok := strings.CutPrefix(key, "deploy."); ok {
		if env, ok = strings.CutSuffix(env, ".adapter"); ok {
			if t, found := in.Deploy[env]; found {
				return t.Adapter, true
			}
		}
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
	switch {
	case in.Core == "":
		problems = append(problems, "core: required")
	case !coreTagPattern.MatchString(in.Core):
		problems = append(problems, fmt.Sprintf("core: %q must be a release tag like v0.0.2", in.Core))
	}
	switch {
	case in.Flavor == "":
		problems = append(problems, "flavor: required")
	case !flavorPattern.MatchString(in.Flavor):
		problems = append(problems, fmt.Sprintf("flavor: %q must have the form <vendor>/margince", in.Flavor))
	}
	envs := make([]string, 0, len(in.Deploy))
	for env := range in.Deploy {
		envs = append(envs, env)
	}
	sort.Strings(envs)
	for _, env := range envs {
		if !namePattern.MatchString(env) {
			problems = append(problems, fmt.Sprintf("deploy: environment %q must match ^[a-z0-9]+(-[a-z0-9]+)*$", env))
			continue
		}
		switch adapter := in.Deploy[env].Adapter; adapter {
		case "":
			problems = append(problems, fmt.Sprintf("deploy.%s.adapter: required", env))
		case "hook":
		case "d13":
			problems = append(problems, fmt.Sprintf("deploy.%s.adapter: d13 is not available yet (issue D1); use hook", env))
		default:
			problems = append(problems, fmt.Sprintf("deploy.%s.adapter: %q is not an adapter (want hook)", env, adapter))
		}
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
