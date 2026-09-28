#!/usr/bin/env bash
# new-instance.sh — create a client instance repository from this template.
#
# The instance is a new repository whose history starts from the template's, so
# template changes merge in normally (make template-sync). GitHub does not allow
# a fork into the organization that owns the template, so the instance is a
# plain repository with a `template` remote instead.
#
# Everything is validated BEFORE anything is created. Nothing is pushed unless
# PUSH=1 is given.
#
# Usage:
#   NAME=acme DISPLAY_NAME="Acme" [DIR=../margince-acme] \
#     [PUSH=1 OWNER=gradionhq] bash scripts/new-instance.sh
#   (or: make new-instance NAME=… DISPLAY_NAME=… …)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$ROOT"

name="${NAME:-}"
display="${DISPLAY_NAME:-}"
dir="${DIR:-$(dirname "$ROOT")/margince-$name}"
owner="${OWNER:-gradionhq}"

[ ! -f .template-version ] || die "new-instance: this is an instance; run make new-instance in margince-template"
[ -n "$name" ] || die "new-instance: pass NAME=<name>, e.g. make new-instance NAME=acme DISPLAY_NAME=Acme"
[ -n "$display" ] || die "new-instance: pass DISPLAY_NAME=<text>, e.g. DISPLAY_NAME=\"Acme\""
# Checked here, before quoting: inside a double-quoted YAML scalar a raw
# newline is folded to a space by the parser, so cli check's single-line rule
# never sees it back out. Refuse it here instead of writing "Acme Client" from
# "Acme\nClient" and silently losing the line break.
case "$display" in
  *$'\n'*|*$'\r'*) die "new-instance: DISPLAY_NAME must be one line" ;;
esac
[ ! -e "$dir" ] || die "new-instance: $dir already exists"
[ -z "$(git status --porcelain)" ] || die "new-instance: commit or discard the template's local changes first"

core_tag="$(instance_get core)"
template_sha="$(git rev-parse HEAD)"
template_url="$(git remote get-url origin 2>/dev/null || printf '%s' "$ROOT")"

# Informational, not a refusal: an instance created off a branch is still a
# usable instance, but it will carry commits origin/main does not have, which
# is worth flagging before it is baked into a new repository's history.
if git rev-parse -q --verify refs/remotes/origin/main >/dev/null \
  && ! git merge-base --is-ancestor HEAD origin/main; then
  echo "new-instance: HEAD ($(git rev-parse --short HEAD)) is not on origin/main; the instance will contain unmerged template commits"
fi

# Validate the new instance.yaml with the same checker make check uses, before
# anything exists on disk.
#
# display_name is written as a double-quoted YAML scalar: an unquoted value
# starting a word with `#` or containing `: ` is either read back wrong (YAML
# treats ` #` as a comment, so "Acme #1 Client" silently becomes "Acme") or
# refused outright ("Acme: Special" does not parse as a plain scalar). Escape
# backslash first, then the double quote, so both are safe inside the quotes.
esc_display="${display//\\/\\\\}"
esc_display="${esc_display//\"/\\\"}"
candidate="$(mktemp)"
success=""
cleanup() {
  rm -f "$candidate"
  # A partially cloned/checked-out instance is worse than none: it looks like
  # a repository but is missing instance.yaml, .template-version or the
  # commit that makes check-template pass. Remove it unless we reached the
  # final commit — success is set only there, after the instance is whole.
  if [ -z "$success" ] && [ -n "${dir:-}" ] && [ -e "$dir" ]; then
    rm -rf "$dir"
  fi
}
trap cleanup EXIT
printf 'name: %s\ndisplay_name: "%s"\ncore: %s\n' "$name" "$esc_display" "$core_tag" > "$candidate"
(cd "$ROOT/scripts/cli" && GOWORK=off go run . check -file "$candidate" -core "$CORE") \
  || die "new-instance: the instance.yaml above would be invalid; fix NAME or DISPLAY_NAME"

git clone --quiet --no-checkout "$ROOT" "$dir"
git -C "$dir" remote remove origin
git -C "$dir" remote add template "$template_url"
git -C "$dir" checkout --quiet -B main "$template_sha"
git -C "$dir" submodule update --quiet --init --reference "$CORE" --dissociate core

cp "$candidate" "$dir/instance.yaml"
printf '%s\n' "$template_sha" > "$dir/.template-version"
cat > "$dir/README.md" <<EOF
# $display

The $display instance of Margince, created from margince-template at
commit ${template_sha:0:12}.

Start with \`make install\`, then \`make dev\`. Guides are in docs/README.md.
Template changes arrive with \`make template-sync\`.
EOF

git -C "$dir" add instance.yaml .template-version README.md
git -C "$dir" commit --quiet -m "chore: create instance $name from margince-template ${template_sha:0:12}"
success=1
echo "new-instance: created $dir (core $core_tag)"

if [ "${PUSH:-}" = "1" ]; then
  command -v gh >/dev/null || die "new-instance: PUSH=1 needs the GitHub CLI (gh)"
  gh repo create "$owner/margince-$name" --private --source "$dir" --remote origin --push
  echo "new-instance: pushed to $owner/margince-$name"
else
  echo
  echo "next:"
  echo "  cd $dir && make install && make dev"
  echo "  create the GitHub repository with PUSH=1 OWNER=$owner, or push it yourself"
fi
