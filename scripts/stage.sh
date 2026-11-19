#!/usr/bin/env bash
# Copy this repo's units into core/extensions/ so the upstream composer can
# see them.
#
# Why a COPY and not a symlink: gen-composition refuses a symlinked entry
# outright ("a symlinked entry is not composable — an enabled unit is a plain
# directory tree", backend/tools/gen-composition/scan.go). Upstream's own CI
# stages its reference fixture the same way (`cp -R fixtures/extensions/
# crm-hello extensions/`), so this is the sanctioned shape, not a workaround.
#
# The submodule work tree is scratch space. Nothing staged is ever committed
# there — the source of truth for every unit is extensions/ in THIS
# repo, and the submodule pointer only ever records an upstream commit.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_core
assert_core_clean "$CORE" "$(marker_file)"

marker="$(marker_file)"
: > "$marker"

units="$(source_units)"
if [ -z "$units" ]; then
  echo "stage: no units under extensions/ — composing the vanilla core"
  exit 0
fi

while IFS= read -r unit; do
  [ -n "$unit" ] || continue

  # The unit-name grammar is upstream's, enforced at scan time AND at boot.
  # Catching it here turns a confusing composer failure into a clear one.
  if ! printf '%s' "$unit" | grep -Eq '^[a-z0-9]+(-[a-z0-9]+)*$'; then
    die "extensions/$unit: name must match ^[a-z0-9]+(-[a-z0-9]+)*\$ (lower-case segments joined by single hyphens)"
  fi
  [ "${#unit}" -le 32 ] || die "extensions/$unit: name exceeds 32 characters"

  # A local unit must never shadow an upstream one. Upstream ships units
  # under extensions/ in the vanilla tree (de, notes, ...); silently
  # overwriting one would replace core behaviour with ours and leave no trace.
  if [ -e "$CORE_EXT/$unit" ] && ! grep -qxF "$unit" "$marker" 2>/dev/null; then
    if git -C "$CORE" ls-files --error-unmatch "extensions/$unit" >/dev/null 2>&1; then
      die "extensions/$unit collides with an upstream unit of the same name — rename ours"
    fi
  fi

  copy_unit_tree "$SRC_EXT/$unit" "$CORE_EXT/$unit"
  printf '%s\n' "$unit" >> "$marker"
  echo "stage: extensions/$unit -> core/extensions/$unit"
done <<< "$units"

# A core that reads the enabled set from instance/go.mod composes only the units that file requires, so require ours.
# Each unit is replaced onto its staged folder, the way core's own units are. The file is restored by unstage.sh.
instance_gomod="$CORE/instance/go.mod"
if [ -f "$instance_gomod" ]; then
  git -C "$CORE" checkout --quiet -- instance/go.mod
  req="" rep=""
  while IFS= read -r unit; do
    [ -n "$unit" ] || continue
    grep -q "margince/extensions/$unit " "$instance_gomod" && continue
    req="$req	github.com/margince/margince/extensions/$unit v0.0.0
"
    rep="$rep	github.com/margince/margince/extensions/$unit => ../extensions/$unit
"
  done <<< "$units"
  if [ -n "$req" ]; then
    # Not awk -v: the macOS awk refuses a newline in a variable.
    printf '%s' "$req" > "$instance_gomod.req"; printf '%s' "$rep" > "$instance_gomod.rep"
    awk -v reqf="$instance_gomod.req" -v repf="$instance_gomod.rep" '
      function dump(f,  l) { while ((getline l < f) > 0) print l; close(f) }
      /^require \(/ { print; dump(reqf); next }
      /^replace \(/ { print; dump(repf); next }
      { print }' "$instance_gomod" > "$instance_gomod.new" && mv "$instance_gomod.new" "$instance_gomod"
    rm -f "$instance_gomod.req" "$instance_gomod.rep"
    : > "$(instance_edit_marker)"
    echo "stage: instance/go.mod requires the staged units"
  fi
fi

# Keep the submodule's `git status` clean. See exclude_block_write in lib.sh.
#
# A while-read loop, NOT mapfile: mapfile is bash 4+ and this machine's only
# bash is 3.2.57. Core states the same rule at
# frontend/scripts/check-ext-imports.sh:39 — "read -a rather than mapfile:
# mapfile is bash 4+, and the shells this repo's gates actually run under
# include macOS's bash 3.2."
staged_units=()
while IFS= read -r staged_unit; do
  [ -n "$staged_unit" ] && staged_units+=("$staged_unit")
done < "$marker"
# "${arr[@]}" on an EMPTY array is an unbound-variable error under `set -u` in
# bash 3.2, so guard rather than expanding blind.
if [ ${#staged_units[@]} -gt 0 ]; then
  exclude_block_write "$(git -C "$CORE" rev-parse --git-dir)/info/exclude" "${staged_units[@]}"
else
  exclude_block_clear "$(git -C "$CORE" rev-parse --git-dir)/info/exclude"
fi
