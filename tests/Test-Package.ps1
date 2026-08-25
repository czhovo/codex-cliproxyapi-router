[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repositoryRoot = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$requiredFiles = @(
    '.gitignore', 'README.md', 'SECURITY.md', 'THIRD_PARTY_NOTICES.md',
    'config\config.template.yaml', 'src\codex-catalog-compat.mjs',
    'scripts\Install-CLIProxyAPIRouter.ps1', 'scripts\Enable-CLIProxyAPI.ps1',
    'scripts\Restore-GPT56Sol-ChatGPT.ps1', 'scripts\Restart-CodexApp.ps1',
    'scripts\Start-CLIProxyAPI.ps1', 'scripts\Stop-CLIProxyAPI.ps1',
    'scripts\New-RuntimeConfig.ps1', 'scripts\Protect-CLIProxyAPICredentials.ps1',
    'scripts\Update-CodexModelCatalog.ps1', 'scripts\Login-CodexOAuth.ps1',
    'scripts\Get-CodexProxyToken.ps1', 'startup\CLIProxyAPI-Autostart.vbs',
    'launchers\enable-cliproxy.cmd', 'launchers\reset-codex.cmd'
)
foreach ($relativePath in $requiredFiles) {
    if (-not (Test-Path -LiteralPath (Join-Path $repositoryRoot $relativePath) -PathType Leaf)) {
        throw "Required package file is missing: $relativePath"
    }
}

$parseErrors = New-Object 'System.Collections.Generic.List[string]'
foreach ($script in @(Get-ChildItem -LiteralPath (Join-Path $repositoryRoot 'scripts') -Filter '*.ps1' -File)) {
    $tokens = $null
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$tokens, [ref]$errors)
    foreach ($error in @($errors)) { $parseErrors.Add("$($script.Name): $($error.Message)") }
}
if ($parseErrors.Count -gt 0) { throw "PowerShell parse errors:`n$($parseErrors -join "`n")" }

$node = Get-Command 'node.exe' -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -eq $node) { throw 'Node.js was not found on PATH.' }
& $node.Source --check (Join-Path $repositoryRoot 'src\codex-catalog-compat.mjs')
if ($LASTEXITCODE -ne 0) { throw 'Node.js syntax validation failed.' }

$template = [System.IO.File]::ReadAllText((Join-Path $repositoryRoot 'config\config.template.yaml'), [System.Text.Encoding]::UTF8)
foreach ($placeholder in @('__LOCAL_PROXY_KEY__', '__DEEPSEEK_API_KEY__', '__AUTH_DIR__')) {
    if (-not $template.Contains($placeholder)) { throw "Configuration template is missing $placeholder." }
}
if ($template -notmatch '(?m)^host:\s*"127\.0\.0\.1"\s*$' -or
    $template -notmatch '(?m)^\s*disable-codex-cloaking:\s*true\s*$') {
    throw 'Configuration template loopback or Codex-cloaking safety validation failed.'
}

$forbiddenLeafNames = @(
    'client-key.txt', 'deepseek_api_key.txt', 'config.runtime.yaml', 'routing-mode.txt',
    'cli-proxy-api.exe', 'cliproxy-model-catalog.json'
)
$forbiddenFiles = @(Get-ChildItem -Recurse -Force -File -LiteralPath $repositoryRoot |
    Where-Object { $_.Name -in $forbiddenLeafNames -or $_.Extension -in @('.log', '.pid', '.zip') })
if ($forbiddenFiles.Count -gt 0) {
    throw "Forbidden runtime artifacts are present: $($forbiddenFiles.Name -join ', ')"
}

$textExtensions = @('.md', '.ps1', '.mjs', '.yaml', '.cmd', '.vbs', '.gitignore')
$textFiles = @(Get-ChildItem -Recurse -Force -File -LiteralPath $repositoryRoot |
    Where-Object { $_.Extension -in $textExtensions -or $_.Name -eq '.gitignore' })
$suspiciousPatterns = [ordered]@{
    ConcreteWindowsProfile = ('C:\\' + 'Users\\[^<%$\s"'']+')
    ConcreteMacProfile = ('/' + 'Users/[^/<$\s"'']+')
    EmailAddress = '(?i)\b[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}\b'
    JWT = '\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b'
    APIKey = '\bsk-[A-Za-z0-9_-]{16,}\b'
    BearerLiteral = '(?i)Bearer\s+[A-Za-z0-9._-]{24,}'
}
$findings = New-Object 'System.Collections.Generic.List[string]'
foreach ($file in $textFiles) {
    $content = [System.IO.File]::ReadAllText($file.FullName, [System.Text.Encoding]::UTF8)
    foreach ($entry in $suspiciousPatterns.GetEnumerator()) {
        if ([Regex]::IsMatch($content, $entry.Value)) {
            $findings.Add("$($entry.Key): $($file.FullName.Substring($repositoryRoot.Length + 1))")
        }
    }
}
if ($findings.Count -gt 0) { throw "Potential secret or machine-specific path found:`n$($findings -join "`n")" }

Write-Output 'Package validation passed: required files, PowerShell syntax, Node syntax, placeholders, and secret/path scan.'
