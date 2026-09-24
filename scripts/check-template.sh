#!/usr/bin/env bash
# check-template.sh — template-owned paths are exactly what the template shipped.
#
# .template-version names the template commit this instance last merged. Every
# path listed in .template-owned must be identical to that commit: no edits, no
# added files. A tooling change is made in margince-template and merged back, so
# every instance gets it (design Section 6.1). The list is read from the
# template commit, so an instance cannot remove a path from it.
#
# The template has no .template-version: it is the source, and there is nothing
# to compare it with.
#
# Usage: bash scripts/check-template.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

if [ ! -f .template-version ]; then
  echo "check-template: no .template-version — this is the template; nothing to compare"
  exit 0
fi

want="$(tr -d '[:space:]' < .template-version)"
if ! printf '%s' "$want" | grep -Eq '^[0-9a-f]{40}$'; then
  echo "check-template: .template-version must hold one 40-character commit id, found '$want'" >&2
  exit 1
fi

# The commit is in this repository's history because the instance merged it. A
# shallow CI checkout may lack it, so fetch exactly that commit from origin.
if ! git cat-file -e "$want^{commit}" 2>/dev/null; then
  git fetch --quiet --depth=1 origin "$want" 2>/dev/null || true
fi
if ! git cat-file -e "$want^{commit}" 2>/dev/null; then
  echo "check-template: template commit $want is not in this repository; run make template-sync" >&2
  exit 1
fi

paths=()
while IFS= read -r line; do
  case "$line" in ''|'#'*) continue ;; esac
  paths+=("$line")
done < <(git show "$want:.template-owned")

changed="$(git diff --name-only "$want" -- "${paths[@]}")"
added="$(git ls-files --others --exclude-standard -- "${paths[@]}")"
if [ -n "$changed$added" ]; then
  echo "check-template: template-owned paths differ from template commit ${want:0:12}:" >&2
  printf '%s\n' $changed $added | sort -u | sed 's/^/  /' >&2
  echo "Make the change in margince-template, then run make template-sync here." >&2
  exit 1
fi
echo "check-template: template-owned paths match template commit ${want:0:12}"
