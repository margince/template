#!/bin/bash
# Runs core's scripts/deploy/db-bootstrap.sql against a managed PostgreSQL 16
# server as its admin, who is not a superuser: Azure Flexible Server's pgadmin
# or RDS's dbadmin. Creates the margince database, the margince_owner and
# margince_app roles and the extensions. The stack's one-off setup runs it
# inside the private network (setup.tf); the SQL is idempotent, so a rerun is
# safe. The AWS and Azure standard stacks ship the same file.
#
#   scripts/bootstrap-db.sh path/to/db-bootstrap.sql
#
# Inputs, from the environment:
#   BOOTSTRAP_PG_HOST, BOOTSTRAP_PG_ADMIN_PASSWORD   the server and its admin
#   BOOTSTRAP_PG_ADMIN_USER                          default pgadmin
#   BOOTSTRAP_OWNER_PASSWORD, BOOTSTRAP_APP_PASSWORD the two role passwords
#   BOOTSTRAP_PGSSLMODE                              default verify-full
#   BOOTSTRAP_PGSSLROOTCERT                          default system
#
# The upstream SQL assumes a superuser, so a few of its statements are
# rewritten on the fly (see the functions below).
set -euo pipefail

SQL="${1:-}"
[[ -n "$SQL" && -f "$SQL" ]] || { echo "bootstrap-db: usage: bootstrap-db.sh path/to/db-bootstrap.sql" >&2; exit 1; }
for v in BOOTSTRAP_PG_HOST BOOTSTRAP_PG_ADMIN_PASSWORD BOOTSTRAP_OWNER_PASSWORD BOOTSTRAP_APP_PASSWORD; do
  [[ -n "${!v:-}" ]] || { echo "bootstrap-db: $v is not set" >&2; exit 1; }
done
owner_pw="$BOOTSTRAP_OWNER_PASSWORD"
app_pw="$BOOTSTRAP_APP_PASSWORD"

export PGHOST="$BOOTSTRAP_PG_HOST" PGPORT=5432 PGUSER="${BOOTSTRAP_PG_ADMIN_USER:-pgadmin}" PGDATABASE=postgres
export PGPASSWORD="$BOOTSTRAP_PG_ADMIN_PASSWORD" PGSSLMODE="${BOOTSTRAP_PGSSLMODE:-verify-full}" PGSSLROOTCERT="${BOOTSTRAP_PGSSLROOTCERT-system}" PGCONNECT_TIMEOUT=10

psql -X -qAtc 'select 1' >/dev/null

# The role passwords go in through stdin, not argv, so they never show up in
# the process list. They are alphanumeric (random_password, special = false).
# The admin is not a superuser, and PostgreSQL only lets a superuser
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
