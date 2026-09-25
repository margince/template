# Lifecycle CI Implementation Plan (T10, part 1)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** CI runs the real instance lifecycle on every pull request: create an instance from the template, check it, add and test a unit, deploy it through the `hook` adapter (success and rollback), and merge a template change into it. A template change that breaks any of these steps fails the template's own CI before any client merges it.

**Architecture:** One template-owned script, `scripts/lifecycle.test.sh`, drives the whole lifecycle in a scratch directory and asserts each outcome. `make test-lifecycle` runs it locally; a new workflow `lifecycle.yml` runs it in CI with the same tool setup as `ci.yml`. Trial (T8) and release (T7) steps are added to the same script when those issues land.

**Tech Stack:** Bash 3.2-compatible shell, GNU Make 3.81, GitHub Actions.

**Spec:** [`docs/superpowers/specs/2026-09-24-client-instance-template-design.md`](../specs/2026-09-24-client-instance-template-design.md) Section 13 (Testing). Issue: [T10 #10](https://github.com/gradionhq/margince-template/issues/10) (partial: trial and release are added later).

## Global Constraints

- Shell runs on macOS Bash 3.2 and Linux Bash 5.
- The script never pushes, never uses `PUSH=1`, never contacts GitHub except where `make` targets already do (core submodule, Go modules).
- The script works in a scratch directory and removes it at the end, unless `KEEP=1`.
- The template repository itself is never modified by the script; any "template change" is made in a scratch clone.
- The script sets its own git identity through `GIT_AUTHOR_*`/`GIT_COMMITTER_*` environment variables (CI runners have none).
- Pinned action SHAs are copied from `.github/workflows/ci.yml`.
- Documentation uses technical standard English. Commits use Conventional Commits.

## Review Focus

1. **The template tree is dirty** (e.g. a developer runs `make test-lifecycle` with local edits). `make new-instance` refuses; the script must say why instead of failing obscurely. Test in Task 1 (manual check recorded in the report).
2. **A step fails midway.** The script stops at that step, names it, and still removes the scratch directory (unless `KEEP=1`).
3. **The expected-failure deploy** (verify fails) must be asserted as a failure with rollback, not silently accepted as success.
4. **CI time.** The job must stay within a reasonable time (target under 15 minutes); record the measured duration.

---

### Task 1: `scripts/lifecycle.test.sh` and `make test-lifecycle`

**Files:**
- Create: `scripts/lifecycle.test.sh`
- Modify: `Makefile` (target `test-lifecycle`, `.PHONY`)

**Interfaces:**
- Consumes: `make new-instance`, `make check-instance`, `make check-template`, `make new-unit`, `make compose`, `make u`, `make deploy`, `make template-sync` (all existing).
- Produces: `bash scripts/lifecycle.test.sh` (exit 0 when every step passes); `make test-lifecycle`.

- [ ] **Step 1: Write the script**

```bash
#!/usr/bin/env bash
# lifecycle.test.sh — the whole instance lifecycle, end to end.
#
# Creates an instance from this template in a scratch directory and walks it
# through what a client developer does: check it, add and test a unit, deploy
# it through the hook adapter (a success and a rollback), and merge a template
# change into it. Every step asserts its outcome. Trial and release steps are
# added when those lanes exist (issues T8, T7).
#
# Slow (it composes and tests a unit), so it is not part of `make test-scripts`.
# Needs the tools `make install` provides.
#
# Usage: bash scripts/lifecycle.test.sh   (or: make test-lifecycle; KEEP=1 keeps the scratch directory)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

export GIT_AUTHOR_NAME="Lifecycle Test" GIT_AUTHOR_EMAIL="lifecycle@example.test"
export GIT_COMMITTER_NAME="Lifecycle Test" GIT_COMMITTER_EMAIL="lifecycle@example.test"

WORK="$(mktemp -d)"
DIR="$WORK/margince-lifecycle-demo"
cleanup() {
  if [ "${KEEP:-}" = "1" ]; then echo "lifecycle: kept $WORK"; else rm -rf "$WORK"; fi
}
trap cleanup EXIT

current=""
step() { current="$*"; printf '\n== lifecycle: %s\n' "$current"; }
fail() { printf '\nlifecycle: FAILED at "%s": %s\n' "$current" "$*" >&2; exit 1; }
trap 'printf "\nlifecycle: FAILED at \"%s\"\n" "$current" >&2' ERR

step "the template tree is clean"
[ -z "$(git -C "$ROOT" status --porcelain)" ] \
  || fail "make new-instance needs a clean template tree; commit or discard local changes first"

step "create an instance"
make -C "$ROOT" -s new-instance NAME=lifecycle-demo DISPLAY_NAME="Lifecycle Demo" DIR="$DIR"
cd "$DIR"

step "the new instance passes its checks"
make -s check-instance
make -s check-template

step "add a unit, compose it, and test it"
make -s new-unit NAME=acme-sync
make -s compose
git add extensions/acme-sync
git commit -q -m "feat: add acme-sync"
make -s u NAME=acme-sync
make -s check-template

step "deploy through the hook adapter"
mkdir -p deploy/staging/hooks
cat >> instance.yaml <<'EOF'
deploy:
  staging: { adapter: hook }
EOF
cat > deploy/staging/hooks/apply.sh <<'EOF'
#!/usr/bin/env bash
printf 'apply %s %s\n' "$DEPLOY_VERSION" "$IMAGE_API" >> "$DEPLOY_DIR/../deploy.log"
EOF
cat > deploy/staging/hooks/verify.sh <<'EOF'
#!/usr/bin/env bash
printf 'verify %s\n' "$DEPLOY_VERSION" >> "$DEPLOY_DIR/../deploy.log"
EOF
cat > deploy/staging/hooks/rollback.sh <<'EOF'
#!/usr/bin/env bash
printf 'rollback %s %s\n' "$DEPLOY_VERSION" "$DEPLOY_FAILED_STEP" >> "$DEPLOY_DIR/../deploy.log"
EOF
printf 'deploy.log\n' > deploy/.gitignore
git add instance.yaml deploy
git commit -q -m "feat: staging deployment"
git tag v0.1.0
make -s check-instance
make -s deploy ENV=staging VERSION=v0.1.0
grep -qx 'apply v0.1.0 lifecycle-demo/margince/api:v0.1.0' deploy/deploy.log || fail "apply did not receive the image name: $(cat deploy/deploy.log)"
grep -qx 'verify v0.1.0' deploy/deploy.log || fail "verify did not run"

step "a failed verify rolls back"
printf '#!/usr/bin/env bash\nexit 1\n' > deploy/staging/hooks/verify.sh
git commit -q -am "test: verify fails"
git tag v0.1.1
if make -s deploy ENV=staging VERSION=v0.1.1; then fail "a failed verify was reported as success"; fi
grep -qx 'rollback v0.1.1 verify' deploy/deploy.log || fail "rollback did not run: $(cat deploy/deploy.log)"

step "merge a template change"
TPL="$WORK/template"
git clone -q "$ROOT" "$TPL"
printf '\nLifecycle test note.\n' >> "$TPL/docs/README.md"
git -C "$TPL" commit -q -am "docs: lifecycle test change"
git remote set-url template "$TPL"
make -s template-sync
[ "$(tr -d '[:space:]' < .template-version)" = "$(git -C "$TPL" rev-parse HEAD)" ] || fail ".template-version does not record the merged template commit"
grep -q 'Lifecycle test note.' docs/README.md || fail "the template change did not arrive"
make -s check-template
make -s check-instance

trap - ERR
printf '\nlifecycle: all steps passed\n'
```

Notes for the implementer:
- `new-instance` gives the instance a `template` remote pointing at the template's `origin`. The last step points it at a scratch clone, so no network access to the template repository is needed.
- `deploy/deploy.log` is written by the hooks next to the environment directories and ignored, so the clean-tree check in `make deploy` still passes on the second deploy. Check this: if `make deploy` refuses the tree, adjust the log location (for example `$WORK`), not the check.
- If `make u` in a fresh instance needs `make install` first (core tools), add `make -s install` to the "add a unit" step and record the added time.

- [ ] **Step 2: Wire the Makefile**

```make
test-lifecycle: ## The whole instance lifecycle in a scratch instance (slow; KEEP=1 keeps it)
	@KEEP='$(subst ','\'',$(value KEEP))' bash scripts/lifecycle.test.sh
```

Add `test-lifecycle` to `.PHONY`. Do not add it to `test-scripts` or `check`.

- [ ] **Step 3: Run locally**

Commit first (the script needs a clean template tree), then run `make test-lifecycle` with output to a log. Expected: `lifecycle: all steps passed`. Record the duration.

Also run it once with a deliberately dirty tree (create an untracked file in the template, run, remove the file) and record the "needs a clean template tree" message.

- [ ] **Step 4: Commit**

```bash
git add scripts/lifecycle.test.sh Makefile
git commit -m "test: the whole instance lifecycle in make test-lifecycle"
```

### Task 2: `lifecycle.yml`

**Files:**
- Create: `.github/workflows/lifecycle.yml`
- Modify: `scripts/workflow-wiring.test.sh` (one case)

- [ ] **Step 1: Write the workflow**

Triggers: `pull_request`, `push` to `main`, `workflow_dispatch`. One job on `ubuntu-latest`, `permissions: contents: read`, `timeout-minutes: 30`. Steps, copied with the same pinned SHAs and settings from `.github/workflows/ci.yml`: checkout with `submodules: recursive`, Go setup, pnpm and Node setup, and the Go gate binaries cache and install step if `make u` needs them. Then one step:

```yaml
      - name: The instance lifecycle
        shell: bash
        run: make test-lifecycle
```

Header comment: what the job proves, that it is slow and therefore separate from `ci.yml`, and that trial and release join when T8 and T7 land.

- [ ] **Step 2: Wiring case** in `scripts/workflow-wiring.test.sh`: `lifecycle.yml` exists, runs `make test-lifecycle`, has `timeout-minutes`, and uses only SHA-pinned actions.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/lifecycle.yml scripts/workflow-wiring.test.sh
git commit -m "ci: run the instance lifecycle on every pull request"
```

### Task 3: Documentation

**Files:**
- Modify: `README.md` (commands table: `make test-lifecycle`), `docs/README.md` if it lists tests, spec Section 13 (the lifecycle test exists; trial and release steps follow T8/T7).

- [ ] **Step 1:** Update the three files; run `bash scripts/check-docs.sh`.
- [ ] **Step 2: Commit**

```bash
git add README.md docs
git commit -m "docs: the lifecycle test"
```
