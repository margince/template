#!/usr/bin/env bash
# check-manifests.sh — every unit's manifest.generated.json is committed and current.
#
# A manifest is DERIVED: `make compose` runs upstream's composer, which writes it
# next to the unit it scanned. The copy beside the source is what reviewers and
# operators read, and a stale one understates a unit's risk tiers — the one thing
# an operator checks before enabling a unit. So it has to be committed, and it
# has to match.
#
# TWO checks, because one is not enough:
#
#   1. CHANGED. `git diff` over the manifests only. Scoping matters: a diff over
#      all of extensions/ also sees the source file you are editing right now,
#      so the gate fired on every uncommitted edit and blamed a stale manifest
#      for it. That made the fast per-unit lane unusable mid-task, and
#      `make compose` could not clear it, because the diff was never about a
#      manifest.
#
#   2. TRACKED. `git diff` ignores untracked files, so a manifest that was never
#      `git add`ed slips past check 1 entirely. That is the normal state of a NEW
#      unit: scripts/new-unit.sh deletes the template's manifest (it is derived,
#      and shipping the template's would describe a different unit), so the first
#      compose writes one that nothing has added. Without this half, a unit can
#      reach main with no manifest at all and every gate green.
#
#      Asserted per unit as "the file is TRACKED", not as `git ls-files --others`
#      over a glob. --others takes --exclude-standard, so an ignored manifest
#      reads as absent and passes -- and adding a file called
#      `manifest.generated.json` to .gitignore is exactly the habit the name
#      invites. Stating the invariant per unit closes untracked, ignored and
#      removed-from-the-index with one question.
#
# Core runs the same two checks over the same artifact at core/backend/Makefile.
# Repeated here rather than reused because core's globs are '../extensions/*/…',
# the STAGED copies, which stage.sh hides in the submodule's info/exclude -- so
# asked from inside core, both halves silently cover nothing.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

glob='extensions/*/manifest.generated.json'

changed="$(git diff --name-only -- "$glob")"

untracked=""
for dir in extensions/*/; do
  [ -d "$dir" ] || continue
  manifest="${dir}manifest.generated.json"
  git ls-files --error-unmatch "$manifest" >/dev/null 2>&1 \
    || untracked="${untracked}${manifest}"$'\n'
done
untracked="${untracked%$'\n'}"

if [ -z "$changed" ] && [ -z "$untracked" ]; then
  exit 0
fi

echo "FAIL: a unit's manifest.generated.json is not committed as generated." >&2
echo >&2

if [ -n "$changed" ]; then
  echo "  changed by the composer (commit the new content):" >&2
  printf '    %s\n' $changed >&2
fi

if [ -n "$untracked" ]; then
  echo "  not tracked by git (run 'make compose', then git add these):" >&2
  printf '    %s\n' $untracked >&2
fi

echo >&2
echo "  The manifest is generated. Run 'make compose', then commit the result." >&2
echo "  Only manifests are checked here — your own uncommitted source edits are" >&2
echo "  not what this gate is about." >&2
exit 1
