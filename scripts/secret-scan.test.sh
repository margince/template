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
