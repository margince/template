#!/usr/bin/env bash
# The release lane ships one macOS folder per architecture, and the expensive
# second one is gated on the first.
#
# The macOS bundle is whatever machine built it — the Go halves build native and
# PostgreSQL, pgvector and Valkey are compiled from source on the runner — so
# `arch` in desktop-macos.yml is not a label on the output, it IS the output.
# What that makes possible, and what this file exists for:
#
#   - a caller passing an `arch` the lane does not offer. The lane builds its
#     DEFAULT architecture and names the artifact after the one that was asked
#     for: an arm64 folder called `intel`, which is the original bug wearing the
#     fix's name. The lane also catches this at runtime with lipo; this catches
#     it in a second rather than in twenty minutes of macOS.
#   - a rename on one side only. The name a lane uploads and the name the
#     publish job downloads are two strings in two files that agree only by hand.
#   - the Intel build losing its gate. Both macOS jobs would then run in
#     parallel and a tree that cannot build an Apple-silicon folder would pay
#     for an Intel one too — macOS bills at ten times a Linux minute. Nothing
#     goes red; it just costs.
#   - publish downloading from a job it does not need. That one IS loud, but it
#     is loud during a release, which is the worst place to learn it.
#
# Usage: bash scripts/desktop-arch.test.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
WF="$HERE/../.github/workflows"
LANE="$WF/desktop-macos.yml"
REL="$WF/release.yml"

FAILURES=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }
ok()   { printf 'ok: %s\n' "$*"; }

# The enumeration lives in the dispatch form's `options:`. workflow_call cannot
# hold a choice, so that list is the only place the legal set is written down —
# which is exactly why a caller can pass something outside it.
offered="$(awk '/^ *options:/ {inside=1; next} inside && /^ *- / {print $2; next} inside {exit}' "$LANE")"
[ -n "$offered" ] || fail "desktop-macos.yml offers no arch options — the enumeration is gone"

# Every job in release.yml that calls the lane, and the arch it passes.
# One record per job: "<job> <arch>".
callers="$(awk '
  /^  [A-Za-z0-9_-]+:/ { job = $1; sub(/:$/, "", job); uses = 0; arch = "" }
  /uses: \.\/\.github\/workflows\/desktop-macos\.yml/ { uses = 1 }
  /^ *arch: / { arch = $2 }
  uses && arch { print job, arch; uses = 0; arch = "" }
' "$REL")"
[ -n "$callers" ] || fail "release.yml calls desktop-macos.yml with no arch at all"

# The body of one top-level job in release.yml: from its key to the next one.
job_body() { awk -v job="$1" '
  $0 ~ "^  " job ":" && !started { started = 1; print; next }
  started { if ($0 ~ /^  [A-Za-z0-9_-]+:/) exit; print }' "$REL"; }

publish="$(job_body publish)"

while read -r job arch; do
  [ -n "$job" ] || continue

  if printf '%s\n' "$offered" | grep -qx "$arch"; then
    ok "release.yml job '$job' passes arch '$arch', which the lane offers"
  else
    fail "release.yml job '$job' passes arch '$arch', which desktop-macos.yml does not offer.
      The lane would build its DEFAULT architecture and name the artifact after
      the one you asked for."
  fi

  if printf '%s\n' "$publish" | grep -q "name: margince-macos-$arch-"; then
    ok "publish downloads the $arch folder"
  else
    fail "publish downloads no artifact named margince-macos-$arch-*.
      The lane uploads one; a release that does not download it publishes
      without it."
  fi

  if printf '%s\n' "$publish" | grep -qE "needs:.*[][ ,]$job[],  ]" \
     || printf '%s\n' "$publish" | grep -qE "needs:.*[][ ,]$job\$"; then
    ok "publish needs '$job'"
  else
    fail "publish downloads from '$job' but does not list it in needs:."
  fi
done <<< "$callers"

# The gate. The Intel job costs a second macOS runner, so it must not start
# until the Apple-silicon one has proved the tree builds a folder at all.
first="$(printf '%s\n' "$callers" | awk '$2 == "apple-silicon" {print $1; exit}')"
second="$(printf '%s\n' "$callers" | awk '$2 == "intel" {print $1; exit}')"
if [ -z "$first" ] || [ -z "$second" ]; then
  fail "release.yml must call the lane for both apple-silicon and intel (got: $(printf '%s' "$callers" | tr '\n' ';'))"
elif job_body "$second" | grep -qE "needs:.*[][ ,]$first[],  ]|needs:.*[][ ,]$first\$"; then
  ok "'$second' is gated on '$first'"
else
  fail "'$second' does not list '$first' in its needs:.
      Both macOS jobs would then run in parallel, and a tree that cannot build
      an Apple-silicon folder would pay for an Intel one too."
fi

# ── the two platforms ship the same shape ────────────────────────────────────
#
# A downloader's Setup must be able to write a model binding, and
# `seeds.ai_routing` lives in margince.yaml — a file Setup NEVER overwrites.
# So a folder that ships one is a folder whose recipient cannot bind a model:
# their Setup says "already here — kept", the seed has nowhere to go, and the
# AI surfaces answer from the offline fake.
#
# The macOS lane ships none by accident of building elsewhere and copying only
# data/ back. The Windows lane runs Setup.cmd IN the folder to seed it, so it
# has to remove the file deliberately — and did not, for two releases, which is
# how one platform came up bound and the other did not from the same gesture.
WIN_LANE="$HERE/../.github/workflows/desktop-windows.yml"
if [ ! -f "$WIN_LANE" ]; then
  fail "no desktop-windows.yml to check"
elif grep -qE 'Remove-Item.*margince\.yaml' "$WIN_LANE"; then
  ok "the Windows lane does not ship margince.yaml"
else
  fail "the Windows lane ships margince.yaml.
      Setup never overwrites that file, so its downloader cannot write a model
      binding and their AI surfaces stay on the offline fake — while macOS,
      which ships none, comes up bound from the same gesture. Remove it before
      the zip, after the seed has consumed its write-once fields."
fi

# And the macOS lane must not START shipping one. It writes margince.yaml
# nowhere today; a step that did would reintroduce the same trap on the
# platform that never had it.
MAC_LANE="$HERE/../.github/workflows/desktop-macos.yml"
if [ -f "$MAC_LANE" ] && grep -qE '^[^#]*(cp|copy|Set-Content|>).*margince\.yaml' "$MAC_LANE"; then
  fail "the macOS lane now writes margince.yaml into the folder it zips. That
      file is what a recipient's Setup writes, and one that ships stops it."
else
  ok "the macOS lane still ships no margince.yaml"
fi

# ── the dataset is a BUILD input, not just a seed input ──────────────────────
#
# Upstream #4732 moved the dataset loader out of core, so the kit builds the
# seeder FROM the dataset checkout. A lane that checks the dataset out AFTER
# stamping the kit produces a folder with no loader — and its own seed step
# then refuses, because `desktop-seed` drives the loader inside the folder
# rather than keeping a seeding path of its own. That is what killed the first
# two attempts at v0.1.1-rc.3, once per platform.
#
# Held as ORDER, because both lanes had every step they needed and ran them in
# the wrong sequence.
for lane in desktop-macos desktop-windows; do
  f="$HERE/../.github/workflows/$lane.yml"
  [ -f "$f" ] || { fail "no $lane.yml"; continue; }
  checkout="$(grep -n 'name: Check out the demo dataset' "$f" | cut -d: -f1 | head -1)"
  # macOS builds and stamps in one `make desktop`; Windows stamps separately.
  consumer="$(grep -nE 'name: (Build the bundle|Stamp the demo-data loader)' "$f" | cut -d: -f1 | tail -1)"
  if [ -z "$checkout" ] || [ -z "$consumer" ]; then
    fail "$lane.yml: cannot find both the dataset checkout and the step that builds the seeder"
  elif [ "$checkout" -lt "$consumer" ]; then
    ok "$lane checks the dataset out before it builds the seeder"
  else
    fail "$lane.yml checks the dataset out at line $checkout, AFTER the step at
      line $consumer that builds the seeder from it. The folder ships with no
      loader and the seed step refuses. Move the checkout above it."
  fi
done

if [ "$FAILURES" -gt 0 ]; then
  printf '\n%d check(s) failed\n' "$FAILURES" >&2
  exit 1
fi
printf '\ndesktop-arch: all checks passed\n'
