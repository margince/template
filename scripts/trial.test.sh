#!/usr/bin/env bash
# trial.test.sh — make trial: a production-mode desktop bundle with a trial
# license (design Section 9.4).
#
# Each case builds a throwaway instance: this repository's scripts/ and an
# instance.yaml. TRIAL_DESKTOP_CMD points at a stub that stands in for
# `make desktop`: it records that it ran and creates a fake
# build/desktop/margince/ holding the launcher's annotated margince.env.
# `uname` is a stub too, so the platform is the case's choice and the suite
# gives the same result on every host.
#
# Usage: bash scripts/trial.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Hermetic against a git hook's environment and the developer's git config
# (the constraints every script suite here follows).
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_PREFIX
export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=commit.gpgsign GIT_CONFIG_VALUE_0=false
export GIT_AUTHOR_NAME="Trial Test" GIT_AUTHOR_EMAIL="trial@example.test"
export GIT_COMMITTER_NAME="Trial Test" GIT_COMMITTER_EMAIL="trial@example.test"

# No license source may leak in from the caller's shell.
unset MARGINCE_TRIAL_LICENSE MARGINCE_LICENSE MARGINCE_LICENSE_API MARGINCE_ACCOUNT_TOKEN FORCE DATASET

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILURES=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }
ok()   { printf 'ok: %s\n' "$*"; }

# A JWT whose payload carries exp = 2031-01-01T00:00:00Z. The payload is
# base64url without padding, as a JWT is, and is chosen so that its length is
# not a multiple of 4: the decoder must restore the padding.
PAYLOAD="$(python3 -c '
import base64, json
p = base64.urlsafe_b64encode(json.dumps({"exp": 1924992000, "k": "t"}).encode()).decode().rstrip("=")
assert len(p) % 4 != 0, p
print(p)')"
TOKEN="eyJhbGciOiJFZERTQSJ9.$PAYLOAD.c2lnbmF0dXJl"

# --- stubs ---
STUBS="$TMP/stubs"
mkdir -p "$STUBS"
cat > "$STUBS/uname" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -s) printf '%s\n' "${TEST_UNAME_S:-Darwin}" ;;
  -m) printf '%s\n' "${TEST_UNAME_M:-arm64}" ;;
  *)  printf '%s\n' "${TEST_UNAME_S:-Darwin}" ;;
esac
EOF
# The desktop build stand-in. It runs from the instance root, as make does.
cat > "$STUBS/fake-desktop" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'ran %s\n' "$*" >> desktop.log
[ "${FAKE_DESKTOP_FAIL:-}" != 1 ] || exit 1
rm -rf build/desktop/margince
mkdir -p build/desktop/margince/runtime build/desktop/margince/data/demo
printf '#!/bin/sh\n' > build/desktop/margince/margince
chmod +x build/desktop/margince/margince
cat > build/desktop/margince/margince.env <<'ENV'
# Margince settings.
# MARGINCE_LICENSE=
# MARGINCE_ENV=production

# MARGINCE_PORT=8800
MARGINCE_KEYVAULT_ROOT_KEY=kept
ENV
chmod 600 build/desktop/margince/margince.env
EOF
chmod +x "$STUBS/uname" "$STUBS/fake-desktop"
export PATH="$STUBS:$PATH"
export TRIAL_DESKTOP_CMD="$STUBS/fake-desktop"

# fresh_instance [instance.yaml extra lines]
fresh_instance() {
  local inst
  inst="$(mktemp -d "$TMP/inst.XXXXXX")"
  cp -R "$SCRIPT_DIR" "$inst/scripts"
  printf 'name: acme\ndisplay_name: Acme\ncore: v0.0.2\n%s' "${1:-}" > "$inst/instance.yaml"
  printf '%s' "$inst"
}

# trial <inst> <version> — run trial.sh there; the combined output is in $OUT.
OUT=""
RC=0
trial() {
  RC=0
  OUT="$(cd "$1" && bash scripts/trial.sh "$2" 2>&1)" || RC=$?
}

ran_desktop() { [ -f "$1/desktop.log" ]; }
file_mode() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null || true; }

# --- no license: fails before the build ---
inst="$(fresh_instance)"
trial "$inst" v1.2.0
if [ "$RC" -ne 0 ]; then ok "no license fails"; else fail "no license fails: $OUT"; fi
if ! ran_desktop "$inst"; then ok "no license: the desktop build never ran"; else fail "no license: the desktop build never ran"; fi
if [ ! -e "$inst/dist/trial" ]; then ok "no license: no output directory"; else fail "no license: no output directory"; fi

# --- an invalid version: fails before the build ---
inst="$(fresh_instance)"
MARGINCE_TRIAL_LICENSE="$TOKEN" trial "$inst" 1.2.0
if [ "$RC" -ne 0 ] && ! ran_desktop "$inst"; then ok "an invalid VERSION fails before the build"; else fail "an invalid VERSION fails before the build: $OUT"; fi
if printf '%s' "$OUT" | grep -q '1.2.0'; then ok "an invalid VERSION is named"; else fail "an invalid VERSION is named: $OUT"; fi

# --- a trial license: the bundle ---
inst="$(fresh_instance)"
MARGINCE_TRIAL_LICENSE="$TOKEN" trial "$inst" v1.2.0
out="$inst/dist/trial/acme-v1.2.0-macos-arm64"
if [ "$RC" -eq 0 ]; then ok "a trial license builds the bundle"; else fail "a trial license builds the bundle: $OUT"; fi
if grep -qx 'ran VERSION=v1.2.0' "$inst/desktop.log" 2>/dev/null; then ok "the desktop build receives VERSION"; else fail "the desktop build receives VERSION: $(cat "$inst/desktop.log" 2>/dev/null)"; fi
if [ -d "$out" ] && [ -x "$out/margince" ] && [ -d "$out/runtime" ]; then ok "output directory is dist/trial/<name>-<v>-<platform>/ with the bundle"; else fail "output directory: $(ls -R "$inst/dist" 2>&1)"; fi
if grep -qx "MARGINCE_LICENSE=$TOKEN" "$out/margince.env" 2>/dev/null; then ok "the license is in the launcher's margince.env"; else fail "the license is in the launcher's margince.env: $(sed 's/eyJ.*/<token>/' "$out/margince.env" 2>&1)"; fi
if grep -qx 'MARGINCE_ENV=production' "$out/margince.env" 2>/dev/null; then ok "production mode is in margince.env"; else fail "production mode is in margince.env"; fi
if [ "$(grep -c '^[[:space:]]*MARGINCE_LICENSE=' "$out/margince.env")" = 1 ] && [ "$(grep -c '^[[:space:]]*MARGINCE_ENV=' "$out/margince.env")" = 1 ]; then ok "each key is set once"; else fail "each key is set once"; fi
if grep -qx 'MARGINCE_KEYVAULT_ROOT_KEY=kept' "$out/margince.env" && grep -qx '# MARGINCE_PORT=8800' "$out/margince.env"; then ok "the rest of margince.env is kept"; else fail "the rest of margince.env is kept"; fi
if [ "$(file_mode "$out/margince.env")" = 600 ]; then ok "margince.env is mode 600"; else fail "margince.env is mode 600: $(file_mode "$out/margince.env")"; fi
if printf '%s' "$OUT" | grep -qF -e "$TOKEN" -e "$PAYLOAD"; then fail "the license is not printed"; else ok "the license is not printed"; fi
if grep -qF -e "$TOKEN" -e "$PAYLOAD" "$out/TRIAL.txt" 2>/dev/null; then fail "TRIAL.txt does not hold the license"; else ok "TRIAL.txt does not hold the license"; fi
if grep -q 'acme' "$out/TRIAL.txt" && grep -q 'v1.2.0' "$out/TRIAL.txt" && grep -q 'v0.0.2' "$out/TRIAL.txt"; then ok "TRIAL.txt has name, version, core version"; else fail "TRIAL.txt has name, version, core version: $(cat "$out/TRIAL.txt" 2>&1)"; fi
if grep -q '2031-01-01' "$out/TRIAL.txt" 2>/dev/null; then ok "TRIAL.txt has the license expiry from exp"; else fail "TRIAL.txt has the license expiry from exp: $(cat "$out/TRIAL.txt" 2>&1)"; fi
if ! printf '%s' "$OUT" | grep -q 'desktop-seed'; then ok "no data.dataset: no seeding command"; else fail "no data.dataset: no seeding command"; fi
if [ -z "$(find "$inst" -name '.trial-license.*' -o -name '.license.*' | grep -v '/scripts/')" ]; then ok "no temporary license file is left"; else fail "no temporary license file is left: $(find "$inst" -name '.*license*')"; fi

# --- existing output: refused without FORCE=1, replaced with it ---
mkdir -p "$out" && touch "$out/old-marker"
rm -f "$inst/desktop.log"
MARGINCE_TRIAL_LICENSE="$TOKEN" trial "$inst" v1.2.0
if [ "$RC" -ne 0 ] && [ -e "$out/old-marker" ]; then ok "an existing output directory is refused without FORCE=1"; else fail "an existing output directory is refused without FORCE=1: $OUT"; fi
if ! ran_desktop "$inst"; then ok "the refusal comes before the build"; else fail "the refusal comes before the build"; fi
if printf '%s' "$OUT" | grep -q 'FORCE=1'; then ok "the refusal names FORCE=1"; else fail "the refusal names FORCE=1: $OUT"; fi
FORCE=1 MARGINCE_TRIAL_LICENSE="$TOKEN" trial "$inst" v1.2.0
if [ "$RC" -eq 0 ] && [ ! -e "$out/old-marker" ] && [ -f "$out/TRIAL.txt" ]; then ok "FORCE=1 replaces the output directory"; else fail "FORCE=1 replaces the output directory: $OUT"; fi

# --- the desktop build fails: no output ---
inst="$(fresh_instance)"
FAKE_DESKTOP_FAIL=1 MARGINCE_TRIAL_LICENSE="$TOKEN" trial "$inst" v1.2.0
if [ "$RC" -ne 0 ] && [ -z "$(ls -A "$inst/dist/trial" 2>/dev/null)" ]; then ok "a failed desktop build fails and leaves no output"; else fail "a failed desktop build fails and leaves no output: $OUT"; fi

# --- platforms ---
check_platform() {
  local s="$1" m="$2" want="$3" inst
  inst="$(fresh_instance)"
  TEST_UNAME_S="$s" TEST_UNAME_M="$m" MARGINCE_TRIAL_LICENSE="$TOKEN" trial "$inst" v1.2.0
  if [ "$RC" -eq 0 ] && [ -d "$inst/dist/trial/acme-v1.2.0-$want" ]; then ok "$s $m is $want"; else fail "$s $m is $want: $OUT"; fi
}
check_platform Darwin x86_64 macos-x64
check_platform MINGW64_NT-10.0-19045 x86_64 windows-x64
check_platform MSYS_NT-10.0-19045 x86_64 windows-x64
inst="$(fresh_instance)"
TEST_UNAME_S=Linux TEST_UNAME_M=x86_64 MARGINCE_TRIAL_LICENSE="$TOKEN" trial "$inst" v1.2.0
if [ "$RC" -eq 1 ] && ! ran_desktop "$inst" && printf '%s' "$OUT" | grep -q 'Linux'; then ok "an unsupported platform exits 1 naming it"; else fail "an unsupported platform exits 1 naming it (rc $RC): $OUT"; fi

# --- a license without exp: the bundle is built, the expiry is unknown ---
inst="$(fresh_instance)"
MARGINCE_TRIAL_LICENSE="opaque-trial-license" trial "$inst" v1.2.0
out="$inst/dist/trial/acme-v1.2.0-macos-arm64"
if [ "$RC" -eq 0 ] && grep -qi 'unknown' "$out/TRIAL.txt" 2>/dev/null; then ok "a license without exp: TRIAL.txt says the expiry is unknown"; else fail "a license without exp: $OUT $(cat "$out/TRIAL.txt" 2>&1)"; fi
if printf '%s' "$OUT" | grep -q 'opaque-trial-license'; then fail "an opaque license is not printed"; else ok "an opaque license is not printed"; fi

# --- data.dataset: the reference is placed and the seeding command printed ---
for ds in "https://example.test/org/demo-data.git@v3.1.0" "git@example.test:org/demo-data.git@main"; do
  url="${ds%@*}"; ref="${ds##*@}"
  inst="$(fresh_instance "data:
  dataset: $ds
")"
  MARGINCE_TRIAL_LICENSE="$TOKEN" trial "$inst" v1.2.0
  out="$inst/dist/trial/acme-v1.2.0-macos-arm64"
  if [ "$RC" -eq 0 ] && printf '%s' "$OUT" | grep -q 'make desktop-seed DATASET='; then ok "data.dataset ($url): the seeding command is printed"; else fail "data.dataset ($url): the seeding command is printed: $OUT"; fi
  if printf '%s' "$OUT" | grep -qF "git clone $url " && printf '%s' "$OUT" | grep -qF "checkout $ref"; then ok "data.dataset ($url): split at the last @ into url and ref"; else fail "data.dataset ($url): split at the last @: $OUT"; fi
  if grep -qxF "url: $url" "$out/data/demo/DATASET.txt" 2>/dev/null && grep -qxF "ref: $ref" "$out/data/demo/DATASET.txt"; then ok "data.dataset ($url): the reference is in data/demo/DATASET.txt"; else fail "data.dataset ($url): the reference is in data/demo/DATASET.txt: $(cat "$out/data/demo/DATASET.txt" 2>&1)"; fi
  if grep -qF "$url" "$out/TRIAL.txt" 2>/dev/null; then ok "data.dataset ($url): TRIAL.txt names the dataset"; else fail "data.dataset ($url): TRIAL.txt names the dataset"; fi
done

if [ "$FAILURES" -ne 0 ]; then
  printf '\ntrial.test: %d failure(s)\n' "$FAILURES" >&2
  exit 1
fi
printf '\ntrial.test: all passed\n'
