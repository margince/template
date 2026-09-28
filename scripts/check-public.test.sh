#!/usr/bin/env bash
# check-public.test.sh — no tracked or staged file names a private repository,
# host, organization or service (spec Section 7).
#
# Runs the real check-public.sh and check-public.patterns against scratch git
# repositories, so a change to either is proven against the same behavior
# `make check-public` runs in this repository.
#
# Usage: bash scripts/check-public.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Hermetic against the developer's git config and signing setup, as
# scripts/lifecycle.test.sh does (lines 33-47).
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY \
  GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_PREFIX
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false
export GIT_AUTHOR_NAME="Test Dev"     GIT_AUTHOR_EMAIL="dev@example.test"
export GIT_COMMITTER_NAME="Test Dev"  GIT_COMMITTER_EMAIL="dev@example.test"
export GIT_CONFIG_NOSYSTEM=1

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILURES=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }
ok()   { printf 'ok: %s\n' "$*"; }

# Fixture values built from parts at runtime, never spelled whole in this
# file's own source: this file is itself scanned by check-public (it is not
# docs/superpowers/ or scripts/check-public.patterns), so a literal match
# here would fail this repository's own gate.
PRIV_ORG="gradion""hq"
PRIV_ORG_UPPER="$(printf '%s' "$PRIV_ORG" | tr '[:lower:]' '[:upper:]')"
PRIV_REPO="margince-demo""-database"

# A scratch repo with a copy of the real script and patterns, so this proves
# the checked-in files, not a fixture that could drift from them.
REPO="$TMP/repo"
mkdir -p "$REPO/scripts" "$REPO/docs/superpowers"
cp "$SCRIPT_DIR/check-public.sh" "$REPO/scripts/check-public.sh"
cp "$SCRIPT_DIR/check-public.patterns" "$REPO/scripts/check-public.patterns"
git init -q -b main "$REPO"

commit_all() { git -C "$REPO" add -A && git -C "$REPO" commit -q -m "$1"; }

run_check() { (cd "$REPO" && bash scripts/check-public.sh); }

# --- a clean tree passes ---
printf 'nothing private here\n' > "$REPO/clean.txt"
commit_all "clean"
if run_check >/dev/null 2>&1; then ok "a clean tree passes"; else fail "a clean tree passes"; fi

# --- a committed file with a private reference fails, naming file and line ---
printf 'line one\n%s/x\n' "$PRIV_ORG" > "$REPO/bad.txt"
commit_all "add a private reference"
out="$(run_check 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then ok "a committed private reference fails"; else fail "a committed private reference fails"; fi
if printf '%s\n' "$out" | grep -qE '^bad\.txt:2:'; then
  ok "names the file and the line"
else
  fail "names the file and the line: $out"
fi
git -C "$REPO" rm -q bad.txt && commit_all "remove the private reference"

# --- a staged but uncommitted new file fails ---
printf '%s/y\n' "$PRIV_ORG" > "$REPO/staged.txt"
git -C "$REPO" add staged.txt
out="$(run_check 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ]; then ok "a staged but uncommitted new file fails"; else fail "a staged but uncommitted new file fails"; fi
if printf '%s\n' "$out" | grep -qE '^staged\.txt:1:'; then
  ok "names the staged file and its line"
else
  fail "names the staged file and its line: $out"
fi
git -C "$REPO" reset -q -- staged.txt && rm -f "$REPO/staged.txt"

# --- a match under docs/superpowers/ passes ---
printf '%s/z\n' "$PRIV_ORG" > "$REPO/docs/superpowers/notes.md"
commit_all "add a docs/superpowers note"
if run_check >/dev/null 2>&1; then
  ok "a match under docs/superpowers/ passes"
else
  fail "a match under docs/superpowers/ passes"
fi
git -C "$REPO" rm -q -r docs/superpowers >/dev/null && mkdir -p "$REPO/docs/superpowers" \
  && : > "$REPO/docs/superpowers/.gitkeep" && commit_all "restore docs/superpowers"

# --- a match under scripts/check-public.patterns itself is not flagged ---
if run_check >/dev/null 2>&1; then
  ok "the patterns file itself is excluded from the scan"
else
  fail "the patterns file itself is excluded from the scan"
fi

# --- a match in .github/workflows/x.yml fails ---
mkdir -p "$REPO/.github/workflows"
printf 'repository: %s/%s\n' "$PRIV_ORG" "$PRIV_REPO" > "$REPO/.github/workflows/x.yml"
commit_all "add a workflow with a private reference"
if run_check >/dev/null 2>&1; then
  fail "a match in .github/workflows/x.yml fails"
else
  ok "a match in .github/workflows/x.yml fails"
fi
git -C "$REPO" rm -q -r .github >/dev/null && commit_all "remove the workflow"

# --- uppercase matches too (case-insensitive) ---
printf '%s\n' "$PRIV_ORG_UPPER" > "$REPO/upper.txt"
commit_all "add an uppercase private reference"
if run_check >/dev/null 2>&1; then
  fail "uppercase $PRIV_ORG_UPPER fails"
else
  ok "uppercase $PRIV_ORG_UPPER fails"
fi
git -C "$REPO" rm -q upper.txt && commit_all "remove it"

# --- a clean tree passes again, after every fixture above is undone ---
if run_check >/dev/null 2>&1; then ok "a clean tree passes again"; else fail "a clean tree passes again"; fi

if [ "$FAILURES" -gt 0 ]; then printf '\n%s case(s) failed\n' "$FAILURES" >&2; exit 1; fi
printf '\nall cases passed\n'
