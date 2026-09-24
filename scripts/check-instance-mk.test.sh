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
