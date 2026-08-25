[CmdletBinding()]
param(
    [ValidateSet(1, 2)]
    [int]$Mode,
    [switch]$ValidateOnly,
    [switch]$NoRestart,
    [string]$Workspace = $env:USERPROFILE
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$codexHome = Join-Path $env:USERPROFILE '.codex'
$configPath = Join-Path $codexHome 'config.toml'
$backupDir = Join-Path $codexHome 'backups'
$catalogPath = Join-Path $codexHome 'cliproxy-model-catalog.json'
$keyPath = Join-Path $codexHome 'deepseek_api_key.txt'
$proxyDir = Join-Path $codexHome 'tools\cliproxyapi'
$modePath = Join-Path $proxyDir 'routing-mode.txt'
$startScript = Join-Path $proxyDir 'Start-CLIProxyAPI.ps1'
$stopScript = Join-Path $proxyDir 'Stop-CLIProxyAPI.ps1'
$loginScript = Join-Path $proxyDir 'Login-CodexOAuth.ps1'
$credentialProtectorPath = Join-Path $proxyDir 'Protect-CLIProxyAPICredentials.ps1'
$runtimeTemplatePath = Join-Path $proxyDir 'config.template.yaml'
$compatScriptPath = Join-Path $proxyDir 'codex-catalog-compat.mjs'
$clientKeyPath = Join-Path $proxyDir 'client-key.txt'
$nodeCommand = Get-Command 'node.exe' -CommandType Application -ErrorAction SilentlyContinue |
    Select-Object -First 1
$nodePath = if ($null -ne $nodeCommand) { $nodeCommand.Source } else { $null }
$authDir = Join-Path $proxyDir 'auth'
$restartScript = Join-Path $codexHome 'Restart-CodexApp.ps1'
$startupLauncherSource = Join-Path $proxyDir 'CLIProxyAPI-Autostart.vbs'
$startupFolder = [Environment]::GetFolderPath('Startup')
$startupLauncherPath = Join-Path $startupFolder 'CLIProxyAPI-Autostart.vbs'
$middleDot = [char]0x00B7
$shortContextDisplayName = "GPT 5.6 Sol $middleDot 272k"
$longContextDisplayName = "GPT 5.6 Sol $middleDot 1.05M"
$modeWasExplicit = $PSBoundParameters.ContainsKey('Mode')

function Get-PersistedMode {
    if (-not (Test-Path -LiteralPath $modePath -PathType Leaf)) { return $null }
    $value = [System.IO.File]::ReadAllText($modePath, [System.Text.Encoding]::UTF8).Trim()
    if ($value -in @('1', '2')) { return [int]$value }
    return $null
}

function Resolve-RoutingMode {
    if ($modeWasExplicit) { return $Mode }
    $saved = Get-PersistedMode
    if ($ValidateOnly) { return $(if ($null -ne $saved) { $saved } else { 1 }) }
    Write-Output 'Select CLIProxyAPI routing mode:'
    Write-Output '  1 = GPT uses Codex App credentials directly; DeepSeek/other proxy models use CLIProxyAPI'
    Write-Output '  2 = GPT, DeepSeek, and other proxy models all use CLIProxyAPI; GPT uses independent OAuth'
    do { $answer = (Read-Host 'Enter 1 or 2').Trim() } while ($answer -notin @('1', '2'))
    return [int]$answer
}

function Write-ModeFile([int]$Value) {
    $temporary = "$modePath.tmp-$PID"
    [System.IO.File]::WriteAllText($temporary, [string]$Value, (New-Object System.Text.UTF8Encoding($false)))
    Move-Item -LiteralPath $temporary -Destination $modePath -Force
}

function Get-ListenerPids([int]$Port) {
    return @(Get-NetTCPConnection -State Listen -LocalAddress '127.0.0.1' -LocalPort $Port -ErrorAction SilentlyContinue |
        Select-Object -ExpandProperty OwningProcess -Unique)
}

function Get-CompatHealth {
    try { return Invoke-RestMethod -TimeoutSec 3 -Uri 'http://127.0.0.1:8318/health' }
    catch { return $null }
}

function Get-ReasoningLevels([object]$Model) {
    return @(
        @($Model.supported_reasoning_levels | ForEach-Object { $_.effort }) +
        @($Model.supported_reasoning_efforts | ForEach-Object { $_.reasoning_effort })
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
}

function New-EnabledConfig([string]$OriginalText, [string]$DefaultModel, [string]$DefaultReasoning) {
    $catalogTomlPath = $catalogPath.Replace('\', '/')
    $desiredSettings = [ordered]@{
        model = "model = `"$DefaultModel`""
        model_reasoning_effort = "model_reasoning_effort = `"$DefaultReasoning`""
        model_provider = 'model_provider = "openai"'
        openai_base_url = 'openai_base_url = "http://127.0.0.1:8318/v1"'
        model_catalog_json = "model_catalog_json = `"$catalogTomlPath`""
        service_tier = 'service_tier = "priority"'
    }
    $lines = [System.Text.RegularExpressions.Regex]::Split($OriginalText, '\r?\n')
    $foundSettings = @{}
    $enabledLines = New-Object 'System.Collections.Generic.List[string]'
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
        if ($skipCLIProxySection) { continue }
        $matched = $false
        if ($insideTopLevel) {
            foreach ($name in $desiredSettings.Keys) {
                if ($line -match ('^\s*' + [Regex]::Escape($name) + '\s*=')) {
                    $enabledLines.Add($desiredSettings[$name])
                    $foundSettings[$name] = $true
                    $matched = $true
                    break
                }
            }
        }
        if (-not $matched) { $enabledLines.Add($line) }
    }
    $missing = @($desiredSettings.Keys | Where-Object { -not $foundSettings.ContainsKey($_) })
    for ($index = $missing.Count - 1; $index -ge 0; $index--) { $enabledLines.Insert(0, $desiredSettings[$missing[$index]]) }
    return ($enabledLines -join "`r`n").TrimEnd() + "`r`n"
}

$selectedMode = Resolve-RoutingMode
$requiredFiles = @(
    $configPath, $keyPath, $startScript, $stopScript, $loginScript, $credentialProtectorPath,
    $runtimeTemplatePath, $compatScriptPath, $clientKeyPath, $startupLauncherSource
)
foreach ($requiredFile in $requiredFiles) {
    if (-not (Test-Path -LiteralPath $requiredFile -PathType Leaf)) { throw "Required file was not found: $requiredFile" }
}
if ([string]::IsNullOrWhiteSpace($nodePath)) { throw 'Node.js was not found on PATH.' }

$deepSeekKey = [System.IO.File]::ReadAllText($keyPath, [System.Text.Encoding]::UTF8).Trim()
if ([string]::IsNullOrWhiteSpace($deepSeekKey)) { throw "DeepSeek API key file is empty: $keyPath" }
$deepSeekKey = $null
$runtimeTemplate = [System.IO.File]::ReadAllText($runtimeTemplatePath, [System.Text.Encoding]::UTF8)
if ($runtimeTemplate -notmatch '(?m)^\s*disable-codex-cloaking:\s*true\s*$' -or
    $runtimeTemplate -notmatch '__LOCAL_PROXY_KEY__' -or $runtimeTemplate -notmatch '__DEEPSEEK_API_KEY__') {
    throw 'CLIProxyAPI runtime template failed safety or placeholder validation.'
}

& $nodePath --check $compatScriptPath
if ($LASTEXITCODE -ne 0) { throw 'Compatibility proxy Node syntax validation failed before enable.' }
$null = & $startScript -ValidateOnly
$oauthFiles = @(Get-ChildItem -LiteralPath $authDir -Filter 'codex-*.json' -File -ErrorAction SilentlyContinue)
if ($ValidateOnly) {
    Write-Output 'CLIProxyAPI enable validation passed; no service or Codex setting was changed.'
    Write-Output "Selected routing mode: $selectedMode"
    Write-Output "Codex OAuth files available for mode 2: $($oauthFiles.Count)"
    Write-Output 'The generated catalog is dynamic; no fixed model slug is required.'
    exit 0
}

if ($selectedMode -eq 2 -and $oauthFiles.Count -eq 0) {
    Write-Output 'Mode 2 requires independent Codex OAuth. Starting the browser login flow...'
    $previousPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    & $loginScript
    $loginExitCode = $LASTEXITCODE
    $ErrorActionPreference = $previousPreference
    if ($loginExitCode -ne 0) { throw 'Codex OAuth login did not complete.' }
    $oauthFiles = @(Get-ChildItem -LiteralPath $authDir -Filter 'codex-*.json' -File -ErrorAction SilentlyContinue)
    if ($oauthFiles.Count -eq 0) { throw 'Codex OAuth login file was not created.' }
}

$configText = [System.IO.File]::ReadAllText($configPath, [System.Text.Encoding]::UTF8)
$configBytes = [System.IO.File]::ReadAllBytes($configPath)
$catalogExisted = Test-Path -LiteralPath $catalogPath -PathType Leaf
$catalogBytes = if ($catalogExisted) { [System.IO.File]::ReadAllBytes($catalogPath) } else { $null }
$modeExisted = Test-Path -LiteralPath $modePath -PathType Leaf
$modeBytes = if ($modeExisted) { [System.IO.File]::ReadAllBytes($modePath) } else { $null }
$startupExisted = Test-Path -LiteralPath $startupLauncherPath -PathType Leaf
$startupBytes = if ($startupExisted) { [System.IO.File]::ReadAllBytes($startupLauncherPath) } else { $null }
$proxyPidsBefore = @(Get-ListenerPids -Port 8317)
$compatPidsBefore = @(Get-ListenerPids -Port 8318)
$backupPath = $null
$transactionStarted = $false

try {
    if (-not (Test-Path -LiteralPath $backupDir -PathType Container)) { New-Item -ItemType Directory -Path $backupDir | Out-Null }
    $timestamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $backupPath = Join-Path $backupDir "config-before-cliproxy-enable-$timestamp.toml"
    Copy-Item -LiteralPath $configPath -Destination $backupPath
    $transactionStarted = $true

    Write-ModeFile -Value $selectedMode
    & $startScript -WaitReady | Out-Host
    $health = Get-CompatHealth
    if ($null -eq $health -or $health.status -ne 'ok' -or [int]$health.mode -ne $selectedMode) {
        throw 'Compatibility proxy health did not report the selected routing mode.'
    }
    if (-not (Test-Path -LiteralPath $catalogPath -PathType Leaf)) { throw "Merged model catalog was not created: $catalogPath" }
    $catalog = [System.IO.File]::ReadAllText($catalogPath, [System.Text.Encoding]::UTF8) | ConvertFrom-Json
    $models = @($catalog.models)
    $modelIds = @($models | ForEach-Object { $_.slug })
    if (@('gpt-5.5', 'gpt-5.4', 'gpt-5.4-mini') | Where-Object { $_ -in $modelIds }) {
        throw 'Generated model catalog still contains a hidden legacy GPT model.'
    }

    $shortGpt = $models | Where-Object { $_.slug -eq 'gpt-5.6-sol' } | Select-Object -First 1
    $longGpt = $models | Where-Object { $_.slug -eq 'gpt-5.6-sol-1m' } | Select-Object -First 1
    if ($null -ne $shortGpt) {
        $shortReasoning = @(Get-ReasoningLevels -Model $shortGpt)
        $longReasoning = @(Get-ReasoningLevels -Model $longGpt)
        if ($null -eq $longGpt -or $shortGpt.display_name -ne $shortContextDisplayName -or
            $longGpt.display_name -ne $longContextDisplayName -or $shortGpt.context_window -ne 272000 -or
            $longGpt.context_window -ne 921000 -or 'max' -notin $shortReasoning -or 'ultra' -notin $shortReasoning -or
            'max' -notin $longReasoning -or 'ultra' -notin $longReasoning -or
            'priority' -notin @($shortGpt.service_tiers | ForEach-Object { $_.id }) -or
            'priority' -notin @($longGpt.service_tiers | ForEach-Object { $_.id }) -or
            $shortGpt.default_service_tier -ne 'priority' -or $longGpt.default_service_tier -ne 'priority') {
            throw 'Conditional GPT-5.6 Sol catalog validation failed.'
        }
    }
    elseif ($null -ne $longGpt) { throw 'Long-context Sol alias exists without an upstream Sol base model.' }

    foreach ($deepSeekId in @('deepseek-v4-flash', 'deepseek-v4-pro')) {
        $deepSeek = $models | Where-Object { $_.slug -eq $deepSeekId } | Select-Object -First 1
        if ($null -eq $deepSeek) { continue }
        if ((@(Get-ReasoningLevels -Model $deepSeek) -join ',') -ne 'low,high,max' -or
            $deepSeek.default_reasoning_level -ne 'high' -or @($deepSeek.service_tiers).Count -ne 0 -or
            @($deepSeek.additional_speed_tiers).Count -ne 0 -or
            -not [string]::IsNullOrWhiteSpace([string]$deepSeek.default_service_tier)) {
            throw "$deepSeekId conditional catalog validation failed."
        }
    }

    $currentModelMatch = [Regex]::Match($configText, '(?m)^model\s*=\s*"([^"]+)"\s*$')
    $currentModel = if ($currentModelMatch.Success) { $currentModelMatch.Groups[1].Value } else { '' }
    if ($null -ne $shortGpt) { $defaultModel = 'gpt-5.6-sol' }
    elseif ($currentModel -in $modelIds) { $defaultModel = $currentModel }
    else {
        $priorityModel = $models | Where-Object { 'priority' -in @($_.service_tiers | ForEach-Object { $_.id }) } | Select-Object -First 1
        $defaultModel = if ($null -ne $priorityModel) { [string]$priorityModel.slug } else { [string]($models | Select-Object -First 1).slug }
    }
    if ([string]::IsNullOrWhiteSpace($defaultModel)) { throw 'Dynamic upstream catalog contains no selectable model.' }
    $defaultModelObject = $models | Where-Object { $_.slug -eq $defaultModel } | Select-Object -First 1
    $availableReasoning = @(Get-ReasoningLevels -Model $defaultModelObject)
    if ('xhigh' -in $availableReasoning) { $defaultReasoning = 'xhigh' }
    elseif (-not [string]::IsNullOrWhiteSpace([string]$defaultModelObject.default_reasoning_level)) { $defaultReasoning = [string]$defaultModelObject.default_reasoning_level }
    elseif ($availableReasoning.Count -gt 0) { $defaultReasoning = [string]$availableReasoning[0] }
    else { $defaultReasoning = 'medium' }

    $enabledText = New-EnabledConfig -OriginalText $configText -DefaultModel $defaultModel -DefaultReasoning $defaultReasoning
    $catalogSettingPattern = '(?m)^model_catalog_json = "' + [Regex]::Escape($catalogPath.Replace('\', '/')) + '"\r?$'
    if ($enabledText -notmatch '(?m)^openai_base_url = "http://127\.0\.0\.1:8318/v1"\r?$' -or
        $enabledText -notmatch $catalogSettingPattern -or
        $enabledText -notmatch '(?m)^service_tier = "priority"\r?$') {
        throw 'Enabled config failed final validation.'
    }
    [System.IO.File]::WriteAllText($configPath, $enabledText, (New-Object System.Text.UTF8Encoding($false)))
    Copy-Item -LiteralPath $startupLauncherSource -Destination $startupLauncherPath -Force
}
catch {
    $originalError = $_
    if ($transactionStarted) {
        try {
            [System.IO.File]::WriteAllBytes($configPath, $configBytes)
            if ($catalogExisted) { [System.IO.File]::WriteAllBytes($catalogPath, $catalogBytes) }
            elseif (Test-Path -LiteralPath $catalogPath) { Remove-Item -LiteralPath $catalogPath -Force }
            if ($modeExisted) { [System.IO.File]::WriteAllBytes($modePath, $modeBytes) }
            elseif (Test-Path -LiteralPath $modePath) { Remove-Item -LiteralPath $modePath -Force }
            if ($startupExisted) { [System.IO.File]::WriteAllBytes($startupLauncherPath, $startupBytes) }
            elseif (Test-Path -LiteralPath $startupLauncherPath) { Remove-Item -LiteralPath $startupLauncherPath -Force }
            if ($null -ne $backupPath -and (Test-Path -LiteralPath $backupPath)) { Remove-Item -LiteralPath $backupPath -Force }
            if ($proxyPidsBefore.Count -eq 0 -and @(Get-ListenerPids -Port 8317).Count -gt 0) { & $stopScript | Out-Host }
            elseif ($compatPidsBefore.Count -eq 0 -and @(Get-ListenerPids -Port 8318).Count -gt 0) { & $stopScript -CompatOnly | Out-Host }
        }
        catch { Write-Warning "Enable rollback was incomplete: $($_.Exception.Message)" }
    }
    throw $originalError
}

Write-Output ''
Write-Output "CLIProxyAPI enabled in routing mode ${selectedMode}:"
if ($selectedMode -eq 1) {
    Write-Output '  GPT = Codex App credentials, official ChatGPT/Codex direct through 8318'
    Write-Output '  Missing native GPT credentials = explicit 401; no fallback to 8317'
}
else {
    Write-Output '  GPT = CLIProxyAPI 8317 independent OAuth through 8318'
}
Write-Output '  DeepSeek/other proxy models = CLIProxyAPI 8317 through 8318'
Write-Output '  model catalog = dynamic; Sol 272k/1.05M and DeepSeek transforms are conditional'
Write-Output '  default speed = Fast (service_tier = priority)'
Write-Output "  persisted mode = $modePath"
Write-Output "  pre-enable config backup = $backupPath"
if (-not $NoRestart) {
    if (-not (Test-Path -LiteralPath $restartScript -PathType Leaf)) { throw "Codex restart helper was not found: $restartScript" }
    Start-Process -FilePath 'powershell.exe' -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $restartScript,
        '-Worker', '-Workspace', $Workspace
    ) -WindowStyle Hidden
    Write-Output 'Codex App restart scheduled.'
}
else { Write-Output 'Automatic restart skipped because -NoRestart was specified.' }
