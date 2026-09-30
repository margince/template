#!/usr/bin/env bash
# aio-install.test.sh — scripts/aio/install.sh, the tester's command
# (docs/superpowers/specs/2026-09-30-all-in-one-image-design.md, Section 8).
#
# Every external command is a stub first on PATH, recording one line per call
# in $STUB_LOG. The stub docker keeps its state in $STATE:
#   $STATE/docker-missing   `docker` is not installed (its stub is left off PATH)
#   $STATE/daemon-down      `docker info` fails
#   $STATE/container        the container exists; its content is the image id
#   $STATE/running          the container runs
#   $STATE/port             its host port
#   $STATE/busy-<port>      `docker run` on that port fails as "address already in use"
# The terminal is a file (MARGINCE_TTY) holding the answer.
#
# Usage: bash scripts/aio-install.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
INSTALL="$SCRIPT_DIR/aio/install.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILURES=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }
ok()   { printf 'ok: %s\n' "$*"; }
check() { local what="$1"; shift; if "$@"; then ok "$what"; else fail "$what"; fi; }

BIN="$TMP/bin"; DBIN="$TMP/docker-bin"; mkdir -p "$BIN" "$DBIN"
export STUB_LOG="$TMP/log" STATE="$TMP/state"

cat > "$DBIN/docker" <<'EOF'
#!/bin/sh
printf 'docker %s\n' "$*" >> "$STUB_LOG"
case "$1" in
  info) [ -f "$STATE/daemon-down" ] && exit 1; exit 0 ;;
  image)
    case "$2" in
      inspect)
        [ -f "$STATE/image-missing" ] && exit 1
        case "$*" in *'{{.Id}}'*) echo "sha256:new" ;; esac; exit 0 ;;
    esac ;;
  pull) rm -f "$STATE/image-missing"; exit 0 ;;
  container)
    [ -f "$STATE/container" ] || exit 1
    case "$*" in
      *'{{.Image}}'*) cat "$STATE/container" ;;
      *'{{.State.Running}}'*) [ -f "$STATE/running" ] && echo true || echo false ;;
      *PortBindings*) cat "$STATE/port" ;;
      *Health*) echo "${STUB_HEALTH:-healthy}" ;;
    esac
    exit 0 ;;
  run)
    port="$(printf '%s\n' "$*" | sed -n 's/.*-p 127\.0\.0\.1:\([0-9]*\):80.*/\1/p')"
    echo "sha256:new" > "$STATE/container"
    echo "$port" > "$STATE/port"
    if [ -f "$STATE/busy-$port" ]; then echo "Error: address already in use" >&2; exit 125; fi
    touch "$STATE/running"; echo "cid"; exit 0 ;;
  start)
    port="$(cat "$STATE/port")"
    if [ -f "$STATE/busy-$port" ]; then echo "Error: address already in use" >&2; exit 1; fi
    touch "$STATE/running"; exit 0 ;;
  stop) rm -f "$STATE/running"; exit 0 ;;
  rm) rm -f "$STATE/container" "$STATE/running" "$STATE/port"; exit 0 ;;
  volume) exit 0 ;;
  exec) echo "  Sign in as admin@localhost password stub-password"; exit 0 ;;
  logs) echo "stub log"; exit 0 ;;
esac
exit 0
EOF
for c in sudo; do
  cat > "$BIN/$c" <<'EOF'
#!/bin/sh
printf 'sudo %s\n' "$*" >> "$STUB_LOG"
[ "$1" = docker ] && { shift; exec docker "$@"; }
exit 0
EOF
done
for c in curl hdiutil open xdg-open apt-get install tee chmod usermod systemctl dpkg id; do
  cat > "$BIN/$c" <<EOF
#!/bin/sh
printf '$c %s\n' "\$*" >> "\$STUB_LOG"
case "$c" in
  dpkg) echo arm64 ;;
  id) echo tester ;;
  open) [ "\$1" = -a ] && rm -f "\$STATE/daemon-down" ;;
  systemctl) rm -f "\$STATE/daemon-down" ;;
esac
exit 0
EOF
done
cat > "$BIN/uname" <<'EOF'
#!/bin/sh
case "$1" in -m) echo "${STUB_ARCH:-arm64}" ;; *) echo "${STUB_OS:-Darwin}" ;; esac
EOF
chmod +x "$BIN"/* "$DBIN"/*

ubuntu() { printf 'ID=ubuntu\nVERSION_ID="%s"\nVERSION_CODENAME=noble\nPRETTY_NAME="Ubuntu %s"\n' "$1" "$1" > "$TMP/os-release"; }

reset() { rm -rf "$STATE"; mkdir -p "$STATE"; : > "$STUB_LOG"; printf 'y\n' > "$TMP/tty"; }

run_install() {
  local dpath="$DBIN:"
  [ -f "$STATE/docker-missing" ] && dpath=""
  PATH="$dpath$BIN:/usr/bin:/bin" MARGINCE_OS_RELEASE="$TMP/os-release" MARGINCE_TTY="${MARGINCE_TTY:-$TMP/tty}" \
  MARGINCE_SLEEP=true MARGINCE_DOCKER_TIMEOUT=4 MARGINCE_START_TIMEOUT=10 \
    sh "$INSTALL" --image acme/all-in-one:v1.0.0 --container margince-acme --volume margince-acme-data "$@"
}

# 1. Docker works: no install; container created on 8080; logins shown.
reset
run_install up >"$TMP/out" 2>&1 || { fail "up with Docker running succeeds"; cat "$TMP/out" >&2; }
check "up does not install Docker when it works" bash -c '! grep -qE "^(hdiutil|apt-get|curl)" "$1"' _ "$STUB_LOG"
check "up runs the container on 127.0.0.1:8080 with the volume and restart policy" \
  grep -q '^docker run -d --name margince-acme --restart unless-stopped -p 127.0.0.1:8080:80 -v margince-acme-data:/data acme/all-in-one:v1.0.0$' "$STUB_LOG"
check "up shows the address and the sign-in" bash -c 'grep -q "http://localhost:8080" "$1" && grep -q "stub-password" "$1"' _ "$TMP/out"
check "up opens the browser" grep -q '^open http://localhost:8080$' "$STUB_LOG"

# 2. Running container, same image: nothing is recreated.
: > "$STUB_LOG"
run_install up >/dev/null 2>&1 || true
check "a second up keeps the running container" bash -c '! grep -qE "^docker (run|rm|start)" "$1"' _ "$STUB_LOG"

# 3. Container of another image: replaced on the same port, volume kept.
echo "sha256:old" > "$STATE/container"; echo 8083 > "$STATE/port"; : > "$STUB_LOG"
run_install up >/dev/null 2>&1 || true
check "a container of another image is replaced on its port" bash -c 'grep -q "^docker rm -f -v margince-acme$" "$1" && grep -q -- "-p 127.0.0.1:8083:80" "$1"' _ "$STUB_LOG"
check "the replacement keeps the volume" bash -c '! grep -q "^docker volume rm" "$1"' _ "$STUB_LOG"

# 4. Port 8080 busy: the next port.
reset; touch "$STATE/busy-8080" "$STATE/busy-8081"
run_install up >/dev/null 2>&1 || true
check "busy ports are skipped" grep -q -- '-p 127.0.0.1:8082:80' "$STUB_LOG"

# 5. Every port busy.
reset; for p in $(seq 8080 8099); do touch "$STATE/busy-$p"; done
if run_install up >"$TMP/out" 2>&1; then fail "all ports busy fails"; else
  check "all ports busy names the range" grep -q 'Ports 8080 to 8099 are all in use' "$TMP/out"; fi

# 6. Stopped container whose port is taken now: recreated on a free port.
reset; echo "sha256:new" > "$STATE/container"; echo 8080 > "$STATE/port"; touch "$STATE/busy-8080"
run_install up >/dev/null 2>&1 || true
check "a stopped container whose port is taken is recreated on a free port" grep -q -- '-p 127.0.0.1:8081:80' "$STUB_LOG"

# 7. macOS without Docker: Docker Desktop for the Mac's architecture.
reset; touch "$STATE/docker-missing"
STUB_OS=Darwin STUB_ARCH=x86_64 run_install up --yes >"$TMP/out" 2>&1 || true
check "macOS downloads Docker Desktop for amd64" grep -q 'https://desktop.docker.com/mac/main/amd64/Docker.dmg' "$STUB_LOG"
check "macOS runs the installer with --accept-license" grep -q 'Docker.app/Contents/MacOS/install --accept-license' "$STUB_LOG"

# 8. Ubuntu 24.04 without Docker: Docker's apt repository.
reset; touch "$STATE/docker-missing"; ubuntu 24.04
STUB_OS=Linux run_install up --yes >"$TMP/out" 2>&1 || true
check "Ubuntu installs docker-ce from Docker's repository" bash -c 'grep -q "download.docker.com/linux/ubuntu/gpg" "$1" && grep -q "apt-get install -y docker-ce docker-ce-cli containerd.io" "$1"' _ "$STUB_LOG"

# 9. Unsupported Linux.
reset; touch "$STATE/docker-missing"
printf 'ID=fedora\nVERSION_ID="40"\nPRETTY_NAME="Fedora Linux 40"\n' > "$TMP/os-release"
if STUB_OS=Linux run_install up --yes >"$TMP/out" 2>&1; then fail "Fedora is refused"; else
  check "an unsupported system is refused by name" grep -q 'Fedora Linux 40' "$TMP/out"; fi

# 10. The tester answers no.
reset; touch "$STATE/docker-missing"; printf 'n\n' > "$TMP/tty"
if STUB_OS=Darwin run_install up >"$TMP/out" 2>&1; then fail "no means no install"; else
  check "no answer installs nothing" bash -c '! grep -q "^hdiutil" "$1"' _ "$STUB_LOG"; fi

# 11. No terminal: names --yes.
reset; touch "$STATE/docker-missing"
if STUB_OS=Darwin MARGINCE_TTY=/nonexistent/tty run_install up >"$TMP/out" 2>&1; then fail "no terminal fails"; else
  check "without a terminal the message names --yes" grep -q -- '--yes' "$TMP/out"; fi

# 11b. The same under dash (Ubuntu's /bin/sh): a failed redirection on a
# special built-in must not end the shell silently.
if command -v dash >/dev/null 2>&1; then
  reset; touch "$STATE/docker-missing"
  if PATH="$BIN:/usr/bin:/bin" MARGINCE_OS_RELEASE="$TMP/os-release" MARGINCE_TTY=/nonexistent/tty MARGINCE_SLEEP=true STUB_OS=Darwin \
      dash "$INSTALL" --image acme/all-in-one:v1.0.0 --container margince-acme --volume margince-acme-data up >"$TMP/out" 2>&1; then
    fail "dash without a terminal fails"
  else
    check "dash without a terminal names --yes" grep -q -- '--yes' "$TMP/out"
  fi
  reset; touch "$STATE/running"; echo sha256:new > "$STATE/container"; echo 8080 > "$STATE/port"
  PATH="$DBIN:$BIN:/usr/bin:/bin" MARGINCE_TTY=/nonexistent/tty dash "$INSTALL" --image x --container margince-acme --volume margince-acme-data reset >"$TMP/out" 2>&1 || true
  check "dash reset without a terminal names --yes" grep -q -- '--yes' "$TMP/out"
fi

# 12. Docker installed but not running on macOS: started, then used.
reset; touch "$STATE/daemon-down"
STUB_OS=Darwin run_install up >"$TMP/out" 2>&1 || true
check "a stopped Docker Desktop is started" grep -q '^open -a Docker$' "$STUB_LOG"

# 13. Never healthy: the logs hint.
reset
if STUB_HEALTH=starting run_install up >"$TMP/out" 2>&1; then fail "never healthy fails"; else
  check "never healthy names the logs action" grep -q 'logs' "$TMP/out"; fi

# 14. down, logins, logs, reset.
reset; run_install up >/dev/null 2>&1 || true; : > "$STUB_LOG"
run_install down >"$TMP/out" 2>&1 || true
check "down stops the container and keeps the data" bash -c 'grep -q "^docker stop margince-acme$" "$1" && ! grep -q "^docker rm" "$1"' _ "$STUB_LOG"
touch "$STATE/running"
run_install logins >"$TMP/out" 2>&1 || true
check "logins prints the address and the accounts" bash -c 'grep -q "http://localhost:8080" "$1" && grep -q "stub-password" "$1"' _ "$TMP/out"
run_install logs >"$TMP/out" 2>&1 || true
check "logs prints the last 200 lines" grep -q '^docker logs --tail 200 margince-acme$' "$STUB_LOG"
printf 'no\n' > "$TMP/tty"; : > "$STUB_LOG"
run_install reset >/dev/null 2>&1 || true
check "reset without typing yes removes nothing" bash -c '! grep -qE "^docker (rm|volume rm)" "$1"' _ "$STUB_LOG"
printf 'yes\n' > "$TMP/tty"
run_install reset >/dev/null 2>&1 || true
check "reset after yes removes the container and the volume" bash -c 'grep -q "^docker rm -f -v margince-acme$" "$1" && grep -q "^docker volume rm margince-acme-data$" "$1"' _ "$STUB_LOG"

# 15. Placeholders left in an unrendered script are refused.
if PATH="$DBIN:$BIN:/usr/bin:/bin" sh "$INSTALL" up >"$TMP/out" 2>&1; then fail "an unrendered script is refused"; else
  check "an unrendered script names make aio-scripts" grep -q 'make aio-scripts' "$TMP/out"; fi

# 16. POSIX: dash parses it when present.
if command -v dash >/dev/null 2>&1; then check "dash parses install.sh" dash -n "$INSTALL"; fi
check "sh parses install.sh" sh -n "$INSTALL"

if [ "$FAILURES" -gt 0 ]; then printf '\naio-install.test.sh: %s failed\n' "$FAILURES" >&2; exit 1; fi
printf '\naio-install.test.sh: all passed\n'
