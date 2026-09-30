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

# ── scratch instance ──
INST="$TMP/inst"
mkdir -p "$INST/core/scripts/deploy" "$INST/core/backend" "$INST/deploy/production/config"
cp -R "$SCRIPT_DIR" "$INST/scripts"
printf 'name: acme\ndisplay_name: Acme\ncore: v0.0.2\n' > "$INST/instance.yaml"
printf -- '-- stand-in bootstrap\nSELECT 1;\n' > "$INST/core/scripts/deploy/db-bootstrap.sql"
printf 'version: 1\nworkspace:\n  name: Acme\n  base_currency: EUR\n  timezone: UTC\n' \
  > "$INST/deploy/production/config/margince.yaml"
git -C "$INST" init -q && git -C "$INST" add -A && git -C "$INST" commit -qm init
git -C "$INST/core" init -q && git -C "$INST/core" commit -q --allow-empty -m core

STUB_BIN="$TMP/stub-bin"
mkdir -p "$STUB_BIN"
export STUB_LOG="$TMP/log"

# docker: `image inspect` fails for refs listed in $STUB_MISSING (space-separated).
cat > "$STUB_BIN/docker" <<'EOF'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >> "$STUB_LOG"
case "$1 ${2:-}" in
  "image inspect")
    for m in ${STUB_MISSING:-}; do [ "$3" = "$m" ] && exit 1; done; exit 0 ;;
  "buildx version") exit 0 ;;
  "buildx build") exit 0 ;;
  "context show") echo stubctx; exit 0 ;;
esac
exit 0
EOF
cat > "$STUB_BIN/make" <<'EOF'
#!/usr/bin/env bash
printf 'make %s\n' "$*" >> "$STUB_LOG"
EOF
# go: `go run` is the real CLI (cli_run needs it); `go build -o <f>` and
# `go mod edit` are recorded and faked.
REAL_GO="$(command -v go)"
cat > "$STUB_BIN/go" <<EOF
#!/usr/bin/env bash
case "\$1" in
  build) printf 'go %s GOOS=%s GOARCH=%s CGO_ENABLED=%s\n' "\$*" "\${GOOS:-}" "\${GOARCH:-}" "\${CGO_ENABLED:-}" >> "\$STUB_LOG"
         prev=""; for a in "\$@"; do [ "\$prev" = -o ] && : > "\$a"; prev="\$a"; done; exit 0 ;;
  mod)   exit 0 ;;
esac
exec "$REAL_GO" "\$@"
EOF
chmod +x "$STUB_BIN"/*

aio() { (cd "$INST" && PATH="$STUB_BIN:$PATH" bash scripts/aio.sh "$@"); }
reset_log() { : > "$STUB_LOG"; }

reset_log
if aio build 1.0 >/dev/null 2>"$TMP/err"; then fail "build refuses a non-release version"; else
  check "build refuses a non-release version, naming VERSION" grep -q 'VERSION=<release version>' "$TMP/err"; fi

reset_log
aio build v1.0.0 >/dev/null 2>&1 || true
check "build with all role images present does not run make package" bash -c '! grep -q "^make .*package" "$1"' _ "$STUB_LOG"
check "build passes the three role images" grep -q -- '--build-arg API_IMAGE=acme/api:v1.0.0 --build-arg WORKER_IMAGE=acme/worker:v1.0.0 --build-arg WEB_IMAGE=acme/web:v1.0.0' "$STUB_LOG"
check "build tags acme/all-in-one:v1.0.0 and loads it" bash -c 'grep "buildx build" "$1" | grep -q -- "--load" && grep "buildx build" "$1" | grep -q -- "-t acme/all-in-one:v1.0.0"' _ "$STUB_LOG"
# A loaded build reads the role images from the local image store, which only
# the docker-driver builder of the current context can see (a docker-container
# builder, the default after setup-buildx-action, cannot).
check "a loaded build uses the current context's docker-driver builder" bash -c 'grep "buildx build" "$1" | grep -q -- "--builder stubctx --load"' _ "$STUB_LOG"
check "build labels the image with the instance and core" bash -c 'grep "buildx build" "$1" | grep -q "com.margince.instance.name=acme" && grep "buildx build" "$1" | grep -q "com.margince.core.version=v0.0.2"' _ "$STUB_LOG"
check "the context holds the scripts, the configuration and db-bootstrap.sql" bash -c 'for f in Dockerfile nginx.conf margince-init margince-seed margince-logins margince.yaml db-bootstrap.sql; do [ -f "$1/build/aio/$f" ] || exit 1; done' _ "$INST"
check "the context's configuration signs in as admin@localhost" grep -q 'admin@localhost' "$INST/build/aio/margince.yaml"
check "without DATASET the context has no seeder and no dataset" bash -c '[ -z "$(ls -A "$1/build/aio/seed")" ] && [ -z "$(ls -A "$1/build/aio/demo")" ]' _ "$INST"

reset_log
STUB_MISSING="acme/web:v1.0.0" aio build v1.0.0 >/dev/null 2>&1 || true
check "a missing role image runs make package VERSION=v1.0.0" grep -q '^make -C .* package VERSION=v1.0.0$' "$STUB_LOG"

reset_log
if (export PUSH=1; aio build v1.0.0) >/dev/null 2>"$TMP/err"; then fail "PUSH=1 without REGISTRY is refused"; else
  check "PUSH=1 without REGISTRY is refused" grep -q 'requires REGISTRY' "$TMP/err"; fi

reset_log
(export PUSH=1 REGISTRY=registry.example.test/acme; aio build v1.0.0) >/dev/null 2>&1 || true
check "PUSH=1 pushes both platforms under the registry" bash -c 'grep "buildx build" "$1" | grep -q -- "--push --platform linux/amd64,linux/arm64" && grep "buildx build" "$1" | grep -q -- "-t registry.example.test/acme/acme/all-in-one:v1.0.0"' _ "$STUB_LOG"
check "PUSH=1 uses the default builder" bash -c '! grep "buildx build" "$1" | grep -q -- "--builder"' _ "$STUB_LOG"
check "PUSH=1 does not look for local role images" bash -c '! grep -q "image inspect" "$1"' _ "$STUB_LOG"

# A dataset checkout with the seeder's source.
DS="$TMP/dataset"
mkdir -p "$DS/datasets/v1" "$DS/tools/seed-demo" "$DS/.git"
printf '{}\n' > "$DS/datasets/v1/demo.json"
printf 'module x\n' > "$DS/tools/seed-demo/go.mod"

reset_log
DATASET="$DS" aio build v1.0.0 >/dev/null 2>&1 || true
check "DATASET builds the seeder for linux/amd64 and linux/arm64 without cgo" bash -c 'grep -q "GOOS=linux GOARCH=amd64 CGO_ENABLED=0" "$1" && grep -q "GOOS=linux GOARCH=arm64 CGO_ENABLED=0" "$1"' _ "$STUB_LOG"
check "DATASET puts both seeders in the context" bash -c '[ -f "$1/build/aio/seed/seed-demo-amd64" ] && [ -f "$1/build/aio/seed/seed-demo-arm64" ]' _ "$INST"
check "DATASET copies the dataset without .git and tools" bash -c '[ -f "$1/build/aio/demo/datasets/v1/demo.json" ] && [ ! -e "$1/build/aio/demo/.git" ] && [ ! -e "$1/build/aio/demo/tools" ]' _ "$INST"

sed -i.bak 's/EUR/USD/' "$INST/deploy/production/config/margince.yaml"
reset_log
DATASET="$DS" aio build v1.0.0 >"$TMP/out" 2>&1 || true
check "a non-EUR workspace gets a notice and no dataset" bash -c 'grep -q "euro-based" "$1" && [ -z "$(ls -A "$2/build/aio/demo")" ]' _ "$TMP/out" "$INST"
mv "$INST/deploy/production/config/margince.yaml.bak" "$INST/deploy/production/config/margince.yaml"

rm -rf "$INST/deploy"
reset_log
aio build v1.0.0 >/dev/null 2>&1 || true
check "without deploy/production the workspace is named after display_name" grep -q 'name: Acme' "$INST/build/aio/margince.yaml"

cat > "$STUB_BIN/docker" <<'EOF'
#!/usr/bin/env bash
printf 'docker %s\n' "$*" >> "$STUB_LOG"
case "$1 ${2:-}" in
  "image inspect")
    for m in ${STUB_MISSING:-}; do [ "$3" = "$m" ] && exit 1; done; exit 0 ;;
  "buildx version"|"buildx build") exit 0 ;;
  "context show") echo stubctx; exit 0 ;;
  "port "*) echo "127.0.0.1:49999"; exit 0 ;;
  "inspect "*)
    case "$*" in
      *Health*) echo "${STUB_HEALTH:-healthy}" ;;
      *State.Status*) echo running ;;
    esac
    exit 0 ;;
  "exec "*)
    case "$*" in
      *sha256sum*) echo "abc  /data/secrets.env" ;;
      *) echo "generated-password" ;;
    esac
    exit 0 ;;
  "logs "*) echo "stub log line"; exit 0 ;;
esac
exit 0
EOF
cat > "$STUB_BIN/curl" <<'EOF'
#!/usr/bin/env bash
printf 'curl %s\n' "$*" >> "$STUB_LOG"
stdin=""; case "$*" in *"--data-binary @-"*) stdin="$(cat)" ;; esac
[ -n "$stdin" ] && printf 'curl-stdin %s\n' "$stdin" >> "$STUB_STDIN_LOG"
case "$*" in
  *"%{http_code}"*readyz*) echo 404 ;;
  *"%{http_code}"*auth/login*) [ "${STUB_LOGIN_FAIL:-}" = 1 ] && echo 401 || echo 200 ;;
  *) echo '<!doctype html><html><div id="root"></div></html>' ;;
esac
EOF
chmod +x "$STUB_BIN"/*
export STUB_STDIN_LOG="$TMP/stdin-log"

reset_log; : > "$STUB_STDIN_LOG"
if aio smoke v1.0.0 >"$TMP/out" 2>&1; then ok "smoke passes against a healthy image"; else fail "smoke passes against a healthy image"; cat "$TMP/out" >&2; fi
check "smoke runs the image on a temporary volume, published on 127.0.0.1" bash -c 'grep "^docker run" "$1" | grep -q -- "-p 127.0.0.1::80" && grep "^docker run" "$1" | grep -qE -- "-v margince-aio-smoke-[0-9]+-data:/data acme/all-in-one:v1.0.0"' _ "$STUB_LOG"
check "smoke restarts the container once" grep -q '^docker restart margince-aio-smoke-' "$STUB_LOG"
check "smoke removes the container and the volume" bash -c 'grep -q "^docker rm -f -v margince-aio-smoke-" "$1" && grep -q "^docker volume rm -f margince-aio-smoke-" "$1"' _ "$STUB_LOG"
check "smoke never puts the password in an argument" bash -c '! grep -q generated-password "$1"' _ "$STUB_LOG"
check "smoke sends the password on standard input" grep -q 'generated-password' "$STUB_STDIN_LOG"

reset_log
if STUB_LOGIN_FAIL=1 aio smoke v1.0.0 >"$TMP/out" 2>&1; then fail "smoke fails when sign-in fails"; else
  check "smoke fails when sign-in fails, prints the log, and still cleans up" bash -c 'grep -q "stub log line" "$1" && grep -q "^docker rm -f -v" "$2"' _ "$TMP/out" "$STUB_LOG"; fi

reset_log
if STUB_MISSING="acme/all-in-one:v1.0.0" aio smoke v1.0.0 >/dev/null 2>"$TMP/err"; then fail "smoke without the image is refused"; else
  check "smoke without the image names make aio" grep -q 'make aio VERSION=v1.0.0' "$TMP/err"; fi

reset_log
if STUB_HEALTH=unhealthy AIO_SMOKE_TIMEOUT=1 aio smoke v1.0.0 >/dev/null 2>&1; then fail "smoke fails when the container never becomes healthy"; else ok "smoke fails when the container never becomes healthy"; fi

# ── install.sh wrappers ──
# A stub sh records how scripts/aio.sh calls install.sh.
cat > "$STUB_BIN/sh" <<'EOF'
#!/bin/bash
printf 'sh %s\n' "$*" >> "$STUB_LOG"
EOF
chmod +x "$STUB_BIN/sh"
reset_log
aio up v1.0.0 >/dev/null 2>&1 || true
check "aio-up runs install.sh up with the image, container and volume" \
  grep -qE '^sh .*/scripts/aio/install.sh up --image acme/all-in-one:v1.0.0 --container margince-acme --volume margince-acme-data$' "$STUB_LOG"
reset_log
aio down >/dev/null 2>&1 || true
check "aio-down runs install.sh down with the container and volume" \
  grep -qE '^sh .*/scripts/aio/install.sh down --image .* --container margince-acme --volume margince-acme-data$' "$STUB_LOG"
if aio up >/dev/null 2>&1; then fail "aio-up without VERSION is refused"; else ok "aio-up without VERSION is refused"; fi
rm -f "$STUB_BIN/sh"

reset_log
aio scripts v1.0.0 >/dev/null 2>&1 || true
out="$INST/dist/aio/v1.0.0"
check "aio-scripts writes install.sh and install.ps1" bash -c '[ -x "$1/install.sh" ] && [ -f "$1/install.ps1" ]' _ "$out"
check "aio-scripts fills in the image, container and volume" bash -c 'for f in install.sh install.ps1; do grep -q "acme/all-in-one:v1.0.0" "$1/$f" && grep -q "margince-acme-data" "$1/$f" || exit 1; done' _ "$out"
check "aio-scripts leaves no placeholder" bash -c '! grep -nE "@(IMAGE|CONTAINER|VOLUME)@" "$1"/install.*' _ "$out"
if aio scripts v1 >/dev/null 2>&1; then fail "aio-scripts refuses a non-release version"; else ok "aio-scripts refuses a non-release version"; fi

if [ "$FAILURES" -gt 0 ]; then printf '\naio.test.sh: %s failed\n' "$FAILURES" >&2; exit 1; fi
printf '\naio.test.sh: all passed\n'
