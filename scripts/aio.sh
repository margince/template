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

# ── smoke ──

SMOKE_C=""
SMOKE_V=""
smoke_cleanup() {
  [ -n "$SMOKE_C" ] || return 0
  docker rm -f -v "$SMOKE_C" >/dev/null 2>&1 || true
  docker volume rm -f "$SMOKE_V" >/dev/null 2>&1 || true
}

smoke_fail() {
  printf 'aio-smoke: FAIL: %s\n' "$*" >&2
  printf '\n--- last 100 log lines of %s ---\n' "$SMOKE_C" >&2
  docker logs --tail 100 "$SMOKE_C" >&2 2>&1 || true
  exit 1
}

smoke_wait_healthy() {
  local timeout="${AIO_SMOKE_TIMEOUT:-600}" i status state
  for ((i = 0; i < timeout; i += 5)); do
    status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$SMOKE_C" 2>/dev/null || true)"
    [ "$status" = healthy ] && return 0
    state="$(docker inspect -f '{{.State.Status}}' "$SMOKE_C" 2>/dev/null || true)"
    [ "$state" = exited ] && smoke_fail "the container exited"
    sleep 5
  done
  smoke_fail "the container was not healthy within ${timeout}s (last status: ${status:-none})"
}

# smoke_login <url> — HTTP status of a sign-in as admin@localhost with the
# generated password, or the seeded one. The password goes on stdin.
smoke_login() {
  local url="$1" password code
  password="$(docker exec "$SMOKE_C" sed -n 's/^MARGINCE_ADMIN_PASSWORD=//p' /data/secrets.env)"
  for pw in "$password" demo-password-123; do
    code="$(printf '{"email":"admin@localhost","password":"%s"}' "$pw" \
      | curl -s -o /dev/null -w '%{http_code}' --max-time 10 -X POST \
          -H 'Content-Type: application/json' --data-binary @- "$url/v1/auth/login")"
    [ "$code" = 200 ] && { printf '200\n'; return 0; }
  done
  printf '%s\n' "$code"
}

cmd_smoke() {
  local version="${1:-}" image url port code before after
  require_version "$version"
  image="$(aio_image "$version")"
  docker image inspect "$image" >/dev/null 2>&1 \
    || die "aio-smoke: no image $image — run make aio VERSION=$version first"

  SMOKE_C="margince-aio-smoke-$$"
  SMOKE_V="$SMOKE_C-data"
  trap smoke_cleanup EXIT

  say "smoke: starting $image"
  docker run -d --name "$SMOKE_C" -p 127.0.0.1::80 -v "$SMOKE_V:/data" "$image" >/dev/null
  smoke_wait_healthy
  port="$(docker port "$SMOKE_C" 80/tcp | head -n1 | sed 's/.*://')"
  url="http://127.0.0.1:$port"

  curl -fsS --max-time 10 "$url/" | grep -qi '<html' || smoke_fail "/ does not serve the web app"
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$url/readyz")"
  [ "$code" = 404 ] || smoke_fail "/readyz answered $code through nginx, want 404"
  code="$(smoke_login "$url")"
  [ "$code" = 200 ] || smoke_fail "admin@localhost could not sign in (HTTP $code)"
  say "smoke: $url serves the app, hides /readyz, and admin@localhost signs in"

  before="$(docker exec "$SMOKE_C" sha256sum /data/secrets.env)"
  docker restart "$SMOKE_C" >/dev/null
  smoke_wait_healthy
  after="$(docker exec "$SMOKE_C" sha256sum /data/secrets.env)"
  [ "$before" = "$after" ] || smoke_fail "the restart replaced /data/secrets.env"
  code="$(smoke_login "$url")"
  [ "$code" = 200 ] || smoke_fail "admin@localhost could not sign in after a restart (HTTP $code)"
  say "smoke: a restart keeps the data"
  say "smoke: passed"
}

# ── install.sh wrappers (make aio-up and the others) ──

install_sh() { sh "$AIO_SRC/install.sh" "$@" --container "$container" --volume "$volume"; }

cmd_up() {
  local version="${1:-}"
  require_version "$version"
  install_sh up --image "$(aio_image "$version")"
}

# ── install scripts ──

cmd_scripts() {
  local version="${1:-}" out f
  require_version "$version"
  out="$ROOT/dist/aio/$version"
  mkdir -p "$out"
  for f in install.sh install.ps1; do
    sed -e "s|@IMAGE@|$(aio_image "$version")|g" -e "s|@CONTAINER@|$container|g" -e "s|@VOLUME@|$volume|g" \
      "$AIO_SRC/$f" > "$out/$f"
    if grep -qE '@(IMAGE|CONTAINER|VOLUME)@' "$out/$f"; then die "aio-scripts: a placeholder is left in $out/$f"; fi
  done
  chmod 755 "$out/install.sh"
  say "wrote $out/install.sh and $out/install.ps1 for $(aio_image "$version")"
}

case "${1:-}" in
  build) shift; cmd_build "$@" ;;
  smoke) shift; cmd_smoke "$@" ;;
  scripts) shift; cmd_scripts "$@" ;;
  up)      shift; cmd_up "$@" ;;
  down|reset|logins|logs) install_sh "$1" --image "$(aio_image v0.0.0)" ;;
  *) die "usage: bash scripts/aio.sh build|smoke|scripts|up <version> | down|reset|logins|logs" ;;
esac
