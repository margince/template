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

if [ "$FAILURES" -gt 0 ]; then printf '\n%s case(s) failed\n' "$FAILURES" >&2; exit 1; fi
printf '\nall cases passed\n'
