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
is_release_version "$version" ||
  die "deploy: VERSION '$version' is not a release tag; it must match $RELEASE_VERSION_RE, e.g. v1.2.0"

# The whole file first: `cli get` only parses, so an unknown adapter, a
# malformed environment name, or a missing deploy/<env>/ directory would
# otherwise reach a hook.
if ! out="$(instance_validate 2>&1)"; then
  printf '%s\n' "$out" >&2
  die "deploy: instance.yaml is not valid; nothing was deployed"
fi

# The hooks and deploy/<env>/ are read from this checkout, not from the
# release. Uncommitted changes match no commit at all, so they are refused
# unless asked for. A checkout that is not at the release tag is only
# reported: deploy.yml enforces the tag in CI, and a local run may deploy a
# release with hooks fixed after it.
if ! dirty="$(git -C "$ROOT" status --porcelain 2>&1)"; then
  die "deploy: cannot read the git status of $ROOT: $dirty"
fi
if [ -n "$dirty" ]; then
  if [ "${ALLOW_DIRTY:-}" = 1 ]; then
    echo "deploy: the working tree has uncommitted changes; deploying anyway (ALLOW_DIRTY=1)" >&2
  else
    printf '%s\n' "$dirty" >&2
    die "deploy: the working tree has uncommitted changes, so the hooks and configuration match no commit; commit them, or re-run with ALLOW_DIRTY=1"
  fi
fi
# The tag's commit, compared with HEAD: exact whichever other tags point at
# HEAD, which `git describe --exact-match` (it names only one) is not.
head="$(git -C "$ROOT" rev-parse HEAD)"
tagged="$(git -C "$ROOT" rev-parse -q --verify "refs/tags/$version^{commit}" 2>/dev/null)" || tagged=""
if [ "$tagged" != "$head" ]; then
  echo "deploy: hooks and configuration come from $(git -C "$ROOT" rev-parse --short HEAD), not from release $version" >&2
fi

# instance_get's cli exits 2 for an unknown key (no such environment) and 1
# for an unreadable or invalid instance.yaml — two different problems that
# must not share one message, or a broken file reads as a missing environment.
if out="$(instance_get "deploy.$env.adapter" 2>&1)"; then
  adapter="$out"
else
  status=$?
  if [ "$status" -eq 2 ]; then
    die "deploy: '$env' is not an environment in instance.yaml (deploy: $env: { adapter: hook })"
  else
    die "deploy: cannot read instance.yaml: $out"
  fi
fi
[ -f "$ROOT/scripts/deploy/$adapter.sh" ] || die "deploy: no adapter script scripts/deploy/$adapter.sh"
[ -d "$ROOT/deploy/$env" ] || die "deploy: missing directory deploy/$env/"

repo="$(image_repo)"
export DEPLOY_ENV="$env" DEPLOY_VERSION="$version" DEPLOY_DIR="$ROOT/deploy/$env"
# Assigned, then exported: `export X="$(cmd)"` returns export's status, not
# cmd's, so a failed read would be exported as an empty value.
name="$(instance_get name)"
export INSTANCE_NAME="$name" IMAGE_REPO="$repo"
export IMAGE_API="$repo/api:$version" IMAGE_WEB="$repo/web:$version" IMAGE_WORKER="$repo/worker:$version"

# One directory the steps of this run share (the host adapter keeps the
# previous release and its SSH files there), removed when the run ends.
state_dir="$(mktemp -d)"
trap 'rm -rf "$state_dir"' EXIT
export DEPLOY_STATE_DIR="$state_dir"

bash "$ROOT/scripts/deploy/$adapter.sh" check

# has <step> — 0 when the adapter provides the step, 1 when it does not.
# Any other exit code is the adapter failing to answer (its message is on
# stderr), never "not provided": deploy.sh stops.
has() {
  local status=0
  bash "$ROOT/scripts/deploy/$adapter.sh" has "$1" || status=$?
  case "$status" in
    0|1) return "$status" ;;
    *) die "deploy: adapter $adapter could not answer 'has $1' (exit $status)" ;;
  esac
}

# run_step <step> — 0 on success or when the adapter does not provide the
# step; the step's own exit code otherwise, unchanged. `has` is asked first,
# so a step that runs is never mistaken for a step that was skipped.
run_step() {
  local step="$1" status=0 provided=0
  export DEPLOY_STEP="$step"
  has "$step" || provided=$?
  if [ "$provided" -eq 1 ]; then
    echo "deploy: $step skipped (not provided)"
    return 0
  fi
  echo "deploy: $step ($env, $version, adapter $adapter)"
  bash "$ROOT/scripts/deploy/$adapter.sh" "$step" || status=$?
  return "$status"
}

rollback() {
  export DEPLOY_FAILED_STEP="$1"
  local status=0 provided=0
  export DEPLOY_STEP=rollback
  echo "deploy: $1 failed — rolling back"
  bash "$ROOT/scripts/deploy/$adapter.sh" has rollback || provided=$?
  if [ "$provided" -eq 1 ]; then
    echo "deploy: no rollback hook — the environment may be half-deployed" >&2
    exit 1
  elif [ "$provided" -ne 0 ]; then
    echo "deploy: adapter $adapter could not answer 'has rollback' (exit $provided) — the environment may be half-deployed" >&2
    exit 1
  fi
  bash "$ROOT/scripts/deploy/$adapter.sh" rollback || status=$?
  if [ "$status" -eq 0 ]; then
    echo "deploy: rolled back"
  else
    echo "deploy: rollback failed (exit $status) — the environment may be half-deployed" >&2
  fi
  exit 1
}

run_step preflight || die "deploy: preflight failed; nothing was changed"
run_step apply || rollback apply
run_step verify || rollback verify
echo "deploy: $env is at $version"
