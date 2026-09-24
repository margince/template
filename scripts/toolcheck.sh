#!/usr/bin/env bash
# toolcheck.sh — the tools this repo's gates run under must be the ones CI runs.
#
# WHY. A local gate's whole promise is "this is what CI will say". pnpm 11
# stopped reading the `pnpm` field of package.json; a laptop on pnpm 10 read it,
# CI on 11 did not, and a change that was green locally failed in CI on an
# override that silently did not apply. Nothing warned, because both versions
# install successfully — they just resolve differently.
#
# The pinned version is READ FROM CORE rather than restated here — a second copy
# of that number is the thing that goes stale. WHICH file to read has flipped,
# and reading the old one is worse than reading nothing:
#
# This scraped the `version:` following `pnpm/action-setup` in core's frontend
# lane. Upstream then made `packageManager` in core/package.json the ONE pin
# ("read by corepack, by pnpm's own self-management and by pnpm/action-setup, so
# no environment picks a major off npm's release schedule") and REMOVED the
# workflow input, because a second source of that version is what
# ERR_PNPM_BAD_PM_VERSION is about — backend/gates/pnpmversionpins_test.go now
# fails a workflow that passes one.
#
# So the awk found no pnpm `version:` and fell through to the next `version:` in
# the file: `node-version: 24`. toolcheck then demanded pnpm 24 — a major
# nothing pins and which corepack would refuse against packageManager — and
# `make check` refused to start over a number that was Node's.
#
# MAJOR only. A patch difference is not a resolution difference, and demanding
# an exact match would fail on the day CI's floating pin moves.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

failures=0
manifest="$CORE/package.json"

if [ ! -f "$manifest" ]; then
  echo "toolcheck: core's package.json is missing — skipping the pnpm check"
  exit 0
fi

# packageManager is "pnpm@<version>", optionally with a +sha512 integrity
# suffix. Only the version is taken, and the caller compares majors.
want="$(sed -n 's/.*"packageManager"[[:space:]]*:[[:space:]]*"pnpm@\([0-9][0-9.]*\).*/\1/p' "$manifest" | head -n1)"
have="$(pnpm --version 2>/dev/null || true)"

if [ -z "$want" ]; then
  echo "toolcheck: could not read the pnpm version core's CI pins — check the lane file"
  failures=$((failures + 1))
elif [ -z "$have" ]; then
  printf 'toolcheck: pnpm is not installed, and CI runs pnpm %s.\n' "$want" >&2
  printf '  corepack enable && corepack prepare pnpm@%s --activate\n' "$want" >&2
  failures=$((failures + 1))
elif [ "${have%%.*}" != "${want%%.*}" ]; then
  printf 'toolcheck: pnpm %s locally, but CI runs pnpm %s.\n' "$have" "$want" >&2
  printf '\n' >&2
  printf '  This is not cosmetic. The two majors read different files for the same\n' >&2
  printf '  setting, so a lane can be green here and red in CI on a config nobody\n' >&2
  printf '  changed. Match it:\n' >&2
  printf '\n' >&2
  printf '    corepack enable && corepack prepare pnpm@%s --activate\n' "$want" >&2
  printf '\n' >&2
  printf '  corepack rather than `npm install -g`: packageManager is the pin, corepack\n' >&2
  printf '  reads it, and a global major that disagrees with it earns\n' >&2
  printf '  ERR_PNPM_BAD_PM_VERSION instead of a working tree.\n' >&2
  printf '\n' >&2
  failures=$((failures + 1))
else
  printf 'toolcheck: pnpm %s matches the %s.x CI runs\n' "$have" "${want%%.*}"
fi

[ "$failures" -eq 0 ] || exit 1
