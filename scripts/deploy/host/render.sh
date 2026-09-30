#!/usr/bin/env bash
# deploy/host/render.sh — build the files of one host adapter deployment
# locally (design Section 9.6), in two parts:
#
#   <out-dir>/release/  upload to $HOST_DIR/releases/<v>/
#   <out-dir>/shared/   upload to $HOST_DIR/shared/ (next to data.env)
#
# Reads DEPLOY_DIR (deploy/<env>/), INSTANCE_NAME, IMAGE_API, IMAGE_WEB and
# IMAGE_WORKER, which scripts/deploy.sh exports, and the environment. Writes:
#
#   release/compose.yaml          copied from scripts/deploy/host/
#   release/config/margince.yaml  copied from DEPLOY_DIR
#   release/.env                  mode 600; read by the api and worker
#                                 containers (compose `format: raw`)
#   release/compose.env           the compose interpolation variables; no secret
#   release/nginx/default.conf.template  copied from scripts/deploy/host/
#                                 nginx.conf.template; routing and rate limits
#   shared/db-init.sh             copied from scripts/deploy/host/ (mode 755)
#   shared/gen-env.sh             copied from scripts/deploy/host/ (mode 755);
#                                 apply runs it to create data.env and
#                                 instance.env once; not installed
#   shared/db-bootstrap.sql       copied from core/scripts/deploy/
#   shared/caddy/Caddyfile        copied from scripts/deploy/host/
#
# The shared files are the only files the postgres and caddy services mount,
# so a new release does not recreate them. A changed shared/caddy/Caddyfile
# needs `caddy reload` in the running caddy container.
#
# .env holds one NAME=value line, written exactly, for:
#   - each name in DEPLOY_DIR/secrets (blank lines and # comments skipped);
#     the value comes from this process's environment;
#   - MARGINCE_DSN, MARGINCE_REDIS and MARGINCE_OWNER_DSN, when MARGINCE_DSN and
#     MARGINCE_REDIS are both set (external database and Redis);
#   - MARGINCE_PUBLIC_BASE_URL=https://<HOST_DOMAIN>, unless secrets lists it;
#   - MARGINCE_BLOBSTORE_PATH=/app/data/blobs (the default file store), unless
#     secrets lists it or MARGINCE_BLOBSTORE_ENDPOINT;
#   - INSTANCE_NAME, IMAGE_API, IMAGE_WEB, IMAGE_WORKER, HOST_DOMAIN,
#     API_REPLICAS, WORKER_REPLICAS, AUTH_RATE_LIMIT_PER_MINUTE, COMPOSE_PROFILES.
# compose.env holds the last group only.
#
# release/compose.yaml is the template unchanged, except when secrets lists
# MARGINCE_BLOBSTORE_ENDPOINT (S3 or compatible): then the blocks between the
# "# >>> default file store" and "# <<< default file store" lines (the blobs
# volume, its mounts, the blobs-init service) are left out.
#
# The generated keys (instance.env) are not written here; a name in secrets
# that is also in instance.env wins because .env is read last.
#
# COMPOSE_PROFILES is `local-data` (the compose file's postgres and redis
# services) unless MARGINCE_DSN and MARGINCE_REDIS are both set; then it is
# empty. HOST_DOMAIN, API_REPLICAS, WORKER_REPLICAS and AUTH_RATE_LIMIT_PER_MINUTE come from
# DEPLOY_DIR/host.env (replicas default 1, the rate limit 30 per minute).
#
# A listed name without a value, or a value with a newline or a carriage
# return, exits 1 naming the
# variable. No value is ever printed. On any failure the output directory is
# removed again, so no partial .env remains.
#
# Usage: bash scripts/deploy/host/render.sh <out-dir>   (<out-dir> absent or empty)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HOST_FILES="$ROOT/scripts/deploy/host"
BOOTSTRAP_SQL="$CORE/scripts/deploy/db-bootstrap.sql"

# The names render.sh writes itself. A secret of the same name would be
# written twice, and the later line would silently win.
GENERATED="INSTANCE_NAME IMAGE_API IMAGE_WEB IMAGE_WORKER HOST_DOMAIN API_REPLICAS WORKER_REPLICAS AUTH_RATE_LIMIT_PER_MINUTE COMPOSE_PROFILES"

out="${1:-}"
[ -n "$out" ] || die "render: pass the output directory: bash scripts/deploy/host/render.sh <out-dir>"
if [ -e "$out" ]; then
  [ -d "$out" ] || die "render: $out exists and is not a directory"
  [ -z "$(ls -A "$out")" ] || die "render: $out is not empty"
fi

for v in DEPLOY_DIR INSTANCE_NAME IMAGE_API IMAGE_WEB IMAGE_WORKER; do
  [ -n "${!v:-}" ] || die "render: $v is not set (run through scripts/deploy.sh)"
done
[[ "$INSTANCE_NAME" =~ ^[a-z0-9][a-z0-9-]*$ ]] || die "render: INSTANCE_NAME '$INSTANCE_NAME' is not a valid name"
for v in IMAGE_API IMAGE_WEB IMAGE_WORKER; do
  [[ "${!v}" =~ ^[A-Za-z0-9][A-Za-z0-9._/:@-]*$ ]] || die "render: $v '${!v}' is not an image reference"
done

[ -f "$DEPLOY_DIR/config/margince.yaml" ] || die "render: $DEPLOY_DIR/config/margince.yaml not found"
[ -f "$DEPLOY_DIR/secrets" ] || die "render: $DEPLOY_DIR/secrets not found (one environment variable name per line)"
[ -f "$BOOTSTRAP_SQL" ] || die "render: $BOOTSTRAP_SQL not found; run 'make init'"

domain="$(host_env_get HOST_DOMAIN)" || die "render: HOST_DOMAIN is not set in $DEPLOY_DIR/host.env"
[[ "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] ||
  die "render: HOST_DOMAIN in $DEPLOY_DIR/host.env is not a host name: '$domain'"
api_replicas="$(host_env_get API_REPLICAS 1)"
worker_replicas="$(host_env_get WORKER_REPLICAS 1)"
[[ "$api_replicas" =~ ^[1-9][0-9]*$ ]] || die "render: API_REPLICAS in $DEPLOY_DIR/host.env must be a positive number"
[[ "$worker_replicas" =~ ^[1-9][0-9]*$ ]] || die "render: WORKER_REPLICAS in $DEPLOY_DIR/host.env must be a positive number"
auth_rate="$(host_env_get AUTH_RATE_LIMIT_PER_MINUTE 30)"
[[ "$auth_rate" =~ ^[1-9][0-9]*$ ]] || die "render: AUTH_RATE_LIMIT_PER_MINUTE in $DEPLOY_DIR/host.env must be a positive number"

external=0
if [ -n "${MARGINCE_DSN:-}" ] && [ -n "${MARGINCE_REDIS:-}" ]; then
  external=1
  [ -n "${MARGINCE_OWNER_DSN:-}" ] ||
    die "render: MARGINCE_DSN and MARGINCE_REDIS are set (external database and Redis), so MARGINCE_OWNER_DSN must be set too: the api migrates as the owner role"
  profiles=""
else
  profiles="local-data"
fi

# The names, in order, each once.
names=""
has_name() { case " $names " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }
while IFS= read -r line || [ -n "$line" ]; do
  line="${line%$'\r'}"
  line="${line#"${line%%[![:space:]]*}"}"
  line="${line%"${line##*[![:space:]]}"}"
  case "$line" in ''|'#'*) continue ;; esac
  [[ "$line" =~ ^[A-Z_][A-Z0-9_]*$ ]] ||
    die "render: '$line' in $DEPLOY_DIR/secrets is not an environment variable name (A-Z, 0-9, _)"
  case " $GENERATED " in
    *" $line "*) die "render: $DEPLOY_DIR/secrets lists $line, which render.sh sets itself; remove it" ;;
  esac
  has_name "$line" || names="$names $line"
done < "$DEPLOY_DIR/secrets"
if [ "$external" = 1 ]; then
  for v in MARGINCE_DSN MARGINCE_REDIS MARGINCE_OWNER_DSN; do
    has_name "$v" || names="$names $v"
  done
fi

missing=""
for name in $names; do
  value="${!name-}"
  if [ -z "$value" ]; then
    missing="$missing $name"
    continue
  fi
  case "$value" in
    *$'\n'*|*$'\r'*) die "render: the value of $name contains a newline or a carriage return; a .env line cannot hold it" ;;
  esac
done
[ -z "$missing" ] || die "render: no value in the environment for:$missing (listed in $DEPLOY_DIR/secrets)"

# The default file store, unless the client configures S3 (or compatible).
blob_endpoint=0
has_name MARGINCE_BLOBSTORE_ENDPOINT && blob_endpoint=1

# From here on files are written; a failure removes the output directory.
created=0
[ -d "$out" ] || created=1
cleanup() {
  local rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$created" = 1 ]; then rm -rf "$out"; else find "$out" -mindepth 1 -delete 2>/dev/null || true; fi
  fi
  exit "$rc"
}
trap cleanup EXIT
rel="$out/release"
shr="$out/shared"
mkdir -p "$rel/config" "$rel/nginx" "$shr/caddy"
chmod 755 "$out" "$rel" "$rel/config" "$rel/nginx" "$shr" "$shr/caddy"

# generated_lines — the variables render.sh sets itself, NAME=value.
generated_lines() {
  printf '%s=%s\n' \
    INSTANCE_NAME "$INSTANCE_NAME" \
    IMAGE_API "$IMAGE_API" \
    IMAGE_WEB "$IMAGE_WEB" \
    IMAGE_WORKER "$IMAGE_WORKER" \
    HOST_DOMAIN "$domain" \
    API_REPLICAS "$api_replicas" \
    WORKER_REPLICAS "$worker_replicas" \
    AUTH_RATE_LIMIT_PER_MINUTE "$auth_rate" \
    COMPOSE_PROFILES "$profiles"
}

(
  umask 077
  {
    for name in $names; do
      printf '%s=%s\n' "$name" "${!name}"
    done
    has_name MARGINCE_PUBLIC_BASE_URL || printf '%s=%s\n' MARGINCE_PUBLIC_BASE_URL "https://$domain"
    [ "$blob_endpoint" = 1 ] || has_name MARGINCE_BLOBSTORE_PATH || printf '%s=%s\n' MARGINCE_BLOBSTORE_PATH /app/data/blobs
    generated_lines
  } > "$rel/.env"
)
chmod 600 "$rel/.env"

generated_lines > "$rel/compose.env"
if [ "$blob_endpoint" = 1 ]; then
  # Drop the default file store blocks; an unbalanced marker is an error.
  awk '
    /^[[:space:]]*# >>> default file store[[:space:]]*$/ { if (skip) exit 3; skip = 1; next }
    /^[[:space:]]*# <<< default file store[[:space:]]*$/ { if (!skip) exit 3; skip = 0; next }
    !skip { print }
    END { if (skip) exit 3 }
  ' "$HOST_FILES/compose.yaml" > "$rel/compose.yaml" || die "render: the default file store markers in $HOST_FILES/compose.yaml are not balanced"
else
  cp "$HOST_FILES/compose.yaml" "$rel/compose.yaml"
fi
cp "$DEPLOY_DIR/config/margince.yaml" "$rel/config/margince.yaml"
cp "$HOST_FILES/Caddyfile" "$shr/caddy/Caddyfile"
cp "$HOST_FILES/nginx.conf.template" "$rel/nginx/default.conf.template"
chmod 644 "$rel/nginx/default.conf.template"
cp "$HOST_FILES/db-init.sh" "$shr/db-init.sh"
cp "$HOST_FILES/gen-env.sh" "$shr/gen-env.sh"
cp "$BOOTSTRAP_SQL" "$shr/db-bootstrap.sql"
chmod 644 "$rel/compose.env" "$rel/compose.yaml" "$rel/config/margince.yaml" "$shr/caddy/Caddyfile" "$shr/db-bootstrap.sql"
chmod 755 "$shr/db-init.sh" "$shr/gen-env.sh"

if [ "$blob_endpoint" = 1 ]; then store="file store: MARGINCE_BLOBSTORE_ENDPOINT"; else store="file store: the blobs volume"; fi
if [ "$external" = 1 ]; then
  echo "render: $out (external database and Redis; COMPOSE_PROFILES empty; $store)"
else
  echo "render: $out (COMPOSE_PROFILES=local-data; $store)"
fi
