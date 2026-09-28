#!/usr/bin/env bash
# local.sh — run a built release on this machine with the host adapter's
# files (design Section 9.7): make local-up, make local-down and
# make local-admin-password.
#
#   up <v>          The images <repo>/{api,web,worker}:<v> must be in the
#                   local image store (make package VERSION=<v>). Ports 80
#                   and 443 must be free, unless this project's caddy holds
#                   them. Builds .local/ like a server's HOST_DIR:
#                     .local/deploy/            the built-in deploy directory,
#                                               rewritten on every run:
#                                               host.env (HOST_DOMAIN=localhost),
#                                               secrets, config/margince.yaml
#                     .local/releases/<v>/      host/render.sh's release/
#                     .local/shared/            host/render.sh's shared/, and
#                                               data.env and instance.env,
#                                               created once by host/gen-env.sh
#                                               (mode 600) and never replaced
#                     .local/current            -> releases/<v>
#                   Then runs compose up -d, reloads caddy when the Caddyfile
#                   changed, and waits until https://localhost/ answers
#                   (LOCAL_TIMEOUT seconds, default 180). Every compose call is
#                     docker compose -p <name>-local -f .local/releases/<v>/compose.yaml
#                                    --env-file .local/releases/<v>/compose.env
#   down            compose down. With WIPE=1: down -v (the database, Redis,
#                   file store and Caddy volumes) and .local/ removed.
#   admin-password  Prints the generated admin password from
#                   .local/shared/instance.env. The only command that prints it.
#
# Mode: MARGINCE_ENV=test (secrets lists MARGINCE_ENV), unless MARGINCE_LICENSE
# is set in the environment; then secrets lists MARGINCE_LICENSE and the
# stack runs in production mode with that license. The stack always uses its
# own postgres and redis: MARGINCE_DSN, MARGINCE_REDIS and MARGINCE_OWNER_DSN
# from the shell are ignored.
#
# No generated value, license or password is printed (except by
# admin-password) or passed on a command line.
#
# Usage: bash scripts/local.sh up <version> | down | admin-password
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

HOST_FILES="$ROOT/scripts/deploy/host"
LOCAL="$ROOT/.local"
DOMAIN=localhost
ADMIN_EMAIL=admin@localhost
PORTS="80 443"

say() { printf 'local: %s\n' "$*"; }

# The variables render.sh and compose would read from this shell instead of
# the files local.sh writes.
unset MARGINCE_DSN MARGINCE_REDIS MARGINCE_OWNER_DSN HOST_DOMAIN API_REPLICAS WORKER_REPLICAS COMPOSE_PROFILES
unset COMPOSE_FILE COMPOSE_PROJECT_NAME COMPOSE_ENV_FILES

name="$(instance_get name)" || die "local: cannot read name from instance.yaml"
PROJECT="$name-local"

# dc <version> — docker compose for the release directory <version>.
dc() {
  local rel="$LOCAL/releases/$1"
  shift
  docker compose -p "$PROJECT" -f "$rel/compose.yaml" --env-file "$rel/compose.env" "$@"
}

# own_caddy_running — 0 when this project's caddy container runs.
own_caddy_running() {
  [ -n "$(docker ps -q --filter "label=com.docker.compose.project=$PROJECT" --filter label=com.docker.compose.service=caddy 2>/dev/null)" ]
}

# check_ports — ports 80 and 443 are free, or held by this project's caddy.
check_ports() {
  local port out busy=""
  if ! command -v lsof >/dev/null 2>&1; then
    say "lsof not found; not checking that ports $PORTS are free"
    return 0
  fi
  own_caddy_running && return 0
  for port in $PORTS; do
    if out="$(lsof -nP "-iTCP:$port" -sTCP:LISTEN 2>/dev/null)" && [ -n "$out" ]; then
      busy="$busy
port $port is in use by: $(printf '%s\n' "$out" | awk 'NR > 1 { printf "%s%s (pid %s)", sep, $1, $2; sep = ", " }')"
    fi
  done
  [ -z "$busy" ] || die "local: make local-up needs ports 80 and 443:$busy
stop that process first (or its stack, for example with make local-down)"
}

# write_deploy_dir <dir> — the built-in local deploy directory.
write_deploy_dir() {
  local dir="$1" display_name
  display_name="$(instance_get display_name)" || die "local: cannot read display_name from instance.yaml"
  display_name="${display_name//\\/\\\\}"
  display_name="${display_name//\"/\\\"}"
  rm -rf "$dir"
  mkdir -p "$dir/config"
  printf 'HOST_DOMAIN=%s\n' "$DOMAIN" > "$dir/host.env"
  if [ -n "${MARGINCE_LICENSE:-}" ]; then
    printf 'MARGINCE_LICENSE\n' > "$dir/secrets"
  else
    printf 'MARGINCE_ENV\n' > "$dir/secrets"
  fi
  cat > "$dir/config/margince.yaml" <<EOF
# .local/deploy/config/margince.yaml — written by make local-up on every run.
# Consumed once, at first boot against an empty database (make local-down
# WIPE=1 starts over). See deploy/<env>/config/margince.yaml, written by
# make deploy-init, for a server's version of this file.
version: 1

workspace:
  name: "$display_name"
  base_currency: EUR
  timezone: UTC

bootstrap_admin:
  email: "$ADMIN_EMAIL"
  display_name: Admin
  # The api's entrypoint writes MARGINCE_ADMIN_PASSWORD (.local/shared/instance.env) here.
  password_file: secrets/admin-password

mcp:
  connector_enabled: false

email:
  enabled: false
EOF
}

up() {
  local v="${1:-}" repo role img missing="" tmp rel shr caddy_changed=0 deadline code timeout_s interval mode
  [ -n "$v" ] || die "local: pass VERSION=<v>, e.g. make local-up VERSION=v1.0.0"
  is_release_version "$v" || die "local: VERSION '$v' is not a release version (vX.Y.Z or vX.Y.Z-rc.N)"
  timeout_s="${LOCAL_TIMEOUT:-180}"
  interval="${LOCAL_INTERVAL:-2}"
  [[ "$timeout_s" =~ ^[0-9]+$ ]] || die "local: LOCAL_TIMEOUT must be a whole number of seconds"
  [[ "$interval" =~ ^[0-9]+$ ]] || die "local: LOCAL_INTERVAL must be a whole number of seconds"

  repo="$(image_repo)" || die "local: cannot read name from instance.yaml"
  export INSTANCE_NAME="$name"
  export IMAGE_API="$repo/api:$v" IMAGE_WEB="$repo/web:$v" IMAGE_WORKER="$repo/worker:$v"
  for role in api web worker; do
    img="$repo/$role:$v"
    docker image inspect "$img" >/dev/null 2>&1 || missing="$missing $img"
  done
  [ -z "$missing" ] || die "local: image(s) not found locally:$missing — run 'make package VERSION=$v' first"

  check_ports

  mkdir -p "$LOCAL/releases" "$LOCAL/shared/caddy"
  write_deploy_dir "$LOCAL/deploy"
  export DEPLOY_DIR="$LOCAL/deploy"
  [ -n "${MARGINCE_LICENSE:-}" ] || export MARGINCE_ENV=test

  tmp="$(mktemp -d "$LOCAL/.render.XXXXXX")"
  # shellcheck disable=SC2064 # expand $tmp now
  trap "rm -rf '$tmp'" EXIT
  bash "$HOST_FILES/render.sh" "$tmp/out" >/dev/null || die "local: the release files for $v cannot be built (see above)"

  rel="$LOCAL/releases/$v"
  shr="$LOCAL/shared"
  rm -rf "$rel"
  mv "$tmp/out/release" "$rel"
  mv -f "$tmp/out/shared/db-init.sh" "$shr/db-init.sh"
  mv -f "$tmp/out/shared/db-bootstrap.sql" "$shr/db-bootstrap.sql"
  if [ -e "$shr/caddy/Caddyfile" ] && ! cmp -s "$tmp/out/shared/caddy/Caddyfile" "$shr/caddy/Caddyfile"; then
    caddy_changed=1
  fi
  mv -f "$tmp/out/shared/caddy/Caddyfile" "$shr/caddy/Caddyfile"
  if [ ! -e "$shr/data.env" ]; then
    sh "$HOST_FILES/gen-env.sh" data "$shr/data.env" || die "local: cannot create $shr/data.env"
    say "created .local/shared/data.env (database passwords, mode 600)"
  fi
  if [ ! -e "$shr/instance.env" ]; then
    sh "$HOST_FILES/gen-env.sh" instance "$shr/instance.env" || die "local: cannot create $shr/instance.env"
    say "created .local/shared/instance.env (vault, connector state and webhook keys, admin password, mode 600)"
  fi
  rm -rf "$tmp"
  trap - EXIT
  ln -sfn "releases/$v" "$LOCAL/current"

  if [ -n "${MARGINCE_LICENSE:-}" ]; then mode="production mode, MARGINCE_LICENSE"; else mode="MARGINCE_ENV=test"; fi
  say "starting $PROJECT at $v ($mode)"
  dc "$v" up -d --remove-orphans || die "local: docker compose up failed for $v; see: docker compose -p $PROJECT logs"
  if [ "$caddy_changed" = 1 ]; then
    dc "$v" exec -T caddy caddy reload --config /etc/caddy/Caddyfile || die "local: caddy reload failed after a Caddyfile change"
    say "reloaded caddy with the changed Caddyfile"
  fi

  deadline=$((SECONDS + timeout_s))
  while :; do
    code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 10 "https://$DOMAIN/" 2>/dev/null)" || true
    if [[ "$code" =~ ^[0-9]{3}$ ]] && [ "$code" -ge 100 ] && [ "$code" -le 499 ]; then break; fi
    [ "$SECONDS" -lt "$deadline" ] ||
      die "local: https://$DOMAIN/ answered ${code:-nothing}, not a status below 500, within ${timeout_s}s (LOCAL_TIMEOUT); see: docker compose -p $PROJECT logs api web caddy"
    sleep "$interval"
  done

  cat <<EOF

Margince $v runs at https://$DOMAIN/
  admin email:     $ADMIN_EMAIL
  admin password:  make local-admin-password
Your browser warns about the certificate: Caddy signs https://$DOMAIN with its
own local certificate authority. Accept the warning to continue.
Stop with make local-down (make local-down WIPE=1 also removes the data).
EOF
}

down() {
  local v=""
  if [ -L "$LOCAL/current" ]; then v="$(readlink "$LOCAL/current")"; v="${v##*/}"; fi
  local args=(down)
  [ "${WIPE:-}" = 1 ] && args+=(-v)
  if [ -n "$v" ] && [ -f "$LOCAL/releases/$v/compose.yaml" ]; then
    dc "$v" "${args[@]}" || die "local: docker compose down failed"
  else
    docker compose -p "$PROJECT" "${args[@]}" || die "local: docker compose down failed"
  fi
  if [ "${WIPE:-}" = 1 ]; then
    rm -rf "$LOCAL"
    say "stopped $PROJECT and removed its volumes and .local/"
  else
    say "stopped $PROJECT; .local/ and the volumes are kept (WIPE=1 removes them)"
  fi
}

admin_password() {
  local f="$LOCAL/shared/instance.env" pw
  [ -f "$f" ] || die "local: $f not found; run make local-up VERSION=<v> first"
  pw="$(sed -n 's/^MARGINCE_ADMIN_PASSWORD=//p' "$f")"
  [ -n "$pw" ] || die "local: $f has no MARGINCE_ADMIN_PASSWORD"
  printf '%s\n' "$pw"
}

case "${1:-}" in
  up) up "${2:-}" ;;
  down) down ;;
  admin-password) admin_password ;;
  *) echo "usage: bash scripts/local.sh up <version> | down | admin-password" >&2; exit 2 ;;
esac
