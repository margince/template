#!/usr/bin/env bash
# config-check.sh — are our config files still in step with core's examples?
#
# Our .env.local and config/*.yaml were seeded from core's tracked examples once.
# Upstream then keeps editing those examples: a new MARGINCE_* setting, a renamed
# posture key. Nothing tells you, because our files are ours and `make dev`
# leaves them alone — so a setting added upstream is one you never learn about
# until something behaves oddly.
#
# STATELESS by design: it compares KEY SETS, ours against the example's, every
# time. Nothing is recorded, so there is no accepted-baseline file to go stale
# and no "review this" state to forget. A key you deliberately removed is
# reported until it exists in your file in some form — `make config-sync` writes
# the missing ones in commented-out, which is both the fix and the silencer.
#
# Values are never compared or printed. Ours hold API keys.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_core

python3 - "$ROOT" "$CORE" <<'PY'
import re, sys, pathlib

root, core = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])

# ours (relative to this repo) -> the tracked example in core
PAIRS = [
    (".env.local", ".env.example"),
    ("config/margince.yaml", "config/margince.example.yaml"),
]

ENV_KEY = re.compile(r"^\s*#?\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=")


def env_keys(text):
    # A COMMENTED key counts as present: config-sync writes missing keys that
    # way, so a synced file must not report the same key again next run.
    return {m.group(1) for line in text.splitlines() if (m := ENV_KEY.match(line))}


def yaml_keys(text):
    try:
        import yaml
    except ImportError:
        return None
    try:
        doc = yaml.safe_load(text) or {}
    except yaml.YAMLError as exc:
        print(f"  ! could not parse: {exc}")
        return None
    out = set()

    def walk(node, path):
        # Mapping keys only. A list's CONTENTS are data (a routing table's
        # entries, a jurisdiction's classes), not settings to be in step about.
        if isinstance(node, dict):
            for k, v in node.items():
                here = f"{path}.{k}" if path else str(k)
                out.add(here)
                walk(v, here)

    walk(doc, "")
    return out


drift = 0
for ours_rel, example_rel in PAIRS:
    ours, example = root / ours_rel, core / example_rel
    if not ours.exists():
        print(f"{ours_rel}: absent — run 'make config'")
        drift += 1
        continue
    if not example.exists():
        print(f"{ours_rel}: core no longer ships {example_rel} — this pair needs revisiting")
        drift += 1
        continue

    reader = env_keys if ours_rel.endswith(".local") else yaml_keys
    mine, theirs = reader(ours.read_text()), reader(example.read_text())
    if mine is None or theirs is None:
        print(f"{ours_rel}: skipped (no YAML parser available)")
        continue

    added, removed = sorted(theirs - mine), sorted(mine - theirs)
    if not added and not removed:
        print(f"{ours_rel}: in step with core/{example_rel}")
        continue

    drift += 1
    print(f"{ours_rel}: differs from core/{example_rel}")
    for k in added:
        print(f"  + {k}   (in core's example, not in yours)")
    for k in removed:
        print(f"  - {k}   (in yours, not in core's example)")

if drift:
    print()
    print("A '+' is a setting upstream added or renamed: read it in the example,")
    print("then either 'make config-sync' to write the missing ones in commented-out,")
    print("or set them yourself. A '-' is usually yours to keep — a local override,")
    print("or a key upstream dropped, in which case delete it.")
sys.exit(0)
PY
