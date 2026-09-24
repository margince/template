# Template Foundation Implementation Plan (T1, T2)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `margince-template` is a working instance without extensions ("Margince Default"): `make install`, `make dev`, `make new-unit`, and `make check` pass, and CI is green.

**Architecture:** The tooling is copied from `margince-automation-world` at `origin/main` (commit `644ee45`). Only files that depend on that instance's five extensions are changed. The template adds `instance.yaml` and a small Go CLI that validates it. Core is a submodule pinned to tag `v0.0.2`.

**Tech Stack:** GNU Make, Bash, Go 1.26.6, `gopkg.in/yaml.v3` v3.0.1 (already used by core), gitleaks (pinned by `scripts/gitleaks-pin.sh`), GitHub Actions.

**Spec:** [`docs/superpowers/specs/2026-09-24-client-instance-template-design.md`](../specs/2026-09-24-client-instance-template-design.md). Issues: [T1 #1](https://github.com/gradionhq/margince-template/issues/1), [T2 #2](https://github.com/gradionhq/margince-template/issues/2).

## Global Constraints

- Source commit for copied files: `gradionhq/margince-automation-world` `origin/main` = `644ee45`. The local `margince-gradion` directory is an older clone of the same repository.
- Core pin: tag `v0.0.2` (`4fb7b64b9`). Core at this tag has no `cli/craft`; craft is resolved by `core/scripts/craft-pin.sh`.
- The template contains no client code and no client names. Allowed exceptions: the repository names `gradionhq/margince-demo-database` and `gradionhq/margince-template`, and the SPDX header `SPDX-FileCopyrightText: 2026 Gradion` (core uses the same header in its own units).
- No file under `core/` is edited.
- Every documented `make <target>` must exist (`scripts/check-docs.sh` scans `README.md`, `CLAUDE.md`, `docs/*.md`).
- The Go CLI runs with `GOWORK=off`. The editor `go.work` that `scripts/gowork.sh` writes at the repository root does not list `scripts/cli`, so without `GOWORK=off` Go refuses to run it.
- Documentation uses technical standard English (see `AGENTS.md`).
- Commits use Conventional Commits and end with `Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>`.

## Findings from the Trial Import

A throwaway import into a scratch directory established the following. The tasks below fix each item.

| # | Finding | Fixed in |
|---|---|---|
| 1 | `scripts/lint.sh` runs craft from `core/cli/craft`, which does not exist at `v0.0.2`. | Task 1 |
| 2 | `scripts/lib.test.sh`: 3 cases assume units `zalo-oa` and `dispact-connector` exist under `extensions/`. | Task 2 |
| 3 | `scripts/secret-scan.test.sh` and `.gitleaks.toml` depend on `extensions/zalo-personal/zalocrypto.go`. | Task 3 |
| 4 | `scripts/new-unit.sh` copies `extensions/gradion`, which the template does not have. | Task 4 |
| 5 | `Makefile` contains the `zalo-lab` target and Gradion wording; `.gitignore` contains the `.zalolab/` rule. | Task 5 |
| 6 | The template `README.md` names `make trial`, `make release`, `make deploy`, which do not exist, so `check-docs` fails. | Task 5 |
| 7 | All other script suites pass unchanged with no extensions: toolcheck (3), core-contrib (70), preflight (16), check-manifests (12), build-info (20), desktop-kit (84), workflow-wiring (5), desktop-arch (11). `make install` passes. | — |
| 8 | `config/` is not tracked in `margince-automation-world`. `make config` generates it from core's examples. | Task 1 (not copied) |

## Review Focus

1. **A unit name that collides with an upstream unit** (for example `notes`). `new-unit` must refuse it and create nothing. Test in Task 4.
2. **`instance.yaml` with an unknown or misspelled key** (for example `flavour:`). Validation must fail and name the key, not silently ignore it. Test in Task 6.
3. **`core/` moved without updating `instance.yaml`**, or `core/` checked out at a commit with no tag. `make check` must fail and say which tag is expected. Test in Task 6.
4. **A path containing a space** in the staged-path rewrite. It must still be rewritten. Kept in Task 2.
5. **A widened secret-scan policy**. The secret-scan test must fail when the allowlist covers unit source. Mutation check in Task 3.

---

### Task 1: Import the tooling

**Files:**
- Create (copied from `margince-automation-world` `644ee45`): `.githooks/pre-push`, `.github/workflows/{ci,desktop-macos,desktop-windows,full-check,release}.yml`, `.gitignore`, `.gitleaks.toml`, `Makefile`, `scripts/**` (all files listed by `git ls-tree -r --name-only 644ee45 scripts`)
- Create: `.gitmodules`, `core` (submodule at `v0.0.2`), `extensions/.gitkeep`
- Modify: `scripts/lint.sh:66-67`

**Interfaces:**
- Produces: the full make target set of `margince-automation-world`; `scripts/lib.sh` variables `ROOT`, `CORE`, `SRC_EXT`; `source_units()`.

- [ ] **Step 1: Copy the files**

```bash
A=../margince-automation-world          # adjust to the local clone
git -C "$A" fetch origin
git -C "$A" archive 644ee45 -- .githooks .github .gitignore .gitleaks.toml Makefile scripts | tar -x
```

Do not copy: `extensions/`, `docs/` (Task 5), `README.md`, `CLAUDE.md`, `.gitmodules` (Step 2), `config/` (generated by `make config`).

- [ ] **Step 2: Add core at `v0.0.2`**

```bash
git submodule add https://github.com/margince/margince.git core
git -C core checkout v0.0.2
git config -f .gitmodules submodule.core.branch main
mkdir -p extensions && touch extensions/.gitkeep
```

Expected: `git -C core describe --tags --exact-match` prints `v0.0.2`.

Check `source_units()` ignores `.gitkeep`: it lists directories only (`find -type d`), so the file does not count as a unit.

- [ ] **Step 3: Point `lint.sh` at the pinned craft binary**

In `scripts/lint.sh`, replace:

```bash
if ! out="$(cd "$CORE/cli/craft" && "$GO_BIN" run . static --strict --root "$SRC_EXT" 2>&1)"; then
```

with:

```bash
# craft is a PINNED BINARY, not a module in the tree: core resolves it through
# scripts/craft-pin.sh, which downloads the version that script names and
# verifies its sha256. Run from $CORE because the script resolves its cache
# relative to core's own root; --root stays ours, so findings name
# extensions/<unit>/… rather than a staged copy.
craft_bin="$(cd "$CORE" && ./scripts/craft-pin.sh)"
if ! out="$("$craft_bin" static --strict --root "$SRC_EXT" 2>&1)"; then
```

- [ ] **Step 4: Verify the known state**

Run: `bash scripts/lib.test.sh; echo rc=$?`
Expected: `3 case(s) failed`, `rc=1` (finding 2, fixed in Task 2).

Run each of: `bash scripts/{toolcheck,core-contrib,preflight,check-manifests,build-info,desktop-kit,workflow-wiring,desktop-arch}.test.sh`
Expected: each exits 0.

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "chore: import instance tooling from margince-automation-world

Source: gradionhq/margince-automation-world 644ee45 (.githooks, .github,
.gitignore, .gitleaks.toml, Makefile, scripts). lint.sh uses core's pinned
craft binary (core v0.0.2 has no cli/craft). Core pinned at v0.0.2.

Co-Authored-By: Claude Opus 5.5 (1M context) <noreply@anthropic.com>"
```

### Task 2: Path-rewrite tests use synthetic units

**Files:**
- Modify: `scripts/lib.test.sh` (section `# --- rewrite_staged_paths ---`)

**Interfaces:**
- Consumes: `rewrite_staged_paths` and `SRC_EXT` from `scripts/lib.sh`. "Ours" is every directory under `$SRC_EXT`.

- [ ] **Step 1: Confirm the failure**

Run: `bash scripts/lib.test.sh 2>&1 | grep FAIL`
Expected: three lines: `rewrites an absolute staged path for one of our units`, `rewrites an absolute staged frontend path`, `survives a path containing a space`.

- [ ] **Step 2: Give the cases their own units**

Directly after the line `# --- rewrite_staged_paths ---`, insert:

```bash
#
# "Ours" is whatever directory exists under $SRC_EXT. The template ships with no
# units, so these cases point SRC_EXT at synthetic units and restore it after.
SAVED_SRC_EXT="$SRC_EXT"
SRC_EXT="$TMP/rewrite-src-ext"
mkdir -p "$SRC_EXT/acme-sync" "$SRC_EXT/acme-portal"
```

In the `expect_rewrite` calls of this section, replace unit names:
- `zalo-oa` → `acme-sync` (4 cases: absolute path, core-relative path, path with a space; both input and expected lines)
- `dispact-connector` → `acme-portal` (the frontend case)

Directly after the last case of the section (`survives a path containing a space`), insert:

```bash

SRC_EXT="$SAVED_SRC_EXT"
```

- [ ] **Step 3: Run the suite**

Run: `bash scripts/lib.test.sh; echo rc=$?`
Expected: no `FAIL`, `rc=0` (41 `ok` lines).

- [ ] **Step 4: Commit**

```bash
git add scripts/lib.test.sh
git commit -m "test(lib): the path-rewrite cases bring their own units"
```

### Task 3: Secret scan without client allowlists

**Files:**
- Modify: `.gitleaks.toml`
- Replace: `scripts/secret-scan.test.sh`

**Interfaces:**
- Consumes: `gitleaks_bin` from `scripts/gitleaks-pin.sh`.

- [ ] **Step 1: Confirm the failure**

Commit state first (the scan reads `git archive HEAD`). Run: `bash scripts/secret-scan.test.sh; echo rc=$?`
Expected: `FAIL: extensions/zalo-personal/zalocrypto.go is not in the export`, `rc=1`.

- [ ] **Step 2: Remove the client allowlist from `.gitleaks.toml`**

Delete everything from the line ``# `zcidKey` — the fixed key Zalo Web ships`` to the end of the file (the "Zalo Web's own published zcid key" allowlist).

Replace the comment paragraph above the test-fixture allowlist:

```toml
# Tests hold fabricated fixtures — stand-in tokens, demo ids, and deliberately
# malformed values. Their literals exist so the code under test can encode,
# decode or refuse them, so a fixture HAS to look like a credential for the test
# to mean anything.
```

In the header comment, replace the last three lines ("That is the property … over-broad.") with:

```toml
# With all three, the file stays scanned — for the other rules AND for the
# excused rule on every line the regex does not name. That is the property
# scripts/secret-scan.test.sh holds. Any new scoped exemption gets a planted case
# there. An allowlist nobody planted against is exactly the one that is
# over-broad.
```

Check: `grep -ci zalo .gitleaks.toml` prints `0`.

- [ ] **Step 3: Replace `scripts/secret-scan.test.sh`**

```bash
#!/usr/bin/env bash
# secret-scan.test.sh — prove the secret gate still CATCHES.
#
# A scan that finds nothing looks identical whether the tree is clean or the
# policy has been widened until it excuses everything. This test tells the two
# apart: it plants tokens into a copy of the tree and requires the scan to fail
# where the policy does not excuse them.
#
# Planted into a COPY of the tree, never the real one. The scan itself reads a
# `git archive HEAD` export, so a plant in the working tree would be invisible to
# it anyway. The copy is exported, planted into, and scanned directly.
#
# The template ships with no units, so every plant goes into a synthetic file
# under extensions/.
#
# Usage: bash scripts/secret-scan.test.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

# shellcheck source=scripts/gitleaks-pin.sh
. "$ROOT/scripts/gitleaks-pin.sh"
GITLEAKS="$(gitleaks_bin)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILURES=0

fail() { printf 'FAIL: %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }
ok()   { printf 'ok: %s\n' "$*"; }

# A fresh export per case: a plant must not be visible to the next one.
export_tree() {
  local dest="$1"
  mkdir -p "$dest"
  git archive HEAD | tar -x -C "$dest"
}

scan() {
  local dir="$1"
  "$GITLEAKS" dir "$dir" --config "$ROOT/.gitleaks.toml" --redact --no-banner >/dev/null 2>&1
}

# plant <tree> <relative path> <line> — append a line to a file in the copy.
plant() {
  local file="$1/$2"
  mkdir -p "$(dirname "$file")"
  printf '\n// planted by scripts/secret-scan.test.sh\n%s\n' "$3" >> "$file"
}

# A `generic-api-key` token, assembled rather than written whole so this file
# does not itself carry a 32-hex-looking literal.
PLANTED_TOKEN="var planted = apiKey = \"$(printf 'a1b2c3d4e5f6a7b8')$(printf 'c9d0e1f2a3b4c5d6')\""

# --- the tree as committed ---

t="$TMP/clean"; export_tree "$t"
if scan "$t"; then ok "the committed tree scans clean"; else
  fail "the committed tree scans clean — the gate is failing before any plant, so nothing below means anything"
fi

# --- a token in unit source is caught ---

t="$TMP/source"; export_tree "$t"
plant "$t" "extensions/acme/client.go" "$PLANTED_TOKEN"
if scan "$t"; then
  fail "a planted token in extensions/acme/client.go was not caught — the policy excuses unit source"
else
  ok "a planted token in unit source is caught"
fi

# --- the test-fixture exemption covers tests and nothing else ---

t="$TMP/fixture"; export_tree "$t"
plant "$t" "extensions/acme/client_test.go" "$PLANTED_TOKEN"
if scan "$t"; then ok "a fabricated token in a _test.go fixture is excused"; else
  fail "a token in a _test.go fixture was caught — the test-fixture allowlist stopped matching"
fi

t="$TMP/near-fixture"; export_tree "$t"
plant "$t" "extensions/acme/client_test_helpers.go" "$PLANTED_TOKEN"
if scan "$t"; then
  fail "a token in client_test_helpers.go was not caught — the test-fixture allowlist matches more than _test.go"
else
  ok "a file that only contains _test in its name is still scanned"
fi

if [ "$FAILURES" -gt 0 ]; then
  printf '\n%s case(s) failed — the policy is wider than intended. Narrow .gitleaks.toml; do not weaken this test.\n' "$FAILURES" >&2
  exit 1
fi
printf '\nall cases passed — the gate still catches\n'
```

- [ ] **Step 4: Run the suite**

Commit first (the test reads `HEAD`), then run: `bash scripts/secret-scan.test.sh`
Expected: 4 `ok` lines and `all cases passed — the gate still catches`.

- [ ] **Step 5: Mutation check (do not commit)**

In `.gitleaks.toml` change `'''_test\.go$''',` to `'''\.go$''',`, commit to a scratch branch, run the test.
Expected: 2 `FAIL` lines (unit source not caught; near-fixture not caught). Then discard the scratch branch.

- [ ] **Step 6: Commit**

```bash
git add .gitleaks.toml scripts/secret-scan.test.sh
git commit -m "test(secret-scan): plant into synthetic files; drop the client allowlist"
```

### Task 4: `new-unit` from a neutral skeleton

**Files:**
- Create: `scripts/unit-skeleton/go.mod.tmpl`, `scripts/unit-skeleton/unit.go.tmpl`, `scripts/unit-skeleton/unit_test.go.tmpl`
- Modify: `scripts/new-unit.sh`
- Create: `scripts/new-unit.test.sh`
- Modify: `Makefile` (`test-scripts` target)

**Interfaces:**
- Consumes: `die`, `rewrite_file_in_place`, `ROOT`, `CORE`, `SRC_EXT` from `scripts/lib.sh`.
- Produces: `bash scripts/new-unit.sh <name>` creates `extensions/<name>/{go.mod,<pkg>.go,<pkg>_test.go}` where `<pkg>` is `<name>` without hyphens. Placeholders in templates: `__NAME__`, `__PKG__`.

- [ ] **Step 1: Write the failing test `scripts/new-unit.test.sh`**

```bash
#!/usr/bin/env bash
# new-unit.test.sh — scaffold units into a throwaway copy of this repository.
#
# Each case gets a fresh copy: scripts/ beside an empty extensions/ and a core/
# git repository that tracks one upstream unit, extensions/notes.
#
# Usage: bash scripts/new-unit.test.sh
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

fresh_repo() {
  local repo
  repo="$(mktemp -d "$TMP/repo.XXXXXX")"
  mkdir -p "$repo/extensions" "$repo/core/extensions/notes"
  cp -R "$SCRIPT_DIR" "$repo/scripts"
  printf 'package notes\n' > "$repo/core/extensions/notes/notes.go"
  git -C "$repo/core" init -q
  git -C "$repo/core" add -A
  git -C "$repo/core" commit -q -m upstream
  printf '%s' "$repo"
}

# --- a valid name ---

repo="$(fresh_repo)"
if out="$(bash "$repo/scripts/new-unit.sh" acme-sync 2>&1)"; then
  ok "scaffolds a valid name"
else
  fail "scaffolds a valid name: $out"
fi
unit="$repo/extensions/acme-sync"
for f in go.mod acmesync.go acmesync_test.go; do
  if [ -f "$unit/$f" ]; then ok "creates $f"; else fail "creates $f"; fi
done
if grep -rqE '__NAME__|__PKG__' "$unit"; then fail "leaves no placeholder"; else ok "leaves no placeholder"; fi
if grep -q '^package acmesync$' "$unit/acmesync.go"; then ok "the package name drops the hyphen"; else fail "the package name drops the hyphen"; fi
if grep -q 'Name:        "acme-sync",' "$unit/acmesync.go"; then ok "declares the directory name"; else fail "declares the directory name"; fi
if grep -q '^module margince.instance/extensions/acme-sync$' "$unit/go.mod"; then ok "names the module after the unit"; else fail "names the module after the unit"; fi
if [ ! -e "$unit/manifest.generated.json" ]; then ok "writes no manifest"; else fail "writes no manifest"; fi

# --- refusals create nothing ---

expect_refused() {
  local label="$1"; shift
  local repo
  repo="$(fresh_repo)"
  if bash "$repo/scripts/new-unit.sh" "$@" >/dev/null 2>&1; then
    fail "$label — it succeeded"
  elif [ -n "$(ls -A "$repo/extensions")" ]; then
    fail "$label — it left a directory behind"
  else
    ok "$label"
  fi
}

expect_refused "refuses a missing name"
expect_refused "refuses an upper-case name" Acme
expect_refused "refuses a double hyphen" acme--sync
expect_refused "refuses a name over 32 characters" abcdefghijklmnopqrstuvwxyz0123456
expect_refused "refuses an upstream unit's name" notes

repo="$(fresh_repo)"
mkdir "$repo/extensions/acme"
if bash "$repo/scripts/new-unit.sh" acme >/dev/null 2>&1; then
  fail "refuses an existing unit"
else
  ok "refuses an existing unit"
fi

if [ "$FAILURES" -gt 0 ]; then
  printf '\n%s case(s) failed\n' "$FAILURES" >&2
  exit 1
fi
printf '\nall cases passed\n'
```

- [ ] **Step 2: Run it to verify it fails**

Run: `bash scripts/new-unit.test.sh; echo rc=$?`
Expected: `FAIL: scaffolds a valid name` (the script copies `extensions/gradion`, which does not exist), `rc=1`.

- [ ] **Step 3: Create the skeleton**

`scripts/unit-skeleton/go.mod.tmpl`:

```
// The __NAME__ unit. Its own Go module, as every stable-tier unit is.
//
// The module path is not fetchable and is not meant to be: an enabled
// extension resolves through the composed workspace that gen-composition
// writes (build/composition/go.work), never through a module proxy.
module margince.instance/extensions/__NAME__

go 1.26.6
```

`scripts/unit-skeleton/unit.go.tmpl`:

```go
// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: 2026 Gradion

// Package __PKG__ is the __NAME__ unit.
//
// It ships as identity only: a name and a version, no capabilities. The unit
// composes, reconciles at boot, appears in the boot inventory and gets its own
// route at #/ext/__NAME__, so the staging path from this repository into the
// composed binary is proven before any behaviour is added.
//
// Capabilities are fields on the returned declaration. See
// docs/adding-an-extension.md and core/docs/how-to/add-an-extension.md.
package __PKG__

import "github.com/margince/margince/backend/pkg/extension"

// New returns the unit's declaration: inert data, holding no handle into the
// core. The generated composition calls it, and only the boot reconciliation
// applies anything.
func New() extension.Extension {
	return extension.Extension{
		Name:        "__NAME__",
		Version:     "0.1.0",
		Description: "The __NAME__ unit. Identity only, with no capabilities.",
	}
}
```

`scripts/unit-skeleton/unit_test.go.tmpl`:

```go
// SPDX-License-Identifier: BUSL-1.1
// SPDX-FileCopyrightText: 2026 Gradion

package __PKG__

import "testing"

// The declaration is the unit's whole contract with the core: the name keys
// SQL identifiers and the #/ext/<name> route, and the version is what the boot
// inventory records.
func TestNewDeclaresTheUnit(t *testing.T) {
	e := New()

	if e.Name != "__NAME__" {
		t.Fatalf("Name = %q, want the unit's directory name __NAME__", e.Name)
	}
	if err := e.Name.Validate(); err != nil {
		t.Fatalf("Name is not a valid unit name: %v", err)
	}
	if e.Version == "" {
		t.Fatal("Version is empty — the boot inventory records it")
	}
	if err := e.Version.Validate(); err != nil {
		t.Fatalf("Version is not a valid unit version: %v", err)
	}
}
```

The templates end in `.tmpl` so no Go tool compiles or lints the unrendered files.

- [ ] **Step 4: Render the skeleton in `scripts/new-unit.sh`**

Change the header line to `# new-unit.sh — scaffold a unit from scripts/unit-skeleton/.`

Change the comment `extensions/zalo-oa is \`package zalooa\` under extensions/zalo-oa.` to `extensions/acme-sync is \`package acmesync\`.`

Replace everything from the line `copy_unit_tree "$SRC_EXT/gradion" "$SRC_EXT/$name"` up to (not including) the line `echo "new-unit: created extensions/$name (package $pkg)"` with:

```bash
SKELETON="$ROOT/scripts/unit-skeleton"
[ -d "$SKELETON" ] || die "new-unit: missing $SKELETON"

# Render every template into the new unit. The manifest is DERIVED and not
# rendered here: the next compose writes it.
mkdir -p "$SRC_EXT/$name"
render() {
  local src="$1" dest="$2"
  cp "$src" "$dest"
  rewrite_file_in_place "$dest" "s|__NAME__|$name|g" "s|__PKG__|$pkg|g"
}
render "$SKELETON/go.mod.tmpl"       "$SRC_EXT/$name/go.mod"
render "$SKELETON/unit.go.tmpl"      "$SRC_EXT/$name/$pkg.go"
render "$SKELETON/unit_test.go.tmpl" "$SRC_EXT/$name/${pkg}_test.go"

```

- [ ] **Step 5: Run the test**

Run: `bash scripts/new-unit.test.sh`
Expected: 13 `ok` lines, `all cases passed`.

- [ ] **Step 6: Add the suite to `make test-scripts`**

In the `test-scripts` recipe of `Makefile`, add after `@bash scripts/lib.test.sh`:

```make
	@bash scripts/new-unit.test.sh
```

In the same file, change `new-unit: ## Scaffold a unit from extensions/gradion (NAME=<name>)` to `new-unit: ## Scaffold a unit from scripts/unit-skeleton (NAME=<name>)`.

- [ ] **Step 7: End-to-end check against the real core**

```bash
make new-unit NAME=acme-demo
make u NAME=acme-demo
```

Expected: `make u` runs `go test` in the staged copy and passes, then the policy gates pass. Then remove the unit: `rm -rf extensions/acme-demo && make unstage`. Nothing is committed from this step.

- [ ] **Step 8: Commit**

```bash
git add scripts/unit-skeleton scripts/new-unit.sh scripts/new-unit.test.sh Makefile
git commit -m "feat(new-unit): scaffold from a neutral skeleton"
```

### Task 5: Remove client-specific targets and import the tooling docs

**Files:**
- Modify: `Makefile`, `.gitignore`, `README.md`, `docs/README.md`
- Create (copied from `644ee45`, then edited): `docs/adding-an-extension.md`, `docs/contributing-to-core.md`, `docs/desktop-build.md`, `docs/glossary.md`, `docs/release.md`, `docs/troubleshooting.md`

- [ ] **Step 1: Confirm the failure**

Run: `bash scripts/check-docs.sh; echo rc=$?`
Expected: `FAIL: README.md names \`make deploy\`` (and `make release`, `make trial`), `rc=1`.

- [ ] **Step 2: Edit the `Makefile`**

- Replace the first four comment lines with:

```make
# Margince instance template.
#
# core/ is upstream Margince as a submodule, never edited. extensions/ holds the
# instance's own units (none in the template).
```

- In `.PHONY`, change `stage unstage compose watch new-unit u u-fe u-check zalo-lab \` to `stage unstage compose watch new-unit u u-fe u-check \`.
- In the `u` recipe, change `e.g. make u NAME=zalo-oa` to `e.g. make u NAME=acme-sync`.
- Delete the block from the line `## zalo-lab is NOT A GATE and is not reachable from one.` up to (not including) the line `# ─────────────────────────────── gates`.

Check: `grep -n -i -E 'zalo|gradion' Makefile` prints only the line with `gradionhq/margince-demo-database`.

- [ ] **Step 3: Edit `.gitignore`**

Delete the `.zalolab/` rule and its three comment lines above it ("The zalo lab's output …").

- [ ] **Step 4: Copy and neutralize the tooling docs**

```bash
git -C "$A" archive 644ee45 -- docs/adding-an-extension.md docs/contributing-to-core.md \
  docs/desktop-build.md docs/glossary.md docs/release.md docs/troubleshooting.md | tar -x
```

Edit each file so that it describes the template:
- Replace "Gradion's units", "the Gradion installation", and similar with "the instance's units", "the instance".
- Replace example unit names (`zalo-oa`, `zalo-personal`, `dispact-connector`, `whatsapp-personal`, `gradion`) with `acme-sync`, or remove unit lists that describe that instance's units (`docs/release.md` lines 100–103, `docs/desktop-build.md` lines 622–625).
- `docs/contributing-to-core.md`: replace `gradionhq/margince-poc-v1` with `margince/margince`.
- `docs/release.md`: replace the example tag message `"Zalo OA inbound, desktop build info"` with `"Desktop build info"`.

Check: the following command prints only lines that name `gradionhq/margince-demo-database` or `gradionhq/margince-template`:

```bash
grep -n -i -E 'gradion|zalo|dispact|whatsapp|automation' docs/*.md
```

- [ ] **Step 5: Replace the commands section of `README.md`**

Replace the section `## Planned commands` (heading and table) with:

```markdown
## Commands

Run `make help` for the full list.

| Command | Function |
|---|---|
| `make install` | Check prerequisites, check out core, install dependencies, hooks, and configuration. |
| `make dev` | Run the development stack with the instance units. |
| `make new-unit NAME=<n>` | Create an extension unit from `scripts/unit-skeleton/`. |
| `make u NAME=<n>` | Run one unit's tests and the policy gates. |
| `make check` | Run the full quality gate. |
| `make ci` | Run `make check` plus the database and submodule lanes. |
| `make update-core REF=<ref>` | Move the core pin. |

Planned, not implemented yet: the trial bundle (issue T8), release (issue T7),
and deployment (issue T9).
```

Change the `## Status` paragraph to: "**Foundation in place.** The template works as Margince Default. Trial, release, and deployment are planned (see the issue breakdown)."

- [ ] **Step 6: Update `docs/README.md`**

Replace the section `## Planned guides` with:

```markdown
## Guides

| Guide | Content |
|---|---|
| [Adding an extension](adding-an-extension.md) | Create and test a unit. |
| [Contributing to core](contributing-to-core.md) | Send a change to `margince/margince`. |
| [Desktop build](desktop-build.md) | Build and run the desktop bundle. |
| [Release](release.md) | The current release workflow. |
| [Troubleshooting](troubleshooting.md) | Known problems and fixes. |
| [Glossary](glossary.md) | Terms. |

Planned: create a new instance, trial, deploy, upgrade core, merge template
changes.
```

- [ ] **Step 7: Verify**

Run: `bash scripts/check-docs.sh`
Expected: `check-docs: every documented make target exists (9 files).`

- [ ] **Step 8: Commit**

```bash
git add Makefile .gitignore README.md docs
git commit -m "docs: tooling guides for the template; drop client-specific targets"
```

### Task 6: `instance.yaml` and its validation (T2)

**Files:**
- Create: `instance.yaml`
- Create: `scripts/cli/go.mod`, `scripts/cli/go.sum`, `scripts/cli/main.go`, `scripts/cli/instance.go`, `scripts/cli/instance_test.go`, `scripts/cli/main_test.go`
- Modify: `Makefile` (targets `check-instance`, `test-cli`; `check` and `test-scripts`; `.PHONY`)
- Modify: `.github/workflows/ci.yml` (one step)

**Interfaces:**
- Produces: `cd scripts/cli && GOWORK=off go run . check -file <path> -core <dir>`. Exit 0 and prints `instance.yaml: ok (<name>, core <tag>)`; exit 1 and prints one `instance.yaml: <problem>` line per problem to stderr; exit 2 on usage errors.
- Produces (Go, package `main`): `type Instance struct { Name, DisplayName, Core, Flavor string }`, `func Parse([]byte) (Instance, error)`, `func (Instance) Validate() []string`, `func CheckCore(want string, tags []string) string`.

Schema (later issues add fields, for example `deploy` in T9):

| Key | Rule |
|---|---|
| `name` | Required. `^[a-z0-9]+(-[a-z0-9]+)*$`, at most 32 characters. |
| `display_name` | Required. One line. |
| `core` | Required. Must be one of the tags that point at `core/` HEAD. |
| `flavor` | Required. `^[a-z0-9]+(-[a-z0-9]+)*/margince$`. |
| any other key | Refused. |

- [ ] **Step 1: Create the module**

`scripts/cli/go.mod`:

```
module margince.instance/template/scripts/cli

go 1.26.6

require gopkg.in/yaml.v3 v3.0.1
```

Run: `cd scripts/cli && GOWORK=off go mod download gopkg.in/yaml.v3`

- [ ] **Step 2: Write the failing tests**

`scripts/cli/instance_test.go`:

```go
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
```

`scripts/cli/main_test.go`:

```go
package main

import (
	"bytes"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

// gitRepo creates a repository with one commit, tagged with each given tag.
func gitRepo(t *testing.T, tags ...string) string {
	t.Helper()
	dir := t.TempDir()
	run := func(args ...string) {
		cmd := exec.Command("git", append([]string{"-C", dir}, args...)...)
		cmd.Env = append(os.Environ(),
			"GIT_AUTHOR_NAME=t", "GIT_AUTHOR_EMAIL=t@example.test",
			"GIT_COMMITTER_NAME=t", "GIT_COMMITTER_EMAIL=t@example.test",
			"GIT_CONFIG_NOSYSTEM=1")
		if out, err := cmd.CombinedOutput(); err != nil {
			t.Fatalf("git %v: %v\n%s", args, err, out)
		}
	}
	run("init", "-q")
	run("commit", "-q", "--allow-empty", "-m", "c")
	for _, tag := range tags {
		run("tag", tag)
	}
	return dir
}

func writeFile(t *testing.T, body string) string {
	t.Helper()
	p := filepath.Join(t.TempDir(), "instance.yaml")
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestRunOK(t *testing.T) {
	var out, errOut bytes.Buffer
	code := run([]string{"check", "-file", writeFile(t, valid), "-core", gitRepo(t, "v0.0.2")}, &out, &errOut)
	if code != 0 {
		t.Fatalf("exit %d, stderr %q", code, errOut.String())
	}
	if !strings.Contains(out.String(), "instance.yaml: ok (margince-default, core v0.0.2)") {
		t.Fatalf("stdout %q", out.String())
	}
}

func TestRunCoreMismatch(t *testing.T) {
	var out, errOut bytes.Buffer
	code := run([]string{"check", "-file", writeFile(t, valid), "-core", gitRepo(t, "v0.0.1")}, &out, &errOut)
	if code != 1 || !strings.Contains(errOut.String(), "v0.0.1") {
		t.Fatalf("exit %d, stderr %q; want 1 naming v0.0.1", code, errOut.String())
	}
}

func TestRunReportsEveryProblem(t *testing.T) {
	var out, errOut bytes.Buffer
	code := run([]string{"check", "-file", writeFile(t, "name: Bad\n"), "-core", gitRepo(t)}, &out, &errOut)
	if code != 1 {
		t.Fatalf("exit %d, want 1", code)
	}
	for _, want := range []string{"name:", "display_name: required", "core: required", "flavor: required"} {
		if !strings.Contains(errOut.String(), want) {
			t.Errorf("stderr %q lacks %q", errOut.String(), want)
		}
	}
}

func TestRunMissingFile(t *testing.T) {
	var out, errOut bytes.Buffer
	if code := run([]string{"check", "-file", filepath.Join(t.TempDir(), "none.yaml")}, &out, &errOut); code != 1 {
		t.Fatalf("exit %d, want 1", code)
	}
}

func TestRunUsage(t *testing.T) {
	var out, errOut bytes.Buffer
	if code := run(nil, &out, &errOut); code != 2 {
		t.Fatalf("no command: exit %d, want 2", code)
	}
	if code := run([]string{"frobnicate"}, &out, &errOut); code != 2 {
		t.Fatalf("unknown command: exit %d, want 2", code)
	}
}
```

- [ ] **Step 3: Run the tests to verify they fail**

Run: `cd scripts/cli && GOWORK=off go test ./...`
Expected: build failure, `undefined: Parse` (and `run`, `Instance`, `CheckCore`).

- [ ] **Step 4: Implement**

`scripts/cli/instance.go`:

```go
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
```

`scripts/cli/main.go`:

```go
// Command cli is the template's own tooling. Run it with GOWORK=off: the
// editor go.work at the repository root does not list this module.
//
//	cli check [-file instance.yaml] [-core core]
package main

import (
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
)

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(args []string, stdout, stderr io.Writer) int {
	if len(args) == 0 || args[0] != "check" {
		fmt.Fprintln(stderr, "usage: cli check [-file instance.yaml] [-core core]")
		return 2
	}
	fs := flag.NewFlagSet("check", flag.ContinueOnError)
	fs.SetOutput(stderr)
	file := fs.String("file", "instance.yaml", "path to instance.yaml")
	core := fs.String("core", "core", "path to the core submodule")
	if err := fs.Parse(args[1:]); err != nil {
		return 2
	}

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
	problems := in.Validate()
	if in.Core != "" {
		tags, err := coreTags(*core)
		if err != nil {
			problems = append(problems, fmt.Sprintf("core: cannot read the tags of %s: %v", *core, err))
		} else if p := CheckCore(in.Core, tags); p != "" {
			problems = append(problems, p)
		}
	}
	if len(problems) > 0 {
		for _, p := range problems {
			fmt.Fprintf(stderr, "instance.yaml: %s\n", p)
		}
		return 1
	}
	fmt.Fprintf(stdout, "instance.yaml: ok (%s, core %s)\n", in.Name, in.Core)
	return 0
}

// coreTags lists the tags that point at HEAD of the core checkout.
func coreTags(dir string) ([]string, error) {
	out, err := exec.Command("git", "-C", dir, "tag", "--points-at", "HEAD").Output()
	if err != nil {
		return nil, err
	}
	return strings.Fields(string(out)), nil
}
```

Run: `cd scripts/cli && GOWORK=off go mod tidy` (writes `go.sum`).

- [ ] **Step 5: Run the tests**

Run: `cd scripts/cli && GOWORK=off go vet ./... && GOWORK=off go test ./... && gofmt -l .`
Expected: `ok  margince.instance/template/scripts/cli`, and `gofmt -l` prints nothing.

- [ ] **Step 6: Add `instance.yaml`**

```yaml
# instance.yaml — what this instance is. Validated by `make check-instance`.
# See docs/superpowers/specs/2026-09-24-client-instance-template-design.md, Section 6.2.
name: margince-default
display_name: Margince Default
core: v0.0.2
flavor: margince/margince
```

- [ ] **Step 7: Wire the Makefile and CI**

Add to `Makefile` in the gates section:

```make
check-instance: ## instance.yaml is valid and names the tag core/ is at
	@cd scripts/cli && GOWORK=off go run . check -file $(CURDIR)/instance.yaml -core $(CURDIR)/$(CORE)

test-cli: ## The template CLI's own tests
	@cd scripts/cli && GOWORK=off go vet ./... && GOWORK=off go test ./...
```

- Add `check-instance test-cli` to `.PHONY`.
- Change `check: toolcheck test-scripts test-secret-scan secret-scan` to `check: check-instance toolcheck test-scripts test-secret-scan secret-scan`.
- In the `test-scripts` recipe add `@$(MAKE) test-cli` as the last line.

In `.github/workflows/ci.yml`, directly before the step `- name: Staging script tests`, add:

```yaml
      - name: instance.yaml is valid
        run: make check-instance
```

- [ ] **Step 8: Verify the gate**

Run: `make check-instance`
Expected: `instance.yaml: ok (margince-default, core v0.0.2)`.

Then change `core: v0.0.2` to `core: v0.0.1` in `instance.yaml` and run `make check-instance; echo rc=$?`.
Expected: `instance.yaml: core: instance.yaml says "v0.0.1", but core/ is at v0.0.2`, `rc=2` (make reports the failed recipe). Restore `v0.0.2`.

- [ ] **Step 9: Commit**

```bash
git add instance.yaml scripts/cli Makefile .github/workflows/ci.yml
git commit -m "feat: instance.yaml and its validation in make check"
```

### Task 7: Full verification and push

**Files:** none changed unless a check fails.

- [ ] **Step 1: Fresh-clone install**

```bash
git clone --recurse-submodules <this repo> /tmp/mt-verify && cd /tmp/mt-verify
make install
```

Expected: ends with `ready. next:`. (`fswatch` missing is a note, not a failure.)

- [ ] **Step 2: Full gate**

Run: `make check`
Expected: exit 0. Record the duration in the pull request.

- [ ] **Step 3: Database and submodule lanes**

Run: `make ci`
Expected: ends with `ci: all lanes passed`.

- [ ] **Step 4: Development stack**

Run: `make dev`, wait for the api to report ready, open the web URL printed by core, sign in with the demo admin from `config/margince.yaml`, then `make dev-stop`.
Expected: the SPA loads and the boot inventory lists no instance units.

- [ ] **Step 5: Push and confirm CI**

Push a branch, open a pull request to `main`.
Expected: the `ci` workflow is green.

- [ ] **Step 6: Close the issues**

Tick T1 and T2 in the tracking issue #14 and close #1 and #2 with a link to the pull request.
