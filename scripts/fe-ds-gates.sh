#!/usr/bin/env bash
# fe-ds-gates.sh — core's design-system gates, minus the one that cannot mean
# anything here.
#
# Core's `fe-ds-gates` recipe runs six commands. Five sweep whole trees —
# frontend/src plus extensions/*/frontend — and say the same thing wherever they
# run. The sixth, check-ds-spacing.sh, is DIFF-SCOPED: it gates "what this branch
# adds" against `merge-base(origin/main, HEAD)` computed INSIDE core.
#
# Downstream there is no such branch. core/ is a pinned commit, and what that
# base resolves to is decided by the checkout's ref state rather than by
# anything we changed. Observed across two runs of the SAME code:
#
#   on the pull request  "no changed frontend *.tsx or *.css — nothing to gate"
#   on main, minutes later  "70 changed *.tsx ... vs origin/main", then FAIL on
#                           core/frontend/src/design-system/moneyinput.stories.tsx
#
# Note what the second one printed as its base: the literal string
# `origin/main`, not a commit. That is the script's own fallback for a
# merge-base that did not resolve, so the comparison ran against whatever that
# ref pointed at in the runner's submodule clone — and swept in core's own
# files, including a raw-px line in a story nobody here has ever touched.
#
# The exact ref is not the point and is not worth chasing: the verdict is
# decided by the checkout rather than by our units, and it can fail on core's
# code. Core exempts that backlog by scoping the gate to "new code on this
# branch", which is a scope we do not have.
#
# So that gate is skipped, by name, and its own census test with it. Nothing is
# lost that we could have had: a gate scoped to a branch we do not have cannot
# tell us anything about our units.
#
# WHAT IS NOT DONE HERE is copy the list. The commands are read out of core's
# recipe, so a gate added upstream joins this lane by itself — which is the
# property that made delegating right in the first place, and the reason a
# hand-kept list here would go stale without saying so.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=scripts/lib.sh
. scripts/lib.sh
require_core

# The one exclusion, matched on the path so both `check-ds-spacing.sh` and
# `check-ds-spacing.test.sh` are caught by it.
SKIP='check-ds-spacing'

# The recipe body: every line after `fe-ds-gates:` that is still indented.
recipe_commands() {
  awk '
    /^fe-ds-gates:/ { inrecipe = 1; next }
    inrecipe && /^\t/ { sub(/^\t/, ""); sub(/^[@-]/, ""); print; next }
    inrecipe { exit }
  ' "$CORE/Makefile"
}

commands="$(recipe_commands)"
[ -n "$commands" ] || die "fe-ds-gates: found no recipe in $CORE/Makefile — has the target been renamed?"

ran=0
while IFS= read -r cmd; do
  [ -n "$cmd" ] || continue
  case "$cmd" in
    *"$SKIP"*)
      printf '==> skipping %s — diff-scoped against core'"'"'s own origin/main, which says nothing about our units (scripts/fe-ds-gates.sh)\n' "$cmd"
      continue
      ;;
  esac
  printf '==> %s\n' "$cmd"
  ( cd "$CORE" && eval "$cmd" )
  ran=$((ran + 1))
done <<EOF
$commands
EOF

[ "$ran" -gt 0 ] || die "fe-ds-gates: every command in core's recipe was skipped — the exclusion no longer matches only what it should"
printf 'fe-ds-gates: %d gate(s) passed over frontend/src + extensions/*/frontend\n' "$ran"
