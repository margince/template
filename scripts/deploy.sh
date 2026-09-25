#!/usr/bin/env bash
# deploy.sh — deploy this instance to one environment (design Section 10.4).
#
# preflight -> apply -> verify. A failed apply or verify runs rollback, then the
# deployment fails. A failed preflight stops without rollback: nothing changed.
# The adapter named for the environment in instance.yaml runs each step.
#
# Usage: bash scripts/deploy.sh <env> <version>   (or: make deploy ENV=<env> VERSION=<v>)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$ROOT"

env="${1:-}"
version="${2:-}"
[ -n "$env" ] || die "deploy: pass ENV=<environment>, e.g. make deploy ENV=staging VERSION=v1.0.0"
[ -n "$version" ] || die "deploy: pass VERSION=<release>, e.g. make deploy ENV=$env VERSION=v1.0.0"

adapter="$(instance_get "deploy.$env.adapter" 2>/dev/null)" \
  || die "deploy: '$env' is not an environment in instance.yaml (deploy: $env: { adapter: hook })"
[ -f "$ROOT/scripts/deploy/$adapter.sh" ] || die "deploy: no adapter script scripts/deploy/$adapter.sh"
[ -d "$ROOT/deploy/$env" ] || die "deploy: missing directory deploy/$env/"

repo="$(image_repo)"
export DEPLOY_ENV="$env" DEPLOY_VERSION="$version" DEPLOY_DIR="$ROOT/deploy/$env"
export INSTANCE_NAME="$(instance_get name)" IMAGE_REPO="$repo"
export IMAGE_API="$repo/api:$version" IMAGE_WEB="$repo/web:$version" IMAGE_WORKER="$repo/worker:$version"

bash "$ROOT/scripts/deploy/$adapter.sh" check

# run_step <step> — 0 on success or when the adapter does not provide the step.
run_step() {
  local status=0
  export DEPLOY_STEP="$1"
  echo "deploy: $DEPLOY_STEP ($env, $version, adapter $adapter)"
  bash "$ROOT/scripts/deploy/$adapter.sh" "$1" || status=$?
  if [ "$status" -eq 3 ]; then
    echo "deploy: $1 skipped (not provided)"
    return 0
  fi
  return "$status"
}

rollback() {
  export DEPLOY_FAILED_STEP="$1"
  local status=0
  export DEPLOY_STEP=rollback
  echo "deploy: $1 failed — rolling back"
  bash "$ROOT/scripts/deploy/$adapter.sh" rollback || status=$?
  case "$status" in
    0) echo "deploy: rolled back" ;;
    3) echo "deploy: no rollback hook — the environment may be half-deployed" >&2 ;;
    *) echo "deploy: rollback failed (exit $status) — the environment may be half-deployed" >&2 ;;
  esac
  exit 1
}

run_step preflight || die "deploy: preflight failed; nothing was changed"
run_step apply || rollback apply
run_step verify || rollback verify
echo "deploy: $env is at $version"
