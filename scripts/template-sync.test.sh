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

# ─── core pin, instance-owned and template-owned conflicts ───────────────
# Local submodule clones use the file transport, which git refuses by default.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always

CORE_UP="$TMP/core-upstream"
git init -q -b main "$CORE_UP"
printf 'one\n' > "$CORE_UP/f" && git -C "$CORE_UP" add -A && git -C "$CORE_UP" commit -q -m one && git -C "$CORE_UP" tag v0.0.1
printf 'two\n' > "$CORE_UP/f" && git -C "$CORE_UP" commit -qam two && git -C "$CORE_UP" tag v0.0.2
V1="$(git -C "$CORE_UP" rev-parse v0.0.1)"

TPL2="$TMP/template2"
git init -q -b main "$TPL2"
mkdir -p "$TPL2/scripts"
cp "$ROOT/.template-owned" "$TPL2/.template-owned"
cp "$SCRIPT_DIR/check-template.sh" "$SCRIPT_DIR/check-instance-mk.sh" "$SCRIPT_DIR/template-sync.sh" "$SCRIPT_DIR/lib.sh" "$TPL2/scripts/"
printf 'help:\n\t@echo help\n' > "$TPL2/Makefile"
printf '# margince-template\n' > "$TPL2/README.md"
printf 'name: margince-default\ncore: v0.0.1\n' > "$TPL2/instance.yaml"
git -C "$TPL2" submodule add -q "$CORE_UP" core
git -C "$TPL2/core" checkout -q --detach v0.0.1
git -C "$TPL2" add -A && git -C "$TPL2" commit -q -m one
T2ONE="$(git -C "$TPL2" rev-parse HEAD)"

INST2="$TMP/instance2"
git clone -q -o template "$TPL2" "$INST2"
git -C "$INST2" submodule update -q --init core
printf '%s\n' "$T2ONE" > "$INST2/.template-version"
printf 'name: acme\ncore: v0.0.1\n' > "$INST2/instance.yaml"
printf '# Acme\n' > "$INST2/README.md"
git -C "$INST2" add -A && git -C "$INST2" commit -q -m "create instance"

# (a) The template bumps core and edits README.md and instance.yaml.
git -C "$TPL2/core" checkout -q --detach v0.0.2
printf 'name: margince-default\ncore: v0.0.2\n' > "$TPL2/instance.yaml"
printf '# margince-template\nnewer\n' > "$TPL2/README.md"
git -C "$TPL2" add -A && git -C "$TPL2" commit -q -m "bump core"
T2TWO="$(git -C "$TPL2" rev-parse HEAD)"

if out="$(cd "$INST2" && bash scripts/template-sync.sh 2>&1)"; then ok "(a) syncs a template that bumped core"; else fail "(a) syncs a template that bumped core: $out"; fi
if [ "$(git -C "$INST2" rev-parse HEAD:core)" = "$V1" ] && [ "$(git -C "$INST2/core" rev-parse HEAD)" = "$V1" ]; then ok "(a) the instance keeps its core pin"; else fail "(a) the instance keeps its core pin"; fi
if [ "$(cat "$INST2/instance.yaml")" = "$(printf 'name: acme\ncore: v0.0.1')" ] && [ "$(cat "$INST2/README.md")" = "# Acme" ]; then ok "(a) instance.yaml and README.md stay the instance's"; else fail "(a) instance.yaml and README.md stay the instance's"; fi
if printf '%s\n' "$out" | grep -qF "template-sync: the template pins core at v0.0.2; this instance stays at v0.0.1. Run make update-core REF=v0.0.2 to follow."; then ok "(a) names the template's core pin"; else fail "(a) names the template's core pin: $out"; fi
if printf '%s\n' "$out" | grep -qF "template-sync: the template changed instance.yaml; review with: git diff" \
  && printf '%s\n' "$out" | grep -qF "template-sync: the template changed README.md; review with: git diff"; then ok "(a) notices the template's instance.yaml and README.md changes"; else fail "(a) notices the template's instance.yaml and README.md changes: $out"; fi
if [ "$(tr -d '[:space:]' < "$INST2/.template-version")" = "$T2TWO" ]; then ok "(a) records the merged commit"; else fail "(a) records the merged commit"; fi
if [ -z "$(git -C "$INST2" status --porcelain)" ] && [ "$(git -C "$INST2" rev-parse -q --verify HEAD^2)" = "$T2TWO" ]; then ok "(a) commits the merge"; else fail "(a) commits the merge"; fi
if bash "$INST2/scripts/check-template.sh" >/dev/null 2>&1; then ok "(a) check-template passes after the sync"; else fail "(a) check-template passes after the sync"; fi

# (b) A conflict on a template-owned file resolves to the template's side.
printf '# instance drift\n' >> "$INST2/scripts/lib.sh"
git -C "$INST2" commit -qam "drift"
printf '# template change\n' >> "$TPL2/scripts/lib.sh"
git -C "$TPL2" commit -qam three
T2THREE="$(git -C "$TPL2" rev-parse HEAD)"
if out="$(cd "$INST2" && bash scripts/template-sync.sh 2>&1)"; then ok "(b) resolves a template-owned conflict"; else fail "(b) resolves a template-owned conflict: $out"; fi
if cmp -s "$INST2/scripts/lib.sh" "$TPL2/scripts/lib.sh"; then ok "(b) the template-owned file is the template's"; else fail "(b) the template-owned file is the template's"; fi
if [ "$(tr -d '[:space:]' < "$INST2/.template-version")" = "$T2THREE" ] && bash "$INST2/scripts/check-template.sh" >/dev/null 2>&1; then ok "(b) records the commit and check-template passes"; else fail "(b) records the commit and check-template passes"; fi

# (c) A conflict on a path in neither list stops with guidance.
printf 'instance\n' > "$INST2/notes.txt" && git -C "$INST2" add notes.txt && git -C "$INST2" commit -qm notes
printf 'template\n' > "$TPL2/notes.txt" && git -C "$TPL2" add notes.txt && git -C "$TPL2" commit -qm notes
if out="$(cd "$INST2" && bash scripts/template-sync.sh 2>&1)"; then
  fail "(c) stops on a conflict in neither list — it succeeded"
else
  ok "(c) stops on a conflict in neither list"
fi
if printf '%s\n' "$out" | grep -q 'notes.txt' && printf '%s\n' "$out" | grep -q 'git commit, then run make template-sync again'; then ok "(c) names the path and the next step"; else fail "(c) names the path and the next step: $out"; fi
if [ "$(tr -d '[:space:]' < "$INST2/.template-version")" = "$T2THREE" ] && git -C "$INST2" rev-parse -q --verify MERGE_HEAD >/dev/null; then ok "(c) leaves the merge in progress and .template-version unchanged"; else fail "(c) leaves the merge in progress and .template-version unchanged"; fi
git -C "$INST2" merge --abort

# ─── default deployment environment (design Section 9.8) ─────────────────
# deploy/ is instance-owned, but a path neither side touched merges in with
# no conflict at all — so a new deploy/<env>/ the template adds, or a change
# to one the instance already has, never goes through take_side. cli check
# needs the real Go CLI, so this template is the full scripts/ tree (like
# new-instance.test.sh), not the four files copied above.
cli_check() {
  (cd "$1/scripts/cli" && GOWORK=off go run . check -file "$1/instance.yaml" -core "$1/core" >/dev/null 2>&1)
}

TPL3="$TMP/template3"
git init -q -b main "$TPL3"
cp -R "$SCRIPT_DIR" "$TPL3/scripts"
cp "$ROOT/.template-owned" "$TPL3/.template-owned"
printf 'help:\n\t@echo help\n' > "$TPL3/Makefile"
printf '# margince-template\n' > "$TPL3/README.md"
printf 'name: margince-default\ndisplay_name: Margince Default\ncore: v0.0.2\n' > "$TPL3/instance.yaml"
git -C "$TPL3" submodule add -q "$CORE_UP" core
git -C "$TPL3/core" checkout -q --detach v0.0.2
git -C "$TPL3" add -A && git -C "$TPL3" commit -q -m one
T3ONE="$(git -C "$TPL3" rev-parse HEAD)"

# (d) An instance created before deploy/production shipped — no deploy/ at
# all — clones the template at T3ONE.
INST3="$TMP/instance3"
git clone -q -o template "$TPL3" "$INST3"
git -C "$INST3" submodule update -q --init core
printf '%s\n' "$T3ONE" > "$INST3/.template-version"
printf 'name: acme\ndisplay_name: Acme\ncore: v0.0.2\n' > "$INST3/instance.yaml"
printf '# Acme\n' > "$INST3/README.md"
git -C "$INST3" add -A && git -C "$INST3" commit -q -m "create instance"

# The template gains deploy/production/ (design Section 9.8).
mkdir -p "$TPL3/deploy/production/config"
printf '# deploy/production/host.env\nHOST_SSH=\nHOST_DOMAIN=\n' > "$TPL3/deploy/production/host.env"
printf 'MARGINCE_LICENSE\n' > "$TPL3/deploy/production/secrets"
printf 'workspace:\n  name: "Margince Default"\n' > "$TPL3/deploy/production/config/margince.yaml"
printf 'name: margince-default\ndisplay_name: Margince Default\ncore: v0.0.2\ndeploy:\n  production: { adapter: host }\n' > "$TPL3/instance.yaml"
git -C "$TPL3" add -A && git -C "$TPL3" commit -q -m "add deploy/production"
T3TWO="$(git -C "$TPL3" rev-parse HEAD)"

if out="$(cd "$INST3" && bash scripts/template-sync.sh 2>&1)"; then ok "(d) syncs a template that adds deploy/production"; else fail "(d) syncs a template that adds deploy/production: $out"; fi
if [ ! -e "$INST3/deploy/production" ]; then ok "(d) deploy/production is not created"; else fail "(d) deploy/production is not created"; fi
if [ "$(cat "$INST3/instance.yaml")" = "$(printf 'name: acme\ndisplay_name: Acme\ncore: v0.0.2')" ]; then ok "(d) instance.yaml's deploy: entries are unchanged (still none)"; else fail "(d) instance.yaml's deploy: entries are unchanged (still none): $(cat "$INST3/instance.yaml")"; fi
if cli_check "$INST3"; then ok "(d) cli check passes"; else fail "(d) cli check passes"; fi
if printf '%s\n' "$out" | grep -qF "template-sync: the template now ships a default production environment; create yours with make deploy-init ENV=production (DOMAIN=, SSH=, ADMIN_EMAIL=)"; then ok "(d) prints the default-production-environment hint"; else fail "(d) prints the default-production-environment hint: $out"; fi
if printf '%s\n' "$out" | grep -qF "template-sync: removed deploy/production/host.env"; then ok "(d) names each removed path"; else fail "(d) names each removed path: $out"; fi

# (e) An instance created AFTER deploy/production shipped keeps its own
# deploy/production/ across a merge that changes a line it never touched,
# and gets the review hint instead of a silent, unreviewed update.
INST4="$TMP/instance4"
git clone -q -o template "$TPL3" "$INST4"
git -C "$INST4" submodule update -q --init core
printf '%s\n' "$T3TWO" > "$INST4/.template-version"
printf 'name: acme4\ndisplay_name: Acme4\ncore: v0.0.2\ndeploy:\n  production: { adapter: host }\n' > "$INST4/instance.yaml"
printf '# Acme4\n' > "$INST4/README.md"
git -C "$INST4" add -A && git -C "$INST4" commit -q -m "create instance"

printf '# deploy/production/host.env\n# a comment the template added\nHOST_SSH=\nHOST_DOMAIN=\n' > "$TPL3/deploy/production/host.env"
git -C "$TPL3" commit -qam "deploy/production/host.env: note"
T3THREE="$(git -C "$TPL3" rev-parse HEAD)"

if out="$(cd "$INST4" && bash scripts/template-sync.sh 2>&1)"; then ok "(e) syncs a template that changed deploy/production/host.env"; else fail "(e) syncs a template that changed deploy/production/host.env: $out"; fi
if grep -qF 'a comment the template added' "$INST4/deploy/production/host.env"; then ok "(e) keeps the instance's deploy/production, with the merge's change"; else fail "(e) keeps the instance's deploy/production, with the merge's change"; fi
if printf '%s\n' "$out" | grep -qF "template-sync: the template changed deploy/production/host.env; review with git diff HEAD -- deploy/production/host.env"; then ok "(e) prints the review hint"; else fail "(e) prints the review hint: $out"; fi
if printf '%s\n' "$out" | grep -q "template-sync: removed deploy/"; then fail "(e) does not remove the instance's own deploy/production"; else ok "(e) does not remove the instance's own deploy/production"; fi
if cli_check "$INST4"; then ok "(e) cli check passes"; else fail "(e) cli check passes"; fi

if [ "$FAILURES" -gt 0 ]; then printf '\n%s case(s) failed\n' "$FAILURES" >&2; exit 1; fi
printf '\nall cases passed\n'
