#!/usr/bin/env bash
# A reusable workflow gets the secrets it is PASSED, and never the caller's.
#
# The defect this exists for shipped four releases. desktop-windows.yml and
# desktop-macos.yml read DEMO_DATASET_DEPLOY_KEY to decide whether to seed the
# folder they build. Both are called by release.yml through
# `uses:`, neither declared the secret under `workflow_call:`, and no call site
# passed it — so in every release the key read empty, the dataset check reported
# it unavailable, every seeding step skipped, and the lane went GREEN shipping an
# empty folder. It was only ever exercised by `workflow_dispatch`, which runs in
# the repository's own context and therefore sees the secret; that is why the
# feature was proved working twice and still never reached a release.
#
# Nothing fails here at runtime. The fallback is deliberate and correct for a
# fork with no key, so the only place this can be caught is the wiring.
#
# Usage: bash scripts/workflow-wiring.test.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WF="$HERE/../.github/workflows"

FAILURES=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }
ok()   { printf 'ok: %s\n' "$*"; }

# The block a top-level key owns: from that key to the next line indented no
# further than it. Used for `workflow_call:` and for one job's body.
block_of() { awk -v key="$1" '
  $0 ~ "^[[:space:]]*" key "[[:space:]]*:" && !started { match($0, /^[ ]*/); ind = RLENGTH; started = 1; print; next }
  started {
    if ($0 ~ /[^[:space:]]/) { match($0, /^[ ]*/); if (RLENGTH <= ind) exit }
    print
  }' "$2"; }

for f in "$WF"/*.yml; do
  [ -e "$f" ] || continue
  name="$(basename "$f")"
  grep -qE '^[[:space:]]*workflow_call[[:space:]]*:' "$f" || continue

  # Every secret this workflow READS, minus GITHUB_TOKEN, which is always there.
  reads="$(grep -oE 'secrets\.[A-Za-z0-9_]+' "$f" | sed 's/secrets\.//' \
             | grep -v '^GITHUB_TOKEN$' | sort -u || true)"
  [ -n "$reads" ] || { ok "$name is callable and reads no secret"; continue; }

  declared="$(block_of workflow_call "$f" | grep -oE '^[[:space:]]{4,}[A-Za-z0-9_]+[[:space:]]*:' \
                | tr -d ' :' | sort -u || true)"

  for s in $reads; do
    if printf '%s\n' "$declared" | grep -qx "$s"; then
      ok "$name declares $s under workflow_call"
    else
      fail "$name reads secrets.$s but does not declare it under \`workflow_call:\`.
      A called workflow inherits NOTHING, so every caller silently hands it an
      empty value and whatever that value gates is skipped, green."
    fi

    # And every caller has to actually pass it.
    for caller in "$WF"/*.yml; do
      grep -q "uses: ./.github/workflows/$name" "$caller" || continue
      cname="$(basename "$caller")"
      passed=no
      # Look at each job in the caller that uses this workflow.
      while IFS= read -r job; do
        body="$(block_of "$job" "$caller")"
        printf '%s\n' "$body" | grep -q "uses: ./.github/workflows/$name" || continue
        if printf '%s\n' "$body" | grep -qE 'secrets:[[:space:]]*inherit' \
           || printf '%s\n' "$body" | grep -q "$s:"; then
          passed=yes
        fi
      done < <(grep -oE '^  [A-Za-z0-9_-]+:' "$caller" | tr -d ' :')
      if [ "$passed" = yes ]; then
        ok "$cname passes $s to $name"
      else
        fail "$cname calls $name but passes it no $s.
      The called workflow reads that secret; unpassed it reads empty, and what it
      gates is skipped without failing anything."
      fi
    done
  done
done

if [ "$FAILURES" -gt 0 ]; then
  printf '\n%d check(s) failed\n' "$FAILURES" >&2
  exit 1
fi
printf '\nworkflow-wiring: all checks passed\n'
