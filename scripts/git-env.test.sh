#!/usr/bin/env bash
# git-env.test.sh — the gates never inherit git's repository location variables.
#
# git sets GIT_DIR (and sometimes GIT_WORK_TREE and GIT_INDEX_FILE) when it runs
# a hook from a linked worktree. The script suites build throwaway repositories
# with `git init` and `git -C <dir>`; with GIT_DIR inherited, those commands act
# on the REAL repository instead: they commit to the current branch and rewrite
# its config (core.bare=true). The pre-push hook and every make recipe must
# therefore run without these variables.
#
# Usage: bash scripts/git-env.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILURES=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }
ok()   { printf 'ok: %s\n' "$*"; }

GIT_VARS='GIT_DIR|GIT_WORK_TREE|GIT_INDEX_FILE|GIT_OBJECT_DIRECTORY|GIT_ALTERNATE_OBJECT_DIRECTORIES|GIT_COMMON_DIR'

# --- the pre-push hook ---
#
# A stand-in `make` records the git variables it sees, then succeeds, so the
# hook's gates do not run for real.
mkdir -p "$TMP/bin"
cat > "$TMP/bin/make" <<EOF
#!/usr/bin/env bash
env | grep -E '^($GIT_VARS)=' >> "$TMP/seen" || true
exit 0
EOF
chmod +x "$TMP/bin/make"
: > "$TMP/seen"

git_dir="$(git -C "$ROOT" rev-parse --absolute-git-dir)"
if (cd "$ROOT" && PATH="$TMP/bin:$PATH" GIT_DIR="$git_dir" GIT_WORK_TREE="$ROOT" GIT_INDEX_FILE="$git_dir/index" \
      bash .githooks/pre-push </dev/null >/dev/null 2>&1); then
  ok "the pre-push hook runs with git's variables set"
else
  fail "the pre-push hook runs with git's variables set"
fi
if [ -s "$TMP/seen" ]; then
  fail "the pre-push hook passes git's variables to make: $(tr '\n' ' ' < "$TMP/seen")"
else
  ok "the pre-push hook clears git's variables before make"
fi

# --- make recipes ---
#
# A probe target read after the Makefile prints what a recipe sees.
printf 'git-env-probe:\n\t@env | grep -E %s || true\n' "'^($GIT_VARS)='" > "$TMP/probe.mk"
seen="$(cd "$ROOT" && GIT_DIR=/nonexistent GIT_WORK_TREE=/nonexistent GIT_INDEX_FILE=/nonexistent \
          make -s -f Makefile -f "$TMP/probe.mk" git-env-probe 2>/dev/null || true)"
if [ -z "$seen" ]; then
  ok "make recipes do not inherit git's variables"
else
  fail "make recipes inherit git's variables: $(printf '%s' "$seen" | tr '\n' ' ')"
fi

if [ "$FAILURES" -gt 0 ]; then printf '\n%s case(s) failed\n' "$FAILURES" >&2; exit 1; fi
printf '\nall cases passed\n'
