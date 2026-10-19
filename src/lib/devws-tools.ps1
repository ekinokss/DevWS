# DevWS user-facing tooling: safe config editing, doctor, and app detection.
#
# These helpers are read-only or editor-only conveniences. They never touch
# workspace lifecycle (launch/focus/reset/save-layout), scheduled tasks,
# AutoHotkey, window movement, or runtime HWND state. The only external
# process this module starts is the user's chosen text editor.

# --- editor selection ---

function Test-DevWSVsCodeEditorName {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $false
    }

    $base = [System.IO.Path]::GetFileNameWithoutExtension($Name)

    return ($base -in @("code", "code-insiders", "codium"))
}

function Resolve-DevWSEditorPath {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $null
    }

    if (Test-Path -LiteralPath $Name -PathType Leaf) {
        return (Resolve-Path -LiteralPath $Name).Path
    }

    $command = Get-Command $Name -ErrorAction SilentlyContinue

    if ($null -eq $command) {
        return $null
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$command.Source)) {
        return [string]$command.Source
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$command.Path)) {
        return [string]$command.Path
    }

    return [string]$command.Name
}

function New-DevWSEditorSpec {
    param(
        [Parameter(Mandatory)]
        [string]$Name,
        [Parameter(Mandatory)]
        [string]$Path
    )

    $family    = "other"
    $arguments = @()

    if ((Test-DevWSVsCodeEditorName -Name $Name) -or (Test-DevWSVsCodeEditorName -Name $Path)) {
        # VS Code-family shims need --wait so the temporary file is fully
        # closed before validation reads it back.
        $family    = "vscode"
        $arguments = @("--wait")
    }

    return [pscustomobject]@{
        Name      = $Name
        Path      = $Path
        Family    = $family
        Arguments = $arguments
    }
}

function Get-DevWSEditorSpec {
    param(
        [string]$EditorOverride = $env:DEVWS_EDITOR,
        [string]$PreferredEditor = "code"
    )

    if (-not [string]::IsNullOrWhiteSpace($EditorOverride)) {
        $resolved = Resolve-DevWSEditorPath -Name $EditorOverride

        if ([string]::IsNullOrWhiteSpace($resolved)) {
            throw "Editor '$EditorOverride' from DEVWS_EDITOR was not found. Fix or unset DEVWS_EDITOR."
        }

        return (New-DevWSEditorSpec -Name $EditorOverride -Path $resolved)
    }

    $preferred = Resolve-DevWSEditorPath -Name $PreferredEditor

    if (-not [string]::IsNullOrWhiteSpace($preferred)) {
        return (New-DevWSEditorSpec -Name $PreferredEditor -Path $preferred)
    }

    $notepad = Resolve-DevWSEditorPath -Name "notepad.exe"

    if ([string]::IsNullOrWhiteSpace($notepad)) {
        throw "No text editor found. Set DEVWS_EDITOR or install VS Code; Notepad was not found either."
    }

    return (New-DevWSEditorSpec -Name "notepad.exe" -Path $notepad)
}

function Invoke-DevWSEditorFile {
    param(
        [Parameter(Mandatory)]
        [string]$FilePath,
        [Parameter(Mandatory)]
        $EditorSpec
    )

    $arguments = @()

    foreach ($argument in @($EditorSpec.Arguments)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$argument)) {
            $arguments += [string]$argument
        }
    }

    # Quote the temporary path so spaces survive, and wait for the editing
    # session to finish before reading the file back.
    $arguments += "`"$FilePath`""

    try {
        $process = Start-Process `
            -FilePath $EditorSpec.Path `
            -ArgumentList $arguments `
            -Wait `
            -PassThru
    }
    catch {
        throw "Editor '$($EditorSpec.Name)' could not be started: $($_.Exception.Message)"
    }

    if ($null -eq $process) {
        throw "Editor '$($EditorSpec.Name)' did not report a process; the edit was not completed."
    }

    return [int]$process.ExitCode
}

# --- temporary config editing ---

function Test-DevWSFileBytesEqual {
    param(
        [Parameter(Mandatory)]
        [string]$PathA,
        [Parameter(Mandatory)]
        [string]$PathB
    )

    $bytesA = [System.IO.File]::ReadAllBytes($PathA)
    $bytesB = [System.IO.File]::ReadAllBytes($PathB)

    return ([Convert]::ToBase64String($bytesA) -eq [Convert]::ToBase64String($bytesB))
}

function New-DevWSEditCopy {
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,
        [string]$Directory
    )

    if ([string]::IsNullOrWhiteSpace($Directory)) {
        $Directory = Get-DevWSRuntimeRoot
    }

    if (-not (Test-Path -LiteralPath $Directory -PathType Container)) {
        New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    }

    $target = Join-Path $Directory ("devws-edit-" + [guid]::NewGuid().ToString("N") + ".json")
    Copy-Item -LiteralPath $SourcePath -Destination $target -Force

    return $target
}

function Invoke-DevWSEditSession {
    param(
        [Parameter(Mandatory)]
        $Location,
        $EditorSpec
    )

    Assert-DevWSConfigWritable -Location $Location

    if ($null -eq $EditorSpec) {
        # Resolve the editor before creating any copy: an invalid
        # DEVWS_EDITOR must fail without leaving a temporary file behind.
        $EditorSpec = Get-DevWSEditorSpec
    }

    $tempPath = New-DevWSEditCopy -SourcePath $Location.Path

    try {
        $exitCode = Invoke-DevWSEditorFile -FilePath $tempPath -EditorSpec $EditorSpec
    }
    catch {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        throw
    }

    if ($exitCode -ne 0) {
        $changed = -not (Test-DevWSFileBytesEqual -PathA $Location.Path -PathB $tempPath)

        if (-not $changed) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
            throw "Editor '$($EditorSpec.Name)' exited with code $exitCode.`nCanonical config was not changed."
        }

        throw "Editor '$($EditorSpec.Name)' exited with code $exitCode.`nCanonical config was not changed.`nYour edited copy is preserved at:`n  $tempPath"
    }

    if (Test-DevWSFileBytesEqual -PathA $Location.Path -PathB $tempPath) {
        Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue

        return [pscustomobject]@{
            Status   = "unchanged"
            TempPath = $tempPath
            Config   = $null
        }
    }

    try {
        $config = Read-DevWSConfigFile -Path $tempPath
        Assert-DevWSConfig -Config $config -Source $tempPath
    }
    catch {
        throw "Edited config is invalid: $($_.Exception.Message)`nCanonical config was not changed.`nYour edited copy is preserved at:`n  $tempPath"
    }

    # Established atomic save path: validates the serialized result and
    # replaces the canonical file in one move.
    Save-DevWSConfig -Config $config -Location $Location

    Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue

    return [pscustomobject]@{
        Status   = "saved"
        TempPath = $tempPath
        Config   = $config
    }
}

# --- doctor orchestration ---

function Invoke-DevWSDoctorCheck {
    param(
        # Optional injection points for tests; production callers pass nothing
        # and use the real installed-machine context.
        $Context,
        $Summary,
        [string]$Title = "DevWS doctor"
    )

    if ($null -eq $Summary) {
        if ($null -eq $Context) {
            $Context = Get-DevWSHealthContext
        }

        $Summary = Invoke-DevWSHealthCheck -Context $Context
    }

    Write-Host ""
    Write-Host $Title -ForegroundColor Cyan
    Write-Host ""

    Write-DevWSHealthReport -Summary $Summary

    return $Summary
}

function Get-DevWSDoctorExitCode {
    param(
        [Parameter(Mandatory)]
        $Summary
    )

    if ($Summary.Ok) {
        return 0
    }

    return 1
}

# --- detect-app helpers (Phase 8: ownership-aware top-level windows) ---
#
# Detect-app is read-only diagnostics over the Phase 8 generic visible
# top-level window layer (src\lib\devws-app-window.ps1). There is deliberately
# no second process-based matcher here: one visible top-level HWND is one row,
# and configured matching uses the same runtime match rules as lifecycle.

function Test-DevWSDetectAppFilter {
    param(
        [Parameter(Mandatory)]
        $Candidate,
        [AllowEmptyCollection()]
        [object[]]$Matches = @(),
        [AllowEmptyString()]
        [string]$Filter = ""
    )

    if ([string]::IsNullOrWhiteSpace($Filter)) {
        return $true
    }

    $fields = @(
        [string]$Candidate.processName,
        [string]$Candidate.processPath,
        [string]$Candidate.title,
        [string]$Candidate.class
    )

    if (-not [string]::IsNullOrWhiteSpace([string]$Candidate.processPath)) {
        $fields += [System.IO.Path]::GetFileName([string]$Candidate.processPath)
    }

    foreach ($match in @($Matches)) {
        $mode = [string]$match.InstanceMode

        if ([string]::IsNullOrWhiteSpace($mode)) {
            $mode = "missing"
        }

        $fields += [string]$match.ScopedId
        $fields += ("{0} [{1}]" -f [string]$match.ScopedId, $mode)
    }

    foreach ($field in $fields) {
        if (-not [string]::IsNullOrWhiteSpace($field) -and
            $field.IndexOf($Filter, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            return $true
        }
    }

    return $false
}

function Get-DevWSDetectAppLines {
    param(
        [Parameter(Mandatory)]
        $Candidate,
        [AllowEmptyCollection()]
        [object[]]$Matches = @(),
        $OwnerApp
    )

    $matchList = @($Matches)
    $lines = [System.Collections.Generic.List[string]]::new()

    $processName = [string]$Candidate.processName

    if ([string]::IsNullOrWhiteSpace($processName)) {
        $processName = "(unknown process)"
    }

    $lines.Add($processName)
    $lines.Add(("  hwnd:        {0}" -f [long]$Candidate.hwnd))
    $lines.Add(("  pid:         {0}" -f [uint32]$Candidate.pid))
    $lines.Add(("  title:       {0}" -f [string]$Candidate.title))
    $lines.Add(("  class:       {0}" -f [string]$Candidate.class))

    $exeName = ""

    if (-not [string]::IsNullOrWhiteSpace([string]$Candidate.processPath)) {
        $exeName = [System.IO.Path]::GetFileName([string]$Candidate.processPath)
    }
    elseif ($processName -ne "(unknown process)") {
        $exeName = $processName

        if (-not $exeName.EndsWith(".exe", [StringComparison]::OrdinalIgnoreCase)) {
            $exeName = "$exeName.exe"
        }
    }

    if ([string]::IsNullOrWhiteSpace($exeName)) {
        $lines.Add("  exe:        unavailable")
    }
    else {
        $lines.Add(("  exe:        {0}" -f $exeName))
    }

    if ([string]::IsNullOrWhiteSpace([string]$Candidate.processPath)) {
        $lines.Add("  path:       unavailable")
    }
    else {
        $lines.Add(("  path:       {0}" -f [string]$Candidate.processPath))
    }

    # Ownership is read-only diagnostics: only configured dedicated tags are
    # ever shown; shared windows remain unowned and are never given a fake
    # owner label.
    if (-not [string]::IsNullOrWhiteSpace([string]$Candidate.ownerError)) {
        $lines.Add(("  ownership:  corruption: {0}" -f [string]$Candidate.ownerError))
    }
    elseif (-not [string]::IsNullOrWhiteSpace([string]$Candidate.ownerKey)) {
        $lines.Add(("  ownership:  {0}" -f [string]$Candidate.ownerKey))

        if ($null -eq $OwnerApp) {
            $lines.Add("  owner status: unknown (definition is not in the current config)")
        }
        elseif (-not (Test-DevWSAppWindowMatch -Candidate $Candidate -Match $OwnerApp.match)) {
            $lines.Add("  owner status: mismatch")
        }
    }
    else {
        $lines.Add("  ownership:  (unowned)")
    }

    if ($matchList.Count -eq 0) {
        $lines.Add("  configured: (none)")

        if (-not [string]::IsNullOrWhiteSpace($exeName)) {
            $lines.Add(("  suggested match:  exe {0}" -f $exeName))
        }

        if ([string]::IsNullOrWhiteSpace([string]$Candidate.processPath)) {
            $lines.Add("  suggested launch: unavailable (executable path is unreadable)")
        }
        else {
            $lines.Add(("  suggested launch: exe {0}" -f [string]$Candidate.processPath))
        }
    }
    else {
        $lines.Add("  configured:")

        foreach ($match in $matchList) {
            $mode = [string]$match.InstanceMode

            if ([string]::IsNullOrWhiteSpace($mode)) {
                $mode = "missing"
            }

            $lines.Add(("    {0} [{1}]" -f [string]$match.ScopedId, $mode))
        }
    }

    return $lines.ToArray()
}
