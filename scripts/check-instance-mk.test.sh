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
elif printf '%s' "$out" | grep -qE "target [\`']check'"; then
  ok "refuses a redefined check target and names it"
else
  fail "refuses a redefined check target and names it: $out"
fi

repo="$(fresh_repo)"
printf 'acme-lab:\n    echo lab\n' > "$repo/instance.mk"
if out="$(bash "$repo/scripts/check-instance-mk.sh" 2>&1)"; then
  fail "refuses a missing-tab recipe line"
elif printf '%s' "$out" | grep -qi "separator"; then
  ok "refuses a missing-tab recipe line"
else
  fail "refuses a missing-tab recipe line: $out"
fi

repo="$(fresh_repo)"
printf 'check::\n\t@echo x\n' > "$repo/instance.mk"
if out="$(bash "$repo/scripts/check-instance-mk.sh" 2>&1)"; then
  fail "refuses a check:: colon-type conflict"
elif printf '%s' "$out" | grep -qE "target file [\`']check' has both : and :: entries"; then
  # Make 3.81 quotes the name as `check', Make 4.x as 'check'.
  ok "refuses a check:: colon-type conflict"
else
  fail "refuses a check:: colon-type conflict: $out"
fi

# --- instance.mk sets only INSTANCE_* variables ---
repo="$(fresh_repo)"
printf 'INSTANCE_LAB_DIR := x\nacme-lab:\n\t@echo $(INSTANCE_LAB_DIR)\n' > "$repo/instance.mk"
if out="$(bash "$repo/scripts/check-instance-mk.sh" 2>&1)"; then ok "passes an INSTANCE_* variable"; else fail "passes an INSTANCE_* variable: $out"; fi

repo="$(fresh_repo)"
printf 'CORE := elsewhere\n' > "$repo/instance.mk"
if out="$(bash "$repo/scripts/check-instance-mk.sh" 2>&1)"; then
  fail "refuses CORE := elsewhere"
elif printf '%s\n' "$out" | grep -qx '  CORE'; then
  ok "refuses CORE := elsewhere and names it"
else
  fail "refuses CORE := elsewhere and names it: $out"
fi

repo="$(fresh_repo)"
printf 'override VERSION = 1\n' > "$repo/instance.mk"
if out="$(bash "$repo/scripts/check-instance-mk.sh" 2>&1)"; then
  fail "refuses override VERSION = 1"
elif printf '%s\n' "$out" | grep -qx '  VERSION'; then
  ok "refuses override VERSION = 1 and names it"
else
  fail "refuses override VERSION = 1 and names it: $out"
fi

if [ "$FAILURES" -gt 0 ]; then printf '\n%s case(s) failed\n' "$FAILURES" >&2; exit 1; fi
printf '\nall cases passed\n'
