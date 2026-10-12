#!/usr/bin/env bash
# standard-setup.test.sh — the scripts that run the standard stacks' one-off
# setup during `terraform apply` (deploy/production/<cloud>/standard/scripts/
# run-setup.sh), with stand-in aws and az first on PATH. No cloud is used.
#
# Usage: bash scripts/deploy/standard-setup.test.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
AWS_RUN="$ROOT/deploy/production/aws/standard/scripts/run-setup.sh"
AZ_RUN="$ROOT/deploy/production/azure/standard/scripts/run-setup.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILURES=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }
ok()   { printf 'ok: %s\n' "$*"; }

mkdir -p "$TMP/bin"
cat >"$TMP/bin/aws" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG"
case " $* " in
  *" run-task "*) printf '%s\n' "${STUB_TASK_ARN:-None}" ;;
  *" wait tasks-stopped "*) exit "${STUB_WAIT_RC:-0}" ;;
  *" describe-tasks "*) printf '%b' "${STUB_RESULTS:-}" ;;
  *) exit 9 ;;
esac
EOF
cat >"$TMP/bin/az" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$STUB_LOG"
case " $* " in
  *" containerapp job start "*) printf '%s\n' "${STUB_EXECUTION:-}" ;;
  *" containerapp job execution show "*) printf '%s\n' "${STUB_STATUS:-Running}" ;;
  *) exit 9 ;;
esac
EOF
printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP/bin/sleep"
chmod +x "$TMP/bin/"*

aws_run() {
  : >"$TMP/log"
  env PATH="$TMP/bin:$PATH" STUB_LOG="$TMP/log" AWS_REGION=eu-central-1 CLUSTER=margince-cluster \
    TASK_DEFINITION=arn:aws:ecs:eu-central-1:123456789012:task-definition/margince-setup:3 \
    SUBNETS=subnet-a,subnet-b SECURITY_GROUP=sg-ops LOG_GROUP=/ecs/margince/setup "$@" \
    bash "$AWS_RUN" >"$TMP/out" 2>&1
}
az_run() {
  : >"$TMP/log"
  env PATH="$TMP/bin:$PATH" STUB_LOG="$TMP/log" RESOURCE_GROUP=margince-rg JOB=margince-setup "$@" \
    bash "$AZ_RUN" >"$TMP/out" 2>&1
}

# ---- AWS ----------------------------------------------------------------------
TASK=arn:aws:ecs:eu-central-1:123456789012:task/margince-cluster/abc
rc=0; aws_run STUB_TASK_ARN="$TASK" STUB_RESULTS='prepare\t0\ndatabase\t0\n' || rc=$?
if [ "$rc" = 0 ] && grep -q 'setup: done' "$TMP/out" \
    && grep -qF "awsvpcConfiguration={subnets=[subnet-a,subnet-b],securityGroups=[sg-ops],assignPublicIp=DISABLED}" "$TMP/log" \
    && grep -qF "wait tasks-stopped --cluster margince-cluster --tasks $TASK" "$TMP/log"; then
  ok "aws: runs the task in the private subnets without a public IP, waits, and passes when both containers exit 0"
else
  fail "aws: a successful setup task (rc=$rc): $(cat "$TMP/out" "$TMP/log")"
fi

rc=0; aws_run STUB_TASK_ARN="$TASK" STUB_RESULTS='prepare\t0\ndatabase\t3\n' || rc=$?
if [ "$rc" = 1 ] && grep -q 'group /ecs/margince/setup' "$TMP/out"; then
  ok "aws: fails and names the log group when a container exits non-zero"
else
  fail "aws: a failed container fails the apply (rc=$rc): $(cat "$TMP/out")"
fi

rc=0; aws_run STUB_TASK_ARN="$TASK" STUB_RESULTS='prepare\t1\ndatabase\tNone\n' || rc=$?
if [ "$rc" = 1 ]; then
  ok "aws: fails when database never ran because prepare failed"
else
  fail "aws: prepare's failure fails the apply (rc=$rc): $(cat "$TMP/out")"
fi

rc=0; aws_run STUB_TASK_ARN=None || rc=$?
if [ "$rc" = 1 ] && grep -q 'did not start' "$TMP/out" && ! grep -q 'wait' "$TMP/log"; then
  ok "aws: fails at once when the task does not start"
else
  fail "aws: a task that does not start (rc=$rc): $(cat "$TMP/out")"
fi

rc=0; aws_run SUBNETS= || rc=$?
if [ "$rc" = 1 ] && grep -q 'SUBNETS is not set' "$TMP/out" && [ ! -s "$TMP/log" ]; then
  ok "aws: refuses a missing input before calling AWS"
else
  fail "aws: a missing input (rc=$rc): $(cat "$TMP/out")"
fi

# ---- Azure ----------------------------------------------------------------------
rc=0; az_run STUB_EXECUTION=margince-setup-x1 STUB_STATUS=Succeeded || rc=$?
if [ "$rc" = 0 ] && grep -q 'setup: done' "$TMP/out" \
    && grep -qF 'containerapp job execution show --name margince-setup --resource-group margince-rg --job-execution-name margince-setup-x1' "$TMP/log"; then
  ok "azure: starts the job, follows its execution, and passes when it succeeds"
else
  fail "azure: a successful setup job (rc=$rc): $(cat "$TMP/out" "$TMP/log")"
fi

rc=0; az_run STUB_EXECUTION=margince-setup-x2 STUB_STATUS=Failed || rc=$?
if [ "$rc" = 1 ] && grep -q 'ended as Failed' "$TMP/out"; then
  ok "azure: fails when the execution fails"
else
  fail "azure: a failed execution fails the apply (rc=$rc): $(cat "$TMP/out")"
fi

rc=0; az_run STUB_EXECUTION=margince-setup-x3 STUB_STATUS=Running SETUP_TIMEOUT=0 || rc=$?
if [ "$rc" = 1 ] && grep -q "still 'Running'" "$TMP/out"; then
  ok "azure: fails when the execution outlasts SETUP_TIMEOUT"
else
  fail "azure: a hanging execution (rc=$rc): $(cat "$TMP/out")"
fi

rc=0; az_run STUB_EXECUTION= || rc=$?
if [ "$rc" = 1 ] && grep -q 'did not start' "$TMP/out"; then
  ok "azure: fails at once when the job does not start"
else
  fail "azure: a job that does not start (rc=$rc): $(cat "$TMP/out")"
fi

if [ "$FAILURES" -eq 0 ]; then
  echo "standard-setup.test.sh: all passed"
else
  echo "standard-setup.test.sh: $FAILURES failure(s)" >&2
  exit 1
fi
