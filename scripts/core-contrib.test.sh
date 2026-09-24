#!/usr/bin/env bash
# core-contrib.sh's git reasoning, proven against SYNTHETIC repositories rather
# than the real submodule. A guard proven only by "core is currently detached
# and clean" is one that keeps passing after it stops working — and these
# guards exist to protect work that only exists on somebody's laptop.
#
# No network, no submodule, no toolchain. Usage: bash scripts/core-contrib.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/core-contrib.sh
CORE_CONTRIB_LIB_ONLY=1 source "$SCRIPT_DIR/core-contrib.sh"

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

expect_eq() {
  local label="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then ok "$label"; else
    fail "$label"; printf '  want: %q\n  got:  %q\n' "$want" "$got" >&2
  fi
}

# A repository with one commit on main, isolated from the developer's git
# config: an inherited commit.gpgsign or a global hooksPath would make these
# cases fail for reasons that have nothing to do with what they test.
mkrepo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" config user.email dev@example.test
  git -C "$dir" config user.name  "Test Dev"
  git -C "$dir" config commit.gpgsign false
  git -C "$dir" config core.hooksPath /dev/null
  printf 'seed\n' > "$dir/file.txt"
  git -C "$dir" add file.txt
  git -C "$dir" commit -qm "seed"
}

# --- git_head_branch ---

r="$TMP/branch"; mkrepo "$r"
expect_eq "reports the branch when attached" "$(git_head_branch "$r")" "main"

git -C "$r" checkout -q --detach HEAD
expect_eq "reports empty when detached" "$(git_head_branch "$r")" ""

git -C "$r" checkout -q -b feat/seam
expect_eq "reports a hyphenated, slashed branch name" "$(git_head_branch "$r")" "feat/seam"

# --- git_tracked_dirty ---

r="$TMP/dirty"; mkrepo "$r"
if git_tracked_dirty "$r"; then fail "a clean tree is not dirty"; else ok "a clean tree is not dirty"; fi

printf 'edited\n' > "$r/file.txt"
if git_tracked_dirty "$r"; then ok "a modified tracked file is dirty"; else fail "a modified tracked file is dirty"; fi

git -C "$r" checkout -q -- file.txt
# UNTRACKED content must NOT count. core/ always holds untracked staged copies
# and untracked build output; a guard that called that dirty would refuse every
# real invocation and get worked around with an env var within a day.
printf 'scratch\n' > "$r/untracked.txt"
if git_tracked_dirty "$r"; then fail "untracked content is not dirty"; else ok "untracked content is not dirty"; fi

# --- git_ahead_behind ---

r="$TMP/ab"; mkrepo "$r"
git -C "$r" branch -q -f upstream main
expect_eq "level with upstream reports 0 behind 0 ahead" \
  "$(git_ahead_behind "$r" upstream)" "$(printf '0\t0')"

printf 'local work\n' > "$r/file.txt"
git -C "$r" commit -qam "local work"
expect_eq "one local commit reports 0 behind 1 ahead" \
  "$(git_ahead_behind "$r" upstream)" "$(printf '0\t1')"

git -C "$r" checkout -q upstream
printf 'upstream work\n' > "$r/other.txt"
git -C "$r" add other.txt && git -C "$r" commit -qm "upstream work"
git -C "$r" checkout -q main
expect_eq "diverged reports both sides" \
  "$(git_ahead_behind "$r" upstream)" "$(printf '1\t1')"

expect_eq "an unknown upstream reports empty rather than dying" \
  "$(git_ahead_behind "$r" no/such/ref)" ""

# --- submodule_pinned_sha ---

sup="$TMP/super"; mkrepo "$sup"
sub="$TMP/sub";   mkrepo "$sub"
# file:// so this stays local; -c protocol.file.allow=always because git
# refuses file-protocol submodules by default since CVE-2022-39253.
git -C "$sup" -c protocol.file.allow=always submodule add -q "file://$sub" core
git -C "$sup" commit -qm "add core"
pinned="$(git -C "$sub" rev-parse HEAD)"
expect_eq "reads the sha the superproject pins" \
  "$(submodule_pinned_sha "$sup" core)" "$pinned"

# Moving the submodule's HEAD must NOT move the pinned sha: the whole point of
# the reading is to tell a contributor those two have diverged.
printf 'moved\n' > "$sup/core/file.txt"
git -C "$sup/core" commit -qam "moved"
expect_eq "the pinned sha does not follow the submodule's HEAD" \
  "$(submodule_pinned_sha "$sup" core)" "$pinned"

# --- pin_reachable_from ---
#
# The guard that keeps main from pinning a commit upstream never merged. Its
# hard case is not the obvious one: an unpushed commit breaks CI loudly at
# submodule fetch, but a commit `make core-pr` already PUSHED is fetchable, so
# CI goes green while main points at an unmerged branch. Both are "not an
# ancestor of upstream/main", which is the only question asked here.
pr="$TMP/pinrepo"; mkrepo "$pr"
git -C "$pr" branch -q -f upstream/main HEAD          # stand-in for origin/main
merged="$(git -C "$pr" rev-parse HEAD)"

# On upstream: the only state that may be pinned.
pin_reachable_from "$pr" "$merged" upstream/main \
  && ok "a merged commit is reachable" || fail "a merged commit is reachable"

# An ANCESTOR of upstream is also legitimately pinnable -- that is just an older
# bump, not a bad one. Committed from a DETACHED head, because git refuses to
# force-update a branch that the current worktree has checked out.
git -C "$pr" checkout -q --detach upstream/main
printf 'newer\n' > "$pr/file.txt"; git -C "$pr" commit -qam "newer upstream"
git -C "$pr" branch -q -f upstream/main HEAD
pin_reachable_from "$pr" "$merged" upstream/main \
  && ok "an older upstream commit is still reachable" \
  || fail "an older upstream commit is still reachable"

# Off upstream: a contribution branch commit. THE case this exists for.
git -C "$pr" checkout -q -b feat/seam "$merged"
printf 'seam\n' > "$pr/file.txt"; git -C "$pr" commit -qam "a seam, not merged"
unmerged="$(git -C "$pr" rev-parse HEAD)"
set +e
pin_reachable_from "$pr" "$unmerged" upstream/main; rc=$?
set -e
# Exactly 1, not "non-zero": 2 would mean it could not check, which must never
# be how this case reports.
expect_eq "an unmerged branch commit is refused" "$rc" "1"

# UNKNOWN is not "no". An unresolvable upstream must report 2, so the caller can
# say it could not check instead of accusing the developer -- the same failure
# mode git_ahead_behind was fixed for.
set +e
pin_reachable_from "$pr" "$merged" no/such/ref; rc=$?
set -e
expect_eq "an unresolvable upstream reports unknown, not refused" "$rc" "2"

# A sha that is not in this repo at all is also unknown, not refused: that is a
# shallow clone, not a bad pointer.
set +e
pin_reachable_from "$pr" "0000000000000000000000000000000000000000" upstream/main; rc=$?
set -e
expect_eq "an absent object reports unknown, not refused" "$rc" "2"

# A SHALLOW repository must report unknown too, even when both objects are
# present and merge-base answers "no". Ancestry cannot be traversed past a graft
# boundary, so the "no" is an artefact of the clone depth, not a fact about the
# pin. CI checks submodules out at depth 1, and this gate failed its own repo on
# the first run there before this case existed.
up="$TMP/shallow-origin"; mkrepo "$up"
for i in 2 3 4 5; do
  printf 'c%s\n' "$i" > "$up/file.txt"
  git -C "$up" commit -qam "c$i"
done
deep_pin="$(git -C "$up" rev-parse HEAD~3)"

sh="$TMP/shallow-clone"; mkdir -p "$sh"
git -C "$sh" init -q -b main
git -C "$sh" config commit.gpgsign false
git -C "$sh" remote add origin "file://$up"
# What actions/checkout does to a submodule: fetch exactly the pinned sha, depth 1.
git -C "$sh" -c protocol.file.allow=always fetch -q --depth 1 origin "$deep_pin"
git -C "$sh" checkout -q --detach "$deep_pin"
git -C "$sh" -c protocol.file.allow=always fetch -q --depth 1 origin main:refs/remotes/origin/main

expect_eq "the synthetic clone really is shallow" \
  "$(git -C "$sh" rev-parse --is-shallow-repository)" "true"

set +e
pin_reachable_from "$sh" "$deep_pin" origin/main; rc=$?
set -e
expect_eq "a shallow repo reports unknown rather than accusing a good pin" "$rc" "2"

# --- assert_core_movable ---
#
# The guard that stops `make update-core` from checking out over a branch. The
# failure it prevents is silent and unrecoverable-looking: your work is still
# in the reflog, but nothing tells you that, and the tree in front of you no
# longer has it.

refuses() {
  local label="$1"; shift
  if ( "$@" ) >/dev/null 2>&1; then fail "$label"; else ok "$label"; fi
}
accepts() {
  local label="$1"; shift
  if ( "$@" ) >/dev/null 2>&1; then ok "$label"; else fail "$label"; fi
}

r="$TMP/movable"; mkrepo "$r"
git -C "$r" branch -q -f origin-main main
git -C "$r" checkout -q --detach main
accepts "a detached, clean, level tree may move" assert_core_movable "$r" origin-main

git -C "$r" checkout -q -b feat/seam
refuses "a tree on a branch may not move" assert_core_movable "$r" origin-main

git -C "$r" checkout -q --detach origin-main
printf 'edited\n' > "$r/file.txt"
refuses "a dirty tree may not move" assert_core_movable "$r" origin-main
git -C "$r" checkout -q -- file.txt

# AHEAD while detached: commits made on a detached HEAD are the easiest work in
# git to lose, so this is the case the guard most needs to catch.
printf 'detached work\n' > "$r/file.txt"
git -C "$r" commit -qam "detached work"
refuses "a tree ahead of upstream may not move" assert_core_movable "$r" origin-main

git -C "$r" checkout -q --detach origin-main
accepts "back level, it may move again" assert_core_movable "$r" origin-main

# --- core_branch_name_ok ---
#
# Upstream's branches are `type/slug` (chore/craft-strict,
# fix/composed-workspace-install-is-not-frozen). Matching that costs nothing
# here and saves a rename after review.

for good in feat/ext-seam fix/a-bug chore/tidy-up docs/a-page feat/seam-2; do
  if core_branch_name_ok "$good"; then ok "accepts $good"; else fail "accepts $good"; fi
done
for bad in "" "Feat/Caps" "feat" "feat/" "/slug" "feat//slug" "feat/UPPER" "feat/trailing-" "wat/slug"; do
  if core_branch_name_ok "$bad"; then fail "refuses '$bad'"; else ok "refuses '$bad'"; fi
done

# --- dco_unsigned ---
#
# Upstream's DCO check BLOCKS the merge. Finding out from CI after the push
# costs a review cycle to learn something this lane knows beforehand.

r="$TMP/dco"; mkrepo "$r"
git -C "$r" branch -q -f base main

printf 'a\n' > "$r/a.txt"; git -C "$r" add a.txt
git -C "$r" commit -qm "signed work" -s
expect_eq "a signed commit is not reported" "$(dco_unsigned "$r" base..HEAD)" ""

printf 'b\n' > "$r/b.txt"; git -C "$r" add b.txt
git -C "$r" commit -qm "unsigned work"
expect_eq "an unsigned commit is reported with its subject" \
  "$(dco_unsigned "$r" base..HEAD | cut -f2)" "unsigned work"

# A trailer-shaped line that is not a real sign-off must not satisfy the gate:
# upstream's checker wants a name and an address.
printf 'c\n' > "$r/c.txt"; git -C "$r" add c.txt
git -C "$r" commit -qm "fake trailer

Signed-off-by: nobody"
expect_eq "a malformed trailer does not count as signed" \
  "$(dco_unsigned "$r" base..HEAD | wc -l | tr -d ' ')" "2"

# --- push_remote ---

r="$TMP/remotes"; mkrepo "$r"
up="$TMP/remotes-origin"; mkrepo "$up"
git -C "$up" config receive.denyCurrentBranch ignore
git -C "$r" remote add origin "file://$up"
expect_eq "a writable origin is the push target" "$(push_remote "$r")" "origin"

r="$TMP/remotes-ro"; mkrepo "$r"
git -C "$r" remote add origin "file://$TMP/does-not-exist"
fk="$TMP/remotes-fork"; mkrepo "$fk"
git -C "$fk" config receive.denyCurrentBranch ignore
git -C "$r" remote add fork "file://$fk"
expect_eq "an unwritable origin falls back to fork" "$(push_remote "$r")" "fork"

r="$TMP/remotes-none"; mkrepo "$r"
git -C "$r" remote add origin "file://$TMP/does-not-exist"
if push_remote "$r" >/dev/null 2>&1; then
  fail "no writable remote is an error"
else
  ok "no writable remote is an error"
fi

# --- repo_slug ---
#
# gh takes OWNER/REPO and rejects a git URL. Both remote spellings must reduce
# to the same slug, or `core-pr` fails at the last step with the branch already
# pushed.

expect_eq "ssh remote reduces to owner/repo" \
  "$(repo_slug 'git@github.com:gradionhq/margince-poc-v1.git')" "gradionhq/margince-poc-v1"
expect_eq "https remote reduces to owner/repo" \
  "$(repo_slug 'https://github.com/gradionhq/margince-poc-v1.git')" "gradionhq/margince-poc-v1"
expect_eq "a url without the .git suffix still reduces" \
  "$(repo_slug 'https://github.com/gradionhq/margince-poc-v1')" "gradionhq/margince-poc-v1"
expect_eq "a fork url reduces to the fork owner" \
  "$(repo_slug 'git@github.com:someone/margince-poc-v1.git')" "someone/margince-poc-v1"

# --- push_remote: an UNREADABLE remote is refused, not chosen ---
#
# What `push --dry-run` can and cannot see matters here. It connects and
# negotiates, so it detects transport and AUTHORIZATION refusal — which is how
# GitHub denies a contributor without write access, and the case this function
# exists for. It does NOT run the remote's pre-receive hook, because a dry run
# transfers nothing; server-side hook rejection is invisible to any probe short
# of a real push. So the local analogue of "denied" is a remote that refuses at
# the transport layer.

r="$TMP/remotes-denied"; mkrepo "$r"
den="$TMP/remotes-denied-origin"; mkrepo "$den"
chmod 000 "$den/.git"
git -C "$r" remote add origin "file://$den"
fk2="$TMP/remotes-denied-fork"; mkrepo "$fk2"
git -C "$fk2" config receive.denyCurrentBranch ignore
git -C "$r" remote add fork "file://$fk2"
expect_eq "a remote that refuses at the transport layer falls back to fork" \
  "$(push_remote "$r")" "fork"
chmod 755 "$den/.git"

# --- assert_core_movable: unknown upstream must REFUSE, not pass ---
#
# The guard used to read an unresolvable upstream as "zero ahead" and permit
# the move, which is the failure it exists to prevent.

r="$TMP/unknown-upstream"; mkrepo "$r"
git -C "$r" checkout -q --detach HEAD
printf 'detached work\n' > "$r/file.txt"
git -C "$r" commit -qam "detached work"
refuses "an unresolvable upstream refuses rather than assuming level" \
  assert_core_movable "$r" origin/main

# --- dco_unsigned reads the trailer block, not the whole message ---

r="$TMP/dco-quote"; mkrepo "$r"
git -C "$r" branch -q -f base main
printf 'q\n' > "$r/q.txt"; git -C "$r" add q.txt
git -C "$r" commit -qm "quotes a sign-off in prose

Someone wrote Signed-off-by: Real Dev <real@example.test> in a review
and this commit merely quotes it.

Refs: #1"
expect_eq "a sign-off quoted in the body does not count" \
  "$(dco_unsigned "$r" base..HEAD | cut -f2)" "quotes a sign-off in prose"

# --- the cmd_* entry points ---
#
# The helpers above are the reasoning; these are what a developer actually
# runs, and every bug review found in this file lived in one of them. They read
# $CORE and $ROOT as globals, so a synthetic superproject + submodule pair is
# pointed at them for the duration. `origin` is another local repository, so
# the fetches these commands make stay offline.

# A superproject whose `core` submodule has an `origin` we can fetch from.
mkinstall() {
  local base="$1"
  local upstream="$base/upstream" sup="$base/super"
  mkrepo "$upstream"
  git -C "$upstream" config receive.denyCurrentBranch ignore
  mkrepo "$sup"
  git -C "$sup" -c protocol.file.allow=always submodule add -q "file://$upstream" core
  git -C "$sup" commit -qm "add core"
  # require_core looks for this exact file before any command will run.
  : > "$sup/core/go.work"
  git -C "$sup/core" config user.email dev@example.test
  git -C "$sup/core" config user.name "Test Dev"
  git -C "$sup/core" config commit.gpgsign false
  git -C "$sup/core" config core.hooksPath /dev/null
  git -C "$sup/core" remote set-url origin "file://$upstream"
  git -C "$sup/core" fetch -q origin main
  # DETACHED, because that is what a real submodule checkout is. `submodule
  # add` leaves it attached to main, and an attached tree is one every guard
  # here correctly refuses — so a fixture that skipped this would test the
  # refusal path forever and never the success path.
  git -C "$sup/core" checkout -q --detach HEAD
}

with_install() {
  local base="$1"; shift
  ROOT="$base/super" CORE="$base/super/core" "$@"
}

# --- cmd_status ---

b="$TMP/i-status"; mkdir -p "$b"; mkinstall "$b"
out="$(with_install "$b" cmd_status 2>&1)"
case "$out" in
  *"detached at"*|*"on branch"*) ok "cmd_status reports where HEAD is" ;;
  *) fail "cmd_status reports where HEAD is" ;;
esac
case "$out" in
  *"tracked files clean"*) ok "cmd_status reports a clean tree as clean" ;;
  *) fail "cmd_status reports a clean tree as clean" ;;
esac
printf 'edited\n' > "$b/super/core/file.txt"
out="$(with_install "$b" cmd_status 2>&1)"
case "$out" in
  *"MODIFIED"*file.txt*) ok "cmd_status names the modified file" ;;
  *) fail "cmd_status names the modified file" ;;
esac
git -C "$b/super/core" checkout -q -- file.txt

# --- cmd_branch ---

b="$TMP/i-branch"; mkdir -p "$b"; mkinstall "$b"
( with_install "$b" cmd_branch "not-a-valid-name" ) >/dev/null 2>&1 \
  && fail "cmd_branch refuses a name outside the grammar" \
  || ok "cmd_branch refuses a name outside the grammar"

( with_install "$b" cmd_branch "" ) >/dev/null 2>&1 \
  && fail "cmd_branch refuses an empty name" || ok "cmd_branch refuses an empty name"

( with_install "$b" cmd_branch feat/a-seam ) >/dev/null 2>&1 \
  && ok "cmd_branch creates a well-named branch" || fail "cmd_branch creates a well-named branch"
expect_eq "cmd_branch leaves core on that branch" \
  "$(git_head_branch "$b/super/core")" "feat/a-seam"

# Starting a branch moves HEAD, so it must refuse exactly where update-core does.
( with_install "$b" cmd_branch feat/another-seam ) >/dev/null 2>&1 \
  && fail "cmd_branch refuses while another branch is open" \
  || ok "cmd_branch refuses while another branch is open"

# --- cmd_restore ---

b2="$TMP/i-restore"; mkdir -p "$b2"; mkinstall "$b2"
pinned="$(submodule_pinned_sha "$b2/super" core)"
( with_install "$b2" cmd_branch feat/a-seam ) >/dev/null 2>&1
printf 'work\n' >> "$b2/super/core/file.txt"
git -C "$b2/super/core" commit -qam "seam work"
( with_install "$b2" cmd_restore ) >/dev/null 2>&1 \
  && ok "cmd_restore succeeds on a clean branch" || fail "cmd_restore succeeds on a clean branch"
expect_eq "cmd_restore returns core to the PINNED commit" \
  "$(git -C "$b2/super/core" rev-parse HEAD)" "$pinned"
expect_eq "cmd_restore keeps the branch" \
  "$(git -C "$b2/super/core" rev-parse --verify --quiet feat/a-seam >/dev/null && echo kept)" "kept"

printf 'uncommitted\n' > "$b2/super/core/file.txt"
( with_install "$b2" cmd_restore ) >/dev/null 2>&1 \
  && fail "cmd_restore refuses to discard uncommitted work" \
  || ok "cmd_restore refuses to discard uncommitted work"
git -C "$b2/super/core" checkout -q -- file.txt

# --- cmd_guard_update ---

b3="$TMP/i-guard"; mkdir -p "$b3"; mkinstall "$b3"
( with_install "$b3" cmd_guard_update ) >/dev/null 2>&1 \
  && ok "cmd_guard_update permits a clean detached tree" \
  || fail "cmd_guard_update permits a clean detached tree"
( with_install "$b3" cmd_branch feat/a-seam ) >/dev/null 2>&1
( with_install "$b3" cmd_guard_update ) >/dev/null 2>&1 \
  && fail "cmd_guard_update refuses while a branch is open" \
  || ok "cmd_guard_update refuses while a branch is open"

# --- cmd_pr: every refusal BEFORE anything is pushed ---

b4="$TMP/i-pr"; mkdir -p "$b4"; mkinstall "$b4"
( with_install "$b4" cmd_pr ) >/dev/null 2>&1 \
  && fail "cmd_pr refuses when core is not on a branch" \
  || ok "cmd_pr refuses when core is not on a branch"

( with_install "$b4" cmd_branch feat/a-seam ) >/dev/null 2>&1
( with_install "$b4" cmd_pr ) >/dev/null 2>&1 \
  && fail "cmd_pr refuses a branch with no commits" \
  || ok "cmd_pr refuses a branch with no commits"

printf 'work\n' >> "$b4/super/core/file.txt"
git -C "$b4/super/core" commit -qam "unsigned seam work"
out="$( ( with_install "$b4" cmd_pr ) 2>&1 || true )"
case "$out" in
  *"no Signed-off-by"*) ok "cmd_pr refuses an unsigned branch" ;;
  *) fail "cmd_pr refuses an unsigned branch" ;;
esac
case "$out" in
  *"rebase --signoff"*) ok "cmd_pr names the fix for an unsigned branch" ;;
  *) fail "cmd_pr names the fix for an unsigned branch" ;;
esac

printf 'more\n' >> "$b4/super/core/file.txt"
out="$( ( with_install "$b4" cmd_pr ) 2>&1 || true )"
case "$out" in
  *"uncommitted changes"*) ok "cmd_pr refuses a dirty tree before pushing" ;;
  *) fail "cmd_pr refuses a dirty tree before pushing" ;;
esac
git -C "$b4/super/core" checkout -q -- file.txt

if [ "$FAILURES" -gt 0 ]; then
  printf '\n%s case(s) failed\n' "$FAILURES" >&2
  exit 1
fi
printf '\nall cases passed\n'
