#!/usr/bin/env bash
# render.test.sh — scripts/deploy/host/render.sh builds one release directory,
# and scripts/deploy/host/lib.sh's host_env_get reads host.env without running it.
#
# The scratch instance holds this repository's scripts/, a stand-in
# core/scripts/deploy/db-bootstrap.sql, and deploy/prod/ with host.env,
# config/margince.yaml and secrets. Each release is rendered into
# <tmp>/r/<v>/ and then installed the way the adapter uploads it: release/ to
# <srv>/releases/<v>/, shared/ to <srv>/shared/, next to <srv>/shared/data.env,
# so the compose file's ../../shared/ paths resolve.
#
# When `docker compose` is available, the rendered compose file is checked with
# `docker compose config`, which reads files only: no daemon call, no network.
# Without Docker those cases print a notice and are skipped.
#
# compose.yaml pins postgres, redis and caddy by tag and digest. When core/ is
# checked out, the postgres and redis images must equal core's in
# core/docker-compose.dev.yml; without core/ that comparison is skipped.
#
# Usage: bash scripts/deploy/host/render.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_PREFIX
unset MARGINCE_DSN MARGINCE_REDIS MARGINCE_OWNER_DSN MARGINCE_PUBLIC_BASE_URL COMPOSE_PROFILES
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false
export GIT_AUTHOR_NAME="Test Dev"     GIT_AUTHOR_EMAIL="dev@example.test"
export GIT_COMMITTER_NAME="Test Dev"  GIT_COMMITTER_EMAIL="dev@example.test"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILURES=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }
ok()   { printf 'ok: %s\n' "$*"; }

INST="$TMP/inst"
mkdir -p "$INST/core/scripts/deploy" "$INST/deploy/prod/config"
cp -R "$SCRIPT_DIR" "$INST/scripts"
printf 'name: acme\ndisplay_name: Acme\ncore: v0.0.2\n' > "$INST/instance.yaml"
printf -- '-- stand-in bootstrap\nSELECT 1;\n' > "$INST/core/scripts/deploy/db-bootstrap.sql"
printf 'version: 1\nworkspace:\n  name: Acme\n' > "$INST/deploy/prod/config/margince.yaml"
cat > "$INST/deploy/prod/host.env" <<'EOF'
# The server.
HOST_SSH=deploy@203.0.113.10
HOST_DOMAIN=crm.example.test
WORKER_REPLICAS=3
EOF
printf '# license and bootstrap\nMARGINCE_LICENSE\n\n  MARGINCE_ADMIN_PASSWORD  \n' > "$INST/deploy/prod/secrets"

# The variables deploy.sh exports to an adapter step.
export DEPLOY_ENV=prod DEPLOY_VERSION=v1.0.0 DEPLOY_STEP=apply DEPLOY_DIR="$INST/deploy/prod"
export INSTANCE_NAME=acme IMAGE_REPO=registry.example.test/acme
export IMAGE_API=registry.example.test/acme/api:v1.0.0
export IMAGE_WEB=registry.example.test/acme/web:v1.0.0
export IMAGE_WORKER=registry.example.test/acme/worker:v1.0.0

# The secret values: spaces, $, #, and both quote characters, not leading.
LICENSE_VALUE='lic a$HOME #not-a-comment "dq" '\''sq'\'' $(id) `id` end'
ADMIN_VALUE='adm1n-pa55'
export MARGINCE_LICENSE="$LICENSE_VALUE" MARGINCE_ADMIN_PASSWORD="$ADMIN_VALUE"

SRV="$TMP/srv"
mkdir -p "$SRV/shared" "$SRV/releases"
cat > "$SRV/shared/data.env" <<'EOF'
POSTGRES_PASSWORD=pg-pa55
MARGINCE_OWNER_DSN=postgres://margince_owner:0123456789abcdef0123456789abcdef@postgres:5432/margince
MARGINCE_DSN=postgres://margince_app:fedcba9876543210fedcba9876543210@postgres:5432/margince
MARGINCE_REDIS=redis:6379
EOF
chmod 600 "$SRV/shared/data.env"
# instance.env as gen-env.sh writes it, with fixed stand-in values.
INST_VAULT='AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8='
INST_STATE='000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f'
INST_WEBHOOK='HyAhIiMkJSYnKCkqKywtLi8wMTIzNDU2Nzg5Ojs8PT4='
INST_ADMIN='GeneratedAdminPassw0rd24'
printf 'MARGINCE_KEYVAULT_ROOT_KEY=%s\nMARGINCE_CONNECTOR_STATE_KEY=%s\nMARGINCE_WEBHOOK_KEY=%s\nMARGINCE_ADMIN_PASSWORD=%s\n' \
  "$INST_VAULT" "$INST_STATE" "$INST_WEBHOOK" "$INST_ADMIN" > "$SRV/shared/instance.env"
chmod 600 "$SRV/shared/instance.env"

# service_image <compose-file> <service> — the image: value of one top-level
# service, with no variable expansion.
service_image() {
  awk -v svc="  $2:" '
    /^[^ #]/ { in_svcs = ($0 == "services:"); cur = 0; next }
    in_svcs && /^  [^ #]/ { cur = ($0 == svc); next }
    cur && /^    image:/ { sub(/^    image:[ ]*/, ""); print; exit }
  ' "$1"
}
CADDY_IMAGE="$(service_image "$SCRIPT_DIR/deploy/host/compose.yaml" caddy)"
NGINX_IMAGE="$(service_image "$SCRIPT_DIR/deploy/host/compose.yaml" nginx)"

# rendered <release-dir> — the render.sh output directory for a release.
rendered() { printf '%s/r/%s' "$TMP" "$(basename "$1")"; }

# render <release-dir> [VAR=value...] — run render.sh with extra environment
# into $(rendered <release-dir>); on success install release/ at <release-dir>
# and shared/ in $SRV/shared/. Output (stdout and stderr) in $TMP/out; prints
# the exit code. An empty <release-dir> passes no output directory.
render() {
  local dest="$1"; shift
  local rc=0 out=""
  [ -z "$dest" ] || out="$(rendered "$dest")"
  (cd "$INST" && env "$@" bash scripts/deploy/host/render.sh "$out") > "$TMP/out" 2>&1 || rc=$?
  if [ "$rc" = 0 ] && [ ! -e "$dest" ]; then
    mkdir -p "$dest"
    cp -Rp "$out/release/." "$dest/"
    cp -Rp "$out/shared/." "$SRV/shared/"
  fi
  printf '%s' "$rc"
}

mode_of() { if stat -c '%a' "$1" >/dev/null 2>&1; then stat -c '%a' "$1"; else stat -f '%Lp' "$1"; fi; }

# no_secret_printed <what> — neither secret value appears in $TMP/out.
no_secret_printed() {
  if grep -qF "$LICENSE_VALUE" "$TMP/out" || grep -qF "$ADMIN_VALUE" "$TMP/out" || grep -qF 'lic a' "$TMP/out"; then
    fail "$1 prints no secret value: $(cat "$TMP/out")"
  else
    ok "$1 prints no secret value"
  fi
}

# --- a default release ---
OUT="$SRV/releases/v1.0.0"
rc="$(render "$OUT")"
if [ "$rc" = 0 ]; then ok "render succeeds"; else fail "render succeeds (rc=$rc): $(cat "$TMP/out")"; fi
R1="$(rendered "$OUT")"
listing="$(cd "$R1" && find . -type f | sort | tr '\n' ' ')"
expected="./release/.env ./release/compose.env ./release/compose.yaml ./release/config/margince.yaml ./release/nginx/default.conf.template ./shared/caddy/Caddyfile ./shared/db-bootstrap.sql ./shared/db-init.sh ./shared/gen-env.sh "
if [ "$listing" = "$expected" ]; then ok "the output has release/ and shared/ with exactly the expected files"; else fail "the output has release/ and shared/ with exactly the expected files: $listing"; fi
if [ "$(mode_of "$R1/release/.env")" = 600 ]; then ok ".env has mode 600"; else fail ".env has mode 600 (got $(mode_of "$R1/release/.env"))"; fi
for f in release/compose.yaml release/config/margince.yaml release/compose.env release/nginx/default.conf.template shared/caddy/Caddyfile shared/db-bootstrap.sql; do
  if [ "$(mode_of "$R1/$f")" = 644 ]; then ok "$f has mode 644"; else fail "$f has mode 644 (got $(mode_of "$R1/$f"))"; fi
done
for d in . release release/config release/nginx shared shared/caddy; do
  if [ "$(mode_of "$R1/$d")" = 755 ]; then ok "directory $d has mode 755"; else fail "directory $d has mode 755 (got $(mode_of "$R1/$d"))"; fi
done
for f in shared/db-init.sh shared/gen-env.sh; do
  if [ "$(mode_of "$R1/$f")" = 755 ]; then ok "$f has mode 755"; else fail "$f has mode 755 (got $(mode_of "$R1/$f"))"; fi
done
if cmp -s "$R1/release/compose.yaml" "$SCRIPT_DIR/deploy/host/compose.yaml" && cmp -s "$R1/shared/caddy/Caddyfile" "$SCRIPT_DIR/deploy/host/Caddyfile" \
    && cmp -s "$R1/shared/db-init.sh" "$SCRIPT_DIR/deploy/host/db-init.sh" && cmp -s "$R1/shared/gen-env.sh" "$SCRIPT_DIR/deploy/host/gen-env.sh"; then
  ok "compose.yaml, Caddyfile, db-init.sh and gen-env.sh are copied unchanged"
else
  fail "compose.yaml, Caddyfile, db-init.sh and gen-env.sh are copied unchanged"
fi
if cmp -s "$OUT/config/margince.yaml" "$INST/deploy/prod/config/margince.yaml"; then ok "config/margince.yaml comes from DEPLOY_DIR"; else fail "config/margince.yaml comes from DEPLOY_DIR"; fi
if cmp -s "$R1/shared/db-bootstrap.sql" "$INST/core/scripts/deploy/db-bootstrap.sql"; then ok "db-bootstrap.sql comes from core"; else fail "db-bootstrap.sql comes from core"; fi
no_secret_printed "a successful render"

if grep -qxF "MARGINCE_LICENSE=$LICENSE_VALUE" "$OUT/.env"; then
  ok ".env holds a value with spaces, \$, #, and quotes unchanged"
else
  fail ".env holds a value with spaces, \$, #, and quotes unchanged: $(grep '^MARGINCE_LICENSE=' "$OUT/.env" || true)"
fi
if grep -qxF "MARGINCE_ADMIN_PASSWORD=$ADMIN_VALUE" "$OUT/.env"; then ok ".env holds a name listed with surrounding blanks"; else fail ".env holds a name listed with surrounding blanks"; fi
for line in IMAGE_API=registry.example.test/acme/api:v1.0.0 IMAGE_WEB=registry.example.test/acme/web:v1.0.0 \
    IMAGE_WORKER=registry.example.test/acme/worker:v1.0.0 HOST_DOMAIN=crm.example.test \
    API_REPLICAS=1 WORKER_REPLICAS=3 AUTH_RATE_LIMIT_PER_MINUTE=30 COMPOSE_PROFILES=local-data MARGINCE_PUBLIC_BASE_URL=https://crm.example.test; do
  if grep -qxF "$line" "$OUT/.env"; then ok ".env has $line"; else fail ".env has $line: $(sed 's/=.*//' "$OUT/.env" | tr '\n' ' ')"; fi
  case "$line" in MARGINCE_PUBLIC_BASE_URL=*) continue ;; esac
  if grep -qxF "$line" "$OUT/compose.env"; then ok "compose.env has $line"; else fail "compose.env has $line"; fi
done
if grep -qE '^(MARGINCE_LICENSE|MARGINCE_ADMIN_PASSWORD|MARGINCE_DSN|MARGINCE_REDIS)=' "$OUT/compose.env"; then
  fail "compose.env holds no secret"
else
  ok "compose.env holds no secret"
fi
if grep -qE '^(MARGINCE_DSN|MARGINCE_REDIS|MARGINCE_OWNER_DSN)=' "$OUT/.env"; then
  fail "a local-data release leaves the database and Redis addresses to data.env"
else
  ok "a local-data release leaves the database and Redis addresses to data.env"
fi
if [ "$(grep -c '^MARGINCE_LICENSE=' "$OUT/.env")" = 1 ]; then ok "each name is written once"; else fail "each name is written once"; fi
if grep -qx 'MARGINCE_BLOBSTORE_PATH=/app/data/blobs' "$OUT/.env" && ! grep -q '^MARGINCE_BLOBSTORE_PATH=' "$OUT/compose.env"; then
  ok ".env sets the default file store MARGINCE_BLOBSTORE_PATH=/app/data/blobs"
else
  fail ".env sets the default file store MARGINCE_BLOBSTORE_PATH=/app/data/blobs"
fi
if grep -qE '^MARGINCE_(KEYVAULT_ROOT_KEY|CONNECTOR_STATE_KEY|WEBHOOK_KEY)=' "$OUT/.env"; then
  fail ".env leaves the generated keys to instance.env"
else
  ok ".env leaves the generated keys to instance.env"
fi

# --- the env_file order of api and worker in compose.yaml ---
# x-app's env_file paths, in order, each with its format.
envfiles="$(awk '/^x-app:/{a=1;next} a&&/^[^ ]/{a=0} a&&/^  env_file:/{e=1;next} e&&/^  [a-z]/{e=0} e&&/- path:/{printf "%s", $3} e&&/format:/{printf ":%s ", $2}' "$OUT/compose.yaml")"
if [ "$envfiles" = "../../shared/data.env:raw ../../shared/instance.env:raw .env:raw " ]; then
  ok "api and worker read data.env, then instance.env, then .env, all format: raw"
else
  fail "api and worker read data.env, then instance.env, then .env, all format: raw: '$envfiles'"
fi
if grep -q '<<: \*app' "$OUT/compose.yaml" && [ "$(grep -c '<<: \*app' "$OUT/compose.yaml")" = 2 ]; then
  ok "only api and worker use the x-app block"
else
  fail "only api and worker use the x-app block"
fi

# --- the output directory ---
rc="$(render "$OUT")"
if [ "$rc" != 0 ] && grep -q "$R1" "$TMP/out"; then ok "a non-empty output directory is refused"; else fail "a non-empty output directory is refused (rc=$rc): $(cat "$TMP/out")"; fi
rc="$(render "")"
if [ "$rc" != 0 ]; then ok "a missing output directory argument is refused"; else fail "a missing output directory argument is refused"; fi

# --- a missing secret ---
OUT2="$SRV/releases/missing"
rc="$(render "$OUT2" -u MARGINCE_ADMIN_PASSWORD)"
if [ "$rc" = 1 ] && grep -q 'MARGINCE_ADMIN_PASSWORD' "$TMP/out"; then ok "a missing secret exits 1 naming it"; else fail "a missing secret exits 1 naming it (rc=$rc): $(cat "$TMP/out")"; fi
no_secret_printed "a missing secret"
if [ -e "$(rendered "$OUT2")" ]; then fail "a failed render leaves no output directory"; else ok "a failed render leaves no output directory"; fi
rc="$(render "$OUT2" MARGINCE_ADMIN_PASSWORD=)"
if [ "$rc" = 1 ] && grep -q 'MARGINCE_ADMIN_PASSWORD' "$TMP/out"; then ok "an empty secret exits 1 naming it"; else fail "an empty secret exits 1 naming it (rc=$rc)"; fi

# --- a value with a newline ---
rc="$(render "$OUT2" "MARGINCE_ADMIN_PASSWORD=line1
line2-secret")"
if [ "$rc" = 1 ] && grep -q 'MARGINCE_ADMIN_PASSWORD' "$TMP/out" && ! grep -q 'line2-secret\|line1' "$TMP/out"; then
  ok "a value with a newline is refused naming the variable, not the value"
else
  fail "a value with a newline is refused naming the variable, not the value (rc=$rc): $(cat "$TMP/out")"
fi
if [ -e "$(rendered "$OUT2")" ]; then fail "a refused newline leaves no output directory"; else ok "a refused newline leaves no output directory"; fi
rc="$(render "$OUT2" "MARGINCE_ADMIN_PASSWORD=cr1$(printf '\r')cr2-secret")"
if [ "$rc" = 1 ] && grep -q 'MARGINCE_ADMIN_PASSWORD' "$TMP/out" && ! grep -q 'cr2-secret\|cr1' "$TMP/out"; then
  ok "a value with a carriage return is refused naming the variable, not the value"
else
  fail "a value with a carriage return is refused naming the variable, not the value (rc=$rc): $(cat "$TMP/out")"
fi
if [ -e "$(rendered "$OUT2")" ]; then fail "a refused carriage return leaves no output directory"; else ok "a refused carriage return leaves no output directory"; fi

# --- the secrets file ---
cp "$INST/deploy/prod/secrets" "$TMP/secrets.bak"
printf 'MARGINCE_LICENSE\nIMAGE_API\n' > "$INST/deploy/prod/secrets"
rc="$(render "$SRV/releases/reserved")"
if [ "$rc" = 1 ] && grep -q 'IMAGE_API' "$TMP/out"; then ok "a secret named like a generated variable is refused"; else fail "a secret named like a generated variable is refused (rc=$rc): $(cat "$TMP/out")"; fi
printf 'MARGINCE_LICENSE\nnot-a-name\n' > "$INST/deploy/prod/secrets"
rc="$(render "$SRV/releases/badname")"
if [ "$rc" = 1 ] && grep -q 'not-a-name' "$TMP/out"; then ok "an invalid name in secrets is refused"; else fail "an invalid name in secrets is refused (rc=$rc): $(cat "$TMP/out")"; fi
rm "$INST/deploy/prod/secrets"
rc="$(render "$SRV/releases/nosecrets")"
if [ "$rc" = 1 ] && grep -q 'secrets' "$TMP/out"; then ok "a missing secrets file is refused"; else fail "a missing secrets file is refused (rc=$rc)"; fi
cp "$TMP/secrets.bak" "$INST/deploy/prod/secrets"

# --- host.env values ---
cp "$INST/deploy/prod/host.env" "$TMP/host.env.bak"
printf 'HOST_SSH=deploy@203.0.113.10\n' > "$INST/deploy/prod/host.env"
rc="$(render "$SRV/releases/nodomain")"
if [ "$rc" = 1 ] && grep -q 'HOST_DOMAIN' "$TMP/out"; then ok "a missing HOST_DOMAIN is refused"; else fail "a missing HOST_DOMAIN is refused (rc=$rc)"; fi
printf 'HOST_DOMAIN=crm.example.test\nAPI_REPLICAS=two\n' > "$INST/deploy/prod/host.env"
rc="$(render "$SRV/releases/badreplicas")"
if [ "$rc" = 1 ] && grep -q 'API_REPLICAS' "$TMP/out"; then ok "a non-numeric API_REPLICAS is refused"; else fail "a non-numeric API_REPLICAS is refused (rc=$rc)"; fi
printf 'HOST_DOMAIN=crm.example.test\nAUTH_RATE_LIMIT_PER_MINUTE=0\n' > "$INST/deploy/prod/host.env"
rc="$(render "$SRV/releases/badrate")"
if [ "$rc" = 1 ] && grep -q 'AUTH_RATE_LIMIT_PER_MINUTE' "$TMP/out"; then ok "an AUTH_RATE_LIMIT_PER_MINUTE of 0 is refused"; else fail "an AUTH_RATE_LIMIT_PER_MINUTE of 0 is refused (rc=$rc)"; fi
printf 'HOST_DOMAIN=crm.example.test\nAUTH_RATE_LIMIT_PER_MINUTE=12\n' > "$INST/deploy/prod/host.env"
rc="$(render "$SRV/releases/rate12")"
if [ "$rc" = 0 ] && grep -qxF 'AUTH_RATE_LIMIT_PER_MINUTE=12' "$(rendered "$SRV/releases/rate12")/release/compose.env"; then ok "AUTH_RATE_LIMIT_PER_MINUTE from host.env reaches compose.env"; else fail "AUTH_RATE_LIMIT_PER_MINUTE from host.env reaches compose.env (rc=$rc)"; fi
printf 'HOST_DOMAIN=crm.example.test { respond 200 }\n' > "$INST/deploy/prod/host.env"
rc="$(render "$SRV/releases/baddomain")"
if [ "$rc" = 1 ] && grep -q 'HOST_DOMAIN' "$TMP/out"; then ok "a HOST_DOMAIN that is not a host name is refused"; else fail "a HOST_DOMAIN that is not a host name is refused (rc=$rc)"; fi
cp "$TMP/host.env.bak" "$INST/deploy/prod/host.env"

rc="$(render "$SRV/releases/noimage" -u IMAGE_WORKER)"
if [ "$rc" = 1 ] && grep -q 'IMAGE_WORKER' "$TMP/out"; then ok "a missing IMAGE_WORKER is refused"; else fail "a missing IMAGE_WORKER is refused (rc=$rc)"; fi

# --- external database and Redis ---
EXT_DSN='postgres://app:p%40ss@db.example.test:5432/margince'
EXT_OWNER='postgres://owner:o%40ss@db.example.test:5432/margince'
EXT_REDIS='cache.example.test:6379'
OUT3="$SRV/releases/external"
rc="$(render "$OUT3" MARGINCE_DSN="$EXT_DSN" MARGINCE_REDIS="$EXT_REDIS" MARGINCE_OWNER_DSN="$EXT_OWNER")"
if [ "$rc" = 0 ] && grep -qx 'COMPOSE_PROFILES=' "$OUT3/.env" && grep -qx 'COMPOSE_PROFILES=' "$OUT3/compose.env"; then
  ok "COMPOSE_PROFILES is empty with both external addresses set"
else
  fail "COMPOSE_PROFILES is empty with both external addresses set (rc=$rc): $(cat "$TMP/out")"
fi
for line in "MARGINCE_DSN=$EXT_DSN" "MARGINCE_REDIS=$EXT_REDIS" "MARGINCE_OWNER_DSN=$EXT_OWNER"; do
  if grep -qxF "$line" "$OUT3/.env"; then ok "an external release writes ${line%%=*}"; else fail "an external release writes ${line%%=*}"; fi
done
if grep -qF 'p%40ss' "$TMP/out"; then fail "an external render prints no DSN"; else ok "an external render prints no DSN"; fi
rc="$(render "$SRV/releases/ext-noowner" MARGINCE_DSN="$EXT_DSN" MARGINCE_REDIS="$EXT_REDIS")"
if [ "$rc" = 1 ] && grep -q 'MARGINCE_OWNER_DSN' "$TMP/out"; then ok "an external database without MARGINCE_OWNER_DSN is refused"; else fail "an external database without MARGINCE_OWNER_DSN is refused (rc=$rc)"; fi
OUT4="$SRV/releases/dsn-only"
rc="$(render "$OUT4" MARGINCE_DSN="$EXT_DSN")"
if [ "$rc" = 0 ] && grep -qx 'COMPOSE_PROFILES=local-data' "$OUT4/.env"; then ok "COMPOSE_PROFILES stays local-data with only MARGINCE_DSN set"; else fail "COMPOSE_PROFILES stays local-data with only MARGINCE_DSN set (rc=$rc)"; fi

# --- a secret that starts with a quote ---
OUT5="$SRV/releases/leading-quote"
QUOTED='"starts with a quote ${notavar'
rc="$(render "$OUT5" MARGINCE_ADMIN_PASSWORD="$QUOTED")"
if [ "$rc" = 0 ] && grep -qxF "MARGINCE_ADMIN_PASSWORD=$QUOTED" "$OUT5/.env"; then ok ".env holds a value that starts with a quote unchanged"; else fail ".env holds a value that starts with a quote unchanged (rc=$rc)"; fi

# --- the S3 file store ---
cp "$INST/deploy/prod/secrets" "$TMP/secrets.bak"
printf 'MARGINCE_BLOBSTORE_ENDPOINT\nMARGINCE_BLOBSTORE_REGION\n' >> "$INST/deploy/prod/secrets"
OUT6="$SRV/releases/s3"
rc="$(render "$OUT6" MARGINCE_BLOBSTORE_ENDPOINT=s3.example.test:443 MARGINCE_BLOBSTORE_REGION=eu-central-1)"
if [ "$rc" = 0 ] && grep -qx 'MARGINCE_BLOBSTORE_ENDPOINT=s3.example.test:443' "$OUT6/.env" && ! grep -q '^MARGINCE_BLOBSTORE_PATH=' "$OUT6/.env"; then
  ok "with MARGINCE_BLOBSTORE_ENDPOINT in secrets, .env has no default MARGINCE_BLOBSTORE_PATH"
else
  fail "with MARGINCE_BLOBSTORE_ENDPOINT in secrets, .env has no default MARGINCE_BLOBSTORE_PATH (rc=$rc): $(cat "$TMP/out")"
fi
if [ -f "$OUT6/compose.yaml" ] && ! grep -v '^[[:space:]]*#' "$OUT6/compose.yaml" | grep -q 'blobs' && ! grep -q '^[[:space:]]*# [<>]\{3\} default file store' "$OUT6/compose.yaml"; then
  ok "with MARGINCE_BLOBSTORE_ENDPOINT in secrets, compose.yaml has no blobs volume or init service"
else
  fail "with MARGINCE_BLOBSTORE_ENDPOINT in secrets, compose.yaml has no blobs volume or init service: $(grep -n blobs "$OUT6/compose.yaml" 2>/dev/null)"
fi
cp "$TMP/secrets.bak" "$INST/deploy/prod/secrets"
printf 'MARGINCE_BLOBSTORE_PATH\n' >> "$INST/deploy/prod/secrets"
OUT7="$SRV/releases/own-path"
rc="$(render "$OUT7" MARGINCE_BLOBSTORE_PATH=/app/data/blobs/mine)"
if [ "$rc" = 0 ] && [ "$(grep -c '^MARGINCE_BLOBSTORE_PATH=' "$OUT7/.env")" = 1 ] && grep -qx 'MARGINCE_BLOBSTORE_PATH=/app/data/blobs/mine' "$OUT7/.env"; then
  ok "a MARGINCE_BLOBSTORE_PATH listed in secrets replaces the default"
else
  fail "a MARGINCE_BLOBSTORE_PATH listed in secrets replaces the default (rc=$rc)"
fi
cp "$TMP/secrets.bak" "$INST/deploy/prod/secrets"
printf 'MARGINCE_WEBHOOK_KEY\n' >> "$INST/deploy/prod/secrets"
OUT8="$SRV/releases/own-webhook"
CLIENT_WEBHOOK='Y2xpZW50LXdlYmhvb2sta2V5LXZhbHVlLTMyYnl0ZXM='
rc="$(render "$OUT8" MARGINCE_WEBHOOK_KEY="$CLIENT_WEBHOOK")"
if [ "$rc" = 0 ] && grep -qxF "MARGINCE_WEBHOOK_KEY=$CLIENT_WEBHOOK" "$OUT8/.env"; then ok "a MARGINCE_WEBHOOK_KEY listed in secrets is written to .env"; else fail "a MARGINCE_WEBHOOK_KEY listed in secrets is written to .env (rc=$rc)"; fi
cp "$TMP/secrets.bak" "$INST/deploy/prod/secrets"

# --- gen-env.sh: the generated files ---
GEN="$INST/scripts/deploy/host/gen-env.sh"
G="$TMP/gen"
mkdir -p "$G"
# gen <args...> — sh gen-env.sh; output in $TMP/out; prints the exit code.
gen() { local rc=0; sh "$GEN" "$@" > "$TMP/out" 2>&1 || rc=$?; printf '%s' "$rc"; }
rc="$(gen instance "$G/instance.env")"
if [ "$rc" = 0 ] && [ -f "$G/instance.env" ] && [ "$(mode_of "$G/instance.env")" = 600 ]; then ok "gen-env.sh instance creates the file with mode 600"; else fail "gen-env.sh instance creates the file with mode 600 (rc=$rc): $(cat "$TMP/out")"; fi
if [ "$(grep -c . "$G/instance.env" 2>/dev/null || true)" = 4 ] \
   && grep -Eq '^MARGINCE_KEYVAULT_ROOT_KEY=[A-Za-z0-9+/]{43}=$' "$G/instance.env" \
   && grep -Eq '^MARGINCE_CONNECTOR_STATE_KEY=[0-9a-f]{64}$' "$G/instance.env" \
   && grep -Eq '^MARGINCE_WEBHOOK_KEY=[A-Za-z0-9+/]{43}=$' "$G/instance.env" \
   && grep -Eq '^MARGINCE_ADMIN_PASSWORD=[A-Za-z0-9]{24}$' "$G/instance.env"; then
  ok "instance.env has the vault key and webhook key (base64 of 32 bytes), the state key (64 hex) and a 24-character admin password"
else
  fail "instance.env has the four keys in their formats: $(sed 's/=.*//' "$G/instance.env" 2>/dev/null | tr '\n' ' ')"
fi
vault="$(sed -n 's/^MARGINCE_KEYVAULT_ROOT_KEY=//p' "$G/instance.env" 2>/dev/null || true)"
if [ "$(printf '%s' "$vault" | base64 -d 2>/dev/null | wc -c | tr -d ' ')" = 32 ] || [ "$(printf '%s' "$vault" | base64 -D 2>/dev/null | wc -c | tr -d ' ')" = 32 ]; then
  ok "the vault key decodes to 32 bytes"
else
  fail "the vault key decodes to 32 bytes"
fi
if [ ! -s "$TMP/out" ]; then ok "gen-env.sh prints nothing"; else fail "gen-env.sh prints nothing: $(sed 's/=.*//' "$TMP/out")"; fi

# With SIGPIPE ignored (some CI runners), a stage that writes to a closed pipe
# gets a write error instead of a quiet death: tr reported one on Linux and
# never ended on macOS. A watchdog keeps a hang from stalling this test.
kill_tree() { local c; for c in $(pgrep -P "$1" 2>/dev/null); do kill_tree "$c"; done; kill "$1" 2>/dev/null || true; }
( trap '' PIPE; exec sh "$GEN" instance "$G/nopipe.env" ) > "$TMP/out" 2>&1 &
pid=$!; i=0
while kill -0 "$pid" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
if kill -0 "$pid" 2>/dev/null; then
  kill_tree "$pid"; wait "$pid" 2>/dev/null || true
  fail "gen-env.sh with SIGPIPE ignored ends within 10 seconds"
else
  rc=0; wait "$pid" || rc=$?
  if [ "$rc" = 0 ] && [ ! -s "$TMP/out" ] && grep -Eq '^MARGINCE_ADMIN_PASSWORD=[A-Za-z0-9]{24}$' "$G/nopipe.env"; then
    ok "gen-env.sh with SIGPIPE ignored prints nothing and writes a 24-character admin password"
  else
    fail "gen-env.sh with SIGPIPE ignored prints nothing and writes a 24-character admin password (rc=$rc): $(sed 's/=.*//' "$TMP/out")"
  fi
fi
sum="$(cksum < "$G/instance.env" 2>/dev/null || true)"
rc="$(gen instance "$G/instance.env")"
if [ "$rc" = 0 ] && [ -n "$sum" ] && [ "$(cksum < "$G/instance.env")" = "$sum" ]; then ok "gen-env.sh keeps an existing instance.env byte for byte"; else fail "gen-env.sh keeps an existing instance.env (rc=$rc)"; fi
rc="$(gen instance --no-admin-password "$G/instance2.env")"
if [ "$rc" = 0 ] && [ "$(grep -c . "$G/instance2.env")" = 3 ] && ! grep -q '^MARGINCE_ADMIN_PASSWORD=' "$G/instance2.env"; then
  ok "gen-env.sh instance --no-admin-password writes no admin password"
else
  fail "gen-env.sh instance --no-admin-password writes no admin password (rc=$rc)"
fi
if [ -n "$vault" ] && [ "$(sed -n 's/^MARGINCE_KEYVAULT_ROOT_KEY=//p' "$G/instance2.env" 2>/dev/null || true)" != "$vault" ]; then ok "two instance.env files get different keys"; else fail "two instance.env files get different keys"; fi
rc="$(gen data "$G/data.env")"
if [ "$rc" = 0 ] && [ "$(mode_of "$G/data.env")" = 600 ] && [ "$(grep -c . "$G/data.env")" = 4 ] \
   && grep -Eq '^POSTGRES_PASSWORD=[0-9a-f]{48}$' "$G/data.env" \
   && grep -Eq '^MARGINCE_OWNER_DSN=postgres://margince_owner:[0-9a-f]{48}@postgres:5432/margince$' "$G/data.env" \
   && grep -Eq '^MARGINCE_DSN=postgres://margince_app:[0-9a-f]{48}@postgres:5432/margince$' "$G/data.env" \
   && grep -qx 'MARGINCE_REDIS=redis:6379' "$G/data.env"; then
  ok "gen-env.sh data writes data.env with mode 600 and hexadecimal passwords"
else
  fail "gen-env.sh data writes data.env with mode 600 and hexadecimal passwords (rc=$rc): $(cat "$TMP/out")"
fi
# Without openssl: dd and base64.
mkdir -p "$TMP/noossl"
for t in od tr cut dd base64 chmod rm ln wc; do ln -s "$(command -v "$t")" "$TMP/noossl/$t"; done
rc=0; PATH="$TMP/noossl" "$(command -v sh)" "$GEN" instance "$G/noossl.env" > "$TMP/out" 2>&1 || rc=$?
if [ "$rc" = 0 ] && grep -Eq '^MARGINCE_KEYVAULT_ROOT_KEY=[A-Za-z0-9+/]{43}=$' "$G/noossl.env" && grep -Eq '^MARGINCE_WEBHOOK_KEY=[A-Za-z0-9+/]{43}=$' "$G/noossl.env"; then
  ok "gen-env.sh writes the base64 keys without openssl"
else
  fail "gen-env.sh writes the base64 keys without openssl (rc=$rc): $(cat "$TMP/out")"
fi
rc="$(gen bogus "$G/x.env")"
if [ "$rc" = 2 ] && [ ! -e "$G/x.env" ]; then ok "gen-env.sh refuses an unknown kind"; else fail "gen-env.sh refuses an unknown kind (rc=$rc)"; fi
rc="$(gen instance "$G/missing-dir/instance.env")"
if [ "$rc" != 0 ] && [ ! -e "$G/missing-dir" ]; then ok "gen-env.sh fails when the directory is missing"; else fail "gen-env.sh fails when the directory is missing (rc=$rc)"; fi
# A write that fails partway (disk full: `ulimit -f 0` makes any write of more
# than zero bytes to a regular file fail with SIGXFSZ) must not leave a file
# at <file> that a later check would treat as already generated. Output goes
# through a command-substitution pipe, not a plain file, so the shell's own
# "Filesize limit exceeded" notice (which the child's 2>/dev/null redirect
# does not catch, since bash prints it from the parent) does not itself trip
# the same limit.
mkdir -p "$G/short"
rc=0; out="$( (ulimit -f 0; sh "$GEN" instance "$G/short/instance.env") 2>&1 )" || rc=$?
if [ "$rc" != 0 ] && [ -z "$(find "$G/short" -mindepth 1 2>/dev/null)" ]; then
  ok "a write that fails partway leaves nothing at all behind (no file, no temp file)"
else
  fail "a write that fails partway leaves nothing behind (rc=$rc): $(ls -la "$G/short" 2>&1)"
fi
rc="$(gen instance "$G/short/instance.env")"
if [ "$rc" = 0 ] && [ "$(grep -c . "$G/short/instance.env" 2>/dev/null || true)" = 4 ]; then
  ok "a later run creates a complete instance.env after a failed write"
else
  fail "a later run creates a complete instance.env after a failed write (rc=$rc)"
fi

# --- host_env_get ---
cat > "$TMP/host.env" <<EOF
# a comment: HOST_DIR=/nope
  # an indented comment
HOST_SSH=\$(touch $TMP/pwned)
HOST_DOMAIN="quoted.example.test"
HOST_DIR='/srv/margince'
API_REPLICAS=
WORKER_REPLICAS=2
SPACED=a b  c
HOST_LAST=first
HOST_LAST=second
EOF
# get <key> [default] — prints "<status>:<output>".
get() {
  local out rc=0
  out="$(DEPLOY_DIR="$TMP" bash -c '
    set -euo pipefail
    source "$1/deploy/host/lib.sh"
    shift; host_env_get "$@"' _ "$INST/scripts" "$@")" || rc=$?
  printf '%s:%s' "$rc" "$out"
}
v="$(get HOST_SSH)"
if [ "$v" = "0:\$(touch $TMP/pwned)" ] && [ ! -e "$TMP/pwned" ]; then ok "host_env_get returns \$(...) literally without running it"; else fail "host_env_get returns \$(...) literally without running it: $v"; fi
v="$(get HOST_DOMAIN)"; if [ "$v" = "0:quoted.example.test" ]; then ok "host_env_get removes one pair of double quotes"; else fail "host_env_get removes one pair of double quotes: $v"; fi
v="$(get HOST_DIR /opt/x)"; if [ "$v" = "0:/srv/margince" ]; then ok "host_env_get removes one pair of single quotes"; else fail "host_env_get removes one pair of single quotes: $v"; fi
v="$(get WORKER_REPLICAS 1)"; if [ "$v" = "0:2" ]; then ok "host_env_get returns a set value over the default"; else fail "host_env_get returns a set value over the default: $v"; fi
v="$(get API_REPLICAS 1)"; if [ "$v" = "0:1" ]; then ok "host_env_get returns the default for an empty value"; else fail "host_env_get returns the default for an empty value: $v"; fi
v="$(get HOST_MISSING fallback)"; if [ "$v" = "0:fallback" ]; then ok "host_env_get returns the default for a missing key"; else fail "host_env_get returns the default for a missing key: $v"; fi
v="$(get HOST_MISSING)"; if [ "$v" = "1:" ]; then ok "host_env_get exits 1 for a missing key without a default"; else fail "host_env_get exits 1 for a missing key without a default: $v"; fi
v="$(get HOST_DIR_NOT)"; if [ "$v" = "1:" ]; then ok "host_env_get ignores a key in a comment line"; else fail "host_env_get ignores a key in a comment line: $v"; fi
v="$(get SPACED)"; if [ "$v" = "0:a b  c" ]; then ok "host_env_get keeps inner spaces"; else fail "host_env_get keeps inner spaces: $v"; fi
v="$(get HOST_LAST)"; if [ "$v" = "0:second" ]; then ok "host_env_get returns the last assignment"; else fail "host_env_get returns the last assignment: $v"; fi
rm -f "$TMP/host.env"
v="$(get HOST_DIR /opt/x)"; if [ "$v" = "0:/opt/x" ]; then ok "host_env_get returns the default without host.env"; else fail "host_env_get returns the default without host.env: $v"; fi

# --- db-init.sh: the bootstrap gets data.env's role passwords through \getenv ---
mkdir -p "$TMP/pgbin"
cat > "$TMP/pgbin/psql" <<'EOF'
#!/bin/sh
printf 'args: %s\n' "$*" > "$STUB_PSQL_LOG"
printf 'owner=%s app=%s\n' "$MARGINCE_BOOTSTRAP_OWNER_PW" "$MARGINCE_BOOTSTRAP_APP_PW" >> "$STUB_PSQL_LOG"
cat >> "$STUB_PSQL_LOG"
EOF
chmod +x "$TMP/pgbin/psql"
rc=0
( set -a; . "$SRV/shared/data.env"; set +a
  PATH="$TMP/pgbin:$PATH" STUB_PSQL_LOG="$TMP/psql.log" MARGINCE_BOOTSTRAP_SQL="$SRV/shared/db-bootstrap.sql" \
    sh "$SRV/shared/db-init.sh" ) > "$TMP/out" 2>&1 || rc=$?
if [ "$rc" = 0 ] && grep -qx 'owner=0123456789abcdef0123456789abcdef app=fedcba9876543210fedcba9876543210' "$TMP/psql.log"; then
  ok "db-init.sh takes the role passwords from data.env's DSNs"
else
  fail "db-init.sh takes the role passwords from data.env's DSNs (rc=$rc): $(cat "$TMP/out" "$TMP/psql.log" 2>/dev/null)"
fi
if grep -qxF '\getenv owner_pw MARGINCE_BOOTSTRAP_OWNER_PW' "$TMP/psql.log" && grep -qxF '\getenv app_pw MARGINCE_BOOTSTRAP_APP_PW' "$TMP/psql.log" \
    && grep -qx 'SELECT 1;' "$TMP/psql.log"; then
  ok "db-init.sh feeds db-bootstrap.sql to psql after the \\getenv lines"
else
  fail "db-init.sh feeds db-bootstrap.sql to psql after the \\getenv lines: $(cat "$TMP/psql.log")"
fi
if grep -qE '0123456789abcdef|fedcba98' "$TMP/out" || grep -qE '^args: .*[0-9a-f]{32}' "$TMP/psql.log"; then
  fail "db-init.sh puts no password on a command line or in its output"
else
  ok "db-init.sh puts no password on a command line or in its output"
fi
rc=0
( unset MARGINCE_DSN; MARGINCE_OWNER_DSN=x sh "$SRV/shared/db-init.sh" ) > "$TMP/out" 2>&1 || rc=$?
if [ "$rc" = 1 ]; then ok "db-init.sh fails without the DSNs"; else fail "db-init.sh fails without the DSNs (rc=$rc)"; fi

# route_check — run caddy and nginx on a private Docker network (no internet)
# with two stand-in upstreams named api and web, both `caddy respond` from the
# local $CADDY_IMAGE image, and check which one answers each path, the 404 for
# the server-only paths, and nginx's 429 on a credential endpoint.
route_check() {
  local net="render-test-$$-$RANDOM" c path want got code
  local started=""
  docker network create --internal "$net" >/dev/null || { fail "create a test network"; return; }
  for c in api web; do
    docker run -d --rm --name "$net-$c" --network "$net" --network-alias "$c" "$CADDY_IMAGE" \
      caddy respond --listen :8080 --body "$c" >/dev/null && started="$started $net-$c"
  done
  # A limit of 2 per minute with a burst of 2: the third request in a row is refused.
  docker run -d --rm --name "$net-nginx" --network "$net" --network-alias nginx -e AUTH_RATE_LIMIT_PER_MINUTE=2 \
    -v "$OUT/nginx/default.conf.template:/etc/nginx/templates/default.conf.template:ro" "$NGINX_IMAGE" >/dev/null \
    && started="$started $net-nginx"
  docker run -d --rm --name "$net-front" --network "$net" --network-alias front -e HOST_DOMAIN=http://front \
    -v "$SRV/shared/caddy:/etc/caddy:ro" "$CADDY_IMAGE" >/dev/null && started="$started $net-front"
  # route <path> — the body that answers <path>, or the status for a 404 or 429.
  route() {
    docker run --rm --network "$net" "$CADDY_IMAGE" sh -c \
      'out="$(wget -q -O - "http://front$1" 2>&1)" && printf "%s" "$out" || { case "$out" in *404*) printf 404 ;; *429*) printf 429 ;; *) printf "error: %s" "$out" ;; esac; }' _ "$1"
  }
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ "$(route /v1/x)" = api ] && break; sleep 1; done
  for pair in /v1:api /v1/auth/capabilities:api /oauth/authorize:api /mcp:api /mcp/x:api \
      /.well-known/oauth-authorization-server:api /.well-known/oauth-protected-resource/mcp:api \
      /webhooks/gmail:api /webhooks/graph:api \
      /:web /v1x:web /mcpx:web /oauthx:web /.well-known/other:web /webhooks/gmailx:web /contacts/1:web \
      /healthz:404 /readyz:404 /metrics:404 /metrics/x:404; do
    path="${pair%:*}"; want="${pair##*:}"
    got="$(route "$path")"
    if [ "$got" = "$want" ]; then ok "caddy and nginx route $path to $want"; else fail "caddy and nginx route $path to $want (got '$got')"; fi
  done
  code=""
  for _ in 1 2 3 4; do code="$(route /v1/auth/login)"; done
  if [ "$code" = 429 ]; then ok "nginx answers 429 once a client passes the credential endpoint limit"; else fail "nginx answers 429 once a client passes the credential endpoint limit (got '$code')"; fi
  if [ "$(route /v1/auth/capabilities)" = api ]; then ok "the credential limit leaves other api paths alone"; else fail "the credential limit leaves other api paths alone"; fi
  # shellcheck disable=SC2086 # the names contain no spaces
  docker rm -f $started >/dev/null 2>&1 || true
  docker network rm "$net" >/dev/null 2>&1 || true
}

# --- the compose file and the Caddyfile, when Docker is here ---
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  dc() { docker compose -p margince-acme "$@"; }
  if dc -f "$OUT/compose.yaml" --env-file "$OUT/.env" config -q > "$TMP/out" 2>&1; then
    ok "docker compose config -q passes with .env"
  else
    fail "docker compose config -q passes with .env: $(cat "$TMP/out")"
  fi
  if dc -f "$OUT5/compose.yaml" --env-file "$OUT5/compose.env" config -q > "$TMP/out" 2>&1; then
    ok "docker compose config -q passes with compose.env when a secret starts with a quote"
  else
    fail "docker compose config -q passes with compose.env when a secret starts with a quote: $(cat "$TMP/out")"
  fi
  services="$(dc -f "$OUT/compose.yaml" --env-file "$OUT/compose.env" config --services 2>/dev/null | sort | tr '\n' ' ' || true)"
  if [ "$services" = "api blobs-init caddy nginx postgres redis web worker " ]; then ok "a local-data release runs postgres and redis"; else fail "a local-data release runs postgres and redis: $services"; fi
  services="$(dc -f "$OUT3/compose.yaml" --env-file "$OUT3/compose.env" config --services 2>/dev/null | sort | tr '\n' ' ' || true)"
  if [ "$services" = "api blobs-init caddy nginx web worker " ]; then ok "an external release runs no postgres or redis"; else fail "an external release runs no postgres or redis: $services"; fi
  services="$(dc -f "$OUT6/compose.yaml" --env-file "$OUT6/compose.env" config --services 2>/dev/null | sort | tr '\n' ' ' || true)"
  if [ "$services" = "api caddy nginx postgres redis web worker " ]; then ok "an S3 file store release runs no blobs-init"; else fail "an S3 file store release runs no blobs-init: $services"; fi
  if dc -f "$OUT6/compose.yaml" --env-file "$OUT6/compose.env" config -q > "$TMP/out" 2>&1; then
    ok "docker compose config -q passes for an S3 file store release"
  else
    fail "docker compose config -q passes for an S3 file store release: $(cat "$TMP/out")"
  fi
  dc -f "$OUT/compose.yaml" --env-file "$OUT/compose.env" config --format json > "$TMP/config.json" 2>/dev/null || true
  if grep -q '"replicas": 3' "$TMP/config.json"; then ok "WORKER_REPLICAS reaches deploy.replicas"; else fail "WORKER_REPLICAS reaches deploy.replicas"; fi
  if grep -q '"image": "registry.example.test/acme/api:v1.0.0"' "$TMP/config.json"; then ok "IMAGE_API names the api image"; else fail "IMAGE_API names the api image"; fi
  if grep -qF 'fedcba9876543210fedcba9876543210' "$TMP/config.json"; then ok "the app reaches the local database with data.env's password"; else fail "the app reaches the local database with data.env's password"; fi
  # The config output is itself a compose file, so it doubles each $ and
  # JSON-escapes each ".
  if grep -qF 'lic a$$HOME #not-a-comment \"dq\" '"'sq'"' $$(id) `id` end' "$TMP/config.json"; then
    ok "the license from .env reaches the api unchanged"
  else
    fail "the license from .env reaches the api unchanged"
  fi
  # web holds no variable from .env or data.env; the worker holds no owner
  # DSN, bootstrap admin password or superuser password.
  web_json="$(sed -n '/^    "web": {/,/^    }/p' "$TMP/config.json")"
  if [ -n "$web_json" ] && ! printf '%s' "$web_json" | grep -qE '"environment"|MARGINCE_|PASSWORD|DSN|env_file'; then
    ok "web has no environment and no env_file"
  else
    fail "web has no environment and no env_file: $web_json"
  fi
  worker_json="$(sed -n '/^    "worker": {/,/^    }/p' "$TMP/config.json")"
  for v in MARGINCE_ADMIN_PASSWORD MARGINCE_OWNER_DSN POSTGRES_PASSWORD; do
    if printf '%s' "$worker_json" | grep -qF "\"$v\": \"\""; then ok "the worker's $v is empty"; else fail "the worker's $v is empty"; fi
  done
  api_json="$(sed -n '/^    "api": {/,/^    }/p' "$TMP/config.json")"
  if printf '%s' "$api_json" | grep -qF "\"MARGINCE_ADMIN_PASSWORD\": \"$ADMIN_VALUE\""; then ok "the api keeps MARGINCE_ADMIN_PASSWORD"; else fail "the api keeps MARGINCE_ADMIN_PASSWORD"; fi
  if printf '%s' "$api_json" | grep -qF "\"MARGINCE_ADMIN_PASSWORD\": \"$ADMIN_VALUE\"" && ! grep -qF "$INST_ADMIN" "$TMP/config.json"; then
    ok "an admin password in secrets wins over instance.env's"
  else
    fail "an admin password in secrets wins over instance.env's"
  fi
  for svc in api worker; do
    j="$(sed -n "/^    \"$svc\": {/,/^    }/p" "$TMP/config.json")"
    if printf '%s' "$j" | grep -qF "\"MARGINCE_KEYVAULT_ROOT_KEY\": \"$INST_VAULT\"" \
       && printf '%s' "$j" | grep -qF "\"MARGINCE_CONNECTOR_STATE_KEY\": \"$INST_STATE\"" \
       && printf '%s' "$j" | grep -qF "\"MARGINCE_WEBHOOK_KEY\": \"$INST_WEBHOOK\""; then
      ok "the $svc gets the three generated keys from instance.env"
    else
      fail "the $svc gets the three generated keys from instance.env"
    fi
    if printf '%s' "$j" | grep -qF '"MARGINCE_BLOBSTORE_PATH": "/app/data/blobs"' \
       && printf '%s' "$j" | grep -qF '"source": "blobs"' && printf '%s' "$j" | grep -qF '"target": "/app/data/blobs"'; then
      ok "the $svc uses the file store /app/data/blobs on the blobs volume"
    else
      fail "the $svc uses the file store /app/data/blobs on the blobs volume"
    fi
  done
  if printf '%s' "$worker_json" | grep -qF '"MARGINCE_ADMIN_PASSWORD": ""' && ! printf '%s' "$worker_json" | grep -qF "$INST_ADMIN"; then
    ok "the worker's admin password stays blank with instance.env"
  else
    fail "the worker's admin password stays blank with instance.env"
  fi
  if printf '%s' "$web_json" | grep -qE 'KEYVAULT|WEBHOOK|blobs'; then fail "web gets no generated key and no blobs volume"; else ok "web gets no generated key and no blobs volume"; fi
  init_json="$(sed -n '/^    "blobs-init": {/,/^    }/p' "$TMP/config.json")"
  if printf '%s' "$init_json" | grep -qF '"source": "blobs"' && printf '%s' "$init_json" | grep -qF '"user": "0:0"' \
     && printf '%s' "$init_json" | grep -qF 'app:app' && ! printf '%s' "$init_json" | grep -qF '10001:10001' \
     && ! printf '%s' "$init_json" | grep -qE 'MARGINCE_|env_file'; then
    ok "blobs-init gives the blobs volume to the image's app user (by name, app:app) and holds no variable"
  else
    fail "blobs-init gives the blobs volume to the image's app user: $init_json"
  fi
  if printf '%s' "$api_json" | grep -qF '"blobs-init"' && printf '%s' "$api_json" | grep -qF 'service_completed_successfully'; then
    ok "the api starts after blobs-init completed"
  else
    fail "the api starts after blobs-init completed"
  fi
  if grep -qE '^    "blobs": \{' "$TMP/config.json" || grep -q '"blobs": {' "$TMP/config.json"; then ok "the blobs volume is declared"; else fail "the blobs volume is declared"; fi

  # A value the client lists in secrets wins over instance.env.
  dc -f "$OUT8/compose.yaml" --env-file "$OUT8/compose.env" config --format json > "$TMP/config8.json" 2>/dev/null || true
  for svc in api worker; do
    j="$(sed -n "/^    \"$svc\": {/,/^    }/p" "$TMP/config8.json")"
    if printf '%s' "$j" | grep -qF "\"MARGINCE_WEBHOOK_KEY\": \"$CLIENT_WEBHOOK\"" && ! printf '%s' "$j" | grep -qF "$INST_WEBHOOK"; then
      ok "the $svc gets the MARGINCE_WEBHOOK_KEY from secrets, not instance.env's"
    else
      fail "the $svc gets the MARGINCE_WEBHOOK_KEY from secrets, not instance.env's"
    fi
  done

  # With an S3 endpoint: no default path, no blobs volume.
  dc -f "$OUT6/compose.yaml" --env-file "$OUT6/compose.env" config --format json > "$TMP/config6.json" 2>/dev/null || true
  if [ -s "$TMP/config6.json" ] && ! grep -qE 'MARGINCE_BLOBSTORE_PATH|"blobs"|/app/data/blobs|blobs-init' "$TMP/config6.json" \
     && grep -qF '"MARGINCE_BLOBSTORE_ENDPOINT": "s3.example.test:443"' "$TMP/config6.json"; then
    ok "an S3 file store release has no MARGINCE_BLOBSTORE_PATH and no blobs volume"
  else
    fail "an S3 file store release has no MARGINCE_BLOBSTORE_PATH and no blobs volume: $(grep -n 'blobs\|BLOBSTORE' "$TMP/config6.json" | head)"
  fi

  # postgres and caddy: the same definition in every release, so `up` from a
  # new release directory (or a rollback) does not recreate them.
  dc -f "$OUT4/compose.yaml" --env-file "$OUT4/compose.env" config --format json > "$TMP/config4.json" 2>/dev/null || true
  for svc in postgres caddy redis; do
    a="$(sed -n "/^    \"$svc\": {/,/^    }/p" "$TMP/config.json")"
    b="$(sed -n "/^    \"$svc\": {/,/^    }/p" "$TMP/config4.json")"
    if [ -n "$a" ] && [ "$a" = "$b" ]; then ok "$svc is defined the same in two releases"; else fail "$svc is defined the same in two releases"; fi
  done
  if sed -n '/^    "postgres": {/,/^    }/p' "$TMP/config.json" | grep -qF "$SRV/shared/db-init.sh" \
      && sed -n '/^    "caddy": {/,/^    }/p' "$TMP/config.json" | grep -qF "\"source\": \"$SRV/shared/caddy\""; then
    ok "postgres and caddy mount from shared/"
  else
    fail "postgres and caddy mount from shared/"
  fi
  if sed -n '/^    "postgres": {/,/^    }/p;/^    "caddy": {/,/^    }/p' "$TMP/config.json" | grep -qF "$SRV/releases/"; then
    fail "postgres and caddy mount nothing from the release directory"
  else
    ok "postgres and caddy mount nothing from the release directory"
  fi

  dc -f "$OUT3/compose.yaml" --env-file "$OUT3/compose.env" config --format json > "$TMP/config3.json" 2>/dev/null || true
  if grep -qF "\"MARGINCE_DSN\": \"$EXT_DSN\"" "$TMP/config3.json" && ! grep -qF '"MARGINCE_DSN": "postgres://margince_app' "$TMP/config3.json"; then
    ok "an external release's app uses the external MARGINCE_DSN"
  else
    fail "an external release's app uses the external MARGINCE_DSN"
  fi

  # nginx: its template comes from the release directory, so a deployment
  # recreates it with the release's routes.
  if sed -n '/^    "nginx": {/,/^    }/p' "$TMP/config.json" | grep -qF "$OUT/nginx/default.conf.template" \
      && sed -n '/^    "nginx": {/,/^    }/p' "$TMP/config.json" | grep -qF '"AUTH_RATE_LIMIT_PER_MINUTE": "30"' \
      && ! sed -n '/^    "nginx": {/,/^    }/p' "$TMP/config.json" | grep -q '"published"'; then
    ok "nginx mounts the release's template, gets the default rate limit, and publishes no port"
  else
    fail "nginx mounts the release's template, gets the default rate limit, and publishes no port"
  fi

  if docker image inspect "$CADDY_IMAGE" >/dev/null 2>&1; then
    if docker run --rm --network none -e HOST_DOMAIN=crm.example.test -v "$SRV/shared/caddy:/etc/caddy:ro" \
        "$CADDY_IMAGE" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile > "$TMP/out" 2>&1; then
      ok "caddy validate accepts the Caddyfile"
    else
      fail "caddy validate accepts the Caddyfile: $(tail -5 "$TMP/out")"
    fi
  else
    echo "notice: $CADDY_IMAGE is not in the local image store; the Caddyfile validation is skipped"
  fi
  if docker image inspect "$NGINX_IMAGE" >/dev/null 2>&1; then
    if docker run --rm --network none -e AUTH_RATE_LIMIT_PER_MINUTE=30 \
        -v "$OUT/nginx/default.conf.template:/etc/nginx/templates/default.conf.template:ro" \
        "$NGINX_IMAGE" nginx -t > "$TMP/out" 2>&1; then
      ok "nginx -t accepts the rendered template"
    else
      fail "nginx -t accepts the rendered template: $(tail -5 "$TMP/out")"
    fi
  else
    echo "notice: $NGINX_IMAGE is not in the local image store; the nginx validation is skipped"
  fi
  if docker image inspect "$CADDY_IMAGE" >/dev/null 2>&1 && docker image inspect "$NGINX_IMAGE" >/dev/null 2>&1; then
    route_check
  else
    echo "notice: the routing and rate-limit checks need $CADDY_IMAGE and $NGINX_IMAGE locally; skipped"
  fi
else
  echo "notice: docker compose is not available; the compose file checks are skipped"
fi

# --- the image pins ---
# postgres and redis use the image references core pins in its
# docker-compose.dev.yml, exactly (tag and digest); caddy has a tag and a digest.
HC="$SCRIPT_DIR/deploy/host/compose.yaml"
for svc in postgres redis caddy nginx; do
  if [[ "$(service_image "$HC" "$svc")" =~ ^[^@\$]+:[^@]+@sha256:[0-9a-f]{64}$ ]]; then
    ok "compose.yaml pins $svc by tag and digest"
  else
    fail "compose.yaml pins $svc by tag and digest: $(service_image "$HC" "$svc")"
  fi
done
CORE_DC="$SCRIPT_DIR/../core/docker-compose.dev.yml"
if [ -f "$CORE_DC" ]; then
  for svc in postgres redis; do
    want="$(service_image "$CORE_DC" "$svc")" got="$(service_image "$HC" "$svc")"
    if [ -n "$want" ] && [ "$got" = "$want" ]; then
      ok "compose.yaml's $svc image is core's ($want)"
    else
      fail "compose.yaml's $svc image is core's: compose.yaml has '$got', core/docker-compose.dev.yml has '$want'"
    fi
  done
else
  echo "notice: core/docker-compose.dev.yml is not checked out; the comparison with core's image pins is skipped"
fi
# nginx is core's web image base, pinned to the digest core's Dockerfile uses.
CORE_DF="$SCRIPT_DIR/../core/Dockerfile"
if [ -f "$CORE_DF" ]; then
  want="$(grep -oE 'nginxinc/nginx-unprivileged:[^ ]+@sha256:[0-9a-f]{64}' "$CORE_DF" | head -n1)" got="$(service_image "$HC" nginx)"
  if [ -n "$want" ] && [ "$got" = "$want" ]; then ok "compose.yaml's nginx image is core's web base ($want)"; else fail "compose.yaml's nginx image is core's web base: '$got' vs '$want'"; fi
else
  echo "notice: core/Dockerfile is not checked out; the comparison with core's nginx pin is skipped"
fi

# --- the Caddyfile hands everything but the server-only paths to nginx ---
CF="$SCRIPT_DIR/deploy/host/Caddyfile"
for p in '{$HOST_DOMAIN}' 'reverse_proxy nginx:8080' '/healthz' '/readyz' '/metrics'; do
  if grep -qF -- "$p" "$CF"; then ok "the Caddyfile names $p"; else fail "the Caddyfile names $p"; fi
done

# --- nginx's routes and credential endpoint limits ---
NT="$SCRIPT_DIR/deploy/host/nginx.conf.template"
for p in 'location = /v1 ' 'location /v1/ ' 'location /oauth/ ' 'location = /mcp ' 'location /mcp/ ' \
    'location /.well-known/oauth-authorization-server ' 'location /.well-known/oauth-protected-resource ' \
    'location = /webhooks/gmail ' 'location = /webhooks/graph ' 'real_ip_recursive off;' \
    'rate=${AUTH_RATE_LIMIT_PER_MINUTE}r/m'; do
  if grep -qF -- "$p" "$NT"; then ok "nginx.conf.template names $p"; else fail "nginx.conf.template names $p"; fi
done
for p in /v1/auth/login /v1/auth/forgot-password /v1/auth/reset-password /oauth/token /oauth/register; do
  if grep -E "^[[:space:]]*location = $p[[:space:]]" "$NT" | grep -q 'limit_req zone=auth'; then
    ok "nginx rate-limits $p"
  else
    fail "nginx rate-limits $p"
  fi
done
if grep -E '^[[:space:]]*location' "$NT" | grep 'oidc' | grep -q limit_req; then fail "nginx leaves Microsoft sign-in unlimited"; else ok "nginx leaves Microsoft sign-in unlimited"; fi

echo
if [ "$FAILURES" -eq 0 ]; then echo "render.test.sh: all passed"; else echo "render.test.sh: $FAILURES failure(s)" >&2; exit 1; fi
