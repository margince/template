#!/usr/bin/env bash
# run-setup.sh — run the one-off setup task (setup.tf) and wait for it.
# Called by terraform_data.setup during `terraform apply`. Fails unless every
# container of the task exits 0; the log is in CloudWatch, LOG_GROUP.
#
# Reads AWS_REGION, CLUSTER, TASK_DEFINITION, SUBNETS (comma-separated),
# SECURITY_GROUP and LOG_GROUP from the environment.
set -euo pipefail

for v in AWS_REGION CLUSTER TASK_DEFINITION SUBNETS SECURITY_GROUP LOG_GROUP; do
  [ -n "${!v:-}" ] || { echo "setup: $v is not set" >&2; exit 1; }
done
command -v aws >/dev/null || { echo "setup: the AWS CLI is not installed" >&2; exit 1; }

ecs() { aws ecs --region "$AWS_REGION" "$@"; }

arn="$(ecs run-task --cluster "$CLUSTER" --task-definition "$TASK_DEFINITION" \
  --launch-type FARGATE --count 1 \
  --network-configuration "awsvpcConfiguration={subnets=[$SUBNETS],securityGroups=[$SECURITY_GROUP],assignPublicIp=DISABLED}" \
  --query 'tasks[0].taskArn' --output text)"
case "$arn" in
  arn:*) echo "setup: started $arn" ;;
  *) echo "setup: the task did not start (run-task returned '$arn')" >&2; exit 1 ;;
esac

# Polls every 6 seconds, for up to 10 minutes.
ecs wait tasks-stopped --cluster "$CLUSTER" --tasks "$arn"

results="$(ecs describe-tasks --cluster "$CLUSTER" --tasks "$arn" \
  --query 'tasks[0].containers[].[name,exitCode]' --output text)"
printf '%s\n' "$results" | sed 's/^/setup: /'
if [ -n "$results" ] && printf '%s\n' "$results" | awk '$2 != "0" { bad = 1 } END { exit bad }'; then
  echo "setup: done"
else
  echo "setup: the setup task failed; its log is in CloudWatch Logs, group $LOG_GROUP" >&2
  exit 1
fi
