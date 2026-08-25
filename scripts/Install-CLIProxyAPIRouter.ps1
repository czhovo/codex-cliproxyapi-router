[CmdletBinding()]
param(
    [switch]$SkipDesktopLaunchers,
    [string]$ArchivePath
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)

$cliProxyVersion = '7.2.119'
$archiveName = "CLIProxyAPI_${cliProxyVersion}_windows_amd64.zip"
$expectedSha256 = '1518a0ffc4f89b609c091f9302c9e3045cffa27e32a4c49f9d211f051de78688'
$downloadUri = "https://github.com/router-for-me/CLIProxyAPI/releases/download/v${cliProxyVersion}/$archiveName"
$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$codexHome = Join-Path $env:USERPROFILE '.codex'
$toolDirectory = Join-Path $codexHome 'tools\cliproxyapi'
$deepSeekKeyPath = Join-Path $codexHome 'deepseek_api_key.txt'
$clientKeyPath = Join-Path $toolDirectory 'client-key.txt'
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

if ($env:OS -ne 'Windows_NT') { throw 'This installer currently supports Windows only.' }
if ([Environment]::Is64BitOperatingSystem -ne $true) { throw 'The pinned package requires 64-bit Windows.' }
if ($null -eq (Get-Command 'node.exe' -CommandType Application -ErrorAction SilentlyContinue)) {
    throw 'Node.js was not found on PATH. Install a current Node.js LTS release first.'
}

$sourceMap = [ordered]@{
    'scripts\Start-CLIProxyAPI.ps1' = 'tools\cliproxyapi\Start-CLIProxyAPI.ps1'
    'scripts\Stop-CLIProxyAPI.ps1' = 'tools\cliproxyapi\Stop-CLIProxyAPI.ps1'
    'scripts\New-RuntimeConfig.ps1' = 'tools\cliproxyapi\New-RuntimeConfig.ps1'
    'scripts\Protect-CLIProxyAPICredentials.ps1' = 'tools\cliproxyapi\Protect-CLIProxyAPICredentials.ps1'
    'scripts\Update-CodexModelCatalog.ps1' = 'tools\cliproxyapi\Update-CodexModelCatalog.ps1'
    'scripts\Login-CodexOAuth.ps1' = 'tools\cliproxyapi\Login-CodexOAuth.ps1'
    'scripts\Get-CodexProxyToken.ps1' = 'tools\cliproxyapi\Get-CodexProxyToken.ps1'
    'src\codex-catalog-compat.mjs' = 'tools\cliproxyapi\codex-catalog-compat.mjs'
    'config\config.template.yaml' = 'tools\cliproxyapi\config.template.yaml'
    'startup\CLIProxyAPI-Autostart.vbs' = 'tools\cliproxyapi\CLIProxyAPI-Autostart.vbs'
    'scripts\Enable-CLIProxyAPI.ps1' = 'Enable-CLIProxyAPI.ps1'
    'scripts\Restore-GPT56Sol-ChatGPT.ps1' = 'Restore-GPT56Sol-ChatGPT.ps1'
    'scripts\Restart-CodexApp.ps1' = 'Restart-CodexApp.ps1'
}

foreach ($relativeSource in $sourceMap.Keys) {
    $sourcePath = Join-Path $repositoryRoot $relativeSource
    if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
        throw "Repository source file is missing: $relativeSource"
    }
}

New-Item -ItemType Directory -Path $codexHome -Force | Out-Null
New-Item -ItemType Directory -Path $toolDirectory -Force | Out-Null

$temporaryDirectory = Join-Path ([System.IO.Path]::GetTempPath()) ("codex-cliproxyapi-install-" + [Guid]::NewGuid().ToString('N'))
$temporaryArchive = Join-Path $temporaryDirectory $archiveName
$expandedDirectory = Join-Path $temporaryDirectory 'expanded'
New-Item -ItemType Directory -Path $temporaryDirectory | Out-Null

try {
    if ([string]::IsNullOrWhiteSpace($ArchivePath)) {
        $previousProtocol = [Net.ServicePointManager]::SecurityProtocol
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -UseBasicParsing -Uri $downloadUri -OutFile $temporaryArchive -TimeoutSec 180
        }
        finally {
            [Net.ServicePointManager]::SecurityProtocol = $previousProtocol
        }
    }
    else {
        $resolvedArchivePath = [System.IO.Path]::GetFullPath($ArchivePath)
        if (-not (Test-Path -LiteralPath $resolvedArchivePath -PathType Leaf)) {
            throw "Specified CLIProxyAPI archive was not found: $resolvedArchivePath"
        }
        Copy-Item -LiteralPath $resolvedArchivePath -Destination $temporaryArchive
    }

    $actualSha256 = (Get-FileHash -Algorithm SHA256 -LiteralPath $temporaryArchive).Hash.ToLowerInvariant()
    if ($actualSha256 -ne $expectedSha256) {
        throw "CLIProxyAPI archive checksum mismatch. Expected $expectedSha256; received $actualSha256."
    }

    Expand-Archive -LiteralPath $temporaryArchive -DestinationPath $expandedDirectory
    $downloadedExecutable = Join-Path $expandedDirectory 'cli-proxy-api.exe'
    if (-not (Test-Path -LiteralPath $downloadedExecutable -PathType Leaf)) {
        throw 'The verified CLIProxyAPI archive did not contain cli-proxy-api.exe.'
    }

    Copy-Item -LiteralPath $downloadedExecutable -Destination (Join-Path $toolDirectory 'cli-proxy-api.exe') -Force
    $downloadedLicense = Join-Path $expandedDirectory 'LICENSE'
    if (Test-Path -LiteralPath $downloadedLicense -PathType Leaf) {
        Copy-Item -LiteralPath $downloadedLicense -Destination (Join-Path $toolDirectory 'CLIProxyAPI-LICENSE.txt') -Force
    }
    foreach ($entry in $sourceMap.GetEnumerator()) {
        $sourcePath = Join-Path $repositoryRoot $entry.Key
        $destinationPath = Join-Path $codexHome $entry.Value
        $destinationDirectory = Split-Path -Parent $destinationPath
        New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
        Copy-Item -LiteralPath $sourcePath -Destination $destinationPath -Force
    }

    if (-not (Test-Path -LiteralPath $clientKeyPath -PathType Leaf)) {
        $bytes = New-Object byte[] 32
        $generator = [System.Security.Cryptography.RandomNumberGenerator]::Create()
        try { $generator.GetBytes($bytes) }
        finally { $generator.Dispose() }
        $generated = [Convert]::ToBase64String($bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        [System.IO.File]::WriteAllText($clientKeyPath, "codex-local-$generated", $utf8NoBom)
    }
    if (-not (Test-Path -LiteralPath $deepSeekKeyPath -PathType Leaf)) {
        [System.IO.File]::WriteAllText($deepSeekKeyPath, '', $utf8NoBom)
    }

    $protector = Join-Path $toolDirectory 'Protect-CLIProxyAPICredentials.ps1'
    $null = & $protector -AdditionalFiles @($deepSeekKeyPath, $clientKeyPath)

    if (-not $SkipDesktopLaunchers) {
        $desktop = [Environment]::GetFolderPath('Desktop')
        if ([string]::IsNullOrWhiteSpace($desktop)) { throw 'The current Windows Desktop folder could not be resolved.' }
        Copy-Item -LiteralPath (Join-Path $repositoryRoot 'launchers\enable-cliproxy.cmd') `
            -Destination (Join-Path $desktop 'enable-cliproxy.cmd') -Force
        Copy-Item -LiteralPath (Join-Path $repositoryRoot 'launchers\reset-codex.cmd') `
            -Destination (Join-Path $desktop 'reset-codex.cmd') -Force
    }

    $installedExecutable = Join-Path $toolDirectory 'cli-proxy-api.exe'
    $savedPreference = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $versionOutput = @(& $installedExecutable --help 2>&1 | ForEach-Object { [string]$_ })
    $ErrorActionPreference = $savedPreference
    if (($versionOutput -join "`n") -notmatch "Version:\s*$([Regex]::Escape($cliProxyVersion))\b") {
        throw 'The installed CLIProxyAPI executable did not report the pinned version.'
    }
    $nodePath = (Get-Command 'node.exe' -CommandType Application | Select-Object -First 1).Source
    & $nodePath --check (Join-Path $toolDirectory 'codex-catalog-compat.mjs')
    if ($LASTEXITCODE -ne 0) { throw 'The installed compatibility layer failed Node.js syntax validation.' }
}
finally {
    if (Test-Path -LiteralPath $temporaryDirectory -PathType Container) {
        $resolvedTemporary = [System.IO.Path]::GetFullPath($temporaryDirectory)
        $resolvedTempRoot = [System.IO.Path]::GetFullPath([System.IO.Path]::GetTempPath())
        if ($resolvedTemporary.StartsWith($resolvedTempRoot, [System.StringComparison]::OrdinalIgnoreCase) -and
            (Split-Path -Leaf $resolvedTemporary) -like 'codex-cliproxyapi-install-*') {
            Remove-Item -LiteralPath $resolvedTemporary -Recurse -Force
        }
    }
}

Write-Output 'Codex CLIProxyAPI router files were installed without starting services or changing config.toml.'
Write-Output "CLIProxyAPI version: $cliProxyVersion (official archive checksum verified)"
Write-Output 'Next: place the DeepSeek API key in the generated key file, run the ACL protector, then run enable-cliproxy.cmd.'
