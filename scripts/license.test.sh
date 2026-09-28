#!/usr/bin/env bash
# license.test.sh — scripts/license.sh: env-var shortcuts and the public
# license API request (design Section 9.3).
#
# A stub `curl`, first on PATH, never reaches the network. It reads its
# canned answer from files under CURL_STUB_DIR (status, body, exit) and
# records its own arguments and standard input separately, so a case can
# assert the account token reached curl only through the piped `-K -`
# config and never through argv.
#
# Usage: bash scripts/license.test.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAILURES=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }
ok()   { printf 'ok: %s\n' "$*"; }

# A scratch instance: this repository's scripts/ (lib.sh, license.sh, the Go
# CLI) plus a valid instance.yaml, as scripts/deploy.test.sh builds one.
INST="$TMP/inst"
mkdir -p "$INST"
cp -R "$SCRIPT_DIR" "$INST/scripts"
printf 'name: acme\ndisplay_name: Acme\ncore: v0.0.2\n' > "$INST/instance.yaml"

STUB_BIN="$TMP/stub-bin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/curl" <<'EOF'
#!/usr/bin/env bash
# Stub curl: records argv (one per line) and stdin, then answers from
# CURL_STUB_DIR/{status,body,exit}, mimicking `-o <file> -w '%{http_code}'`.
set -u
dir="$CURL_STUB_DIR"
: > "$dir/args"
out=""
args=("$@")
i=0
while [ "$i" -lt "${#args[@]}" ]; do
  printf '%s\n' "${args[$i]}" >> "$dir/args"
  if [ "${args[$i]}" = "-o" ]; then
    i=$((i + 1))
    out="${args[$i]}"
  fi
  i=$((i + 1))
done
cat > "$dir/stdin"
if [ -n "$out" ] && [ -f "$dir/body" ]; then
  cp "$dir/body" "$out"
fi
[ -f "$dir/status" ] && printf '%s' "$(cat "$dir/status")"
code=0
[ -f "$dir/exit" ] && code="$(cat "$dir/exit")"
exit "$code"
EOF
chmod +x "$STUB_BIN/curl"
export PATH="$STUB_BIN:$PATH"

reset_stub() {
  export CURL_STUB_DIR="$TMP/curl-stub"
  rm -rf "$CURL_STUB_DIR"
  mkdir -p "$CURL_STUB_DIR"
}
stub_answer() { # stub_answer <status> <body> [exit-code]
  printf '%s' "$1" > "$CURL_STUB_DIR/status"
  printf '%s' "$2" > "$CURL_STUB_DIR/body"
  printf '%s' "${3:-0}" > "$CURL_STUB_DIR/exit"
}

# license_out <kind> <file> [VAR=val ...] — combined stdout/stderr, this
# repository's other environment variables always unset first.
license_out() {
  local kind="$1" file="$2"; shift 2
  (cd "$INST" && env -u MARGINCE_LICENSE -u MARGINCE_TRIAL_LICENSE \
    -u MARGINCE_LICENSE_API -u MARGINCE_ACCOUNT_TOKEN "$@" \
    bash scripts/license.sh "$kind" "$file") 2>&1
}
license_rc() {
  local kind="$1" file="$2"; shift 2
  (cd "$INST" && env -u MARGINCE_LICENSE -u MARGINCE_TRIAL_LICENSE \
    -u MARGINCE_LICENSE_API -u MARGINCE_ACCOUNT_TOKEN "$@" \
    bash scripts/license.sh "$kind" "$file") >/dev/null 2>&1
}

# --- bad arguments ---
out="$(license_out bogus "$TMP/f1")" && rc=0 || rc=$?
if [ "$rc" -eq 2 ]; then ok "a bad kind exits 2"; else fail "a bad kind exits 2 (rc=$rc): $out"; fi

out="$(license_out trial "")" && rc=0 || rc=$?
if [ "$rc" -eq 2 ]; then ok "a missing file argument exits 2"; else fail "a missing file argument exits 2 (rc=$rc): $out"; fi

# --- MARGINCE_TRIAL_LICENSE short-circuits a trial request ---
reset_stub
f="$TMP/trial-var"
out="$(license_out trial "$f" MARGINCE_TRIAL_LICENSE=abc)" && rc=0 || rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat "$f")" = abc ]; then ok "MARGINCE_TRIAL_LICENSE writes its value to the file"; else fail "MARGINCE_TRIAL_LICENSE writes its value to the file (rc=$rc): $out, file=$(cat "$f" 2>/dev/null)"; fi
mode="$(stat -f '%Lp' "$f" 2>/dev/null || stat -c '%a' "$f" 2>/dev/null)"
if [ "$mode" = 600 ]; then ok "the file written from MARGINCE_TRIAL_LICENSE is mode 600"; else fail "the file written from MARGINCE_TRIAL_LICENSE is mode 600 (got $mode)"; fi
if [ -s "$CURL_STUB_DIR/args" ]; then fail "MARGINCE_TRIAL_LICENSE makes no request — curl was called"; else ok "MARGINCE_TRIAL_LICENSE makes no request"; fi

# --- MARGINCE_LICENSE short-circuits a production request ---
reset_stub
f="$TMP/prod-var"
out="$(license_out production "$f" MARGINCE_LICENSE=xyz)" && rc=0 || rc=$?
if [ "$rc" -eq 0 ] && [ "$(cat "$f")" = xyz ]; then ok "MARGINCE_LICENSE writes its value to the file"; else fail "MARGINCE_LICENSE writes its value to the file (rc=$rc): $out"; fi
mode="$(stat -f '%Lp' "$f" 2>/dev/null || stat -c '%a' "$f" 2>/dev/null)"
if [ "$mode" = 600 ]; then ok "the file written from MARGINCE_LICENSE is mode 600"; else fail "the file written from MARGINCE_LICENSE is mode 600 (got $mode)"; fi
if [ -s "$CURL_STUB_DIR/args" ]; then fail "MARGINCE_LICENSE makes no request — curl was called"; else ok "MARGINCE_LICENSE makes no request"; fi

# --- no API variables ---
reset_stub
f="$TMP/noapi"
out="$(license_out trial "$f")" && rc=0 || rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qF 'MARGINCE_LICENSE_API' && printf '%s' "$out" | grep -qF 'MARGINCE_ACCOUNT_TOKEN'; then
  ok "no API variables set exits 1, naming both"
else
  fail "no API variables set exits 1, naming both (rc=$rc): $out"
fi
if [ -e "$f" ]; then fail "no API variables set writes no file"; else ok "no API variables set writes no file"; fi

# --- a successful request ---
reset_stub
stub_answer 201 '{"license":"jwt-value","expires_at":"2026-12-31T00:00:00Z"}'
f="$TMP/ok-license"
out="$(license_out trial "$f" MARGINCE_LICENSE_API=http://license.example.test MARGINCE_ACCOUNT_TOKEN=tok-secret-123)" && rc=0 || rc=$?
if [ "$rc" -eq 0 ]; then ok "a 201 answer succeeds"; else fail "a 201 answer succeeds (rc=$rc): $out"; fi
if grep -qF 'jwt-value' "$f" 2>/dev/null; then ok "the license is written to the file"; else fail "the license is written to the file: $(cat "$f" 2>/dev/null)"; fi
mode="$(stat -f '%Lp' "$f" 2>/dev/null || stat -c '%a' "$f" 2>/dev/null)"
if [ "$mode" = 600 ]; then ok "the license file is mode 600"; else fail "the license file is mode 600 (got $mode)"; fi
if printf '%s' "$out" | grep -qF 'expires 2026-12-31T00:00:00Z'; then ok "the expiry is printed"; else fail "the expiry is printed: $out"; fi
if grep -qF '"kind":"trial"' "$CURL_STUB_DIR/args" || grep -qF '"kind": "trial"' "$CURL_STUB_DIR/args"; then
  ok "the request body names the kind"
else
  fail "the request body names the kind: $(cat "$CURL_STUB_DIR/args")"
fi
body_arg="$(cat "$CURL_STUB_DIR/args")"
if printf '%s' "$body_arg" | grep -qF '"instance":"acme"' || printf '%s' "$body_arg" | grep -qF '"instance": "acme"'; then
  ok "the request body names the instance"
else
  fail "the request body names the instance: $body_arg"
fi
if printf '%s' "$body_arg" | grep -qF '"core":"v0.0.2"' || printf '%s' "$body_arg" | grep -qF '"core": "v0.0.2"'; then
  ok "the request body names the core tag"
else
  fail "the request body names the core tag: $body_arg"
fi

# --- an error answer ---
reset_stub
stub_answer 403 '{"error":"account suspended"}'
f="$TMP/refused"
out="$(license_out production "$f" MARGINCE_LICENSE_API=http://license.example.test MARGINCE_ACCOUNT_TOKEN=tok-secret-123)" && rc=0 || rc=$?
if [ "$rc" -eq 1 ]; then ok "a 403 answer fails"; else fail "a 403 answer fails (rc=$rc): $out"; fi
if printf '%s' "$out" | grep -qF '403' && printf '%s' "$out" | grep -qF 'account suspended'; then
  ok "the failure names the status and the service's message"
else
  fail "the failure names the status and the service's message: $out"
fi
if [ -e "$f" ]; then fail "a 403 answer writes no file"; else ok "a 403 answer writes no file"; fi

# --- a 201 answer with an empty license is an error ---
reset_stub
stub_answer 201 '{"license":"","expires_at":"2026-12-31T00:00:00Z"}'
f="$TMP/empty-license"
out="$(license_out trial "$f" MARGINCE_LICENSE_API=http://license.example.test MARGINCE_ACCOUNT_TOKEN=tok-secret-123)" && rc=0 || rc=$?
if [ "$rc" -eq 1 ]; then ok "a 201 answer with an empty license fails"; else fail "a 201 answer with an empty license fails (rc=$rc): $out"; fi
if [ -e "$f" ]; then fail "a 201 answer with an empty license writes no file"; else ok "a 201 answer with an empty license writes no file"; fi

# --- curl cannot reach the service ---
reset_stub
stub_answer '' '' 7
f="$TMP/unreachable"
out="$(license_out trial "$f" MARGINCE_LICENSE_API=http://license.example.test MARGINCE_ACCOUNT_TOKEN=tok-secret-123)" && rc=0 || rc=$?
if [ "$rc" -eq 1 ] && printf '%s' "$out" | grep -qF 'cannot reach'; then
  ok "a curl failure (exit 7) fails with 'cannot reach'"
else
  fail "a curl failure (exit 7) fails with 'cannot reach' (rc=$rc): $out"
fi
if [ -e "$f" ]; then fail "a curl failure writes no file"; else ok "a curl failure writes no file"; fi

# --- the account token and the license never appear in stdout/stderr or argv ---
reset_stub
stub_answer 201 '{"license":"jwt-value","expires_at":"2026-12-31T00:00:00Z"}'
f="$TMP/secret-check"
out="$(license_out trial "$f" MARGINCE_LICENSE_API=http://license.example.test MARGINCE_ACCOUNT_TOKEN=tok-secret-123)"
if printf '%s' "$out" | grep -qF 'tok-secret-123'; then fail "the account token never appears in output"; else ok "the account token never appears in output"; fi
if printf '%s' "$out" | grep -qF 'jwt-value'; then fail "the license value never appears in output"; else ok "the license value never appears in output"; fi
if grep -qF 'tok-secret-123' "$CURL_STUB_DIR/args"; then fail "the account token never appears in curl's arguments"; else ok "the account token never appears in curl's arguments"; fi
if grep -qF 'tok-secret-123' "$CURL_STUB_DIR/stdin"; then ok "the account token reaches curl through standard input (the -K - config)"; else fail "the account token reaches curl through standard input (the -K - config)"; fi

file_mode() { stat -f '%Lp' "$1" 2>/dev/null || stat -c '%a' "$1" 2>/dev/null; }

# --- a pre-existing file's mode is forced to 600 after a successful write,
# even though it was created wider (e.g. 644) ---
reset_stub
f="$TMP/existing-644-var"
printf 'old-content' > "$f"; chmod 644 "$f"
license_rc trial "$f" MARGINCE_TRIAL_LICENSE=abc
if [ "$(file_mode "$f")" = 600 ] && [ "$(cat "$f")" = abc ]; then
  ok "an existing 644 file is mode 600 after the MARGINCE_TRIAL_LICENSE shortcut writes it"
else
  fail "an existing 644 file is mode 600 after the MARGINCE_TRIAL_LICENSE shortcut writes it (mode=$(file_mode "$f"))"
fi

reset_stub
stub_answer 201 '{"license":"jwt-value","expires_at":"2026-12-31T00:00:00Z"}'
f="$TMP/existing-644-201"
printf 'old-content' > "$f"; chmod 644 "$f"
license_rc trial "$f" MARGINCE_LICENSE_API=http://license.example.test MARGINCE_ACCOUNT_TOKEN=tok-secret-123
if [ "$(file_mode "$f")" = 600 ] && grep -qF 'jwt-value' "$f"; then
  ok "an existing 644 file is mode 600 after a 201 answer writes it"
else
  fail "an existing 644 file is mode 600 after a 201 answer writes it (mode=$(file_mode "$f"))"
fi

# --- a token holding a double quote and a backslash reaches curl escaped ---
reset_stub
stub_answer 201 '{"license":"jwt-value","expires_at":"2026-12-31T00:00:00Z"}'
f="$TMP/escaped-token"
special_token='tok"back\slash'
out="$(license_out trial "$f" MARGINCE_LICENSE_API=http://license.example.test MARGINCE_ACCOUNT_TOKEN="$special_token")" && rc=0 || rc=$?
expected_stdin='header = "Authorization: Bearer tok\"back\\slash"'
got_stdin="$(cat "$CURL_STUB_DIR/stdin")"
if [ "$rc" -eq 0 ] && [ "$got_stdin" = "$expected_stdin" ]; then
  ok "a token with a double quote and a backslash reaches curl's config correctly escaped"
else
  fail "a token with a double quote and a backslash reaches curl's config correctly escaped (rc=$rc): got [$got_stdin] want [$expected_stdin]"
fi

# --- a token holding a control character (a newline) is refused before curl runs ---
reset_stub
f="$TMP/newline-token"
bad_token=$'tok\nInjected-directive: evil'
out="$(license_out trial "$f" MARGINCE_LICENSE_API=http://license.example.test MARGINCE_ACCOUNT_TOKEN="$bad_token")" && rc=0 || rc=$?
if [ "$rc" -eq 1 ]; then ok "a token with an embedded newline is refused"; else fail "a token with an embedded newline is refused (rc=$rc): $out"; fi
if [ -e "$CURL_STUB_DIR/args" ]; then fail "a token with an embedded newline never reaches curl"; else ok "a token with an embedded newline never reaches curl"; fi
if printf '%s' "$out" | grep -qF 'Injected-directive'; then fail "the token's value never appears in output"; else ok "the token's value never appears in output"; fi
if printf '%s' "$out" | grep -qF 'MARGINCE_ACCOUNT_TOKEN'; then ok "the refusal names MARGINCE_ACCOUNT_TOKEN"; else fail "the refusal names MARGINCE_ACCOUNT_TOKEN: $out"; fi
if [ -e "$f" ]; then fail "a token with an embedded newline writes no file"; else ok "a token with an embedded newline writes no file"; fi

# --- a pre-existing file is left unchanged after a failure ---
reset_stub
stub_answer 403 '{"error":"account suspended"}'
f="$TMP/pre-existing"
printf 'previous-content' > "$f"
license_rc production "$f" MARGINCE_LICENSE_API=http://license.example.test MARGINCE_ACCOUNT_TOKEN=tok-secret-123 || true
if [ "$(cat "$f")" = previous-content ]; then ok "a pre-existing file is left unchanged after a failure"; else fail "a pre-existing file is left unchanged after a failure: $(cat "$f")"; fi

if [ "$FAILURES" -gt 0 ]; then printf '\n%s case(s) failed\n' "$FAILURES" >&2; exit 1; fi
printf '\nall cases passed\n'
