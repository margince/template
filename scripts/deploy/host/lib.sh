#!/usr/bin/env bash
# deploy/host/lib.sh — functions shared by the host adapter's scripts.
#
# Sourced, not run. It sources nothing itself, so a caller that has not
# sourced scripts/lib.sh can still use it.

# host_env_get <key> [default] — the value of <key> in $DEPLOY_DIR/host.env.
#
# host.env is read as KEY=VALUE lines and never executed: `HOST_SSH=$(cmd)`
# returns the text `$(cmd)`. Blank lines and lines whose first non-blank
# character is `#` are skipped. Blanks around the key and around the value are
# removed, and then one pair of matching surrounding quotes (" or '). No other
# quote, escape, or `$` handling is done. When the key appears more than once,
# the last line wins.
#
# A missing file, a missing key, and an empty value all give the default. With
# no default, the function prints nothing and returns 1.
host_env_get() {
  local key="$1" file="${DEPLOY_DIR:?DEPLOY_DIR is not set}/host.env"
  local line k v found=0 value=""
  if [ -f "$file" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      line="${line%$'\r'}"
      # Leading blanks removed; a comment or blank line is skipped.
      line="${line#"${line%%[![:space:]]*}"}"
      case "$line" in ''|'#'*) continue ;; *=*) ;; *) continue ;; esac
      k="${line%%=*}"
      k="${k%"${k##*[![:space:]]}"}"
      [ "$k" = "$key" ] || continue
      v="${line#*=}"
      v="${v#"${v%%[![:space:]]*}"}"
      v="${v%"${v##*[![:space:]]}"}"
      if [ "${#v}" -ge 2 ]; then
        case "$v" in
          \"*\") v="${v#\"}"; v="${v%\"}" ;;
          \'*\') v="${v#\'}"; v="${v%\'}" ;;
        esac
      fi
      value="$v"
      found=1
    done < "$file"
  fi
  if [ "$found" = 1 ] && [ -n "$value" ]; then
    printf '%s\n' "$value"
  elif [ "$#" -ge 2 ]; then
    printf '%s\n' "$2"
  else
    return 1
  fi
}

# The oldest Docker Compose the rendered compose.yaml works with. compose.yaml
# uses `env_file` entries with `path` and `format: raw` and `depends_on` with
# `required: false`. `required` (env_file) arrived in Compose 2.24.0 and
# `depends_on.required` in 2.20.0; `format` arrived in 2.30.0 (compose-go
# 2.3.0; Compose 2.29.x uses compose-go 2.2.0, which has no such field).
# shellcheck disable=SC2034 # used by host.sh and bootstrap.sh
HOST_MIN_COMPOSE=2.30.0

# host_q <value> — <value> as one single-quoted POSIX shell word, for a
# command that a remote shell reads.
host_q() {
  printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"
}

# host_version_at_least <version> <minimum> — 0 when X.Y.Z <version> (a
# leading v and a -suffix or +suffix are ignored) is <minimum> or later.
host_version_at_least() {
  local v="${1#v}" m="${2#v}" i a b
  v="${v%%[-+]*}"
  [[ "$v" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || return 1
  local IFS=.
  # shellcheck disable=SC2086
  set -- $v 0 0 0
  a=("$1" "$2" "$3")
  # shellcheck disable=SC2086
  set -- $m 0 0 0
  b=("$1" "$2" "$3")
  for i in 0 1 2; do
    [ "$((10#${a[$i]}))" -gt "$((10#${b[$i]}))" ] && return 0
    [ "$((10#${a[$i]}))" -lt "$((10#${b[$i]}))" ] && return 1
  done
  return 0
}

# host_ssh_target — HOST_SSH from host.env, checked: user@host, where both
# parts are letters, digits, `.`, `_` and `-` and neither starts with `-`.
# Prints it; exit 1 with a message otherwise.
host_ssh_target() {
  local t
  t="$(host_env_get HOST_SSH)" || { echo "HOST_SSH is not set in $DEPLOY_DIR/host.env (user@host)" >&2; return 1; }
  [[ "$t" =~ ^[A-Za-z0-9_][A-Za-z0-9._-]*@[A-Za-z0-9_][A-Za-z0-9._-]*$ ]] ||
    { echo "HOST_SSH in $DEPLOY_DIR/host.env must be user@host (letters, digits, '.', '_', '-'): '$t'" >&2; return 1; }
  printf '%s\n' "$t"
}

# host_ssh_setup <dir> <target> — write the SSH files into <dir> (mode 600)
# and set HOST_SSH_OPTS and HOST_SSH_TARGET for host_ssh and host_scp.
#
#   <dir>/known_hosts  from HOST_KNOWN_HOSTS (required: host key checking is
#                      never disabled)
#   <dir>/ssh_key      from HOST_SSH_KEY, when it is set (otherwise the SSH
#                      agent's keys are used)
host_ssh_setup() {
  local dir="$1"
  case "$dir" in *[[:space:]]*) echo "the SSH state directory '$dir' contains a blank; ssh -o cannot take it" >&2; return 1 ;; esac
  [ -n "${HOST_KNOWN_HOSTS:-}" ] || {
    echo "HOST_KNOWN_HOSTS is not set: pass the server's known_hosts line(s) (for example from ssh-keyscan, checked against the server's fingerprint); host key checking is never disabled" >&2
    return 1
  }
  ( umask 077; printf '%s\n' "$HOST_KNOWN_HOSTS" > "$dir/known_hosts" )
  chmod 600 "$dir/known_hosts"
  HOST_SSH_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$dir/known_hosts")
  if [ -n "${HOST_SSH_KEY:-}" ]; then
    ( umask 077; printf '%s\n' "$HOST_SSH_KEY" > "$dir/ssh_key" )
    chmod 600 "$dir/ssh_key"
    HOST_SSH_OPTS+=(-i "$dir/ssh_key")
  fi
  HOST_SSH_TARGET="$2"
}

# host_ssh <command> — run <command> (one string, read by the remote shell)
# on the server. Standard input is passed on.
host_ssh() { ssh "${HOST_SSH_OPTS[@]}" "$HOST_SSH_TARGET" "$@"; }

# host_scp <args...> — scp with the same options.
host_scp() { scp "${HOST_SSH_OPTS[@]}" "$@"; }

# host_dir <instance-name> — the server directory: HOST_DIR from the
# environment, else from host.env, else /opt/margince/<instance-name>, without
# a trailing /. It must be an absolute path of letters, digits, `.`, `_`, `-`
# and `/`, without . or .. components. Prints it; exit 1 with a message
# otherwise.
host_dir() {
  local d="${HOST_DIR:-}"
  [ -n "$d" ] || d="$(host_env_get HOST_DIR "/opt/margince/$1")"
  d="${d%/}"
  [[ "$d" =~ ^/[A-Za-z0-9._/-]+$ ]] ||
    { echo "HOST_DIR '$d' must be an absolute path of letters, digits, '.', '_', '-' and '/'" >&2; return 1; }
  case "/$d/" in */../*|*/./*) echo "HOST_DIR '$d' must not contain . or .. components" >&2; return 1 ;; esac
  printf '%s\n' "$d"
}

# host_secrets_lists <name> — 0 when $DEPLOY_DIR/secrets lists <name> (the
# same reading as render.sh: blanks around a name removed, blank lines and #
# comments skipped); 1 otherwise, also when the file is missing.
host_secrets_lists() {
  local file="${DEPLOY_DIR:?DEPLOY_DIR is not set}/secrets" line
  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line%$'\r'}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ "$line" = "$1" ] && return 0
  done < "$file"
  return 1
}
