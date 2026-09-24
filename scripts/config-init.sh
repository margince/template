#!/usr/bin/env bash
# config-init.sh — this installation's own env and deployment config, owned HERE.
#
# THE PROBLEM. A dev stack reads three files, and every one of them lived inside
# the submodule: .env.local, config/margince.yaml and
# config/margince-admin-password. dev.sh seeds them there on first run. They are
# gitignored in core, so they survive a pointer move and never dirty the
# submodule — but an engineer looking for "where do I put my API key" is sent
# into a checkout this repository's own CLAUDE.md tells them never to edit, and
# the answer is discoverable only by reading dev.sh.
#
# They are also not upstream's business. The workspace name, the bootstrap
# admin, the AI posture and this machine's provider keys are the INSTALLATION's,
# and the installation is this repository.
#
# THE SHAPE. Same model the units already use: the source of truth is here, and
# core gets a STAGED COPY. `stage` refreshes it, so every lane re-copies before
# it runs and the copy cannot drift from ours.
#
# A COPY AND NOT A SYMLINK, which a reader will otherwise reach for, because it
# is the smaller change: upstream's gates walk the whole submodule tree and
# `uniquenessclaimscorpus_test.go` refuses the FIRST symlink anywhere under it —
# it will not follow one, so it reads a link as a blind spot rather than as the
# file behind it. Upstream's own dev.sh seeds these paths as regular files, so a
# link at one of them is a shape only this installation can produce.
#
# The password file is deliberately NOT moved: it holds a live credential, dev.sh
# seeds and chmods it, and no part of this repository needs to read it.
#
# Idempotent. Run by `make init`, or directly as `make config`.
#
# `config-init.sh stage` is the restaging half alone, which is what `stage` calls
# on every lane. It seeds nothing and asserts nothing about the submodule: the
# full run is a SETUP step an engineer invokes, while this one is inside every
# build, including the ones deliberately holding a dirty core/ to edit a seam
# (MARGINCE_ALLOW_DIRTY_CORE=1). The clean-submodule assertion below would refuse
# every one of those, so it stays out of the path builds take.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_core

mode_arg="${1:-init}"
case "$mode_arg" in
  init | stage) ;;
  *)
    echo "config-init.sh: unknown mode '$mode_arg' (expected 'init' or 'stage')" >&2
    exit 2
    ;;
esac

# ours | theirs (inside core) | the tracked example to seed from | mode
CONFIG_FILES="
.env.local|.env.local|.env.example|600
config/margince.yaml|config/margince.yaml|config/margince.example.yaml|644
"

while IFS='|' read -r ours theirs example mode; do
  [ -n "$ours" ] || continue
  mkdir -p "$(dirname "$ROOT/$ours")"

  if [ ! -e "$ROOT/$ours" ]; then
    # Only `init` creates ours, and `stage` does not stand in for it: seeding a
    # default from inside a lane would let a build run green against settings
    # nobody chose.
    #
    # Absent is NOT an error here, because CI is the case. Its jobs go straight
    # to `make compose` and friends — `make init` is a developer lane, by that
    # workflow's own comment — so these files never exist there, and core never
    # had them on a CI runner before this script staged anything either. There
    # is nothing to copy and nothing to warn about; a refusal here would fail
    # every CI job on a tree with nothing wrong with it.
    if [ "$mode_arg" = stage ]; then
      continue
    fi
    # Adopt whatever the submodule already had, so a stack that has been running
    # keeps its settings instead of silently reverting to the example.
    if [ -f "$CORE/$theirs" ] && [ ! -L "$CORE/$theirs" ]; then
      mv "$CORE/$theirs" "$ROOT/$ours"
      echo "config: adopted core/$theirs -> $ours"
    else
      cp "$CORE/$example" "$ROOT/$ours"
      echo "config: seeded $ours from core/$example"
    fi
    chmod "$mode" "$ROOT/$ours"
  fi

  # Stage ours into core. Compared before copying so a lane that changed nothing
  # does not churn the mtime, and the destination is REMOVED first so a SYMLINK
  # sitting there is replaced by a regular file rather than followed — cp through
  # a link would write back through it, onto ours. `-rf` rather than `-f` so a
  # directory at that path is cleared too: cmp reads one as "differs", and plain
  # `rm -f` would then fail under `set -e` naming no remedy.
  mkdir -p "$(dirname "$CORE/$theirs")"
  if [ -L "$CORE/$theirs" ] || ! cmp -s "$ROOT/$ours" "$CORE/$theirs"; then
    rm -rf "$CORE/$theirs"
    cp "$ROOT/$ours" "$CORE/$theirs"
    chmod "$mode" "$CORE/$theirs"
    echo "config: staged $ours -> core/$theirs"
  fi
done <<EOF
$CONFIG_FILES
EOF

if [ "$mode_arg" = stage ]; then
  exit 0
fi

# The submodule must not notice any of this. These paths are gitignored in core,
# so a copy at one of them is invisible to git — assert it rather than assume
# it, because a future upstream that TRACKED one of these files would turn this
# script into something that dirties the submodule on every run.
dirty="$(git -C "$CORE" status --porcelain 2>/dev/null || true)"
if [ -n "$dirty" ]; then
  printf 'config: WARNING — the submodule is no longer clean:\n%s\n' "$dirty" >&2
  echo "config: one of the paths above is tracked upstream now. Do not commit core/; fix this script." >&2
  exit 1
fi

echo "config: this installation's env and deployment config live here, in .env.local and config/"
