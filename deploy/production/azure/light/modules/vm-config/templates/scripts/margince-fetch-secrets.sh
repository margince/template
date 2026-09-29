#!/bin/bash
# Reads Margince's secrets from Key Vault with the VM's managed identity and
# writes them to /etc/margince/secrets.env (root:margince, 0640), the
# environment file of margince-api and margince-worker. Runs before every
# service start, so a restart picks up rotated values.
#
#   margince-fetch-secrets            write secrets.env
#   margince-fetch-secrets --get NAME print one Key Vault secret
#
# MARGINCE_FETCH_ATTEMPTS (default 3, 20 s apart) covers the minutes a fresh
# role assignment needs to take effect.
set -euo pipefail

# shellcheck source=/dev/null
. /etc/margince/deploy.env

OUT=/etc/margince/secrets.env
MAP=/etc/margince/secret-map
ATTEMPTS="${MARGINCE_FETCH_ATTEMPTS:-3}"
IMDS_TOKEN_URL="http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net"

token() {
  curl -fsS --max-time 10 -H Metadata:true "$IMDS_TOKEN_URL" | jq -er .access_token
}

kv_get() {
  curl -fsS --max-time 15 -H "Authorization: Bearer $TOKEN" \
    "https://${KEY_VAULT_NAME}.vault.azure.net/secrets/$1?api-version=7.4" | jq -er .value
}

with_retries() {
  local i
  for ((i = 1; i <= ATTEMPTS; i++)); do
    if "$@"; then return 0; fi
    if ((i < ATTEMPTS)); then
      echo "margince-fetch-secrets: attempt $i/$ATTEMPTS failed, retrying in 20 s" >&2
      sleep 20
    fi
  done
  return 1
}

get_one() {
  TOKEN="$(token)" || return 1
  kv_get "$1"
}

if [[ "${1:-}" == "--get" ]]; then
  with_retries get_one "$2"
  exit 0
fi

write_file() {
  local tmp env name value owner_pw app_pw push_token
  TOKEN="$(token)" || return 1
  umask 077
  tmp="$(mktemp /etc/margince/.secrets.XXXXXX)"
  # shellcheck disable=SC2064
  trap "rm -f '$tmp'" RETURN

  owner_pw="$(kv_get margince-owner-password)" || return 1
  app_pw="$(kv_get margince-app-password)" || return 1
  push_token="$(kv_get margince-graph-push-token)" || return 1
  {
    echo "MARGINCE_OWNER_DSN=postgres://margince_owner:${owner_pw}@${PG_HOST}:5432/margince?sslmode=verify-full&sslrootcert=system"
    echo "MARGINCE_DSN=postgres://margince_app:${app_pw}@${PG_HOST}:5432/margince?sslmode=verify-full&sslrootcert=system"
    echo "MARGINCE_GRAPH_PUSH_TOKEN=${push_token}"
    echo "MARGINCE_GRAPH_NOTIFICATION_URL=${PUBLIC_BASE_URL}/webhooks/graph?token=${push_token}"
  } >"$tmp"

  while read -r env name; do
    [[ -z "$env" || "$env" == \#* ]] && continue
    value="$(kv_get "$name")" || return 1
    if [[ "$value" == *$'\n'* || "$value" == *$'\r'* ]]; then
      echo "margince-fetch-secrets: secret $name contains a line break; refusing to write it" >&2
      return 1
    fi
    echo "${env}=${value}" >>"$tmp"
  done <"$MAP"

  chown root:margince "$tmp"
  chmod 0640 "$tmp"
  mv -f "$tmp" "$OUT"
}

if ! with_retries write_file; then
  if [[ -s "$OUT" ]]; then
    echo "margince-fetch-secrets: Key Vault unreachable, keeping the existing $OUT" >&2
    exit 0
  fi
  echo "margince-fetch-secrets: could not read secrets from Key Vault ${KEY_VAULT_NAME}" >&2
  exit 1
fi
