#!/usr/bin/env bash
# lifecycle.test.sh — the whole instance lifecycle, end to end.
#
# Creates an instance from this template in a scratch directory and walks it
# through what a client developer does: check it, add and test a unit, deploy
# it through the hook adapter (a success and a rollback), and merge a template
# change into it. Every step asserts its outcome. Trial and release steps are
# added when those lanes exist (issues T8, T7).
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
git tag v0.1.0
make -s check-instance
make -s deploy ENV=staging VERSION=v0.1.0
grep -qx 'apply v0.1.0 lifecycle-demo/api:v0.1.0' deploy/deploy.log || fail "apply did not receive the image name: $(cat deploy/deploy.log)"
grep -qx 'verify v0.1.0' deploy/deploy.log || fail "verify did not run"

step "a failed verify rolls back"
printf '#!/usr/bin/env bash\nexit 1\n' > deploy/staging/hooks/verify.sh
git commit -q -am "test: verify fails"
git tag v0.1.1
if make -s deploy ENV=staging VERSION=v0.1.1; then fail "a failed verify was reported as success"; fi
grep -qx 'rollback v0.1.1 verify' deploy/deploy.log || fail "rollback did not run: $(cat deploy/deploy.log)"

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
