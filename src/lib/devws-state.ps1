# DevWS runtime terminal state.
#
# Runtime state is disposable. It caches the last known top-level HWND for a
# managed terminal so lifecycle operations can validate the window without
# relying on the current visible title. Canonical workspace config must never
# contain HWND/runtime identity data.
#
# State schema v2 keys terminals by scoped identity `<set-id>/<terminal-id>`
# because the same item id may exist in several sets (for example `main/slot`
# and `secondary/slot`). v3 set/item ids cannot contain '/', so the key is
# unambiguous.
#
# Schema v1 (bare terminal-id keys) predates workspace sets and is DISPOSED on
# read: it is treated as an empty v2 state, never migrated. This is safe because
# a terminal's canonical `windowId` remains the durable recoverable identity;
# live discovery simply falls back to the existing UI Automation/windowId flow.
#
# The physical file lives under the DevWS state root (see devws-paths.ps1);
# all callers use these helpers so the location stays in one place.

function Get-DevWSStatePath {
    # Installed layouts route the disposable runtime cache to the protected
    # High-owned publication (Phase 2-B): the legacy LocalAppData runtime state
    # is never authority and is neither migrated nor deleted. The repository
    # layout keeps the historical state-root path so development and the test
    # suite are unchanged.
    if ((Get-DevWSPathsLayout) -ne 'repository') {
        return (Get-DevWSProtectedRuntimeStatePath)
    }

    return (Join-Path (Get-DevWSRuntimeRoot) "runtime-state.json")
}

function Get-DevWSRuntimeTerminalKey {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$SetId,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Id
    )

    # One canonical key builder; callers never concatenate set/item identity
    # themselves. Both parts are required so an unscoped lookup cannot be
    # performed accidentally.
    if ([string]::IsNullOrWhiteSpace($SetId) -or [string]::IsNullOrWhiteSpace($Id)) {
        throw "A terminal runtime-state key requires both a set id and a terminal id."
    }

    return "$SetId/$Id"
}

function New-DevWSRuntimeState {
    return [pscustomobject]@{
        version   = 2
        terminals = [ordered]@{}
    }
}

function Read-DevWSRuntimeState {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = Get-DevWSStatePath
    }
    else {
        Assert-DevWSRuntimeStatePathAllowed -Path $Path
    }

    $state = New-DevWSRuntimeState

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $state
    }

    try {
        $parsed = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        # Corrupt runtime state is disposable: ignore it and start fresh.
        return $state
    }

    if ($null -eq $parsed -or $parsed -isnot [System.Management.Automation.PSCustomObject]) {
        return $state
    }

    # v1 (bare terminal-id keys) and unknown versions are disposed, not
    # migrated: the canonical windowId still recovers live terminals.
    if ($parsed.version -ne 2 -or $null -eq $parsed.terminals) {
        return $state
    }

    foreach ($property in $parsed.terminals.PSObject.Properties) {
        $record = $property.Value

        if ($null -eq $record -or -not (Test-DevWSInteger $record.hwnd)) {
            continue
        }

        $state.terminals[$property.Name] = [pscustomobject]@{
            windowId = [string]$record.windowId
            hwnd     = [long]$record.hwnd
        }
    }

    return $state
}

function Get-DevWSRuntimeTerminal {
    param(
        [Parameter(Mandatory)]
        $State,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$SetId,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Id
    )

    $key = Get-DevWSRuntimeTerminalKey -SetId $SetId -Id $Id

    foreach ($candidate in @($State.terminals.Keys)) {
        if ($candidate -ieq $key) {
            return $State.terminals[$candidate]
        }
    }

    return $null
}

function Set-DevWSRuntimeTerminal {
    param(
        [Parameter(Mandatory)]
        $State,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$SetId,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Id,
        [Parameter(Mandatory)]
        [string]$WindowId,
        [Parameter(Mandatory)]
        $Hwnd
    )

    $key = Get-DevWSRuntimeTerminalKey -SetId $SetId -Id $Id

    foreach ($candidate in @($State.terminals.Keys)) {
        if ($candidate -ieq $key) {
            $State.terminals.Remove($candidate)
        }
    }

    $State.terminals[$key] = [pscustomobject]@{
        windowId = $WindowId
        hwnd     = [long]$Hwnd
    }
}

function Save-DevWSRuntimeState {
    param(
        [Parameter(Mandatory)]
        $State,
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = Get-DevWSStatePath
    }
    else {
        Assert-DevWSRuntimeStatePathAllowed -Path $Path
    }

    $directory = [System.IO.Path]::GetDirectoryName($Path)
    $installed = ((Get-DevWSPathsLayout) -ne 'repository')

    if ($installed) {
        # Installed runtime-cache writes validate the COMPLETE protected P2-A
        # chain before any temporary file or destination write; a missing,
        # drifted or reparse-containing protected root refuses and is NEVER
        # created or modified through an ordinary directory create.
        Assert-DevWSProtectedStateWritable -Root $directory
    }
    elseif (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $json = $State | ConvertTo-Json -Depth 10
    $tempPath = "$Path.tmp"

    # Never write through an unexpected existing filesystem object (a
    # directory or a reparse point) at the temporary or destination pathname.
    foreach ($candidate in @($tempPath, $Path)) {
        if (Test-Path -LiteralPath $candidate) {
            $candidateItem = Get-Item -LiteralPath $candidate -Force

            if ($candidateItem.PSIsContainer -or [bool]($candidateItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                throw "Refusing a runtime-cache write through an unexpected filesystem object at '$candidate'."
            }
        }
    }

    try {
        [System.IO.File]::WriteAllText(
            $tempPath,
            $json + [Environment]::NewLine,
            [System.Text.UTF8Encoding]::new($false)
        )

        # Validate the serialized result before replacing the state file.
        $null = Get-Content -LiteralPath $tempPath -Raw | ConvertFrom-Json

        [System.IO.File]::Move($tempPath, $Path, $true)
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Update-DevWSRuntimeTerminal {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$SetId,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Id,
        [Parameter(Mandatory)]
        [string]$WindowId,
        [Parameter(Mandatory)]
        $Hwnd,
        [string]$Path
    )

    $state = Read-DevWSRuntimeState -Path $Path
    Set-DevWSRuntimeTerminal -State $state -SetId $SetId -Id $Id -WindowId $WindowId -Hwnd $Hwnd
    Save-DevWSRuntimeState -State $state -Path $Path
}
