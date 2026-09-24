#!/usr/bin/env bash
# new-instance.test.sh — create instances from a throwaway template.
#
# Never pushes: PUSH is unset in every case.
#
# Usage: bash scripts/new-instance.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

export GIT_AUTHOR_NAME="Test Dev"     GIT_AUTHOR_EMAIL="dev@example.test"
export GIT_COMMITTER_NAME="Test Dev"  GIT_COMMITTER_EMAIL="dev@example.test"
export GIT_CONFIG_NOSYSTEM=1
# Local submodule clones use the file transport, which git refuses by default.
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=protocol.file.allow GIT_CONFIG_VALUE_0=always
unset PUSH OWNER

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILURES=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }
ok()   { printf 'ok: %s\n' "$*"; }

# A core with one release tag.
CORE_UP="$TMP/core-upstream"
git init -q -b main "$CORE_UP"
printf 'go 1.26.6\n' > "$CORE_UP/go.work"
git -C "$CORE_UP" add -A && git -C "$CORE_UP" commit -q -m core && git -C "$CORE_UP" tag v0.0.2

# A template: this repository's scripts and ownership list, core as a submodule.
TPL="$TMP/template"
git init -q -b main "$TPL"
cp -R "$SCRIPT_DIR" "$TPL/scripts"
cp "$ROOT/.template-owned" "$TPL/.template-owned"
printf 'help:\n\t@echo help\n' > "$TPL/Makefile"
printf '# margince-template\n' > "$TPL/README.md"
printf 'name: margince-default\ndisplay_name: Margince Default\ncore: v0.0.2\nflavor: margince/margince\n' > "$TPL/instance.yaml"
git -C "$TPL" submodule add -q "$CORE_UP" core
git -C "$TPL/core" checkout -q --detach v0.0.2
git -C "$TPL" add -A && git -C "$TPL" commit -q -m template
git -C "$TPL" remote add origin "$TMP/template-origin.git"
TPL_SHA="$(git -C "$TPL" rev-parse HEAD)"

create() { (cd "$TPL" && env "$@" bash scripts/new-instance.sh); }
# cli_get <instance dir> <key> — one value from an instance's instance.yaml,
# read through the same CLI the scripts use, so quoting/escaping in the file
# is irrelevant to the assertion.
cli_get() { (cd "$1/scripts/cli" && GOWORK=off go run . get -file "$1/instance.yaml" "$2"); }

# --- a valid instance ---
DIR="$TMP/margince-acme"
if out="$(create NAME=acme DISPLAY_NAME=Acme DIR="$DIR" 2>&1)"; then ok "creates an instance"; else fail "creates an instance: $out"; fi
if [ "$(git -C "$DIR" rev-parse --abbrev-ref HEAD)" = "main" ]; then ok "the instance is on main"; else fail "the instance is on main"; fi
if [ "$(git -C "$DIR" remote get-url template)" = "$TMP/template-origin.git" ]; then ok "the template remote is the template's origin"; else fail "the template remote is the template's origin"; fi
if git -C "$DIR" remote get-url origin >/dev/null 2>&1; then fail "has no origin before a push"; else ok "has no origin before a push"; fi
if [ "$(tr -d '[:space:]' < "$DIR/.template-version")" = "$TPL_SHA" ]; then ok "records the template commit"; else fail "records the template commit"; fi
if grep -qx 'flavor: acme/margince' "$DIR/instance.yaml" && grep -qx 'core: v0.0.2' "$DIR/instance.yaml" && [ "$(cli_get "$DIR" display_name)" = "Acme" ]; then ok "writes instance.yaml"; else fail "writes instance.yaml"; fi
if [ "$(git -C "$DIR/core" describe --tags --exact-match 2>/dev/null)" = "v0.0.2" ]; then ok "checks out core at the pinned tag"; else fail "checks out core at the pinned tag"; fi
if [ -z "$(git -C "$DIR" status --porcelain)" ]; then ok "commits everything"; else fail "commits everything"; fi
if bash "$DIR/scripts/check-template.sh" >/dev/null 2>&1; then ok "the new instance passes check-template"; else fail "the new instance passes check-template"; fi
if (cd "$DIR/scripts/cli" && GOWORK=off go run . check -file "$DIR/instance.yaml" -core "$DIR/core" >/dev/null 2>&1); then ok "the new instance passes check-instance"; else fail "the new instance passes check-instance"; fi

# --- core is dissociated from the template's checkout ---
# Without --dissociate, core/'s objects depend on the template's own core
# checkout via objects/info/alternates, so the instance's core/ silently stops
# working (or worse, corrupts) if the template checkout is ever removed.
git_dir="$(cd "$DIR/core" && git rev-parse --git-dir)"
case "$git_dir" in
  /*) alternates="$git_dir/objects/info/alternates" ;;
  *)  alternates="$DIR/core/$git_dir/objects/info/alternates" ;;
esac
if [ -e "$alternates" ]; then fail "core is dissociated from the template checkout"; else ok "core is dissociated from the template checkout"; fi

# --- a HEAD that is not on origin/main is flagged, not refused ---
# An unrelated commit stands in for origin/main, so HEAD is not its ancestor.
unrelated="$(git -C "$TPL" commit-tree -m unrelated "$(git -C "$TPL" rev-parse 'HEAD^{tree}')")"
git -C "$TPL" update-ref refs/remotes/origin/main "$unrelated"
DIR5="$TMP/margince-offmain"
if out="$(create NAME=offmain DISPLAY_NAME=Off DIR="$DIR5" 2>&1)"; then
  if printf '%s\n' "$out" | grep -q "new-instance: HEAD (.*) is not on origin/main; the instance will contain unmerged template commits"; then
    ok "warns when HEAD is not on origin/main"
  else
    fail "warns when HEAD is not on origin/main: $out"
  fi
else
  fail "warns when HEAD is not on origin/main — it refused: $out"
fi
git -C "$TPL" update-ref refs/remotes/origin/main "$TPL_SHA"
if out="$(create NAME=onmain DISPLAY_NAME=On DIR="$TMP/margince-onmain" 2>&1)" && ! printf '%s\n' "$out" | grep -q 'is not on origin/main'; then
  ok "does not warn when HEAD is on origin/main"
else
  fail "does not warn when HEAD is on origin/main: $out"
fi
git -C "$TPL" update-ref -d refs/remotes/origin/main

# --- VENDOR sets the flavor ---
DIR2="$TMP/margince-acme-eu"
create NAME=acme-eu DISPLAY_NAME="Acme EU" VENDOR=acme DIR="$DIR2" >/dev/null 2>&1 || true
if grep -qx 'flavor: acme/margince' "$DIR2/instance.yaml" 2>/dev/null; then ok "VENDOR sets the flavor"; else fail "VENDOR sets the flavor"; fi

# --- DISPLAY_NAME with YAML-special characters round-trips exactly ---
DIR3="$TMP/margince-acme-special"
special='Acme #1: Client "EU"'
if out="$(create NAME=acme-special DISPLAY_NAME="$special" DIR="$DIR3" 2>&1)"; then
  got="$(cli_get "$DIR3" display_name 2>&1)"
  if [ "$got" = "$special" ]; then
    ok "quotes a display name with #, : and \" so it round-trips exactly"
  else
    fail "quotes a display name with #, : and \" so it round-trips exactly: got $got"
  fi
else
  fail "quotes a display name with #, : and \" so it round-trips exactly: $out"
fi

# --- refusals create nothing ---
expect_refused() {
  local label="$1" dir="$2"; shift 2
  if create "$@" DIR="$dir" >/dev/null 2>&1; then fail "$label — it succeeded"
  elif [ -e "$dir" ] && [ "$dir" != "$DIR" ]; then fail "$label — it created $dir"
  else ok "$label"; fi
}
expect_refused "refuses a missing name" "$TMP/x1" DISPLAY_NAME=X
expect_refused "refuses an invalid name" "$TMP/x2" NAME=Acme DISPLAY_NAME=X
expect_refused "refuses a missing display name" "$TMP/x3" NAME=acme2
expect_refused "refuses an existing directory" "$DIR" NAME=acme DISPLAY_NAME=Acme
expect_refused "refuses a multi-line display name" "$TMP/x5" NAME=multiline DISPLAY_NAME=$'Acme\nClient'
if (cd "$DIR" && NAME=other DISPLAY_NAME=O DIR="$TMP/x4" bash scripts/new-instance.sh >/dev/null 2>&1); then
  fail "refuses to run inside an instance"
elif [ -e "$TMP/x4" ]; then fail "refuses to run inside an instance — it created a directory"
else ok "refuses to run inside an instance"; fi

# --- a half-created instance is removed when core cannot be fetched ---
# A template whose core submodule points at a path that does not exist, so
# `git submodule update --init` fails partway through (the same shape as core
# being unreachable offline), after the clone and checkout already created
# $dir on disk.
TPL_BROKEN="$TMP/template-broken"
cp -R "$TPL" "$TPL_BROKEN"
git -C "$TPL_BROKEN" config -f .gitmodules submodule.core.url "$TMP/does-not-exist"
git -C "$TPL_BROKEN" add .gitmodules
git -C "$TPL_BROKEN" commit -q -m "point core at an unreachable url"
DIR4="$TMP/margince-broken"
if (cd "$TPL_BROKEN" && env NAME=broken DISPLAY_NAME=Broken DIR="$DIR4" bash scripts/new-instance.sh >/dev/null 2>&1); then
  fail "removes a half-created instance when core cannot be fetched — it succeeded"
elif [ -e "$DIR4" ]; then
  fail "removes a half-created instance when core cannot be fetched — $DIR4 remains"
else
  ok "removes a half-created instance when core cannot be fetched"
fi

if [ "$FAILURES" -gt 0 ]; then printf '\n%s case(s) failed\n' "$FAILURES" >&2; exit 1; fi
printf '\nall cases passed\n'
