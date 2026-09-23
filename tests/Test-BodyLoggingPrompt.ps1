$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot '..\scripts\Enable-CLIProxyAPI.ps1'
$source = Get-Content -LiteralPath $scriptPath -Raw -Encoding UTF8
$start = $source.IndexOf("if (-not `$PSBoundParameters.ContainsKey('BodyLogging'))")
$end = $source.IndexOf('$bodyLoggingPath =', $start)
if ($start -lt 0 -or $end -lt 0) { throw 'Body logging prompt block not found.' }
$block = $source.Substring($start, $end - $start)
$probe = [scriptblock]::Create("param([ValidateSet('y','n')][string]`$BodyLogging)`n" + $block + "`n`$bodyLoggingValue")
function Read-Host { param($Prompt) return $script:answer }
foreach ($case in @(
    @{ Answer = ''; Expected = 'disabled' },
    @{ Answer = '   '; Expected = 'disabled' },
    @{ Answer = 'n'; Expected = 'disabled' },
    @{ Answer = 'N'; Expected = 'disabled' },
    @{ Answer = 'no'; Expected = 'disabled' },
    @{ Answer = 'y'; Expected = 'enabled' },
    @{ Answer = 'Y'; Expected = 'enabled' },
    @{ Answer = 'yes'; Expected = 'enabled' },
    @{ Answer = 'unknown'; Expected = 'disabled' }
)) {
    $script:answer = $case.Answer
    $actual = & $probe
    if ($actual -ne $case.Expected) { throw "Unexpected result for input '$($case.Answer)': $actual" }
}
function Read-Host { throw 'Explicit parameter must not prompt.' }
if ((& $probe -BodyLogging y) -ne 'enabled') { throw 'Explicit y failed.' }
if ((& $probe -BodyLogging n) -ne 'disabled') { throw 'Explicit n failed.' }
Write-Output 'Body logging prompt passed: 9 interactive inputs and 2 explicit parameters; no services started.'
