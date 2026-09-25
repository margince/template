#!/usr/bin/env bash
# deploy/hook.sh — the hook adapter: run the instance's own step scripts.
#
# deploy/<env>/hooks/<step>.sh, called with bash so a missing executable bit
# does not matter. apply.sh is required; the other steps are optional — the
# caller asks `has <step>` first and only calls a step it has confirmed is
# provided, so a step's own exit code always means the step's own result,
# never "not provided". `has` exits 0 (provided) or 1 (not provided) only;
# any other exit code is an error, and the caller stops. Called by
# scripts/deploy.sh, which has exported the DEPLOY_* and IMAGE_* variables.
#
# Usage: bash scripts/deploy/hook.sh check|has <step>|preflight|apply|verify|rollback
set -euo pipefail

step="${1:-}"
# Exit 2, not set -u's 1: for `has`, 1 means "not provided".
[ -n "${DEPLOY_DIR:-}" ] || { echo "deploy/hook.sh: DEPLOY_DIR is not set (run through scripts/deploy.sh)" >&2; exit 2; }
hooks="$DEPLOY_DIR/hooks"

case "$step" in
  check)
    [ -f "$hooks/apply.sh" ] || { echo "deploy: the hook adapter needs $hooks/apply.sh" >&2; exit 1; }
    exit 0 ;;
  has)
    case "${2:-}" in
      preflight|apply|verify|rollback) ;;
      *) echo "deploy/hook.sh: unknown step '${2:-}'" >&2; exit 2 ;;
    esac
    [ -f "$hooks/${2}.sh" ]; exit $? ;;
  preflight|apply|verify|rollback)
    [ -f "$hooks/$step.sh" ] || { echo "deploy/hook.sh: $hooks/$step.sh not found (call 'has' first)" >&2; exit 2; }
    exec bash "$hooks/$step.sh" ;;
  *) echo "deploy/hook.sh: unknown step '$step'" >&2; exit 2 ;;
esac
