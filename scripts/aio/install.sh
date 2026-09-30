#!/bin/sh
# install.sh — install and run Margince from its all-in-one image, on macOS
# and Ubuntu (docs/superpowers/specs/2026-09-30-all-in-one-image-design.md,
# Section 8). The Windows version is install.ps1.
#
#   curl -fsSL <url>/install.sh | sh
#   curl -fsSL <url>/install.sh | sh -s -- <action> [--yes]
#
# Actions: up (default) installs Docker when it is missing, starts Margince and
# opens it; down stops it; reset deletes it and its data; logins shows how to
# sign in; logs prints its log. make aio-up and the other make aio-* targets
# run this script with --image, --container and --volume.
#
# POSIX sh: `curl ... | sh` runs it with the system's sh.
set -eu

IMAGE='@IMAGE@'
CONTAINER='@CONTAINER@'
VOLUME='@VOLUME@'

FIRST_PORT=8080
LAST_PORT=8099
DOCKER_TIMEOUT="${MARGINCE_DOCKER_TIMEOUT:-180}"
START_TIMEOUT="${MARGINCE_START_TIMEOUT:-600}"
OS_RELEASE="${MARGINCE_OS_RELEASE:-/etc/os-release}"
TTY="${MARGINCE_TTY:-/dev/tty}"
SLEEP="${MARGINCE_SLEEP:-sleep}"

DOCKER=docker
PORT=""
ERR_FILE=""

say() { printf '%s\n' "$*"; }
fail() { printf '\nError: %s\n' "$*" >&2; exit 1; }

cleanup() { [ -z "$ERR_FILE" ] || rm -f "$ERR_FILE"; }
trap cleanup EXIT

usage() {
  say "usage: install.sh [up|down|reset|logins|logs] [--yes]"
}

ACTION=up
YES=no
while [ $# -gt 0 ]; do
  case "$1" in
    up|down|reset|logins|logs) ACTION="$1" ;;
    --yes|-y) YES=yes ;;
    --image|--container|--volume)
      [ $# -ge 2 ] || fail "$1 needs a value."
      case "$1" in
        --image) IMAGE="$2" ;;
        --container) CONTAINER="$2" ;;
        --volume) VOLUME="$2" ;;
      esac
      shift ;;
    -h|--help) usage; exit 0 ;;
    *) fail "Unknown argument: $1. Use up, down, reset, logins or logs." ;;
  esac
  shift
done

for value in "$IMAGE" "$CONTAINER" "$VOLUME"; do
  case "$value" in
    @*@) fail "This script has no image name. Create it with make aio-scripts, or run make aio-up." ;;
  esac
done

# ── questions ──

# ask <question> — 0 for yes. Reads the terminal, not standard input:
# standard input is this script when it runs as `curl ... | sh`. The terminal
# is probed in a subshell: dash ends the shell on a failed redirection of a
# special built-in such as `:`.
ask() {
  [ "$YES" = yes ] && return 0
  if ! (: <"$TTY") 2>/dev/null; then
    fail "$1 There is no terminal to answer in. Run the command again with --yes at the end (sh -s -- up --yes)."
  fi
  printf '%s [Y/n] ' "$1"
  answer=""
  read -r answer <"$TTY" || answer=n
  case "$answer" in
    ""|y|Y|yes|Yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

# ── Docker ──

docker_ok() { $DOCKER info >/dev/null 2>&1; }

use_sudo_if_needed() {
  [ "$(uname -s)" = Linux ] || return 1
  command -v sudo >/dev/null 2>&1 || return 1
  sudo docker info >/dev/null 2>&1 || return 1
  DOCKER="sudo docker"
}

os_value() { sed -n "s/^$1=//p" "$OS_RELEASE" | tr -d '"' | head -n1; }

install_docker_mac() {
  case "$(uname -m)" in
    arm64) arch=arm64 ;;
    x86_64) arch=amd64 ;;
    *) fail "This Mac ($(uname -m)) is not supported." ;;
  esac
  tmp="$(mktemp -d)"
  say "Downloading Docker Desktop..."
  curl -fL --progress-bar -o "$tmp/Docker.dmg" "https://desktop.docker.com/mac/main/$arch/Docker.dmg" \
    || fail "Could not download Docker Desktop. Check the internet connection, then run this command again."
  say "Installing Docker Desktop. Enter your Mac password when asked."
  sudo hdiutil attach -nobrowse -quiet -mountpoint "$tmp/mnt" "$tmp/Docker.dmg" \
    || fail "Could not open the Docker Desktop download. Run this command again."
  if ! sudo "$tmp/mnt/Docker.app/Contents/MacOS/install" --accept-license --user="$(id -un)"; then
    sudo hdiutil detach -quiet "$tmp/mnt" || true
    fail "Docker Desktop was not installed. Install it from https://docs.docker.com/desktop/, then run this command again."
  fi
  sudo hdiutil detach -quiet "$tmp/mnt" || true
  rm -rf "$tmp"
  PATH="$PATH:/usr/local/bin:$HOME/.docker/bin"
  open -a Docker
}

install_docker_ubuntu() {
  codename="$(os_value VERSION_CODENAME)"
  say "Installing Docker Engine. Enter your password when asked."
  sudo apt-get update
  sudo apt-get install -y ca-certificates curl
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu %s stable\n' \
    "$(dpkg --print-architecture)" "$codename" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
  sudo apt-get update
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  sudo systemctl enable --now docker
  sudo usermod -aG docker "$(id -un)"
  DOCKER="sudo docker"
  say "Docker is installed. After you log in again, docker works without sudo."
}

install_docker() {
  case "$(uname -s)" in
    Darwin)
      ask "Margince needs Docker Desktop, which is not installed. Install it now? Docker's subscription terms apply." \
        || fail "Margince needs Docker. Install Docker Desktop from https://docs.docker.com/desktop/, then run this command again."
      install_docker_mac ;;
    Linux)
      [ -r "$OS_RELEASE" ] || fail "This system is not supported. Install Docker from https://docs.docker.com/get-docker/, then run this command again."
      case "$(os_value ID):$(os_value VERSION_ID)" in
        ubuntu:22.04|ubuntu:24.04) ;;
        *) fail "This system ($(os_value PRETTY_NAME)) is not supported. Install Docker Engine from https://docs.docker.com/engine/install/, then run this command again." ;;
      esac
      ask "Margince needs Docker Engine, which is not installed. Install it now?" \
        || fail "Margince needs Docker. Install Docker Engine from https://docs.docker.com/engine/install/ubuntu/, then run this command again."
      install_docker_ubuntu ;;
    *)
      fail "This system ($(uname -s)) is not supported. Install Docker from https://docs.docker.com/get-docker/, then run this command again." ;;
  esac
}

start_docker() {
  case "$(uname -s)" in
    Darwin)
      say "Starting Docker Desktop..."
      open -a Docker || fail "Docker is installed but not running. Start Docker Desktop, then run this command again." ;;
    Linux)
      sudo systemctl start docker || fail "Docker is installed but not running. Start it with: sudo systemctl start docker" ;;
  esac
}

wait_docker() {
  waited=0
  [ "$(uname -s)" = Darwin ] && say "Waiting for Docker. Docker Desktop may ask you to accept its terms; accept them to continue."
  while ! docker_ok; do
    use_sudo_if_needed && return 0
    [ "$waited" -ge "$DOCKER_TIMEOUT" ] \
      && fail "Docker did not start within 3 minutes. Start Docker Desktop, wait until it says it is running, then run this command again."
    $SLEEP 2
    waited=$((waited + 2))
  done
}

ensure_docker() {
  if command -v docker >/dev/null 2>&1; then
    docker_ok && return 0
    use_sudo_if_needed && return 0
    start_docker
  else
    install_docker
  fi
  wait_docker
}

# For down, reset, logins and logs: Docker must already work.
require_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    say "Margince is not installed on this computer."
    exit 0
  fi
  docker_ok || use_sudo_if_needed || fail "Docker is not running. Start Docker Desktop, then run this command again."
}

# ── the container ──

container_exists() { $DOCKER container inspect "$CONTAINER" >/dev/null 2>&1; }
container_running() { [ "$($DOCKER container inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" = true ]; }
container_image() { $DOCKER container inspect -f '{{.Image}}' "$CONTAINER"; }
container_port() {
  $DOCKER container inspect -f '{{with index .HostConfig.PortBindings "80/tcp"}}{{(index . 0).HostPort}}{{end}}' "$CONTAINER" 2>/dev/null
}
image_id() { $DOCKER image inspect -f '{{.Id}}' "$IMAGE"; }

ensure_image() {
  $DOCKER image inspect "$IMAGE" >/dev/null 2>&1 && return 0
  say "Downloading Margince. This takes a few minutes the first time."
  $DOCKER pull "$IMAGE" || fail "Could not download $IMAGE. Check the internet connection, then run this command again."
}

port_error() { grep -qiE 'already in use|already allocated|bind' "$ERR_FILE"; }

# run_on <port> — create and start the container; 1 when the port is taken.
run_on() {
  if $DOCKER run -d --name "$CONTAINER" --restart unless-stopped -p "127.0.0.1:$1:80" -v "$VOLUME:/data" "$IMAGE" \
      >/dev/null 2>"$ERR_FILE"; then
    PORT="$1"
    return 0
  fi
  port_error || { cat "$ERR_FILE" >&2; fail "Docker could not start Margince (see the message above)."; }
  $DOCKER rm -f -v "$CONTAINER" >/dev/null 2>&1 || true
  return 1
}

# create_container [<port>] — on <port> when it is free, else the first free one.
create_container() {
  [ -n "${1:-}" ] && run_on "$1" && return 0
  p="$FIRST_PORT"
  while [ "$p" -le "$LAST_PORT" ]; do
    run_on "$p" && return 0
    p=$((p + 1))
  done
  fail "Ports 8080 to 8099 are all in use. Close a program that uses one of them, then run this command again."
}

wait_healthy() {
  say "Starting Margince. The first start takes a few minutes."
  waited=0
  while :; do
    status="$($DOCKER container inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$CONTAINER" 2>/dev/null || true)"
    [ "$status" = healthy ] && return 0
    [ "$waited" -ge "$START_TIMEOUT" ] \
      && fail "Margince did not start within 10 minutes. Run the command again with \"logs\" at the end (sh -s -- logs) and send the output to the person who gave you this command."
    $SLEEP 5
    waited=$((waited + 5))
  done
}

show_logins() {
  say ""
  say "Margince is running at http://localhost:$PORT"
  say ""
  $DOCKER exec "$CONTAINER" margince-logins || true
  say ""
}

open_browser() {
  url="http://localhost:$PORT"
  case "$(uname -s)" in
    Darwin) open "$url" >/dev/null 2>&1 || true ;;
    Linux)
      if command -v xdg-open >/dev/null 2>&1 && [ -n "${DISPLAY:-}${WAYLAND_DISPLAY:-}" ]; then
        xdg-open "$url" >/dev/null 2>&1 || true
      fi ;;
  esac
}

cmd_up() {
  ERR_FILE="$(mktemp)"
  ensure_docker
  ensure_image
  if container_exists; then
    PORT="$(container_port)"
    if [ "$(container_image)" != "$(image_id)" ]; then
      say "Updating Margince. Your data is kept."
      $DOCKER rm -f -v "$CONTAINER" >/dev/null
      create_container "$PORT"
    elif ! container_running; then
      if ! $DOCKER start "$CONTAINER" >/dev/null 2>"$ERR_FILE"; then
        port_error || { cat "$ERR_FILE" >&2; fail "Docker could not start Margince (see the message above)."; }
        say "Port $PORT is in use now. Moving Margince to another port. Your data is kept."
        $DOCKER rm -f -v "$CONTAINER" >/dev/null
        create_container ""
      fi
    fi
  else
    create_container ""
  fi
  wait_healthy
  show_logins
  say "To stop Margince, run the same command with \"down\" at the end. Your data is kept."
  open_browser
}

cmd_down() {
  require_docker
  container_exists || { say "Margince is not installed on this computer."; return 0; }
  $DOCKER stop "$CONTAINER" >/dev/null
  say "Margince is stopped. Your data is kept. Run the command again to start it."
}

cmd_reset() {
  require_docker
  if [ "$YES" != yes ]; then
    (: <"$TTY") 2>/dev/null || fail "There is no terminal to answer in. Run the command again with --yes at the end."
    printf 'This deletes Margince and all its data. Type yes to continue: '
    answer=""
    read -r answer <"$TTY" || answer=""
    [ "$answer" = yes ] || { say "Nothing was deleted."; return 1; }
  fi
  container_exists && $DOCKER rm -f -v "$CONTAINER" >/dev/null
  $DOCKER volume rm "$VOLUME" >/dev/null 2>&1 || true
  say "Margince and its data are deleted."
}

cmd_logins() {
  require_docker
  if ! container_exists || ! container_running; then
    say "Margince is not running. Run the command again without an action to start it."
    return 0
  fi
  PORT="$(container_port)"
  show_logins
}

cmd_logs() {
  require_docker
  container_exists || { say "Margince is not installed on this computer."; return 0; }
  $DOCKER logs --tail 200 "$CONTAINER" 2>&1
}

case "$ACTION" in
  up) cmd_up ;;
  down) cmd_down ;;
  reset) cmd_reset ;;
  logins) cmd_logins ;;
  logs) cmd_logs ;;
esac
