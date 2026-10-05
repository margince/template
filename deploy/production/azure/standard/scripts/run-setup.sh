#!/usr/bin/env bash
# run-setup.sh — run the one-off setup job (setup.tf) and wait for it.
# Called by terraform_data.setup during `terraform apply`. Fails unless the
# execution succeeds; its log is in the job's execution history and in Log
# Analytics.
#
# Reads RESOURCE_GROUP and JOB from the environment. SETUP_TIMEOUT (seconds,
# default 900) bounds the wait.
set -euo pipefail

for v in RESOURCE_GROUP JOB; do
  [ -n "${!v:-}" ] || { echo "setup: $v is not set" >&2; exit 1; }
done
command -v az >/dev/null || { echo "setup: the Azure CLI is not installed" >&2; exit 1; }

execution="$(az containerapp job start --name "$JOB" --resource-group "$RESOURCE_GROUP" --query name --output tsv)"
[ -n "$execution" ] || { echo "setup: the job did not start" >&2; exit 1; }
echo "setup: started $execution"

timeout="${SETUP_TIMEOUT:-900}"
deadline=$((SECONDS + timeout))
while :; do
  status="$(az containerapp job execution show --name "$JOB" --resource-group "$RESOURCE_GROUP" \
    --job-execution-name "$execution" --query properties.status --output tsv)"
  case "$status" in
    Succeeded) echo "setup: done"; exit 0 ;;
    Failed | Stopped | Degraded)
      echo "setup: the setup job ended as $status; see its execution $execution in the portal or Log Analytics" >&2
      exit 1 ;;
  esac
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "setup: the setup job is still '$status' after ${timeout}s" >&2
    exit 1
  fi
  sleep 10
done
