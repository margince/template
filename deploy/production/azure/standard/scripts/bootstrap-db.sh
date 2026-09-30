#!/bin/bash
# Runs core's scripts/deploy/db-bootstrap.sql (the core/ submodule) against the
# Flexible Server as its admin (pgadmin): creates the margince database, the
# margince_owner and margince_app roles and the extensions. Run it from the
# jumpbox (the server has no public endpoint), in this stack's directory so
# `terraform output` works. The SQL is idempotent, so a rerun is safe.
#
#   scripts/bootstrap-db.sh [path/to/db-bootstrap.sql]
#
# The upstream SQL assumes a superuser. Azure's pgadmin is not one, so a few
# of its statements are rewritten on the fly (see the functions below).
set -euo pipefail

cd "$(dirname "$0")/.."

# core's bootstrap SQL, from the instance repository's core/ submodule (the
# core version instance.yaml pins); the working directory is this stack.
default_sql=../../../../core/scripts/deploy/db-bootstrap.sql
SQL="${1:-$default_sql}"
[[ -f "$SQL" ]] || { echo "bootstrap-db: $SQL not found (run git submodule update --init, or pass the path)" >&2; exit 1; }

# The BOOTSTRAP_* variables override the terraform outputs and TLS settings
# (for a local test server); unset, they change nothing.
pg_host="${BOOTSTRAP_PG_HOST:-$(terraform output -raw postgres_fqdn)}"
admin_pw="${BOOTSTRAP_PG_ADMIN_PASSWORD:-$(terraform output -raw postgres_admin_password)}"
owner_pw="${BOOTSTRAP_OWNER_PASSWORD:-$(terraform output -raw margince_owner_password)}"
app_pw="${BOOTSTRAP_APP_PASSWORD:-$(terraform output -raw margince_app_password)}"

export PGHOST="$pg_host" PGPORT=5432 PGUSER=pgadmin PGDATABASE=postgres
export PGPASSWORD="$admin_pw" PGSSLMODE="${BOOTSTRAP_PGSSLMODE:-verify-full}" PGSSLROOTCERT="${BOOTSTRAP_PGSSLROOTCERT-system}" PGCONNECT_TIMEOUT=10

psql -X -qAtc 'select 1' >/dev/null

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

echo "bootstrap-db: done"
