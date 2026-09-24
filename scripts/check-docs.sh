#!/usr/bin/env bash
# check-docs.sh — every `make <target>` named in the docs exists.
#
# The cheap half of a real problem. This repository's docs were accurate about
# design and wrong about facts: a target that was never wired, a lane that
# claimed to run something it did not, a hardcoded list of upstream units that
# named two of ours. Most of that class needs a human reading the recipe.
#
# But the commonest and most annoying kind -- a documented command that does not
# exist, or that was renamed and left behind -- is mechanical, so it is checked
# here on every `make check`.
#
# What this does NOT catch, deliberately stated so nobody trusts it too far: a
# target that exists but does something other than what the prose says. Only
# reading the recipe catches that.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

DOCS=(README.md CLAUDE.md)
while IFS= read -r f; do DOCS+=("$f"); done < <(find docs -maxdepth 1 -name '*.md' | sort)

# The declared target set, from the same `##` help strings `make help` prints.
# Read from the Makefile rather than by running make, so this needs no submodule.
declared="$(grep -hE '^[a-z][a-z0-9-]*:.*?## ' Makefile | cut -d: -f1 | sort -u)"

# Pattern rules cannot appear in that list and are the documented escape hatch
# out of the named set. `target`/`targets` are the English words, not commands.
ALLOW='core-root-|core-backend-|^target$|^targets$'

fail=0
for doc in "${DOCS[@]}"; do
  [ -f "$doc" ] || continue
  # `make -C core ...` is deliberately named in CLAUDE.md as the thing NOT to do,
  # and names core's targets, not ours. Drop those before matching.
  used="$(sed 's/make -C core [a-z-]*//g' "$doc" \
    | grep -ohE '\bmake [a-z][a-z0-9-]+' \
    | awk '{print $2}' | sort -u || true)"
  for t in $used; do
    printf '%s\n' "$t" | grep -qE "$ALLOW" && continue
    grep -qx "$t" <<<"$declared" && continue
    printf 'FAIL: %s names `make %s`, which the Makefile does not declare.\n' "$doc" "$t" >&2
    fail=1
  done
done

if [ "$fail" -ne 0 ]; then
  printf '\n  Either the target was renamed and the doc was not, or the doc\n' >&2
  printf '  invented it. `make help` lists what exists.\n' >&2
  exit 1
fi

printf 'check-docs: every documented make target exists (%s files).\n' "${#DOCS[@]}"
