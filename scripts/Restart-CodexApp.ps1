[CmdletBinding()]
param(
    [string]$Workspace = $env:USERPROFILE,
    [int]$WaitSeconds = 15,
    [int]$DelaySeconds = 2,
    [switch]$ValidateOnly,
    [switch]$Worker
)

$ErrorActionPreference = 'Stop'
$logFile = Join-Path $env:USERPROFILE '.codex\log\restart-codex-app.log'

function Write-RestartLog([string]$Message) {
    $logDir = Split-Path -Parent $logFile
    if (-not (Test-Path -LiteralPath $logDir -PathType Container)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }
    Add-Content -LiteralPath $logFile -Value "[$(Get-Date -Format o)] $Message" -Encoding UTF8
}

function Get-CodexAppProcesses {
    return @(Get-CimInstance Win32_Process | Where-Object {
        $executablePath = [string]$_.ExecutablePath
        $commandLine = [string]$_.CommandLine
        $executablePath -match '(?i)\\WindowsApps\\OpenAI\.Codex_[^\\]+\\app\\' -or
        $commandLine -match '(?i)\\WindowsApps\\OpenAI\.Codex_[^\\]+\\app\\'
    })
}

function Open-CodexWorkspace([string]$WorkspacePath) {
    if (-not (Test-Path -LiteralPath $WorkspacePath -PathType Container)) {
        $WorkspacePath = $env:USERPROFILE
    }

    $absolute = [System.IO.Path]::GetFullPath($WorkspacePath)
    if (-not $absolute.StartsWith('\\?\')) {
        $absolute = "\\?\$absolute"
    }

    $uri = "codex://threads/new?path=$([System.Uri]::EscapeDataString($absolute))"
    Write-RestartLog "Opening URI: $uri"
    Start-Process -FilePath $uri
}

try {
    if ($ValidateOnly) {
        $validationProcesses = @(Get-CodexAppProcesses)
        Write-Output 'Codex App restart helper validation passed; no process was changed.'
        Write-Output "Workspace to reopen: $Workspace"
        Write-Output "Matched Codex package processes: $($validationProcesses.Count)"
        $validationProcesses |
            Sort-Object ProcessId |
            ForEach-Object { Write-Output "  pid=$($_.ProcessId) name=$($_.Name)" }
        exit 0
    }

    if (-not $Worker) {
        $workerArguments = @(
            '-NoProfile',
            '-ExecutionPolicy', 'Bypass',
            '-File', $PSCommandPath,
            '-Worker',
            '-Workspace', $Workspace,
            '-WaitSeconds', [string]$WaitSeconds,
            '-DelaySeconds', [string]$DelaySeconds
        )
        Start-Process -FilePath 'powershell.exe' -ArgumentList $workerArguments -WindowStyle Hidden
        Write-RestartLog "Detached restart worker scheduled workspace=$Workspace delay=$DelaySeconds"
        Write-Output 'Codex App restart worker scheduled in a detached process.'
        exit 0
    }

    Write-RestartLog "Restart worker started workspace=$Workspace delay=$DelaySeconds"
    Start-Sleep -Seconds $DelaySeconds

    $processes = Get-CodexAppProcesses
    foreach ($process in $processes) {
        Write-RestartLog "Stopping $($process.Name) pid=$($process.ProcessId)"
        Stop-Process -Id $process.ProcessId -Force -ErrorAction SilentlyContinue
    }

    $deadline = (Get-Date).AddSeconds($WaitSeconds)
    do {
        Start-Sleep -Milliseconds 300
        $remaining = Get-CodexAppProcesses
    } while ($remaining.Count -gt 0 -and (Get-Date) -lt $deadline)

    if ($remaining.Count -gt 0) {
        Write-RestartLog "Warning: $($remaining.Count) Codex package processes remained after timeout."
    }

    Start-Sleep -Seconds 1
    Open-CodexWorkspace $Workspace
    Write-RestartLog 'Codex App launch requested.'
}
catch {
    Write-RestartLog "ERROR: $($_.Exception.Message)"
    throw
}
