#!/usr/bin/env bash
# smoke.sh <version> — start the three role images and check that they answer.
#
# The images must already be in the local Docker image store (`make package
# VERSION=<version>`). The smoke test runs them the way core's deployment guide
# (core/docs/deployment.md) describes, in its order of operations:
#
#   1. A private network margince-smoke-<random>, PostgreSQL and Redis on it,
#      from the images the host adapter pins (scripts/deploy/host/compose.yaml,
#      the same digests as core's docker-compose.dev.yml).
#   2. The database bootstrap, core/scripts/deploy/db-bootstrap.sql, run once as
#      the superuser: the owner role, the app role, the database, the extensions.
#   3. api (its entrypoint migrates as the owner role, then serves as the app
#      role), polled on /readyz until 200.
#   4. worker and web, at the same release. web must answer / with 200; the
#      worker must still be running after SMOKE_SETTLE seconds.
#
# Every container and the network are removed on exit, on success and on
# failure. On failure the last 100 log lines of each Margince container are
# printed first.
#
# The database passwords, and the vault, connector-state and webhook keys, are
# random per run. They reach the containers through `docker run -e NAME` (the
# value comes from this process's environment), so no password, DSN or key
# appears in a command line. The three keys are what make /readyz exercise the
# keyvault probe (core/docs/reference/configuration.md, "Secret vault") instead
# of running with no vault, the way earlier releases of this test did.
#
# Environment:
#   SMOKE_TIMEOUT  seconds to wait for each of PostgreSQL, api /readyz, web / (default 180)
#   SMOKE_SETTLE   seconds the worker must stay running after start (default 10)
#   REGISTRY       registry prefix of the image names (see image_repo in lib.sh)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# The postgres and redis images of the host adapter's compose file: one pin,
# checked against core by scripts/deploy/host/render.test.sh.
compose_image() {
  awk -v svc="  $1:" '$0 == svc { f = 1; next } f && $1 == "image:" { print $2; exit }' \
    "$(dirname "${BASH_SOURCE[0]}")/deploy/host/compose.yaml"
}
PG_IMAGE="$(compose_image postgres)"
REDIS_IMAGE="$(compose_image redis)"
[ -n "$PG_IMAGE" ] && [ -n "$REDIS_IMAGE" ] || { echo "smoke: cannot read the postgres/redis images from scripts/deploy/host/compose.yaml" >&2; exit 1; }

VERSION="${1:-}"
is_release_version "$VERSION" \
  || die "smoke: VERSION must match $RELEASE_VERSION_RE (got '${VERSION}'). Usage: make smoke VERSION=vX.Y.Z"

SMOKE_TIMEOUT="${SMOKE_TIMEOUT:-180}"
SMOKE_SETTLE="${SMOKE_SETTLE:-10}"
[[ "$SMOKE_TIMEOUT" =~ ^[1-9][0-9]*$ ]] || die "smoke: SMOKE_TIMEOUT must be a positive number of seconds"
[[ "$SMOKE_SETTLE" =~ ^[0-9]+$ ]] || die "smoke: SMOKE_SETTLE must be a number of seconds"

BOOTSTRAP_SQL="$CORE/scripts/deploy/db-bootstrap.sql"
[ -f "$BOOTSTRAP_SQL" ] || die "smoke: $BOOTSTRAP_SQL not found — run 'make init'"
command -v docker >/dev/null || die "smoke: docker is not installed"
command -v curl >/dev/null || die "smoke: curl is not installed"

repo="$(image_repo)" || exit 1
API_IMAGE="$repo/api:$VERSION"
WORKER_IMAGE="$repo/worker:$VERSION"
WEB_IMAGE="$repo/web:$VERSION"

# All three images, before anything starts.
missing=""
for image in "$API_IMAGE" "$WORKER_IMAGE" "$WEB_IMAGE"; do
  docker image inspect "$image" >/dev/null 2>&1 || missing="$missing $image"
done
[ -z "$missing" ] || die "smoke: image(s) not found locally:$missing — run 'make package VERSION=$VERSION' first"

rand() { od -An -N"$1" -tx1 /dev/urandom | tr -d ' \n'; }

# b64_32 — 32 random bytes as standard base64, the same shape gen-env.sh writes
# for MARGINCE_KEYVAULT_ROOT_KEY and MARGINCE_WEBHOOK_KEY.
b64_32() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 32 | tr -d '\n'
  else
    dd if=/dev/urandom bs=32 count=1 2>/dev/null | base64 | tr -d '\n'
  fi
}

PREFIX="margince-smoke-$(rand 4)"
NET="$PREFIX"
PG="$PREFIX-pg"
REDIS="$PREFIX-redis"
API="$PREFIX-api"
WORKER="$PREFIX-worker"
WEB="$PREFIX-web"

STARTED=""         # every container name docker run was asked to create
MARGINCE_STARTED="" # the Margince ones, whose logs a failure prints
NET_CREATED=0
CFG_DIR=""

cleanup() {
  local rc=$?
  set +e
  if [ "$rc" -ne 0 ]; then
    local c
    for c in $MARGINCE_STARTED; do
      printf '\n--- docker logs --tail 100 %s ---\n' "$c" >&2
      docker logs --tail 100 "$c" >&2 2>&1
    done
  fi
  # shellcheck disable=SC2086 # the names contain no spaces
  [ -n "$STARTED" ] && docker rm -f $STARTED >/dev/null 2>&1
  [ "$NET_CREATED" = 1 ] && docker network rm "$NET" >/dev/null 2>&1
  [ -n "$CFG_DIR" ] && rm -rf "$CFG_DIR"
  if [ "$rc" -ne 0 ]; then
    printf '\nsmoke: FAILED (%s %s)\n' "$repo" "$VERSION" >&2
  fi
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# start <name> <margince:0|1> <docker run args...>
start() {
  local name="$1" margince="$2"; shift 2
  STARTED="$STARTED $name"
  [ "$margince" = 1 ] && MARGINCE_STARTED="$MARGINCE_STARTED $name"
  docker run -d --name "$name" --network "$NET" "$@" >/dev/null
}

running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" = true ]; }

# published <container> — host:port of the container's 8080, bound to 127.0.0.1.
published() { docker port "$1" 8080/tcp | sed -n 1p; }

# wait_for <what> <container> <command...> — until the command succeeds, the
# container stops running, or SMOKE_TIMEOUT passes.
wait_for() {
  local what="$1" container="$2"; shift 2
  local deadline=$((SECONDS + SMOKE_TIMEOUT))
  while :; do
    "$@" >/dev/null 2>&1 && return 0
    running "$container" || die "smoke: $container stopped while waiting for $what"
    [ "$SECONDS" -lt "$deadline" ] || die "smoke: $what not reached within ${SMOKE_TIMEOUT}s"
    sleep 1
  done
}

http_ok() { curl -fsS -o /dev/null --max-time 5 "$1"; }

# Throwaway credentials for this run only.
export POSTGRES_PASSWORD SMOKE_OWNER_PW SMOKE_APP_PW
POSTGRES_PASSWORD="$(rand 16)"
SMOKE_OWNER_PW="$(rand 16)"
SMOKE_APP_PW="$(rand 16)"

# The api and worker environment (core/docs/deployment.md, "Configuration").
export MARGINCE_OWNER_DSN MARGINCE_DSN MARGINCE_REDIS MARGINCE_ENV MARGINCE_CONFIG MARGINCE_ADMIN_PASSWORD
export MARGINCE_KEYVAULT_ROOT_KEY MARGINCE_CONNECTOR_STATE_KEY MARGINCE_WEBHOOK_KEY
MARGINCE_OWNER_DSN="postgres://margince_owner:$SMOKE_OWNER_PW@$PG:5432/margince"
MARGINCE_DSN="postgres://margince_app:$SMOKE_APP_PW@$PG:5432/margince"
MARGINCE_REDIS="$REDIS:6379"
# Non-production posture: the smoke test runs without a license, which a
# production posture refuses (core/docs/reference/configuration.md, "License").
MARGINCE_ENV=test
MARGINCE_CONFIG=/app/config/margince.yaml
MARGINCE_ADMIN_PASSWORD="$(rand 16)"
# The vault, connector-state and webhook keys (constraints.md formats): with
# MARGINCE_KEYVAULT_ROOT_KEY set, the api gains the /readyz keyvault probe
# instead of booting with no vault at all.
MARGINCE_KEYVAULT_ROOT_KEY="$(b64_32)"
MARGINCE_CONNECTOR_STATE_KEY="$(rand 32)"
MARGINCE_WEBHOOK_KEY="$(b64_32)"

# The first-boot configuration: an empty database needs workspace and
# bootstrap_admin. password_file is where the api entrypoint writes
# MARGINCE_ADMIN_PASSWORD. It holds no secret, so it is world-readable for the
# container's own user.
CFG_DIR="$(mktemp -d)"
chmod 755 "$CFG_DIR"
cat > "$CFG_DIR/margince.yaml" <<'EOF'
version: 1
workspace:
  name: Smoke Test
  base_currency: EUR
  timezone: Europe/Berlin
bootstrap_admin:
  email: admin@smoke.test
  display_name: Smoke Admin
  password_file: secrets/admin-password
EOF
chmod 644 "$CFG_DIR/margince.yaml"

printf 'smoke: %s/{api,worker,web}:%s on network %s\n' "$repo" "$VERSION" "$NET"

docker network create "$NET" >/dev/null
NET_CREATED=1

start "$PG" 0 -e POSTGRES_PASSWORD "$PG_IMAGE"
start "$REDIS" 0 "$REDIS_IMAGE"

# Over TCP: the image's init phase serves on the socket only, then restarts.
wait_for "PostgreSQL" "$PG" docker exec "$PG" pg_isready -q -h 127.0.0.1 -U postgres

printf 'smoke: bootstrapping the database\n'
{
  printf '\\getenv owner_pw SMOKE_OWNER_PW\n\\getenv app_pw SMOKE_APP_PW\n'
  cat "$BOOTSTRAP_SQL"
} | docker exec -i -e SMOKE_OWNER_PW -e SMOKE_APP_PW "$PG" \
      psql -q -v ON_ERROR_STOP=1 -U postgres -d postgres >/dev/null

printf 'smoke: starting api\n'
start "$API" 1 -p 127.0.0.1::8080 \
  -e MARGINCE_OWNER_DSN -e MARGINCE_DSN -e MARGINCE_REDIS -e MARGINCE_ENV \
  -e MARGINCE_CONFIG -e MARGINCE_ADMIN_PASSWORD \
  -e MARGINCE_KEYVAULT_ROOT_KEY -e MARGINCE_CONNECTOR_STATE_KEY -e MARGINCE_WEBHOOK_KEY \
  -v "$CFG_DIR/margince.yaml:/app/config/margince.yaml:ro" \
  "$API_IMAGE"
api_addr="$(published "$API")"
[ -n "$api_addr" ] || die "smoke: api has no published port"
wait_for "api /readyz" "$API" http_ok "http://$api_addr/readyz"
printf 'smoke: api is ready\n'

printf 'smoke: starting worker and web\n'
start "$WORKER" 1 -e MARGINCE_DSN -e MARGINCE_REDIS -e MARGINCE_ENV \
  -e MARGINCE_KEYVAULT_ROOT_KEY -e MARGINCE_CONNECTOR_STATE_KEY -e MARGINCE_WEBHOOK_KEY \
  "$WORKER_IMAGE"
start "$WEB" 1 -p 127.0.0.1::8080 "$WEB_IMAGE"
web_addr="$(published "$WEB")"
[ -n "$web_addr" ] || die "smoke: web has no published port"
wait_for "web /" "$WEB" http_ok "http://$web_addr/"
printf 'smoke: web answers /\n'

[ "$SMOKE_SETTLE" -gt 0 ] && sleep "$SMOKE_SETTLE"
running "$WORKER" || die "smoke: worker is not running"
printf 'smoke: worker is running\n'

printf 'smoke: passed (%s %s)\n' "$repo" "$VERSION"
