#!/usr/bin/env bash
# deploy/host/admin-password.sh — print the first admin password of a host
# adapter environment (make host-admin-password, design Section 9.7).
#
# When deploy/<env>/secrets lists MARGINCE_ADMIN_PASSWORD, the password is
# the value the client provides, and this script says so without printing
# anything else. Otherwise it reads MARGINCE_ADMIN_PASSWORD from
# $HOST_DIR/shared/instance.env on the server over SSH (the same options and
# credentials as the host adapter: HOST_KNOWN_HOSTS, HOST_SSH_KEY) and prints
# only the password, on one line. The password travels on the SSH output,
# never on a command line.
#
# HOST_DIR comes from the environment, else from host.env, else
# /opt/margince/<name>.
#
# Usage: bash scripts/deploy/host/admin-password.sh <env>   (or: make host-admin-password ENV=<env>)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/../../lib.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

env="${1:-}"
[ -n "$env" ] || die "host-admin-password: pass ENV=<environment>, e.g. make host-admin-password ENV=prod"

if ! out="$(instance_validate 2>&1)"; then
  printf '%s\n' "$out" >&2
  die "host-admin-password: instance.yaml is not valid"
fi
if adapter="$(instance_get "deploy.$env.adapter" 2>/dev/null)"; then :; else
  die "host-admin-password: '$env' is not an environment in instance.yaml (deploy: $env: { adapter: host })"
fi
[ "$adapter" = host ] || die "host-admin-password: environment '$env' uses the $adapter adapter; host-admin-password is for the host adapter"
name="$(instance_get name)" || die "host-admin-password: instance.yaml has no name"
export DEPLOY_DIR="$ROOT/deploy/$env"

if host_secrets_lists MARGINCE_ADMIN_PASSWORD; then
  echo "host-admin-password: $env takes MARGINCE_ADMIN_PASSWORD from deploy/$env/secrets; the password is the value you provide there, not a generated one"
  exit 0
fi

target="$(host_ssh_target)" || exit 1
hd="$(host_dir "$name")" || exit 1
state="$(mktemp -d)"
trap 'rm -rf "$state"' EXIT
host_ssh_setup "$state" "$target" || die "host-admin-password: cannot set up SSH"

file="$hd/shared/instance.env"
pw="$(host_ssh "if [ -f $(host_q "$file") ]; then sed -n 's/^MARGINCE_ADMIN_PASSWORD=//p' $(host_q "$file"); else echo 'no-instance-env' >&2; exit 3; fi" 2>"$state/err")" || {
  rc=$?
  if grep -q no-instance-env "$state/err"; then
    die "host-admin-password: $target has no $file; run make deploy ENV=$env VERSION=<v> first"
  fi
  cat "$state/err" >&2
  die "host-admin-password: cannot read $file on $target over SSH (exit $rc)"
}
[ -n "$pw" ] || die "host-admin-password: $file on $target holds no MARGINCE_ADMIN_PASSWORD (it was created while secrets listed MARGINCE_ADMIN_PASSWORD)"
printf '%s\n' "$pw"
