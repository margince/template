# Shared helpers for this installation's mono-repo lanes. Sourced, never executed.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE="$ROOT/core"
SRC_EXT="$ROOT/extensions"
CORE_EXT="$CORE/extensions"

# The staging marker. It records exactly which unit directories this repo
# copied into the submodule, so unstaging removes ours and never an
# upstream-owned one. Kept inside the submodule's git dir rather than the
# work tree: it is machine state, not source, and it must not become a
# staged file itself.
marker_file() {
  printf '%s/staged-units\n' "$(git -C "$CORE" rev-parse --git-dir)"
}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

require_core() {
  [ -f "$CORE/go.work" ] || die "core/ is not checked out — run 'make init' (git submodule update --init)"
}

# Every unit directory this repo owns, one per line, sorted.
source_units() {
  [ -d "$SRC_EXT" ] || return 0
  find "$SRC_EXT" -mindepth 1 -maxdepth 1 -type d -exec basename {} \; | sort
}

# instance_get <key> — one value from instance.yaml.
#
# Read through the template CLI so there is one parser. GOWORK=off because the
# editor go.work at the repository root does not list scripts/cli.
# INSTANCE_FILE overrides the file, for tests.
instance_get() {
  (cd "$ROOT/scripts/cli" && GOWORK=off go run . get -file "${INSTANCE_FILE:-$ROOT/instance.yaml}" "$1")
}

# The managed block in the submodule's info/exclude. Staged units are untracked
# content in core/, which would otherwise make this repo report the submodule as
# dirty on every build and train everyone to ignore that signal.
#
# Split out of stage.sh and given a clear() half because stage.sh originally
# wrote this block and NOTHING removed it: unstage deleted the directories and
# the marker but left the rules, so a path stayed hidden in the submodule long
# after the unit that justified hiding it was gone.
EXCLUDE_BEGIN='# BEGIN staged units (managed by scripts/stage.sh)'
EXCLUDE_END='# END staged units'

# exclude_block_write <exclude_file> <unit>...
exclude_block_write() {
  local file="$1"; shift
  mkdir -p "$(dirname "$file")"
  local tmp; tmp="$(mktemp)"
  exclude_block_strip "$file" > "$tmp"
  {
    cat "$tmp"
    printf '%s\n' "$EXCLUDE_BEGIN"
    local unit
    for unit in "$@"; do
      [ -n "$unit" ] && printf '/extensions/%s/\n' "$unit"
    done
    printf '%s\n' "$EXCLUDE_END"
  } > "$file"
  rm -f "$tmp"
}

# exclude_block_clear <exclude_file>
exclude_block_clear() {
  local file="$1"
  [ -f "$file" ] || return 0
  local tmp; tmp="$(mktemp)"
  exclude_block_strip "$file" > "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

# exclude_block_strip <file> — the file's content with the managed block removed,
# on stdout. Absent file yields nothing.
exclude_block_strip() {
  local file="$1"
  [ -f "$file" ] || return 0
  awk -v b="$EXCLUDE_BEGIN" -v e="$EXCLUDE_END" '
    $0 == b {skip=1; next} $0 == e {skip=0; next} !skip {print}
  ' "$file"
}

# copy_unit_tree <src_dir> <dest_dir>
#
# tar rather than cp: a unit's frontend/ holds an installed node_modules (and,
# under pnpm, symlinks into a store that does not exist inside the submodule),
# and staging it would put a dependency tree where the composer,
# check-ext-imports and the vitest globs all walk. Both BSD and GNU tar support
# --exclude; cp supports no exclusion at all.
#
# The destination is REPLACED, not merged: a file deleted at the source must
# disappear from the staged copy, or a removal silently fails to take effect.
copy_unit_tree() {
  local src="$1" dest="$2"
  [ -d "$src" ] || die "copy_unit_tree: $src is not a directory"
  [ -n "$dest" ] || die "copy_unit_tree: no destination"
  rm -rf "${dest:?}"
  mkdir -p "$dest"
  # Both sides made ABSOLUTE before either cd. The copy below cds into src, so a
  # RELATIVE dest would resolve against src rather than the caller's directory —
  # which fails loudly here ("no such file or directory") but only because the
  # pipeline is guarded; it is exactly the kind of path bug that reads as a tar
  # problem. Callers pass relative paths (the units-out-of-core plan does, twice).
  src="$(cd "$src" && pwd)"
  dest="$(cd "$dest" && pwd)"
  # pipefail INSIDE the function: a caller that sources lib.sh interactively has
  # none, and a failing `tar cf` masked by a succeeding `tar xf` yields a
  # SILENTLY PARTIAL copy — from the helper Task 9's point-of-no-return copy uses.
  ( set -o pipefail
    cd "$src" && tar cf - --exclude='node_modules' . | ( cd "$dest" && tar xf - )
  ) || die "copy_unit_tree: copying $src -> $dest failed"
}

# assert_core_clean <repo_dir> <marker_file>
#
# Staging deletes and recopies each unit unconditionally, so an edit inside a
# staged copy is lost on the next compose WITHOUT A WARNING. That was harmless
# while nothing in core/ was ever edited by hand. It stops being harmless the
# moment anyone works inside the submodule, so refuse rather than destroy.
#
# Only MODIFIED TRACKED files are a refusal. Untracked staged copies from a
# previous run are the normal steady state.
assert_core_clean() {
  local repo="$1" marker="$2"
  [ "${MARGINCE_ALLOW_DIRTY_CORE:-}" = "1" ] && return 0
  # --untracked-files=all, NOT =no. With =no this would ignore every untracked
  # path — including an unexpected core/extensions/<other-unit>/, which the
  # composer would enable, since presence under extensions/ IS enablement. So
  # look at everything, then subtract only the staged copies the marker accounts
  # for. (The first draft used =no and never read `marker` at all.)
  local dirty="" line path unit
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    path="${line:3}"
    if [ "${line:0:2}" = "??" ] && [ -f "$marker" ]; then
      unit="${path#extensions/}"; unit="${unit%%/*}"
      if [ "$path" != "$unit" ] && grep -qxF "$unit" "$marker" 2>/dev/null; then
        continue
      fi
    fi
    dirty="$dirty$line
"
  done <<EOF
$(git -C "$repo" status --porcelain --untracked-files=all)
EOF
  [ -z "$dirty" ] && return 0
  printf 'error: %s has modified tracked files, and staging would overwrite work in it:\n' "$repo" >&2
  printf '%s\n' "$dirty" >&2
  printf '\nCommit or discard them first. A staged copy is scratch: the next\n' >&2
  printf 'compose replaces it, so an edit made inside core/extensions/<unit>/ is\n' >&2
  printf 'lost. The source of truth is extensions/<unit>/ in this repo.\n' >&2
  printf '\nIf you are deliberately working inside the submodule (see the plan for\n' >&2
  printf 'moving units out of core), re-run with MARGINCE_ALLOW_DIRTY_CORE=1.\n' >&2
  exit 1
}

# rewrite_staged_paths — a stdin/stdout filter mapping core/extensions/<ours>/…
# back to extensions/<ours>/….
#
# A composed lane reports a path inside the SUBMODULE, which for our units is a
# scratch copy: the developer is forbidden to edit it and the next compose
# overwrites it. Sending them there is the single most confusing thing about
# working downstream. stage.sh already follows this philosophy by catching the
# name grammar before the composer can produce a worse message.
#
# ABSOLUTE paths only, and that is the whole target rather than a limitation. The
# delegating lanes run as `make -C core …`, so a gate's cwd is core/ and it
# prints CORE-RELATIVE paths (extensions/acme-sync/send.go) — which already resolve
# to our source when read from the repository root, and must be left alone. What
# misleads is Go's toolchain, which prints absolute paths into the submodule.
#
# Only OUR units are rewritten. An upstream unit's path must stay pointing into
# core/, or we would send someone looking for a file this repo does not have.
rewrite_staged_paths() {
  local units unit
  units="$(source_units)"
  if [ -z "$units" ]; then cat; return 0; fi
  # An ARRAY, not a string. Unquoted `sed $expr` relies on word splitting, which
  # breaks the moment a path contains a space.
  local args=()
  while IFS= read -r unit; do
    [ -n "$unit" ] || continue
    args+=(-e "s|$CORE/extensions/$unit/|$ROOT/extensions/$unit/|g")
  done <<EOF
$units
EOF
  if [ ${#args[@]} -eq 0 ]; then cat; return 0; fi
  sed "${args[@]}"
}

# rewrite_file_in_place <file> <sed-expr>...
#
# `sed -i` has no portable spelling: BSD sed requires a backup-suffix argument
# and GNU sed refuses one, so `sed -i ''` works only on macOS and `sed -i`
# works only on GNU. new-unit.sh shipped the BSD form, which made the
# scaffolder — step one of the first journey a contributor takes — fail on
# every Linux box and devcontainer.
#
# The output is written back with `cat`, not `mv`: mv would replace the file
# with mktemp's 0600 and drop its mode, which silently strips the executable
# bit off anything a caller scaffolds.
rewrite_file_in_place() {
  local file="$1"; shift
  [ -f "$file" ] || die "rewrite_file_in_place: no such file: $file"
  [ "$#" -gt 0 ] || return 0
  local args=() expr
  for expr in "$@"; do args+=(-e "$expr"); done
  local tmp; tmp="$(mktemp)"
  if ! sed "${args[@]}" "$file" > "$tmp"; then
    rm -f "$tmp"
    die "rewrite_file_in_place: sed failed on $file"
  fi
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

# dataset_path [given] — the demo dataset checkout.
#
# core computes its own default from `git rev-parse --git-common-dir`, which
# for a submodule is <instance>/.git/modules/core. Its default therefore
# resolves to <instance>/.git/modules/margince-demo-database: a path inside a
# git directory that can never exist, behind an error message telling you to
# clone "beside this repo". Computing it from the INSTANCE root instead is what
# core means, spelled where the submodule cannot distort it.
#
# The variable stays DATASET, exactly as core spells it. A richer contract (a
# URL, a clone-on-demand) belongs in core first and is inherited here.
# ALWAYS absolute, whether the path exists yet or not. Two callers depend on
# that and would disagree otherwise: the guard in the seed-demo lane resolves a
# relative path from the instance root, while the delegation beneath it runs
# `make -C core` and would resolve the same string from core/. A dataset that
# has not been cloned yet is exactly when a developer types a relative path, so
# "absolute only if it exists" is absolute precisely when it is not needed.
dataset_path() {
  local given="${1:-}"
  if [ -z "$given" ]; then
    printf '%s/margince-demo-database\n' "$(cd "$ROOT/.." && pwd)"
    return 0
  fi
  case "$given" in
    # POSIX absolute, and the Windows spelling of one. MSYS2 bash accepts
    # `D:/a/...` and does not start it with a slash, so the relative arm below
    # turned it into <pwd>/D:/a/... — a path that cannot exist, reported by
    # everything downstream as "no dataset reachable". That cost a release
    # build on the Windows lane.
    /* | [A-Za-z]:/* | [A-Za-z]:\\*) printf '%s\n' "$given" ;;
    *)  printf '%s/%s\n' "$(pwd)" "$given" ;;
  esac
}
