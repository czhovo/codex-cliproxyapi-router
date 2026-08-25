[CmdletBinding()]
param(
    [string]$OutputPath = (Join-Path $PSScriptRoot 'config.runtime.yaml'),
    [int]$Port = 8317,
    [switch]$SkipAcl
)

$ErrorActionPreference = 'Stop'
$installDir = $PSScriptRoot
$templatePath = Join-Path $installDir 'config.template.yaml'
$runtimePath = [System.IO.Path]::GetFullPath($OutputPath)
$clientKeyPath = Join-Path $installDir 'client-key.txt'
$codexHome = Join-Path $env:USERPROFILE '.codex'
$deepSeekKeyPath = Join-Path $codexHome 'deepseek_api_key.txt'
$protectorPath = Join-Path $installDir 'Protect-CLIProxyAPICredentials.ps1'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

if (-not (Test-Path -LiteralPath $deepSeekKeyPath -PathType Leaf)) {
    throw "DeepSeek API key file not found: $deepSeekKeyPath"
}
if (-not (Test-Path -LiteralPath $clientKeyPath -PathType Leaf)) {
    $bytes = New-Object byte[] 32
    $generator = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $generator.GetBytes($bytes)
    }
    finally {
        $generator.Dispose()
    }
    $generated = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
    [System.IO.File]::WriteAllText($clientKeyPath, "codex-local-$generated", $utf8NoBom)
}

$deepSeekKey = [System.IO.File]::ReadAllText($deepSeekKeyPath, [System.Text.Encoding]::UTF8).Trim()
$clientKey = [System.IO.File]::ReadAllText($clientKeyPath, [System.Text.Encoding]::UTF8).Trim()
if ($deepSeekKey -notmatch '^sk-[A-Za-z0-9_-]{16,}$') {
    throw "DeepSeek API key file does not contain a valid-looking key: $deepSeekKeyPath"
}
if ($clientKey.Length -lt 32) {
    throw 'Local CLIProxyAPI client key is invalid.'
}
if ($Port -lt 1 -or $Port -gt 65535) {
    throw 'Runtime port is outside the valid TCP range.'
}

$template = [System.IO.File]::ReadAllText($templatePath, [System.Text.Encoding]::UTF8)
foreach ($placeholder in @('__DEEPSEEK_API_KEY__', '__LOCAL_PROXY_KEY__', '__AUTH_DIR__')) {
    if (-not $template.Contains($placeholder)) { throw "Runtime template is missing $placeholder." }
}
if ($template -notmatch '(?m)^disable-cooling:\s*true\s*$' -or
    $template -notmatch '(?m)^\s*disable-codex-cloaking:\s*true\s*$') {
    throw 'Runtime template must disable credential cooling and Codex cloaking.'
}

$authDirectory = (Join-Path $installDir 'auth').Replace('\', '/').Replace('"', '\"')
$runtime = $template.Replace('__DEEPSEEK_API_KEY__', $deepSeekKey).
    Replace('__LOCAL_PROXY_KEY__', $clientKey).
    Replace('__AUTH_DIR__', $authDirectory)
$runtime = [Regex]::Replace($runtime, '(?m)^port:\s*8317\s*$', "port: $Port")
if ($runtime -notmatch "(?m)^port:\s*$Port\s*$") {
    throw 'Runtime port substitution failed.'
}
[System.IO.File]::WriteAllText($runtimePath, $runtime, $utf8NoBom)
$deepSeekKey = $null
$clientKey = $null
$runtime = $null

if (-not $SkipAcl) {
    $null = & $protectorPath -AdditionalFiles @($deepSeekKeyPath, $clientKeyPath, $runtimePath)
}
Write-Output $runtimePath
