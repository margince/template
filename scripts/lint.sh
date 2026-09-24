#!/usr/bin/env bash
# lint.sh — the same quality tier core holds its own units to, over OURS.
#
# WHY THIS EXISTS. Core's gates cannot see our units, and not by oversight:
# check-lint-modules.sh and check-gofmt.sh both enumerate with `git ls-files`,
# which lists what CORE tracks. Our units are staged copies — untracked there —
# so golangci-lint and the gofmt gate walk straight past them. Measured, not
# assumed: core's lint-modules linted relay-probe (tracked upstream) and none of
# ours. The craft gate walks the filesystem instead, so it does cover a staged
# unit, but only while it is staged and `check` pass 1 runs unstaged.
#
# Same tools, same configs, one config per tool — a per-repo golangci config
# would have to restate core's baseline and would drift from it.
#
# Go code is linted through the ROOT go.work (scripts/gowork.sh), which makes our
# SOURCES type-checkable. That is what lets findings name extensions/<unit>/… —
# linting the staged copies would name a path nobody may edit.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_core

GO_BIN="${GO:-go}"
GOLANGCI="${GOLANGCI_LINT:-$("$GO_BIN" env GOPATH 2>/dev/null)/bin/golangci-lint}"
GOFMT="${GOFMT:-gofmt}"
BIOME="$CORE/frontend/node_modules/.bin/biome"
failures=0

fail() { printf '\nFAIL: %s\n' "$*" >&2; failures=$((failures + 1)); }

# gofmt first: it needs no toolchain, no workspace and no install, so a
# formatting finding arrives before anything slow runs.
echo "== gofmt"
unformatted="$(find "$SRC_EXT" -name '*.go' -not -path '*/node_modules/*' -print0 \
  | xargs -0 "$GOFMT" -l 2>/dev/null || true)"
if [ -n "$unformatted" ]; then
  printf '%s\n' "$unformatted" | sed "s|^$ROOT/|  |"
  fail "gofmt would rewrite the files above — run 'make fmt'"
else
  echo "  every .go file under extensions/ is gofmt-clean"
fi

echo "== golangci-lint (per unit module, core's config)"
if [ ! -x "$GOLANGCI" ]; then
  fail "golangci-lint not found at $GOLANGCI — run 'make init' (core's 'make tools' installs the pinned version)"
else
  [ -f "$ROOT/go.work" ] || bash "$(dirname "${BASH_SOURCE[0]}")/gowork.sh"
  while IFS= read -r unit; do
    [ -n "$unit" ] || continue
    [ -f "$SRC_EXT/$unit/go.mod" ] || continue
    printf '  %s: ' "$unit"
    # Through core's wrapper: it diagnoses the machine-wide cache answering from
    # another checkout, which is a real failure mode here and unreadable without it.
    if ! out="$(cd "$SRC_EXT/$unit" && GOWORK="$ROOT/go.work" GOLANGCI_LINT="$GOLANGCI" \
        bash "$CORE/scripts/run-golangci.sh" run --config "$CORE/backend/.golangci.yml" ./... 2>&1)"; then
      printf '\n'
      printf '%s\n' "$out" | sed 's/^/    /'
      fail "golangci-lint findings in extensions/$unit"
    else
      printf '%s\n' "$(printf '%s' "$out" | tail -1)"
    fi
  done <<EOF
$(source_units)
EOF
fi

echo "== craft (code-craftsmanship gate)"
# craft is a PINNED BINARY, not a module in the tree: core resolves it through
# scripts/craft-pin.sh, which downloads the version that script names and
# verifies its sha256. Run from $CORE because the script resolves its cache
# relative to core's own root; --root stays ours, so findings name
# extensions/<unit>/… rather than a staged copy.
craft_bin="$(cd "$CORE" && ./scripts/craft-pin.sh)"
if ! out="$("$craft_bin" static --strict --root "$SRC_EXT" 2>&1)"; then
  printf '%s\n' "$out" | sed 's/^/  /'
  fail "craft findings under extensions/"
else
  printf '%s\n' "$out" | tail -1 | sed 's/^/  /'
fi

echo "== biome (unit frontends, core's config)"
if [ ! -x "$BIOME" ]; then
  echo "  SKIP: biome is not installed — run 'make fe-install'"
elif ! ls -d "$SRC_EXT"/*/frontend >/dev/null 2>&1; then
  echo "  no unit ships a frontend/"
else
  if ! out="$("$BIOME" check --config-path "$CORE/frontend" "$SRC_EXT"/*/frontend 2>&1)"; then
    printf '%s\n' "$out" | sed 's/^/  /'
    fail "biome findings under extensions/*/frontend — 'make fmt' fixes the safe ones"
  else
    printf '%s\n' "$out" | tail -2 | sed 's/^/  /'
  fi
fi

if [ "$failures" -gt 0 ]; then
  printf '\nlint: %s check(s) failed\n' "$failures" >&2
  exit 1
fi
printf '\nlint: clean\n'
