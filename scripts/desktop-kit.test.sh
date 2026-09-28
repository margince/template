#!/usr/bin/env bash
# The shipped kit scripts, held to the claims a local lane can actually check.
#
# The Windows half of the kit runs on an engine no lane here has: Windows
# PowerShell 5.1, on a machine nobody in this repository owns. CI parses those
# files with a real 5.1 parser and (see .github/workflows/desktop-windows.yml)
# now RUNS the setup script and reads back what it wrote. Neither is reachable
# from a macOS or Linux checkout.
#
# What IS reachable is the source-level invariant behind the one bug that got
# past the parse gate and shipped in v0.0.1-rc.1: `Set-Content -Encoding UTF8`
# writes a UTF-8 byte-order mark on 5.1, the mark defeats the leading-"#" test
# in the launcher's margince.env parser, and Margince refuses to start with
# "expected KEY=value". A grep cannot prove the fix; it can stop the cmdlet
# coming back, which is how it came back the first time.
#
# Usage: bash scripts/desktop-kit.test.sh
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
KIT="$HERE/desktop-kit"

FAILURES=0
fail() { printf 'FAIL: %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }
ok()   { printf 'ok: %s\n' "$*"; }

# Comments are stripped first: this file and setup.ps1 both DISCUSS Set-Content,
# and a gate that cannot tell prose from code teaches people to phrase around it.
ps_code() { sed 's/#.*//' "$1"; }

# ── no write goes through a cmdlet that BOMs on 5.1 ──────────────────────────
for f in "$KIT"/*.ps1; do
  name="$(basename "$f")"
  if hits="$(ps_code "$f" | grep -n 'Set-Content\|Add-Content\|Out-File' || true)"; [ -n "$hits" ]; then
    fail "$name writes through a cmdlet that adds a UTF-8 BOM on Windows PowerShell 5.1.
      Use Write-Utf8NoBom instead — a BOM in margince.env stops the launcher.
      $hits"
  else
    ok "$name writes nothing through Set-Content/Add-Content/Out-File"
  fi
done

# ── and every read names its encoding, which is the same default reversed ────
#
# With no mark to detect, 5.1 decodes as the system's ANSI codepage. The
# margince.env template carries em-dashes, so an unqualified read followed by a
# rewrite turns each into three characters permanently — a file the launcher
# still accepts and a human can no longer read.
# setup.ps1 ONLY, and the scope is the point rather than a convenience. It is
# the one script that reads a config file and writes it BACK, which is what
# turns a wrong decode from a mangled value into a corrupted file. The loader
# names its encoding too, but as correctness rather than under a gate: its reads
# are read-only, and a rule reaching further would fire on the pid file and the
# generated password, which are ASCII by construction, and get argued around.
bare="$(ps_code "$KIT/setup.ps1" | grep -n 'Get-Content\|Select-String' |
          grep -v 'Encoding UTF8' || true)"
if [ -n "$bare" ]; then
  fail "setup.ps1 reads a file without naming its encoding, and it writes that
      file back. On Windows PowerShell 5.1 an unmarked file decodes as the ANSI
      codepage, so the rewrite makes the mangling permanent. Add -Encoding UTF8:
      $bare"
else
  ok "setup.ps1 names -Encoding UTF8 on every read it writes back"
fi

# ── the .ps1 files keep their OWN mark, which is the opposite requirement ────
#
# 5.1 reads a .ps1 as ANSI without it and every em-dash reaches the user as
# mojibake. The two rules are easy to conflate, so both are held down here.
for f in "$KIT"/*.ps1; do
  name="$(basename "$f")"
  if [ "$(head -c 3 "$f" | od -An -tx1 | tr -d ' \n')" = "efbbbf" ]; then
    ok "$name keeps its own BOM (5.1 reads it as ANSI without one)"
  else
    fail "$name lost its UTF-8 BOM — Windows PowerShell 5.1 will read it as ANSI
      and mangle every em-dash in its messages."
  fi
done

# ── an inline `shell: powershell` block in CI must be pure ASCII ─────────────
#
# The same 5.1 default, met from the other side and one level up. GitHub Actions
# writes a `run:` block to a temp .ps1 with NO byte-order mark, and 5.1 reads an
# unmarked .ps1 as the ANSI codepage. An em-dash arrives as three cp1252
# characters ending in a RIGHT DOUBLE QUOTATION MARK, which closes the string it
# sits in; the file then stops parsing and the step fails with a cascade of
# "Unexpected token" that names nothing about an encoding.
#
# It cost a full Windows dispatch to learn, and reading the YAML cannot catch it:
# the block is valid YAML and valid PowerShell exactly as authored. `shell: pwsh`
# (7) is exempt, because it reads UTF-8 with no mark.
for f in "$HERE/../.github/workflows"/*.yml; do
  [ -e "$f" ] || continue
  name="$(basename "$f")"
  hits="$(LC_ALL=C awk '
    /^[[:space:]]*shell:[[:space:]]*powershell[[:space:]]*$/ { armed = 1; next }
    armed && /^[[:space:]]*run:[[:space:]]*\|/ {
      match($0, /^[ ]*/); runindent = RLENGTH; inblock = 1; armed = 0; next
    }
    inblock {
      if ($0 ~ /[^[:space:]]/) {
        match($0, /^[ ]*/)
        if (RLENGTH <= runindent) { inblock = 0; next }
      }
      if ($0 ~ /[\x80-\xFF]/) printf "      line %d: %s\n", NR, $0
    }
  ' "$f")"
  if [ -n "$hits" ]; then
    fail "$name has a non-ASCII character inside a \`shell: powershell\` block.
      5.1 reads that block as ANSI, so the string it sits in stops parsing and
      the step dies on \"Unexpected token\". Write it in ASCII.
$hits"
  else
    ok "$name: every inline \`shell: powershell\` block is ASCII"
  fi
done

# ── the repair for folders the old script already corrupted still runs ───────
#
# A fixed writer does not help the population that has already run Setup once:
# Set-EnvKey keeps an existing value and rewrites nothing. Repair-EnvEncoding is
# what makes re-running Setup.cmd the fix, so it has to stay wired to the flow
# and not just defined.
if ps_code "$KIT/setup.ps1" | grep -qE '^Repair-EnvEncoding[[:space:]]*$'; then
  ok "setup.ps1 calls Repair-EnvEncoding from its main flow"
else
  fail "setup.ps1 defines Repair-EnvEncoding but never calls it at top level —
      a folder corrupted by an earlier release stays unstartable."
fi

# ── the macOS half writes the same two files and must agree ──────────────────
#
# Nothing in bash can emit a BOM by accident, so this only checks the pair has
# not drifted into writing different filenames.
for f in "$KIT/setup.command" "$KIT/setup.ps1"; do
  name="$(basename "$f")"
  for want in margince.env margince.yaml; do
    if grep -q "$want" "$f"; then
      ok "$name writes $want"
    else
      fail "$name no longer mentions $want — the two halves have drifted."
    fi
  done
done

# ── the provider menu writes the key that was chosen, and only that one ──────
#
# Setup asks for ONE model provider key, chosen from a menu, because the app's
# own onboarding offers exactly these two (frontend/src/screens/setup-providers.ts)
# and they are the two vendors that serve chat AND embeddings from one key. A
# routing document requires an embeddings binding, so a third choice here would
# be a provider that cannot complete one.
#
# Run end to end rather than grepped, because the failure this catches is not a
# missing string: a menu that reads the choice and then writes the OTHER vendor's
# variable leaves a folder whose AI surfaces are still on the offline fake, with
# the pasted key sitting under a name nothing reads. Only reading the file back
# tells those two apart.
setup_fixture() {
  local dir="$1"
  mkdir -p "$dir"
  # The shape stamp_env_template lands: every key line present and COMMENTED,
  # which is the branch of set_env_key that rewrites in place rather than
  # appending. A fixture without them would exercise the other branch only.
  cat >"$dir/margince.env" <<'ENV'
# Margince settings.
# ANTHROPIC_API_KEY=
# OPENAI_API_KEY=
# GEMINI_API_KEY=
# OPENAI_COMPATIBLE_API_KEY=
ENV
  cp "$KIT/setup.command" "$dir/Setup.command"
}

# Piped stdin, deliberately. It leaves PROMPT on — INTERACTIVE is what --no-prompt
# and desktop.sh turn off — while `finish`'s pause tests `[ -t 0 ]` and so does
# not block. The Google prompts after the provider read EOF and skip themselves.
run_setup() {
  local dir="$1"; shift
  printf '%b' "$1" | ( cd "$dir" && bash "./Setup.command" >/dev/null 2>&1 )
}

env_set() {  # env_set <dir> <key> — the UNcommented value, empty when unset
  sed -n "s/^$2=//p" "$1/margince.env" | tail -n1
}

# picked <label> <stdin> <key it must set> <value> <key it must not touch>
picked() {
  local label="$1" input="$2" want_key="$3" want_val="$4" other="$5" dir got other_got
  dir="$(mktemp -d)"
  setup_fixture "$dir"
  run_setup "$dir" "$input"
  got="$(env_set "$dir" "$want_key")"
  other_got="$(env_set "$dir" "$other")"
  if [ "$got" != "$want_val" ]; then
    fail "the provider menu on \"$label\" left $want_key=\"$got\", wanted \"$want_val\".
      Someone who picked a provider and pasted a key would have an installation
      whose AI surfaces are still on the offline fake."
  elif [ -n "$other_got" ]; then
    fail "the provider menu on \"$label\" ALSO set $other=$other_got. It asks for one
      key and must write one: a second vendor's variable filled from this answer
      is a key stored under a name its owner never chose."
  else
    ok "setup.command: $label sets $want_key and leaves $other alone"
  fi
  rm -rf "$dir"
}

picked '1 picks OpenRouter'  '1\nsk-or-TEST\n'  OPENAI_COMPATIBLE_API_KEY sk-or-TEST GEMINI_API_KEY
picked '2 picks Gemini'      '2\nAIzaTEST\n'    GEMINI_API_KEY            AIzaTEST   OPENAI_COMPATIBLE_API_KEY
# The names are accepted beside the digits: a menu whose reader types what they
# see is a menu that works. Held here so the two halves cannot quietly diverge
# into digits-only on one platform.
picked 'the word gemini'     'gemini\nAIzaWORD\n'  GEMINI_API_KEY AIzaWORD OPENAI_COMPATIBLE_API_KEY

# Neither key set is a SUPPORTED outcome rather than a degraded one: the folder
# still starts, and Settings -> AI can bind a provider later. What must never
# happen is a variable filled from an answer that named no provider.
declined() {
  local label="$1" dir left
  dir="$(mktemp -d)"
  setup_fixture "$dir"
  shift
  if [ "$1" = "--no-prompt" ]; then
    ( cd "$dir" && bash "./Setup.command" --no-prompt >/dev/null 2>&1 </dev/null )
  else
    run_setup "$dir" "$1"
  fi
  left="$(env_set "$dir" OPENAI_COMPATIBLE_API_KEY)$(env_set "$dir" GEMINI_API_KEY)"
  if [ -n "$left" ]; then
    fail "setup.command wrote a provider key (\"$left\") when the menu got \"$label\".
      Nothing that is not a choice may be taken for one."
  else
    ok "setup.command: $label leaves both provider keys unset"
  fi
  rm -rf "$dir"
}

declined 'a bare Return'      '\n'
declined 'an answer that is neither' 'zzz\n'

# ── the binding, not just the key ─────────────────────────────────────────
#
# A provider key is half the configuration and the half that does nothing alone.
# Nothing routes to a vendor until a TIER is bound to it, and until then every AI
# surface answers from the offline fake — plausibly, in canned text. So a folder
# handed a perfectly good key was indistinguishable from one whose key had been
# rejected, and that is what these hold: the vendor a person picked has to reach
# margince.yaml as a binding, not only margince.env as a credential.
#
# Read back through a YAML parser rather than grepped. The failure that costs an
# afternoon is a seed block that is present and malformed — deployconfig.Load
# runs at the top of every boot and REFUSES the file, so a broken binding does
# not degrade the AI surfaces, it stops the process.
bound() {  # bound <label> <stdin> <provider it must name> <base_url, or ""> 
  local label="$1" input="$2" want_provider="$3" want_url="$4" dir
  dir="$(mktemp -d)"
  setup_fixture "$dir"
  run_setup "$dir" "$input"
  if ! WANT_PROVIDER="$want_provider" WANT_URL="$want_url" python3 - "$dir/margince.yaml" <<'PY'
import os, sys, yaml
doc = yaml.safe_load(open(sys.argv[1]))
want, want_url = os.environ["WANT_PROVIDER"], os.environ["WANT_URL"]
r = (doc.get("seeds") or {}).get("ai_routing")
if not r:
    sys.exit("margince.yaml carries no seeds.ai_routing")
tiers = r.get("tiers") or {}
# The five the task contract declares. A binding missing one leaves that lane on
# the fake, which is the whole failure in miniature.
for t in ("local_small", "local_large", "cheap_cloud", "premium", "frontier"):
    if t not in tiers:
        sys.exit("no binding for tier %s: %s" % (t, sorted(tiers)))
    if tiers[t].get("provider") != want:
        sys.exit("tier %s names %r, wanted %r" % (t, tiers[t].get("provider"), want))
    if not tiers[t].get("model"):
        sys.exit("tier %s names no model" % t)
    if want_url and tiers[t].get("base_url") != want_url:
        sys.exit("tier %s has base_url %r, wanted %r" % (t, tiers[t].get("base_url"), want_url))
emb = r.get("embeddings") or {}
# A routing document REQUIRES an embeddings binding; without one the seed is
# refused and the installation boots unbound anyway.
if emb.get("provider") != want or not emb.get("model"):
    sys.exit("embeddings binding is %r, wanted provider %r with a model" % (emb, want))
if not r.get("profile"):
    sys.exit("the binding declares no profile")
PY
  then
    fail "picking \"$label\" left margince.yaml without a usable binding.
      The key was written and nothing was bound to it, so every AI surface still
      answers from the offline fake — which reads as a rejected key."
  else
    ok "setup.command: $label binds every tier to $want_provider"
  fi
  rm -rf "$dir"
}

bound 'Gemini'     '2\nAIzaTEST\n'    gemini            ""
# OpenRouter rides the openai_compatible adapter, which FAILS CLOSED without a
# base_url. A binding that named the adapter and omitted the URL would be the
# same bug one layer down: configured, and serving nothing.
bound 'OpenRouter' '1\nsk-or-TEST\n'  openai_compatible "https://openrouter.ai/api"

# No provider is a supported outcome, and it must not produce a half-written
# binding. An installation with nothing bound runs with its AI lanes absent,
# which is a state Settings -> AI can fix; a seed naming a vendor with no key
# is one it cannot.
unbound() {
  local label="$1" dir
  dir="$(mktemp -d)"
  setup_fixture "$dir"
  shift
  if [ "$1" = "--no-prompt" ]; then
    ( cd "$dir" && bash "./Setup.command" --no-prompt >/dev/null 2>&1 </dev/null )
  else
    run_setup "$dir" "$1"
  fi
  if grep -q 'ai_routing' "$dir/margince.yaml"; then
    fail "setup.command wrote a model binding when the menu got \"$label\".
      A binding naming a vendor this installation has no key for is worse than
      none: it routes real work at a credential that was never given."
  else
    ok "setup.command: $label leaves margince.yaml unbound"
  fi
  rm -rf "$dir"
}

unbound 'a bare Return' '\n'
unbound '--no-prompt'   --no-prompt

# The binding and the key must name the SAME vendor. Held separately from the
# menu test because the two are written by different functions from the same
# answer, and a mismatch is invisible in either file alone: the folder would
# hold a real OpenRouter key and route every lane at Gemini.
same_vendor() {
  local dir provider key
  dir="$(mktemp -d)"
  setup_fixture "$dir"
  run_setup "$dir" '2\nAIzaPAIR\n'
  provider="$(python3 -c "import yaml,sys; d=yaml.safe_load(open(sys.argv[1])); print(d['seeds']['ai_routing']['tiers']['premium']['provider'])" "$dir/margince.yaml" 2>/dev/null)"
  key="$(env_set "$dir" GEMINI_API_KEY)"
  if [ "$provider" != "gemini" ] || [ "$key" != "AIzaPAIR" ]; then
    fail "the key and the binding disagree: margince.env holds GEMINI_API_KEY=\"$key\"
      and margince.yaml routes premium at \"$provider\". One answer must produce one vendor."
  else
    ok "setup.command: the binding names the vendor whose key it stored"
  fi
  rm -rf "$dir"
}
same_vendor
declined 'immediate EOF'      ''
# The lane every release runs. A read added to this path blocks a CI job that
# has no keyboard, which is the failure mode --no-prompt exists to prevent.
declined '--no-prompt'        '--no-prompt'

# ── the webhook key is generated exactly like the vault key ─────────────────
#
# MARGINCE_WEBHOOK_KEY is this installation's third own-alone key, generated by
# the same helper (set_env_key), under the same "only when absent" rule, in the
# same base64-of-32-bytes format as MARGINCE_KEYVAULT_ROOT_KEY (constraints.md).
# Without it a bundle's mutating /webhook-subscriptions paths answer 503
# (core/docs/reference/configuration.md, MARGINCE_WEBHOOK_KEY) — never wired up
# until this task.
#
# Run end to end, for the same reason the provider menu above is: a key that is
# generated in the wrong shape, or that a second run silently rotates, is
# invisible to a grep and only a real run and a real second run catch it.
key_fixture() {
  mkdir -p "$1"
  cp "$KIT/setup.command" "$1/Setup.command"
}

KDIR="$(mktemp -d)"
key_fixture "$KDIR"
kout="$(cd "$KDIR" && bash "./Setup.command" --no-prompt 2>&1 </dev/null)"
vault="$(env_set "$KDIR" MARGINCE_KEYVAULT_ROOT_KEY)"
state="$(env_set "$KDIR" MARGINCE_CONNECTOR_STATE_KEY)"
webhook="$(env_set "$KDIR" MARGINCE_WEBHOOK_KEY)"

if [[ "$webhook" =~ ^[A-Za-z0-9+/]{43}=$ ]]; then
  ok "setup.command generates MARGINCE_WEBHOOK_KEY as base64 of 32 bytes"
else
  fail "setup.command's MARGINCE_WEBHOOK_KEY is \"$webhook\", wanted base64 of 32
      bytes like MARGINCE_KEYVAULT_ROOT_KEY (\"$vault\")"
fi

if printf '%s' "$kout" | grep -q 'generated MARGINCE_WEBHOOK_KEY'; then
  ok "setup.command announces the generated webhook key, in the same style as the vault key"
else
  fail "setup.command generates MARGINCE_WEBHOOK_KEY without saying so:
$kout"
fi

# Re-running keeps every key: a second value would silently invalidate what the
# first one signed — the same reason set_env_key never overwrites the vault key.
kout2="$(cd "$KDIR" && bash "./Setup.command" --no-prompt 2>&1 </dev/null)"
if [ "$(env_set "$KDIR" MARGINCE_WEBHOOK_KEY)" = "$webhook" ] \
   && [ "$(env_set "$KDIR" MARGINCE_KEYVAULT_ROOT_KEY)" = "$vault" ] \
   && [ "$(env_set "$KDIR" MARGINCE_CONNECTOR_STATE_KEY)" = "$state" ]; then
  ok "a second run keeps all three installation keys unchanged"
else
  fail "a second run changed a key that must never rotate silently: $kout2"
fi
rm -rf "$KDIR"

# A second, independent installation must not share the first one's key — one
# key shared by every download would sign every recipient's webhook
# subscriptions under a value anyone with the download already has.
K2DIR="$(mktemp -d)"
key_fixture "$K2DIR"
( cd "$K2DIR" && bash "./Setup.command" --no-prompt >/dev/null 2>&1 </dev/null )
webhook2="$(env_set "$K2DIR" MARGINCE_WEBHOOK_KEY)"
if [ -n "$webhook2" ] && [ "$webhook2" != "$webhook" ]; then
  ok "two installations get different MARGINCE_WEBHOOK_KEY values"
else
  fail "two installations got the same MARGINCE_WEBHOOK_KEY: \"$webhook2\""
fi
rm -rf "$K2DIR"

# The openssl-missing note has to grow with the key it now also leaves unset,
# or a folder without openssl is told to fix two keys and ships a third that
# silently answers 503.
if grep -q 'rand -base64 32   # MARGINCE_WEBHOOK_KEY' "$KIT/setup.command"; then
  ok "setup.command's openssl-missing note also covers MARGINCE_WEBHOOK_KEY"
else
  fail "setup.command's openssl-missing note never mentions MARGINCE_WEBHOOK_KEY —
      a folder without openssl would ship with the key unset and no way to know."
fi

# setup.ps1 cannot be run from here (Windows PowerShell 5.1 only), so its half
# of the same behavior is grepped, the same way the rest of this file holds the
# Windows half to the macOS one.
if grep -q "Set-EnvKey 'MARGINCE_WEBHOOK_KEY'" "$KIT/setup.ps1"; then
  ok "setup.ps1 sets MARGINCE_WEBHOOK_KEY through Set-EnvKey, the same write-once helper as the vault key"
else
  fail "setup.ps1 never calls Set-EnvKey 'MARGINCE_WEBHOOK_KEY' — the webhook key is not generated on Windows"
fi
if grep -qE '\$webhook[[:space:]]*=[[:space:]]*\[Convert\]::ToBase64String\(\(New-RandomBytes 32\)\)' "$KIT/setup.ps1"; then
  ok "setup.ps1 generates MARGINCE_WEBHOOK_KEY as base64 of 32 random bytes, like the vault key"
else
  fail "setup.ps1 does not generate MARGINCE_WEBHOOK_KEY as base64 of 32 random bytes"
fi
if grep -q 'generated MARGINCE_WEBHOOK_KEY' "$KIT/setup.ps1"; then
  ok "setup.ps1 announces the generated webhook key"
else
  fail "setup.ps1 generates MARGINCE_WEBHOOK_KEY without announcing it"
fi

# ── the download's quarantine is cleared, and only when there is one ─────────
#
# A downloaded folder carries com.apple.quarantine on every file, and Margince's
# binaries are ad-hoc signed, so Gatekeeper refuses them while the mark is
# there. Setup is the one file whose mark the reader has already got past, which
# makes it the only place that can clear it for the launcher behind it.
#
# Run rather than grepped, for the reason the provider menu is: the failure is
# not a missing string but a mark that is still on the file afterwards, and only
# reading the attribute back can see that.
if ! command -v xattr >/dev/null 2>&1; then
  ok "setup.command quarantine: skipped (no xattr on this platform)"
else
  # A folder that arrived as a download.
  QDIR="$(mktemp -d)"
  setup_fixture "$QDIR"
  printf '#!/bin/sh\nexit 0\n' >"$QDIR/margince"
  chmod +x "$QDIR/margince"
  xattr -w com.apple.quarantine "0081;00000000;Test;TESTUUID" "$QDIR/margince" 2>/dev/null || true
  if ! xattr "$QDIR/margince" 2>/dev/null | grep -q com.apple.quarantine; then
    ok "setup.command quarantine: skipped (this filesystem keeps no xattrs)"
  else
    qout="$(printf '\n\n\n' | ( cd "$QDIR" && bash "./Setup.command" 2>&1 ) || true)"
    if xattr "$QDIR/margince" 2>/dev/null | grep -q com.apple.quarantine; then
      fail "setup.command left com.apple.quarantine on the launcher binary. The
      app is ad-hoc signed, so Gatekeeper refuses it while the mark is there and
      the folder cannot start at all."
    else
      ok "setup.command clears the download's quarantine from the folder"
    fi
    # Announced, not silent: this removes the check that would have stopped a
    # malicious download, and the person it is done for is sitting right there.
    if printf '%s' "$qout" | grep -q 'xattr -dr com.apple.quarantine'; then
      ok "setup.command prints the quarantine command it ran"
    else
      fail "setup.command cleared the quarantine without saying so. Removing
      Gatekeeper's check is a decision, not a detail — it has to name what it
      did and print the command, so a reader can judge it."
    fi
  fi
  rm -rf "$QDIR"

  # A folder built locally has no mark, and must be left alone in silence —
  # every folder `make desktop-install` ever sees is this one.
  CDIR="$(mktemp -d)"
  setup_fixture "$CDIR"
  printf '#!/bin/sh\nexit 0\n' >"$CDIR/margince"
  chmod +x "$CDIR/margince"
  cout="$(printf '\n\n\n' | ( cd "$CDIR" && bash "./Setup.command" 2>&1 ) || true)"
  if printf '%s' "$cout" | grep -qi 'quarantine\|downloaded'; then
    fail "setup.command talked about quarantine on a folder that carries none.
      A locally built folder is the only kind the make lanes ever prepare."
  else
    ok "setup.command says nothing about quarantine on an unmarked folder"
  fi
  rm -rf "$CDIR"
fi

# ── and the Windows half must offer the same two ─────────────────────────────
#
# The macOS half is exercised end to end above; 5.1 is not reachable from this
# checkout. What a grep CAN hold is that a provider added to one platform's menu
# was added to the other's — a release where only one platform reaches Gemini is
# the drift this catches.
# ── a folder that cannot consume the seed is told so ─────────────────────────
#
# seeds.ai_routing is consumed ONCE, at workspace creation. The release
# bundles ship a workspace already created — they are seeded on the build
# machine — so a binding Setup writes into their margince.yaml is never read.
#
# Verified on the real v0.1.1-rc.1 Apple-silicon folder: Setup wrote the seed,
# the app booted, `ai.routing` was ABSENT, and all 1842 ai_call rows were
# `fake`. Setup had said "the AI surfaces answer on your key rather than the
# fake" — a message asserting the opposite of what happened, which is the same
# failure shape as the argument-mode bug below.
#
# So the claim is conditional on the folder actually being able to take it, and
# `data/pg` is the signal available before the first start. The seed is still
# WRITTEN in both cases: `data/` is what the documented reset deletes, and a
# rebuilt installation should come up bound.
seeded_claim() {  # seeded_claim <label> <make data/pg?> <must say> <must not say>
  local label="$1" seed_pg="$2" want="$3" unwanted="$4" dir out
  dir="$(mktemp -d)"
  setup_fixture "$dir"
  [ "$seed_pg" = yes ] && mkdir -p "$dir/data/pg"
  out="$(printf '2\nAQ.TESTKEY\n\n\n' | ( cd "$dir" && bash ./Setup.command 2>&1 ) || true)"

  if ! printf '%s' "$out" | grep -qF "$want"; then
    fail "on $label, Setup does not say \"$want\":
$(printf '%s' "$out" | sed 's/^/      /' | tail -8)"
  elif printf '%s' "$out" | grep -qF "$unwanted"; then
    fail "on $label, Setup says \"$unwanted\" — which is not true of this folder.
      A message that asserts what did not happen is worse than none: it sends
      the reader looking for a fault somewhere else entirely."
  # The seed is written either way, so a later reset comes up bound.
  elif ! grep -q 'ai_routing' "$dir/margince.yaml"; then
    fail "on $label, no binding was written at all. It belongs in the file even
      when this installation cannot consume it — data/ is what the documented
      reset deletes, and the rebuilt installation should come up bound."
  else
    ok "setup.command: $label is told the truth about the binding"
  fi
  rm -rf "$dir"
}

# The seeded folder is told its AI stays on the fake, and NOT told to go bind
# the tiers in Settings -> AI. That instruction was itself unfollowable: the
# screen renders no form for an installation with no tiers, so the note sent
# its reader to the one place that looks like the answer and is not. Fixed
# upstream in margince/margince#4853; until a build carries it, saying nothing
# about that screen beats naming a dead end.
# Both shapes now get the same answer, because the seed reaches the
# installation either way: a fresh folder consumes it at workspace creation,
# and one that ships a database has it planted at the next boot (core #4856).
# The folder that cannot take a seed at all is the one whose margince.yaml
# already exists, and that branch is held by the Settings -> AI guard below.
seeded_claim 'a folder that ships a database' yes \
  'answer on your key rather than the fake' 'cannot make that first binding'
seeded_claim 'a fresh folder'                no  \
  'answer on your key rather than the fake' 'cannot make that first binding'

# The instruction is correct again, and this is the commit that restores it.
#
# It was removed because Settings -> AI rendered no form for an installation
# with no tiers bound, so "bind the tiers there" could not be carried out. Core
# margince/margince#4853 gives that screen a first binding built from a keyed
# provider's presets, and #4856 makes a DECLARED binding arrive on its own — so
# the folder that writes a seed needs no instruction at all, and the one that
# cannot write a seed has a screen that works.
#
# Held as a string because that is where the wrongness lived: the sentence
# survived two releases with every behavioural test around it passing.
for f in "$KIT/setup.command" "$KIT/setup.ps1"; do
  name="$(basename "$f")"
  if grep -q 'Settings -> AI' "$f"; then
    ok "$name points at Settings -> AI, which can now bind a first tier"
  else
    fail "$name names no way to bind the tiers. A folder whose margince.yaml
      already exists cannot take a seed, so its reader needs the screen — and
      since core #4853 that screen works."
  fi
done

# And the claim that a written seed does nothing must be gone with it: since
# core #4856 the binding is planted at boot wherever ai.routing is unset.
for f in "$KIT/setup.command" "$KIT/setup.ps1"; do
  name="$(basename "$f")"
  if grep -qE 'cannot make that first binding|binding cannot reach it' "$f"; then
    fail "$name still says the binding cannot reach this installation. Core
      #4856 plants a declared binding at boot when ai.routing is unset, so a
      folder that wrote a seed comes up bound."
  else
    ok "$name no longer claims a written seed goes unread"
  fi
done

# The Windows half ships margince.yaml as well — its lane runs Setup.cmd to seed
# and zips the result — so it needs the same predicate. Grep, because 5.1 is not
# reachable from here.
for want in Say-BindInApp; do
  if grep -q "$want" "$KIT/setup.ps1"; then
    ok "setup.ps1 carries $want"
  else
    fail "setup.ps1 has no $want, so a seeded Windows folder still claims a
      binding it cannot apply. That lane ships margince.yaml too."
  fi
done

# ── argument mode is not expression mode ─────────────────────────────────────
#
# `Cmd $a @(...) + (Get-Thing)` parses as FOUR arguments, because a command's
# arguments are read in argument mode where `+` is a bare word rather than an
# operator. A function declaring two parameters and carrying no CmdletBinding
# takes the extras into $args and drops them, so the concatenation vanishes with
# no error and no output.
#
# This shipped once: Write-ConfigYaml wrote margince.yaml WITHOUT the model
# binding while still printing that it had written one. It is invisible from a
# macOS checkout — the parser accepts it, so CI's ParseFile gate passes, and
# every string a grep would look for is present in the file. Only running it on
# Windows, or reading the parse mode, tells you.
#
# So the shape is banned outright. Concatenate into a variable first and pass one
# parenthesized expression.
for f in "$KIT"/*.ps1; do
  name="$(basename "$f")"
  if grep -nE '^[[:space:]]*\)[[:space:]]*\+' "$f" >/dev/null; then
    fail "$name closes an array literal and then concatenates it in ARGUMENT position:
$(grep -nE '^[[:space:]]*\)[[:space:]]*\+' "$f" | sed 's/^/      /')
      PowerShell reads that \`+\` as a bare word, so the call gets extra arguments
      that a non-CmdletBinding function silently drops into \$args. Build the array
      into a variable and pass one parenthesized expression instead."
  else
    ok "$name concatenates arrays outside argument position"
  fi
done

# The binding travels with the key, on BOTH halves. setup.ps1 cannot be run from
# a macOS checkout — CI's Windows parser is the only thing that reads it here —
# so this is a grep, and it is the only guard the Windows half has against
# shipping the exact bug the macOS tests above prove is gone: a folder that
# stores a provider key and binds nothing to it. Each string below is load-
# bearing on both platforms.
for want in ai_routing cloud_frontier gemini-3.1-flash-lite gemini-embedding-001 openrouter.ai/api; do
  for f in "$KIT/setup.command" "$KIT/setup.ps1"; do
    name="$(basename "$f")"
    if grep -q "$want" "$f"; then
      ok "$name binds the provider it keys — carries $want"
    else
      fail "$name no longer mentions $want, so its half of the model binding has
      drifted. A folder from this platform would store a provider key and bind
      nothing to it: every AI surface answers from the offline fake, which is
      indistinguishable from a key the vendor rejected."
    fi
  done
done

for want in OPENAI_COMPATIBLE_API_KEY GEMINI_API_KEY; do
  for f in "$KIT/setup.command" "$KIT/setup.ps1"; do
    name="$(basename "$f")"
    if grep -q "$want" "$f"; then
      ok "$name offers $want"
    else
      fail "$name no longer mentions $want — the two halves of the setup pair have
      drifted, and only one platform can reach that provider."
    fi
  done
done

# ── every region in the folder README has a rule in the writer ───────────────
#
# The template and write_kit_readme's substitution list are two places. A region
# added to one and not the other is invisible here: desktop.sh's own guard fires
# only at BUILD time, on a machine running a release lane, and the reader who
# learns about it is whoever downloaded the folder. This is the same check, one
# step earlier and without needing a built bundle.
#
# Both halves are required. Without a DROP rule a section reaches the platform it
# was never meant for — a Windows reader told that opening Setup settles the rest
# of the folder, which on Windows it does not. Without a STRIP rule the marker
# itself survives into the shipped README.
README_TPL="$KIT/README.md"
DESKTOP_SH="$HERE/desktop.sh"
for marker in $(grep -oE '<!--[A-Z][A-Z0-9]*-->' "$README_TPL" | tr -d '<!->' | sort -u); do
  # Fixed strings, not patterns: the rules being matched are themselves sed
  # scripts full of / and \\, and a gate that has to escape its own subject is a
  # gate that fails on the escaping rather than the thing.
  if ! grep -qF -- "<!--$marker-->/,/" "$DESKTOP_SH"; then
    fail "the folder README has a <!--$marker--> region and write_kit_readme has no
      rule dropping it. Every region is there to be withheld from some folder;
      one with no rule ships to every platform unconditionally."
  elif ! grep -qF -- "*$marker-->/d" "$DESKTOP_SH"; then
    fail "write_kit_readme drops the <!--$marker--> region but never strips its
      markers, so they survive verbatim into a shipped README."
  else
    ok "write_kit_readme handles the <!--$marker--> region"
  fi
done

# ── the seeder follows the dataset, and the loader follows the seeder ────────
#
# Upstream #4732 moved the loader out of core — "it only ever read that
# dataset, so it belonged beside the data rather than beside the product" — and
# the first build after that bump died with `stat core/backend/tools/seed-demo:
# directory not found`, taking a release with it.
#
# Two claims. The source is resolved from the DATASET checkout, not core; and a
# build that cannot reach one ships no loader rather than failing, because the
# release runner checks the dataset out AFTER the build and every seeded bundle
# ships loaderless anyway. What must never ship is a loader with no seeder: a
# double-click that fails on the machine of somebody who cannot fix it.
if grep -qE 'CORE/backend.*tools/seed-demo|\$CORE.*seed-demo' "$DESKTOP_SH"; then
  fail "desktop.sh still builds the seeder out of core. Upstream removed
      backend/tools/seed-demo (#4732); it lives in the demo-dataset repository
      now, as a self-contained module."
else
  ok "the seeder is not built from core"
fi
if grep -q 'dataset_seeder_src' "$DESKTOP_SH"; then
  ok "the seeder source is resolved from the dataset checkout"
else
  fail "desktop.sh names no dataset source for the seeder."
fi
# The loader copy must be GATED on the build, not merely sequenced after it.
if grep -qE 'build_seeder (darwin|windows) "\$dir/runtime/seed-demo(\.exe)?"; then' "$DESKTOP_SH"; then
  ok "the loader ships only when its seeder built"
else
  fail "the loader is copied without checking that build_seeder succeeded, so a
      folder can ship a double-click with nothing behind it."
fi

# ── the seeder builds where CI puts the dataset ──────────────────────────────
#
# Run, not grepped, and the fixture sits INSIDE this repository on purpose:
# that is where the release lanes check the dataset out (.dataset), and it is
# the difference between the two outcomes. A module beside the repo builds
# fine; one inside it makes `go build` walk up, find our go.work and refuse —
#
#   current directory is contained in a module that is not one of the
#   workspace modules listed in go.work
#
# — which is exactly how this passed locally and failed on the runner twice.
# The seeder is self-contained, so it must build with no workspace at all.
seeder_selftest() {
  local ds="$ROOT_DIR/.dataset-kit-selftest" dir out
  rm -rf "$ds"; mkdir -p "$ds/tools/seed-demo"
  # A FAITHFUL fixture, which is the only kind that has caught anything here.
  # The real seeder's module is rooted at the product's path so Go's
  # import-path `internal` rule lets it reach backend/internal/..., and it
  # carries a replace at ../../../margince-poc-v1/backend — a core checkout of
  # that name beside the dataset, which no checkout here has. A fixture without
  # the replace proves nothing: that path is exactly what broke the release.
  #
  # The `go` directive matches core's too. Declared lower, Go selects an older
  # toolchain and the build dies on core's own requirement instead of on
  # anything this test is about.
  {
    printf 'module github.com/margince/margince/backend/tools/seed-demo\n\n'
    printf 'go %s\n\n' "$(sed -n 's/^go //p' "$ROOT_DIR/core/backend/go.mod" | head -1)"
    printf 'require github.com/margince/margince/backend v0.0.0\n\n'
    printf 'replace github.com/margince/margince/backend => ../../../margince-poc-v1/backend\n'
  } >"$ds/tools/seed-demo/go.mod"
  printf 'package main\n\nimport _ "github.com/margince/margince/backend/pkg/extension"\n\nfunc main() {}\n' \
    >"$ds/tools/seed-demo/main.go"
  dir="$(mktemp -d)"; mkdir -p "$dir/f/runtime" "$dir/f/data"; : >"$dir/f/margince"
  # The WINDOWS arm, deliberately, so this runs everywhere the suite does. It
  # exercises the same resolution, the same GOWORK=off build and the same gate;
  # what it skips is codesign, which exists only on macOS. Asking for darwin
  # here made the gate refuse on the Linux runner — correctly, since an
  # unsigned seeder is useless in a downloaded macOS folder — and the test read
  # that as a product fault.
  out="$(DATASET="$ds" bash "$HERE/desktop.sh" kit --dir "$dir/f" --os windows --version v0-selftest 2>&1)"
  local built=no loader=no
  [ -s "$dir/f/runtime/seed-demo.exe" ] && built=yes
  [ -e "$dir/f/Load Demo Data.cmd" ] && loader=yes
  rm -rf "$ds" "$dir"
  if [ "$built" != yes ]; then
    fail "the seeder did not build from a dataset inside this repository:
$(printf '%s' "$out" | sed 's/^/      /' | tail -6)
      Two things it needs: GOWORK=off, because a workspace it is not a member
      of refuses it; and its replace repointed at this checkout's core, because
      the one it ships expects a sibling directory no checkout here has."
  elif [ "$loader" != yes ]; then
    fail "the seeder built and the loader did not ship, so the folder would
      carry neither. The loader copy is gated on the build; check the gate."
  else
    ok "the seeder builds from a dataset inside this repository, and the loader ships"
  fi
}
ROOT_DIR="$(cd "$HERE/.." && pwd)"
seeder_selftest

# ── a stamped README describes the folder it is IN ───────────────────────────
#
# write_kit_readme's own comment states the rule: "the reader of a stamped
# README must never meet instructions for the state their folder is not in."
# The mechanism was right and the markup was not — the whole "If something goes
# wrong" section sat OUTSIDE any region, so a seeded folder shipped five entries
# telling its reader to run a loader it does not contain and to preserve a
# `data/demo/` that is not there. One of them advised deleting `data/`, which in
# a seeded folder throws away the demo database that came with the download and
# which nothing in the folder can rebuild.
#
# The region test above cannot catch that: it checks each marker has a drop rule
# and that markers are stripped, which was true the whole time. What was missing
# is an assertion about the STAMPED TEXT, so that is what this makes.
readme_stamp() {  # readme_stamp <seeded: yes|no>  → path to a stamped README
  local seeded="$1" dir
  dir="$(mktemp -d)"
  # bash, not the caller's shell: desktop.sh reads BASH_SOURCE to find ROOT.
  bash -c '
    set -euo pipefail
    cd "$1"; source scripts/desktop.sh
    write_kit_readme "$2" "Start Margince.command" "Load Demo Data.command" "/" \
      "v0.0.0-test" "Setup.command" "$3" "Connect to Claude.command" darwin
  ' _ "$(dirname "$HERE")" "$dir" "$seeded" >/dev/null 2>&1 || true
  printf '%s\n' "$dir/README.md"
}

seeded_readme="$(readme_stamp yes)"
if [ ! -s "$seeded_readme" ]; then
  ok "stamped-README check skipped (write_kit_readme is not sourceable standalone)"
else
  bad=""
  # The loader's own filename, and the directory that only an unseeded folder has.
  grep -qF 'Load Demo Data.command' "$seeded_readme" && bad="$bad the loader's filename;"
  grep -qF 'data/demo' "$seeded_readme"               && bad="$bad data/demo;"
  # "run the loader" in any casing — the entries that survived said exactly this.
  grep -qiE 'run the loader|the loader (stops|cannot)' "$seeded_readme" && bad="$bad instructions to run the loader;"
  if [ -n "$bad" ]; then
    fail "the SEEDED README still mentions:$bad
      A folder that arrives with the demo in it has no loader and no
      data/demo. Wrap the passage in <!--LOADER--> so it is dropped, and give
      the seeded reader the entry that applies to them instead."
  fi
  ok "the seeded README mentions no loader and no data/demo"

  # And the inverse, or the fix would be "delete the section".
  loader_readme="$(readme_stamp no)"
  if grep -qF 'Load Demo Data.command' "$loader_readme"; then
    ok "the unseeded README still names the loader"
  else
    fail "the unseeded README no longer names its loader — the loader-shaped
      troubleshooting was removed outright rather than made conditional."
  fi
  # The destructive advice must not reach a folder whose data/ is the download.
  if grep -qiE 'Do not delete .data' "$seeded_readme"; then
    ok "the seeded README warns against deleting data/"
  else
    fail "the seeded README does not warn against deleting data/. The demo
      database lives there and came with the download; nothing in the folder
      can rebuild it."
  fi
  rm -rf "$(dirname "$loader_readme")"
fi
rm -rf "$(dirname "$seeded_readme")"

# ── the connect script prepares a folder the api can actually boot from ──────
#
# Three writes have to land together or the installation is worse off than
# before: mcp.connector_enabled in margince.yaml, MARGINCE_PUBLIC_BASE_URL in
# margince.env, and the address in both agreeing with the tunnel that is up. The
# api REFUSES TO BOOT with the gate on and the URL unset (backend/cmd/api/boot.go),
# so a script that got two of the three would leave a folder that no longer
# starts at all — which is why this runs the real script end to end rather than
# grepping it.
#
# BOTH providers, because they publish their address in different places and a
# change to one has no way of failing the other: ngrok answers on a local API,
# cloudflared prints the address once into its own log. Each is stubbed in the
# shape the real thing has.
connect_fixture() {
  local dir="$1"
  mkdir -p "$dir/runtime" "$dir/data/logs"
  cat >"$dir/margince.env" <<'ENV'
# Margince settings.
# MARGINCE_PORT=8800
MARGINCE_PUBLIC_BASE_URL=http://127.0.0.1:8800
ENV
  cat >"$dir/margince.yaml" <<'YAML'
version: 1

workspace:
  name: Margince
YAML
  # A stub that IS the server, so the pid the script kills is the pid holding
  # the port. A wrapper shell would leave the server behind on cleanup.
  cat >"$dir/runtime/ngrok" <<'NGROK'
#!/usr/bin/env bash
exec python3 -c '
import http.server, json
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps({"tunnels": [
            {"public_url": "http://stub.ngrok.test", "proto": "http"},
            {"public_url": "https://stub.ngrok.test", "proto": "https"}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", 4040), H).serve_forever()
'
NGROK
  chmod +x "$dir/runtime/ngrok"
  # cloudflared prints its address once and then serves. The sleep is what makes
  # it a running tunnel rather than an exited command, which is the difference
  # the script's liveness check reads.
  cat >"$dir/runtime/cloudflared" <<'CFD'
#!/usr/bin/env bash
echo "INF |  https://stub-quick.trycloudflare.com  |"
sleep 300
CFD
  chmod +x "$dir/runtime/cloudflared"
  printf '#!/bin/sh\nexit 0\n' >"$dir/margince"
  chmod +x "$dir/margince"
  cp "$KIT/connect-claude.command" "$dir/Connect to Claude.command"
  chmod +x "$dir/Connect to Claude.command"
}

# No NGROK_* in the environment: setting one would make resolve_provider INFER
# ngrok, and the default path would then never be exercised by anything here.
run_connect() {
  local dir="$1"; shift
  ( cd "$dir" && MARGINCE_KIT_INTERACTIVE=0 \
      bash "./Connect to Claude.command" --check "$@" 2>&1 )
}

if ! command -v python3 >/dev/null 2>&1; then
  ok "connect-claude.command: skipped (no python3 to stub a tunnel with)"
else
  CONNECT_DIR="$(mktemp -d)"
  # shellcheck disable=SC2064 -- the path is expanded now, on purpose
  trap "rm -rf '$CONNECT_DIR'" EXIT
  connect_fixture "$CONNECT_DIR"

  # ── the default provider, which is the one that needs no account ──
  if out="$(run_connect "$CONNECT_DIR")"; then
    if grep -q 'connector_enabled:[[:space:]]*true' "$CONNECT_DIR/margince.yaml"; then
      ok "connect-claude.command turns the MCP connector on in margince.yaml"
    else
      fail "connect-claude.command left margince.yaml without mcp.connector_enabled:
      the api mounts no /mcp at all without it."
    fi

    got="$(sed -n 's/^MARGINCE_PUBLIC_BASE_URL=//p' "$CONNECT_DIR/margince.env" | tail -n1)"
    if [ "$got" = "https://stub-quick.trycloudflare.com" ]; then
      ok "connect-claude.command defaults to cloudflared and writes its address"
    else
      fail "with nothing configured, connect-claude.command wrote
      MARGINCE_PUBLIC_BASE_URL=$got, wanted the cloudflared quick-tunnel address.
      cloudflared is the default BECAUSE ngrok v3 opens no anonymous tunnel;
      defaulting to ngrok puts a signup in front of the feature."
    fi

    if printf '%s' "$out" | grep -q 'https://stub-quick.trycloudflare.com/mcp'; then
      ok "connect-claude.command prints the MCP endpoint to paste into Claude"
    else
      fail "connect-claude.command never printed the /mcp address, which is the
      one thing its reader has to copy."
    fi

    # Twice, because the folder is the user's and this runs on every start.
    if out2="$(run_connect "$CONNECT_DIR")"; then
      blocks="$(grep -c '^[[:space:]]*mcp:' "$CONNECT_DIR/margince.yaml" || true)"
      if [ "$blocks" = "1" ]; then
        ok "connect-claude.command is idempotent — margince.yaml keeps one mcp: block"
      else
        fail "connect-claude.command appended a second mcp: block on the second run
      ($blocks found). deployconfig parses strictly and a duplicate key is a
      boot error, so the second start would fail."
      fi
    else
      fail "connect-claude.command failed on a folder it had already prepared:
$out2"
    fi
  else
    fail "connect-claude.command failed against a stubbed cloudflared:
$out"
  fi

  # ── ngrok, chosen explicitly, read back from its local API ──
  if nc -z 127.0.0.1 4040 >/dev/null 2>&1; then
    ok "connect-claude.command ngrok path: skipped (something already holds port 4040)"
  else
    NG_DIR="$(mktemp -d)"
    connect_fixture "$NG_DIR"
    if out3="$(cd "$NG_DIR" && MARGINCE_KIT_INTERACTIVE=0 MARGINCE_TUNNEL=ngrok \
        NGROK_AUTHTOKEN=stub-token bash "./Connect to Claude.command" --check 2>&1)"; then
      got="$(sed -n 's/^MARGINCE_PUBLIC_BASE_URL=//p' "$NG_DIR/margince.env" | tail -n1)"
      if [ "$got" = "https://stub.ngrok.test" ]; then
        ok "connect-claude.command MARGINCE_TUNNEL=ngrok reads the https address off the local API"
      else
        fail "the ngrok path wrote MARGINCE_PUBLIC_BASE_URL=$got, wanted the https
      address. The http twin ngrok publishes alongside it must not win — an
      OAuth redirect that downgrades is one the agent's client refuses."
      fi
    else
      fail "connect-claude.command failed against a stubbed ngrok:
$out3"
    fi
    rm -rf "$NG_DIR"
  fi

  # A folder whose owner turned the connector OFF must not have it turned back
  # on behind them. The script refuses instead.
  OFF_DIR="$(mktemp -d)"
  connect_fixture "$OFF_DIR"
  printf '\nmcp:\n  connector_enabled: false\n' >>"$OFF_DIR/margince.yaml"
  if run_connect "$OFF_DIR" >/dev/null 2>&1; then
    fail "connect-claude.command overrode an mcp: section that disables the
      connector. Turning it off is a decision someone made."
  else
    ok "connect-claude.command refuses a folder whose mcp: section disables the connector"
  fi
  rm -rf "$OFF_DIR"
fi

# ── and the Windows half of the connect pair must not drift from it ─────────
#
# The macOS half is exercised end to end above; the Windows half runs on an
# engine no lane here has. What a grep CAN hold is that both halves still do the
# three things that have to happen together — the gate, the tunnel address, and
# the https preference that keeps the advertised MCP resource off http.
for want in 'connector_enabled' 'MARGINCE_PUBLIC_BASE_URL' '4040/api/tunnels' 'trycloudflare' 'https'; do
  for f in "$KIT/connect-claude.command" "$KIT/connect-claude.ps1"; do
    name="$(basename "$f")"
    if grep -q "$want" "$f"; then
      ok "$name still handles $want"
    else
      fail "$name no longer mentions $want — the two halves of the connect pair
      have drifted, and only one platform gets a working connector."
    fi
  done
done

if [ "$FAILURES" -gt 0 ]; then
  printf '\n%d check(s) failed\n' "$FAILURES" >&2
  exit 1
fi
printf '\ndesktop-kit: all checks passed\n'
