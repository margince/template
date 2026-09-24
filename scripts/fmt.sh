#!/usr/bin/env bash
# fmt.sh — format our unit sources in place.
#
# gofmt, not gofumpt: gofmt is the bar core's own gate holds
# (scripts/check-gofmt.sh states that gofumpt's stricter set is deliberately not
# it), and a formatter stricter than the gate would rewrite files nothing asked
# to change.
#
# Biome runs twice, and the order matters: `check --write` applies the SAFE lint
# fixes, then `format --write` settles the layout the fixes just changed.
# Unsafe fixes are never applied — those change behaviour, and a formatter must
# not.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GOFMT="${GOFMT:-gofmt}"
BIOME="$CORE/frontend/node_modules/.bin/biome"

echo "== gofmt -w"
changed="$(find "$SRC_EXT" -name '*.go' -not -path '*/node_modules/*' -print0 \
  | xargs -0 "$GOFMT" -l -w 2>/dev/null || true)"
if [ -n "$changed" ]; then
  printf '%s\n' "$changed" | sed "s|^$ROOT/|  rewrote |"
else
  echo "  nothing to rewrite"
fi

if [ -x "$BIOME" ] && ls -d "$SRC_EXT"/*/frontend >/dev/null 2>&1; then
  echo "== biome"
  "$BIOME" check --write --config-path "$CORE/frontend" "$SRC_EXT"/*/frontend 2>&1 | tail -2 | sed 's/^/  /'
  "$BIOME" format --write --config-path "$CORE/frontend" "$SRC_EXT"/*/frontend 2>&1 | tail -2 | sed 's/^/  /'
else
  echo "== biome: skipped (not installed, or no unit ships a frontend/)"
fi

echo
echo "fmt: done — 'make lint' is the gate that has to agree"
