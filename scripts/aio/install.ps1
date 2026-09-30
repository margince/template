# install.ps1 — install and run Margince from its all-in-one image on Windows
# (docs/superpowers/specs/2026-09-30-all-in-one-image-design.md, Section 8).
# The macOS and Ubuntu version is install.sh.
#
#   irm <url>/install.ps1 | iex
#   .\install.ps1 -Action <up|down|reset|logins|logs> [-Yes]
#
# No param() block: `irm | iex` cannot pass parameters, and the arguments of
# a downloaded script are parsed from $args instead.

$Script:Image = '@IMAGE@'
$Script:Container = '@CONTAINER@'
$Script:Volume = '@VOLUME@'

class AioStop : System.Exception { AioStop([string]$m) : base($m) {} }

function Say([string]$Text) { Write-Host $Text }
function Fail([string]$Text) { throw [AioStop]::new($Text) }

function Test-DockerCli { [bool](Get-Command docker -ErrorAction SilentlyContinue) }
function Test-DockerOk { docker info *> $null; return ($LASTEXITCODE -eq 0) }

function Ask([string]$Question) {
    if ($Script:Yes) { return $true }
    $answer = Read-Host "$Question [Y/n]"
    return ($answer -eq '' -or $answer -match '^(y|yes)$')
}

function Install-Docker {
    if (-not (Ask 'Margince needs Docker Desktop, which is not installed. Install it now? Docker''s subscription terms apply.')) {
        Fail 'Margince needs Docker. Install Docker Desktop from https://docs.docker.com/desktop/, then run this command again.'
    }
    wsl --status *> $null
    if ($LASTEXITCODE -ne 0) {
        Say 'Installing WSL 2, which Docker Desktop needs. Windows asks for permission.'
        Start-Process -FilePath 'wsl.exe' -ArgumentList '--install', '--no-distribution' -Verb RunAs -Wait
        Fail 'Restart the computer to finish installing WSL 2, then run this command again.'
    }
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Fail 'winget is not available. Install Docker Desktop from https://docs.docker.com/desktop/, then run this command again.'
    }
    Say 'Installing Docker Desktop. Windows asks for permission.'
    winget install -e --id Docker.DockerDesktop --accept-package-agreements --accept-source-agreements
    if ($LASTEXITCODE -ne 0) {
        Fail 'Docker Desktop was not installed. Install it from https://docs.docker.com/desktop/, then run this command again.'
    }
    $env:Path += ";$env:ProgramFiles\Docker\Docker\resources\bin"
    Start-DockerDesktop
}

function Start-DockerDesktop {
    Say 'Starting Docker Desktop...'
    Start-Process -FilePath "$env:ProgramFiles\Docker\Docker\Docker Desktop.exe"
}

function Wait-Docker {
    Say 'Waiting for Docker. Docker Desktop may ask you to accept its terms; accept them to continue.'
    $timeout = [int]($env:MARGINCE_DOCKER_TIMEOUT, 180 | Where-Object { $_ } | Select-Object -First 1)
    for ($waited = 0; -not (Test-DockerOk); $waited += 2) {
        if ($waited -ge $timeout) {
            Fail 'Docker did not start within 3 minutes. Start Docker Desktop, wait until it says it is running, then run this command again.'
        }
        Start-Sleep -Seconds 2
    }
}

function Confirm-Docker {
    if (Test-DockerCli) {
        if (Test-DockerOk) { return }
        Start-DockerDesktop
    } else {
        Install-Docker
    }
    Wait-Docker
}

function Test-Container { docker container inspect $Script:Container *> $null; return ($LASTEXITCODE -eq 0) }
function Get-ContainerValue([string]$Format) { (docker container inspect -f $Format $Script:Container 2>$null | Out-String).Trim() }
function Get-ContainerPort { Get-ContainerValue '{{with index .HostConfig.PortBindings "80/tcp"}}{{(index . 0).HostPort}}{{end}}' }

function Confirm-Image {
    docker image inspect $Script:Image *> $null
    if ($LASTEXITCODE -eq 0) { return }
    Say 'Downloading Margince. This takes a few minutes the first time.'
    docker pull $Script:Image
    if ($LASTEXITCODE -ne 0) { Fail "Could not download $($Script:Image). Check the internet connection, then run this command again." }
}

function Test-PortError([string]$Text) { return ($Text -match 'already in use|already allocated|bind') }

function Start-On([string]$Port) {
    $err = docker run -d --name $Script:Container --restart unless-stopped -p "127.0.0.1:${Port}:80" -v "$($Script:Volume):/data" $Script:Image 2>&1 | Out-String
    if ($LASTEXITCODE -eq 0) { $Script:Port = $Port; return $true }
    if (-not (Test-PortError $err)) { Say $err; Fail 'Docker could not start Margince (see the message above).' }
    docker rm -f -v $Script:Container *> $null
    return $false
}

function New-Container([string]$Port) {
    if ($Port -and (Start-On $Port)) { return }
    foreach ($p in 8080..8099) { if (Start-On "$p") { return } }
    Fail 'Ports 8080 to 8099 are all in use. Close a program that uses one of them, then run this command again.'
}

function Wait-Healthy {
    Say 'Starting Margince. The first start takes a few minutes.'
    $timeout = [int]($env:MARGINCE_START_TIMEOUT, 600 | Where-Object { $_ } | Select-Object -First 1)
    for ($waited = 0; (Get-ContainerValue '{{if .State.Health}}{{.State.Health.Status}}{{end}}') -ne 'healthy'; $waited += 5) {
        if ($waited -ge $timeout) {
            Fail 'Margince did not start within 10 minutes. Download install.ps1, run .\install.ps1 -Action logs, and send the output to the person who gave you this command.'
        }
        Start-Sleep -Seconds 5
    }
}

function Show-Logins {
    Say ''
    Say "Margince is running at http://localhost:$($Script:Port)"
    Say ''
    docker exec $Script:Container margince-logins | ForEach-Object { Say $_ }
    Say ''
}

function Invoke-Up {
    Confirm-Docker
    Confirm-Image
    if (Test-Container) {
        $Script:Port = Get-ContainerPort
        $imageId = (docker image inspect -f '{{.Id}}' $Script:Image | Out-String).Trim()
        if ((Get-ContainerValue '{{.Image}}') -ne $imageId) {
            Say 'Updating Margince. Your data is kept.'
            docker rm -f -v $Script:Container *> $null
            New-Container $Script:Port
        } elseif ((Get-ContainerValue '{{.State.Running}}') -ne 'true') {
            $err = docker start $Script:Container 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0) {
                if (-not (Test-PortError $err)) { Say $err; Fail 'Docker could not start Margince (see the message above).' }
                Say "Port $($Script:Port) is in use now. Moving Margince to another port. Your data is kept."
                docker rm -f -v $Script:Container *> $null
                New-Container ''
            }
        }
    } else {
        New-Container ''
    }
    Wait-Healthy
    Show-Logins
    Say 'To stop Margince, run .\install.ps1 -Action down. Your data is kept.'
    Start-Process -FilePath "http://localhost:$($Script:Port)"
}

function Confirm-DockerRunning {
    if (-not (Test-DockerCli)) { Say 'Margince is not installed on this computer.'; return $false }
    if (-not (Test-DockerOk)) { Fail 'Docker is not running. Start Docker Desktop, then run this command again.' }
    return $true
}

function Invoke-Down {
    if (-not (Confirm-DockerRunning)) { return }
    if (-not (Test-Container)) { Say 'Margince is not installed on this computer.'; return }
    docker stop $Script:Container *> $null
    Say 'Margince is stopped. Your data is kept. Run the command again to start it.'
}

function Invoke-Reset {
    if (-not (Confirm-DockerRunning)) { return }
    if (-not $Script:Yes) {
        $answer = Read-Host 'This deletes Margince and all its data. Type yes to continue'
        if ($answer -ne 'yes') { Say 'Nothing was deleted.'; return }
    }
    if (Test-Container) { docker rm -f -v $Script:Container *> $null }
    docker volume rm $Script:Volume *> $null
    Say 'Margince and its data are deleted.'
}

function Invoke-Logins {
    if (-not (Confirm-DockerRunning)) { return }
    if (-not (Test-Container) -or (Get-ContainerValue '{{.State.Running}}') -ne 'true') {
        Say 'Margince is not running. Run the command again without an action to start it.'; return
    }
    $Script:Port = Get-ContainerPort
    Show-Logins
}

function Invoke-Logs {
    if (-not (Confirm-DockerRunning)) { return }
    docker logs --tail 200 $Script:Container 2>&1 | ForEach-Object { Say $_ }
}

function Invoke-Aio([object[]]$Arguments) {
    $saved = @{ Image = $Script:Image; Container = $Script:Container; Volume = $Script:Volume }
    $Script:Yes = $false
    $action = 'up'
    try {
        for ($i = 0; $i -lt $Arguments.Count; $i++) {
            $arg = [string]$Arguments[$i]
            switch -regex ($arg) {
                '^(up|down|reset|logins|logs)$' { $action = $arg; continue }
                '^-Action$' { $i++; $action = [string]$Arguments[$i]; continue }
                '^-Yes$' { $Script:Yes = $true; continue }
                '^-Image$' { $i++; $Script:Image = [string]$Arguments[$i]; continue }
                '^-Container$' { $i++; $Script:Container = [string]$Arguments[$i]; continue }
                '^-Volume$' { $i++; $Script:Volume = [string]$Arguments[$i]; continue }
                default { Fail "Unknown argument: $arg. Use up, down, reset, logins or logs." }
            }
        }
        foreach ($v in @($Script:Image, $Script:Container, $Script:Volume)) {
            if ($v -match '^@.*@$') { Fail 'This script has no image name. Create it with make aio-scripts.' }
        }
        switch ($action) {
            'up' { Invoke-Up }
            'down' { Invoke-Down }
            'reset' { Invoke-Reset }
            'logins' { Invoke-Logins }
            'logs' { Invoke-Logs }
            default { Fail "Unknown action: $action. Use up, down, reset, logins or logs." }
        }
        return $true
    } catch [AioStop] {
        Write-Host ''
        Write-Host "Error: $($_.Exception.Message)" -ForegroundColor Red
        return $false
    } finally {
        $Script:Image = $saved.Image; $Script:Container = $saved.Container; $Script:Volume = $saved.Volume
    }
}

if (-not $env:MARGINCE_AIO_NO_MAIN) {
    $ok = Invoke-Aio $args
    # Exit only when run as a file: under `irm | iex`, exit would close the
    # tester's PowerShell window.
    if (-not $ok -and $PSCommandPath) { exit 1 }
}
