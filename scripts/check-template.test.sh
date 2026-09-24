#!/usr/bin/env bash
# check-template.test.sh — an instance's template-owned paths match its template commit.
#
# Usage: bash scripts/check-template.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

export GIT_AUTHOR_NAME="Test Dev"     GIT_AUTHOR_EMAIL="dev@example.test"
export GIT_COMMITTER_NAME="Test Dev"  GIT_COMMITTER_EMAIL="dev@example.test"
export GIT_CONFIG_NOSYSTEM=1

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILURES=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }
ok()   { printf 'ok: %s\n' "$*"; }

# A template with the real check script and ownership list.
TPL="$TMP/template"
git init -q -b main "$TPL"
mkdir -p "$TPL/scripts" "$TPL/docs/client"
# A placeholder so docs/client survives the commit and clone below: git does not
# track an empty directory, and the instance-owned-edit case further down writes
# into docs/client/ on the assumption that it already exists.
: > "$TPL/docs/client/.gitkeep"
cp "$ROOT/.template-owned" "$TPL/.template-owned"
cp "$SCRIPT_DIR/check-template.sh" "$SCRIPT_DIR/check-instance-mk.sh" "$TPL/scripts/"
printf 'help:\n\t@echo help\n' > "$TPL/Makefile"
printf 'guide\n' > "$TPL/docs/guide.md"
printf 'name: margince-default\n' > "$TPL/instance.yaml"
git -C "$TPL" add -A && git -C "$TPL" commit -q -m template
TPL_SHA="$(git -C "$TPL" rev-parse HEAD)"

fresh_instance() {
  local inst
  inst="$(mktemp -d "$TMP/instance.XXXXXX")"
  rmdir "$inst"
  git clone -q "$TPL" "$inst"
  printf '%s\n' "$TPL_SHA" > "$inst/.template-version"
  git -C "$inst" add .template-version && git -C "$inst" commit -q -m "record template"
  printf '%s' "$inst"
}

check() { bash "$1/scripts/check-template.sh" >/dev/null 2>&1; }

# --- the template itself ---
if check "$TPL"; then ok "the template itself passes"; else fail "the template itself passes"; fi

# --- clean instance, and instance-owned edits ---
inst="$(fresh_instance)"
if check "$inst"; then ok "an unchanged instance passes"; else fail "an unchanged instance passes"; fi
printf 'name: acme\n' > "$inst/instance.yaml"; printf 'notes\n' > "$inst/docs/client/notes.md"
if check "$inst"; then ok "instance-owned edits pass"; else fail "instance-owned edits pass"; fi

# --- template-owned edits fail ---
inst="$(fresh_instance)"; printf 'x\n' >> "$inst/Makefile"
if check "$inst"; then fail "an uncommitted Makefile edit fails"; else ok "an uncommitted Makefile edit fails"; fi

inst="$(fresh_instance)"; printf 'x\n' >> "$inst/docs/guide.md"; git -C "$inst" commit -qam edit
if check "$inst"; then fail "a committed docs edit fails"; else ok "a committed docs edit fails"; fi

inst="$(fresh_instance)"; printf 'x\n' > "$inst/scripts/extra.sh"
if check "$inst"; then fail "an untracked file under scripts/ fails"; else ok "an untracked file under scripts/ fails"; fi

inst="$(fresh_instance)"; printf 'x\n' > "$inst/scripts/extra.sh"; git -C "$inst" add -A; git -C "$inst" commit -qm add
if check "$inst"; then fail "a committed new file under scripts/ fails"; else ok "a committed new file under scripts/ fails"; fi

inst="$(fresh_instance)"
grep -v '^Makefile$' "$inst/.template-owned" > "$inst/o" && mv "$inst/o" "$inst/.template-owned"
printf 'x\n' >> "$inst/Makefile"
if check "$inst"; then fail "shrinking .template-owned does not hide an edit"; else ok "shrinking .template-owned does not hide an edit"; fi

inst="$(fresh_instance)"; printf 'not-a-sha\n' > "$inst/.template-version"
if check "$inst"; then fail "a malformed .template-version fails"; else ok "a malformed .template-version fails"; fi

inst="$(fresh_instance)"; printf '%s\n' "0123456789012345678901234567890123456789" > "$inst/.template-version"
if check "$inst"; then fail "an unknown template commit fails"; else ok "an unknown template commit fails"; fi

# --- a path with a space is not word-split or glob-expanded in the listing ---
inst="$(fresh_instance)"; printf 'x\n' > "$inst/scripts/with space.sh"
set +e
err="$(bash "$inst/scripts/check-template.sh" 2>&1 >/dev/null)"
status=$?
set -e
if [ "$status" -ne 0 ] && printf '%s\n' "$err" | grep -qF 'scripts/with space.sh'; then
  ok "an untracked file with a space in its name fails, listed on one line"
else
  fail "an untracked file with a space in its name fails, listed on one line: status=$status output=$err"
fi

if [ "$FAILURES" -gt 0 ]; then printf '\n%s case(s) failed\n' "$FAILURES" >&2; exit 1; fi
printf '\nall cases passed\n'
