#!/usr/bin/env bash
# new-instance.test.sh — create instances from a throwaway template.
#
# PUSH is unset for most cases; the two that DO set it (OWNER required, OWNER
# given) run against a stub `gh` on PATH, never the real one, so no case here
# ever reaches the network.
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

# A stub gh, first on PATH. PUSH=1 needs OWNER to even reach the point of
# calling gh (die fires first without it) — this stub exists so a regression
# that lets that check through still cannot create a real repository or
# reach the network.
STUB_BIN="$TMP/stub-bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/gh" <<'EOF'
#!/usr/bin/env bash
printf 'stub gh: %s\n' "$*" >&2
exit 0
EOF
chmod +x "$STUB_BIN/gh"
export PATH="$STUB_BIN:$PATH"

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
# The real Makefile: the make-level case below runs its new-instance recipe.
cp "$ROOT/Makefile" "$TPL/Makefile"
printf '# margince-template\n' > "$TPL/README.md"
printf 'name: margince-default\ndisplay_name: Margince Default\ncore: v0.0.2\n' > "$TPL/instance.yaml"
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
if printf '%s\n' "$out" | grep -qxF "new-instance: created $DIR (core v0.0.2)"; then
  ok "prints the created line naming the directory and core, without a flavor"
else
  fail "prints the created line naming the directory and core, without a flavor: $out"
fi
if [ "$(git -C "$DIR" rev-parse --abbrev-ref HEAD)" = "main" ]; then ok "the instance is on main"; else fail "the instance is on main"; fi
if [ "$(git -C "$DIR" remote get-url template)" = "$TMP/template-origin.git" ]; then ok "the template remote is the template's origin"; else fail "the template remote is the template's origin"; fi
if git -C "$DIR" remote get-url origin >/dev/null 2>&1; then fail "has no origin before a push"; else ok "has no origin before a push"; fi
if [ "$(tr -d '[:space:]' < "$DIR/.template-version")" = "$TPL_SHA" ]; then ok "records the template commit"; else fail "records the template commit"; fi
keys="$(grep -oE '^[a-zA-Z_]+:' "$DIR/instance.yaml" | tr -d ':' | sort | tr '\n' ' ')"
if [ "$keys" = "core deploy display_name name " ] && [ "$(cli_get "$DIR" core)" = "v0.0.2" ] && [ "$(cli_get "$DIR" display_name)" = "Acme" ]; then
  ok "writes instance.yaml with exactly the keys name, display_name, core, deploy"
else
  fail "writes instance.yaml with exactly the keys name, display_name, core, deploy: $(cat "$DIR/instance.yaml")"
fi
if [ "$(cli_get "$DIR" deploy.production.adapter)" = "host" ]; then
  ok "instance.yaml has deploy.production.adapter: host"
else
  fail "instance.yaml has deploy.production.adapter: host: $(cat "$DIR/instance.yaml")"
fi
if [ -f "$DIR/deploy/production/host.env" ] && [ -f "$DIR/deploy/production/secrets" ] && [ -f "$DIR/deploy/production/config/margince.yaml" ]; then
  ok "creates deploy/production/ for the new instance"
else
  fail "creates deploy/production/ for the new instance: $(find "$DIR/deploy" 2>&1)"
fi
if grep -qF 'name: "Acme"' "$DIR/deploy/production/config/margince.yaml"; then
  ok "deploy/production/config/margince.yaml's workspace name is this instance's display_name"
else
  fail "deploy/production/config/margince.yaml's workspace name is this instance's display_name: $(cat "$DIR/deploy/production/config/margince.yaml")"
fi
if grep -qx 'HOST_SSH=' "$DIR/deploy/production/host.env" && grep -qx 'HOST_DOMAIN=' "$DIR/deploy/production/host.env"; then
  ok "no DOMAIN/SSH given: deploy/production/host.env has the empty placeholders"
else
  fail "no DOMAIN/SSH given: deploy/production/host.env has the empty placeholders: $(cat "$DIR/deploy/production/host.env")"
fi
if [ "$(git -C "$DIR/core" describe --tags --exact-match 2>/dev/null)" = "v0.0.2" ]; then ok "checks out core at the pinned tag"; else fail "checks out core at the pinned tag"; fi
if [ -z "$(git -C "$DIR" status --porcelain)" ]; then ok "commits everything"; else fail "commits everything"; fi
if bash "$DIR/scripts/check-template.sh" >/dev/null 2>&1; then ok "the new instance passes check-template"; else fail "the new instance passes check-template"; fi
if (cd "$DIR/scripts/cli" && GOWORK=off go run . check -file "$DIR/instance.yaml" -core "$DIR/core" >/dev/null 2>&1); then ok "the new instance passes check-instance"; else fail "the new instance passes check-instance"; fi

# --- DOMAIN, SSH and ADMIN_EMAIL, when given, land in deploy/production/ ---
DIR9="$TMP/margince-withdeploy"
if out="$(create NAME=withdeploy DISPLAY_NAME=WithDeploy DIR="$DIR9" DOMAIN=crm.example.test SSH=deploy@203.0.113.10 ADMIN_EMAIL=ops@acme.test 2>&1)"; then
  ok "creates an instance with DOMAIN, SSH and ADMIN_EMAIL"
else
  fail "creates an instance with DOMAIN, SSH and ADMIN_EMAIL: $out"
fi
if grep -qx 'HOST_SSH=deploy@203.0.113.10' "$DIR9/deploy/production/host.env" \
  && grep -qx 'HOST_DOMAIN=crm.example.test' "$DIR9/deploy/production/host.env"; then
  ok "deploy/production/host.env holds the given HOST_SSH and HOST_DOMAIN"
else
  fail "deploy/production/host.env holds the given HOST_SSH and HOST_DOMAIN: $(cat "$DIR9/deploy/production/host.env")"
fi
if grep -qF 'email: "ops@acme.test"' "$DIR9/deploy/production/config/margince.yaml"; then
  ok "deploy/production/config/margince.yaml holds the given ADMIN_EMAIL"
else
  fail "deploy/production/config/margince.yaml holds the given ADMIN_EMAIL: $(cat "$DIR9/deploy/production/config/margince.yaml")"
fi
if grep -qF 'name: "WithDeploy"' "$DIR9/deploy/production/config/margince.yaml"; then
  ok "deploy/production/config/margince.yaml's workspace name is this instance's display_name"
else
  fail "deploy/production/config/margince.yaml's workspace name is this instance's display_name: $(cat "$DIR9/deploy/production/config/margince.yaml")"
fi
if [ "$(cli_get "$DIR9" deploy.production.adapter)" = "host" ]; then
  ok "with DOMAIN/SSH/ADMIN_EMAIL given: instance.yaml still has deploy.production.adapter: host"
else
  fail "with DOMAIN/SSH/ADMIN_EMAIL given: instance.yaml still has deploy.production.adapter: host"
fi
if (cd "$DIR9/scripts/cli" && GOWORK=off go run . check -file "$DIR9/instance.yaml" -core "$DIR9/core" >/dev/null 2>&1); then
  ok "the new instance with DOMAIN/SSH/ADMIN_EMAIL passes check-instance"
else
  fail "the new instance with DOMAIN/SSH/ADMIN_EMAIL passes check-instance"
fi
if [ -z "$(git -C "$DIR9" status --porcelain)" ]; then ok "commits deploy/ along with instance.yaml"; else fail "commits deploy/ along with instance.yaml: $(git -C "$DIR9" status --porcelain)"; fi

# --- an exported/command-line ADAPTER cannot change the default deploy/production adapter ---
# new-instance.sh's own deploy-init call must pass ADAPTER=host explicitly:
# scripts/deploy-init.sh defaults ADAPTER to host only when ADAPTER is unset,
# so an ADAPTER a caller's environment already exports (or passes on the
# command line here) would otherwise silently scaffold deploy/production/ as
# the hook adapter instead.
DIR10="$TMP/margince-adapterhook"
if out="$(create NAME=adapterhook DISPLAY_NAME=AdapterHook DIR="$DIR10" ADAPTER=hook 2>&1)"; then
  ok "creates an instance with ADAPTER=hook exported"
else
  fail "creates an instance with ADAPTER=hook exported: $out"
fi
if [ "$(cli_get "$DIR10" deploy.production.adapter)" = "host" ]; then
  ok "an exported ADAPTER does not change deploy.production.adapter away from host"
else
  fail "an exported ADAPTER does not change deploy.production.adapter away from host: $(cat "$DIR10/instance.yaml")"
fi
if [ -f "$DIR10/deploy/production/host.env" ]; then
  ok "an exported ADAPTER does not change deploy/production/ away from the host adapter's files"
else
  fail "an exported ADAPTER does not change deploy/production/ away from the host adapter's files: $(find "$DIR10/deploy" 2>&1)"
fi

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

# --- make new-instance passes shell-special characters through untouched ---
# The recipe once wrapped each variable in double quotes, so `"` ended the
# string, a backtick ran a command and $5 expanded. Run the real target.
DIR6="$TMP/margince-acme-make"
special_make='Acme "EU" `x` $5'
if out="$(make -s -C "$TPL" new-instance NAME=acme-make DISPLAY_NAME="$special_make" DIR="$DIR6" 2>&1)"; then
  got="$(cli_get "$DIR6" display_name 2>&1)"
  if [ "$got" = "$special_make" ]; then
    ok "make new-instance passes a display name with \", \` and \$ through exactly"
  else
    fail "make new-instance passes a display name with \", \` and \$ through exactly: got $got"
  fi
else
  fail "make new-instance passes a display name with \", \` and \$ through exactly: $out"
fi
DIR7="$TMP/margince-acme-apos"
special_apos="Acme's Client"
if out="$(make -s -C "$TPL" new-instance NAME=acme-apos DISPLAY_NAME="$special_apos" DIR="$DIR7" 2>&1)" \
  && [ "$(cli_get "$DIR7" display_name 2>&1)" = "$special_apos" ]; then
  ok "make new-instance passes a display name with a single quote through exactly"
else
  fail "make new-instance passes a display name with a single quote through exactly: $out"
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
expect_refused "refuses PUSH=1 without OWNER" "$TMP/x6" NAME=needsowner DISPLAY_NAME=X PUSH=1
out="$(create NAME=needsowner DISPLAY_NAME=X DIR="$TMP/x6b" PUSH=1 2>&1)" && rc=0 || rc=$?
if [ "$rc" -ne 0 ] && printf '%s\n' "$out" | grep -qxF "error: new-instance: PUSH=1 needs OWNER=<github owner>"; then
  ok "PUSH=1 without OWNER fails with the exact message"
else
  fail "PUSH=1 without OWNER fails with the exact message: rc=$rc out=$out"
fi

# --- PUSH=1 with OWNER reaches the stub gh, not the real one ---
DIR8="$TMP/margince-pushed"
out="$(create NAME=pushed DISPLAY_NAME=Pushed DIR="$DIR8" PUSH=1 OWNER=acme-org 2>&1)"
if printf '%s\n' "$out" | grep -qF "stub gh: repo create acme-org/margince-pushed"; then
  ok "PUSH=1 with OWNER invokes gh repo create <OWNER>/margince-<NAME>"
else
  fail "PUSH=1 with OWNER invokes gh repo create <OWNER>/margince-<NAME>: $out"
fi
unset OWNER

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
