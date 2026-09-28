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
