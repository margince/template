#!/usr/bin/env bash
# check-core-clean.sh — core/ came out of a build untouched, and unstage really
# unstaged.
#
# Run AFTER `make unstage`. Asserts the four things that must be true of a
# pristine submodule, one at a time.
#
# Checked PRECISELY, not with `git status --ignored`. stage.sh adds our staged
# copies to the submodule's info/exclude, so `git diff` and a plain `git status`
# are both blind to them, and the old check passed while residue sat in the tree.
# But a blanket --ignored check can never pass either: core's own build output
# (build/, frontend/node_modules/, .tmp/) is always present as ignored files. So
# each condition is asserted on its own terms.
#
# Lived in .github/workflows/ci.yml as inline shell, where `make ci` could not
# reach it -- which is how "ci means what CI would say" stopped being true.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

CORE="${CORE:-core}"
fail=0

# GitHub Actions renders ::error:: as an annotation; a plain shell run just sees
# the text. One emitter either way.
err() {
  if [ -n "${GITHUB_ACTIONS:-}" ]; then printf '::error::%s\n' "$*" >&2
  else printf 'FAIL: %s\n' "$*" >&2; fi
  fail=1
}

# 1. No tracked file in the submodule was modified. The read-only invariant.
if ! git -C "$CORE" diff --exit-code >/dev/null 2>&1; then
  err "the build modified tracked files in $CORE/ — the submodule is read-only here"
  git -C "$CORE" diff --name-only | sed 's|^|    |' >&2
fi

# 2. No staged unit survived unstage.
for unit in extensions/*/; do
  unit="$(basename "$unit")"
  [ -e "$CORE/extensions/$unit" ] && err "$CORE/extensions/$unit survived unstage"
done

# 3. The staging marker is gone.
marker="$(git -C "$CORE" rev-parse --git-dir)/staged-units"
[ -f "$marker" ] && err "the staging marker survived unstage"

# 4. The info/exclude block is gone. Left behind, it hides real residue from
#    every later check -- including check 2 on the next run.
exclude="$(git -C "$CORE" rev-parse --git-dir)/info/exclude"
if grep -q 'BEGIN staged units' "$exclude" 2>/dev/null; then
  err "unstage left its exclude block behind"
fi

if [ "$fail" -ne 0 ]; then
  printf '\n  Run `make unstage` and re-check. If a tracked file really changed,\n' >&2
  printf '  that edit belongs on a contribution branch: see docs/contributing-to-core.md.\n' >&2
  exit 1
fi

echo "check-core-clean: $CORE/ is pristine and fully unstaged."
