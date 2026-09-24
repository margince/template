#!/usr/bin/env bash
# test-integration-ext.sh — the integration lane for OUR units.
#
# It exists because core's has a hole this repository cannot see from the
# outside: core/scripts/test-integration-parallel.sh sets GO_DIRS=(backend), so
# the lane that proves core against a real Postgres never discovers an
# extension module. A unit that ships migrations/ (for example acme-sync) is
# invisible to it, and until this lane nothing ever executed that SQL against a
# cluster.
#
# Every connection setting comes from core's own scripts/lib-testdb.sh —
# parse_test_dsn, db_admin, owner_clone_dsn. None is restated here. A second
# spelling of the DSN would be a second thing to drift from core's, and this
# repository already has one lane (toolcheck) whose whole job is catching that
# class of drift.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$SCRIPT_DIR/lib.sh"
require_core

COMPOSED_GOWORK="$CORE/build/composition/go.work"
[ -f "$COMPOSED_GOWORK" ] || die "test-integration-ext: no composed workspace — run 'make compose'"

# lib-testdb.sh's helpers cd into backend/ relative to the CORE ROOT, so it is
# sourced from there and every call is made from there.
cd "$CORE"
# shellcheck source=/dev/null
source scripts/lib-testdb.sh
parse_test_dsn

export GOWORK="$COMPOSED_GOWORK"

# Named for the lane, so it can never be confused with a dev stack's database
# and can be dropped without asking whose it is.
#
# The override is CONSTRAINED to that prefix, because the next two lines drop
# and recreate whatever it names. `EXT_IT_DB=margince` would have destroyed the
# developer's dev database, silently, from a variable that reads like a
# harmless knob. A lane allowed to drop a database must not be allowed to be
# pointed at an arbitrary one.
EXT_DB="${EXT_IT_DB:-margince_ext_it}"
case "$EXT_DB" in
  margince_ext_it|margince_ext_it_*) ;;
  *) die "test-integration-ext: EXT_IT_DB must be margince_ext_it or margince_ext_it_<suffix>, got '$EXT_DB' — this lane DROPS the database it names" ;;
esac
EXT_DSN="$(owner_clone_dsn "$EXT_DB")"

units="$(source_units)"
[ -n "$units" ] && printf 'test-integration-ext: units: %s\n' "$(printf '%s' "$units" | tr '\n' ' ')"

# A teardown that cannot drop leaves a database on the cluster. Reported and
# folded into the exit status rather than swallowed: a green run that leaked is
# indistinguishable from a clean one, and the leak survives to confuse the next.
LEAKED=0
cleanup() {
  if ! db_admin drop-db --name "$EXT_DB" >/dev/null 2>&1; then
    printf 'test-integration-ext: FAILED to drop %s — it is leaked on the cluster\n' "$EXT_DB" >&2
    LEAKED=1
  fi
}
trap 'cleanup; [ "$LEAKED" -eq 0 ] || exit 1' EXIT

printf '\n== leg 1: unit migrations apply against a real cluster\n'
db_admin drop-db --name "$EXT_DB" >/dev/null 2>&1 || true
db_admin recreate-db --name "$EXT_DB" >/dev/null

migrate_up() { ( cd backend && MARGINCE_OWNER_DSN="$EXT_DSN" go run ./cmd/migrate up ); }

first="$(migrate_up)"
printf '%s\n' "$first"

# The lane must prove OUR units' migrations ran, not merely that SOME migration
# did. Without this the gate goes vacuously green the moment a composition or
# staging regression drops unit migrations: core+custom still apply, the second
# run still reports zero, and the lane reports success having checked nothing
# about units — the exact shape .github/workflows/ci.yml warns about.
for unit in $units; do
  [ -d "$CORE_EXT/$unit/migrations" ] || continue
  ns="ext_$(printf '%s' "$unit" | tr '-' '_')"
  printf '%s' "$first" | grep -q "$ns" \
    || die "unit $unit ships migrations/ but '$ns' never appeared in the migrate output — its SQL was not applied"
done

# Re-applying must change NOTHING. core's own integration test asserts this
# shape for the composed lane (backend/cmd/migrate/main_integration_test.go),
# so a unit migration that is not idempotent is a real defect, not a style note.
second="$(migrate_up)"
printf '%s\n' "$second"
# core's own integration test asserts this exact sentence, so match it rather
# than a prefix: 'applied 0 ' alone would also match a line reporting zero core
# migrations while units applied work.
printf '%s' "$second" | grep -qE 'applied 0 core\+custom\+extension \+ 0 river' \
  || die "a second 'migrate up' applied work — a unit migration is not idempotent"

# UP ONLY, deliberately. backend/cmd/migrate/main.go hands down() the core and
# custom sets and nothing else, and main_integration_test.go records why: an
# extension migration is recorded in its own table precisely so a plain
# `migrate down` cannot revert it. There is no extension down lane to exercise,
# and inventing one here would be a second migration path for core's to drift
# from.

printf '\n== leg 2: unit integration tests\n'
ran=0
skipped=()
while IFS= read -r unit; do
  [ -n "$unit" ] || continue
  dir="$CORE_EXT/$unit"
  [ -d "$dir" ] || continue
  if ! grep -rlq '^//go:build integration' "$dir" --include='*_test.go' 2>/dev/null; then
    skipped+=("$unit")
    continue
  fi
  printf '  %s\n' "$unit"
  # BOTH DSNs, and both overridden rather than inherited. core's integration
  # contract uses the owner/app pair, and an ambient MARGINCE_TEST_APP_DSN in
  # the developer's shell would otherwise point a unit's RLS-bound test at
  # whatever database that names instead of this throwaway one.
  ( cd "$dir" \
      && MARGINCE_TEST_DSN="$EXT_DSN" \
         MARGINCE_TEST_APP_DSN="$(app_clone_dsn "$EXT_DB")" \
         go test -tags integration -count=1 ./... )
  ran=$((ran + 1))
done <<EOF
$units
EOF

# Reported by name, not passed over. This repository already makes the argument
# in .github/workflows/ci.yml: a gate that quietly checks nothing looks exactly
# like a passing one. No unit has an integration test today; the value of this
# leg is that the first one has somewhere to land and a database to land on.
if [ "$ran" -eq 0 ]; then
  printf '\n  NO unit declares an integration test (//go:build integration).\n'
  printf '  Units checked and found without one: %s\n' "${skipped[*]:-none}"
  printf '  Leg 1 above still executed their migrations against a real cluster.\n'
fi

printf '\ntest-integration-ext: ok (%s unit suite(s) ran)\n' "$ran"
