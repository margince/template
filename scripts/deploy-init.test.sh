#!/usr/bin/env bash
# deploy-init.test.sh — make deploy-init scaffolds a deploy environment and
# registers it in instance.yaml (design Sections 9.6, 9.7).
#
# Each case builds a throwaway instance: this repository's scripts/, a
# throwaway core/ checked out at a release tag (so cli check can verify it,
# exactly like new-instance.test.sh's core), and an instance.yaml.
#
# Usage: bash scripts/deploy-init.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR
export GIT_AUTHOR_NAME="Test Dev"     GIT_AUTHOR_EMAIL="dev@example.test"
export GIT_COMMITTER_NAME="Test Dev"  GIT_COMMITTER_EMAIL="dev@example.test"
export GIT_CONFIG_NOSYSTEM=1

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILURES=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }
ok()   { printf 'ok: %s\n' "$*"; }

git_q() { git -C "$1" -c commit.gpgsign=false -c tag.gpgsign=false "${@:2}" >/dev/null; }

# fresh_instance [core-tag] — a throwaway instance directory: this
# repository's scripts/, a real (non-submodule) core/ checkout tagged
# v0.0.2 (or the given tag), and instance.yaml naming that tag.
fresh_instance() {
  local core_tag="${1:-v0.0.2}" inst
  inst="$(mktemp -d "$TMP/inst.XXXXXX")"
  cp -R "$SCRIPT_DIR" "$inst/scripts"
  mkdir -p "$inst/core"
  git_q "$inst/core" init -q
  printf 'go 1.26.6\n' > "$inst/core/go.work"
  git_q "$inst/core" add -A
  git_q "$inst/core" commit -q -m core
  git_q "$inst/core" tag "$core_tag"
  printf 'name: acme\ndisplay_name: Acme\ncore: v0.0.2\n' > "$inst/instance.yaml"
  printf '%s' "$inst"
}

deploy_init() {
  local inst="$1"; shift
  (cd "$inst" && env "$@" bash scripts/deploy-init.sh)
}
deploy_init_out() {
  local inst="$1"; shift
  (cd "$inst" && env "$@" bash scripts/deploy-init.sh) 2>&1
}
cli_check() {
  (cd "$1/scripts/cli" && GOWORK=off go run . check -file "$1/instance.yaml" -core "$1/core" >/dev/null 2>&1)
}

# --- refuses a missing or malformed ENV, and creates nothing ---
expect_env_refused() {
  local label="$1" env_val="$2" inst
  inst="$(fresh_instance)"
  if [ -n "$env_val" ]; then
    if deploy_init "$inst" ENV="$env_val" DOMAIN=crm.example.test SSH=deploy@203.0.113.10 >/dev/null 2>&1; then
      fail "$label — it succeeded"
      return
    fi
  else
    if deploy_init "$inst" DOMAIN=crm.example.test SSH=deploy@203.0.113.10 >/dev/null 2>&1; then
      fail "$label — it succeeded"
      return
    fi
  fi
  if [ -e "$inst/deploy" ]; then fail "$label — it created deploy/"; return; fi
  if ! diff -q "$inst/instance.yaml" <(printf 'name: acme\ndisplay_name: Acme\ncore: v0.0.2\n') >/dev/null; then
    fail "$label — it changed instance.yaml"; return
  fi
  ok "$label"
}
expect_env_refused "refuses a missing ENV" ""
expect_env_refused "refuses an uppercase ENV" "Prod"
expect_env_refused "refuses an ENV with an underscore" "pro_d"
expect_env_refused "refuses an ENV starting with a dash" "-prod"

# --- refuses an unknown ADAPTER ---
inst="$(fresh_instance)"
if deploy_init "$inst" ENV=staging ADAPTER=ftp >/dev/null 2>&1; then
  fail "refuses an unknown ADAPTER — it succeeded"
elif [ -e "$inst/deploy" ]; then
  fail "refuses an unknown ADAPTER — it created deploy/"
else
  ok "refuses an unknown ADAPTER"
fi

# --- host: DOMAIN, SSH and ADMIN_EMAIL are all optional (design Section 9.8) ---
# Missing DOMAIN and SSH: empty host.env values, each with a comment above it
# saying what to enter; the admin email falls back to the general placeholder
# admin@example.com (there is no DOMAIN to build admin@<DOMAIN> from), with a
# comment to change it; the next steps start by naming the two files to fill in.
inst_ph="$(fresh_instance)"
out_ph="$(deploy_init_out "$inst_ph" ENV=production)"
dir_ph="$inst_ph/deploy/production"
if [ -f "$dir_ph/host.env" ] && [ -f "$dir_ph/secrets" ] && [ -f "$dir_ph/config/margince.yaml" ]; then
  ok "the host adapter accepts a missing DOMAIN and SSH"
else
  fail "the host adapter accepts a missing DOMAIN and SSH: $out_ph"
fi
if grep -qx 'HOST_SSH=' "$dir_ph/host.env" && grep -qx 'HOST_DOMAIN=' "$dir_ph/host.env"; then
  ok "host.env has HOST_SSH= and HOST_DOMAIN= empty when not given"
else
  fail "host.env has HOST_SSH= and HOST_DOMAIN= empty when not given: $(cat "$dir_ph/host.env")"
fi
ssh_comment_line="$(grep -B1 -x 'HOST_SSH=' "$dir_ph/host.env" | head -1)"
domain_comment_line="$(grep -B1 -x 'HOST_DOMAIN=' "$dir_ph/host.env" | head -1)"
case "$ssh_comment_line" in
  '#'*) case "$domain_comment_line" in
    '#'*) ok "a comment line above each empty host.env value says what to enter" ;;
    *) fail "a comment line above HOST_DOMAIN= says what to enter: $(cat "$dir_ph/host.env")" ;;
  esac ;;
  *) fail "a comment line above HOST_SSH= says what to enter: $(cat "$dir_ph/host.env")" ;;
esac
if grep -qF 'email: "admin@example.com"' "$dir_ph/config/margince.yaml"; then
  ok "the admin email defaults to the placeholder admin@example.com when DOMAIN is missing"
else
  fail "the admin email defaults to the placeholder admin@example.com when DOMAIN is missing: $(cat "$dir_ph/config/margince.yaml")"
fi
if grep -F 'email: "admin@example.com"' "$dir_ph/config/margince.yaml" | grep -qiF 'change'; then
  ok "the placeholder admin email has a comment to change it"
else
  fail "the placeholder admin email has a comment to change it: $(cat "$dir_ph/config/margince.yaml")"
fi
if printf '%s' "$out_ph" | grep -qxF "  fill in deploy/production/host.env and the admin email in deploy/production/config/margince.yaml"; then
  ok "next steps start with filling in host.env and the admin email"
else
  fail "next steps start with filling in host.env and the admin email: $out_ph"
fi
if cli_check "$inst_ph"; then ok "instance.yaml with placeholder deploy/production passes cli check"; else fail "instance.yaml with placeholder deploy/production passes cli check"; fi

# DOMAIN given without SSH: HOST_DOMAIN is set as before, HOST_SSH is the
# empty placeholder, and the admin email still defaults to admin@<DOMAIN> (not
# the general placeholder) — this is a "given value", not a missing one.
inst_partial="$(fresh_instance)"
deploy_init "$inst_partial" ENV=production DOMAIN=crm.example.test >/dev/null
dir_partial="$inst_partial/deploy/production"
if grep -qx 'HOST_DOMAIN=crm.example.test' "$dir_partial/host.env" && grep -qx 'HOST_SSH=' "$dir_partial/host.env"; then
  ok "DOMAIN given without SSH: HOST_DOMAIN is set, HOST_SSH is the empty placeholder"
else
  fail "DOMAIN given without SSH: $(cat "$dir_partial/host.env")"
fi
if grep -qF 'email: "admin@crm.example.test"' "$dir_partial/config/margince.yaml"; then
  ok "DOMAIN given without SSH: the admin email still defaults to admin@<DOMAIN>, not the general placeholder"
else
  fail "DOMAIN given without SSH: the admin email still defaults to admin@<DOMAIN>: $(cat "$dir_partial/config/margince.yaml")"
fi

# --- host scaffold: files and contents ---
inst="$(fresh_instance)"
out="$(deploy_init_out "$inst" ENV=production DOMAIN=crm.example.test SSH=deploy@203.0.113.10)"
dir="$inst/deploy/production"
if [ -f "$dir/host.env" ] && [ -f "$dir/secrets" ] && [ -f "$dir/config/margince.yaml" ] && [ ! -e "$dir/hooks" ]; then
  ok "the host adapter writes host.env, secrets and config/margince.yaml"
else
  fail "the host adapter writes host.env, secrets and config/margince.yaml: $(ls -la "$dir" 2>&1)"
fi
if grep -qx 'HOST_SSH=deploy@203.0.113.10' "$dir/host.env" && grep -qx 'HOST_DOMAIN=crm.example.test' "$dir/host.env"; then
  ok "host.env holds HOST_SSH and HOST_DOMAIN"
else
  fail "host.env holds HOST_SSH and HOST_DOMAIN: $(cat "$dir/host.env")"
fi
if [ "$(grep -c '^#' "$dir/host.env")" = 2 ]; then
  ok "given DOMAIN and SSH: host.env has only its original two header comments, no fill-in comments"
else
  fail "given DOMAIN and SSH: host.env has only its original two header comments: $(cat "$dir/host.env")"
fi
if printf '%s' "$out" | grep -qF 'fill in deploy/'; then
  fail "given DOMAIN and SSH: the next steps do not mention filling in host.env: $out"
else
  ok "given DOMAIN and SSH: the next steps do not mention filling in host.env"
fi
if grep -qx 'MARGINCE_LICENSE' "$dir/secrets"; then
  ok "secrets lists MARGINCE_LICENSE"
else
  fail "secrets lists MARGINCE_LICENSE: $(cat "$dir/secrets")"
fi
if grep -qF 'MARGINCE_KEYVAULT_ROOT_KEY' "$dir/secrets" \
  && grep -qF 'MARGINCE_CONNECTOR_STATE_KEY' "$dir/secrets" \
  && grep -qF 'MARGINCE_WEBHOOK_KEY' "$dir/secrets" \
  && grep -qiF 'admin password' "$dir/secrets" \
  && grep -qF 'shared/instance.env' "$dir/secrets"; then
  ok "secrets explains the generated keys and the admin password (shared/instance.env)"
else
  fail "secrets explains the generated keys and the admin password: $(cat "$dir/secrets")"
fi
if grep -qiF 'overrides the generated' "$dir/secrets"; then
  ok "secrets explains that listing a generated name here overrides it"
else
  fail "secrets explains that listing a generated name here overrides it: $(cat "$dir/secrets")"
fi
if grep -qiF 'must never change' "$dir/secrets" && grep -qF 'MARGINCE_KEYVAULT_ROOT_KEY' "$dir/secrets"; then
  ok "secrets warns the vault key must never change once data is sealed"
else
  fail "secrets warns the vault key must never change once data is sealed: $(cat "$dir/secrets")"
fi
if grep -qF 'MARGINCE_ENV' "$dir/secrets" && grep -qiF 'test' "$dir/secrets" && grep -qiF 'MARGINCE_LICENSE' "$dir/secrets"; then
  ok "secrets explains MARGINCE_ENV=test for a test environment"
else
  fail "secrets explains MARGINCE_ENV=test for a test environment: $(cat "$dir/secrets")"
fi
if grep -qx 'version: 1' "$dir/config/margince.yaml"; then ok "margince.yaml has version: 1"; else fail "margince.yaml has version: 1: $(cat "$dir/config/margince.yaml")"; fi
if grep -qF 'name: "Acme"' "$dir/config/margince.yaml"; then ok "margince.yaml's workspace name is the instance display_name"; else fail "margince.yaml's workspace name is the instance display_name: $(cat "$dir/config/margince.yaml")"; fi
if grep -qF 'base_currency: EUR' "$dir/config/margince.yaml" && grep -qF 'timezone: UTC' "$dir/config/margince.yaml"; then
  ok "margince.yaml sets base_currency: EUR and timezone: UTC"
else
  fail "margince.yaml sets base_currency: EUR and timezone: UTC: $(cat "$dir/config/margince.yaml")"
fi
if grep -qF 'email: "admin@crm.example.test"' "$dir/config/margince.yaml"; then
  ok "margince.yaml defaults bootstrap_admin.email to admin@<DOMAIN>"
else
  fail "margince.yaml defaults bootstrap_admin.email to admin@<DOMAIN>: $(cat "$dir/config/margince.yaml")"
fi
if grep -qF 'display_name: Admin' "$dir/config/margince.yaml" && grep -qF 'password_file: secrets/admin-password' "$dir/config/margince.yaml"; then
  ok "margince.yaml's bootstrap_admin has display_name: Admin and password_file: secrets/admin-password"
else
  fail "margince.yaml's bootstrap_admin has display_name: Admin and password_file: secrets/admin-password: $(cat "$dir/config/margince.yaml")"
fi
if grep -qF 'connector_enabled: false' "$dir/config/margince.yaml"; then
  ok "margince.yaml sets mcp.connector_enabled: false"
else
  fail "margince.yaml sets mcp.connector_enabled: false: $(cat "$dir/config/margince.yaml")"
fi
if grep -qF 'enabled: false' "$dir/config/margince.yaml" && grep -q '^email:' "$dir/config/margince.yaml"; then
  ok "margince.yaml's email block is disabled"
else
  fail "margince.yaml's email block is disabled: $(cat "$dir/config/margince.yaml")"
fi
if grep -qF '#   smtp:' "$dir/config/margince.yaml" || grep -qF '# smtp:' "$dir/config/margince.yaml"; then
  ok "margince.yaml comments out the SMTP fields"
else
  fail "margince.yaml comments out the SMTP fields: $(cat "$dir/config/margince.yaml")"
fi
top_keys="$(grep -oE '^[a-zA-Z_]+:' "$dir/config/margince.yaml" | tr -d ':' | sort -u | tr '\n' ' ')"
if [ "$top_keys" = "bootstrap_admin email mcp version workspace " ]; then
  ok "margince.yaml's top-level keys are exactly the schema's (version, workspace, bootstrap_admin, mcp, email)"
else
  fail "margince.yaml's top-level keys are exactly the schema's: $top_keys"
fi
# The grep-based checks above are the real assertions. This is an extra,
# best-effort structural check on top of them: pyyaml is not provided by
# `make install` or CI (only the Go toolchain and the stdlib tools this
# repository's own scripts need are), so its absence is a skip, not a
# failure — same pattern as scripts/desktop-kit.test.sh's python3 guard.
yaml_err="$TMP/deploy-init-yaml-err"
if ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import yaml' >/dev/null 2>&1; then
  ok "margince.yaml YAML-structure check: skipped (no pyyaml)"
elif python3 -c "
import sys, yaml
with open('$dir/config/margince.yaml') as f:
    doc = yaml.safe_load(f)
assert doc['version'] == 1
assert doc['workspace']['name'] == 'Acme'
assert doc['workspace']['base_currency'] == 'EUR'
assert doc['workspace']['timezone'] == 'UTC'
assert doc['bootstrap_admin']['email'] == 'admin@crm.example.test'
assert doc['bootstrap_admin']['display_name'] == 'Admin'
assert doc['bootstrap_admin']['password_file'] == 'secrets/admin-password'
assert doc['mcp']['connector_enabled'] is False
assert doc['email']['enabled'] is False
assert set(doc.keys()) <= {'version', 'workspace', 'bootstrap_admin', 'mcp', 'email'}
" 2>"$yaml_err"; then
  ok "margince.yaml parses as YAML with the exact expected structure"
else
  fail "margince.yaml parses as YAML with the exact expected structure: $(cat "$yaml_err")"
fi
rm -f "$yaml_err"

# --- ADMIN_EMAIL overrides the default ---
inst2="$(fresh_instance)"
deploy_init "$inst2" ENV=production DOMAIN=crm.example.test SSH=deploy@203.0.113.10 ADMIN_EMAIL=ops@acme.test >/dev/null
if grep -qF 'email: "ops@acme.test"' "$inst2/deploy/production/config/margince.yaml"; then
  ok "ADMIN_EMAIL overrides the default admin@<DOMAIN>"
else
  fail "ADMIN_EMAIL overrides the default admin@<DOMAIN>: $(cat "$inst2/deploy/production/config/margince.yaml")"
fi

# --- registers the environment in instance.yaml, keeping other lines ---
if grep -qx 'name: acme' "$inst/instance.yaml" && grep -qx 'display_name: Acme' "$inst/instance.yaml" && grep -qx 'core: v0.0.2' "$inst/instance.yaml"; then
  ok "instance.yaml keeps its other lines"
else
  fail "instance.yaml keeps its other lines: $(cat "$inst/instance.yaml")"
fi
if grep -qx 'deploy:' "$inst/instance.yaml" && grep -qxF '  production: { adapter: host }' "$inst/instance.yaml"; then
  ok "instance.yaml adds deploy: production: { adapter: host }"
else
  fail "instance.yaml adds deploy: production: { adapter: host }: $(cat "$inst/instance.yaml")"
fi
if cli_check "$inst"; then ok "instance.yaml passes cli check after deploy-init"; else fail "instance.yaml passes cli check after deploy-init"; fi

# --- adding a second environment appends under the existing deploy: block ---
deploy_init "$inst" ENV=staging ADAPTER=hook >/dev/null
if grep -qxF '  production: { adapter: host }' "$inst/instance.yaml" && grep -qxF '  staging: { adapter: hook }' "$inst/instance.yaml" \
  && [ "$(grep -cx 'deploy:' "$inst/instance.yaml")" = 1 ]; then
  ok "a second deploy-init adds under the same deploy: block, once"
else
  fail "a second deploy-init adds under the same deploy: block, once: $(cat "$inst/instance.yaml")"
fi
if cli_check "$inst"; then ok "instance.yaml still passes cli check with two environments"; else fail "instance.yaml still passes cli check with two environments"; fi

# --- a `deploy:` line with a trailing comment is still recognized as the key ---
inst_comment="$(fresh_instance)"
printf 'name: acme\ndisplay_name: Acme\ncore: v0.0.2\ndeploy: # environments\n  existing: { adapter: hook }\n' > "$inst_comment/instance.yaml"
mkdir -p "$inst_comment/deploy/existing/hooks"
: > "$inst_comment/deploy/existing/hooks/apply.sh"
deploy_init "$inst_comment" ENV=production DOMAIN=crm.example.test SSH=deploy@203.0.113.10 >/dev/null
if [ "$(grep -cE '^deploy:' "$inst_comment/instance.yaml")" = 1 ] \
  && grep -qxF 'deploy: # environments' "$inst_comment/instance.yaml" \
  && grep -qxF '  existing: { adapter: hook }' "$inst_comment/instance.yaml" \
  && grep -qxF '  production: { adapter: host }' "$inst_comment/instance.yaml"; then
  ok "a deploy: line with a trailing comment is recognized, not duplicated"
else
  fail "a deploy: line with a trailing comment is recognized, not duplicated: $(cat "$inst_comment/instance.yaml")"
fi
if cli_check "$inst_comment"; then ok "instance.yaml with a commented deploy: line still passes cli check"; else fail "instance.yaml with a commented deploy: line still passes cli check"; fi

# --- default ADAPTER is host ---
inst3="$(fresh_instance)"
deploy_init "$inst3" ENV=production DOMAIN=crm.example.test SSH=deploy@203.0.113.10 >/dev/null
if grep -qxF '  production: { adapter: host }' "$inst3/instance.yaml"; then
  ok "ADAPTER defaults to host"
else
  fail "ADAPTER defaults to host: $(cat "$inst3/instance.yaml")"
fi

# --- hook scaffold ---
inst4="$(fresh_instance)"
out="$(deploy_init_out "$inst4" ENV=staging ADAPTER=hook)"
dir4="$inst4/deploy/staging"
if [ -f "$dir4/hooks/apply.sh" ] && [ ! -e "$dir4/host.env" ] && [ ! -e "$dir4/secrets" ] && [ ! -e "$dir4/config" ]; then
  ok "the hook adapter writes only hooks/apply.sh"
else
  fail "the hook adapter writes only hooks/apply.sh: $(find "$dir4" 2>&1)"
fi
for v in DEPLOY_ENV DEPLOY_VERSION DEPLOY_STEP DEPLOY_DIR DEPLOY_STATE_DIR INSTANCE_NAME IMAGE_REPO IMAGE_API IMAGE_WEB IMAGE_WORKER; do
  grep -qF "$v" "$dir4/hooks/apply.sh" || fail "hooks/apply.sh's comment lists $v: $(cat "$dir4/hooks/apply.sh")"
done
ok "hooks/apply.sh's comment lists the exported variables"
if grep -qx 'deploy:' "$inst4/instance.yaml" && grep -qxF '  staging: { adapter: hook }' "$inst4/instance.yaml"; then
  ok "instance.yaml registers the hook environment"
else
  fail "instance.yaml registers the hook environment: $(cat "$inst4/instance.yaml")"
fi
if cli_check "$inst4"; then ok "the hook instance.yaml passes cli check"; else fail "the hook instance.yaml passes cli check"; fi
if [ -x "$dir4/hooks/apply.sh" ]; then ok "hooks/apply.sh is executable"; else fail "hooks/apply.sh is executable"; fi

# --- refuses an existing deploy/<env>/ directory, and changes nothing ---
inst5="$(fresh_instance)"
mkdir -p "$inst5/deploy/production"
printf 'marker\n' > "$inst5/deploy/production/marker"
before="$(cat "$inst5/instance.yaml")"
if deploy_init "$inst5" ENV=production DOMAIN=crm.example.test SSH=deploy@203.0.113.10 >/dev/null 2>&1; then
  fail "refuses an existing deploy/<env>/ directory — it succeeded"
elif [ ! -f "$inst5/deploy/production/marker" ]; then
  fail "refuses an existing deploy/<env>/ directory — it touched the existing directory"
elif [ "$(cat "$inst5/instance.yaml")" != "$before" ]; then
  fail "refuses an existing deploy/<env>/ directory — it changed instance.yaml"
else
  ok "refuses an existing deploy/<env>/ directory, and changes nothing"
fi

# --- refuses an existing deploy.<env> key in instance.yaml, and changes nothing ---
inst6="$(fresh_instance)"
printf 'deploy:\n  production: { adapter: host }\n' >> "$inst6/instance.yaml"
before="$(cat "$inst6/instance.yaml")"
if deploy_init "$inst6" ENV=production DOMAIN=crm.example.test SSH=deploy@203.0.113.10 >/dev/null 2>&1; then
  fail "refuses an existing deploy.<env> key — it succeeded"
elif [ -e "$inst6/deploy/production" ]; then
  fail "refuses an existing deploy.<env> key — it created deploy/production/"
elif [ "$(cat "$inst6/instance.yaml")" != "$before" ]; then
  fail "refuses an existing deploy.<env> key — it changed instance.yaml"
else
  ok "refuses an existing deploy.<env> key, and changes nothing"
fi

# --- an instance.yaml that is invalid regardless of this edit is refused, and restored ---
inst7="$(fresh_instance)"
printf 'name: acme\ndisplay_name: Acme\ncore: v9.9.9\n' > "$inst7/instance.yaml"
before="$(cat "$inst7/instance.yaml")"
out="$(deploy_init_out "$inst7" ENV=production DOMAIN=crm.example.test SSH=deploy@203.0.113.10)" && rc=0 || rc=$?
if [ "$rc" -eq 0 ]; then
  fail "refuses when the resulting instance.yaml is invalid — it succeeded"
elif [ -e "$inst7/deploy/production" ]; then
  fail "refuses when the resulting instance.yaml is invalid — it left deploy/production/ behind"
elif [ "$(cat "$inst7/instance.yaml")" != "$before" ]; then
  fail "refuses when the resulting instance.yaml is invalid — it did not restore instance.yaml"
elif ! printf '%s' "$out" | grep -qiF 'core'; then
  fail "refuses when the resulting instance.yaml is invalid, naming the problem: $out"
else
  ok "refuses when the resulting instance.yaml is invalid, restoring it and removing what this run created"
fi

# --- prints the next steps ---
inst8="$(fresh_instance)"
out="$(deploy_init_out "$inst8" ENV=production DOMAIN=crm.example.test SSH=deploy@203.0.113.10)"
if printf '%s' "$out" | grep -qF 'MARGINCE_LICENSE' \
  && printf '%s' "$out" | grep -qF 'make host-bootstrap ENV=production' \
  && printf '%s' "$out" | grep -qF 'make deploy ENV=production VERSION='; then
  ok "prints the next steps: MARGINCE_LICENSE, host-bootstrap, deploy"
else
  fail "prints the next steps: MARGINCE_LICENSE, host-bootstrap, deploy: $out"
fi

inst9="$(fresh_instance)"
out="$(deploy_init_out "$inst9" ENV=staging ADAPTER=hook)"
if printf '%s' "$out" | grep -qF 'make deploy ENV=staging VERSION='; then
  ok "the hook adapter's next steps mention make deploy"
else
  fail "the hook adapter's next steps mention make deploy: $out"
fi

if [ "$FAILURES" -gt 0 ]; then printf '\n%s case(s) failed\n' "$FAILURES" >&2; exit 1; fi
printf '\nall cases passed\n'
