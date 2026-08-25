[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$installDir = $PSScriptRoot
$clientKeyPath = Join-Path $installDir 'client-key.txt'
if (-not (Test-Path -LiteralPath $clientKeyPath -PathType Leaf)) {
    throw 'Local CLIProxyAPI client key has not been generated. Run New-RuntimeConfig.ps1 first.'
}
$clientKey = [System.IO.File]::ReadAllText($clientKeyPath, [System.Text.Encoding]::UTF8).Trim()
if ($clientKey.Length -lt 32) { throw 'Local CLIProxyAPI client key is invalid.' }

try {
    $headers = @{ Authorization = "Bearer $clientKey" }
    $null = Invoke-WebRequest -UseBasicParsing -TimeoutSec 2 -Headers $headers -Uri 'http://127.0.0.1:8318/v1/models'
}
catch {
    $null = & (Join-Path $installDir 'Start-CLIProxyAPI.ps1') -WaitReady
}

Write-Output $clientKey
