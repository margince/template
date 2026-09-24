#!/usr/bin/env bash
# config-sync.sh — write the settings core's examples have and ours do not.
#
# Only for .env.local, and only COMMENTED OUT: a key upstream added is a key you
# have to decide about, and a script that decided for you would either invent a
# value or silently turn a feature on. Appended with the example's own comment
# block, so the reason arrives with the key.
#
# The YAML files are reported, never rewritten. config/margince.yaml is a live
# deployment config whose keys merge by structure (a scalar replaces, a mapping
# merges, a list replaces whole) — a text append cannot express that, and getting
# it wrong changes what the installation IS. `make config-check` names the keys;
# you merge them.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
require_core

python3 - "$ROOT" "$CORE" <<'PY'
import re, sys, pathlib

root, core = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2])
ours, example = root / ".env.local", core / ".env.example"
ENV_KEY = re.compile(r"^\s*#?\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=")

if not ours.exists():
    sys.exit("config-sync: .env.local is absent — run 'make config' first")

have = {m.group(1) for line in ours.read_text().splitlines() if (m := ENV_KEY.match(line))}
lines = example.read_text().splitlines()

# Each missing key carries the comment block immediately above it, which is
# where upstream explains what the setting does.
blocks, comment = [], []
for line in lines:
    if line.startswith("#") or not line.strip():
        comment.append(line)
        continue
    m = ENV_KEY.match(line)
    if m and m.group(1) not in have:
        blocks.append((m.group(1), list(comment), line))
    comment = []

if not blocks:
    print("config-sync: .env.local already names every key in core/.env.example")
    sys.exit(0)

with ours.open("a") as fh:
    fh.write("\n# --- added by 'make config-sync' from core/.env.example ---\n")
    fh.write("# Commented out on purpose: each of these is a decision, not a default.\n")
    for key, block, decl in blocks:
        fh.write("\n")
        for c in block:
            fh.write(f"{c}\n" if c.strip() else "\n")
        fh.write(f"# {decl}\n")

print(f"config-sync: wrote {len(blocks)} key(s) into .env.local, commented out:")
for key, _, _ in blocks:
    print(f"  {key}")
print("Uncomment and set the ones you need.")
PY
