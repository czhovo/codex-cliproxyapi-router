[CmdletBinding()]
param(
    [string]$CatalogUri = 'http://127.0.0.1:8318/v1/models?client_version=0.146.0-alpha.9.2',
    [string]$OutputPath = (Join-Path (Join-Path $env:USERPROFILE '.codex') 'cliproxy-model-catalog.json')
)

$ErrorActionPreference = 'Stop'
$clientKeyPath = Join-Path $PSScriptRoot 'client-key.txt'
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

$response = Invoke-WebRequest -UseBasicParsing -TimeoutSec 15 -Headers $headers -Uri $CatalogUri
$clientKey = $null
$catalog = $response.Content | ConvertFrom-Json
if ($null -eq $catalog -or $null -eq $catalog.models) { throw 'Upstream model catalog does not contain a models array.' }

$hiddenPickerModelIds = @('gpt-5.5', 'gpt-5.4', 'gpt-5.4-mini')
$longContextModelId = 'gpt-5.6-sol-1m'
$middleDot = [char]0x00B7
$shortContextDisplayName = "GPT 5.6 Sol $middleDot 272k"
$longContextDisplayName = "GPT 5.6 Sol $middleDot 1.05M"
$sourceModels = @(
    $catalog.models | Where-Object {
        $_.slug -notin $hiddenPickerModelIds -and $_.slug -ne $longContextModelId
    }
)

$deepSeekReasoningLevels = [object[]]@(
    [pscustomobject]@{ effort = 'low'; description = 'Fast responses with lighter reasoning' }
    [pscustomobject]@{ effort = 'high'; description = 'Greater reasoning depth for complex problems' }
    [pscustomobject]@{ effort = 'max'; description = 'Maximum reasoning depth for the hardest problems' }
)

$pickerModels = New-Object 'System.Collections.Generic.List[object]'
foreach ($model in $sourceModels) {
    Set-ModelProperty -Model $model -Name 'prefer_websockets' -Value $false
    Set-ModelProperty -Model $model -Name 'supports_reasoning_summaries' -Value $true

    if ($model.slug -eq 'gpt-5.6-sol') {
        $gptReasoning = @(Get-ReasoningLevels -Model $model)
        $gptTierIds = @($model.service_tiers | ForEach-Object { $_.id })
        if ('max' -notin $gptReasoning -or 'ultra' -notin $gptReasoning) {
            throw 'Upstream gpt-5.6-sol exists but does not expose max and ultra reasoning.'
        }
        if ('priority' -notin $gptTierIds) {
            throw 'Upstream gpt-5.6-sol exists but does not expose Fast/priority.'
        }

        $longContextModel = $model | ConvertTo-Json -Depth 100 | ConvertFrom-Json
        Set-ModelProperty -Model $model -Name 'display_name' -Value $shortContextDisplayName
        Set-ModelProperty -Model $model -Name 'context_window' -Value 272000
        Set-ModelProperty -Model $model -Name 'max_context_window' -Value 272000
        Set-ModelProperty -Model $model -Name 'default_service_tier' -Value 'priority'

        Set-ModelProperty -Model $longContextModel -Name 'slug' -Value $longContextModelId
        Set-ModelProperty -Model $longContextModel -Name 'display_name' -Value $longContextDisplayName
        Set-ModelProperty -Model $longContextModel -Name 'description' -Value 'GPT-5.6 Sol with the 1.05M total context window.'
        Set-ModelProperty -Model $longContextModel -Name 'context_window' -Value 921000
        Set-ModelProperty -Model $longContextModel -Name 'max_context_window' -Value 921000
        Set-ModelProperty -Model $longContextModel -Name 'default_service_tier' -Value 'priority'
        Set-ModelProperty -Model $longContextModel -Name 'prefer_websockets' -Value $false

        $pickerModels.Add($model)
        $pickerModels.Add($longContextModel)
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
if (@($hiddenPickerModelIds | Where-Object { $_ -in $pickerIds }).Count -ne 0) {
    throw 'A hidden legacy GPT model remains in the generated catalog.'
}

$sourceHasSol = @($sourceModels | Where-Object { $_.slug -eq 'gpt-5.6-sol' }).Count -gt 0
$shortContextGpt = $models | Where-Object { $_.slug -eq 'gpt-5.6-sol' } | Select-Object -First 1
$longContextGpt = $models | Where-Object { $_.slug -eq $longContextModelId } | Select-Object -First 1
if ($sourceHasSol) {
    if ($null -eq $shortContextGpt -or $null -eq $longContextGpt -or
        $shortContextGpt.display_name -ne $shortContextDisplayName -or
        $shortContextGpt.context_window -ne 272000 -or
        $longContextGpt.display_name -ne $longContextDisplayName -or
        $longContextGpt.context_window -ne 921000 -or
        $shortContextGpt.default_service_tier -ne 'priority' -or
        $longContextGpt.default_service_tier -ne 'priority') {
        throw 'Dynamic GPT-5.6 Sol context variants failed validation.'
    }
}
elseif ($null -ne $shortContextGpt -or $null -ne $longContextGpt) {
    throw 'GPT-5.6 Sol variants were generated without an upstream base model.'
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
