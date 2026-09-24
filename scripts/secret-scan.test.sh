#!/usr/bin/env bash
# secret-scan.test.sh — prove the secret gate still CATCHES.
#
# A scan that finds nothing looks identical whether the tree is clean or the
# policy has been widened until it excuses everything. This is what tells the two
# apart: for the scoped allowlist in .gitleaks.toml, plant a token of the rule it
# targets, in a file its `paths` cover, on a line its `regexes` do NOT match, and
# require the scan to FAIL.
#
# Planted into a COPY of the tree, never the real one. The scan itself reads a
# `git archive HEAD` export, so a plant in the working tree would be invisible to
# it anyway — the copy is exported, planted into, and scanned directly.
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

# A `generic-api-key` token. Kept in one place so a rule change is one edit, and
# assembled rather than written whole so this file does not itself carry a
# 32-hex-looking literal on a line the allowlist regex might one day cover.
PLANTED_TOKEN="apiKey = \"$(printf 'a1b2c3d4e5f6a7b8' )$(printf 'c9d0e1f2a3b4c5d6')\""

# --- the tree as committed ---

t="$TMP/clean"; export_tree "$t"
if scan "$t"; then ok "the committed tree scans clean"; else
  fail "the committed tree scans clean — the gate is failing before any plant, so nothing below means anything"
fi

# --- THE CASE THIS FILE EXISTS FOR ---
#
# zalocrypto.go is excused for generic-api-key on lines matching the published
# zcid constant, and for nothing else. A token on any OTHER line of that file
# must still be caught. If this passes, the allowlist has become a file
# exclusion: narrow the allowlist, never weaken this case.
t="$TMP/scoped"; export_tree "$t"
target="$t/extensions/zalo-personal/zalocrypto.go"
[ -f "$target" ] || fail "extensions/zalo-personal/zalocrypto.go is not in the export — this case is scanning nothing"
printf '\n// planted by scripts/secret-scan.test.sh\nvar planted = %s\n' "$PLANTED_TOKEN" >> "$target"
if scan "$t"; then
  fail "a planted token on an UNEXCUSED line of zalocrypto.go was not caught — the allowlist covers the whole file"
else
  ok "a planted token elsewhere in zalocrypto.go is still caught"
fi

# The other half of "scoped": the excused literal itself must stay excused, or
# the exemption is not doing its job and the real file would fail the gate.
t="$TMP/excused"; export_tree "$t"
if scan "$t"; then ok "the published zcid constant stays excused"; else
  fail "the published zcid constant is no longer excused — the allowlist stopped matching it"
fi

# --- the allowlist must be bound to its RULE, not global ---
#
# Without targetRules an allowlist is global: gitleaks skips the file before it
# reads a line, so a token of a DIFFERENT rule would pass too. Plant one.
t="$TMP/otherrule"; export_tree "$t"
target="$t/extensions/zalo-personal/zalocrypto.go"
# ghp_ plus exactly 36 alphanumerics — the rule's own shape. A shorter string
# is not a github-pat and would make this case pass by being unmatched rather
# than by being allowlisted, which is the failure mode it exists to detect.
printf '\n// planted by scripts/secret-scan.test.sh\nvar plantedPAT = "%s"\n' \
  "ghp_$(printf '0123456789abcdefghij')$(printf '0123456789abcdef')" >> "$target"
if scan "$t"; then
  fail "a github-pat token in zalocrypto.go was not caught — the allowlist is global rather than bound to generic-api-key"
else
  ok "a token of a rule the allowlist does not target is still caught"
fi

if [ "$FAILURES" -gt 0 ]; then
  printf '\n%s case(s) failed — the exemption is wider than intended. Narrow .gitleaks.toml; do not weaken this test.\n' "$FAILURES" >&2
  exit 1
fi
printf '\nall cases passed — the gate still catches\n'
