[CmdletBinding()]
param(
    [string]$AuthDirectory = (Join-Path $PSScriptRoot 'auth'),
    [string[]]$AdditionalFiles = @(
        (Join-Path (Join-Path $env:USERPROFILE '.codex') 'deepseek_api_key.txt'),
        (Join-Path $PSScriptRoot 'client-key.txt'),
        (Join-Path $PSScriptRoot 'config.runtime.yaml')
    )
)

$ErrorActionPreference = 'Stop'
$currentSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
$systemSid = New-Object System.Security.Principal.SecurityIdentifier(
    [System.Security.Principal.WellKnownSidType]::LocalSystemSid,
    $null
)
$administratorsSid = New-Object System.Security.Principal.SecurityIdentifier(
    [System.Security.Principal.WellKnownSidType]::BuiltinAdministratorsSid,
    $null
)
$allowedSids = @($currentSid, $systemSid, $administratorsSid)
$allowedValues = @($allowedSids | ForEach-Object { $_.Value })

function Set-RestrictedAcl([string]$LiteralPath) {
    $item = Get-Item -LiteralPath $LiteralPath -Force
    $isDirectory = [bool]$item.PSIsContainer
    $grants = @($allowedValues | ForEach-Object {
        if ($isDirectory) { "*${_}:(OI)(CI)F" } else { "*${_}:F" }
    })
    $arguments = @($item.FullName, '/inheritance:r', '/grant:r') + $grants + @('/Q')
    $output = & icacls.exe @arguments 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "icacls failed for $($item.FullName): $($output -join [Environment]::NewLine)"
    }
}

function Test-RestrictedAcl([string]$LiteralPath) {
    $acl = Get-Acl -LiteralPath $LiteralPath
    if (-not $acl.AreAccessRulesProtected) { return $false }
    $currentUserFullControl = $false
    foreach ($rule in @($acl.Access)) {
        if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) { return $false }
        try {
            $sidValue = $rule.IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value
        }
        catch {
            return $false
        }
        if ($sidValue -notin $allowedValues) { return $false }
        if ($sidValue -eq $currentSid.Value -and
            ($rule.FileSystemRights -band [System.Security.AccessControl.FileSystemRights]::FullControl)) {
            $currentUserFullControl = $true
        }
    }
    return $currentUserFullControl
}

if (-not (Test-Path -LiteralPath $AuthDirectory -PathType Container)) {
    $null = New-Item -ItemType Directory -Path $AuthDirectory -Force
}

$targets = New-Object 'System.Collections.Generic.List[string]'
$targets.Add([System.IO.Path]::GetFullPath($AuthDirectory))
foreach ($item in @(Get-ChildItem -LiteralPath $AuthDirectory -Recurse -Force)) {
    $targets.Add($item.FullName)
}
foreach ($file in $AdditionalFiles) {
    if (-not [string]::IsNullOrWhiteSpace($file) -and (Test-Path -LiteralPath $file -PathType Leaf)) {
        $targets.Add([System.IO.Path]::GetFullPath($file))
    }
}

foreach ($target in @($targets | Select-Object -Unique)) {
    Set-RestrictedAcl -LiteralPath $target
}
foreach ($target in @($targets | Select-Object -Unique)) {
    if (-not (Test-RestrictedAcl -LiteralPath $target)) {
        throw "Credential ACL validation failed: $target"
    }
}

[pscustomobject]@{
    ProtectedItems = @($targets | Select-Object -Unique).Count
    AllowedPrincipals = 3
}
