#requires -Version 7
[CmdletBinding()]
param(
    [string]$DotNetPath = 'dotnet',
    [switch]$KeepArtifacts
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent $PSScriptRoot
$BuildScript = Join-Path $PSScriptRoot 'build-setup.ps1'
$ChecksProject = Join-Path $PSScriptRoot 'bootstrapper-checks\DevWS.Setup.Checks.csproj'
$BootstrapperProject = Join-Path $PSScriptRoot 'bootstrapper\DevWS.Setup.csproj'
$TestRoot = Join-Path ([IO.Path]::GetTempPath()) ('devws-bootstrapper-tests-' + [guid]::NewGuid().ToString('N'))
$Suffix = [guid]::NewGuid().ToString('N').Substring(0, 8)
$ProductId = 'ekinokss.DevWS.Fixture.' + $Suffix
$DisplayName = 'DevWS Setup Fixture ' + $Suffix
$RootLeaf = 'DevWS-Setup-Fixture-' + $Suffix
$Sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$FixtureRoot = Join-Path $env:ProgramFiles $RootLeaf
$FixtureLocal = Join-Path $env:LOCALAPPDATA $RootLeaf
$FixtureSetupDirectory = Join-Path $FixtureRoot ('setup\' + $Sid)
$PersistedSetup = Join-Path $FixtureSetupDirectory 'DevWS-Setup.exe'
$ArpRelativePath = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\' + $ProductId
$DevWSBase = Join-Path $env:ProgramData 'DevWS'
$StagingParent = Join-Path $env:ProgramData 'DevWS\setup-staging'
# Conservative defaults: if the fixture fails before observing the shared
# roots, cleanup must preserve them rather than infer ownership.
$DevWSBaseBefore = $true
$StagingParentBefore = $true
$DevWSBaseObserved = $false
$StagingParentObserved = $false
$ProductionArpRelativePath = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\ekinokss.DevWS'
$ProductionLifecycle = Join-Path $env:ProgramFiles ('DevWS\setup\' + $Sid)
$ProductionArpBefore = $null
$ProductionLifecycleBefore = $null
$FixtureInstallLog = Join-Path $TestRoot 'fixture-install.log'
$FixtureUninstallLog = Join-Path $TestRoot 'fixture-uninstall.log'
$FixtureMarker = Join-Path $FixtureLocal 'user-data-marker.txt'

function Assert-Condition([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ($Expected -ne $Actual) { throw "Assertion failed: $Message (expected '$Expected', got '$Actual')" }
}
function Assert-Contains([string]$Text, [string]$Needle, [string]$Message) {
    Assert-Condition ($Text.IndexOf($Needle, [StringComparison]::OrdinalIgnoreCase) -ge 0) "$Message (missing '$Needle')"
}
function Assert-NotContains([string]$Text, [string]$Needle, [string]$Message) {
    Assert-Condition ($Text.IndexOf($Needle, [StringComparison]::OrdinalIgnoreCase) -lt 0) "$Message (unexpected '$Needle')"
}
function ConvertTo-Sid([string]$Identity) {
    try {
        return ([Security.Principal.NTAccount]::new($Identity)).Translate([Security.Principal.SecurityIdentifier]).Value
    }
    catch {
        return $Identity
    }
}
function Open-ArpKey([bool]$Writable) {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::CurrentUser,
        [Microsoft.Win32.RegistryView]::Registry64)
    if ($Writable) {
        return $base.CreateSubKey($ArpRelativePath, $true)
    }
    return $base.OpenSubKey($ArpRelativePath, $false)
}
function Get-ArpValue([string]$Name) {
    $key = Open-ArpKey $false
    if ($null -eq $key) { return $null }
    try { return $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
    finally { $key.Dispose() }
}
function Test-KeyExists([string]$RelativePath) {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::CurrentUser,
        [Microsoft.Win32.RegistryView]::Registry64)
    try { return $null -ne $base.OpenSubKey($RelativePath, $false) }
    finally { $base.Dispose() }
}
function Remove-FixtureArp {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::CurrentUser,
        [Microsoft.Win32.RegistryView]::Registry64)
    try { $base.DeleteSubKeyTree($ArpRelativePath, $false) }
    finally { $base.Dispose() }
}
function Get-LogLines([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return @() }
    return @(Get-Content -LiteralPath $Path -Encoding UTF8 | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_ | ConvertFrom-Json })
}
function Remove-FixtureOwnedEmptyDirectory([string]$Path, [bool]$Preexisted) {
    # Shared roots are removed only when this fixture observed their absence
    # before the run and they are still empty at cleanup. A pre-existing empty
    # root belongs to the environment and is never touched.
    if ($Preexisted -or -not (Test-Path -LiteralPath $Path)) { return }
    $remaining = @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction SilentlyContinue)
    if ($remaining.Count -eq 0) {
        Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    }
}
function Test-FixtureCleanupOwnership([string]$Root) {
    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    $preexisting = Join-Path $Root 'pre-existing-empty-base'
    $fixtureOwned = Join-Path $Root 'fixture-owned-empty-base'
    $fixtureNonEmpty = Join-Path $Root 'fixture-owned-nonempty-base'
    New-Item -ItemType Directory -Path $preexisting -Force | Out-Null
    New-Item -ItemType Directory -Path $fixtureOwned -Force | Out-Null
    New-Item -ItemType Directory -Path $fixtureNonEmpty -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $fixtureNonEmpty 'marker.txt') -Value 'fixture-owned' -Encoding Ascii

    $beforeItem = Get-Item -LiteralPath $preexisting -Force
    $beforeAcl = Get-Acl -LiteralPath $preexisting
    $beforeCreation = $beforeItem.CreationTimeUtc
    $beforeWrite = $beforeItem.LastWriteTimeUtc
    Remove-FixtureOwnedEmptyDirectory -Path $preexisting -Preexisted $true
    $afterItem = Get-Item -LiteralPath $preexisting -Force
    $afterAcl = Get-Acl -LiteralPath $preexisting
    Assert-Condition (Test-Path -LiteralPath $preexisting) 'pre-existing empty base was removed by cleanup'
    Assert-Condition ($afterAcl.Owner -eq $beforeAcl.Owner) 'pre-existing empty base owner changed'
    Assert-Condition ($afterAcl.Sddl -eq $beforeAcl.Sddl) 'pre-existing empty base ACL changed'
    Assert-Condition ($afterItem.CreationTimeUtc -eq $beforeCreation) 'pre-existing empty base creation time changed'
    Assert-Condition ($afterItem.LastWriteTimeUtc -eq $beforeWrite) 'pre-existing empty base metadata changed'

    Remove-FixtureOwnedEmptyDirectory -Path $fixtureOwned -Preexisted $false
    Assert-Condition (-not (Test-Path -LiteralPath $fixtureOwned)) 'fixture-owned empty base was not removed'

    Remove-FixtureOwnedEmptyDirectory -Path $fixtureNonEmpty -Preexisted $false
    Assert-Condition (Test-Path -LiteralPath $fixtureNonEmpty) 'fixture-owned non-empty base was removed'

    Write-Output 'PASS: cleanup preserves a pre-existing empty shared base and its metadata'
    Write-Output 'PASS: cleanup removes only fixture-created empty directories'
}
function Assert-ProtectedPath([string]$Path, [bool]$IsFile) {
    Assert-Condition (Test-Path -LiteralPath $Path) "Protected package path is missing: $Path"
    $acl = Get-Acl -LiteralPath $Path
    $owner = ConvertTo-Sid $acl.Owner
    Assert-Condition ($owner -in @('S-1-5-32-544', 'S-1-5-18')) "Protected package path owner is untrusted: $owner"

    $userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $userRead = $false
    $dangerous = 2 -bor 4 -bor 16 -bor 64 -bor 256 -bor 65536 -bor 262144 -bor 524288 -bor 278
    foreach ($rule in $acl.Access) {
        if ($rule.AccessControlType -ne 'Allow') { continue }
        $sid = ConvertTo-Sid $rule.IdentityReference.Value
        $rights = [int]$rule.FileSystemRights
        if (($rights -band $dangerous) -ne 0 -and $sid -notin @('S-1-5-32-544', 'S-1-5-18')) {
            throw "Protected package path grants untrusted write/delete rights to $sid`: $Path"
        }
        if ($sid -eq $userSid -and ($rights -band 1) -ne 0 -and ($rights -band 32) -ne 0) {
            $userRead = $true
        }
    }
    Assert-Condition $userRead "Target user lacks read/execute on protected package path: $Path"
}
function Assert-NoPackageBackups {
    $files = @(Get-ChildItem -LiteralPath $FixtureSetupDirectory -File -Force -ErrorAction SilentlyContinue | Where-Object { $_.Name -like 'DevWS-Setup.old.*' -or $_.Name -like 'DevWS-Setup.new.*' })
    Assert-Condition ($files.Count -eq 0) "Package replacement backups remain: $(@($files | ForEach-Object FullName) -join ', ')"
}
function Invoke-Setup([string]$Exe, [string[]]$Arguments) {
    $output = & $Exe @Arguments 2>&1 | Out-String
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
}
function Write-FixturePayload {
    $source = Join-Path $TestRoot 'fixture-source'
    New-Item -ItemType Directory -Path $source -Force | Out-Null
    $install = @'
param(
    [switch]$PackageMode,
    [switch]$Force,
    [switch]$ResetConfig,
    [switch]$Purge
)
$record = [ordered]@{
    kind = 'install'
    packageMode = [bool]$PackageMode
    force = [bool]$Force
    resetConfig = [bool]$ResetConfig
    purge = [bool]$Purge
    cwd = (Get-Location).Path
    script = $PSCommandPath
    psMajor = $PSVersionTable.PSVersion.Major
}
Add-Content -LiteralPath $env:DEVWS_SETUP_FIXTURE_INSTALL_LOG -Value ($record | ConvertTo-Json -Compress) -Encoding utf8
$exitCode = 0
if (-not [int]::TryParse($env:DEVWS_SETUP_FIXTURE_INSTALL_EXIT, [ref]$exitCode)) { $exitCode = 0 }
if ($exitCode -eq 0) {
    $marker = $env:DEVWS_SETUP_FIXTURE_MARKER
    New-Item -ItemType Directory -Path (Split-Path -Parent $marker) -Force | Out-Null
    Set-Content -LiteralPath $marker -Value 'preserve this fixture user data' -NoNewline -Encoding utf8NoBOM
}
exit $exitCode
'@
    $uninstall = @'
param(
    [switch]$PackageMode,
    [switch]$Force,
    [switch]$Purge
)
$record = [ordered]@{
    kind = 'uninstall'
    packageMode = [bool]$PackageMode
    force = [bool]$Force
    purge = [bool]$Purge
    cwd = (Get-Location).Path
    script = $PSCommandPath
    psMajor = $PSVersionTable.PSVersion.Major
}
Add-Content -LiteralPath $env:DEVWS_SETUP_FIXTURE_UNINSTALL_LOG -Value ($record | ConvertTo-Json -Compress) -Encoding utf8
$exitCode = 0
if (-not [int]::TryParse($env:DEVWS_SETUP_FIXTURE_UNINSTALL_EXIT, [ref]$exitCode)) { $exitCode = 0 }
exit $exitCode
'@
    Set-Content -LiteralPath (Join-Path $source 'install.ps1') -Value $install -Encoding utf8NoBOM
    Set-Content -LiteralPath (Join-Path $source 'uninstall.ps1') -Value $uninstall -Encoding utf8NoBOM
    $zip = Join-Path $TestRoot 'fixture-payload.zip'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [System.IO.Compression.ZipFile]::CreateFromDirectory($source, $zip, [System.IO.Compression.CompressionLevel]::Optimal, $false)
    return $zip
}
function Build-Fixture([string]$Version, [string]$Name) {
    $out = Join-Path $TestRoot $Name
    $lastOutput = ''
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        if (Test-Path -LiteralPath $out) { Remove-Item -LiteralPath $out -Recurse -Force }
        try {
            $buildOutput = & $BuildScript -DotNetPath $DotNetPath -Fixture -PayloadZip $FixtureZip -OutputDir $out `
                -ProductVersion $Version -ProductId $ProductId -DisplayName $DisplayName `
                -ProgramFilesRootLeaf $RootLeaf -InstallRootLeaf $RootLeaf 2>&1 | Out-String
            $buildCode = $LASTEXITCODE
        }
        catch {
            $buildOutput = ($_ | Out-String)
            $buildCode = 1
        }
        $lastOutput = $buildOutput
        if ($buildCode -eq 0) { break }
        Start-Sleep -Seconds 2
    }
    Assert-Condition ($buildCode -eq 0) "Fixture build $Version failed.`n$lastOutput"
    $exe = Join-Path $out 'DevWS-Setup.exe'
    Assert-Condition (Test-Path -LiteralPath $exe -PathType Leaf) "Fixture build $Version did not produce an EXE."
    return $exe
}

try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = [Security.Principal.WindowsPrincipal]::new($identity)
    Assert-Condition ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) 'test-bootstrapper.ps1 must run from an elevated PowerShell.'
    Assert-Condition ($ProductId -ne 'ekinokss.DevWS') 'Fixture product identity collided with production.'
    $ProductionArpBefore = Test-KeyExists $ProductionArpRelativePath
    $ProductionLifecycleBefore = Test-Path -LiteralPath $ProductionLifecycle
    $DevWSBaseBefore = Test-Path -LiteralPath $DevWSBase
    $StagingParentBefore = Test-Path -LiteralPath $StagingParent
    $DevWSBaseObserved = $true
    $StagingParentObserved = $true

    New-Item -ItemType Directory -Path $TestRoot -Force | Out-Null
    Test-FixtureCleanupOwnership -Root (Join-Path $TestRoot 'cleanup-ownership')
    $FixtureZip = Write-FixturePayload
    $exe020 = Build-Fixture '0.2.0' 'fixture-020'
    $exe021 = Build-Fixture '0.2.1' 'fixture-021'
    $hash020 = (Get-FileHash -LiteralPath $exe020 -Algorithm SHA256).Hash
    $hash021 = (Get-FileHash -LiteralPath $exe021 -Algorithm SHA256).Hash

    Write-Output '[test] Running bootstrapper source checks...'
    & $DotNetPath run --project $ChecksProject -c Release
    Assert-Condition ($LASTEXITCODE -eq 0) 'Bootstrapper source checks failed.'

    Write-Output '[test] Verifying bootstrapper/installer ACL contract...'
    & pwsh -NoLogo -NoProfile -File (Join-Path $PSScriptRoot 'test-staging-acl-contract.ps1') `
        -DotNetPath $DotNetPath -ChecksProject $ChecksProject
    Assert-Condition ($LASTEXITCODE -eq 0) 'Bootstrapper/installer ACL contract test failed.'

    $env:DEVWS_SETUP_FIXTURE_INSTALL_LOG = $FixtureInstallLog
    $env:DEVWS_SETUP_FIXTURE_UNINSTALL_LOG = $FixtureUninstallLog
    $env:DEVWS_SETUP_FIXTURE_MARKER = $FixtureMarker
    $env:DEVWS_SETUP_FIXTURE_INSTALL_EXIT = '0'
    $env:DEVWS_SETUP_FIXTURE_UNINSTALL_EXIT = '0'

    $help = Invoke-Setup $exe020 @('--help')
    Assert-Equal 0 $help.ExitCode '--help must not require elevation or lifecycle work'
    Assert-Contains $help.Output 'Windows x64 setup lifecycle' '--help usage'
    $version = Invoke-Setup $exe020 @('--version')
    Assert-Equal 0 $version.ExitCode '--version must not require elevation'
    Assert-Contains $version.Output '0.2.0' '--version reports product version'
    $bad = Invoke-Setup $exe020 @('--bogus')
    Assert-Condition ($bad.ExitCode -ne 0) 'malformed argument was accepted'
    Assert-Condition (-not (Test-Path -LiteralPath $FixtureMarker)) 'help/version/malformed created fixture user data'

    # A. Fresh package install.
    $fresh = Invoke-Setup $exe020 @()
    Assert-Equal 0 $fresh.ExitCode "fresh install failed`n$($fresh.Output)"
    Assert-Condition (Test-KeyExists $ArpRelativePath) 'fresh install did not create ARP key'
    Assert-Equal $DisplayName (Get-ArpValue 'DisplayName') 'ARP DisplayName'
    Assert-Equal '0.2.0' (Get-ArpValue 'DisplayVersion') 'ARP fresh version'
    Assert-Equal 'ekinokss' (Get-ArpValue 'Publisher') 'ARP Publisher'
    Assert-Equal $FixtureLocal (Get-ArpValue 'InstallLocation') 'ARP InstallLocation'
    $expectedUninstall = '"' + $PersistedSetup + '" --uninstall'
    Assert-Equal $expectedUninstall (Get-ArpValue 'UninstallString') 'ARP UninstallString'
    Assert-Equal $expectedUninstall (Get-ArpValue 'QuietUninstallString') 'ARP QuietUninstallString'
    Assert-Equal $PersistedSetup (Get-ArpValue 'DisplayIcon') 'ARP DisplayIcon'
    Assert-Equal 'https://github.com/ekinokss/DevWS' (Get-ArpValue 'URLInfoAbout') 'ARP URLInfoAbout'
    Assert-Equal 1 (Get-ArpValue 'NoModify') 'ARP NoModify'
    Assert-Equal 1 (Get-ArpValue 'NoRepair') 'ARP NoRepair'
    Assert-Condition ((Get-ArpValue 'InstallDate') -match '^\d{8}$') 'ARP InstallDate format'
    Assert-Condition ((Get-ArpValue 'DevWSSourceSha') -match '^[0-9a-f]{40}-fixture$') 'ARP source SHA'
    Assert-Condition (Test-Path -LiteralPath $PersistedSetup -PathType Leaf) 'persisted setup missing'
    Assert-Equal $hash020 (Get-FileHash -LiteralPath $PersistedSetup -Algorithm SHA256).Hash 'fresh persisted hash'
    Assert-ProtectedPath $PersistedSetup $true
    Assert-ProtectedPath $FixtureSetupDirectory $false
    Assert-Condition (Test-Path -LiteralPath $FixtureMarker -PathType Leaf) 'fixture user data marker missing'
    $installLines = @(Get-LogLines $FixtureInstallLog)
    Assert-Equal 1 $installLines.Count 'fresh install invocation count'
    Assert-Equal $true $installLines[0].packageMode 'fresh install package mode'
    Assert-Equal $false $installLines[0].force 'fresh install force'
    Assert-Equal $false $installLines[0].resetConfig 'fresh install reset'
    Assert-Equal $false $installLines[0].purge 'fresh install purge'
    Assert-Contains ([string]$installLines[0].cwd) $StagingParent 'staging root location'
    Assert-Condition (-not ([string]$installLines[0].cwd).StartsWith($env:TEMP, [StringComparison]::OrdinalIgnoreCase)) 'staging used TEMP'
    Assert-Condition (-not ([string]$installLines[0].cwd).StartsWith($env:LOCALAPPDATA, [StringComparison]::OrdinalIgnoreCase)) 'staging used LOCALAPPDATA'
    Assert-Contains $fresh.Output '[setup] trusted PowerShell:' 'trusted PowerShell report'

    # B. Same-version reinstall.
    $reinstall = Invoke-Setup $exe020 @()
    Assert-Equal 0 $reinstall.ExitCode 'same-version reinstall failed'
    $installLines = @(Get-LogLines $FixtureInstallLog)
    Assert-Equal 2 $installLines.Count 'reinstall invoked installer again'
    Assert-Equal '0.2.0' (Get-ArpValue 'DisplayVersion') 'reinstall version'
    Assert-Equal $hash020 (Get-FileHash -LiteralPath $PersistedSetup -Algorithm SHA256).Hash 'reinstall persisted hash'
    Assert-Condition (@(Get-ChildItem -LiteralPath (Join-Path $FixtureRoot 'setup') -Directory -Force).Count -eq 1) 'reinstall duplicated lifecycle roots'
    Assert-NoPackageBackups

    # C. Upgrade.
    $upgrade = Invoke-Setup $exe021 @()
    Assert-Equal 0 $upgrade.ExitCode "upgrade failed`n$($upgrade.Output)"
    $installLines = @(Get-LogLines $FixtureInstallLog)
    Assert-Equal 3 $installLines.Count 'upgrade invocation count'
    Assert-Equal '0.2.1' (Get-ArpValue 'DisplayVersion') 'upgrade version'
    Assert-Equal $hash021 (Get-FileHash -LiteralPath $PersistedSetup -Algorithm SHA256).Hash 'upgrade persisted hash'
    Assert-Condition (@(Get-ChildItem -LiteralPath (Join-Path $FixtureRoot 'setup') -Directory -Force).Count -eq 1) 'upgrade duplicated lifecycle roots'
    Assert-NoPackageBackups

    # D. Downgrade refusal.
    $downgrade = Invoke-Setup $exe020 @()
    Assert-Condition ($downgrade.ExitCode -ne 0) 'downgrade was accepted'
    Assert-Contains $downgrade.Output 'newer DevWS package version' 'downgrade explanation'
    $installLines = @(Get-LogLines $FixtureInstallLog)
    Assert-Equal 3 $installLines.Count 'downgrade invoked installer'
    Assert-Equal '0.2.1' (Get-ArpValue 'DisplayVersion') 'downgrade changed ARP version'
    Assert-Equal $hash021 (Get-FileHash -LiteralPath $PersistedSetup -Algorithm SHA256).Hash 'downgrade changed persisted setup'

    # E. Install failure preservation.
    $env:DEVWS_SETUP_FIXTURE_INSTALL_EXIT = '23'
    $installFailure = Invoke-Setup $exe021 @()
    $env:DEVWS_SETUP_FIXTURE_INSTALL_EXIT = '0'
    Assert-Equal 23 $installFailure.ExitCode 'controlled install failure did not propagate'
    $installLines = @(Get-LogLines $FixtureInstallLog)
    Assert-Equal 4 $installLines.Count 'install failure did not invoke installer'
    Assert-Equal '0.2.1' (Get-ArpValue 'DisplayVersion') 'install failure changed ARP version'
    Assert-Equal $hash021 (Get-FileHash -LiteralPath $PersistedSetup -Algorithm SHA256).Hash 'install failure changed persisted setup'

    # A copy in a user-writable directory is not accepted for elevated uninstall.
    $userWritableUninstall = Invoke-Setup $exe021 @('--uninstall')
    Assert-Condition ($userWritableUninstall.ExitCode -ne 0) 'user-writable uninstall copy was accepted'
    Assert-Contains $userWritableUninstall.Output 'user-writable copy' 'user-writable uninstall refusal'
    Assert-Condition (Test-KeyExists $ArpRelativePath) 'user-writable uninstall removed ARP'
    Assert-Condition (Test-Path -LiteralPath $PersistedSetup -PathType Leaf) 'user-writable uninstall removed persisted setup'

    # F. Uninstall failure preservation.
    $env:DEVWS_SETUP_FIXTURE_UNINSTALL_EXIT = '24'
    $uninstallFailure = Invoke-Setup $PersistedSetup @('--uninstall')
    $env:DEVWS_SETUP_FIXTURE_UNINSTALL_EXIT = '0'
    Assert-Equal 24 $uninstallFailure.ExitCode 'controlled uninstall failure did not propagate'
    Assert-Condition (Test-KeyExists $ArpRelativePath) 'uninstall failure removed ARP'
    Assert-Condition (Test-Path -LiteralPath $PersistedSetup -PathType Leaf) 'uninstall failure removed persisted setup'

    # G. Successful uninstall and post-exit self-removal.
    $uninstallSuccess = Invoke-Setup $PersistedSetup @('--uninstall')
    Assert-Equal 0 $uninstallSuccess.ExitCode "successful uninstall failed`n$($uninstallSuccess.Output)"
    Assert-Condition (-not (Test-KeyExists $ArpRelativePath)) 'successful uninstall left ARP key'
    $deadline = (Get-Date).AddSeconds(45)
    while ((Get-Date) -lt $deadline) {
        if (-not (Test-Path -LiteralPath $FixtureSetupDirectory) -and
            -not (Test-Path -LiteralPath $PersistedSetup)) { break }
        Start-Sleep -Milliseconds 250
    }
    Assert-Condition (-not (Test-Path -LiteralPath $PersistedSetup)) 'persisted setup survived successful uninstall'
    Assert-Condition (-not (Test-Path -LiteralPath $FixtureSetupDirectory)) 'per-user setup directory survived successful uninstall'
    Assert-Condition (-not (Test-Path -LiteralPath $FixtureRoot)) 'fixture Program Files root survived successful uninstall'
    Assert-Condition (Test-Path -LiteralPath $FixtureMarker -PathType Leaf) 'fixture user data was removed by package uninstall'
    if (-not $StagingParentBefore) {
        Assert-Condition (-not (Test-Path -LiteralPath $StagingParent)) 'fixture staging parent survived successful uninstall'
    }
    Assert-Condition (((Test-Path -LiteralPath $ProductionLifecycle) -eq $ProductionLifecycleBefore)) 'production lifecycle path state changed'
    Assert-Condition (((Test-KeyExists $ProductionArpRelativePath) -eq $ProductionArpBefore)) 'production ARP state changed'
    $uninstallLines = @(Get-LogLines $FixtureUninstallLog)
    Assert-Equal 2 $uninstallLines.Count 'uninstall invocation count'
    foreach ($line in $uninstallLines) {
        Assert-Equal $true $line.packageMode 'uninstall package mode'
        Assert-Equal $false $line.force 'uninstall force'
        Assert-Equal $false $line.purge 'uninstall purge'
    }

    Write-Output 'PASS: fixture fresh install, same-version reinstall, upgrade, downgrade refusal'
    Write-Output 'PASS: fixture install/uninstall failure preservation and package-state rollback behavior'
    Write-Output 'PASS: fixture protected ARP, per-SID setup ACL, uninstall self-removal, user-data preservation'
}
finally {
    Remove-Item Env:\DEVWS_SETUP_FIXTURE_INSTALL_LOG -ErrorAction SilentlyContinue
    Remove-Item Env:\DEVWS_SETUP_FIXTURE_UNINSTALL_LOG -ErrorAction SilentlyContinue
    Remove-Item Env:\DEVWS_SETUP_FIXTURE_MARKER -ErrorAction SilentlyContinue
    Remove-Item Env:\DEVWS_SETUP_FIXTURE_INSTALL_EXIT -ErrorAction SilentlyContinue
    Remove-Item Env:\DEVWS_SETUP_FIXTURE_UNINSTALL_EXIT -ErrorAction SilentlyContinue
    Remove-FixtureArp
    if (Test-Path -LiteralPath $FixtureRoot) { Remove-Item -LiteralPath $FixtureRoot -Recurse -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath $FixtureLocal) { Remove-Item -LiteralPath $FixtureLocal -Recurse -Force -ErrorAction SilentlyContinue }
    Remove-FixtureOwnedEmptyDirectory -Path $StagingParent -Preexisted $StagingParentBefore
    Remove-FixtureOwnedEmptyDirectory -Path $DevWSBase -Preexisted $DevWSBaseBefore

    foreach ($directory in @(
        (Join-Path $PSScriptRoot 'bootstrapper-checks\bin'),
        (Join-Path $PSScriptRoot 'bootstrapper-checks\obj'),
        (Join-Path $PSScriptRoot 'bootstrapper\bin'),
        (Join-Path $PSScriptRoot 'bootstrapper\obj')
    )) {
        if (Test-Path -LiteralPath $directory) {
            Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    if (-not $KeepArtifacts -and (Test-Path -LiteralPath $TestRoot)) {
        Remove-Item -LiteralPath $TestRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    elseif ($KeepArtifacts) {
        Write-Output "[test] artifacts retained at $TestRoot"
    }
}

if ($DevWSBaseObserved -and $DevWSBaseBefore -and -not (Test-Path -LiteralPath $DevWSBase)) {
    throw 'pre-existing shared DevWS base was removed during fixture cleanup'
}
if ($StagingParentObserved -and $StagingParentBefore -and -not (Test-Path -LiteralPath $StagingParent)) {
    throw 'pre-existing staging parent was removed during fixture cleanup'
}
