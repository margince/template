#!/usr/bin/env bash
# template-sync.sh — merge margince-template into this instance and record it.
#
# Template changes reach an instance by merge (design Section 4). After the
# merge, .template-version names the merged template commit, which is what
# make check-template compares the template-owned paths with.
#
# The instance keeps its own core pin: the template's core gitlink is not
# merged in. core moves only through make update-core.
#
# Conflicts are resolved by ownership (design Section 6):
#   - instance-owned paths keep the instance's side;
#   - paths matched by the TARGET's .template-owned take the template's side;
#   - any other conflicted path stops the sync with the merge in progress.
#
# Usage: bash scripts/template-sync.sh   (or: make template-sync)
#   TEMPLATE_REMOTE (default template), TEMPLATE_BRANCH (default main)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$ROOT"

remote="${TEMPLATE_REMOTE:-template}"
branch="${TEMPLATE_BRANCH:-main}"

[ -f .template-version ] || die "template-sync: no .template-version — run this in an instance, not in the template"
git remote get-url "$remote" >/dev/null 2>&1 \
  || die "template-sync: no git remote '$remote'. Add it: git remote add $remote git@github.com:gradionhq/margince-template.git"
[ -z "$(git status --porcelain)" ] || die "template-sync: commit or discard local changes first"

git fetch --quiet "$remote" "$branch"
target="$(git rev-parse FETCH_HEAD)"
pre="$(git rev-parse HEAD)"
old="$(tr -d '[:space:]' < .template-version)"

record() {
  printf '%s\n' "$target" > .template-version
  git add .template-version
}

# core_tag_in <commit> — the core: value recorded in that commit's instance.yaml.
core_tag_in() {
  git show "$1:instance.yaml" 2>/dev/null | sed -n 's/^core:[[:space:]]*//p' | head -n 1
}

# is_instance_owned <path> — design Section 6.
is_instance_owned() {
  case "$1" in
    instance.yaml|instance.mk|README.md|.template-version) return 0 ;;
    extensions/*|config/*|data/*|deploy/*|docs/client/*) return 0 ;;
  esac
  return 1
}

# take_side <ours|theirs> <path> — resolve one conflicted path to one side. A
# side that deleted the path resolves to the deletion.
take_side() {
  local side="$1" path="$2" stage=2
  [ "$side" = "theirs" ] && stage=3
  if git cat-file -e ":$stage:$path" 2>/dev/null; then
    git checkout "--$side" -- "$path"
    git add -- "$path"
  else
    git rm --quiet --cached -f -- "$path"
    rm -f -- "$path"
  fi
}

set +e
merge_out="$(git merge --no-commit --no-ff "$target" 2>&1)"
set -e

if ! git rev-parse -q --verify MERGE_HEAD >/dev/null; then
  git merge-base --is-ancestor "$target" HEAD \
    || die "template-sync: git merge failed:
$merge_out"
  # Nothing to merge. Record the commit if .template-version lags behind.
  record
  if git diff --cached --quiet; then
    echo "template-sync: already at template commit ${target:0:12}"
  else
    git commit --quiet -m "chore: record template commit ${target:0:12}"
    echo "template-sync: recorded template commit ${target:0:12}"
  fi
  exit 0
fi

# Keep this instance's core pin. The core/ checkout is left alone: it is
# already at the pre-merge gitlink.
if pre_core="$(git rev-parse -q --verify "$pre:core" 2>/dev/null)"; then
  git update-index --cacheinfo 160000,"$pre_core",core
  if tpl_core="$(git rev-parse -q --verify "$target:core" 2>/dev/null)" && [ "$tpl_core" != "$pre_core" ]; then
    tpl_pin="$(core_tag_in "$target")"
    [ -n "$tpl_pin" ] || tpl_pin="${tpl_core:0:12}"
    own_pin="$(core_tag_in "$pre")"
    [ -n "$own_pin" ] || own_pin="${pre_core:0:12}"
    echo "template-sync: the template pins core at $tpl_pin; this instance stays at $own_pin. Run make update-core REF=$tpl_pin to follow."
  fi
fi

# Resolve conflicts by ownership. The ownership list is the TARGET's.
owned=()
while IFS= read -r line; do
  case "$line" in ''|'#'*) continue ;; esac
  owned+=("$line")
done < <(git show "$target:.template-owned" 2>/dev/null || true)

template_conflicts=""
if [ "${#owned[@]}" -gt 0 ]; then
  template_conflicts="$(git diff --name-only --diff-filter=U -- "${owned[@]}")"
fi

unresolved=""
while IFS= read -r path; do
  [ -n "$path" ] || continue
  [ "$path" = "core" ] && continue
  if is_instance_owned "$path"; then
    take_side ours "$path"
  elif printf '%s\n' "$template_conflicts" | grep -qxF -- "$path"; then
    take_side theirs "$path"
  else
    unresolved="$unresolved  $path
"
  fi
done <<EOF
$(git diff --name-only --diff-filter=U)
EOF

if [ -n "$unresolved" ]; then
  printf 'template-sync: the merge has conflicts on paths that are neither instance-owned nor template-owned:\n%s' "$unresolved" >&2
  die "template-sync: resolve them, finish the merge with git commit, then run make template-sync again"
fi

# The template's own versions of these files are not merged over the
# instance's when they conflict; point at what changed so it can be reviewed.
if git cat-file -e "$old^{commit}" 2>/dev/null; then
  for f in instance.yaml README.md; do
    if ! git diff --quiet "$old" "$target" -- "$f"; then
      echo "template-sync: the template changed $f; review with: git diff ${old:0:12} ${target:0:12} -- $f"
    fi
  done
fi

record
git commit --quiet -m "chore: merge template ${target:0:12} and record it"
echo "template-sync: merged and recorded template commit ${target:0:12}"
