#!/usr/bin/env bash
# release.sh — check every precondition, then tag and push a release (design
# Section 9.2). Every check below runs before any tag exists: the first one
# that fails exits 1 and leaves no tag, locally or on the remote.
#
# Usage: bash scripts/release.sh <version>   (or: make release VERSION=<v>)
#   RELEASE_REMOTE (default origin), RELEASE_BRANCH (default main),
#   RELEASE_CHECK_TARGET (default check)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$ROOT"

version="${1:-}"
remote="${RELEASE_REMOTE:-origin}"
branch="${RELEASE_BRANCH:-main}"
target="${RELEASE_CHECK_TARGET:-check}"

is_release_version "$version" ||
  die "release: VERSION '$version' does not match $RELEASE_VERSION_RE, e.g. v1.2.0 or v1.2.0-rc.1"

dirty="$(git status --porcelain)"
[ -z "$dirty" ] ||
  die "release: the working tree has uncommitted changes; commit or discard them first"

git fetch --quiet --tags "$remote" "$branch" ||
  die "release: git fetch $remote $branch failed"
git merge-base --is-ancestor HEAD "$remote/$branch" ||
  die "release: HEAD is not an ancestor of $remote/$branch; push or merge it first"

! git rev-parse -q --verify "refs/tags/$version" >/dev/null 2>&1 ||
  die "release: tag $version already exists locally"
[ -z "$(git ls-remote --tags "$remote" "refs/tags/$version")" ] ||
  die "release: tag $version already exists on $remote"

# Every existing release tag must be older than the one about to be pushed.
# The fetch above already brought every tag on $remote into this checkout
# (git fetch --tags), so the local tag list covers both.
while IFS= read -r tag; do
  [ -n "$tag" ] || continue
  is_release_version "$tag" || continue
  version_newer "$version" "$tag" ||
    die "release: $version is not newer than $tag"
done <<< "$(git tag -l)"

echo "release: running make $target"
make "$target" || die "release: make $target failed; nothing was tagged"

git tag -a "$version" -m "release $version"
if ! git push "$remote" "refs/tags/$version"; then
  git tag -d "$version" >/dev/null
  die "release: push to $remote failed; the local tag was removed"
fi

echo "release: pushed $version; release.yml builds it"
