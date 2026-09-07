[CmdletBinding()]
param(
    [string]$CatalogUri = 'http://127.0.0.1:8318/v1/models?client_version=0.146.0-alpha.9.2',
    [string]$OutputPath = (Join-Path (Join-Path $env:USERPROFILE '.codex') 'cliproxy-model-catalog.json')
)

$ErrorActionPreference = 'Stop'
$clientKeyPath = Join-Path $PSScriptRoot 'client-key.txt'
$routingModePath = Join-Path $PSScriptRoot 'routing-mode.txt'
$catalogPath = [System.IO.Path]::GetFullPath($OutputPath)
$clientKey = [System.IO.File]::ReadAllText($clientKeyPath, [System.Text.Encoding]::UTF8).Trim()
$headers = @{ Authorization = "Bearer $clientKey" }

function Set-ModelProperty([object]$Model, [string]$Name, [object]$Value) {
    if ($Model.PSObject.Properties.Name -contains $Name) { $Model.$Name = $Value }
    else { $Model | Add-Member -NotePropertyName $Name -NotePropertyValue $Value }
}

function Get-ReasoningLevels([object]$Model) {
    return @(
        @($Model.supported_reasoning_levels | ForEach-Object { $_.effort }) +
        @($Model.supported_reasoning_efforts | ForEach-Object { $_.reasoning_effort })
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
}

function Resolve-CodexAppExecutable {
    $appBinRoot = Join-Path $env:LOCALAPPDATA 'OpenAI\Codex\bin'
    if (Test-Path -LiteralPath $appBinRoot -PathType Container) {
        $candidate = Get-ChildItem -LiteralPath $appBinRoot -Filter 'codex.exe' -File -Recurse |
            Sort-Object LastWriteTimeUtc -Descending |
            Select-Object -First 1
        if ($null -ne $candidate) { return $candidate.FullName }
    }
    $pathCandidate = Get-Command 'codex.exe' -CommandType Application -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if ($null -ne $pathCandidate) { return $pathCandidate.Source }
    throw 'Codex App codex.exe was not found for the mode 1 official model catalog.'
}

$response = Invoke-WebRequest -UseBasicParsing -TimeoutSec 15 -Headers $headers -Uri $CatalogUri
$clientKey = $null
$catalog = $response.Content | ConvertFrom-Json
if ($null -eq $catalog -or $null -eq $catalog.models) { throw 'Upstream model catalog does not contain a models array.' }

$routingMode = if (Test-Path -LiteralPath $routingModePath -PathType Leaf) {
    [System.IO.File]::ReadAllText($routingModePath, [System.Text.Encoding]::UTF8).Trim()
}
else { '1' }
if ($routingMode -notin @('1', '2')) { throw 'Persisted routing mode must be 1 or 2.' }
if ($routingMode -eq '1') {
    $codexExecutable = Resolve-CodexAppExecutable
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $officialOutput = @(& $codexExecutable debug models --bundled 2>&1 | ForEach-Object { [string]$_ })
    $officialExitCode = $LASTEXITCODE
    $ErrorActionPreference = $savedPreference
    if ($officialExitCode -ne 0) { throw 'Unable to read the bundled official Codex model catalog for mode 1.' }
    $officialCatalog = ($officialOutput -join "`n") | ConvertFrom-Json
    if ($null -eq $officialCatalog -or $null -eq $officialCatalog.models) {
        throw 'Bundled official Codex model catalog does not contain a models array.'
    }
    $officialIds = @($officialCatalog.models | ForEach-Object { [string]$_.slug })
    $proxyOnlyModels = @(
        $catalog.models | Where-Object {
            -not ([string]$_.slug).StartsWith('gpt-') -and ([string]$_.slug) -notin $officialIds
        }
    )
    Set-ModelProperty -Model $officialCatalog -Name 'models' -Value ([object[]]@($officialCatalog.models + $proxyOnlyModels))
    $catalog = $officialCatalog
}

$visibleSourceModelIds = @(
    'gpt-6-astra', 'gpt-5.6-sol', 'gpt-5.6-terra', 'gpt-5.6-luna', 'gpt-5.3-codex-spark',
    'deepseek-v4-flash', 'deepseek-v4-pro'
)
$astraModelId = 'gpt-6-astra'
$astraLongContextModelId = 'gpt-6-astra-1m'
$solModelId = 'gpt-5.6-sol'
$removedSolLongContextModelId = 'gpt-5.6-sol-1m'
$middleDot = [char]0x00B7
$astraShortContextDisplayName = "GPT 6 Astra $middleDot 272k"
$astraLongContextDisplayName = "GPT 6 Astra $middleDot 1.05M"
$solDisplayName = 'GPT 5.6 Sol'
$sourceModels = @(
    foreach ($modelId in $visibleSourceModelIds) {
        $catalog.models | Where-Object { $_.slug -eq $modelId } | Select-Object -First 1
    }
) | Where-Object { $null -ne $_ }

# Keep Astra available when an older upstream catalog has another GPT model but
# predates the Astra entry. Both routing modes still use the real Astra model ID.
if (@($sourceModels | Where-Object { $_.slug -eq $astraModelId }).Count -eq 0) {
    $astraTemplate = $sourceModels | Where-Object { $_.slug -eq $solModelId } | Select-Object -First 1
    if ($null -eq $astraTemplate) {
        $astraTemplate = $sourceModels | Where-Object { [string]$_.slug -like 'gpt-*' } | Select-Object -First 1
    }
    if ($null -ne $astraTemplate) {
        $astraModel = $astraTemplate | ConvertTo-Json -Depth 100 | ConvertFrom-Json
        Set-ModelProperty -Model $astraModel -Name 'slug' -Value $astraModelId
        Set-ModelProperty -Model $astraModel -Name 'display_name' -Value 'GPT 6 Astra'
        Set-ModelProperty -Model $astraModel -Name 'description' -Value 'GPT-6 Astra. Our most capable model for the hardest end-to-end work.'
        Set-ModelProperty -Model $astraModel -Name 'default_reasoning_level' -Value 'medium'
        $fallbackReasoning = [object[]]@(
            foreach ($effort in @('low', 'medium', 'high', 'xhigh', 'max', 'ultra')) {
                $sourceLevel = @($astraTemplate.supported_reasoning_levels | Where-Object { $_.effort -eq $effort }) | Select-Object -First 1
                $description = if ($null -ne $sourceLevel -and -not [string]::IsNullOrWhiteSpace([string]$sourceLevel.description)) {
                    [string]$sourceLevel.description
                }
                elseif ($effort -eq 'ultra') { 'Maximum reasoning with automatic task delegation' }
                else { $effort }
                [pscustomobject]@{ effort = $effort; description = $description }
            }
        )
        Set-ModelProperty -Model $astraModel -Name 'supported_reasoning_levels' -Value $fallbackReasoning
        Set-ModelProperty -Model $astraModel -Name 'context_window' -Value 921000
        Set-ModelProperty -Model $astraModel -Name 'max_context_window' -Value 921000
        Set-ModelProperty -Model $astraModel -Name 'effective_context_window_percent' -Value 95
        Set-ModelProperty -Model $astraModel -Name 'auto_compact_token_limit' -Value $null
        Set-ModelProperty -Model $astraModel -Name 'default_service_tier' -Value 'default'
        $sourceModels = @($astraModel) + @($sourceModels)
    }
}

$displayNames = @{
    'gpt-5.6-terra' = 'GPT 5.6 Terra'
    'gpt-5.6-luna' = 'GPT 5.6 Luna'
    'gpt-5.3-codex-spark' = 'GPT 5.3 Codex Spark'
    'deepseek-v4-flash' = 'DeepSeek V4 Flash'
    'deepseek-v4-pro' = 'DeepSeek V4 Pro'
}

$deepSeekReasoningLevels = [object[]]@(
    [pscustomobject]@{ effort = 'low'; description = 'Fast responses with lighter reasoning' }
    [pscustomobject]@{ effort = 'high'; description = 'Greater reasoning depth for complex problems' }
    [pscustomobject]@{ effort = 'max'; description = 'Maximum reasoning depth for the hardest problems' }
)

$pickerModels = New-Object 'System.Collections.Generic.List[object]'
foreach ($model in $sourceModels) {
    Set-ModelProperty -Model $model -Name 'prefer_websockets' -Value $false
    Set-ModelProperty -Model $model -Name 'supports_reasoning_summaries' -Value $true
    if ($displayNames.ContainsKey([string]$model.slug)) {
        Set-ModelProperty -Model $model -Name 'display_name' -Value $displayNames[[string]$model.slug]
    }

    if ($model.slug -eq $astraModelId) {
        $astraReasoningLevels = New-Object 'System.Collections.Generic.List[object]'
        foreach ($level in @($model.supported_reasoning_levels)) { $astraReasoningLevels.Add($level) }
        if ('ultra' -notin @($model.supported_reasoning_levels | ForEach-Object { $_.effort })) {
            $astraReasoningLevels.Add([pscustomobject]@{
                effort = 'ultra'
                description = 'Maximum reasoning with automatic task delegation'
            })
        }
        Set-ModelProperty -Model $model -Name 'supported_reasoning_levels' -Value ([object[]]$astraReasoningLevels.ToArray())

        $longContextModel = $model | ConvertTo-Json -Depth 100 | ConvertFrom-Json
        Set-ModelProperty -Model $model -Name 'display_name' -Value $astraShortContextDisplayName
        Set-ModelProperty -Model $model -Name 'context_window' -Value 272000
        Set-ModelProperty -Model $model -Name 'max_context_window' -Value 272000
        Set-ModelProperty -Model $model -Name 'effective_context_window_percent' -Value 95
        Set-ModelProperty -Model $model -Name 'auto_compact_token_limit' -Value $null

        Set-ModelProperty -Model $longContextModel -Name 'slug' -Value $astraLongContextModelId
        Set-ModelProperty -Model $longContextModel -Name 'display_name' -Value $astraLongContextDisplayName
        Set-ModelProperty -Model $longContextModel -Name 'context_window' -Value 921000
        Set-ModelProperty -Model $longContextModel -Name 'max_context_window' -Value 921000
        Set-ModelProperty -Model $longContextModel -Name 'effective_context_window_percent' -Value 95
        Set-ModelProperty -Model $longContextModel -Name 'auto_compact_token_limit' -Value $null

        $pickerModels.Add($model)
        $pickerModels.Add($longContextModel)
        continue
    }

    if ($model.slug -eq $solModelId) {
        $gptReasoning = @(Get-ReasoningLevels -Model $model)
        $gptTierIds = @($model.service_tiers | ForEach-Object { $_.id })
        if ('max' -notin $gptReasoning -or 'ultra' -notin $gptReasoning) {
            throw 'Upstream gpt-5.6-sol exists but does not expose max and ultra reasoning.'
        }
        if ('priority' -notin $gptTierIds) {
            throw 'Upstream gpt-5.6-sol exists but does not expose Fast/priority.'
        }

        Set-ModelProperty -Model $model -Name 'display_name' -Value $solDisplayName
        Set-ModelProperty -Model $model -Name 'context_window' -Value 272000
        Set-ModelProperty -Model $model -Name 'max_context_window' -Value 272000
        Set-ModelProperty -Model $model -Name 'default_service_tier' -Value 'priority'

        $pickerModels.Add($model)
        continue
    }

    if ($model.slug -in @('deepseek-v4-flash', 'deepseek-v4-pro')) {
        Set-ModelProperty -Model $model -Name 'context_window' -Value 1000000
        Set-ModelProperty -Model $model -Name 'max_context_window' -Value 1000000
        Set-ModelProperty -Model $model -Name 'effective_context_window_percent' -Value 95
        Set-ModelProperty -Model $model -Name 'auto_compact_token_limit' -Value $null
        Set-ModelProperty -Model $model -Name 'default_reasoning_level' -Value 'high'
        Set-ModelProperty -Model $model -Name 'supported_reasoning_levels' -Value $deepSeekReasoningLevels
        Set-ModelProperty -Model $model -Name 'supported_reasoning_efforts' -Value ([object[]]@())
        Set-ModelProperty -Model $model -Name 'service_tiers' -Value ([object[]]@())
        Set-ModelProperty -Model $model -Name 'additional_speed_tiers' -Value ([object[]]@())
        Set-ModelProperty -Model $model -Name 'default_service_tier' -Value $null
    }

    $pickerModels.Add($model)
}

$models = [object[]]$pickerModels.ToArray()
Set-ModelProperty -Model $catalog -Name 'models' -Value $models
$pickerIds = @($models | ForEach-Object { $_.slug })
$visiblePickerModelIds = @(
    'gpt-6-astra', 'gpt-6-astra-1m', 'gpt-5.6-sol', 'gpt-5.6-terra', 'gpt-5.6-luna',
    'gpt-5.3-codex-spark', 'deepseek-v4-flash', 'deepseek-v4-pro'
)
if (@($pickerIds | Where-Object { $_ -notin $visiblePickerModelIds }).Count -ne 0) {
    throw 'A model outside the supported picker list remains in the generated catalog.'
}

$astraShortContext = $models | Where-Object { $_.slug -eq $astraModelId } | Select-Object -First 1
$astraLongContext = $models | Where-Object { $_.slug -eq $astraLongContextModelId } | Select-Object -First 1
if ($null -ne $astraShortContext) {
    if ($null -eq $astraLongContext -or
        $astraShortContext.display_name -ne $astraShortContextDisplayName -or
        $astraLongContext.display_name -ne $astraLongContextDisplayName -or
        $astraShortContext.context_window -ne 272000 -or
        $astraLongContext.context_window -ne 921000 -or
        'ultra' -notin @(Get-ReasoningLevels -Model $astraShortContext) -or
        'ultra' -notin @(Get-ReasoningLevels -Model $astraLongContext)) {
        throw 'Dynamic GPT-6 Astra context variants failed validation.'
    }
}
elseif ($null -ne $astraLongContext) {
    throw 'Long-context Astra alias exists without an Astra base model.'
}

$sourceHasSol = @($sourceModels | Where-Object { $_.slug -eq $solModelId }).Count -gt 0
$solModel = $models | Where-Object { $_.slug -eq $solModelId } | Select-Object -First 1
if ($sourceHasSol) {
    if ($null -eq $solModel -or $solModel.display_name -ne $solDisplayName -or
        $solModel.context_window -ne 272000 -or $solModel.default_service_tier -ne 'priority' -or
        $removedSolLongContextModelId -in $pickerIds) {
        throw 'Dynamic GPT-5.6 Sol model failed validation.'
    }
}
elseif ($null -ne $solModel -or $removedSolLongContextModelId -in $pickerIds) {
    throw 'GPT-5.6 Sol was generated without an upstream base model.'
}

foreach ($deepSeekId in @('deepseek-v4-flash', 'deepseek-v4-pro')) {
    $deepSeekModel = $models | Where-Object { $_.slug -eq $deepSeekId } | Select-Object -First 1
    if ($null -eq $deepSeekModel) { continue }
    $actualReasoning = @(Get-ReasoningLevels -Model $deepSeekModel)
    if (($actualReasoning -join ',') -ne 'low,high,max' -or
        $deepSeekModel.default_reasoning_level -ne 'high' -or
        $deepSeekModel.context_window -ne 1000000 -or
        $deepSeekModel.effective_context_window_percent -ne 95 -or
        @($deepSeekModel.service_tiers).Count -ne 0 -or
        @($deepSeekModel.additional_speed_tiers).Count -ne 0 -or
        -not [string]::IsNullOrWhiteSpace([string]$deepSeekModel.default_service_tier) -or
        $deepSeekModel.prefer_websockets -ne $false) {
        throw "$deepSeekId dynamic catalog compatibility validation failed."
    }
}

$catalogJson = $catalog | ConvertTo-Json -Depth 100
$tempPath = "$catalogPath.tmp-$PID"
[System.IO.File]::WriteAllText($tempPath, $catalogJson, (New-Object System.Text.UTF8Encoding($false)))
Move-Item -LiteralPath $tempPath -Destination $catalogPath -Force
Write-Output $catalogPath
