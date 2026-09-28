#!/usr/bin/env bash
# update-core.test.sh — move a throwaway core between tags.
#
# A fake upstream carries two tagged releases and one untagged commit on main.
# Each case works in a fresh copy of this repository's scripts/ beside a clone
# of that upstream as core/.
#
# Usage: bash scripts/update-core.test.sh
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

# The upstream: v0.0.1, v0.0.2, then one untagged commit on main.
UP="$TMP/upstream"
git init -q -b main "$UP"
printf 'go 1.26.6\n' > "$UP/go.work"
git -C "$UP" add -A && git -C "$UP" commit -q -m one && git -C "$UP" tag v0.0.1
printf 'two\n' > "$UP/two" && git -C "$UP" add -A && git -C "$UP" commit -q -m two && git -C "$UP" tag v0.0.2
printf 'three\n' > "$UP/three" && git -C "$UP" add -A && git -C "$UP" commit -q -m three
V2="$(git -C "$UP" rev-parse v0.0.2^{commit})"
MAIN="$(git -C "$UP" rev-parse main)"
# A real tag, but not shaped like a release: instance.yaml can only record a
# release tag, so this must be refused on shape alone, before core/ is even
# asked whether the tag exists.
git -C "$UP" tag archive/pr100-salvage "$V2"

fresh_repo() {
  local repo
  repo="$(mktemp -d "$TMP/repo.XXXXXX")"
  cp -R "$SCRIPT_DIR" "$repo/scripts"
  git clone -q "$UP" "$repo/core"
  git -C "$repo/core" checkout -q --detach v0.0.1
  printf 'name: acme\ndisplay_name: Acme\ncore: v0.0.1\n' > "$repo/instance.yaml"
  printf '%s' "$repo"
}

# --- a release tag ---

repo="$(fresh_repo)"
if out="$(bash "$repo/scripts/update-core.sh" v0.0.2 2>&1)"; then ok "moves to a release tag"; else fail "moves to a release tag: $out"; fi
if [ "$(git -C "$repo/core" rev-parse HEAD)" = "$V2" ]; then ok "core/ is at the tag"; else fail "core/ is at the tag"; fi
if grep -qx 'core: v0.0.2' "$repo/instance.yaml"; then ok "instance.yaml records the tag"; else fail "instance.yaml records the tag"; fi
if grep -qx 'name: acme' "$repo/instance.yaml" && grep -qx 'display_name: Acme' "$repo/instance.yaml"; then ok "other keys are unchanged"; else fail "other keys are unchanged"; fi

# --- refusals change nothing ---

expect_refused() {
  local label="$1" ref="$2" repo
  repo="$(fresh_repo)"
  if bash "$repo/scripts/update-core.sh" "$ref" >/dev/null 2>&1; then
    fail "$label — it succeeded"
  elif [ "$(git -C "$repo/core" describe --tags --exact-match 2>/dev/null)" != "v0.0.1" ]; then
    fail "$label — core/ moved"
  elif ! grep -qx 'core: v0.0.1' "$repo/instance.yaml"; then
    fail "$label — instance.yaml changed"
  else
    ok "$label"
  fi
}

expect_refused "refuses an empty ref" ""
expect_refused "refuses a branch" main
expect_refused "refuses a commit" "$MAIN"
expect_refused "refuses a tag that does not exist" v9.9.9
expect_refused "refuses a non-release tag" archive/pr100-salvage

if [ "$FAILURES" -gt 0 ]; then printf '\n%s case(s) failed\n' "$FAILURES" >&2; exit 1; fi
printf '\nall cases passed\n'
