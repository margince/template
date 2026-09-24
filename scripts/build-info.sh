#!/usr/bin/env bash
# build-info.sh — record what went into a built desktop folder, inside it.
#
# The zip name was the only place a build's identity lived, and a zip name does
# not survive being unzipped. A user reporting a bug from an installed folder
# could say "the desktop app"; nothing in the folder could say which one, which
# upstream it carried, or which of our units were composed into it.
#
# Two files, because two readers:
#
#   BUILD-INFO.txt        a person, asked to paste it into a bug report
#   runtime/build-info.json  a program (nothing reads it yet — see below)
#
# The JSON is written now rather than when a reader appears, because the folder
# it describes is built on two platforms by two lanes and shipped to people who
# cannot rebuild it. A field added later is absent from every copy already in
# the field, and those are exactly the copies a support question comes from.
#
# WHERE these land is not cosmetic. desktop-distribution.md fixes the update
# contract: an update replaces the launcher, the starter and runtime/, and
# nothing else. So the JSON goes in runtime/, where the copy-over gesture
# refreshes it. BUILD-INFO.txt sits at the root beside README.md, which the kit
# already ships and cmd_install already lists as replaceable — the same
# precedent, not a new rule. A build-info file that survives an update is worse
# than none: it would name the version the user no longer runs.
#
# Usage: build-info.sh --dir <folder> --os <darwin|windows> [--version <v>]
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=scripts/lib.sh
. scripts/lib.sh

usage() {
  cat >&2 <<'EOF'
usage: build-info.sh --dir <folder> --os <darwin|windows> [--version <v>]
       build-info.sh --print-version [--version <v>]

  --dir            a built desktop folder (the one with runtime/ in it)
  --os             which platform the folder is FOR, not which one is stamping it
  --version        the release version. Defaults to `git describe`, then dev-<sha>.
  --seeded         the folder carries demo data, so an unrecorded dataset commit
                   is reported as `unknown` rather than `none`.
  --print-version  resolve the version, print it, stamp nothing.

  MARGINCE_BUILD_DATASET_SHA names the demo-database commit the folder was
  seeded from. Only the lane that cloned it can know, so only the lane sets it.
EOF
  exit 2
}

# resolve_version — what this build calls itself.
#
# Three sources in falling order of authority: what a release lane was told, what
# the tags say, and the commit. CI always passes --version, so the fallbacks are
# for a developer's own `make desktop` — where `git describe` on a checkout with
# no tags fetched fails, which is why there is a third.
#
# --match 'v*' restricts it to VERSION tags. Without it the nearest tag of any
# shape wins, and a repository accumulates tags that name no version at all. A
# local build would then name itself after a string chosen for somebody's
# convenience, and report it in BUILD-INFO.txt as though it were a version.
resolve_version() {
  local given="${1:-}"
  if [ -n "$given" ]; then printf '%s\n' "$given"; return 0; fi
  local described
  if described="$(git describe --tags --match 'v*' --dirty 2>/dev/null)" && [ -n "$described" ]; then
    printf '%s\n' "$described"; return 0
  fi
  printf 'dev-%s\n' "$(repo_sha)"
}

# short_sha <repo> [git-diff-args...] — seven characters, with -dirty when
# tracked files differ.
#
# The suffix is the point: a bundle built from an uncommitted tree is not
# identified by its commit, and saying so here is cheaper than discovering it
# from a bug report that does not reproduce. Which is exactly why the two
# callers below measure it differently — a marker that fires on every build
# says nothing.
short_sha() {
  local repo="$1"; shift
  local sha
  sha="$(git -C "$repo" rev-parse --short=7 HEAD 2>/dev/null)" || { printf 'unknown\n'; return 0; }
  if ! git -C "$repo" diff --quiet HEAD "$@" 2>/dev/null; then sha="$sha-dirty"; fi
  printf '%s\n' "$sha"
}

# repo_sha — this installation's commit.
#
# --ignore-submodules, because git reports a MODIFIED SUBMODULE as a change to
# the parent's gitlink. Without it, anything that touches core/ marks this
# repository dirty — and core's own commit is reported separately, with its own
# marker, one line below. The parent's suffix is meant to answer "were this
# repo's sources uncommitted", and the submodule is not this repo's sources.
repo_sha() {
  if [ -n "${MARGINCE_BUILD_REPO_SHA:-}" ]; then
    printf '%s\n' "$MARGINCE_BUILD_REPO_SHA"; return 0
  fi
  short_sha "$ROOT" --ignore-submodules
}

# core_sha — the pinned upstream commit.
#
# Overridable, because one lane cannot measure this honestly by the time it
# runs. The Windows build regenerates the manifests of CORE'S OWN units as a
# side effect (desktop-windows.yml says so at length), so core/ is dirty
# before the kit is reached — on every Windows build, for a reason that has
# nothing to do with the sources the bundle was built from. That lane measures
# both commits at checkout and passes them in; a marker that is always set is
# one nobody reads.
core_sha() {
  if [ -n "${MARGINCE_BUILD_CORE_SHA:-}" ]; then
    printf '%s\n' "$MARGINCE_BUILD_CORE_SHA"; return 0
  fi
  short_sha "$CORE"
}

# dataset_sha <seeded> — which commit of the demo database this folder was
# filled from, when it was filled from one at all.
#
# ENV-ONLY, with no measurement to fall back on, and that is the honest shape
# rather than a shortcut. The dataset is not a checkout this script can find: it
# is a separate private repository that a release lane clones to a path of its
# own choosing, and by the time the kit re-stamps a SEEDED folder the data is
# inside a Postgres cluster, where no commit is recoverable. Only the lane that
# cloned it knows, so only the lane can say.
#
# The two blank answers are deliberately different words, because they are
# different facts and a reader has to be able to tell them apart:
#
#   none      this folder ships no demo data — nothing to identify
#   unknown   it ships demo data whose provenance was not recorded
#
# `unknown` is the one that should prompt a question. It means a seeded bundle
# was built by something that did not pass the sha — a lane that has drifted from
# this contract — and reporting it as `none` would hide exactly that.
#
# It matters more here than a pinned dependency would, because the dataset is
# deliberately NOT pinned: both desktop lanes check it out with no ref, so every
# build takes whatever its default branch was at that moment. Recording the sha
# is therefore the only thing that can ever say which demo data a bundle holds.
dataset_sha() {
  local seeded="${1:-no}"
  if [ -n "${MARGINCE_BUILD_DATASET_SHA:-}" ]; then
    printf '%s\n' "$MARGINCE_BUILD_DATASET_SHA"; return 0
  fi
  if [ "$seeded" = yes ]; then printf 'unknown\n'; return 0; fi
  printf 'none\n'
}

# target_platform <os> — what the FOLDER runs on, not what stamped it.
#
# Windows is hardcoded x64 deliberately. `make desktop-win-kit DIR=` is
# documented as runnable from macOS against a folder built on a Windows host, so
# `uname -m` here would report the stamping Mac and write arm64 into a bundle
# that is amd64. There is no ARM Windows build (desktop-distribution.md, "one
# architecture per build"), so the constant is true where the reading is not.
target_platform() {
  case "$1" in
    windows) printf 'windows/amd64\n' ;;
    darwin)
      local m; m="$(uname -m)"
      case "$m" in
        arm64|aarch64) printf 'darwin/arm64\n' ;;
        x86_64|amd64)  printf 'darwin/amd64\n' ;;
        *)             printf 'darwin/%s\n' "$m" ;;
      esac
      ;;
    *) die "build-info: unknown target os: $1" ;;
  esac
}

# manifest_version <unit> — a unit's version from its generated manifest.
#
# Parsed with sed rather than jq: no lane here has jq, including the MSYS2 shell
# the Windows lane stamps from. The file is generated by core's gen-composition
# with a fixed shape, so the grammar this matches is one our own tool emits.
manifest_version() {
  local file="$SRC_EXT/$1/manifest.generated.json" v=""
  [ -f "$file" ] || { printf 'unknown\n'; return 0; }
  v="$(sed -n 's/.*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$file" | head -1)"
  printf '%s\n' "${v:-unknown}"
}

# The unit set is read from extensions/, which `make desktop` stages in full
# before any of this runs — so the source list and the composed list are the same
# list. The repo commit beside it pins which version of that list this was.
write_json() {
  local dir="$1" version="$2" built="$3" platform="$4" repo="$5" core="$6" dataset="$7"
  local out="$dir/runtime/build-info.json" unit first=1
  {
    printf '{\n'
    printf '  "version": "%s",\n'  "$version"
    printf '  "built_at": "%s",\n' "$built"
    printf '  "platform": "%s",\n' "$platform"
    printf '  "repo": "%s",\n'     "$repo"
    printf '  "core": "%s",\n'     "$core"
    printf '  "dataset": "%s",\n'  "$dataset"
    printf '  "units": [\n'
    while IFS= read -r unit; do
      [ -n "$unit" ] || continue
      [ "$first" = 1 ] || printf ',\n'
      first=0
      printf '    {"name": "%s", "version": "%s"}' "$unit" "$(manifest_version "$unit")"
    done <<EOF
$(source_units)
EOF
    [ "$first" = 1 ] || printf '\n'
    printf '  ]\n'
    printf '}\n'
  } > "$out"
}

write_text() {
  local dir="$1" version="$2" built="$3" platform="$4" repo="$5" core="$6" dataset="$7"
  local out="$dir/BUILD-INFO.txt" unit width=0

  # One pass to measure, one to print: the unit column is aligned so a reader
  # can scan versions down it, and the widest name decides the width.
  while IFS= read -r unit; do
    [ ${#unit} -gt "$width" ] && width=${#unit}
  done <<EOF
$(source_units)
EOF

  {
    printf 'Margince %s\n\n' "$version"
    printf '  built     %s\n' "$built"
    printf '  platform  %s\n' "$platform"
    printf '  repo      %s\n' "$repo"
    printf '  core      %s\n'   "$core"
    printf '  dataset   %s\n\n' "$dataset"
    printf '  units\n'
    while IFS= read -r unit; do
      [ -n "$unit" ] || continue
      printf '    %-*s  %s\n' "$width" "$unit" "$(manifest_version "$unit")"
    done <<EOF
$(source_units)
EOF
    cat <<'NOTE'

Quote the version above in a bug report. The commits identify the exact sources
this folder was built from: "repo" is the Gradion installation, "core" is the
upstream Margince it carries, and "dataset" is the demo database it was filled
from -- "none" if it ships no demo data at all.

This file is replaced when the folder is updated. Your data, settings and
demo database are not.
NOTE
  } > "$out"
}

main() {
  local dir="" goos="" version="" print_only=no seeded=no
  while [ $# -gt 0 ]; do
    case "$1" in
      --dir)     [ $# -ge 2 ] || usage; dir="$2"; shift 2 ;;
      --os)      [ $# -ge 2 ] || usage; goos="$2"; shift 2 ;;
      --version) [ $# -ge 2 ] || usage; version="$2"; shift 2 ;;
      --seeded)  seeded=yes; shift ;;
      --print-version) print_only=yes; shift ;;
      *)         usage ;;
    esac
  done

  # The resolver, on its own. cmd_kit needs the version BEFORE it stamps —
  # the folder README carries it too — and asking for it here means the README
  # and BUILD-INFO.txt cannot disagree, which two independent resolutions of
  # `git describe` across a midnight boundary otherwise could.
  if [ "$print_only" = yes ]; then
    resolve_version "$version"
    return 0
  fi
  [ -n "$dir" ]  || die "build-info: --dir is required"
  [ -n "$goos" ] || die "build-info: --os is required (darwin or windows)"
  [ -d "$dir" ]  || die "build-info: no folder at $dir"
  [ -d "$dir/runtime" ] || die "build-info: $dir has no runtime/ — that is not a built desktop folder"

  local resolved built platform repo core dataset
  resolved="$(resolve_version "$version")"
  built="$(date -u +%Y-%m-%dT%H:%MZ)"
  platform="$(target_platform "$goos")"
  repo="$(repo_sha)"
  core="$(core_sha)"
  dataset="$(dataset_sha "$seeded")"

  write_json "$dir" "$resolved" "$built" "$platform" "$repo" "$core" "$dataset"
  write_text "$dir" "$resolved" "$built" "$platform" "$repo" "$core" "$dataset"
  printf 'build-info: %s (%s) — repo %s, core %s, dataset %s\n' \
    "$resolved" "$platform" "$repo" "$core" "$dataset"
}

main "$@"
