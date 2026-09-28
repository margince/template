#!/usr/bin/env bash
# deploy.test.sh — the deploy steps in order, with rollback on failure.
#
# Each case builds a throwaway instance: a git repository holding this
# repository's scripts/, an instance.yaml with one environment, and hook
# scripts that append their step and the variables they received to a log.
# The instance is committed and tagged v1.0.0, because deploy.sh refuses a
# dirty working tree and warns when HEAD is not at the release tag.
#
# Usage: bash scripts/deploy.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Hermetic against the developer's git config and a git hook's environment.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_COMMON_DIR ALLOW_DIRTY
export GIT_AUTHOR_NAME="Test Dev"     GIT_AUTHOR_EMAIL="dev@example.test"
export GIT_COMMITTER_NAME="Test Dev"  GIT_COMMITTER_EMAIL="dev@example.test"
export GIT_CONFIG_NOSYSTEM=1

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILURES=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }
ok()   { printf 'ok: %s\n' "$*"; }

git_q() { git -C "$1" -c commit.gpgsign=false -c tag.gpgsign=false "${@:2}" >/dev/null; }

# commit_all <inst> — commit every change, so the working tree is clean again.
commit_all() { git_q "$1" add -A && git_q "$1" commit -q --allow-empty -m change; }

# fresh_instance <hooks...> — each hook is name[:exitcode]; default exit 0.
fresh_instance() {
  local inst hook name code
  inst="$(mktemp -d "$TMP/inst.XXXXXX")"
  cp -R "$SCRIPT_DIR" "$inst/scripts"
  printf 'name: acme\ndisplay_name: Acme\ncore: v0.0.2\ndeploy:\n  staging: { adapter: hook }\n' > "$inst/instance.yaml"
  printf '/log\n' > "$inst/.gitignore"
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
  git_q "$inst" init -q
  commit_all "$inst"
  git_q "$inst" tag v1.0.0
  printf '%s' "$inst"
}

deploy() { (cd "$1" && bash scripts/deploy.sh "$2" "$3") >/dev/null 2>&1; }
deploy_out() { (cd "$1" && bash scripts/deploy.sh "$2" "$3") 2>&1; }
steps() { [ -f "$1/log" ] && awk '{print $1}' "$1/log" | tr '\n' ' ' | sed 's/ $//'; }

# --- success ---
inst="$(fresh_instance preflight apply verify rollback)"
if deploy "$inst" staging v1.0.0; then ok "a full deployment succeeds"; else fail "a full deployment succeeds"; fi
if [ "$(steps "$inst")" = "preflight apply verify" ]; then ok "runs preflight, apply, verify in order"; else fail "runs preflight, apply, verify in order: $(steps "$inst")"; fi
if grep -qx 'apply staging v1.0.0 acme/api:v1.0.0 ' "$inst/log"; then ok "hooks receive the environment, version and image names"; else fail "hooks receive the environment, version and image names: $(cat "$inst/log")"; fi

# --- verify fails ---
inst="$(fresh_instance preflight apply verify:1 rollback)"
if deploy "$inst" staging v1.0.0; then fail "a failed verify fails the deployment"; else ok "a failed verify fails the deployment"; fi
if [ "$(steps "$inst")" = "preflight apply verify rollback" ]; then ok "a failed verify runs rollback"; else fail "a failed verify runs rollback: $(steps "$inst")"; fi
if grep -q '^rollback .* verify$' "$inst/log"; then ok "rollback receives the failed step"; else fail "rollback receives the failed step"; fi

# --- exit code 3 is a step's own result, never "not provided" ---
inst="$(fresh_instance apply:3 verify rollback)"
if deploy "$inst" staging v1.0.0; then fail "an apply exiting 3 fails the deployment"; else ok "an apply exiting 3 fails the deployment"; fi
if [ "$(steps "$inst")" = "apply rollback" ]; then ok "an apply exiting 3 runs rollback, not a skip"; else fail "an apply exiting 3 runs rollback, not a skip: $(steps "$inst")"; fi

inst="$(fresh_instance preflight apply verify:3 rollback)"
if deploy "$inst" staging v1.0.0; then fail "a verify exiting 3 fails the deployment"; else ok "a verify exiting 3 fails the deployment"; fi
if [ "$(steps "$inst")" = "preflight apply verify rollback" ]; then ok "a verify exiting 3 runs rollback, not a skip"; else fail "a verify exiting 3 runs rollback, not a skip: $(steps "$inst")"; fi

# --- apply fails ---
inst="$(fresh_instance apply:1 verify rollback)"
if deploy "$inst" staging v1.0.0; then fail "a failed apply fails the deployment"; else ok "a failed apply fails the deployment"; fi
if [ "$(steps "$inst")" = "apply rollback" ]; then ok "a failed apply skips verify and runs rollback"; else fail "a failed apply skips verify and runs rollback: $(steps "$inst")"; fi

# --- preflight fails ---
inst="$(fresh_instance preflight:1 apply rollback)"
if deploy "$inst" staging v1.0.0; then fail "a failed preflight fails the deployment"; else ok "a failed preflight fails the deployment"; fi
if [ "$(steps "$inst")" = "preflight" ]; then ok "a failed preflight changes nothing and does not roll back"; else fail "a failed preflight changes nothing and does not roll back: $(steps "$inst")"; fi

# --- optional hooks, and a hook without the executable bit ---
inst="$(fresh_instance apply)"
chmod -x "$inst/deploy/staging/hooks/apply.sh"
commit_all "$inst"
if deploy "$inst" staging v1.0.0 && [ "$(steps "$inst")" = "apply" ]; then ok "only apply is required, and it runs without the executable bit"; else fail "only apply is required, and it runs without the executable bit"; fi

inst="$(fresh_instance apply verify:1)"
if deploy "$inst" staging v1.0.0; then fail "a failed verify without a rollback hook still fails"; else ok "a failed verify without a rollback hook still fails"; fi

# --- refusals run no hook ---
expect_refused() {
  local label="$1" env="$2" version="$3" inst
  inst="$(fresh_instance preflight apply)"
  if [ "${4:-}" = "no-apply" ]; then rm "$inst/deploy/staging/hooks/apply.sh"; commit_all "$inst"; fi
  if deploy "$inst" "$env" "$version"; then fail "$label — it succeeded"
  elif [ -s "$inst/log" ]; then fail "$label — a hook ran"
  else ok "$label"; fi
}
expect_refused "refuses a missing environment" "" v1.0.0
expect_refused "refuses an environment not in instance.yaml" production v1.0.0
expect_refused "refuses a missing version" staging ""
expect_refused "refuses a VERSION that is not a release tag (v1)" staging v1
expect_refused "refuses a VERSION without the v (1.0.0)" staging 1.0.0
expect_refused "refuses a release candidate numbered 0 (v1.0.0-rc.0)" staging v1.0.0-rc.0
expect_refused "refuses a VERSION missing the patch number (v1.0)" staging v1.0
expect_refused "refuses when apply.sh is missing" staging v1.0.0 no-apply

# --- a release candidate is a valid VERSION ---
inst="$(fresh_instance preflight apply verify rollback)"
if deploy "$inst" staging v1.0.0-rc.1 && [ "$(steps "$inst")" = "preflight apply verify" ]; then
  ok "accepts VERSION=v1.0.0-rc.1"
else
  fail "accepts VERSION=v1.0.0-rc.1: $(cat "$inst/log" 2>/dev/null)"
fi

# --- an invalid instance.yaml is refused before any hook, naming the problem ---
# expect_invalid <label> <env> <instance.yaml body> <text the output must contain>
expect_invalid() {
  local label="$1" env="$2" body="$3" want="$4" inst out rc
  inst="$(fresh_instance preflight apply)"
  printf '%b' "$body" > "$inst/instance.yaml"
  if [ "$env" != staging ]; then
    mkdir -p "$inst/deploy/$env/hooks"
    cp "$inst/deploy/staging/hooks/"*.sh "$inst/deploy/$env/hooks/"
  fi
  out="$(deploy_out "$inst" "$env" v1.0.0)" && rc=0 || rc=$?
  if [ "$rc" -eq 0 ]; then
    fail "$label — it succeeded"
  elif [ -s "$inst/log" ]; then
    fail "$label — a hook ran"
  elif ! printf '%s' "$out" | grep -qF "$want"; then
    fail "$label — the output does not contain '$want': $out"
  else
    ok "$label"
  fi
}
base='name: acme\ndisplay_name: Acme\ncore: v0.0.2\n'
expect_invalid "a broken instance.yaml names the problem and runs no hook" staging \
  'name: acme\n  bad: [unterminated\n' 'instance.yaml is not valid'
expect_invalid "adapter d13 is refused by the generic adapter message, and runs no hook" staging \
  "${base}deploy:\n  staging: { adapter: d13 }\n" 'is not an adapter (want hook or host)'
expect_invalid "an environment named Prod is refused and runs no hook" Prod \
  "${base}deploy:\n  Prod: { adapter: hook }\n" 'environment "Prod" must match'
expect_invalid "an environment without its deploy/<env>/ directory elsewhere in instance.yaml is refused" staging \
  "${base}deploy:\n  staging: { adapter: hook }\n  qa: { adapter: hook }\n" 'deploy.qa: missing directory deploy/qa/'

# --- the version and the working tree ---
inst="$(fresh_instance apply)"
out="$(deploy_out "$inst" staging 1.0.0)" || true
if printf '%s' "$out" | grep -qF '^v[0-9]+\.[0-9]+\.[0-9]+(-rc\.[1-9][0-9]*)?$'; then ok "a bad VERSION is refused, naming the format"; else fail "a bad VERSION is refused, naming the format: $out"; fi

inst="$(fresh_instance apply)"
printf '# edited\n' >> "$inst/deploy/staging/hooks/apply.sh"
out="$(deploy_out "$inst" staging v1.0.0)" && rc=0 || rc=$?
if [ "$rc" -eq 0 ]; then fail "a dirty working tree is refused — it succeeded"
elif [ -s "$inst/log" ]; then fail "a dirty working tree is refused — a hook ran"
elif ! printf '%s' "$out" | grep -qF 'ALLOW_DIRTY=1'; then fail "a dirty working tree is refused, naming ALLOW_DIRTY=1: $out"
else ok "a dirty working tree is refused, naming ALLOW_DIRTY=1, and runs no hook"; fi

inst="$(fresh_instance apply)"
printf 'scratch\n' > "$inst/untracked.txt"
if deploy "$inst" staging v1.0.0; then fail "an untracked file makes the tree dirty"; else ok "an untracked file makes the tree dirty"; fi

inst="$(fresh_instance apply)"
printf '# edited\n' >> "$inst/deploy/staging/hooks/apply.sh"
if (cd "$inst" && ALLOW_DIRTY=1 bash scripts/deploy.sh staging v1.0.0) >/dev/null 2>&1 && [ "$(steps "$inst")" = "apply" ]; then
  ok "ALLOW_DIRTY=1 deploys from a dirty working tree"
else
  fail "ALLOW_DIRTY=1 deploys from a dirty working tree"
fi

inst="$(fresh_instance apply)"
out="$(deploy_out "$inst" staging v1.0.0)"
if printf '%s' "$out" | grep -q 'not from release'; then fail "no warning when HEAD is at the release tag: $out"; else ok "no warning when HEAD is at the release tag"; fi

inst="$(fresh_instance apply)"
sha="$(git -C "$inst" rev-parse --short HEAD)"
out="$(deploy_out "$inst" staging v1.0.1)" && rc=0 || rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qxF "deploy: hooks and configuration come from $sha, not from release v1.0.1"; then
  ok "warns, and still deploys, when the release tag is absent"
else
  fail "warns, and still deploys, when the release tag is absent (exit $rc): $out"
fi

inst="$(fresh_instance apply)"
commit_all "$inst"
sha="$(git -C "$inst" rev-parse --short HEAD)"
out="$(deploy_out "$inst" staging v1.0.0)" && rc=0 || rc=$?
if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -qxF "deploy: hooks and configuration come from $sha, not from release v1.0.0"; then
  ok "warns when HEAD has moved past the release tag"
else
  fail "warns when HEAD has moved past the release tag (exit $rc): $out"
fi

# --- `has` exiting other than 0 or 1 is an error, never "not provided" ---
# broken_has <inst> <step> <code> — the instance's copy of the hook adapter
# answers `has <step>` with <code>.
broken_has() {
  local f="$1/scripts/deploy/hook.sh" tmp
  tmp="$(mktemp "$TMP/hook.XXXXXX")"
  awk -v step="$2" -v code="$3" 'NR == 1 { print; print "[ \"${1:-}\" = has ] && [ \"${2:-}\" = " step " ] && { echo \"deploy/hook.sh: cannot read hooks\" >&2; exit " code "; }"; next } { print }' "$f" > "$tmp"
  cat "$tmp" > "$f"; rm -f "$tmp"
  commit_all "$1"
}
inst="$(fresh_instance preflight apply verify rollback)"
broken_has "$inst" verify 3
out="$(deploy_out "$inst" staging v1.0.0)" && rc=0 || rc=$?
if [ "$rc" -eq 0 ]; then fail "has exiting 3 stops the deployment — it succeeded"
elif ! printf '%s' "$out" | grep -qF "could not answer 'has verify' (exit 3)"; then fail "has exiting 3 stops the deployment with the adapter's message: $out"
elif ! printf '%s' "$out" | grep -qF 'cannot read hooks'; then fail "has exiting 3 shows the adapter's own message: $out"
elif printf '%s' "$out" | grep -q 'verify skipped'; then fail "has exiting 3 is not read as a skip: $out"
else ok "has exiting 3 stops the deployment with the adapter's message, not a skip"; fi

inst="$(fresh_instance preflight apply verify:1 rollback)"
broken_has "$inst" rollback 3
out="$(deploy_out "$inst" staging v1.0.0)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF "could not answer 'has rollback' (exit 3)" && ! printf '%s' "$out" | grep -q 'no rollback hook'; then
  ok "has rollback exiting 3 is reported as an adapter error, not as no rollback hook"
else
  fail "has rollback exiting 3 is reported as an adapter error (exit $rc): $out"
fi

if DEPLOY_DIR= bash "$SCRIPT_DIR/deploy/hook.sh" has apply 2>/dev/null; then rc=0; else rc=$?; fi
if [ "$rc" -eq 2 ]; then ok "hook.sh has exits 2, not 1, without DEPLOY_DIR"; else fail "hook.sh has exits 2, not 1, without DEPLOY_DIR — exit $rc"; fi

# --- make deploy: hooks do not inherit make's variables, and quoting holds ---
inst="$(fresh_instance)"
cp "$SCRIPT_DIR/../Makefile" "$inst/Makefile"
cat > "$inst/deploy/staging/hooks/apply.sh" <<EOF
#!/usr/bin/env bash
printf 'ENV=%s VERSION=%s MAKEFLAGS=%s MAKELEVEL=%s ALLOW_DIRTY=%s\n' "\${ENV-unset}" "\${VERSION-unset}" "\${MAKEFLAGS-unset}" "\${MAKELEVEL-unset}" "\${ALLOW_DIRTY-unset}" >> "$inst/log"
EOF
commit_all "$inst"
if (cd "$inst" && make -s deploy ENV=staging VERSION=v1.0.0) >/dev/null 2>&1 \
   && grep -qx 'ENV=unset VERSION=unset MAKEFLAGS=unset MAKELEVEL=unset ALLOW_DIRTY=' "$inst/log"; then
  ok "make deploy runs the hooks without ENV, VERSION or make's own variables"
else
  fail "make deploy runs the hooks without ENV, VERSION or make's own variables: $(cat "$inst/log" 2>/dev/null)"
fi
rm -f "$inst/log"
printf '# edited\n' >> "$inst/deploy/staging/hooks/apply.sh"
if (cd "$inst" && make -s deploy ENV=staging VERSION=v1.0.0 ALLOW_DIRTY=1) >/dev/null 2>&1 && [ -s "$inst/log" ]; then
  ok "make deploy passes ALLOW_DIRTY=1 through"
else
  fail "make deploy passes ALLOW_DIRTY=1 through"
fi
rm -f "$inst/log"
if (cd "$inst" && make -s deploy "ENV=staging'; touch pwned; '" VERSION=v1.0.0 ALLOW_DIRTY="1'; touch pwned2; '") >/dev/null 2>&1; then
  fail "make deploy refuses a quoted ENV — it succeeded"
elif [ -e "$inst/pwned" ] || [ -e "$inst/pwned2" ] || [ -s "$inst/log" ]; then
  fail "make deploy keeps a single quote in ENV or ALLOW_DIRTY as data"
else
  ok "make deploy keeps a single quote in ENV or ALLOW_DIRTY as data"
fi

if [ "$FAILURES" -gt 0 ]; then printf '\n%s case(s) failed\n' "$FAILURES" >&2; exit 1; fi
printf '\nall cases passed\n'
