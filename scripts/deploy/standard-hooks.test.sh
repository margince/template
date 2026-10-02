#!/usr/bin/env bash
# standard-hooks.test.sh — the `make deploy` hooks of the AWS and Azure
# standard stacks (deploy/production/<cloud>/standard/hooks/), with stand-in
# terraform and curl first on PATH. No cloud, registry or network is used.
#
# Usage: bash scripts/deploy/standard-hooks.test.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
unset TERRAFORM_DIR VERIFY_TIMEOUT STUB_PREVIOUS STUB_RELEASE STUB_READY_RC STUB_TF_RC

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILURES=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }
ok()   { printf 'ok: %s\n' "$*"; }

# ---- stubs -------------------------------------------------------------------
mkdir -p "$TMP/bin"
cat >"$TMP/bin/terraform" <<'EOF'
#!/usr/bin/env bash
# Logs its arguments; answers the two outputs the hooks read.
printf '%s\n' "$*" >>"$STUB_LOG"
args=" $* "
case "$args" in
  *" output -raw release_version "*)
    [ -n "${STUB_PREVIOUS:-}" ] || exit 1
    printf '%s' "$STUB_PREVIOUS" ;;
  *" output -raw public_base_url "*) printf 'https://crm.example.test' ;;
  *) exit "${STUB_TF_RC:-0}" ;;
esac
EOF
cat >"$TMP/bin/curl" <<'EOF'
#!/usr/bin/env bash
for url; do :; done
case "$url" in
  */readyz) exit "${STUB_READY_RC:-0}" ;;
  */v1/auth/capabilities) printf '{"password":true,"release_version":"%s"}' "${STUB_RELEASE:-}" ;;
  *) exit 7 ;;
esac
EOF
cat >"$TMP/bin/sleep" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/bin/"*

# run_hook <cloud> <step> — run one hook in a fresh deployment state; the
# output goes to $TMP/out, the terraform calls to $TMP/tf.log.
run_hook() {
  local cloud="$1" step="$2"
  PATH="$TMP/bin:$PATH" STUB_LOG="$TMP/tf.log" TERRAFORM_DIR="$TF_DIR" \
    DEPLOY_STATE_DIR="$STATE" IMAGE_REPO=ghcr.io/acme/margince-default DEPLOY_VERSION=v1.4.0 \
    bash "$ROOT/deploy/production/$cloud/standard/hooks/$step.sh" >"$TMP/out" 2>&1
}

fresh() {
  STATE="$(mktemp -d "$TMP/state.XXXXXX")"
  TF_DIR="$(mktemp -d "$TMP/tf.XXXXXX")"
  mkdir -p "$TF_DIR/.terraform"
  : >"$TMP/tf.log"
}

for cloud in aws azure; do
  if [ "$cloud" = azure ]; then extra=' -var deploy_apps=true'; else extra=''; fi
  plan_line="-chdir=TFDIR plan -input=false -out=STATE/release.tfplan -var image_repo=ghcr.io/acme/margince-default -var release_version=VERSION$extra"

  # -- preflight --
  fresh
  rc=0; STUB_PREVIOUS=v1.3.0 run_hook "$cloud" preflight || rc=$?
  want="${plan_line//TFDIR/$TF_DIR}"; want="${want//STATE/$STATE}"; want="${want//VERSION/v1.4.0}"
  if [ "$rc" = 0 ] && grep -qxF -- "$want" "$TMP/tf.log" && [ "$(cat "$STATE/previous-release")" = v1.3.0 ]; then
    ok "$cloud: preflight records the running release and plans <repo>/<role>:<version>"
  else
    fail "$cloud: preflight records the running release and plans the new one (rc=$rc): $(cat "$TMP/out" "$TMP/tf.log")"
  fi

  fresh
  rc=0; run_hook "$cloud" preflight || rc=$?
  if [ "$rc" = 0 ] && [ -f "$STATE/previous-release" ] && [ ! -s "$STATE/previous-release" ]; then
    ok "$cloud: preflight before the first release records no previous release"
  else
    fail "$cloud: preflight before the first release (rc=$rc): $(cat "$TMP/out")"
  fi

  fresh
  rmdir "$TF_DIR/.terraform"
  rc=0; run_hook "$cloud" preflight || rc=$?
  if [ "$rc" = 1 ] && grep -q 'is not initialized' "$TMP/out" && [ ! -s "$TMP/tf.log" ]; then
    ok "$cloud: preflight refuses an uninitialized stack and runs no terraform command"
  else
    fail "$cloud: preflight refuses an uninitialized stack (rc=$rc): $(cat "$TMP/out")"
  fi

  # -- apply --
  fresh
  : >"$STATE/release.tfplan"
  rc=0; run_hook "$cloud" apply || rc=$?
  if [ "$rc" = 0 ] && grep -qxF -- "-chdir=$TF_DIR apply -input=false $STATE/release.tfplan" "$TMP/tf.log"; then
    ok "$cloud: apply applies exactly the plan preflight wrote"
  else
    fail "$cloud: apply applies the plan (rc=$rc): $(cat "$TMP/out" "$TMP/tf.log")"
  fi

  fresh
  rc=0; run_hook "$cloud" apply || rc=$?
  if [ "$rc" = 1 ] && grep -q 'no plan' "$TMP/out" && [ ! -s "$TMP/tf.log" ]; then
    ok "$cloud: apply without a plan fails and changes nothing"
  else
    fail "$cloud: apply without a plan fails (rc=$rc): $(cat "$TMP/out")"
  fi

  # -- verify --
  fresh
  rc=0; STUB_RELEASE=v1.4.0 run_hook "$cloud" verify || rc=$?
  if [ "$rc" = 0 ] && grep -q 'runs v1.4.0' "$TMP/out"; then
    ok "$cloud: verify passes once the api is ready and reports the release"
  else
    fail "$cloud: verify passes on the new release (rc=$rc): $(cat "$TMP/out")"
  fi

  fresh
  rc=0; STUB_RELEASE=v1.3.0 VERIFY_TIMEOUT=0 run_hook "$cloud" verify || rc=$?
  if [ "$rc" = 1 ] && grep -q 'did not report release v1.4.0' "$TMP/out"; then
    ok "$cloud: verify fails while the api still reports the previous release"
  else
    fail "$cloud: verify fails on the previous release (rc=$rc): $(cat "$TMP/out")"
  fi

  fresh
  rc=0; STUB_RELEASE=v1.4.0 STUB_READY_RC=22 VERIFY_TIMEOUT=0 run_hook "$cloud" verify || rc=$?
  if [ "$rc" = 1 ]; then
    ok "$cloud: verify fails while /readyz is not 200"
  else
    fail "$cloud: verify fails while /readyz is not 200 (rc=$rc): $(cat "$TMP/out")"
  fi

  # -- rollback --
  fresh
  printf 'v1.3.0' >"$STATE/previous-release"
  rc=0; run_hook "$cloud" rollback || rc=$?
  want="${plan_line//TFDIR/$TF_DIR}"; want="${want//STATE/$STATE}"; want="${want//VERSION/v1.3.0}"
  if [ "$rc" = 0 ] && grep -qxF -- "$want" "$TMP/tf.log" && grep -qxF -- "-chdir=$TF_DIR apply -input=false $STATE/release.tfplan" "$TMP/tf.log"; then
    ok "$cloud: rollback plans and applies the recorded release"
  else
    fail "$cloud: rollback goes back to the recorded release (rc=$rc): $(cat "$TMP/out" "$TMP/tf.log")"
  fi

  fresh
  : >"$STATE/previous-release"
  rc=0; run_hook "$cloud" rollback || rc=$?
  if [ "$rc" = 1 ] && grep -q 'nothing to roll back to' "$TMP/out" && [ ! -s "$TMP/tf.log" ]; then
    ok "$cloud: rollback without a recorded release fails and changes nothing"
  else
    fail "$cloud: rollback without a recorded release (rc=$rc): $(cat "$TMP/out")"
  fi
done

# The two stacks' hooks differ only in the inputs each release apply sets.
if diff <(grep -v -e '^EXTRA_VARS=' -e '^# Inputs every release apply' -e '^# the gateway exist' "$ROOT/deploy/production/aws/standard/hooks/lib.sh") \
  <(grep -v -e '^EXTRA_VARS=' -e '^# Inputs every release apply' -e '^# the gateway exist' "$ROOT/deploy/production/azure/standard/hooks/lib.sh") >/dev/null; then
  ok "the AWS and Azure hooks are the same apart from EXTRA_VARS"
else
  fail "the AWS and Azure hooks differ beyond EXTRA_VARS"
fi

if [ "$FAILURES" -eq 0 ]; then
  echo "standard-hooks.test.sh: all passed"
else
  echo "standard-hooks.test.sh: $FAILURES failure(s)" >&2
  exit 1
fi
