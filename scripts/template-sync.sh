#!/usr/bin/env bash
# template-sync.sh — merge margince-template into this instance and record it.
#
# Template changes reach an instance by merge (design Section 4). After the
# merge, .template-version names the merged template commit, which is what
# make check-template compares the template-owned paths with.
#
# Usage: bash scripts/template-sync.sh   (or: make template-sync)
#   TEMPLATE_REMOTE (default template), TEMPLATE_BRANCH (default main)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$ROOT"

remote="${TEMPLATE_REMOTE:-template}"
branch="${TEMPLATE_BRANCH:-main}"

[ -f .template-version ] || die "template-sync: no .template-version — run this in an instance, not in the template"
git remote get-url "$remote" >/dev/null 2>&1 \
  || die "template-sync: no git remote '$remote'. Add it: git remote add $remote git@github.com:gradionhq/margince-template.git"
[ -z "$(git status --porcelain)" ] || die "template-sync: commit or discard local changes first"

git fetch --quiet "$remote" "$branch"
target="$(git rev-parse FETCH_HEAD)"

if ! git merge --no-edit "$target"; then
  die "template-sync: the merge has conflicts. For template-owned paths keep the template version (git checkout --theirs -- <path>), finish the merge with git commit, then run make template-sync again"
fi

printf '%s\n' "$target" > .template-version
git add .template-version
if git diff --cached --quiet; then
  echo "template-sync: already at template commit ${target:0:12}"
else
  git commit --quiet -m "chore: record template commit ${target:0:12}"
  echo "template-sync: merged and recorded template commit ${target:0:12}"
fi
