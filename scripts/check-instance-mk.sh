#!/usr/bin/env bash
# check-instance-mk.sh — instance.mk adds targets; it never redefines one,
# and it never breaks make's ability to read the Makefile at all.
#
# make notices a second recipe for a target, warns, and then uses the LAST one.
# An instance.mk that redefined `check` would therefore replace the template's
# gate without any failure. This script turns the warning into a refusal.
# GNU Make 3.81 (macOS) says "overriding commands"; Make 4.x says
# "overriding recipe". Both are matched.
#
# A broken instance.mk (a missing-tab recipe line, or a `check::` that
# conflicts with the template's `check:`) makes `make` itself fail with a
# nonzero exit and no "overriding" warning at all -- that must be refused
# too, not treated as "no redefinition found".
#
# instance.mk may assign only variables named INSTANCE_*: any other
# assignment (CORE, VERSION, ...) would change template targets silently.
#
# Usage: bash scripts/check-instance-mk.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ ! -f "$ROOT/instance.mk" ]; then
  echo "check-instance-mk: no instance.mk"
  exit 0
fi

set +e
output="$(make -C "$ROOT" -n help 2>&1 >/dev/null)"
status=$?
set -e

if [ "$status" -ne 0 ]; then
  printf 'check-instance-mk: make cannot read the Makefile with instance.mk:\n' >&2
  printf '%s\n' "$output" | sed 's/^/  /' >&2
  exit 1
fi

warnings="$(printf '%s\n' "$output" | grep -E 'warning: (overriding|ignoring old) (recipe|commands) for target' || true)"
if [ -n "$warnings" ]; then
  printf 'check-instance-mk: instance.mk redefines a template target:\n' >&2
  printf '%s\n' "$warnings" | grep 'overriding' | sed 's/^/  /' >&2
  printf 'Give the target another name in instance.mk, or change the template.\n' >&2
  exit 1
fi
# instance.mk may set only its own variables. A line such as `CORE := elsewhere`
# or `override VERSION = 1` would change what every template target does,
# without any target being redefined. Recipe lines (tab-indented) and comments
# are skipped; a target line has no assignment operator after its name.
assign_re='^[[:space:]]*(override[[:space:]]+|export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_.-]*)[[:space:]]*(:=|::=|\?=|\+=|!=|=)'
foreign=""
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in $'\t'*|'#'*) continue ;; esac
  case "${line#"${line%%[![:space:]]*}"}" in '#'*) continue ;; esac
  if [[ "$line" =~ $assign_re ]]; then
    var="${BASH_REMATCH[2]}"
    case "$var" in
      INSTANCE_*) ;;
      *) foreign="$foreign  $var
" ;;
    esac
  fi
done < "$ROOT/instance.mk"
if [ -n "$foreign" ]; then
  printf 'check-instance-mk: instance.mk may only set variables named INSTANCE_*; it sets:\n%s' "$foreign" >&2
  printf 'Rename the variable to INSTANCE_<name>, or change the template.\n' >&2
  exit 1
fi

echo "check-instance-mk: instance.mk adds targets only"
