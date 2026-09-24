#!/usr/bin/env bash
# toolcheck.test.sh — toolcheck must read the version core actually pins.
#
# It did not, and the failure was invisible in the only way that matters: it
# still printed a number, still compared majors, and still refused `make check`.
# It scraped the `version:` after `pnpm/action-setup` in core's frontend lane;
# upstream moved the pin into `packageManager` and removed that input, so the
# awk fell through to `node-version: 24` and demanded pnpm 24 — a major nothing
# pins, which corepack would refuse against packageManager.
#
# A gate whose job is "match CI" is worthless if it can be wrong about what CI
# runs, and this one is the FIRST thing `make check` does: wrong here blocks
# every lane behind it. So the invariant held below is not "the script runs" but
# "the number it reports is the number core pins".
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

pass=0
ok()   { printf 'ok: %s\n' "$*"; pass=$((pass + 1)); }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

CORE="${CORE:-core}"

[ -f "$CORE/package.json" ] || { echo "toolcheck-test: no $CORE/package.json — skipping"; exit 0; }

# The pin, read the way a human would: the packageManager field.
pinned="$(python3 -c '
import json, re, sys
pm = json.load(open(sys.argv[1])).get("packageManager") or ""
m = re.match(r"pnpm@([0-9][0-9.]*)", pm)
print(m.group(1) if m else "")
' "$CORE/package.json")"

[ -n "$pinned" ] || fail "core/package.json declares no pnpm packageManager, so this test cannot
      judge toolcheck. If upstream really dropped the field, toolcheck's source
      of truth moved again and both halves need rereading — do not delete this
      test to make the suite green."

# toolcheck names the version it wants in every branch it can take, so the
# report is scraped rather than the internals reimplemented.
out="$(bash scripts/toolcheck.sh 2>&1 || true)"

# The MAJOR, not the full version, because that is toolcheck's own contract: "a
# patch difference is not a resolution difference". Its two branches also say
# different things — a mismatch names the pinned version in full, a match names
# the local version and the major it satisfies — so the pinned patch appears in
# only one of them. Asserting the full string passed on a laptop that was a
# major behind and failed in CI, which is a major in step: the assertion was
# reading which BRANCH ran, not whether the number came from the right file.
pinned_major="${pinned%%.*}"

if ! printf '%s' "$out" | grep -qE "CI runs pnpm $pinned\b|matches the $pinned_major\.x"; then
  fail "core pins pnpm $pinned (major $pinned_major), and toolcheck's answer does not
      agree with it:
$(printf '%s' "$out" | sed 's/^/      /' | head -6)
      A gate that is wrong about what CI runs sends somebody to install a
      version nothing pins, and it is the first thing \`make check\` does."
fi
ok "toolcheck's pnpm major agrees with core's pin ($pinned_major.x)"

# The remedy has to be one that RESPECTS the pin. `npm install -g` puts a global
# major beside packageManager, and corepack then refuses the pair with
# ERR_PNPM_BAD_PM_VERSION — advice that replaces one broken state with another.
if printf '%s' "$out" | grep -q 'pnpm .* locally, but CI runs'; then
  # An indented COMMAND, not any mention: toolcheck's own prose explains why it
  # says corepack instead of `npm install -g`, and that sentence must not trip
  # this. Matching a leading-whitespace command line separates advice from
  # explanation.
  if printf '%s' "$out" | grep -qE '^[[:space:]]+npm install -g'; then
    fail "toolcheck tells the reader to \`npm install -g\` pnpm. packageManager is the
      pin and corepack reads it, so a global major that disagrees earns
      ERR_PNPM_BAD_PM_VERSION rather than a working tree. Say corepack."
  fi
  printf '%s' "$out" | grep -q 'corepack' \
    || fail "toolcheck reports a pnpm mismatch and offers no way to fix it."
  ok "the mismatch it reports comes with a corepack remedy"
else
  ok "local pnpm matches the pin (no remedy to check)"
fi

# The old bug in one line: whatever toolcheck reads, it must not be Node's.
node_major="$(grep -m1 -oE 'node-version:[[:space:]]*[0-9]+' \
  "$CORE/.github/workflows/_lane-frontend.yml" 2>/dev/null | grep -oE '[0-9]+' || true)"
if [ -n "$node_major" ] && [ "${pinned%%.*}" != "$node_major" ]; then
  printf '%s' "$out" | grep -q "pnpm $node_major\b" \
    && fail "toolcheck reports pnpm $node_major, which is core's node-version, not its pnpm
      pin ($pinned). This is the original bug: the pnpm \`version:\` input is
      gone from the lane, so a scrape falls through to the next \`version:\`."
  ok "it does not mistake node-version ($node_major) for the pnpm pin"
fi

printf '\ntoolcheck-test: %d check(s) passed\n' "$pass"
