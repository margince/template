# Instance Basics Implementation Plan (T3, T4, T5, T6, T11)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One command creates a new client instance from the template. The instance has neutral image names and labels, pins core by release tag, can add its own make targets, and fails `make check` when it edits a template-owned file. Template changes reach it with `make template-sync`.

**Architecture:** Scripts read `instance.yaml` through the existing Go CLI (`scripts/cli`), which gains a `get` command. New shell scripts follow the existing pattern (one script, one `*.test.sh` beside it, listed in `make test-scripts`). The drift check compares template-owned paths with the template commit recorded in `.template-version`; the list of template-owned paths is read from that commit, so an instance cannot shrink it.

**Tech Stack:** GNU Make (macOS ships 3.81), Bash 3.2-compatible shell (no `mapfile`), Go 1.26.6, git.

**Spec:** [`docs/superpowers/specs/2026-09-24-client-instance-template-design.md`](../specs/2026-09-24-client-instance-template-design.md) Sections 6, 7, 9, 11. Issues: [T3 #3](https://github.com/gradionhq/margince-template/issues/3), [T4 #4](https://github.com/gradionhq/margince-template/issues/4), [T5 #5](https://github.com/gradionhq/margince-template/issues/5), [T6 #6](https://github.com/gradionhq/margince-template/issues/6), [T11 #11](https://github.com/gradionhq/margince-template/issues/11).

**Base:** branch `feat/instance-basics`, stacked on `feat/template-foundation` (PR #15).

## Global Constraints

- Shell must run on macOS Bash 3.2 and Linux Bash 5: no `mapfile`, no `${var,,}`, no `declare -A`.
- GNU Make on macOS is 3.81: its duplicate-recipe warning reads `warning: overriding commands for target`; Make 4.x reads `warning: overriding recipe for target`. Match both.
- The Go CLI runs with `GOWORK=off` (the editor `go.work` at the repository root does not list `scripts/cli`).
- Image names follow core's `docker-bake.hcl`, which names images `${REPO}/api`, `${REPO}/web`, `${REPO}/worker`. The instance sets `REPO=<registry>/<flavor>`; without a registry, `REPO=<flavor>`.
- Core release tags are `v0.0.x` (spec Section 11). `make update-core` accepts tags only.
- The template contains no client unit names or client-specific wording. `gradionhq/*` repository names and the SPDX header are allowed.
- No file under `core/` is edited.
- `make new-instance` never pushes or creates a GitHub repository unless `PUSH=1` is given.
- Documentation uses technical standard English.
- Commits use Conventional Commits and end with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.

## Review Focus

1. **An instance edits a template-owned file and also removes it from `.template-owned`.** The drift check must still fail: it reads the list from the template commit. Test in Task 5.
2. **A new file added under a template-owned directory** (for example `scripts/extra.sh`), committed or untracked. The drift check must fail. Test in Task 5.
3. **`make update-core REF=main`** or a commit SHA. Refused, and `core/` and `instance.yaml` stay unchanged. Test in Task 3.
4. **`instance.mk` redefines `check`.** `make check-template` fails and names the target, on Make 3.81 and 4.x. Test in Task 4.
5. **`make new-instance` with an invalid name, or into an existing directory.** Refused before anything is created. Test in Task 6.

---

### Task 1: `cli get` and `instance_get`

**Files:**
- Modify: `scripts/cli/main.go` (dispatch), `scripts/cli/instance.go` (add `Value`)
- Create: `scripts/cli/get.go`, `scripts/cli/get_test.go`
- Modify: `scripts/lib.sh` (add `instance_get`), `scripts/lib.test.sh`

**Interfaces:**
- Produces (Go): `func (Instance) Value(key string) (string, bool)`; `func runCheck(args []string, stdout, stderr io.Writer) int` (the current body of `run` after the `check` word); `func runGet(args []string, stdout, stderr io.Writer) int`.
- Produces (CLI): `cli get [-file instance.yaml] <key>` prints the value and exits 0; exit 1 when the file is unreadable, invalid YAML, or the value is empty; exit 2 on an unknown key or usage error.
- Produces (shell): `instance_get <key>` prints one value from `${INSTANCE_FILE:-$ROOT/instance.yaml}`.

- [ ] **Step 1: Write the failing Go tests** — `scripts/cli/get_test.go`:

```go
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
		"flavor":       "margince/margince",
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
	if code := run([]string{"get", "-file", writeFile(t, "name: a\n"), "flavor"}, &out, &errOut); code != 1 {
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
```

`writeFile` and `valid` already exist in `main_test.go` and `instance_test.go`.

- [ ] **Step 2: Run to verify failure**

Run: `cd scripts/cli && GOWORK=off go test ./...`
Expected: FAIL (`get` is a usage error today, so the tests get exit 2 instead of 0/1).

- [ ] **Step 3: Implement**

In `scripts/cli/main.go`, replace the head of `run` so it dispatches, and move the rest of the current body into `runCheck`:

```go
const usage = "usage: cli check [-file instance.yaml] [-core core] | cli get [-file instance.yaml] <key>"

func run(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, usage)
		return 2
	}
	switch args[0] {
	case "check":
		return runCheck(args[1:], stdout, stderr)
	case "get":
		return runGet(args[1:], stdout, stderr)
	}
	fmt.Fprintln(stderr, usage)
	return 2
}

// runCheck validates instance.yaml and that core/ is at the tag it names.
func runCheck(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("check", flag.ContinueOnError)
	fs.SetOutput(stderr)
	file := fs.String("file", "instance.yaml", "path to instance.yaml")
	core := fs.String("core", "core", "path to the core submodule")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	// … the remainder of the former run body, unchanged …
}
```

Update the package comment's usage lines to list both commands.

In `scripts/cli/instance.go`, add:

```go
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
```

Create `scripts/cli/get.go`:

```go
package main

import (
	"flag"
	"fmt"
	"io"
	"os"
)

// runGet prints one value from instance.yaml. Scripts read the file through
// this command, so there is one parser.
func runGet(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("get", flag.ContinueOnError)
	fs.SetOutput(stderr)
	file := fs.String("file", "instance.yaml", "path to instance.yaml")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if fs.NArg() != 1 {
		fmt.Fprintln(stderr, "usage: cli get [-file instance.yaml] <key>")
		return 2
	}
	key := fs.Arg(0)

	data, err := os.ReadFile(*file)
	if err != nil {
		fmt.Fprintf(stderr, "instance.yaml: %v\n", err)
		return 1
	}
	in, err := Parse(data)
	if err != nil {
		fmt.Fprintf(stderr, "instance.yaml: %v\n", err)
		return 1
	}
	value, ok := in.Value(key)
	if !ok {
		fmt.Fprintf(stderr, "instance.yaml: unknown key %q (want name, display_name, core, flavor)\n", key)
		return 2
	}
	if value == "" {
		fmt.Fprintf(stderr, "instance.yaml: %s is empty\n", key)
		return 1
	}
	fmt.Fprintln(stdout, value)
	return 0
}
```

- [ ] **Step 4: Run the Go tests**

Run: `cd scripts/cli && GOWORK=off go vet ./... && GOWORK=off go test ./... && gofmt -l .`
Expected: `ok`, and `gofmt -l` prints nothing. Existing tests still pass (`TestRunUsage` expects 2 for no command and for an unknown command).

- [ ] **Step 5: Add `instance_get` to `scripts/lib.sh`** (after `source_units`):

```bash
# instance_get <key> — one value from instance.yaml.
#
# Read through the template CLI so there is one parser. GOWORK=off because the
# editor go.work at the repository root does not list scripts/cli.
# INSTANCE_FILE overrides the file, for tests.
instance_get() {
  (cd "$ROOT/scripts/cli" && GOWORK=off go run . get -file "${INSTANCE_FILE:-$ROOT/instance.yaml}" "$1")
}
```

- [ ] **Step 6: Test it in `scripts/lib.test.sh`** (append a section before the final summary):

```bash
# --- instance_get ---

INSTANCE_FILE="$TMP/instance.yaml"
printf 'name: acme\ndisplay_name: Acme\ncore: v0.0.2\nflavor: acme/margince\n' > "$INSTANCE_FILE"
if [ "$(instance_get name)" = "acme" ]; then ok "instance_get reads a key"; else fail "instance_get reads a key"; fi
if [ "$(instance_get flavor)" = "acme/margince" ]; then ok "instance_get reads the flavor"; else fail "instance_get reads the flavor"; fi
if instance_get units >/dev/null 2>&1; then fail "instance_get refuses an unknown key"; else ok "instance_get refuses an unknown key"; fi
unset INSTANCE_FILE
```

Run: `bash scripts/lib.test.sh`
Expected: all cases pass.

- [ ] **Step 7: Commit**

```bash
git add scripts/cli scripts/lib.sh scripts/lib.test.sh
git commit -m "feat(cli): get one value from instance.yaml"
```

### Task 2: Neutral image names, labels, and bundle text (T3)

**Files:**
- Modify: `scripts/lib.sh` (add `image_repo`), `scripts/lib.test.sh`
- Modify: `scripts/package.sh:24`, `scripts/package.sh:61-69`
- Modify: `scripts/desktop.sh:863`, `scripts/build-info.sh:244`
- Modify: `docs/*.md` lines that document `package.sh`'s default `REPO` or the `com.gradion.*` labels (find with `grep -n 'com.gradion\|REPO' docs/*.md`)

**Interfaces:**
- Consumes: `instance_get` (Task 1).
- Produces: `image_repo` prints `<REGISTRY>/<flavor>` when `REGISTRY` is set (trailing `/` removed), else `<flavor>`.

- [ ] **Step 1: Write the failing test** — append to `scripts/lib.test.sh` after the `instance_get` section:

```bash
# --- image_repo ---

INSTANCE_FILE="$TMP/instance.yaml"
unset REGISTRY
if [ "$(image_repo)" = "acme/margince" ]; then ok "image_repo is the flavor without a registry"; else fail "image_repo is the flavor without a registry"; fi
if [ "$(REGISTRY=registry.example.com image_repo)" = "registry.example.com/acme/margince" ]; then ok "image_repo prefixes the registry"; else fail "image_repo prefixes the registry"; fi
if [ "$(REGISTRY=registry.example.com/ image_repo)" = "registry.example.com/acme/margince" ]; then ok "image_repo drops a trailing slash"; else fail "image_repo drops a trailing slash"; fi
unset INSTANCE_FILE
```

Run: `bash scripts/lib.test.sh`
Expected: FAIL (`image_repo: command not found`).

- [ ] **Step 2: Implement `image_repo` in `scripts/lib.sh`** (after `instance_get`):

```bash
# image_repo — the REPO this instance's role images are named under.
#
# core's docker-bake.hcl names the images ${REPO}/api, ${REPO}/web and
# ${REPO}/worker. The instance's flavor (<vendor>/margince) is the namespace;
# REGISTRY, when set, is the registry host in front of it.
image_repo() {
  local flavor
  flavor="$(instance_get flavor)"
  if [ -n "${REGISTRY:-}" ]; then
    printf '%s/%s\n' "${REGISTRY%/}" "$flavor"
  else
    printf '%s\n' "$flavor"
  fi
}
```

Run: `bash scripts/lib.test.sh` — Expected: all pass.

- [ ] **Step 3: Use it in `scripts/package.sh`**

Replace `REPO="${REPO:-margince-automation-world}"` with:

```bash
REPO="${REPO:-$(image_repo)}"
instance_name="$(instance_get name)"
```

Replace the three `--set "*.labels.com.gradion.*"` lines with:

```bash
    --set "*.labels.com.margince.instance.name=$instance_name" \
    --set "*.labels.com.margince.instance.revision=$revision" \
    --set "*.labels.com.margince.core.revision=$core_revision" \
    --set "*.labels.com.margince.instance.units=${units% }" \
```

In the header comment, replace "this installation" with "this instance" and "installation image" with "instance image". In the summary lines, change `installation %s` to `instance      %s`.

- [ ] **Step 4: Neutralize the bundle text**

- `scripts/desktop.sh:863`: replace `Ask your Gradion contact` with `Ask the team that provided this build`.
- `scripts/build-info.sh:244`: replace `"repo" is the Gradion installation` with `"repo" is the instance repository`.
- Update any test that asserts the old text: `grep -rn 'Gradion contact\|Gradion installation' scripts/*.test.sh` must print nothing afterwards.

- [ ] **Step 5: Update docs**

Every doc line that shows `REPO=margince-automation-world` or a `com.gradion.` label now shows `<flavor>` / `com.margince.instance.` / `com.margince.core.`.

Check: `grep -rn -i -E 'gradion|automation-world' scripts/package.sh scripts/desktop.sh scripts/build-info.sh` prints only `gradionhq/margince-demo-database` lines.

- [ ] **Step 6: Run the suites**

Run: `make test-scripts && bash scripts/check-docs.sh`
Expected: both pass. (`make package` needs Docker and a long build; it is exercised in Task 7.)

- [ ] **Step 7: Commit**

```bash
git add scripts docs
git commit -m "feat(package): name images after the flavor; neutral labels and bundle text"
```

### Task 3: `update-core` accepts release tags only (T5)

**Files:**
- Create: `scripts/update-core.sh`, `scripts/update-core.test.sh`
- Modify: `Makefile` (`update-core` target, `test-scripts`), `README.md` (`make update-core REF=<tag>`), docs that describe `update-core` without a `REF`

**Interfaces:**
- Consumes: `require_core`, `die`, `rewrite_file_in_place`, `ROOT`, `CORE` (lib.sh); `bash scripts/core-contrib.sh guard-update` (fetches `origin main --tags`, refuses a core/ with local work).
- Produces: `bash scripts/update-core.sh <tag>` moves `core/` to the tag and sets `core: <tag>` in `instance.yaml`; exits non-zero and changes nothing for an empty ref, a branch, or a commit.

- [ ] **Step 1: Write the failing test `scripts/update-core.test.sh`**

```bash
#!/usr/bin/env bash
# update-core.test.sh — move a throwaway core between tags.
#
# A fake upstream carries two tagged releases and one untagged commit on main.
# Each case works in a fresh copy of this repository's scripts/ beside a clone
# of that upstream as core/.
#
# Usage: bash scripts/update-core.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

export GIT_AUTHOR_NAME="Test Dev"     GIT_AUTHOR_EMAIL="dev@example.test"
export GIT_COMMITTER_NAME="Test Dev"  GIT_COMMITTER_EMAIL="dev@example.test"
export GIT_CONFIG_NOSYSTEM=1

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILURES=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }
ok()   { printf 'ok: %s\n' "$*"; }

# The upstream: v0.0.1, v0.0.2, then one untagged commit on main.
UP="$TMP/upstream"
git init -q -b main "$UP"
printf 'go 1.26.6\n' > "$UP/go.work"
git -C "$UP" add -A && git -C "$UP" commit -q -m one && git -C "$UP" tag v0.0.1
printf 'two\n' > "$UP/two" && git -C "$UP" add -A && git -C "$UP" commit -q -m two && git -C "$UP" tag v0.0.2
printf 'three\n' > "$UP/three" && git -C "$UP" add -A && git -C "$UP" commit -q -m three
V2="$(git -C "$UP" rev-parse v0.0.2^{commit})"
MAIN="$(git -C "$UP" rev-parse main)"

fresh_repo() {
  local repo
  repo="$(mktemp -d "$TMP/repo.XXXXXX")"
  cp -R "$SCRIPT_DIR" "$repo/scripts"
  git clone -q "$UP" "$repo/core"
  git -C "$repo/core" checkout -q --detach v0.0.1
  printf 'name: acme\ndisplay_name: Acme\ncore: v0.0.1\nflavor: acme/margince\n' > "$repo/instance.yaml"
  printf '%s' "$repo"
}

# --- a release tag ---

repo="$(fresh_repo)"
if out="$(bash "$repo/scripts/update-core.sh" v0.0.2 2>&1)"; then ok "moves to a release tag"; else fail "moves to a release tag: $out"; fi
if [ "$(git -C "$repo/core" rev-parse HEAD)" = "$V2" ]; then ok "core/ is at the tag"; else fail "core/ is at the tag"; fi
if grep -qx 'core: v0.0.2' "$repo/instance.yaml"; then ok "instance.yaml records the tag"; else fail "instance.yaml records the tag"; fi
if grep -qx 'flavor: acme/margince' "$repo/instance.yaml"; then ok "other keys are unchanged"; else fail "other keys are unchanged"; fi

# --- refusals change nothing ---

expect_refused() {
  local label="$1" ref="$2" repo
  repo="$(fresh_repo)"
  if bash "$repo/scripts/update-core.sh" "$ref" >/dev/null 2>&1; then
    fail "$label — it succeeded"
  elif [ "$(git -C "$repo/core" describe --tags --exact-match 2>/dev/null)" != "v0.0.1" ]; then
    fail "$label — core/ moved"
  elif ! grep -qx 'core: v0.0.1' "$repo/instance.yaml"; then
    fail "$label — instance.yaml changed"
  else
    ok "$label"
  fi
}

expect_refused "refuses an empty ref" ""
expect_refused "refuses a branch" main
expect_refused "refuses a commit" "$MAIN"
expect_refused "refuses a tag that does not exist" v9.9.9

if [ "$FAILURES" -gt 0 ]; then printf '\n%s case(s) failed\n' "$FAILURES" >&2; exit 1; fi
printf '\nall cases passed\n'
```

Run: `bash scripts/update-core.test.sh; echo rc=$?`
Expected: `FAIL: moves to a release tag` (the script does not exist), `rc=1`.

- [ ] **Step 2: Implement `scripts/update-core.sh`**

```bash
#!/usr/bin/env bash
# update-core.sh — move core/ to a core release tag and record it in instance.yaml.
#
# Instances pin core releases only (design Section 11). A branch or a commit
# names no release, so instance.yaml could not name it either, and
# `make check-instance` would refuse the result. Refusing here says so first.
#
# Usage: bash scripts/update-core.sh <tag>   (or: make update-core REF=<tag>)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_core

ref="${1:-}"
[ -n "$ref" ] || die "update-core: pass a core release tag, e.g. make update-core REF=v0.0.3"

# Fetches origin main with tags, then refuses a core/ that holds work of its own.
bash "$ROOT/scripts/core-contrib.sh" guard-update

git -C "$CORE" rev-parse -q --verify "refs/tags/$ref^{commit}" >/dev/null \
  || die "update-core: '$ref' is not a core release tag. Instances pin releases only; list them with: git -C core tag --list 'v*'"

git -C "$CORE" checkout -q --detach "refs/tags/$ref"
rewrite_file_in_place "$ROOT/instance.yaml" "s|^core: .*|core: $ref|"
printf 'update-core: core/ is at %s (%s); instance.yaml records it.\n' "$ref" "$(git -C "$CORE" rev-parse --short HEAD)"
```

If `guard-update` needs more than a clean detached clone with an `origin` remote (read `assert_core_movable` in `scripts/core-contrib.sh`), extend `fresh_repo` in the test to provide it; do not weaken the guard.

- [ ] **Step 3: Run the test**

Run: `bash scripts/update-core.test.sh`
Expected: 8 `ok` lines, `all cases passed`.

- [ ] **Step 4: Wire the Makefile**

Replace the `update-core` target (the recipe with `guard-update` and `checkout -q --detach $(if $(REF),$(REF),origin/main)`) with:

```make
update-core: ## Move core/ to a core release tag and record it in instance.yaml (REF=<tag>)
	@bash scripts/update-core.sh "$(REF)"
	@$(MAKE) config
	@$(MAKE) config-check
	@$(MAKE) check-instance
	@echo "run 'make check' before committing the bump"
```

Add `@bash scripts/update-core.test.sh` to the `test-scripts` recipe, after `@bash scripts/new-unit.test.sh`.

- [ ] **Step 5: Update docs**

`README.md`: `make update-core REF=<ref>` → `make update-core REF=<tag>`, function "Move the core pin to a core release tag." In `docs/*.md`, every `make update-core` usage that relies on the old default (fast-forward to `origin/main`) or on `REF=<sha|branch>` now names a tag. Run `bash scripts/check-docs.sh`.

- [ ] **Step 6: Run the suites and commit**

Run: `make test-scripts && bash scripts/check-docs.sh`

```bash
git add scripts/update-core.sh scripts/update-core.test.sh Makefile README.md docs
git commit -m "feat(update-core): pin core by release tag and record it in instance.yaml"
```

### Task 4: `instance.mk` (T4)

**Files:**
- Modify: `Makefile` (end of file: `-include instance.mk`; `test-scripts`)
- Create: `scripts/check-instance-mk.sh`, `scripts/check-instance-mk.test.sh`

**Interfaces:**
- Produces: `bash scripts/check-instance-mk.sh` exits 0 when there is no `instance.mk` or it only adds targets; exits 1 and names the target when it redefines one. Task 5 calls it from `make check-template`.

- [ ] **Step 1: Write the failing test `scripts/check-instance-mk.test.sh`**

```bash
#!/usr/bin/env bash
# check-instance-mk.test.sh — instance.mk may add targets and never redefine one.
#
# Usage: bash scripts/check-instance-mk.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILURES=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }
ok()   { printf 'ok: %s\n' "$*"; }

fresh_repo() {
  local repo
  repo="$(mktemp -d "$TMP/repo.XXXXXX")"
  cp "$ROOT/Makefile" "$repo/Makefile"
  cp -R "$SCRIPT_DIR" "$repo/scripts"
  printf '%s' "$repo"
}

repo="$(fresh_repo)"
if bash "$repo/scripts/check-instance-mk.sh" >/dev/null 2>&1; then ok "passes without instance.mk"; else fail "passes without instance.mk"; fi

repo="$(fresh_repo)"
printf 'acme-lab: ## A target only this instance needs\n\t@echo lab\n' > "$repo/instance.mk"
if bash "$repo/scripts/check-instance-mk.sh" >/dev/null 2>&1; then ok "passes when instance.mk adds a target"; else fail "passes when instance.mk adds a target"; fi
if make -C "$repo" -s acme-lab 2>/dev/null | grep -qx lab; then ok "the added target runs"; else fail "the added target runs"; fi

repo="$(fresh_repo)"
printf 'check:\n\t@echo skipped\n' > "$repo/instance.mk"
if out="$(bash "$repo/scripts/check-instance-mk.sh" 2>&1)"; then
  fail "refuses a redefined check target"
elif printf '%s' "$out" | grep -q "check"; then
  ok "refuses a redefined check target and names it"
else
  fail "refuses a redefined check target and names it: $out"
fi

if [ "$FAILURES" -gt 0 ]; then printf '\n%s case(s) failed\n' "$FAILURES" >&2; exit 1; fi
printf '\nall cases passed\n'
```

Run: `bash scripts/check-instance-mk.test.sh; echo rc=$?` — Expected: FAIL (script missing), `rc=1`.

- [ ] **Step 2: Include `instance.mk`** — append to the end of `Makefile`:

```make

# ──────────────────────────── instance.mk ─────────────────────────────

## Targets only this instance needs. instance.mk is instance-owned and
## optional. It may add targets; it must not redefine a template target
## (make check-template refuses that).
-include instance.mk
```

- [ ] **Step 3: Implement `scripts/check-instance-mk.sh`**

```bash
#!/usr/bin/env bash
# check-instance-mk.sh — instance.mk adds targets; it never redefines one.
#
# make notices a second recipe for a target, warns, and then uses the LAST one.
# An instance.mk that redefined `check` would therefore replace the template's
# gate without any failure. This script turns the warning into a refusal.
# GNU Make 3.81 (macOS) says "overriding commands"; Make 4.x says
# "overriding recipe". Both are matched.
#
# Usage: bash scripts/check-instance-mk.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ ! -f "$ROOT/instance.mk" ]; then
  echo "check-instance-mk: no instance.mk"
  exit 0
fi

warnings="$(make -C "$ROOT" -n help 2>&1 >/dev/null | grep -E 'warning: (overriding|ignoring old) (recipe|commands) for target' || true)"
if [ -n "$warnings" ]; then
  printf 'check-instance-mk: instance.mk redefines a template target:\n' >&2
  printf '%s\n' "$warnings" | grep 'overriding' | sed 's/^/  /' >&2
  printf 'Give the target another name in instance.mk, or change the template.\n' >&2
  exit 1
fi
echo "check-instance-mk: instance.mk adds targets only"
```

- [ ] **Step 4: Run the test**

Run: `bash scripts/check-instance-mk.test.sh`
Expected: 4 `ok` lines, `all cases passed`.

- [ ] **Step 5: Add to `test-scripts` and commit**

Add `@bash scripts/check-instance-mk.test.sh` to `test-scripts`. Run `make test-scripts`.

```bash
git add Makefile scripts/check-instance-mk.sh scripts/check-instance-mk.test.sh
git commit -m "feat: instance.mk for instance-only targets, refused when it redefines one"
```

### Task 5: Drift check and template sync (T6)

**Files:**
- Create: `.template-owned`, `scripts/check-template.sh`, `scripts/check-template.test.sh`, `scripts/template-sync.sh`, `scripts/template-sync.test.sh`
- Modify: `Makefile` (targets `check-template`, `template-sync`; `check` prerequisites; `.PHONY`; `test-scripts`)
- Modify: `.github/workflows/ci.yml`, `.github/workflows/full-check.yml` (one step each, after `instance.yaml is valid`)

**Interfaces:**
- Consumes: `scripts/check-instance-mk.sh` (Task 4).
- Produces: `.template-version` format — one line, a 40-character commit id. `bash scripts/check-template.sh` exits 0 in the template (no `.template-version`) and when template-owned paths equal the recorded commit; exits 1 otherwise and lists the paths. `bash scripts/template-sync.sh` merges `<TEMPLATE_REMOTE:-template>/<TEMPLATE_BRANCH:-main>` and records the merged commit.

- [ ] **Step 1: Create `.template-owned`**

```
# Paths the template owns (design Section 6). An instance never edits them;
# changes come from margince-template through `make template-sync`.
# One git pathspec per line. scripts/check-template.sh reads this file from the
# template commit named in .template-version, not from the working tree.
Makefile
scripts/
.github/workflows/
.githooks/
.gitleaks.toml
.gitignore
.template-owned
AGENTS.md
CLAUDE.md
:(glob)docs/*.md
```

`:(glob)` limits `*` to one path segment, so `docs/client/` and `docs/superpowers/` stay instance-owned.

- [ ] **Step 2: Write the failing test `scripts/check-template.test.sh`**

```bash
#!/usr/bin/env bash
# check-template.test.sh — an instance's template-owned paths match its template commit.
#
# Usage: bash scripts/check-template.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

export GIT_AUTHOR_NAME="Test Dev"     GIT_AUTHOR_EMAIL="dev@example.test"
export GIT_COMMITTER_NAME="Test Dev"  GIT_COMMITTER_EMAIL="dev@example.test"
export GIT_CONFIG_NOSYSTEM=1

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILURES=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }
ok()   { printf 'ok: %s\n' "$*"; }

# A template with the real check script and ownership list.
TPL="$TMP/template"
git init -q -b main "$TPL"
mkdir -p "$TPL/scripts" "$TPL/docs/client"
cp "$ROOT/.template-owned" "$TPL/.template-owned"
cp "$SCRIPT_DIR/check-template.sh" "$SCRIPT_DIR/check-instance-mk.sh" "$TPL/scripts/"
printf 'help:\n\t@echo help\n' > "$TPL/Makefile"
printf 'guide\n' > "$TPL/docs/guide.md"
printf 'name: margince-default\n' > "$TPL/instance.yaml"
git -C "$TPL" add -A && git -C "$TPL" commit -q -m template
TPL_SHA="$(git -C "$TPL" rev-parse HEAD)"

fresh_instance() {
  local inst
  inst="$(mktemp -d "$TMP/instance.XXXXXX")"
  rmdir "$inst"
  git clone -q "$TPL" "$inst"
  printf '%s\n' "$TPL_SHA" > "$inst/.template-version"
  git -C "$inst" add .template-version && git -C "$inst" commit -q -m "record template"
  printf '%s' "$inst"
}

check() { bash "$1/scripts/check-template.sh" >/dev/null 2>&1; }

# --- the template itself ---
if check "$TPL"; then ok "the template itself passes"; else fail "the template itself passes"; fi

# --- clean instance, and instance-owned edits ---
inst="$(fresh_instance)"
if check "$inst"; then ok "an unchanged instance passes"; else fail "an unchanged instance passes"; fi
printf 'name: acme\n' > "$inst/instance.yaml"; printf 'notes\n' > "$inst/docs/client/notes.md"
if check "$inst"; then ok "instance-owned edits pass"; else fail "instance-owned edits pass"; fi

# --- template-owned edits fail ---
inst="$(fresh_instance)"; printf 'x\n' >> "$inst/Makefile"
if check "$inst"; then fail "an uncommitted Makefile edit fails"; else ok "an uncommitted Makefile edit fails"; fi

inst="$(fresh_instance)"; printf 'x\n' >> "$inst/docs/guide.md"; git -C "$inst" commit -qam edit
if check "$inst"; then fail "a committed docs edit fails"; else ok "a committed docs edit fails"; fi

inst="$(fresh_instance)"; printf 'x\n' > "$inst/scripts/extra.sh"
if check "$inst"; then fail "an untracked file under scripts/ fails"; else ok "an untracked file under scripts/ fails"; fi

inst="$(fresh_instance)"; printf 'x\n' > "$inst/scripts/extra.sh"; git -C "$inst" add -A; git -C "$inst" commit -qm add
if check "$inst"; then fail "a committed new file under scripts/ fails"; else ok "a committed new file under scripts/ fails"; fi

inst="$(fresh_instance)"
grep -v '^Makefile$' "$inst/.template-owned" > "$inst/o" && mv "$inst/o" "$inst/.template-owned"
printf 'x\n' >> "$inst/Makefile"
if check "$inst"; then fail "shrinking .template-owned does not hide an edit"; else ok "shrinking .template-owned does not hide an edit"; fi

inst="$(fresh_instance)"; printf 'not-a-sha\n' > "$inst/.template-version"
if check "$inst"; then fail "a malformed .template-version fails"; else ok "a malformed .template-version fails"; fi

inst="$(fresh_instance)"; printf '%s\n' "0123456789012345678901234567890123456789" > "$inst/.template-version"
if check "$inst"; then fail "an unknown template commit fails"; else ok "an unknown template commit fails"; fi

if [ "$FAILURES" -gt 0 ]; then printf '\n%s case(s) failed\n' "$FAILURES" >&2; exit 1; fi
printf '\nall cases passed\n'
```

Run: `bash scripts/check-template.test.sh; echo rc=$?` — Expected: FAIL (script missing), `rc=1`.

- [ ] **Step 3: Implement `scripts/check-template.sh`**

```bash
#!/usr/bin/env bash
# check-template.sh — template-owned paths are exactly what the template shipped.
#
# .template-version names the template commit this instance last merged. Every
# path listed in .template-owned must be identical to that commit: no edits, no
# added files. A tooling change is made in margince-template and merged back, so
# every instance gets it (design Section 6.1). The list is read from the
# template commit, so an instance cannot remove a path from it.
#
# The template has no .template-version: it is the source, and there is nothing
# to compare it with.
#
# Usage: bash scripts/check-template.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [ ! -f .template-version ]; then
  echo "check-template: no .template-version — this is the template; nothing to compare"
  exit 0
fi

want="$(tr -d '[:space:]' < .template-version)"
if ! printf '%s' "$want" | grep -Eq '^[0-9a-f]{40}$'; then
  echo "check-template: .template-version must hold one 40-character commit id, found '$want'" >&2
  exit 1
fi

# The commit is in this repository's history because the instance merged it. A
# shallow CI checkout may lack it, so fetch exactly that commit from origin.
if ! git cat-file -e "$want^{commit}" 2>/dev/null; then
  git fetch --quiet --depth=1 origin "$want" 2>/dev/null || true
fi
if ! git cat-file -e "$want^{commit}" 2>/dev/null; then
  echo "check-template: template commit $want is not in this repository; run make template-sync" >&2
  exit 1
fi

paths=()
while IFS= read -r line; do
  case "$line" in ''|'#'*) continue ;; esac
  paths+=("$line")
done < <(git show "$want:.template-owned")

changed="$(git diff --name-only "$want" -- "${paths[@]}")"
added="$(git ls-files --others --exclude-standard -- "${paths[@]}")"
if [ -n "$changed$added" ]; then
  echo "check-template: template-owned paths differ from template commit ${want:0:12}:" >&2
  printf '%s\n' $changed $added | sort -u | sed 's/^/  /' >&2
  echo "Make the change in margince-template, then run make template-sync here." >&2
  exit 1
fi
echo "check-template: template-owned paths match template commit ${want:0:12}"
```

- [ ] **Step 4: Run the test**

Run: `bash scripts/check-template.test.sh`
Expected: 10 `ok` lines, `all cases passed`.

- [ ] **Step 5: Write the failing test `scripts/template-sync.test.sh`**

```bash
#!/usr/bin/env bash
# template-sync.test.sh — merge the template into an instance and record the commit.
#
# Usage: bash scripts/template-sync.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

export GIT_AUTHOR_NAME="Test Dev"     GIT_AUTHOR_EMAIL="dev@example.test"
export GIT_COMMITTER_NAME="Test Dev"  GIT_COMMITTER_EMAIL="dev@example.test"
export GIT_CONFIG_NOSYSTEM=1

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILURES=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }
ok()   { printf 'ok: %s\n' "$*"; }

TPL="$TMP/template"
git init -q -b main "$TPL"
mkdir -p "$TPL/scripts"
cp "$ROOT/.template-owned" "$TPL/.template-owned"
cp "$SCRIPT_DIR/check-template.sh" "$SCRIPT_DIR/check-instance-mk.sh" "$SCRIPT_DIR/template-sync.sh" "$SCRIPT_DIR/lib.sh" "$TPL/scripts/"
printf 'help:\n\t@echo help\n' > "$TPL/Makefile"
git -C "$TPL" add -A && git -C "$TPL" commit -q -m one
ONE="$(git -C "$TPL" rev-parse HEAD)"

INST="$TMP/instance"
git clone -q -o template "$TPL" "$INST"
printf '%s\n' "$ONE" > "$INST/.template-version"
printf 'name: acme\n' > "$INST/instance.yaml"
git -C "$INST" add -A && git -C "$INST" commit -q -m "create instance"

printf '# newer\n' >> "$TPL/scripts/lib.sh"
git -C "$TPL" commit -qam two
TWO="$(git -C "$TPL" rev-parse HEAD)"

if out="$(cd "$INST" && bash scripts/template-sync.sh 2>&1)"; then ok "syncs a newer template"; else fail "syncs a newer template: $out"; fi
if [ "$(tr -d '[:space:]' < "$INST/.template-version")" = "$TWO" ]; then ok "records the merged commit"; else fail "records the merged commit"; fi
if grep -q '# newer' "$INST/scripts/lib.sh"; then ok "brings the template change"; else fail "brings the template change"; fi
if grep -qx 'name: acme' "$INST/instance.yaml"; then ok "keeps instance-owned content"; else fail "keeps instance-owned content"; fi
if bash "$INST/scripts/check-template.sh" >/dev/null 2>&1; then ok "check-template passes after the sync"; else fail "check-template passes after the sync"; fi

if (cd "$INST" && bash scripts/template-sync.sh >/dev/null 2>&1); then ok "a second sync with nothing new succeeds"; else fail "a second sync with nothing new succeeds"; fi

printf 'dirty\n' > "$INST/instance.yaml"
if (cd "$INST" && bash scripts/template-sync.sh >/dev/null 2>&1); then fail "refuses a dirty tree"; else ok "refuses a dirty tree"; fi
git -C "$INST" checkout -q instance.yaml

git -C "$INST" remote rename template upstream-template
if (cd "$INST" && bash scripts/template-sync.sh >/dev/null 2>&1); then fail "refuses without a template remote"; else ok "refuses without a template remote"; fi

if (cd "$TPL" && bash scripts/template-sync.sh >/dev/null 2>&1); then fail "refuses to run in the template"; else ok "refuses to run in the template"; fi

if [ "$FAILURES" -gt 0 ]; then printf '\n%s case(s) failed\n' "$FAILURES" >&2; exit 1; fi
printf '\nall cases passed\n'
```

Run: `bash scripts/template-sync.test.sh; echo rc=$?` — Expected: FAIL (script missing), `rc=1`.

- [ ] **Step 6: Implement `scripts/template-sync.sh`**

```bash
#!/usr/bin/env bash
# template-sync.sh — merge margince-template into this instance and record it.
#
# Template changes reach an instance by merge (design Section 4). After the
# merge, .template-version names the merged template commit, which is what
# make check-template compares the template-owned paths with.
#
# Usage: bash scripts/template-sync.sh   (or: make template-sync)
#   TEMPLATE_REMOTE (default template), TEMPLATE_BRANCH (default main)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$ROOT"

remote="${TEMPLATE_REMOTE:-template}"
branch="${TEMPLATE_BRANCH:-main}"

[ -f .template-version ] || die "template-sync: no .template-version — run this in an instance, not in the template"
git remote get-url "$remote" >/dev/null 2>&1 \
  || die "template-sync: no git remote '$remote'. Add it: git remote add $remote git@github.com:gradionhq/margince-template.git"
[ -z "$(git status --porcelain)" ] || die "template-sync: commit or discard local changes first"

git fetch --quiet "$remote" "$branch"
target="$(git rev-parse FETCH_HEAD)"

if ! git merge --no-edit "$target"; then
  die "template-sync: the merge has conflicts. For template-owned paths keep the template version (git checkout --theirs -- <path>), finish the merge with git commit, then run make template-sync again"
fi

printf '%s\n' "$target" > .template-version
git add .template-version
if git diff --cached --quiet; then
  echo "template-sync: already at template commit ${target:0:12}"
else
  git commit --quiet -m "chore: record template commit ${target:0:12}"
  echo "template-sync: merged and recorded template commit ${target:0:12}"
fi
```

- [ ] **Step 7: Run the test**

Run: `bash scripts/template-sync.test.sh`
Expected: 9 `ok` lines, `all cases passed`.

- [ ] **Step 8: Wire the Makefile and CI**

Add in the gates section:

```make
check-template: ## Template-owned paths match the template commit this instance merged; instance.mk only adds targets
	@bash scripts/check-instance-mk.sh
	@bash scripts/check-template.sh

template-sync: ## Merge margince-template's main into this instance and record it in .template-version
	@bash scripts/template-sync.sh
```

- `.PHONY`: add `check-template template-sync`.
- `check:` prerequisites: `toolcheck check-instance check-template test-scripts test-secret-scan secret-scan`.
- `test-scripts`: add `@bash scripts/check-template.test.sh` and `@bash scripts/template-sync.test.sh`.
- `.github/workflows/ci.yml` and `.github/workflows/full-check.yml`: directly after the `instance.yaml is valid` step, add:

```yaml
      - name: Template-owned paths are unchanged
        run: make check-template
```

- [ ] **Step 9: Run and commit**

Run: `make check-template && make test-scripts`
Expected: `check-template: no .template-version — this is the template; nothing to compare`; all suites pass.

```bash
git add .template-owned scripts Makefile .github/workflows
git commit -m "feat: drift check for template-owned paths, and make template-sync"
```

### Task 6: `make new-instance` (T11)

**Files:**
- Create: `scripts/new-instance.sh`, `scripts/new-instance.test.sh`
- Modify: `Makefile` (target `new-instance`; `.PHONY`; `test-scripts`)

**Interfaces:**
- Consumes: `scripts/cli` (`check`), `lib.sh` (`die`, `ROOT`, `CORE`), `.template-version` format (Task 5).
- Produces: `NAME=<n> DISPLAY_NAME=<d> [VENDOR=<v>] [DIR=<dir>] [PUSH=1 OWNER=<org>] bash scripts/new-instance.sh`. Creates `<DIR>` (default `<template parent>/margince-<NAME>`) as a git repository on `main` with remote `template`, no `origin`, `instance.yaml` (flavor `<VENDOR>/margince`, VENDOR default NAME, core copied from the template), `.template-version` = template HEAD, an instance `README.md`, and `core/` checked out. With `PUSH=1`, runs `gh repo create <OWNER>/margince-<NAME> --private --source <DIR> --remote origin --push` (OWNER default `gradionhq`).

- [ ] **Step 1: Write the failing test `scripts/new-instance.test.sh`**

```bash
#!/usr/bin/env bash
# new-instance.test.sh — create instances from a throwaway template.
#
# Never pushes: PUSH is unset in every case.
#
# Usage: bash scripts/new-instance.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

export GIT_AUTHOR_NAME="Test Dev"     GIT_AUTHOR_EMAIL="dev@example.test"
export GIT_COMMITTER_NAME="Test Dev"  GIT_COMMITTER_EMAIL="dev@example.test"
export GIT_CONFIG_NOSYSTEM=1
# Local submodule clones use the file transport, which git refuses by default.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always
unset PUSH OWNER

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILURES=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }
ok()   { printf 'ok: %s\n' "$*"; }

# A core with one release tag.
CORE_UP="$TMP/core-upstream"
git init -q -b main "$CORE_UP"
printf 'go 1.26.6\n' > "$CORE_UP/go.work"
git -C "$CORE_UP" add -A && git -C "$CORE_UP" commit -q -m core && git -C "$CORE_UP" tag v0.0.2

# A template: this repository's scripts and ownership list, core as a submodule.
TPL="$TMP/template"
git init -q -b main "$TPL"
cp -R "$SCRIPT_DIR" "$TPL/scripts"
cp "$ROOT/.template-owned" "$TPL/.template-owned"
printf 'help:\n\t@echo help\n' > "$TPL/Makefile"
printf '# margince-template\n' > "$TPL/README.md"
printf 'name: margince-default\ndisplay_name: Margince Default\ncore: v0.0.2\nflavor: margince/margince\n' > "$TPL/instance.yaml"
git -C "$TPL" submodule add -q "$CORE_UP" core
git -C "$TPL/core" checkout -q --detach v0.0.2
git -C "$TPL" add -A && git -C "$TPL" commit -q -m template
git -C "$TPL" remote add origin "$TMP/template-origin.git"
TPL_SHA="$(git -C "$TPL" rev-parse HEAD)"

create() { (cd "$TPL" && env "$@" bash scripts/new-instance.sh); }

# --- a valid instance ---
DIR="$TMP/margince-acme"
if out="$(create NAME=acme DISPLAY_NAME=Acme DIR="$DIR" 2>&1)"; then ok "creates an instance"; else fail "creates an instance: $out"; fi
if [ "$(git -C "$DIR" rev-parse --abbrev-ref HEAD)" = "main" ]; then ok "the instance is on main"; else fail "the instance is on main"; fi
if [ "$(git -C "$DIR" remote get-url template)" = "$TMP/template-origin.git" ]; then ok "the template remote is the template's origin"; else fail "the template remote is the template's origin"; fi
if git -C "$DIR" remote get-url origin >/dev/null 2>&1; then fail "has no origin before a push"; else ok "has no origin before a push"; fi
if [ "$(tr -d '[:space:]' < "$DIR/.template-version")" = "$TPL_SHA" ]; then ok "records the template commit"; else fail "records the template commit"; fi
if grep -qx 'flavor: acme/margince' "$DIR/instance.yaml" && grep -qx 'core: v0.0.2' "$DIR/instance.yaml" && grep -qx 'display_name: Acme' "$DIR/instance.yaml"; then ok "writes instance.yaml"; else fail "writes instance.yaml"; fi
if [ "$(git -C "$DIR/core" describe --tags --exact-match 2>/dev/null)" = "v0.0.2" ]; then ok "checks out core at the pinned tag"; else fail "checks out core at the pinned tag"; fi
if [ -z "$(git -C "$DIR" status --porcelain)" ]; then ok "commits everything"; else fail "commits everything"; fi
if bash "$DIR/scripts/check-template.sh" >/dev/null 2>&1; then ok "the new instance passes check-template"; else fail "the new instance passes check-template"; fi
if (cd "$DIR/scripts/cli" && GOWORK=off go run . check -file "$DIR/instance.yaml" -core "$DIR/core" >/dev/null 2>&1); then ok "the new instance passes check-instance"; else fail "the new instance passes check-instance"; fi

# --- VENDOR sets the flavor ---
DIR2="$TMP/margince-acme-eu"
create NAME=acme-eu DISPLAY_NAME="Acme EU" VENDOR=acme DIR="$DIR2" >/dev/null 2>&1 || true
if grep -qx 'flavor: acme/margince' "$DIR2/instance.yaml" 2>/dev/null; then ok "VENDOR sets the flavor"; else fail "VENDOR sets the flavor"; fi

# --- refusals create nothing ---
expect_refused() {
  local label="$1" dir="$2"; shift 2
  if create "$@" DIR="$dir" >/dev/null 2>&1; then fail "$label — it succeeded"
  elif [ -e "$dir" ] && [ "$dir" != "$DIR" ]; then fail "$label — it created $dir"
  else ok "$label"; fi
}
expect_refused "refuses a missing name" "$TMP/x1" DISPLAY_NAME=X
expect_refused "refuses an invalid name" "$TMP/x2" NAME=Acme DISPLAY_NAME=X
expect_refused "refuses a missing display name" "$TMP/x3" NAME=acme2
expect_refused "refuses an existing directory" "$DIR" NAME=acme DISPLAY_NAME=Acme
if (cd "$DIR" && NAME=other DISPLAY_NAME=O DIR="$TMP/x4" bash scripts/new-instance.sh >/dev/null 2>&1); then
  fail "refuses to run inside an instance"
elif [ -e "$TMP/x4" ]; then fail "refuses to run inside an instance — it created a directory"
else ok "refuses to run inside an instance"; fi

if [ "$FAILURES" -gt 0 ]; then printf '\n%s case(s) failed\n' "$FAILURES" >&2; exit 1; fi
printf '\nall cases passed\n'
```

Run: `bash scripts/new-instance.test.sh; echo rc=$?` — Expected: FAIL (script missing), `rc=1`.

- [ ] **Step 2: Implement `scripts/new-instance.sh`**

```bash
#!/usr/bin/env bash
# new-instance.sh — create a client instance repository from this template.
#
# The instance is a new repository whose history starts from the template's, so
# template changes merge in normally (make template-sync). GitHub does not allow
# a fork into the organization that owns the template, so the instance is a
# plain repository with a `template` remote instead.
#
# Everything is validated BEFORE anything is created. Nothing is pushed unless
# PUSH=1 is given.
#
# Usage:
#   NAME=acme DISPLAY_NAME="Acme" [VENDOR=acme] [DIR=../margince-acme] \
#     [PUSH=1 OWNER=gradionhq] bash scripts/new-instance.sh
#   (or: make new-instance NAME=… DISPLAY_NAME=… …)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$ROOT"

name="${NAME:-}"
display="${DISPLAY_NAME:-}"
vendor="${VENDOR:-$name}"
dir="${DIR:-$(dirname "$ROOT")/margince-$name}"
owner="${OWNER:-gradionhq}"

[ ! -f .template-version ] || die "new-instance: this is an instance; run make new-instance in margince-template"
[ -n "$name" ] || die "new-instance: pass NAME=<name>, e.g. make new-instance NAME=acme DISPLAY_NAME=Acme"
[ -n "$display" ] || die "new-instance: pass DISPLAY_NAME=<text>, e.g. DISPLAY_NAME=\"Acme\""
[ ! -e "$dir" ] || die "new-instance: $dir already exists"
[ -z "$(git status --porcelain)" ] || die "new-instance: commit or discard the template's local changes first"

core_tag="$(instance_get core)"
template_sha="$(git rev-parse HEAD)"
template_url="$(git remote get-url origin 2>/dev/null || printf '%s' "$ROOT")"

# Validate the new instance.yaml with the same checker make check uses, before
# anything exists on disk.
candidate="$(mktemp)"
trap 'rm -f "$candidate"' EXIT
printf 'name: %s\ndisplay_name: %s\ncore: %s\nflavor: %s/margince\n' "$name" "$display" "$core_tag" "$vendor" > "$candidate"
(cd "$ROOT/scripts/cli" && GOWORK=off go run . check -file "$candidate" -core "$CORE") \
  || die "new-instance: the instance.yaml above would be invalid; fix NAME, DISPLAY_NAME or VENDOR"

git clone --quiet --no-checkout "$ROOT" "$dir"
git -C "$dir" remote remove origin
git -C "$dir" remote add template "$template_url"
git -C "$dir" checkout --quiet -B main "$template_sha"
git -C "$dir" submodule update --quiet --init --reference "$CORE" core

cp "$candidate" "$dir/instance.yaml"
printf '%s\n' "$template_sha" > "$dir/.template-version"
cat > "$dir/README.md" <<EOF
# $display

The $display instance of Margince, created from margince-template at
commit ${template_sha:0:12}.

Start with \`make install\`, then \`make dev\`. Guides are in docs/README.md.
Template changes arrive with \`make template-sync\`.
EOF

git -C "$dir" add instance.yaml .template-version README.md
git -C "$dir" commit --quiet -m "chore: create instance $name from margince-template ${template_sha:0:12}"
echo "new-instance: created $dir (flavor $vendor/margince, core $core_tag)"

if [ "${PUSH:-}" = "1" ]; then
  command -v gh >/dev/null || die "new-instance: PUSH=1 needs the GitHub CLI (gh)"
  gh repo create "$owner/margince-$name" --private --source "$dir" --remote origin --push
  echo "new-instance: pushed to $owner/margince-$name"
else
  echo
  echo "next:"
  echo "  cd $dir && make install && make dev"
  echo "  create the GitHub repository with PUSH=1 OWNER=$owner, or push it yourself"
fi
```

- [ ] **Step 3: Run the test**

Run: `bash scripts/new-instance.test.sh`
Expected: 16 `ok` lines, `all cases passed`.

- [ ] **Step 4: Wire the Makefile**

```make
new-instance: ## Create a client instance repository from this template (NAME=, DISPLAY_NAME=, VENDOR=, DIR=, PUSH=1 OWNER=)
	@NAME="$(NAME)" DISPLAY_NAME="$(DISPLAY_NAME)" VENDOR="$(VENDOR)" DIR="$(DIR)" \
		PUSH="$(PUSH)" OWNER="$(OWNER)" bash scripts/new-instance.sh
```

Add `new-instance` to `.PHONY`, and `@bash scripts/new-instance.test.sh` to `test-scripts`.

- [ ] **Step 5: Run and commit**

Run: `make test-scripts`

```bash
git add scripts/new-instance.sh scripts/new-instance.test.sh Makefile
git commit -m "feat: make new-instance creates a client instance from the template"
```

### Task 7: Documentation and verification

**Files:**
- Create: `docs/create-an-instance.md`
- Modify: `README.md`, `docs/README.md`, `AGENTS.md` (status line), spec Sections 6.1, 6.2, 9, 10.3

- [ ] **Step 1: Write `docs/create-an-instance.md`**

Sections, in technical standard English: 1. Prerequisites (`make install` in the template; `gh` for `PUSH=1`). 2. Create (`make new-instance NAME=acme DISPLAY_NAME="Acme"`, what each variable does, `PUSH=1 OWNER=`). 3. What the instance contains (instance-owned vs template-owned paths; `.template-owned`, `.template-version`). 4. Daily work (`make dev`, `make new-unit`, `make check`). 5. Receiving template changes (`make template-sync`, conflict rule). 6. Upgrading core (`make update-core REF=<tag>`). 7. Instance-only targets (`instance.mk`). 8. Image names (`make package`, `REGISTRY=`, `<registry>/<flavor>/api`).

- [ ] **Step 2: Update `README.md` and `docs/README.md`**

README commands table: add `make new-instance NAME=<n> DISPLAY_NAME=<d>`, `make template-sync`, `make check-template`; `make update-core REF=<tag>`. docs/README guides table: add "Create an instance". Remove "create a new instance" and "upgrade core" and "merge template changes" from the "Planned" line.

- [ ] **Step 3: Update the spec**

- Section 6.1: `.template-owned` (list, read from the template commit), `.template-version` (one commit id), untracked and added files count as drift, the template itself has no `.template-version`, `make template-sync`.
- Section 6.2: image namespace is `<registry>/<flavor>` and core's bake appends `/api`, `/web`, `/worker` (replace `<registry>/<vendor>/margince-api`).
- Section 9: add `make new-instance`, `make template-sync`, `make check-template` rows as existing; `make update-core REF=<tag>` records the tag.
- Section 10.3: image names `<registry>/<flavor>/api`, `/web`, `/worker`.

- [ ] **Step 4: Verify**

```bash
make test-scripts
make test-cli
make check-instance
make check-template
bash scripts/check-docs.sh
make new-instance NAME=acme-demo DISPLAY_NAME="Acme Demo" DIR=/tmp/margince-acme-demo
cd /tmp/margince-acme-demo && make check-instance && make check-template && make new-unit NAME=acme-sync && make compose && git add extensions/acme-sync && make u NAME=acme-sync
cd - && rm -rf /tmp/margince-acme-demo
make check
```

Expected: each command exits 0. `make check` is the full gate (about 8 minutes). Record durations.

- [ ] **Step 5: Commit**

```bash
git add docs README.md AGENTS.md
git commit -m "docs: create an instance, template sync, and image names"
```
