# aio-install.test.ps1 — scripts/aio/install.ps1 with every external command
# replaced by a function (functions win over applications in PowerShell's
# command resolution). Run: pwsh -NoProfile -File scripts/aio-install.test.ps1
$ErrorActionPreference = 'Stop'
$script:Failures = 0
function Check([string]$What, [bool]$Condition) {
    if ($Condition) { Write-Host "ok: $What" } else { Write-Host "FAIL: $What"; $script:Failures++ }
}

$env:MARGINCE_AIO_NO_MAIN = '1'
. (Join-Path $PSScriptRoot 'aio/install.ps1')

function Reset-Stub {
    $script:Log = [System.Collections.Generic.List[string]]::new()
    $script:S = @{ DockerMissing = $false; DaemonDown = $false; Container = $null; Running = $false; Port = $null; Busy = @(); Health = 'healthy'; Answer = 'y'; WslOk = $true }
}
function Get-Command { param([string]$Name, $ErrorAction)
    if ($Name -eq 'docker' -and $script:S.DockerMissing) { return $null }
    if ($Name -eq 'winget') { return 'winget' }
    return $Name }
function docker {
    $a = $args -join ' '; $script:Log.Add("docker $a"); $global:LASTEXITCODE = 0
    switch ($args[0]) {
        'info' { if ($script:S.DaemonDown) { $global:LASTEXITCODE = 1 }; return }
        'image' { if ($a -like '*{{.Id}}*') { return 'sha256:new' }; return }
        'pull' { return }
        'container' {
            if (-not $script:S.Container) { $global:LASTEXITCODE = 1; return }
            if ($a -like '*{{.Image}}*') { return $script:S.Container }
            if ($a -like '*State.Running*') { if ($script:S.Running) { return 'true' } else { return 'false' } }
            if ($a -like '*PortBindings*') { return $script:S.Port }
            if ($a -like '*Health*') { return $script:S.Health }
            return }
        'run' {
            $p = [regex]::Match($a, '127\.0\.0\.1:(\d+):80').Groups[1].Value
            $script:S.Container = 'sha256:new'; $script:S.Port = $p
            if ($script:S.Busy -contains $p) { $global:LASTEXITCODE = 125; return 'Error: address already in use' }
            $script:S.Running = $true; return 'cid' }
        'start' { if ($script:S.Busy -contains $script:S.Port) { $global:LASTEXITCODE = 1; return 'Error: address already in use' }; $script:S.Running = $true; return }
        'stop' { $script:S.Running = $false; return }
        'rm' { $script:S.Container = $null; $script:S.Running = $false; return }
        'volume' { return }
        'exec' { return '  Sign in as admin@localhost password stub-password' }
        'logs' { return 'stub log' }
    }
}
function winget { $script:Log.Add("winget $($args -join ' ')"); $global:LASTEXITCODE = 0 }
function wsl { $script:Log.Add("wsl $($args -join ' ')"); if ($script:S.WslOk) { $global:LASTEXITCODE = 0 } else { $global:LASTEXITCODE = 1 } }
function Start-Process { param($FilePath, $ArgumentList, $Verb, [switch]$Wait) $script:Log.Add("start $FilePath $($ArgumentList -join ' ')") }
function Start-Sleep { param($Seconds) }
function Read-Host { param($Prompt) return $script:S.Answer }

$common = @('-Image', 'acme/all-in-one:v1.0.0', '-Container', 'margince-acme', '-Volume', 'margince-acme-data')

Reset-Stub
$out = Invoke-Aio (@('up') + $common) *>&1 | Out-String
Check 'up runs the container on 127.0.0.1:8080' ($script:Log -contains 'docker run -d --name margince-acme --restart unless-stopped -p 127.0.0.1:8080:80 -v margince-acme-data:/data acme/all-in-one:v1.0.0')
Check 'up shows the address and the sign-in' (($out -match 'http://localhost:8080') -and ($out -match 'stub-password'))
Check 'up opens the browser' ($script:Log -contains 'start http://localhost:8080 ')

Reset-Stub; $script:S.Busy = @('8080')
Invoke-Aio (@('up') + $common) *>&1 | Out-Null
Check 'a busy port is skipped' (@($script:Log | Where-Object { $_ -like '*127.0.0.1:8081:80*' }).Count -eq 1)

Reset-Stub; $script:S.Container = 'sha256:old'; $script:S.Port = '8085'
Invoke-Aio (@('up') + $common) *>&1 | Out-Null
Check 'a container of another image is replaced on its port' (($script:Log -contains 'docker rm -f -v margince-acme') -and (@($script:Log | Where-Object { $_ -like '*127.0.0.1:8085:80*' }).Count -eq 1))

Reset-Stub; $script:S.DockerMissing = $true
Invoke-Aio (@('up', '-Yes') + $common) *>&1 | Out-Null
Check 'a missing Docker is installed with winget' (@($script:Log | Where-Object { $_ -like 'winget install -e --id Docker.DockerDesktop*' }).Count -eq 1)

Reset-Stub; $script:S.DockerMissing = $true; $script:S.WslOk = $false
$out = Invoke-Aio (@('up', '-Yes') + $common) *>&1 | Out-String
Check 'a missing WSL is installed and the tester is asked to restart' ((@($script:Log | Where-Object { $_ -like 'start wsl.exe --install --no-distribution*' }).Count -eq 1) -and ($out -match 'Restart'))

Reset-Stub; $script:S.DockerMissing = $true; $script:S.Answer = 'n'
Invoke-Aio (@('up') + $common) *>&1 | Out-Null
Check 'no answer installs nothing' (@($script:Log | Where-Object { $_ -like 'winget*' }).Count -eq 0)

Reset-Stub; $script:S.Health = 'starting'; $env:MARGINCE_START_TIMEOUT = '10'
$out = Invoke-Aio (@('up') + $common) *>&1 | Out-String
Check 'never healthy names the logs action' ($out -match 'logs')
Remove-Item Env:MARGINCE_START_TIMEOUT

Reset-Stub; Invoke-Aio (@('up') + $common) *>&1 | Out-Null; $script:Log.Clear()
Invoke-Aio (@('down') + $common) *>&1 | Out-Null
Check 'down stops the container' ($script:Log -contains 'docker stop margince-acme')
$script:S.Answer = 'yes'
Invoke-Aio (@('reset') + $common) *>&1 | Out-Null
Check 'reset after yes removes the container and the volume' (($script:Log -contains 'docker rm -f -v margince-acme') -and ($script:Log -contains 'docker volume rm margince-acme-data'))

$out = Invoke-Aio @('up') *>&1 | Out-String
Check 'an unrendered script names make aio-scripts' ($out -match 'make aio-scripts')

if ($script:Failures -gt 0) { Write-Host "`naio-install.test.ps1: $($script:Failures) failed"; exit 1 }
Write-Host "`naio-install.test.ps1: all passed"
