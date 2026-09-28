#!/usr/bin/env bash
# license.sh — obtain a Margince license (design Section 9.3).
#
# MARGINCE_TRIAL_LICENSE (kind trial) or MARGINCE_LICENSE (kind production),
# when set, is written to <file> directly and no request is made. Otherwise
# this requests one from the public Margince license API named by
# MARGINCE_LICENSE_API, authenticated with MARGINCE_ACCOUNT_TOKEN.
#
# The account token never reaches argv or a file: it is piped to curl as a
# config on standard input (`-K -`), which is how curl reads a bearer header
# without it showing up in `ps` or on disk.
#
# Usage: bash scripts/license.sh <trial|production> <file>
#        (or: make license OUT=<file>, for a production license)
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
cd "$ROOT"

usage() { echo "license: usage: bash scripts/license.sh <trial|production> <file>" >&2; exit 2; }

kind="${1:-}"
file="${2:-}"
case "$kind" in
  trial|production) ;;
  *) usage ;;
esac
[ -n "$file" ] || usage

if [ "$kind" = trial ]; then
  var=MARGINCE_TRIAL_LICENSE
  value="${MARGINCE_TRIAL_LICENSE:-}"
else
  var=MARGINCE_LICENSE
  value="${MARGINCE_LICENSE:-}"
fi

if [ -n "$value" ]; then
  ( umask 077 && printf '%s' "$value" > "$file" )
  echo "license: using \$$var (no request made)"
  exit 0
fi

missing=""
[ -n "${MARGINCE_LICENSE_API:-}" ] || missing="MARGINCE_LICENSE_API"
if [ -z "${MARGINCE_ACCOUNT_TOKEN:-}" ]; then
  if [ -n "$missing" ]; then missing="$missing and MARGINCE_ACCOUNT_TOKEN"; else missing="MARGINCE_ACCOUNT_TOKEN"; fi
fi
if [ -n "$missing" ]; then
  printf 'license: set %s (or set $%s directly to skip the request)\n' "$missing" "$var" >&2
  exit 1
fi

name="$(instance_get name)" || die "license: cannot read instance.yaml: name"
core="$(instance_get core)" || die "license: cannot read instance.yaml: core"

# The request body. Values are validated instance data, but this still goes
# through a real JSON encoder rather than string interpolation.
json="$(python3 -c '
import json, sys
kind, instance, core = sys.argv[1:4]
sys.stdout.write(json.dumps({"kind": kind, "instance": instance, "core": core}))
' "$kind" "$name" "$core")"

body_file="$(mktemp)"
trap 'rm -f "$body_file"' EXIT

api="${MARGINCE_LICENSE_API%/}"
token="$MARGINCE_ACCOUNT_TOKEN"

# -K - reads the Authorization header from standard input, so the token
# appears in no argv and in no file on disk.
http_code=""
if http_code="$(printf 'header = "Authorization: Bearer %s"\n' "$token" \
    | curl -sS -o "$body_file" -w '%{http_code}' -K - -X POST \
        -H 'Content-Type: application/json' \
        --data "$json" \
        "$api/v1/licenses")"; then
  curl_rc=0
else
  curl_rc=$?
fi

if [ "$curl_rc" -ne 0 ]; then
  printf 'license: cannot reach %s\n' "$MARGINCE_LICENSE_API" >&2
  exit 1
fi

if [ "$http_code" = 201 ]; then
  license="$(python3 -c '
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
except Exception:
    data = {}
sys.stdout.write(data.get("license") or "")
' "$body_file")"
  expires_at="$(python3 -c '
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
except Exception:
    data = {}
sys.stdout.write(data.get("expires_at") or "")
' "$body_file")"
  if [ -z "$license" ]; then
    echo "license: the license service answered 201 with no license" >&2
    exit 1
  fi
  ( umask 077 && printf '%s' "$license" > "$file" )
  printf 'license: %s license written to %s\n' "$kind" "$file"
  [ -n "$expires_at" ] && printf 'license: expires %s\n' "$expires_at"
  exit 0
fi

error_message="$(python3 -c '
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    sys.stdout.write(data.get("error") or "no message")
except Exception:
    sys.stdout.write("no message")
' "$body_file")"
printf 'license: the license service answered %s: %s\n' "$http_code" "$error_message" >&2
exit 1
