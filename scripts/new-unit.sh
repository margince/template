#!/usr/bin/env bash
# new-unit.sh — scaffold a unit from extensions/gradion.
#
# Everything is validated BEFORE anything is created. A scaffold that
# half-creates a rejected unit is worse than one that refuses: presence under
# extensions/ IS the enablement, so a directory left behind by a failed run is a
# unit the next compose tries to enable.
#
# Usage: bash scripts/new-unit.sh <name>   (or: make new-unit NAME=<name>)
set -euo pipefail
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
# Extension.Name. zalo-oa is `package zalooa` under extensions/zalo-oa.
pkg="$(printf '%s' "$name" | tr -d '-')"

copy_unit_tree "$SRC_EXT/gradion" "$SRC_EXT/$name"
mv "$SRC_EXT/$name/gradion.go" "$SRC_EXT/$name/$pkg.go"
mv "$SRC_EXT/$name/gradion_test.go" "$SRC_EXT/$name/${pkg}_test.go"
# The manifest is DERIVED — the next compose writes it. Shipping the template's
# would mean a scaffolded unit whose manifest describes a different unit until
# somebody composed.
rm -f "$SRC_EXT/$name/manifest.generated.json"

# Longest patterns first, so a shorter rule cannot eat a longer one.
#
# rewrite_file_in_place rather than `sed -i`: BSD sed requires a backup-suffix
# argument and GNU sed refuses one, so the `sed -i ''` this used to run made
# the scaffolder fail on every Linux box.
while IFS= read -r file; do
  rewrite_file_in_place "$file" \
    "s|extensions/gradion|extensions/$name|g" \
    "s|package gradion|package $pkg|g" \
    "s|\"gradion\"|\"$name\"|g" \
    "s|TestNewDeclaresTheHouseUnit|TestNewDeclaresTheUnit|g" \
    "s|the Gradion house unit|the $name unit|g" \
    "s|The Gradion house unit|The $name unit|g" \
    "s|Package gradion is Gradion's house unit|Package $pkg is the $name unit|g" \
    "s|directory name gradion|directory name $name|g"
done < <(find "$SRC_EXT/$name" -type f)

echo "new-unit: created extensions/$name (package $pkg)"
echo
echo "next:"
echo "  \$EDITOR extensions/$name/$pkg.go   # declare what it does"
echo "  make u NAME=$name                   # its tests + the policy gates"
echo
echo "The manifest is generated: 'make compose' writes"
echo "extensions/$name/manifest.generated.json and it is committed with the unit."
