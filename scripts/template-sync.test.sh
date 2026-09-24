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
