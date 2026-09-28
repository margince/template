#!/usr/bin/env bash
# local.test.sh — make local-up, make local-down and make local-admin-password
# (scripts/local.sh; design Section 9.7).
#
# The scratch instance has this repository's scripts/ and Makefile, a
# stand-in core/scripts/deploy/db-bootstrap.sql and an instance.yaml named
# acme. docker and curl are the stubs in scripts/deploy/host/test-stubs/;
# lsof is a stub written here: it reports a listener on a port when
# $STUB_STATE/lsof-<port> exists (its content is lsof's output). No image,
# container, port or network is used.
#
# Usage: bash scripts/local.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
STUBS="$SCRIPT_DIR/deploy/host/test-stubs"

unset MARGINCE_DSN MARGINCE_REDIS MARGINCE_OWNER_DSN MARGINCE_PUBLIC_BASE_URL COMPOSE_PROFILES REGISTRY MARGINCE_ENV
unset MARGINCE_LICENSE MARGINCE_ADMIN_PASSWORD MARGINCE_KEYVAULT_ROOT_KEY MARGINCE_CONNECTOR_STATE_KEY MARGINCE_WEBHOOK_KEY
unset MARGINCE_BLOBSTORE_ENDPOINT MARGINCE_BLOBSTORE_PATH HOST_DOMAIN HOST_DIR WIPE VERSION
unset MAKEFLAGS MAKELEVEL MFLAGS

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILURES=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }
ok()   { printf 'ok: %s\n' "$*"; }
mode_of() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

INST="$TMP/inst"
L="$INST/.local"
mkdir -p "$INST/core/scripts/deploy" "$TMP/bin"
cp -R "$SCRIPT_DIR" "$INST/scripts"
cp "$SCRIPT_DIR/../Makefile" "$INST/Makefile"
printf 'name: acme\ndisplay_name: Acme "Test"\ncore: v0.0.2\n' > "$INST/instance.yaml"
printf -- '-- stand-in bootstrap\nSELECT 1;\n' > "$INST/core/scripts/deploy/db-bootstrap.sql"

cat > "$TMP/bin/lsof" <<'EOF'
#!/usr/bin/env bash
# Test stub for lsof: a listener on <port> when $STUB_STATE/lsof-<port> exists.
set -euo pipefail
: "${STUB_STATE:?STUB_STATE is not set}"
printf '%s\n' "$*" >> "$STUB_STATE/lsof.log"
for a in "$@"; do
  case "$a" in
    -iTCP:*)
      p="${a#-iTCP:}"
      if [ -f "$STUB_STATE/lsof-$p" ]; then cat "$STUB_STATE/lsof-$p"; exit 0; fi ;;
  esac
done
exit 1
EOF
chmod +x "$TMP/bin/lsof"

export PATH="$TMP/bin:$STUBS:$PATH"
export LOCAL_INTERVAL=0

# reset — a new stub state; .local/ removed.
reset() {
  rm -rf "$L" "$TMP/state"
  mkdir -p "$TMP/state"
  export STUB_STATE="$TMP/state"
}
run_make() { (cd "$INST" && env "$@") </dev/null > "$TMP/out" 2>&1; }
compose_calls() { grep '^compose ' "$STUB_STATE/docker.log" 2>/dev/null || true; }

# --- a VERSION that is not a release version: nothing happens ---
reset
if run_make make local-up VERSION=latest; then
  fail "local-up accepted VERSION=latest"
elif [ -e "$L" ] || [ -n "$(compose_calls)" ]; then
  fail "local-up with a bad VERSION created .local/ or ran compose"
elif ! grep -q "VERSION" "$TMP/out"; then
  fail "local-up with a bad VERSION does not name VERSION: $(cat "$TMP/out")"
else
  ok "local-up refuses a VERSION that is not a release version"
fi
reset
if run_make make local-up; then fail "local-up without VERSION succeeded"; else ok "local-up needs VERSION"; fi

# --- a missing image fails before compose, suggesting make package ---
reset
printf 'acme/web:v1.0.0\n' > "$STUB_STATE/fail.image"
if run_make make local-up VERSION=v1.0.0; then
  fail "local-up succeeded with a missing image"
elif [ -e "$L" ] || [ -n "$(compose_calls)" ]; then
  fail "local-up with a missing image created .local/ or ran compose"
elif ! grep -q "acme/web:v1.0.0" "$TMP/out" || ! grep -q "make package VERSION=v1.0.0" "$TMP/out"; then
  fail "the missing-image failure does not name the image and make package: $(cat "$TMP/out")"
elif grep -q "acme/api:v1.0.0" "$TMP/out"; then
  fail "the missing-image failure names an image that exists: $(cat "$TMP/out")"
else
  ok "a missing image fails before anything starts and suggests make package"
fi

# --- a busy port fails, naming the process, before anything starts ---
reset
printf 'COMMAND   PID USER   FD   TYPE DEVICE SIZE/OFF NODE NAME\nnginx   4242 root    6u  IPv4 0x1      0t0  TCP *:443 (LISTEN)\n' > "$STUB_STATE/lsof-443"
if run_make make local-up VERSION=v1.0.0; then
  fail "local-up succeeded with port 443 in use"
elif [ -e "$L" ] || [ -n "$(compose_calls)" ]; then
  fail "local-up with a busy port created .local/ or ran compose"
elif ! grep -q "443" "$TMP/out" || ! grep -q "nginx" "$TMP/out" || ! grep -q "4242" "$TMP/out"; then
  fail "the busy-port failure does not name the port and the process: $(cat "$TMP/out")"
else
  ok "a busy port fails, naming the process, before anything starts"
fi

# --- without lsof: a port that accepts a connection fails, by number ---
# Two free high ports (LOCAL_PORTS and LOCAL_LSOF are local.sh's internal
# test overrides); a real listener on the first one, on 127.0.0.1 only.
reset
read -r P1 P2 < <(python3 -c 'import socket
s=[socket.socket() for _ in range(2)]
[x.bind(("127.0.0.1",0)) for x in s]
print(*[x.getsockname()[1] for x in s])')
python3 -c 'import socket,sys,time
s=socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", int(sys.argv[1]))); s.listen(8)
open(sys.argv[2], "w").close()
time.sleep(60)' "$P1" "$TMP/listening" &
LISTENER=$!
for _ in $(seq 1 100); do [ -e "$TMP/listening" ] && break; sleep 0.05; done
if run_make env LOCAL_LSOF=no-such-lsof LOCAL_PORTS="$P1 $P2" make local-up VERSION=v1.0.0; then
  fail "local-up without lsof succeeded with port $P1 in use"
elif [ -e "$L" ] || [ -n "$(compose_calls)" ]; then
  fail "local-up without lsof and a busy port created .local/ or ran compose"
elif ! grep -q "port $P1 is in use" "$TMP/out" || ! grep -q "lsof" "$TMP/out" || grep -q "port $P2 is in use" "$TMP/out"; then
  fail "the busy-port failure without lsof does not name exactly port $P1 and lsof: $(cat "$TMP/out")"
else
  ok "without lsof, a busy port fails before anything starts, naming the port"
fi
kill "$LISTENER" 2>/dev/null || true
wait "$LISTENER" 2>/dev/null || true
reset
if run_make env LOCAL_LSOF=no-such-lsof LOCAL_PORTS="$P1 $P2" make local-up VERSION=v1.0.0; then
  ok "without lsof, free ports pass the check"
else
  fail "local-up without lsof failed with free ports: $(cat "$TMP/out")"
fi

# --- the first local-up ---
reset
export MARGINCE_DSN=postgres://x@ext/db MARGINCE_REDIS=ext:6379
if ! run_make make local-up VERSION=v1.0.0; then
  fail "the first local-up failed: $(cat "$TMP/out")"
else
  ok "the first local-up succeeds"
fi
unset MARGINCE_DSN MARGINCE_REDIS
rel="$L/releases/v1.0.0"
for f in "$L/shared/data.env" "$L/shared/instance.env" "$rel/.env"; do
  if [ ! -f "$f" ]; then fail "${f#"$INST/"} is missing"
  elif [ "$(mode_of "$f")" != 600 ]; then fail "${f#"$INST/"} has mode $(mode_of "$f"), want 600"
  else ok "${f#"$INST/"} exists with mode 600"; fi
done
for f in "$rel/compose.yaml" "$rel/compose.env" "$rel/config/margince.yaml" "$L/shared/caddy/Caddyfile" "$L/shared/db-init.sh" "$L/shared/db-bootstrap.sql"; do
  [ -f "$f" ] && ok "${f#"$INST/"} exists" || fail "${f#"$INST/"} is missing"
done
if [ -L "$L/current" ] && [ "$(readlink "$L/current")" = releases/v1.0.0 ]; then
  ok "current points at releases/v1.0.0"
else
  fail "current does not point at releases/v1.0.0: $(readlink "$L/current" 2>/dev/null || echo none)"
fi
for key in MARGINCE_KEYVAULT_ROOT_KEY MARGINCE_CONNECTOR_STATE_KEY MARGINCE_WEBHOOK_KEY MARGINCE_ADMIN_PASSWORD; do
  grep -q "^$key=." "$L/shared/instance.env" && ok "instance.env has $key" || fail "instance.env has no $key"
done
grep -qx 'HOST_DOMAIN=localhost' "$rel/compose.env" && ok "HOST_DOMAIN is localhost" || fail "compose.env: $(cat "$rel/compose.env")"
grep -qx 'COMPOSE_PROFILES=local-data' "$rel/compose.env" &&
  ok "local-up runs the local postgres and redis, even with MARGINCE_DSN and MARGINCE_REDIS in the shell" ||
  fail "compose.env: $(cat "$rel/compose.env")"
grep -qx 'MARGINCE_ENV=test' "$rel/.env" && ok "MARGINCE_ENV=test without MARGINCE_LICENSE" || fail ".env has no MARGINCE_ENV=test"
grep -qx 'MARGINCE_PUBLIC_BASE_URL=https://localhost' "$rel/.env" && ok "the public base URL is https://localhost" || fail ".env has no https://localhost base URL"
grep -q '^MARGINCE_LICENSE=' "$rel/.env" && fail ".env has MARGINCE_LICENSE without one set" || ok "no MARGINCE_LICENSE without one set"
if grep -q 'name: "Acme \\"Test\\""' "$rel/config/margince.yaml" && grep -q 'email: "admin@localhost"' "$rel/config/margince.yaml" &&
   grep -q 'password_file: secrets/admin-password' "$rel/config/margince.yaml" && grep -q 'connector_enabled: false' "$rel/config/margince.yaml"; then
  ok "config/margince.yaml has the display name, admin@localhost, the password file and MCP off"
else
  fail "config/margince.yaml: $(cat "$rel/config/margince.yaml")"
fi
if compose_calls | grep -qF -- "compose -p acme-local -f $rel/compose.yaml --env-file $rel/compose.env up -d --remove-orphans"; then
  ok "compose up runs with -p acme-local and --env-file compose.env"
else
  fail "no compose up with the right arguments: $(compose_calls)"
fi
if grep -qE -- '(^| )-[a-zA-Z]*k( |$)' "$STUB_STATE/curl.log" && grep -q 'https://localhost/' "$STUB_STATE/curl.log"; then
  ok "local-up waits for https://localhost/ with curl -k"
else
  fail "curl.log: $(cat "$STUB_STATE/curl.log" 2>/dev/null)"
fi
if grep -q 'https://localhost' "$TMP/out" && grep -q 'admin@localhost' "$TMP/out" &&
   grep -q 'make local-admin-password' "$TMP/out" && grep -qi 'certificate' "$TMP/out"; then
  ok "local-up prints the URL, the admin email, make local-admin-password and the certificate warning"
else
  fail "local-up output: $(cat "$TMP/out")"
fi
leaked=""
while IFS='=' read -r k v; do
  [ -n "$v" ] || continue
  if grep -qF -- "$v" "$TMP/out" "$STUB_STATE/docker.log" "$STUB_STATE/curl.log"; then leaked="$leaked $k"; fi
done < <(cat "$L/shared/instance.env" "$L/shared/data.env")
[ -z "$leaked" ] && ok "no generated value is printed or on a command line" || fail "printed or on a command line:$leaked"
cp "$L/shared/instance.env" "$TMP/instance.env.1"
cp "$L/shared/data.env" "$TMP/data.env.1"

# --- the admin password is printed only by local-admin-password ---
pw="$(sed -n 's/^MARGINCE_ADMIN_PASSWORD=//p' "$L/shared/instance.env")"
if run_make make local-admin-password && [ "$(cat "$TMP/out")" = "$pw" ]; then
  ok "local-admin-password prints exactly the generated password"
else
  fail "local-admin-password: $(cat "$TMP/out")"
fi

# --- a second local-up, same version, with our caddy on the ports ---
: > "$STUB_STATE/docker.log"
printf 'COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME\ncom.docke 999 dev 100u IPv6 0x2 0t0 TCP *:80 (LISTEN)\n' > "$STUB_STATE/lsof-80"
cp "$STUB_STATE/lsof-80" "$STUB_STATE/lsof-443"
printf 'abc123\n' > "$STUB_STATE/docker-ps"
printf '# changed by hand\n' >> "$L/shared/caddy/Caddyfile"
if ! run_make make local-up VERSION=v1.0.0; then
  fail "the second local-up failed (its own caddy holds the ports): $(cat "$TMP/out")"
elif cmp -s "$TMP/instance.env.1" "$L/shared/instance.env" && cmp -s "$TMP/data.env.1" "$L/shared/data.env"; then
  ok "a second local-up keeps instance.env and data.env byte-identical, with its own caddy on the ports"
else
  fail "the second local-up changed instance.env or data.env"
fi
if grep -q 'exec -T caddy caddy reload' "$STUB_STATE/docker.log" && cmp -s "$INST/scripts/deploy/host/Caddyfile" "$L/shared/caddy/Caddyfile"; then
  ok "a changed Caddyfile is replaced and caddy reloaded"
else
  fail "no caddy reload after a Caddyfile change: $(compose_calls)"
fi
grep -q "$pw" "$TMP/out" && fail "the second local-up printed the password" || ok "local-up does not print the password"
rm -f "$STUB_STATE/lsof-80" "$STUB_STATE/lsof-443" "$STUB_STATE/docker-ps"

# --- a new version keeps the keys; a license switches to production mode ---
: > "$STUB_STATE/docker.log"
if ! MARGINCE_LICENSE='lic-secret-value' run_make make local-up VERSION=v1.1.0; then
  fail "local-up of a new version failed: $(cat "$TMP/out")"
else
  rel="$L/releases/v1.1.0"
  if cmp -s "$TMP/instance.env.1" "$L/shared/instance.env" && cmp -s "$TMP/data.env.1" "$L/shared/data.env"; then
    ok "local-up of a new version keeps instance.env and data.env byte-identical"
  else
    fail "local-up of a new version changed instance.env or data.env"
  fi
  [ "$(readlink "$L/current")" = releases/v1.1.0 ] && ok "current points at the new version" || fail "current: $(readlink "$L/current")"
  if grep -qx 'MARGINCE_LICENSE=lic-secret-value' "$rel/.env" && ! grep -q '^MARGINCE_ENV=' "$rel/.env"; then
    ok "with MARGINCE_LICENSE set, .env has the license and no MARGINCE_ENV"
  else
    fail "with MARGINCE_LICENSE: .env is wrong"
  fi
  grep -q 'lic-secret-value' "$TMP/out" "$STUB_STATE/docker.log" && fail "the license was printed or on a command line" || ok "the license is not printed"
  grep -q 'caddy reload' "$STUB_STATE/docker.log" && fail "caddy reloaded with an unchanged Caddyfile" || ok "no caddy reload with an unchanged Caddyfile"
fi

# --- local-up fails when https://localhost/ does not answer in time ---
printf '502' > "$STUB_STATE/curl-code"
if LOCAL_TIMEOUT=0 run_make make local-up VERSION=v1.1.0; then
  fail "local-up succeeded while https://localhost/ answers 502"
elif grep -q 'https://localhost/' "$TMP/out" && grep -q 'logs' "$TMP/out"; then
  ok "local-up fails when https://localhost/ does not answer, pointing at the logs"
else
  fail "the wait failure: $(cat "$TMP/out")"
fi
rm -f "$STUB_STATE/curl-code"

# --- local-down keeps .local/ without WIPE ---
: > "$STUB_STATE/docker.log"
if ! run_make make local-down; then
  fail "local-down failed: $(cat "$TMP/out")"
elif ! compose_calls | grep -qF -- "compose -p acme-local -f $L/releases/v1.1.0/compose.yaml --env-file $L/releases/v1.1.0/compose.env down"; then
  fail "no compose down for the current release: $(compose_calls)"
elif compose_calls | grep -q -- ' -v'; then
  fail "local-down without WIPE passed -v: $(compose_calls)"
elif ! cmp -s "$TMP/instance.env.1" "$L/shared/instance.env"; then
  fail "local-down without WIPE changed .local/"
else
  ok "local-down stops the stack and keeps .local/ and the volumes"
fi

# --- local-down WIPE=1 removes the volumes and .local/ ---
: > "$STUB_STATE/docker.log"
if ! run_make make local-down WIPE=1; then
  fail "local-down WIPE=1 failed: $(cat "$TMP/out")"
elif ! compose_calls | grep -q -- 'down -v'; then
  fail "local-down WIPE=1 did not pass -v: $(compose_calls)"
elif [ -e "$L" ]; then
  fail "local-down WIPE=1 kept .local/"
else
  ok "local-down WIPE=1 removes the volumes and .local/"
fi

# --- without .local/ ---
reset
if run_make make local-admin-password; then
  fail "local-admin-password succeeded without .local/"
elif grep -q 'make local-up' "$TMP/out"; then
  ok "local-admin-password without .local/ points at make local-up"
else
  fail "local-admin-password without .local/: $(cat "$TMP/out")"
fi
if run_make make local-down WIPE=1 && compose_calls | grep -q -- '-p acme-local down -v'; then
  ok "local-down without .local/ still stops the project by name"
else
  fail "local-down without .local/: $(cat "$TMP/out") $(compose_calls)"
fi

if [ "$FAILURES" -ne 0 ]; then
  printf '\nlocal.test.sh: %d failure(s)\n' "$FAILURES" >&2
  exit 1
fi
printf '\nlocal.test.sh: all passed\n'
