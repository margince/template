#!/usr/bin/env bash
# desktop.sh — install, run, seed and inspect the built desktop folder.
#
# `make desktop` produces a folder; everything a developer then wants to DO with
# it was a paragraph of prose and a five-line shell command. The gestures below
# are that prose, executable:
#
#   install   copy the build somewhere it can actually run, or update a copy
#   run       start it
#   connect   start it behind a public address, for Claude
#   seed      fill it from the commercial demo dataset
#   status    where it is, whether it is up, how to sign in
#   logins    which accounts exist and what their passwords are
#   psql/dsn  its database, from psql or from a GUI client
#
# Why a script and not eight Makefile recipes: every one of them needs the same
# four facts, and each fact is read from the INSTALLATION rather than from this
# repository — the port from margince.env, the sign-in address from
# margince.yaml, the password from data/admin-password, the database socket from
# data/sockets. Computing those in make would mean either $(shell) at parse time
# (wrong: they change while make runs, and a missing install would error on
# every unrelated target) or the same $$(...) subshell repeated per recipe.
#
# The installation is the user's, not a build artifact: data/, margince.yaml and
# margince.env are never overwritten here. That is upstream's update contract —
# core/docs/how-to/build-the-desktop-app.md, "Update an installation" — and
# `install` implements exactly it.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
# shellcheck source=scripts/lib.sh
. scripts/lib.sh

SRC="build/desktop/margince"

# DEST is where the installation lives. ~/Margince is short, outside the repo
# and outside any sync folder, which is the whole of what the socket limit and
# the "never writes outside its folder" promise ask for.
DEST="${DEST:-$HOME/Margince}"
DEST="${DEST%/}"

# macOS caps a unix socket path at 103 bytes. The launcher puts the database
# socket at <root>/data/sockets/.s.PGSQL.5432 — 27 bytes — so the root has 76.
# The launcher measures this too and refuses; we measure it BEFORE copying
# 163 MB somewhere that cannot start.
SOCKET_TAIL=27
SOCKET_LIMIT=103

# The demo dataset is euro-based: seedFxRates (core/backend/tools/seed-demo/fx.go)
# loads a rate for every non-EUR currency it meets, and the api refuses a rate
# whose from_currency IS the base currency ("the rate is always 1"). So a USD
# installation — the launcher's default — cannot finish a seed: it dies at the FX
# phase with 422 fx_rate_base_self, after having written most of the dataset.
#
# margince.yaml is created ONCE, on the first launch, and never overwritten,
# and the workspace is bootstrapped from it. So the currency has to be right
# BEFORE the first run, which is the only moment `install` still owns.
CURRENCY="${CURRENCY:-EUR}"

usage() {
  cat >&2 <<'EOF'
usage: desktop.sh <install|run|seed|verify|status|logins|psql|dsn|kit>

  install   copy build/desktop/margince to $DEST (default ~/Margince).
            An existing installation is UPDATED: the launcher, the starter, the
            demo loader and runtime/ are replaced; data/ (the dataset in
            data/demo included), margince.yaml and margince.env are not.
  run       start the installation at $DEST in the foreground.
  connect   the same, behind a public tunnel address, with the MCP connector
            on so Claude or ChatGPT can reach it.
  seed      fill the running installation from the demo dataset ($DATASET).
  verify    re-run the seeder's verify pass, writing nothing.
  kit       stamp the demo loader and the build info into a built folder:
              kit --dir <folder> --os <darwin|windows> [--version <v>]
  status    where it is, whether it is running, how to sign in.
  logins    every account that can sign in, and its password.
  psql      open psql on its database, using the psql it ships.
  dsn       print how to connect a database client to it.
EOF
  exit 2
}

# ─────────────────────────── reading the install ──────────────────────────

require_install() {
  [ -d "$DEST" ] || die "no installation at $DEST — run 'make desktop-install'"
  [ -x "$DEST/margince" ] || die "$DEST has no launcher — run 'make desktop-install'"
}

# The port the launcher will listen on: margince.env wins, 8800 is its default.
# Only an UNcommented assignment counts — the generated file documents every
# setting as a comment, so a naive grep reports 8800 as configured everywhere.
desktop_port() {
  local env_file="$DEST/margince.env" port=""
  if [ -f "$env_file" ]; then
    port="$(sed -n 's/^[[:space:]]*MARGINCE_PORT[[:space:]]*=[[:space:]]*\([0-9]\{1,\}\).*/\1/p' "$env_file" | tail -n1)"
  fi
  printf '%s\n' "${port:-8800}"
}

desktop_url() { printf 'http://127.0.0.1:%s\n' "$(desktop_port)"; }

# The sign-in address is the launcher's bootstrap_admin, which the user may have
# edited before the first launch. Read it rather than assuming the default.
desktop_email() {
  local yaml="$DEST/margince.yaml" email=""
  if [ -f "$yaml" ]; then
    email="$(sed -n 's/^[[:space:]]*email:[[:space:]]*\([^[:space:]]\{1,\}\).*/\1/p' "$yaml" | head -n1)"
  fi
  printf '%s\n' "${email:-owner@margince.local}"
}

# data/admin-password is the ONLY copy of the launcher's password. Read, never
# written — the file is the user's.
desktop_file_password() {
  local file="$DEST/data/admin-password"
  [ -f "$file" ] || die "no $file — start it once ('make desktop-run') so it creates the account"
  tr -d '\n' <"$file"
}

# SEEDED_PASSWORD is where the seeder LEAVES the account. It replaces the
# bootstrap credential — the product puts a configured bootstrap on
# must_change_password and refuses every write until it is really replaced, so
# this is not a convenience the seeder could skip — and lands on the one value
# core documents (tools/seed-demo/apiclient.go, scripts/seed-dev.sh).
#
# The consequence is local and easy to trip over: after the first seed,
# data/admin-password is STALE. Nothing rewrites it, because the file is the
# launcher's record of what it generated, not a live credential store.
SEEDED_PASSWORD="demo-password-123"

api_login_works() {
  local password="$1"
  # Quoting: these two are the only characters that would break the hand-built
  # JSON below, and neither appears in a launcher-generated password or in
  # SEEDED_PASSWORD. A password carrying one is the caller's to pass explicitly.
  case "$password" in *[\"\\]*) return 1 ;; esac
  curl -fsS -o /dev/null --max-time 10 \
    -X POST -H 'Content-Type: application/json' \
    -d "{\"email\":\"$(desktop_email)\",\"password\":\"$password\"}" \
    "$(desktop_url)/v1/auth/login" 2>/dev/null
}

# The password that actually signs in right now, which is why this probes
# instead of reading. An explicit MARGINCE_SEED_PASSWORD always wins.
desktop_password() {
  if [ -n "${MARGINCE_SEED_PASSWORD:-}" ]; then
    printf '%s\n' "$MARGINCE_SEED_PASSWORD"
    return 0
  fi
  local file_password
  file_password="$(desktop_file_password)"
  if api_login_works "$file_password"; then
    printf '%s\n' "$file_password"
  elif api_login_works "$SEEDED_PASSWORD"; then
    printf '%s\n' "$SEEDED_PASSWORD"
  else
    die "$(printf 'neither data/admin-password nor the seeded password signs in as %s.\nPass the one that does:\n  MARGINCE_SEED_PASSWORD=... make desktop-seed' "$(desktop_email)")"
  fi
}

# The owner DSN over the installation's own unix socket, in the launcher's own
# spelling (desktop/launcher/postgres_unix.go). Local socket auth is trust, so
# there is no password to find. Without this the seeder skips teams, seats,
# finance links and facts, then dies in the ownership pass with "no seats to own
# anything" — so it is not optional, which is why nothing here makes it a flag.
desktop_dsn() {
  printf 'postgres://margince_owner@/margince?host=%s/data/sockets\n' "$DEST"
}

desktop_running() {
  curl -fsS -o /dev/null --max-time 2 "$(desktop_url)" 2>/dev/null && return 0
  # A running installation that answers 404 on / is still running. curl -f
  # reports the status, so only a connection failure means "not up".
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "$(desktop_url)" 2>/dev/null || true)"
  [ -n "$code" ] && [ "$code" != "000" ]
}

# A path with whitespace in it cannot go into the DSN's host= query as-is, and
# quietly seeding nowhere is worse than refusing.
assert_dest_sane() {
  case "$DEST" in
    *[[:space:]]*) die "the installation path contains whitespace, which the database socket cannot use: $DEST" ;;
  esac
  local len=$(( ${#DEST} + SOCKET_TAIL ))
  if [ "$len" -gt "$SOCKET_LIMIT" ]; then
    die "$(printf 'the installation path is too long: the database socket would be %s bytes and the system limit is %s.\n  %s\nChoose a shorter DEST, e.g. make desktop-install DEST=~/M' "$len" "$SOCKET_LIMIT" "$DEST")"
  fi
}

# ────────────────────────────────── install ───────────────────────────────

# Everything upstream calls replaceable on an update. Anything NOT in this list
# is the user's: data/ is the database, margince.yaml and margince.env are their
# settings.
# BUILD-INFO.txt is HERE and not among the keep-what-exists files below: it
# describes the programs, and the programs are what an update replaces. Left
# behind, it would name the version the installation no longer runs — which is
# worse than not saying, because somebody would quote it in a bug report.
REPLACEABLE=(margince "Start Margince.command" "Load Demo Data.command" "Setup.command" \
  "Connect to Claude.command" README.md BUILD-INFO.txt runtime)

# run_setup hands the installation to the Setup.command inside it.
#
# THE SAME SCRIPT A DOWNLOADER RUNS, for the reason `make desktop-seed` already
# delegates to the loader beside it: the configuration a developer gets and the
# configuration a recipient gets must be one thing, or the two drift and only one
# of them is the one anybody tests. The admin address moved once already, and a
# second spelling here is a second place to forget it.
#
# --no-prompt because a make lane must not block asking for a vendor credential,
# and MARGINCE_KIT_INTERACTIVE=0 because a lane is not a window anyone is
# looking at. What is left is exactly the part a developer needs: this
# installation's own keys, and a margince.yaml with the currency and the admin
# address the demo dataset expects.
#
# A folder built before this script shipped has no Setup.command. That is not a
# reason to fail an install — the launcher still writes its own margince.env and
# margince.yaml on the first start — so it is reported and skipped, naming what
# the installation will be missing.
run_setup() {
  local setup="$DEST/Setup.command"
  if [ ! -f "$setup" ]; then
    printf 'desktop: note — %s has no Setup.command, so this installation gets the
' "$DEST"
    printf '         launcher defaults: no keyvault key, no connector state key, and USD.
'
    printf '         Rebuild with '"'"'make desktop'"'"' to stamp one in.
'
    return 0
  fi
  CURRENCY="$CURRENCY" MARGINCE_KIT_INTERACTIVE=0 bash "$setup" --no-prompt | sed 's/^/desktop: /'
}

cmd_install() {
  [ -d "$SRC" ] || die "no build at $SRC — run 'make desktop' first"
  assert_dest_sane

  local updating=no
  [ -d "$DEST/data" ] && updating=yes

  if [ "$updating" = yes ] && desktop_running; then
    die "the installation at $DEST is running — quit it first (Ctrl-C in its window), then install again"
  fi

  mkdir -p "$DEST"
  local item
  for item in "${REPLACEABLE[@]}"; do
    [ -e "$SRC/$item" ] || continue
    rm -rf "${DEST:?}/$item"
    cp -Rp "$SRC/$item" "$DEST/$item"
  done
  # The generated config files are copied only when absent, which is what makes
  # this both the install and the update: the launcher creates them on first
  # run, and a second install must not reset a port or an API key.
  for item in margince.yaml margince.env; do
    [ -e "$SRC/$item" ] && [ ! -e "$DEST/$item" ] && cp -p "$SRC/$item" "$DEST/$item"
  done
  # data/demo is the user's the moment it exists: it holds a 63 MB dataset they
  # were asked to copy in by hand, and the private repository it came from is not
  # something an update can fetch again. So it is created when absent and never
  # touched when present.
  #
  # It no longer needs a contract of its OWN, which is why it lives here: data/
  # is the one directory an update never replaces, so putting the dataset inside
  # it makes the guarantee structural rather than a rule this function has to
  # keep remembering. What is left is the fresh-install gesture — mkdir, because
  # on a fresh install data/ does not exist yet; the launcher creates it on first
  # run, and this runs before that.
  if [ -d "$SRC/data/demo" ] && [ ! -d "$DEST/data/demo" ]; then
    mkdir -p "$DEST/data"
    cp -Rp "$SRC/data/demo" "$DEST/data/demo"
  fi
  # Asserted on every install, not only when the copy above runs: an
  # installation that came from an unzipped download rather than from here has
  # whatever mode the unzip chose, and this is the lane that can still fix it.
  # Narrowing an existing installation's data/ is safe — 0700 is what the
  # launcher would have created it as.
  [ -d "$DEST/data" ] && chmod 700 "$DEST/data"
  run_setup

  # A copy made here carries no quarantine flag (cp sets none), so the launcher
  # has nothing to clear and the first run shows no Gatekeeper dialog.
  if [ "$updating" = yes ]; then
    printf 'desktop: updated %s — data/, margince.yaml and margince.env kept\n' "$DEST"
  else
    printf 'desktop: installed %s (%s)\n' "$DEST" "$(du -sh "$DEST" | cut -f1)"
  fi
  printf '\n  make desktop-run     start it (prints the sign-in password on the first run)\n'
  printf '  make desktop-seed    fill it from the demo dataset, once it is running\n\n'
}

# ──────────────────────────────────── run ─────────────────────────────────

cmd_run() {
  require_install
  if desktop_running; then
    die "something already answers on $(desktop_url) — that is probably this installation. 'make desktop-status'"
  fi
  # A configured-but-unreachable object store fails the BOOT, not a request:
  # platform/blobstore's New ensures its bucket and gives up after ~30s. Only an
  # installation whose margince.env names an endpoint can hit this — the default
  # is a directory, which is always there — so the message points at the file.
  local blob
  blob="$(env_value MARGINCE_BLOBSTORE_ENDPOINT)"
  if [ -n "$blob" ] && ! nc -z "${blob%%:*}" "${blob##*:}" 2>/dev/null; then
    die "$(printf 'margince.env names an object store at %s and nothing is listening there.\nThe api refuses to boot without it. Remove those MARGINCE_BLOBSTORE_* lines\nfrom %s/margince.env and attachments go back to data/blobs.' "$blob" "$DEST")"
  fi

  printf 'desktop: starting %s — Ctrl-C to stop\n\n' "$DEST"
  cd "$DEST" && exec ./margince
}

# cmd_connect delegates to the installation's own connect script, for the same
# reason cmd_seed delegates to its loader: the folder ships the one path, and a
# second spelling here would be the one that rots. It is stamped by cmd_kit, so
# an installation from before this existed does not have it — say so rather than
# fail on a missing file.
cmd_connect() {
  require_install
  local script="$DEST/Connect to Claude.command"
  [ -f "$script" ] || die "$(printf 'no "Connect to Claude.command" in %s.\nIt is stamped by the kit, so this installation predates it: rebuild\nwith `make desktop` and reinstall, or run `make desktop-kit` against\nthe build and `make desktop-install` again.' "$DEST")"
  if desktop_running; then
    die "something already answers on $(desktop_url) — that is probably this installation. Stop it first: this script starts Margince itself."
  fi
  printf 'desktop: connecting %s — Ctrl-C to stop\n\n' "$DEST"
  cd "$DEST" && exec bash "$script" "$@"
}

# ─────────────────────────────────── seed ─────────────────────────────────

# Seeding is the INSTALLATION's job, not this repository's.
#
# It used to be the other way round: this script computed the four facts, set
# eight environment variables and called `make -C core/backend seed-demo`, which
# ran the seeder with `go run`. That worked for a developer standing in a
# checkout and for nobody else — and the desktop folder exists precisely for the
# people who have neither the checkout nor Go.
#
# So the seeder is now a BINARY inside the folder (runtime/seed-demo), driven by
# a loader script beside it, and this delegates there. One seeding path, run by
# users and developers alike: what `make desktop-seed` exercises is exactly what
# ships. It also retires the `make -C core/backend` call this file used to have
# to justify in a comment — the gesture CLAUDE.md forbids is simply gone.
#
# DATASET= still overrides the location, because a developer's checkout does
# not live inside the installation.
run_loader() {
  require_install
  local loader="$DEST/Load Demo Data.command"
  [ -x "$loader" ] || die "$(printf 'the installation at %s has no demo loader.\nIt predates the loader — reinstall it:\n  make desktop && make desktop-install' "$DEST")"

  # Which dataset, in the order that surprises nobody: an explicit DATASET wins;
  # otherwise a dataset the user copied into the installation is what the loader
  # would find on its own. There is no third default any more — it used to be a
  # developer checkout beside this repo, named after the dataset's own private
  # repository, and that name cannot appear here.
  local args=()
  if [ -n "${DATASET:-}" ]; then
    args+=(--dataset "$(dataset_path "$DATASET")")
  elif [ ! -d "$DEST/data/demo" ] || [ -z "$(find -L "$DEST/data/demo" -name demo.json -print -quit 2>/dev/null)" ]; then
    die "$(printf 'no demo dataset.\n\nEither copy one into the installation:\n    %s/data/demo\n\nor point the lane at one you already have:\n  make desktop-seed DATASET=/path/to/it' "$DEST")"
  fi

  assert_dest_sane

  # A make lane is not a window anyone is looking at, so the loader's
  # press-Return-to-close pause would hang the build.
  # ${args[@]+...}: bash 3.2 ships with macOS and treats an EMPTY array as an
  # unbound variable under `set -u`, so the plain expansion aborts the lane in
  # exactly the case this function is designed for — no DATASET, dataset already
  # inside the installation, nothing to pass.
  MARGINCE_KIT_INTERACTIVE=0 bash "$loader" ${args[@]+"${args[@]}"} "$@"
}

cmd_seed() { run_loader "$@"; }

cmd_verify() { run_loader --verify; }

# env_value reads an UNcommented key out of margince.env. The generated file
# documents every setting as a comment, so the anchor matters: a naive grep
# reports every documented default as configured.
env_value() {
  local file="$DEST/margince.env"
  [ -f "$file" ] || return 0
  sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*\(.*\)$/\1/p" "$file" | tail -n1
}

# ──────────────────────────── the database ────────────────────────────────

# SEAT_PASSWORD is what the seeder gives every demo colleague. It cannot go
# through the API — the contract floors a password at 12 characters and only
# sets one through a single-use link — so the seeder writes the Argon2 hash
# directly, and this value is the one every demo script already assumes
# (core/backend/tools/seed-demo/users.go).
SEAT_PASSWORD="1234"

desktop_psql_bin() { printf '%s/runtime/pgsql/bin/psql\n' "$DEST"; }

# The installation ships its own psql, which is the one guaranteed to match the
# server: nothing here depends on a Postgres being installed on the machine.
require_psql() {
  require_install
  [ -x "$(desktop_psql_bin)" ] || die "no psql in $DEST/runtime/pgsql/bin — reinstall with 'make desktop-install'"
  [ -S "$DEST/data/sockets/.s.PGSQL.5432" ] || die "$(printf 'the database socket is not there — the installation is not running.\n  make desktop-run')"
}

db_query() { "$(desktop_psql_bin)" "$(desktop_dsn)" -Atc "$1"; }

cmd_psql() {
  require_psql
  exec "$(desktop_psql_bin)" "$(desktop_dsn)"
}

# cmd_dsn exists because "look in the database" is a normal thing to want and
# the desktop installation makes it unobvious: there is NO TCP listener at all
# (listen_addresses='' — desktop/launcher/postgres_unix.go), so the usual
# host/port/password a client asks for do not exist. The socket, the owner role
# and trust auth do.
cmd_dsn() {
  require_install
  local dir="$DEST/data/sockets"
  cat <<EOF
  Connection facts (macOS build — unix socket only, no TCP listener):

    host        $dir        (a directory, not a hostname)
    database    margince
    user        margince_owner       owns the tables; use this to look around
                margince_app        the runtime role: non-superuser, RLS applies
    password    none — local socket auth is trust, and the socket directory is 0700
    port        5432 on the socket; the database has NO tcp listener

  URL form
    $(desktop_dsn)

  Keyword form (psql, pgcli, libpq clients)
    "host=$dir user=margince_owner dbname=margince"

  The psql it ships, which always matches the server
    make desktop-psql
    $(desktop_psql_bin) "$(desktop_dsn)"

  A GUI client
    TablePlus, Postico and DBeaver's socket option take the host directory
    above verbatim, with user margince_owner and an empty password.

    For a client that speaks TCP only, bridge the socket — this exposes the
    database on a local port for as long as it runs, so stop it when finished:

      socat TCP-LISTEN:15433,reuseaddr,fork UNIX-CONNECT:$dir/.s.PGSQL.5432
      # then connect to 127.0.0.1:15433, user margince_owner, no password

  It is the live database of a running app. Read freely; a write is a write.
EOF
}

# ─────────────────────────────── logins ───────────────────────────────────

# cmd_logins answers the question the sign-in screen raises and nothing on it
# answers: which accounts exist, and what are their passwords. It reads the
# accounts from the database rather than from the dataset, so it describes the
# installation in front of you — including one that was never seeded.
cmd_logins() {
  require_install
  printf '\n  Sign in at %s\n\n' "$(desktop_url)"

  # A stopped installation can still answer half the question — the admin email
  # is config and the launcher's password is a file — and refusing to answer any
  # of it is the unhelpful shape this lane exists to fix.
  if [ ! -S "$DEST/data/sockets/.s.PGSQL.5432" ]; then
    printf '  admin\n    %-32s ' "$(desktop_email)"
    if [ -f "$DEST/data/admin-password" ]; then
      printf '%s (from data/admin-password)\n' "$(desktop_file_password)"
    else
      printf '(created on the first run)\n'
    fi
    printf '\n  It is not running, so the rest is unreadable — the accounts live in its\n'
    printf '  database. Start it and ask again:\n      make desktop-run\n      make desktop-logins\n\n'
    return 0
  fi
  require_psql

  local admin_password="(unknown)"
  if desktop_running; then
    admin_password="$(desktop_password 2>/dev/null || echo '(neither data/admin-password nor the seeded password works)')"
  elif [ -f "$DEST/data/admin-password" ]; then
    admin_password="$(desktop_file_password) (from data/admin-password, not verified — it is not running)"
  fi
  printf '  admin\n    %-32s %s\n' "$(desktop_email)" "$admin_password"

  # The demo colleagues, exactly as seeded: a real seat, not the bootstrap
  # account and not the AI agent (which has no password to give).
  local seats
  seats="$(db_query "select email || '|' || display_name from app_user
    where password_hash is not null and not is_agent and archived_at is null
      and lower(email) <> lower('$(desktop_email)')
    order by created_at" 2>/dev/null || true)"
  if [ -z "$seats" ]; then
    printf '\n  No other accounts yet — "make desktop-seed" creates the demo colleagues.\n\n'
    return 0
  fi
  printf '\n  demo colleagues (password %s)\n' "$SEAT_PASSWORD"
  printf '%s\n' "$seats" | while IFS='|' read -r email name; do
    printf '    %-32s %s\n' "$email" "$name"
  done
  printf '\n'
}

# ────────────────────────────────── status ────────────────────────────────

cmd_status() {
  printf '  folder     %s' "$DEST"
  if [ ! -d "$DEST" ]; then
    printf ' (not installed — make desktop-install)\n'
    return 0
  fi
  printf ' (%s)\n' "$(du -sh "$DEST" | cut -f1)"
  printf '  build      %s\n' "$([ -d "$SRC" ] && echo "$SRC" || echo 'not built — make desktop')"
  printf '  url        %s' "$(desktop_url)"
  if desktop_running; then printf ' (running)\n'; else printf ' (not running — make desktop-run)\n'; fi
  printf '  sign in    %s\n' "$(desktop_email)"
  # Which password is live is worth a probe rather than a guess: a seeded
  # installation is on SEEDED_PASSWORD and data/admin-password no longer opens
  # it, which reads as a broken install if nothing says so.
  if [ ! -f "$DEST/data/admin-password" ]; then
    printf '  password   not created yet — the first run creates the account\n'
  elif ! desktop_running; then
    printf '  password   %s (not running, so not verified)\n' "$DEST/data/admin-password"
  elif api_login_works "$(desktop_file_password)"; then
    printf '  password   %s\n' "$DEST/data/admin-password"
  elif api_login_works "$SEEDED_PASSWORD"; then
    printf '  password   %s (seeded — data/admin-password is no longer current)\n' "$SEEDED_PASSWORD"
  else
    printf '  password   unknown — neither data/admin-password nor the seeded one signs in\n'
  fi
  printf '  database   %s\n' "$(desktop_dsn)"
  printf '  logs       %s\n' "$DEST/data/logs"
}

# ──────────────────────────────────── kit ────────────────────────────────

# cmd_kit stamps the demo loader into a BUILT folder — the seeder binary, the
# loader script for that platform, the README a downloader reads, and an empty
# data/demo signpost.
#
# It is a separate gesture rather than part of desktop-mirror because the two
# platforms' folders are produced in different places: the macOS one lands in
# this repo's build/, and the Windows one is built by upstream's PowerShell on a
# Windows host (pgvector needs MSVC and Redis needs MSYS2, so neither half
# cross-builds). Taking --dir means whoever assembles the Windows folder can
# stamp it wherever it is.
#
# The SEEDER is built the way core builds api/worker/migrate — through
# build/composition/go.work, not a bare `go build`. That wiring is what links
# our units in, and a seeder built against the vanilla stub would look identical
# from the outside while resolving a workspace none of our units are in.
KIT_SRC="scripts/desktop-kit"

# The composed workspace, which `make desktop-kit` guarantees by depending on
# `compose`. Named rather than assumed so a direct invocation says what is
# missing instead of building the wrong tree.
composition_workspace() {
  local work="$CORE/build/composition/go.work"
  [ -f "$work" ] || die "no composed workspace at $work — run 'make compose' first"
  printf '%s\n' "$work"
}

# Where the seeder's SOURCE is, which stopped being core in upstream #4732 —
# "the loader only ever read that dataset, so it belonged beside the data
# rather than beside the product". It is a self-contained module there, with
# its own go.mod, so it needs no composed workspace and no core checkout.
#
# DATASET required: no default sibling checkout. The only default worth
# computing would be named after the dataset's own private repository.
dataset_seeder_src() {
  local d="${DATASET:-}"
  [ -n "$d" ] || return 1
  [ -d "$d/tools/seed-demo" ] || return 1
  printf '%s\n' "$d/tools/seed-demo"
}

# Builds the seeder, or reports that it cannot and leaves the caller to ship a
# folder without one.
#
# NOT fatal when the source is absent, and that is the whole change: this used
# to build from core, which every checkout has, so failing loudly was right.
# The source is now a private repository most builds cannot reach — including
# `make desktop` on this project's own release runner, which checks the dataset
# out AFTER the build. A folder without a loader is a supported shape (every
# seeded bundle ships as one); a folder with a loader and no seeder is not.
build_seeder() {
  local goos="$1" out="$2" src
  if ! src="$(dataset_seeder_src)"; then
    say "kit: no demo dataset reachable, so this folder ships no loader."
    say "     DATASET=/path/to/it to include one."
    return 1
  fi
  printf 'kit: building the seeder for %s from %s\n' "$goos" "$src"

  # Built from a COPY with the replace repointed at this checkout's core.
  #
  # The seeder is not self-contained: its module is rooted at the product's
  # path — deliberately, so Go's import-path `internal` rule lets it reach
  # backend/internal/{people,identity,blobstore,jobs} — and it carries
  #
  #   replace github.com/margince/margince/backend => ../../../margince-poc-v1/backend
  #
  # which expects a core checkout of that NAME beside the dataset. Ours is a
  # submodule at core/, and the dataset is checked out wherever the caller put
  # it, so that path resolves nowhere here.
  #
  # The replace is load-bearing rather than a convenience — its own comment says
  # so: without a local one, the backend resolves from the NETWORK and pins a
  # pseudo-version of whatever was last pushed, and the seeder then compiles
  # against a different backend than the one it seeds. So it is repointed, not
  # dropped.
  #
  # A copy rather than an edit in place: the dataset is somebody's checkout, and
  # a build has no business leaving a modified go.mod in it.
  local build_dir core_backend
  # Resolved BEFORE the subshell. Inside it the working directory is the copy,
  # so a relative $CORE would resolve against that and the replace would be
  # handed an empty path — which go mod edit reports as `invalid new path:
  # malformed import path ""`, three steps from the cause.
  core_backend="$(cd "$CORE/backend" && pwd)" || die "kit: no core backend at $CORE/backend"
  build_dir="$(mktemp -d)"
  # Cleaned up explicitly at the end, NOT with `trap ... RETURN`: bash's traps
  # are not function-scoped without functrace, so a RETURN trap set here fires
  # on every later function return too — where build_dir is gone and `set -u`
  # turns the cleanup into an error in an unrelated place.
  cp -R "$src/." "$build_dir/"
  ( cd "$build_dir" && GOWORK=off go mod edit \
      -replace "github.com/margince/margince/backend=$core_backend" ) \
    || die "kit: could not repoint the seeder at $core_backend"
  src="$build_dir"
  # GOWORK=off, and it is not optional. The seeder is a SELF-CONTAINED module
  # with its own go.mod, and the release lanes check the dataset out INSIDE this
  # repository (.dataset) — so `go build` walks up, finds our go.work, and
  # refuses a module the workspace does not list:
  #
  #   current directory is contained in a module that is not one of the
  #   workspace modules listed in go.work
  #
  # A dataset checked out BESIDE the repo builds fine without this, which is
  # why it passed locally and failed on the runner.
  #
  # A build that FAILS is fatal, unlike a source that is absent. The two are
  # different states and were reported as one: the missing binary reached
  # codesign, which failed on a path that was never written, and the folder was
  # then described as having reached no dataset at all.
  case "$goos" in
    darwin)
      ( cd "$src" && GOWORK=off go build -o "$out" . ) \
        || die "kit: the seeder in $src did not build"
      # Ad-hoc signed like every other binary in the bundle. Unsigned, macOS
      # kills it on first run in a downloaded folder.
      codesign --force --sign - --timestamp=none "$out"
      ;;
    windows)
      # CGO_ENABLED=0 because there is no Windows C toolchain here and the
      # seeder needs none: it is an api client over net/http plus pgx, which is
      # pure Go. That is what makes this the one half of the Windows bundle
      # that CAN be cross-built from macOS.
      ( cd "$src" && CGO_ENABLED=0 GOOS=windows GOARCH=amd64 GOWORK=off go build -o "$out" . ) \
        || die "kit: the seeder in $src did not build"
      ;;
    *) die "kit: unknown target os: $goos" ;;
  esac
  rm -rf "$build_dir"
}

# The README is one source with the platform spelled into it, rather than two
# that drift: a macOS reader should not be told to double-click a .cmd, and the
# path separator in a user-facing instruction has to be the one they will see.
write_kit_readme() {
  local dir="$1" starter="$2" loader="$3" sep="$4" version="$5" setup="${6:-}" seeded="${7:-no}" connect="${8:-}" os="${9:-}"
  # A folder that ships no setup script must not be told to double-click one.
  # The section comes OUT rather than being softened, because a reader following
  # a step that names a file which is not there learns nothing except that the
  # folder lies. Both platforms ship one today; the parameter stays because the
  # readme template and the kit branches are two places, and this is the one that
  # keeps them from disagreeing silently.
  #
  # An ARRAY rather than a no-op expression: sed's `b` with no label branches to
  # the end of the script, so a "do nothing" -e of that shape silently skips
  # every substitution after it for every line.
  local -a drop=()
  [ -n "$setup" ] || drop+=(-e '/<!--SETUP-->/,/<!--\/SETUP-->/d')
  # Same rule as SETUP above, for the same reason: a folder that ships no
  # connect script must not carry a section telling its reader to double-click
  # one. Both platforms ship it today.
  [ -n "$connect" ] || drop+=(-e '/<!--CONNECT-->/,/<!--\/CONNECT-->/d')
  # The quarantine section is macOS's alone. Windows marks a download too, but
  # nothing here clears it there, so a Windows reader must not be told that
  # opening Setup once settles the rest of the folder — it would not.
  [ "$os" = darwin ] || drop+=(-e '/<!--MACOS-->/,/<!--\/MACOS-->/d')
  # A folder is either seeded or loadable, never both, so exactly one of these
  # regions survives. Written as two removals rather than one conditional
  # because the reader of a stamped README must never meet instructions for the
  # state their folder is not in.
  if [ "$seeded" = yes ]; then
    drop+=(-e '/<!--LOADER-->/,/<!--\/LOADER-->/d')
  else
    drop+=(-e '/<!--SEEDED-->/,/<!--\/SEEDED-->/d')
  fi
  sed ${drop[@]+"${drop[@]}"} \
      -e '/<!--\/*SETUP-->/d' \
      -e '/<!--\/*CONNECT-->/d' \
      -e '/<!--\/*MACOS-->/d' \
      -e '/<!--\/*LOADER-->/d' \
      -e '/<!--\/*SEEDED-->/d' \
      -e "s|@@SETUP@@|$setup|g" \
      -e "s|@@CONNECT@@|$connect|g" \
      -e "s|@@START@@|$starter|g" \
      -e "s|@@LOADER@@|$loader|g" \
      -e "s|@@SEP@@|$sep|g" \
      -e "s|@@VERSION@@|$version|g" \
      "$ROOT/$KIT_SRC/README.md" > "$dir/README.md"

  # The template and the substitution list above are two places, and only this
  # catches them disagreeing. A placeholder added to one and not the other
  # survives every gate here — the folder builds, the zip uploads, and the first
  # reader of the literal @@THING@@ is whoever downloaded it.
  # `|| true` because grep exits 1 when it matches NOTHING — which is the
  # success case here. Without it this guard fails on every correct build and
  # only on correct builds, which is the one way an assertion can be worse than
  # no assertion at all.
  local left
  left="$(grep -oE '@@[A-Z0-9_]*@@|<!--/?[A-Z]+-->' "$dir/README.md" | sort -u | tr '\n' ' ' || true)"
  [ -z "$left" ] || die "kit: the folder README still has unsubstituted placeholders or region markers: $left"
}

# stamp_env_template puts the launcher's own annotated margince.env into the
# folder, so Setup.command can fill in this installation's keys BEFORE the first
# start. The launcher writes the same file on first run, which is too late: the
# api reads the keyvault key at boot, so an installation that has started once
# without it has already answered 500 to every extension that stores a credential.
#
# The content is lifted from desktop/launcher/envfile.go rather than restated. It
# is the reference for every setting a desktop installation has, and a copy kept
# here would rot against it.
#
# ONLY where a setup script ships alongside it, which is now both platforms. A
# stamped margince.env stops the launcher writing its own — ensureEnvFile leaves
# an existing file alone — so a folder given the file without the script that
# fills it would LOSE the keyvault key it has today rather than gain one. Stamp
# the two together or neither.
stamp_env_template() {
  local dir="$1" template
  # The template's first line shares the declaration line, so it is recovered
  # from that line rather than skipped with it.
  template="$(awk '/^const envTemplate = `/{f=1; sub(/^const envTemplate = `/, ""); print; next}
                   f && /^`$/{exit} f' \
    "$ROOT/core/desktop/launcher/envfile.go" 2>/dev/null || true)"
  if [ -z "$template" ]; then
    printf 'kit: note — could not read the launcher env template; the first start writes it,\n'
    printf '     and Setup.command will write a minimal one instead.\n'
    return 0
  fi
  printf '%s\n' "$template" >"$dir/margince.env"
  chmod 600 "$dir/margince.env"
  printf 'kit: stamped margince.env (the launcher template, keys left for the setup script)\n'
}

# retire_loader removes the demo loader and the seeder it drives.
#
# Run UNCONDITIONALLY, then the loader is put back only when the folder is not
# seeded. Re-stamping is how a seeded folder is made — the kit runs once before
# the seed and again after it — so this has to be able to take a loader OUT of a
# folder that already has one, not merely decline to add it.
#
# data/demo goes with them. It exists to hold a dataset the recipient was asked
# to fetch, and a folder that arrives with the data has nothing to put there.
retire_loader() {
  local dir="$1" launcher="$2" seeder="$3" ps1="$4"
  rm -f "$dir/$launcher" "$dir/runtime/$seeder" "$dir/runtime/$ps1"
  rm -rf "$dir/data/demo"
}

cmd_kit() {
  local dir="" goos="" version="" seeded=no
  while [ $# -gt 0 ]; do
    case "$1" in
      --dir)     [ $# -ge 2 ] || usage; dir="$2"; shift 2 ;;
      --os)      [ $# -ge 2 ] || usage; goos="$2"; shift 2 ;;
      --version) [ $# -ge 2 ] || usage; version="$2"; shift 2 ;;
      --seeded)  seeded=yes; shift ;;
      *)         usage ;;
    esac
  done
  [ -n "$dir" ] || die "kit: --dir is required"
  [ -n "$goos" ] || die "kit: --os is required (darwin or windows)"
  [ -d "$dir" ] || die "kit: no folder at $dir"
  [ -d "$dir/runtime" ] || die "kit: $dir has no runtime/ — that is not a built desktop folder"
  # ABSOLUTE from here on: build_seeder cds into core/backend, so a relative -o
  # would resolve against the wrong directory and write the seeder into core/.
  dir="$(cd "$dir" && pwd)"

  # Resolved ONCE, here, and then handed to both readers. The README carries the
  # version and so does BUILD-INFO.txt; resolving twice would let them disagree,
  # and a folder that names two versions of itself is worse than one that names
  # none. build-info.sh owns the rule — see its resolve_version.
  if [ -n "$version" ]; then
    version="$(bash "$ROOT/scripts/build-info.sh" --print-version --version "$version")"
  else
    version="$(bash "$ROOT/scripts/build-info.sh" --print-version)"
  fi

  case "$goos" in
    darwin)
      retire_loader "$dir" "Load Demo Data.command" seed-demo load-demo-data.ps1
      # `&&`, not two statements: a loader whose seeder is not beside it is a
      # double-click that fails on the machine of somebody who cannot fix it.
      if [ "$seeded" = no ] && build_seeder darwin "$dir/runtime/seed-demo"; then
        cp "$ROOT/$KIT_SRC/load-demo-data.command" "$dir/Load Demo Data.command"
        chmod +x "$dir/Load Demo Data.command"
      fi
      cp "$ROOT/$KIT_SRC/setup.command" "$dir/Setup.command"
      chmod +x "$dir/Setup.command"
      cp "$ROOT/$KIT_SRC/connect-claude.command" "$dir/Connect to Claude.command"
      chmod +x "$dir/Connect to Claude.command"
      stamp_env_template "$dir"
      write_kit_readme "$dir" "Start Margince.command" "Load Demo Data.command" "/" "$version" "Setup.command" "$seeded" "Connect to Claude.command" darwin
      ;;
    windows)
      # The .cmd is the double-clickable half and the .ps1 is the whole of the
      # work; the .ps1 lives in runtime/ so the folder root stays two files a
      # non-technical reader can tell apart.
      retire_loader "$dir" "Load Demo Data.cmd" seed-demo.exe load-demo-data.ps1
      if [ "$seeded" = no ] && build_seeder windows "$dir/runtime/seed-demo.exe"; then
        cp "$ROOT/$KIT_SRC/load-demo-data.cmd" "$dir/Load Demo Data.cmd"
        cp "$ROOT/$KIT_SRC/load-demo-data.ps1" "$dir/runtime/load-demo-data.ps1"
      fi
      cp "$ROOT/$KIT_SRC/setup.cmd" "$dir/Setup.cmd"
      cp "$ROOT/$KIT_SRC/setup.ps1" "$dir/runtime/setup.ps1"
      cp "$ROOT/$KIT_SRC/connect-claude.cmd" "$dir/Connect to Claude.cmd"
      cp "$ROOT/$KIT_SRC/connect-claude.ps1" "$dir/runtime/connect-claude.ps1"
      stamp_env_template "$dir"
      # Four backslashes: bash makes two, and sed needs two in a replacement to
      # emit one. A single \ here is an unterminated sed escape, not a separator.
      write_kit_readme "$dir" "Start Margince.cmd" "Load Demo Data.cmd" "\\\\" "$version" "Setup.cmd" "$seeded" "Connect to Claude.cmd" windows
      ;;
    *) die "kit: unknown target os: $goos" ;;
  esac

  # The dataset is a PRIVATE repository, so nothing of it ships. What ships is
  # the place to put it — an empty directory does not survive a zip, so the note
  # inside is what makes the signpost arrive.
  #
  # A SEEDED folder gets neither. It arrives with the data, so a directory
  # labelled "put the demo database here" is an instruction for a problem its
  # reader does not have. This runs after the case above, which is why
  # retire_loader removing the directory does not settle it on its own.
  if [ "$seeded" = no ]; then
    mkdir -p "$dir/data/demo"
    cat > "$dir/data/demo/PUT-THE-DEMO-DATABASE-HERE.txt" <<'NOTE'
Copy the Margince demo database folder into THIS directory, then run the
demo loader in the installation folder (two levels up). See its README.md.

The demo database is not part of this download. Ask the team that provided this build
for it. It is a folder with a "datasets" directory inside it.
NOTE
  fi

  # 0700 either way, because the launcher can no longer be the one to set it. It
  # creates data/ with 0700 on first run, but MkdirAll leaves an EXISTING
  # directory's mode alone — and this folder now ships one, created here under
  # whatever umask the builder had and re-created by whatever unzipped it. On
  # macOS the database's access control IS the filesystem
  # (desktop-distribution.md, "the filesystem is the access control"), so a data/
  # arriving 0755 would widen what the launcher's own 0700 was there to close.
  # data/sockets keeps its own 0700 from resolveSocketDir and never ships, so
  # this is about everything else under data/: the admin password, the blobs, the
  # database.
  mkdir -p "$dir/data"
  chmod 700 "$dir/data"

  # Last, so it describes a FINISHED folder: the seeder it lists among the
  # programs is in runtime/ by now, and a build-info written before the copy
  # would describe a folder that did not exist yet.
  # --seeded is forwarded so build-info can tell "ships no demo data" from
  # "ships demo data nobody recorded the commit of". Only this function knows
  # which of the two a folder is.
  bash "$ROOT/scripts/build-info.sh" --dir "$dir" --os "$goos" --version "$version" \
    $([ "$seeded" = yes ] && printf -- '--seeded')

  # Three outcomes, not two. A folder can lack the loader because it is SEEDED
  # (nothing to load) or because no dataset was reachable to build one from,
  # and reporting the second as the first would describe a folder that has the
  # demo in it when it does not.
  if [ "$seeded" = yes ]; then
    printf 'kit: stamped %s (%s) — seeded, so the demo loader is not in it\n' "$dir" "$goos"
  elif [ -e "$dir/Load Demo Data.command" ] || [ -e "$dir/Load Demo Data.cmd" ]; then
    printf 'kit: stamped the demo loader into %s (%s)\n' "$dir" "$goos"
  else
    printf 'kit: stamped %s (%s) — no dataset was reachable, so it carries no loader and no demo data\n' "$dir" "$goos"
  fi
}

# SOURCED rather than run: define the functions and stop. scripts/desktop-kit.test.sh
# needs write_kit_readme on its own — stamping a README through `kit` would
# compile the seeder, which is minutes for a suite that runs in a second, and
# reimplementing the sed rules in the test would put them in a second place to
# drift from. The standard idiom, and inert when the script is executed.
(return 0 2>/dev/null) && return 0

case "${1:-}" in
  install) shift; cmd_install "$@" ;;
  run)     shift; cmd_run "$@" ;;
  seed)    shift; cmd_seed "$@" ;;
  verify)  shift; cmd_verify "$@" ;;
  status)  shift; cmd_status "$@" ;;
  logins)  shift; cmd_logins "$@" ;;
  psql)    shift; cmd_psql "$@" ;;
  dsn)     shift; cmd_dsn "$@" ;;
  connect) shift; cmd_connect "$@" ;;
  kit)     shift; cmd_kit "$@" ;;
  *)       usage ;;
esac
