#!/usr/bin/env bash
# aio.test.sh — the all-in-one image's files and scripts/aio.sh
# (docs/superpowers/specs/2026-09-30-all-in-one-image-design.md).
#
# Static checks read scripts/aio/ as text: the nginx routes follow the host
# adapter's Caddyfile, and the start script keeps the rules no stub can see.
# The build, smoke and scripts cases run scripts/aio.sh in a scratch instance
# with stub `docker`, `make`, `go` and `curl` first on PATH; each stub appends
# one line per call to $STUB_LOG.
#
# Usage: bash scripts/aio.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
AIO="$SCRIPT_DIR/aio"

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_PREFIX
unset REGISTRY REPO PUSH DATASET METADATA_FILE AIO_PLATFORMS AIO_SMOKE_TIMEOUT
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false
export GIT_AUTHOR_NAME="Test Dev"     GIT_AUTHOR_EMAIL="dev@example.test"
export GIT_COMMITTER_NAME="Test Dev"  GIT_COMMITTER_EMAIL="dev@example.test"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILURES=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }
ok()   { printf 'ok: %s\n' "$*"; }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else fail "$what"; fi; }

# ── static: nginx ──
# Every path the Caddyfile routes to the api is routed to the api here.
for path in /v1 /v1/x /oauth/x /mcp /mcp/x /.well-known/oauth-authorization-server /.well-known/oauth-protected-resource/x /webhooks/gmail /webhooks/graph; do
  check "nginx routes $path to the api" \
    grep -qE '^[[:space:]]*location ~ \^/\(v1\(/\.\*\)\?\|oauth/\.\*\|mcp\(/\.\*\)\?\|\\\.well-known/oauth-\(authorization-server\|protected-resource\)\.\*\|webhooks/\(gmail\|graph\)\)\$' "$AIO/nginx.conf"
done
check "nginx answers 404 for /healthz, /readyz and /metrics" \
  grep -qE 'location ~ \^/\(healthz\|readyz\|metrics\)\(/\|\$\) \{ return 404; \}' "$AIO/nginx.conf"
check "nginx listens on 80 only" bash -c '[ "$(grep -cE "^[[:space:]]*listen " "$1")" = 1 ] && grep -qE "^[[:space:]]*listen 80;" "$1"' _ "$AIO/nginx.conf"
check "nginx proxies to the api on 127.0.0.1:8080" grep -q 'server 127.0.0.1:8080;' "$AIO/nginx.conf"

# ── static: margince-init ──
init="$AIO/margince-init"
check "init sets MARGINCE_ENV=test" grep -q '^export MARGINCE_ENV=test$' "$init"
check "init never reads MARGINCE_LICENSE" bash -c '! grep -q MARGINCE_LICENSE "$1"' _ "$init"
check "init gates initdb on PG_VERSION" grep -q 'PG_VERSION' "$init"
check "init writes secrets through a temporary file and a rename" bash -c 'grep -q "tmp=\"\$SECRETS.tmp\"" "$1" && grep -q "mv \"\$tmp\" \"\$SECRETS\"" "$1"' _ "$init"
check "init runs db-bootstrap.sql on every start (not inside the initdb branch)" \
  bash -c 'awk "/^if \[ ! -s \"\\\$PGDATA\/PG_VERSION\" \]/{inside=1} inside&&/^fi/{inside=0} inside&&/db-bootstrap/{bad=1} END{exit bad}" "$1"' _ "$init"
check "the worker gets neither the owner DSN nor the admin password" \
  bash -c 'sed -n "/^run_worker()/,/^)/p" "$1" | grep -q "unset MARGINCE_ADMIN_PASSWORD" && ! sed -n "/^run_worker()/,/^)/p" "$1" | grep -q MARGINCE_OWNER_DSN' _ "$init"
check "no script puts a password in curl's arguments" bash -c '! grep -nE "curl .*-d \"[^@]" "$1"/margince-*' _ "$AIO"
check "the Dockerfile's entrypoint is tini and margince-init" grep -q 'ENTRYPOINT \["/usr/bin/tini", "--", "/usr/local/bin/margince-init"\]' "$AIO/Dockerfile"
check "the Dockerfile sets no ENV" bash -c '! grep -qE "^ENV " "$1"' _ "$AIO/Dockerfile"
check "the health check asks the api for /readyz" grep -q 'http://127.0.0.1:8080/readyz' "$AIO/Dockerfile"
for f in margince-init margince-seed margince-logins; do
  check "$f passes bash -n" bash -n "$AIO/$f"
done

if [ "$FAILURES" -gt 0 ]; then printf '\naio.test.sh: %s failed\n' "$FAILURES" >&2; exit 1; fi
printf '\naio.test.sh: all passed\n'
