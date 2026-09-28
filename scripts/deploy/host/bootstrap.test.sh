#!/usr/bin/env bash
# bootstrap.test.sh — scripts/deploy/host/bootstrap.sh (make host-bootstrap)
# prepares a server over SSH.
#
# ssh is scripts/deploy/host/test-stubs/bootstrap/ssh, first on PATH: it
# answers /etc/os-release, `docker compose version --short` and `id -nG`
# from files in $STUB_STATE and records the install scripts it receives. No
# server is contacted.
#
# Usage: bash scripts/deploy/host/bootstrap.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
STUBS="$SCRIPT_DIR/deploy/host/test-stubs/bootstrap"

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_PREFIX
unset HOST_SSH_KEY
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false
export GIT_AUTHOR_NAME="Test Dev"     GIT_AUTHOR_EMAIL="dev@example.test"
export GIT_COMMITTER_NAME="Test Dev"  GIT_COMMITTER_EMAIL="dev@example.test"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILURES=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }
ok()   { printf 'ok: %s\n' "$*"; }

INST="$TMP/inst"
mkdir -p "$INST/deploy/prod/config" "$INST/deploy/staging/hooks"
cp -R "$SCRIPT_DIR" "$INST/scripts"
cp "$SCRIPT_DIR/../Makefile" "$INST/Makefile"
printf 'name: acme\ndisplay_name: Acme\ncore: v0.0.2\ndeploy:\n  prod: { adapter: host }\n  staging: { adapter: hook }\n' > "$INST/instance.yaml"
printf 'HOST_SSH=ubuntu@203.0.113.10\nHOST_DOMAIN=crm.example.test\n' > "$INST/deploy/prod/host.env"
printf 'true\n' > "$INST/deploy/staging/hooks/apply.sh"

export PATH="$STUBS:$PATH"
export HOST_KNOWN_HOSTS='203.0.113.10 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIStubHostKeyForTestsOnly'

UBUNTU_2404='PRETTY_NAME="Ubuntu 24.04.1 LTS"
NAME="Ubuntu"
VERSION_ID="24.04"
VERSION_CODENAME=noble
ID=ubuntu
ID_LIKE=debian'
UBUNTU_2204='NAME="Ubuntu"
VERSION_ID="22.04"
ID=ubuntu'
UBUNTU_2004='NAME="Ubuntu"
VERSION_ID="20.04"
ID=ubuntu'
AMZN_2023='NAME="Amazon Linux"
VERSION="2023"
ID="amzn"
ID_LIKE="fedora"
VERSION_ID="2023"'
DEBIAN_12='PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"
VERSION_ID="12"
ID=debian'

# server <os-release> <compose-version or ""> <groups> — a fresh stub server.
server() {
  rm -rf "$TMP/stub"; mkdir -p "$TMP/stub"
  export STUB_STATE="$TMP/stub"
  printf '%s\n' "$1" > "$STUB_STATE/os-release"
  [ -z "$2" ] || printf '%s\n' "$2" > "$STUB_STATE/compose-version"
  printf '%s\n' "$3" > "$STUB_STATE/groups"
}
bootstrap() { (cd "$INST" && env "$@" bash scripts/deploy/host/bootstrap.sh prod) > "$TMP/out" 2>&1; }
out() { cat "$TMP/out"; }
scripts() { cat "$STUB_STATE/scripts.log" 2>/dev/null || true; }

# --- a ready server ---
server "$UBUNTU_2404" 2.39.4 "ubuntu adm sudo docker"
if bootstrap && out | grep -qxF 'host-bootstrap: ubuntu@203.0.113.10 is ready (nothing to change)'; then
  ok "a ready server: nothing to change"
else
  fail "a ready server: nothing to change: $(out)"
fi
if [ -z "$(scripts)" ]; then ok "a ready server runs no install command"; else fail "a ready server runs no install command: $(scripts)"; fi
if grep -q -- '-o BatchMode=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=' "$STUB_STATE/ssh.log"; then
  ok "bootstrap uses BatchMode, StrictHostKeyChecking and the known hosts file"
else
  fail "bootstrap uses BatchMode, StrictHostKeyChecking and the known hosts file"
fi

# --- Ubuntu 24.04 without Docker ---
server "$UBUNTU_2404" "" "ubuntu adm sudo"
if bootstrap; then ok "Ubuntu 24.04 without Docker: bootstrap succeeds"; else fail "Ubuntu 24.04 without Docker: bootstrap succeeds: $(out)"; fi
if scripts | grep -qF 'https://download.docker.com/linux/ubuntu' \
   && scripts | grep -qF 'apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin'; then
  ok "Ubuntu 24.04 without Docker runs the apt repository install commands"
else
  fail "Ubuntu 24.04 without Docker runs the apt repository install commands: $(scripts)"
fi
if scripts | grep -qF 'usermod -aG docker'; then ok "the SSH user is added to the docker group"; else fail "the SSH user is added to the docker group: $(scripts)"; fi
if out | grep -q 'installed Docker Engine and the Compose plugin' && out | grep -q 'docker group'; then
  ok "bootstrap prints what it changed"
else
  fail "bootstrap prints what it changed: $(out)"
fi
if bootstrap && out | grep -q 'is ready (nothing to change)'; then ok "a second run changes nothing"; else fail "a second run changes nothing: $(out)"; fi

# --- Ubuntu with the distribution's conflicting packages ---
server "$UBUNTU_2404" "" "ubuntu adm sudo"
printf 'ii  docker.io\nun  docker-doc\nii  podman-docker\n' > "$STUB_STATE/dpkg"
if ! bootstrap && out | grep -qF 'docker.io podman-docker' && out | grep -qF 'sudo apt-get remove docker.io podman-docker' \
   && ! out | grep -q docker-doc && [ -z "$(scripts)" ]; then
  ok "Ubuntu with docker.io and podman-docker installed stops, naming them and the removal command, and installs nothing"
else
  fail "Ubuntu with conflicting packages stops, naming them: $(out) $(scripts)"
fi
if grep -q 'dpkg-query -W' "$STUB_STATE/ssh.log"; then ok "the conflict check asks dpkg-query"; else fail "the conflict check asks dpkg-query"; fi

# --- Ubuntu 22.04: Docker present, user not in the group ---
server "$UBUNTU_2204" 2.39.4 "ubuntu adm"
if bootstrap && ! scripts | grep -q 'apt-get' && scripts | grep -qF 'usermod -aG docker'; then
  ok "Ubuntu 22.04 with Docker: only the group is changed"
else
  fail "Ubuntu 22.04 with Docker: only the group is changed: $(scripts) $(out)"
fi

# --- Amazon Linux 2023 without Docker ---
server "$AMZN_2023" "" "ec2-user adm wheel"
if bootstrap && scripts | grep -qF 'dnf install -y docker' \
   && scripts | grep -qF 'https://github.com/docker/compose/releases/download/v2.39.4/docker-compose-linux-' \
   && scripts | grep -qF 'sha256sum -c' \
   && scripts | grep -qF '/usr/local/lib/docker/cli-plugins/docker-compose'; then
  ok "Amazon Linux 2023 without Docker installs docker with dnf and the checked Compose plugin"
else
  fail "Amazon Linux 2023 without Docker installs docker with dnf and the checked Compose plugin: $(scripts) $(out)"
fi

# --- refused ---
server "$DEBIAN_12" "" "admin"
if ! bootstrap && out | grep -q 'debian 12' && [ -z "$(scripts)" ]; then
  ok "an unknown OS fails, naming it, and installs nothing"
else
  fail "an unknown OS fails, naming it, and installs nothing: $(out)"
fi
server "$UBUNTU_2004" "" "ubuntu"
if ! bootstrap && out | grep -q 'ubuntu 20.04' && [ -z "$(scripts)" ]; then
  ok "Ubuntu 20.04 is refused"
else
  fail "Ubuntu 20.04 is refused: $(out)"
fi
server "$UBUNTU_2404" 2.20.0 "ubuntu docker"
if ! bootstrap && out | grep -q '2.30.0' && [ -z "$(scripts)" ]; then
  ok "an existing Docker Compose older than 2.30.0 is reported, not replaced"
else
  fail "an existing Docker Compose older than 2.30.0 is reported, not replaced: $(out)"
fi
server "$UBUNTU_2404" "" "ubuntu"
touch "$STUB_STATE/fail.install"
if ! bootstrap && out | grep -q 'install'; then ok "a failed install fails bootstrap"; else fail "a failed install fails bootstrap: $(out)"; fi
server "$UBUNTU_2404" 2.39.4 "ubuntu docker"
if ! bootstrap HOST_KNOWN_HOSTS= && out | grep -q HOST_KNOWN_HOSTS && [ ! -e "$STUB_STATE/ssh.log" ]; then
  ok "a missing HOST_KNOWN_HOSTS fails before connecting"
else
  fail "a missing HOST_KNOWN_HOSTS fails before connecting: $(out)"
fi
server "$UBUNTU_2404" 2.39.4 "ubuntu docker"
if ! (cd "$INST" && bash scripts/deploy/host/bootstrap.sh staging) > "$TMP/out" 2>&1 && out | grep -q 'adapter' && [ ! -e "$STUB_STATE/ssh.log" ]; then
  ok "an environment whose adapter is not host is refused"
else
  fail "an environment whose adapter is not host is refused: $(out)"
fi
if ! (cd "$INST" && bash scripts/deploy/host/bootstrap.sh) > "$TMP/out" 2>&1 && out | grep -q 'ENV='; then
  ok "a missing environment is refused"
else
  fail "a missing environment is refused: $(out)"
fi

# --- make host-bootstrap ---
server "$UBUNTU_2404" 2.39.4 "ubuntu docker"
if (cd "$INST" && make -s host-bootstrap ENV=prod) > "$TMP/out" 2>&1 && out | grep -q 'is ready'; then
  ok "make host-bootstrap ENV=prod runs bootstrap.sh"
else
  fail "make host-bootstrap ENV=prod runs bootstrap.sh: $(out)"
fi

if (cd "$INST" && make -s host-bootstrap "ENV=prod'; touch pwned; '") > "$TMP/out" 2>&1; then
  fail "make host-bootstrap refuses a quoted ENV — it succeeded"
elif [ -e "$INST/pwned" ]; then
  fail "make host-bootstrap keeps a single quote in ENV as data"
else
  ok "make host-bootstrap keeps a single quote in ENV as data"
fi

if [ "$FAILURES" -gt 0 ]; then printf '\nbootstrap.test.sh: %s failure(s)\n' "$FAILURES" >&2; exit 1; fi
printf '\nbootstrap.test.sh: all passed\n'
