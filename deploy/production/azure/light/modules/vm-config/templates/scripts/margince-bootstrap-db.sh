#!/bin/bash
# Runs scripts/deploy/db-bootstrap.sql from the checked-out Margince source
# against Postgres as the server admin (pgadmin): creates the margince
# database, the margince_owner and margince_app roles and the extensions.
# The script is idempotent, so running this again is safe.
set -euo pipefail

# shellcheck source=/dev/null
. /etc/margince/deploy.env

SQL=/var/lib/margince/build/src/scripts/deploy/db-bootstrap.sql
[[ -f "$SQL" ]] || { echo "margince-bootstrap-db: $SQL not found; run margince-build first" >&2; exit 1; }

export MARGINCE_FETCH_ATTEMPTS="${MARGINCE_FETCH_ATTEMPTS:-30}"
admin_pw="$(margince-fetch-secrets --get postgres-admin-password)"
owner_pw="$(margince-fetch-secrets --get margince-owner-password)"
app_pw="$(margince-fetch-secrets --get margince-app-password)"

export PGHOST="$PG_HOST" PGPORT=5432 PGUSER=pgadmin PGDATABASE=postgres
export PGPASSWORD="$admin_pw" PGSSLMODE=verify-full PGSSLROOTCERT=system PGCONNECT_TIMEOUT=10

# The server may still be provisioning, or its private DNS record may not
# have propagated yet.
for i in $(seq 1 60); do
  if psql -qAtc 'select 1' >/dev/null 2>&1; then break; fi
  if ((i == 60)); then
    echo "margince-bootstrap-db: Postgres at $PG_HOST is not reachable" >&2
    psql -qAtc 'select 1'
    exit 1
  fi
  echo "margince-bootstrap-db: waiting for Postgres ($i/60)"
  sleep 20
done

# The role passwords go in through stdin, not argv, so they never show up in
# the process list. They are alphanumeric (random_password, special = false).
# Azure's pgadmin is not a superuser, and PostgreSQL only lets a superuser
# name the SUPERUSER attribute (and a BYPASSRLS holder name BYPASSRLS) in
# ALTER ROLE, even to turn it off. The script's unconditional normalisation
# therefore fails here; it is replaced by the same checks run only when a
# role actually carries the attribute, which keeps the guarantee: a role that
# really is SUPERUSER or BYPASSRLS still makes the bootstrap fail. When the
# upstream script stops using the unconditional form, nothing is replaced.
normalise_roles() {
  cat <<'SQL'
SELECT format('ALTER ROLE %I NOSUPERUSER', rolname) FROM pg_roles
 WHERE rolname IN ('margince_app', 'margince_owner') AND rolsuper \gexec
SELECT format('ALTER ROLE %I NOBYPASSRLS', rolname) FROM pg_roles
 WHERE rolname IN ('margince_app', 'margince_owner') AND rolbypassrls \gexec
SELECT 'ALTER ROLE margince_app NOCREATEDB' FROM pg_roles
 WHERE rolname = 'margince_app' AND rolcreatedb \gexec
SELECT 'ALTER ROLE margince_app NOCREATEROLE' FROM pg_roles
 WHERE rolname = 'margince_app' AND rolcreaterole \gexec
SQL
}

# PostgreSQL 16 gives a non-superuser that creates a role only ADMIN on it,
# without INHERIT or SET, so CREATE DATABASE ... OWNER margince_owner fails
# with "must be able to SET ROLE". The admin is granted SET and INHERIT on
# margince_owner right after the roles are normalised, and the grant is
# revoked at the end. Older servers reject the WITH syntax, so the statement
# is chosen by version. An upstream GRANT/REVOKE of the same membership is
# replaced by these, so the script works whether or not it has them.
grant_owner_to_admin() {
  cat <<'SQL'
SELECT CASE WHEN current_setting('server_version_num')::int >= 160000
  THEN 'GRANT margince_owner TO CURRENT_USER WITH INHERIT TRUE, SET TRUE'
  ELSE 'GRANT margince_owner TO CURRENT_USER' END \gexec
SQL
}

revoke_owner_from_admin() {
  cat <<'SQL'
SELECT CASE WHEN current_setting('server_version_num')::int >= 160000
  THEN 'REVOKE margince_owner FROM CURRENT_USER GRANTED BY CURRENT_USER'
  ELSE 'REVOKE margince_owner FROM CURRENT_USER' END \gexec
SQL
}

bootstrap_sql() {
  local line revoked=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      "ALTER ROLE margince_app   NOSUPERUSER NOBYPASSRLS NOCREATEDB NOCREATEROLE;")
        normalise_roles
        grant_owner_to_admin
        ;;
      "ALTER ROLE margince_owner NOSUPERUSER NOBYPASSRLS;" | "GRANT margince_owner TO CURRENT_USER;") ;;
      "REVOKE margince_owner FROM CURRENT_USER;")
        revoke_owner_from_admin
        revoked=1
        ;;
      *) printf '%s\n' "$line" ;;
    esac
  done <"$SQL"
  if ((revoked == 0)); then revoke_owner_from_admin; fi
}

{
  printf '\\set owner_pw %s\n' "$owner_pw"
  printf '\\set app_pw %s\n' "$app_pw"
  bootstrap_sql
} | psql -X -v ON_ERROR_STOP=1 -f -

echo "margince-bootstrap-db: done"
