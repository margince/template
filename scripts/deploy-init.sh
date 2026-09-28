#!/usr/bin/env bash
# deploy-init.sh — scaffold a deploy environment and register it in
# instance.yaml (design Sections 9.6, 9.7; make deploy-init).
#
# A new environment works on its first deployment without hand-written
# secrets: this generates a working host.env, secrets and
# config/margince.yaml (or, for the hook adapter, a hooks/apply.sh scaffold)
# and adds the environment under deploy: in instance.yaml.
#
# Refuses an existing deploy/<env>/ directory and an existing deploy.<env>
# entry in instance.yaml; in either case nothing is created or changed.
#
# host (the default; ADAPTER=host) needs DOMAIN=<host> and SSH=<user@host>.
# Writes deploy/<env>/host.env, deploy/<env>/secrets and
# deploy/<env>/config/margince.yaml — every default feature on, MCP off,
# email off, ready for `make deploy` once MARGINCE_LICENSE is set.
#
# hook (ADAPTER=hook) writes deploy/<env>/hooks/apply.sh: a scaffold with a
# comment naming the variables scripts/deploy.sh exports, for you to fill in.
#
# instance.yaml is edited line-based: `deploy:` is appended if it is not
# already there, then `  <env>: { adapter: <adapter> }` is added as one of
# its lines; every other line is left untouched. The result is checked with
# the same validation `make check-instance` runs (cli check); when it is not
# valid, instance.yaml is restored and the directory this run created is
# removed, so a failure leaves nothing behind.
#
# Usage: ENV=<env> [ADAPTER=host|hook] [DOMAIN=<host>] [SSH=<user@host>]
#        [ADMIN_EMAIL=<email>] bash scripts/deploy-init.sh
#        (or: make deploy-init ENV=… ADAPTER=… DOMAIN=… SSH=… ADMIN_EMAIL=…)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$ROOT"

env="${ENV:-}"
adapter="${ADAPTER:-host}"
domain="${DOMAIN:-}"
ssh="${SSH:-}"
admin_email="${ADMIN_EMAIL:-}"

[ -n "$env" ] || die "deploy-init: pass ENV=<environment>, e.g. make deploy-init ENV=production DOMAIN=crm.example.com SSH=deploy@203.0.113.10"
[[ "$env" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || die "deploy-init: ENV '$env' must match ^[a-z0-9]+(-[a-z0-9]+)*\$"
case "$adapter" in
  host|hook) ;;
  *) die "deploy-init: ADAPTER '$adapter' is not an adapter (want host or hook)" ;;
esac

dir="$ROOT/deploy/$env"
[ ! -e "$dir" ] || die "deploy-init: $dir already exists"

# The same lookup scripts/deploy.sh uses for an adapter: exit 2 (cli_run)
# means the key is absent, which is the only case deploy-init proceeds on.
if out="$(instance_get "deploy.$env.adapter" 2>&1)"; then
  die "deploy-init: '$env' is already an environment in instance.yaml (deploy.$env: { adapter: $out })"
else
  status=$?
  [ "$status" -eq 2 ] || die "deploy-init: cannot read instance.yaml: $out"
fi

if [ "$adapter" = host ]; then
  [ -n "$domain" ] || die "deploy-init: the host adapter needs DOMAIN=<host>, e.g. DOMAIN=crm.example.com"
  [ -n "$ssh" ] || die "deploy-init: the host adapter needs SSH=<user@host>, e.g. SSH=deploy@203.0.113.10"
  # host.env is KEY=VALUE lines, written verbatim below; a raw newline would
  # split into an extra, unparseable line rather than staying part of the
  # value.
  case "$domain" in *$'\n'*|*$'\r'*) die "deploy-init: DOMAIN must be a single line" ;; esac
  case "$ssh" in *$'\n'*|*$'\r'*) die "deploy-init: SSH must be a single line" ;; esac
  [ -n "$admin_email" ] || admin_email="admin@$domain"
fi

display_name="$(instance_get display_name)" || die "deploy-init: cannot read display_name from instance.yaml"

# esc_yaml <value> — <value> safe inside a double-quoted YAML scalar
# (backslash, then double quote — same order and reasoning as
# new-instance.sh's DISPLAY_NAME escaping).
esc_yaml() {
  local v="$1"
  v="${v//\\/\\\\}"
  v="${v//\"/\\\"}"
  printf '%s' "$v"
}

write_host_files() {
  mkdir -p "$dir/config"
  cat > "$dir/host.env" <<EOF
# deploy/$env/host.env — the host adapter's server (docs/deploy.md).
# Read as KEY=VALUE lines; not executed.
HOST_SSH=$ssh
HOST_DOMAIN=$domain
EOF

  cat > "$dir/secrets" <<EOF
# deploy/$env/secrets — names of the environment variables written into
# this environment's release .env, one per line. \`make deploy\` reads each
# NAME's value from its own environment (a shell variable, or a CI secret);
# never write a value in this file.
#
# MARGINCE_KEYVAULT_ROOT_KEY, MARGINCE_CONNECTOR_STATE_KEY,
# MARGINCE_WEBHOOK_KEY and the first admin password (MARGINCE_ADMIN_PASSWORD)
# are generated once, on this environment's first \`make deploy\`, and kept
# on the server (shared/instance.env) unchanged across every later release.
# Listing one of these names here overrides the generated value with the one
# you provide. MARGINCE_KEYVAULT_ROOT_KEY must never change once data has
# been sealed with it: sealed data cannot be opened with another key.
#
# For a test environment, list MARGINCE_ENV below and set it to \`test\`
# (for example: make deploy ENV=$env VERSION=<v> MARGINCE_ENV=test); without
# it, this environment runs in production mode and preflight fails unless
# MARGINCE_LICENSE is set.
MARGINCE_LICENSE
EOF

  cat > "$dir/config/margince.yaml" <<EOF
# yaml-language-server: \$schema=../../../core/config/margince.schema.json
#
# deploy/$env/config/margince.yaml — this environment's installation
# configuration (core/config/margince.schema.json), mounted read-only into
# the api and worker containers. Consumed once, at first boot against an
# empty database; Settings edits these values afterwards. See
# core/config/margince.example.yaml and core/docs/deployment.md for the full
# reference.
version: 1

workspace:
  name: "$(esc_yaml "$display_name")" # change this — the workspace name shown in the app
  base_currency: EUR                  # change this — the ISO 4217 code deals convert against
  timezone: UTC                       # change this — the IANA timezone name

bootstrap_admin:
  email: "$(esc_yaml "$admin_email")"
  display_name: Admin
  # Read at boot from /app/secrets/admin-password (the api's working
  # directory is /app; core/docs/deployment.md, "First-boot bootstrap
  # config"). The generated password lands there from shared/instance.env on
  # the server, unless you list MARGINCE_ADMIN_PASSWORD in
  # deploy/$env/secrets.
  password_file: secrets/admin-password

# Remote MCP connector (design Section 5.5, Gate 1). Off: turning it on
# exposes an internet-facing authorization server and the agent tool
# surface, which is an explicit operator decision.
mcp:
  connector_enabled: false

# Outbound transactional email (password reset). Off until you set an SMTP
# relay: uncomment enabled and smtp below.
email:
  enabled: false
  # smtp:
  #   host: smtp.example.test
  #   port: 587
  #   username: <smtp-username>
  #   password: \${env:MARGINCE_SMTP_PASSWORD}
  #   from_address: noreply@$domain
EOF
}

write_hook_files() {
  mkdir -p "$dir/hooks"
  cat > "$dir/hooks/apply.sh" <<EOF
#!/usr/bin/env bash
# deploy/$env/hooks/apply.sh — deploy $env your way (docs/deploy.md).
#
# scripts/deploy.sh runs this script for the "apply" step, exporting the
# variables every step of every adapter receives:
#   DEPLOY_ENV        the environment name ($env)
#   DEPLOY_VERSION    the release being deployed, e.g. v1.2.0
#   DEPLOY_STEP       the step's own name (apply, here)
#   DEPLOY_DIR        deploy/$env/, this directory, as an absolute path
#   DEPLOY_STATE_DIR  one directory shared by this run's steps, removed when
#                     the run ends
#   INSTANCE_NAME     name from instance.yaml
#   IMAGE_REPO        the image namespace
#   IMAGE_API, IMAGE_WEB, IMAGE_WORKER   \$IMAGE_REPO/<role>:\$DEPLOY_VERSION
#
# Add preflight.sh, verify.sh and rollback.sh beside this file for the other
# steps; each of the four is optional except this one — a missing one is
# skipped, not failed. A failed apply or verify runs rollback.sh
# (DEPLOY_FAILED_STEP names which step failed); without a rollback.sh the
# deployment still fails, unrolled back.
#
# Replace the lines below with your own deployment: pull the images, run
# migrations, restart the services.
set -euo pipefail
echo "deploy/$env/hooks/apply.sh: not configured yet — edit this file to deploy \$IMAGE_API, \$IMAGE_WEB and \$IMAGE_WORKER" >&2
exit 1
EOF
  chmod +x "$dir/hooks/apply.sh"
}

# add_deploy_env <file> — `deploy:` is appended when absent, then
# `  <env>: { adapter: <adapter> }` is added as one of its lines. Every other
# line is left exactly as it was: no other line is read, reordered or
# rewritten.
#
# The `deploy:` line is matched with a pattern, not string equality, so a
# trailing comment (`deploy: # environments`) is still recognized as the key
# rather than read as absent — which would otherwise plant a second,
# shadowing top-level `deploy:` block.
DEPLOY_KEY_RE='^deploy:[[:space:]]*(#.*)?$'
add_deploy_env() {
  local file="$1" tmp
  tmp="$(mktemp)"
  if grep -qE "$DEPLOY_KEY_RE" "$file"; then
    awk -v line="  $env: { adapter: $adapter }" -v re="$DEPLOY_KEY_RE" '
      { print }
      $0 ~ re && !done { print line; done = 1 }
    ' "$file" > "$tmp"
  else
    cp "$file" "$tmp"
    printf 'deploy:\n  %s: { adapter: %s }\n' "$env" "$adapter" >> "$tmp"
  fi
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

mkdir -p "$dir"
if [ "$adapter" = host ]; then write_host_files; else write_hook_files; fi

backup="$(mktemp)"
cp "$ROOT/instance.yaml" "$backup"
add_deploy_env "$ROOT/instance.yaml"

# The same validation `make check-instance` runs. A problem here is never
# this run's own edit — that edit is a well-formed line matching the format
# instance.yaml already validates — so it is a pre-existing problem
# elsewhere in the file; either way, nothing this run did is kept.
if ! check_out="$(cd "$ROOT/scripts/cli" && GOWORK=off go run . check -file "$ROOT/instance.yaml" -core "$CORE" 2>&1)"; then
  cp "$backup" "$ROOT/instance.yaml"
  rm -f "$backup"
  rm -rf "$dir"
  printf '%s\n' "$check_out" >&2
  die "deploy-init: the instance.yaml this would produce is not valid (see above); nothing was created"
fi
rm -f "$backup"

echo "deploy-init: wrote deploy/$env/ and added deploy.$env: { adapter: $adapter } to instance.yaml"
echo
echo "next steps:"
if [ "$adapter" = host ]; then
  echo "  set MARGINCE_LICENSE (production) — or list MARGINCE_ENV in deploy/$env/secrets and set it to test"
  echo "  make host-bootstrap ENV=$env"
else
  echo "  edit deploy/$env/hooks/apply.sh (add preflight.sh, verify.sh, rollback.sh if you need them)"
fi
echo "  make deploy ENV=$env VERSION=<v>"
