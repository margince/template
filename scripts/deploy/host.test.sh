#!/usr/bin/env bash
# host.test.sh — the host adapter (scripts/deploy/host.sh) through
# `scripts/deploy.sh prod <v>`.
#
# The scratch instance is a git repository with this repository's scripts/, a
# stand-in core/scripts/deploy/db-bootstrap.sql, `deploy: { prod: { adapter:
# host } }`, and deploy/prod/ (host.env, config/margince.yaml, secrets).
#
# ssh, scp, docker, curl and timeout are the stubs in
# scripts/deploy/host/test-stubs/, first on PATH. ssh runs the remote command
# locally in a scratch "server" root ($SRV); the default HOST_DIR
# /opt/margince/acme becomes $SRV/opt/margince/acme. docker's results are
# driven by files in $STUB_STATE. No network, server, or registry is used.
#
# Usage: bash scripts/deploy/host.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
STUBS="$SCRIPT_DIR/deploy/host/test-stubs"

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_PREFIX ALLOW_DIRTY
unset MARGINCE_DSN MARGINCE_REDIS MARGINCE_OWNER_DSN MARGINCE_PUBLIC_BASE_URL COMPOSE_PROFILES REGISTRY MARGINCE_ENV
unset MARGINCE_KEYVAULT_ROOT_KEY MARGINCE_CONNECTOR_STATE_KEY MARGINCE_WEBHOOK_KEY MARGINCE_BLOBSTORE_ENDPOINT MARGINCE_BLOBSTORE_PATH
unset MAKEFLAGS MAKELEVEL MFLAGS
unset REGISTRY_USERNAME REGISTRY_PASSWORD HOST_VERIFY_TIMEOUT HOST_VERIFY_PUBLIC HOST_APPLY_TIMEOUT HOST_SSH_KEY
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false
export GIT_AUTHOR_NAME="Test Dev"     GIT_AUTHOR_EMAIL="dev@example.test"
export GIT_COMMITTER_NAME="Test Dev"  GIT_COMMITTER_EMAIL="dev@example.test"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILURES=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }
ok()   { printf 'ok: %s\n' "$*"; }
mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

git_q() { git -C "$1" -c tag.gpgsign=false "${@:2}" >/dev/null; }
commit_all() { git_q "$1" add -A && git_q "$1" commit -q --allow-empty -m change; }

# The secret values: spaces, $, #, both quote characters, and a backslash.
LICENSE_VALUE='lic a$HOME #not-a-comment "dq" '\''sq'\'' $(id) `id` back\slash end'
ADMIN_VALUE='adm1n-pa55-w0rd'
REG_PASSWORD='reg-Pa55 $word #x "q"'

INST="$TMP/inst"
mkdir -p "$INST/core/scripts/deploy" "$INST/deploy/prod/config"
cp -R "$SCRIPT_DIR" "$INST/scripts"
cp "$SCRIPT_DIR/../Makefile" "$INST/Makefile"
printf 'name: acme\ndisplay_name: Acme\ncore: v0.0.2\ndeploy:\n  prod: { adapter: host }\n' > "$INST/instance.yaml"
printf -- '-- stand-in bootstrap\nSELECT 1;\n' > "$INST/core/scripts/deploy/db-bootstrap.sql"
printf 'version: 1\nworkspace:\n  name: Acme\n' > "$INST/deploy/prod/config/margince.yaml"
printf 'HOST_SSH=deploy@203.0.113.10\nHOST_DOMAIN=crm.example.test\n' > "$INST/deploy/prod/host.env"
printf 'MARGINCE_LICENSE\nMARGINCE_ADMIN_PASSWORD\n' > "$INST/deploy/prod/secrets"
git_q "$INST" init -q
commit_all "$INST"
git_q "$INST" tag v1.0.0

export PATH="$STUBS:$PATH"
export HOST_KNOWN_HOSTS='203.0.113.10 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIStubHostKeyForTestsOnly'
export HOST_SSH_KEY='stub-private-key-for-tests'
export MARGINCE_LICENSE="$LICENSE_VALUE" MARGINCE_ADMIN_PASSWORD="$ADMIN_VALUE"
export HOST_VERIFY_INTERVAL=0 HOST_VERIFY_TIMEOUT=5

SRV="" HD=""
# fresh_server — an empty server and empty stub state.
fresh_server() {
  rm -rf "$TMP/srv" "$TMP/stub"
  mkdir -p "$TMP/srv" "$TMP/stub"
  export STUB_STATE="$TMP/stub" STUB_SERVER_ROOT="$TMP/srv"
  SRV="$TMP/srv"
  HD="$SRV/opt/margince/acme"
}

# deploy <version> [VAR=value...] — make deploy; output in $TMP/out; prints nothing, returns its status.
deploy() {
  local v="$1"; shift
  (cd "$INST" && env "$@" bash scripts/deploy.sh prod "$v") > "$TMP/out" 2>&1
}
out() { cat "$TMP/out"; }
current() { readlink "$HD/current" 2>/dev/null || true; }
releases() { ls -1 "$HD/releases" 2>/dev/null | tr '\n' ' ' | sed 's/ $//'; }
fail_op() { if [ -n "${2:-}" ]; then printf '%s\n' "$2" > "$STUB_STATE/fail.$1"; else : > "$STUB_STATE/fail.$1"; fi; }
clear_fail() { rm -f "$STUB_STATE/fail.$1"; }
# docker_calls <pattern> — the docker.log lines that match.
docker_calls() { grep -e "$1" "$STUB_STATE/docker.log" 2>/dev/null || true; }

# ---------------------------------------------------------------- has
cd "$INST"
has_rc() { local rc=0; DEPLOY_DIR="$INST/deploy/prod" bash scripts/deploy/host.sh has "$1" >/dev/null 2>&1 || rc=$?; printf '%s' "$rc"; }
for s in preflight apply verify rollback; do
  if [ "$(has_rc "$s")" = 0 ]; then ok "has $s exits 0"; else fail "has $s exits 0 — exit $(has_rc "$s")"; fi
done
for s in check deploy ""; do
  if [ "$(has_rc "$s")" = 2 ]; then ok "has '$s' exits 2"; else fail "has '$s' exits 2 — exit $(has_rc "$s")"; fi
done
cd - >/dev/null

# ---------------------------------------------------------------- first deploy
fresh_server
if deploy v1.0.0; then ok "the first deployment succeeds"; else fail "the first deployment succeeds: $(out)"; fi
if [ -f "$HD/releases/v1.0.0/compose.yaml" ] && [ -f "$HD/releases/v1.0.0/compose.env" ] && [ -f "$HD/releases/v1.0.0/config/margince.yaml" ]; then
  ok "the first deployment creates releases/v1.0.0"
else
  fail "the first deployment creates releases/v1.0.0: $(ls -R "$SRV" 2>&1 | head -30)"
fi
if [ "$(current)" = releases/v1.0.0 ]; then ok "current points to releases/v1.0.0"; else fail "current points to releases/v1.0.0: '$(current)'"; fi
if [ -f "$HD/releases/v1.0.0/.env" ] && [ "$(mode_of "$HD/releases/v1.0.0/.env")" = 600 ]; then ok "the server .env has mode 600"; else fail "the server .env has mode 600"; fi
if [ -f "$HD/shared/data.env" ] && [ "$(mode_of "$HD/shared/data.env")" = 600 ]; then ok "shared/data.env is created with mode 600"; else fail "shared/data.env is created with mode 600"; fi
if [ "$(grep -c . "$HD/shared/data.env" 2>/dev/null || true)" = 4 ] \
   && grep -Eq '^POSTGRES_PASSWORD=[0-9a-f]{48}$' "$HD/shared/data.env" \
   && grep -Eq '^MARGINCE_OWNER_DSN=postgres://margince_owner:[0-9a-f]{48}@postgres:5432/margince$' "$HD/shared/data.env" \
   && grep -Eq '^MARGINCE_DSN=postgres://margince_app:[0-9a-f]{48}@postgres:5432/margince$' "$HD/shared/data.env" \
   && grep -qx 'MARGINCE_REDIS=redis:6379' "$HD/shared/data.env"; then
  ok "data.env has the four lines with hexadecimal passwords"
else
  fail "data.env has the four lines with hexadecimal passwords"
fi
pw="$(sed -n 's/^POSTGRES_PASSWORD=//p' "$HD/shared/data.env" 2>/dev/null || true)"
if [ -n "$pw" ] && ! out | grep -qF "$pw"; then ok "the generated passwords are not printed"; else fail "the generated passwords are not printed"; fi
if [ -f "$HD/shared/caddy/Caddyfile" ] && [ -f "$HD/shared/db-init.sh" ] && [ -f "$HD/shared/db-bootstrap.sql" ]; then
  ok "shared/ holds caddy/Caddyfile, db-init.sh, db-bootstrap.sql"
else
  fail "shared/ holds caddy/Caddyfile, db-init.sh, db-bootstrap.sql"
fi
# shellcheck disable=SC2010 # the names are the adapter's own
if [ ! -e "$HD/releases/v1.0.0/Caddyfile" ] && [ -z "$(ls -A "$HD" | grep -v -e '^releases$' -e '^shared$' -e '^current$')" ]; then
  ok "the upload leaves no staging directory behind"
else
  fail "the upload leaves no staging directory behind: $(ls -A "$HD")"
fi
proj="-p margince-acme -f $HD/releases/v1.0.0/compose.yaml --env-file $HD/releases/v1.0.0/compose.env"
if [ -n "$(docker_calls "^compose $proj pull")" ] && [ -n "$(docker_calls "^compose $proj up -d --remove-orphans")" ]; then
  ok "apply runs compose pull and up -d --remove-orphans for the release"
else
  fail "apply runs compose pull and up -d --remove-orphans for the release: $(cat "$STUB_STATE/docker.log")"
fi
if [ -z "$(grep '^compose' "$STUB_STATE/docker.log" | grep -v -e '^compose version' | grep -vF -e "compose -p margince-acme -f $HD/releases/" )" ] \
   && [ -z "$(grep '^compose -p' "$STUB_STATE/docker.log" | grep -v -e '/compose.yaml --env-file .*/compose.env ')" ]; then
  ok "every docker compose call passes -p, -f <release>/compose.yaml and --env-file <release>/compose.env"
else
  fail "every docker compose call passes -p, -f and --env-file: $(grep '^compose' "$STUB_STATE/docker.log")"
fi
if docker_calls ' up ' | grep -q -- '--wait'; then fail "apply does not wait with up --wait"; else ok "apply does not wait with up --wait (readiness is verify's)"; fi
if [ -n "$(docker_calls "exec -T api wget -q -O /dev/null http://127.0.0.1:8080/readyz")" ] && [ -n "$(docker_calls ' ps --status running --services')" ]; then
  ok "verify checks /readyz inside the api container and the running services"
else
  fail "verify checks /readyz inside the api container and the running services"
fi
if grep -q "https://crm.example.test/" "$STUB_STATE/curl.log" 2>/dev/null; then ok "verify checks https://<HOST_DOMAIN>/"; else fail "verify checks https://<HOST_DOMAIN>/"; fi
if grep -q -- '-o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=' "$STUB_STATE/ssh.log" && grep -q -- ' -i ' "$STUB_STATE/ssh.log" && grep -q -- '-o BatchMode=yes -o StrictHostKeyChecking=yes' "$STUB_STATE/scp.log"; then
  ok "ssh and scp use BatchMode, StrictHostKeyChecking, the known hosts file and the key"
else
  fail "ssh and scp use BatchMode, StrictHostKeyChecking, the known hosts file and the key"
fi
if grep -q 'stub-private-key' "$STUB_STATE/ssh.log" "$TMP/out"; then fail "the SSH key is not on the command line or in the output"; else ok "the SSH key is not on the command line or in the output"; fi

# --- instance.env: the generated keys ---
IE="$HD/shared/instance.env"
if [ -f "$IE" ] && [ "$(mode_of "$IE")" = 600 ]; then ok "shared/instance.env is created with mode 600"; else fail "shared/instance.env is created with mode 600"; fi
if [ "$(grep -c . "$IE" 2>/dev/null || true)" = 3 ] \
   && grep -Eq '^MARGINCE_KEYVAULT_ROOT_KEY=[A-Za-z0-9+/]{43}=$' "$IE" \
   && grep -Eq '^MARGINCE_CONNECTOR_STATE_KEY=[0-9a-f]{64}$' "$IE" \
   && grep -Eq '^MARGINCE_WEBHOOK_KEY=[A-Za-z0-9+/]{43}=$' "$IE"; then
  ok "instance.env has the vault, state and webhook keys in their formats"
else
  fail "instance.env has the vault, state and webhook keys in their formats: $(sed 's/=.*//' "$IE" 2>/dev/null | tr '\n' ' ')"
fi
if grep -q '^MARGINCE_ADMIN_PASSWORD=' "$IE" 2>/dev/null; then
  fail "with MARGINCE_ADMIN_PASSWORD in secrets, instance.env holds no admin password"
else
  ok "with MARGINCE_ADMIN_PASSWORD in secrets, instance.env holds no admin password"
fi
leaked=0
while IFS= read -r line; do
  val="${line#*=}"
  [ -n "$val" ] || continue
  if grep -rqF -- "$val" "$TMP/out" "$STUB_STATE"; then leaked=1; fi
done < "$IE"
if [ "$leaked" = 0 ]; then ok "the generated keys are not printed or on a command line"; else fail "the generated keys are not printed or on a command line"; fi
if out | grep -q 'created .*shared/instance.env'; then ok "apply says it created instance.env"; else fail "apply says it created instance.env: $(out)"; fi

# --- the secret value reaches .env unchanged and is never printed ---
if grep -qxF "MARGINCE_LICENSE=$LICENSE_VALUE" "$HD/releases/v1.0.0/.env" 2>/dev/null; then
  ok "a secret with spaces, \$, quotes, # and a backslash reaches the server .env unchanged"
else
  fail "a secret with spaces, \$, quotes, # and a backslash reaches the server .env unchanged"
fi
if grep -qF "$LICENSE_VALUE" "$TMP/out" "$STUB_STATE/ssh.log" "$STUB_STATE/scp.log" "$STUB_STATE/docker.log" \
   || grep -qF "$ADMIN_VALUE" "$TMP/out" "$STUB_STATE/ssh.log" "$STUB_STATE/scp.log" "$STUB_STATE/docker.log"; then
  fail "no secret value is printed or on a command line"
else
  ok "no secret value is printed or on a command line"
fi

# --- second deployment ---
sum1="$(cksum < "$HD/shared/data.env" 2>/dev/null || true)"
isum1="$(cksum < "$HD/shared/instance.env" 2>/dev/null || true)"
: > "$STUB_STATE/docker.log"
if deploy v1.1.0; then ok "the second deployment succeeds"; else fail "the second deployment succeeds: $(out)"; fi
if [ -n "$isum1" ] && [ "$(cksum < "$HD/shared/instance.env" 2>/dev/null || true)" = "$isum1" ]; then ok "shared/instance.env is created once and kept byte for byte"; else fail "shared/instance.env is created once and kept"; fi
if out | grep -q 'instance.env'; then fail "a second deployment does not report creating instance.env"; else ok "a second deployment does not report creating instance.env"; fi
if [ "$(current)" = releases/v1.1.0 ]; then ok "the second deployment points current to releases/v1.1.0"; else fail "current points to releases/v1.1.0: '$(current)'"; fi
if [ -n "$sum1" ] && [ "$(cksum < "$HD/shared/data.env" 2>/dev/null || true)" = "$sum1" ]; then ok "shared/data.env is created once and kept"; else fail "shared/data.env is created once and kept"; fi
if [ "$(releases)" = "v1.0.0 v1.1.0" ]; then ok "both release directories are kept"; else fail "both release directories are kept: $(releases)"; fi
if [ -z "$(docker_calls 'caddy reload')" ]; then ok "an unchanged Caddyfile is not reloaded"; else fail "an unchanged Caddyfile is not reloaded"; fi

# --- the steps directly, with a DEPLOY_STATE_DIR the test reads ---
STATE="$TMP/state"
run_step() {
  rm -rf "$STATE"; mkdir -p "$STATE"
  (cd "$INST" && env DEPLOY_ENV=prod DEPLOY_VERSION="$1" DEPLOY_STEP="$2" DEPLOY_DIR="$INST/deploy/prod" DEPLOY_STATE_DIR="$STATE" \
    INSTANCE_NAME=acme IMAGE_REPO=acme IMAGE_API="acme/api:$1" IMAGE_WEB="acme/web:$1" IMAGE_WORKER="acme/worker:$1" \
    bash scripts/deploy/host.sh "$2") > "$TMP/out" 2>&1
}
if run_step v1.2.0 apply && [ "$(cat "$STATE/previous")" = v1.1.0 ]; then
  ok "apply records previous=v1.1.0 in DEPLOY_STATE_DIR"
else
  fail "apply records previous=v1.1.0 in DEPLOY_STATE_DIR: $(cat "$STATE/previous" 2>/dev/null) $(out)"
fi
if [ "$(mode_of "$STATE/known_hosts")" = 600 ] && [ "$(mode_of "$STATE/ssh_key")" = 600 ]; then
  ok "the known hosts and key files are written with mode 600 into DEPLOY_STATE_DIR"
else
  fail "the known hosts and key files are written with mode 600 into DEPLOY_STATE_DIR"
fi
# shellcheck disable=SC2010 # the names are the adapter's own
if [ -z "$(ls "$STATE" | grep -v -e '^previous$' -e '^known_hosts$' -e '^ssh_key$')" ]; then
  ok "apply removes its local render directory (it holds .env)"
else
  fail "apply removes its local render directory: $(ls "$STATE")"
fi
fresh_server
if run_step v1.0.0 apply && [ -f "$STATE/previous" ] && [ ! -s "$STATE/previous" ]; then
  ok "apply on a new server records an empty previous"
else
  fail "apply on a new server records an empty previous"
fi

# --- Caddyfile change reloads caddy ---
fresh_server
deploy v1.0.0 || fail "setup: deploy v1.0.0: $(out)"
printf '\n# changed\n' >> "$INST/scripts/deploy/host/Caddyfile"
commit_all "$INST"
: > "$STUB_STATE/docker.log"
if deploy v1.1.0 && [ -n "$(docker_calls "exec -T caddy caddy reload --config /etc/caddy/Caddyfile")" ] && grep -q '# changed' "$HD/shared/caddy/Caddyfile"; then
  ok "a changed Caddyfile is uploaded and caddy is reloaded"
else
  fail "a changed Caddyfile is uploaded and caddy is reloaded: $(out)"
fi
printf 'api\nworker\n' > "$STUB_STATE/ps-services"
printf '\n# changed again\n' >> "$INST/scripts/deploy/host/Caddyfile"
commit_all "$INST"
: > "$STUB_STATE/docker.log"
if deploy v1.2.0 && [ -z "$(docker_calls 'caddy reload')" ]; then
  ok "caddy is not reloaded when it is not running"
else
  fail "caddy is not reloaded when it is not running: $(out)"
fi
rm -f "$STUB_STATE/ps-services"
git -C "$INST" checkout -q HEAD~2 -- scripts/deploy/host/Caddyfile
commit_all "$INST"

# --- an existing data.env is never replaced ---
fresh_server
mkdir -p "$HD/shared"
printf 'POSTGRES_PASSWORD=keep\n' > "$HD/shared/data.env"; chmod 600 "$HD/shared/data.env"
if deploy v1.0.0 && [ "$(cat "$HD/shared/data.env")" = POSTGRES_PASSWORD=keep ]; then
  ok "an existing shared/data.env is kept unchanged"
else
  fail "an existing shared/data.env is kept unchanged: $(out)"
fi

# --- an existing instance.env is never replaced ---
fresh_server
mkdir -p "$HD/shared"
printf 'MARGINCE_KEYVAULT_ROOT_KEY=keep\n' > "$HD/shared/instance.env"; chmod 600 "$HD/shared/instance.env"
if deploy v1.0.0 && [ "$(cat "$HD/shared/instance.env")" = MARGINCE_KEYVAULT_ROOT_KEY=keep ]; then
  ok "an existing shared/instance.env is kept unchanged"
else
  fail "an existing shared/instance.env is kept unchanged: $(out)"
fi

# --- a failed apply, then a new apply: the generated files stay the same ---
fresh_server
fail_op compose-up
if deploy v1.0.0; then fail "a first deployment whose compose up fails fails"; else ok "a first deployment whose compose up fails fails"; fi
isum="$(cksum < "$HD/shared/instance.env" 2>/dev/null || true)"
dsum="$(cksum < "$HD/shared/data.env" 2>/dev/null || true)"
if [ -n "$isum" ] && [ -n "$dsum" ]; then ok "the failed apply created instance.env and data.env before up"; else fail "the failed apply created instance.env and data.env before up"; fi
clear_fail compose-up
if deploy v1.0.0 && [ "$(cksum < "$HD/shared/instance.env")" = "$isum" ] && [ "$(cksum < "$HD/shared/data.env")" = "$dsum" ]; then
  ok "the next apply keeps instance.env and data.env byte for byte"
else
  fail "the next apply keeps instance.env and data.env byte for byte: $(out)"
fi
fail_op compose-up "releases/v1.1.0/"
deploy v1.1.0 || true
clear_fail compose-up
if deploy v1.2.0 && [ "$(cksum < "$HD/shared/instance.env")" = "$isum" ] && [ "$(cksum < "$HD/shared/data.env")" = "$dsum" ]; then
  ok "a failed and rolled-back apply, then a new apply, keep instance.env and data.env"
else
  fail "a failed and rolled-back apply, then a new apply, keep instance.env and data.env: $(out)"
fi

# --- the generated admin password, and make host-admin-password ---
# admin_pw — make host-admin-password ENV=prod; output in $TMP/pw; prints nothing, returns its status.
admin_pw() { (cd "$INST" && make --no-print-directory host-admin-password ENV=prod) > "$TMP/pw" 2>&1; }
printf 'MARGINCE_LICENSE\n' > "$INST/deploy/prod/secrets"
commit_all "$INST"
fresh_server
if deploy v1.0.0; then ok "a deployment without MARGINCE_ADMIN_PASSWORD in secrets succeeds"; else fail "a deployment without MARGINCE_ADMIN_PASSWORD in secrets succeeds: $(out)"; fi
if [ "$(grep -c . "$HD/shared/instance.env" 2>/dev/null || true)" = 4 ] && grep -Eq '^MARGINCE_ADMIN_PASSWORD=[A-Za-z0-9]{24}$' "$HD/shared/instance.env"; then
  ok "without MARGINCE_ADMIN_PASSWORD in secrets, instance.env holds a 24-character admin password"
else
  fail "without MARGINCE_ADMIN_PASSWORD in secrets, instance.env holds a 24-character admin password"
fi
gpw="$(sed -n 's/^MARGINCE_ADMIN_PASSWORD=//p' "$HD/shared/instance.env" 2>/dev/null || true)"
if [ -n "$gpw" ] && ! grep -rqF -- "$gpw" "$TMP/out" "$STUB_STATE"; then ok "the generated admin password is not printed by the deployment"; else fail "the generated admin password is not printed by the deployment"; fi
if grep -q '^MARGINCE_ADMIN_PASSWORD=' "$HD/releases/v1.0.0/.env"; then fail "the release .env holds no admin password"; else ok "the release .env holds no admin password"; fi
: > "$STUB_STATE/ssh.log"
if admin_pw && [ "$(cat "$TMP/pw")" = "$gpw" ]; then
  ok "make host-admin-password prints the generated password and nothing else"
else
  fail "make host-admin-password prints the generated password and nothing else: $(sed "s/$gpw/<password>/" "$TMP/pw")"
fi
if [ -n "$gpw" ] && ! grep -qF -- "$gpw" "$STUB_STATE/ssh.log"; then ok "make host-admin-password puts no password on a command line"; else fail "make host-admin-password puts no password on a command line"; fi
if (cd "$INST" && env HOST_KNOWN_HOSTS= make --no-print-directory host-admin-password ENV=prod) > "$TMP/pw" 2>&1; then
  fail "make host-admin-password needs HOST_KNOWN_HOSTS"
else
  ok "make host-admin-password needs HOST_KNOWN_HOSTS"
fi
if (cd "$INST" && make --no-print-directory host-admin-password ENV=nope) > "$TMP/pw" 2>&1; then fail "make host-admin-password refuses an unknown environment"; else ok "make host-admin-password refuses an unknown environment"; fi
fresh_server
if admin_pw; then fail "make host-admin-password fails before the first deployment"; else ok "make host-admin-password fails before the first deployment"; fi
if grep -q 'instance.env' "$TMP/pw"; then ok "it names instance.env"; else fail "it names instance.env: $(cat "$TMP/pw")"; fi
printf 'MARGINCE_LICENSE\nMARGINCE_ADMIN_PASSWORD\n' > "$INST/deploy/prod/secrets"
commit_all "$INST"
deploy v1.0.0 || fail "setup: deploy v1.0.0: $(out)"
if admin_pw && grep -q 'secrets' "$TMP/pw" && ! grep -qF "$ADMIN_VALUE" "$TMP/pw"; then
  ok "make host-admin-password says the password comes from secrets, without printing it"
else
  fail "make host-admin-password says the password comes from secrets: $(cat "$TMP/pw")"
fi

# ---------------------------------------------------------------- license
LICENSE_MSG='deploy: prod runs in production mode and needs MARGINCE_LICENSE: list it in deploy/prod/secrets and set it (or set MARGINCE_ENV=test for a test environment)'
# with_secrets <content> — write deploy/prod/secrets and commit.
with_secrets() { printf '%b' "$1" > "$INST/deploy/prod/secrets"; commit_all "$INST"; }
with_secrets 'MARGINCE_ADMIN_PASSWORD\n'
fresh_server
if deploy v1.0.0; then fail "production mode without MARGINCE_LICENSE in secrets fails"; else ok "production mode without MARGINCE_LICENSE in secrets fails"; fi
if out | grep -qxF "$LICENSE_MSG" && out | grep -q 'preflight failed'; then ok "the preflight failure says production mode needs MARGINCE_LICENSE"; else fail "the preflight failure says production mode needs MARGINCE_LICENSE: $(out)"; fi
if [ ! -e "$STUB_STATE/ssh.log" ] && [ ! -e "$STUB_STATE/scp.log" ] && [ ! -e "$SRV/opt" ]; then ok "a missing license connects to nothing and uploads nothing"; else fail "a missing license connects to nothing and uploads nothing"; fi
fresh_server
if ! deploy v1.0.0 MARGINCE_ENV=test && out | grep -qxF "$LICENSE_MSG"; then
  ok "MARGINCE_ENV=test in the environment but not in secrets is still production mode"
else
  fail "MARGINCE_ENV=test in the environment but not in secrets is still production mode: $(out)"
fi
with_secrets 'MARGINCE_ENV\nMARGINCE_ADMIN_PASSWORD\n'
fresh_server
if ! deploy v1.0.0 MARGINCE_ENV=production && out | grep -qxF "$LICENSE_MSG"; then ok "MARGINCE_ENV=production without a license fails"; else fail "MARGINCE_ENV=production without a license fails: $(out)"; fi
fresh_server
if ! deploy v1.0.0 MARGINCE_ENV=staging && out | grep -qxF "$LICENSE_MSG"; then ok "MARGINCE_ENV=staging is production mode"; else fail "MARGINCE_ENV=staging is production mode: $(out)"; fi
for e in test dev; do
  fresh_server
  if deploy v1.0.0 -u MARGINCE_LICENSE MARGINCE_ENV=$e && grep -qx "MARGINCE_ENV=$e" "$HD/releases/v1.0.0/.env"; then
    ok "MARGINCE_ENV=$e in secrets without a license passes"
  else
    fail "MARGINCE_ENV=$e in secrets without a license passes: $(out)"
  fi
done
with_secrets 'MARGINCE_LICENSE\nMARGINCE_ADMIN_PASSWORD\n'

# ---------------------------------------------------------------- rollback
fresh_server
deploy v1.0.0 || fail "setup: deploy v1.0.0: $(out)"
fail_op compose-up "releases/v1.1.0/"
if deploy v1.1.0; then fail "a failed compose up fails the deployment"; else ok "a failed compose up fails the deployment"; fi
if [ "$(current)" = releases/v1.0.0 ]; then ok "a failed compose up rolls back: current points to releases/v1.0.0"; else fail "a failed compose up rolls back: current '$(current)'"; fi
if [ -n "$(docker_calls "releases/v1.1.0/compose.env up -d")" ] && docker_calls ' up -d' | tail -n1 | grep -q 'releases/v1.0.0/compose.env up -d --remove-orphans'; then
  ok "the rollback runs up -d --remove-orphans for releases/v1.0.0 after the failed up"
else
  fail "the rollback runs up -d --remove-orphans for releases/v1.0.0: $(docker_calls ' up ')"
fi
if out | grep -q 'rolled back'; then ok "the output says it rolled back"; else fail "the output says it rolled back: $(out)"; fi
clear_fail compose-up

# --- verify timeout ---
fresh_server
deploy v1.0.0 || fail "setup: deploy v1.0.0: $(out)"
fail_op compose-exec-api "releases/v1.1.0/"
start=$SECONDS
if deploy v1.1.0 HOST_VERIFY_TIMEOUT=2 HOST_VERIFY_INTERVAL=1; then fail "a verify timeout fails the deployment"; else ok "a verify timeout fails the deployment"; fi
if [ "$(current)" = releases/v1.0.0 ]; then ok "a verify timeout rolls back to releases/v1.0.0"; else fail "a verify timeout rolls back to releases/v1.0.0: '$(current)'"; fi
if [ $((SECONDS - start)) -lt 30 ]; then ok "verify stops at HOST_VERIFY_TIMEOUT"; else fail "verify stops at HOST_VERIFY_TIMEOUT"; fi
if out | grep -q '/readyz'; then ok "a verify timeout names the check that failed"; else fail "a verify timeout names the check that failed: $(out)"; fi
clear_fail compose-exec-api

# --- verify polls until ready ---
fresh_server
printf '3\n' > "$STUB_STATE/fail-times.compose-exec-api"
if deploy v1.0.0 && [ "$(docker_calls 'exec -T api' | wc -l | tr -d ' ')" = 4 ]; then
  ok "verify polls /readyz until it answers"
else
  fail "verify polls /readyz until it answers: $(docker_calls 'exec -T api' | wc -l) $(out)"
fi

# --- worker not running ---
fresh_server
deploy v1.0.0 || fail "setup: deploy v1.0.0: $(out)"
printf 'api\nweb\ncaddy\n' > "$STUB_STATE/ps-services"
if ! deploy v1.1.0 HOST_VERIFY_TIMEOUT=1 && [ "$(current)" = releases/v1.0.0 ] && out | grep -q worker; then
  ok "a worker that is not running fails verify and rolls back"
else
  fail "a worker that is not running fails verify and rolls back: $(out)"
fi
rm -f "$STUB_STATE/ps-services"

# --- public check ---
fresh_server
deploy v1.0.0 || fail "setup: deploy v1.0.0: $(out)"
printf '502' > "$STUB_STATE/curl-code"
if ! deploy v1.1.0 HOST_VERIFY_TIMEOUT=1 && [ "$(current)" = releases/v1.0.0 ]; then
  ok "a public status of 502 fails verify and rolls back"
else
  fail "a public status of 502 fails verify and rolls back: $(out)"
fi
printf '404' > "$STUB_STATE/curl-code"
if deploy v1.1.0; then ok "a public status of 404 passes verify"; else fail "a public status of 404 passes verify: $(out)"; fi
printf '502' > "$STUB_STATE/curl-code"
: > "$STUB_STATE/curl.log"
if deploy v1.2.0 HOST_VERIFY_PUBLIC=0 && [ ! -s "$STUB_STATE/curl.log" ]; then
  ok "HOST_VERIFY_PUBLIC=0 skips the public check"
else
  fail "HOST_VERIFY_PUBLIC=0 skips the public check: $(out)"
fi
rm -f "$STUB_STATE/curl-code"

# --- first deploy with a failing verify ---
fresh_server
fail_op compose-exec-api
if deploy v1.0.0 HOST_VERIFY_TIMEOUT=1; then fail "a first deployment with a failing verify fails"; else ok "a first deployment with a failing verify fails"; fi
if out | grep -qF 'deploy: no previous release to roll back to'; then ok "it says there is no previous release"; else fail "it says there is no previous release: $(out)"; fi
if [ -n "$(docker_calls "releases/v1.0.0/compose.env down")" ]; then ok "it runs compose down for the new release"; else fail "it runs compose down for the new release: $(cat "$STUB_STATE/docker.log")"; fi
if [ -z "$(current)" ]; then ok "it leaves no current link to the stopped release"; else fail "it leaves no current link: '$(current)'"; fi
clear_fail compose-exec-api

# ---------------------------------------------------------------- preflight
fresh_server
if deploy v1.0.0 MARGINCE_LICENSE=; then fail "a missing secret fails preflight"; else ok "a missing secret fails preflight"; fi
if out | grep -q 'MARGINCE_LICENSE' && out | grep -q 'preflight failed'; then ok "the preflight failure names the secret"; else fail "the preflight failure names the secret: $(out)"; fi
if [ ! -e "$STUB_STATE/scp.log" ] && [ ! -e "$SRV/opt" ]; then ok "a missing secret uploads nothing"; else fail "a missing secret uploads nothing"; fi

fresh_server
if deploy v1.0.0 HOST_KNOWN_HOSTS=; then fail "a missing HOST_KNOWN_HOSTS fails preflight"; else ok "a missing HOST_KNOWN_HOSTS fails preflight"; fi
if out | grep -q 'HOST_KNOWN_HOSTS' && [ ! -e "$STUB_STATE/ssh.log" ] && [ ! -e "$STUB_STATE/scp.log" ]; then
  ok "a missing HOST_KNOWN_HOSTS is named and nothing connects"
else
  fail "a missing HOST_KNOWN_HOSTS is named and nothing connects: $(out)"
fi

fresh_server
touch "$STUB_STATE/fail.ssh"
if ! deploy v1.0.0 && out | grep -q 'cannot connect' && [ ! -e "$STUB_STATE/scp.log" ]; then
  ok "an SSH connection failure fails preflight"
else
  fail "an SSH connection failure fails preflight: $(out)"
fi
rm -f "$STUB_STATE/fail.ssh"

fresh_server
printf '2.29.7\n' > "$STUB_STATE/compose-version"
if ! deploy v1.0.0 && out | grep -q '2.30.0' && [ ! -e "$STUB_STATE/scp.log" ]; then
  ok "Docker Compose older than 2.30.0 fails preflight, naming the minimum"
else
  fail "Docker Compose older than 2.30.0 fails preflight, naming the minimum: $(out)"
fi
printf 'v5.1.2\n' > "$STUB_STATE/compose-version"
if deploy v1.0.0; then ok "Docker Compose v5.1.2 passes preflight"; else fail "Docker Compose v5.1.2 passes preflight: $(out)"; fi
rm -f "$STUB_STATE/compose-version"

fresh_server
fail_op compose-version
if ! deploy v1.0.0 && out | grep -q 'host-bootstrap' && [ ! -e "$STUB_STATE/scp.log" ]; then
  ok "a server without the Compose plugin fails preflight, naming make host-bootstrap"
else
  fail "a server without the Compose plugin fails preflight: $(out)"
fi

fresh_server
fail_op manifest "acme/worker:v1.0.0"
if ! deploy v1.0.0 && out | grep -q 'acme/worker:v1.0.0' && [ ! -e "$STUB_STATE/scp.log" ]; then
  ok "an unreadable image manifest fails preflight, naming the image"
else
  fail "an unreadable image manifest fails preflight, naming the image: $(out)"
fi

# --- registry login ---
fresh_server
if deploy v1.0.0 REGISTRY=registry.example.test REGISTRY_USERNAME=robot REGISTRY_PASSWORD="$REG_PASSWORD"; then
  ok "a deployment with a registry login succeeds"
else
  fail "a deployment with a registry login succeeds: $(out)"
fi
if [ -n "$(docker_calls '^login --username robot --password-stdin registry.example.test$')" ] && [ "$(cat "$STUB_STATE/login.stdin" 2>/dev/null)" = "$REG_PASSWORD" ]; then
  ok "docker login on the server gets the password on standard input"
else
  fail "docker login on the server gets the password on standard input: $(docker_calls login)"
fi
if [ -n "$(docker_calls '^manifest inspect registry.example.test/acme/api:v1.0.0')" ]; then ok "preflight reads the image manifests"; else fail "preflight reads the image manifests"; fi
if grep -qF "$REG_PASSWORD" "$TMP/out" "$STUB_STATE/ssh.log" "$STUB_STATE/scp.log" "$STUB_STATE/docker.log"; then
  fail "REGISTRY_PASSWORD never appears in the output or the ssh arguments"
else
  ok "REGISTRY_PASSWORD never appears in the output or the ssh arguments"
fi
fresh_server
if ! deploy v1.0.0 REGISTRY_USERNAME=robot REGISTRY_PASSWORD= && out | grep -q 'REGISTRY_PASSWORD'; then
  ok "REGISTRY_USERNAME without REGISTRY_PASSWORD fails preflight"
else
  fail "REGISTRY_USERNAME without REGISTRY_PASSWORD fails preflight: $(out)"
fi

# ---------------------------------------------------------------- fix round 1
# I1: redeploying the running release keeps its older copy for the rollback.
fresh_server
deploy v1.0.0 || fail "setup: deploy v1.0.0: $(out)"
fail_op compose-exec-api
if deploy v1.0.0 MARGINCE_ADMIN_PASSWORD=changed-admin-pw HOST_VERIFY_TIMEOUT=1; then fail "a redeployment with a failing verify fails"; else ok "a redeployment with a failing verify fails"; fi
if grep -qxF "MARGINCE_ADMIN_PASSWORD=$ADMIN_VALUE" "$HD/releases/v1.0.0/.env" 2>/dev/null && [ "$(current)" = releases/v1.0.0 ]; then
  ok "a failed redeployment of the running release restores its original files, and current points at them"
else
  fail "a failed redeployment of the running release restores its original files: $(grep ADMIN "$HD/releases/v1.0.0/.env" 2>/dev/null | cut -c1-40) current $(current)"
fi
if [ ! -e "$HD/releases/.replaced-v1.0.0" ] && out | grep -q 'restored the previous copy of releases/v1.0.0'; then
  ok "the rollback moves .replaced-v1.0.0 back"
else
  fail "the rollback moves .replaced-v1.0.0 back: $(ls -A "$HD/releases") $(out)"
fi
clear_fail compose-exec-api
if deploy v1.0.0 MARGINCE_ADMIN_PASSWORD=changed-admin-pw && grep -qx 'MARGINCE_ADMIN_PASSWORD=changed-admin-pw' "$HD/releases/v1.0.0/.env" && [ -d "$HD/releases/.replaced-v1.0.0" ]; then
  ok "a successful redeployment installs the new files and keeps .replaced-v1.0.0 until the next deployment"
else
  fail "a successful redeployment installs the new files and keeps .replaced-v1.0.0: $(out)"
fi
if deploy v1.1.0 && [ -z "$(find "$HD/releases" -maxdepth 1 -name '.replaced-*')" ] && [ "$(releases)" = "v1.0.0 v1.1.0" ]; then
  ok "the next deployment removes .replaced-v1.0.0"
else
  fail "the next deployment removes .replaced-v1.0.0: $(ls -A "$HD/releases")"
fi

# M1: a changed Caddyfile is installed only after up succeeds.
fresh_server
deploy v1.0.0 || fail "setup: deploy v1.0.0: $(out)"
printf '\n# staged\n' >> "$INST/scripts/deploy/host/Caddyfile"
commit_all "$INST"
fail_op compose-up "releases/v1.1.0/"
: > "$STUB_STATE/docker.log"
if ! deploy v1.1.0 && ! grep -q '# staged' "$HD/shared/caddy/Caddyfile" && [ ! -e "$HD/shared/caddy/Caddyfile.new" ] && [ -z "$(docker_calls 'caddy reload')" ]; then
  ok "a failed up leaves the running Caddyfile unchanged, and the rollback removes Caddyfile.new"
else
  fail "a failed up leaves the running Caddyfile unchanged: $(ls "$HD/shared/caddy") $(out)"
fi
clear_fail compose-up
if deploy v1.1.0 && grep -q '# staged' "$HD/shared/caddy/Caddyfile" && [ ! -e "$HD/shared/caddy/Caddyfile.new" ]; then
  ok "after a successful up the staged Caddyfile replaces the old one"
else
  fail "after a successful up the staged Caddyfile replaces the old one: $(out)"
fi
git -C "$INST" checkout -q HEAD~1 -- scripts/deploy/host/Caddyfile
commit_all "$INST"

# M2: current is switched by renaming a new link over it.
if grep -q 'current.tmp' "$STUB_STATE/ssh.log" && grep -q 'mv -T' "$STUB_STATE/ssh.log" && [ ! -e "$HD/current.tmp" ] && [ ! -L "$HD/current.tmp" ] && [ -L "$HD/current" ]; then
  ok "current is switched with ln -sfn current.tmp and mv -T, leaving no current.tmp"
else
  fail "current is switched with ln -sfn current.tmp and mv -T"
fi

# M3: the registry login lives in a per-step DOCKER_CONFIG that is removed.
fresh_server
if deploy v1.0.0 REGISTRY=registry.example.test REGISTRY_USERNAME=robot REGISTRY_PASSWORD="$REG_PASSWORD"; then ok "setup: a deployment with a registry login"; else fail "setup: a deployment with a registry login: $(out)"; fi
if grep -Eq "^login DOCKER_CONFIG=$HD/\.docker-preflight-" "$STUB_STATE/docker-env.log" \
   && grep -Eq "^manifest DOCKER_CONFIG=$HD/\.docker-preflight-" "$STUB_STATE/docker-env.log" \
   && grep -Eq "^login DOCKER_CONFIG=$HD/\.docker-apply-" "$STUB_STATE/docker-env.log" \
   && grep -Eq "^compose-pull DOCKER_CONFIG=$HD/\.docker-apply-" "$STUB_STATE/docker-env.log"; then
  ok "login, manifest inspect and pull use a DOCKER_CONFIG directory of the step"
else
  fail "login, manifest inspect and pull use a DOCKER_CONFIG directory of the step: $(cat "$STUB_STATE/docker-env.log")"
fi
if [ -z "$(find "$SRV" -name config.json)" ] && [ ! -e "$STUB_STATE/home-docker" ] && [ -z "$(find "$HD" -maxdepth 1 -name '.docker-*')" ]; then
  ok "no registry credentials file remains on the server after the steps"
else
  fail "no registry credentials file remains on the server: $(find "$SRV" -name config.json) $(ls -A "$HD")"
fi
fresh_server
fail_op manifest "acme/web:v1.0.0"
if ! deploy v1.0.0 REGISTRY=registry.example.test REGISTRY_USERNAME=robot REGISTRY_PASSWORD="$REG_PASSWORD" \
   && [ -n "$(docker_calls '^login ')" ] && [ -z "$(find "$SRV" -name config.json)" ] && [ ! -e "$STUB_STATE/home-docker" ]; then
  ok "a preflight that fails after the login still removes the credentials"
else
  fail "a preflight that fails after the login still removes the credentials: $(find "$SRV" -name config.json) $(out)"
fi
clear_fail manifest

# ---------------------------------------------------------------- keep five
fresh_server
for v in v1.0.0 v1.1.0 v1.2.0 v1.3.0 v1.4.0 v1.5.0 v1.6.0; do
  deploy "$v" || fail "deploy $v: $(out)"
done
if [ "$(releases)" = "v1.2.0 v1.3.0 v1.4.0 v1.5.0 v1.6.0" ] && [ "$(current)" = releases/v1.6.0 ]; then
  ok "seven deployments keep the five newest release directories"
else
  fail "seven deployments keep the five newest release directories: $(releases), current $(current)"
fi
if deploy v1.0.0 && [ "$(current)" = releases/v1.0.0 ] && [ "$(releases)" = "v1.0.0 v1.2.0 v1.3.0 v1.4.0 v1.5.0 v1.6.0" ]; then
  ok "an older current release is kept beyond the five newest"
else
  fail "an older current release is kept beyond the five newest: $(releases), current $(current)"
fi
mkdir -p "$HD/releases/notes"
if deploy v1.7.0 && [ -d "$HD/releases/notes" ] && [ -d "$HD/releases/v1.0.0" ] && [ "$(releases)" = "notes v1.0.0 v1.3.0 v1.4.0 v1.5.0 v1.6.0 v1.7.0" ]; then
  ok "the previous release is kept, and a directory that is not a release is left alone"
else
  fail "the previous release is kept, and a directory that is not a release is left alone: $(releases)"
fi

# ---------------------------------------------------------------- check
bad_env() {
  local label="$1" body="$2"
  cp "$INST/deploy/prod/host.env" "$TMP/host.env.bak"
  printf '%b' "$body" > "$INST/deploy/prod/host.env"
  commit_all "$INST"
  fresh_server
  if ! deploy v1.0.0 && [ ! -e "$STUB_STATE/ssh.log" ]; then ok "$label"; else fail "$label: $(out)"; fi
  cp "$TMP/host.env.bak" "$INST/deploy/prod/host.env"
  commit_all "$INST"
}
bad_env "check refuses a host.env without HOST_SSH" 'HOST_DOMAIN=crm.example.test\n'
bad_env "check refuses a host.env without HOST_DOMAIN" 'HOST_SSH=deploy@203.0.113.10\n'
bad_env "check refuses a HOST_SSH that starts with -" 'HOST_SSH=-oProxyCommand=x\nHOST_DOMAIN=crm.example.test\n'
bad_env "check refuses a relative HOST_DIR" 'HOST_SSH=deploy@203.0.113.10\nHOST_DOMAIN=crm.example.test\nHOST_DIR=opt/m\n'
bad_env "check refuses a HOST_DIR with a quote" "HOST_SSH=deploy@203.0.113.10\nHOST_DOMAIN=crm.example.test\nHOST_DIR=/opt/m'x\n"

if [ "$FAILURES" -gt 0 ]; then printf '\nhost.test.sh: %s failure(s)\n' "$FAILURES" >&2; exit 1; fi
printf '\nhost.test.sh: all passed\n'
