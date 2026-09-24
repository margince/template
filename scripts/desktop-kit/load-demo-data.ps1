# load-demo-data.ps1 — fill THIS installation from the demo dataset (Windows).
#
# The Windows half of "Load Demo Data.command". Same contract: it lives inside
# the installation it seeds and reads every fact from a file beside it, so it
# needs no repository, no Go toolchain and no make. "Load Demo Data.cmd" at the
# folder root is the double-clickable wrapper around this file.
#
# Three things differ from macOS, all of them forced by the platform rather
# than chosen (core/desktop/launcher/postgres_windows.go says why):
#
#   1. There is no unix socket. Postgres listens on loopback TCP, so the DSN
#      needs a port and a password instead of a socket directory.
#   2. That port is EPHEMERAL — the launcher picks a free one on every start
#      and never writes it to a settings file. The one place it is recorded is
#      the cluster's own data\pg\postmaster.pid, whose fourth line is the port.
#      That file exists only while the database is running, which is exactly
#      when this script runs, so reading it is not a workaround.
#   3. The owner password is real (scram-sha-256, not trust) and lives in
#      data\db-margince_owner-password.
# This file is stored WITH a UTF-8 byte-order mark, deliberately. Windows
# PowerShell 5.1 — which "Load Demo Data.cmd" invokes, because it is the one
# every Windows box has — reads a .ps1 as ANSI unless a BOM says otherwise, and
# every em-dash in the messages below would reach the user as mojibake. Keep the
# BOM if you edit this file.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = $PSScriptRoot
if (-not $Root) { $Root = Split-Path -Parent $MyInvocation.MyCommand.Path }
# The kit ships this file in runtime\, so the installation root is its parent.
$Root = Split-Path -Parent $Root

$SeededPassword = 'demo-password-123'

# Double-clicked, the console window closes the moment this returns, taking
# every line of output with it. The pause is the only thing that lets a user
# READ a failure. Set MARGINCE_KIT_INTERACTIVE=0 to skip it in a CI job.
$Interactive = $true
if ($env:MARGINCE_KIT_INTERACTIVE -eq '0') { $Interactive = $false }

function Finish([int]$Code) {
    if ($Interactive) {
        Write-Host ''
        Read-Host 'Press Enter to close this window' | Out-Null
    }
    exit $Code
}

function Fail([string]$Message) {
    Write-Host ''
    Write-Host "error: $Message" -ForegroundColor Red
    Finish 1
}

# ─────────────────────────── reading the installation ─────────────────────
#
# -Encoding UTF8 on both readers below. Windows PowerShell 5.1 decodes a file
# with no byte-order mark as the system's ANSI codepage, and margince.env is
# written without one deliberately (setup.ps1 says why: a mark stops the
# launcher). Nothing here writes either file back, so a wrong decode costs a
# mangled value rather than a corrupted file — but the port and the sign-in
# address are read from them, and a reader should not have to work out which
# fields happen to be ASCII today.

# Only an UNCOMMENTED assignment counts: the generated margince.env documents
# every setting as a comment, so a naive match reports the default as set.
function Get-EnvValue([string]$Key) {
    $file = Join-Path $Root 'margince.env'
    if (-not (Test-Path $file)) { return '' }
    $match = Select-String -Encoding UTF8 -Path $file -Pattern "^\s*$([regex]::Escape($Key))\s*=\s*(.*)$" |
        Select-Object -Last 1
    if ($null -eq $match) { return '' }
    return $match.Matches[0].Groups[1].Value.Trim()
}

function Get-AppPort {
    $value = Get-EnvValue 'MARGINCE_PORT'
    if ($value -match '^\d+$') { return [int]$value }
    return 8800
}

function Get-AppUrl { "http://127.0.0.1:$(Get-AppPort)" }

function Get-YamlScalar([string]$Key, [string]$Default) {
    $file = Join-Path $Root 'margince.yaml'
    if (-not (Test-Path $file)) { return $Default }
    $match = Select-String -Encoding UTF8 -Path $file -Pattern "^\s*$([regex]::Escape($Key)):\s*(\S+)" |
        Select-Object -First 1
    if ($null -eq $match) { return $Default }
    return $match.Matches[0].Groups[1].Value
}

function Get-AppEmail    { Get-YamlScalar 'email' 'owner@margince.local' }
function Get-AppCurrency { Get-YamlScalar 'base_currency' 'USD' }

# The owner DSN over loopback TCP. See the header: the port comes out of the
# running cluster's postmaster.pid because nothing else records it.
function Get-OwnerDsn {
    $pidFile = Join-Path $Root 'data\pg\postmaster.pid'
    if (-not (Test-Path $pidFile)) {
        Fail "the database is not running (no data\pg\postmaster.pid). Start Margince first."
    }
    $lines = @(Get-Content $pidFile)
    if ($lines.Count -lt 4 -or $lines[3] -notmatch '^\d+$') {
        Fail "could not read the database port from $pidFile"
    }
    $port = $lines[3]

    $pwFile = Join-Path $Root 'data\db-margince_owner-password'
    if (-not (Test-Path $pwFile)) {
        Fail "no $pwFile — start Margince once so it creates the database."
    }
    # The launcher generates this with a base64url alphabet — letters, digits,
    # '-' and '_' — so there is nothing in it a URL needs escaped. Escaped
    # anyway: the alphabet is upstream's choice, not this script's to depend on.
    $password = [System.Uri]::EscapeDataString((Get-Content $pwFile -Raw).Trim())
    return "postgres://margince_owner:$password@127.0.0.1:$port/margince?sslmode=disable"
}

# A TCP connect rather than an HTTP request, deliberately: "it answers 404 on /"
# and "it is running" are the same thing, and the two PowerShells disagree about
# how a non-2xx response is thrown — Windows PowerShell 5.1 raises WebException,
# PowerShell 7 raises HttpResponseException — so catching the difference is a
# bug waiting for whichever host the user happens to have. The launcher binds
# this port only once the api is up, and Test-Login is the real API check.
function Test-AppRunning {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $connect = $client.BeginConnect('127.0.0.1', (Get-AppPort), $null, $null)
        if (-not $connect.AsyncWaitHandle.WaitOne(3000, $false)) { return $false }
        $client.EndConnect($connect)
        return $true
    } catch {
        return $false
    } finally {
        $client.Close()
    }
}

function Test-Login([string]$Password) {
    if ([string]::IsNullOrEmpty($Password)) { return $false }
    $body = @{ email = (Get-AppEmail); password = $Password } | ConvertTo-Json -Compress
    try {
        Invoke-RestMethod -Method Post -Uri "$(Get-AppUrl)/v1/auth/login" `
            -ContentType 'application/json' -Body $body -TimeoutSec 10 | Out-Null
        return $true
    } catch {
        return $false
    }
}

# The password that signs in RIGHT NOW, which is why this probes instead of
# reading: after the first seed, data\admin-password is stale. Nothing rewrites
# it — the file is the launcher's record of what it generated, not a live
# credential store — and the seeder must replace the bootstrap credential,
# because the product puts a configured bootstrap on must_change_password and
# refuses every write until it is really replaced.
function Get-AppPassword {
    if ($env:MARGINCE_SEED_PASSWORD) { return $env:MARGINCE_SEED_PASSWORD }

    $file = Join-Path $Root 'data\admin-password'
    $fromFile = ''
    if (Test-Path $file) { $fromFile = (Get-Content $file -Raw).Trim() }

    if (Test-Login $fromFile)        { return $fromFile }
    if (Test-Login $SeededPassword)  { return $SeededPassword }

    Fail ("neither data\admin-password nor the seeded password signs in as " +
          "$(Get-AppEmail). If you changed it, pass it in:`n" +
          "  set MARGINCE_SEED_PASSWORD=... && `"Load Demo Data.cmd`"")
}

# ────────────────────────────────── dataset ───────────────────────────────

# The dataset is NOT shipped: it is a private repository, and a folder anyone
# can download is not where it belongs. So this looks for what the README asks
# the user to copy in — either the checkout's contents in data\demo, or the
# checkout itself dropped inside it under whatever name it arrived with.
function Find-Dataset([string]$Given) {
    if ($Given) {
        if (-not (Test-Path (Join-Path $Given 'datasets\v1\demo.json'))) {
            Fail "no demo dataset at $Given (expected datasets\v1\demo.json inside it)"
        }
        return (Resolve-Path $Given).Path
    }

    $demoData = Join-Path $Root 'data\demo'
    if (Test-Path (Join-Path $demoData 'datasets\v1\demo.json')) { return $demoData }

    if (Test-Path $demoData) {
        foreach ($dir in Get-ChildItem -Path $demoData -Directory -ErrorAction SilentlyContinue) {
            if (Test-Path (Join-Path $dir.FullName 'datasets\v1\demo.json')) { return $dir.FullName }
        }
    }

    Fail ("no demo dataset in $demoData`n`n" +
          "Copy the demo database folder into:`n    $demoData`n`n" +
          "See README.md beside this file.")
}

# ─────────────────────────────────── seed ─────────────────────────────────

$datasetArg = ''
$verify = $false
$passThrough = @()
for ($i = 0; $i -lt $args.Count; $i++) {
    switch ($args[$i]) {
        '--dataset' { $i++; $datasetArg = $args[$i] }
        '--verify'  { $verify = $true }
        default     { $passThrough += $args[$i] }
    }
}

$seeder = Join-Path $Root 'runtime\seed-demo.exe'
if (-not (Test-Path $seeder)) {
    Fail ("this installation has no seeder at runtime\seed-demo.exe.`n" +
          "It was built before the demo loader existed — reinstall from a newer build.")
}

$dataset = Find-Dataset $datasetArg

if (-not (Test-AppRunning)) {
    Fail ("Margince is not running.`n" +
          "Start it first — double-click `"Start Margince.cmd`" — then run this again.")
}

# Said BEFORE the run rather than discovered during it: with a non-EUR base the
# seeder writes companies, people and employments and only then hits the FX
# phase, so the failure arrives after several minutes of apparent success.
if ((Get-AppCurrency) -ne 'EUR') {
    Write-Host "WARNING — this installation's base currency is $(Get-AppCurrency) and the demo dataset is euro-based." -ForegroundColor Yellow
    Write-Host "          The FX step will be refused after most of the dataset is written."
    Write-Host "          margince.yaml is written once and the workspace came from it, so a"
    Write-Host "          euro installation means a fresh one: quit Margince, delete data\ and"
    Write-Host "          margince.yaml, set base_currency: EUR, and start it again."
    Write-Host ''
}

$password = Get-AppPassword
$dsn = Get-OwnerDsn

# The seeder writes company logos itself, through the same blobstore the api
# reads, so passing this installation's own directory is all that stands between
# "logos: skipped" and the real thing. An installation whose margince.env names
# a real endpoint has that read out of the file instead.
$blobEndpoint = Get-EnvValue 'MARGINCE_BLOBSTORE_ENDPOINT'
$blobPath     = Get-EnvValue 'MARGINCE_BLOBSTORE_PATH'
if (-not $blobEndpoint -and -not $blobPath) { $blobPath = Join-Path $Root 'data\blobs' }

$env:MARGINCE_SEED_PASSWORD           = $password
$env:MARGINCE_SEED_DSN                = $dsn
$env:MARGINCE_BLOBSTORE_ENDPOINT      = $blobEndpoint
$env:MARGINCE_BLOBSTORE_PATH          = $blobPath
$env:MARGINCE_BLOBSTORE_ACCESS_KEY    = Get-EnvValue 'MARGINCE_BLOBSTORE_ACCESS_KEY'
$env:MARGINCE_BLOBSTORE_SECRET_KEY    = Get-EnvValue 'MARGINCE_BLOBSTORE_SECRET_KEY'
$env:MARGINCE_BLOBSTORE_BUCKET        = Get-EnvValue 'MARGINCE_BLOBSTORE_BUCKET'
$env:MARGINCE_BLOBSTORE_REGION        = Get-EnvValue 'MARGINCE_BLOBSTORE_REGION'

$seedArgs = @('-dataset', $dataset, '-api', (Get-AppUrl), '-email', (Get-AppEmail))
if ($verify) { $seedArgs += '-verify-only' }
if ($passThrough.Count -gt 0) { $seedArgs += $passThrough }

if ($verify) {
    Write-Host "Checking $(Get-AppUrl) against $dataset"
} else {
    Write-Host "Loading $dataset into $(Get-AppUrl)"
    Write-Host 'This takes a few minutes. Leave Margince running.'
}
Write-Host ''

& $seeder @seedArgs
if ($LASTEXITCODE -ne 0) { Fail "the seeder failed (exit $LASTEXITCODE)" }

Write-Host ''
if ($verify) {
    Write-Host 'Checked. Nothing was written.'
} else {
    Write-Host "Done. Sign in at $(Get-AppUrl)"
    Write-Host "  $(Get-AppEmail) / $SeededPassword"
    Write-Host ''
    Write-Host 'The loader replaced the sign-in password, so data\admin-password is no'
    Write-Host 'longer current. The seeded colleagues sign in with password "1234".'
}
Finish 0
