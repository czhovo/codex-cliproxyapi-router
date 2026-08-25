[CmdletBinding()]
param(
    [switch]$ValidateOnly,
    [switch]$KeepProxyRunning,
    [switch]$NoRestart,
    [string]$Workspace = $env:USERPROFILE
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$codexHome = Join-Path $env:USERPROFILE '.codex'
$configPath = Join-Path $codexHome 'config.toml'
$backupDir = Join-Path $codexHome 'backups'
$catalogPath = Join-Path $codexHome 'cliproxy-model-catalog.json'
$modePath = Join-Path $codexHome 'tools\cliproxyapi\routing-mode.txt'
$proxyStopScript = Join-Path $codexHome 'tools\cliproxyapi\Stop-CLIProxyAPI.ps1'
$restartScript = Join-Path $codexHome 'Restart-CodexApp.ps1'
$startupFolder = [Environment]::GetFolderPath('Startup')
$startupLauncherPath = Join-Path $startupFolder 'CLIProxyAPI-Autostart.vbs'

function Resolve-CodexAppExecutable {
    $appBinRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
    if (Test-Path -LiteralPath $appBinRoot -PathType Container) {
        $candidate = Get-ChildItem -LiteralPath $appBinRoot -Filter 'codex.exe' -File -Recurse |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -First 1
        if ($null -ne $candidate) {
            return $candidate.FullName
        }
    }

    $pathCandidate = Get-Command 'codex.exe' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -ne $pathCandidate) {
        return $pathCandidate.Source
    }

    throw 'Codex App codex.exe was not found. Install or reopen Codex App first.'
}

function Get-ChatGPTLoginStatus([string]$CodexExecutable) {
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $statusOutput = @(& $CodexExecutable login status 2>&1 | ForEach-Object { [string]$_ })
    $statusExitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorActionPreference
    return [pscustomobject]@{
        IsChatGPT = [bool](($statusOutput -join "`n") -match 'Logged in using ChatGPT')
        Text = ($statusOutput -join "`n").Trim()
        ExitCode = $statusExitCode
    }
}

if (-not (Test-Path -LiteralPath $configPath -PathType Leaf)) {
    throw "Codex config file was not found: $configPath"
}

$configText = [System.IO.File]::ReadAllText($configPath, [System.Text.Encoding]::UTF8)
$lines = [System.Text.RegularExpressions.Regex]::Split($configText, '\r?\n')
$desiredSettings = [ordered]@{
    model = 'model = "gpt-5.6-sol"'
    model_reasoning_effort = 'model_reasoning_effort = "xhigh"'
    model_provider = 'model_provider = "openai"'
    service_tier = 'service_tier = "priority"'
}
$foundSettings = @{}
$restoredLines = New-Object 'System.Collections.Generic.List[string]'
$insideTopLevel = $true
$skipCLIProxySection = $false

foreach ($line in $lines) {
    if ($line -match '^\s*\[model_providers\.cliproxy(?:\.[^\]]+)?\]\s*$') {
        $skipCLIProxySection = $true
        continue
    }

    if ($line -match '^\s*\[[^\]]+\]\s*$') {
        $skipCLIProxySection = $false
        $insideTopLevel = $false
    }

    if ($skipCLIProxySection) {
        continue
    }

    if ($insideTopLevel -and $line -match '^\s*(?:model_catalog_json|openai_base_url)\s*=') {
        continue
    }

    $settingMatched = $false
    if ($insideTopLevel) {
        foreach ($settingName in $desiredSettings.Keys) {
            if ($line -match ('^\s*' + [Regex]::Escape($settingName) + '\s*=')) {
                $restoredLines.Add($desiredSettings[$settingName])
                $foundSettings[$settingName] = $true
                $settingMatched = $true
                break
            }
        }
    }

    if (-not $settingMatched) {
        $restoredLines.Add($line)
    }
}

$missingSettings = @($desiredSettings.Keys | Where-Object { -not $foundSettings.ContainsKey($_) })
for ($index = $missingSettings.Count - 1; $index -ge 0; $index--) {
    $restoredLines.Insert(0, $desiredSettings[$missingSettings[$index]])
}

while ($restoredLines.Count -gt 1 -and
       [string]::IsNullOrWhiteSpace($restoredLines[$restoredLines.Count - 1]) -and
       [string]::IsNullOrWhiteSpace($restoredLines[$restoredLines.Count - 2])) {
    $restoredLines.RemoveAt($restoredLines.Count - 1)
}

$restoredText = ($restoredLines -join "`r`n")
if (-not $restoredText.EndsWith("`r`n")) {
    $restoredText += "`r`n"
}

$requiredPatterns = @(
    '(?m)^model = "gpt-5\.6-sol"\r?$',
    '(?m)^model_reasoning_effort = "xhigh"\r?$',
    '(?m)^model_provider = "openai"\r?$',
    '(?m)^service_tier = "priority"\r?$'
)
foreach ($pattern in $requiredPatterns) {
    if ($restoredText -notmatch $pattern) {
        throw "Restored config failed validation: $pattern"
    }
}
if ($restoredText -match '(?m)^(?:model_catalog_json|openai_base_url)\s*=' -or
    $restoredText -match '(?m)^\[model_providers\.cliproxy(?:\.|\])') {
    throw 'Restored config still contains a CLIProxyAPI routing setting.'
}

$codexExecutable = Resolve-CodexAppExecutable

if ($ValidateOnly) {
    $loginStatus = Get-ChatGPTLoginStatus $codexExecutable
    Write-Output 'Restore script validation passed; no file or process was changed.'
    Write-Output "Codex App CLI: $codexExecutable"
    Write-Output "ChatGPT login active: $($loginStatus.IsChatGPT)"
    Write-Output 'Default speed after restore: Fast (service_tier = priority)'
    exit 0
}

if (-not (Test-Path -LiteralPath $backupDir -PathType Container)) {
    New-Item -ItemType Directory -Path $backupDir | Out-Null
}
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$currentBackupPath = Join-Path $backupDir "config-before-gpt56sol-restore-$timestamp.toml"
$startupLauncherExisted = Test-Path -LiteralPath $startupLauncherPath -PathType Leaf
$startupLauncherBytes = if ($startupLauncherExisted) {
    [System.IO.File]::ReadAllBytes($startupLauncherPath)
}
else {
    $null
}
$catalogExisted = Test-Path -LiteralPath $catalogPath -PathType Leaf
$catalogBytes = if ($catalogExisted) {
    [System.IO.File]::ReadAllBytes($catalogPath)
}
else {
    $null
}
$modeExisted = Test-Path -LiteralPath $modePath -PathType Leaf
$modeBytes = if ($modeExisted) {
    [System.IO.File]::ReadAllBytes($modePath)
}
else {
    $null
}

try {
    Copy-Item -LiteralPath $configPath -Destination $currentBackupPath
    [System.IO.File]::WriteAllText(
        $configPath,
        $restoredText,
        (New-Object System.Text.UTF8Encoding($false))
    )

    if ($startupLauncherExisted) {
        Remove-Item -LiteralPath $startupLauncherPath -Force
    }
    if ($catalogExisted) {
        Remove-Item -LiteralPath $catalogPath -Force
    }
    if ($modeExisted) {
        Remove-Item -LiteralPath $modePath -Force
    }

    if (-not $KeepProxyRunning -and (Test-Path -LiteralPath $proxyStopScript -PathType Leaf)) {
        & $proxyStopScript | Out-Host
    }
}
catch {
    $originalError = $_
    try {
        [System.IO.File]::WriteAllText(
            $configPath,
            $configText,
            (New-Object System.Text.UTF8Encoding($false))
        )
        if ($startupLauncherExisted) {
            [System.IO.File]::WriteAllBytes($startupLauncherPath, $startupLauncherBytes)
        }
        if ($catalogExisted) {
            [System.IO.File]::WriteAllBytes($catalogPath, $catalogBytes)
        }
        if ($modeExisted) {
            [System.IO.File]::WriteAllBytes($modePath, $modeBytes)
        }
        if (Test-Path -LiteralPath $currentBackupPath -PathType Leaf) {
            Remove-Item -LiteralPath $currentBackupPath -Force
        }
    }
    catch {
        Write-Warning "Reset rollback was incomplete: $($_.Exception.Message)"
    }
    throw $originalError
}

$loginStatus = Get-ChatGPTLoginStatus $codexExecutable
if (-not $loginStatus.IsChatGPT) {
    Write-Output 'ChatGPT subscription login is not active. Starting the official browser login flow...'
    $previousErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $codexExecutable login
    $loginExitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousErrorActionPreference
    if ($loginExitCode -ne 0) {
        throw 'ChatGPT login did not complete. The config is restored; run this script again later.'
    }
    $loginStatus = Get-ChatGPTLoginStatus $codexExecutable
}

if (-not $loginStatus.IsChatGPT) {
    throw "ChatGPT subscription login was not confirmed. codex login status: $($loginStatus.Text)"
}

Write-Output ''
Write-Output 'Restore completed:'
Write-Output '  model = gpt-5.6-sol'
Write-Output '  model_reasoning_effort = xhigh'
Write-Output '  model_provider = openai'
Write-Output '  openai_base_url = official default'
Write-Output '  default speed = Fast (service_tier = priority)'
Write-Output '  GPT route = official ChatGPT/Codex direct'
Write-Output '  ChatGPT subscription login = active'
Write-Output '  CLIProxyAPI service autostart = removed'
Write-Output '  persisted CLIProxyAPI routing mode = removed'
Write-Output "  pre-restore config backup = $currentBackupPath"
Write-Output ''
if (-not $NoRestart) {
    if (-not (Test-Path -LiteralPath $restartScript -PathType Leaf)) {
        throw "Codex restart helper was not found: $restartScript"
    }
    $restartArguments = @(
        '-NoProfile',
        '-ExecutionPolicy', 'Bypass',
        '-File', $restartScript,
        '-Worker',
        '-Workspace', $Workspace
    )
    Start-Process -FilePath 'powershell.exe' -ArgumentList $restartArguments -WindowStyle Hidden
    Write-Output 'Codex App restart scheduled. It will close and reopen automatically.'
}
else {
    Write-Output 'Automatic restart skipped because -NoRestart was specified.'
}
