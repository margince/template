#!/usr/bin/env bash
# check-public.sh — no tracked or staged file names a private repository,
# private host, private organization or private service (spec Section 7).
#
# This repository is a public template. scripts/check-public.patterns holds
# the private names it must never carry; this script fails the build the
# moment one of them lands in a tracked or staged file, anywhere except
# scripts/check-public.patterns itself (which has to name them to check for
# them) and docs/superpowers/ (working notes about this repository's own
# history, not shipped template content).
#
# TWO scans, because one is not enough:
#
#   1. `git grep`, no --cached: every file tracked in the working tree. This is
#      what a clone of this repository ships.
#   2. `git grep --cached`: the index. A file that is `git add`ed but not yet
#      committed is caught here before it ever reaches a commit — the case
#      the constraints' Review Focus item 5 calls out by name.
#
# Neither descends into core/: `git grep` never looks inside a submodule's
# gitlink, and that is deliberate here — core/ is upstream Margince, not
# template content this scan owns.
#
# Usage: bash scripts/check-public.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
PATTERNS="$HERE/check-public.patterns"

cd "$ROOT"

[ -f "$PATTERNS" ] || { echo "check-public: no patterns file at $PATTERNS" >&2; exit 1; }

# git grep -f treats every line of the patterns file as its own pattern,
# comments and blank lines included -- an empty pattern matches every line of
# every file. Strip both before handing it to git grep.
FILTERED="$(mktemp)"
trap 'rm -f "$FILTERED"' EXIT
grep -v -E '^[[:space:]]*(#|$)' "$PATTERNS" > "$FILTERED" || true

PATHSPEC=(-- ':!docs/superpowers/' ':!scripts/check-public.patterns')

hits="$( { git grep -n -i -E -f "$FILTERED" "${PATHSPEC[@]}" 2>/dev/null || true
           git grep -n -i -E -f "$FILTERED" --cached "${PATHSPEC[@]}" 2>/dev/null || true
         } | sort -u -t: -k1,1 -k2,2n)"

if [ -n "$hits" ]; then
  echo "check-public: a tracked or staged file names a private repository, host, organization or service:" >&2
  printf '%s\n' "$hits" >&2
  echo >&2
  echo "  Replace it. Only docs/superpowers/ and scripts/check-public.patterns may name one." >&2
  exit 1
fi

exit 0
