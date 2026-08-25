[CmdletBinding()]
param(
    [switch]$CompatOnly
)

$ErrorActionPreference = 'Stop'
$installDir = $PSScriptRoot
$exePath = Join-Path $installDir 'cli-proxy-api.exe'
$nodeCommand = Get-Command 'node.exe' -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1
$nodePath = if ($null -ne $nodeCommand) { $nodeCommand.Source } else { $null }
$compatScriptPath = Join-Path $installDir 'codex-catalog-compat.mjs'
$clientKeyPath = Join-Path $installDir 'client-key.txt'
$pidPath = Join-Path $installDir 'cli-proxy-api.pid'
$compatPidPath = Join-Path $installDir 'codex-catalog-compat.pid'
$mutex = New-Object System.Threading.Mutex($false, 'Local\CodexCLIProxyAPI-StartStop')
$lockTaken = $false

function Test-OwnedProcess([int]$ProcessId, [ValidateSet('proxy', 'compat')]$Kind) {
    $process = Get-CimInstance Win32_Process -Filter "ProcessId = $ProcessId" -ErrorAction SilentlyContinue
    if ($null -eq $process) { return $false }
    if ($Kind -eq 'compat') {
        return [string]$process.ExecutablePath -eq $nodePath -and
            [string]$process.CommandLine -like "*$compatScriptPath*"
    }
    $path = [string]$process.ExecutablePath
    return $path -eq $exePath -or
        ($path.StartsWith($installDir, [System.StringComparison]::OrdinalIgnoreCase) -and
         [System.IO.Path]::GetFileName($path) -eq 'cli-proxy-api.exe')
}

function Read-PidFile([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $text = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8).Trim()
    if ($text -match '^\d+$') { return [int]$text }
    return $null
}

function Get-ListenerPids([int]$Port) {
    return @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty OwningProcess -Unique)
}

function Wait-ProcessExit([int]$ProcessId, [int]$Seconds = 12) {
    $deadline = [DateTime]::UtcNow.AddSeconds($Seconds)
    do {
        if ($null -eq (Get-Process -Id $ProcessId -ErrorAction SilentlyContinue)) { return $true }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    return $false
}

function Stop-CompatOwned {
    $listenerPids = @(Get-ListenerPids -Port 8318)
    foreach ($processId in $listenerPids) {
        if (-not (Test-OwnedProcess -ProcessId $processId -Kind compat)) {
            throw "Refusing to stop unrelated process PID $processId on port 8318."
        }
    }
    $recordedPid = Read-PidFile -Path $compatPidPath
    $candidates = @($listenerPids + @($recordedPid) | Where-Object { $null -ne $_ } | Select-Object -Unique)
    if ($listenerPids.Count -gt 0 -and (Test-Path -LiteralPath $clientKeyPath -PathType Leaf)) {
        try {
            $clientKey = [System.IO.File]::ReadAllText($clientKeyPath, [System.Text.Encoding]::UTF8).Trim()
            $headers = @{ Authorization = "Bearer $clientKey" }
            $null = Invoke-WebRequest -UseBasicParsing -TimeoutSec 3 -Method Post `
                -Headers $headers -Uri 'http://127.0.0.1:8318/__cliproxy_internal/shutdown'
            $clientKey = $null
        }
        catch {}
    }
    foreach ($processId in $candidates) {
        if (-not (Test-OwnedProcess -ProcessId $processId -Kind compat)) { continue }
        if (-not (Wait-ProcessExit -ProcessId $processId -Seconds 12)) {
            Stop-Process -Id $processId -Force -ErrorAction SilentlyContinue
            $null = Wait-ProcessExit -ProcessId $processId -Seconds 5
        }
    }
    Remove-Item -LiteralPath $compatPidPath -Force -ErrorAction SilentlyContinue
    if (@(Get-ListenerPids -Port 8318).Count -gt 0) { throw 'Port 8318 remained listening after stop.' }
}

function Stop-ProxyOwned {
    $listenerPids = @(Get-ListenerPids -Port 8317)
    foreach ($processId in $listenerPids) {
        if (-not (Test-OwnedProcess -ProcessId $processId -Kind proxy)) {
            throw "Refusing to stop unrelated process PID $processId on port 8317."
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
    if (@(Get-ListenerPids -Port 8317).Count -gt 0) { throw 'Port 8317 remained listening after stop.' }
}

try {
    $lockTaken = $mutex.WaitOne([TimeSpan]::FromSeconds(30))
    if (-not $lockTaken) { throw 'Timed out waiting for the CLIProxyAPI start/stop lock.' }
    if ([string]::IsNullOrWhiteSpace($nodePath)) { throw 'Node.js was not found on PATH.' }
    Stop-CompatOwned
    if ($CompatOnly) {
        Write-Output 'Compatibility proxy is stopped; CLIProxyAPI on 8317 was left running.'
        return
    }
    Stop-ProxyOwned
    Write-Output 'CLIProxyAPI and compatibility proxy are stopped.'
}
finally {
    if ($lockTaken) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
