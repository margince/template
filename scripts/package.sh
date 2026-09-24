#!/usr/bin/env bash
# package.sh — build this instance's role images, with our units inside.
#
# The images come out of CORE's Dockerfile and docker-bake.hcl, which is the
# point: the three role images (api, worker, web) are upstream's build, and our
# units reach them the same way they reach every other lane — staging puts them
# under core/extensions/, and the Dockerfile's own gen-composition step folds
# them in. There is no second build definition here to drift from upstream's.
#
# WHAT IDENTIFIES THE ARTIFACT is this repository's commit, not core's. A core
# SHA names the upstream half; an instance image is core PLUS a unit set
# PLUS a submodule pointer, and only this repo's commit names all three. The
# core SHA rides along as a label so the pair is readable off the image.
#
# Refuses to build from a dirty tree unless told otherwise: an image tagged with
# a commit it does not contain is worse than no tag at all.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_core

command -v docker >/dev/null || die "package: docker is not installed"
docker buildx version >/dev/null 2>&1 || die "package: docker buildx is required (it drives core's bake file)"

REPO="${REPO:-$(image_repo)}"
instance_name="$(instance_get name)"
# Read here, before `cd "$CORE"`: the release tag instance.yaml records.
core_version="$(instance_get core)"
ROLE="${ROLE:-}"

revision="$(git -C "$ROOT" rev-parse HEAD)"
core_revision="$(git -C "$CORE" rev-parse HEAD)"
dirty=""
[ -n "$(git -C "$ROOT" status --porcelain)" ] && dirty="-dirty"

if [ -z "${VERSION:-}" ]; then
  # A tag if this commit has one, else a short SHA. Same shape core's own
  # default has, so a local image reads like a release image with `dev` swapped
  # for something that identifies the tree.
  VERSION="$(git -C "$ROOT" describe --tags --exact-match 2>/dev/null || true)"
  [ -n "$VERSION" ] || VERSION="$(git -C "$ROOT" rev-parse --short HEAD)$dirty"
fi

if [ -n "$dirty" ] && [ "${ALLOW_DIRTY:-}" != "1" ]; then
  printf 'package: refusing to build — this repository has uncommitted changes.\n' >&2
  printf '\n' >&2
  git -C "$ROOT" status --short >&2
  printf '\nAn image tagged %s would not contain what that name says. Commit first,\n' "$VERSION" >&2
  printf 'or re-run with ALLOW_DIRTY=1 for a throwaway build.\n' >&2
  exit 1
fi

# The unit set going in, named before a long build rather than discovered after.
units="$(source_units | tr '\n' ' ')"
printf 'package: %s/{api,worker,web}:%s\n' "$REPO" "$VERSION"
printf '  instance      %s\n' "$revision"
printf '  core         %s\n' "$core_revision"
printf '  units        %s\n' "${units:-none}"
printf '\n'

# Bake runs in core/, whose whole tree is the build context — the composed
# workspace references ../backend and ../extensions/* by relative path, so a
# partial context cannot compose.
cd "$CORE"
REPO="$REPO" VERSION="$VERSION" MARGINCE_BUILD_REVISION="$revision" \
  docker buildx bake \
    --set "*.labels.com.margince.instance.name=$instance_name" \
    --set "*.labels.com.margince.instance.revision=$revision" \
    --set "*.labels.com.margince.core.revision=$core_revision" \
    --set "*.labels.com.margince.core.version=$core_version" \
    --set "*.labels.com.margince.instance.units=${units% }" \
    ${ROLE:+"$ROLE"}

printf '\npackage: built. Inspect what went in:\n'
printf '  docker inspect %s/api:%s --format "{{json .Config.Labels}}"\n' "$REPO" "$VERSION"
