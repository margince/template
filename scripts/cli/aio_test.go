package main

import (
	"bytes"
	"path/filepath"
	"strings"
	"testing"

	"gopkg.in/yaml.v3"
)

const prodConfig = `version: 1
workspace:
  name: "Acme Corp"
  base_currency: EUR
  timezone: Europe/Berlin
bootstrap_admin:
  email: "owner@acme.example"
  display_name: Owner
  password_file: other/path
mcp:
  connector_enabled: true
email:
  enabled: true
  smtp:
    host: smtp.acme.example
seeds:
  ai_routing: {}
`

func decode(t *testing.T, data []byte) map[string]any {
	t.Helper()
	var m map[string]any
	if err := yaml.Unmarshal(data, &m); err != nil {
		t.Fatalf("output is not YAML: %v\n%s", err, data)
	}
	return m
}

func TestAIOConfigOverrides(t *testing.T) {
	out, err := AIOConfig(writeFile(t, prodConfig), "")
	if err != nil {
		t.Fatal(err)
	}
	m := decode(t, out)
	admin := m["bootstrap_admin"].(map[string]any)
	if admin["email"] != "admin@localhost" || admin["password_file"] != "secrets/admin-password" || admin["display_name"] != "Owner" {
		t.Fatalf("bootstrap_admin = %v", admin)
	}
	if m["mcp"].(map[string]any)["connector_enabled"] != false {
		t.Fatalf("mcp = %v", m["mcp"])
	}
	email := m["email"].(map[string]any)
	if len(email) != 1 || email["enabled"] != false {
		t.Fatalf("email = %v, want only enabled: false", email)
	}
	ws := m["workspace"].(map[string]any)
	if ws["name"] != "Acme Corp" || ws["timezone"] != "Europe/Berlin" {
		t.Fatalf("workspace = %v", ws)
	}
	if _, ok := m["seeds"]; !ok {
		t.Fatal("seeds was dropped")
	}
}

func TestAIOConfigAddsMissingBlocks(t *testing.T) {
	out, err := AIOConfig(writeFile(t, "version: 1\nworkspace:\n  name: A\n  base_currency: EUR\n  timezone: UTC\n"), "")
	if err != nil {
		t.Fatal(err)
	}
	m := decode(t, out)
	admin := m["bootstrap_admin"].(map[string]any)
	if admin["email"] != "admin@localhost" || admin["display_name"] != "Admin" {
		t.Fatalf("bootstrap_admin = %v", admin)
	}
}

func TestAIOConfigDefaultWithoutFile(t *testing.T) {
	missing := filepath.Join(t.TempDir(), "margince.yaml")
	out, err := AIOConfig(missing, `Acme #1: "Co"`)
	if err != nil {
		t.Fatal(err)
	}
	m := decode(t, out)
	ws := m["workspace"].(map[string]any)
	if ws["name"] != `Acme #1: "Co"` || ws["base_currency"] != "EUR" || ws["timezone"] != "UTC" {
		t.Fatalf("workspace = %v", ws)
	}
	if m["bootstrap_admin"].(map[string]any)["email"] != "admin@localhost" {
		t.Fatalf("bootstrap_admin = %v", m["bootstrap_admin"])
	}
}

func TestAIOConfigRefusals(t *testing.T) {
	missing := filepath.Join(t.TempDir(), "margince.yaml")
	if _, err := AIOConfig(missing, ""); err == nil || !strings.Contains(err.Error(), "-display-name") {
		t.Fatalf("missing file without display name: err = %v", err)
	}
	if _, err := AIOConfig(writeFile(t, "- a list\n"), ""); err == nil {
		t.Fatal("a top-level list was accepted")
	}
	if _, err := AIOConfig(writeFile(t, "a: [unclosed\n"), ""); err == nil {
		t.Fatal("invalid YAML was accepted")
	}
}

func TestRunAIOConfig(t *testing.T) {
	var out, errOut bytes.Buffer
	if code := run([]string{"aio-config", "-file", writeFile(t, prodConfig)}, &out, &errOut); code != 0 {
		t.Fatalf("exit %d, stderr %q", code, errOut.String())
	}
	if !strings.Contains(out.String(), "admin@localhost") {
		t.Fatalf("stdout %q", out.String())
	}
	out.Reset()
	errOut.Reset()
	if code := run([]string{"aio-config", "-file", filepath.Join(t.TempDir(), "x.yaml")}, &out, &errOut); code != 1 {
		t.Fatalf("exit %d, want 1", code)
	}
	if !strings.HasPrefix(errOut.String(), "aio-config: ") {
		t.Fatalf("stderr %q", errOut.String())
	}
}

// core resolves bootstrap_admin.password before password_file, so a
// production reference such as ${file:/run/secrets/...} would win and point
// at a path the image does not have.
func TestAIOConfigDropsPasswordReference(t *testing.T) {
	in := "version: 1\nworkspace:\n  name: A\n  base_currency: EUR\n  timezone: UTC\n" +
		"bootstrap_admin:\n  email: a@b.example\n  password: ${file:/run/secrets/admin-password}\n"
	out, err := AIOConfig(writeFile(t, in), "")
	if err != nil {
		t.Fatal(err)
	}
	admin := decode(t, out)["bootstrap_admin"].(map[string]any)
	if _, ok := admin["password"]; ok {
		t.Fatalf("bootstrap_admin.password was kept: %v", admin)
	}
	if admin["password_file"] != "secrets/admin-password" {
		t.Fatalf("bootstrap_admin = %v", admin)
	}
}
