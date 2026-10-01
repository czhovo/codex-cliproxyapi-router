$ErrorActionPreference = 'Stop'
$source = Get-Content (Join-Path $PSScriptRoot '..\scripts\Update-CodexModelCatalog.ps1') -Raw -Encoding UTF8
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$parseErrors)
foreach ($name in @('Set-ModelProperty', 'Get-ReasoningLevels')) {
    $functionAst = $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq $name }, $true)
    . ([scriptblock]::Create($functionAst.Extent.Text))
}
# Execute the production transformation and validations, without network or disk writes.
$start = $source.IndexOf('# Until native entries arrive')
$end = $source.IndexOf('$catalogJson =', $start)
if ($start -lt 0 -or $end -lt 0) { throw 'Catalog transformation block not found.' }
$transform = [scriptblock]::Create($source.Substring($start, $end - $start) + "`nreturn `$catalog")
function New-Model($slug) {
    [pscustomobject]@{
        slug = $slug; context_window = 300000; max_context_window = 300000
        supported_reasoning_levels = @([pscustomobject]@{effort='high'})
        service_tiers = @([pscustomobject]@{id='priority';name='Fast'})
        additional_speed_tiers = @('fast'); default_reasoning_level = 'high'
    }
}
function Build($entries) {
    $catalog = [pscustomobject]@{models=@($entries)}
    & $transform
}
$legacy = @('gpt-6-astra','gpt-5.6-sol','gpt-5.6-terra','gpt-5.6-luna','deepseek-v4.1-flash','deepseek-v4.1-pro') | ForEach-Object { New-Model $_ }
$result = Build $legacy
$expected = 'gpt-6-astra,gpt-6-astra-1m,gpt-6.1-sol,gpt-6-luna,deepseek-v4.1-flash,deepseek-v4.1-pro'
if (($result.models.slug -join ',') -ne $expected) { throw 'Picker order or fallback failed.' }
if ((@($result.models | Sort-Object priority).slug -join ',') -ne $expected -or ($result.models.priority -join ',') -ne '0,1,2,3,4,5') { throw 'Numeric picker priorities failed.' }
foreach ($slug in @('gpt-6.1-sol','gpt-6-luna')) {
    $model = $result.models | Where-Object slug -eq $slug
    if ($model.context_window -ne 272000 -or $model.default_service_tier -ne 'priority') { throw 'Fallback metadata failed.' }
}
$native = @('gpt-6.1-sol','gpt-6-luna') | ForEach-Object { $m=New-Model $_; $m.context_window=400000; $m.max_context_window=400000; $m }
$result = Build (@($legacy) + @($native))
foreach ($slug in @('gpt-6.1-sol','gpt-6-luna')) {
    $matches = @($result.models | Where-Object slug -eq $slug)
    if ($matches.Count -ne 1 -or $matches[0].context_window -ne 400000 -or ($matches[0].supported_reasoning_levels.effort -join ',') -ne 'high') { throw 'Native metadata was overwritten.' }
}
$result = Build @((New-Model 'deepseek-v4.1-flash'))
if (($result.models.slug -join ',') -ne 'deepseek-v4.1-flash') { throw 'Missing GPT must not create fallback models.' }
$predecessor = New-Model 'gpt-6-sol'
$predecessor.supported_reasoning_levels = @([pscustomobject]@{effort='low'})
$result = Build (@($legacy) + @($predecessor))
$sol = $result.models | Where-Object slug -eq 'gpt-6.1-sol'
if (($sol.supported_reasoning_levels.effort -join ',') -ne 'low' -or 'gpt-6-sol' -in $result.models.slug) { throw 'Sol 6.1 must prefer Sol 6 over 5.6 and replace its picker entry.' }
$result = Build @((New-Model 'gpt-5.6-luna'))
if (($result.models.slug -join ',') -ne 'gpt-6-astra,gpt-6-astra-1m,gpt-6-luna') { throw 'Luna-only fallback failed.' }
$sortStart = $source.IndexOf('$familyOrder =')
$sortEnd = $source.IndexOf('Set-ModelProperty -Model $catalog -Name', $sortStart)
$pickerModels = New-Object 'System.Collections.Generic.List[object]'
foreach ($slug in @('gpt-9-luna','gpt-8-terra','gpt-7-sol','gpt-6-astra')) { $pickerModels.Add((New-Model $slug)) }
$sorted = & ([scriptblock]::Create($source.Substring($sortStart, $sortEnd - $sortStart) + "`nreturn `$models"))
if (($sorted.slug -join ',') -ne 'gpt-6-astra,gpt-7-sol,gpt-8-terra,gpt-9-luna') { throw 'Family must take precedence over version.' }
Write-Output 'Windows catalog passed: legacy fallback, native metadata, family-first numeric ordering, Astra variants, and DeepSeek-only catalog.'
