#!/usr/bin/env bash
# package.test.sh — scripts/package.sh: how the images leave the bake.
#
# A local build is loaded into the Docker image store (--load), where
# `make smoke` finds it. PUSH=1 pushes instead (--push), and only with a
# REGISTRY: without one the image names have no registry host, and a push
# would go to the default public registry.
#
# A stub `docker`, first on PATH, records each call and the PLATFORMS it
# received. The scratch instance holds this repository's scripts/, an
# instance.yaml, and a core/ that is its own git repository with a go.work.
#
# Usage: bash scripts/package.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_PREFIX
unset REGISTRY REPO ROLE PUSH METADATA_FILE PLATFORMS ALLOW_DIRTY VERSION
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false
export GIT_AUTHOR_NAME="Test Dev"     GIT_AUTHOR_EMAIL="dev@example.test"
export GIT_COMMITTER_NAME="Test Dev"  GIT_COMMITTER_EMAIL="dev@example.test"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILURES=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }
ok()   { printf 'ok: %s\n' "$*"; }

INST="$TMP/inst"
mkdir -p "$INST/core"
cp -R "$SCRIPT_DIR" "$INST/scripts"
printf 'name: acme\ndisplay_name: Acme\ncore: v0.0.2\n' > "$INST/instance.yaml"
printf 'go 1.26\n' > "$INST/core/go.work"
git -C "$INST/core" init -q && git -C "$INST/core" add -A && git -C "$INST/core" commit -qm core
git -C "$INST" init -q && git -C "$INST" add instance.yaml && git -C "$INST" commit -qm inst

STUB_BIN="$TMP/stub-bin"
mkdir -p "$STUB_BIN"
export STUB_LOG="$TMP/log"
cat > "$STUB_BIN/docker" <<'EOF'
#!/usr/bin/env bash
printf 'docker %s | PLATFORMS=%s\n' "$*" "${PLATFORMS:-}" >> "$STUB_LOG"
exit 0
EOF
chmod +x "$STUB_BIN/docker"
export PATH="$STUB_BIN:$PATH"

run_package() {
  : > "$STUB_LOG"
  local rc=0
  (cd "$INST" && env ALLOW_DIRTY=1 VERSION=v1.0.0 "$@" bash scripts/package.sh) > "$TMP/out" 2>&1 || rc=$?
  printf '%s' "$rc"
}
bake() { grep '^docker buildx bake' "$STUB_LOG" || true; }

# --- default: loaded into the local image store ---
rc="$(run_package)"
if [ "$rc" = 0 ] && bake | grep -q -- ' --load'; then ok "a local build is loaded (--load)"; else fail "a local build is loaded (--load) (rc=$rc): $(bake) $(cat "$TMP/out")"; fi
if bake | grep -q -- '--push'; then fail "a local build does not push"; else ok "a local build does not push"; fi

# --- PLATFORMS reaches the bake ---
rc="$(run_package PLATFORMS=linux/amd64)"
if [ "$rc" = 0 ] && bake | grep -q 'PLATFORMS=linux/amd64$'; then ok "PLATFORMS reaches the bake"; else fail "PLATFORMS reaches the bake: $(bake)"; fi

# --- PUSH=1 without REGISTRY is refused before the bake ---
rc="$(run_package PUSH=1)"
if [ "$rc" = 1 ]; then ok "PUSH=1 without REGISTRY exits 1"; else fail "PUSH=1 without REGISTRY exits 1 (rc=$rc)"; fi
if [ -z "$(bake)" ]; then ok "PUSH=1 without REGISTRY runs no bake"; else fail "PUSH=1 without REGISTRY runs no bake: $(bake)"; fi
if grep -q 'REGISTRY' "$TMP/out"; then ok "the refusal names REGISTRY"; else fail "the refusal names REGISTRY: $(cat "$TMP/out")"; fi

# --- PUSH=1 with REGISTRY pushes, and writes the metadata file when asked ---
rc="$(run_package PUSH=1 REGISTRY=registry.example.test METADATA_FILE="$TMP/meta.json" PLATFORMS=linux/amd64,linux/arm64)"
line="$(bake)"
if [ "$rc" = 0 ] && printf '%s\n' "$line" | grep -q -- ' --push' && ! printf '%s\n' "$line" | grep -q -- '--load'; then
  ok "PUSH=1 pushes (--push, no --load)"
else
  fail "PUSH=1 pushes (--push, no --load) (rc=$rc): $line $(cat "$TMP/out")"
fi
if printf '%s\n' "$line" | grep -qF -- "--metadata-file $TMP/meta.json"; then ok "METADATA_FILE reaches the bake"; else fail "METADATA_FILE reaches the bake: $line"; fi
if printf '%s\n' "$line" | grep -q 'PLATFORMS=linux/amd64,linux/arm64$'; then ok "a push builds every platform in PLATFORMS"; else fail "a push builds every platform in PLATFORMS: $line"; fi
if grep -q 'registry.example.test/acme/{api,worker,web}:v1.0.0' "$TMP/out"; then ok "the pushed names carry REGISTRY"; else fail "the pushed names carry REGISTRY: $(cat "$TMP/out")"; fi

if [ "$FAILURES" -gt 0 ]; then
  printf '\n%d check(s) failed\n' "$FAILURES" >&2
  exit 1
fi
printf '\npackage: all checks passed\n'
