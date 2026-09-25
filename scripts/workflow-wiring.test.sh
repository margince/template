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

# deploy.yml runs by hand, in a GitHub Environment named by its own input, and
# must never let that input (or `version`) reach a shell verbatim: a
# workflow_dispatch input is attacker-controlled text the same as a pull
# request title, and `${{ inputs.x }}` spliced into a `run:` script is
# injected before the shell ever sees a variable. The job passes both through
# `env:` instead, which is opaque to the shell's parser.
DEPLOY_WF="$WF/deploy.yml"
if [ -e "$DEPLOY_WF" ]; then
  ok "deploy.yml exists"

  on_block="$(block_of on "$DEPLOY_WF")"
  if printf '%s\n' "$on_block" | grep -qE '^[[:space:]]{2}(push|pull_request|schedule|workflow_call)[[:space:]]*:'; then
    fail "deploy.yml triggers on more than workflow_dispatch"
  elif printf '%s\n' "$on_block" | grep -qE '^[[:space:]]{2}workflow_dispatch[[:space:]]*:'; then
    ok "deploy.yml triggers only on workflow_dispatch"
  else
    fail "deploy.yml does not trigger on workflow_dispatch"
  fi

  if grep -qE '^[[:space:]]*environment:[[:space:]]*\$\{\{[[:space:]]*inputs\.environment[[:space:]]*\}\}' "$DEPLOY_WF"; then
    ok "deploy.yml runs its job in the environment named by inputs.environment"
  else
    fail "deploy.yml does not set environment: \${{ inputs.environment }}"
  fi

  if grep -qE '^[[:space:]]*run:.*make deploy\b' "$DEPLOY_WF"; then
    ok "deploy.yml runs make deploy"
  else
    fail "deploy.yml does not run make deploy"
  fi

  # The `environment:` job key is resolved by GitHub before any step runs, so
  # a bad name still resolves an environment before this can object -- but it
  # still has to stop the job, before checkout finishes or any secret is
  # exported, on a name workflow_dispatch let through free-form.
  if grep -qF '^[a-z0-9]+(-[a-z0-9]+)*$' "$DEPLOY_WF"; then
    ok "deploy.yml validates the environment name"
  else
    fail "deploy.yml does not validate inputs.environment against ^[a-z0-9]+(-[a-z0-9]+)*\$"
  fi

  # A secret named PATH, GIT_*, GITHUB_*, BASH_ENV and the like would shadow a
  # variable the runner, git or a later step relies on. BASH_ENV stands in for
  # the whole deny list here: a shell-startup hook is the sharpest of them,
  # since a secret by that name would run as code the moment any later step's
  # shell starts, not merely read as data.
  if grep -qF 'BASH_ENV' "$DEPLOY_WF"; then
    ok "deploy.yml filters secret names against a deny list"
  else
    fail "deploy.yml does not filter secret names before exporting them (BASH_ENV not found in a deny list)"
  fi

  if grep -qE '^[[:space:]]*persist-credentials:[[:space:]]*false[[:space:]]*$' "$DEPLOY_WF"; then
    ok "deploy.yml's checkout does not persist a credential past the job"
  else
    fail "deploy.yml's checkout does not set persist-credentials: false"
  fi

  # Every line that belongs to a `run:` step, single-line or the body of a
  # `run: |` block, collected the same way block_of collects a top-level key's
  # body: from the `run:` line until indentation returns to its own level or
  # less.
  run_lines="$(awk '
    /^[[:space:]]*run:[[:space:]]*[|>]/ {
      match($0, /^[ ]*/); ind = RLENGTH; inrun = 1; print; next
    }
    /^[[:space:]]*run:/ { print; inrun = 0; next }
    inrun {
      if ($0 ~ /[^[:space:]]/) {
        match($0, /^[ ]*/)
        if (RLENGTH <= ind) { inrun = 0 } else { print }
      } else { print }
    }
  ' "$DEPLOY_WF")"
  if printf '%s\n' "$run_lines" | grep -qF '${{ inputs.'; then
    fail "deploy.yml templates \${{ inputs. directly into a run: step.
      inputs.environment and inputs.version must reach the shell through
      env:, never through \${{ }} inside run:, or a crafted input injects
      shell code."
  else
    ok "deploy.yml never templates \${{ inputs. into a run: step"
  fi
else
  fail "deploy.yml is missing"
fi

if [ "$FAILURES" -gt 0 ]; then
  printf '\n%d check(s) failed\n' "$FAILURES" >&2
  exit 1
fi
printf '\nworkflow-wiring: all checks passed\n'
