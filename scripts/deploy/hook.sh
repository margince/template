#!/usr/bin/env bash
# deploy/hook.sh — the hook adapter: run the instance's own step scripts.
#
# deploy/<env>/hooks/<step>.sh, called with bash so a missing executable bit
# does not matter. apply.sh is required; the other steps are optional and a
# missing one exits 3 ("not provided"). Called by scripts/deploy.sh, which has
# exported the DEPLOY_* and IMAGE_* variables.
#
# Usage: bash scripts/deploy/hook.sh check|preflight|apply|verify|rollback
set -euo pipefail

step="${1:-}"
hooks="$DEPLOY_DIR/hooks"

case "$step" in
  check)
    [ -f "$hooks/apply.sh" ] || { echo "deploy: the hook adapter needs $hooks/apply.sh" >&2; exit 1; }
    exit 0 ;;
  preflight|apply|verify|rollback) ;;
  *) echo "deploy/hook.sh: unknown step '$step'" >&2; exit 2 ;;
esac

[ -f "$hooks/$step.sh" ] || exit 3
exec bash "$hooks/$step.sh"
