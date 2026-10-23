#requires -Version 7
[CmdletBinding()]
param(
    [string]$DotNetPath = 'dotnet',
    [string]$ChecksProject = ''
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($ChecksProject)) {
    $ChecksProject = Join-Path $PSScriptRoot 'bootstrapper-checks\DevWS.Setup.Checks.csproj'
}
$PathsScript = Join-Path $RepoRoot 'src\lib\devws-paths.ps1'
$TempRoot = Join-Path ([IO.Path]::GetTempPath()) ('devws-staging-acl-' + [guid]::NewGuid().ToString('N'))
$CommonData = Join-Path $TempRoot 'ProgramData'

function Fail([string]$Message) {
    throw "ACL contract test failed: $Message"
}

try {
    New-Item -ItemType Directory -Path $CommonData -Force | Out-Null

    $output = @(& $DotNetPath run --project $ChecksProject -c Release -- --emit-acl-json $CommonData 2>&1 | ForEach-Object { "$_" })
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        Fail ("emitter exited $exitCode`n" + ($output -join [Environment]::NewLine))
    }

    $marker = 'DEVWS_ACL_CONTRACT_JSON:'
    $line = @($output | Where-Object { $_.StartsWith($marker, [StringComparison]::Ordinal) } | Select-Object -Last 1)
    if ($line.Count -ne 1) {
        Fail "emitter did not produce the ACL contract marker"
    }

    $record = ([string]$line[0]).Substring($marker.Length) | ConvertFrom-Json
    foreach ($name in @('baseSddl', 'stagingSddl', 'runSddl')) {
        if ([string]::IsNullOrWhiteSpace([string]$record.$name)) {
            Fail "emitter did not return $name"
        }
    }

    . $PathsScript
    $userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value

    $baseSecurity = [System.Security.AccessControl.DirectorySecurity]::new()
    $baseSecurity.SetSecurityDescriptorSddlForm([string]$record.baseSddl)
    $baseValidation = Test-DevWSPrivilegedStateSecurity -Security $baseSecurity -Kind Base -UserSid $userSid
    if (-not $baseValidation.Ok) {
        Fail ("bootstrapper-created base ACL does not satisfy the installer base validator: " + ($baseValidation.Errors -join '; '))
    }

    $administrators = [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544')
    $system = [Security.Principal.SecurityIdentifier]::new('S-1-5-18')

    foreach ($entry in @(
        @{ Name = 'setup-staging'; Sddl = [string]$record.stagingSddl },
        @{ Name = 'staging run'; Sddl = [string]$record.runSddl }
    )) {
        $security = [System.Security.AccessControl.DirectorySecurity]::new()
        $security.SetSecurityDescriptorSddlForm($entry.Sddl)
        if (-not $security.AreAccessRulesProtected) {
            Fail "$($entry.Name) DACL is not protected"
        }

        $owner = $security.GetOwner([Security.Principal.SecurityIdentifier])
        if (-not ($owner.Equals($administrators) -or $owner.Equals($system))) {
            Fail "$($entry.Name) owner is not Administrators or SYSTEM"
        }

        foreach ($rule in @($security.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))) {
            if ($rule.AccessControlType -ne [System.Security.AccessControl.AccessControlType]::Allow) {
                Fail "$($entry.Name) contains a non-allow access rule"
            }
            if ($rule.IsInherited) {
                Fail "$($entry.Name) contains an inherited access rule"
            }

            $sid = [Security.Principal.SecurityIdentifier]$rule.IdentityReference
            if (-not ($sid.Equals($administrators) -or $sid.Equals($system))) {
                Fail "$($entry.Name) grants access to untrusted identity $sid"
            }
        }
    }

    Write-Output 'PASS: bootstrapper base ACL satisfies the canonical installer validator'
    Write-Output 'PASS: setup-staging and staging run ACLs remain SYSTEM/Administrators-only'
}
finally {
    if (Test-Path -LiteralPath $TempRoot) {
        Remove-Item -LiteralPath $TempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
