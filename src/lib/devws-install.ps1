# DevWS installer/migration/uninstall helpers.
#
# Every function here is either pure or explicitly parameterized by target
# paths, so the full install/migration/uninstall decision model can be
# exercised in temp fixtures without touching the live machine.
#
# Required libraries (dot-source first): devws-paths.ps1, devws-config.ps1,
# devws-worker-protocol.ps1 (Write-DevWSJsonFile). Install/uninstall entry
# scripts also load devws-health.ps1.

function Get-DevWSScheduledTaskNames {
    return @(
        "DevWorkspace-ElevatedHelper",
        "DevWorkspace-ElevatedCapture",
        "DevWorkspace-ElevatedFocus",
        "DevWorkspace-ElevatedReset",
        "DevWorkspace-ElevatedBroker"
    )
}

function Get-DevWSNamedProperty {
    param(
        $Object,
        [Parameter(Mandatory)]
        [string]$Name
    )

    if ($null -eq $Object) {
        return $null
    }

    foreach ($property in $Object.PSObject.Properties) {
        if ($property.Name -ieq $Name) {
            return $property
        }
    }

    return $null
}

function ConvertFrom-DevWSJsonText {
    param(
        [Parameter(Mandatory)]
        [string]$Text,
        [switch]$KeepDatesAsStrings
    )

    # PowerShell auto-converts ISO timestamps to DateTime while parsing JSON.
    # Metadata must round-trip its timestamp strings unchanged, so use
    # -DateKind String when the runtime supports it (PowerShell 7.5+).
    if ($KeepDatesAsStrings) {
        $command = Get-Command ConvertFrom-Json

        if ($command.Parameters.ContainsKey("DateKind")) {
            return ($Text | ConvertFrom-Json -DateKind String -ErrorAction Stop)
        }
    }

    return ($Text | ConvertFrom-Json -ErrorAction Stop)
}

function Get-DevWSRequiredLibraryNames {
    # Canonical runtime library set that must exist under app\lib. Keep this
    # list in sync with src\lib\*.ps1; the test suite compares both sets so a
    # new library cannot silently escape health coverage.
    return @(
        "devws-ahk.ps1",
        "devws-app.ps1",
        "devws-app-ownership.ps1",
        "devws-app-window.ps1",
        "devws-bindings.ps1",
        "devws-broker-protocol.ps1",
        "devws-capture.ps1",
        "devws-config.ps1",
        "devws-coordinator.ps1",
        "devws-cwd-paths.ps1",
        "devws-cwd.ps1",
        "devws-display.ps1",
        "devws-health.ps1",
        "devws-help.ps1",
        "devws-identity.ps1",
        "devws-install.ps1",
        "devws-launch.ps1",
        "devws-layout-profile.ps1",
        "devws-lifecycle-layout.ps1",
        "devws-lifecycle.ps1",
        "devws-locator.ps1",
        "devws-monitor.ps1",
        "devws-mutation.ps1",
        "devws-native.ps1",
        "devws-paths.ps1",
        "devws-state.ps1",
        "devws-status.ps1",
        "devws-terminal.ps1",
        "devws-terminal-launch.ps1",
        "devws-terminal-operations.ps1",
        "devws-tools.ps1",
        "devws-uia.ps1",
        "devws-window-ops.ps1",
        "devws-worker-protocol.ps1"
    )
}

function Get-DevWSInstallManifest {
    # Normal (user-owned) install surface under %LOCALAPPDATA%\DevWS. The
    # High-reachable workers, the privileged library copies, the High-only
    # helpers and the protected native DLL copy live in the administrator-
    # protected privileged root and are staged from
    # Get-DevWSPrivilegedInstallManifest / Install-DevWSPrivilegedFiles
    # (Public Security Phase 1). The one exception is window-helper.ahk: it is
    # executed at BOTH integrity levels, so each surface stages its own copy.
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot
    )

    $srcRoot = Join-Path $RepoRoot "src"
    $entries = [System.Collections.Generic.List[object]]::new()

    $core = @(
        @{ Source = (Join-Path $srcRoot "ws.ps1"); Target = "app\ws.ps1" },
        @{ Source = (Join-Path $srcRoot "coordinator\coordinator.ps1"); Target = "app\coordinator.ps1" },
        @{ Source = (Join-Path $RepoRoot "config\workspace.default.json"); Target = "app\config\workspace.default.json" },
        @{ Source = (Join-Path $srcRoot "shim\ws.cmd"); Target = "bin\ws.cmd" }
    )

    foreach ($entry in $core) {
        $entries.Add([pscustomobject]@{ Source = $entry.Source; Target = $entry.Target })
    }

    foreach ($file in @(Get-ChildItem -Path (Join-Path $srcRoot "lib") -Filter "*.ps1" -File | Sort-Object Name)) {
        $entries.Add([pscustomobject]@{ Source = $file.FullName; Target = "app\lib\$($file.Name)" })
    }

    foreach ($file in @(Get-ChildItem -Path (Join-Path $srcRoot "helpers") -File | Where-Object { $_.Name -ieq "window-helper.ahk" } | Sort-Object Name)) {
        $entries.Add([pscustomobject]@{ Source = $file.FullName; Target = "helpers\$($file.Name)" })
    }

    return $entries.ToArray()
}

function Get-DevWSPrivilegedInstallManifest {
    # Administrator-protected privileged surface under
    # %ProgramFiles%\DevWS\privileged. Every file here can execute or load in
    # a High DevWS process; the deterministic set is owned by
    # devws-paths.ps1 (Get-DevWSPrivilegedLibraryNames / WorkerNames /
    # HelperNames) and is parity-tested against the worker imports and the
    # normal copies.
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot
    )

    $srcRoot = Join-Path $RepoRoot "src"
    $entries = [System.Collections.Generic.List[object]]::new()

    foreach ($name in @(Get-DevWSPrivilegedLibraryNames)) {
        $entries.Add([pscustomobject]@{ Source = (Join-Path $srcRoot "lib\$name"); Target = "lib\$name" })
    }

    foreach ($name in @(Get-DevWSPrivilegedWorkerNames)) {
        $entries.Add([pscustomobject]@{ Source = (Join-Path $srcRoot "workers\$name"); Target = "workers\$name" })
    }

    foreach ($name in @(Get-DevWSPrivilegedHelperNames)) {
        $entries.Add([pscustomobject]@{ Source = (Join-Path $srcRoot "helpers\$name"); Target = "helpers\$name" })
    }

    return $entries.ToArray()
}

function Install-DevWSApplicationFiles {
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot,
        [Parameter(Mandatory)]
        [string]$InstallRoot
    )

    $installed = [System.Collections.Generic.List[string]]::new()

    foreach ($directory in @("app\lib", "app\config", "helpers", "workers", "bin", "state")) {
        $path = Join-Path $InstallRoot $directory

        if (-not (Test-Path -LiteralPath $path -PathType Container)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }
    }

    foreach ($entry in @(Get-DevWSInstallManifest -RepoRoot $RepoRoot)) {
        if (-not (Test-Path -LiteralPath $entry.Source -PathType Leaf)) {
            throw "Install source is missing: $($entry.Source)"
        }

        $target = Join-Path $InstallRoot $entry.Target

        if ($entry.Target -ieq "bin\ws.cmd") {
            # Generated so every install root (including test overrides) gets a
            # shim that points at its own app\ws.ps1.
            Write-DevWSTextFileAtomic -Path $target -Content (New-DevWSShimContent -InstallRoot $InstallRoot)
        }
        else {
            Copy-Item -LiteralPath $entry.Source -Destination $target -Force
        }

        $installed.Add($target)
    }

    return $installed.ToArray()
}

function Get-DevWSMissingInstalledFiles {
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot,
        [Parameter(Mandatory)]
        [string]$InstallRoot
    )

    $missing = [System.Collections.Generic.List[string]]::new()

    foreach ($entry in @(Get-DevWSInstallManifest -RepoRoot $RepoRoot)) {
        $target = Join-Path $InstallRoot $entry.Target

        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
            $missing.Add($target)
        }
    }

    return $missing.ToArray()
}

function Get-DevWSPrivilegedMissingFiles {
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot,
        [Parameter(Mandatory)]
        [string]$PrivilegedRoot
    )

    $missing = [System.Collections.Generic.List[string]]::new()

    foreach ($entry in @(Get-DevWSPrivilegedInstallManifest -RepoRoot $RepoRoot)) {
        $target = Join-Path $PrivilegedRoot $entry.Target

        if (-not (Test-Path -LiteralPath $target -PathType Leaf)) {
            $missing.Add($target) | Out-Null
        }
    }

    return $missing.ToArray()
}

function Install-DevWSPrivilegedFiles {
    # Stages the administrator-protected privileged runtime. All candidates are
    # copied and parse-validated BEFORE any target is replaced, so a source or
    # validation failure leaves the previous privileged runtime fully intact.
    # Promotion is a per-file atomic replace (candidate + Move); every
    # individual file is therefore always either the old or the new complete
    # content.
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot,
        [Parameter(Mandatory)]
        [string]$PrivilegedRoot
    )

    foreach ($directory in @("lib", "workers", "native", "helpers")) {
        $path = Join-Path $PrivilegedRoot $directory

        if (-not (Test-Path -LiteralPath $path -PathType Container)) {
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        }
    }

    $entries = @(Get-DevWSPrivilegedInstallManifest -RepoRoot $RepoRoot)
    $candidates = [System.Collections.Generic.List[object]]::new()

    try {
        # Phase 1: copy every source to a unique candidate next to its target.
        foreach ($entry in $entries) {
            if (-not (Test-Path -LiteralPath $entry.Source -PathType Leaf)) {
                throw "Privileged install source is missing: $($entry.Source). The previous privileged runtime was left unchanged."
            }

            $target = Join-Path $PrivilegedRoot $entry.Target
            $candidate = "$target.candidate-" + [guid]::NewGuid().ToString("N")

            [System.IO.File]::Copy($entry.Source, $candidate, $true)
            $candidates.Add([pscustomobject]@{ Candidate = $candidate; Target = $target }) | Out-Null
        }

        # Phase 2: validate every candidate before promotion.
        foreach ($candidate in $candidates) {
            if ($candidate.Candidate.EndsWith(".ps1", [StringComparison]::OrdinalIgnoreCase)) {
                $tokens = $null
                $parseErrors = $null

                [void][System.Management.Automation.Language.Parser]::ParseFile($candidate.Candidate, [ref]$tokens, [ref]$parseErrors)

                foreach ($parseError in @($parseErrors)) {
                    throw "Privileged candidate failed to parse ($($candidate.Target):$($parseError.Extent.StartLineNumber)): $($parseError.Message). The previous privileged runtime was left unchanged."
                }
            }
        }

        # Phase 3: promote every candidate with a per-file atomic replace.
        $installed = [System.Collections.Generic.List[string]]::new()

        foreach ($candidate in $candidates) {
            [System.IO.File]::Move($candidate.Candidate, $candidate.Target, $true)
            $installed.Add($candidate.Target)
        }

        return $installed.ToArray()
    }
    finally {
        foreach ($candidate in $candidates) {
            if (Test-Path -LiteralPath $candidate.Candidate -PathType Leaf) {
                Remove-Item -LiteralPath $candidate.Candidate -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Remove-DevWSStaleNormalPrivilegedCopies {
    # Removes the user-writable copies that the privileged root supersedes:
    # <install root>\workers\*.ps1 and the High-only helpers. The medium
    # window-helper.ahk copy stays. Safe on a machine that was never migrated
    # (nothing to remove).
    param(
        [Parameter(Mandatory)]
        [string]$InstallRoot
    )

    $removed = [System.Collections.Generic.List[string]]::new()
    $workers = Join-Path $InstallRoot "workers"

    foreach ($file in @(Get-ChildItem -Path $workers -Filter "*.ps1" -File -ErrorAction SilentlyContinue)) {
        Remove-Item -LiteralPath $file.FullName -Force
        $removed.Add($file.FullName) | Out-Null
    }

    if ((Test-Path -LiteralPath $workers -PathType Container) -and
        @(Get-ChildItem -LiteralPath $workers -Force -ErrorAction SilentlyContinue).Count -eq 0) {
        Remove-Item -LiteralPath $workers -Force
        $removed.Add($workers) | Out-Null
    }

    foreach ($name in @("cwd-shell-bootstrap.ps1", "reset-window.ahk")) {
        $path = Join-Path $InstallRoot ("helpers\" + $name)

        if (Test-Path -LiteralPath $path -PathType Leaf) {
            Remove-Item -LiteralPath $path -Force
            $removed.Add($path) | Out-Null
        }
    }

    return $removed.ToArray()
}

function Get-DevWSInstalledPowerShellErrors {
    param(
        [Parameter(Mandatory)]
        [string]$InstallRoot
    )

    $errors = [System.Collections.Generic.List[string]]::new()
    $directories = @((Join-Path $InstallRoot "app"))

    foreach ($directory in $directories) {
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            continue
        }

        foreach ($file in @(Get-ChildItem -Path $directory -Recurse -Filter "*.ps1" -File)) {
            $tokens = $null
            $parseErrors = $null

            [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)

            foreach ($parseError in @($parseErrors)) {
                $errors.Add("$($file.FullName):$($parseError.Extent.StartLineNumber): $($parseError.Message)")
            }
        }
    }

    return $errors.ToArray()
}

function Get-DevWSPrivilegedPowerShellErrors {
    param(
        [Parameter(Mandatory)]
        [string]$PrivilegedRoot
    )

    $errors = [System.Collections.Generic.List[string]]::new()

    if (-not (Test-Path -LiteralPath $PrivilegedRoot -PathType Container)) {
        return $errors.ToArray()
    }

    foreach ($file in @(Get-ChildItem -Path $PrivilegedRoot -Recurse -Filter "*.ps1" -File)) {
        $tokens = $null
        $parseErrors = $null

        [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)

        foreach ($parseError in @($parseErrors)) {
            $errors.Add("$($file.FullName):$($parseError.Extent.StartLineNumber): $($parseError.Message)")
        }
    }

    return $errors.ToArray()
}

function Get-DevWSNativeSourcePaths {
    # Deterministic ordered list of the tracked C# native declarations that are
    # compiled into the single installed DevWS.Native.dll. None of these files
    # is part of Get-DevWSInstallManifest: the installed DLL is generated
    # derived state, and repeated compilations are byte non-deterministic.
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot
    )

    $nativeRoot = Join-Path $RepoRoot "src\native"

    return @(
        (Join-Path $nativeRoot "devws-window-ops.cs"),
        (Join-Path $nativeRoot "devws-app-window.cs"),
        (Join-Path $nativeRoot "devws-app-ownership.cs"),
        (Join-Path $nativeRoot "devws-app-candidates.cs"),
        (Join-Path $nativeRoot "devws-terminal-candidates.cs"),
        (Join-Path $nativeRoot "devws-broker-pipe.cs"),
        (Join-Path $nativeRoot "devws-monitor.cs"),
        (Join-Path $nativeRoot "devws-privilege-identity.cs"),
        (Join-Path $nativeRoot "devws-worker-pipe-identity.cs")
    )
}

function Get-DevWSInstalledNativeDllPath {
    param(
        [Parameter(Mandatory)]
        [string]$InstallRoot
    )

    return (Join-Path $InstallRoot "app\native\DevWS.Native.dll")
}

function Test-DevWSNativeAssemblyBytes {
    # Structural validation of generated native assembly bytes. Loading from
    # bytes is deliberate: Assembly.LoadFrom would lock the candidate file and
    # complicate safe replacement. Returns an object with Ok and a diagnostic
    # Message so callers can fail actionably.
    param(
        [Parameter(Mandatory)]
        [byte[]]$Bytes
    )

    $staticPublic = [System.Reflection.BindingFlags]::Public -bor [System.Reflection.BindingFlags]::Static

    $requiredFields = @(
        "SW_RESTORE",
        "SWP_NOZORDER",
        "SWP_NOACTIVATE"
    )

    $requiredMethods = @(
        "IsWindow",
        "GetWindowThreadProcessId",
        "IsIconic",
        "IsZoomed",
        "IsWindowVisible",
        "GetWindowRect",
        "FindWindowW",
        "FindWindowByExactTitle",
        "ShowWindow",
        "SetWindowPos"
    )

    $assembly = $null

    try {
        $assembly = [System.Reflection.Assembly]::Load($Bytes)
    }
    catch {
        return [pscustomobject]@{ Ok = $false; Message = "assembly bytes failed to load ($($_.Exception.Message))" }
    }

    $type = $assembly.GetType("DevWSWindowOpsNative", $false)

    if ($null -eq $type) {
        return [pscustomobject]@{ Ok = $false; Message = "type DevWSWindowOpsNative is missing" }
    }

    foreach ($field in $requiredFields) {
        if ($null -eq $type.GetField($field, $staticPublic)) {
            return [pscustomobject]@{ Ok = $false; Message = "field $field is missing" }
        }
    }

    if ($null -eq $type.GetNestedType("RECT")) {
        return [pscustomobject]@{ Ok = $false; Message = "nested type RECT is missing" }
    }

    foreach ($method in $requiredMethods) {
        if ($null -eq $type.GetMethod($method)) {
            return [pscustomobject]@{ Ok = $false; Message = "method $method is missing" }
        }
    }

    # App-window enumeration surface.
    $appWindowType = $assembly.GetType("DevWSAppWindowNative", $false)

    if ($null -eq $appWindowType) {
        return [pscustomobject]@{ Ok = $false; Message = "type DevWSAppWindowNative is missing" }
    }

    if ($null -eq $appWindowType.GetNestedType("EnumWindowsProc")) {
        return [pscustomobject]@{ Ok = $false; Message = "nested type DevWSAppWindowNative+EnumWindowsProc is missing" }
    }

    foreach ($method in @("EnumWindows", "IsWindow", "IsWindowVisible", "GetWindowThreadProcessId", "GetWindowTextW", "GetClassNameW")) {
        if ($null -eq $appWindowType.GetMethod($method)) {
            return [pscustomobject]@{ Ok = $false; Message = "method DevWSAppWindowNative.$method is missing" }
        }
    }

    # Ownership property surface.
    $ownershipType = $assembly.GetType("DevWSAppOwnershipNative", $false)

    if ($null -eq $ownershipType) {
        return [pscustomobject]@{ Ok = $false; Message = "type DevWSAppOwnershipNative is missing" }
    }

    foreach ($method in @("IsWindow", "SetPropW", "GetPropW", "RemovePropW")) {
        if ($null -eq $ownershipType.GetMethod($method)) {
            return [pscustomobject]@{ Ok = $false; Message = "method DevWSAppOwnershipNative.$method is missing" }
        }
    }

    # Candidate fact-record surface.
    $candidateType = $assembly.GetType("DevWSAppWindowCandidate", $false)

    if ($null -eq $candidateType) {
        return [pscustomobject]@{ Ok = $false; Message = "type DevWSAppWindowCandidate is missing" }
    }

    foreach ($property in @("Hwnd", "Pid", "ProcessName", "ProcessPath", "PathUnavailable", "Visible", "Class", "Title")) {
        if ($null -eq $candidateType.GetProperty($property)) {
            return [pscustomobject]@{ Ok = $false; Message = "property DevWSAppWindowCandidate.$property is missing" }
        }
    }

    # Candidate collector surface: static, single bool parameter, returns the
    # fact-record array.
    $collectorType = $assembly.GetType("DevWSAppWindowCandidateCollector", $false)

    if ($null -eq $collectorType) {
        return [pscustomobject]@{ Ok = $false; Message = "type DevWSAppWindowCandidateCollector is missing" }
    }

    $collectMethod = $collectorType.GetMethod("CollectAppWindowCandidates")

    if ($null -eq $collectMethod) {
        return [pscustomobject]@{ Ok = $false; Message = "method DevWSAppWindowCandidateCollector.CollectAppWindowCandidates is missing" }
    }

    $collectParameters = @($collectMethod.GetParameters())

    if ($collectParameters.Count -ne 1 -or $collectParameters[0].ParameterType -ne [bool]) {
        return [pscustomobject]@{ Ok = $false; Message = "method DevWSAppWindowCandidateCollector.CollectAppWindowCandidates has an unexpected signature" }
    }

    if (-not $collectMethod.ReturnType.IsArray -or $collectMethod.ReturnType.GetElementType().FullName -ne "DevWSAppWindowCandidate") {
        return [pscustomobject]@{ Ok = $false; Message = "method DevWSAppWindowCandidateCollector.CollectAppWindowCandidates must return DevWSAppWindowCandidate[]" }
    }

    # Fast Windows Terminal top-level enumeration surface.
    $terminalType = $assembly.GetType("DevWSTerminalNative", $false)

    if ($null -eq $terminalType) {
        return [pscustomobject]@{ Ok = $false; Message = "type DevWSTerminalNative is missing" }
    }

    $terminalMethod = $terminalType.GetMethod("GetWindowsTerminalTopLevelHwnds")

    if ($null -eq $terminalMethod -or $terminalMethod.GetParameters().Count -ne 0 -or
        -not $terminalMethod.ReturnType.IsArray -or $terminalMethod.ReturnType.GetElementType() -ne [long]) {
        return [pscustomobject]@{ Ok = $false; Message = "method DevWSTerminalNative.GetWindowsTerminalTopLevelHwnds is missing or has an unexpected signature" }
    }

    # Secure elevated broker pipe creation surface.
    $pipeType = $assembly.GetType("DevWSBrokerPipeNative", $false)

    if ($null -eq $pipeType) {
        return [pscustomobject]@{ Ok = $false; Message = "type DevWSBrokerPipeNative is missing" }
    }

    $pipeMethod = $pipeType.GetMethod("TryCreateSecurePipe")

    if ($null -eq $pipeMethod) {
        return [pscustomobject]@{ Ok = $false; Message = "method DevWSBrokerPipeNative.TryCreateSecurePipe is missing" }
    }

    $pipeParameters = @($pipeMethod.GetParameters())

    if ($pipeParameters.Count -ne 4 -or
        $pipeParameters[0].ParameterType -ne [string] -or
        $pipeParameters[1].ParameterType -ne [string] -or
        -not $pipeParameters[2].IsOut -or
        $pipeParameters[2].ParameterType -ne [System.IntPtr].MakeByRefType() -or
        -not $pipeParameters[3].IsOut -or
        $pipeParameters[3].ParameterType -ne [int].MakeByRefType() -or
        $pipeMethod.ReturnType -ne [bool]) {
        return [pscustomobject]@{ Ok = $false; Message = "method DevWSBrokerPipeNative.TryCreateSecurePipe has an unexpected signature" }
    }

    if ($null -eq $pipeType.GetNestedType("SECURITY_ATTRIBUTES")) {
        return [pscustomobject]@{ Ok = $false; Message = "nested type DevWSBrokerPipeNative+SECURITY_ATTRIBUTES is missing" }
    }

    # Read-only monitor topology surface (Pass 5B).
    $monitorType = $assembly.GetType("DevWSMonitorNative", $false)

    if ($null -eq $monitorType) {
        return [pscustomobject]@{ Ok = $false; Message = "type DevWSMonitorNative is missing" }
    }

    if ($null -eq $monitorType.GetField("MaxSnapshotAttempts", $staticPublic)) {
        return [pscustomobject]@{ Ok = $false; Message = "field DevWSMonitorNative.MaxSnapshotAttempts is missing" }
    }

    $gdiMethod = $monitorType.GetMethod("GetGdiMonitorRows")

    if ($null -eq $gdiMethod -or $gdiMethod.GetParameters().Count -ne 0 -or
        -not $gdiMethod.ReturnType.IsArray -or
        $gdiMethod.ReturnType.GetElementType().FullName -ne "DevWSMonitorGdiRow") {
        return [pscustomobject]@{ Ok = $false; Message = "method DevWSMonitorNative.GetGdiMonitorRows is missing or has an unexpected signature" }
    }

    $pathMethod = $monitorType.GetMethod("GetActivePathSnapshot")

    if ($null -eq $pathMethod -or $pathMethod.GetParameters().Count -ne 0 -or
        $pathMethod.ReturnType.FullName -ne "DevWSMonitorPathSnapshot") {
        return [pscustomobject]@{ Ok = $false; Message = "method DevWSMonitorNative.GetActivePathSnapshot is missing or has an unexpected signature" }
    }

    $gdiRowType = $assembly.GetType("DevWSMonitorGdiRow", $false)

    if ($null -eq $gdiRowType) {
        return [pscustomobject]@{ Ok = $false; Message = "type DevWSMonitorGdiRow is missing" }
    }

    foreach ($property in @("GdiDeviceName", "Primary", "MonitorLeft", "MonitorTop", "MonitorRight", "MonitorBottom", "WorkLeft", "WorkTop", "WorkRight", "WorkBottom", "DpiOk", "DpiEffectiveX")) {
        if ($null -eq $gdiRowType.GetProperty($property)) {
            return [pscustomobject]@{ Ok = $false; Message = "property DevWSMonitorGdiRow.$property is missing" }
        }
    }

    $pathRowType = $assembly.GetType("DevWSMonitorPathRow", $false)

    if ($null -eq $pathRowType) {
        return [pscustomobject]@{ Ok = $false; Message = "type DevWSMonitorPathRow is missing" }
    }

    foreach ($property in @("GdiDeviceName", "MonitorDevicePath", "FriendlyName", "OutputTechnology", "EdidManufactureId", "EdidProductCodeId", "ConnectorInstance", "SourceModePositionX", "TargetActiveWidth")) {
        if ($null -eq $pathRowType.GetProperty($property)) {
            return [pscustomobject]@{ Ok = $false; Message = "property DevWSMonitorPathRow.$property is missing" }
        }
    }

    $snapshotType = $assembly.GetType("DevWSMonitorPathSnapshot", $false)

    if ($null -eq $snapshotType) {
        return [pscustomobject]@{ Ok = $false; Message = "type DevWSMonitorPathSnapshot is missing" }
    }

    foreach ($property in @("Paths", "Attempts", "ErrorCode")) {
        if ($null -eq $snapshotType.GetProperty($property)) {
            return [pscustomobject]@{ Ok = $false; Message = "property DevWSMonitorPathSnapshot.$property is missing" }
        }
    }

    # Privileged identity surface (Security Phase 1): the OS appmodel package
    # query and the process token integrity read used by High hosts.
    $privilegeType = $assembly.GetType("DevWSPrivilegeNative", $false)

    if ($null -eq $privilegeType) {
        return [pscustomobject]@{ Ok = $false; Message = "type DevWSPrivilegeNative is missing" }
    }

    if ($null -eq $privilegeType.GetField("PackageFilterHead", $staticPublic)) {
        return [pscustomobject]@{ Ok = $false; Message = "field DevWSPrivilegeNative.PackageFilterHead is missing" }
    }

    foreach ($method in @("FindPackagesByPackageFamily", "PackageFamilyNameFromFullName", "GetPackagePathByFullName", "OpenProcessToken", "GetTokenInformation", "ConvertSidToStringSid", "SecureCreateDirectory", "TryOpenPathIdentity", "OpenAndInspectPath", "TryInspectAnchorAccess", "OpenClaimDeleteProbe")) {
        if ($null -eq $privilegeType.GetMethod($method)) {
            return [pscustomobject]@{ Ok = $false; Message = "method DevWSPrivilegeNative.$method is missing" }
        }
    }

    # Worker pipe peer identity surface (Public Security Phase 2-D): the
    # Medium caller authenticates the connected High worker from the pipe
    # handle; PeekNamedPipe backs the deadline-driven bounded frame reader.
    $workerPipeType = $assembly.GetType("DevWSWorkerPipeIdentityNative", $false)

    if ($null -eq $workerPipeType) {
        return [pscustomobject]@{ Ok = $false; Message = "type DevWSWorkerPipeIdentityNative is missing" }
    }

    if ($null -eq $workerPipeType.GetField("ProcessQueryLimitedInformation", $staticPublic)) {
        return [pscustomobject]@{ Ok = $false; Message = "field DevWSWorkerPipeIdentityNative.ProcessQueryLimitedInformation is missing" }
    }

    foreach ($method in @("GetNamedPipeServerProcessId", "GetNamedPipeClientProcessId", "OpenProcess", "CloseHandle", "QueryFullProcessImageNameW", "GetProcessTimes", "PeekNamedPipe", "TryGetCommandLine", "SplitCommandLine", "TryFlushFileBuffers")) {
        if ($null -eq $workerPipeType.GetMethod($method)) {
            return [pscustomobject]@{ Ok = $false; Message = "method DevWSWorkerPipeIdentityNative.$method is missing" }
        }
    }

    return [pscustomobject]@{ Ok = $true; Message = "native surface complete" }
}

function Install-DevWSNativeRuntime {
    # Generates app\native\DevWS.Native.dll from the tracked C# source, then
    # validates and atomically promotes the candidate. The previous known-good
    # DLL is only replaced after the candidate fully passes validation, so a
    # first-upgrade generation failure leaves the existing installed runtime
    # (and its runtime-compile loader) working. When -PrivilegedRoot is given,
    # the same validated bytes are also promoted to
    # <privileged root>\native\DevWS.Native.dll for the High hosts (one
    # assembly, two integrity-level copies, both from the tracked sources).
    param(
        [Parameter(Mandatory)]
        [string]$RepoRoot,
        [Parameter(Mandatory)]
        [string]$InstallRoot,
        [string]$PrivilegedRoot
    )

    $sourcePaths = @(Get-DevWSNativeSourcePaths -RepoRoot $RepoRoot)
    $sourceRoot  = Join-Path $RepoRoot "src\native"
    $targetPath  = Get-DevWSInstalledNativeDllPath -InstallRoot $InstallRoot
    $nativeRoot  = Split-Path -Parent $targetPath

    foreach ($sourcePath in $sourcePaths) {
        if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
            throw "Native interop source is missing: $sourcePath. The installed native runtime was left unchanged."
        }
    }

    if (-not (Test-Path -LiteralPath $nativeRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $nativeRoot -Force | Out-Null
    }

    # Unique candidate on the target volume so promotion is an atomic replace.
    $candidatePath = Join-Path $nativeRoot ("DevWS.Native.candidate-" + [guid]::NewGuid().ToString("N") + ".dll")
    $compileScriptPath = Join-Path $nativeRoot ("DevWS.Native.compile-" + [guid]::NewGuid().ToString("N") + ".ps1")

    try {
        # Compilation runs in a fresh pwsh process: Add-Type refuses to emit an
        # assembly whose type name is already loaded in the caller's session,
        # and generation must succeed regardless of caller session state. The
        # tracked sources travel as an ordered file-name list plus the native
        # root because pwsh -File cannot bind a string array argument directly.
        $compileSource = @'
param(
    [Parameter(Mandatory)][string]$SourceRoot,
    [Parameter(Mandatory)][string]$SourceList,
    [Parameter(Mandatory)][string]$OutputPath
)

$ErrorActionPreference = "Stop"

$sourceFiles = @(
    $SourceList -split ";" |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        ForEach-Object { Join-Path $SourceRoot $_ }
)

Add-Type -Path $sourceFiles -OutputAssembly $OutputPath -OutputType Library -ErrorAction Stop
'@

        [System.IO.File]::WriteAllText($compileScriptPath, $compileSource)

        # The compile child is only ever the trusted, policy-validated
        # PowerShell executable (never PATH resolution).
        $pwshPath = Resolve-DevWSTrustedPowerShellPath

        $sourceList = @($sourcePaths | ForEach-Object { Split-Path -Leaf $_ }) -join ";"

        $compileOutput = & $pwshPath -NoLogo -NoProfile -File $compileScriptPath -SourceRoot $sourceRoot -SourceList $sourceList -OutputPath $candidatePath 2>&1 | Out-String

        if ($LASTEXITCODE -ne 0) {
            throw "Native interop generation failed; the installed native runtime was left unchanged. $($compileOutput.Trim())"
        }

        if (-not (Test-Path -LiteralPath $candidatePath -PathType Leaf)) {
            throw "Native interop generation produced no candidate assembly; the installed native runtime was left unchanged."
        }

        $validation = Test-DevWSNativeAssemblyBytes -Bytes ([System.IO.File]::ReadAllBytes($candidatePath))

        if (-not $validation.Ok) {
            throw "Native interop candidate validation failed ($($validation.Message)); the installed native runtime was left unchanged."
        }

        [System.IO.File]::Move($candidatePath, $targetPath, $true)

        if (-not [string]::IsNullOrWhiteSpace($PrivilegedRoot)) {
            $privilegedNativeRoot = Join-Path $PrivilegedRoot "native"

            if (-not (Test-Path -LiteralPath $privilegedNativeRoot -PathType Container)) {
                New-Item -ItemType Directory -Path $privilegedNativeRoot -Force | Out-Null
            }

            $privilegedTarget    = Join-Path $privilegedNativeRoot "DevWS.Native.dll"
            $privilegedCandidate = Join-Path $privilegedNativeRoot ("DevWS.Native.candidate-" + [guid]::NewGuid().ToString("N") + ".dll")

            try {
                [System.IO.File]::Copy($targetPath, $privilegedCandidate, $true)

                $privilegedValidation = Test-DevWSNativeAssemblyBytes -Bytes ([System.IO.File]::ReadAllBytes($privilegedCandidate))

                if (-not $privilegedValidation.Ok) {
                    throw "Privileged native runtime candidate validation failed ($($privilegedValidation.Message)); the previous privileged native runtime was left unchanged."
                }

                [System.IO.File]::Move($privilegedCandidate, $privilegedTarget, $true)
            }
            finally {
                if (Test-Path -LiteralPath $privilegedCandidate -PathType Leaf) {
                    Remove-Item -LiteralPath $privilegedCandidate -Force -ErrorAction SilentlyContinue
                }
            }
        }
    }
    finally {
        foreach ($artifact in @($candidatePath, $compileScriptPath)) {
            if (Test-Path -LiteralPath $artifact -PathType Leaf) {
                Remove-Item -LiteralPath $artifact -Force -ErrorAction SilentlyContinue
            }
        }
    }

    return $targetPath
}

function Test-DevWSAdministrator {
    try {
        $principal = [Security.Principal.WindowsPrincipal]::new(
            [Security.Principal.WindowsIdentity]::GetCurrent()
        )

        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        return $false
    }
}

function Get-DevWSPrerequisiteResults {
    param(
        [string]$WindowsTerminalPath,
        [string]$AutoHotkeyPath
    )

    if ([string]::IsNullOrWhiteSpace($WindowsTerminalPath)) {
        $WindowsTerminalPath = Get-DevWSWindowsTerminalPath
    }

    if ([string]::IsNullOrWhiteSpace($AutoHotkeyPath)) {
        $AutoHotkeyPath = Get-DevWSAutoHotkeyPath
    }

    $results = [System.Collections.Generic.List[object]]::new()

    $runningOnWindows = $null

    if ($null -ne $IsWindows) {
        # Read the built-in read-only automatic variable; never assign to it.
        $runningOnWindows = [bool]$IsWindows
    }
    else {
        $runningOnWindows = ([System.Environment]::OSVersion.Platform -eq [System.PlatformID]::Win32NT)
    }

    $results.Add([pscustomobject]@{
        Name    = "Windows"
        Ok      = [bool]$runningOnWindows
        Message = [System.Environment]::OSVersion.VersionString
    })

    $psVersion = $PSVersionTable.PSVersion

    $results.Add([pscustomobject]@{
        Name    = "PowerShell 7+"
        Ok      = ($psVersion.Major -ge 7)
        Message = "PowerShell $psVersion"
    })

    # Windows Terminal must be the genuine registered package executable
    # (administrator-protected WindowsApps package): a failed trust resolution
    # fails the prerequisite before any modification. An explicit
    # caller-supplied path is a test/dev override with existence-only
    # semantics.
    $wtOk = $false
    $wtMessage = $WindowsTerminalPath

    if ($PSBoundParameters.ContainsKey("WindowsTerminalPath")) {
        $wtOk = (Test-Path -LiteralPath $WindowsTerminalPath -PathType Leaf)
    }
    else {
        try {
            $wtMessage = Resolve-DevWSTrustedWindowsTerminalPath -Installed
            $wtOk = $true
        }
        catch {
            $wtOk = $false
            $wtMessage = $_.Exception.Message
        }
    }

    $results.Add([pscustomobject]@{
        Name    = "Windows Terminal"
        Ok      = $wtOk
        Message = $wtMessage
    })

    $results.Add([pscustomobject]@{
        Name    = "AutoHotkey v2"
        Ok      = (Test-Path -LiteralPath $AutoHotkeyPath -PathType Leaf)
        Message = $AutoHotkeyPath
    })

    return $results.ToArray()
}

function Write-DevWSBytesAtomic {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [byte[]]$Bytes
    )

    $directory = [System.IO.Path]::GetDirectoryName($Path)

    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $tempPath = "$Path.tmp"

    try {
        [System.IO.File]::WriteAllBytes($tempPath, $Bytes)
        [System.IO.File]::Move($tempPath, $Path, $true)
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Write-DevWSTextFileAtomic {
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Content
    )

    Write-DevWSBytesAtomic -Path $Path -Bytes ([System.Text.UTF8Encoding]::new($false).GetBytes($Content))
}

function Copy-DevWSFileToBackup {
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,
        [Parameter(Mandatory)]
        [string]$BackupRoot,
        [Parameter(Mandatory)]
        [string]$Prefix,
        [string]$Extension = ".bak"
    )

    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
        throw "Cannot back up a missing file: $SourcePath"
    }

    if (-not (Test-Path -LiteralPath $BackupRoot -PathType Container)) {
        New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
    }

    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $suffix = [guid]::NewGuid().ToString("N").Substring(0, 8)
    $target = Join-Path $BackupRoot "$Prefix-$stamp-$suffix$Extension"

    [System.IO.File]::Copy($SourcePath, $target, $true)

    return $target
}

# ---------------------------------------------------------------------------
# v1 recognition and migration
# ---------------------------------------------------------------------------

function Get-DevWSV1LayoutErrors {
    param($Layout)

    $errors = [System.Collections.Generic.List[string]]::new()

    if ($null -eq $Layout -or $Layout -isnot [System.Management.Automation.PSCustomObject]) {
        $errors.Add("layout must be an object with integer x, y, w, h.")
        return $errors.ToArray()
    }

    foreach ($property in $Layout.PSObject.Properties) {
        if ($property.Name -notin @("x", "y", "w", "h")) {
            $errors.Add("layout has unexpected property '$($property.Name)'.")
        }
    }

    foreach ($field in @("x", "y", "w", "h")) {
        $value = if ($null -ne (Get-DevWSNamedProperty -Object $Layout -Name $field)) {
            (Get-DevWSNamedProperty -Object $Layout -Name $field).Value
        }
        else {
            $null
        }

        if (-not (Test-DevWSInteger $value)) {
            $errors.Add("layout.$field must be an integer.")
        }
    }

    $width = if ($null -ne (Get-DevWSNamedProperty -Object $Layout -Name "w")) { (Get-DevWSNamedProperty -Object $Layout -Name "w").Value } else { $null }
    $height = if ($null -ne (Get-DevWSNamedProperty -Object $Layout -Name "h")) { (Get-DevWSNamedProperty -Object $Layout -Name "h").Value } else { $null }

    if ((Test-DevWSInteger $width) -and [int]$width -le 0) {
        $errors.Add("layout.w must be greater than 0.")
    }

    if ((Test-DevWSInteger $height) -and [int]$height -le 0) {
        $errors.Add("layout.h must be greater than 0.")
    }

    return $errors.ToArray()
}

function Get-DevWSV1ConfigErrors {
    param(
        [Parameter(Mandatory)]
        $Config,
        [Parameter(Mandatory)]
        $Template
    )

    $errors = [System.Collections.Generic.List[string]]::new()

    if ($null -eq $Config -or $Config -isnot [System.Management.Automation.PSCustomObject]) {
        $errors.Add("root must be a JSON object.")
        return $errors.ToArray()
    }

    foreach ($property in $Config.PSObject.Properties) {
        if ($property.Name -notin @("version", "terminals", "apps")) {
            $errors.Add("unexpected top-level property '$($property.Name)'.")
        }
    }

    $version = Get-DevWSNamedProperty -Object $Config -Name "version"

    if ($null -eq $version -or -not (Test-DevWSInteger $version.Value) -or [int]$version.Value -ne 1) {
        $errors.Add("'version' must be 1.")
    }

    $templateSet       = Get-DevWSDefaultSet -Config $Template
    $templateTerminals = @($templateSet.windows | Where-Object { $_.type -eq "terminal" })
    $templateApps      = @($templateSet.windows | Where-Object { $_.type -eq "app" })

    $terminals = Get-DevWSNamedProperty -Object $Config -Name "terminals"

    if ($null -eq $terminals -or $terminals.Value -isnot [array]) {
        $errors.Add("'terminals' must be an array.")
    }
    else {
        $slots = [System.Collections.Generic.List[int]]::new()

        for ($i = 0; $i -lt @($terminals.Value).Count; $i++) {
            $terminal = @($terminals.Value)[$i]
            $label = "terminals[$i]"

            if ($null -eq $terminal -or $terminal -isnot [System.Management.Automation.PSCustomObject]) {
                $errors.Add("$label must be an object.")
                continue
            }

            foreach ($property in $terminal.PSObject.Properties) {
                if ($property.Name -notin @("slot", "windowId", "path", "layout")) {
                    $errors.Add("$label has unexpected property '$($property.Name)'.")
                }
            }

            $slot = Get-DevWSNamedProperty -Object $terminal -Name "slot"

            if ($null -eq $slot -or -not (Test-DevWSInteger $slot.Value) -or [int]$slot.Value -lt 1) {
                $errors.Add("$label 'slot' must be a positive integer.")
            }
            elseif ($slots.Contains([int]$slot.Value)) {
                $errors.Add("$label duplicate slot $($slot.Value).")
            }
            else {
                $slots.Add([int]$slot.Value)
            }

            $windowId = Get-DevWSNamedProperty -Object $terminal -Name "windowId"

            if ($null -eq $windowId -or $windowId.Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$windowId.Value)) {
                $errors.Add("$label 'windowId' must be a non-empty string.")
            }

            $path = Get-DevWSNamedProperty -Object $terminal -Name "path"

            if ($null -eq $path -or $path.Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$path.Value)) {
                $errors.Add("$label 'path' must be a non-empty string.")
            }

            $layout = Get-DevWSNamedProperty -Object $terminal -Name "layout"

            foreach ($layoutError in @(Get-DevWSV1LayoutErrors -Layout $(if ($null -ne $layout) { $layout.Value } else { $null }))) {
                $errors.Add("$label $layoutError")
            }
        }

        if ($slots.Count -ge 0) {
            $expected = @()

            for ($slotNumber = 1; $slotNumber -le $templateTerminals.Count; $slotNumber++) {
                $expected += $slotNumber
            }

            $sorted = @($slots | Sort-Object)

            if (($sorted -join ",") -ne ($expected -join ",")) {
                $errors.Add("terminal slots must be exactly $($expected -join ', ') (found: $($sorted -join ', ')).")
            }
        }
    }

    $apps = Get-DevWSNamedProperty -Object $Config -Name "apps"

    if ($null -eq $apps -or $apps.Value -isnot [System.Management.Automation.PSCustomObject]) {
        $errors.Add("'apps' must be an object.")
    }
    else {
        foreach ($property in $apps.Value.PSObject.Properties) {
            $templateApp = $null

            foreach ($candidate in $templateApps) {
                if ([string]$candidate.id -ieq $property.Name) {
                    $templateApp = $candidate
                    break
                }
            }

            if ($null -eq $templateApp) {
                $errors.Add("apps has unrecognized key '$($property.Name)'.")
            }
        }

        foreach ($templateApp in $templateApps) {
            $appProperty = Get-DevWSNamedProperty -Object $apps.Value -Name ([string]$templateApp.id)
            $label = "apps.$($templateApp.id)"

            if ($null -eq $appProperty) {
                $errors.Add("missing recognized app '$($templateApp.id)'.")
                continue
            }

            $app = $appProperty.Value

            if ($null -eq $app -or $app -isnot [System.Management.Automation.PSCustomObject]) {
                $errors.Add("$label must be an object.")
                continue
            }

            $launchKind = [string]$templateApp.launch.kind
            $valueName = if ($launchKind -eq "appId") { "appId" } else { "executable" }
            $allowed = @($valueName, "layout")

            foreach ($property in $app.PSObject.Properties) {
                if ($property.Name -notin $allowed) {
                    $errors.Add("$label has unexpected property '$($property.Name)'.")
                }
            }

            $value = Get-DevWSNamedProperty -Object $app -Name $valueName

            if ($null -eq $value -or $value.Value -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$value.Value)) {
                $errors.Add("$label '$valueName' must be a non-empty string.")
            }

            $layout = Get-DevWSNamedProperty -Object $app -Name "layout"

            foreach ($layoutError in @(Get-DevWSV1LayoutErrors -Layout $(if ($null -ne $layout) { $layout.Value } else { $null }))) {
                $errors.Add("$label $layoutError")
            }
        }
    }

    return $errors.ToArray()
}

function Assert-DevWSV1Config {
    param(
        [Parameter(Mandatory)]
        $Config,
        [Parameter(Mandatory)]
        $Template
    )

    $errors = @(Get-DevWSV1ConfigErrors -Config $Config -Template $Template)

    if ($errors.Count -gt 0) {
        throw ("Unrecognized DevWS v1 workspace config:" + [Environment]::NewLine + "  - " + ($errors -join ([Environment]::NewLine + "  - ")))
    }

    return $true
}

function Set-DevWSEnrichedAppDefinition {
    param(
        [Parameter(Mandatory)]
        $Set,
        [Parameter(Mandatory)]
        $Item,
        [Parameter(Mandatory)]
        [string]$Mode
    )

    # Replace the app definition inside its set with a canonical-order object
    # (id, type, enabled, match, launch, instanceMode, layout) so enriched
    # configs are deterministic and match the bundled default ordering.
    $rebuilt = [pscustomobject][ordered]@{
        id           = [string]$Item.id
        type         = "app"
        enabled      = [bool]$Item.enabled
        match        = $Item.match
        launch       = $Item.launch
        instanceMode = $Mode
        layout       = $Item.layout
    }

    $windows = @($Set.windows)

    for ($i = 0; $i -lt $windows.Count; $i++) {
        if ([object]::ReferenceEquals($windows[$i], $Item)) {
            $windows[$i] = $rebuilt
            $Set.windows = $windows
            return
        }
    }

    throw "Could not locate app '$($Item.id)' in set '$($Set.id)' while adding its instance mode."
}

function ConvertTo-DevWSConfigWithExplicitInstanceModes {
    param(
        [Parameter(Mandatory)]
        $Config,
        [Parameter(Mandatory)]
        $BundledTemplate
    )

    # Deterministic installer/migration enrichment for a structurally valid v3
    # config that predates mandatory app instance modes. Returns a deep
    # independent copy; the source object is never mutated, and any failure
    # leaves it untouched.
    #
    # Policy (ordered, never capability detection):
    #   1. an explicit mode already present for the app id propagates to every
    #      missing definition of the same id (shared requires strict
    #      equivalence);
    #   2. otherwise a bundled-default app with the same id may supply its mode
    #      when every definition matches it on match/launch fields;
    #   3. otherwise a single-occurrence app becomes dedicated;
    #   4. otherwise enrichment fails safely.
    $working = ConvertFrom-Json (ConvertTo-Json -InputObject $Config -Depth 20)

    $templateApps = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)

    foreach ($set in @(Get-DevWSSets -Config $BundledTemplate)) {
        if ($null -eq $set) {
            continue
        }

        foreach ($item in @($set.windows)) {
            if ($null -eq $item -or $item.type -ne "app") {
                continue
            }

            if (-not (Test-DevWSProperty -Object $item -Name "instanceMode")) {
                continue
            }

            $templateId = [string]$item.id

            if (-not $templateApps.ContainsKey($templateId)) {
                $templateApps[$templateId] = $item
            }
        }
    }

    $groupMap   = [System.Collections.Generic.Dictionary[string, object]]::new([System.StringComparer]::OrdinalIgnoreCase)
    $groupOrder = [System.Collections.Generic.List[string]]::new()

    foreach ($set in @(Get-DevWSSets -Config $working)) {
        if ($null -eq $set) {
            continue
        }

        foreach ($item in @($set.windows)) {
            if ($null -eq $item -or $item.type -ne "app") {
                continue
            }

            $appId = [string]$item.id

            if (-not $groupMap.ContainsKey($appId)) {
                $groupMap[$appId] = [System.Collections.Generic.List[object]]::new()
                $groupOrder.Add($appId) | Out-Null
            }

            $groupMap[$appId].Add([pscustomobject]@{
                SetId = [string]$set.id
                Set   = $set
                Item  = $item
            }) | Out-Null
        }
    }

    foreach ($appId in $groupOrder) {
        $entries = @($groupMap[$appId])

        $explicitModes = @(
            $entries |
                Where-Object { Test-DevWSProperty -Object $_.Item -Name "instanceMode" } |
                ForEach-Object { ([string]$_.Item.instanceMode).ToLowerInvariant() } |
                Sort-Object -Unique
        )

        if ($explicitModes.Count -gt 0) {
            # Rule 1: propagate the already-agreed explicit mode.
            if ($explicitModes.Count -gt 1) {
                $refs = @($entries | ForEach-Object { "$($_.SetId)/$($_.Item.id)" }) -join ", "
                throw "Cannot add instance modes for app id '$appId': conflicting explicit modes exist across sets ($refs)."
            }

            $mode = $explicitModes[0]

            if ($mode -eq "shared") {
                $reference = $entries[0]

                foreach ($entry in $entries) {
                    $difference = Get-DevWSSharedAppDefinitionDifference -First $reference.Item -Second $entry.Item

                    if ($difference) {
                        throw "Cannot add instance modes for app id '$appId': the explicit 'shared' definition in set '$($reference.SetId)' is not equivalent to the definition in set '$($entry.SetId)' (differs on '$difference'). Shared definitions must match on match/launch fields."
                    }
                }
            }

            foreach ($entry in $entries) {
                if (-not (Test-DevWSProperty -Object $entry.Item -Name "instanceMode")) {
                    Set-DevWSEnrichedAppDefinition -Set $entry.Set -Item $entry.Item -Mode $mode
                }
            }

            continue
        }

        # Rule 2: deterministic bundled-template match for the whole group.
        if ($templateApps.ContainsKey($appId)) {
            $template = $templateApps[$appId]
            $templateMatches = $true

            foreach ($entry in $entries) {
                $difference = Get-DevWSSharedAppDefinitionDifference -First $template -Second $entry.Item

                if ($difference) {
                    $templateMatches = $false
                    break
                }
            }

            if ($templateMatches) {
                $templateMode = ([string]$template.instanceMode).ToLowerInvariant()

                foreach ($entry in $entries) {
                    Set-DevWSEnrichedAppDefinition -Set $entry.Set -Item $entry.Item -Mode $templateMode
                }

                continue
            }
        }

        # Rule 3: a single occurrence is a safe deterministic default.
        if ($entries.Count -eq 1) {
            Set-DevWSEnrichedAppDefinition -Set $entries[0].Set -Item $entries[0].Item -Mode "dedicated"
            continue
        }

        # Rule 4: never guess shared vs dedicated across sets.
        $refs = @($entries | ForEach-Object { "$($_.SetId)/$($_.Item.id)" }) -join ", "
        throw "Cannot infer instanceMode for app id '$appId': it appears in multiple sets without an explicit mode and does not match the bundled default definition ($refs). Set an explicit mode (for example with 'ws set-instance-mode $appId <dedicated|shared>') and retry."
    }

    return $working
}

function Convert-DevWSV1ConfigToV3 {
    param(
        [Parameter(Mandatory)]
        $V1Config,
        [Parameter(Mandatory)]
        $Template
    )

    Assert-DevWSV1Config -Config $V1Config -Template $Template | Out-Null

    # The bundled v3 default is the semantic template: terminal order maps to
    # v1 slots 1..N and app ids match v1 app keys. Nothing here duplicates
    # command/app constants; they come from the checked-in default's default
    # set.
    $templateSet       = Get-DevWSDefaultSet -Config $Template
    $templateTerminals = @($templateSet.windows | Where-Object { $_.type -eq "terminal" })
    $templateApps      = @($templateSet.windows | Where-Object { $_.type -eq "app" })

    $windows = [System.Collections.Generic.List[object]]::new()

    for ($i = 0; $i -lt $templateTerminals.Count; $i++) {
        $slotNumber = $i + 1
        $v1Terminal = @($V1Config.terminals | Where-Object { [int]$_.slot -eq $slotNumber })[0]
        $templateTerminal = $templateTerminals[$i]

        $tabs = [System.Collections.Generic.List[object]]::new()

        foreach ($tab in @($templateTerminal.tabs)) {
            $tabs.Add([pscustomobject][ordered]@{
                command = $tab.command
                args    = @($tab.args)
            })
        }

        $windows.Add([pscustomobject][ordered]@{
            id        = [string]$templateTerminal.id
            type      = "terminal"
            enabled   = $true
            windowId  = [string]$v1Terminal.windowId
            path      = [string]$v1Terminal.path
            elevated  = [bool]$templateTerminal.elevated
            tabs      = @($tabs.ToArray())
            activeTab = [int]$templateTerminal.activeTab
            layout    = [pscustomobject][ordered]@{
                x = [int]$v1Terminal.layout.x
                y = [int]$v1Terminal.layout.y
                w = [int]$v1Terminal.layout.w
                h = [int]$v1Terminal.layout.h
            }
        })
    }

    foreach ($templateApp in $templateApps) {
        $v1AppProperty = Get-DevWSNamedProperty -Object $V1Config.apps -Name ([string]$templateApp.id)
        $v1App = $v1AppProperty.Value
        $launchKind = [string]$templateApp.launch.kind
        $valueName = if ($launchKind -eq "appId") { "appId" } else { "executable" }
        $launchValue = [string](Get-DevWSNamedProperty -Object $v1App -Name $valueName).Value

        $windows.Add([pscustomobject][ordered]@{
            id      = [string]$templateApp.id
            type    = "app"
            enabled = $true
            match   = [pscustomobject][ordered]@{
                kind  = [string]$templateApp.match.kind
                value = [string]$templateApp.match.value
            }
            launch  = [pscustomobject][ordered]@{
                kind  = $launchKind
                value = $launchValue
                args  = @()
            }
            layout  = [pscustomobject][ordered]@{
                x = [int]$v1App.layout.x
                y = [int]$v1App.layout.y
                w = [int]$v1App.layout.w
                h = [int]$v1App.layout.h
            }
        })
    }

    $migrated = [pscustomobject][ordered]@{
        version    = 3
        defaultSet = [string]$Template.defaultSet
        bindings   = @()
        sets       = @(
            [pscustomobject][ordered]@{
                id      = [string]$Template.defaultSet
                windows = @($windows.ToArray())
            }
        )
    }

    # v3 now requires explicit app instance modes; the v1 app definitions are
    # the bundled template's own definitions, so the locked personal modes are
    # derived deterministically from that template.
    $enriched = ConvertTo-DevWSConfigWithExplicitInstanceModes -Config $migrated -BundledTemplate $Template
    Assert-DevWSConfig -Config $enriched -Source "v1 migration"

    return $enriched
}

function Convert-DevWSV2ConfigToV3 {
    param(
        [Parameter(Mandatory)]
        $V2Config,
        [Parameter(Mandatory)]
        $Template
    )

    # Pure deterministic wrap: the v2 workspace becomes the single `main` set.
    # Window order, item definitions, windowId values, layouts, tabs, activeTab,
    # enabled flags, and app match/launch definitions are preserved exactly;
    # no values are regenerated or normalized. App instance modes are then
    # derived deterministically (bundled-template match, otherwise the
    # single-workspace app becomes dedicated).
    Assert-DevWSV2Config -Config $V2Config -Source "v2 migration" | Out-Null

    $migrated = [pscustomobject][ordered]@{
        version    = 3
        defaultSet = "main"
        bindings   = @()
        sets       = @(
            [pscustomobject][ordered]@{
                id      = "main"
                windows = @($V2Config.windows)
            }
        )
    }

    # The resulting v3 object must pass the real v3 validator. A config can be
    # valid v2 yet not representable as valid v3 (for example a manually edited
    # item id such as 'foo/bar', or a digit-only app id). Fail with migration
    # guidance instead of renaming, normalizing, or dropping anything.
    try {
        $migrated = ConvertTo-DevWSConfigWithExplicitInstanceModes -Config $migrated -BundledTemplate $Template
        Assert-DevWSConfig -Config $migrated -Source "v2 migration"
    }
    catch {
        throw (
            "The workspace config is valid v2 but cannot be migrated automatically to v3 because it contains item definitions that are not valid under the v3 stable-id rules. " +
            "Rename the affected item(s) while still using the v2 runtime, or run the installer with -ResetConfig if you deliberately want to replace the configuration. " +
            "The canonical config was not modified." +
            [Environment]::NewLine +
            $_.Exception.Message
        )
    }

    return $migrated
}

# ---------------------------------------------------------------------------
# Canonical config decision and installation
# ---------------------------------------------------------------------------

function New-DevWSWritableConfigLocation {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    return [pscustomobject]@{
        Path             = $Path
        Source           = "install"
        IsBundledDefault = $false
        IsWritable       = $true
        Warning          = $null
    }
}

function Get-DevWSInstallConfigPlan {
    param(
        [Parameter(Mandatory)]
        [string]$CanonicalPath,
        [Parameter(Mandatory)]
        [string]$BundledPath,
        [Parameter(Mandatory)]
        [string]$V1Path,
        [switch]$ResetConfig
    )

    $canonicalExists = Test-Path -LiteralPath $CanonicalPath -PathType Leaf
    $v1Exists        = Test-Path -LiteralPath $V1Path -PathType Leaf

    $plan = [ordered]@{
        Action           = "fail"
        Message          = ""
        CanonicalExists  = $canonicalExists
        CanonicalValid   = $false
        CanonicalSchema  = 0
        CanonicalV2      = $false
        CanonicalPreInstanceMode = $false
        V1Exists         = $v1Exists
        V1Recognized     = $false
        ResetRequested   = [bool]$ResetConfig
    }

    if ($ResetConfig) {
        $plan.Action  = "reset"
        $plan.Message = "Explicit -ResetConfig: install the bundled default config."
        return [pscustomobject]$plan
    }

    if ($canonicalExists) {
        # Canonical config is authoritative: it is either a valid v3 config to
        # preserve, a valid v2 config to migrate, or an invalid file that must
        # fail safely. It never falls through to v1/default migration.
        $canonicalConfig = $null
        $readError       = $null

        try {
            $canonicalConfig = Read-DevWSConfigFile -Path $CanonicalPath
        }
        catch {
            $readError = $_.Exception.Message
        }

        if ($null -ne $canonicalConfig) {
            $v3Error = $null

            try {
                Assert-DevWSConfig -Config $canonicalConfig -Source $CanonicalPath
                $plan.Action         = "preserve"
                $plan.CanonicalValid = $true
                $plan.CanonicalSchema = 3
                $plan.Message        = "Existing canonical config is valid and will be preserved."
                return [pscustomobject]$plan
            }
            catch {
                $v3Error = $_.Exception.Message
            }

            # Installer-only recognition: a historical Phase 7 v3 config is
            # structurally valid but predates mandatory app instance modes. It
            # is enriched deterministically (or the plan fails safely); the
            # runtime validator stays strict.
            try {
                Assert-DevWSPreInstanceModeV3Config -Config $canonicalConfig -Source $CanonicalPath

                $plan.CanonicalValid           = $true
                $plan.CanonicalSchema          = 3
                $plan.CanonicalPreInstanceMode = $true

                try {
                    if (-not (Test-Path -LiteralPath $BundledPath -PathType Leaf)) {
                        throw "Bundled default config not found: $BundledPath"
                    }

                    $template = Read-DevWSConfigFile -Path $BundledPath
                    $enriched = ConvertTo-DevWSConfigWithExplicitInstanceModes -Config $canonicalConfig -BundledTemplate $template
                    Assert-DevWSConfig -Config $enriched -Source "instance-mode enrichment plan"

                    $plan.Action  = "enrich-v3-instance-modes"
                    $plan.Message = "Historical v3 config recognized; explicit app instance modes will be added deterministically and the original canonical bytes will be backed up first."
                }
                catch {
                    $plan.Action  = "fail"
                    $plan.Message = "Canonical config '$CanonicalPath' is a historical v3 config without explicit app instance modes, but the modes cannot be inferred safely; it was NOT modified. $($_.Exception.Message)"
                }

                return [pscustomobject]$plan
            }
            catch {
                # Not a pre-mode v3 config; fall through to v2 recognition.
            }

            try {
                Assert-DevWSV2Config -Config $canonicalConfig -Source $CanonicalPath
                $plan.CanonicalSchema = 2
                $plan.CanonicalV2     = $true

                try {
                    if (-not (Test-Path -LiteralPath $BundledPath -PathType Leaf)) {
                        throw "Bundled default config not found: $BundledPath"
                    }

                    $template = Read-DevWSConfigFile -Path $BundledPath
                    $null = Convert-DevWSV2ConfigToV3 -V2Config $canonicalConfig -Template $template
                    $plan.Action  = "migrate-v2"
                    $plan.Message = "Existing canonical config uses the supported v2 schema; it will be backed up and migrated to v3 (window identities preserved, explicit app instance modes added)."
                }
                catch {
                    # Valid v2 but not representable as valid v3: fail the plan
                    # before anything can be overwritten.
                    $plan.Action  = "fail"
                    $plan.Message = "Canonical config '$CanonicalPath' is valid v2 but cannot be migrated automatically to v3; it was NOT modified. $($_.Exception.Message)"
                }

                return [pscustomobject]$plan
            }
            catch {
                $plan.Message = "Canonical config '$CanonicalPath' exists but is invalid (neither v3 nor v2); it was NOT modified. Fix it or re-run with -ResetConfig. Details: $v3Error"
                return [pscustomobject]$plan
            }
        }

        $plan.Message = "Canonical config '$CanonicalPath' exists but is invalid (unreadable JSON); it was NOT modified. Fix it or re-run with -ResetConfig. Details: $readError"
        return [pscustomobject]$plan
    }

    if ($v1Exists) {
        try {
            if (-not (Test-Path -LiteralPath $BundledPath -PathType Leaf)) {
                throw "Bundled default config not found: $BundledPath"
            }

            $v1Config = Read-DevWSConfigFile -Path $V1Path
            $template = Read-DevWSConfigFile -Path $BundledPath
            Assert-DevWSV1Config -Config $v1Config -Template $template | Out-Null

            $plan.Action       = "migrate"
            $plan.V1Recognized = $true
            $plan.Message      = "Recognized v1 config at '$V1Path'; a deterministic v1 -> v3 migration will be written."
        }
        catch {
            $plan.Message = "The v1 config at '$V1Path' is not a recognized DevWS v1 workspace; refusing to migrate and refusing to overwrite it. Re-run with -ResetConfig to install the bundled default instead. Details: $($_.Exception.Message)"
        }

        return [pscustomobject]$plan
    }

    if (-not (Test-Path -LiteralPath $BundledPath -PathType Leaf)) {
        $plan.Message = "No canonical config, no v1 config, and the bundled default was not found: $BundledPath"
        return [pscustomobject]$plan
    }

    $plan.Action  = "install-default"
    $plan.Message = "No existing config; the bundled default config will be installed."

    return [pscustomobject]$plan
}

function Install-DevWSConfigFromFile {
    param(
        [Parameter(Mandatory)]
        [string]$SourcePath,
        [Parameter(Mandatory)]
        [string]$CanonicalPath
    )

    # Validate the source before copying bytes, then re-validate the written
    # canonical file. Byte copy keeps the checked-in default formatting.
    $config = Read-DevWSConfigFile -Path $SourcePath
    Assert-DevWSConfig -Config $config -Source $SourcePath

    Write-DevWSBytesAtomic -Path $CanonicalPath -Bytes ([System.IO.File]::ReadAllBytes($SourcePath))

    $reloaded = Read-DevWSConfigFile -Path $CanonicalPath
    Assert-DevWSConfig -Config $reloaded -Source $CanonicalPath
}

function Initialize-DevWSWorkspaceConfig {
    param(
        [Parameter(Mandatory)]
        $Plan,
        [Parameter(Mandatory)]
        [string]$CanonicalPath,
        [Parameter(Mandatory)]
        [string]$BundledPath,
        [Parameter(Mandatory)]
        [string]$V1Path,
        [Parameter(Mandatory)]
        [string]$BackupRoot
    )

    switch ($Plan.Action) {
        "preserve" {
            $config = Read-DevWSConfigFile -Path $CanonicalPath
            Assert-DevWSConfig -Config $config -Source $CanonicalPath

            return [pscustomobject]@{
                Action  = "preserve"
                Backup  = $null
                Message = "Existing canonical config preserved byte-for-byte."
            }
        }

        "install-default" {
            Install-DevWSConfigFromFile -SourcePath $BundledPath -CanonicalPath $CanonicalPath

            return [pscustomobject]@{
                Action  = "install-default"
                Backup  = $null
                Message = "Installed the bundled default config."
            }
        }

        "migrate" {
            $v1Config = Read-DevWSConfigFile -Path $V1Path
            $template = Read-DevWSConfigFile -Path $BundledPath
            $migrated = Convert-DevWSV1ConfigToV3 -V1Config $v1Config -Template $template

            Assert-DevWSConfig -Config $migrated -Source "v1 migration"

            $backup = Copy-DevWSFileToBackup -SourcePath $V1Path -BackupRoot $BackupRoot -Prefix "v1-workspace" -Extension ".json"

            Save-DevWSConfig -Config $migrated -Location (New-DevWSWritableConfigLocation -Path $CanonicalPath)

            return [pscustomobject]@{
                Action  = "migrate"
                Backup  = $backup
                Message = "Migrated the v1 workspace to v3 (window ids preserved; explicit app instance modes added; v1 config left untouched)."
            }
        }

        "migrate-v2" {
            $v2Config = Read-DevWSConfigFile -Path $CanonicalPath
            $template = Read-DevWSConfigFile -Path $BundledPath
            $migrated = Convert-DevWSV2ConfigToV3 -V2Config $v2Config -Template $template

            Assert-DevWSConfig -Config $migrated -Source "v2 migration"

            $backup = Copy-DevWSFileToBackup -SourcePath $CanonicalPath -BackupRoot $BackupRoot -Prefix "canonical-v2-workspace" -Extension ".json"

            Save-DevWSConfig -Config $migrated -Location (New-DevWSWritableConfigLocation -Path $CanonicalPath)

            return [pscustomobject]@{
                Action  = "migrate-v2"
                Backup  = $backup
                Message = "Migrated the canonical v2 workspace to v3 (window identities preserved; explicit app instance modes added; the v2 file was backed up)."
            }
        }

        "enrich-v3-instance-modes" {
            $canonicalConfig = Read-DevWSConfigFile -Path $CanonicalPath
            Assert-DevWSPreInstanceModeV3Config -Config $canonicalConfig -Source $CanonicalPath

            $template = Read-DevWSConfigFile -Path $BundledPath
            $enriched = ConvertTo-DevWSConfigWithExplicitInstanceModes -Config $canonicalConfig -BundledTemplate $template
            Assert-DevWSConfig -Config $enriched -Source "instance-mode enrichment"

            $backup = Copy-DevWSFileToBackup -SourcePath $CanonicalPath -BackupRoot $BackupRoot -Prefix "canonical-v3-pre-instancemode" -Extension ".json"

            Save-DevWSConfig -Config $enriched -Location (New-DevWSWritableConfigLocation -Path $CanonicalPath)

            $reloaded = Read-DevWSConfigFile -Path $CanonicalPath
            Assert-DevWSConfig -Config $reloaded -Source $CanonicalPath

            return [pscustomobject]@{
                Action  = "enrich-v3-instance-modes"
                Backup  = $backup
                Message = "Added explicit app instance modes to the historical v3 canonical config (everything else preserved; the original bytes were backed up)."
            }
        }

        "reset" {
            $backup = $null

            if (Test-Path -LiteralPath $CanonicalPath -PathType Leaf) {
                $backup = Copy-DevWSFileToBackup -SourcePath $CanonicalPath -BackupRoot $BackupRoot -Prefix "canonical-workspace" -Extension ".json"
            }

            Install-DevWSConfigFromFile -SourcePath $BundledPath -CanonicalPath $CanonicalPath

            return [pscustomobject]@{
                Action  = "reset"
                Backup  = $backup
                Message = "Canonical config reset to the bundled default."
            }
        }

        default {
            throw $Plan.Message
        }
    }
}

# ---------------------------------------------------------------------------
# User PATH helpers
# ---------------------------------------------------------------------------

function Split-DevWSPathText {
    param([AllowEmptyString()][string]$PathText)

    return @("$PathText" -split ';')
}

function ConvertTo-DevWSPathKey {
    param([AllowEmptyString()][string]$Entry)

    $trimmed = "$Entry".Trim().Trim('"')

    while ($trimmed.EndsWith("\")) {
        $trimmed = $trimmed.Substring(0, $trimmed.Length - 1)
    }

    return $trimmed.ToLowerInvariant()
}

function Test-DevWSPathEntry {
    param(
        [AllowEmptyString()][string]$PathText,
        [Parameter(Mandatory)][string]$Entry
    )

    $key = ConvertTo-DevWSPathKey -Entry $Entry

    if ([string]::IsNullOrEmpty($key)) {
        return $false
    }

    foreach ($candidate in @(Split-DevWSPathText -PathText $PathText)) {
        if ((ConvertTo-DevWSPathKey -Entry $candidate) -eq $key) {
            return $true
        }
    }

    return $false
}

function Add-DevWSPathEntry {
    param(
        [AllowEmptyString()][string]$PathText,
        [Parameter(Mandatory)][string]$Entry
    )

    if (Test-DevWSPathEntry -PathText $PathText -Entry $Entry) {
        return [pscustomobject]@{
            PathText = $PathText
            Added    = $false
        }
    }

    $trimmedEntry = $Entry.Trim()

    if ([string]::IsNullOrWhiteSpace($PathText)) {
        return [pscustomobject]@{
            PathText = $trimmedEntry
            Added    = $true
        }
    }

    # Prepend so DevWS bin wins over obsolete user-PATH ws aliases.
    return [pscustomobject]@{
        PathText = ($trimmedEntry + ";" + $PathText)
        Added    = $true
    }
}

function Remove-DevWSPathEntry {
    param(
        [AllowEmptyString()][string]$PathText,
        [Parameter(Mandatory)][string]$Entry
    )

    $key = ConvertTo-DevWSPathKey -Entry $Entry
    $all = @(Split-DevWSPathText -PathText $PathText)
    $kept = @($all | Where-Object { (ConvertTo-DevWSPathKey -Entry $_) -ne $key })

    if ($kept.Count -eq $all.Count) {
        return [pscustomobject]@{
            PathText = $PathText
            Removed  = $false
        }
    }

    return [pscustomobject]@{
        PathText = ($kept -join ';')
        Removed  = $true
    }
}

function Get-DevWSUserPathText {
    return [Environment]::GetEnvironmentVariable("Path", "User")
}

function Set-DevWSUserPathText {
    param([AllowEmptyString()][string]$PathText)

    [Environment]::SetEnvironmentVariable("Path", $PathText, "User")
}

# ---------------------------------------------------------------------------
# Shim and hotkey content
# ---------------------------------------------------------------------------

function New-DevWSShimContent {
    param([string]$InstallRoot)

    $defaultAppScript = Join-Path (Get-DevWSDefaultInstallRoot) "app\ws.ps1"
    $appScript = if ([string]::IsNullOrWhiteSpace($InstallRoot)) {
        $defaultAppScript
    }
    else {
        Join-Path $InstallRoot "app\ws.ps1"
    }

    if ([string]::Equals($appScript, $defaultAppScript, [StringComparison]::OrdinalIgnoreCase)) {
        $target = '%LOCALAPPDATA%\DevWS\app\ws.ps1'
    }
    else {
        $target = $appScript
    }

    return ("@echo off" + "`r`n" + "pwsh.exe -NoLogo -NoProfile -File `"$target`" %*" + "`r`n")
}

function Get-DevWSScriptLines {
    param([AllowEmptyString()][string]$Content)

    return @("$Content" -replace "`r`n", "`n" -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })
}

function Test-DevWSLegacyShimContent {
    param([AllowEmptyString()][string]$Content)

    $lines = @(Get-DevWSScriptLines -Content $Content)

    if ($lines.Count -ne 2) {
        return $false
    }

    if ($lines[0] -ine "@echo off") {
        return $false
    }

    return ($lines[1] -ieq 'pwsh.exe -NoLogo -NoProfile -File "%USERPROFILE%\.ws\ws.ps1" %*')
}

function Test-DevWSForwardingShimContent {
    param(
        [AllowEmptyString()][string]$Content,
        [Parameter(Mandatory)]
        [string]$InstallRoot
    )

    $lines = @(Get-DevWSScriptLines -Content $Content)

    if ($lines.Count -ne 2) {
        return $false
    }

    if ($lines[0] -ine "@echo off") {
        return $false
    }

    $expected = @(Get-DevWSScriptLines -Content (New-DevWSShimContent -InstallRoot $InstallRoot))

    return ($lines[1] -ieq $expected[1])
}

function Install-DevWSLegacyShim {
    param(
        [Parameter(Mandatory)]
        [string]$LegacyShimPath,
        [Parameter(Mandatory)]
        [string]$ForwardingContent,
        [Parameter(Mandatory)]
        [string]$InstallRoot,
        [Parameter(Mandatory)]
        [string]$BackupRoot,
        [Parameter(Mandatory)]
        $Metadata
    )

    if (-not (Test-Path -LiteralPath $LegacyShimPath -PathType Leaf)) {
        return [pscustomobject]@{
            Status  = "absent"
            Backup  = $null
            Message = "No legacy ws.cmd found; nothing to migrate."
        }
    }

    $content = Get-Content -LiteralPath $LegacyShimPath -Raw

    if (Test-DevWSForwardingShimContent -Content $content -InstallRoot $InstallRoot) {
        return [pscustomobject]@{
            Status  = "owned"
            Backup  = $null
            Message = "Legacy ws.cmd already forwards to the installed DevWS."
        }
    }

    if (-not (Test-DevWSLegacyShimContent -Content $content)) {
        return [pscustomobject]@{
            Status  = "unknown"
            Backup  = $null
            Message = "Unrecognized ws.cmd left untouched (not the known DevWS v1 shim)."
        }
    }

    $backup = [string]$Metadata.legacyShim.backup

    if ([string]::IsNullOrWhiteSpace($backup) -or -not (Test-Path -LiteralPath $backup -PathType Leaf)) {
        $backup = Copy-DevWSFileToBackup -SourcePath $LegacyShimPath -BackupRoot $BackupRoot -Prefix "legacy-ws-cmd" -Extension ".cmd"
    }

    Write-DevWSTextFileAtomic -Path $LegacyShimPath -Content $ForwardingContent

    return [pscustomobject]@{
        Status  = "replaced"
        Backup  = $backup
        Message = "Legacy ws.cmd backed up and replaced with a forwarding shim."
    }
}

function Get-DevWSManagedHotkeyIncludeLine {
    param(
        [Parameter(Mandatory)]
        [string]$BindingsPath
    )

    # AutoHotkey v2 optional include: the *i option must sit inside the
    # parameter and a missing generated file is skipped without breaking the
    # Alt+T / Alt+Shift+T contracts.
    return '#Include "*i ' + $BindingsPath + '"'
}

function Test-DevWSManagedHotkeyIncludeContract {
    param(
        [AllowEmptyString()]
        [string]$Content,
        [Parameter(Mandatory)]
        [string]$BindingsPath
    )

    return ("$Content".IndexOf((Get-DevWSManagedHotkeyIncludeLine -BindingsPath $BindingsPath), [StringComparison]::OrdinalIgnoreCase) -ge 0)
}

function New-DevWSTerminalShortcutContent {
    param(
        [Parameter(Mandatory)]
        [string]$AppScriptPath,
        [Parameter(Mandatory)]
        [string]$BindingsPath
    )

    # Stage 1: Alt+Shift+T sends a launch request directly to the warm normal
    # coordinator over a current-user-only local pipe. The hotkey script stays
    # policy-free: it probes/sends and, only when the coordinator is
    # unavailable, starts it once and retries briefly before falling back to
    # the exact previous hidden `pwsh ... ws.ps1 launch` behavior.
    $defaultAppScript = Join-Path (Get-DevWSDefaultInstallRoot) "app\ws.ps1"
    $coordinatorPath  = Join-Path (Split-Path -Parent $AppScriptPath) "coordinator.ps1"

    if ([string]::Equals($AppScriptPath, $defaultAppScript, [StringComparison]::OrdinalIgnoreCase)) {
        $coordinatorLine = 'global DevWSCoordinatorScript := EnvGet("LOCALAPPDATA") "\DevWS\app\coordinator.ps1"'
        $appLine         = 'global DevWSAppScript := EnvGet("LOCALAPPDATA") ''\DevWS\app\ws.ps1'''
    }
    else {
        $coordinatorLine = 'global DevWSCoordinatorScript := ' + (ConvertTo-DevWSAhkSingleQuotedString -Value $coordinatorPath)
        $appLine         = 'global DevWSAppScript := ' + (ConvertTo-DevWSAhkSingleQuotedString -Value $AppScriptPath)
    }

    $lines = @(
        "#Requires AutoHotkey v2.0",
        "#SingleInstance Force",
        "",
        "; Alt + T -> elevated Terminal",
        "!t::Run('schtasks /run /tn `"AdminTerminal`"', , `"Hide`")",
        "",
        "; Alt + Shift + T -> warm DevWS coordinator launch (local IPC)",
        "!+t::DevWSLaunchWorkspace()",
        "",
        "; --- DevWS Stage 1 warm coordinator client (managed; do not edit) ---------",
        'global DevWSCoordinatorPipe := "DevWS.Coordinator.v1"',
        $coordinatorLine,
        $appLine,
        "",
        "DevWSLaunchWorkspace() {",
        "    if (DevWSCoordinatorRequest())",
        "        return",
        "",
        "    ; Bounded recovery: start the coordinator once, retry briefly, then fall",
        "    ; back to the exact hidden launch behavior (slow but semantically equal).",
        "    DevWSCoordinatorStart()",
        "    deadline := A_TickCount + 6000",
        "",
        "    while (A_TickCount < deadline) {",
        "        Sleep 150",
        "",
        "        if (DevWSCoordinatorRequest())",
        "            return",
        "    }",
        "",
        "    Run('pwsh.exe -NoLogo -NoProfile -WindowStyle Hidden -File `"' DevWSAppScript '`" launch', , `"Hide`")",
        "}",
        "",
        "DevWSCoordinatorStart() {",
        "    if (!FileExist(DevWSCoordinatorScript))",
        "        return false",
        "",
        "    try",
        "        Run('pwsh.exe -NoLogo -NoProfile -WindowStyle Hidden -File `"' DevWSCoordinatorScript '`"', , `"Hide`")",
        "    catch",
        "        return false",
        "",
        "    return true",
        "}",
        "",
        "DevWSCoordinatorProbe() {",
        "    h := DllCall(`"CreateFile`", `"Str`", `"\\.\pipe\`" DevWSCoordinatorPipe, `"UInt`", 0xC0000000, `"UInt`", 3, `"Ptr`", 0, `"UInt`", 3, `"UInt`", 0, `"Ptr`", 0, `"Ptr`")",
        "",
        "    if (h = -1 || h = 0)",
        "        return false",
        "",
        "    DllCall(`"CloseHandle`", `"Ptr`", h)",
        "    return true",
        "}",
        "",
        "DevWSCoordinatorRequest() {",
        '    request := ''{"version":1,"command":"launch"}'' . "`n"',
        "    size := StrPut(request, `"UTF-8`")",
        "    buf := Buffer(size, 0)",
        "    StrPut(request, buf, `"UTF-8`")",
        "",
        "    h := DllCall(`"CreateFile`", `"Str`", `"\\.\pipe\`" DevWSCoordinatorPipe, `"UInt`", 0xC0000000, `"UInt`", 3, `"Ptr`", 0, `"UInt`", 3, `"UInt`", 0, `"Ptr`", 0, `"Ptr`")",
        "",
        "    if (h = -1 || h = 0)",
        "        return false",
        "",
        "    written := 0",
        "    ok := DllCall(`"WriteFile`", `"Ptr`", h, `"Ptr`", buf, `"UInt`", size - 1, `"UInt*`", &written, `"Ptr`", 0)",
        "    ack := `"`"",
        "",
        "    if (ok) {",
        "        deadline := A_TickCount + 5000",
        "        avail := 0",
        "",
        "        while (A_TickCount < deadline) {",
        "            if (!DllCall(`"PeekNamedPipe`", `"Ptr`", h, `"Ptr`", 0, `"UInt`", 0, `"Ptr`", 0, `"UInt*`", &avail, `"Ptr`", 0))",
        "                break",
        "",
        "            if (avail)",
        "                break",
        "",
        "            Sleep 5",
        "        }",
        "",
        "        if (avail) {",
        "            rbuf := Buffer(4096, 0)",
        "            read := 0",
        "",
        "            if (DllCall(`"ReadFile`", `"Ptr`", h, `"Ptr`", rbuf, `"UInt`", rbuf.Size, `"UInt*`", &read, `"Ptr`", 0) && read > 0)",
        "                ack := StrGet(rbuf, read, `"UTF-8`")",
        "        }",
        "    }",
        "",
        "    DllCall(`"CloseHandle`", `"Ptr`", h)",
        '    return ack != "" && InStr(ack, ''"ok":true'')',
        "}",
        "",
        "; Ensure the warm coordinator is running once at login (idempotent; hidden).",
        "if (!DevWSCoordinatorProbe())",
        "    DevWSCoordinatorStart()",
        "",
        "; Additional set launch hotkeys (generated derived state; safe to be absent)",
        (Get-DevWSManagedHotkeyIncludeLine -BindingsPath $BindingsPath)
    )

    return (($lines -join "`r`n") + "`r`n")
}

function Test-DevWSLegacyHotkeyContent {
    param([AllowEmptyString()][string]$Content)

    return ("$Content".IndexOf('\.ws\ws.ps1', [StringComparison]::OrdinalIgnoreCase) -ge 0)
}

function Test-DevWSManagedHotkeyContent {
    param(
        [AllowEmptyString()][string]$Content,
        [Parameter(Mandatory)]
        [string]$InstallRoot
    )

    $text = "$Content"

    if (Test-DevWSLegacyHotkeyContent -Content $text) {
        return $false
    }

    if ($text.IndexOf("AdminTerminal", [StringComparison]::OrdinalIgnoreCase) -lt 0) {
        return $false
    }

    if ($text.IndexOf("!t::", [StringComparison]::Ordinal) -lt 0 -or $text.IndexOf("!+t::", [StringComparison]::Ordinal) -lt 0) {
        return $false
    }

    # Two recognized managed shapes:
    #   - Stage 1: the normal Alt+Shift+T path sends the launch request to the
    #     warm coordinator over local IPC (historical cores must still be
    #     recognized so an install can upgrade them in place);
    #   - historical: the direct `pwsh ... ws.ps1 launch` hotkey.
    $stage1 = (
        $text.IndexOf("DevWSLaunchWorkspace", [StringComparison]::Ordinal) -ge 0 -and
        $text.IndexOf("DevWS.Coordinator.v1", [StringComparison]::Ordinal) -ge 0 -and
        (
            $text.IndexOf((Join-Path $InstallRoot "app\coordinator.ps1"), [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
            $text.IndexOf('\DevWS\app\coordinator.ps1', [StringComparison]::OrdinalIgnoreCase) -ge 0
        )
    )

    $historical = (
        $text.IndexOf((Join-Path $InstallRoot "app\ws.ps1"), [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
        $text.IndexOf('\DevWS\app\ws.ps1', [StringComparison]::OrdinalIgnoreCase) -ge 0
    )

    return ($stage1 -or $historical)
}

function Test-DevWSCoordinatorHotkeyContract {
    # Stage 1 contract used by health: the normal hotkey path must send the
    # launch request to the warm coordinator over current-user-only local IPC
    # and must not run pwsh directly on that path.
    param(
        [AllowEmptyString()][string]$Content,
        [Parameter(Mandatory)]
        [string]$InstallRoot
    )

    $text = "$Content"

    if ($text.IndexOf("DevWSLaunchWorkspace", [StringComparison]::Ordinal) -lt 0) {
        return $false
    }

    if ($text.IndexOf("DevWS.Coordinator.v1", [StringComparison]::Ordinal) -lt 0) {
        return $false
    }

    if ($text.IndexOf("!+t::Run('pwsh", [StringComparison]::Ordinal) -ge 0) {
        return $false
    }

    $coordinatorScript = Join-Path $InstallRoot "app\coordinator.ps1"

    return (
        $text.IndexOf($coordinatorScript, [StringComparison]::OrdinalIgnoreCase) -ge 0 -or
        $text.IndexOf('\DevWS\app\coordinator.ps1', [StringComparison]::OrdinalIgnoreCase) -ge 0
    )
}

function Install-DevWSTerminalShortcut {
    param(
        [Parameter(Mandatory)]
        [string]$HotkeyPath,
        [Parameter(Mandatory)]
        [string]$Content,
        [Parameter(Mandatory)]
        [string]$InstallRoot,
        [Parameter(Mandatory)]
        [string]$BackupRoot,
        [Parameter(Mandatory)]
        $Metadata
    )

    $normalizedNew = "$Content".Replace("`r`n", "`n").Trim()

    if (-not (Test-Path -LiteralPath $HotkeyPath -PathType Leaf)) {
        Write-DevWSTextFileAtomic -Path $HotkeyPath -Content $Content

        return [pscustomobject]@{
            Status  = "installed"
            Backup  = $null
            Message = "Installed TerminalShortcut.ahk."
        }
    }

    $existing = Get-Content -LiteralPath $HotkeyPath -Raw

    if (Test-DevWSManagedHotkeyContent -Content $existing -InstallRoot $InstallRoot) {
        if ("$existing".Replace("`r`n", "`n").Trim() -eq $normalizedNew) {
            return [pscustomobject]@{
                Status  = "current"
                Backup  = $null
                Message = "TerminalShortcut.ahk already current."
            }
        }

        Write-DevWSTextFileAtomic -Path $HotkeyPath -Content $Content

        return [pscustomobject]@{
            Status  = "updated"
            Backup  = $null
            Message = "TerminalShortcut.ahk updated to the installed path."
        }
    }

    if (-not (Test-DevWSLegacyHotkeyContent -Content $existing)) {
        return [pscustomobject]@{
            Status  = "unknown"
            Backup  = $null
            Message = "Unrecognized TerminalShortcut.ahk left untouched."
        }
    }

    $backup = [string]$Metadata.hotkey.backup

    if ([string]::IsNullOrWhiteSpace($backup) -or -not (Test-Path -LiteralPath $backup -PathType Leaf)) {
        $backup = Copy-DevWSFileToBackup -SourcePath $HotkeyPath -BackupRoot $BackupRoot -Prefix "TerminalShortcut" -Extension ".ahk"
    }

    Write-DevWSTextFileAtomic -Path $HotkeyPath -Content $Content

    return [pscustomobject]@{
        Status  = "replaced"
        Backup  = $backup
        Message = "Legacy TerminalShortcut.ahk backed up and updated."
    }
}

function Start-DevWSInstalledHotkey {
    param(
        [Parameter(Mandatory)]
        [string]$HotkeyPath
    )

    if (-not (Test-Path -LiteralPath $HotkeyPath -PathType Leaf)) {
        return $false
    }

    # #SingleInstance Force replaces a previous instance; generic AutoHotkey
    # processes are never killed.
    Start-Process -FilePath (Get-DevWSAutoHotkeyPath) -ArgumentList "`"$HotkeyPath`"" | Out-Null

    return $true
}

# ---------------------------------------------------------------------------
# Install metadata
# ---------------------------------------------------------------------------

function New-DevWSInstallMetadata {
    return [pscustomobject][ordered]@{
        version     = 1
        installRoot = ""
        installedAt = ""
        updatedAt   = ""
        path        = [pscustomobject][ordered]@{
            added = $false
            entry = ""
        }
        legacyShim  = [pscustomobject][ordered]@{
            replaced = $false
            path     = ""
            backup   = ""
        }
        hotkey      = [pscustomobject][ordered]@{
            managed = $false
            path    = ""
            backup  = ""
        }
        tasks       = [pscustomobject][ordered]@{
            backups = [pscustomobject]@{}
        }
        config      = [pscustomobject][ordered]@{
            action = ""
            backup = ""
        }
        privileged  = [pscustomobject][ordered]@{
            # Additive Security Phase 1 layout record: the administrator-
            # protected privileged root and the absolute trusted PowerShell
            # executable recorded at install time. Absent in legacy metadata
            # (treated as an unmigrated installation).
            root           = ""
            powerShellPath = ""
        }
    }
}

function Read-DevWSInstallMetadata {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = Get-DevWSInstallMetadataPath
    }

    $metadata = New-DevWSInstallMetadata

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $metadata
    }

    try {
        $parsed = ConvertFrom-DevWSJsonText -Text (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop) -KeepDatesAsStrings
    }
    catch {
        return $metadata
    }

    if ($null -eq $parsed -or $parsed -isnot [System.Management.Automation.PSCustomObject]) {
        return $metadata
    }

    if ($null -eq (Get-DevWSNamedProperty -Object $parsed -Name "version") -or
        -not (Test-DevWSInteger (Get-DevWSNamedProperty -Object $parsed -Name "version").Value) -or
        [int](Get-DevWSNamedProperty -Object $parsed -Name "version").Value -ne 1) {
        return $metadata
    }

    $metadata.installRoot = [string](Get-DevWSNamedProperty -Object $parsed -Name "installRoot").Value
    $metadata.installedAt = [string](Get-DevWSNamedProperty -Object $parsed -Name "installedAt").Value
    $metadata.updatedAt   = [string](Get-DevWSNamedProperty -Object $parsed -Name "updatedAt").Value

    if ($null -ne (Get-DevWSNamedProperty -Object $parsed -Name "path")) {
        $metadata.path.added = [bool]$parsed.path.added
        $metadata.path.entry = [string]$parsed.path.entry
    }

    if ($null -ne (Get-DevWSNamedProperty -Object $parsed -Name "legacyShim")) {
        $metadata.legacyShim.replaced = [bool]$parsed.legacyShim.replaced
        $metadata.legacyShim.path     = [string]$parsed.legacyShim.path
        $metadata.legacyShim.backup   = [string]$parsed.legacyShim.backup
    }

    if ($null -ne (Get-DevWSNamedProperty -Object $parsed -Name "hotkey")) {
        $metadata.hotkey.managed = [bool]$parsed.hotkey.managed
        $metadata.hotkey.path    = [string]$parsed.hotkey.path
        $metadata.hotkey.backup  = [string]$parsed.hotkey.backup
    }

    if ($null -ne (Get-DevWSNamedProperty -Object $parsed -Name "config")) {
        $metadata.config.action = [string]$parsed.config.action
        $metadata.config.backup = [string]$parsed.config.backup
    }

    # Additive Security Phase 1 record; absent in legacy (unmigrated) metadata.
    $privilegedProperty = Get-DevWSNamedProperty -Object $parsed -Name "privileged"

    if ($null -ne $privilegedProperty -and $null -ne $privilegedProperty.Value) {
        $privilegedRootProperty = Get-DevWSNamedProperty -Object $privilegedProperty.Value -Name "root"
        $privilegedPowerShellProperty = Get-DevWSNamedProperty -Object $privilegedProperty.Value -Name "powerShellPath"

        if ($null -ne $privilegedRootProperty) {
            $metadata.privileged.root = [string]$privilegedRootProperty.Value
        }

        if ($null -ne $privilegedPowerShellProperty) {
            $metadata.privileged.powerShellPath = [string]$privilegedPowerShellProperty.Value
        }
    }

    if ($null -ne (Get-DevWSNamedProperty -Object $parsed -Name "tasks")) {
        $backupProperty = Get-DevWSNamedProperty -Object $parsed.tasks -Name "backups"

        if ($null -ne $backupProperty -and $backupProperty.Value -is [System.Management.Automation.PSCustomObject]) {
            foreach ($property in $backupProperty.Value.PSObject.Properties) {
                $metadata.tasks.backups | Add-Member -NotePropertyName $property.Name -NotePropertyValue ([string]$property.Value) -Force
            }
        }
    }

    return $metadata
}

function Save-DevWSInstallMetadata {
    param(
        [Parameter(Mandatory)]
        $Metadata,
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = Get-DevWSInstallMetadataPath
    }

    $Metadata.updatedAt = (Get-Date).ToString("o")

    Write-DevWSJsonFile -Path $Path -Object $Metadata
}

# ---------------------------------------------------------------------------
# Scheduled tasks
# ---------------------------------------------------------------------------

function Get-DevWSScheduledTaskSpecs {
    # Every spec carries the worker path inside the administrator-protected
    # privileged root and the exact absolute trusted PowerShell executable
    # recorded at install time (Public Security Phase 1). -InstallRoot is kept
    # for caller compatibility; workers never resolve from it any more.
    param(
        [Parameter(Mandatory)]
        [string]$InstallRoot,
        [string]$PrivilegedRoot,
        [string]$PowerShellPath
    )

    if ([string]::IsNullOrWhiteSpace($PrivilegedRoot)) {
        $PrivilegedRoot = Get-DevWSPrivilegedInstallRoot
    }

    if ([string]::IsNullOrWhiteSpace($PowerShellPath)) {
        $PowerShellPath = Resolve-DevWSTrustedPowerShellPath
    }

    $workerDir = Join-Path $PrivilegedRoot "workers"

    return @(
        [pscustomobject]@{
            TaskName       = "DevWorkspace-ElevatedHelper"
            Worker         = Join-Path $workerDir "elevated.ps1"
            PowerShellPath = $PowerShellPath
        },
        [pscustomobject]@{
            TaskName       = "DevWorkspace-ElevatedCapture"
            Worker         = Join-Path $workerDir "elevated-capture.ps1"
            PowerShellPath = $PowerShellPath
        },
        [pscustomobject]@{
            TaskName       = "DevWorkspace-ElevatedFocus"
            Worker         = Join-Path $workerDir "elevated-focus.ps1"
            PowerShellPath = $PowerShellPath
        },
        [pscustomobject]@{
            TaskName       = "DevWorkspace-ElevatedReset"
            Worker         = Join-Path $workerDir "elevated-reset.ps1"
            PowerShellPath = $PowerShellPath
        },
        [pscustomobject]@{
            # Stage 2 persistent elevated broker: highest/Interactive/current
            # user, one instance, no execution time limit, battery-safe,
            # restarted on failure, started at logon and on demand.
            TaskName                  = "DevWorkspace-ElevatedBroker"
            Worker                    = Join-Path $workerDir "elevated-broker.ps1"
            PowerShellPath            = $PowerShellPath
            LogonTrigger              = $true
            ExecutionTimeLimitZero    = $true
            AllowBattery              = $true
            RestartCount              = 3
            RestartIntervalMinutes    = 1
            StopBeforeRegister        = $true
        }
    )
}

function New-DevWSScheduledTaskDefinition {
    param(
        [Parameter(Mandatory)]
        $Spec
    )

    $powerShellPath = [string]$Spec.PowerShellPath

    if ([string]::IsNullOrWhiteSpace($powerShellPath)) {
        throw "The scheduled-task spec for '$($Spec.TaskName)' is missing the trusted absolute PowerShell path (Public Security Phase 1 forbids bare 'pwsh.exe' in privileged task actions)."
    }

    $action = New-ScheduledTaskAction `
        -Execute $powerShellPath `
        -Argument ("-NoProfile -WindowStyle Hidden -File `"$($Spec.Worker)`"")

    $principal = New-ScheduledTaskPrincipal `
        -UserId $env:USERNAME `
        -LogonType Interactive `
        -RunLevel Highest

    # Defaults mirror the proven v1 tasks: IgnoreNew, no trigger (run on
    # demand), start blocked on battery. The broker spec extends these.
    $settingsArguments = @{ MultipleInstances = "IgnoreNew" }

    if ($Spec.PSObject.Properties["ExecutionTimeLimitZero"] -and [bool]$Spec.ExecutionTimeLimitZero) {
        $settingsArguments["ExecutionTimeLimit"] = [TimeSpan]::Zero
    }

    if ($Spec.PSObject.Properties["AllowBattery"] -and [bool]$Spec.AllowBattery) {
        $settingsArguments["AllowStartIfOnBatteries"] = $true
        $settingsArguments["DontStopIfGoingOnBatteries"] = $true
    }

    if ($Spec.PSObject.Properties["RestartCount"] -and [int]$Spec.RestartCount -gt 0) {
        $settingsArguments["RestartCount"] = [int]$Spec.RestartCount
        $settingsArguments["RestartInterval"] = [TimeSpan]::FromMinutes([int]$Spec.RestartIntervalMinutes)
    }

    $settings = New-ScheduledTaskSettingsSet @settingsArguments

    $triggers = @()

    if ($Spec.PSObject.Properties["LogonTrigger"] -and [bool]$Spec.LogonTrigger) {
        $triggers = @(New-ScheduledTaskTrigger -AtLogOn -User $env:USERNAME)
    }

    return [pscustomobject]@{
        TaskName  = $Spec.TaskName
        Action    = $action
        Principal = $principal
        Settings  = $settings
        Triggers  = $triggers
    }
}

function Install-DevWSScheduledTasks {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Specs,
        [Parameter(Mandatory)]
        [string]$BackupRoot,
        [Parameter(Mandatory)]
        $Metadata
    )

    $results = [System.Collections.Generic.List[object]]::new()

    foreach ($spec in $Specs) {
        $existing = Get-ScheduledTask -TaskName $spec.TaskName -ErrorAction SilentlyContinue
        $backup = $null

        if ($null -ne $existing) {
            $recordedProperty = Get-DevWSNamedProperty -Object $Metadata.tasks.backups -Name $spec.TaskName
            $recorded = if ($null -ne $recordedProperty) { [string]$recordedProperty.Value } else { "" }

            if (-not [string]::IsNullOrWhiteSpace($recorded) -and (Test-Path -LiteralPath $recorded -PathType Leaf)) {
                $backup = $recorded
            }
            else {
                if (-not (Test-Path -LiteralPath $BackupRoot -PathType Container)) {
                    New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null
                }

                $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
                $backup = Join-Path $BackupRoot "task-$($spec.TaskName)-$stamp.xml"
                $xml = Export-ScheduledTask -TaskName $spec.TaskName | Out-String

                [System.IO.File]::WriteAllText($backup, $xml, [System.Text.UTF8Encoding]::new($false))

                $Metadata.tasks.backups | Add-Member -NotePropertyName $spec.TaskName -NotePropertyValue $backup -Force
            }
        }

        # A long-lived broker must be stopped before its definition is
        # replaced so the new code takes effect; this is an exact managed-task
        # stop, never a process-name kill.
        if ($Spec.PSObject.Properties["StopBeforeRegister"] -and [bool]$Spec.StopBeforeRegister -and $null -ne $existing) {
            try {
                if ([string]$existing.State -eq "Running") {
                    Stop-ScheduledTask -TaskName $spec.TaskName -ErrorAction Stop
                }
            }
            catch { }
        }

        $definition = New-DevWSScheduledTaskDefinition -Spec $spec

        $registerArguments = @{
            TaskName  = $spec.TaskName
            Action    = $definition.Action
            Principal = $definition.Principal
            Settings  = $definition.Settings
            Force     = $true
        }

        # Register-ScheduledTask rejects an empty trigger collection; the four
        # short-lived workers intentionally have no trigger (on-demand only).
        if (@($definition.Triggers).Count -gt 0) {
            $registerArguments["Trigger"] = $definition.Triggers
        }

        Register-ScheduledTask @registerArguments | Out-Null

        $results.Add([pscustomobject]@{
            TaskName = $spec.TaskName
            Worker   = $spec.Worker
            Backup   = $backup
        })
    }

    return $results.ToArray()
}

# ---------------------------------------------------------------------------
# Uninstall decision model and execution
# ---------------------------------------------------------------------------

function Get-DevWSUninstallPlan {
    param(
        [Parameter(Mandatory)]
        [string]$InstallRoot,
        [string]$PrivilegedRoot,
        [string]$PrivilegedStateRoot,
        [Parameter(Mandatory)]
        [string]$CanonicalPath,
        [Parameter(Mandatory)]
        [string]$LegacyShimPath,
        [Parameter(Mandatory)]
        [string]$HotkeyPath,
        [Parameter(Mandatory)]
        $Metadata,
        [switch]$Purge
    )

    $messages = [System.Collections.Generic.List[string]]::new()

    $binRoot   = Join-Path $InstallRoot "bin"
    $stateRoot = Join-Path $InstallRoot "state"

    # Legacy shim: restore only when this installer replaced a recognized shim
    # and the current file is still our forwarding shim.
    $restoreShim = $false
    $shimBackup = [string]$Metadata.legacyShim.backup

    if ([bool]$Metadata.legacyShim.replaced -and
        -not [string]::IsNullOrWhiteSpace($shimBackup) -and
        (Test-Path -LiteralPath $shimBackup -PathType Leaf)) {
        if (Test-Path -LiteralPath $LegacyShimPath -PathType Leaf) {
            $currentShim = Get-Content -LiteralPath $LegacyShimPath -Raw

            if (Test-DevWSForwardingShimContent -Content $currentShim -InstallRoot $InstallRoot) {
                $restoreShim = $true
            }
            else {
                $messages.Add("Legacy ws.cmd is no longer the DevWS forwarding shim; left untouched.")
            }
        }
    }

    # Hotkey: restore the pre-install backup, or remove our managed file.
    $restoreHotkey = $false
    $removeHotkey = $false
    $hotkeyBackup = [string]$Metadata.hotkey.backup

    if ([bool]$Metadata.hotkey.managed -and (Test-Path -LiteralPath $HotkeyPath -PathType Leaf)) {
        $currentHotkey = Get-Content -LiteralPath $HotkeyPath -Raw

        if (Test-DevWSManagedHotkeyContent -Content $currentHotkey -InstallRoot $InstallRoot) {
            if (-not [string]::IsNullOrWhiteSpace($hotkeyBackup) -and (Test-Path -LiteralPath $hotkeyBackup -PathType Leaf)) {
                $restoreHotkey = $true
            }
            else {
                $removeHotkey = $true
            }
        }
        else {
            $messages.Add("TerminalShortcut.ahk is not DevWS-managed; left untouched.")
        }
    }

    $pathEntry = [string]$Metadata.path.entry

    if ([string]::IsNullOrWhiteSpace($pathEntry)) {
        $pathEntry = $binRoot
    }

    # Privileged-root removal is limited to the real installed pair: an
    # explicit -PrivilegedRoot, or the resolved privileged root when the plan
    # targets the real install root. Fixture plans (arbitrary InstallRoot)
    # never default to the machine's real privileged root.
    $privilegedPath = $null

    if (-not [string]::IsNullOrWhiteSpace($PrivilegedRoot)) {
        $privilegedPath = $PrivilegedRoot
    }
    elseif ([string]::Equals($InstallRoot, (Get-DevWSInstallRoot), [StringComparison]::OrdinalIgnoreCase)) {
        $privilegedPath = Get-DevWSPrivilegedInstallRoot
    }

    # Protected privileged-state foundation (Public Security Phase 2-A): same
    # real-install gating as the privileged root. A normal uninstall may remove
    # the invoking user's SID root only when it is empty and
    # security-validated; non-empty or invalid foundations are preserved.
    $protectedStatePath = $null

    if (-not [string]::IsNullOrWhiteSpace($PrivilegedStateRoot)) {
        $protectedStatePath = $PrivilegedStateRoot
    }
    elseif ([string]::Equals($InstallRoot, (Get-DevWSInstallRoot), [StringComparison]::OrdinalIgnoreCase)) {
        $protectedStatePath = Get-DevWSPrivilegedStateRoot
    }

    $removeProtectedState = $false

    if ($null -ne $protectedStatePath) {
        $protectedRemovable = Test-DevWSProtectedStateRootRemovable -Root $protectedStatePath

        if ($protectedRemovable.Ok) {
            $removeProtectedState = $true
        }
        else {
            $messages.Add("Protected state root preserved: $($protectedRemovable.Reason).")
        }
    }

    return [pscustomobject]@{
        InstallRoot            = $InstallRoot
        AppPath                = Join-Path $InstallRoot "app"
        HelpersPath            = Join-Path $InstallRoot "helpers"
        WorkersPath            = Join-Path $InstallRoot "workers"
        BinPath                = $binRoot
        StatePath              = $stateRoot
        BackupRoot             = Join-Path $stateRoot "backups"
        CanonicalPath          = $CanonicalPath
        PrivilegedPath         = $privilegedPath
        ProtectedStatePath     = $protectedStatePath
        ProtectedStateBasePath = $(if ($null -ne $protectedStatePath) { Split-Path -Parent $protectedStatePath } else { $null })
        RemoveProtectedState   = $removeProtectedState
        TaskNames              = @(Get-DevWSScheduledTaskNames)
        RemoveApplicationFiles = $true
        RemoveState            = [bool]$Purge
        RemoveCanonicalConfig  = [bool]$Purge
        RestoreLegacyShim      = $restoreShim
        LegacyShimPath         = $LegacyShimPath
        LegacyShimBackup       = $shimBackup
        RestoreHotkey          = $restoreHotkey
        RemoveHotkey           = $removeHotkey
        HotkeyPath             = $HotkeyPath
        HotkeyBackup           = $hotkeyBackup
        RemovePathEntry        = [bool]$Metadata.path.added
        PathEntry              = $pathEntry
        PreserveV1             = $true
        Messages               = @($messages)
    }
}

function Undo-DevWSProtectedStateCreation {
    # Exactly-scoped failed-install rollback (Public Security Phase 2-A):
    # removes ONLY the components created by the current installer invocation
    # (@($protectedState.Created)), deepest first, and only while each one is
    # still an ordinary, non-reparse, empty directory carrying the expected
    # protected-state security. A component that received content, changed
    # identity or no longer validates is preserved together with its
    # ancestors; a path that was not created in this invocation is never
    # touched (a pre-existing DevWS container survives even when it is empty).
    #
    # Deliberately separate from Remove-DevWSProtectedStateRootSafe, which
    # implements the explicit uninstall cleanup of a validated empty
    # foundation.
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$CreatedPaths,
        [string]$UserSid = ""
    )

    $removed   = [System.Collections.Generic.List[string]]::new()
    $preserved = [System.Collections.Generic.List[string]]::new()

    if ([string]::IsNullOrWhiteSpace($UserSid)) { $UserSid = Get-DevWSCurrentUserSid }

    # Deepest first: the initializer records parent -> child order, and the
    # depth sort keeps the contract explicit even for a reordered caller.
    $ordered = @($CreatedPaths | Sort-Object -Property @{ Expression = { ([string]$_).Split([System.IO.Path]::DirectorySeparatorChar).Count } } -Descending)

    foreach ($path in $ordered) {
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        if (-not (Test-Path -LiteralPath $path)) { continue }

        $item = Get-Item -LiteralPath $path -Force

        if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -or -not $item.PSIsContainer) {
            $preserved.Add($path) | Out-Null
            continue
        }

        $kind = "Base"

        if ((Split-Path -Leaf $path) -ieq $UserSid) { $kind = "User" }

        try { $acl = Get-Acl -LiteralPath $path -ErrorAction Stop }
        catch { $preserved.Add($path) | Out-Null; continue }

        $validation = Test-DevWSPrivilegedStateSecurity -Security $acl -Kind $kind -UserSid $UserSid

        if (-not $validation.Ok) {
            $preserved.Add($path) | Out-Null
            continue
        }

        if (@(Get-ChildItem -LiteralPath $path -Force -ErrorAction SilentlyContinue).Count -gt 0) {
            $preserved.Add($path) | Out-Null
            continue
        }

        try {
            [System.IO.Directory]::Delete($path, $false)
            $removed.Add($path) | Out-Null
        }
        catch {
            $preserved.Add($path) | Out-Null
        }
    }

    return [pscustomobject]@{
        Removed   = @($removed)
        Preserved = @($preserved)
    }
}

function Remove-DevWSProtectedStateRootSafe {
    # UNINSTALL helper (not the install-rollback path; failed installs use
    # Undo-DevWSProtectedStateCreation with the exact Created set). Safe
    # removal of the protected privileged-state foundation: never recursive,
    # never through a reparse point, never another user's SID directory. The
    # SID root is removed only when it revalidates as a trusted empty DevWS
    # protected root; the empty privileged-state / DevWS containers are then
    # removed leaf-first while they are empty and ordinary.
    param(
        [Parameter(Mandatory)]
        [string]$Root,
        [string]$UserSid = ""
    )

    if ([string]::IsNullOrWhiteSpace($UserSid)) { $UserSid = Get-DevWSCurrentUserSid }

    $removed = [System.Collections.Generic.List[string]]::new()

    $removable = Test-DevWSProtectedStateRootRemovable -Root $Root -UserSid $UserSid

    if (-not $removable.Ok) {
        return [pscustomobject]@{ Removed = @(); Preserved = $true; Message = "Protected state root preserved: $($removable.Reason)." }
    }

    try {
        # Non-recursive delete: fails closed if anything appeared after the
        # emptiness check.
        [System.IO.Directory]::Delete($Root, $false)
        $removed.Add($Root) | Out-Null
    }
    catch {
        return [pscustomobject]@{ Removed = @(); Preserved = $true; Message = "Protected state root could not be removed safely: $($_.Exception.Message)" }
    }

    $parent = Split-Path -Parent $Root
    $trustedAnchor = [Environment]::GetFolderPath('CommonApplicationData')

    while (-not [string]::IsNullOrWhiteSpace($parent)) {
        $leaf = Split-Path -Leaf $parent

        if ($leaf -notin @("privileged-state", "DevWS")) { break }
        if (Test-DevWSPathUnderRoot -Path $trustedAnchor -Root $parent) { break }

        if ($leaf -ieq "DevWS" -and
            -not [string]::Equals((Split-Path -Parent $parent), $trustedAnchor, [StringComparison]::OrdinalIgnoreCase)) {
            break
        }

        if (-not (Test-Path -LiteralPath $parent -PathType Container)) { break }

        $parentItem = Get-Item -LiteralPath $parent -Force

        if ($parentItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) { break }
        if (-not $parentItem.PSIsContainer) { break }
        if (@(Get-ChildItem -LiteralPath $parent -Force -ErrorAction SilentlyContinue).Count -gt 0) { break }

        try {
            [System.IO.Directory]::Delete($parent, $false)
            $removed.Add($parent) | Out-Null
        }
        catch { break }

        $parent = Split-Path -Parent $parent
    }

    return [pscustomobject]@{
        Removed   = @($removed)
        Preserved = $false
        Message   = "Removed the protected state foundation: $(@($removed) -join ', ')."
    }
}

function Invoke-DevWSUninstall {
    param(
        [Parameter(Mandatory)]
        $Plan,
        [switch]$SkipTasks
    )

    $actions = [System.Collections.Generic.List[string]]::new()

    if (-not $SkipTasks) {
        foreach ($taskName in @($Plan.TaskNames)) {
            $task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue

            if ($null -ne $task) {
                # Stop the exact managed broker task before removing it so no
                # orphan persistent broker process survives an uninstall.
                if ($taskName -ieq "DevWorkspace-ElevatedBroker" -and [string]$task.State -eq "Running") {
                    try { Stop-ScheduledTask -TaskName $taskName -ErrorAction Stop } catch { }
                }

                Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
                $actions.Add("Removed scheduled task '$taskName'.")
            }
        }
    }

    if ($Plan.RestoreLegacyShim) {
        [System.IO.File]::Copy($Plan.LegacyShimBackup, $Plan.LegacyShimPath, $true)
        $actions.Add("Restored the pre-install legacy ws.cmd.")
    }

    if ($Plan.RestoreHotkey) {
        [System.IO.File]::Copy($Plan.HotkeyBackup, $Plan.HotkeyPath, $true)
        $actions.Add("Restored the pre-install TerminalShortcut.ahk.")
    }
    elseif ($Plan.RemoveHotkey) {
        Remove-Item -LiteralPath $Plan.HotkeyPath -Force
        $actions.Add("Removed the DevWS-managed TerminalShortcut.ahk.")
    }

    if ($Plan.RemovePathEntry) {
        $userPath = Get-DevWSUserPathText
        $removed = Remove-DevWSPathEntry -PathText $userPath -Entry $Plan.PathEntry

        if ($removed.Removed) {
            Set-DevWSUserPathText -PathText $removed.PathText
            $actions.Add("Removed the DevWS bin directory from the user PATH.")
        }
    }

    foreach ($directory in @($Plan.AppPath, $Plan.HelpersPath, $Plan.WorkersPath, $Plan.BinPath)) {
        if (-not $directory.StartsWith($Plan.InstallRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove a path outside the install root: $directory"
        }

        if (Test-Path -LiteralPath $directory -PathType Container) {
            Remove-Item -LiteralPath $directory -Recurse -Force
            $actions.Add("Removed $directory")
        }
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$Plan.PrivilegedPath)) {
        $privilegedPath = [string]$Plan.PrivilegedPath
        $privilegedLeaf = Split-Path -Leaf $privilegedPath
        $privilegedParentLeaf = Split-Path -Leaf (Split-Path -Parent $privilegedPath)

        if (-not [System.IO.Path]::IsPathRooted($privilegedPath) -or
            $privilegedLeaf -ine "privileged" -or
            $privilegedParentLeaf -ine "DevWS" -or
            (Test-DevWSPathUnderRoot -Path $Plan.InstallRoot -Root $privilegedPath)) {
            throw "Refusing to remove an unexpected privileged path: $privilegedPath"
        }

        if (Test-Path -LiteralPath $privilegedPath -PathType Container) {
            Remove-Item -LiteralPath $privilegedPath -Recurse -Force
            $actions.Add("Removed $privilegedPath")
        }

        $privilegedParent = Split-Path -Parent $privilegedPath

        if ((Test-Path -LiteralPath $privilegedParent -PathType Container) -and
            @(Get-ChildItem -LiteralPath $privilegedParent -Force -ErrorAction SilentlyContinue).Count -eq 0) {
            Remove-Item -LiteralPath $privilegedParent -Force
            $actions.Add("Removed $privilegedParent")
        }
    }

    if ([bool]$Plan.RemoveProtectedState -and -not [string]::IsNullOrWhiteSpace([string]$Plan.ProtectedStatePath)) {
        $protectedResult = Remove-DevWSProtectedStateRootSafe -Root ([string]$Plan.ProtectedStatePath)

        if (@($protectedResult.Removed).Count -gt 0) {
            foreach ($removedPath in @($protectedResult.Removed)) {
                $actions.Add("Removed $removedPath")
            }
        }

        if ([bool]$protectedResult.Preserved) {
            $actions.Add($protectedResult.Message)
        }
    }

    if ($Plan.RemoveState) {
        if (-not $Plan.StatePath.StartsWith($Plan.InstallRoot, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove a path outside the install root: $($Plan.StatePath)"
        }

        if (Test-Path -LiteralPath $Plan.StatePath -PathType Container) {
            Remove-Item -LiteralPath $Plan.StatePath -Recurse -Force
            $actions.Add("Removed $($Plan.StatePath)")
        }
    }

    if ($Plan.RemoveCanonicalConfig) {
        if (Test-Path -LiteralPath $Plan.CanonicalPath -PathType Leaf) {
            Remove-Item -LiteralPath $Plan.CanonicalPath -Force
            $actions.Add("Removed the canonical workspace config.")
        }
    }

    return $actions.ToArray()
}
