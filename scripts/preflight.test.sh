#!/usr/bin/env bash
# preflight.sh's tool reasoning, against DESCRIBED machines rather than this one.
#
# The point of the overridable preflight_have: a check that can only be tested
# by uninstalling go from the developer's laptop is a check nobody tests, and
# this one exists precisely for machines that are not the author's.
#
# Usage: bash scripts/preflight.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=scripts/preflight.sh
PREFLIGHT_LIB_ONLY=1 source "$SCRIPT_DIR/preflight.sh"

FAILURES=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }
ok()   { printf 'ok: %s\n' "$*"; }

expect_eq() {
  local label="$1" got="$2" want="$3"
  if [ "$got" = "$want" ]; then ok "$label"; else
    fail "$label"; printf '  want: %q\n  got:  %q\n' "$want" "$got" >&2
  fi
}

# Describe a machine: HAVE lists the commands that exist on it.
HAVE=""
preflight_have() { case " $HAVE " in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

# And whether its docker daemon answers, which is independent of whether the
# docker CLI is installed. Default yes, so the cases below that are not about
# docker keep describing a working machine.
DOCKER_RUNNING=yes
preflight_docker_running() { [ "$DOCKER_RUNNING" = yes ]; }

# --- a complete machine ---
HAVE="git go node pnpm docker gh fswatch"
expect_eq "a complete machine is missing nothing required" "$(preflight_missing required)" ""
expect_eq "a complete machine is missing nothing optional" "$(preflight_missing optional)" ""
( cmd_preflight ) >/dev/null 2>&1 && ok "a complete machine passes the check" \
  || fail "a complete machine passes the check"

# --- optional-only gaps must NOT fail the check ---
#
# The distinction is the whole design: failing a fresh clone because fswatch is
# absent would make the bootstrap lane wrong about what it takes to start.
HAVE="git go node pnpm docker"
expect_eq "fswatch and gh are reported as optional" \
  "$(preflight_missing optional | awk '{print $1}' | sort | tr '\n' ' ')" "fswatch gh "
( cmd_preflight ) >/dev/null 2>&1 && ok "missing optional tools still pass" \
  || fail "missing optional tools still pass"

# --- a required gap must fail, and name every gap at once ---
HAVE="git node"
expect_eq "every missing required tool is named, not just the first" \
  "$(preflight_missing required | awk '{print $1}' | sort | tr '\n' ' ')" "docker go pnpm "
( cmd_preflight ) >/dev/null 2>&1 && fail "a missing required tool fails the check" \
  || ok "a missing required tool fails the check"

# --- the brew line ---
expect_eq "the brew line installs every formula-installable gap in one command" \
  "$(preflight_brew_line "$(preflight_missing required)")" "brew install go pnpm"

# docker and git have no formula here; a machine missing ONLY those must not be
# told to run a brew command with no arguments.
HAVE="go node pnpm gh fswatch"
expect_eq "a gap brew cannot fill yields no brew line" \
  "$(preflight_brew_line "$(preflight_missing required)")" ""

# And that machine must still be told what to do about docker.
out="$( ( cmd_preflight ) 2>&1 || true )"
case "$out" in
  *"Docker Desktop"*) ok "docker's own instruction is given when brew cannot help" ;;
  *) fail "docker's own instruction is given when brew cannot help" ;;
esac

# --- docker installed but NOT RUNNING ---
#
# The gap `command -v docker` cannot see. This machine has every tool, so the
# old check printed "every required tool is present" and then make dev died
# inside core's db-up on a cluster it could not start.
HAVE="git go node pnpm docker gh fswatch"
DOCKER_RUNNING=no
expect_eq "a stopped daemon is not a MISSING tool" "$(preflight_missing required)" ""
( cmd_preflight ) >/dev/null 2>&1 && fail "a stopped docker daemon fails the check" \
  || ok "a stopped docker daemon fails the check"

out="$( ( cmd_preflight ) 2>&1 || true )"
case "$out" in
  *"daemon is not responding"*) ok "the stopped daemon is named as the problem" ;;
  *) fail "the stopped daemon is named as the problem" ;;
esac
case "$out" in
  *"Start Docker Desktop"*) ok "the stopped daemon says what to do about it" ;;
  *) fail "the stopped daemon says what to do about it" ;;
esac

# A machine with NO docker at all must get one message about installing it, not
# a second about the daemon it cannot be running.
HAVE="git go node pnpm"
DOCKER_RUNNING=no
out="$( ( cmd_preflight ) 2>&1 || true )"
case "$out" in
  *"daemon is not responding"*) fail "a missing docker is not also reported as stopped" ;;
  *) ok "a missing docker is not also reported as stopped" ;;
esac
case "$out" in
  *"Docker Desktop"*) ok "a missing docker still gets its install instruction" ;;
  *) fail "a missing docker still gets its install instruction" ;;
esac

DOCKER_RUNNING=yes

if [ "$FAILURES" -gt 0 ]; then
  printf '\n%s case(s) failed\n' "$FAILURES" >&2
  exit 1
fi
printf '\nall cases passed\n'
