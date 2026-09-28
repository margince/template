#!/usr/bin/env bash
# Setup.command — prepare THIS installation before its first start.
#
# Double-click it, or run it from a terminal. Like the demo loader beside it, it
# lives inside the installation it configures, so every fact it needs is a file
# next to it: no repository, no toolchain and no make.
#
# It writes the two files the launcher would otherwise create for itself:
#
#   margince.yaml   base currency, timezone, the admin address
#   margince.env    this installation's own keys, and the shared demo credentials
#
# BOTH are write-once — the launcher creates each only when it finds none, and
# the workspace is bootstrapped from margince.yaml on the first start. So
# every decision here is one that cannot be revisited without deleting data/,
# and running this BEFORE the first start is the whole point of it existing.
#
# The repository half of this pair is scripts/desktop.sh: `make desktop-install`
# delegates HERE rather than keeping a second spelling of the same config. There
# is one configuration path and users and developers both run it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

# Double-clicked, Finder gives this a Terminal window that closes the moment the
# script returns — taking every line of output with it. desktop.sh sets this to
# 0, because a make lane is not a window anyone is looking at, and because a
# lane must never block on a prompt.
INTERACTIVE="${MARGINCE_KIT_INTERACTIVE:-1}"

# The demo dataset is euro-based: the seeder loads an fx rate for every non-EUR
# currency it meets, and the api refuses a rate whose currency IS the base one.
# A USD installation therefore fails the seed AFTER most of the dataset is
# written, and the currency cannot be changed once the workspace exists.
CURRENCY="${CURRENCY:-EUR}"

# The demo dataset calls the admin this. The seeder replaces that account's
# password and never renames one, so an installation bootstrapped under any
# other address leaves the dataset describing someone who is not here.
ADMIN_EMAIL="${ADMIN_EMAIL:-admin@demo.test}"

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
usage: "Setup.command" [--no-prompt]

  --no-prompt   generate this installation's own keys and write margince.yaml,
                but ask for nothing. The vendor credentials are left blank.

  CURRENCY= and ADMIN_EMAIL= override what margince.yaml is created with. Both
  are decided on the first start and cannot be changed afterwards.
EOF
  exit 2
}

PROMPT=1
while [ $# -gt 0 ]; do
  case "$1" in
    --no-prompt) PROMPT=0; shift ;;
    *)           usage ;;
  esac
done
[ "$INTERACTIVE" = "1" ] || PROMPT=0

# ───────────────────────────── reading the folder ─────────────────────────

# Only an UNcommented assignment counts. The generated margince.env documents
# every setting as a comment, so a naive grep reports a default as configured.
env_value() {
  local key="$1"
  [ -f "$ROOT/margince.env" ] || return 0
  sed -n "s/^[[:space:]]*$key[[:space:]]*=[[:space:]]*\(.*\)/\1/p" "$ROOT/margince.env" | tail -n1
}

app_port() {
  local port
  port="$(sed -n 's/^[[:space:]]*MARGINCE_PORT[[:space:]]*=[[:space:]]*\([0-9]\{1,\}\).*/\1/p' \
    "$ROOT/margince.env" 2>/dev/null | tail -n1)"
  printf '%s\n' "${port:-8800}"
}

# ───────────────────────────── writing the folder ─────────────────────────

# set_env_key sets KEY to VALUE in margince.env, whether the template carried it
# commented out or not there at all. An existing UNcommented value is kept: this
# runs on a folder a person may already have edited, and the keys it manages are
# ones a second value would silently invalidate — a rotated vault key cannot open
# what the first one sealed.
set_env_key() {
  local key="$1" value="$2" file="$ROOT/margince.env"
  if [ -n "$(env_value "$key")" ]; then
    return 1
  fi
  if grep -q "^[[:space:]]*#[[:space:]]*$key=" "$file" 2>/dev/null; then
    # A literal replacement, and the value never sits on a spawned process's
    # command line (visible to any other user with `ps` for the life of that
    # process): awk reads key and value from its own environment (ENVIRON)
    # rather than from argv, writes to a temp file, then the temp file is
    # renamed over the original.
    local tmp="$file.tmp.$$" mode
    mode="$(stat -f '%OLp' "$file" 2>/dev/null || stat -c '%a' "$file" 2>/dev/null || echo 600)"
    SET_ENV_KEY="$key" SET_ENV_VALUE="$value" awk '
      BEGIN { k = ENVIRON["SET_ENV_KEY"]; v = ENVIRON["SET_ENV_VALUE"] }
      $0 ~ ("^[[:space:]]*#[[:space:]]*" k "=") { print k "=" v; next }
      { print }
    ' "$file" >"$tmp"
    chmod "$mode" "$tmp"
    mv -f "$tmp" "$file"
  else
    printf '%s=%s\n' "$key" "$value" >>"$file"
  fi
  return 0
}

# The launcher writes margince.env from its own annotated template on the first
# start, which is TOO LATE for the keyvault key: the api reads it at boot, so an
# installation that starts once without it has already answered 500 to every
# extension that stores a credential. The kit stamps the template into the folder
# at build time so this can fill it in beforehand.
ensure_env_file() {
  [ -f "$ROOT/margince.env" ] && return 0
  say "note — margince.env is missing, so a minimal one is written instead of the"
  say "       launcher's annotated template. Every setting it documents is still"
  say "       available; see the launcher's own file on an untouched installation."
  cat >"$ROOT/margince.env" <<'EOF'
# Margince settings. Written by Setup.command before the first start.
# Restart Margince after changing anything here.
EOF
  chmod 600 "$ROOT/margince.env"
}

# The one sentence both "cannot consume a seed" cases need, so the two do not
# drift into saying different things about the same state.
#
# It used to end "bind the tiers in the app under Settings -> AI", and that was
# WRONG in the way this whole file keeps being wrong: an instruction the reader
# cannot carry out. That screen renders a form only for an installation that
# already has tiers; with none it shows a callout naming `seeds.ai_routing` and
# offers nothing to press (core frontend/src/screens/ai-routing.tsx). So the
# reader was sent to the one place that looks like the answer and is not.
#
# Fixed upstream in margince/margince#4853 — the screen offers a first binding
# from a keyed provider's presets. Until this folder is built against a core
# carrying it, the honest thing is to say the surfaces stay on the fake rather
# than name a path that dead-ends.
say_bind_in_app() {
  say ""
  say "  NOTE — $1"
  say "  $2"
  say "  Your key is stored and sealed. Bind the tiers in the app under"
  say "  Settings -> AI, which opens on this provider's defaults — until then"
  say "  the AI surfaces answer from the offline fake."
}

# ───────────────────────────── the model binding ──────────────────────────

# The tier→model binding a fresh installation is CREATED with.
#
# A provider key is only half the configuration, and for a long time this script
# wrote the half that does nothing on its own. Nothing routes to a vendor until a
# TIER is bound to it; until then every AI surface answers from the offline fake
# — plausibly, in canned text — so an installation given a perfectly good key
# looked exactly like one whose key had been rejected. margince.env says this
# ("a key with no tier bound to its vendor changes nothing") in a file nobody
# running Setup is reading.
#
# `seeds.ai_routing` is consumed ONCE, at workspace creation (ADR-0061 §2),
# so it has to be in margince.yaml before the first start — which is exactly
# where this script already stands. The database is authoritative afterwards and
# Settings -> AI re-points any lane.
#
# The models mirror the app's own onboarding presets, which are a deliberate
# mirror of the server's price sheet
# (core/frontend/src/screens/setup-providers.ts): an id outside that sheet
# reports UNPRICED on every call, which is a materially different signal from
# free and a poor thing to hand somebody in their first five minutes.
#
# Every tier takes the same model on purpose. Choosing a cheaper id for the
# small lanes would be this script inventing a routing policy nobody asked it
# for; the lanes are visible and editable in Settings -> AI the moment the
# installation is up.
routing_seed() {
  local provider model embed base_url="" tier
  if [ -n "$(env_value GEMINI_API_KEY)" ]; then
    provider="gemini"
    model="gemini-3.1-flash-lite"
    embed="gemini-embedding-001"
  elif [ -n "$(env_value OPENAI_COMPATIBLE_API_KEY)" ]; then
    # OpenRouter is a preset over the openai_compatible adapter, which fails
    # closed without a base_url — so the binding carries one and the key alone
    # would not have been enough even with a tier bound.
    provider="openai_compatible"
    model="mistralai/mistral-small-3.2-24b-instruct"
    embed="openai/text-embedding-3-small"
    base_url="https://openrouter.ai/api"
  else
    return 0
  fi

  local url_field=""
  [ -n "$base_url" ] && url_field=", base_url: $base_url"

  printf '\n'
  printf 'seeds:\n'
  printf '  # Consumed once, when the workspace is created on the first start.\n'
  printf '  # Re-point any lane afterwards in Settings -> AI; this file is not read again.\n'
  printf '  ai_routing:\n'
  printf '    profile: cloud_frontier\n'
  printf '    tiers:\n'
  for tier in local_small local_large cheap_cloud premium frontier; do
    printf '      %s: {provider: %s, model: %s%s}\n' "$tier" "$provider" "$model" "$url_field"
  done
  printf '    embeddings: {provider: %s, model: %s%s}\n' "$provider" "$embed" "$url_field"
}

# margince.yaml is NOT stamped into the folder at build time, unlike margince.env,
# because it carries the timezone — baking that at build time would give every
# recipient the build machine's. It is written here, on the machine that will run
# it, from the same template the launcher uses (desktop/launcher/layout.go).
write_config_yaml() {
  local yaml="$ROOT/margince.yaml"
  if [ -e "$yaml" ]; then
    say "margince.yaml is already here — kept, including its currency and admin address."
    # An existing file is yours, and its seeds were consumed the first time this
    # installation started. So a key set on THIS run has no binding to arrive
    # with, and saying nothing would repeat the failure this seed exists to end:
    # the AI surfaces would answer from the fake and look like a rejected key.
    if [ -n "$(routing_seed)" ] && ! grep -q '^[[:space:]]*ai_routing:' "$yaml"; then
      say_bind_in_app "margince.yaml is already here, so the binding cannot be added to" \
                      "it — its seed is read once, when the workspace is created."
    fi
    return 0
  fi
  local tz
  tz="$(readlink /etc/localtime 2>/dev/null | sed -n 's|.*/zoneinfo/||p')"
  cat >"$yaml" <<EOF
# Margince deployment configuration (A107/ADR-0061).
# Created by Setup.command and never overwritten — your edits survive a restart.
# Restart Margince after changing anything here.
#
# base_currency is $CURRENCY because the demo dataset is euro-based and the api
# refuses an fx rate for the base currency itself, so a USD installation cannot
# complete a demo load. The workspace is created from this file once, on the
# first start, so this cannot be changed afterwards.
version: 1

workspace:
  name: Margince
  base_currency: $CURRENCY
  timezone: ${tz:-UTC}

bootstrap_admin:
  email: $ADMIN_EMAIL
  display_name: Owner
  password_file: data/admin-password
EOF
  # Written even when it cannot be consumed: `data/` is the one thing an update
  # never replaces, and the documented reset for this folder is to delete it. A
  # seed already in the file is then what a rebuilt installation comes up with,
  # which is the whole point of it being a seed.
  routing_seed >>"$yaml"
  chmod 600 "$yaml"
  say "wrote margince.yaml — $CURRENCY, ${tz:-UTC}, admin $ADMIN_EMAIL"
  if [ -n "$(routing_seed)" ]; then
    say "  and the model binding, so the AI surfaces answer on your key rather than the fake"
  fi
}

# ───────────────────────────── this installation's keys ───────────────────

# Three keys that are this installation's alone. Neither may ship in a
# downloaded folder: one key shared by every installation would seal every
# recipient's credentials, and sign every recipient's webhooks, under a value
# anyone with the download already has.
#
# The lengths are contracts, not preferences. The keyvault and webhook keys are
# decoded as base64 and must be EXACTLY 32 bytes for AES-256; the state key is
# an HMAC key the api floors at 32 characters and refuses below it.
generate_keys() {
  command -v openssl >/dev/null || {
    say "note — openssl is missing, so this installation's keys are left unset."
    say "       Extension credentials answer 500, Gmail cannot connect and webhook"
    say "       subscriptions answer 503 until they are:"
    say "           openssl rand -base64 32   # MARGINCE_KEYVAULT_ROOT_KEY"
    say "           openssl rand -hex 32      # MARGINCE_CONNECTOR_STATE_KEY"
    say "           openssl rand -base64 32   # MARGINCE_WEBHOOK_KEY"
    return 0
  }
  if set_env_key MARGINCE_KEYVAULT_ROOT_KEY "$(openssl rand -base64 32)"; then
    say "generated MARGINCE_KEYVAULT_ROOT_KEY — extension credentials are sealed with it"
  fi
  if set_env_key MARGINCE_CONNECTOR_STATE_KEY "$(openssl rand -hex 32)"; then
    say "generated MARGINCE_CONNECTOR_STATE_KEY — the Gmail and Calendar consent flows sign with it"
  fi
  if set_env_key MARGINCE_WEBHOOK_KEY "$(openssl rand -base64 32)"; then
    say "generated MARGINCE_WEBHOOK_KEY — webhook subscription signing secrets are sealed with it"
  fi
  if set_env_key MARGINCE_PUBLIC_BASE_URL "http://127.0.0.1:$(app_port)"; then
    say "set MARGINCE_PUBLIC_BASE_URL — the address Google redirects back to"
  fi
}

# ───────────────────────────── the shared credentials ─────────────────────

# Asked for rather than shipped. These belong to whoever operates the
# installation: one Google app and one model provider key, the same on every
# machine, and none of it may sit in a folder anyone can download.
ask() {
  local key="$1" label="$2" hint="$3" current value
  current="$(env_value "$key")"
  if [ -n "$current" ]; then
    say "$label is already set — kept."
    return 0
  fi
  [ "$PROMPT" = "1" ] || return 0
  printf '\n  %s\n  %s\n  > ' "$label" "$hint"
  read -r value || true
  [ -n "$value" ] || { say "  skipped."; return 0; }
  set_env_key "$key" "$value" >/dev/null || true
  say "  set."
}

# The model provider is ONE CHOICE, not two prompts. The app's own onboarding
# offers exactly these two and no more — core/frontend/src/screens/setup-providers.ts,
# whose comment gives the reason: they are the two vendors that serve chat AND
# embeddings from a single key, and a routing document requires an embeddings
# binding. Offering a third here would walk a first-time admin into a form they
# cannot complete.
#
# Only the KEY is written, whichever is picked, which is what the single
# OpenRouter prompt this replaced already did. The tier bindings — and
# OpenRouter's base_url, which the openai_compatible adapter fails closed
# without — are set in the app under Settings -> AI. So neither provider gains a
# second step here, and the choice below is a shortcut past pasting a long key
# into a browser rather than a second way to configure routing.
ask_provider() {
  # Either key already set answers the question: a re-run must not ask somebody
  # to re-pick a provider they have already chosen, and set_env_key would keep
  # the existing value anyway. Same contract as ask(), across two variables
  # rather than one.
  if [ -n "$(env_value OPENAI_COMPATIBLE_API_KEY)" ]; then
    say "OpenRouter API key is already set — kept."
    return 0
  fi
  if [ -n "$(env_value GEMINI_API_KEY)" ]; then
    say "Google Gemini API key is already set — kept."
    return 0
  fi
  [ "$PROMPT" = "1" ] || return 0

  printf '\n  Model provider — powers the AI surfaces.\n'
  printf '    1) OpenRouter      https://openrouter.ai/keys\n'
  printf '    2) Google Gemini   https://aistudio.google.com/apikey\n'
  printf '  Press Return to skip.\n  > '
  local choice=""
  read -r choice || true
  # ONE read, and anything unrecognized skips rather than asking again. A retry
  # loop is the one shape here that can spin forever in a double-clicked window
  # whose stdin has closed, and the script has already said it can be re-run.
  case "$(printf '%s' "$choice" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
    1|openrouter) ask OPENAI_COMPATIBLE_API_KEY "OpenRouter API key" "begins sk-or-; https://openrouter.ai/keys" ;;
    2|gemini|googlegemini) ask GEMINI_API_KEY "Google Gemini API key" "from https://aistudio.google.com/apikey" ;;
    "") say "  skipped." ;;
    *)  say "  that is neither 1 nor 2 — skipped. Run this again to choose one." ;;
  esac
}

# ───────────────────────────── the download's mark ────────────────────────

# A folder that arrived as a download carries com.apple.quarantine on every file
# in it, and Margince's binaries are AD-HOC signed rather than Developer ID
# signed — `spctl -a -t execute margince` answers "rejected" and always will.
# Gatekeeper ENFORCES that verdict only on a marked file, so the mark is the
# whole difference between a folder that opens and one that answers every
# double-click with "Apple could not verify...".
#
# This script is the one file in the folder whose own mark the reader has
# already had to get past in order to be running it, which makes it the only
# place that can clear the mark for everything else. Without this, the same
# dialog waits again on "Start Margince.command", and again on the binary
# behind it.
#
# ANNOUNCED, never silent. This removes the check that would have stopped a
# malicious download, which is a real decision and not a detail to bury in a
# log — so it names what the mark is, prints the exact command it runs, and
# says that the scope is this folder and nothing else. A recipient who would
# rather not can close the window: everything below here still works on a
# folder that keeps its mark, they will simply meet Gatekeeper once per file.
#
# It is a NO-OP on a folder that was built locally rather than downloaded,
# which is every folder `make desktop-install` ever sees.
clear_quarantine() {
  command -v xattr >/dev/null 2>&1 || return 0
  # The launcher binary rather than this script: it is the file whose mark
  # actually stops Margince starting, and the last one a user would clear by
  # hand. Ours is already cleared by the time anyone reads this.
  [ -e "$ROOT/margince" ] || return 0
  xattr -p com.apple.quarantine "$ROOT/margince" >/dev/null 2>&1 || return 0

  say "This folder was downloaded, so macOS has marked every file in it. The"
  say "binaries here carry an ad-hoc signature rather than a Developer ID one,"
  say "and Gatekeeper refuses a marked copy of those — which is what turns a"
  say "double-click into \"Apple could not verify...\"."
  say ""
  say "Clearing that mark, on this folder and nothing else:"
  say "    xattr -dr com.apple.quarantine \"$ROOT\""
  if xattr -dr com.apple.quarantine "$ROOT" >/dev/null 2>&1; then
    say "cleared — Start Margince.command and the app behind it will now open."
  else
    say "could NOT clear it. Run the line above yourself before starting Margince,"
    say "or Gatekeeper will refuse the app when you do."
  fi
  say ""
}

# ───────────────────────────────── the run ────────────────────────────────

say "Preparing $ROOT"
say ""
clear_quarantine
ensure_env_file
generate_keys

if [ "$PROMPT" = "1" ]; then
  say ""
  say "Shared credentials. Leave one blank to skip it — you can run this again,"
  say "or set it in margince.env, any time before you need the surface it serves."
  ask_provider
  ask MARGINCE_GMAIL_CLIENT_ID "Google OAuth client id" "ends .apps.googleusercontent.com"
  ask MARGINCE_GMAIL_CLIENT_SECRET "Google OAuth client secret" "begins GOCSPX-"
fi

# AFTER the provider prompt, and that is the whole reason this moved: the file
# it writes carries the binding for the vendor that prompt just chose, and
# `seeds.ai_routing` is read once, at workspace creation. Written before the
# answer exists, it could only ever seed nothing.
say ""
write_config_yaml

chmod 600 "$ROOT/margince.env" 2>/dev/null || true

say ""
say "Ready. Start Margince and sign in as $ADMIN_EMAIL —"
say "the first start prints the password and saves it in data/admin-password."
finish 0
