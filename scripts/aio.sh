#!/usr/bin/env bash
# aio.sh — the all-in-one image
# (docs/superpowers/specs/2026-09-30-all-in-one-image-design.md).
#
#   build <v>    make aio: assemble build/aio/ and build <repo>/all-in-one:<v>.
#                Runs make package first when a role image is missing.
#                PUSH=1 (needs REGISTRY) pushes linux/amd64 and linux/arm64
#                (AIO_PLATFORMS) from the pushed role images. DATASET=<checkout>
#                includes the demo dataset and its seeder. METADATA_FILE=<path>
#                writes buildx's metadata file.
#   smoke <v>    make aio-smoke: run the image on a temporary volume and check it.
#   scripts <v>  make aio-scripts: write dist/aio/<v>/install.sh and install.ps1.
#   up <v>, down, reset, logins, logs
#                make aio-up and the others: run scripts/aio/install.sh with
#                this instance's image, container and volume.
#
# Usage: bash scripts/aio.sh <command> [<version>]
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

AIO_SRC="$ROOT/scripts/aio"
CONTEXT="$ROOT/build/aio"

say() { printf 'aio: %s\n' "$*"; }

name="$(instance_get name)" || die "aio: cannot read name from instance.yaml"
REPO="${REPO:-$(image_repo)}"
container="margince-$name"
volume="margince-$name-data"

aio_image() { printf '%s/all-in-one:%s\n' "$REPO" "$1"; }

require_version() {
  is_release_version "${1:-}" \
    || die "aio: pass VERSION=<release version>, e.g. make aio VERSION=v0.1.0 (got '${1:-}')"
}

# ── build ──

include_dataset() {
  if [ -z "${DATASET:-}" ]; then
    say "notice: no DATASET, so the image has no demo data. DATASET=<checkout> includes it."
    return 0
  fi
  local dataset currency
  dataset="$(dataset_path "$DATASET")"
  [ -f "$dataset/datasets/v1/demo.json" ] \
    || die "aio: no demo dataset at $dataset (expected datasets/v1/demo.json inside it)"
  currency="$(sed -n 's/^[[:space:]]*base_currency:[[:space:]]*\([A-Za-z]\{3\}\).*/\1/p' "$CONTEXT/margince.yaml" | head -n1)"
  if [ "$currency" != EUR ]; then
    say "notice: the workspace's base_currency is ${currency:-unset} and the demo dataset is euro-based, so the image has no demo data."
    return 0
  fi
  if ! ( DATASET="$dataset"
         # shellcheck source=scripts/desktop.sh
         source "$ROOT/scripts/desktop.sh"
         build_seeder linux-amd64 "$CONTEXT/seed/seed-demo-amd64"
         build_seeder linux-arm64 "$CONTEXT/seed/seed-demo-arm64" ); then
    rm -f "$CONTEXT"/seed/*
    say "notice: the dataset has no seeder (tools/seed-demo), so the image has no demo data."
    return 0
  fi
  tar -C "$dataset" --exclude=./.git --exclude=./tools -cf - . | tar -C "$CONTEXT/demo" -xf -
  say "the image includes the demo dataset from $dataset"
}

assemble_context() {
  local display
  rm -rf "$CONTEXT"
  mkdir -p "$CONTEXT/seed" "$CONTEXT/demo"
  cp "$AIO_SRC/Dockerfile" "$AIO_SRC/nginx.conf" "$AIO_SRC/margince-init" \
     "$AIO_SRC/margince-seed" "$AIO_SRC/margince-logins" "$CONTEXT/"
  cp "$CORE/scripts/deploy/db-bootstrap.sql" "$CONTEXT/"
  display="$(instance_get display_name)" || die "aio: cannot read display_name from instance.yaml"
  cli_run aio-config -file "$ROOT/deploy/production/config/margince.yaml" -display-name "$display" \
    > "$CONTEXT/margince.yaml" || die "aio: could not write the image's margince.yaml"
  include_dataset
}

cmd_build() {
  local version="${1:-}" role missing=no
  require_version "$version"
  command -v docker >/dev/null || die "aio: docker is not installed"
  docker buildx version >/dev/null 2>&1 || die "aio: docker buildx is required"

  local output=(--load)
  if [ "${PUSH:-}" = "1" ]; then
    [ -n "${REGISTRY:-}" ] || die "aio: PUSH=1 requires REGISTRY (the registry host the image is pushed to)"
    output=(--push --platform "${AIO_PLATFORMS:-linux/amd64,linux/arm64}")
  else
    for role in api web worker; do
      docker image inspect "$REPO/$role:$version" >/dev/null 2>&1 || missing=yes
    done
    if [ "$missing" = yes ]; then
      say "a role image of $version is missing; running make package VERSION=$version"
      make -C "$ROOT" package VERSION="$version"
    fi
  fi
  [ -n "${METADATA_FILE:-}" ] && output+=(--metadata-file "$METADATA_FILE")

  assemble_context

  local revision core_revision core_version units
  revision="$(git -C "$ROOT" rev-parse HEAD)"
  core_revision="$(git -C "$CORE" rev-parse HEAD)"
  core_version="$(instance_get core)"
  units="$(source_units | tr '\n' ' ')"

  say "building $(aio_image "$version")"
  docker buildx build "${output[@]}" \
    --build-arg API_IMAGE="$REPO/api:$version" --build-arg WORKER_IMAGE="$REPO/worker:$version" --build-arg WEB_IMAGE="$REPO/web:$version" \
    --build-arg VERSION="$version" \
    --label "org.opencontainers.image.revision=$revision" \
    --label "com.margince.instance.name=$name" \
    --label "com.margince.instance.revision=$revision" \
    --label "com.margince.core.revision=$core_revision" \
    --label "com.margince.core.version=$core_version" \
    --label "com.margince.instance.units=${units% }" \
    -t "$(aio_image "$version")" "$CONTEXT"
  say "built $(aio_image "$version")"
}

case "${1:-}" in
  build) shift; cmd_build "$@" ;;
  *) die "usage: bash scripts/aio.sh build|smoke|scripts|up <version> | down|reset|logins|logs" ;;
esac
