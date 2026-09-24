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
#   NAME=acme DISPLAY_NAME="Acme" [VENDOR=acme] [DIR=../margince-acme] \
#     [PUSH=1 OWNER=gradionhq] bash scripts/new-instance.sh
#   (or: make new-instance NAME=… DISPLAY_NAME=… …)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$ROOT"

name="${NAME:-}"
display="${DISPLAY_NAME:-}"
vendor="${VENDOR:-$name}"
dir="${DIR:-$(dirname "$ROOT")/margince-$name}"
owner="${OWNER:-gradionhq}"

[ ! -f .template-version ] || die "new-instance: this is an instance; run make new-instance in margince-template"
[ -n "$name" ] || die "new-instance: pass NAME=<name>, e.g. make new-instance NAME=acme DISPLAY_NAME=Acme"
[ -n "$display" ] || die "new-instance: pass DISPLAY_NAME=<text>, e.g. DISPLAY_NAME=\"Acme\""
[ ! -e "$dir" ] || die "new-instance: $dir already exists"
[ -z "$(git status --porcelain)" ] || die "new-instance: commit or discard the template's local changes first"

core_tag="$(instance_get core)"
template_sha="$(git rev-parse HEAD)"
template_url="$(git remote get-url origin 2>/dev/null || printf '%s' "$ROOT")"

# Validate the new instance.yaml with the same checker make check uses, before
# anything exists on disk.
candidate="$(mktemp)"
trap 'rm -f "$candidate"' EXIT
printf 'name: %s\ndisplay_name: %s\ncore: %s\nflavor: %s/margince\n' "$name" "$display" "$core_tag" "$vendor" > "$candidate"
(cd "$ROOT/scripts/cli" && GOWORK=off go run . check -file "$candidate" -core "$CORE") \
  || die "new-instance: the instance.yaml above would be invalid; fix NAME, DISPLAY_NAME or VENDOR"

git clone --quiet --no-checkout "$ROOT" "$dir"
git -C "$dir" remote remove origin
git -C "$dir" remote add template "$template_url"
git -C "$dir" checkout --quiet -B main "$template_sha"
git -C "$dir" submodule update --quiet --init --reference "$CORE" core

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
echo "new-instance: created $dir (flavor $vendor/margince, core $core_tag)"

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
