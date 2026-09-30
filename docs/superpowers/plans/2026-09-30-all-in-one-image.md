# All-in-One Image Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One Docker image per instance release that runs all of Margince, and one command (plus `make aio-*` wrappers) that installs Docker when it is missing and starts it.

**Architecture:** `scripts/aio/Dockerfile` copies the binaries of the `api`, `worker`, and `web` role images onto `pgvector/pgvector:pg16` and adds nginx, Redis, `tini`, and three bash scripts (`margince-init`, `margince-seed`, `margince-logins`). `scripts/aio.sh` assembles the build context, builds, smoke-tests, and renders the install scripts. `scripts/aio/install.sh` (POSIX sh) and `scripts/aio/install.ps1` (PowerShell) install Docker and manage the container; the `make aio-*` targets call them.

**Tech Stack:** bash, POSIX sh, PowerShell 5.1+, Go (`scripts/cli`, `gopkg.in/yaml.v3`), Docker Buildx, nginx, PostgreSQL 16 + pgvector, Redis, GitHub Actions.

**Spec:** [docs/superpowers/specs/2026-09-30-all-in-one-image-design.md](../specs/2026-09-30-all-in-one-image-design.md)

## Global Constraints

- Image name: `<image_repo>/all-in-one:<version>`; `<version>` must pass `is_release_version`.
- Container name `margince-<name>`, volume `margince-<name>-data`, container port 80, host port `127.0.0.1:<port>`, port 8080 else the first free of 8081–8099.
- The container takes no environment variable, file, or flag. Fixed settings: `MARGINCE_ENV=test`, `MARGINCE_CONFIG=/etc/margince/margince.yaml`, `MARGINCE_OWNER_DSN=postgres://margince_owner@/margince?host=/run/postgresql`, `MARGINCE_DSN=postgres://margince_app@/margince?host=/run/postgresql`, `MARGINCE_REDIS=127.0.0.1:6379`, `MARGINCE_BLOBSTORE_PATH=/data/blobs`.
- Generated values live in `/data/secrets.env` (mode 600) and reach only the api and the worker; the worker gets neither the owner DSN nor the admin password.
- Admin sign-in: `admin@localhost`, the generated password; seeded installations use `demo-password-123`, colleagues `1234`.
- No secret on a command line, in a log, or in a stub-recorded argument.
- Timeouts: api ready 300 s, Docker start 180 s, container healthy 600 s.
- Public-only rule: no private repository, host, or organization name anywhere outside `docs/superpowers/` (`make check-public`).
- Writing style of `AGENTS.md` for every document; every `make <word>` in docs must be a real target (`make check-docs`).
- Each new `*.test.sh` is added to `test-scripts` in the `Makefile`.
- Conventional Commits, one logical change per commit, ending with the `Co-Authored-By` line.

## Review Focus

1. **Safari and the session cookie over plain `http://localhost`.** If the api sets `Secure` cookies, Safari may refuse them on http. `aio-smoke` records the `Set-Cookie` flags of the login response (Task 4), and the guide states the browsers that work (Task 8).
2. **A tester runs `up` twice at once or while the first start is still migrating.** The second run must find the running container and wait for `healthy` instead of creating a second one — covered by the "running container" case in Task 5.
3. **The pasted command has no terminal (`curl | sh` inside CI or an IDE task).** `ask` must fail with a message that names `--yes`, not hang — Task 5 test "no terminal".
4. **Interrupted first start (Docker Desktop quit mid-initdb).** The next start must finish initialization: PostgreSQL init is gated on `PG_VERSION`, secrets are written through a temporary file and a rename, and `db-bootstrap.sql` is idempotent and runs on every start — Task 2 static checks and Task 4 restart case.
5. **A port that was free when the container was made is taken later.** `docker start` then fails; `up` must recreate the container on a free port, keeping the volume — Task 5 test "stopped container whose port is taken".

---

## File Structure

| Path | Responsibility |
|---|---|
| `scripts/cli/aio.go`, `scripts/cli/aio_test.go` | `cli aio-config`: the image's first-boot `margince.yaml`. |
| `scripts/cli/main.go` | Dispatch `aio-config`. |
| `scripts/aio/Dockerfile` | The image. |
| `scripts/aio/nginx.conf` | Routing: api paths, SPA, 404 for internal endpoints. |
| `scripts/aio/margince-init` | Process start, order, and stop inside the container. |
| `scripts/aio/margince-seed` | One demo-data load inside the container. |
| `scripts/aio/margince-logins` | Print the accounts inside the container. |
| `scripts/aio/install.sh` | Tester command for macOS and Ubuntu; `make aio-*` backend. |
| `scripts/aio/install.ps1` | Tester command for Windows. |
| `scripts/aio.sh` | `build`, `smoke`, `scripts`, and the `up`/`down`/`reset`/`logins`/`logs` wrappers. |
| `scripts/aio.test.sh` | Stubbed tests of `aio.sh` and static checks of `scripts/aio/`. |
| `scripts/aio-install.test.sh` | Stubbed tests of `install.sh`. |
| `scripts/aio-install.test.ps1` | Stubbed tests of `install.ps1`. |
| `scripts/desktop.sh` | `build_seeder` gains `linux-amd64` and `linux-arm64`. |
| `Makefile` | `aio`, `aio-up`, `aio-down`, `aio-reset`, `aio-logins`, `aio-logs`, `aio-smoke`, `aio-scripts`; `test-scripts` entries. |
| `.gitignore` | `/build/aio/`. |
| `.github/workflows/release.yml` | Build, smoke, push, scripts, attach. |
| `docs/try-margince.md`, `README.md`, `docs/README.md`, `docs/glossary.md`, `docs/troubleshooting.md` | Documentation. |

---

### Task 1: `cli aio-config`

**Files:**
- Create: `scripts/cli/aio.go`
- Create: `scripts/cli/aio_test.go`
- Modify: `scripts/cli/main.go` (usage string, `switch`)

**Interfaces:**
- Produces: `cli aio-config [-file <margince.yaml>] [-display-name <text>]` writes YAML to stdout, exit 0; exit 1 with `aio-config: <reason>` on stderr; exit 2 on bad flags. Go: `func AIOConfig(file, displayName string) ([]byte, error)`.

- [ ] **Step 1: Write the failing tests** in `scripts/cli/aio_test.go`:

```go
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
```

`writeFile` already exists in the package's tests (used by `get_test.go`); confirm with `grep -n "func writeFile" scripts/cli/*_test.go`.

- [ ] **Step 2: Run to verify failure**

Run: `cd scripts/cli && GOWORK=off go test ./... -run AIO`
Expected: FAIL — `undefined: AIOConfig`.

- [ ] **Step 3: Implement** `scripts/cli/aio.go`:

```go
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
```

In `scripts/cli/main.go`: extend the header comment and `usage` with `cli aio-config [-file margince.yaml] [-display-name text]`, and add to the `switch`:

```go
	case "aio-config":
		return runAIOConfig(args[1:], stdout, stderr)
```

- [ ] **Step 4: Run to verify pass**

Run: `make test-cli`
Expected: `ok  margince.instance/template/scripts/cli`

- [ ] **Step 5: Commit**

```bash
git add scripts/cli
git commit -m "feat(cli): aio-config writes the all-in-one first-boot configuration"
```

---

### Task 2: The image's runtime files

**Files:**
- Create: `scripts/aio/Dockerfile`, `scripts/aio/nginx.conf`, `scripts/aio/margince-init`, `scripts/aio/margince-seed`, `scripts/aio/margince-logins`
- Create: `scripts/aio.test.sh` (static section; Task 3 adds the build section)
- Modify: `Makefile` (`test-scripts` gains `@bash scripts/aio.test.sh`)

**Interfaces:**
- Consumes: build context files `margince.yaml`, `db-bootstrap.sql`, `seed/` (maybe empty), `demo/` (maybe empty) — produced by Task 3.
- Produces: build args `API_IMAGE`, `WORKER_IMAGE`, `WEB_IMAGE`, `VERSION`; in-image commands `margince-init` (entrypoint), `margince-logins` (used by install scripts via `docker exec <c> margince-logins`), `/data/secrets.env` with `MARGINCE_ADMIN_PASSWORD=` (read by `aio-smoke`).

- [ ] **Step 1: Write the failing static tests** — `scripts/aio.test.sh` header and static section:

```bash
#!/usr/bin/env bash
# aio.test.sh — the all-in-one image's files and scripts/aio.sh
# (docs/superpowers/specs/2026-09-30-all-in-one-image-design.md).
#
# Static checks read scripts/aio/ as text: the nginx routes follow the host
# adapter's Caddyfile, and the start script keeps the rules no stub can see.
# The build, smoke and scripts cases run scripts/aio.sh in a scratch instance
# with stub `docker`, `make`, `go` and `curl` first on PATH; each stub appends
# one line per call to $STUB_LOG.
#
# Usage: bash scripts/aio.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AIO="$SCRIPT_DIR/aio"

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_PREFIX
unset REGISTRY REPO PUSH DATASET METADATA_FILE AIO_PLATFORMS AIO_SMOKE_TIMEOUT
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false
export GIT_AUTHOR_NAME="Test Dev"     GIT_AUTHOR_EMAIL="dev@example.test"
export GIT_COMMITTER_NAME="Test Dev"  GIT_COMMITTER_EMAIL="dev@example.test"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILURES=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }
ok()   { printf 'ok: %s\n' "$*"; }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else fail "$what"; fi; }

# ── static: nginx ──
# Every path the Caddyfile routes to the api is routed to the api here.
for path in /v1 /v1/x /oauth/x /mcp /mcp/x /.well-known/oauth-authorization-server /.well-known/oauth-protected-resource/x /webhooks/gmail /webhooks/graph; do
  check "nginx routes $path to the api" \
    grep -qE '^[[:space:]]*location ~ \^/\(v1\(/\.\*\)\?\|oauth/\.\*\|mcp\(/\.\*\)\?\|\\\.well-known/oauth-\(authorization-server\|protected-resource\)\.\*\|webhooks/\(gmail\|graph\)\)\$' "$AIO/nginx.conf"
done
check "nginx answers 404 for /healthz, /readyz and /metrics" \
  grep -qE 'location ~ \^/\(healthz\|readyz\|metrics\)\(/\|\$\) \{ return 404; \}' "$AIO/nginx.conf"
check "nginx listens on 80 only" bash -c '[ "$(grep -cE "^[[:space:]]*listen " "$1")" = 1 ] && grep -qE "^[[:space:]]*listen 80;" "$1"' _ "$AIO/nginx.conf"
check "nginx proxies to the api on 127.0.0.1:8080" grep -q 'server 127.0.0.1:8080;' "$AIO/nginx.conf"

# ── static: margince-init ──
init="$AIO/margince-init"
check "init sets MARGINCE_ENV=test" grep -q '^export MARGINCE_ENV=test$' "$init"
check "init never reads MARGINCE_LICENSE" bash -c '! grep -q MARGINCE_LICENSE "$1"' _ "$init"
check "init gates initdb on PG_VERSION" grep -q 'PG_VERSION' "$init"
check "init writes secrets through a temporary file and a rename" bash -c 'grep -q "tmp=\"\$SECRETS.tmp\"" "$1" && grep -q "mv \"\$tmp\" \"\$SECRETS\"" "$1"' _ "$init"
check "init runs db-bootstrap.sql on every start (not inside the initdb branch)" \
  bash -c 'awk "/^if \[ ! -s \"\\\$PGDATA\/PG_VERSION\" \]/{inside=1} inside&&/^fi/{inside=0} inside&&/db-bootstrap/{bad=1} END{exit bad}" "$1"' _ "$init"
check "the worker gets neither the owner DSN nor the admin password" \
  bash -c 'sed -n "/^run_worker()/,/^)/p" "$1" | grep -q "unset MARGINCE_ADMIN_PASSWORD" && ! sed -n "/^run_worker()/,/^)/p" "$1" | grep -q MARGINCE_OWNER_DSN' _ "$init"
check "no script puts a password in curl's arguments" bash -c '! grep -nE "curl .*-d \"[^@]" "$1"/margince-*' _ "$AIO"
check "the Dockerfile's entrypoint is tini and margince-init" grep -q 'ENTRYPOINT \["/usr/bin/tini", "--", "/usr/local/bin/margince-init"\]' "$AIO/Dockerfile"
check "the Dockerfile sets no ENV" bash -c '! grep -qE "^ENV " "$1"' _ "$AIO/Dockerfile"
check "the health check asks the api for /readyz" grep -q 'http://127.0.0.1:8080/readyz' "$AIO/Dockerfile"
for f in margince-init margince-seed margince-logins; do
  check "$f passes bash -n" bash -n "$AIO/$f"
done

if [ "$FAILURES" -gt 0 ]; then printf '\naio.test.sh: %s failed\n' "$FAILURES" >&2; exit 1; fi
printf '\naio.test.sh: all passed\n'
```

(Task 3 inserts its cases before the final summary.)

- [ ] **Step 2: Run to verify failure**

Run: `bash scripts/aio.test.sh`
Expected: FAIL lines (files do not exist).

- [ ] **Step 3: Write `scripts/aio/nginx.conf`**

```nginx
# nginx.conf — the all-in-one image's only listener (design 2026-09-30,
# Section 5.4). Routes follow the host adapter's Caddyfile; the SPA rules
# follow core's frontend/nginx.conf.
user www-data;
worker_processes 2;
pid /run/nginx.pid;
error_log /dev/stderr warn;

events {
    worker_connections 512;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    access_log off;
    sendfile on;
    client_max_body_size 100m;

    map $http_upgrade $connection_upgrade {
        default upgrade;
        ''      close;
    }

    upstream margince_api {
        server 127.0.0.1:8080;
    }

    server {
        listen 80;
        server_name _;

        root /usr/share/margince/web;
        index index.html;

        add_header Referrer-Policy "no-referrer" always;

        gzip on;
        gzip_types text/css application/javascript application/json image/svg+xml;
        gzip_min_length 1024;
        gzip_vary on;

        # For the container's own health check only.
        location ~ ^/(healthz|readyz|metrics)(/|$) { return 404; }

        location ~ ^/(v1(/.*)?|oauth/.*|mcp(/.*)?|\.well-known/oauth-(authorization-server|protected-resource).*|webhooks/(gmail|graph))$ {
            proxy_pass http://margince_api;
            proxy_http_version 1.1;
            proxy_set_header Host $host;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-Forwarded-Proto $scheme;
            proxy_set_header Upgrade $http_upgrade;
            proxy_set_header Connection $connection_upgrade;
            proxy_buffering off;
            proxy_read_timeout 1h;
        }

        location /assets/ {
            try_files $uri =404;
            expires 1y;
            add_header Cache-Control "public, immutable";
            add_header Referrer-Policy "no-referrer" always;
        }

        location = /index.html {
            add_header Cache-Control "no-cache";
            add_header Referrer-Policy "no-referrer" always;
        }

        location /mcp-apps/ {
            try_files $uri =404;
            add_header Cache-Control "no-cache";
            add_header Referrer-Policy "no-referrer" always;
        }

        location / {
            try_files $uri $uri/ /index.html;
        }
    }
}
```

- [ ] **Step 4: Write `scripts/aio/margince-init`**

```bash
#!/usr/bin/env bash
# margince-init — start, order and stop every process of the all-in-one image
# (docs/superpowers/specs/2026-09-30-all-in-one-image-design.md, Section 6).
#
# Runs as root under tini. Order: PostgreSQL, Redis, api (which migrates),
# worker, nginx, then the one-time demo seed in the background. When one of
# the processes exits, the others are stopped in the reverse order and this
# exits 1, so Docker's restart policy starts the container again. SIGTERM
# (docker stop) stops them in the same order and exits 0.
#
# The container takes no configuration. Fixed settings are exported below;
# generated values are in /data/secrets.env and reach only the api and the
# worker, through their environment.
set -euo pipefail

DATA=/data
SECRETS="$DATA/secrets.env"
PGDATA="$DATA/postgres"
SOCKET_DIR=/run/postgresql
API_READY_TIMEOUT=300

export MARGINCE_ENV=test
export MARGINCE_CONFIG=/etc/margince/margince.yaml
export MARGINCE_REDIS=127.0.0.1:6379
export MARGINCE_BLOBSTORE_PATH="$DATA/blobs"
OWNER_DSN="postgres://margince_owner@/margince?host=$SOCKET_DIR"
APP_DSN="postgres://margince_app@/margince?host=$SOCKET_DIR"

say() { printf 'margince: %s\n' "$*"; }

as_user() { local user="$1"; shift; setpriv --reuid="$user" --regid="$user" --init-groups "$@"; }

rand_b64_32() { head -c 32 /dev/urandom | base64 | tr -d '\n'; }
rand_hex_32() { od -An -tx1 -N32 /dev/urandom | tr -d ' \n'; }
# `|| true`: head closes the pipe early, and tr's SIGPIPE must not fail the
# pipeline under pipefail.
rand_alnum() { { LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom || true; } | head -c "$1"; }

# ── processes ──
PIDS=()
NAMES=()
SEED_PID=""
STOPPING=0
trap 'STOPPING=1' TERM INT

start() {
  local name="$1"; shift
  "$@" &
  PIDS+=("$!")
  NAMES+=("$name")
}

stop_all() {
  local i sig
  if [ -n "$SEED_PID" ]; then
    kill -TERM -- "-$SEED_PID" 2>/dev/null || true
    wait "$SEED_PID" 2>/dev/null || true
  fi
  for ((i = ${#PIDS[@]} - 1; i >= 0; i--)); do
    # PostgreSQL's fast shutdown is SIGINT; SIGTERM would wait for clients.
    sig=TERM
    [ "${NAMES[i]}" = postgres ] && sig=INT
    kill "-$sig" "${PIDS[i]}" 2>/dev/null || true
    wait "${PIDS[i]}" 2>/dev/null || true
  done
}

stop_if_asked() {
  if [ "$STOPPING" = 1 ]; then
    say "stopping"
    stop_all
    exit 0
  fi
}

give_up() {
  say "$*"
  stop_all
  exit 1
}

alive() { kill -0 "$1" 2>/dev/null; }

# wait_for <seconds> <pid> <what> <command...> — until the command succeeds.
wait_for() {
  local seconds="$1" pid="$2" what="$3" i
  shift 3
  for ((i = 0; i < seconds; i++)); do
    stop_if_asked
    alive "$pid" || give_up "$what exited while starting"
    "$@" >/dev/null 2>&1 && return 0
    sleep 1
  done
  give_up "$what did not start within $seconds seconds"
}

# ── directories ──
mkdir -p "$DATA/blobs" "$DATA/redis"
chown app:app "$DATA/blobs"
chmod 700 "$DATA/blobs"
chown redis:redis "$DATA/redis"
install -d -o postgres -g postgres -m 2775 "$SOCKET_DIR"

# ── generated values, once ──
if [ ! -f "$SECRETS" ]; then
  say "first start: generating this installation's keys and admin password"
  tmp="$SECRETS.tmp"
  ( umask 077
    {
      printf 'MARGINCE_KEYVAULT_ROOT_KEY=%s\n' "$(rand_b64_32)"
      printf 'MARGINCE_CONNECTOR_STATE_KEY=%s\n' "$(rand_hex_32)"
      printf 'MARGINCE_WEBHOOK_KEY=%s\n' "$(rand_b64_32)"
      printf 'MARGINCE_ADMIN_PASSWORD=%s\n' "$(rand_alnum 24)"
    } > "$tmp" )
  mv "$tmp" "$SECRETS"
fi

# ── PostgreSQL ──
if [ ! -s "$PGDATA/PG_VERSION" ]; then
  say "first start: creating the database"
  rm -rf "$PGDATA"
  install -d -o postgres -g postgres -m 700 "$PGDATA"
  as_user postgres initdb -D "$PGDATA" --username=postgres --auth-local=trust --auth-host=reject \
    --encoding=UTF8 --locale=C.UTF-8 >/dev/null
fi
start postgres as_user postgres postgres -D "$PGDATA" -c listen_addresses= -c unix_socket_directories="$SOCKET_DIR"
wait_for 60 "${PIDS[-1]}" PostgreSQL pg_isready -q -h "$SOCKET_DIR"

# Idempotent (IF NOT EXISTS throughout), so it also completes a first start
# that was interrupted. The role passwords are used once and not stored:
# local connections use trust authentication and there is no TCP listener.
MARGINCE_BOOTSTRAP_OWNER_PW="$(rand_alnum 32)" MARGINCE_BOOTSTRAP_APP_PW="$(rand_alnum 32)"
export MARGINCE_BOOTSTRAP_OWNER_PW MARGINCE_BOOTSTRAP_APP_PW
{
  printf '\\getenv owner_pw MARGINCE_BOOTSTRAP_OWNER_PW\n\\getenv app_pw MARGINCE_BOOTSTRAP_APP_PW\n'
  cat /usr/share/margince/db-bootstrap.sql
} | as_user postgres psql -q -v ON_ERROR_STOP=1 -h "$SOCKET_DIR" -U postgres -d postgres >/dev/null \
  || give_up "the database bootstrap failed"
unset MARGINCE_BOOTSTRAP_OWNER_PW MARGINCE_BOOTSTRAP_APP_PW

# ── Redis ──
start redis as_user redis redis-server --bind 127.0.0.1 --port 6379 --dir "$DATA/redis" \
  --appendonly yes --save '' --protected-mode yes --daemonize no
wait_for 30 "${PIDS[-1]}" Redis redis-cli -h 127.0.0.1 -p 6379 ping

# ── api and worker ──
run_api() (
  set -a
  . "$SECRETS"
  set +a
  export MARGINCE_OWNER_DSN="$OWNER_DSN" MARGINCE_DSN="$APP_DSN"
  cd /app
  exec setpriv --reuid=app --regid=app --init-groups /usr/local/bin/margince-api-entrypoint
)

run_worker() (
  set -a
  . "$SECRETS"
  set +a
  unset MARGINCE_ADMIN_PASSWORD
  export MARGINCE_DSN="$APP_DSN"
  cd /app
  exec setpriv --reuid=app --regid=app --init-groups /usr/local/bin/margince-worker-entrypoint
)

start api run_api
say "starting the api (the first start migrates the database)"
wait_for "$API_READY_TIMEOUT" "${PIDS[-1]}" "the api" curl -fsS -o /dev/null --max-time 2 http://127.0.0.1:8080/readyz
start worker run_worker
start nginx nginx -g 'daemon off;'
say "ready"

# ── demo data, once ──
if [ -x /usr/local/bin/seed-demo ] && [ -d /opt/margince/demo ] && [ ! -f "$DATA/.seeded" ]; then
  setsid /usr/local/bin/margince-seed &
  SEED_PID=$!
fi

# ── supervise ──
while :; do
  set +e
  wait -n "${PIDS[@]}"
  set -e
  stop_if_asked
  for ((i = 0; i < ${#PIDS[@]}; i++)); do
    alive "${PIDS[i]}" || give_up "${NAMES[i]} exited; stopping the container so Docker restarts it"
  done
done
```

- [ ] **Step 5: Write `scripts/aio/margince-seed`**

```bash
#!/usr/bin/env bash
# margince-seed — load the demo dataset once (design 2026-09-30, Section 7.3).
#
# Started by margince-init in the background, as root. Signs in as the
# bootstrap admin with the generated password, or with the seeder's password
# when an earlier, interrupted run already replaced it. Creates /data/.seeded
# on success; on failure the next start tries again.
set -euo pipefail

API=http://127.0.0.1:8080
EMAIL=admin@localhost
SEEDED_PASSWORD=demo-password-123

say() { printf 'margince: %s\n' "$*"; }

# The password travels on standard input, never in curl's arguments.
login_works() {
  printf '{"email":"%s","password":"%s"}' "$EMAIL" "$1" \
    | curl -fsS -o /dev/null --max-time 10 -X POST -H 'Content-Type: application/json' --data-binary @- \
        "$API/v1/auth/login" 2>/dev/null
}

generated="$(sed -n 's/^MARGINCE_ADMIN_PASSWORD=//p' /data/secrets.env)"
if login_works "$generated"; then
  password="$generated"
elif login_works "$SEEDED_PASSWORD"; then
  password="$SEEDED_PASSWORD"
else
  say "loading the demo data failed: neither the generated nor the seeded password signs in as $EMAIL"
  exit 1
fi

say "loading the demo data (a few minutes)"
if MARGINCE_SEED_PASSWORD="$password" \
   MARGINCE_SEED_DSN="postgres://margince_owner@/margince?host=/run/postgresql" \
   MARGINCE_BLOBSTORE_PATH=/data/blobs \
   setpriv --reuid=app --regid=app --init-groups \
     /usr/local/bin/seed-demo -dataset /opt/margince/demo -api "$API" -email "$EMAIL"; then
  touch /data/.seeded
  say "demo data loaded"
else
  say "loading the demo data failed; the next start tries again"
  exit 1
fi
```

- [ ] **Step 6: Write `scripts/aio/margince-logins`**

```bash
#!/usr/bin/env bash
# margince-logins — the accounts that sign in to this installation (design
# 2026-09-30, Section 8.3). Run with `docker exec <container> margince-logins`.
set -euo pipefail

EMAIL=admin@localhost
SEEDED_PASSWORD=demo-password-123
SEAT_PASSWORD=1234

if [ -f /data/.seeded ]; then
  printf '  Sign in as\n    %-32s password %s\n' "$EMAIL" "$SEEDED_PASSWORD"
  seats="$(psql "postgres://margince_owner@/margince?host=/run/postgresql" -Atc \
    "select email || '|' || display_name from app_user
      where password_hash is not null and not is_agent and archived_at is null
        and lower(email) <> lower('$EMAIL')
      order by created_at" 2>/dev/null || true)"
  if [ -n "$seats" ]; then
    printf '\n  Demo colleagues (password %s)\n' "$SEAT_PASSWORD"
    printf '%s\n' "$seats" | while IFS='|' read -r email name; do
      printf '    %-32s %s\n' "$email" "$name"
    done
  fi
  exit 0
fi

password="$(sed -n 's/^MARGINCE_ADMIN_PASSWORD=//p' /data/secrets.env 2>/dev/null || true)"
if [ -z "$password" ]; then
  printf '  Margince is still starting. Run this again in a minute.\n'
  exit 0
fi
printf '  Sign in as\n    %-32s password %s\n\n' "$EMAIL" "$password"
printf '  The first sign-in asks you to choose a new password.\n'
printf '  After that, sign in with the password you chose.\n'
if [ -x /usr/local/bin/seed-demo ]; then
  printf '\n  The demo data is loading. When it is loaded, sign in with password %s.\n' "$SEEDED_PASSWORD"
fi
```

- [ ] **Step 7: Write `scripts/aio/Dockerfile`**

```dockerfile
# syntax=docker/dockerfile:1
#
# The all-in-one image (docs/superpowers/specs/2026-09-30-all-in-one-image-design.md).
# Built by scripts/aio.sh from a context in build/aio/, never from this
# directory. The Margince binaries and the SPA come unchanged from the role
# images of the same version; this file only packages them with PostgreSQL,
# Redis and nginx.
ARG API_IMAGE
ARG WORKER_IMAGE
ARG WEB_IMAGE

FROM ${API_IMAGE} AS api
FROM ${WORKER_IMAGE} AS worker
FROM ${WEB_IMAGE} AS web

FROM pgvector/pgvector:pg16

ARG TARGETARCH
ARG VERSION=dev

RUN apt-get update \
    && apt-get install -y --no-install-recommends tini nginx redis-server curl ca-certificates tzdata \
    && rm -rf /var/lib/apt/lists/* /etc/nginx/sites-enabled /etc/nginx/conf.d \
    && useradd --system --uid 10001 --user-group --home-dir /app --no-create-home app \
    && mkdir -p /app/secrets /etc/margince \
    && chown -R app:app /app

COPY --from=api /usr/local/bin/margince-api /usr/local/bin/margince-migrate /usr/local/bin/
COPY --from=api /usr/local/bin/entrypoint.sh /usr/local/bin/margince-api-entrypoint
COPY --from=worker /usr/local/bin/margince-worker /usr/local/bin/
COPY --from=worker /usr/local/bin/entrypoint.sh /usr/local/bin/margince-worker-entrypoint
COPY --from=web /usr/share/nginx/html /usr/share/margince/web
COPY --from=api /etc/margince/release-version /etc/margince/release-version

COPY nginx.conf /etc/nginx/nginx.conf
COPY margince.yaml /etc/margince/margince.yaml
COPY db-bootstrap.sql /usr/share/margince/db-bootstrap.sql
COPY --chmod=0755 margince-init margince-seed margince-logins /usr/local/bin/

# The seeder and the dataset, when the build included them (Section 7.2).
COPY seed/ /tmp/seed/
RUN if [ -f "/tmp/seed/seed-demo-${TARGETARCH}" ]; then \
      install -m 0755 "/tmp/seed/seed-demo-${TARGETARCH}" /usr/local/bin/seed-demo; \
    fi \
    && rm -rf /tmp/seed
COPY demo/ /opt/margince/demo/
RUN if [ ! -x /usr/local/bin/seed-demo ]; then rm -rf /opt/margince/demo; fi

LABEL org.opencontainers.image.version="${VERSION}"

EXPOSE 80
VOLUME ["/data"]
STOPSIGNAL SIGTERM
HEALTHCHECK --interval=10s --timeout=5s --start-period=600s --retries=3 \
  CMD curl -fsS -o /dev/null http://127.0.0.1:8080/readyz || exit 1
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/margince-init"]
CMD []
```

- [ ] **Step 8: Add `@bash scripts/aio.test.sh` to `test-scripts` in the `Makefile`** (after `@bash scripts/trial.test.sh`). Run `chmod +x scripts/aio/margince-*`.

- [ ] **Step 9: Run to verify pass**

Run: `bash scripts/aio.test.sh`
Expected: `aio.test.sh: all passed`

- [ ] **Step 10: Commit**

```bash
git add scripts/aio scripts/aio.test.sh Makefile
git commit -m "feat(aio): the all-in-one image's Dockerfile, start script and nginx routes"
```

---

### Task 3: `scripts/aio.sh build` and `make aio`

**Files:**
- Create: `scripts/aio.sh`
- Modify: `scripts/desktop.sh` (`build_seeder`: `linux-amd64`, `linux-arm64`)
- Modify: `scripts/aio.test.sh` (build cases)
- Modify: `Makefile` (`aio` target), `.gitignore` (`/build/aio/`)

**Interfaces:**
- Consumes: `cli aio-config` (Task 1), `scripts/aio/*` (Task 2), `lib.sh`: `instance_get`, `image_repo`, `is_release_version`, `cli_run`, `dataset_path`, `source_units`; `desktop.sh`: `build_seeder <goos> <out>`.
- Produces: `bash scripts/aio.sh build <version>`; env `PUSH=1`, `REGISTRY`, `REPO`, `DATASET`, `AIO_PLATFORMS` (default `linux/amd64,linux/arm64` with push), `METADATA_FILE`; functions `aio_image <version>`, variables `container`, `volume` for later tasks.

- [ ] **Step 1: Write the failing build tests** — insert into `scripts/aio.test.sh` before the summary:

```bash
# ── scratch instance ──
INST="$TMP/inst"
mkdir -p "$INST/core/scripts/deploy" "$INST/core/backend" "$INST/deploy/production/config"
cp -R "$SCRIPT_DIR" "$INST/scripts"
printf 'name: acme\ndisplay_name: Acme\ncore: v0.0.2\n' > "$INST/instance.yaml"
printf -- '-- stand-in bootstrap\nSELECT 1;\n' > "$INST/core/scripts/deploy/db-bootstrap.sql"
printf 'version: 1\nworkspace:\n  name: Acme\n  base_currency: EUR\n  timezone: UTC\n' \
  > "$INST/deploy/production/config/margince.yaml"
git -C "$INST" init -q && git -C "$INST" add -A && git -C "$INST" commit -qm init
git -C "$INST/core" init -q && git -C "$INST/core" commit -q --allow-empty -m core

STUB_BIN="$TMP/stub-bin"
mkdir -p "$STUB_BIN"
export STUB_LOG="$TMP/log"

# docker: `image inspect` fails for refs listed in $STUB_MISSING (space-separated).
cat > "$STUB_BIN/docker" <<'EOF'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >> "$STUB_LOG"
case "$1 ${2:-}" in
  "image inspect")
    for m in ${STUB_MISSING:-}; do [ "$3" = "$m" ] && exit 1; done; exit 0 ;;
  "buildx version") exit 0 ;;
  "buildx build") exit 0 ;;
esac
exit 0
EOF
cat > "$STUB_BIN/make" <<'EOF'
#!/usr/bin/env bash
printf 'make %s\n' "$*" >> "$STUB_LOG"
EOF
# go: `go run` is the real CLI (cli_run needs it); `go build -o <f>` and
# `go mod edit` are recorded and faked.
REAL_GO="$(command -v go)"
cat > "$STUB_BIN/go" <<EOF
#!/usr/bin/env bash
case "\$1" in
  build) printf 'go %s GOOS=%s GOARCH=%s CGO_ENABLED=%s\n' "\$*" "\${GOOS:-}" "\${GOARCH:-}" "\${CGO_ENABLED:-}" >> "\$STUB_LOG"
         prev=""; for a in "\$@"; do [ "\$prev" = -o ] && : > "\$a"; prev="\$a"; done; exit 0 ;;
  mod)   exit 0 ;;
esac
exec "$REAL_GO" "\$@"
EOF
chmod +x "$STUB_BIN"/*

aio() { (cd "$INST" && PATH="$STUB_BIN:$PATH" bash scripts/aio.sh "$@"); }
reset_log() { : > "$STUB_LOG"; }

reset_log
if aio build 1.0 >/dev/null 2>"$TMP/err"; then fail "build refuses a non-release version"; else
  check "build refuses a non-release version, naming VERSION" grep -q 'VERSION=<release version>' "$TMP/err"; fi

reset_log
aio build v1.0.0 >/dev/null 2>&1
check "build with all role images present does not run make package" bash -c '! grep -q "^make .*package" "$1"' _ "$STUB_LOG"
check "build passes the three role images" grep -q -- '--build-arg API_IMAGE=acme/api:v1.0.0 --build-arg WORKER_IMAGE=acme/worker:v1.0.0 --build-arg WEB_IMAGE=acme/web:v1.0.0' "$STUB_LOG"
check "build tags acme/all-in-one:v1.0.0 and loads it" bash -c 'grep "buildx build" "$1" | grep -q -- "--load" && grep "buildx build" "$1" | grep -q -- "-t acme/all-in-one:v1.0.0"' _ "$STUB_LOG"
check "build labels the image with the instance and core" bash -c 'grep "buildx build" "$1" | grep -q "com.margince.instance.name=acme" && grep "buildx build" "$1" | grep -q "com.margince.core.version=v0.0.2"' _ "$STUB_LOG"
check "the context holds the scripts, the configuration and db-bootstrap.sql" bash -c 'for f in Dockerfile nginx.conf margince-init margince-seed margince-logins margince.yaml db-bootstrap.sql; do [ -f "$1/build/aio/$f" ] || exit 1; done' _ "$INST"
check "the context's configuration signs in as admin@localhost" grep -q 'admin@localhost' "$INST/build/aio/margince.yaml"
check "without DATASET the context has no seeder and no dataset" bash -c '[ -z "$(ls -A "$1/build/aio/seed")" ] && [ -z "$(ls -A "$1/build/aio/demo")" ]' _ "$INST"

reset_log
STUB_MISSING="acme/web:v1.0.0" aio build v1.0.0 >/dev/null 2>&1
check "a missing role image runs make package VERSION=v1.0.0" grep -q '^make -C .* package VERSION=v1.0.0$' "$STUB_LOG"

reset_log
if (export PUSH=1; aio build v1.0.0) >/dev/null 2>"$TMP/err"; then fail "PUSH=1 without REGISTRY is refused"; else
  check "PUSH=1 without REGISTRY is refused" grep -q 'requires REGISTRY' "$TMP/err"; fi

reset_log
(export PUSH=1 REGISTRY=registry.example.test/acme; aio build v1.0.0) >/dev/null 2>&1
check "PUSH=1 pushes both platforms under the registry" bash -c 'grep "buildx build" "$1" | grep -q -- "--push --platform linux/amd64,linux/arm64" && grep "buildx build" "$1" | grep -q -- "-t registry.example.test/acme/acme/all-in-one:v1.0.0"' _ "$STUB_LOG"
check "PUSH=1 does not look for local role images" bash -c '! grep -q "image inspect" "$1"' _ "$STUB_LOG"

# A dataset checkout with the seeder's source.
DS="$TMP/dataset"
mkdir -p "$DS/datasets/v1" "$DS/tools/seed-demo" "$DS/.git"
printf '{}\n' > "$DS/datasets/v1/demo.json"
printf 'module x\n' > "$DS/tools/seed-demo/go.mod"

reset_log
DATASET="$DS" aio build v1.0.0 >/dev/null 2>&1
check "DATASET builds the seeder for linux/amd64 and linux/arm64 without cgo" bash -c 'grep -q "GOOS=linux GOARCH=amd64 CGO_ENABLED=0" "$1" && grep -q "GOOS=linux GOARCH=arm64 CGO_ENABLED=0" "$1"' _ "$STUB_LOG"
check "DATASET puts both seeders in the context" bash -c '[ -f "$1/build/aio/seed/seed-demo-amd64" ] && [ -f "$1/build/aio/seed/seed-demo-arm64" ]' _ "$INST"
check "DATASET copies the dataset without .git and tools" bash -c '[ -f "$1/build/aio/demo/datasets/v1/demo.json" ] && [ ! -e "$1/build/aio/demo/.git" ] && [ ! -e "$1/build/aio/demo/tools" ]' _ "$INST"

sed -i.bak 's/EUR/USD/' "$INST/deploy/production/config/margince.yaml"
reset_log
DATASET="$DS" aio build v1.0.0 >"$TMP/out" 2>&1
check "a non-EUR workspace gets a notice and no dataset" bash -c 'grep -q "euro-based" "$1" && [ -z "$(ls -A "$2/build/aio/demo")" ]' _ "$TMP/out" "$INST"
mv "$INST/deploy/production/config/margince.yaml.bak" "$INST/deploy/production/config/margince.yaml"

rm -rf "$INST/deploy"
reset_log
aio build v1.0.0 >/dev/null 2>&1
check "without deploy/production the workspace is named after display_name" grep -q 'name: Acme' "$INST/build/aio/margince.yaml"
```

- [ ] **Step 2: Run to verify failure**

Run: `bash scripts/aio.test.sh`
Expected: FAIL on every build case (`scripts/aio.sh` does not exist).

- [ ] **Step 3: Extend `build_seeder` in `scripts/desktop.sh`** — add a case after `windows)`:

```bash
    linux-amd64|linux-arm64)
      # The all-in-one image (scripts/aio.sh). Pure Go, like the Windows
      # build, so it cross-builds from any host.
      ( cd "$src" && CGO_ENABLED=0 GOOS=linux GOARCH="${goos#linux-}" GOWORK=off go build -o "$out" . ) \
        || die "kit: the seeder in $src did not build"
      ;;
```

- [ ] **Step 4: Write `scripts/aio.sh`**

```bash
#!/usr/bin/env bash
# aio.sh — the all-in-one image
# (docs/superpowers/specs/2026-09-30-all-in-one-image-design.md).
#
#   build <v>    make aio: assemble build/aio/ and build <repo>/all-in-one:<v>.
#                Runs make package first when a role image is missing.
#                PUSH=1 (needs REGISTRY) pushes linux/amd64 and linux/arm64
#                (AIO_PLATFORMS) from the pushed role images. DATASET=<checkout>
#                includes the demo dataset and its seeder. METADATA_FILE=<path>
#                writes buildx's metadata file.
#   smoke <v>    make aio-smoke: run the image on a temporary volume and check it.
#   scripts <v>  make aio-scripts: write dist/aio/<v>/install.sh and install.ps1.
#   up <v>, down, reset, logins, logs
#                make aio-up and the others: run scripts/aio/install.sh with
#                this instance's image, container and volume.
#
# Usage: bash scripts/aio.sh <command> [<version>]
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AIO_SRC="$ROOT/scripts/aio"
CONTEXT="$ROOT/build/aio"

say() { printf 'aio: %s\n' "$*"; }

name="$(instance_get name)" || die "aio: cannot read name from instance.yaml"
REPO="${REPO:-$(image_repo)}"
container="margince-$name"
volume="margince-$name-data"

aio_image() { printf '%s/all-in-one:%s\n' "$REPO" "$1"; }

require_version() {
  is_release_version "${1:-}" \
    || die "aio: pass VERSION=<release version>, e.g. make aio VERSION=v0.1.0 (got '${1:-}')"
}

# ── build ──

include_dataset() {
  if [ -z "${DATASET:-}" ]; then
    say "notice: no DATASET, so the image has no demo data. DATASET=<checkout> includes it."
    return 0
  fi
  local dataset currency
  dataset="$(dataset_path "$DATASET")"
  [ -f "$dataset/datasets/v1/demo.json" ] \
    || die "aio: no demo dataset at $dataset (expected datasets/v1/demo.json inside it)"
  currency="$(sed -n 's/^[[:space:]]*base_currency:[[:space:]]*\([A-Za-z]\{3\}\).*/\1/p' "$CONTEXT/margince.yaml" | head -n1)"
  if [ "$currency" != EUR ]; then
    say "notice: the workspace's base_currency is ${currency:-unset} and the demo dataset is euro-based, so the image has no demo data."
    return 0
  fi
  if ! ( DATASET="$dataset"
         # shellcheck source=scripts/desktop.sh
         source "$ROOT/scripts/desktop.sh"
         build_seeder linux-amd64 "$CONTEXT/seed/seed-demo-amd64"
         build_seeder linux-arm64 "$CONTEXT/seed/seed-demo-arm64" ); then
    rm -f "$CONTEXT"/seed/*
    say "notice: the dataset has no seeder (tools/seed-demo), so the image has no demo data."
    return 0
  fi
  tar -C "$dataset" --exclude=./.git --exclude=./tools -cf - . | tar -C "$CONTEXT/demo" -xf -
  say "the image includes the demo dataset from $dataset"
}

assemble_context() {
  local display
  rm -rf "$CONTEXT"
  mkdir -p "$CONTEXT/seed" "$CONTEXT/demo"
  cp "$AIO_SRC/Dockerfile" "$AIO_SRC/nginx.conf" "$AIO_SRC/margince-init" \
     "$AIO_SRC/margince-seed" "$AIO_SRC/margince-logins" "$CONTEXT/"
  cp "$CORE/scripts/deploy/db-bootstrap.sql" "$CONTEXT/"
  display="$(instance_get display_name)" || die "aio: cannot read display_name from instance.yaml"
  cli_run aio-config -file "$ROOT/deploy/production/config/margince.yaml" -display-name "$display" \
    > "$CONTEXT/margince.yaml" || die "aio: could not write the image's margince.yaml"
  include_dataset
}

cmd_build() {
  local version="${1:-}" role missing=no
  require_version "$version"
  command -v docker >/dev/null || die "aio: docker is not installed"
  docker buildx version >/dev/null 2>&1 || die "aio: docker buildx is required"

  local output=(--load)
  if [ "${PUSH:-}" = "1" ]; then
    [ -n "${REGISTRY:-}" ] || die "aio: PUSH=1 requires REGISTRY (the registry host the image is pushed to)"
    output=(--push --platform "${AIO_PLATFORMS:-linux/amd64,linux/arm64}")
  else
    for role in api web worker; do
      docker image inspect "$REPO/$role:$version" >/dev/null 2>&1 || missing=yes
    done
    if [ "$missing" = yes ]; then
      say "a role image of $version is missing; running make package VERSION=$version"
      make -C "$ROOT" package VERSION="$version"
    fi
  fi
  [ -n "${METADATA_FILE:-}" ] && output+=(--metadata-file "$METADATA_FILE")

  assemble_context

  local revision core_revision core_version units
  revision="$(git -C "$ROOT" rev-parse HEAD)"
  core_revision="$(git -C "$CORE" rev-parse HEAD)"
  core_version="$(instance_get core)"
  units="$(source_units | tr '\n' ' ')"

  say "building $(aio_image "$version")"
  docker buildx build "${output[@]}" \
    --build-arg API_IMAGE="$REPO/api:$version" --build-arg WORKER_IMAGE="$REPO/worker:$version" --build-arg WEB_IMAGE="$REPO/web:$version" \
    --build-arg VERSION="$version" \
    --label "org.opencontainers.image.revision=$revision" \
    --label "com.margince.instance.name=$name" \
    --label "com.margince.instance.revision=$revision" \
    --label "com.margince.core.revision=$core_revision" \
    --label "com.margince.core.version=$core_version" \
    --label "com.margince.instance.units=${units% }" \
    -t "$(aio_image "$version")" "$CONTEXT"
  say "built $(aio_image "$version")"
}

case "${1:-}" in
  build) shift; cmd_build "$@" ;;
  *) die "usage: bash scripts/aio.sh build|smoke|scripts|up <version> | down|reset|logins|logs" ;;
esac
```

The `--build-arg` line must stay on one line as written: the test greps the three args in sequence.

- [ ] **Step 5: Add the `Makefile` target** after the `desktop-*` section:

```make
# ─────────────────────────── all-in-one image ─────────────────────────

## aio — one image with all of Margince, for non-technical testers (design
## docs/superpowers/specs/2026-09-30-all-in-one-image-design.md). Built from
## the role images of VERSION; runs `make package` when one is missing.
aio: ## Build the all-in-one image <repo>/all-in-one:<v> (VERSION=, DATASET=, PUSH=1)
	@bash scripts/aio.sh build "$(VERSION)"
```

Add `aio` to the `.PHONY` list (search `^\.PHONY` in the `Makefile`). Add to `.gitignore`, next to `/build/desktop/`:

```gitignore
# The all-in-one image's build context, assembled by scripts/aio.sh.
/build/aio/
```

- [ ] **Step 6: Run to verify pass**

Run: `bash scripts/aio.test.sh && bash scripts/desktop-kit.test.sh`
Expected: both `all passed`.

- [ ] **Step 7: Commit**

```bash
git add scripts/aio.sh scripts/aio.test.sh scripts/desktop.sh Makefile .gitignore
git commit -m "feat(aio): make aio builds the all-in-one image from the role images"
```

---

### Task 4: `make aio-smoke`

**Files:**
- Modify: `scripts/aio.sh` (`cmd_smoke`, dispatch)
- Modify: `scripts/aio.test.sh` (smoke cases)
- Modify: `Makefile` (`aio-smoke`)

**Interfaces:**
- Consumes: `aio_image`, the image's `/data/secrets.env` and health check (Task 2).
- Produces: `bash scripts/aio.sh smoke <version>`; env `AIO_SMOKE_TIMEOUT` (seconds, default 600).

- [ ] **Step 1: Write the failing tests** — extend the docker stub (replace the stub from Task 3 with this superset) and add cases:

```bash
cat > "$STUB_BIN/docker" <<'EOF'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >> "$STUB_LOG"
case "$1 ${2:-}" in
  "image inspect")
    for m in ${STUB_MISSING:-}; do [ "$3" = "$m" ] && exit 1; done; exit 0 ;;
  "buildx version"|"buildx build") exit 0 ;;
  "port "*) echo "127.0.0.1:49999"; exit 0 ;;
  "inspect "*)
    case "$*" in
      *Health*) echo "${STUB_HEALTH:-healthy}" ;;
      *State.Status*) echo running ;;
    esac
    exit 0 ;;
  "exec "*)
    case "$*" in
      *sha256sum*) echo "abc  /data/secrets.env" ;;
      *) echo "generated-password" ;;
    esac
    exit 0 ;;
  "logs "*) echo "stub log line"; exit 0 ;;
esac
exit 0
EOF
cat > "$STUB_BIN/curl" <<'EOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "$STUB_LOG"
stdin=""; [ ! -t 0 ] && stdin="$(cat)"
[ -n "$stdin" ] && printf 'curl-stdin %s\n' "$stdin" >> "$STUB_STDIN_LOG"
case "$*" in
  *"%{http_code}"*readyz*) echo 404 ;;
  *"%{http_code}"*auth/login*) [ "${STUB_LOGIN_FAIL:-}" = 1 ] && echo 401 || echo 200 ;;
  *) echo '<!doctype html><html><div id="root"></div></html>' ;;
esac
EOF
chmod +x "$STUB_BIN"/*
export STUB_STDIN_LOG="$TMP/stdin-log"

reset_log; : > "$STUB_STDIN_LOG"
if aio smoke v1.0.0 >"$TMP/out" 2>&1; then ok "smoke passes against a healthy image"; else fail "smoke passes against a healthy image"; cat "$TMP/out" >&2; fi
check "smoke runs the image on a temporary volume, published on 127.0.0.1" bash -c 'grep "^docker run" "$1" | grep -q -- "-p 127.0.0.1::80" && grep "^docker run" "$1" | grep -qE -- "-v margince-aio-smoke-[0-9]+-data:/data acme/all-in-one:v1.0.0"' _ "$STUB_LOG"
check "smoke restarts the container once" grep -q '^docker restart margince-aio-smoke-' "$STUB_LOG"
check "smoke removes the container and the volume" bash -c 'grep -q "^docker rm -f -v margince-aio-smoke-" "$1" && grep -q "^docker volume rm -f margince-aio-smoke-" "$1"' _ "$STUB_LOG"
check "smoke never puts the password in an argument" bash -c '! grep -q generated-password "$1"' _ "$STUB_LOG"
check "smoke sends the password on standard input" grep -q 'generated-password' "$STUB_STDIN_LOG"

reset_log
if STUB_LOGIN_FAIL=1 aio smoke v1.0.0 >"$TMP/out" 2>&1; then fail "smoke fails when sign-in fails"; else
  check "smoke fails when sign-in fails, prints the log, and still cleans up" bash -c 'grep -q "stub log line" "$1" && grep -q "^docker rm -f -v" "$2"' _ "$TMP/out" "$STUB_LOG"; fi

reset_log
if STUB_MISSING="acme/all-in-one:v1.0.0" aio smoke v1.0.0 >/dev/null 2>"$TMP/err"; then fail "smoke without the image is refused"; else
  check "smoke without the image names make aio" grep -q 'make aio VERSION=v1.0.0' "$TMP/err"; fi

reset_log
if STUB_HEALTH=unhealthy AIO_SMOKE_TIMEOUT=1 aio smoke v1.0.0 >/dev/null 2>&1; then fail "smoke fails when the container never becomes healthy"; else ok "smoke fails when the container never becomes healthy"; fi
```

- [ ] **Step 2: Run to verify failure** — `bash scripts/aio.test.sh`; Expected: smoke cases FAIL (`usage` error).

- [ ] **Step 3: Implement `cmd_smoke`** in `scripts/aio.sh` (before the `case`), and add `smoke) shift; cmd_smoke "$@" ;;`:

```bash
# ── smoke ──

SMOKE_C=""
SMOKE_V=""
smoke_cleanup() {
  [ -n "$SMOKE_C" ] || return 0
  docker rm -f -v "$SMOKE_C" >/dev/null 2>&1 || true
  docker volume rm -f "$SMOKE_V" >/dev/null 2>&1 || true
}

smoke_fail() {
  printf 'aio-smoke: FAIL: %s\n' "$*" >&2
  printf '\n--- last 100 log lines of %s ---\n' "$SMOKE_C" >&2
  docker logs --tail 100 "$SMOKE_C" >&2 2>&1 || true
  exit 1
}

smoke_wait_healthy() {
  local timeout="${AIO_SMOKE_TIMEOUT:-600}" i status state
  for ((i = 0; i < timeout; i += 5)); do
    status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$SMOKE_C" 2>/dev/null || true)"
    [ "$status" = healthy ] && return 0
    state="$(docker inspect -f '{{.State.Status}}' "$SMOKE_C" 2>/dev/null || true)"
    [ "$state" = exited ] && smoke_fail "the container exited"
    sleep 5
  done
  smoke_fail "the container was not healthy within ${timeout}s (last status: ${status:-none})"
}

# smoke_login <url> — HTTP status of a sign-in as admin@localhost with the
# generated password, or the seeded one. The password goes on stdin.
smoke_login() {
  local url="$1" password code
  password="$(docker exec "$SMOKE_C" sed -n 's/^MARGINCE_ADMIN_PASSWORD=//p' /data/secrets.env)"
  for pw in "$password" demo-password-123; do
    code="$(printf '{"email":"admin@localhost","password":"%s"}' "$pw" \
      | curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X POST \
          -H 'Content-Type: application/json' --data-binary @- "$url/v1/auth/login")"
    [ "$code" = 200 ] && { printf '200\n'; return 0; }
  done
  printf '%s\n' "$code"
}

cmd_smoke() {
  local version="${1:-}" image url port code before after
  require_version "$version"
  image="$(aio_image "$version")"
  docker image inspect "$image" >/dev/null 2>&1 \
    || die "aio-smoke: no image $image — run make aio VERSION=$version first"

  SMOKE_C="margince-aio-smoke-$$"
  SMOKE_V="$SMOKE_C-data"
  trap smoke_cleanup EXIT

  say "smoke: starting $image"
  docker run -d --name "$SMOKE_C" -p 127.0.0.1::80 -v "$SMOKE_V:/data" "$image" >/dev/null
  smoke_wait_healthy
  port="$(docker port "$SMOKE_C" 80/tcp | head -n1 | sed 's/.*://')"
  url="http://127.0.0.1:$port"

  curl -fsS --max-time 10 "$url/" | grep -qi '<html' || smoke_fail "/ does not serve the web app"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$url/readyz")"
  [ "$code" = 404 ] || smoke_fail "/readyz answered $code through nginx, want 404"
  code="$(smoke_login "$url")"
  [ "$code" = 200 ] || smoke_fail "admin@localhost could not sign in (HTTP $code)"
  say "smoke: $url serves the app, hides /readyz, and admin@localhost signs in"

  before="$(docker exec "$SMOKE_C" sha256sum /data/secrets.env)"
  docker restart "$SMOKE_C" >/dev/null
  smoke_wait_healthy
  after="$(docker exec "$SMOKE_C" sha256sum /data/secrets.env)"
  [ "$before" = "$after" ] || smoke_fail "the restart replaced /data/secrets.env"
  code="$(smoke_login "$url")"
  [ "$code" = 200 ] || smoke_fail "admin@localhost could not sign in after a restart (HTTP $code)"
  say "smoke: a restart keeps the data"
  say "smoke: passed"
}
```

Note: after `docker restart` the host port stays the same (the binding is part of the container).

- [ ] **Step 4: Makefile target**:

```make
aio-smoke: ## Run the all-in-one image on a temporary volume and check it (VERSION=, AIO_SMOKE_TIMEOUT=)
	@bash scripts/aio.sh smoke "$(VERSION)"
```

Add `aio-smoke` to `.PHONY`.

- [ ] **Step 5: Run** `bash scripts/aio.test.sh` — Expected: all passed.

- [ ] **Step 6: Commit**

```bash
git add scripts/aio.sh scripts/aio.test.sh Makefile
git commit -m "feat(aio): make aio-smoke checks the all-in-one image end to end"
```

---

### Task 5: `install.sh` and the `make aio-up/down/reset/logins/logs` targets

**Files:**
- Create: `scripts/aio/install.sh`
- Create: `scripts/aio-install.test.sh`
- Modify: `scripts/aio.sh` (`up`, `down`, `reset`, `logins`, `logs`)
- Modify: `Makefile` (five targets, `test-scripts`)

**Interfaces:**
- Consumes: `margince-logins` in the image (Task 2); `aio_image`, `container`, `volume` (Task 3).
- Produces: `sh install.sh [up|down|reset|logins|logs] [--yes] [--image <ref>] [--container <name>] [--volume <name>]`; placeholders `@IMAGE@`, `@CONTAINER@`, `@VOLUME@` (Task 6 renders them). Test hooks (environment): `MARGINCE_OS_RELEASE`, `MARGINCE_TTY`, `MARGINCE_SLEEP`, `MARGINCE_DOCKER_TIMEOUT`, `MARGINCE_START_TIMEOUT`.

- [ ] **Step 1: Write the failing tests** — `scripts/aio-install.test.sh`:

```bash
#!/usr/bin/env bash
# aio-install.test.sh — scripts/aio/install.sh, the tester's command
# (docs/superpowers/specs/2026-09-30-all-in-one-image-design.md, Section 8).
#
# Every external command is a stub first on PATH, recording one line per call
# in $STUB_LOG. The stub docker keeps its state in $STATE:
#   $STATE/docker-missing   `docker` is not installed (the stub hides itself)
#   $STATE/daemon-down      `docker info` fails
#   $STATE/container        the container exists; its content is the image id
#   $STATE/running          the container runs
#   $STATE/port             its host port
#   $STATE/busy-<port>      `docker run` on that port fails as "address already in use"
# The terminal is a file (MARGINCE_TTY) holding the answer.
#
# Usage: bash scripts/aio-install.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL="$SCRIPT_DIR/aio/install.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILURES=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }
ok()   { printf 'ok: %s\n' "$*"; }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else fail "$what"; fi; }

BIN="$TMP/bin"; mkdir -p "$BIN"
export STUB_LOG="$TMP/log" STATE="$TMP/state"

cat > "$BIN/docker" <<'EOF'
#!/bin/sh
[ -f "$STATE/docker-missing" ] && exit 127
printf 'docker %s\n' "$*" >> "$STUB_LOG"
case "$1" in
  info) [ -f "$STATE/daemon-down" ] && exit 1; exit 0 ;;
  image)
    case "$2" in
      inspect)
        [ -f "$STATE/image-missing" ] && exit 1
        case "$*" in *'{{.Id}}'*) echo "sha256:new" ;; esac; exit 0 ;;
    esac ;;
  pull) rm -f "$STATE/image-missing"; exit 0 ;;
  container)
    [ -f "$STATE/container" ] || exit 1
    case "$*" in
      *'{{.Image}}'*) cat "$STATE/container" ;;
      *'{{.State.Running}}'*) [ -f "$STATE/running" ] && echo true || echo false ;;
      *PortBindings*) cat "$STATE/port" ;;
      *Health*) echo "${STUB_HEALTH:-healthy}" ;;
    esac
    exit 0 ;;
  run)
    port="$(printf '%s\n' "$*" | sed -n 's/.*-p 127\.0\.0\.1:\([0-9]*\):80.*/\1/p')"
    echo "sha256:new" > "$STATE/container"
    echo "$port" > "$STATE/port"
    if [ -f "$STATE/busy-$port" ]; then echo "Error: address already in use" >&2; exit 125; fi
    touch "$STATE/running"; echo "cid"; exit 0 ;;
  start)
    port="$(cat "$STATE/port")"
    if [ -f "$STATE/busy-$port" ]; then echo "Error: address already in use" >&2; exit 1; fi
    touch "$STATE/running"; exit 0 ;;
  stop) rm -f "$STATE/running"; exit 0 ;;
  rm) rm -f "$STATE/container" "$STATE/running" "$STATE/port"; exit 0 ;;
  volume) exit 0 ;;
  exec) echo "  Sign in as admin@localhost password stub-password"; exit 0 ;;
  logs) echo "stub log"; exit 0 ;;
esac
exit 0
EOF
for c in sudo; do
  cat > "$BIN/$c" <<'EOF'
#!/bin/sh
printf 'sudo %s\n' "$*" >> "$STUB_LOG"
[ "$1" = docker ] && { shift; exec docker "$@"; }
exit 0
EOF
done
for c in curl hdiutil open xdg-open apt-get install tee chmod usermod systemctl dpkg id; do
  cat > "$BIN/$c" <<EOF
#!/bin/sh
printf '$c %s\n' "\$*" >> "\$STUB_LOG"
case "$c" in
  dpkg) echo arm64 ;;
  id) echo tester ;;
  open) [ "\$1" = -a ] && rm -f "\$STATE/daemon-down" ;;
  systemctl) rm -f "\$STATE/daemon-down" ;;
esac
exit 0
EOF
done
cat > "$BIN/uname" <<'EOF'
#!/bin/sh
case "$1" in -m) echo "${STUB_ARCH:-arm64}" ;; *) echo "${STUB_OS:-Darwin}" ;; esac
EOF
chmod +x "$BIN"/*

ubuntu() { printf 'ID=ubuntu\nVERSION_ID="%s"\nVERSION_CODENAME=noble\nPRETTY_NAME="Ubuntu %s"\n' "$1" "$1" > "$TMP/os-release"; }

reset() { rm -rf "$STATE"; mkdir -p "$STATE"; : > "$STUB_LOG"; printf 'y\n' > "$TMP/tty"; }

run_install() {
  PATH="$BIN:/usr/bin:/bin" MARGINCE_OS_RELEASE="$TMP/os-release" MARGINCE_TTY="$TMP/tty" \
  MARGINCE_SLEEP=true MARGINCE_DOCKER_TIMEOUT=4 MARGINCE_START_TIMEOUT=10 \
    sh "$INSTALL" --image acme/all-in-one:v1.0.0 --container margince-acme --volume margince-acme-data "$@"
}

# 1. Docker works: no install; container created on 8080; logins shown.
reset
run_install up >"$TMP/out" 2>&1 || { fail "up with Docker running succeeds"; cat "$TMP/out" >&2; }
check "up does not install Docker when it works" bash -c '! grep -qE "^(hdiutil|apt-get|curl)" "$1"' _ "$STUB_LOG"
check "up runs the container on 127.0.0.1:8080 with the volume and restart policy" \
  grep -q '^docker run -d --name margince-acme --restart unless-stopped -p 127.0.0.1:8080:80 -v margince-acme-data:/data acme/all-in-one:v1.0.0$' "$STUB_LOG"
check "up shows the address and the sign-in" bash -c 'grep -q "http://localhost:8080" "$1" && grep -q "stub-password" "$1"' _ "$TMP/out"
check "up opens the browser" grep -q '^open http://localhost:8080$' "$STUB_LOG"

# 2. Running container, same image: nothing is recreated.
: > "$STUB_LOG"
run_install up >/dev/null 2>&1
check "a second up keeps the running container" bash -c '! grep -qE "^docker (run|rm|start)" "$1"' _ "$STUB_LOG"

# 3. Container of another image: replaced on the same port, volume kept.
echo "sha256:old" > "$STATE/container"; echo 8083 > "$STATE/port"; : > "$STUB_LOG"
run_install up >/dev/null 2>&1
check "a container of another image is replaced on its port" bash -c 'grep -q "^docker rm -f -v margince-acme$" "$1" && grep -q -- "-p 127.0.0.1:8083:80" "$1"' _ "$STUB_LOG"
check "the replacement keeps the volume" bash -c '! grep -q "^docker volume rm" "$1"' _ "$STUB_LOG"

# 4. Port 8080 busy: the next port.
reset; touch "$STATE/busy-8080" "$STATE/busy-8081"
run_install up >/dev/null 2>&1
check "busy ports are skipped" grep -q -- '-p 127.0.0.1:8082:80' "$STUB_LOG"

# 5. Every port busy.
reset; for p in $(seq 8080 8099); do touch "$STATE/busy-$p"; done
if run_install up >"$TMP/out" 2>&1; then fail "all ports busy fails"; else
  check "all ports busy names the range" grep -q 'Ports 8080 to 8099 are all in use' "$TMP/out"; fi

# 6. Stopped container whose port is taken now: recreated on a free port.
reset; echo "sha256:new" > "$STATE/container"; echo 8080 > "$STATE/port"; touch "$STATE/busy-8080"
run_install up >/dev/null 2>&1
check "a stopped container whose port is taken is recreated on a free port" grep -q -- '-p 127.0.0.1:8081:80' "$STUB_LOG"

# 7. macOS without Docker: Docker Desktop for the Mac's architecture.
reset; touch "$STATE/docker-missing"
STUB_OS=Darwin STUB_ARCH=x86_64 run_install up --yes >"$TMP/out" 2>&1 || true
check "macOS downloads Docker Desktop for amd64" grep -q 'https://desktop.docker.com/mac/main/amd64/Docker.dmg' "$STUB_LOG"
check "macOS runs the installer with --accept-license" grep -q 'Docker.app/Contents/MacOS/install --accept-license' "$STUB_LOG"

# 8. Ubuntu 24.04 without Docker: Docker's apt repository.
reset; touch "$STATE/docker-missing"; ubuntu 24.04
STUB_OS=Linux run_install up --yes >"$TMP/out" 2>&1 || true
check "Ubuntu installs docker-ce from Docker's repository" bash -c 'grep -q "download.docker.com/linux/ubuntu/gpg" "$1" && grep -q "apt-get install -y docker-ce docker-ce-cli containerd.io" "$1"' _ "$STUB_LOG"

# 9. Unsupported Linux.
reset; touch "$STATE/docker-missing"
printf 'ID=fedora\nVERSION_ID="40"\nPRETTY_NAME="Fedora Linux 40"\n' > "$TMP/os-release"
if STUB_OS=Linux run_install up --yes >"$TMP/out" 2>&1; then fail "Fedora is refused"; else
  check "an unsupported system is refused by name" grep -q 'Fedora Linux 40' "$TMP/out"; fi

# 10. The tester answers no.
reset; touch "$STATE/docker-missing"; printf 'n\n' > "$TMP/tty"
if STUB_OS=Darwin run_install up >"$TMP/out" 2>&1; then fail "no means no install"; else
  check "no answer installs nothing" bash -c '! grep -q "^hdiutil" "$1"' _ "$STUB_LOG"; fi

# 11. No terminal: names --yes.
reset; touch "$STATE/docker-missing"
if STUB_OS=Darwin MARGINCE_TTY=/nonexistent/tty run_install up >"$TMP/out" 2>&1; then fail "no terminal fails"; else
  check "without a terminal the message names --yes" grep -q -- '--yes' "$TMP/out"; fi

# 12. Docker installed but not running on macOS: started, then used.
reset; touch "$STATE/daemon-down"
STUB_OS=Darwin run_install up >"$TMP/out" 2>&1 || true
check "a stopped Docker Desktop is started" grep -q '^open -a Docker$' "$STUB_LOG"

# 13. Never healthy: the logs hint.
reset
if STUB_HEALTH=starting run_install up >"$TMP/out" 2>&1; then fail "never healthy fails"; else
  check "never healthy names the logs action" grep -q 'logs' "$TMP/out"; fi

# 14. down, logins, logs, reset.
reset; run_install up >/dev/null 2>&1; : > "$STUB_LOG"
run_install down >"$TMP/out" 2>&1
check "down stops the container and keeps the data" bash -c 'grep -q "^docker stop margince-acme$" "$1" && ! grep -q "^docker rm" "$1"' _ "$STUB_LOG"
touch "$STATE/running"
run_install logins >"$TMP/out" 2>&1
check "logins prints the address and the accounts" bash -c 'grep -q "http://localhost:8080" "$1" && grep -q "stub-password" "$1"' _ "$TMP/out"
run_install logs >"$TMP/out" 2>&1
check "logs prints the last 200 lines" grep -q '^docker logs --tail 200 margince-acme$' "$STUB_LOG"
printf 'no\n' > "$TMP/tty"; : > "$STUB_LOG"
run_install reset >/dev/null 2>&1 || true
check "reset without typing yes removes nothing" bash -c '! grep -qE "^docker (rm|volume rm)" "$1"' _ "$STUB_LOG"
printf 'yes\n' > "$TMP/tty"
run_install reset >/dev/null 2>&1
check "reset after yes removes the container and the volume" bash -c 'grep -q "^docker rm -f -v margince-acme$" "$1" && grep -q "^docker volume rm margince-acme-data$" "$1"' _ "$STUB_LOG"

# 15. Placeholders left in an unrendered script are refused.
if PATH="$BIN:/usr/bin:/bin" sh "$INSTALL" up >"$TMP/out" 2>&1; then fail "an unrendered script is refused"; else
  check "an unrendered script names make aio-scripts" grep -q 'make aio-scripts' "$TMP/out"; fi

# 16. POSIX: dash parses it when present.
if command -v dash >/dev/null 2>&1; then check "dash parses install.sh" dash -n "$INSTALL"; fi
check "sh parses install.sh" sh -n "$INSTALL"

if [ "$FAILURES" -gt 0 ]; then printf '\naio-install.test.sh: %s failed\n' "$FAILURES" >&2; exit 1; fi
printf '\naio-install.test.sh: all passed\n'
```

- [ ] **Step 2: Run to verify failure** — `bash scripts/aio-install.test.sh`; Expected: FAIL (no `install.sh`).

- [ ] **Step 3: Write `scripts/aio/install.sh`**

```sh
#!/bin/sh
# install.sh — install and run Margince from its all-in-one image, on macOS
# and Ubuntu (docs/superpowers/specs/2026-09-30-all-in-one-image-design.md,
# Section 8). The Windows version is install.ps1.
#
#   curl -fsSL <url>/install.sh | sh
#   curl -fsSL <url>/install.sh | sh -s -- <action> [--yes]
#
# Actions: up (default) installs Docker when it is missing, starts Margince and
# opens it; down stops it; reset deletes it and its data; logins shows how to
# sign in; logs prints its log. make aio-up and the other make aio-* targets
# run this script with --image, --container and --volume.
#
# POSIX sh: `curl ... | sh` runs it with the system's sh.
set -eu

IMAGE='@IMAGE@'
CONTAINER='@CONTAINER@'
VOLUME='@VOLUME@'

FIRST_PORT=8080
LAST_PORT=8099
DOCKER_TIMEOUT="${MARGINCE_DOCKER_TIMEOUT:-180}"
START_TIMEOUT="${MARGINCE_START_TIMEOUT:-600}"
OS_RELEASE="${MARGINCE_OS_RELEASE:-/etc/os-release}"
TTY="${MARGINCE_TTY:-/dev/tty}"
SLEEP="${MARGINCE_SLEEP:-sleep}"

DOCKER=docker
PORT=""
ERR_FILE=""

say() { printf '%s\n' "$*"; }
fail() { printf '\nError: %s\n' "$*" >&2; exit 1; }

cleanup() { [ -z "$ERR_FILE" ] || rm -f "$ERR_FILE"; }
trap cleanup EXIT

usage() {
  say "usage: install.sh [up|down|reset|logins|logs] [--yes]"
}

ACTION=up
YES=no
while [ $# -gt 0 ]; do
  case "$1" in
    up|down|reset|logins|logs) ACTION="$1" ;;
    --yes|-y) YES=yes ;;
    --image|--container|--volume)
      [ $# -ge 2 ] || fail "$1 needs a value."
      case "$1" in
        --image) IMAGE="$2" ;;
        --container) CONTAINER="$2" ;;
        --volume) VOLUME="$2" ;;
      esac
      shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown argument: $1. Use up, down, reset, logins or logs." ;;
  esac
  shift
done

for value in "$IMAGE" "$CONTAINER" "$VOLUME"; do
  case "$value" in
    @*@) fail "This script has no image name. Create it with make aio-scripts, or run make aio-up." ;;
  esac
done

# ── questions ──

# ask <question> — 0 for yes. Reads the terminal, not standard input:
# standard input is this script when it runs as `curl ... | sh`.
ask() {
  [ "$YES" = yes ] && return 0
  if ! { : <"$TTY"; } 2>/dev/null; then
    fail "$1 There is no terminal to answer in. Run the command again with --yes at the end (sh -s -- up --yes)."
  fi
  printf '%s [Y/n] ' "$1"
  answer=""
  read -r answer <"$TTY" || answer=n
  case "$answer" in
    ""|y|Y|yes|Yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

# ── Docker ──

docker_ok() { $DOCKER info >/dev/null 2>&1; }

use_sudo_if_needed() {
  [ "$(uname -s)" = Linux ] || return 1
  command -v sudo >/dev/null 2>&1 || return 1
  sudo docker info >/dev/null 2>&1 || return 1
  DOCKER="sudo docker"
}

os_value() { sed -n "s/^$1=//p" "$OS_RELEASE" | tr -d '"' | head -n1; }

install_docker_mac() {
  case "$(uname -m)" in
    arm64) arch=arm64 ;;
    x86_64) arch=amd64 ;;
    *) fail "This Mac ($(uname -m)) is not supported." ;;
  esac
  tmp="$(mktemp -d)"
  say "Downloading Docker Desktop..."
  curl -fL --progress-bar -o "$tmp/Docker.dmg" "https://desktop.docker.com/mac/main/$arch/Docker.dmg" \
    || fail "Could not download Docker Desktop. Check the internet connection, then run this command again."
  say "Installing Docker Desktop. Enter your Mac password when asked."
  sudo hdiutil attach -nobrowse -quiet -mountpoint "$tmp/mnt" "$tmp/Docker.dmg" \
    || fail "Could not open the Docker Desktop download. Run this command again."
  if ! sudo "$tmp/mnt/Docker.app/Contents/MacOS/install" --accept-license --user="$(id -un)"; then
    sudo hdiutil detach -quiet "$tmp/mnt" || true
    fail "Docker Desktop was not installed. Install it from https://docs.docker.com/desktop/, then run this command again."
  fi
  sudo hdiutil detach -quiet "$tmp/mnt" || true
  rm -rf "$tmp"
  PATH="$PATH:/usr/local/bin:$HOME/.docker/bin"
  open -a Docker
}

install_docker_ubuntu() {
  codename="$(os_value VERSION_CODENAME)"
  say "Installing Docker Engine. Enter your password when asked."
  sudo apt-get update
  sudo apt-get install -y ca-certificates curl
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu %s stable\n' \
    "$(dpkg --print-architecture)" "$codename" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  sudo systemctl enable --now docker
  sudo usermod -aG docker "$(id -un)"
  DOCKER="sudo docker"
  say "Docker is installed. After you log in again, docker works without sudo."
}

install_docker() {
  case "$(uname -s)" in
    Darwin)
      ask "Margince needs Docker Desktop, which is not installed. Install it now? Docker's subscription terms apply." \
        || fail "Margince needs Docker. Install Docker Desktop from https://docs.docker.com/desktop/, then run this command again."
      install_docker_mac ;;
    Linux)
      [ -r "$OS_RELEASE" ] || fail "This system is not supported. Install Docker from https://docs.docker.com/get-docker/, then run this command again."
      case "$(os_value ID):$(os_value VERSION_ID)" in
        ubuntu:22.04|ubuntu:24.04) ;;
        *) fail "This system ($(os_value PRETTY_NAME)) is not supported. Install Docker Engine from https://docs.docker.com/engine/install/, then run this command again." ;;
      esac
      ask "Margince needs Docker Engine, which is not installed. Install it now?" \
        || fail "Margince needs Docker. Install Docker Engine from https://docs.docker.com/engine/install/ubuntu/, then run this command again."
      install_docker_ubuntu ;;
    *)
      fail "This system ($(uname -s)) is not supported. Install Docker from https://docs.docker.com/get-docker/, then run this command again." ;;
  esac
}

start_docker() {
  case "$(uname -s)" in
    Darwin)
      say "Starting Docker Desktop..."
      open -a Docker || fail "Docker is installed but not running. Start Docker Desktop, then run this command again." ;;
    Linux)
      sudo systemctl start docker || fail "Docker is installed but not running. Start it with: sudo systemctl start docker" ;;
  esac
}

wait_docker() {
  waited=0
  [ "$(uname -s)" = Darwin ] && say "Waiting for Docker. Docker Desktop may ask you to accept its terms; accept them to continue."
  while ! docker_ok; do
    use_sudo_if_needed && return 0
    [ "$waited" -ge "$DOCKER_TIMEOUT" ] \
      && fail "Docker did not start within 3 minutes. Start Docker Desktop, wait until it says it is running, then run this command again."
    $SLEEP 2
    waited=$((waited + 2))
  done
}

ensure_docker() {
  if command -v docker >/dev/null 2>&1 && [ "$(docker >/dev/null 2>&1; echo $?)" != 127 ]; then
    docker_ok && return 0
    use_sudo_if_needed && return 0
    start_docker
  else
    install_docker
  fi
  wait_docker
}

# For down, reset, logins and logs: Docker must already work.
require_docker() {
  if ! command -v docker >/dev/null 2>&1 || [ "$(docker >/dev/null 2>&1; echo $?)" = 127 ]; then
    say "Margince is not installed on this computer."
    exit 0
  fi
  docker_ok || use_sudo_if_needed || fail "Docker is not running. Start Docker Desktop, then run this command again."
}

# ── the container ──

container_exists() { $DOCKER container inspect "$CONTAINER" >/dev/null 2>&1; }
container_running() { [ "$($DOCKER container inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" = true ]; }
container_image() { $DOCKER container inspect -f '{{.Image}}' "$CONTAINER"; }
container_port() {
  $DOCKER container inspect -f '{{with index .HostConfig.PortBindings "80/tcp"}}{{(index . 0).HostPort}}{{end}}' "$CONTAINER" 2>/dev/null
}
image_id() { $DOCKER image inspect -f '{{.Id}}' "$IMAGE"; }

ensure_image() {
  $DOCKER image inspect "$IMAGE" >/dev/null 2>&1 && return 0
  say "Downloading Margince. This takes a few minutes the first time."
  $DOCKER pull "$IMAGE" || fail "Could not download $IMAGE. Check the internet connection, then run this command again."
}

port_error() { grep -qiE 'already in use|already allocated|bind' "$ERR_FILE"; }

# run_on <port> — create and start the container; 1 when the port is taken.
run_on() {
  if $DOCKER run -d --name "$CONTAINER" --restart unless-stopped -p "127.0.0.1:$1:80" -v "$VOLUME:/data" "$IMAGE" \
      >/dev/null 2>"$ERR_FILE"; then
    PORT="$1"
    return 0
  fi
  port_error || { cat "$ERR_FILE" >&2; fail "Docker could not start Margince (see the message above)."; }
  $DOCKER rm -f -v "$CONTAINER" >/dev/null 2>&1 || true
  return 1
}

# create_container [<port>] — on <port> when it is free, else the first free one.
create_container() {
  [ -n "${1:-}" ] && run_on "$1" && return 0
  p="$FIRST_PORT"
  while [ "$p" -le "$LAST_PORT" ]; do
    run_on "$p" && return 0
    p=$((p + 1))
  done
  fail "Ports 8080 to 8099 are all in use. Close a program that uses one of them, then run this command again."
}

wait_healthy() {
  say "Starting Margince. The first start takes a few minutes."
  waited=0
  while :; do
    status="$($DOCKER container inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$CONTAINER" 2>/dev/null || true)"
    [ "$status" = healthy ] && return 0
    [ "$waited" -ge "$START_TIMEOUT" ] \
      && fail "Margince did not start within 10 minutes. Run the command again with \"logs\" at the end (sh -s -- logs) and send the output to the person who gave you this command."
    $SLEEP 5
    waited=$((waited + 5))
  done
}

show_logins() {
  say ""
  say "Margince is running at http://localhost:$PORT"
  say ""
  $DOCKER exec "$CONTAINER" margince-logins || true
  say ""
}

open_browser() {
  url="http://localhost:$PORT"
  case "$(uname -s)" in
    Darwin) open "$url" >/dev/null 2>&1 || true ;;
    Linux)
      if command -v xdg-open >/dev/null 2>&1 && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
        xdg-open "$url" >/dev/null 2>&1 || true
      fi ;;
  esac
}

cmd_up() {
  ERR_FILE="$(mktemp)"
  ensure_docker
  ensure_image
  if container_exists; then
    PORT="$(container_port)"
    if [ "$(container_image)" != "$(image_id)" ]; then
      say "Updating Margince. Your data is kept."
      $DOCKER rm -f -v "$CONTAINER" >/dev/null
      create_container "$PORT"
    elif ! container_running; then
      if ! $DOCKER start "$CONTAINER" >/dev/null 2>"$ERR_FILE"; then
        port_error || { cat "$ERR_FILE" >&2; fail "Docker could not start Margince (see the message above)."; }
        say "Port $PORT is in use now. Moving Margince to another port. Your data is kept."
        $DOCKER rm -f -v "$CONTAINER" >/dev/null
        create_container ""
      fi
    fi
  else
    create_container ""
  fi
  wait_healthy
  show_logins
  say "To stop Margince, run the same command with \"down\" at the end. Your data is kept."
  open_browser
}

cmd_down() {
  require_docker
  container_exists || { say "Margince is not installed on this computer."; return 0; }
  $DOCKER stop "$CONTAINER" >/dev/null
  say "Margince is stopped. Your data is kept. Run the command again to start it."
}

cmd_reset() {
  require_docker
  if [ "$YES" != yes ]; then
    { : <"$TTY"; } 2>/dev/null || fail "There is no terminal to answer in. Run the command again with --yes at the end."
    printf 'This deletes Margince and all its data. Type yes to continue: '
    answer=""
    read -r answer <"$TTY" || answer=""
    [ "$answer" = yes ] || { say "Nothing was deleted."; return 1; }
  fi
  container_exists && $DOCKER rm -f -v "$CONTAINER" >/dev/null
  $DOCKER volume rm "$VOLUME" >/dev/null 2>&1 || true
  say "Margince and its data are deleted."
}

cmd_logins() {
  require_docker
  if ! container_exists || ! container_running; then
    say "Margince is not running. Run the command again without an action to start it."
    return 0
  fi
  PORT="$(container_port)"
  show_logins
}

cmd_logs() {
  require_docker
  container_exists || { say "Margince is not installed on this computer."; return 0; }
  $DOCKER logs --tail 200 "$CONTAINER" 2>&1
}

case "$ACTION" in
  up) cmd_up ;;
  down) cmd_down ;;
  reset) cmd_reset ;;
  logins) cmd_logins ;;
  logs) cmd_logs ;;
esac
```

The `docker volume rm` in `cmd_reset` must be recorded by the stub as `docker volume rm margince-acme-data` (no `-f`), matching the test.

- [ ] **Step 4: Add wrappers to `scripts/aio.sh`** (before the `case`) and dispatch lines:

```bash
# ── install.sh wrappers (make aio-up and the others) ──

install_sh() { sh "$AIO_SRC/install.sh" "$@" --container "$container" --volume "$volume"; }

cmd_up() {
  local version="${1:-}"
  require_version "$version"
  install_sh up --image "$(aio_image "$version")"
}
```

Dispatch:

```bash
  up)      shift; cmd_up "$@" ;;
  down|reset|logins|logs) install_sh "$1" --image "$(aio_image v0.0.0)" ;;
```

(`--image` is only read by `up`; the other actions need a non-placeholder value.)

- [ ] **Step 5: Makefile targets** and `test-scripts` line `@bash scripts/aio-install.test.sh`:

```make
aio-up: ## Start the all-in-one image here; installs Docker when it is missing (VERSION=)
	@bash scripts/aio.sh up "$(VERSION)"

aio-down: ## Stop the all-in-one container; the data is kept
	@bash scripts/aio.sh down

aio-reset: ## Delete the all-in-one container and its data (asks first)
	@bash scripts/aio.sh reset

aio-logins: ## The address and the accounts of the running all-in-one container
	@bash scripts/aio.sh logins

aio-logs: ## The last 200 log lines of the all-in-one container
	@bash scripts/aio.sh logs
```

Add all five to `.PHONY`.

- [ ] **Step 6: Run** `bash scripts/aio-install.test.sh && bash scripts/aio.test.sh` — Expected: all passed.

- [ ] **Step 7: Commit**

```bash
git add scripts/aio/install.sh scripts/aio-install.test.sh scripts/aio.sh Makefile
git commit -m "feat(aio): the install command for macOS and Ubuntu, and make aio-up/down/reset/logins/logs"
```

---

### Task 6: `install.ps1` and `make aio-scripts`

**Files:**
- Create: `scripts/aio/install.ps1`, `scripts/aio-install.test.ps1`
- Modify: `scripts/aio.sh` (`cmd_scripts`), `scripts/aio.test.sh` (scripts cases), `Makefile` (`aio-scripts`; `test-scripts` runs the PowerShell test when `pwsh` exists)

**Interfaces:**
- Consumes: placeholders `@IMAGE@`, `@CONTAINER@`, `@VOLUME@` in both install scripts.
- Produces: `dist/aio/<v>/install.sh` (mode 755) and `dist/aio/<v>/install.ps1`.

- [ ] **Step 1: Write the failing `aio-scripts` tests** in `scripts/aio.test.sh`:

```bash
reset_log
aio scripts v1.0.0 >/dev/null 2>&1
out="$INST/dist/aio/v1.0.0"
check "aio-scripts writes install.sh and install.ps1" bash -c '[ -x "$1/install.sh" ] && [ -f "$1/install.ps1" ]' _ "$out"
check "aio-scripts fills in the image, container and volume" bash -c 'for f in install.sh install.ps1; do grep -q "acme/all-in-one:v1.0.0" "$1/$f" && grep -q "margince-acme-data" "$1/$f" || exit 1; done' _ "$out"
check "aio-scripts leaves no placeholder" bash -c '! grep -nE "@(IMAGE|CONTAINER|VOLUME)@" "$1"/install.*' _ "$out"
if aio scripts v1 >/dev/null 2>&1; then fail "aio-scripts refuses a non-release version"; else ok "aio-scripts refuses a non-release version"; fi
```

- [ ] **Step 2: Write the failing PowerShell test** `scripts/aio-install.test.ps1`:

```powershell
# aio-install.test.ps1 — scripts/aio/install.ps1 with every external command
# replaced by a function (functions win over applications in PowerShell's
# command resolution). Run: pwsh -NoProfile -File scripts/aio-install.test.ps1
$ErrorActionPreference = 'Stop'
$script:Failures = 0
function Check([string]$What, [bool]$Condition) {
    if ($Condition) { Write-Host "ok: $What" } else { Write-Host "FAIL: $What"; $script:Failures++ }
}

$env:MARGINCE_AIO_NO_MAIN = '1'
. (Join-Path $PSScriptRoot 'aio/install.ps1')

function Reset-Stub {
    $script:Log = [System.Collections.Generic.List[string]]::new()
    $script:S = @{ DockerMissing = $false; DaemonDown = $false; Container = $null; Running = $false; Port = $null; Busy = @(); Health = 'healthy'; Answer = 'y'; WslOk = $true }
}
function Get-Command { param([string]$Name, $ErrorAction)
    if ($Name -eq 'docker' -and $script:S.DockerMissing) { return $null }
    if ($Name -eq 'winget') { return 'winget' }
    return $Name }
function docker {
    $a = $args -join ' '; $script:Log.Add("docker $a"); $global:LASTEXITCODE = 0
    switch ($args[0]) {
        'info' { if ($script:S.DaemonDown) { $global:LASTEXITCODE = 1 }; return }
        'image' { if ($a -like '*{{.Id}}*') { return 'sha256:new' }; return }
        'pull' { return }
        'container' {
            if (-not $script:S.Container) { $global:LASTEXITCODE = 1; return }
            if ($a -like '*{{.Image}}*') { return $script:S.Container }
            if ($a -like '*State.Running*') { if ($script:S.Running) { return 'true' } else { return 'false' } }
            if ($a -like '*PortBindings*') { return $script:S.Port }
            if ($a -like '*Health*') { return $script:S.Health }
            return }
        'run' {
            $p = [regex]::Match($a, '127\.0\.0\.1:(\d+):80').Groups[1].Value
            $script:S.Container = 'sha256:new'; $script:S.Port = $p
            if ($script:S.Busy -contains $p) { $global:LASTEXITCODE = 125; return 'Error: address already in use' }
            $script:S.Running = $true; return 'cid' }
        'start' { if ($script:S.Busy -contains $script:S.Port) { $global:LASTEXITCODE = 1; return 'Error: address already in use' }; $script:S.Running = $true; return }
        'stop' { $script:S.Running = $false; return }
        'rm' { $script:S.Container = $null; $script:S.Running = $false; return }
        'volume' { return }
        'exec' { return '  Sign in as admin@localhost password stub-password' }
        'logs' { return 'stub log' }
    }
}
function winget { $script:Log.Add("winget $($args -join ' ')"); $global:LASTEXITCODE = 0 }
function wsl { $script:Log.Add("wsl $($args -join ' ')"); if ($script:S.WslOk) { $global:LASTEXITCODE = 0 } else { $global:LASTEXITCODE = 1 } }
function Start-Process { param($FilePath, $ArgumentList, $Verb, [switch]$Wait) $script:Log.Add("start $FilePath $($ArgumentList -join ' ')") }
function Start-Sleep { param($Seconds) }
function Read-Host { param($Prompt) return $script:S.Answer }

$common = @('-Image', 'acme/all-in-one:v1.0.0', '-Container', 'margince-acme', '-Volume', 'margince-acme-data')

Reset-Stub
$out = Invoke-Aio (@('up') + $common) *>&1 | Out-String
Check 'up runs the container on 127.0.0.1:8080' ($script:Log -contains 'docker run -d --name margince-acme --restart unless-stopped -p 127.0.0.1:8080:80 -v margince-acme-data:/data acme/all-in-one:v1.0.0')
Check 'up shows the address and the sign-in' (($out -match 'http://localhost:8080') -and ($out -match 'stub-password'))
Check 'up opens the browser' ($script:Log -contains 'start http://localhost:8080 ')

Reset-Stub; $script:S.Busy = @('8080')
Invoke-Aio (@('up') + $common) *>&1 | Out-Null
Check 'a busy port is skipped' (@($script:Log | Where-Object { $_ -like '*127.0.0.1:8081:80*' }).Count -eq 1)

Reset-Stub; $script:S.Container = 'sha256:old'; $script:S.Port = '8085'
Invoke-Aio (@('up') + $common) *>&1 | Out-Null
Check 'a container of another image is replaced on its port' (($script:Log -contains 'docker rm -f -v margince-acme') -and (@($script:Log | Where-Object { $_ -like '*127.0.0.1:8085:80*' }).Count -eq 1))

Reset-Stub; $script:S.DockerMissing = $true
Invoke-Aio (@('up', '-Yes') + $common) *>&1 | Out-Null
Check 'a missing Docker is installed with winget' (@($script:Log | Where-Object { $_ -like 'winget install -e --id Docker.DockerDesktop*' }).Count -eq 1)

Reset-Stub; $script:S.DockerMissing = $true; $script:S.WslOk = $false
$out = Invoke-Aio (@('up', '-Yes') + $common) *>&1 | Out-String
Check 'a missing WSL is installed and the tester is asked to restart' ((@($script:Log | Where-Object { $_ -like 'start wsl.exe --install --no-distribution*' }).Count -eq 1) -and ($out -match 'Restart'))

Reset-Stub; $script:S.DockerMissing = $true; $script:S.Answer = 'n'
Invoke-Aio (@('up') + $common) *>&1 | Out-Null
Check 'no answer installs nothing' (@($script:Log | Where-Object { $_ -like 'winget*' }).Count -eq 0)

Reset-Stub; $script:S.Health = 'starting'; $env:MARGINCE_START_TIMEOUT = '10'
$out = Invoke-Aio (@('up') + $common) *>&1 | Out-String
Check 'never healthy names the logs action' ($out -match 'logs')
Remove-Item Env:MARGINCE_START_TIMEOUT

Reset-Stub; Invoke-Aio (@('up') + $common) *>&1 | Out-Null; $script:Log.Clear()
Invoke-Aio (@('down') + $common) *>&1 | Out-Null
Check 'down stops the container' ($script:Log -contains 'docker stop margince-acme')
$script:S.Answer = 'yes'
Invoke-Aio (@('reset') + $common) *>&1 | Out-Null
Check 'reset after yes removes the container and the volume' (($script:Log -contains 'docker rm -f -v margince-acme') -and ($script:Log -contains 'docker volume rm margince-acme-data'))

$out = Invoke-Aio @('up') *>&1 | Out-String
Check 'an unrendered script names make aio-scripts' ($out -match 'make aio-scripts')

if ($script:Failures -gt 0) { Write-Host "`naio-install.test.ps1: $($script:Failures) failed"; exit 1 }
Write-Host "`naio-install.test.ps1: all passed"
```

- [ ] **Step 3: Run to verify failure**

Run: `bash scripts/aio.test.sh` (scripts cases FAIL), and `docker run --rm -v "$PWD:/w" -w /w mcr.microsoft.com/powershell pwsh -NoProfile -File scripts/aio-install.test.ps1` (FAIL: no `install.ps1`).

- [ ] **Step 4: Write `scripts/aio/install.ps1`**

```powershell
# install.ps1 — install and run Margince from its all-in-one image on Windows
# (docs/superpowers/specs/2026-09-30-all-in-one-image-design.md, Section 8).
# The macOS and Ubuntu version is install.sh.
#
#   irm <url>/install.ps1 | iex
#   .\install.ps1 -Action <up|down|reset|logins|logs> [-Yes]
#
# No param() block: `irm | iex` cannot pass parameters, and the arguments of
# a downloaded script are parsed from $args instead.

$Script:Image = '@IMAGE@'
$Script:Container = '@CONTAINER@'
$Script:Volume = '@VOLUME@'

class AioStop : System.Exception { AioStop([string]$m) : base($m) {} }

function Say([string]$Text) { Write-Host $Text }
function Fail([string]$Text) { throw [AioStop]::new($Text) }

function Test-DockerCli { [bool](Get-Command docker -ErrorAction SilentlyContinue) }
function Test-DockerOk { docker info *> $null; return ($LASTEXITCODE -eq 0) }

function Ask([string]$Question) {
    if ($Script:Yes) { return $true }
    $answer = Read-Host "$Question [Y/n]"
    return ($answer -eq '' -or $answer -match '^(y|yes)$')
}

function Install-Docker {
    if (-not (Ask 'Margince needs Docker Desktop, which is not installed. Install it now? Docker''s subscription terms apply.')) {
        Fail 'Margince needs Docker. Install Docker Desktop from https://docs.docker.com/desktop/, then run this command again.'
    }
    wsl --status *> $null
    if ($LASTEXITCODE -ne 0) {
        Say 'Installing WSL 2, which Docker Desktop needs. Windows asks for permission.'
        Start-Process -FilePath 'wsl.exe' -ArgumentList '--install', '--no-distribution' -Verb RunAs -Wait
        Fail 'Restart the computer to finish installing WSL 2, then run this command again.'
    }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Fail 'winget is not available. Install Docker Desktop from https://docs.docker.com/desktop/, then run this command again.'
    }
    Say 'Installing Docker Desktop. Windows asks for permission.'
    winget install -e --id Docker.DockerDesktop --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        Fail 'Docker Desktop was not installed. Install it from https://docs.docker.com/desktop/, then run this command again.'
    }
    $env:Path += ";$env:ProgramFiles\Docker\Docker\resources\bin"
    Start-DockerDesktop
}

function Start-DockerDesktop {
    Say 'Starting Docker Desktop...'
    Start-Process -FilePath "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe"
}

function Wait-Docker {
    Say 'Waiting for Docker. Docker Desktop may ask you to accept its terms; accept them to continue.'
    $timeout = [int]($env:MARGINCE_DOCKER_TIMEOUT, 180 | Where-Object { $_ } | Select-Object -First 1)
    for ($waited = 0; -not (Test-DockerOk); $waited += 2) {
        if ($waited -ge $timeout) {
            Fail 'Docker did not start within 3 minutes. Start Docker Desktop, wait until it says it is running, then run this command again.'
        }
        Start-Sleep -Seconds 2
    }
}

function Confirm-Docker {
    if (Test-DockerCli) {
        if (Test-DockerOk) { return }
        Start-DockerDesktop
    } else {
        Install-Docker
    }
    Wait-Docker
}

function Test-Container { docker container inspect $Script:Container *> $null; return ($LASTEXITCODE -eq 0) }
function Get-ContainerValue([string]$Format) { (docker container inspect -f $Format $Script:Container 2>$null | Out-String).Trim() }
function Get-ContainerPort { Get-ContainerValue '{{with index .HostConfig.PortBindings "80/tcp"}}{{(index . 0).HostPort}}{{end}}' }

function Confirm-Image {
    docker image inspect $Script:Image *> $null
    if ($LASTEXITCODE -eq 0) { return }
    Say 'Downloading Margince. This takes a few minutes the first time.'
    docker pull $Script:Image
    if ($LASTEXITCODE -ne 0) { Fail "Could not download $($Script:Image). Check the internet connection, then run this command again." }
}

function Test-PortError([string]$Text) { return ($Text -match 'already in use|already allocated|bind') }

function Start-On([string]$Port) {
    $err = docker run -d --name $Script:Container --restart unless-stopped -p "127.0.0.1:${Port}:80" -v "$($Script:Volume):/data" $Script:Image 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0) { $Script:Port = $Port; return $true }
    if (-not (Test-PortError $err)) { Say $err; Fail 'Docker could not start Margince (see the message above).' }
    docker rm -f -v $Script:Container *> $null
    return $false
}

function New-Container([string]$Port) {
    if ($Port -and (Start-On $Port)) { return }
    foreach ($p in 8080..8099) { if (Start-On "$p") { return } }
    Fail 'Ports 8080 to 8099 are all in use. Close a program that uses one of them, then run this command again.'
}

function Wait-Healthy {
    Say 'Starting Margince. The first start takes a few minutes.'
    $timeout = [int]($env:MARGINCE_START_TIMEOUT, 600 | Where-Object { $_ } | Select-Object -First 1)
    for ($waited = 0; (Get-ContainerValue '{{if .State.Health}}{{.State.Health.Status}}{{end}}') -ne 'healthy'; $waited += 5) {
        if ($waited -ge $timeout) {
            Fail 'Margince did not start within 10 minutes. Download install.ps1, run .\install.ps1 -Action logs, and send the output to the person who gave you this command.'
        }
        Start-Sleep -Seconds 5
    }
}

function Show-Logins {
    Say ''
    Say "Margince is running at http://localhost:$($Script:Port)"
    Say ''
    docker exec $Script:Container margince-logins | ForEach-Object { Say $_ }
    Say ''
}

function Invoke-Up {
    Confirm-Docker
    Confirm-Image
    if (Test-Container) {
        $Script:Port = Get-ContainerPort
        $imageId = (docker image inspect -f '{{.Id}}' $Script:Image | Out-String).Trim()
        if ((Get-ContainerValue '{{.Image}}') -ne $imageId) {
            Say 'Updating Margince. Your data is kept.'
            docker rm -f -v $Script:Container *> $null
            New-Container $Script:Port
        } elseif ((Get-ContainerValue '{{.State.Running}}') -ne 'true') {
            $err = docker start $Script:Container 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0) {
                if (-not (Test-PortError $err)) { Say $err; Fail 'Docker could not start Margince (see the message above).' }
                Say "Port $($Script:Port) is in use now. Moving Margince to another port. Your data is kept."
                docker rm -f -v $Script:Container *> $null
                New-Container ''
            }
        }
    } else {
        New-Container ''
    }
    Wait-Healthy
    Show-Logins
    Say 'To stop Margince, run .\install.ps1 -Action down. Your data is kept.'
    Start-Process -FilePath "http://localhost:$($Script:Port)"
}

function Confirm-DockerRunning {
    if (-not (Test-DockerCli)) { Say 'Margince is not installed on this computer.'; return $false }
    if (-not (Test-DockerOk)) { Fail 'Docker is not running. Start Docker Desktop, then run this command again.' }
    return $true
}

function Invoke-Down {
    if (-not (Confirm-DockerRunning)) { return }
    if (-not (Test-Container)) { Say 'Margince is not installed on this computer.'; return }
    docker stop $Script:Container *> $null
    Say 'Margince is stopped. Your data is kept. Run the command again to start it.'
}

function Invoke-Reset {
    if (-not (Confirm-DockerRunning)) { return }
    if (-not $Script:Yes) {
        $answer = Read-Host 'This deletes Margince and all its data. Type yes to continue'
        if ($answer -ne 'yes') { Say 'Nothing was deleted.'; return }
    }
    if (Test-Container) { docker rm -f -v $Script:Container *> $null }
    docker volume rm $Script:Volume *> $null
    Say 'Margince and its data are deleted.'
}

function Invoke-Logins {
    if (-not (Confirm-DockerRunning)) { return }
    if (-not (Test-Container) -or (Get-ContainerValue '{{.State.Running}}') -ne 'true') {
        Say 'Margince is not running. Run the command again without an action to start it.'; return
    }
    $Script:Port = Get-ContainerPort
    Show-Logins
}

function Invoke-Logs {
    if (-not (Confirm-DockerRunning)) { return }
    docker logs --tail 200 $Script:Container 2>&1 | ForEach-Object { Say $_ }
}

function Invoke-Aio([object[]]$Arguments) {
    $saved = @{ Image = $Script:Image; Container = $Script:Container; Volume = $Script:Volume }
    $Script:Yes = $false
    $action = 'up'
    try {
        for ($i = 0; $i -lt $Arguments.Count; $i++) {
            $arg = [string]$Arguments[$i]
            switch -regex ($arg) {
                '^(up|down|reset|logins|logs)$' { $action = $arg; continue }
                '^-Action$' { $i++; $action = [string]$Arguments[$i]; continue }
                '^-Yes$' { $Script:Yes = $true; continue }
                '^-Image$' { $i++; $Script:Image = [string]$Arguments[$i]; continue }
                '^-Container$' { $i++; $Script:Container = [string]$Arguments[$i]; continue }
                '^-Volume$' { $i++; $Script:Volume = [string]$Arguments[$i]; continue }
                default { Fail "Unknown argument: $arg. Use up, down, reset, logins or logs." }
            }
        }
        foreach ($v in @($Script:Image, $Script:Container, $Script:Volume)) {
            if ($v -match '^@.*@$') { Fail 'This script has no image name. Create it with make aio-scripts.' }
        }
        switch ($action) {
            'up' { Invoke-Up }
            'down' { Invoke-Down }
            'reset' { Invoke-Reset }
            'logins' { Invoke-Logins }
            'logs' { Invoke-Logs }
            default { Fail "Unknown action: $action. Use up, down, reset, logins or logs." }
        }
        return $true
    } catch [AioStop] {
        Write-Host ''
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    } finally {
        $Script:Image = $saved.Image; $Script:Container = $saved.Container; $Script:Volume = $saved.Volume
    }
}

if (-not $env:MARGINCE_AIO_NO_MAIN) {
    $ok = Invoke-Aio $args
    # Exit only when run as a file: under `irm | iex`, exit would close the
    # tester's PowerShell window.
    if (-not $ok -and $PSCommandPath) { exit 1 }
}
```

Note for the test: `Invoke-Aio` output includes the boolean return; the test pipes to `Out-String`/`Out-Null`, which is fine.

- [ ] **Step 5: Implement `cmd_scripts`** in `scripts/aio.sh`, dispatch `scripts) shift; cmd_scripts "$@" ;;`:

```bash
# ── install scripts ──

cmd_scripts() {
  local version="${1:-}" out f
  require_version "$version"
  out="$ROOT/dist/aio/$version"
  mkdir -p "$out"
  for f in install.sh install.ps1; do
    sed -e "s|@IMAGE@|$(aio_image "$version")|g" -e "s|@CONTAINER@|$container|g" -e "s|@VOLUME@|$volume|g" \
      "$AIO_SRC/$f" > "$out/$f"
    if grep -qE '@(IMAGE|CONTAINER|VOLUME)@' "$out/$f"; then die "aio-scripts: a placeholder is left in $out/$f"; fi
  done
  chmod 755 "$out/install.sh"
  say "wrote $out/install.sh and $out/install.ps1 for $(aio_image "$version")"
}
```

Wait: `grep -qE '@(IMAGE|CONTAINER|VOLUME)@'` also matches the placeholder check inside the scripts (`@*@` pattern does not; `'^@.*@$'` does not) — both scripts contain no literal `@IMAGE@` besides the defaults, so after substitution the check passes.

- [ ] **Step 6: Makefile** — target and PowerShell test in `test-scripts`:

```make
aio-scripts: ## Write dist/aio/<v>/install.sh and install.ps1 for testers (VERSION=)
	@bash scripts/aio.sh scripts "$(VERSION)"
```

In `test-scripts`, after `@bash scripts/aio-install.test.sh`:

```make
	@if command -v pwsh >/dev/null 2>&1; then pwsh -NoProfile -File scripts/aio-install.test.ps1; \
	  else echo "aio-install.test.ps1: skipped (pwsh is not installed; CI runs it)"; fi
```

Add `aio-scripts` to `.PHONY`.

- [ ] **Step 7: Run**

Run: `bash scripts/aio.test.sh` and `docker run --rm -v "$PWD:/w" -w /w mcr.microsoft.com/powershell pwsh -NoProfile -File scripts/aio-install.test.ps1`
Expected: both `all passed`.

- [ ] **Step 8: Commit**

```bash
git add scripts/aio/install.ps1 scripts/aio-install.test.ps1 scripts/aio.sh scripts/aio.test.sh Makefile
git commit -m "feat(aio): the Windows install command and make aio-scripts"
```

---

### Task 7: Release workflow

**Files:**
- Modify: `.github/workflows/release.yml` (`images` job, `publish` job)
- Modify: `scripts/release.test.sh` or `scripts/workflow-wiring.test.sh` only if an existing assertion breaks.

**Interfaces:**
- Consumes: `make aio`, `make aio-smoke`, `make aio-scripts`; `METADATA_FILE` in `aio.sh build`.

- [ ] **Step 1: Add steps to the `images` job**, after `Smoke test`:

```yaml
      ## The all-in-one image (docs/superpowers/specs/2026-09-30-all-in-one-image-design.md).
      ## The dataset reaches it as it reaches the desktop lanes; without it the
      ## image has no demo data and says so.
      - name: Can the demo dataset be reached?
        id: dataset
        shell: bash
        env:
          KEY: ${{ secrets.DATASET_DEPLOY_KEY }}
          REPO: ${{ vars.DATASET_REPOSITORY }}
        run: |
          if [ -n "$KEY" ] && [ -n "$REPO" ]; then
            echo "available=true" >> "$GITHUB_OUTPUT"
          else
            echo "available=false" >> "$GITHUB_OUTPUT"
            echo "::notice::no DATASET_REPOSITORY/DATASET_DEPLOY_KEY — the all-in-one image has no demo data"
          fi

      - name: Check out the demo dataset
        if: steps.dataset.outputs.available == 'true'
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          repository: ${{ vars.DATASET_REPOSITORY }}
          ssh-key: ${{ secrets.DATASET_DEPLOY_KEY }}
          path: .dataset
          persist-credentials: false

      - name: Build the all-in-one image (linux/amd64, loaded locally)
        shell: bash
        env:
          DATASET: ${{ steps.dataset.outputs.available == 'true' && '.dataset' || '' }}
        run: make aio VERSION="$VERSION"

      - name: Smoke test the all-in-one image
        shell: bash
        run: make aio-smoke VERSION="$VERSION"
```

In `Push the images`, after the role loop that writes `images.txt`, append:

```bash
          aio_metadata="$RUNNER_TEMP/aio-metadata.json"
          DATASET="${AIO_DATASET:-}" make aio VERSION="$VERSION" PUSH=1 METADATA_FILE="$aio_metadata"
          digest="$(jq -er '."containerimage.digest"' "$aio_metadata")"
          echo "${repo}/all-in-one:${VERSION}@${digest}" >> "$list"
```

and add `AIO_DATASET: ${{ steps.dataset.outputs.available == 'true' && '.dataset' || '' }}` to that step's `env`.

After `Image list to the job summary`:

```yaml
      - name: Install scripts for testers
        shell: bash
        run: make aio-scripts VERSION="$VERSION"

      - uses: actions/upload-artifact@043fb46d1a93c77aae656e7c1c64a875d1fc6a0a # v7.0.1
        with:
          name: margince-aio-scripts-${{ needs.version.outputs.version }}
          path: |
            dist/aio/${{ needs.version.outputs.version }}/install.sh
            dist/aio/${{ needs.version.outputs.version }}/install.ps1
          if-no-files-found: error
```

- [ ] **Step 2: `publish` job** — download the scripts next to the zips, attach them, and add the tester commands to the notes:

```yaml
      - uses: actions/download-artifact@3e5f45b2cfb9172054b4087a40e8e0b5a5461e7c # v8.0.1
        with:
          name: margince-aio-scripts-${{ needs.version.outputs.version }}
          path: dist
```

In `Release notes`, after the images block inside `{ ... } > notes.md`:

```bash
            echo
            echo "## Try it"
            echo
            echo "Testers start the all-in-one image with one command (Docker is installed when it is missing):"
            echo
            echo "- macOS, Ubuntu: \`curl -fsSL https://github.com/${GITHUB_REPOSITORY}/releases/download/${TAG}/install.sh | sh\`"
            echo "- Windows (PowerShell): \`irm https://github.com/${GITHUB_REPOSITORY}/releases/download/${TAG}/install.ps1 | iex\`"
```

with `TAG: ${{ needs.version.outputs.version }}` added to the step's `env`. In `Publish the release`, replace `dist/*.zip` with `dist/*.zip dist/install.sh dist/install.ps1` in both the `gh release upload` and the `gh release create` lines.

- [ ] **Step 3: Validate**

Run: `make test-scripts` (includes `workflow-wiring.test.sh` and `release.test.sh`), and `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/release.yml'))"`.
Expected: all passed; YAML loads. If an existing test asserts the exact `dist/*.zip` spelling or the step list, update that assertion to the new spelling in the same commit.

- [ ] **Step 4: Commit**

```bash
git add .github/workflows/release.yml scripts/*.test.sh
git commit -m "ci(release): build, smoke-test, push and attach the all-in-one image"
```

---

### Task 8: Documentation

**Files:**
- Create: `docs/try-margince.md`
- Modify: `README.md` (Quick start section and command table), `docs/README.md`, `docs/glossary.md`, `docs/troubleshooting.md`
- Modify: `docs/superpowers/specs/2026-09-24-client-instance-template-design.md` (T19 status → Done)

- [ ] **Step 1: Write `docs/try-margince.md`** with numbered sections:

1. Purpose and audience (instance owner; testers are non-technical); limits (test mode, `127.0.0.1` only, not for production, one image per release).
2. Prerequisites (a checkout with `make install`, Docker with Buildx; for `PUSH=1` a registry that allows anonymous pulls).
3. Build: `make aio VERSION=<v>`; variable table (`VERSION`, `DATASET`, `PUSH`, `REGISTRY`, `REPO`, `AIO_PLATFORMS`, `METADATA_FILE`); what it runs; the dataset rule (EUR, the image then contains the dataset's files).
4. Test locally: `make aio-smoke VERSION=<v>`, `make aio-up VERSION=<v>`, `make aio-logins`, `make aio-logs`, `make aio-down`, `make aio-reset`.
5. Give testers the command: `make aio-scripts VERSION=<v>`; hosting options (GitHub release assets, which `release.yml` attaches, when the repository is public; any web server); the two one-liners; the other actions.
6. What the tester sees: Docker install per system (table from spec Section 8.2), address, sign-in, first-sign-in password change, seeded accounts.
7. What is inside and where data lives (table from spec Section 5.5); reset.
8. Browsers: record the result of Review Focus item 1 (Task 9 Step 3) — the browsers verified to sign in over `http://localhost`.

- [ ] **Step 2: Other documents**
  - `README.md`: under Quick start, a subsection `### Let a tester try Margince` with `make aio VERSION=<v>`, `make aio-scripts VERSION=<v>` and a link to `docs/try-margince.md`; add rows for `aio`, `aio-up`, `aio-smoke`, `aio-scripts` to the command table.
  - `docs/README.md`: a row `| [Try Margince](try-margince.md) | Build the all-in-one image and give testers the one-line install command. |`.
  - `docs/glossary.md`: entries `## all-in-one image` and `## install command`, alphabetically placed, each linking to `try-margince.md`.
  - `docs/troubleshooting.md`: a section `## All-in-one image` with each message of spec Section 8.4, plus `aio: PUSH=1 requires REGISTRY`, `aio-smoke: no image`, with cause and fix.
  - Main spec Section 13: T19 → `Done`, and the Order line ends `→ T19. All complete.`

- [ ] **Step 3: Validate**

Run: `make check-docs && make check-public`
Expected: both pass. Check every relative link and anchor by hand (`grep -o '([a-z-]*\.md#[^)]*)' docs/try-margince.md`).

- [ ] **Step 4: Commit**

```bash
git add docs README.md
git commit -m "docs: guide for the all-in-one image and the tester's install command"
```

---

### Task 9: End-to-end verification with the real image

**Files:** none new; fixes go to the files of Tasks 2–6 with their own commits.

- [ ] **Step 1: Build the role images and the image** (native platform; `ALLOW_DIRTY=1` only when the tree has uncommitted fixes):

```bash
make package VERSION=v0.0.0-rc.1
make aio VERSION=v0.0.0-rc.1
```

Expected: `aio: built margince-default/all-in-one:v0.0.0-rc.1`.

- [ ] **Step 2: Smoke test**

Run: `make aio-smoke VERSION=v0.0.0-rc.1`
Expected: `aio: smoke: passed`. On failure, read the printed log, fix, rebuild, rerun.

- [ ] **Step 3: Review Focus item 1** — record the cookie flags:

```bash
docker run -d --name aio-cookie -p 127.0.0.1:18080:80 margince-default/all-in-one:v0.0.0-rc.1
# wait for healthy, then:
pw="$(docker exec aio-cookie sed -n 's/^MARGINCE_ADMIN_PASSWORD=//p' /data/secrets.env)"
printf '{"email":"admin@localhost","password":"%s"}' "$pw" | curl -si -X POST -H 'Content-Type: application/json' --data-binary @- http://127.0.0.1:18080/v1/auth/login | grep -i '^set-cookie'
docker rm -f -v aio-cookie
```

Write the result into `docs/try-margince.md` Section 8 (if `Secure` is set: Chrome, Edge and Firefox accept it on `http://localhost`; Safari may not).

- [ ] **Step 4: The tester flow through make**

Run: `make aio-up VERSION=v0.0.0-rc.1`, then `make aio-logins`, `make aio-down`, `make aio-up VERSION=v0.0.0-rc.1` (restart keeps data), `make aio-reset` (type `yes`).
Expected: each prints the messages of spec Section 8; the second `up` keeps the password shown by the first.

- [ ] **Step 5: Full gates**

Run: `make test-scripts && make check-docs && make check-public`
Expected: all pass.

- [ ] **Step 6: Commit any fixes** with `fix(aio): <what>` messages, one per fix.
