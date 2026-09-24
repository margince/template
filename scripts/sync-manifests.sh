#!/usr/bin/env bash
# gen-composition derives each unit's manifest.generated.json NEXT TO THE UNIT
# — which, for us, means inside the staged copy. Copy it back so the manifest
# is committed alongside the unit's source in this repo, the way upstream
# commits it alongside its own units. The manifest is what an operator reads
# to see a unit's risk tiers, secrets and subscriptions before enabling it, so
# it belongs in review, not in scratch space.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

marker="$(marker_file)"
[ -f "$marker" ] || exit 0

while IFS= read -r unit; do
  [ -n "$unit" ] || continue
  src="$CORE_EXT/$unit/manifest.generated.json"
  [ -f "$src" ] || continue
  if ! cmp -s "$src" "$SRC_EXT/$unit/manifest.generated.json" 2>/dev/null; then
    cp "$src" "$SRC_EXT/$unit/manifest.generated.json"
    echo "sync-manifests: updated extensions/$unit/manifest.generated.json"
  fi
done < "$marker"
