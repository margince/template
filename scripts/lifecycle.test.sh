#!/usr/bin/env bash
# lifecycle.test.sh — the whole instance lifecycle, end to end.
#
# Creates an instance from this template in a scratch directory and walks it
# through what a client developer does: check it, add and test a unit,
# release it against a local bare "origin", deploy it through the hook
# adapter (a success and a rollback) and through the host adapter (through
# stubs), and merge a template change into it. Every step asserts its
# outcome. Trial is covered by trial.test.sh.
#
# Slow (it composes and tests a unit), so it is not part of `make test-scripts`.
# Needs the tools `make install` provides.
#
# Runs `make install` in the scratch instance, which installs core's gate
# tools into `$(go env GOPATH)/bin` and fills the Go module cache and the
# pnpm store — machine-wide caches, not scratch state. Only the scratch
# directory itself is removed afterwards.
#
# Usage: bash scripts/lifecycle.test.sh   (or: make test-lifecycle; KEEP=1 keeps the scratch directory)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# This is an instance, not the template: `make new-instance` refuses to run
# here ("this is an instance"), so the lifecycle it drives cannot either.
# lifecycle.yml is template-owned (.template-owned) and every instance
# inherits it unchanged, so this script skips itself instead of failing on
# every instance's CI.
if [ -e "$ROOT/.template-version" ]; then
  echo "lifecycle: skipped — this is an instance; the lifecycle test runs in margince-template"
  exit 0
fi

# git's repository location variables never reach this script when it is run
# directly, bypassing the Makefile's `unexport` (Makefile:11); inherited, they
# would make the scratch clones below act on this repository instead of
# their own.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_PREFIX

# The scratch commits below must not depend on the developer's own commit
# signing config — a signing key that needs a passphrase, or is simply absent,
# would hang or fail this test for a reason that has nothing to do with the
# lifecycle.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false

export GIT_AUTHOR_NAME="Lifecycle Test" GIT_AUTHOR_EMAIL="lifecycle@example.test"
export GIT_COMMITTER_NAME="Lifecycle Test" GIT_COMMITTER_EMAIL="lifecycle@example.test"

WORK="$(mktemp -d)"
DIR="$WORK/margince-lifecycle-demo"
cleanup() {
  if [ "${KEEP:-}" = "1" ]; then echo "lifecycle: kept $WORK"; else rm -rf "$WORK"; fi
}
trap cleanup EXIT

current=""
step() { current="$*"; printf '\n== lifecycle: %s\n' "$current"; }
fail() { printf '\nlifecycle: FAILED at "%s": %s\n' "$current" "$*" >&2; exit 1; }
trap 'printf "\nlifecycle: FAILED at \"%s\"\n" "$current" >&2' ERR

step "the template tree is clean"
[ -z "$(git -C "$ROOT" status --porcelain)" ] \
  || fail "make new-instance needs a clean template tree; commit or discard local changes first"

step "create an instance"
make -C "$ROOT" -s new-instance NAME=lifecycle-demo DISPLAY_NAME="Lifecycle Demo" DIR="$DIR"
cd "$DIR"

step "the new instance passes its checks"
make -s check-instance
make -s check-template

step "add a unit, compose it, and test it"
make -s install
make -s new-unit NAME=acme-sync
make -s compose
git add extensions/acme-sync
git commit -q -m "feat: add acme-sync"
make -s u NAME=acme-sync
make -s check-template

step "release v0.1.0"
git init -q --bare "$WORK/origin.git"
git remote add origin "$WORK/origin.git"
git push -q -u origin main
make -s release VERSION=v0.1.0 RELEASE_CHECK_TARGET=check-instance
git -C "$WORK/origin.git" tag -l | grep -qx v0.1.0 || fail "origin.git does not have tag v0.1.0"
if make -s release VERSION=v0.1.0 RELEASE_CHECK_TARGET=check-instance; then
  fail "a second release of v0.1.0 succeeded"
fi

step "deploy through the hook adapter"
mkdir -p deploy/staging/hooks
cat >> instance.yaml <<'EOF'
deploy:
  staging: { adapter: hook }
EOF
cat > deploy/staging/hooks/apply.sh <<'EOF'
#!/usr/bin/env bash
printf 'apply %s %s\n' "$DEPLOY_VERSION" "$IMAGE_API" >> "$DEPLOY_DIR/../deploy.log"
EOF
cat > deploy/staging/hooks/verify.sh <<'EOF'
#!/usr/bin/env bash
printf 'verify %s\n' "$DEPLOY_VERSION" >> "$DEPLOY_DIR/../deploy.log"
EOF
cat > deploy/staging/hooks/rollback.sh <<'EOF'
#!/usr/bin/env bash
printf 'rollback %s %s\n' "$DEPLOY_VERSION" "$DEPLOY_FAILED_STEP" >> "$DEPLOY_DIR/../deploy.log"
EOF
printf 'deploy.log\n' > deploy/.gitignore
git add instance.yaml deploy
git commit -q -m "feat: staging deployment"
make -s check-instance
make -s deploy ENV=staging VERSION=v0.1.0
grep -qx 'apply v0.1.0 lifecycle-demo/api:v0.1.0' deploy/deploy.log || fail "apply did not receive the image name: $(cat deploy/deploy.log)"
grep -qx 'verify v0.1.0' deploy/deploy.log || fail "verify did not run"

step "a failed verify rolls back"
printf '#!/usr/bin/env bash\nexit 1\n' > deploy/staging/hooks/verify.sh
git commit -q -am "test: verify fails"
git push -q origin main
make -s release VERSION=v0.1.1 RELEASE_CHECK_TARGET=check-instance
if make -s deploy ENV=staging VERSION=v0.1.1; then fail "a failed verify was reported as success"; fi
grep -qx 'rollback v0.1.1 verify' deploy/deploy.log || fail "rollback did not run: $(cat deploy/deploy.log)"

step "deploy through the host adapter"
mkdir -p deploy/prod/config
cat > deploy/prod/host.env <<'EOF'
HOST_SSH=test@server
HOST_DOMAIN=demo.example.test
EOF
cat > deploy/prod/config/margince.yaml <<'EOF'
version: 1
workspace:
  name: Lifecycle Demo
EOF
printf 'MARGINCE_LICENSE\n' > deploy/prod/secrets
printf '  prod: { adapter: host }\n' >> instance.yaml
git add instance.yaml deploy/prod
git commit -q -m "feat: host deployment"
make -s check-instance

# Stubs for ssh, scp, docker, curl and timeout: scripts/deploy/host/test-stubs
# is template-owned, so the scratch instance already has its own copy. First
# on PATH, so nothing real is contacted (design Section 12; task-7-report.md
# Section 6).
STUB_STATE="$WORK/host-stub-state"
STUB_SERVER_ROOT="$WORK/host-stub-server"
mkdir -p "$STUB_STATE" "$STUB_SERVER_ROOT"
export STUB_STATE STUB_SERVER_ROOT
export PATH="$DIR/scripts/deploy/host/test-stubs:$PATH"
MARGINCE_LICENSE=test HOST_KNOWN_HOSTS='server ssh-ed25519 AAAA' make -s deploy ENV=prod VERSION=v0.1.0
SRV_HD="$STUB_SERVER_ROOT/opt/margince/lifecycle-demo"
[ -d "$SRV_HD/releases/v0.1.0" ] || fail "the scratch server does not have releases/v0.1.0"
[ "$(readlink "$SRV_HD/current")" = "releases/v0.1.0" ] || fail "current does not point to releases/v0.1.0: '$(readlink "$SRV_HD/current" 2>/dev/null)'"

step "merge a template change"
TPL="$WORK/template"
git -c advice.detachedHead=false clone -q "$ROOT" "$TPL"
# $ROOT's HEAD may not be a branch at all — CI checks out a detached PR merge
# commit — in which case the clone has no local branch, and template-sync's
# default TEMPLATE_BRANCH=main has nothing to fetch. Give the scratch clone a
# branch of its own and sync from exactly that, regardless of what $ROOT's
# HEAD is.
git -C "$TPL" checkout -q -B lifecycle-template
printf '\nLifecycle test note.\n' >> "$TPL/docs/README.md"
git -C "$TPL" commit -q -am "docs: lifecycle test change"
git remote set-url template "$TPL"
export TEMPLATE_BRANCH=lifecycle-template
make -s template-sync
[ "$(tr -d '[:space:]' < .template-version)" = "$(git -C "$TPL" rev-parse HEAD)" ] || fail ".template-version does not record the merged template commit"
grep -q 'Lifecycle test note.' docs/README.md || fail "the template change did not arrive"
make -s check-template
make -s check-instance

trap - ERR
printf '\nlifecycle: all steps passed\n'
