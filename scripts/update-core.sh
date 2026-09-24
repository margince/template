#!/usr/bin/env bash
# update-core.sh — move core/ to a core release tag and record it in instance.yaml.
#
# Instances pin core releases only (design Section 11). A branch or a commit
# names no release, so instance.yaml could not name it either, and
# `make check-instance` would refuse the result. Refusing here says so first.
#
# Usage: bash scripts/update-core.sh <tag>   (or: make update-core REF=<tag>)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_core

ref="${1:-}"
[ -n "$ref" ] || die "update-core: pass a core release tag, e.g. make update-core REF=v0.0.3"

# Fetches origin main with tags, then refuses a core/ that holds work of its own.
bash "$ROOT/scripts/core-contrib.sh" guard-update

git -C "$CORE" rev-parse -q --verify "refs/tags/$ref^{commit}" >/dev/null \
  || die "update-core: '$ref' is not a core release tag. Instances pin releases only; list them with: git -C core tag --list 'v*'"

git -C "$CORE" checkout -q --detach "refs/tags/$ref"
rewrite_file_in_place "$ROOT/instance.yaml" "s|^core: .*|core: $ref|"
printf 'update-core: core/ is at %s (%s); instance.yaml records it.\n' "$ref" "$(git -C "$CORE" rev-parse --short HEAD)"
