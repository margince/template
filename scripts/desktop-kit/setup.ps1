# setup.ps1 — prepare THIS installation before its first start (Windows).
#
# The Windows half of "Setup.command". Same contract: it lives inside the
# installation it configures and reads every fact from a file beside it, so it
# needs no repository, no toolchain and no make. "Setup.cmd" at the folder root
# is the double-clickable wrapper around this file.
#
# It writes the two files the launcher would otherwise create for itself, and it
# writes them BEFORE the first start because both are write-once and the
# workspace is bootstrapped from one of them. Every decision here is one that
# cannot be revisited without deleting data\.
#
# One thing differs from macOS, and it is not a choice. margince.yaml wants an
# IANA timezone name; Windows names its zones differently and the mapping lives
# in CLDR data the stdlib does not carry (the launcher says the same, in
# desktop\launcher\platform_windows.go). deployconfig validates `timezone` only
# when it is present, so this omits it rather than writing a name the api would
# refuse. An operator who wants one adds it before the first start.
#
# This file is stored WITH a UTF-8 byte-order mark, deliberately. Windows
# PowerShell 5.1 — which "Setup.cmd" invokes, because it is the one every
# Windows box has — reads a .ps1 as ANSI unless a BOM says otherwise, and every
# em-dash in the messages below would reach the user as mojibake. Keep the BOM
# if you edit this file.
#
# That is true of THIS file and of nothing this file writes. A mark in
# margince.env stops the launcher starting, which is why every write below goes
# through Write-Utf8NoBom — see the comment on it.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = $PSScriptRoot
if (-not $Root) { $Root = Split-Path -Parent $MyInvocation.MyCommand.Path }
# The kit ships this file in runtime\, so the installation root is its parent.
$Root = Split-Path -Parent $Root

# Double-clicked, the console window closes the moment this returns, taking
# every line of output with it. The pause is the only thing that lets a user
# READ a failure. desktop.sh sets this to 0, because a lane is not a window
# anyone is looking at and must never block on a prompt.
$Interactive = $true
if ($env:MARGINCE_KIT_INTERACTIVE -eq '0') { $Interactive = $false }

$Prompt = $Interactive
if ($args -contains '--no-prompt') { $Prompt = $false }

# The demo dataset is euro-based: the seeder loads an fx rate for every non-EUR
# currency it meets, and the api refuses a rate whose currency IS the base one.
# A USD installation fails the seed after most of the dataset is written, and the
# currency cannot be changed once the workspace exists.
$Currency = if ($env:CURRENCY) { $env:CURRENCY } else { 'EUR' }

# The demo dataset calls the admin this. The seeder replaces that account's
# password and never renames one, so an installation bootstrapped under any
# other address leaves the dataset describing someone who is not here.
$AdminEmail = if ($env:ADMIN_EMAIL) { $env:ADMIN_EMAIL } else { 'admin@demo.test' }

$EnvPath = Join-Path $Root 'margince.env'
$YamlPath = Join-Path $Root 'margince.yaml'

function Say([string]$Message) { Write-Host $Message }

function Finish([int]$Code) {
  if ($Interactive) {
    Write-Host ''
    Read-Host 'Press Return to close this window' | Out-Null
  }
  exit $Code
}

# Only an UNcommented assignment counts. The generated margince.env documents
# every setting as a comment, so a naive match reports a default as configured.
function Get-EnvValue([string]$Key) {
  if (-not (Test-Path $EnvPath)) { return '' }
  # -Encoding UTF8 for the reason Write-Utf8NoBom's comment gives in reverse:
  # 5.1 decodes a file with NO byte-order mark as the system's ANSI codepage.
  $hit = Select-String -Encoding UTF8 -Path $EnvPath -Pattern ("^\s*" + [regex]::Escape($Key) + "\s*=\s*(.*)$") |
    Select-Object -Last 1
  if ($hit) { return $hit.Matches[0].Groups[1].Value.Trim() }
  return ''
}

# EVERY write in this file goes through this, and the reason is a Windows
# PowerShell 5.1 trap that cost a release. `Set-Content -Encoding UTF8` on 5.1
# writes a UTF-8 BYTE-ORDER MARK; PowerShell 7's UTF8 is BOM-less, so nothing
# reproduces it except the engine "Setup.cmd" actually invokes — and it invokes
# 5.1 deliberately, because it is the one every Windows box has.
#
# The launcher's margince.env parser then reads line 1 as
# "\ufeff# Margince settings.": the mark defeats the leading-"#" test, the line
# is taken for a setting, and the app refuses to start with "expected
# KEY=value". A mark on a line that IS an assignment is worse — it parses, and
# the child process is handed a variable nothing will ever read.
#
# .NET's UTF8Encoding($false) is BOM-less on both engines. WriteAllLines
# resolves a RELATIVE path against .NET's working directory rather than
# PowerShell's, so every caller here passes a path built from $Root.
#
# Dropping the mark obliges every READ here to name its encoding, which is the
# same 5.1 default wearing the other face: with no mark to detect, Get-Content
# and Select-String decode as the system's ANSI codepage. The template this
# script edits carries em-dashes, so an unqualified read would turn each into
# three characters and the rewrite would make that permanent — a file the
# launcher accepts and a human can no longer read. Hence -Encoding UTF8 on
# every read of margince.env below.
function Write-Utf8NoBom([string]$Path, [string[]]$Lines) {
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllLines($Path, $Lines, $utf8NoBom)
}

# Repairs a folder an EARLIER version of this script corrupted. Releases up to
# v0.0.1-rc.1 wrote margince.env back through Set-Content, and a user who has
# already run Setup once holds a file the launcher will not read.
#
# Re-running Setup could not fix it on its own: Set-EnvKey keeps an existing
# uncommented value, so it rewrites nothing, and Initialize-EnvFile leaves a
# file that exists alone. Both are right — the settings were never wrong, only
# the three bytes in front of them.
#
# Idempotent, and it costs a healthy folder one read. margince.yaml is written
# the same way and is NOT repaired here: yaml.v3 strips a leading mark per the
# YAML spec, and the launcher's own reader meets it on a comment line.
function Repair-EnvEncoding {
  if (-not (Test-Path $EnvPath)) { return }
  $bytes = [System.IO.File]::ReadAllBytes($EnvPath)
  if ($bytes.Length -lt 3) { return }
  if ($bytes[0] -ne 0xEF -or $bytes[1] -ne 0xBB -or $bytes[2] -ne 0xBF) { return }
  # Get-Content strips the mark on read, so writing the lines back drops it.
  Write-Utf8NoBom $EnvPath @(Get-Content -Encoding UTF8 -LiteralPath $EnvPath)
  Say 'repaired margince.env - a byte-order mark from an earlier setup is removed,'
  Say '                        which is what stopped Margince starting.'
}

# Sets KEY whether the template carried it commented out or not there at all. An
# existing UNcommented value is KEPT: this runs on a folder a person may already
# have edited, and the keys it manages are ones a second value would silently
# invalidate — a rotated vault key cannot open what the first one sealed.
function Set-EnvKey([string]$Key, [string]$Value) {
  if (Get-EnvValue $Key) { return $false }
  $line = "$Key=$Value"
  if (Test-Path $EnvPath) {
    $lines = @(Get-Content -Encoding UTF8 -LiteralPath $EnvPath)
    $pattern = "^\s*#\s*" + [regex]::Escape($Key) + "="
    $index = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
      if ($lines[$i] -match $pattern) { $index = $i; break }
    }
    if ($index -ge 0) {
      $lines[$index] = $line
    } else {
      $lines = $lines + $line
    }
    Write-Utf8NoBom $EnvPath $lines
  } else {
    Write-Utf8NoBom $EnvPath @($line)
  }
  return $true
}

function Get-AppPort {
  $value = Get-EnvValue 'MARGINCE_PORT'
  if ($value -match '^\d+$') { return $value }
  return '8800'
}

# The launcher writes margince.env from its own annotated template on the first
# start, which is TOO LATE for the keyvault key: the api reads it at boot, so an
# installation that has started once without it has already answered 500 to every
# extension that stores a credential. The kit stamps the template into the folder
# at build time so this can fill it in beforehand.
function Initialize-EnvFile {
  if (Test-Path $EnvPath) { return }
  Say 'note - margince.env is missing, so a minimal one is written instead of the'
  Say '       launcher template. Every setting it documents is still available.'
  Write-Utf8NoBom $EnvPath @(
    '# Margince settings. Written by Setup.cmd before the first start.',
    '# Restart Margince after changing anything here.'
  )
}

# The one sentence both "cannot consume a seed" cases need, so the two do not
# drift into saying different things about the same state.
# See setup.command's say_bind_in_app for why this no longer names Settings ->
# AI as the fix: that screen cannot create a FIRST binding, so the old wording
# sent the reader to the one place that looks like the answer and is not.
# Upstream margince/margince#4853.
function Say-BindInApp([string]$Why1, [string]$Why2) {
  Say ''
  Say "  NOTE - $Why1"
  Say "  $Why2"
  Say '  Your key is stored and sealed. Bind the tiers in the app under'
  Say '  Settings -> AI, which opens on this provider''s defaults - until then'
  Say '  the AI surfaces answer from the offline fake.'
}

# The tier->model binding a fresh installation is CREATED with. The macOS half
# carries the same function and the same comment; see setup.command's
# routing_seed for why this exists at all.
#
# Short version: a provider key is half the configuration. Nothing routes to a
# vendor until a TIER is bound to it, and until then every AI surface answers
# from the offline fake in canned text - so a folder given a good key looked
# exactly like one whose key had been rejected. seeds.ai_routing is consumed
# once, at workspace creation, so it has to be here before the first start.
#
# Models mirror the app's own onboarding presets, which mirror the server's
# price sheet: an id outside it reports UNPRICED on every call.
function Get-RoutingSeed {
  $provider = ''; $model = ''; $embed = ''; $baseUrl = ''
  if (Get-EnvValue 'GEMINI_API_KEY') {
    $provider = 'gemini'
    $model = 'gemini-3.1-flash-lite'
    $embed = 'gemini-embedding-001'
  } elseif (Get-EnvValue 'OPENAI_COMPATIBLE_API_KEY') {
    # OpenRouter rides the openai_compatible adapter, which fails closed
    # without a base_url, so the binding carries one.
    $provider = 'openai_compatible'
    $model = 'mistralai/mistral-small-3.2-24b-instruct'
    $embed = 'openai/text-embedding-3-small'
    $baseUrl = 'https://openrouter.ai/api'
  } else {
    return @()
  }

  $urlField = ''
  if ($baseUrl) { $urlField = ", base_url: $baseUrl" }

  $lines = @(
    '',
    'seeds:',
    '  # Consumed once, when the workspace is created on the first start.',
    '  # Re-point any lane afterwards in Settings -> AI; this file is not read again.',
    '  ai_routing:',
    '    profile: cloud_frontier',
    '    tiers:'
  )
  foreach ($tier in @('local_small', 'local_large', 'cheap_cloud', 'premium', 'frontier')) {
    $lines += "      ${tier}: {provider: $provider, model: $model$urlField}"
  }
  $lines += "    embeddings: {provider: $provider, model: $embed$urlField}"
  return $lines
}

function Write-ConfigYaml {
  if (Test-Path $YamlPath) {
    Say 'margince.yaml is already here - kept, including its currency and admin address.'
    # An existing file is yours and its seeds were consumed on the first start,
    # so a key set on THIS run has no binding to arrive with. Saying nothing
    # would repeat the failure the seed exists to end.
    if (@(Get-RoutingSeed).Count -gt 0 -and
        -not (Select-String -Path $YamlPath -Pattern '^\s*ai_routing:' -Quiet -Encoding UTF8)) {
      Say-BindInApp 'margince.yaml is already here, so the binding cannot be added to' `
                    'it - its seed is read once, when the workspace is created.'
    }
    return
  }
  # Built into a variable and concatenated INSIDE the parentheses, which is not
  # a style choice. `Write-Utf8NoBom $YamlPath @(...) + (Get-RoutingSeed)` parses
  # in ARGUMENT mode: the `+` is a bare word, not an operator, so the call
  # receives four arguments. The function declares two and carries no
  # CmdletBinding, so the third and fourth land in $args and are discarded —
  # the file would be written without the binding while the line below still
  # said it had been. Silent on Windows, and unreachable from a macOS checkout.
  $configLines = @(
    '# Margince deployment configuration (A107/ADR-0061).',
    '# Created by Setup.cmd and never overwritten - your edits survive a restart.',
    '# Restart Margince after changing anything here.',
    '#',
    "# base_currency is $Currency because the demo dataset is euro-based and the api",
    '# refuses an fx rate for the base currency itself, so a USD installation cannot',
    '# complete a demo load. The workspace is created from this file once, on the',
    '# first start, so this cannot be changed afterwards.',
    '#',
    '# timezone is deliberately absent: Windows does not name zones the way this',
    '# file wants and the api validates the field only when it is set. Add an IANA',
    '# name here before the first start if you want one.',
    'version: 1',
    '',
    'workspace:',
    '  name: Margince',
    "  base_currency: $Currency",
    '',
    'bootstrap_admin:',
    "  email: $AdminEmail",
    '  display_name: Owner',
    '  password_file: data/admin-password'
  )
  # @(...) around the call so an empty return is an empty ARRAY rather than
  # $null: .Count on the latter is a version-dependent answer, and this file
  # has to behave the same on 5.1 and 7.
  $routingSeed = @(Get-RoutingSeed)
  Write-Utf8NoBom $YamlPath ($configLines + $routingSeed)
  Say "wrote margince.yaml - $Currency, admin $AdminEmail"
  if ($routingSeed.Count -gt 0) {
    Say '  and the model binding, so the AI surfaces answer on your key rather than the fake'
  }
}

# Three keys that are this installation's alone. Neither may ship in a
# downloaded folder: one key shared by every installation would seal every
# recipient's credentials, and sign every recipient's webhooks, under a value
# anyone with the download already has.
#
# The lengths are contracts, not preferences. The keyvault and webhook keys are
# decoded as base64 and must be EXACTLY 32 bytes for AES-256; the state key is
# an HMAC key the api floors at 32 characters and refuses below it.
function New-RandomBytes([int]$Count) {
  $bytes = New-Object 'System.Byte[]' $Count
  [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
  return $bytes
}

function New-InstallationKeys {
  $vault = [Convert]::ToBase64String((New-RandomBytes 32))
  if (Set-EnvKey 'MARGINCE_KEYVAULT_ROOT_KEY' $vault) {
    Say 'generated MARGINCE_KEYVAULT_ROOT_KEY - extension credentials are sealed with it'
  }
  $state = -join ((New-RandomBytes 32) | ForEach-Object { $_.ToString('x2') })
  if (Set-EnvKey 'MARGINCE_CONNECTOR_STATE_KEY' $state) {
    Say 'generated MARGINCE_CONNECTOR_STATE_KEY - the Gmail and Calendar consent flows sign with it'
  }
  $webhook = [Convert]::ToBase64String((New-RandomBytes 32))
  if (Set-EnvKey 'MARGINCE_WEBHOOK_KEY' $webhook) {
    Say 'generated MARGINCE_WEBHOOK_KEY - webhook subscription signing secrets are sealed with it'
  }
  if (Set-EnvKey 'MARGINCE_PUBLIC_BASE_URL' ("http://127.0.0.1:" + (Get-AppPort))) {
    Say 'set MARGINCE_PUBLIC_BASE_URL - the address Google redirects back to'
  }
}

# Asked for rather than shipped. These belong to whoever operates the
# installation: one Google app and one model provider key, the same on every
# machine, and none of it may sit in a folder anyone can download.
function Request-Credential([string]$Key, [string]$Label, [string]$Hint) {
  if (Get-EnvValue $Key) { Say "$Label is already set - kept."; return }
  if (-not $Prompt) { return }
  Write-Host ''
  Write-Host "  $Label"
  Write-Host "  $Hint"
  $value = Read-Host '  >'
  if (-not $value) { Say '  skipped.'; return }
  Set-EnvKey $Key $value | Out-Null
  Say '  set.'
}

# The model provider is ONE CHOICE, not two prompts. The app's own onboarding
# offers exactly these two and no more - frontend/src/screens/setup-providers.ts,
# whose comment gives the reason: they are the two vendors that serve chat AND
# embeddings from a single key, and a routing document requires an embeddings
# binding. A third choice here would walk a first-time admin into a form they
# cannot complete.
#
# Only the KEY is written, whichever is picked, which is what the single
# OpenRouter prompt this replaced already did. The tier bindings - and
# OpenRouter's base_url, which the openai_compatible adapter fails closed
# without - are set in the app under Settings -> AI.
#
# The macOS half of this pair is ask_provider in setup.command, and
# scripts/desktop-kit.test.sh holds the two to offering the same providers.
function Request-Provider {
  # Either key already set answers the question: a re-run must not ask somebody
  # to re-pick a provider they have already chosen, and Set-EnvKey would keep the
  # existing value anyway. Same contract as Request-Credential, over two
  # variables rather than one.
  if (Get-EnvValue 'OPENAI_COMPATIBLE_API_KEY') { Say 'OpenRouter API key is already set - kept.'; return }
  if (Get-EnvValue 'GEMINI_API_KEY') { Say 'Google Gemini API key is already set - kept.'; return }
  if (-not $Prompt) { return }

  Write-Host ''
  Write-Host '  Model provider - powers the AI surfaces.'
  Write-Host '    1) OpenRouter      https://openrouter.ai/keys'
  Write-Host '    2) Google Gemini   https://aistudio.google.com/apikey'
  Write-Host '  Press Return to skip.'
  $choice = Read-Host '  >'
  # Read-Host returns '' rather than $null on a bare Return, but StrictMode turns
  # a surprise there into a terminating error, so it is normalised either way.
  if (-not $choice) { $choice = '' }
  # ONE read, and anything unrecognized skips rather than asking again: a retry
  # loop is the shape that spins forever in a double-clicked window whose stdin
  # has closed, and the script has already said it can be re-run.
  switch -Regex ($choice.Trim().ToLowerInvariant() -replace '\s', '') {
    '^(1|openrouter)$' {
      Request-Credential 'OPENAI_COMPATIBLE_API_KEY' 'OpenRouter API key' 'begins sk-or-; https://openrouter.ai/keys'
      break
    }
    '^(2|gemini|googlegemini)$' {
      Request-Credential 'GEMINI_API_KEY' 'Google Gemini API key' 'from https://aistudio.google.com/apikey'
      break
    }
    '^$' { Say '  skipped.'; break }
    default { Say '  that is neither 1 nor 2 - skipped. Run this again to choose one.' }
  }
}

Say "Preparing $Root"
Say ''
Initialize-EnvFile
Repair-EnvEncoding
New-InstallationKeys

if ($Prompt) {
  Say ''
  Say 'Shared credentials. Leave one blank to skip it - you can run this again,'
  Say 'or set it in margince.env, any time before you need the surface it serves.'
  Request-Provider
  Request-Credential 'MARGINCE_GMAIL_CLIENT_ID' 'Google OAuth client id' 'ends .apps.googleusercontent.com'
  Request-Credential 'MARGINCE_GMAIL_CLIENT_SECRET' 'Google OAuth client secret' 'begins GOCSPX-'
}

# AFTER the provider prompt, and that is the whole reason this moved: the file
# it writes carries the binding for the vendor that prompt just chose, and
# seeds.ai_routing is read once, at workspace creation.
Say ''
Write-ConfigYaml

Say ''
Say "Ready. Start Margince and sign in as $AdminEmail -"
Say 'the first start prints the password and saves it in data\admin-password.'
Finish 0
