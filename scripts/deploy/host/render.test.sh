#!/usr/bin/env bash
# render.test.sh — scripts/deploy/host/render.sh builds one release directory,
# and scripts/deploy/host/lib.sh's host_env_get reads host.env without running it.
#
# The scratch instance holds this repository's scripts/, a stand-in
# core/scripts/deploy/db-bootstrap.sql, and deploy/prod/ with host.env,
# config/margince.yaml and secrets. Each release is rendered into
# <srv>/releases/<v>/, the layout the server uses, with <srv>/shared/data.env
# beside it, so the compose file's ../../shared/data.env resolves.
#
# When `docker compose` is available, the rendered compose file is checked with
# `docker compose config`, which reads files only: no daemon call, no network.
# Without Docker those cases print a notice and are skipped.
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
POSTGRES_PASSWORD=00112233445566778899aabbccddeeff
MARGINCE_OWNER_DSN=postgres://margince_owner:0123456789abcdef0123456789abcdef@postgres:5432/margince
MARGINCE_DSN=postgres://margince_app:fedcba9876543210fedcba9876543210@postgres:5432/margince
MARGINCE_REDIS=redis:6379
EOF
chmod 600 "$SRV/shared/data.env"

# render <out> [VAR=value...] — run render.sh with extra environment; output
# (stdout and stderr) in $TMP/out; prints the exit code.
render() {
  local out="$1"; shift
  local rc=0
  (cd "$INST" && env "$@" bash scripts/deploy/host/render.sh "$out") > "$TMP/out" 2>&1 || rc=$?
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
for f in compose.yaml Caddyfile config/margince.yaml .env compose.env db-bootstrap.sql db-init.sh; do
  if [ -f "$OUT/$f" ]; then ok "the release holds $f"; else fail "the release holds $f"; fi
done
if [ "$(mode_of "$OUT/.env")" = 600 ]; then ok ".env has mode 600"; else fail ".env has mode 600 (got $(mode_of "$OUT/.env"))"; fi
for f in compose.yaml Caddyfile config/margince.yaml compose.env db-bootstrap.sql; do
  if [ "$(mode_of "$OUT/$f")" = 644 ]; then ok "$f has mode 644"; else fail "$f has mode 644 (got $(mode_of "$OUT/$f"))"; fi
done
if [ "$(mode_of "$OUT/db-init.sh")" = 755 ]; then ok "db-init.sh has mode 755"; else fail "db-init.sh has mode 755 (got $(mode_of "$OUT/db-init.sh"))"; fi
if cmp -s "$OUT/compose.yaml" "$SCRIPT_DIR/deploy/host/compose.yaml" && cmp -s "$OUT/Caddyfile" "$SCRIPT_DIR/deploy/host/Caddyfile"; then
  ok "compose.yaml and Caddyfile are copied unchanged"
else
  fail "compose.yaml and Caddyfile are copied unchanged"
fi
if cmp -s "$OUT/config/margince.yaml" "$INST/deploy/prod/config/margince.yaml"; then ok "config/margince.yaml comes from DEPLOY_DIR"; else fail "config/margince.yaml comes from DEPLOY_DIR"; fi
if cmp -s "$OUT/db-bootstrap.sql" "$INST/core/scripts/deploy/db-bootstrap.sql"; then ok "db-bootstrap.sql comes from core"; else fail "db-bootstrap.sql comes from core"; fi
no_secret_printed "a successful render"

if grep -qxF "MARGINCE_LICENSE=$LICENSE_VALUE" "$OUT/.env"; then
  ok ".env holds a value with spaces, \$, #, and quotes unchanged"
else
  fail ".env holds a value with spaces, \$, #, and quotes unchanged: $(grep '^MARGINCE_LICENSE=' "$OUT/.env" || true)"
fi
if grep -qxF "MARGINCE_ADMIN_PASSWORD=$ADMIN_VALUE" "$OUT/.env"; then ok ".env holds a name listed with surrounding blanks"; else fail ".env holds a name listed with surrounding blanks"; fi
for line in IMAGE_API=registry.example.test/acme/api:v1.0.0 IMAGE_WEB=registry.example.test/acme/web:v1.0.0 \
    IMAGE_WORKER=registry.example.test/acme/worker:v1.0.0 HOST_DOMAIN=crm.example.test \
    API_REPLICAS=1 WORKER_REPLICAS=3 COMPOSE_PROFILES=local-data MARGINCE_PUBLIC_BASE_URL=https://crm.example.test; do
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

# --- the output directory ---
rc="$(render "$OUT")"
if [ "$rc" != 0 ] && grep -q "$OUT" "$TMP/out"; then ok "a non-empty output directory is refused"; else fail "a non-empty output directory is refused (rc=$rc): $(cat "$TMP/out")"; fi
rc="$(render "")"
if [ "$rc" != 0 ]; then ok "a missing output directory argument is refused"; else fail "a missing output directory argument is refused"; fi

# --- a missing secret ---
OUT2="$SRV/releases/missing"
rc="$(render "$OUT2" -u MARGINCE_ADMIN_PASSWORD)"
if [ "$rc" = 1 ] && grep -q 'MARGINCE_ADMIN_PASSWORD' "$TMP/out"; then ok "a missing secret exits 1 naming it"; else fail "a missing secret exits 1 naming it (rc=$rc): $(cat "$TMP/out")"; fi
no_secret_printed "a missing secret"
if [ -e "$OUT2/.env" ]; then fail "a failed render leaves no .env"; else ok "a failed render leaves no .env"; fi
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
if [ -e "$OUT2/.env" ]; then fail "a refused newline leaves no .env"; else ok "a refused newline leaves no .env"; fi

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
  PATH="$TMP/pgbin:$PATH" STUB_PSQL_LOG="$TMP/psql.log" MARGINCE_BOOTSTRAP_SQL="$OUT/db-bootstrap.sql" \
    sh "$OUT/db-init.sh" ) > "$TMP/out" 2>&1 || rc=$?
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
( unset MARGINCE_DSN; MARGINCE_OWNER_DSN=x sh "$OUT/db-init.sh" ) > "$TMP/out" 2>&1 || rc=$?
if [ "$rc" = 1 ]; then ok "db-init.sh fails without the DSNs"; else fail "db-init.sh fails without the DSNs (rc=$rc)"; fi

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
  if [ "$services" = "api caddy postgres redis web worker " ]; then ok "a local-data release runs postgres and redis"; else fail "a local-data release runs postgres and redis: $services"; fi
  services="$(dc -f "$OUT3/compose.yaml" --env-file "$OUT3/compose.env" config --services 2>/dev/null | sort | tr '\n' ' ' || true)"
  if [ "$services" = "api caddy web worker " ]; then ok "an external release runs no postgres or redis"; else fail "an external release runs no postgres or redis: $services"; fi
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
  dc -f "$OUT3/compose.yaml" --env-file "$OUT3/compose.env" config --format json > "$TMP/config3.json" 2>/dev/null || true
  if grep -qF "\"MARGINCE_DSN\": \"$EXT_DSN\"" "$TMP/config3.json" && ! grep -qF '"MARGINCE_DSN": "postgres://margince_app' "$TMP/config3.json"; then
    ok "an external release's app uses the external MARGINCE_DSN"
  else
    fail "an external release's app uses the external MARGINCE_DSN"
  fi

  if docker image inspect caddy:2 >/dev/null 2>&1; then
    if docker run --rm --network none -e HOST_DOMAIN=crm.example.test -v "$OUT/Caddyfile:/etc/caddy/Caddyfile:ro" \
        caddy:2 caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile > "$TMP/out" 2>&1; then
      ok "caddy validate accepts the Caddyfile"
    else
      fail "caddy validate accepts the Caddyfile: $(tail -5 "$TMP/out")"
    fi
  else
    echo "notice: caddy:2 is not in the local image store; the Caddyfile validation is skipped"
  fi
else
  echo "notice: docker compose is not available; the compose file checks are skipped"
fi

# --- the Caddyfile's routes ---
CF="$SCRIPT_DIR/deploy/host/Caddyfile"
for p in '{$HOST_DOMAIN}' '/v1*' '/oauth*' '/.well-known*' '/mcp*' 'dynamic a api 8080' 'dynamic a web 8080' '/healthz' '/readyz' '/metrics'; do
  if grep -qF -- "$p" "$CF"; then ok "the Caddyfile names $p"; else fail "the Caddyfile names $p"; fi
done

echo
if [ "$FAILURES" -eq 0 ]; then echo "render.test.sh: all passed"; else echo "render.test.sh: $FAILURES failure(s)" >&2; exit 1; fi
