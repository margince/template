#!/usr/bin/env bash
# build-info.sh against SYNTHETIC trees, one per claim the stamped files make.
#
# The claims worth holding down are the ones a reader would trust without being
# able to check: that the version is the release's and not the builder's, that
# the architecture is the BUNDLE's and not the stamping machine's, and that a
# build from an uncommitted tree says so. Each is a sentence in a file somebody
# pastes into a bug report, so a wrong one is worse than a missing one.
#
# Usage: bash scripts/build-info.test.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

FAILURES=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }
ok()   { printf 'ok: %s\n' "$*"; }

# A repo shaped like this one: two units with manifests, a core submodule that
# is its own git repo, and a built folder to stamp.
#
# Hermetic against the developer's own git config, for the reason
# check-manifests.test.sh gives: an init.defaultBranch or a commit.gpgsign in
# ~/.gitconfig must not decide whether this suite passes.
new_tree() {
  local dir; dir="$(mktemp -d)"
  mkdir -p "$dir/scripts" "$dir/extensions/alpha" "$dir/extensions/beta" \
           "$dir/core" "$dir/folder/runtime"
  cp "$HERE/build-info.sh" "$HERE/lib.sh" "$dir/scripts/"

  # Two manifest spellings on purpose: gen-composition's own indented output and
  # a compact one, so the parser is not holding on to whitespace it happens to
  # meet today.
  cat > "$dir/extensions/alpha/manifest.generated.json" <<'JSON'
{
  "schema": 1,
  "name": "alpha",
  "version": "1.2.3",
  "risk_tiers": []
}
JSON
  printf '{"schema":1,"name":"beta","version":"0.4.0"}\n' \
    > "$dir/extensions/beta/manifest.generated.json"

  local repo
  for repo in "$dir" "$dir/core"; do
    git -C "$repo" init -q
    git -C "$repo" config user.email t@t.t
    git -C "$repo" config user.name t
    git -C "$repo" config commit.gpgsign false
  done
  echo core > "$dir/core/VERSION"
  git -C "$dir/core" add -A
  git -C "$dir/core" commit -qm core
  # core/ is a repo inside a repo here, as it is in the real tree. Excluded
  # rather than added, so `git add -A` does not warn about an embedded
  # repository on every one of these trees and bury the results.
  printf '/core/\n' > "$dir/.git/info/exclude"
  git -C "$dir" add -A
  git -C "$dir" commit -qm init
  printf '%s' "$dir"
}

# The same tree, but with core/ as a REAL submodule rather than a nested repo,
# which is the only way to exercise the gitlink. Returns empty if git refuses a
# file-protocol submodule (it is disabled by default on newer git, and the
# -c below is the documented opt-in).
new_tree_with_submodule() {
  local dir; dir="$(new_tree)"
  rm -rf "$dir/core" "$dir/.git/info/exclude"
  local src; src="$(mktemp -d)"
  git -C "$src" init -q
  git -C "$src" config user.email t@t.t
  git -C "$src" config user.name t
  git -C "$src" config commit.gpgsign false
  echo core > "$src/VERSION"
  git -C "$src" add -A
  git -C "$src" commit -qm core
  if ! git -C "$dir" -c protocol.file.allow=always submodule add -q "$src" core 2>/dev/null; then
    rm -rf "$dir" "$src"; printf ''; return 0
  fi
  git -C "$dir" add -A
  git -C "$dir" commit -qm submodule
  printf '%s' "$dir"
}

run() { ( cd "$1" && bash scripts/build-info.sh --dir folder "${@:2}" ); }
text() { cat "$1/folder/BUILD-INFO.txt"; }
json() { cat "$1/folder/runtime/build-info.json"; }

# --- an explicit version wins over everything git could say ---
r="$(new_tree)"
git -C "$r" tag v9.9.9
run "$r" --os darwin --version v0.3.0 >/dev/null
grep -qx 'Margince v0.3.0' <<<"$(text "$r")" \
  && ok "--version is what the folder calls itself" \
  || fail "--version is what the folder calls itself (got: $(head -1 "$r/folder/BUILD-INFO.txt"))"
rm -rf "$r"

# --- without one, the tags speak ---
r="$(new_tree)"
git -C "$r" tag v9.9.9
run "$r" --os darwin >/dev/null
grep -q '"version": "v9.9.9"' <<<"$(json "$r")" \
  && ok "no --version falls back to git describe" \
  || fail "no --version falls back to git describe"
rm -rf "$r"

# --- and with no tags at all, the commit does. A developer's checkout has no
# --- tags fetched, so this is the everyday path, not the exotic one.
r="$(new_tree)"
run "$r" --os darwin >/dev/null
sha="$(git -C "$r" rev-parse --short=7 HEAD)"
grep -q "\"version\": \"dev-$sha\"" <<<"$(json "$r")" \
  && ok "no tags falls back to dev-<sha>" \
  || fail "no tags falls back to dev-<sha>"
rm -rf "$r"

# --- a tag that names no version is ignored by describe, whatever its shape.
# --- Only `v*` is a version here; a build naming itself after any other tag
# --- would be quoting somebody's convenience back as a release number.
r="$(new_tree)"
git -C "$r" tag pre-alpha-20260825-0629
run "$r" --os darwin >/dev/null
sha="$(git -C "$r" rev-parse --short=7 HEAD)"
grep -q "\"version\": \"dev-$sha\"" <<<"$(json "$r")" \
  && ok "a tag that is not a v* version is not mistaken for one" \
  || fail "a tag that is not a v* version is not mistaken for one"
rm -rf "$r"

# --- --print-version resolves without stamping. cmd_kit asks first so the
# --- folder README and BUILD-INFO.txt cannot name different builds.
r="$(new_tree)"
git -C "$r" tag v9.9.9
got="$( cd "$r" && bash scripts/build-info.sh --print-version )"
if [ "$got" = v9.9.9 ] && [ ! -e "$r/folder/BUILD-INFO.txt" ]; then
  ok "--print-version resolves and stamps nothing"
else
  fail "--print-version resolves and stamps nothing (got '$got')"
fi
rm -rf "$r"

# --- THE TRAP: a Windows folder stamped from this Mac is still amd64.
# --- `make desktop-win-kit DIR=` is documented as exactly that gesture, so
# --- reading uname here would write the stamping machine into the bundle.
r="$(new_tree)"
run "$r" --os windows --version v1.0.0 >/dev/null
grep -q '"platform": "windows/amd64"' <<<"$(json "$r")" \
  && ok "a windows folder is amd64 whatever stamped it" \
  || fail "a windows folder is amd64 whatever stamped it"
rm -rf "$r"

# --- a build from an uncommitted tree admits it ---
r="$(new_tree)"
echo 'edited' >> "$r/extensions/alpha/manifest.generated.json"
run "$r" --os darwin --version v1.0.0 >/dev/null
grep -qE '"repo": "[0-9a-f]{7}-dirty"' <<<"$(json "$r")" \
  && ok "a dirty tree is marked dirty" \
  || fail "a dirty tree is marked dirty"
rm -rf "$r"

# --- THE WINDOWS REGRESSION: a dirty submodule is not a dirty repo.
#
# git reports a modified submodule as a change to the parent's gitlink, so
# without --ignore-submodules anything that touches core/ marks this repository
# dirty too. The Windows build regenerates core's own manifests as a side
# effect, so EVERY Windows bundle carried `repo <sha>-dirty` — a marker that
# fires on every build, about sources nobody changed.
r="$(new_tree_with_submodule)"
if [ -n "$r" ]; then
  echo 'scratch' >> "$r/core/VERSION"
  run "$r" --os darwin --version v1.0.0 >/dev/null
  repo_line="$(grep '"repo"' "$r/folder/runtime/build-info.json")"
  core_line="$(grep '"core"' "$r/folder/runtime/build-info.json")"
  if grep -q 'dirty' <<<"$repo_line"; then
    fail "a dirty submodule does not mark the repo dirty (got: $repo_line)"
  else
    ok "a dirty submodule does not mark the repo dirty"
  fi
  # core's OWN line still tells the truth about core.
  grep -q 'dirty' <<<"$core_line" \
    && ok "core's own marker still reports core's dirtiness" \
    || fail "core's own marker still reports core's dirtiness (got: $core_line)"
  rm -rf "$r"
else
  ok "SKIPPED the submodule cases (git refused a file-protocol submodule)"
fi

# --- a lane that cannot measure honestly passes the values in.
#
# The Windows lane measures both commits at checkout, because its own build
# dirties core/ before the kit is reached.
r="$(new_tree)"
echo 'scratch' >> "$r/extensions/alpha/manifest.generated.json"
( cd "$r" && MARGINCE_BUILD_REPO_SHA=aaaaaaa MARGINCE_BUILD_CORE_SHA=bbbbbbb \
    bash scripts/build-info.sh --dir folder --os windows --version v1.0.0 ) >/dev/null
if grep -q '"repo": "aaaaaaa"' <<<"$(json "$r")" && grep -q '"core": "bbbbbbb"' <<<"$(json "$r")"; then
  ok "the checkout-time overrides win over what the tree looks like now"
else
  fail "the checkout-time overrides win over what the tree looks like now"
fi
rm -rf "$r"

# --- the unit set and its versions come from the manifests ---
r="$(new_tree)"
run "$r" --os darwin --version v1.0.0 >/dev/null
if grep -q '{"name": "alpha", "version": "1.2.3"}' <<<"$(json "$r")" &&
   grep -q '{"name": "beta", "version": "0.4.0"}' <<<"$(json "$r")"; then
  ok "every unit and its version is recorded"
else
  fail "every unit and its version is recorded"
fi
rm -rf "$r"

# --- a unit with no manifest is still listed, rather than silently dropped ---
r="$(new_tree)"
mkdir -p "$r/extensions/gamma"
run "$r" --os darwin --version v1.0.0 >/dev/null
grep -q '{"name": "gamma", "version": "unknown"}' <<<"$(json "$r")" \
  && ok "a unit with no manifest is listed as unknown, not dropped" \
  || fail "a unit with no manifest is listed as unknown, not dropped"
rm -rf "$r"

# --- the JSON is JSON: the whole document, compared literally.
#
# A field-by-field grep cannot see a trailing comma after the last unit, which
# is the one malformation the loop that writes it can produce.
r="$(new_tree)"
run "$r" --os darwin --version v1.0.0 >/dev/null
got="$(sed -e 's/"built_at": "[^"]*"/"built_at": "STAMP"/' \
           -e 's/"repo": "[^"]*"/"repo": "SHA"/' \
           -e 's/"core": "[^"]*"/"core": "SHA"/' \
           -e 's|"platform": "[^"]*"|"platform": "PLAT"|' "$r/folder/runtime/build-info.json")"
want='{
  "version": "v1.0.0",
  "built_at": "STAMP",
  "platform": "PLAT",
  "repo": "SHA",
  "core": "SHA",
  "dataset": "none",
  "units": [
    {"name": "alpha", "version": "1.2.3"},
    {"name": "beta", "version": "0.4.0"}
  ]
}'
[ "$got" = "$want" ] && ok "the JSON document is exactly what it claims" \
  || fail "the JSON document is exactly what it claims:
--- got ---
$got
--- want ---
$want"
rm -rf "$r"

# --- core's commit is read from core/, not from the repo ---
r="$(new_tree)"
run "$r" --os darwin --version v1.0.0 >/dev/null
core_sha="$(git -C "$r/core" rev-parse --short=7 HEAD)"
grep -q "\"core\": \"$core_sha\"" <<<"$(json "$r")" \
  && ok "the core commit is core's, not the repo's" \
  || fail "the core commit is core's, not the repo's"
rm -rf "$r"

# --- a folder that is not a built desktop folder is refused, not stamped.
# --- runtime/ is the tell, and it is where half the output goes.
r="$(new_tree)"
mkdir -p "$r/not-a-folder"
if ( cd "$r" && bash scripts/build-info.sh --dir not-a-folder --os darwin ) >/dev/null 2>&1; then
  fail "a folder with no runtime/ is refused"
else
  ok "a folder with no runtime/ is refused"
fi
rm -rf "$r"

# --- an unknown target os is refused rather than guessed ---
r="$(new_tree)"
if run "$r" --os linux >/dev/null 2>&1; then
  fail "an unsupported target os is refused"
else
  ok "an unsupported target os is refused"
fi
rm -rf "$r"

# --- the demo dataset commit: three states, and they must stay distinguishable
#
# The dataset is deliberately UNPINNED — both desktop lanes check it out with no
# ref — so recording the sha is the only thing that can ever say which demo data
# a bundle holds. That makes the difference between "ships none" and "ships some,
# unrecorded" load-bearing: collapsing them would hide a lane that stopped
# passing the value, which is the one failure this field exists to expose.
r="$(new_tree)"
run "$r" --os darwin --version v1.0.0 >/dev/null
if grep -qE '^  dataset   none$' <<<"$(text "$r")"; then
  ok "an unseeded folder reports dataset none"
else
  fail "an unseeded folder must report 'dataset none' — it ships no demo data.
      got: $(grep -E '^  dataset' <<<"$(text "$r")" || echo '(no dataset line)')"
fi

run "$r" --os darwin --version v1.0.0 --seeded >/dev/null
if grep -qE '^  dataset   unknown$' <<<"$(text "$r")"; then
  ok "a seeded folder with no recorded commit reports dataset unknown"
else
  fail "a SEEDED folder whose dataset commit was not passed must report
      'unknown', not 'none': it ships demo data of unrecorded provenance, and
      reporting that as 'none' hides a lane that has drifted from the contract.
      got: $(grep -E '^  dataset' <<<"$(text "$r")" || echo '(no dataset line)')"
fi

MARGINCE_BUILD_DATASET_SHA=1a2b3c4 run "$r" --os darwin --version v1.0.0 --seeded >/dev/null
if grep -qE '^  dataset   1a2b3c4$' <<<"$(text "$r")"; then
  ok "the recorded dataset commit reaches BUILD-INFO.txt"
else
  fail "MARGINCE_BUILD_DATASET_SHA must reach BUILD-INFO.txt — it is the only
      record of which demo data a bundle carries.
      got: $(grep -E '^  dataset' <<<"$(text "$r")" || echo '(no dataset line)')"
fi
if grep -q '"dataset": "1a2b3c4"' <<<"$(json "$r")"; then
  ok "the recorded dataset commit reaches build-info.json"
else
  fail "build-info.json lost the dataset field. It is written for readers that do
      not exist yet, and a field added later is absent from every copy already
      in the field."
fi
rm -rf "$r"

if [ "$FAILURES" -ne 0 ]; then
  printf '\n%d failure(s)\n' "$FAILURES" >&2
  exit 1
fi
printf '\nbuild-info.test.sh: all good\n'
