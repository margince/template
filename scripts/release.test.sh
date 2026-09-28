#!/usr/bin/env bash
# release.test.sh — scripts/release.sh: check every precondition (design
# Section 9.2), tag and push, before anything reaches make check-instance.
#
# Each case builds a throwaway "origin" (a scratch bare repository) and a
# clone holding scripts/lib.sh, scripts/release.sh, the CLI directory and a
# Makefile whose check and check-instance targets append their own name to a
# log and fail when a file FAIL_CHECK exists. lib.sh derives ROOT from its own
# location, so this is everything release.sh needs to run.
#
# Usage: bash scripts/release.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Hermetic against the developer's git config and a git hook's environment.
# release.sh runs `git tag -a` and `git push` directly (not through a
# wrapper), so signing is disabled through the environment rather than a
# per-command -c flag, the way lifecycle.test.sh does it.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_PREFIX
export GIT_CONFIG_COUNT=2 \
  GIT_CONFIG_KEY_0=commit.gpgsign   GIT_CONFIG_VALUE_0=false \
  GIT_CONFIG_KEY_1=tag.gpgsign      GIT_CONFIG_VALUE_1=false
export GIT_AUTHOR_NAME="Test Dev"     GIT_AUTHOR_EMAIL="dev@example.test"
export GIT_COMMITTER_NAME="Test Dev"  GIT_COMMITTER_EMAIL="dev@example.test"
export GIT_CONFIG_NOSYSTEM=1

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILURES=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }
ok()   { printf 'ok: %s\n' "$*"; }

git_q() { git -C "$1" "${@:2}" >/dev/null; }

# commit_all <repo> — commit every change, so the working tree is clean again.
commit_all() { git_q "$1" add -A && git_q "$1" commit -q --allow-empty -m change; }

# bare_of <work> — the paired scratch "origin" for a work dir fresh_repo made.
bare_of() { printf '%s/origin.git\n' "$(dirname "$1")"; }

# fresh_repo — a bare "origin" and a clone with scripts/lib.sh,
# scripts/release.sh, scripts/cli/ and a Makefile whose check and
# check-instance targets each append their own name to ./log and fail when
# ./FAIL_CHECK exists. main is committed and pushed to origin.
fresh_repo() {
  local base bare work
  base="$(mktemp -d "$TMP/repo.XXXXXX")"
  bare="$base/origin.git"
  work="$base/work"
  git init -q --bare "$bare" >/dev/null
  mkdir -p "$work/scripts"
  cp "$SCRIPT_DIR/lib.sh" "$work/scripts/lib.sh"
  cp "$SCRIPT_DIR/release.sh" "$work/scripts/release.sh"
  cp -R "$SCRIPT_DIR/cli" "$work/scripts/cli"
  printf '/log\n/FAIL_CHECK\n' > "$work/.gitignore"
  # Written with printf, one line at a time, rather than a heredoc: a
  # Makefile recipe line must start with a literal tab, and a heredoc
  # embedded in this script's own indentation makes that byte easy to lose
  # or duplicate by accident.
  {
    printf '.PHONY: check check-instance\n\n'
    printf 'check:\n'
    printf '\t@echo check >> log\n'
    printf '\t@[ ! -f FAIL_CHECK ]\n\n'
    printf 'check-instance:\n'
    printf '\t@echo check-instance >> log\n'
    printf '\t@[ ! -f FAIL_CHECK ]\n'
  } > "$work/Makefile"
  git_q "$work" init -q -b main
  git_q "$work" remote add origin "$bare"
  commit_all "$work"
  git_q "$work" push -q -u origin main
  printf '%s' "$work"
}

# release_out <work> <version> [VAR=val ...] — combined stdout/stderr.
release_out() {
  local work="$1" version="$2"; shift 2
  (cd "$work" && env "$@" bash scripts/release.sh "$version") 2>&1
}

# tags_of <repo> — every tag, one per line (empty when none).
tags_of() { git -C "$1" tag -l; }

# assert_no_tag <label> <work> <version> — neither the clone nor its origin
# gained the tag.
assert_no_tag() {
  local label="$1" work="$2" version="$3" bare
  bare="$(bare_of "$work")"
  if printf '%s\n' "$(tags_of "$work")" | grep -qxF "$version"; then
    fail "$label — a local tag was left behind"
  elif printf '%s\n' "$(tags_of "$bare")" | grep -qxF "$version"; then
    fail "$label — a remote tag was left behind"
  else
    ok "$label"
  fi
}

# --- missing VERSION ---
work="$(fresh_repo)"
out="$(release_out "$work" "")" && rc=0 || rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF 'does not match' && printf '%s' "$out" | grep -qF 'v[0-9]+'; then
  ok "a missing VERSION is refused, naming the pattern"
else
  fail "a missing VERSION is refused, naming the pattern: $out"
fi

# --- a VERSION without the v (1.0.0) ---
work="$(fresh_repo)"
out="$(release_out "$work" "1.0.0")" && rc=0 || rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF "'1.0.0'"; then
  ok "a VERSION without the v (1.0.0) is refused"
else
  fail "a VERSION without the v (1.0.0) is refused: $out"
fi
assert_no_tag "a VERSION without the v leaves no tag" "$work" "1.0.0"

# --- a release candidate numbered 0 (v1.0.0-rc.0) ---
work="$(fresh_repo)"
out="$(release_out "$work" "v1.0.0-rc.0")" && rc=0 || rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF "'v1.0.0-rc.0'"; then
  ok "a release candidate numbered 0 (v1.0.0-rc.0) is refused"
else
  fail "a release candidate numbered 0 (v1.0.0-rc.0) is refused: $out"
fi
assert_no_tag "v1.0.0-rc.0 leaves no tag" "$work" "v1.0.0-rc.0"

# --- a dirty working tree (a tracked file edited, not committed) ---
work="$(fresh_repo)"
printf 'edit\n' >> "$work/Makefile"
out="$(release_out "$work" "v1.0.0")" && rc=0 || rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF 'uncommitted changes'; then
  ok "a dirty working tree is refused"
else
  fail "a dirty working tree is refused: $out"
fi
assert_no_tag "a dirty working tree leaves no tag" "$work" "v1.0.0"

# --- an untracked file also makes the tree dirty ---
work="$(fresh_repo)"
printf 'scratch\n' > "$work/untracked.txt"
out="$(release_out "$work" "v1.0.0")" && rc=0 || rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF 'uncommitted changes'; then
  ok "an untracked file is refused as a dirty working tree"
else
  fail "an untracked file is refused as a dirty working tree: $out"
fi
assert_no_tag "an untracked file leaves no tag" "$work" "v1.0.0"

# --- HEAD not on origin/main (a local commit was never pushed) ---
work="$(fresh_repo)"
commit_all "$work"
out="$(release_out "$work" "v1.0.0")" && rc=0 || rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF 'not an ancestor'; then
  ok "HEAD not on origin/main is refused"
else
  fail "HEAD not on origin/main is refused: $out"
fi
assert_no_tag "HEAD not on origin/main leaves no tag" "$work" "v1.0.0"

# --- the tag exists locally ---
work="$(fresh_repo)"
git_q "$work" tag v1.0.0
out="$(release_out "$work" "v1.0.0")" && rc=0 || rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF 'already exists locally'; then
  ok "a tag that already exists locally is refused"
else
  fail "a tag that already exists locally is refused: $out"
fi
if [ "$(git -C "$(bare_of "$work")" tag -l v1.0.0)" = "v1.0.0" ]; then
  fail "a tag that already exists locally is refused — it was pushed"
else
  ok "a tag that already exists locally is refused, and it is never pushed"
fi

# --- the tag exists only on the remote ---
work="$(fresh_repo)"
git_q "$work" tag v1.0.0
git_q "$work" push -q origin refs/tags/v1.0.0
git_q "$work" tag -d v1.0.0
out="$(release_out "$work" "v1.0.0")" && rc=0 || rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF 'already exists'; then
  ok "a tag that exists only on the remote is refused"
else
  fail "a tag that exists only on the remote is refused: $out"
fi

# --- v1.2.0 released, then v1.2.0 again ---
work="$(fresh_repo)"
git_q "$work" tag -a v1.2.0 -m rel
git_q "$work" push -q origin refs/tags/v1.2.0
out="$(release_out "$work" "v1.2.0")" && rc=0 || rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF 'already exists'; then
  ok "v1.2.0 after v1.2.0 already exists is refused"
else
  fail "v1.2.0 after v1.2.0 already exists is refused: $out"
fi
if [ "$(git -C "$(bare_of "$work")" tag -l | grep -c '^v1\.2\.0$')" = 1 ]; then
  ok "v1.2.0 after v1.2.0 already exists creates no second tag"
else
  fail "v1.2.0 after v1.2.0 already exists creates no second tag"
fi

# --- v1.2.0-rc.1 released after v1.2.0 already exists: not newer ---
work="$(fresh_repo)"
git_q "$work" tag -a v1.2.0 -m rel
git_q "$work" push -q origin refs/tags/v1.2.0
out="$(release_out "$work" "v1.2.0-rc.1")" && rc=0 || rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF 'v1.2.0-rc.1 is not newer than v1.2.0'; then
  ok "v1.2.0-rc.1 after v1.2.0 already exists is refused as not newer"
else
  fail "v1.2.0-rc.1 after v1.2.0 already exists is refused as not newer: $out"
fi
assert_no_tag "v1.2.0-rc.1 after v1.2.0 already exists leaves no new tag" "$work" "v1.2.0-rc.1"

# --- a failing check: no tag locally or on the remote ---
# FAIL_CHECK is gitignored, so creating it does not dirty the working tree.
work="$(fresh_repo)"
: > "$work/FAIL_CHECK"
out="$(release_out "$work" "v1.0.0")" && rc=0 || rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF 'make check failed'; then
  ok "a failing make check fails the release"
else
  fail "a failing make check fails the release: $out"
fi
assert_no_tag "a failing make check leaves no tag" "$work" "v1.0.0"
if [ "$(cat "$work/log" 2>/dev/null)" = "check" ]; then
  ok "a failing make check runs check exactly once"
else
  fail "a failing make check runs check exactly once: $(cat "$work/log" 2>/dev/null)"
fi

# --- success: an annotated tag on the remote, pointing at HEAD; check ran once ---
work="$(fresh_repo)"
out="$(release_out "$work" "v1.0.0")" && rc=0 || rc=$?
if [ "$rc" -eq 0 ]; then ok "a clean release succeeds"; else fail "a clean release succeeds: $out"; fi
if printf '%s' "$out" | grep -qF 'release: running make check'; then
  ok "it prints that it is running make check, before tagging"
else
  fail "it prints that it is running make check, before tagging: $out"
fi
if printf '%s' "$out" | grep -qF 'release: pushed v1.0.0; release.yml builds it'; then
  ok "it prints the final pushed message"
else
  fail "it prints the final pushed message: $out"
fi
bare="$(bare_of "$work")"
head="$(git -C "$work" rev-parse HEAD)"
if [ "$(git -C "$bare" cat-file -t v1.0.0 2>/dev/null)" = tag ]; then
  ok "the pushed tag is annotated"
else
  fail "the pushed tag is annotated"
fi
if [ "$(git -C "$bare" rev-list -n1 v1.0.0 2>/dev/null)" = "$head" ]; then
  ok "the pushed tag points at HEAD"
else
  fail "the pushed tag points at HEAD"
fi
if [ "$(cat "$work/log" 2>/dev/null)" = "check" ]; then
  ok "a successful release runs check exactly once"
else
  fail "a successful release runs check exactly once: $(cat "$work/log" 2>/dev/null)"
fi

# --- a push failure (the bare repository's pre-receive hook exits 1) ---
work="$(fresh_repo)"
bare="$(bare_of "$work")"
mkdir -p "$bare/hooks"
printf '#!/usr/bin/env bash\nexit 1\n' > "$bare/hooks/pre-receive"
chmod +x "$bare/hooks/pre-receive"
out="$(release_out "$work" "v1.0.0")" && rc=0 || rc=$?
if [ "$rc" -ne 0 ] && printf '%s' "$out" | grep -qF 'push to origin failed'; then
  ok "a push failure fails the release"
else
  fail "a push failure fails the release: $out"
fi
if git -C "$work" rev-parse -q --verify refs/tags/v1.0.0 >/dev/null 2>&1; then
  fail "a push failure leaves no local tag — it did"
else
  ok "a push failure leaves no local tag"
fi
if [ -z "$(git -C "$bare" tag -l v1.0.0)" ]; then
  ok "a push failure leaves no remote tag"
else
  fail "a push failure leaves no remote tag"
fi

# --- RELEASE_CHECK_TARGET=check-instance runs that target ---
work="$(fresh_repo)"
out="$(release_out "$work" "v1.0.0" RELEASE_CHECK_TARGET=check-instance)" && rc=0 || rc=$?
if [ "$rc" -eq 0 ]; then ok "RELEASE_CHECK_TARGET=check-instance succeeds"; else fail "RELEASE_CHECK_TARGET=check-instance succeeds: $out"; fi
if printf '%s' "$out" | grep -qF 'release: running make check-instance'; then
  ok "RELEASE_CHECK_TARGET=check-instance is announced"
else
  fail "RELEASE_CHECK_TARGET=check-instance is announced: $out"
fi
if [ "$(cat "$work/log" 2>/dev/null)" = "check-instance" ]; then
  ok "RELEASE_CHECK_TARGET=check-instance runs check-instance, not check"
else
  fail "RELEASE_CHECK_TARGET=check-instance runs check-instance, not check: $(cat "$work/log" 2>/dev/null)"
fi

if [ "$FAILURES" -gt 0 ]; then printf '\n%s case(s) failed\n' "$FAILURES" >&2; exit 1; fi
printf '\nall cases passed\n'
