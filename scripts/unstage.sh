#!/usr/bin/env bash
# Remove the units this repo staged into core/extensions/, restoring the
# submodule to a pristine upstream checkout. Driven by the marker written at
# stage time, so it can only ever delete directories we put there.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
[ -d "$CORE/.git" ] || [ -f "$CORE/.git" ] || exit 0

marker="$(marker_file)"
[ -f "$marker" ] || exit 0

while IFS= read -r unit; do
  [ -n "$unit" ] || continue
  # Refuse to delete anything upstream tracks, even if the marker names it.
  if git -C "$CORE" ls-files --error-unmatch "extensions/$unit" >/dev/null 2>&1; then
    echo "unstage: skipping extensions/$unit — upstream owns it" >&2
    continue
  fi
  rm -rf "${CORE_EXT:?}/$unit"
  echo "unstage: removed core/extensions/$unit"
done < "$marker"
# Remove the rules stage.sh added. Leaving them behind keeps a path hidden in
# the submodule after the unit that justified hiding it is gone.
exclude_block_clear "$(git -C "$CORE" rev-parse --git-dir)/info/exclude"
rm -f "$marker"
