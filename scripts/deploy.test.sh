#!/usr/bin/env bash
# deploy.test.sh — the deploy steps in order, with rollback on failure.
#
# Each case builds a throwaway instance: this repository's scripts/, an
# instance.yaml with one environment, and hook scripts that append their step
# and the variables they received to a log.
#
# Usage: bash scripts/deploy.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILURES=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }
ok()   { printf 'ok: %s\n' "$*"; }

# fresh_instance <hooks...> — each hook is name[:exitcode]; default exit 0.
fresh_instance() {
  local inst hook name code
  inst="$(mktemp -d "$TMP/inst.XXXXXX")"
  cp -R "$SCRIPT_DIR" "$inst/scripts"
  printf 'name: acme\ndisplay_name: Acme\ncore: v0.0.2\nflavor: acme/margince\ndeploy:\n  staging: { adapter: hook }\n' > "$inst/instance.yaml"
  mkdir -p "$inst/deploy/staging/hooks"
  for hook in "$@"; do
    name="${hook%%:*}"; code=0
    [ "$name" != "$hook" ] && code="${hook#*:}"
    cat > "$inst/deploy/staging/hooks/$name.sh" <<EOF
#!/usr/bin/env bash
printf '%s %s %s %s %s\n' "\$DEPLOY_STEP" "\$DEPLOY_ENV" "\$DEPLOY_VERSION" "\$IMAGE_API" "\${DEPLOY_FAILED_STEP:-}" >> "$inst/log"
exit $code
EOF
  done
  printf '%s' "$inst"
}

deploy() { (cd "$1" && bash scripts/deploy.sh "$2" "$3") >/dev/null 2>&1; }
steps() { [ -f "$1/log" ] && awk '{print $1}' "$1/log" | tr '\n' ' ' | sed 's/ $//'; }

# --- success ---
inst="$(fresh_instance preflight apply verify rollback)"
if deploy "$inst" staging v1.2.3; then ok "a full deployment succeeds"; else fail "a full deployment succeeds"; fi
if [ "$(steps "$inst")" = "preflight apply verify" ]; then ok "runs preflight, apply, verify in order"; else fail "runs preflight, apply, verify in order: $(steps "$inst")"; fi
if grep -qx 'apply staging v1.2.3 acme/margince/api:v1.2.3 ' "$inst/log"; then ok "hooks receive the environment, version and image names"; else fail "hooks receive the environment, version and image names: $(cat "$inst/log")"; fi

# --- verify fails ---
inst="$(fresh_instance preflight apply verify:1 rollback)"
if deploy "$inst" staging v1; then fail "a failed verify fails the deployment"; else ok "a failed verify fails the deployment"; fi
if [ "$(steps "$inst")" = "preflight apply verify rollback" ]; then ok "a failed verify runs rollback"; else fail "a failed verify runs rollback: $(steps "$inst")"; fi
if grep -q '^rollback .* verify$' "$inst/log"; then ok "rollback receives the failed step"; else fail "rollback receives the failed step"; fi

# --- apply fails ---
inst="$(fresh_instance apply:1 verify rollback)"
if deploy "$inst" staging v1; then fail "a failed apply fails the deployment"; else ok "a failed apply fails the deployment"; fi
if [ "$(steps "$inst")" = "apply rollback" ]; then ok "a failed apply skips verify and runs rollback"; else fail "a failed apply skips verify and runs rollback: $(steps "$inst")"; fi

# --- preflight fails ---
inst="$(fresh_instance preflight:1 apply rollback)"
if deploy "$inst" staging v1; then fail "a failed preflight fails the deployment"; else ok "a failed preflight fails the deployment"; fi
if [ "$(steps "$inst")" = "preflight" ]; then ok "a failed preflight changes nothing and does not roll back"; else fail "a failed preflight changes nothing and does not roll back: $(steps "$inst")"; fi

# --- optional hooks, and a hook without the executable bit ---
inst="$(fresh_instance apply)"
chmod -x "$inst/deploy/staging/hooks/apply.sh"
if deploy "$inst" staging v1 && [ "$(steps "$inst")" = "apply" ]; then ok "only apply is required, and it runs without the executable bit"; else fail "only apply is required, and it runs without the executable bit"; fi

inst="$(fresh_instance apply verify:1)"
if deploy "$inst" staging v1; then fail "a failed verify without a rollback hook still fails"; else ok "a failed verify without a rollback hook still fails"; fi

# --- refusals run no hook ---
expect_refused() {
  local label="$1" env="$2" version="$3" inst
  inst="$(fresh_instance preflight apply)"
  [ "${4:-}" = "no-apply" ] && rm "$inst/deploy/staging/hooks/apply.sh"
  if deploy "$inst" "$env" "$version"; then fail "$label — it succeeded"
  elif [ -s "$inst/log" ]; then fail "$label — a hook ran"
  else ok "$label"; fi
}
expect_refused "refuses a missing environment" "" v1
expect_refused "refuses an environment not in instance.yaml" production v1
expect_refused "refuses a missing version" staging ""
expect_refused "refuses when apply.sh is missing" staging v1 no-apply

if [ "$FAILURES" -gt 0 ]; then printf '\n%s case(s) failed\n' "$FAILURES" >&2; exit 1; fi
printf '\nall cases passed\n'
