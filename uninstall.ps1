# DevWS uninstaller.
#
# Removes the DevWS-owned runtime under %LOCALAPPDATA%\DevWS and the DevWS-owned
# integrations (five managed scheduled tasks, user PATH entry when this installer added
# it, TerminalShortcut.ahk when DevWS-managed, recognized legacy ws.cmd when a
# backup exists).
#
# Default uninstall preserves:
#   - the canonical workspace config (%USERPROFILE%\.config\devws\workspace.json);
#   - disposable state/backups (removed only with -Purge);
#   - the legacy v1 directory (%USERPROFILE%\.ws) — always;
#   - unrelated Startup scripts, scheduled tasks, Windows Terminal settings,
#     and the PowerShell profile.
#
# Usage:
#   uninstall.ps1              remove DevWS, preserve the workspace config
#   uninstall.ps1 -Purge       also remove canonical config, state, and backups
#   uninstall.ps1 -Force       skip the confirmation prompt

param(
    [switch]$Purge,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

$RepoRoot = $PSScriptRoot
$LibDir   = Join-Path $RepoRoot "src\lib"

foreach ($libName in @(
    "devws-paths.ps1",
    "devws-config.ps1",
    "devws-install.ps1"
)) {
    . (Join-Path $LibDir $libName)
}

try {
    if (-not (Test-DevWSAdministrator)) {
        throw ("The uninstaller must run from an Administrator PowerShell so it can remove the five managed DevWS scheduled tasks. Rerun it elevated:" + [Environment]::NewLine + "  Start-Process pwsh -Verb RunAs -ArgumentList '-NoLogo','-NoProfile','-File','`"" + $PSCommandPath + "`"'")
    }

    $installRoot    = Get-DevWSInstallRoot
    $canonicalPath  = Get-DevWSCanonicalConfigPath
    $legacyShimPath = Get-DevWSLegacyShimPath
    $hotkeyPath     = Join-Path (Get-DevWSStartupPath) "TerminalShortcut.ahk"
    $metadataPath   = Get-DevWSInstallMetadataPath

    $metadata = Read-DevWSInstallMetadata -Path $metadataPath

    $plan = Get-DevWSUninstallPlan `
        -InstallRoot $installRoot `
        -PrivilegedRoot (Get-DevWSPrivilegedInstallRoot) `
        -CanonicalPath $canonicalPath `
        -LegacyShimPath $legacyShimPath `
        -HotkeyPath $hotkeyPath `
        -Metadata $metadata `
        -Purge:$Purge

    Write-Host ""
    Write-Host "DevWS uninstall plan" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  install root:      $installRoot"
    Write-Host "  scheduled tasks:   $($plan.TaskNames -join ', ')"

    if ($plan.RemoveApplicationFiles) {
        Write-Host "  application files: $($plan.AppPath), $($plan.HelpersPath), $($plan.WorkersPath), $($plan.BinPath)"
    }

    if ($plan.RemovePathEntry) {
        Write-Host "  user PATH entry:   remove $($plan.PathEntry)"
    }
    else {
        Write-Host "  user PATH entry:   keep (not added by this installer)"
    }

    if ($plan.RestoreLegacyShim) {
        Write-Host "  legacy ws.cmd:     restore the pre-install shim from backup"
    }
    else {
        Write-Host "  legacy ws.cmd:     no DevWS-owned change"
    }

    if ($plan.RemoveHotkey) {
        Write-Host "  hotkey file:       remove the DevWS-managed TerminalShortcut.ahk"
    }
    elseif ($plan.RestoreHotkey) {
        Write-Host "  hotkey file:       restore the pre-install TerminalShortcut.ahk"
    }
    else {
        Write-Host "  hotkey file:       no DevWS-owned change"
    }

    if ($plan.RemoveCanonicalConfig) {
        Write-Host "  canonical config:  REMOVE (-Purge)" -ForegroundColor Yellow
    }
    else {
        Write-Host "  canonical config:  preserve"
    }

    if ($plan.RemoveState) {
        Write-Host "  disposable state:  REMOVE (-Purge)" -ForegroundColor Yellow
    }
    else {
        Write-Host "  disposable state:  preserve"
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$plan.ProtectedStatePath)) {
        if ($plan.RemoveProtectedState) {
            Write-Host "  protected state:   remove the empty $($plan.ProtectedStatePath)"
        }
        else {
            Write-Host "  protected state:   preserve $($plan.ProtectedStatePath)"
        }
    }

    foreach ($message in @($plan.Messages)) {
        Write-Host "  note:              $message" -ForegroundColor DarkGray
    }

    Write-Host "  v1 rollback dir:   $(Join-Path $HOME '.ws') (always preserved)"
    Write-Host ""

    if (-not $Force) {
        $answer = Read-Host "Continue? [y/N]"

        if ($answer -notmatch '^(?i:y|yes)$') {
            Write-Host "Cancelled. Nothing was changed." -ForegroundColor DarkGray
            exit 0
        }
    }

    $actions = @(Invoke-DevWSUninstall -Plan $plan)

    Write-Host ""

    foreach ($action in $actions) {
        Write-Host "  $action"
    }

    Write-Host ""

    if ($plan.RemoveCanonicalConfig) {
        Write-Host "Workspace config was removed (-Purge)." -ForegroundColor Yellow
    }
    else {
        Write-Host "workspace config preserved" -ForegroundColor Green
    }

    Write-Host "The v1 rollback directory $(Join-Path $HOME '.ws') was preserved." -ForegroundColor Green
    Write-Host ""
}
catch {
    Write-Host ""
    Write-Host "uninstall: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ""
    exit 1
}
