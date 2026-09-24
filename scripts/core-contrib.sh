#!/usr/bin/env bash
# core-contrib.sh — the lanes for sending a change UP to core.
#
# This repository is built around one direction of travel: core/ is read-only,
# `update-core` pulls, CI asserts the submodule came out of a build untouched.
# But a unit is written against an extension seam, and the person who finds a
# seam missing is the person writing the unit — downstream, here. Before this
# script the only way to act on that was to edit the submodule by hand, with
# `make update-core` liable to `git checkout origin/main` straight over the
# result.
#
# The branch lives in core/ itself rather than a worktree or a sibling clone,
# because the composed installation is the reason to contribute from here at
# all: a seam change is worth making downstream precisely when `make u
# NAME=<unit>` can prove it against a real unit in the same breath.
#
# Every helper takes the repository it acts on as an argument so the tests can
# point it at a synthetic repo (core-contrib.test.sh).
set -euo pipefail

CORE_CONTRIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$CORE_CONTRIB_DIR/lib.sh"

# Never prompt. A push probe against an https remote the developer cannot write
# would otherwise sit waiting for a username, which reads as a hung lane.
export GIT_TERMINAL_PROMPT=0

# git_head_branch <repo> — the branch, or empty when detached.
git_head_branch() {
  git -C "$1" symbolic-ref --quiet --short HEAD 2>/dev/null || true
}

# git_tracked_dirty <repo> — 0 when a TRACKED file is modified.
#
# Tracked only, deliberately. core/ always carries untracked staged copies and
# untracked build output; treating those as dirty would refuse every real
# invocation, and a guard everyone overrides is not a guard.
git_tracked_dirty() {
  [ -n "$(git -C "$1" diff --name-only; git -C "$1" diff --cached --name-only)" ]
}

# git_ahead_behind <repo> <upstream> — "<behind>\t<ahead>", or empty when the
# upstream ref does not resolve.
#
# Empty means UNKNOWN, never "level". Every caller must treat it as unknown and
# refuse; see assert_core_movable, where reading it as zero-ahead was a guard
# that failed open on exactly the tree it exists to protect.
git_ahead_behind() {
  local repo="$1" upstream="$2"
  git -C "$repo" rev-parse --verify --quiet "$upstream" >/dev/null 2>&1 || return 0
  git -C "$repo" rev-list --left-right --count "$upstream...HEAD" 2>/dev/null || true
}

# submodule_pinned_sha <superproject> <path> — the commit the SUPERPROJECT
# pins, read from its tree rather than from the submodule's HEAD. The two
# differing is exactly what a contributor needs told.
submodule_pinned_sha() {
  git -C "$1" ls-tree HEAD "$2" | awk '$2 == "commit" {print $3}'
}

# pin_reachable_from <repo> <sha> <upstream> — 0 when <sha> is an ancestor of
# <upstream>, i.e. the commit is really ON upstream's history.
#
# Returns 2 for UNKNOWN: the upstream ref does not resolve, or the object is not
# present at all. Never conflated with "no" — a caller that cannot fetch must say
# it could not check, not accuse the developer of pinning a bad commit. Same
# lesson as git_ahead_behind.
pin_reachable_from() {
  local repo="$1" sha="$2" upstream="$3"
  git -C "$repo" rev-parse --verify --quiet "$upstream" >/dev/null 2>&1 || return 2
  git -C "$repo" cat-file -e "${sha}^{commit}" 2>/dev/null || return 2

  git -C "$repo" merge-base --is-ancestor "$sha" "$upstream" 2>/dev/null && return 0

  # A "no" from a SHALLOW repository is not a no. Ancestry cannot be traversed
  # past a graft boundary, so a perfectly good pin reads as unreachable. CI
  # checks submodules out at depth 1, and this gate accused its own repo of a
  # bad pointer on its first run there.
  #
  # Asked only after the negative answer, so a deep clone -- every developer
  # machine -- pays nothing and still gets a hard yes or no.
  [ "$(git -C "$repo" rev-parse --is-shallow-repository 2>/dev/null)" = true ] && return 2
  return 1
}

UPSTREAM_REMOTE="${UPSTREAM_REMOTE:-origin}"
UPSTREAM_BRANCH="${UPSTREAM_BRANCH:-main}"
UPSTREAM_REF="$UPSTREAM_REMOTE/$UPSTREAM_BRANCH"

cmd_status() {
  require_core
  local branch head pinned counts behind ahead
  branch="$(git_head_branch "$CORE")"
  head="$(git -C "$CORE" rev-parse --short HEAD)"
  pinned="$(submodule_pinned_sha "$ROOT" core)"

  printf 'core/\n'
  if [ -n "$branch" ]; then
    printf '  on branch   %s (at %s)\n' "$branch" "$head"
  else
    printf '  detached at %s\n' "$head"
  fi
  printf '  pinned      %s' "${pinned:0:12}"
  if [ -n "$pinned" ] && [ "$(git -C "$CORE" rev-parse HEAD)" != "$pinned" ]; then
    printf '  <- differs from HEAD; this repo would record a pointer move\n'
  else
    printf '  (HEAD matches)\n'
  fi

  counts="$(git_ahead_behind "$CORE" "$UPSTREAM_REF")"
  if [ -n "$counts" ]; then
    behind="$(printf '%s' "$counts" | cut -f1)"
    ahead="$(printf '%s' "$counts" | cut -f2)"
    printf '  vs %-9s %s behind, %s ahead\n' "$UPSTREAM_REF" "$behind" "$ahead"
  else
    printf '  vs %-9s unknown (run: git -C core fetch %s)\n' "$UPSTREAM_REF" "$UPSTREAM_REMOTE"
  fi

  if git_tracked_dirty "$CORE"; then
    printf '  tracked files are MODIFIED:\n'
    git -C "$CORE" diff --name-only HEAD | sed 's|^|    |'
  else
    printf '  tracked files clean\n'
  fi
}

# assert_core_movable <repo> <upstream-ref>
#
# Refuses to let a lane move core/ when doing so would destroy work. Before
# this, `make update-core` ran `git checkout -q origin/main` unconditionally:
# on a contribution branch that silently detaches, and on a detached HEAD
# carrying commits it strands them in the reflog with nothing said.
assert_core_movable() {
  local repo="$1" upstream="$2" branch counts ahead
  branch="$(git_head_branch "$repo")"
  if [ -n "$branch" ]; then
    printf 'error: core/ is on branch %s, and moving it would abandon that branch.\n' "$branch" >&2
    printf '\nFinish or park the contribution first:\n' >&2
    printf '  make core-pr             open the pull request\n' >&2
    printf '  make core-restore        return core/ to the pinned commit\n' >&2
    return 1
  fi
  if git_tracked_dirty "$repo"; then
    printf 'error: core/ has modified tracked files, and moving it would discard them:\n' >&2
    git -C "$repo" diff --name-only HEAD | sed 's|^|  |' >&2
    printf '\nCommit them on a branch (make core-branch NAME=<name>) or discard them.\n' >&2
    return 1
  fi
  # UNKNOWN refuses, and that is the point. This read used to treat an
  # unresolvable upstream as "zero ahead", so a detached HEAD carrying commits
  # sailed through whenever origin/main was not present locally — a shallow or
  # single-branch submodule clone, or an overridden UPSTREAM_REMOTE. The guard
  # then permitted precisely the loss it exists to prevent. Callers fetch first.
  counts="$(git_ahead_behind "$repo" "$upstream")"
  if [ -z "$counts" ]; then
    printf 'error: cannot tell whether core/ is ahead of %s — that ref does not resolve.\n' "$upstream" >&2
    printf '\nRefusing rather than guessing: if core/ carries commits, moving it now\n' >&2
    printf 'would strand them. Fetch it and try again:\n' >&2
    printf '  git -C core fetch %s %s\n' "$UPSTREAM_REMOTE" "$UPSTREAM_BRANCH" >&2
    return 1
  fi
  ahead="$(printf '%s' "$counts" | cut -f2)"
  if [ "$ahead" != "0" ]; then
    printf 'error: core/ is %s commit(s) ahead of %s on a detached HEAD.\n' "$ahead" "$upstream" >&2
    printf '\nThose commits are reachable by nothing but the reflog. Give them a name\n' >&2
    printf 'before moving: git -C core branch <name>\n' >&2
    return 1
  fi
  return 0
}

cmd_guard_update() {
  require_core
  # Fetch BEFORE judging. The guard reads how far core/ is from the upstream
  # ref, and update-core used to fetch afterwards — so the verdict was formed
  # against a stale (or absent) origin/main and could permit a move that
  # abandoned commits, or refuse one that was fine.
  git -C "$CORE" fetch "$UPSTREAM_REMOTE" "$UPSTREAM_BRANCH" --tags
  assert_core_movable "$CORE" "$UPSTREAM_REF"
}

# core_branch_name_ok <name> — upstream's own branch shape, `type/slug`.
#
# Enforced here rather than left to review: origin already carries
# chore/craft-strict and fix/composed-workspace-install-is-not-frozen, and a
# rename after the PR is open costs a force-push and a stale review link.
core_branch_name_ok() {
  printf '%s' "${1:-}" | grep -Eq '^(feat|fix|chore|docs|refactor|test|perf)/[a-z0-9]+(-[a-z0-9]+)*$'
}

cmd_branch() {
  require_core
  local name="${1:-}"
  [ -n "$name" ] || die "core-branch: pass NAME=<type>/<slug>, e.g. make core-branch NAME=feat/ext-seam"
  core_branch_name_ok "$name" \
    || die "core-branch: '$name' must be <type>/<slug> — type one of feat|fix|chore|docs|refactor|test|perf, slug lower-case words joined by single hyphens"

  # The same guard update-core uses: starting a branch moves HEAD, so it can
  # destroy exactly what update-core can.
  assert_core_movable "$CORE" "$UPSTREAM_REF" || exit 1

  git -C "$CORE" fetch "$UPSTREAM_REMOTE" "$UPSTREAM_BRANCH"
  git -C "$CORE" checkout -q -b "$name" "$UPSTREAM_REF"

  printf '\ncore/ is on %s, branched from %s.\n' "$name" "$UPSTREAM_REF"
  printf '\nWhile you are here:\n'
  printf '  this repo now reports core/ as modified. That is the pointer moving,\n'
  printf '  and it must NOT be committed here. `make core-restore` clears it.\n'
  printf '  (`git checkout core` does not: it never enters the submodule.)\n'
  printf '\nThe loop:\n'
  printf '  $EDITOR core/backend/pkg/extension/...   change the seam\n'
  printf '  MARGINCE_ALLOW_DIRTY_CORE=1 \\\n'
  printf '    make u NAME=<unit>                     prove it against a real unit\n'
  printf '  git -C core commit -s                    sign off (upstream blocks without it)\n'
  printf '  make core-check                          upstream'"'"'s own merge gate\n'
  printf '  make core-pr                             push and open the PR\n'
  printf '  make core-restore                        put core/ back (branch kept)\n'
  printf '\nMARGINCE_ALLOW_DIRTY_CORE=1 is required, not optional. Staging refuses to\n'
  printf 'run when core/ has modified tracked files, and editing a seam modifies\n'
  printf 'them. The same override applies to `make check` and `make build`.\n'
  printf '\nPREFIX it on each command. Do not export it, or the guard stays off for\n'
  printf 'the rest of your session.\n'
}

# check-pin — the commit this repo pins for core/ is really on upstream's main.
#
# The invariant everything else assumed and nothing enforced. "core/ is
# read-only, the pointer moves only by update-core" was documentation: no gate
# ever asked WHICH commit the pointer names.
#
# Two ways it goes wrong, and the second is the expensive one:
#
#   1. A contribution branch commit that was never pushed. CI's submodule
#      checkout fails on fetch with a raw git error and no hint about what to do.
#      Annoying, but loud.
#
#   2. A contribution branch commit that WAS pushed, by `make core-pr`. That
#      object is fetchable, so CI checks it out and every gate passes -- while
#      main pins an unmerged branch. When the PR is squashed, rebased, or closed,
#      the pin dangles and the repo stops building for everyone, long after the
#      commit that caused it.
#
# Both start the same way: `git status` reports core/ as modified while a branch
# is checked out, and the developer reaches for `git commit core` to make the
# report go away. So this gate is what makes the invariant real.
cmd_check_pin() {
  require_core
  local pinned rc
  pinned="$(submodule_pinned_sha "$ROOT" core)"
  [ -n "$pinned" ] || die "core-check-pin: this repo records no submodule pointer for core/"

  # Deepen first where it is needed, so a shallow checkout still gets a real
  # answer instead of a skip. --unshallow fails on an already-complete repo, so
  # it is asked for only when the repo says it is shallow, and its failure is not
  # fatal: the worst case is the skip below.
  if [ "$(git -C "$CORE" rev-parse --is-shallow-repository 2>/dev/null)" = true ]; then
    git -C "$CORE" fetch --quiet --unshallow "$UPSTREAM_REMOTE" "$UPSTREAM_BRANCH" 2>/dev/null || true
  fi
  git -C "$CORE" fetch --quiet "$UPSTREAM_REMOTE" "$UPSTREAM_BRANCH" 2>/dev/null || true

  set +e
  pin_reachable_from "$CORE" "$pinned" "$UPSTREAM_REF"
  rc=$?
  set -e

  case "$rc" in
    0) printf 'core-check-pin: pinned %s is on %s.\n' "${pinned:0:12}" "$UPSTREAM_REF" ;;
    2)
      # UNKNOWN, not "bad". No network, an object this clone does not have, or a
      # shallow repository whose history cannot be traversed. Refusing here would
      # break every offline build and every depth-1 CI checkout; passing silently
      # would hide the real thing. So: say what could not be checked, and why.
      printf 'core-check-pin: SKIPPED — could not establish whether %s is on %s.\n' \
        "${pinned:0:12}" "$UPSTREAM_REF" >&2
      if [ "$(git -C "$CORE" rev-parse --is-shallow-repository 2>/dev/null)" = true ]; then
        printf '  core/ is a shallow clone, so ancestry is not traversable here.\n' >&2
        printf '  Fetch full history to make this gate meaningful:\n' >&2
        printf '    git -C core fetch --unshallow %s %s\n' "$UPSTREAM_REMOTE" "$UPSTREAM_BRANCH" >&2
      else
        printf '  Run `git -C core fetch %s %s` and retry.\n' "$UPSTREAM_REMOTE" "$UPSTREAM_BRANCH" >&2
      fi
      printf '  The pin was NOT verified. The pre-push hook checks it on a full clone.\n' >&2
      ;;
    *)
      printf 'error: core/ is pinned to %s, which is NOT on %s.\n\n' "${pinned:0:12}" "$UPSTREAM_REF" >&2
      printf 'This repo may only pin a commit that upstream has merged. A pointer to a\n' >&2
      printf 'contribution branch builds here and breaks for everyone else — and if the\n' >&2
      printf 'branch was pushed, CI passes too, until the PR is squashed or closed.\n\n' >&2
      printf 'To fix, restore the pointer and commit that:\n' >&2
      printf '  make core-restore\n' >&2
      printf '  git checkout HEAD -- core        # if the bad pointer is already committed\n' >&2
      printf '  git commit core -m "core: restore the pinned commit"\n\n' >&2
      printf 'If your seam is merged upstream, bump to it properly instead:\n' >&2
      printf '  make update-core\n' >&2
      exit 1
      ;;
  esac
}

cmd_restore() {
  require_core
  local pinned branch
  pinned="$(submodule_pinned_sha "$ROOT" core)"
  [ -n "$pinned" ] || die "core-restore: this repo records no submodule pointer for core/"

  if git_tracked_dirty "$CORE"; then
    printf 'error: core/ has modified tracked files; restoring would discard them:\n' >&2
    git -C "$CORE" diff --name-only HEAD | sed 's|^|  |' >&2
    printf '\nCommit them on the branch first, or discard them yourself.\n' >&2
    exit 1
  fi

  branch="$(git_head_branch "$CORE")"
  git -C "$CORE" checkout -q --detach "$pinned"
  printf 'core/ restored to the pinned commit %s.\n' "${pinned:0:12}"
  if [ -n "$branch" ]; then
    printf 'Branch %s is kept — check it out again with: git -C core checkout %s\n' "$branch" "$branch"
  fi
}

# dco_unsigned <repo> <range> — "<short-sha>\t<subject>" for each commit in the
# range with no valid Signed-off-by trailer.
#
# The pattern wants a name AND an address, because that is what upstream's
# checker wants; a bare "Signed-off-by: nobody" satisfies a naive grep and then
# blocks the merge anyway.
dco_unsigned() {
  local repo="$1" range="$2" sha
  while IFS= read -r sha; do
    [ -n "$sha" ] || continue
    # `git interpret-trailers --parse` reads the TRAILER BLOCK, not the whole
    # message. Grepping the body accepted a commit that merely quoted somebody
    # else's sign-off line while carrying none of its own.
    if ! git -C "$repo" show -s --format='%B' "$sha" \
        | git interpret-trailers --parse \
        | grep -qE '^Signed-off-by: .+ <[^ ]+@[^ ]+>[[:space:]]*$'; then
      printf '%s\t%s\n' \
        "$(git -C "$repo" rev-parse --short "$sha")" \
        "$(git -C "$repo" show -s --format='%s' "$sha")"
    fi
  done < <(git -C "$repo" rev-list --reverse "$range")
}

# repo_slug <git-url> — OWNER/REPO from either remote spelling.
#
# gh takes OWNER/REPO for --repo and rejects a git URL, and the fork path needs
# the owner on its own to build a cross-repo --head. Both spellings end in the
# same two path segments, so strip the scheme/host and the .git suffix.
repo_slug() {
  local url="${1:-}"
  url="${url%.git}"
  url="${url##*:}"        # git@host:owner/repo -> owner/repo
  url="${url##*/}"        # (leaves repo when the url was https)
  local rest="${1%.git}"
  rest="${rest%/*}"
  printf '%s/%s\n' "${rest##*[:/]}" "$url"
}

# push_remote <repo> — where a contribution branch should go.
#
# Probed, not configured. The team writes to origin (which already carries
# chore/craft-strict and siblings); an outside plugin developer cannot, and
# needs a fork. Asking the remote is the only way to tell those apart without
# a flag that the wrong half of the audience will get wrong.
#
# WHAT THE PROBE SEES: --dry-run connects and negotiates, so it detects
# transport and authorization refusal — which is how GitHub denies a
# contributor without write access, and the case this exists for. It does NOT
# run the remote's pre-receive hook, because a dry run transfers nothing. A
# remote that accepts the connection and rejects in a hook reads as writable
# here, and the real push is where that surfaces.
#
# The probe pushes HEAD to a refspec that CANNOT already exist, rather than to
# the same-named branch. `push --dry-run <remote> HEAD` resolves to the branch
# of the same name, so it fails "non-fast-forward" whenever that branch exists
# on the remote with different history — and this function would then report
# "no writable remote" when the true answer is "you can write; that one branch
# diverged". A create is the only push whose outcome depends on permission
# alone. --dry-run means nothing is created.
PUSH_PROBE_REF="refs/heads/margince-push-probe-do-not-create"

push_remote() {
  local repo="$1" remote
  for remote in origin fork; do
    git -C "$repo" remote get-url "$remote" >/dev/null 2>&1 || continue
    if git -C "$repo" push --dry-run "$remote" "HEAD:$PUSH_PROBE_REF" >/dev/null 2>&1; then
      printf '%s\n' "$remote"; return 0
    fi
  done
  return 1
}

cmd_pr() {
  require_core
  local branch unsigned remote upstream_url range
  branch="$(git_head_branch "$CORE")"
  [ -n "$branch" ] || die "core-pr: core/ is not on a branch — start one with 'make core-branch NAME=<type>/<slug>'"

  if git_tracked_dirty "$CORE"; then
    printf 'error: core/ has uncommitted changes; commit them before opening a PR:\n' >&2
    git -C "$CORE" diff --name-only HEAD | sed 's|^|  |' >&2
    exit 1
  fi

  git -C "$CORE" fetch "$UPSTREAM_REMOTE" "$UPSTREAM_BRANCH"
  range="$UPSTREAM_REF..HEAD"
  [ -n "$(git -C "$CORE" rev-list "$range")" ] \
    || die "core-pr: $branch has no commits that $UPSTREAM_REF does not already have"

  unsigned="$(dco_unsigned "$CORE" "$range")"
  if [ -n "$unsigned" ]; then
    printf 'error: these commits carry no Signed-off-by trailer:\n' >&2
    printf '%s\n' "$unsigned" | sed 's|^|  |' >&2
    printf '\nUpstream'"'"'s DCO check BLOCKS the merge without it, so this refuses now\n' >&2
    printf 'rather than letting you find out from CI. Fix the whole branch with:\n' >&2
    printf '  git -C core rebase --signoff %s\n' "$UPSTREAM_REF" >&2
    exit 1
  fi

  if ! remote="$(push_remote "$CORE")"; then
    printf 'error: no remote on core/ accepts a push.\n' >&2
    printf '\nYou need write access to origin, or a fork. To create one:\n' >&2
    printf '  gh repo fork margince/margince --remote=false --clone=false\n' >&2
    printf '  git -C core remote add fork git@github.com:<you>/margince.git\n' >&2
    exit 1
  fi

  printf 'core-pr: pushing %s to %s\n' "$branch" "$remote"
  git -C "$CORE" push -u "$remote" "$branch"

  command -v gh >/dev/null || {
    printf '\nPushed. gh is not installed, so open the PR by hand against\n'
    printf '%s, base %s.\n' "$UPSTREAM_REMOTE" "$UPSTREAM_BRANCH"
    return 0
  }

  upstream_url="$(git -C "$CORE" remote get-url "$UPSTREAM_REMOTE")"
  # gh wants OWNER/REPO, not a git URL. Both forms a remote can take —
  # git@host:owner/repo.git and https://host/owner/repo.git — reduce to the
  # last two path segments with the .git suffix removed.
  local upstream_slug head_ref fork_owner
  upstream_slug="$(repo_slug "$upstream_url")"

  # A cross-repo pull request needs --head <fork-owner>:<branch>. A bare branch
  # name is resolved against the UPSTREAM repo, where a fork's branch does not
  # exist — so the fork path failed at the last step, after the push had
  # already happened.
  head_ref="$branch"
  if [ "$remote" = "fork" ]; then
    fork_owner="$(repo_slug "$(git -C "$CORE" remote get-url fork)")"
    fork_owner="${fork_owner%%/*}"
    head_ref="$fork_owner:$branch"
  fi

  printf '\ncore-pr: opening the pull request.\n'
  printf 'Upstream asks for a proportionate AI disclosure (core/CONTRIBUTING.md):\n'
  printf '  Assisted  — you wrote it with AI help. The default.\n'
  printf '  Generated — AI produced substantial portions you reviewed and own.\n\n'
  ( cd "$CORE" && gh pr create --repo "$upstream_slug" --base "$UPSTREAM_BRANCH" --head "$head_ref" )
}

# Sourced by the test for its helpers alone; executed for its commands.
if [ -z "${CORE_CONTRIB_LIB_ONLY:-}" ]; then
  case "${1:-}" in
    status) cmd_status ;;
    guard-update) cmd_guard_update ;;
    branch) shift; cmd_branch "${1:-}" ;;
    restore) cmd_restore ;;
    pr) cmd_pr ;;
    check-pin) cmd_check_pin ;;
    *) die "core-contrib: unknown command: ${1:-<none>} (want: status, branch, restore, pr, guard-update, check-pin)" ;;
  esac
fi
