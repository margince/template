#!/usr/bin/env bash
# secret-scan.sh — no hardcoded credential reaches main.
#
# Scans a clean `git archive HEAD` export, NOT the working tree. gitleaks walks
# the filesystem and does not honour .gitignore, so an in-place scan reads
# whatever else happens to sit in the checkout — a sibling worktree under
# .claude/, a developer's real .env.local, build output — and reaches a
# different verdict on every machine. The export contains exactly what the
# commit contains, which is the only thing a merge gate can be about. (Same
# reason the SBOM lane builds from an export.)
#
# The policy lives in .gitleaks.toml, read identically here and in CI's
# secret-scan job, so `make secret-scan` locally is the bar the PR will face.
#
# The export matters MORE here than upstream. This checkout holds the core
# submodule and, after any build lane, staged copies of our own units under
# core/extensions/ — so an in-place scan would re-scan the whole of core against
# OUR policy and reach a verdict that depends on whether somebody had run `make
# compose`. `git archive HEAD` contains our commits and nothing else; the
# submodule is a gitlink, which exports as no content at all.
set -euo pipefail

root="$(git rev-parse --show-toplevel)"
cd "$root"

# The scanner is pinned and checksum-verified, never whatever is on PATH: a
# scan's verdict is a function of its rule set, so a different version is a
# different gate and local would stop predicting CI.
# shellcheck source=scripts/gitleaks-pin.sh
. "$root/scripts/gitleaks-pin.sh"
gitleaks="$(gitleaks_bin)"

export_dir="$(mktemp -d)"
trap 'rm -rf "$export_dir"' EXIT
git archive HEAD | tar -x -C "$export_dir"

# --redact: findings print as file:line with the value masked. This repo is
# a real leak must not be echoed into a permanent build log by the tool that
# caught it. Open the named line to see the value.
if ! "$gitleaks" dir "$export_dir" \
	--config "$root/.gitleaks.toml" \
	--redact \
	--no-banner; then
	echo >&2
	echo "secret-scan: FAIL — the finding above is in the commit, not just your worktree." >&2
	echo "Real credential: remove it from the source, then rotate it — it is in git history." >&2
	echo "False positive:  add a scoped allowlist to .gitleaks.toml saying why it is not one." >&2
	exit 1
fi

echo "secret-scan: clean (gitleaks over the committed tree)"
