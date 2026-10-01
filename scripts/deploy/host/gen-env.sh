#!/bin/sh
# deploy/host/gen-env.sh — create one generated environment file of a host
# adapter installation (design Sections 9.6 and 9.7), once.
#
# POSIX sh: it runs on the server (uploaded in shared/ and run by the apply
# step's install script) and on the developer's machine (make local-up). It
# needs /dev/urandom, od, tr, cut and dd; openssl or base64 for the base64
# keys.
#
# Kinds:
#   data      the database passwords:
#               POSTGRES_PASSWORD=<48 hex>
#               MARGINCE_OWNER_DSN=postgres://margince_owner:<48 hex>@postgres:5432/margince
#               MARGINCE_DSN=postgres://margince_app:<48 hex>@postgres:5432/margince
#               MARGINCE_REDIS=redis:6379
#   instance  the instance keys and the first admin password:
#               MARGINCE_KEYVAULT_ROOT_KEY=<base64 of 32 random bytes>
#               MARGINCE_CONNECTOR_STATE_KEY=<hex of 32 random bytes>
#               MARGINCE_WEBHOOK_KEY=<base64 of 32 random bytes>
#               MARGINCE_ADMIN_PASSWORD=<24 characters of [A-Za-z0-9]>
#             --no-admin-password leaves out the last line (secrets lists
#             MARGINCE_ADMIN_PASSWORD).
#
# The file is written only when it does not exist. The content is written to
# a temp file in the same directory first (umask 077, so mode 600), its line
# count is checked against what this kind must have, and only then is it
# published at <file> with `ln` (never `mv`): `ln` fails, without touching
# <file>, when a concurrent run has just created it. This keeps a partial
# write (for example the disk fills up mid-write) from ever reaching <file>:
# a short or failed write is discarded, so a later run still finds no file
# and creates one properly, instead of finding a corrupt file that looks
# already created. An existing file is left as it is and the exit status is
# 0. No value is printed or passed to another program's arguments.
#
# Exit status: 0 created or already present; 1 a value could not be
# generated (nothing is written) or the file could not be created; 2 usage.
#
# Usage: sh gen-env.sh data <file>
#        sh gen-env.sh instance [--no-admin-password] <file>
set -eu

usage() {
  echo "usage: gen-env.sh data <file> | gen-env.sh instance [--no-admin-password] <file>" >&2
  exit 2
}

kind="${1:-}"
[ "$#" -ge 2 ] || usage
shift
admin=1
case "$kind" in
  data) [ "$#" -eq 1 ] || usage ;;
  instance)
    if [ "$1" = --no-admin-password ]; then admin=0; shift; fi
    [ "$#" -eq 1 ] || usage
    ;;
  *) usage ;;
esac
file="$1"
case "$file" in -*|'') usage ;; esac

[ ! -e "$file" ] || exit 0

LC_ALL=C
export LC_ALL

# hex <bytes> — <bytes> random bytes as lowercase hexadecimal.
hex() {
  od -An -tx1 -N"$1" /dev/urandom | tr -d ' \n'
}

# b64_32 — 32 random bytes as standard base64 (44 characters).
b64_32() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -base64 32 | tr -d '\n'
  else
    dd if=/dev/urandom bs=32 count=1 2>/dev/null | base64 | tr -d '\n'
  fi
}

# alnum <n> — <n> random characters of [A-Za-z0-9]. The input is bounded and
# cut reads to its end, so no stage writes to a closed pipe: with SIGPIPE
# ignored, `tr < /dev/urandom | head` makes tr report a write error (Linux) or
# never end (macOS). 1024 bytes give about 248 characters; check() refuses a
# short value.
alnum() {
  dd if=/dev/urandom bs=1024 count=1 2>/dev/null | tr -dc 'A-Za-z0-9' | cut -c "1-$1"
}

# check <value> <length> <kind> — exit 1 unless <value> has <length>
# characters of the alphabet <kind> (hex, b64, alnum).
check() {
  [ "${#1}" -eq "$2" ] || { echo "gen-env.sh: a generated value has the wrong length" >&2; exit 1; }
  case "$3" in
    hex) case "$1" in *[!0-9a-f]*) echo "gen-env.sh: a generated value is not hexadecimal" >&2; exit 1 ;; esac ;;
    alnum) case "$1" in *[!A-Za-z0-9]*) echo "gen-env.sh: a generated value is not alphanumeric" >&2; exit 1 ;; esac ;;
    b64)
      case "$1" in *=) ;; *) echo "gen-env.sh: a generated value is not base64 of 32 bytes" >&2; exit 1 ;; esac
      case "${1%=}" in *[!A-Za-z0-9+/]*) echo "gen-env.sh: a generated value is not base64" >&2; exit 1 ;; esac
      ;;
  esac
}

if [ "$kind" = data ]; then
  want_lines=4
  pg="$(hex 24)"; check "$pg" 48 hex
  owner="$(hex 24)"; check "$owner" 48 hex
  app="$(hex 24)"; check "$app" 48 hex
  content="$(printf 'POSTGRES_PASSWORD=%s\nMARGINCE_OWNER_DSN=postgres://margince_owner:%s@postgres:5432/margince\nMARGINCE_DSN=postgres://margince_app:%s@postgres:5432/margince\nMARGINCE_REDIS=redis:6379' "$pg" "$owner" "$app")"
else
  want_lines=3
  vault="$(b64_32)"; check "$vault" 44 b64
  state="$(hex 32)"; check "$state" 64 hex
  webhook="$(b64_32)"; check "$webhook" 44 b64
  content="$(printf 'MARGINCE_KEYVAULT_ROOT_KEY=%s\nMARGINCE_CONNECTOR_STATE_KEY=%s\nMARGINCE_WEBHOOK_KEY=%s' "$vault" "$state" "$webhook")"
  if [ "$admin" = 1 ]; then
    want_lines=4
    pw="$(alnum 24)"; check "$pw" 24 alnum
    content="$(printf '%s\nMARGINCE_ADMIN_PASSWORD=%s' "$content" "$pw")"
  fi
fi

# Write to a temp file in the same directory first, and only publish it at
# <file> once it is confirmed complete (right line count) and the publish
# step (`ln`, not `mv`) itself succeeds. A concurrent run's file, or one this
# run's own failed write leaves behind, is never overwritten and never left
# half-written at <file>.
tmp="$file.$$.tmp"
rm -f "$tmp" 2>/dev/null || true
wrote=1
( umask 077; printf '%s\n' "$content" > "$tmp" ) 2>/dev/null || wrote=0
if [ "$wrote" = 1 ]; then
  lines="$(wc -l < "$tmp" 2>/dev/null | tr -d '[:space:]')" || lines=""
  [ "$lines" = "$want_lines" ] || wrote=0
fi
if [ "$wrote" != 1 ]; then
  rm -f "$tmp"
  [ ! -e "$file" ] || exit 0
  echo "gen-env.sh: cannot create $file" >&2
  exit 1
fi
if ln "$tmp" "$file" 2>/dev/null; then
  rm -f "$tmp"
  chmod 600 "$file"
  exit 0
fi
rm -f "$tmp"
[ ! -e "$file" ] || exit 0
echo "gen-env.sh: cannot create $file" >&2
exit 1
