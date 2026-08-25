[CmdletBinding()]
param(
    [switch]$WaitReady,
    [switch]$ValidateOnly,
    [switch]$ReloadCompat
)

$ErrorActionPreference = 'Stop'
$installDir = $PSScriptRoot
$exePath = Join-Path $installDir 'cli-proxy-api.exe'
$pidPath = Join-Path $installDir 'cli-proxy-api.pid'
$compatScriptPath = Join-Path $installDir 'codex-catalog-compat.mjs'
$compatPidPath = Join-Path $installDir 'codex-catalog-compat.pid'
$clientKeyPath = Join-Path $installDir 'client-key.txt'
$nodeCommand = Get-Command 'node.exe' -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1
$nodePath = if ($null -ne $nodeCommand) { $nodeCommand.Source } else { $null }
$stdoutPath = Join-Path $installDir 'server.stdout.log'
$stderrPath = Join-Path $installDir 'server.stderr.log'
$compatStdoutPath = Join-Path $installDir 'compat.stdout.log'
$compatStderrPath = Join-Path $installDir 'compat.stderr.log'
$historyDir = Join-Path $installDir 'logs'
$catalogUpdaterPath = Join-Path $installDir 'Update-CodexModelCatalog.ps1'
$routingModePath = Join-Path $installDir 'routing-mode.txt'
$credentialProtectorPath = Join-Path $installDir 'Protect-CLIProxyAPICredentials.ps1'
$runtimeBuilderPath = Join-Path $installDir 'New-RuntimeConfig.ps1'
$mutex = New-Object System.Threading.Mutex($false, 'Local\CodexCLIProxyAPI-StartStop')
$lockTaken = $false
$startedProxy = $false
$startedCompat = $false

function Get-ExecutableVersion {
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $output = @(& $exePath --help 2>&1 | ForEach-Object { [string]$_ })
    $ErrorActionPreference = $savedPreference
    return $output | Where-Object { $_ -match '^CLIProxyAPI Version:' } | Select-Object -First 1
}

function Get-ListenerPids([int]$Port) {
    return @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty OwningProcess -Unique)
}

function Test-OwnedProcess([int]$ProcessId, [ValidateSet('proxy', 'compat')]$Kind) {
    $process = Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction SilentlyContinue
    if ($null -eq $process) { return $false }
    if ($Kind -eq 'proxy') { return [string]$process.ExecutablePath -eq $exePath }
    return [string]$process.ExecutablePath -eq $nodePath -and
        [string]$process.CommandLine -like "*$compatScriptPath*"
}

function Read-PidFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8).Trim()
    if ($text -match '^\d+$') { return [int]$text }
    return $null
}

function Write-PidFile([string]$Path, [int]$ProcessId) {
    $tempPath = "$Path.tmp"
    [System.IO.File]::WriteAllText($tempPath, [string]$ProcessId, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $tempPath -Destination $Path -Force
}

function Test-Endpoint([int]$Port, [switch]$Catalog) {
    try {
        $clientKey = [System.IO.File]::ReadAllText($clientKeyPath, [System.Text.Encoding]::UTF8).Trim()
        $headers = @{ Authorization = "Bearer $clientKey" }
        $suffix = if ($Catalog) { '/v1/models?client_version=startup-check' } else { '/v1/models' }
        $response = Invoke-WebRequest -UseBasicParsing -TimeoutSec 3 -Headers $headers -Uri "http://127.0.0.1:$Port$suffix"
        $clientKey = $null
        return $response.StatusCode -eq 200
    }
    catch { return $false }
}

function Wait-Endpoint([int]$Port, [switch]$Catalog, [int]$Seconds = 25) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        if (Test-Endpoint -Port $Port -Catalog:$Catalog) { return $true }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    return $false
}

function Get-CompatHealth {
    try {
        return Invoke-RestMethod -TimeoutSec 3 -Uri 'http://127.0.0.1:8318/health'
    }
    catch { return $null }
}

function Wait-CompatHealth([int]$Seconds = 25) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        $health = Get-CompatHealth
        if ($null -ne $health -and $health.status -eq 'ok' -and $health.mode -in @(1, 2)) { return $health }
        Start-Sleep -Milliseconds 250
    } while ([DateTime]::UtcNow -lt $deadline)
    return $null
}

function Assert-CompatIdle {
    $health = Get-CompatHealth
    if ($null -ne $health) {
        if ([int]$health.active_requests -gt 0) {
            throw "Compatibility proxy has $($health.active_requests) active request(s); reload was not attempted."
        }
        return
    }
    $active = @{}
    if (Test-Path -LiteralPath $compatStdoutPath -PathType Leaf) {
        foreach ($line in @(Get-Content -LiteralPath $compatStdoutPath -Tail 5000 -Encoding UTF8 -ErrorAction SilentlyContinue)) {
            try { $event = $line | ConvertFrom-Json } catch { continue }
            $requestId = [string]$event.request_id
            if ([string]::IsNullOrWhiteSpace($requestId)) { continue }
            if ($event.event -eq 'route') { $active[$requestId] = $true }
            elseif ($event.event -in @('complete', 'route_rejected', 'request_error', 'alias_rewrite_error')) { $active.Remove($requestId) }
        }
    }
    if ($active.Count -gt 0) {
        throw "Legacy compatibility proxy has $($active.Count) logged active request(s); reload was not attempted."
    }
}

function Wait-ProcessExit([int]$ProcessId, [int]$Seconds = 15) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        if ($null -eq (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) { return $true }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    return $false
}

function Rotate-Log([string]$Path, [string]$Prefix) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return }
    if ((Get-Item -LiteralPath $Path).Length -eq 0) { return }
    if (-not (Test-Path -LiteralPath $historyDir -PathType Container)) {
        New-Item -ItemType Directory -Path $historyDir | Out-Null
    }
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    Move-Item -LiteralPath $Path -Destination (Join-Path $historyDir "$Prefix-$timestamp.log") -Force
}

function Stop-CompatOwned {
    $listenerPids = @(Get-ListenerPids -Port 8318)
    foreach ($processId in $listenerPids) {
        if (-not (Test-OwnedProcess -ProcessId $processId -Kind compat)) {
            throw "Port 8318 is occupied by an unrelated process (PID $processId)."
        }
    }
    $recordedPid = Read-PidFile -Path $compatPidPath
    $candidates = @($listenerPids + @($recordedPid) | Where-Object { $null -ne $_ } | Select-Object -Unique)
    if ($listenerPids.Count -gt 0 -and (Test-Path -LiteralPath $clientKeyPath -PathType Leaf)) {
        try {
            $clientKey = [System.IO.File]::ReadAllText($clientKeyPath, [System.Text.Encoding]::UTF8).Trim()
            $headers = @{ Authorization = "Bearer $clientKey" }
            $response = Invoke-WebRequest -UseBasicParsing -TimeoutSec 3 -Method Post `
                -Headers $headers -Uri 'http://127.0.0.1:8318/__cliproxy_internal/shutdown'
            $clientKey = $null
            if ($response.StatusCode -ne 202) { throw 'Compatibility proxy rejected graceful shutdown.' }
        }
        catch {
            # Older compatibility layers do not have the internal shutdown endpoint.
        }
    }
    foreach ($processId in $candidates) {
        if (-not (Test-OwnedProcess -ProcessId $processId -Kind compat)) { continue }
        if (-not (Wait-ProcessExit -ProcessId $processId -Seconds 12)) {
            Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
            $null = Wait-ProcessExit -ProcessId $processId -Seconds 5
        }
    }
    Remove-Item -LiteralPath $compatPidPath -Force -ErrorAction SilentlyContinue
    if (@(Get-ListenerPids -Port 8318).Count -gt 0) { throw 'Port 8318 did not stop cleanly.' }
    Rotate-Log -Path $compatStdoutPath -Prefix 'compat-stdout'
    Rotate-Log -Path $compatStderrPath -Prefix 'compat-stderr'
}

function Stop-ProxyOwned {
    $listenerPids = @(Get-ListenerPids -Port 8317)
    foreach ($processId in $listenerPids) {
        if (-not (Test-OwnedProcess -ProcessId $processId -Kind proxy)) {
            throw "Port 8317 is occupied by an unrelated process (PID $processId)."
        }
    }
    $recordedPid = Read-PidFile -Path $pidPath
    $candidates = @($listenerPids + @($recordedPid) | Where-Object { $null -ne $_ } | Select-Object -Unique)
    foreach ($processId in $candidates) {
        if (-not (Test-OwnedProcess -ProcessId $processId -Kind proxy)) { continue }
        Stop-Process -Id $processId -ErrorAction SilentlyContinue
        if (-not (Wait-ProcessExit -ProcessId $processId -Seconds 5)) {
            Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
            $null = Wait-ProcessExit -ProcessId $processId -Seconds 5
        }
    }
    Remove-Item -LiteralPath $pidPath -Force -ErrorAction SilentlyContinue
    if (@(Get-ListenerPids -Port 8317).Count -gt 0) { throw 'Port 8317 did not stop cleanly.' }
    Rotate-Log -Path $stdoutPath -Prefix 'server-stdout'
    Rotate-Log -Path $stderrPath -Prefix 'server-stderr'
}

function Start-Proxy([string]$RuntimePath) {
    $process = Start-Process -FilePath $exePath `
        -ArgumentList @('-config', $RuntimePath) `
        -WorkingDirectory $installDir `
        -WindowStyle Hidden `
        -RedirectStandardOutput $stdoutPath `
        -RedirectStandardError $stderrPath `
        -PassThru
    Write-PidFile -Path $pidPath -ProcessId $process.Id
    return $process
}

function Start-Compat {
    Rotate-Log -Path $compatStdoutPath -Prefix 'compat-stdout'
    Rotate-Log -Path $compatStderrPath -Prefix 'compat-stderr'
    $process = Start-Process -FilePath $nodePath `
        -ArgumentList @($compatScriptPath) `
        -WorkingDirectory $installDir `
        -WindowStyle Hidden `
        -RedirectStandardOutput $compatStdoutPath `
        -RedirectStandardError $compatStderrPath `
        -PassThru
    Write-PidFile -Path $compatPidPath -ProcessId $process.Id
    return $process
}

try {
    $lockTaken = $mutex.WaitOne([TimeSpan]::FromSeconds(30))
    if (-not $lockTaken) { throw 'Timed out waiting for the CLIProxyAPI start/stop lock.' }
    if ([string]::IsNullOrWhiteSpace($nodePath)) { throw 'Node.js was not found on PATH.' }

    foreach ($required in @($exePath, $compatScriptPath, $nodePath, $runtimeBuilderPath, $credentialProtectorPath, $catalogUpdaterPath)) {
        if (-not (Test-Path -LiteralPath $required -PathType Leaf)) { throw "Required file is missing: $required" }
    }
    $version = Get-ExecutableVersion
    if ($version -notmatch 'Version:\s*7\.2\.119\b') {
        throw 'The fixed CLIProxyAPI executable is not official version 7.2.119.'
    }
    & $nodePath --check $compatScriptPath
    if ($LASTEXITCODE -ne 0) { throw 'Compatibility proxy Node syntax validation failed.' }
    $runtimePath = & $runtimeBuilderPath
    $null = & $credentialProtectorPath

    if (Test-Path -LiteralPath $routingModePath -PathType Leaf) {
        $savedMode = [System.IO.File]::ReadAllText($routingModePath, [System.Text.Encoding]::UTF8).Trim()
        if ($savedMode -notin @('1', '2')) { throw 'Persisted routing mode must be 1 or 2.' }
    }

    if ($ValidateOnly) {
        Write-Output 'CLIProxyAPI startup validation passed; no process was changed.'
        Write-Output $version
        return
    }

    $proxyListeners = @(Get-ListenerPids -Port 8317)
    foreach ($processId in $proxyListeners) {
        if (-not (Test-OwnedProcess -ProcessId $processId -Kind proxy)) {
            throw "Port 8317 is occupied by an unrelated process (PID $processId)."
        }
    }
    foreach ($processId in @(Get-ListenerPids -Port 8318)) {
        if (-not (Test-OwnedProcess -ProcessId $processId -Kind compat)) {
            throw "Port 8318 is occupied by an unrelated process (PID $processId)."
        }
    }

    $proxyReady = Test-Endpoint -Port 8317
    if ($ReloadCompat) {
        if (-not $proxyReady -or $proxyListeners.Count -ne 1) {
            throw 'Cannot reload only 8318 because the owned 8317 service is not ready.'
        }
        $preservedProxyPid = $proxyListeners[0]
        Assert-CompatIdle
        Stop-CompatOwned
        $compatProcess = Start-Compat
        $startedCompat = $true
        $compatHealth = Wait-CompatHealth -Seconds 25
        if ($null -eq $compatHealth -or -not (Wait-Endpoint -Port 8318 -Catalog -Seconds 25)) {
            throw "Compatibility proxy did not become ready. See $compatStderrPath"
        }
        if ((Get-ListenerPids -Port 8317) -notcontains $preservedProxyPid) {
            throw '8317 PID changed during an 8318-only reload.'
        }
        $null = & $catalogUpdaterPath
        Write-Output "Compatibility proxy reloaded in mode $($compatHealth.mode); CLIProxyAPI PID $preservedProxyPid was preserved."
        return
    }

    $existingHealth = Get-CompatHealth
    if ($proxyReady -and $null -ne $existingHealth -and $existingHealth.status -eq 'ok' -and
        $existingHealth.mode -in @(1, 2) -and (Test-Endpoint -Port 8318 -Catalog)) {
        $null = & $catalogUpdaterPath
        Write-Output "CLIProxyAPI is already healthy in routing mode $($existingHealth.mode); services were not restarted."
        return
    }

    if (-not $proxyReady) {
        Assert-CompatIdle
        Stop-CompatOwned
        Stop-ProxyOwned
        $proxyProcess = Start-Proxy -RuntimePath $runtimePath
        $startedProxy = $true
        if (-not (Wait-Endpoint -Port 8317 -Seconds 25)) {
            throw "CLIProxyAPI did not become ready. See $stderrPath"
        }
    }

    Assert-CompatIdle
    Stop-CompatOwned
    $compatProcess = Start-Compat
    $startedCompat = $true
    $compatHealth = Wait-CompatHealth -Seconds 25
    if ($null -eq $compatHealth -or -not (Wait-Endpoint -Port 8318 -Catalog -Seconds 25)) {
        throw "Compatibility proxy did not become ready. See $compatStderrPath"
    }
    $null = & $catalogUpdaterPath
    Write-Output "CLIProxyAPI ready in routing mode $($compatHealth.mode)."
}
catch {
    $originalError = $_
    if ($startedCompat) {
        try { Stop-CompatOwned } catch {}
    }
    if ($startedProxy) {
        try { Stop-ProxyOwned } catch {}
    }
    throw $originalError
}
finally {
    if ($lockTaken) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
