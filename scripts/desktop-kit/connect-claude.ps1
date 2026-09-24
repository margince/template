# connect-claude.ps1 - start Margince with a public address, for Claude (Windows).
#
# The Windows half of "Connect to Claude.command". Same contract and same three
# writes, and they are required together:
#
#   1. mcp.connector_enabled in margince.yaml
#   2. a tunnel to this installation's port
#   3. that tunnel's address in margince.env as MARGINCE_PUBLIC_BASE_URL
#
# The api mounts /mcp, the authorization server and both discovery documents
# only when the deployment declares the connector (backend/cmd/api/boot.go,
# "Gate 1"), and it REFUSES TO BOOT with the gate on and no public base URL: the
# OAuth audience and the advertised MCP resource are derived from that value and
# must never come off a Host header. So the tunnel has to be open BEFORE the api
# starts, which is why the launcher is started last here.
#
# WHAT THIS EXPOSES. A tunnel publishes the whole installation, not just /mcp.
# The sign-in page is on the same origin and has to be, because approving the
# agent is a browser sign-in on the public address. Anyone with the URL reaches
# your login page. Treat it as private and stop this when you are not using it.
#
# EVERY WRITE GOES THROUGH Write-Utf8NoBom, for the reason setup.ps1 states at
# length: Set-Content -Encoding UTF8 on Windows PowerShell 5.1 writes a UTF-8
# byte-order mark, and a mark in margince.env stops the launcher starting.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$Root = $PSScriptRoot
if (-not $Root) { $Root = Split-Path -Parent $MyInvocation.MyCommand.Path }
# The kit ships this file in runtime\, so the installation root is its parent.
$Root = Split-Path -Parent $Root

$EnvPath    = Join-Path $Root 'margince.env'
$YamlPath   = Join-Path $Root 'margince.yaml'
$LogDir     = Join-Path $Root 'data\logs'
$TunnelLog  = Join-Path $LogDir 'tunnel.log'

$Interactive = $true
if ($env:MARGINCE_KIT_INTERACTIVE -eq '0') { $Interactive = $false }

$CheckOnly = $false
if ($args -contains '--check') { $CheckOnly = $true }

function Say([string]$Message) { Write-Host $Message }

function Finish([int]$Code) {
  if ($Interactive) {
    Write-Host ''
    Write-Host 'Press Enter to close this window. ' -NoNewline
    [void](Read-Host)
  }
  exit $Code
}

function Fail([string]$Message) {
  Write-Host "error: $Message" -ForegroundColor Red
  Finish 1
}

# See setup.ps1's comment on the same function. UTF8Encoding($false) is BOM-less
# on both engines; WriteAllLines resolves a relative path against .NET's working
# directory, so every caller passes a path built from $Root.
function Write-Utf8NoBom([string]$Path, [string[]]$Lines) {
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllLines($Path, $Lines, $utf8NoBom)
}

# -Encoding UTF8 on the read for the same default reversed: with no mark to
# detect, 5.1 decodes as the system's ANSI codepage, and this file is read and
# written back.
function Get-EnvValue([string]$Key) {
  if (-not (Test-Path $EnvPath)) { return '' }
  $hit = Select-String -Encoding UTF8 -Path $EnvPath -Pattern ("^\s*" + [regex]::Escape($Key) + "\s*=\s*(.*)$") |
    Select-Object -Last 1
  if ($hit) { return $hit.Matches[0].Groups[1].Value.Trim() }
  return ''
}

function Get-AppPort {
  $value = Get-EnvValue 'MARGINCE_PORT'
  if ($value -match '^\d+$') { return [int]$value }
  return 8800
}

# OVERWRITES an existing value, which is the difference from setup.ps1's
# Set-EnvKey. That script keeps the first value because the keys it manages are
# sealed against - a second keyvault key cannot open what the first one sealed.
# This key names a tunnel that did not exist a minute ago, so a kept value is
# guaranteed to be the stale one.
function Set-EnvKeyForce([string]$Key, [string]$Value) {
  if (-not (Test-Path $EnvPath)) {
    Write-Utf8NoBom $EnvPath @('# Margince settings.')
  }
  $line = "$Key=$Value"
  $lines = @(Get-Content -Encoding UTF8 -LiteralPath $EnvPath)
  $pattern = "^\s*#?\s*" + [regex]::Escape($Key) + "\s*="
  $replaced = $false
  $out = foreach ($l in $lines) {
    if (-not $replaced -and $l -match $pattern) { $replaced = $true; $line } else { $l }
  }
  if (-not $replaced) { $out = @($lines) + $line }
  Write-Utf8NoBom $EnvPath @($out)
}

# Appended as a top-level block rather than edited into place: the file is the
# user's, the parser is strict about unknown fields but indifferent to order,
# and a block appended once is one this can recognise on every later run. An
# existing mcp: section is left exactly as it is - including one that says
# false, which is a person having turned this off on purpose.
function Enable-Connector {
  if (-not (Test-Path $YamlPath)) {
    Fail "no margince.yaml here. Run Setup.cmd first, or start Margince once so it writes one."
  }
  $lines = @(Get-Content -Encoding UTF8 -LiteralPath $YamlPath)
  if ($lines -match '^\s*mcp:') {
    if ($lines -match 'connector_enabled:\s*true') {
      Say 'margince.yaml already declares the MCP connector - kept.'
      return
    }
    Fail @"
margince.yaml has an mcp: section that does not enable the connector.
       Set 'connector_enabled: true' under it by hand, or remove the section
       and run this again. It is not overwritten here: turning it off is a
       decision someone made.
"@
  }
  $block = @(
    '',
    '# Added by "Connect to Claude.cmd". Serves /mcp, the OAuth authorization',
    '# server and both discovery documents. Requires MARGINCE_PUBLIC_BASE_URL in',
    '# margince.env - the api refuses to boot with this on and that unset.',
    'mcp:',
    '  connector_enabled: true'
  )
  Write-Utf8NoBom $YamlPath @($lines + $block)
  Say 'margince.yaml - turned the MCP connector on.'
}

# TWO providers, because the obvious one turned out to have a signup in front of
# it. `ngrok http` opened an anonymous tunnel in v2 and does not in v3: the
# SESSION is what authenticates now, so v3 exits with ERR_NGROK_4018 before any
# tunnel exists. cloudflared's quick tunnel still needs no account at all, which
# is why it is the default.
#
# ngrok is kept for the one thing cloudflared's quick tunnel cannot do: a
# RESERVED DOMAIN, so the address survives a restart and the connector is added
# in Claude once instead of every time.
#
# Chosen by MARGINCE_TUNNEL, and INFERRED when that is unset - someone who has
# put an ngrok token or domain in margince.env has already said which one they
# want, and asking again would be asking them to repeat themselves.
function Resolve-Provider {
  $choice = $env:MARGINCE_TUNNEL
  if (-not $choice) { $choice = Get-EnvValue 'MARGINCE_TUNNEL' }
  if (-not $choice) {
    $token = $env:NGROK_AUTHTOKEN
    if (-not $token) { $token = Get-EnvValue 'NGROK_AUTHTOKEN' }
    $domain = $env:NGROK_DOMAIN
    if (-not $domain) { $domain = Get-EnvValue 'NGROK_DOMAIN' }
    if ($token -or $domain) { $choice = 'ngrok' } else { $choice = 'cloudflared' }
  }
  if ($choice -ne 'ngrok' -and $choice -ne 'cloudflared') {
    Fail "MARGINCE_TUNNEL is $choice; it must be cloudflared or ngrok."
  }
  return $choice
}

# The tunnel binary lives in runtime\ with the other programs, so an update
# replaces it like them and nothing lands outside this folder. One already on
# PATH wins: a person who installed the tool themselves has an account and a
# config that a second copy here would ignore.
function Resolve-Binary([string]$Name) {
  $local = Join-Path $Root "runtime\$Name.exe"
  if (Test-Path $local) { return $local }
  $onPath = Get-Command "$Name.exe" -ErrorAction SilentlyContinue
  if ($onPath) { return $onPath.Source }
  return ''
}

# Tls12 named explicitly: 5.1 defaults to SSL3/TLS1 on older boxes and the
# download fails with a bare "could not create SSL/TLS secure channel".
# -UseBasicParsing because 5.1 otherwise wants Internet Explorer's engine, which
# is absent on a server SKU.
function Get-Download([string]$Url, [string]$OutFile) {
  [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
  try {
    Invoke-WebRequest -Uri $Url -OutFile $OutFile -UseBasicParsing
  } catch {
    Fail "could not download $Url ($($_.Exception.Message)). Install the tool yourself and run this again."
  }
}

function Get-ArchSuffix {
  if ([Environment]::Is64BitOperatingSystem) { return 'amd64' }
  return '386'
}

# cloudflared is Apache-2.0, so unlike ngrok it COULD ship inside the folder. It
# is still fetched on first use, because most installations never turn this on
# and a 38 MB binary in every download is a poor trade for the ones that do.
#
# The Windows release is a bare .exe rather than an archive, so there is nothing
# to unpack.
function Install-Cloudflared {
  $target = Join-Path $Root 'runtime\cloudflared.exe'
  $url = "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-$(Get-ArchSuffix).exe"
  Say "downloading cloudflared (once) - $url"
  Get-Download $url $target
  # Downloaded through the same path a browser uses, so it carries the same
  # mark-of-the-web, and Windows blocks an executable that has one.
  Unblock-File -LiteralPath $target -ErrorAction SilentlyContinue
  Say 'cloudflared is in runtime\cloudflared.exe'
  return $target
}

function Install-Ngrok {
  $target = Join-Path $Root 'runtime\ngrok.exe'
  $zip = Join-Path $Root 'runtime\.ngrok.zip'
  $url = "https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-windows-$(Get-ArchSuffix).zip"
  Say "downloading ngrok (once) - $url"
  Get-Download $url $zip
  Expand-Archive -LiteralPath $zip -DestinationPath (Join-Path $Root 'runtime') -Force
  Remove-Item -LiteralPath $zip -Force
  Unblock-File -LiteralPath $target -ErrorAction SilentlyContinue
  Say 'ngrok is in runtime\ngrok.exe'
  return $target
}

# ngrok v3 opens no tunnel at all without a token, and says so in a log nobody
# opens. Asked for here and kept in margince.env, so the second run does not ask.
# cloudflared needs none of this, which is the whole reason it is the default.
function Resolve-AuthToken {
  $token = $env:NGROK_AUTHTOKEN
  if (-not $token) { $token = Get-EnvValue 'NGROK_AUTHTOKEN' }
  if (-not $token) {
    $config = Join-Path $env:LOCALAPPDATA 'ngrok\ngrok.yml'
    if (Test-Path $config) {
      Say 'using the ngrok account already configured on this machine.'
      return
    }
  }
  if (-not $token -and $Interactive) {
    Say ''
    Say '  ngrok needs a token. It is free - sign in and copy it from'
    Say '  https://dashboard.ngrok.com/get-started/your-authtoken'
    Say '  (or leave this blank and unset MARGINCE_TUNNEL to use cloudflared,'
    Say '   which needs no account at all)'
    $token = Read-Host '  token'
  }
  if (-not $token) {
    Fail "no ngrok token, so no public address can be opened.
       Put NGROK_AUTHTOKEN=... in margince.env, or set MARGINCE_TUNNEL=cloudflared
       to use the provider that needs no account."
  }
  Set-EnvKeyForce 'NGROK_AUTHTOKEN' $token
  $env:NGROK_AUTHTOKEN = $token
}

$script:Tunnel = $null

# Stopped on every exit, including the failures above and the Ctrl-C that stops
# Margince itself. A tunnel outliving the app it publishes is an open door onto
# a port that now answers for somebody else.
function Stop-Tunnel {
  if (-not $script:Tunnel) { return }
  try {
    if (-not $script:Tunnel.HasExited) { $script:Tunnel.Kill() }
  } catch { }
  $script:Tunnel = $null
}

# The two providers publish their address in different places, and neither is a
# value this script may assume: a reserved domain can be unavailable and an
# account can be over its tunnel limit, and both of those still start a process.
#
# ngrok answers on a local API. cloudflared has none - the quick tunnel's
# address appears once, in its own output, which is why that is read back from
# the log file rather than from a socket.
#
# https FIRST on the ngrok side, and the fallback is deliberate rather than tidy.
# ngrok publishes one tunnel under both schemes and lists http first; taking the
# first match would advertise an http MCP resource, and an OAuth flow that
# redirects to http is one the agent's client refuses outright.
function Get-NgrokUrl {
  try {
    $body = Invoke-RestMethod -Uri 'http://127.0.0.1:4040/api/tunnels' -TimeoutSec 2 -UseBasicParsing
  } catch {
    return ''
  }
  if (-not $body.tunnels) { return '' }
  $urls = @($body.tunnels | ForEach-Object { $_.public_url })
  $https = @($urls | Where-Object { $_ -like 'https://*' })
  if ($https.Count -gt 0) { return $https[0] }
  if ($urls.Count -gt 0) { return $urls[0] }
  return ''
}

function Get-CloudflaredUrl([string]$LogPath) {
  if (-not (Test-Path $LogPath)) { return '' }
  $hit = Select-String -Encoding UTF8 -Path $LogPath -Pattern 'https://[a-z0-9-]+\.trycloudflare\.com' |
    Select-Object -First 1
  if ($hit) { return $hit.Matches[0].Value }
  return ''
}

function Start-Tunnel([string]$Provider, [string]$Exe, [int]$Port) {
  if (-not (Test-Path $LogDir)) { [void](New-Item -ItemType Directory -Path $LogDir -Force) }
  # Truncated, not appended: the address is READ BACK out of this file, and a
  # previous run's URL sitting above this one is the wrong answer available
  # before the right one exists.
  Write-Utf8NoBom $TunnelLog @()

  if ($Provider -eq 'ngrok') {
    $domain = $env:NGROK_DOMAIN
    if (-not $domain) { $domain = Get-EnvValue 'NGROK_DOMAIN' }
    $tunnelArgs = @('http', "$Port", '--log', 'stdout', '--log-format', 'logfmt')
    if ($domain) { $tunnelArgs += @('--domain', $domain) }
  } else {
    $tunnelArgs = @('tunnel', '--url', "http://127.0.0.1:$Port")
  }

  $script:Tunnel = Start-Process -FilePath $Exe -ArgumentList $tunnelArgs -PassThru `
    -WindowStyle Hidden -RedirectStandardOutput $TunnelLog -RedirectStandardError "$TunnelLog.err"

  # 100 tries at a fifth of a second. ngrok registers in about a second;
  # cloudflared's quick tunnel takes longer, because it provisions a hostname on
  # the way up.
  for ($i = 0; $i -lt 100; $i++) {
    if ($script:Tunnel.HasExited) { break }
    if ($Provider -eq 'ngrok') { $url = Get-NgrokUrl } else { $url = Get-CloudflaredUrl $TunnelLog }
    if ($url) { return $url }
    Start-Sleep -Milliseconds 200
  }
  Say ''
  Say "$Provider did not open a tunnel. Its last words, from data\logs\tunnel.log:"
  foreach ($f in @($TunnelLog, "$TunnelLog.err")) {
    if (Test-Path $f) { Get-Content -Encoding UTF8 -LiteralPath $f -Tail 12 | ForEach-Object { Say "    $_" } }
  }
  Stop-Tunnel
  Fail 'no public address.'
}

# ----------------------------------- the run --------------------------------

try {
  Say 'Margince -> Claude'
  Say ''

  Enable-Connector

  $provider = Resolve-Provider
  $exe = Resolve-Binary $provider
  if (-not $exe) {
    if ($provider -eq 'ngrok') { $exe = Install-Ngrok } else { $exe = Install-Cloudflared }
  }
  if ($provider -eq 'ngrok') { Resolve-AuthToken }

  $port = Get-AppPort
  $url = Start-Tunnel $provider $exe $port
  Set-EnvKeyForce 'MARGINCE_PUBLIC_BASE_URL' $url

  Say ''
  Say "Public address:  $url"
  Say "MCP endpoint:    $url/mcp"
  Say ''
  Say 'Add it in Claude - Settings, Connectors, Add custom connector - and paste'
  Say 'the MCP endpoint above. Claude registers itself and opens a sign-in page;'
  Say 'sign in as you do here, and approve the connection.'
  Say ''
  $domain = $env:NGROK_DOMAIN
  if (-not $domain) { $domain = Get-EnvValue 'NGROK_DOMAIN' }
  if (-not $domain) {
    Say 'This address is temporary. It changes every time you run this, and the'
    Say 'connector has to be added again each time. The way to a permanent one is'
    Say 'a reserved ngrok domain: set NGROK_DOMAIN in margince.env, which also'
    Say 'switches this to ngrok, and sign up for the free account it needs.'
    Say ''
  }
  if ($provider -eq 'ngrok') {
    Say 'On the first browser visit ngrok shows its own warning page once. Click'
    Say "through it. Claude's own calls never see it."
    Say ''
  }

  if ($CheckOnly) {
    Say '--check: not starting Margince.'
    Stop-Tunnel
    exit 0
  }

  Say 'Starting Margince. Leave this window open; Ctrl-C stops both.'
  Say ''
  & (Join-Path $Root 'margince.exe')
} finally {
  # finally, not an exit path: Ctrl-C during the launcher run has to close the
  # tunnel too, and that arrives as a terminating error rather than a return.
  Stop-Tunnel
}
