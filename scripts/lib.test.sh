#!/usr/bin/env bash
# lib.sh's file operations, proven against SYNTHETIC files rather than a real
# submodule — a gate proven only by "the tree is currently clean" is one that
# keeps passing after it stops working.
#
# Usage: bash scripts/lib.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"

# HERMETIC against the developer's git config. These suites create repositories
# and commit in them; a machine with no global user.email — every CI runner —
# fails with "empty ident name" in whichever repo the per-repo config was not
# set on. Setting it in the environment covers every repo including the ones
# `git submodule add` creates for us, which is the one this first went wrong on.
export GIT_AUTHOR_NAME="Test Dev"     GIT_AUTHOR_EMAIL="dev@example.test"
export GIT_COMMITTER_NAME="Test Dev"  GIT_COMMITTER_EMAIL="dev@example.test"
export GIT_CONFIG_NOSYSTEM=1

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILURES=0

fail() { printf 'FAIL: %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }
ok()   { printf 'ok: %s\n' "$*"; }

# NOTE: command substitution strips trailing newlines, so this cannot see a
# trailing-newline difference. Deliberate — the contract here is which LINES are
# present. The byte-level guarantee is checked by the cmp case further down.
expect_file_is() {
  local label="$1" file="$2" want="$3"
  local got; got="$(cat "$file")"
  if [ "$got" = "$want" ]; then ok "$label"; else
    fail "$label"
    printf '  want:\n%s\n  got:\n%s\n' "$want" "$got" >&2
  fi
}

# --- exclude_block_write ---

f="$TMP/exclude-new"
exclude_block_write "$f" alpha beta
expect_file_is "writes a block listing each unit" "$f" \
'# BEGIN staged units (managed by scripts/stage.sh)
/extensions/alpha/
/extensions/beta/
# END staged units'

f="$TMP/exclude-preexisting"
printf '/local-scratch/\n' > "$f"
exclude_block_write "$f" alpha
expect_file_is "preserves pre-existing content above the block" "$f" \
'/local-scratch/
# BEGIN staged units (managed by scripts/stage.sh)
/extensions/alpha/
# END staged units'

f="$TMP/exclude-rewrite"
printf '/local-scratch/\n' > "$f"
exclude_block_write "$f" alpha beta
exclude_block_write "$f" gamma
expect_file_is "a second write replaces the block rather than appending" "$f" \
'/local-scratch/
# BEGIN staged units (managed by scripts/stage.sh)
/extensions/gamma/
# END staged units'

f="$TMP/nested/dir/exclude"
exclude_block_write "$f" alpha
[ -f "$f" ] && ok "creates a missing parent directory" || fail "creates a missing parent directory"

# --- exclude_block_clear: THE BUG THIS TASK FIXES ---

f="$TMP/clear-roundtrip"
printf '/local-scratch/\n' > "$f"
exclude_block_write "$f" alpha beta
exclude_block_clear "$f"
expect_file_is "clear removes the block and leaves other content byte-identical" "$f" \
'/local-scratch/'

f="$TMP/clear-noblock"
printf '/local-scratch/\n' > "$f"
exclude_block_clear "$f"
expect_file_is "clear is a no-op when no block is present" "$f" \
'/local-scratch/'

exclude_block_clear "$TMP/does-not-exist" \
  && ok "clear exits 0 on a missing file" \
  || fail "clear exits 0 on a missing file"

# Byte-level. expect_file_is cannot prove this: command substitution strips the
# trailing newline, so a normalisation bug would pass every case above.
f="$TMP/clear-bytes"
printf '/local-scratch/\n/another/\n' > "$f"
cp "$f" "$TMP/clear-bytes.orig"
exclude_block_write "$f" alpha beta
exclude_block_clear "$f"
cmp -s "$f" "$TMP/clear-bytes.orig" \
  && ok "a write-then-clear round trip is byte-identical" \
  || fail "a write-then-clear round trip is byte-identical"

# --- copy_unit_tree ---

src="$TMP/src/probe"
mkdir -p "$src/frontend/node_modules/@margince" "$src/migrations" "$src/frontend/i18n"
printf 'package probe\n'  > "$src/probe.go"
printf '{}\n'             > "$src/frontend/package.json"
printf 'en\n'             > "$src/frontend/i18n/en.json"
printf 'CREATE TABLE x;\n'> "$src/migrations/0001_x.up.sql"
printf 'junk\n'           > "$src/frontend/node_modules/junk.js"
ln -s /nonexistent "$src/frontend/node_modules/@margince/frontend"
mkdir -p "$src/node_modules" && printf 'top\n' > "$src/node_modules/top.js"

dest="$TMP/dest/probe"
copy_unit_tree "$src" "$dest"

[ -f "$dest/probe.go" ]                  && ok "copies Go source"                  || fail "copies Go source"
[ -f "$dest/frontend/package.json" ]     && ok "copies the frontend manifest"      || fail "copies the frontend manifest"
[ -f "$dest/frontend/i18n/en.json" ]     && ok "copies the i18n layer"             || fail "copies the i18n layer"
[ -f "$dest/migrations/0001_x.up.sql" ]  && ok "copies migrations"                 || fail "copies migrations"
[ ! -e "$dest/frontend/node_modules" ]   && ok "excludes a nested node_modules"    || fail "excludes a nested node_modules"
[ ! -e "$dest/node_modules" ]            && ok "excludes a top-level node_modules" || fail "excludes a top-level node_modules"

# A second copy must replace, not merge: a file removed at the source must not
# survive in the staged copy, or a deletion silently fails to take effect.
printf 'stale\n' > "$dest/stale.go"
copy_unit_tree "$src" "$dest"
[ ! -e "$dest/stale.go" ] && ok "replaces the destination rather than merging" || fail "replaces the destination rather than merging"

# RELATIVE paths, from a directory that is neither. copy_unit_tree cds into the
# source to build the tar, so a relative destination resolved against the source
# instead of the caller — the plan's own unit-move step passes relative paths.
mkdir -p "$TMP/relcwd"
( cd "$TMP/relcwd" && copy_unit_tree ../src/probe ./reldest ) >/dev/null 2>&1   && [ -f "$TMP/relcwd/reldest/probe.go" ]   && ok "accepts relative source and destination paths"   || fail "accepts relative source and destination paths"

# --- assert_core_clean ---

make_repo() {
  local dir="$1"
  mkdir -p "$dir" && git -C "$dir" init -q
  git -C "$dir" config user.email t@t.test && git -C "$dir" config user.name t
  printf 'x\n' > "$dir/tracked.txt"
  git -C "$dir" add tracked.txt && git -C "$dir" commit -qm init
}

repo="$TMP/clean-repo"; make_repo "$repo"
marker="$TMP/marker-empty"; : > "$marker"
( assert_core_clean "$repo" "$marker" ) >/dev/null 2>&1 \
  && ok "accepts a clean repo" || fail "accepts a clean repo"

repo="$TMP/dirty-repo"; make_repo "$repo"
printf 'edited\n' > "$repo/tracked.txt"
( assert_core_clean "$repo" "$marker" ) >/dev/null 2>&1 \
  && fail "refuses a repo with modified tracked files" \
  || ok "refuses a repo with modified tracked files"

# A staged copy from a previous run is untracked and NAMED IN THE MARKER. That
# is the normal steady state, not a reason to refuse.
repo="$TMP/staged-repo"; make_repo "$repo"
mkdir -p "$repo/extensions/alpha" && printf 'y\n' > "$repo/extensions/alpha/alpha.go"
marker_alpha="$TMP/marker-alpha"; printf 'alpha\n' > "$marker_alpha"
( assert_core_clean "$repo" "$marker_alpha" ) >/dev/null 2>&1 \
  && ok "tolerates a staged copy named in the marker" \
  || fail "tolerates a staged copy named in the marker"

# The case that proves the marker is actually CONSULTED. Without it, an
# implementation ignoring all untracked files passes the case above — which is
# exactly the bug review found in this function's first draft.
repo="$TMP/unknown-untracked"; make_repo "$repo"
mkdir -p "$repo/extensions/stranger" && printf 'y\n' > "$repo/extensions/stranger/s.go"
( assert_core_clean "$repo" "$marker_alpha" ) >/dev/null 2>&1 \
  && fail "refuses an untracked unit the marker does not name" \
  || ok "refuses an untracked unit the marker does not name"

repo="$TMP/override-repo"; make_repo "$repo"
printf 'edited\n' > "$repo/tracked.txt"
( MARGINCE_ALLOW_DIRTY_CORE=1 assert_core_clean "$repo" "$marker" ) >/dev/null 2>&1 \
  && ok "the documented override permits a dirty repo" \
  || fail "the documented override permits a dirty repo"

# --- rewrite_staged_paths ---

#
# "Ours" is whatever directory exists under $SRC_EXT. The template ships with no
# units, so these cases point SRC_EXT at synthetic units and restore it after.
SAVED_SRC_EXT="$SRC_EXT"
SRC_EXT="$TMP/rewrite-src-ext"
mkdir -p "$SRC_EXT/acme-sync" "$SRC_EXT/acme-portal"

expect_rewrite() {
  local label="$1" input="$2" want="$3" got
  got="$(printf '%s\n' "$input" | rewrite_staged_paths)"
  if [ "$got" = "$want" ]; then ok "$label"; else
    fail "$label"; printf '  want: %s\n  got:  %s\n' "$want" "$got" >&2
  fi
}

expect_rewrite "rewrites an absolute staged path for one of our units" \
  "$ROOT/core/extensions/acme-sync/send.go:41: bad import" \
  "$ROOT/extensions/acme-sync/send.go:41: bad import"

expect_rewrite "rewrites an absolute staged frontend path" \
  "  --> $ROOT/core/extensions/acme-portal/frontend/screen.tsx" \
  "  --> $ROOT/extensions/acme-portal/frontend/screen.tsx"

# core's OWN units are not ours. Redirecting one would send a developer looking
# for a file this repository does not have.
expect_rewrite "leaves an upstream unit's path alone" \
  "$ROOT/core/extensions/notes/notes.go:12: oops" \
  "$ROOT/core/extensions/notes/notes.go:12: oops"

expect_rewrite "leaves unrelated core paths alone" \
  "$ROOT/core/backend/pkg/extension/extension.go:9: note" \
  "$ROOT/core/backend/pkg/extension/extension.go:9: note"

# A core-RELATIVE path already resolves to our source when read from the repo
# root, so it must be left exactly as it is. This is the case whose absence let
# the first draft of this filter pass while doing nothing.
expect_rewrite "leaves a core-relative path untouched" \
  "extensions/acme-sync/send.go:41: bad import" \
  "extensions/acme-sync/send.go:41: bad import"

# A path with a SPACE in it, which is what the args array rather than an
# unquoted expansion buys.
expect_rewrite "survives a path containing a space" \
  "$ROOT/core/extensions/acme-sync/a file.go:1: x" \
  "$ROOT/extensions/acme-sync/a file.go:1: x"

SRC_EXT="$SAVED_SRC_EXT"

# --- rewrite_file_in_place ---
#
# `sed -i` is the portability trap this helper exists for: BSD sed REQUIRES a
# backup-suffix argument and GNU sed REFUSES one, so no single `sed -i`
# spelling works on both. new-unit.sh shipped the BSD spelling, which made the
# scaffolder fail on Linux at the first step of the first journey.

f="$TMP/rewrite-basic"
printf 'package acme\nname = "acme"\n' > "$f"
rewrite_file_in_place "$f" 's|package acme|package crmsync|g' 's|"acme"|"crm-sync"|g'
expect_file_is "applies every expression in order" "$f" \
'package crmsync
name = "crm-sync"'

f="$TMP/rewrite no-match"
printf 'untouched\n' > "$f"
rewrite_file_in_place "$f" 's|absent|present|g'
expect_file_is "a non-matching expression leaves the file alone" "$f" 'untouched'

# A path with a SPACE, which is the case an unquoted expansion breaks on.
f="$TMP/a dir with spaces"
mkdir -p "$f"
printf 'old\n' > "$f/file.go"
rewrite_file_in_place "$f/file.go" 's|old|new|g'
expect_file_is "survives a path containing a space" "$f/file.go" 'new'

# The MODE must survive. `mv tmp file` would replace the file with mktemp's
# 0600, which silently strips the executable bit from a scaffolded script.
f="$TMP/rewrite-mode"
printf 'old\n' > "$f"
chmod 755 "$f"
rewrite_file_in_place "$f" 's|old|new|g'
if [ -x "$f" ]; then ok "preserves the file mode"; else fail "preserves the file mode"; fi

# No expressions at all is a no-op, not an error: a caller building an
# expression list from a loop can legitimately produce an empty one.
f="$TMP/rewrite-noexpr"
printf 'kept\n' > "$f"
rewrite_file_in_place "$f"
expect_file_is "no expressions is a no-op" "$f" 'kept'

if ( rewrite_file_in_place "$TMP/definitely-absent" 's|a|b|' ) 2>/dev/null; then
  fail "refuses a missing file"
else
  ok "refuses a missing file"
fi

# --- dataset_path ---
#
# core derives this from ITS OWN git-common-dir, which under a submodule is
# <instance>/.git/modules/core — so core's default resolves to
# <instance>/.git/modules/margince-demo-database, inside a git directory, and
# the demo seed has never been reachable downstream.

expect_eq_str() {
  local label="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then ok "$label"; else
    fail "$label"; printf '  want: %s\n  got:  %s\n' "$want" "$got" >&2
  fi
}

expect_eq_str "defaults beside this repository, not inside a git dir" \
  "$(dataset_path)" "$(cd "$ROOT/.." && pwd)/margince-demo-database"

case "$(dataset_path)" in
  *.git*) fail "the default never points inside a git directory" ;;
  *)      ok   "the default never points inside a git directory" ;;
esac

d="$TMP/given-dataset"; mkdir -p "$d"
expect_eq_str "an existing given path is passed through absolute" "$(dataset_path "$d")" "$d"

expect_eq_str "a relative given path resolves against the caller" \
  "$(cd "$TMP" && dataset_path "given-dataset")" "$d"

expect_eq_str "an absolute path that does not exist is kept as given" \
  "$(dataset_path /no/such/dataset)" "/no/such/dataset"

# A WINDOWS absolute path is absolute. MSYS2 bash accepts `D:/a/...` and does
# not start it with a slash, so the relative arm turned it into
# <pwd>/D:/a/... — a path that cannot exist. Everything downstream then
# reported "no dataset reachable", and the desktop-windows lane stamped a
# folder with no loader and failed on the seed step three lines later.
expect_eq_str "a Windows drive path is absolute, not relative" \
  "$(cd "$TMP" && dataset_path "D:/a/dataset")" "D:/a/dataset"
expect_eq_str "a Windows drive path with backslashes is absolute too" \
  "$(cd "$TMP" && dataset_path 'C:\\a\\dataset')" 'C:\\a\\dataset'

# The case the seed-demo lane depends on: a RELATIVE path to a dataset nobody
# has cloned yet must still come back absolute, because the guard resolves it
# from the instance root and the delegation beneath resolves it from core/.
expect_eq_str "a relative path that does not exist is still made absolute" \
  "$(cd "$TMP" && dataset_path "not-cloned-yet")" "$TMP/not-cloned-yet"

# --- instance_get ---

INSTANCE_FILE="$TMP/instance.yaml"
printf 'name: acme\ndisplay_name: Acme\ncore: v0.0.2\nflavor: acme/margince\n' > "$INSTANCE_FILE"
if [ "$(instance_get name)" = "acme" ]; then ok "instance_get reads a key"; else fail "instance_get reads a key"; fi
if [ "$(instance_get flavor)" = "acme/margince" ]; then ok "instance_get reads the flavor"; else fail "instance_get reads the flavor"; fi
if instance_get units >/dev/null 2>&1; then fail "instance_get refuses an unknown key"; else ok "instance_get refuses an unknown key"; fi
rc=0; instance_get units >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 2 ]; then ok "instance_get exits exactly 2 for an unknown key"; else fail "instance_get exits exactly 2 for an unknown key — exit $rc"; fi
# Under errexit, as a caller with `set -e` runs it: the exit code and the
# cli's message still come out, instead of the shell aborting inside. A
# separate bash, not a subshell: errexit is ignored inside a subshell on the
# left of ||, which would make this pass either way.
rc=0
bash -c 'set -euo pipefail; source "$1"; instance_get units >/dev/null' _ "$SCRIPT_DIR/lib.sh" 2>"$TMP/errexit.err" || rc=$?
if [ "$rc" -eq 2 ] && grep -qF 'unknown key "units"' "$TMP/errexit.err" && ! grep -q '^exit status' "$TMP/errexit.err"; then
  ok "instance_get under set -e exits 2 and replays the cli's message"
else
  fail "instance_get under set -e exits 2 and replays the cli's message — exit $rc, stderr: $(cat "$TMP/errexit.err")"
fi
rc=0; INSTANCE_FILE="$TMP/no-such-instance.yaml" instance_get name >/dev/null 2>&1 || rc=$?
if [ "$rc" -eq 1 ]; then ok "instance_get exits exactly 1 for an unreadable file"; else fail "instance_get exits exactly 1 for an unreadable file — exit $rc"; fi
unset INSTANCE_FILE

# --- image_repo ---

INSTANCE_FILE="$TMP/instance.yaml"
unset REGISTRY
if [ "$(image_repo)" = "acme/margince" ]; then ok "image_repo is the flavor without a registry"; else fail "image_repo is the flavor without a registry"; fi
if [ "$(REGISTRY=registry.example.com image_repo)" = "registry.example.com/acme/margince" ]; then ok "image_repo prefixes the registry"; else fail "image_repo prefixes the registry"; fi
if [ "$(REGISTRY=registry.example.com/ image_repo)" = "registry.example.com/acme/margince" ]; then ok "image_repo drops a trailing slash"; else fail "image_repo drops a trailing slash"; fi
unset INSTANCE_FILE

INSTANCE_FILE="$TMP/no-such-instance.yaml"
if out="$(REGISTRY=registry.example.com image_repo 2>/dev/null)"; then
  fail "image_repo fails when instance.yaml cannot be read — printed '$out'"
elif [ -n "$out" ]; then
  fail "image_repo fails when instance.yaml cannot be read — printed '$out'"
else
  ok "image_repo fails when instance.yaml cannot be read"
fi
unset INSTANCE_FILE

if [ "$FAILURES" -gt 0 ]; then
  printf '\n%s case(s) failed\n' "$FAILURES" >&2
  exit 1
fi
printf '\nall cases passed\n'
