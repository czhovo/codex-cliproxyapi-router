[CmdletBinding()]
param(
    [switch]$DeviceCode
)

$ErrorActionPreference = 'Stop'
$installDir = $PSScriptRoot
$exePath = Join-Path $installDir 'cli-proxy-api.exe'
$credentialProtectorPath = Join-Path $installDir 'Protect-CLIProxyAPICredentials.ps1'
$runtimePath = & (Join-Path $installDir 'New-RuntimeConfig.ps1')

$savedPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
$versionOutput = @(& $exePath --help 2>&1 | ForEach-Object { [string]$_ })
$ErrorActionPreference = $savedPreference
$versionLine = $versionOutput | Where-Object { $_ -match '^CLIProxyAPI Version:' } | Select-Object -First 1
if ($versionLine -notmatch 'Version:\s*7\.2\.119\b') {
    throw 'Codex OAuth login requires the fixed CLIProxyAPI 7.2.119 executable.'
}

$arguments = @('-config', $runtimePath)
if ($DeviceCode) {
    $arguments += '-codex-device-login'
}
else {
    $arguments += '-codex-login'
}

$loginExitCode = 1
try {
    & $exePath @arguments
    $loginExitCode = $LASTEXITCODE
}
finally {
    # OAuth refresh and login can create or replace token files. Reapply the
    # password-equivalent ACL immediately after the login process exits.
    $null = & $credentialProtectorPath
}

exit $loginExitCode
