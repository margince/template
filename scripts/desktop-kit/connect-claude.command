#!/usr/bin/env bash
# "Connect to Claude.command" — start Margince with a public address, so an
# agent (Claude, ChatGPT) can reach its MCP connector.
#
# Double-click it INSTEAD of the ordinary starter. It does three things the
# ordinary starter does not, and then hands over to it:
#
#   1. turns the MCP connector on in margince.yaml   (mcp.connector_enabled)
#   2. opens a tunnel to this installation's port
#   3. writes that tunnel's address into margince.env (MARGINCE_PUBLIC_BASE_URL)
#
# All three are required together and none of them is optional. The api mounts
# /mcp, the authorization server and both discovery documents only when the
# deployment declares the connector (backend/cmd/api/boot.go, "Gate 1"), and it
# REFUSES TO BOOT with the gate on and no public base URL — the OAuth audience
# and the advertised MCP resource are derived from that value and must never be
# read off a Host header. So a tunnel without the gate serves 404s, and the gate
# without a tunnel advertises an address only this machine can resolve.
#
# The order is forced by the same fact. The address has to exist BEFORE the api
# starts, because the api reads it once at boot — which is why this script opens
# the tunnel first and starts the launcher last, rather than the other way round.
#
# WHAT THIS EXPOSES. A tunnel publishes the whole installation, not just /mcp.
# The sign-in page is on the same origin, and it has to be: the agent's consent
# flow is a browser visit to /oauth/authorize on the public address, which needs
# a session. Anyone with the URL reaches your login page. Treat the address as
# private, and stop this script when you are not using it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT"

# Double-clicked, Finder gives this a Terminal window that closes the moment the
# script returns, taking every line of output with it. The same convention as
# Setup.command beside it.
INTERACTIVE="${MARGINCE_KIT_INTERACTIVE:-1}"

say()  { printf '%s\n' "$*"; }
warn() { printf 'note — %s\n' "$*"; }
die()  { printf 'error: %s\n' "$*" >&2; finish 1; }

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
usage: "Connect to Claude.command" [--check]

  --check   do the preparation and print the address, but do not start
            Margince. Used by the repository's own test lane.

  MARGINCE_TUNNEL=  cloudflared (the default, and it needs no account) or
                    ngrok. Inferred as ngrok when either setting below is set.
  NGROK_AUTHTOKEN=  your ngrok token. Free, but required: ngrok v3 opens no
                    anonymous tunnel at all.
  NGROK_DOMAIN=     a reserved ngrok domain, and the only way to a PERMANENT
                    address. Without one the address changes on every start
                    and the connector has to be re-added in Claude each time.

  All three are read from margince.env when set there.
EOF
  exit 2
}

CHECK_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --check) CHECK_ONLY=1; shift ;;
    *)       usage ;;
  esac
done

# ───────────────────────────── reading the folder ─────────────────────────

# Only an UNcommented assignment counts. margince.env documents every setting as
# a comment, so a naive grep reports a default as configured. Lifted from
# Setup.command deliberately: these two scripts read the same file and a second
# spelling of "what is set" would let them disagree about it.
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

# put_env_key sets KEY to VALUE, whatever state the file is in: the key absent,
# present but commented out, or already set to something else.
#
# It OVERWRITES an existing value, and that is the difference from Setup.command's
# set_env_key, which keeps one. The keys that script manages are sealed against —
# a second keyvault key cannot open what the first one sealed — so keeping the
# first value is the only safe answer there. This key is the opposite: it names a
# tunnel that did not exist a minute ago and will not exist tomorrow, so a kept
# value is guaranteed to be the stale one.
put_env_key() {
  local key="$1" value="$2" file="$ROOT/margince.env"
  [ -f "$file" ] || { printf '# Margince settings.\n' >"$file"; chmod 600 "$file"; }
  # A literal replacement: a URL carries / and the value may carry + and & from a
  # token, so the separator has to be something none of them can produce.
  if grep -q "^[[:space:]]*#\{0,1\}[[:space:]]*$key=" "$file" 2>/dev/null; then
    sed -i.bak -e "s|^[[:space:]]*#\{0,1\}[[:space:]]*$key=.*|$key=$value|" "$file"
    rm -f "$file.bak"
  else
    printf '%s=%s\n' "$key" "$value" >>"$file"
  fi
  chmod 600 "$file"
}

# enable_connector declares the MCP gate in margince.yaml.
#
# Appended as a top-level block rather than edited into place: the file is the
# user's, the parser is strict about unknown fields but indifferent to order, and
# a block appended once is a block this can recognise on every later run. An
# existing `mcp:` section is left exactly as it is — including one that says
# false, which is a person having turned this off on purpose.
enable_connector() {
  local yaml="$ROOT/margince.yaml"
  if [ ! -f "$yaml" ]; then
    die "no margince.yaml here. Run Setup.command first, or start Margince once so it writes one."
  fi
  if grep -q '^[[:space:]]*mcp:' "$yaml"; then
    if sed -n '/^[[:space:]]*mcp:/,/^[^[:space:]#]/p' "$yaml" | grep -q 'connector_enabled:[[:space:]]*true'; then
      say "margince.yaml already declares the MCP connector — kept."
      return 0
    fi
    die "margince.yaml has an mcp: section that does not enable the connector.
       Set 'connector_enabled: true' under it by hand, or remove the section
       and run this again. It is not overwritten here: turning it off is a
       decision someone made."
  fi
  cat >>"$yaml" <<'YAML'

# Added by "Connect to Claude.command". Serves /mcp, the OAuth authorization
# server and both discovery documents. Requires MARGINCE_PUBLIC_BASE_URL in
# margince.env — the api refuses to boot with this on and that unset.
mcp:
  connector_enabled: true
YAML
  say "margince.yaml — turned the MCP connector on."
}

# ──────────────────────────────── the tunnel ──────────────────────────────

# TWO providers, because the obvious one turned out to have a signup in front of
# it. `ngrok http` opened an anonymous tunnel in v2 and does not in v3: the
# SESSION is what authenticates now, so v3 exits with ERR_NGROK_4018 before any
# tunnel exists. cloudflared's quick tunnel still needs no account at all, which
# is why it is the default.
#
# ngrok is kept for the one thing cloudflared's quick tunnel cannot do: a
# RESERVED DOMAIN, so the address survives a restart and the connector is added
# in Claude once instead of every time.
#
# Chosen by MARGINCE_TUNNEL, and INFERRED when that is unset — someone who has
# put an ngrok token or domain in margince.env has already said which one they
# want, and asking again would be asking them to repeat themselves.
resolve_provider() {
  local choice="${MARGINCE_TUNNEL:-$(env_value MARGINCE_TUNNEL)}"
  if [ -z "$choice" ]; then
    if [ -n "${NGROK_AUTHTOKEN:-$(env_value NGROK_AUTHTOKEN)}" ] || \
       [ -n "${NGROK_DOMAIN:-$(env_value NGROK_DOMAIN)}" ]; then
      choice=ngrok
    else
      choice=cloudflared
    fi
  fi
  case "$choice" in
    cloudflared|ngrok) PROVIDER="$choice" ;;
    *) die "MARGINCE_TUNNEL is $choice; it must be cloudflared or ngrok." ;;
  esac
}

# The tunnel binary lives in runtime/ with the other programs, so an update
# replaces it like them and nothing lands outside this folder. One already on
# PATH wins: a person who installed the tool themselves has an account and a
# config that a second copy here would ignore.
TUNNEL_BIN=""

resolve_binary() {
  local name="$1"
  if [ -x "$ROOT/runtime/$name" ]; then TUNNEL_BIN="$ROOT/runtime/$name"; return 0; fi
  if command -v "$name" >/dev/null 2>&1; then TUNNEL_BIN="$(command -v "$name")"; return 0; fi
  return 1
}

# Cleared on every download for the same reason the starter clears the
# launcher's: a file fetched over HTTP carries the quarantine flag, and the
# launcher only clears the binaries IT spawns.
unquarantine() { /usr/bin/xattr -d com.apple.quarantine "$1" 2>/dev/null || true; }

arch_suffix() {
  case "$(uname -m)" in
    arm64)  printf 'arm64\n' ;;
    x86_64) printf 'amd64\n' ;;
    *)      die "no tunnel build for this machine ($(uname -m)). Install cloudflared or ngrok yourself and run this again." ;;
  esac
}

# cloudflared is Apache-2.0, so unlike ngrok it COULD ship inside the folder.
# It is still fetched on first use, because most installations never turn this
# on and a 38 MB binary in every download is a poor trade for the ones that do.
fetch_cloudflared() {
  local url tgz
  url="https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-darwin-$(arch_suffix).tgz"
  tgz="$ROOT/runtime/.cloudflared.tgz"
  say "downloading cloudflared (once) — $url"
  curl -fsSL --retry 2 -o "$tgz" "$url" \
    || die "could not download cloudflared. Check the connection, or install it yourself and run this again."
  tar xzf "$tgz" -C "$ROOT/runtime" cloudflared || die "could not unpack $tgz"
  rm -f "$tgz"
  chmod +x "$ROOT/runtime/cloudflared"
  unquarantine "$ROOT/runtime/cloudflared"
  TUNNEL_BIN="$ROOT/runtime/cloudflared"
  say "cloudflared is in runtime/cloudflared"
}

fetch_ngrok() {
  local url zip
  url="https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-darwin-$(arch_suffix).zip"
  zip="$ROOT/runtime/.ngrok.zip"
  say "downloading ngrok (once) — $url"
  curl -fsSL --retry 2 -o "$zip" "$url" \
    || die "could not download ngrok. Check the connection, or install ngrok yourself and run this again."
  # -o overwrites without asking: unzip's interactive prompt would hang a
  # double-clicked window with no way to answer it.
  unzip -qo "$zip" ngrok -d "$ROOT/runtime" || die "could not unpack $zip"
  rm -f "$zip"
  chmod +x "$ROOT/runtime/ngrok"
  unquarantine "$ROOT/runtime/ngrok"
  TUNNEL_BIN="$ROOT/runtime/ngrok"
  say "ngrok is in runtime/ngrok"
}

# ngrok v3 opens no tunnel at all without a token, and says so in a log nobody
# opens. Asked for here, and kept in margince.env, so the second run does not
# ask again. cloudflared needs none of this, which is the whole reason it is the
# default.
resolve_authtoken() {
  local token
  token="${NGROK_AUTHTOKEN:-$(env_value NGROK_AUTHTOKEN)}"
  if [ -z "$token" ] && [ -f "$HOME/Library/Application Support/ngrok/ngrok.yml" ]; then
    say "using the ngrok account already configured on this machine."
    return 0
  fi
  if [ -z "$token" ] && [ "$INTERACTIVE" = "1" ] && [ -t 0 ]; then
    say ""
    say "  ngrok needs a token. It is free — sign in and copy it from"
    say "  https://dashboard.ngrok.com/get-started/your-authtoken"
    say "  (or leave this blank and unset MARGINCE_TUNNEL to use cloudflared,"
    say "   which needs no account at all)"
    printf '  > '
    read -r token || true
  fi
  [ -n "$token" ] || die "no ngrok token, so no public address can be opened.
       Put NGROK_AUTHTOKEN=... in margince.env, or set MARGINCE_TUNNEL=cloudflared
       to use the provider that needs no account."
  put_env_key NGROK_AUTHTOKEN "$token"
  export NGROK_AUTHTOKEN="$token"
}

TUNNEL_PID=""
# Stopped on every exit, including the failures below and the Ctrl-C that stops
# Margince itself. A tunnel outliving the app it publishes is an open door onto
# a port that now answers for somebody else.
cleanup() {
  [ -n "$TUNNEL_PID" ] || return 0
  kill "$TUNNEL_PID" 2>/dev/null || true
  wait "$TUNNEL_PID" 2>/dev/null || true
  TUNNEL_PID=""
}
trap cleanup EXIT INT TERM

# The two providers publish their address in different places, and neither is a
# value this script may assume: a reserved domain can be unavailable and an
# account can be over its tunnel limit, and both of those still start a process.
#
# ngrok answers on a local API. cloudflared has none — the quick tunnel's
# address appears once, in its own output, which is why that is read back from
# the log file rather than from a socket.
ngrok_url() {
  local body urls
  body="$(curl -fsS --max-time 2 http://127.0.0.1:4040/api/tunnels 2>/dev/null)" || return 1
  # https FIRST, and the fallback is deliberate rather than tidy. ngrok publishes
  # one tunnel under both schemes and lists http first; taking the first match
  # would advertise an http MCP resource, and an OAuth flow that redirects to
  # http is one the agent's client refuses outright.
  urls="$(printf '%s' "$body" | tr ',' '\n' \
    | sed -n 's/.*"public_url"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  [ -n "$urls" ] || return 1
  printf '%s\n' "$urls" | grep -m1 '^https://' && return 0
  printf '%s\n' "$urls" | head -n1
}

cloudflared_url() {
  grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' "$1" 2>/dev/null | head -n1 | grep .
}

# Sets TUNNEL_URL rather than printing it, and that is not a style choice.
# Running this in a command substitution would put the background start in a
# SUBSHELL, so the TUNNEL_PID the trap reads would stay empty in this one — and
# the tunnel would outlive the script that opened it, publishing a port that now
# answers for somebody else.
TUNNEL_URL=""
start_tunnel() {
  local port="$1" log="$ROOT/data/logs/tunnel.log"
  mkdir -p "$ROOT/data/logs"
  # Truncated, not appended: the address is READ BACK out of this file, and a
  # previous run's URL sitting above this one is the wrong answer available
  # before the right one exists.
  : >"$log"

  local -a args=()
  if [ "$PROVIDER" = ngrok ]; then
    local domain="${NGROK_DOMAIN:-$(env_value NGROK_DOMAIN)}"
    args=(http "$port" --log stdout --log-format logfmt)
    [ -z "$domain" ] || args+=(--domain "$domain")
  else
    args=(tunnel --url "http://127.0.0.1:$port")
  fi

  "$TUNNEL_BIN" "${args[@]}" >>"$log" 2>&1 &
  TUNNEL_PID=$!

  TUNNEL_URL=""
  local i=0
  # 100 tries at a fifth of a second. ngrok registers in about a second;
  # cloudflared's quick tunnel takes longer, because it provisions a hostname
  # on the way up.
  while [ "$i" -lt 100 ]; do
    kill -0 "$TUNNEL_PID" 2>/dev/null || break
    if [ "$PROVIDER" = ngrok ]; then
      TUNNEL_URL="$(ngrok_url || true)"
    else
      TUNNEL_URL="$(cloudflared_url "$log" || true)"
    fi
    [ -z "$TUNNEL_URL" ] || return 0
    i=$((i + 1))
    sleep 0.2
  done
  say ""
  say "$PROVIDER did not open a tunnel. Its last words, from data/logs/tunnel.log:"
  tail -n 12 "$log" 2>/dev/null | sed 's/^/    /'
  die "no public address."
}

# ───────────────────────────────── the run ────────────────────────────────

PORT="$(app_port)"

say "Margince → Claude"
say ""

enable_connector

resolve_provider
if [ "$PROVIDER" = ngrok ]; then
  resolve_binary ngrok || fetch_ngrok
  resolve_authtoken
else
  resolve_binary cloudflared || fetch_cloudflared
fi

start_tunnel "$PORT"
URL="$TUNNEL_URL"
put_env_key MARGINCE_PUBLIC_BASE_URL "$URL"

say ""
say "Public address:  $URL"
say "MCP endpoint:    $URL/mcp"
say ""
say "Add it in Claude — Settings → Connectors → Add custom connector — and paste"
say "the MCP endpoint above. Claude registers itself and opens a sign-in page;"
say "sign in as you do here, and approve the connection."
say ""
if [ -z "${NGROK_DOMAIN:-$(env_value NGROK_DOMAIN)}" ]; then
  say "This address is temporary. It changes every time you run this, and the"
  say "connector has to be added again each time. The way to a permanent one is"
  say "a reserved ngrok domain: set NGROK_DOMAIN in margince.env, which also"
  say "switches this to ngrok, and sign up for the free account it needs."
  say ""
fi
if [ "$PROVIDER" = ngrok ]; then
  say "On the first browser visit ngrok shows its own warning page once. Click"
  say "through it. Claude's own calls never see it."
  say ""
fi

if [ "$CHECK_ONLY" = "1" ]; then
  say "--check: not starting Margince."
  cleanup
  exit 0
fi

say "Starting Margince. Leave this window open; Ctrl-C stops both."
say ""

# The same quarantine clearing the ordinary starter does, for the same reason:
# Gatekeeper has already asked about THIS file, and clearing the launcher's flag
# here is what stops the identical question about ./margince a moment later.
/usr/bin/xattr -d com.apple.quarantine ./margince 2>/dev/null || true

# NOT exec: the trap above has to outlive the launcher so the tunnel is closed
# when Margince stops.
./margince
