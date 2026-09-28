#!/usr/bin/env bash
# smoke.test.sh — scripts/smoke.sh: the three role images start and answer,
# and everything the smoke test started is removed, on success and on failure.
#
# Stub `docker` and `curl`, first on PATH, never reach a daemon or a network.
# Both append one line per call to a shared log, so a case can assert what ran,
# in which order, and what was removed. The stubs read their behavior from
# environment variables:
#
#   STUB_MISSING_IMAGE   an image reference `docker image inspect` does not find
#   STUB_NOT_READY=1     curl on /readyz fails
#   STUB_WORKER_DEAD=1   `docker inspect` reports the worker container not running
#
# The scratch instance holds this repository's scripts/, an instance.yaml named
# acme, and a stand-in core/scripts/deploy/db-bootstrap.sql.
#
# Usage: bash scripts/smoke.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_PREFIX
unset REGISTRY SMOKE_TIMEOUT SMOKE_SETTLE STUB_MISSING_IMAGE STUB_NOT_READY STUB_WORKER_DEAD
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false
export GIT_AUTHOR_NAME="Test Dev"     GIT_AUTHOR_EMAIL="dev@example.test"
export GIT_COMMITTER_NAME="Test Dev"  GIT_COMMITTER_EMAIL="dev@example.test"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILURES=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }
ok()   { printf 'ok: %s\n' "$*"; }

INST="$TMP/inst"
mkdir -p "$INST/core/scripts/deploy"
cp -R "$SCRIPT_DIR" "$INST/scripts"
printf 'name: acme\ndisplay_name: Acme\ncore: v0.0.2\n' > "$INST/instance.yaml"
printf -- '-- stand-in bootstrap\nSELECT 1;\n' > "$INST/core/scripts/deploy/db-bootstrap.sql"

STUB_BIN="$TMP/stub-bin"
mkdir -p "$STUB_BIN"
export STUB_LOG="$TMP/log"
export STUB_STATE="$TMP/state"

cat > "$STUB_BIN/docker" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'docker %s\n' "$*" >> "$STUB_LOG"
case "${1:-}" in
  image)
    # docker image inspect <ref>
    [ "${3:-}" = "${STUB_MISSING_IMAGE:-}" ] && { echo "Error: No such image: $3" >&2; exit 1; }
    exit 0 ;;
  network) exit 0 ;;
  run)
    name=""
    prev=""
    for a in "$@"; do
      [ "$prev" = "--name" ] && name="$a"
      prev="$a"
    done
    printf '%s\n' "$name" >> "$STUB_STATE"
    printf 'id-%s\n' "$name"
    exit 0 ;;
  exec)
    # psql reads the bootstrap from standard input.
    cat >/dev/null 2>&1 || true
    exit 0 ;;
  port) printf '127.0.0.1:18080\n'; exit 0 ;;
  inspect)
    last=""
    for a in "$@"; do last="$a"; done
    case "$last" in
      *-worker) [ "${STUB_WORKER_DEAD:-}" = 1 ] && { echo false; exit 0; } ;;
    esac
    echo true; exit 0 ;;
  logs)
    last=""
    for a in "$@"; do last="$a"; done
    printf 'stub log line of %s\n' "$last"
    exit 0 ;;
  rm) exit 0 ;;
esac
exit 0
EOF

cat > "$STUB_BIN/curl" <<'EOF'
#!/usr/bin/env bash
set -u
printf 'curl %s\n' "$*" >> "$STUB_LOG"
for a in "$@"; do
  case "$a" in
    */readyz) [ "${STUB_NOT_READY:-}" = 1 ] && exit 22 ;;
  esac
done
exit 0
EOF
chmod +x "$STUB_BIN/docker" "$STUB_BIN/curl"
export PATH="$STUB_BIN:$PATH"

# run_smoke <version> [VAR=value...] — output in $TMP/out, exit code echoed.
run_smoke() {
  local version="$1"; shift
  : > "$STUB_LOG"; : > "$STUB_STATE"
  local rc=0
  (cd "$INST" && env SMOKE_SETTLE=0 "$@" bash scripts/smoke.sh "$version") > "$TMP/out" 2>&1 || rc=$?
  printf '%s' "$rc"
}

# Every container `docker run --name` started is named in a `docker rm -f`,
# and every network created is removed.
all_removed() {
  local name net
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    grep -E "^docker rm .*(^| )$name( |$)" "$STUB_LOG" >/dev/null || return 1
  done < "$STUB_STATE"
  net="$(sed -n 's/^docker network create \([^ ]*\).*/\1/p' "$STUB_LOG")"
  [ -n "$net" ] || return 1
  grep -qx "docker network rm $net" "$STUB_LOG"
}

# --- invalid VERSION: exit 1 before any docker call ---
rc="$(run_smoke 1.0.0)"
if [ "$rc" = 1 ]; then ok "an invalid VERSION exits 1"; else fail "an invalid VERSION exits 1 (rc=$rc)"; fi
if [ ! -s "$STUB_LOG" ]; then ok "an invalid VERSION makes no docker call"; else fail "an invalid VERSION makes no docker call: $(cat "$STUB_LOG")"; fi

rc="$(run_smoke v1.2.0-rc.0)"
if [ "$rc" = 1 ] && [ ! -s "$STUB_LOG" ]; then ok "v1.2.0-rc.0 is refused before docker"; else fail "v1.2.0-rc.0 is refused before docker (rc=$rc)"; fi

# --- a missing image: exit 1 before any container starts ---
rc="$(run_smoke v1.0.0 STUB_MISSING_IMAGE=acme/worker:v1.0.0)"
if [ "$rc" = 1 ]; then ok "a missing image exits 1"; else fail "a missing image exits 1 (rc=$rc)"; fi
if ! grep -qE '^docker (run|network create)' "$STUB_LOG"; then ok "a missing image starts no container and no network"; else fail "a missing image starts no container and no network: $(cat "$STUB_LOG")"; fi
if grep -q 'acme/worker:v1.0.0' "$TMP/out"; then ok "a missing image is named"; else fail "a missing image is named: $(cat "$TMP/out")"; fi
if grep -qx 'docker image inspect acme/api:v1.0.0' "$STUB_LOG" \
   && grep -qx 'docker image inspect acme/web:v1.0.0' "$STUB_LOG"; then
  ok "all three images are inspected"
else
  fail "all three images are inspected: $(cat "$STUB_LOG")"
fi

# --- success ---
rc="$(run_smoke v1.0.0)"
if [ "$rc" = 0 ]; then ok "a healthy set passes"; else fail "a healthy set passes (rc=$rc): $(cat "$TMP/out")"; fi
if all_removed; then ok "success removes every container and the network"; else fail "success removes every container and the network: $(cat "$STUB_LOG")"; fi
if grep -qE '^docker network create margince-smoke-[a-z0-9]+' "$STUB_LOG"; then ok "the network is margince-smoke-<random>"; else fail "the network is margince-smoke-<random>"; fi
for img in pgvector/pgvector:pg16 redis:7 acme/api:v1.0.0 acme/worker:v1.0.0 acme/web:v1.0.0; do
  if grep -E "^docker run .* $img( |$)" "$STUB_LOG" >/dev/null; then ok "starts $img"; else fail "starts $img"; fi
done
if grep -qE '^docker exec -i .* psql ' "$STUB_LOG"; then ok "bootstraps the database with psql"; else fail "bootstraps the database with psql"; fi
if grep -E '^curl .*/readyz' "$STUB_LOG" >/dev/null && grep -E '^curl .*:18080/$' "$STUB_LOG" >/dev/null; then
  ok "polls api /readyz and web /"
else
  fail "polls api /readyz and web /: $(grep '^curl' "$STUB_LOG" || true)"
fi
ready_line="$(grep -nE '^curl .*/readyz' "$STUB_LOG" | head -1 | cut -d: -f1 || true)"
worker_line="$(grep -nE '^docker run .* acme/worker:v1.0.0' "$STUB_LOG" | head -1 | cut -d: -f1 || true)"
if [ -n "$ready_line" ] && [ -n "$worker_line" ] && [ "$ready_line" -lt "$worker_line" ]; then
  ok "the worker starts after the api is ready"
else
  fail "the worker starts after the api is ready (readyz line $ready_line, worker line $worker_line)"
fi
api_run="$(grep -E '^docker run .* acme/api:v1.0.0' "$STUB_LOG" || true)"
for v in MARGINCE_OWNER_DSN MARGINCE_DSN MARGINCE_REDIS MARGINCE_ENV MARGINCE_CONFIG MARGINCE_ADMIN_PASSWORD \
         MARGINCE_KEYVAULT_ROOT_KEY MARGINCE_CONNECTOR_STATE_KEY MARGINCE_WEBHOOK_KEY; do
  if printf '%s\n' "$api_run" | grep -qE -- "-e $v( |$)"; then ok "api receives $v"; else fail "api receives $v: $api_run"; fi
done
# The vault, connector-state and webhook keys, so /readyz exercises the vault
# probe and the worker's webhook delivery lane is on too — the smoke test used
# to run every image without them.
worker_run="$(grep -E '^docker run .* acme/worker:v1.0.0' "$STUB_LOG" || true)"
for v in MARGINCE_KEYVAULT_ROOT_KEY MARGINCE_CONNECTOR_STATE_KEY MARGINCE_WEBHOOK_KEY; do
  if printf '%s\n' "$worker_run" | grep -qE -- "-e $v( |$)"; then ok "worker receives $v"; else fail "worker receives $v: $worker_run"; fi
done
if grep -qE 'postgres://|PASSWORD=|MARGINCE_(KEYVAULT_ROOT_KEY|CONNECTOR_STATE_KEY|WEBHOOK_KEY)=' "$STUB_LOG"; then
  fail "a DSN, password or generated key reaches docker's argv: $(grep -E 'postgres://|PASSWORD=|MARGINCE_(KEYVAULT_ROOT_KEY|CONNECTOR_STATE_KEY|WEBHOOK_KEY)=' "$STUB_LOG")"
else
  ok "no DSN, password or generated key reaches docker's argv"
fi
if grep -qE 'postgres://|PASSWORD=|MARGINCE_(KEYVAULT_ROOT_KEY|CONNECTOR_STATE_KEY|WEBHOOK_KEY)=' "$TMP/out"; then
  fail "a DSN, password or generated key reaches smoke's own output: $(cat "$TMP/out")"
else
  ok "no DSN, password or generated key reaches smoke's own output"
fi
if grep -q '^docker logs' "$STUB_LOG"; then fail "success prints no container logs"; else ok "success prints no container logs"; fi

# --- readiness timeout ---
start=$SECONDS
rc="$(run_smoke v1.0.0 SMOKE_TIMEOUT=2 STUB_NOT_READY=1)"
elapsed=$((SECONDS - start))
if [ "$rc" = 1 ]; then ok "a readiness timeout exits 1"; else fail "a readiness timeout exits 1 (rc=$rc)"; fi
if [ "$elapsed" -lt 30 ]; then ok "SMOKE_TIMEOUT bounds the wait (${elapsed}s)"; else fail "SMOKE_TIMEOUT bounds the wait (${elapsed}s)"; fi
if grep -qE '^docker logs --tail 100 .*-api$' "$STUB_LOG" && grep -q 'stub log line of .*-api' "$TMP/out"; then
  ok "a readiness timeout prints the api's last 100 log lines"
else
  fail "a readiness timeout prints the api's last 100 log lines: $(cat "$TMP/out")"
fi
if grep -qE '^docker logs .*(pg|redis)$' "$STUB_LOG"; then fail "only Margince containers' logs are printed"; else ok "only Margince containers' logs are printed"; fi
if all_removed; then ok "a readiness timeout still removes everything"; else fail "a readiness timeout still removes everything: $(cat "$STUB_LOG")"; fi

# --- worker not running ---
rc="$(run_smoke v1.0.0 STUB_WORKER_DEAD=1)"
if [ "$rc" = 1 ]; then ok "a worker that is not running exits 1"; else fail "a worker that is not running exits 1 (rc=$rc)"; fi
if grep -qE '^docker logs --tail 100 .*-worker$' "$STUB_LOG"; then ok "a dead worker's logs are printed"; else fail "a dead worker's logs are printed"; fi
if all_removed; then ok "a dead worker still removes everything"; else fail "a dead worker still removes everything"; fi

# --- REGISTRY names the images ---
rc="$(run_smoke v1.0.0 REGISTRY=registry.example.test)"
if [ "$rc" = 0 ] && grep -qx 'docker image inspect registry.example.test/acme/api:v1.0.0' "$STUB_LOG"; then
  ok "REGISTRY prefixes the image names"
else
  fail "REGISTRY prefixes the image names (rc=$rc): $(grep 'image inspect' "$STUB_LOG" || true)"
fi

if [ "$FAILURES" -gt 0 ]; then
  printf '\n%d check(s) failed\n' "$FAILURES" >&2
  exit 1
fi
printf '\nsmoke: all checks passed\n'
