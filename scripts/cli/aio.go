package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"io/fs"
	"os"

	"gopkg.in/yaml.v3"
)

// runAIOConfig prints the all-in-one image's first-boot configuration
// (docs/superpowers/specs/2026-09-30-all-in-one-image-design.md, Section 7.1).
func runAIOConfig(args []string, stdout, stderr io.Writer) int {
	fset := flag.NewFlagSet("aio-config", flag.ContinueOnError)
	fset.SetOutput(stderr)
	file := fset.String("file", "deploy/production/config/margince.yaml", "the production margince.yaml")
	display := fset.String("display-name", "", "the workspace name when -file does not exist")
	if err := fset.Parse(args); err != nil {
		return 2
	}
	out, err := AIOConfig(*file, *display)
	if err != nil {
		fmt.Fprintf(stderr, "aio-config: %v\n", err)
		return 1
	}
	if _, err := stdout.Write(out); err != nil {
		fmt.Fprintf(stderr, "aio-config: %v\n", err)
		return 1
	}
	return 0
}

// aioDefault is the configuration of an instance without
// deploy/production/config/margince.yaml. workspace.name is set from
// display_name after parsing, so no quoting rule is needed here.
const aioDefault = `version: 1
workspace:
  name: ""
  base_currency: EUR
  timezone: UTC
`

// AIOConfig reads file, or the default when file does not exist, and applies
// the all-in-one overrides. Every key it does not override is kept.
func AIOConfig(file, displayName string) ([]byte, error) {
	data, err := os.ReadFile(file)
	fromDefault := false
	switch {
	case errors.Is(err, fs.ErrNotExist):
		if displayName == "" {
			return nil, fmt.Errorf("%s does not exist and no -display-name was given", file)
		}
		data, fromDefault = []byte(aioDefault), true
	case err != nil:
		return nil, err
	}

	var doc yaml.Node
	if err := yaml.Unmarshal(data, &doc); err != nil {
		return nil, fmt.Errorf("%s: %v", file, err)
	}
	if doc.Kind != yaml.DocumentNode || len(doc.Content) != 1 || doc.Content[0].Kind != yaml.MappingNode {
		return nil, fmt.Errorf("%s: the top level is not a mapping", file)
	}
	root := doc.Content[0]
	if fromDefault {
		setScalar(root, "!!str", displayName, "workspace", "name")
	}
	setScalar(root, "!!str", "admin@localhost", "bootstrap_admin", "email")
	if lookup(root, "bootstrap_admin", "display_name") == nil {
		setScalar(root, "!!str", "Admin", "bootstrap_admin", "display_name")
	}
	setScalar(root, "!!str", "secrets/admin-password", "bootstrap_admin", "password_file")
	setScalar(root, "!!bool", "false", "mcp", "connector_enabled")
	setValue(root, "email", &yaml.Node{Kind: yaml.MappingNode, Tag: "!!map", Content: []*yaml.Node{
		{Kind: yaml.ScalarNode, Tag: "!!str", Value: "enabled"},
		{Kind: yaml.ScalarNode, Tag: "!!bool", Value: "false"},
	}})
	return yaml.Marshal(&doc)
}

// lookup returns the value node at path, or nil.
func lookup(m *yaml.Node, path ...string) *yaml.Node {
	for _, key := range path {
		if m == nil || m.Kind != yaml.MappingNode {
			return nil
		}
		var next *yaml.Node
		for i := 0; i+1 < len(m.Content); i += 2 {
			if m.Content[i].Value == key {
				next = m.Content[i+1]
				break
			}
		}
		m = next
	}
	return m
}

// setValue sets key in mapping m to value, adding the key when it is absent.
func setValue(m *yaml.Node, key string, value *yaml.Node) {
	for i := 0; i+1 < len(m.Content); i += 2 {
		if m.Content[i].Value == key {
			m.Content[i+1] = value
			return
		}
	}
	m.Content = append(m.Content, &yaml.Node{Kind: yaml.ScalarNode, Tag: "!!str", Value: key}, value)
}

// setScalar sets the scalar at path, creating (or replacing non-mapping)
// intermediate mappings.
func setScalar(m *yaml.Node, tag, value string, path ...string) {
	for _, key := range path[:len(path)-1] {
		next := lookup(m, key)
		if next == nil || next.Kind != yaml.MappingNode {
			next = &yaml.Node{Kind: yaml.MappingNode, Tag: "!!map"}
			setValue(m, key, next)
		}
		m = next
	}
	setValue(m, path[len(path)-1], &yaml.Node{Kind: yaml.ScalarNode, Tag: tag, Value: value})
}
