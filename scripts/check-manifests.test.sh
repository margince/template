#!/usr/bin/env bash
# check-manifests.sh against SYNTHETIC trees, one per state it must distinguish.
#
# The two regressions this suite exists to hold down are opposites, which is why
# neither half of the gate can be dropped:
#
#   - a diff over all of extensions/ fired on an uncommitted SOURCE edit and
#     called it a stale manifest, breaking the fast per-unit lane mid-task;
#   - a diff alone is blind to an UNTRACKED manifest, which is exactly what a
#     newly scaffolded unit has.
#
# Usage: bash scripts/check-manifests.test.sh
set -euo pipefail

SCRIPT="$(cd "$(dirname "$0")" && pwd)/check-manifests.sh"

FAILURES=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }
ok()   { printf 'ok: %s\n' "$*"; }

# A repo with one unit whose manifest is committed and current.
#
# Hermetic against the developer's own git config: an init.defaultBranch or a
# commit.gpgsign in ~/.gitconfig must not decide whether this suite passes.
new_repo() {
  local dir; dir="$(mktemp -d)"
  git -C "$dir" init -q
  git -C "$dir" config user.email t@t.t
  git -C "$dir" config user.name t
  git -C "$dir" config commit.gpgsign false
  mkdir -p "$dir/extensions/alpha" "$dir/scripts"
  echo 'package alpha' > "$dir/extensions/alpha/alpha.go"
  echo '{"name":"alpha"}' > "$dir/extensions/alpha/manifest.generated.json"
  cp "$SCRIPT" "$dir/scripts/check-manifests.sh"
  git -C "$dir" add -A
  git -C "$dir" commit -qm init
  printf '%s' "$dir"
}

run() { ( cd "$1" && bash scripts/check-manifests.sh 2>&1 ); }
status() { ( cd "$1" && bash scripts/check-manifests.sh >/dev/null 2>&1 ); echo $?; }

# --- clean tree passes ---
r="$(new_repo)"
[ "$(status "$r")" = 0 ] && ok "a committed, current manifest passes" \
  || fail "a committed, current manifest passes"
rm -rf "$r"

# --- THE REGRESSION: an uncommitted source edit is not this gate's business ---
r="$(new_repo)"
printf '\n// work in progress\n' >> "$r/extensions/alpha/alpha.go"
[ "$(status "$r")" = 0 ] && ok "an uncommitted source edit still passes" \
  || fail "an uncommitted source edit still passes"
rm -rf "$r"

# Not even when the edit is a whole new source file, which is the other shape
# mid-task work takes.
r="$(new_repo)"
echo 'package alpha' > "$r/extensions/alpha/poll.go"
[ "$(status "$r")" = 0 ] && ok "a new, untracked source file still passes" \
  || fail "a new, untracked source file still passes"
rm -rf "$r"

# --- a changed manifest fails, and names the file ---
r="$(new_repo)"
echo '{"name":"alpha","tier":"changed"}' > "$r/extensions/alpha/manifest.generated.json"
[ "$(status "$r")" = 1 ] && ok "a changed manifest fails" || fail "a changed manifest fails"
case "$(run "$r")" in
  *"extensions/alpha/manifest.generated.json"*) ok "a changed manifest is named in the failure" ;;
  *) fail "a changed manifest is named in the failure" ;;
esac
rm -rf "$r"

# --- THE OTHER REGRESSION: an untracked manifest fails ---
#
# git diff cannot see this state at all. A scaffolded unit is always in it:
# new-unit.sh deletes the template's manifest, so the first compose writes one
# that was never `git add`ed.
r="$(new_repo)"
mkdir -p "$r/extensions/beta"
echo 'package beta' > "$r/extensions/beta/beta.go"
echo '{"name":"beta"}' > "$r/extensions/beta/manifest.generated.json"
[ "$(status "$r")" = 1 ] && ok "a new unit's untracked manifest fails" \
  || fail "a new unit's untracked manifest fails"
case "$(run "$r")" in
  *"not tracked by git"*) ok "the untracked case says the manifest is not tracked" ;;
  *) fail "the untracked case says the manifest is not tracked" ;;
esac
rm -rf "$r"

# A gitignored manifest must not count as committed either -- --exclude-standard
# would hide it, so the ignore rule must not be what decides.
r="$(new_repo)"
mkdir -p "$r/extensions/beta"
echo 'extensions/beta/manifest.generated.json' > "$r/.gitignore"
echo '{"name":"beta"}' > "$r/extensions/beta/manifest.generated.json"
git -C "$r" add .gitignore && git -C "$r" commit -qm ignore
[ "$(status "$r")" = 1 ] && ok "an ignored manifest does not pass as committed" \
  || fail "an ignored manifest does not pass as committed"
rm -rf "$r"

# --- both at once are both reported ---
#
# One run should tell you everything to fix, not the first thing.
r="$(new_repo)"
echo '{"name":"alpha","tier":"changed"}' > "$r/extensions/alpha/manifest.generated.json"
mkdir -p "$r/extensions/beta"
echo '{"name":"beta"}' > "$r/extensions/beta/manifest.generated.json"
# `|| true` because the gate is SUPPOSED to fail here, and under `set -e` a
# failing command substitution in an assignment would end the suite.
out="$(run "$r")" || true
case "$out" in
  *"changed by the composer"*) ok "a mixed tree reports the changed manifest" ;;
  *) fail "a mixed tree reports the changed manifest" ;;
esac
case "$out" in
  *"not tracked by git"*) ok "a mixed tree reports the untracked manifest too" ;;
  *) fail "a mixed tree reports the untracked manifest too" ;;
esac
rm -rf "$r"

# --- a deleted manifest fails ---
r="$(new_repo)"
rm "$r/extensions/alpha/manifest.generated.json"
[ "$(status "$r")" = 1 ] && ok "a deleted manifest fails" || fail "a deleted manifest fails"
rm -rf "$r"

# --- the failure tells you what to run ---
r="$(new_repo)"
rm "$r/extensions/alpha/manifest.generated.json"
case "$(run "$r")" in
  *"make compose"*) ok "the failure names the command that fixes it" ;;
  *) fail "the failure names the command that fixes it" ;;
esac
rm -rf "$r"

if [ "$FAILURES" -gt 0 ]; then
  printf '\n%s case(s) failed\n' "$FAILURES" >&2
  exit 1
fi
printf '\nall cases passed\n'
