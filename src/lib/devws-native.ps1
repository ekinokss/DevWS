# DevWS shared native runtime loader.
#
# Single owner of the generated DevWS native assembly. One assembly exposes
# every DevWS native interop type:
#
#     DevWSWindowOpsNative            (window operations)
#     DevWSAppWindowNative            (generic top-level enumeration)
#     DevWSAppOwnershipNative         (window ownership properties)
#     DevWSAppWindowCandidateCollector + DevWSAppWindowCandidate
#                                     (app-window candidate fact acquisition)
#     DevWSTerminalNative             (fast WT top-level HWND enumeration)
#     DevWSBrokerPipeNative           (secure elevated broker pipe creation)
#     DevWSMonitorNative              (read-only display topology facts)
#     DevWSPrivilegeNative            (privileged identity: WT package query +
#                                      process token integrity)
#
# The runtime layout is derived from this file's own location:
#   repository: <repo>\src\lib\devws-native.ps1
#               -> compile every tracked src\native\*.cs once per process
#   installed user-owned: <InstallRoot>\app\lib\devws-native.ps1
#               -> byte-load app\native\DevWS.Native.dll (never compiles);
#                  consumed by the Medium CLI (monitor/app/window facts)
#   installed privileged: <privileged root>\lib\devws-native.ps1
#               -> byte-load <privileged root>\native\DevWS.Native.dll;
#                  consumed by High workers/broker (window ops + broker pipe)
# Both installed DLL copies are generated from the same tracked C# sources by
# install.ps1 and are byte-identical.
#
# The loader never probes the current directory, PATH, the GAC, or an
# AssemblyResolve handler. Installed execution byte-loads the generated DLL at
# most once per process, so the file is never locked and can be atomically
# replaced by a later install.

$script:DevWSNativeSourceFileNames = @(
    "devws-window-ops.cs",
    "devws-app-window.cs",
    "devws-app-ownership.cs",
    "devws-app-candidates.cs",
    "devws-terminal-candidates.cs",
    "devws-broker-pipe.cs",
    "devws-monitor.cs",
    "devws-privilege-identity.cs",
    "devws-worker-pipe-identity.cs"
)

function Get-DevWSNativeSourceTypeMap {
    # Native source file -> required types. Repository mode compiles exactly
    # the missing sources, so a partially initialized process can never hit a
    # duplicate-type-definition failure.
    return [ordered]@{
        "devws-window-ops.cs"           = @("DevWSWindowOpsNative")
        "devws-app-window.cs"           = @("DevWSAppWindowNative")
        "devws-app-ownership.cs"        = @("DevWSAppOwnershipNative")
        "devws-app-candidates.cs"       = @("DevWSAppWindowCandidateCollector", "DevWSAppWindowCandidate")
        "devws-terminal-candidates.cs"  = @("DevWSTerminalNative")
        "devws-broker-pipe.cs"          = @("DevWSBrokerPipeNative")
        "devws-monitor.cs"              = @("DevWSMonitorNative", "DevWSMonitorGdiRow", "DevWSMonitorPathRow", "DevWSMonitorPathSnapshot")
        "devws-privilege-identity.cs"   = @("DevWSPrivilegeNative")
        "devws-worker-pipe-identity.cs" = @("DevWSWorkerPipeIdentityNative")
    }
}

function Get-DevWSNativeRequiredTypeNames {
    return @(
        "DevWSWindowOpsNative",
        "DevWSAppWindowNative",
        "DevWSAppOwnershipNative",
        "DevWSAppWindowCandidateCollector",
        "DevWSAppWindowCandidate",
        "DevWSTerminalNative",
        "DevWSBrokerPipeNative",
        "DevWSMonitorNative",
        "DevWSMonitorGdiRow",
        "DevWSMonitorPathRow",
        "DevWSMonitorPathSnapshot",
        "DevWSPrivilegeNative",
        "DevWSWorkerPipeIdentityNative"
    )
}

function Test-DevWSTerminalNativeMethodSurface {
    # The exact-HWND terminal class check is part of the generated native
    # contract. A type-only check would let an older assembly load and fail
    # later with a missing-method error at the first presence observation.
    param([AllowNull()]$Type = $null)

    if ($null -eq $Type) {
        $Type = ([System.Management.Automation.PSTypeName]'DevWSTerminalNative').Type
    }

    if ($null -eq $Type) {
        return $false
    }

    $flags = [System.Reflection.BindingFlags]::Public -bor [System.Reflection.BindingFlags]::Static
    $method = $Type.GetMethod('IsWindowsTerminalTopLevelHwnd', $flags)

    if ($null -eq $method) {
        return $false
    }

    $parameters = @($method.GetParameters())

    return ($parameters.Count -eq 1 -and
        $parameters[0].ParameterType -eq [long] -and
        $method.ReturnType -eq [bool])
}

function Test-DevWSNativeRuntimeLoaded {
    foreach ($typeName in @(Get-DevWSNativeRequiredTypeNames)) {
        if ($null -eq ([System.Management.Automation.PSTypeName]$typeName).Type) {
            return $false
        }
    }

    return (Test-DevWSTerminalNativeMethodSurface)
}

function Get-DevWSNativeRuntimeLayout {
    param(
        [string]$LibRoot = $PSScriptRoot
    )

    $appRoot = Split-Path -Parent $LibRoot

    switch (Split-Path -Leaf $appRoot) {
        "src" {
            return [pscustomobject]@{
                Mode        = "repository"
                AppRoot     = $appRoot
                NativeRoot  = (Join-Path $appRoot "native")
                SourcePaths = @($script:DevWSNativeSourceFileNames | ForEach-Object { Join-Path $appRoot "native\$_" })
                DllPath     = $null
            }
        }
        "app" {
            # Installed user-owned runtime (Medium hosts): the normal DLL copy.
            return [pscustomobject]@{
                Mode        = "installed"
                AppRoot     = $appRoot
                NativeRoot  = (Join-Path $appRoot "native")
                SourcePaths = @()
                DllPath     = (Join-Path $appRoot "native\DevWS.Native.dll")
            }
        }
        "privileged" {
            # Installed administrator-protected runtime (High hosts): the
            # privileged DLL copy. High processes must never load the
            # user-writable app\native copy.
            return [pscustomobject]@{
                Mode        = "privileged"
                AppRoot     = $appRoot
                NativeRoot  = (Join-Path $appRoot "native")
                SourcePaths = @()
                DllPath     = (Join-Path $appRoot "native\DevWS.Native.dll")
            }
        }
        default {
            throw "Unrecognized DevWS native layout: '$LibRoot' is neither '<root>\src\lib', '<root>\app\lib' nor '<privileged root>\lib'; cannot resolve the DevWS native runtime."
        }
    }
}

function Initialize-DevWSNativeRuntime {
    # Loads/compiles the single native assembly at most once per process. The
    # fast path is a type-presence check; every subsystem initializer delegates
    # here behind its own guard.
    if (Test-DevWSNativeRuntimeLoaded) {
        return
    }

    $layout = Get-DevWSNativeRuntimeLayout

    if ($layout.Mode -eq "repository") {
        $typeMap = Get-DevWSNativeSourceTypeMap
        $sourcesToCompile = [System.Collections.Generic.List[string]]::new()

        foreach ($fileName in $script:DevWSNativeSourceFileNames) {
            $missing = @($typeMap[$fileName] | Where-Object { $null -eq ([System.Management.Automation.PSTypeName]$_).Type })

            if ($missing.Count -gt 0) {
                $sourcesToCompile.Add((Join-Path $layout.NativeRoot $fileName)) | Out-Null
            }
        }

        foreach ($sourcePath in @($sourcesToCompile)) {
            if (-not (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
                throw "DevWS native interop source is missing: $sourcePath."
            }
        }

        # One Add-Type for every missing source: a cold process compiles the
        # whole native set together, and repeated initialization never reaches
        # this branch.
        if ($sourcesToCompile.Count -gt 0) {
            Add-Type -Path @($sourcesToCompile) -ErrorAction Stop
        }
    }
    else {
        if (-not (Test-Path -LiteralPath $layout.DllPath -PathType Leaf)) {
            throw "The generated DevWS native runtime is missing: $($layout.DllPath). Run install.ps1 to generate it."
        }

        try {
            # Byte loading never locks the DLL, so a later install can replace
            # it while this process still holds the previously loaded assembly.
            $assembly = [System.Reflection.Assembly]::Load([System.IO.File]::ReadAllBytes($layout.DllPath))
        }
        catch {
            throw "The generated DevWS native runtime could not be loaded ($($layout.DllPath)): $($_.Exception.Message). Run install.ps1 to regenerate it."
        }

        $missingTypes = @(Get-DevWSNativeRequiredTypeNames | Where-Object { $null -eq $assembly.GetType($_, $false) })

        if ($missingTypes.Count -gt 0) {
            throw "The generated DevWS native runtime is incomplete ($($layout.DllPath)): missing $($missingTypes -join ', '). Run install.ps1 to regenerate it."
        }

        $terminalType = $assembly.GetType("DevWSTerminalNative", $false)

        if (-not (Test-DevWSTerminalNativeMethodSurface -Type $terminalType)) {
            throw "The generated DevWS native runtime is stale ($($layout.DllPath)): DevWSTerminalNative.IsWindowsTerminalTopLevelHwnd is missing or has an unexpected signature. Run install.ps1 to regenerate it."
        }
    }

    # Post-condition: every required type and the terminal method surface must
    # resolve through PowerShell.
    $stillMissing = @(Get-DevWSNativeRequiredTypeNames | Where-Object { $null -eq ([System.Management.Automation.PSTypeName]$_).Type })

    if ($stillMissing.Count -gt 0) {
        throw "DevWS native runtime initialization did not expose: $($stillMissing -join ', ')."
    }

    if (-not (Test-DevWSTerminalNativeMethodSurface)) {
        throw "DevWS native runtime is stale or incomplete: DevWSTerminalNative.IsWindowsTerminalTopLevelHwnd is missing or has an unexpected signature. Run install.ps1 to regenerate it."
    }
}
