#!/usr/bin/env bash
# preflight.sh — is this machine able to build the installation at all?
#
# `make init` assumed a toolchain and delegated straight into core's install, so
# a machine missing one of them failed deep inside somebody else's Makefile with
# a message about that Makefile. This answers the question first, names EVERY
# missing tool at once rather than one per run, and says how to get each.
#
# REQUIRED vs OPTIONAL is a real distinction, not a courtesy: docker is needed
# for a database and therefore for `make ci`, while fswatch is needed only by
# `make watch`. Failing a fresh clone over fswatch would be wrong.
set -euo pipefail

PREFLIGHT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib.sh
source "$PREFLIGHT_DIR/lib.sh"

# "<command> <required|optional> <brew-formula> <what needs it>".
# A formula of "-" means brew cannot install it and the note below carries the
# instruction instead.
PREFLIGHT_TOOLS="\
git required - everything
go required go the backend, every gate
node required node the composed frontend lanes
pnpm required pnpm the composed frontend lanes
docker required - the database: make dev, make ci
gh optional gh make core-pr (opening the upstream PR)
fswatch optional fswatch make watch (re-staging on change)"

# Overridable so the tests can describe a machine rather than being run on one.
preflight_have() { command -v "$1" >/dev/null 2>&1; }

# preflight_docker_running — 0 when the daemon answers.
#
# Separate from preflight_have because `command -v docker` finds the CLI, and the
# CLI is present whenever Docker Desktop is INSTALLED, running or not. A stopped
# daemon passed the whole preflight and then failed inside core's db-up — which
# is the exact failure this script exists to move earlier. Overridable for the
# same reason as preflight_have: a check that can only be tested by quitting
# Docker on the author's laptop is a check nobody tests.
preflight_docker_running() { docker info >/dev/null 2>&1; }

# preflight_missing <required|optional> — "<command> <formula> <note>" per line.
preflight_missing() {
  local want="$1" cmd class formula note
  while read -r cmd class formula note; do
    [ -n "$cmd" ] || continue
    [ "$class" = "$want" ] || continue
    preflight_have "$cmd" || printf '%s %s %s\n' "$cmd" "$formula" "$note"
  done <<PREFLIGHT_TABLE
$PREFLIGHT_TOOLS
PREFLIGHT_TABLE
}

# preflight_brew_line <missing-lines> — the one brew command installing every
# missing tool brew can install, or empty when none of them can be.
preflight_brew_line() {
  local formulae="" formula
  while read -r _ formula _; do
    [ -n "$formula" ] && [ "$formula" != "-" ] && formulae="$formulae $formula"
  done <<PREFLIGHT_MISSING
$1
PREFLIGHT_MISSING
  [ -n "$formulae" ] && printf 'brew install%s\n' "$formulae"
  return 0
}

cmd_preflight() {
  local missing_req missing_opt brew_req
  missing_req="$(preflight_missing required)"
  missing_opt="$(preflight_missing optional)"

  if [ -n "$missing_opt" ]; then
    printf 'preflight: optional tools not installed:\n'
    printf '%s\n' "$missing_opt" | while read -r cmd _ note; do
      [ -n "$cmd" ] && printf '  %-10s needed by %s\n' "$cmd" "$note"
    done
    printf '  (make install INSTALL_TOOLS=1 installs what brew can)\n\n'
  fi

  if [ -z "$missing_req" ]; then
    # Installed is not the same as usable. Asked only when docker is present,
    # so a machine missing it entirely gets the one clear "install it" message
    # rather than two about the same tool.
    if ! preflight_docker_running; then
      printf 'preflight: docker is installed but its daemon is not responding.\n' >&2
      printf '  Needed by: the database — make dev, make check, make ci\n' >&2
      printf '  Start Docker Desktop and re-run. `docker info` should succeed.\n' >&2
      return 1
    fi
    printf 'preflight: every required tool is present.\n'
    return 0
  fi

  printf 'preflight: REQUIRED tools are missing:\n' >&2
  printf '%s\n' "$missing_req" | while read -r cmd _ note; do
    [ -n "$cmd" ] && printf '  %-10s needed by %s\n' "$cmd" "$note" >&2
  done
  printf '\n' >&2
  brew_req="$(preflight_brew_line "$missing_req")"
  [ -n "$brew_req" ] && printf 'Install them with:\n  %s\n' "$brew_req" >&2
  printf '%s\n' "$missing_req" | while read -r cmd formula _; do
    [ "$formula" = "-" ] || continue
    case "$cmd" in
      docker) printf 'docker: install Docker Desktop — https://docs.docker.com/desktop/\n' >&2 ;;
      git)    printf 'git: install the Xcode command line tools — xcode-select --install\n' >&2 ;;
    esac
  done
  return 1
}

# cmd_tools — install what brew can. Separate from the check, and opt-in,
# because installing software on somebody's machine is their decision and not
# one a bootstrap lane makes for them.
cmd_tools() {
  command -v brew >/dev/null || die "install-tools: brew is not installed — see https://brew.sh, or install the tools by hand"
  local line all
  all="$(preflight_missing required
preflight_missing optional)"
  line="$(preflight_brew_line "$all")"
  if [ -z "$line" ]; then
    printf 'install-tools: nothing brew can add.\n'
    return 0
  fi
  printf 'install-tools: %s\n' "$line"
  eval "$line"
}

if [ -z "${PREFLIGHT_LIB_ONLY:-}" ]; then
  case "${1:-}" in
    check) cmd_preflight ;;
    tools) cmd_tools ;;
    *) die "preflight: unknown command: ${1:-<none>} (want: check, tools)" ;;
  esac
fi
