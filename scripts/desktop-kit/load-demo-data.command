#!/usr/bin/env bash
# Load Demo Data.command — fill THIS installation from the demo dataset.
#
# Double-click it, or run it from a terminal. It lives inside the installation
# it seeds, which is the whole design: every fact it needs is a file beside it,
# so it works from a downloaded folder with no repository, no Go toolchain and
# no make.
#
#   the port          margince.env (MARGINCE_PORT), 8800 if unset
#   the account       margince.yaml (bootstrap_admin.email)
#   its password      data/admin-password, probed against the api
#   the database      data/sockets, the launcher's own unix socket directory
#   the dataset       data/demo, inside the installation
#
# The repository half of this pair is scripts/desktop.sh, which now delegates
# `make desktop-seed` HERE rather than keeping a second seeding path of its own.
# There is one seeding path and users and developers both run it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

# Double-clicked, Finder gives this a Terminal window that closes the moment the
# script returns — taking every line of output with it. The pause at the end is
# the only thing that lets a user READ a failure. desktop.sh sets this to skip
# it, because a make lane is not a window anyone is looking at.
INTERACTIVE="${MARGINCE_KIT_INTERACTIVE:-1}"

SEEDED_PASSWORD="demo-password-123"

say() { printf '%s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; finish 1; }

finish() {
  local code="${1:-0}"
  if [ "$INTERACTIVE" = "1" ] && [ -t 0 ]; then
    printf '\nPress Return to close this window. '
    read -r _ || true
  fi
  exit "$code"
}

usage() {
  cat >&2 <<'EOF'
usage: "Load Demo Data.command" [--dataset PATH] [--verify] [seeder flags...]

  --dataset PATH   the demo database checkout (default: ./data/demo)
  --verify         check an already-seeded installation, write nothing

  Anything else is passed to the seeder: -limit N, -dry-run.
EOF
  exit 2
}

# ─────────────────────────── reading the installation ─────────────────────

# Only an UNcommented assignment counts. The generated margince.env documents
# every setting as a comment, so a naive grep reports the default as configured.
env_value() {
  local file="$ROOT/margince.env" key="$1"
  [ -f "$file" ] || return 0
  sed -n "s/^[[:space:]]*$key[[:space:]]*=[[:space:]]*\(.*\)/\1/p" "$file" | tail -n1
}

app_port() {
  local port
  port="$(sed -n 's/^[[:space:]]*MARGINCE_PORT[[:space:]]*=[[:space:]]*\([0-9]\{1,\}\).*/\1/p' \
    "$ROOT/margince.env" 2>/dev/null | tail -n1)"
  printf '%s\n' "${port:-8800}"
}

app_url() { printf 'http://127.0.0.1:%s\n' "$(app_port)"; }

# The user may have edited bootstrap_admin before the first launch, so this is
# read rather than assumed.
app_email() {
  local email
  email="$(sed -n 's/^[[:space:]]*email:[[:space:]]*\([^[:space:]]\{1,\}\).*/\1/p' \
    "$ROOT/margince.yaml" 2>/dev/null | head -n1)"
  printf '%s\n' "${email:-owner@margince.local}"
}

app_currency() {
  local cur
  cur="$(sed -n 's/^[[:space:]]*base_currency:[[:space:]]*\([A-Za-z]\{3\}\).*/\1/p' \
    "$ROOT/margince.yaml" 2>/dev/null | head -n1)"
  printf '%s\n' "${cur:-USD}"
}

# The owner DSN over this installation's own unix socket, in the launcher's
# spelling (desktop/launcher/postgres_unix.go). Local socket auth is trust, so
# there is no password to find. Without it the seeder skips teams, seats,
# finance links and facts and then dies in the ownership pass with "no seats to
# own anything" — so it is not optional.
owner_dsn() { printf 'postgres://margince_owner@/margince?host=%s/data/sockets\n' "$ROOT"; }

app_running() {
  curl -fsS -o /dev/null --max-time 2 "$(app_url)" 2>/dev/null && return 0
  # A running installation that answers 404 on / is still running: only a
  # connection failure means "not up".
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$(app_url)" 2>/dev/null || true)"
  [ -n "$code" ] && [ "$code" != "000" ]
}

login_works() {
  # These two characters are the only ones that would break the hand-built JSON,
  # and neither appears in a launcher-generated password or in SEEDED_PASSWORD.
  case "$1" in *[\"\\]*) return 1 ;; esac
  curl -fsS -o /dev/null --max-time 10 \
    -X POST -H 'Content-Type: application/json' \
    -d "{\"email\":\"$(app_email)\",\"password\":\"$1\"}" \
    "$(app_url)/v1/auth/login" 2>/dev/null
}

# The password that signs in RIGHT NOW, which is why this probes instead of
# reading: after the first seed, data/admin-password is stale. Nothing rewrites
# it — the file is the launcher's record of what it generated, not a live
# credential store — and the seeder must replace the bootstrap credential,
# because the product puts a configured bootstrap on must_change_password and
# refuses every write until it is really replaced.
app_password() {
  if [ -n "${MARGINCE_SEED_PASSWORD:-}" ]; then
    printf '%s\n' "$MARGINCE_SEED_PASSWORD"
    return 0
  fi
  local file="$ROOT/data/admin-password" from_file=""
  [ -f "$file" ] && from_file="$(tr -d '\n' <"$file")"
  if [ -n "$from_file" ] && login_works "$from_file"; then
    printf '%s\n' "$from_file"
  elif login_works "$SEEDED_PASSWORD"; then
    printf '%s\n' "$SEEDED_PASSWORD"
  else
    die "$(printf 'neither data/admin-password nor the seeded password signs in as %s.\nIf you changed it, pass it in:\n  MARGINCE_SEED_PASSWORD=... "%s"' \
      "$(app_email)" "$ROOT/Load Demo Data.command")"
  fi
}

# ────────────────────────────────── dataset ───────────────────────────────

# The dataset is NOT shipped: it is a private repository, and a folder anyone
# can download is not where it belongs. So this looks for what the README asks
# the user to copy in — either the checkout's contents in data/demo, or the
# checkout itself dropped inside it under whatever name it arrived with.
find_dataset() {
  local given="${1:-}"
  if [ -n "$given" ]; then
    [ -f "$given/datasets/v1/demo.json" ] || die "no demo dataset at $given (expected datasets/v1/demo.json inside it)"
    printf '%s\n' "$given"
    return 0
  fi

  local candidate
  if [ -f "$ROOT/data/demo/datasets/v1/demo.json" ]; then
    printf '%s\n' "$ROOT/data/demo"
    return 0
  fi
  for candidate in "$ROOT"/data/demo/*/; do
    [ -f "$candidate/datasets/v1/demo.json" ] || continue
    printf '%s\n' "${candidate%/}"
    return 0
  done

  die "$(printf 'no demo dataset in %s/data/demo\n\nCopy the demo database folder into:\n    %s/data/demo\n\nSee README.md beside this file.' "$ROOT" "$ROOT")"
}

# ─────────────────────────────────── seed ─────────────────────────────────

main() {
  local dataset_arg="" verify=no
  local pass=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --dataset) [ $# -ge 2 ] || usage; dataset_arg="$2"; shift 2 ;;
      --verify)  verify=yes; shift ;;
      -h|--help) usage ;;
      *)         pass+=("$1"); shift ;;
    esac
  done

  [ -x "$ROOT/runtime/seed-demo" ] || die "$(printf 'this installation has no seeder at runtime/seed-demo.\nIt was built before the demo loader existed — reinstall from a newer build.')"

  # A path with whitespace cannot go into the DSN's host= query as-is, and
  # quietly seeding nowhere is worse than refusing.
  case "$ROOT" in
    *[[:space:]]*) die "this folder's path contains a space, which the database socket cannot use: $ROOT" ;;
  esac

  local dataset; dataset="$(find_dataset "$dataset_arg")"

  app_running || die "$(printf 'Margince is not running.\nStart it first — double-click "Start Margince.command" — then run this again.')"

  # Said BEFORE the run rather than discovered during it: with a non-EUR base
  # the seeder writes companies, people and employments and only then hits the
  # FX phase, so the failure arrives after several minutes of apparent success.
  if [ "$(app_currency)" != "EUR" ]; then
    say "WARNING — this installation's base currency is $(app_currency) and the demo dataset is euro-based."
    say "          The FX step will be refused after most of the dataset is written."
    say "          margince.yaml is written once and the workspace came from it, so a"
    say "          euro installation means a fresh one: quit Margince, delete data/ and"
    say "          margince.yaml, set base_currency: EUR, and start it again."
    say ""
  fi

  local password; password="$(app_password)"

  # The seeder writes company logos itself, through the same blobstore the api
  # reads, so passing this installation's own directory is all that stands
  # between "logos: skipped" and the real thing. An installation whose
  # margince.env names a real endpoint has that read out of the file instead.
  local blob_endpoint blob_path
  blob_endpoint="$(env_value MARGINCE_BLOBSTORE_ENDPOINT)"
  blob_path="$(env_value MARGINCE_BLOBSTORE_PATH)"
  if [ -z "$blob_endpoint" ] && [ -z "$blob_path" ]; then
    blob_path="$ROOT/data/blobs"
  fi

  local args=(-dataset "$dataset" -api "$(app_url)" -email "$(app_email)")
  [ "$verify" = yes ] && args+=(-verify-only)
  [ ${#pass[@]} -gt 0 ] && args+=("${pass[@]}")

  if [ "$verify" = yes ]; then
    say "Checking $(app_url) against $dataset"
  else
    say "Loading $dataset into $(app_url)"
    say "This takes a few minutes. Leave Margince running."
  fi
  say ""

  MARGINCE_SEED_PASSWORD="$password" \
  MARGINCE_SEED_DSN="$(owner_dsn)" \
  MARGINCE_BLOBSTORE_ENDPOINT="$blob_endpoint" \
  MARGINCE_BLOBSTORE_PATH="$blob_path" \
  MARGINCE_BLOBSTORE_ACCESS_KEY="$(env_value MARGINCE_BLOBSTORE_ACCESS_KEY)" \
  MARGINCE_BLOBSTORE_SECRET_KEY="$(env_value MARGINCE_BLOBSTORE_SECRET_KEY)" \
  MARGINCE_BLOBSTORE_BUCKET="$(env_value MARGINCE_BLOBSTORE_BUCKET)" \
  MARGINCE_BLOBSTORE_REGION="$(env_value MARGINCE_BLOBSTORE_REGION)" \
    "$ROOT/runtime/seed-demo" "${args[@]}"

  say ""
  if [ "$verify" = yes ]; then
    say "Checked. Nothing was written."
  else
    say "Done. Sign in at $(app_url)"
    say "  $(app_email) / $SEEDED_PASSWORD"
    say ""
    say "The loader replaced the sign-in password, so data/admin-password is no"
    say "longer current. The seeded colleagues sign in with password \"1234\"."
  fi
  finish 0
}

main "$@"
