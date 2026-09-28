#!/bin/sh
# deploy/host/db-init.sh — the one-time database bootstrap of the host adapter's
# local PostgreSQL.
#
# It runs inside the postgres container, not on the deploying machine: the
# image runs /docker-entrypoint-initdb.d/* once, when the data volume is empty,
# as the superuser over the local socket. It runs core's
# scripts/deploy/db-bootstrap.sql (mounted at /margince/db-bootstrap.sql), as
# core/docs/deployment.md requires before the first api start: the roles
# margince_owner and margince_app, the database margince, the extensions.
#
# The role passwords are the ones in MARGINCE_OWNER_DSN and MARGINCE_DSN, which
# the container receives from ../../shared/data.env, so the database and the
# application always agree. They reach psql through \getenv, never through a
# command line. data.env passwords are hexadecimal, so the DSNs need no
# percent-decoding.
#
# POSIX sh, no `set -u`: the image's entrypoint sources this file when it is
# not executable, and the options would then apply to the entrypoint too.

margince_dsn_password() {
  # postgres://user:password@host:port/db -> password
  printf '%s' "$1" | sed -e 's|^[^:]*://[^:]*:||' -e 's|@[^@]*$||'
}

if [ -z "${MARGINCE_OWNER_DSN:-}" ] || [ -z "${MARGINCE_DSN:-}" ]; then
  echo "db-init: MARGINCE_OWNER_DSN and MARGINCE_DSN must be set (from shared/data.env)" >&2
  exit 1
fi
MARGINCE_BOOTSTRAP_OWNER_PW="$(margince_dsn_password "$MARGINCE_OWNER_DSN")"
MARGINCE_BOOTSTRAP_APP_PW="$(margince_dsn_password "$MARGINCE_DSN")"
export MARGINCE_BOOTSTRAP_OWNER_PW MARGINCE_BOOTSTRAP_APP_PW

echo "db-init: running db-bootstrap.sql (roles, database, extensions)"
{
  printf '\\getenv owner_pw MARGINCE_BOOTSTRAP_OWNER_PW\n\\getenv app_pw MARGINCE_BOOTSTRAP_APP_PW\n'
  cat "${MARGINCE_BOOTSTRAP_SQL:-/margince/db-bootstrap.sql}"
} | psql -q -v ON_ERROR_STOP=1 --username "${POSTGRES_USER:-postgres}" --dbname postgres || exit 1
unset MARGINCE_BOOTSTRAP_OWNER_PW MARGINCE_BOOTSTRAP_APP_PW
