#!/usr/bin/env bash
# hooks/lib.sh — the `make deploy` steps of this standard stack, for the
# template's hook adapter (docs/deploy.md). The steps ship one release:
#
#   preflight  record the running release, plan the new one; nothing changes
#   apply      apply exactly that plan
#   verify     wait until the api answers /readyz and reports the release
#   rollback   plan and apply the release preflight recorded
#
# The images are <IMAGE_REPO>/<role>:<DEPLOY_VERSION>, the references
# `make deploy` exports, passed to Terraform as image_repo and release_version.
# All three roles move in one apply; core's release guard refuses a mixed set.
#
# TERRAFORM_DIR is the stack directory, initialized with its backend
# (`terraform init -backend-config=backend.hcl`); default: the directory that
# holds hooks/. The stack's other inputs come from terraform.tfvars or TF_VAR_*.
# VERIFY_TIMEOUT (seconds, default 900) bounds the wait in verify.
set -euo pipefail

: "${DEPLOY_STATE_DIR:?run through make deploy}" "${IMAGE_REPO:?run through make deploy}" "${DEPLOY_VERSION:?run through make deploy}"

TF_DIR="${TERRAFORM_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
PLAN="$DEPLOY_STATE_DIR/release.tfplan"
PREVIOUS="$DEPLOY_STATE_DIR/previous-release"
# Inputs every release apply sets besides the release itself.
EXTRA_VARS=()

die() { echo "deploy: $*" >&2; exit 1; }
tf() { terraform -chdir="$TF_DIR" "$@"; }

plan_release() {
  tf plan -input=false -out="$PLAN" \
    -var "image_repo=$IMAGE_REPO" -var "release_version=$1" ${EXTRA_VARS[@]+"${EXTRA_VARS[@]}"}
}

step_preflight() {
  command -v terraform >/dev/null || die "terraform is not installed"
  command -v curl >/dev/null || die "curl is not installed"
  [ -d "$TF_DIR/.terraform" ] || die "$TF_DIR is not initialized: run terraform init -backend-config=backend.hcl there first"
  # The running release, for rollback; empty before the first release.
  tf output -raw release_version >"$PREVIOUS" 2>/dev/null || : >"$PREVIOUS"
  plan_release "$DEPLOY_VERSION"
}

step_apply() {
  [ -f "$PLAN" ] || die "no plan: preflight did not run"
  tf apply -input=false "$PLAN"
}

step_verify() {
  local url timeout deadline body
  url="$(tf output -raw public_base_url)" || die "the stack has no public_base_url output"
  timeout="${VERIFY_TIMEOUT:-900}"
  deadline=$((SECONDS + timeout))
  while :; do
    if curl -fsS --max-time 10 -o /dev/null "$url/readyz" 2>/dev/null &&
      body="$(curl -fsS --max-time 10 "$url/v1/auth/capabilities" 2>/dev/null)" &&
      [[ "$body" == *"\"release_version\":\"$DEPLOY_VERSION\""* ]]; then
      echo "deploy: $url is ready and runs $DEPLOY_VERSION"
      return 0
    fi
    [ "$SECONDS" -lt "$deadline" ] || die "$url did not report release $DEPLOY_VERSION as ready within ${timeout}s"
    sleep 10
  done
}

step_rollback() {
  local previous
  previous="$(cat "$PREVIOUS" 2>/dev/null || true)"
  [ -n "$previous" ] || die "no previous release recorded; nothing to roll back to"
  echo "deploy: rolling back to $previous"
  plan_release "$previous"
  tf apply -input=false "$PLAN"
}
