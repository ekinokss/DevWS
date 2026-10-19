# DevWS installer.
#
# DevWS installer; there is intentionally no onboarding
# wizard. It must run from the DevWS repository root in an Administrator
# PowerShell. It stages the runtime under %LOCALAPPDATA%\DevWS, establishes the
# canonical workspace config (preserve v3 / migrate v2 or v1 / bundled default),
# updates the five managed DevWS scheduled tasks, the user PATH, the legacy ws.cmd
# shim, and the TerminalShortcut.ahk hotkey, and finishes with a health check.
#
# The legacy v1 directory (%USERPROFILE%\.ws) is never modified or deleted.
#
# Usage:
#   install.ps1                   normal install/update (idempotent)
#   install.ps1 -ResetConfig      replace the canonical config with the default
#   install.ps1 -ResetConfig -Force   skip the reset confirmation
#   install.ps1 -HealthCheck      non-destructive health check only
#   install.ps1 -RepairTasks      restore stale managed task PowerShell bindings
#                                 (after a packaged PowerShell update) without
#                                 reinstalling anything else

param(
    [switch]$ResetConfig,
    [switch]$Force,
    [switch]$HealthCheck,
    [switch]$RepairTasks
)

$ErrorActionPreference = "Stop"

$RepoRoot = $PSScriptRoot
$LibDir   = Join-Path $RepoRoot "src\lib"

foreach ($libName in @(
    "devws-paths.ps1",
    "devws-config.ps1",
    "devws-bindings.ps1",
    "devws-worker-protocol.ps1",
    "devws-install.ps1",
    "devws-health.ps1"
)) {
    . (Join-Path $LibDir $libName)
}

function Write-DevWSInstallSection {
    param([Parameter(Mandatory)][string]$Text)

    Write-Host ""
    Write-Host $Text -ForegroundColor Cyan
}

function Get-DevWSInstallerRerunCommand {
    return ("Start-Process pwsh -Verb RunAs -ArgumentList '-NoLogo','-NoProfile','-File','`"$PSCommandPath`"'")
}

try {
    if ($RepairTasks -and ($ResetConfig -or $Force -or $HealthCheck)) {
        throw "install.ps1 -RepairTasks is a task-only repair mode and cannot be combined with -ResetConfig, -Force or -HealthCheck."
    }

    if ($RepairTasks) {
        # --- Isolated task-only repair path ---------------------------------
        # It never falls through into the nine-step installer: no application
        # files, native runtime, privileged staging, protected state, config,
        # PATH, shim, hotkey or AutoHotkey work happens here.
        Write-DevWSInstallSection "DevWS scheduled-task PowerShell repair"

        if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot "src\ws.ps1") -PathType Leaf)) {
            throw "install.ps1 must run from the DevWS repository root (src\ws.ps1 was not found next to it)."
        }

        if (-not (Test-DevWSAdministrator)) {
            throw ("Repairing the DevWS scheduled tasks requires an Administrator PowerShell so the managed task actions can be rewritten. Rerun it elevated:" + [Environment]::NewLine + "  " + (Get-DevWSInstallerRerunCommand))
        }

        $trustedPowerShell = Resolve-DevWSTrustedPowerShellPath -VerifyRuntime
        Write-Host "  trusted PowerShell: $trustedPowerShell"

        $installRoot    = Get-DevWSInstallRoot
        $privilegedRoot = Get-DevWSPrivilegedInstallRoot
        $metadataPath   = Get-DevWSInstallMetadataPath
        $metadata       = Read-DevWSInstallMetadata -Path $metadataPath
        $specs          = @(Get-DevWSScheduledTaskSpecs `
            -InstallRoot $installRoot `
            -PrivilegedRoot $privilegedRoot `
            -PowerShellPath $trustedPowerShell)

        $preflight = Get-DevWSTaskRepairPreflight `
            -TaskSpecs $specs `
            -Metadata $metadata `
            -MetadataPath $metadataPath `
            -InstallRoot $installRoot `
            -PrivilegedRoot $privilegedRoot

        if (-not $preflight.Ok) {
            throw ("DevWS is not installed sufficiently for a task-only repair:" + [Environment]::NewLine + "  " + (@($preflight.Errors) -join ([Environment]::NewLine + "  ")) + [Environment]::NewLine + "Run install.ps1 (normal mode) instead.")
        }

        $repair = Invoke-DevWSTaskPowerShellRepair `
            -TaskSpecs $specs `
            -Metadata $metadata `
            -MetadataPath $metadataPath

        if ($repair.Status -eq "current") {
            Write-Host "  all five managed tasks and the recorded metadata already use this executable; nothing was changed."
        }
        else {
            Write-Host ("  repaired {0} task(s): {1}" -f @($repair.ChangedTasks).Count, (@($repair.ChangedTasks) -join ", "))
            Write-Host ("  recorded PowerShell path: {0}" -f $repair.PowerShellPath)
            Write-Host ("  metadata: {0}" -f $(if ($repair.MetadataUpdated) { "updated" } else { "already current" }))
            Write-Host ("  broker: {0}" -f $(if (-not $repair.BrokerWasRunning) { "was not running; left stopped (starts on demand or at logon)" } elseif ($repair.BrokerRestarted) { "was running; restarted" } else { "was running; restart deferred" }))
        }

        foreach ($warning in @($repair.Warnings)) {
            Write-Host ("  warning: " + $warning) -ForegroundColor Yellow
        }

        Write-Host ""
        Write-Host "Repair complete. Verify with: install.ps1 -HealthCheck" -ForegroundColor DarkGray
        Write-Host ""

        exit 0
    }

    if ($HealthCheck) {
        Write-DevWSInstallSection "DevWS health check"

        $healthContext = Get-DevWSHealthContext
        $healthContext.PrivilegedStateRoot = Get-DevWSPrivilegedStateRoot

        $summary = Invoke-DevWSHealthCheck -Context $healthContext
        Write-DevWSHealthReport -Summary $summary

        if ($summary.Ok) {
            exit 0
        }

        exit 1
    }

    Write-DevWSInstallSection "DevWS installer"

    if (-not (Test-Path -LiteralPath (Join-Path $RepoRoot "src\ws.ps1") -PathType Leaf)) {
        throw "install.ps1 must run from the DevWS repository root (src\ws.ps1 was not found next to it)."
    }

    # --- Prerequisites and elevation (before any modification) -------------
    Write-Host "Prerequisites:"

    $prerequisites = @(Get-DevWSPrerequisiteResults)

    foreach ($prerequisite in $prerequisites) {
        $marker = "[ok]  "

        if (-not $prerequisite.Ok) {
            $marker = "[FAIL]"
        }

        Write-Host ("  {0} {1}: {2}" -f $marker, $prerequisite.Name, $prerequisite.Message)
    }

    $failedPrerequisites = @($prerequisites | Where-Object { -not $_.Ok })

    if ($failedPrerequisites.Count -gt 0) {
        throw ("Missing prerequisites: " + (@($failedPrerequisites | ForEach-Object { $_.Name }) -join ", ") + ". Install them manually, then re-run.")
    }

    if (-not (Test-DevWSAdministrator)) {
        throw ("The installer must run from an Administrator PowerShell so it can update the five managed DevWS scheduled tasks. Rerun it elevated:" + [Environment]::NewLine + "  " + (Get-DevWSInstallerRerunCommand))
    }

    $installRoot = Get-DevWSInstallRoot

    # Public Security Phase 1: resolve the administrator-protected privileged
    # root and validate the absolute trusted PowerShell executable BEFORE any
    # modification. A failed resolution leaves the machine untouched.
    $privilegedRoot    = Get-DevWSPrivilegedInstallRoot
    $trustedPowerShell = Resolve-DevWSTrustedPowerShellPath -VerifyRuntime

    # --- Explicit config reset confirmation --------------------------------
    if ($ResetConfig -and -not $Force) {
        $existingCanonical = Get-DevWSCanonicalConfigPath

        if (Test-Path -LiteralPath $existingCanonical -PathType Leaf) {
            $answer = Read-Host "Replace the existing canonical workspace config with the bundled default? A timestamped backup is kept in the DevWS state directory. [y/N]"

            if ($answer -notmatch '^(?i:y|yes)$') {
                Write-Host "Cancelled. Nothing was changed." -ForegroundColor DarkGray
                exit 0
            }
        }
    }

    # --- 1. Application files ----------------------------------------------
    Write-DevWSInstallSection "1/9 Application files"

    # A long-lived broker must not keep running while its administrator-
    # protected runtime is replaced. Stop the exact managed task first; it is
    # restarted from the promoted runtime after task registration (step 4).
    $existingBroker = Get-ScheduledTask -TaskName "DevWorkspace-ElevatedBroker" -ErrorAction SilentlyContinue

    if ($null -ne $existingBroker -and [string]$existingBroker.State -eq "Running") {
        try {
            Stop-ScheduledTask -TaskName "DevWorkspace-ElevatedBroker" -ErrorAction Stop
            Write-Host "  stopped the running elevated broker before replacing the privileged runtime"
        }
        catch {
            Write-Host "  warning: could not stop the running elevated broker: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }

    # Generated derived native runtime first: the new source-managed loader
    # requires app\native\DevWS.Native.dll, so a failing native generation must
    # leave the previous installed runtime (and its runtime-compile loader)
    # untouched. The same validated bytes are promoted to the privileged root.
    $nativeRuntime = Install-DevWSNativeRuntime -RepoRoot $RepoRoot -InstallRoot $installRoot -PrivilegedRoot $privilegedRoot
    Write-Host "  generated native runtime: $nativeRuntime"
    Write-Host "  privileged native runtime: $(Get-DevWSPrivilegedNativeDllPath)"

    $installed = @(Install-DevWSApplicationFiles -RepoRoot $RepoRoot -InstallRoot $installRoot)
    Write-Host "  staged $($installed.Count) user-owned source-managed files under $installRoot"

    $privilegedInstalled = @(Install-DevWSPrivilegedFiles -RepoRoot $RepoRoot -PrivilegedRoot $privilegedRoot)
    Write-Host "  staged $($privilegedInstalled.Count) privileged files under $privilegedRoot"

    $missing = @(Get-DevWSMissingInstalledFiles -RepoRoot $RepoRoot -InstallRoot $installRoot)

    if ($missing.Count -gt 0) {
        throw "Installed file check failed; missing: $($missing -join ', ')"
    }

    $privilegedMissing = @(Get-DevWSPrivilegedMissingFiles -RepoRoot $RepoRoot -PrivilegedRoot $privilegedRoot)

    if ($privilegedMissing.Count -gt 0) {
        throw "Privileged runtime check failed; missing: $($privilegedMissing -join ', ')"
    }

    $parseErrors = @(Get-DevWSInstalledPowerShellErrors -InstallRoot $installRoot)

    if ($parseErrors.Count -gt 0) {
        throw ("Installed PowerShell files failed to parse:" + [Environment]::NewLine + "  " + ($parseErrors -join ([Environment]::NewLine + "  ")))
    }

    $privilegedParseErrors = @(Get-DevWSPrivilegedPowerShellErrors -PrivilegedRoot $privilegedRoot)

    if ($privilegedParseErrors.Count -gt 0) {
        throw ("Privileged PowerShell files failed to parse:" + [Environment]::NewLine + "  " + ($privilegedParseErrors -join ([Environment]::NewLine + "  ")))
    }

    Write-Host "  file set verified; all installed and privileged PowerShell files parse"

    # --- Protected privileged-state foundation (Public Security Phase 2-A) --
    # Created only after every prerequisite and every candidate validation
    # above has succeeded. The foundation is deliberately EMPTY in Phase 2-A:
    # no runtime artifact (runtime state, capture artifacts, cwd tracking,
    # worker exchange) uses it yet.
    $protectedState = Initialize-DevWSPrivilegedStateRoot

    foreach ($createdPath in @($protectedState.Created)) {
        Write-Host "  created protected state directory: $createdPath"
    }

    Write-Host "  protected state root: $($protectedState.Root)"

    # --- 2. Canonical config -----------------------------------------------
    Write-DevWSInstallSection "2/9 Workspace config"

    $canonicalPath = Get-DevWSCanonicalConfigPath
    $bundledPath   = Find-DevWSBundledDefaultConfig -StartPath $RepoRoot
    $v1Path        = Join-Path $HOME ".ws\workspace.json"
    $backupRoot    = Get-DevWSBackupRoot

    $plan = Get-DevWSInstallConfigPlan `
        -CanonicalPath $canonicalPath `
        -BundledPath $bundledPath `
        -V1Path $v1Path `
        -ResetConfig:$ResetConfig

    if ($plan.Action -eq "fail") {
        throw $plan.Message
    }

    $configResult = Initialize-DevWSWorkspaceConfig `
        -Plan $plan `
        -CanonicalPath $canonicalPath `
        -BundledPath $bundledPath `
        -V1Path $v1Path `
        -BackupRoot $backupRoot

    Write-Host "  action:  $($configResult.Action)"
    Write-Host "  message: $($configResult.Message)"

    if ($configResult.Backup) {
        Write-Host "  backup:  $($configResult.Backup)"
    }

    $null = Get-DevWSConfig -Location (New-DevWSWritableConfigLocation -Path $canonicalPath)
    Write-Host "  canonical config verified: $canonicalPath"

    # --- 3. Install metadata -----------------------------------------------
    Write-DevWSInstallSection "3/9 Install metadata"

    $metadataPath = Get-DevWSInstallMetadataPath
    $metadata = Read-DevWSInstallMetadata -Path $metadataPath

    if ([string]::IsNullOrWhiteSpace([string]$metadata.installedAt)) {
        $metadata.installedAt = (Get-Date).ToString("o")
    }

    $metadata.installRoot = $installRoot
    $metadata.config.action = $configResult.Action
    $metadata.privileged.root = $privilegedRoot
    $metadata.privileged.powerShellPath = $trustedPowerShell

    if ($configResult.Backup) {
        $metadata.config.backup = $configResult.Backup
    }

    Save-DevWSInstallMetadata -Path $metadataPath -Metadata $metadata
    Write-Host "  metadata: $metadataPath"

    # --- 4. Scheduled tasks ------------------------------------------------
    Write-DevWSInstallSection "4/9 Scheduled tasks"

    $taskResults = @(Install-DevWSScheduledTasks `
        -Specs (Get-DevWSScheduledTaskSpecs -InstallRoot $installRoot -PrivilegedRoot $privilegedRoot -PowerShellPath $trustedPowerShell) `
        -BackupRoot $backupRoot `
        -Metadata $metadata)

    Save-DevWSInstallMetadata -Path $metadataPath -Metadata $metadata

    foreach ($taskResult in $taskResults) {
        $backupText = ""

        if ($taskResult.Backup) {
            $backupText = " (previous definition backed up)"
        }

        Write-Host "  $($taskResult.TaskName)$backupText"
    }

    # The tasks now point exclusively at the privileged runtime; remove the
    # superseded user-writable worker/helper copies so no High code path can
    # ever resolve them again.
    $staleRemoved = @(Remove-DevWSStaleNormalPrivilegedCopies -InstallRoot $installRoot)

    if ($staleRemoved.Count -gt 0) {
        Write-Host "  removed $($staleRemoved.Count) superseded user-writable privileged copies"
    }

    # Restart the managed broker through the existing controlled mechanism so
    # the promoted privileged runtime is live immediately.
    try {
        Start-ScheduledTask -TaskName "DevWorkspace-ElevatedBroker"
        Write-Host "  restarted the elevated broker from the protected runtime"
    }
    catch {
        Write-Host "  note: the elevated broker will start on demand ($($_.Exception.Message))" -ForegroundColor DarkGray
    }

    # --- 5. User PATH ------------------------------------------------------
    Write-DevWSInstallSection "5/9 User PATH"

    $binRoot  = Get-DevWSBinRoot
    $userPath = Get-DevWSUserPathText
    $pathUpdate = Add-DevWSPathEntry -PathText $userPath -Entry $binRoot

    if ($pathUpdate.Added) {
        Set-DevWSUserPathText -PathText $pathUpdate.PathText
        $metadata.path.added = $true
        Write-Host "  added $binRoot to the user PATH"
    }
    else {
        Write-Host "  $binRoot is already on the user PATH"
    }

    if ([string]::IsNullOrWhiteSpace([string]$metadata.path.entry)) {
        $metadata.path.entry = $binRoot
    }

    Save-DevWSInstallMetadata -Path $metadataPath -Metadata $metadata

    # --- 6. Legacy ws.cmd --------------------------------------------------
    Write-DevWSInstallSection "6/9 Legacy ws.cmd"

    $legacyShimPath = Get-DevWSLegacyShimPath
    $shimResult = Install-DevWSLegacyShim `
        -LegacyShimPath $legacyShimPath `
        -ForwardingContent (New-DevWSShimContent -InstallRoot $installRoot) `
        -InstallRoot $installRoot `
        -BackupRoot $backupRoot `
        -Metadata $metadata

    switch ($shimResult.Status) {
        "replaced" {
            $metadata.legacyShim.replaced = $true
            $metadata.legacyShim.path     = $legacyShimPath
            $metadata.legacyShim.backup   = $shimResult.Backup
            Write-Host "  $($shimResult.Message)"
        }
        "owned" {
            $metadata.legacyShim.replaced = $true
            $metadata.legacyShim.path     = $legacyShimPath
            Write-Host "  $($shimResult.Message)"
        }
        "unknown" {
            Write-Host "  warning: $($shimResult.Message)" -ForegroundColor Yellow
        }
        default {
            Write-Host "  $($shimResult.Message)"
        }
    }

    Save-DevWSInstallMetadata -Path $metadataPath -Metadata $metadata

    # --- 7. Hotkey integration ---------------------------------------------
    Write-DevWSInstallSection "7/9 Hotkey integration"

    $hotkeyPath   = Join-Path (Get-DevWSStartupPath) "TerminalShortcut.ahk"
    $bindingsPath = Get-DevWSBindingsAhkPath
    $installConfig = Read-DevWSConfigFile -Path $canonicalPath

    # Derived state first: the core script include must target a file that
    # already exists (even for bindings = []).
    $bindingsResult = Write-DevWSBindingsState `
        -Config $installConfig `
        -AppScriptPath (Get-DevWSInstalledAppScriptPath) `
        -Path $bindingsPath

    if ($bindingsResult.Status -eq "written") {
        Write-Host "  generated set launch hotkeys: $bindingsPath"
    }
    else {
        Write-Host "  set launch hotkeys already current: $bindingsPath"
    }

    $hotkeyContent = New-DevWSTerminalShortcutContent `
        -AppScriptPath (Get-DevWSInstalledAppScriptPath) `
        -BindingsPath $bindingsPath

    $hotkeyResult = Install-DevWSTerminalShortcut `
        -HotkeyPath $hotkeyPath `
        -Content $hotkeyContent `
        -InstallRoot $installRoot `
        -BackupRoot $backupRoot `
        -Metadata $metadata

    if ($hotkeyResult.Status -in @("installed", "updated", "replaced", "current")) {
        $metadata.hotkey.managed = $true
        $metadata.hotkey.path    = $hotkeyPath
    }

    if ($hotkeyResult.Backup) {
        $metadata.hotkey.backup = $hotkeyResult.Backup
    }

    Write-Host "  $($hotkeyResult.Message)"

    if ($hotkeyResult.Status -in @("installed", "updated", "replaced")) {
        [void](Start-DevWSInstalledHotkey -HotkeyPath $hotkeyPath)
        Write-Host "  reloaded it through AutoHotkey v2 (#SingleInstance Force)"
    }

    if ($hotkeyResult.Status -eq "unknown") {
        Write-Host "  warning: unrecognized TerminalShortcut.ahk was left untouched" -ForegroundColor Yellow
    }

    Save-DevWSInstallMetadata -Path $metadataPath -Metadata $metadata

    # --- 8. Health check ---------------------------------------------------
    Write-DevWSInstallSection "8/9 Health check"

    $healthContext = Get-DevWSHealthContext
    $healthContext.PrivilegedStateRoot = [string]$protectedState.Root

    $summary = Invoke-DevWSHealthCheck -Context $healthContext
    Write-DevWSHealthReport -Summary $summary

    if (-not $summary.Ok) {
        throw "Installation files and integrations were applied, but the health check failed: $($summary.FailedIds -join ', '). Review the failing checks above."
    }

    # --- 9. Summary --------------------------------------------------------
    Write-DevWSInstallSection "9/9 Summary"

    Write-Host "  install root:  $installRoot"
    Write-Host "  app:           $(Join-Path $installRoot 'app')"
    Write-Host "  state:         $installRoot\state"
    Write-Host "  bin:           $installRoot\bin"
    Write-Host "  privileged:    $privilegedRoot"
    Write-Host "  protected:     $($protectedState.Root)"
    Write-Host "  powershell:    $trustedPowerShell"
    Write-Host "  config:        $canonicalPath ($($configResult.Action))"
    Write-Host "  tasks:         $(@($taskResults | ForEach-Object { $_.TaskName }) -join ', ')"
    $wtSummary = $null

    try {
        $wtSummary = Resolve-DevWSTrustedWindowsTerminalPath -Installed
    }
    catch {
        $wtSummary = Get-DevWSWindowsTerminalPath
    }

    Write-Host "  terminal:      $wtSummary"
    Write-Host ""
    Write-Host "The legacy v1 directory $(Join-Path $HOME '.ws') was not modified (rollback material)." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "Open a new shell and run:" -ForegroundColor Green
    Write-Host "  ws list"
    Write-Host "  ws launch"
    Write-Host ""
}
catch {
    # Failed-install rollback is exactly scoped: only components created by
    # this invocation are candidates, deepest first, and only while each is
    # still an ordinary, empty, security-valid directory. Everything else -
    # including a pre-existing DevWS container - is preserved.
    if ($null -ne $protectedState -and @($protectedState.Created).Count -gt 0) {
        $rollback = Undo-DevWSProtectedStateCreation -CreatedPaths @($protectedState.Created)

        if (@($rollback.Removed).Count -gt 0) {
            Write-Host ""
            Write-Host "Rolled back newly created protected state directories: $(@($rollback.Removed) -join ', ')" -ForegroundColor Yellow
        }

        if (@($rollback.Preserved).Count -gt 0) {
            Write-Host "Preserved protected state directories that were not removable: $(@($rollback.Preserved) -join ', ')" -ForegroundColor Yellow
        }
    }

    Write-Host ""
    Write-Host "install: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    exit 1
}
