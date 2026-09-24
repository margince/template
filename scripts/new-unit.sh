#!/usr/bin/env bash
# new-unit.sh — scaffold a unit from scripts/unit-skeleton/.
#
# Everything is validated BEFORE anything is created. A scaffold that
# half-creates a rejected unit is worse than one that refuses: presence under
# extensions/ IS the enablement, so a directory left behind by a failed run is a
# unit the next compose tries to enable.
#
# Usage: bash scripts/new-unit.sh <name>   (or: make new-unit NAME=<name>)
set -Eeuo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

name="${1:-}"
[ -n "$name" ] || die "new-unit: pass a name, e.g. make new-unit NAME=crm-sync"

# The grammar is upstream's, enforced at scan time AND at boot
# (extension.Name.Validate). Catching it here turns a composer failure into a
# sentence about the name.
printf '%s' "$name" | grep -Eq '^[a-z0-9]+(-[a-z0-9]+)*$' \
  || die "new-unit: '$name' must match ^[a-z0-9]+(-[a-z0-9]+)*\$ (lower-case segments joined by single hyphens)"
[ "${#name}" -le 32 ] || die "new-unit: '$name' exceeds 32 characters"

[ ! -e "$SRC_EXT/$name" ] || die "new-unit: extensions/$name already exists"

# The collision stage.sh would hit later, caught earlier and more clearly. A
# local unit must never shadow an upstream one: silently overwriting one would
# replace core behaviour with ours and leave no trace.
if [ -d "$CORE/.git" ] || [ -f "$CORE/.git" ]; then
  if git -C "$CORE" ls-files --error-unmatch "extensions/$name" >/dev/null 2>&1; then
    die "new-unit: '$name' is an upstream unit — staging ours would shadow core behaviour. Pick another name."
  fi
fi

# The Go package identifier drops the hyphens and nothing else does: a hyphen is
# illegal in a Go identifier but legal in a module path, a directory name and
# Extension.Name. extensions/acme-sync is `package acmesync`.
pkg="$(printf '%s' "$name" | tr -d '-')"

SKELETON="$ROOT/scripts/unit-skeleton"
[ -d "$SKELETON" ] || die "new-unit: missing $SKELETON"

# Render every template into the new unit. The manifest is DERIVED and not
# rendered here: the next compose writes it.
mkdir -p "$SRC_EXT/$name"
# A failure partway through rendering (a missing or unreadable template) must
# not leave a partial unit behind: presence under extensions/ IS the
# enablement (see the file header), so a half-written directory here is a
# unit the next compose tries to enable. `set -E` above makes this trap fire
# even when render, not the top level, is where the failure happens.
trap 'rm -rf "$SRC_EXT/$name"' ERR
render() {
  local src="$1" dest="$2"
  cp "$src" "$dest"
  rewrite_file_in_place "$dest" "s|__NAME__|$name|g" "s|__PKG__|$pkg|g"
}
render "$SKELETON/go.mod.tmpl"       "$SRC_EXT/$name/go.mod"
render "$SKELETON/unit.go.tmpl"      "$SRC_EXT/$name/$pkg.go"
render "$SKELETON/unit_test.go.tmpl" "$SRC_EXT/$name/${pkg}_test.go"
trap - ERR

echo "new-unit: created extensions/$name (package $pkg)"
echo
echo "next:"
echo "  \$EDITOR extensions/$name/$pkg.go   # declare what it does"
echo "  make compose                        # writes extensions/$name/manifest.generated.json"
echo "  git add extensions/$name"
echo "  make u NAME=$name                   # its tests + the policy gates"
echo
echo "The manifest is generated: 'make compose' writes"
echo "extensions/$name/manifest.generated.json and it is committed with the unit."
