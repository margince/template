#!/usr/bin/env bash
# new-unit.test.sh — scaffold units into a throwaway copy of this repository.
#
# Each case gets a fresh copy: scripts/ beside an empty extensions/ and a core/
# git repository that tracks one upstream unit, extensions/notes.
#
# Usage: bash scripts/new-unit.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

export GIT_AUTHOR_NAME="Test Dev"     GIT_AUTHOR_EMAIL="dev@example.test"
export GIT_COMMITTER_NAME="Test Dev"  GIT_COMMITTER_EMAIL="dev@example.test"
export GIT_CONFIG_NOSYSTEM=1

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILURES=0

fail() { printf 'FAIL: %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }
ok()   { printf 'ok: %s\n' "$*"; }

fresh_repo() {
  local repo
  repo="$(mktemp -d "$TMP/repo.XXXXXX")"
  mkdir -p "$repo/extensions" "$repo/core/extensions/notes"
  cp -R "$SCRIPT_DIR" "$repo/scripts"
  printf 'package notes\n' > "$repo/core/extensions/notes/notes.go"
  git -C "$repo/core" init -q
  git -C "$repo/core" add -A
  git -C "$repo/core" commit -q -m upstream
  printf '%s' "$repo"
}

# --- a valid name ---

repo="$(fresh_repo)"
if out="$(bash "$repo/scripts/new-unit.sh" acme-sync 2>&1)"; then
  ok "scaffolds a valid name"
else
  fail "scaffolds a valid name: $out"
fi
unit="$repo/extensions/acme-sync"
for f in go.mod acmesync.go acmesync_test.go; do
  if [ -f "$unit/$f" ]; then ok "creates $f"; else fail "creates $f"; fi
done
if grep -rqE '__NAME__|__PKG__' "$unit"; then fail "leaves no placeholder"; else ok "leaves no placeholder"; fi
if grep -q '^package acmesync$' "$unit/acmesync.go"; then ok "the package name drops the hyphen"; else fail "the package name drops the hyphen"; fi
if grep -q 'Name:        "acme-sync",' "$unit/acmesync.go"; then ok "declares the directory name"; else fail "declares the directory name"; fi
if grep -q '^module margince.instance/extensions/acme-sync$' "$unit/go.mod"; then ok "names the module after the unit"; else fail "names the module after the unit"; fi
if [ ! -e "$unit/manifest.generated.json" ]; then ok "writes no manifest"; else fail "writes no manifest"; fi

# --- refusals create nothing ---

expect_refused() {
  local label="$1"; shift
  local repo
  repo="$(fresh_repo)"
  if bash "$repo/scripts/new-unit.sh" "$@" >/dev/null 2>&1; then
    fail "$label — it succeeded"
  elif [ -n "$(ls -A "$repo/extensions")" ]; then
    fail "$label — it left a directory behind"
  else
    ok "$label"
  fi
}

expect_refused "refuses a missing name"
expect_refused "refuses an upper-case name" Acme
expect_refused "refuses a double hyphen" acme--sync
expect_refused "refuses a name over 32 characters" abcdefghijklmnopqrstuvwxyz0123456
expect_refused "refuses an upstream unit's name" notes

repo="$(fresh_repo)"
mkdir "$repo/extensions/acme"
if bash "$repo/scripts/new-unit.sh" acme >/dev/null 2>&1; then
  fail "refuses an existing unit"
else
  ok "refuses an existing unit"
fi

# --- a render that fails partway through leaves nothing behind ---
#
# Validation cannot catch this one: the name is fine, and the failure is a
# missing template discovered only once rendering is under way, after
# extensions/<name> already exists. The ERR trap around render() is what
# cleans this up, not the up-front checks above.

repo="$(fresh_repo)"
rm "$repo/scripts/unit-skeleton/unit_test.go.tmpl"
if out="$(bash "$repo/scripts/new-unit.sh" acme-sync 2>&1)"; then
  fail "a failed render — it succeeded: $out"
elif [ -n "$(ls -A "$repo/extensions")" ]; then
  fail "a failed render — it left extensions/acme-sync behind"
else
  ok "a failed render leaves no partial unit"
fi

if [ "$FAILURES" -gt 0 ]; then
  printf '\n%s case(s) failed\n' "$FAILURES" >&2
  exit 1
fi
printf '\nall cases passed\n'
