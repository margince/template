#!/usr/bin/env bash
# deploy/host.sh — the host adapter: deploy the three role images to one Linux
# server over SSH with Docker Compose (design Section 9.6).
#
# Called by scripts/deploy.sh, which exports DEPLOY_ENV, DEPLOY_VERSION,
# DEPLOY_DIR, DEPLOY_STATE_DIR, INSTANCE_NAME, IMAGE_REPO and IMAGE_*.
#
# Steps:
#   check      host.env has HOST_SSH and HOST_DOMAIN; config/margince.yaml
#              and secrets exist. No connection.
#   preflight  The release files can be built (every name in secrets has a
#              value); HOST_KNOWN_HOSTS is set; SSH connects; the server has
#              Docker, `timeout`, and Docker Compose 2.30.0 or later; the
#              server can log in to the registry and read the three image
#              manifests. Nothing is uploaded.
#   apply      Records the release `current` points to in
#              $DEPLOY_STATE_DIR/previous (empty when there is none); builds
#              the files with host/render.sh; uploads release/ to
#              $HOST_DIR/releases/<v>/ and shared/ into $HOST_DIR/shared/
#              (data.env is never replaced; it is created once, mode 600,
#              when absent); logs in to the registry; runs compose pull and
#              `up -d --remove-orphans`; installs a changed Caddyfile (staged
#              as caddy/Caddyfile.new until `up` succeeds) and reloads caddy;
#              points `current` at the release (new link renamed over it);
#              keeps the five newest release directories (and always current
#              and previous). Redeploying the running version moves its
#              directory to releases/.replaced-<v>, removed by the next apply.
#   verify     Every HOST_VERIFY_INTERVAL seconds (default 5) within
#              HOST_VERIFY_TIMEOUT (default 300): the api answers /readyz
#              inside the server and the worker is running; then, unless
#              HOST_VERIFY_PUBLIC=0, https://<HOST_DOMAIN>/ answers 100-499.
#   rollback   Removes a staged Caddyfile.new; restores releases/.replaced-<v>
#              when the previous release is the redeployed one; starts the
#              previous release directory and points `current` at it. Without
#              a previous release: stops the new release and exits 1.
#
# `up -d` is bounded by HOST_APPLY_TIMEOUT (default 600 seconds) with the
# server's `timeout`: compose waits for the api health check (start period
# 300 seconds) before it starts worker and web, and a stuck start must not
# hold the deployment. Readiness itself is verify's check; `--wait` is not
# used.
#
# Settings: HOST_DIR (default /opt/margince/<name>), HOST_VERIFY_TIMEOUT,
# HOST_VERIFY_PUBLIC, HOST_VERIFY_INTERVAL, HOST_APPLY_TIMEOUT come from the
# environment, else from host.env. Credentials come from the environment
# only: HOST_KNOWN_HOSTS, HOST_SSH_KEY, REGISTRY_USERNAME, REGISTRY_PASSWORD.
# No secret is printed or passed on a command line: the registry password
# goes to `docker login --password-stdin`, and secret values travel inside
# the uploaded .env (mode 600). The registry login is kept in a DOCKER_CONFIG
# directory of the step on the server, removed when the step ends.
#
# Every compose call is
#   docker compose -p margince-<name> -f <release>/compose.yaml --env-file <release>/compose.env
#
# Usage: bash scripts/deploy/host.sh check|has <step>|preflight|apply|verify|rollback
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/host/lib.sh"

HOST_FILES="$ROOT/scripts/deploy/host"
KEEP_RELEASES=5

step="${1:-}"

if [ "$step" = has ]; then
  case "${2:-}" in
    preflight|apply|verify|rollback) exit 0 ;;
    *) echo "deploy/host.sh: unknown step '${2:-}'" >&2; exit 2 ;;
  esac
fi

# fail <message> — the step's failure, exit 1.
fail() { printf 'deploy: %s\n' "$*" >&2; exit 1; }
say() { printf 'host: %s\n' "$*"; }

[ -n "${DEPLOY_DIR:-}" ] || { echo "deploy/host.sh: DEPLOY_DIR is not set (run through scripts/deploy.sh)" >&2; exit 2; }
[ -n "${INSTANCE_NAME:-}" ] || { echo "deploy/host.sh: INSTANCE_NAME is not set (run through scripts/deploy.sh)" >&2; exit 2; }

# setting <name> <default> — the environment's value, else host.env's, else <default>.
setting() {
  if [ -n "${!1:-}" ]; then printf '%s\n' "${!1}"; else host_env_get "$1" "$2"; fi
}

# load — read and check host.env. Sets TARGET, DOMAIN, HD, PROJECT.
load() {
  TARGET="$(host_ssh_target)" || exit 1
  DOMAIN="$(host_env_get HOST_DOMAIN)" || fail "HOST_DOMAIN is not set in $DEPLOY_DIR/host.env"
  HD="$(setting HOST_DIR "/opt/margince/$INSTANCE_NAME")"
  HD="${HD%/}"
  [[ "$HD" =~ ^/[A-Za-z0-9._/-]+$ ]] ||
    fail "HOST_DIR '$HD' must be an absolute path of letters, digits, '.', '_', '-' and '/'"
  case "/$HD/" in */../*|*/./*) fail "HOST_DIR '$HD' must not contain . or .. components" ;; esac
  PROJECT="margince-$INSTANCE_NAME"
}

need_state() {
  [ -n "${DEPLOY_STATE_DIR:-}" ] && [ -d "$DEPLOY_STATE_DIR" ] ||
    fail "DEPLOY_STATE_DIR is not set or not a directory (run through scripts/deploy.sh)"
}

connect() {
  need_state
  host_ssh_setup "$DEPLOY_STATE_DIR" "$TARGET" || exit 1
}

# number <name> <default> — a positive whole number setting.
number() {
  local n
  n="$(setting "$1" "$2")"
  [[ "$n" =~ ^[0-9]+$ ]] || fail "$1 must be a whole number of seconds: '$n'"
  printf '%s\n' "$n"
}

# dc <version> — the remote compose command for a release directory.
dc() {
  local rel="$HD/releases/$1"
  printf 'docker compose -p %s -f %s --env-file %s' "$(host_q "$PROJECT")" "$(host_q "$rel/compose.yaml")" "$(host_q "$rel/compose.env")"
}

# registry_host — the registry to log in to: the first part of IMAGE_REPO
# when it names a host (contains . or :, or is localhost); empty for Docker Hub.
registry_host() {
  local first="${IMAGE_REPO%%/*}"
  [ "$first" != "${IMAGE_REPO:-}" ] || return 0
  case "$first" in *.*|*:*|localhost) printf '%s' "$first" ;; esac
}

# registry_login — when REGISTRY_USERNAME is set: docker login on the server
# into a DOCKER_CONFIG directory of this step ($HOST_DIR/.docker-<step>-<pid>,
# mode 700), removed again when the step ends (EXIT trap), so no registry
# credential stays on the server. Sets REG, the prefix for the remote docker
# commands that need the login (manifest inspect, pull); empty without a
# login. The password goes to standard input, never to a command line.
REG=""
REG_DIR=""
registry_end() {
  [ -n "$REG_DIR" ] || return 0
  host_ssh "rm -rf $(host_q "$REG_DIR")" || echo "deploy: could not remove $REG_DIR on $TARGET; remove it by hand (it holds a registry login)" >&2
  REG_DIR=""
}
registry_login() {
  [ -n "${REGISTRY_USERNAME:-}" ] || return 0
  [ -n "${REGISTRY_PASSWORD:-}" ] || fail "REGISTRY_USERNAME is set, so REGISTRY_PASSWORD must be set too"
  local cmd reg dir="$HD/.docker-$step-$$"
  reg="$(registry_host)"
  host_ssh "mkdir -p $(host_q "$HD") && rm -rf $(host_q "$dir") && mkdir -m 700 $(host_q "$dir")" ||
    fail "cannot create $dir on $TARGET"
  REG_DIR="$dir"
  trap registry_end EXIT
  REG="DOCKER_CONFIG=$(host_q "$dir") "
  cmd="${REG}docker login --username $(host_q "$REGISTRY_USERNAME") --password-stdin"
  [ -z "$reg" ] || cmd="$cmd $(host_q "$reg")"
  printf '%s' "$REGISTRY_PASSWORD" | host_ssh "$cmd" >/dev/null ||
    fail "docker login to ${reg:-Docker Hub} as $REGISTRY_USERNAME failed on $TARGET"
}

# switch_current <version> — point $HOST_DIR/current at releases/<version>
# atomically: a new link, renamed over the old one (GNU mv -T).
switch_current() {
  host_ssh "ln -sfn $(host_q "releases/$1") $(host_q "$HD/current.tmp") && mv -T $(host_q "$HD/current.tmp") $(host_q "$HD/current")" ||
    fail "cannot point $HD/current at releases/$1"
  say "current -> releases/$1"
}

# render_into <dir> — host/render.sh into <dir>; its stdout is dropped, its
# errors (which name variables, never values) are shown.
render_into() {
  bash "$HOST_FILES/render.sh" "$1" >/dev/null
}

check() {
  load
  [ -f "$DEPLOY_DIR/config/margince.yaml" ] || fail "the host adapter needs $DEPLOY_DIR/config/margince.yaml"
  [ -f "$DEPLOY_DIR/secrets" ] || fail "the host adapter needs $DEPLOY_DIR/secrets (one environment variable name per line)"
}

preflight() {
  load
  need_state
  local tmp v img
  tmp="$(mktemp -d "$DEPLOY_STATE_DIR/preflight.XXXXXX")"
  if ! render_into "$tmp"; then
    rm -rf "$tmp"
    fail "the release files for $DEPLOY_VERSION cannot be built (see above)"
  fi
  rm -rf "$tmp"
  connect
  host_ssh true || fail "cannot connect to $TARGET over SSH (check HOST_SSH, HOST_SSH_KEY, HOST_KNOWN_HOSTS)"
  host_ssh "docker version --format '{{.Server.Version}}'" >/dev/null ||
    fail "Docker on $TARGET does not answer for this user; run make host-bootstrap ENV=$DEPLOY_ENV"
  host_ssh "command -v timeout" >/dev/null || fail "$TARGET has no 'timeout' command (coreutils)"
  v="$(host_ssh "docker compose version --short")" ||
    fail "$TARGET has no Docker Compose plugin; run make host-bootstrap ENV=$DEPLOY_ENV"
  host_version_at_least "$v" "$HOST_MIN_COMPOSE" ||
    fail "Docker Compose on $TARGET is $v; the host adapter needs $HOST_MIN_COMPOSE or later (compose.yaml uses env_file format: raw)"
  registry_login
  for img in "$IMAGE_API" "$IMAGE_WEB" "$IMAGE_WORKER"; do
    host_ssh "${REG}docker manifest inspect $(host_q "$img")" >/dev/null ||
      fail "$TARGET cannot read the manifest of $img (is the release pushed, and the registry login right?)"
  done
  say "$TARGET is ready for $DEPLOY_VERSION (Docker Compose $v)"
}

# prune — remove release directories beyond the newest KEEP_RELEASES; never
# the new release (current) or the previous one. Names that are not release
# versions are left alone.
prune() {
  local keep="$1" names name best rest pool="" sorted="" n=0 remove="" cmd=""
  names="$(host_ssh "ls -1 $(host_q "$HD/releases")")" || fail "cannot list $HD/releases"
  while IFS= read -r name; do
    if is_release_version "$name"; then pool="$pool $name"; fi
  done <<EOF_NAMES
$names
EOF_NAMES
  # Newest first.
  while [ -n "$pool" ]; do
    best=""; rest=""
    for name in $pool; do
      if [ -z "$best" ] || version_newer "$name" "$best"; then best="$name"; fi
    done
    for name in $pool; do
      [ "$name" = "$best" ] || rest="$rest $name"
    done
    sorted="$sorted $best"
    pool="$rest"
  done
  for name in $sorted; do
    n=$((n + 1))
    [ "$n" -gt "$KEEP_RELEASES" ] || continue
    case " $keep " in *" $name "*) continue ;; esac
    remove="$remove $name"
    cmd="$cmd $(host_q "$HD/releases/$name")"
  done
  [ -n "$cmd" ] || return 0
  host_ssh "rm -rf$cmd" || fail "cannot remove old release directories:$remove"
  say "removed old releases:$remove"
}

apply() {
  load
  connect
  local v="$DEPLOY_VERSION" prev out up script res timeout_s
  timeout_s="$(number HOST_APPLY_TIMEOUT 600)"
  is_release_version "$v" || fail "DEPLOY_VERSION '$v' is not a release version"

  prev="$(host_ssh "if [ -L $(host_q "$HD/current") ]; then readlink $(host_q "$HD/current"); fi")" ||
    fail "cannot read $HD/current on $TARGET"
  prev="${prev##*/}"
  if [ -n "$prev" ]; then
    is_release_version "$prev" || fail "$HD/current points at '$prev', which is not a release directory"
    printf '%s\n' "$prev" > "$DEPLOY_STATE_DIR/previous"
    say "running release: $prev"
  else
    : > "$DEPLOY_STATE_DIR/previous"
    say "no running release on $TARGET"
  fi

  # A .replaced-<v> directory is the older copy of a redeployed release, kept
  # for that deployment's rollback. The deployment has ended, so it goes.
  host_ssh "if [ -d $(host_q "$HD/releases") ]; then cd $(host_q "$HD/releases") && rm -rf .replaced-*; fi" ||
    fail "cannot clean $HD/releases on $TARGET"

  out="$(mktemp -d "$DEPLOY_STATE_DIR/release.XXXXXX")"
  render_into "$out" || { rm -rf "$out"; fail "the release files for $v cannot be built"; }

  up="$HD/.upload-$v"
  host_ssh "mkdir -p $(host_q "$HD/releases") $(host_q "$HD/shared/caddy") && rm -rf $(host_q "$up")" ||
    { rm -rf "$out"; fail "cannot prepare $HD on $TARGET"; }
  if ! host_scp -r -p -q "$out" "$TARGET:$up"; then
    rm -rf "$out"
    fail "the upload to $TARGET:$up failed"
  fi
  rm -rf "$out"

  # Install the upload. The running release directory, when it is the one
  # being redeployed, is moved to .replaced-<v> for the rollback. data.env:
  # created once (noclobber), never replaced. A changed Caddyfile is staged as
  # caddy/Caddyfile.new and renamed over Caddyfile after `up` succeeds; on a
  # first deployment (no Caddyfile) it is installed at once.
  script="set -e
hd=$(host_q "$HD"); v=$(host_q "$v"); up=$(host_q "$up"); prev=$(host_q "$prev")
chmod 600 \"\$up/release/.env\"
if [ \"\$v\" = \"\$prev\" ] && [ -d \"\$hd/releases/\$v\" ]; then
  rm -rf \"\$hd/releases/.replaced-\$v\"
  mv \"\$hd/releases/\$v\" \"\$hd/releases/.replaced-\$v\"
  echo replaced=yes
else
  rm -rf \"\$hd/releases/\$v\"
fi
mv \"\$up/release\" \"\$hd/releases/\$v\"
mv -f \"\$up/shared/db-init.sh\" \"\$hd/shared/db-init.sh\"
mv -f \"\$up/shared/db-bootstrap.sql\" \"\$hd/shared/db-bootstrap.sql\"
rm -f \"\$hd/shared/caddy/Caddyfile.new\"
if [ ! -e \"\$hd/shared/caddy/Caddyfile\" ]; then
  mv -f \"\$up/shared/caddy/Caddyfile\" \"\$hd/shared/caddy/Caddyfile\"
  echo caddy=new
elif cmp -s \"\$up/shared/caddy/Caddyfile\" \"\$hd/shared/caddy/Caddyfile\"; then
  echo caddy=same
else
  mv -f \"\$up/shared/caddy/Caddyfile\" \"\$hd/shared/caddy/Caddyfile.new\"
  echo caddy=staged
fi
if [ ! -e \"\$hd/shared/data.env\" ]; then
  (
    umask 077
    set -C
    pg=\$(od -An -tx1 -N24 /dev/urandom | tr -d ' \\n')
    owner=\$(od -An -tx1 -N24 /dev/urandom | tr -d ' \\n')
    app=\$(od -An -tx1 -N24 /dev/urandom | tr -d ' \\n')
    for x in \"\$pg\" \"\$owner\" \"\$app\"; do [ \${#x} -eq 48 ] || exit 1; done
    printf 'POSTGRES_PASSWORD=%s\\nMARGINCE_OWNER_DSN=postgres://margince_owner:%s@postgres:5432/margince\\nMARGINCE_DSN=postgres://margince_app:%s@postgres:5432/margince\\nMARGINCE_REDIS=redis:6379\\n' \"\$pg\" \"\$owner\" \"\$app\" > \"\$hd/shared/data.env\"
  )
  chmod 600 \"\$hd/shared/data.env\"
  echo data=created
fi
rm -rf \"\$up\""
  res="$(host_ssh "$script")" || fail "installing releases/$v on $TARGET failed"
  case "$res" in *data=created*) say "created $HD/shared/data.env (database passwords, mode 600)" ;; esac
  say "uploaded $HD/releases/$v"

  case "$res" in *replaced=yes*) say "kept the running copy of $v as releases/.replaced-$v until the next deployment" ;; esac

  registry_login
  host_ssh "${REG}$(dc "$v") pull --quiet" || fail "docker compose pull failed for $v"
  registry_end
  host_ssh "timeout $timeout_s $(dc "$v") up -d --remove-orphans" ||
    fail "docker compose up failed for $v (or did not finish within HOST_APPLY_TIMEOUT=${timeout_s}s)"
  case "$res" in
    *caddy=staged*)
      host_ssh "mv -f $(host_q "$HD/shared/caddy/Caddyfile.new") $(host_q "$HD/shared/caddy/Caddyfile") && if $(dc "$v") ps --status running --services | grep -qx caddy; then $(dc "$v") exec -T caddy caddy reload --config /etc/caddy/Caddyfile; fi" ||
        fail "installing the new Caddyfile or caddy reload failed; the running proxy keeps its previous configuration"
      say "installed the changed Caddyfile"
      ;;
  esac
  switch_current "$v"
  prune "$v $prev"
}

verify() {
  load
  connect
  local v="$DEPLOY_VERSION" timeout_s interval deadline why code public
  timeout_s="$(number HOST_VERIFY_TIMEOUT 300)"
  interval="$(number HOST_VERIFY_INTERVAL 5)"
  public="$(setting HOST_VERIFY_PUBLIC 1)"
  deadline=$((SECONDS + timeout_s))
  while :; do
    if ! host_ssh "$(dc "$v") exec -T api wget -q -O /dev/null http://127.0.0.1:8080/readyz" >/dev/null 2>&1; then
      why="the api does not answer /readyz"
    elif ! host_ssh "$(dc "$v") ps --status running --services | grep -qx worker" >/dev/null 2>&1; then
      why="the worker is not running"
    else
      why=""
    fi
    [ -n "$why" ] || break
    [ "$SECONDS" -lt "$deadline" ] || fail "$why on $TARGET after ${timeout_s}s (HOST_VERIFY_TIMEOUT)"
    sleep "$interval"
  done
  say "the api answers /readyz and the worker is running"
  if [ "$public" = 0 ]; then
    say "public check skipped (HOST_VERIFY_PUBLIC=0)"
    return 0
  fi
  while :; do
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 10 "https://$DOMAIN/" 2>/dev/null)" || true
    if [[ "$code" =~ ^[0-9]{3}$ ]] && [ "$code" -ge 100 ] && [ "$code" -le 499 ]; then break; fi
    [ "$SECONDS" -lt "$deadline" ] ||
      fail "https://$DOMAIN/ answered ${code:-nothing}, not a status below 500, within ${timeout_s}s (HOST_VERIFY_TIMEOUT)"
    sleep "$interval"
  done
  say "https://$DOMAIN/ answers $code"
}

rollback() {
  load
  connect
  local v="$DEPLOY_VERSION" prev timeout_s
  timeout_s="$(number HOST_APPLY_TIMEOUT 600)"
  [ -f "$DEPLOY_STATE_DIR/previous" ] ||
    fail "apply stopped before it read the running release; the server's current release was not changed"
  prev="$(cat "$DEPLOY_STATE_DIR/previous")"
  # A Caddyfile staged by the failed apply is never installed.
  host_ssh "rm -f $(host_q "$HD/shared/caddy/Caddyfile.new")" || echo "deploy: could not remove $HD/shared/caddy/Caddyfile.new" >&2
  if [ -n "$prev" ]; then
    is_release_version "$prev" || fail "the recorded previous release '$prev' is not a release version"
    if [ "$prev" = "$v" ]; then
      # A redeployment of the running release: restore its older copy.
      host_ssh "cd $(host_q "$HD/releases") && if [ -d $(host_q ".replaced-$v") ]; then rm -rf $(host_q "$v") && mv $(host_q ".replaced-$v") $(host_q "$v") && echo restored; fi" |
        grep -q restored && say "restored the previous copy of releases/$v" ||
        echo "deploy: no older copy of releases/$v to restore; restarting the uploaded one" >&2
    fi
    host_ssh "test -f $(host_q "$HD/releases/$prev/compose.yaml")" || fail "$HD/releases/$prev is missing on $TARGET"
    host_ssh "timeout $timeout_s $(dc "$prev") up -d --remove-orphans" || fail "docker compose up failed for the previous release $prev"
    switch_current "$prev"
    return 0
  fi
  # No previous release: stop the new one and drop a current link to it.
  host_ssh "if [ -f $(host_q "$HD/releases/$v/compose.yaml") ]; then $(dc "$v") down; fi; if [ \"\$(readlink $(host_q "$HD/current") 2>/dev/null)\" = $(host_q "releases/$v") ]; then rm -f $(host_q "$HD/current"); fi" ||
    echo "deploy: docker compose down failed for $v" >&2
  fail "no previous release to roll back to"
}

case "$step" in
  check|preflight|apply|verify|rollback) "$step" ;;
  *) echo "deploy/host.sh: unknown step '$step'" >&2; exit 2 ;;
esac
