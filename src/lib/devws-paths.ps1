# DevWS path abstraction.
#
# Every install/runtime path is derived here so literal %LOCALAPPDATA%\DevWS
# construction does not spread across the source tree. Three layouts are
# supported deterministically (Public Security Phase 1 split):
#
#   repository (development/tests):
#     <repo>\src\ws.ps1
#     <repo>\src\lib\...            -> recognized by the "src" parent leaf
#     <repo>\src\helpers\...
#     <repo>\src\workers\...
#     <repo>\config\workspace.default.json
#
#   installed user-owned runtime (Medium hosts + installer):
#     %LOCALAPPDATA%\DevWS\app\ws.ps1
#     %LOCALAPPDATA%\DevWS\app\lib\...
#     %LOCALAPPDATA%\DevWS\helpers\...   (medium-only helper copies)
#     %LOCALAPPDATA%\DevWS\bin\ws.cmd
#     %LOCALAPPDATA%\DevWS\state\...
#
#   installed privileged runtime (High hosts; administrator-protected):
#     %ProgramFiles%\DevWS\privileged\workers\...
#     %ProgramFiles%\DevWS\privileged\lib\...      (High-reachable copies)
#     %ProgramFiles%\DevWS\privileged\native\DevWS.Native.dll
#     %ProgramFiles%\DevWS\privileged\helpers\...
#
# Security rule (Public Security Phase 1): every script/library/DLL/helper a
# High DevWS process executes or loads comes from the administrator-protected
# privileged root. The privileged root is NEVER derived from process
# environment variables: installed privileged hosts derive it from their own
# location, and every other context derives it from the registry-backed
# Program Files known folder. The DEVWS_* path overrides are honored only in
# the repository layout, so a scheduled High host can never be redirected to
# user-writable privileged code. State/config/diagnostic-trace overrides stay
# honored in every layout (user-authority paths; Security Phase 2 scope).
#
# The legacy v1 directory (%USERPROFILE%\.ws) is never used for new v2 runtime
# state. It only remains as read-only rollback/migration input.

function Get-DevWSPathsLayout {
    # Layout discriminator derived from this file's own location, never from
    # process environment. An unrecognized location fails closed in the
    # consumers that care about it.
    $appRootName = Split-Path -Leaf (Split-Path -Parent $PSScriptRoot)

    if ($appRootName -ieq "src")        { return "repository" }
    if ($appRootName -ieq "app")        { return "installed-normal" }
    if ($appRootName -ieq "privileged") { return "installed-privileged" }

    return "unsupported"
}

function Test-DevWSPathsOverrideAllowed {
    # DEVWS_* path overrides are test/development inputs. They are honored
    # only when the runtime executes from the repository layout.
    return ((Get-DevWSPathsLayout) -eq "repository")
}

function Test-DevWSPathUnderRoot {
    param(
        [string]$Path,
        [string]$Root
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or [string]::IsNullOrWhiteSpace($Root)) {
        return $false
    }

    try {
        $fullPath = [System.IO.Path]::GetFullPath($Path)
        $fullRoot = [System.IO.Path]::GetFullPath($Root)
    }
    catch {
        return $false
    }

    if ($fullPath.Equals($fullRoot, [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }

    return $fullPath.StartsWith(($fullRoot.TrimEnd('\') + '\'), [StringComparison]::OrdinalIgnoreCase)
}

function Get-DevWSDefaultInstallRoot {
    # Registry-backed known folder: never the LOCALAPPDATA environment value.
    return (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) "DevWS")
}

function Get-DevWSInstallRoot {
    # The user-owned runtime root (app/bin/state live under it).
    $layout = Get-DevWSPathsLayout

    if ($layout -eq "installed-normal") {
        return (Split-Path -Parent (Get-DevWSAppRoot))
    }

    if ($layout -eq "installed-privileged") {
        return (Get-DevWSDefaultInstallRoot)
    }

    if ((Test-DevWSPathsOverrideAllowed) -and -not [string]::IsNullOrWhiteSpace($env:DEVWS_INSTALL_ROOT)) {
        return $env:DEVWS_INSTALL_ROOT.Trim()
    }

    return (Get-DevWSDefaultInstallRoot)
}

function Get-DevWSPrivilegedInstallRoot {
    # The administrator-protected privileged runtime root. Installed privileged
    # hosts derive it from their own location; every other context derives it
    # from the registry-backed Program Files known folder. Environment
    # variables are deliberately not consulted.
    if ((Get-DevWSPathsLayout) -eq "installed-privileged") {
        return (Get-DevWSAppRoot)
    }

    $programFiles = [Environment]::GetFolderPath('ProgramFiles')

    if ([string]::IsNullOrWhiteSpace($programFiles)) {
        throw "The Program Files folder could not be resolved; cannot locate the DevWS privileged runtime root."
    }

    return (Join-Path $programFiles "DevWS\privileged")
}

function Get-DevWSPrivilegedLibRoot {
    return (Join-Path (Get-DevWSPrivilegedInstallRoot) "lib")
}

function Get-DevWSPrivilegedWorkersRoot {
    return (Join-Path (Get-DevWSPrivilegedInstallRoot) "workers")
}

function Get-DevWSPrivilegedHelpersRoot {
    return (Join-Path (Get-DevWSPrivilegedInstallRoot) "helpers")
}

function Get-DevWSPrivilegedNativeRoot {
    return (Join-Path (Get-DevWSPrivilegedInstallRoot) "native")
}

function Get-DevWSPrivilegedNativeDllPath {
    return (Join-Path (Get-DevWSPrivilegedNativeRoot) "DevWS.Native.dll")
}

function Get-DevWSPrivilegedLibraryNames {
    # Deterministic High-reachable library set. Keep in sync with the imports
    # of src\workers\*.ps1; the privileged-runtime test group compares both
    # sets so a new worker import cannot silently escape the privileged copy.
    return @(
        "devws-ahk.ps1",
        "devws-bindings.ps1",
        "devws-broker-protocol.ps1",
        "devws-config.ps1",
        "devws-coordinator.ps1",
        "devws-cwd-paths.ps1",
        "devws-cwd.ps1",
        "devws-identity.ps1",
        "devws-install.ps1",
        "devws-locator.ps1",
        "devws-native.ps1",
        "devws-paths.ps1",
        "devws-state.ps1",
        "devws-terminal.ps1",
        "devws-terminal-launch.ps1",
        "devws-terminal-operations.ps1",
        "devws-uia.ps1",
        "devws-window-ops.ps1",
        "devws-worker-protocol.ps1"
    )
}

function Get-DevWSPrivilegedWorkerNames {
    return @(
        "elevated.ps1",
        "elevated-broker.ps1",
        "elevated-capture.ps1",
        "elevated-focus.ps1",
        "elevated-reset.ps1"
    )
}

function Get-DevWSPrivilegedHelperNames {
    return @(
        "cwd-shell-bootstrap.ps1",
        "reset-window.ahk",
        "window-helper.ahk"
    )
}

function Assert-DevWSPrivilegedRuntimeComplete {
    # Fail-closed completeness check for the administrator-protected runtime.
    # Called by installed High workers before any work and by the health
    # checks; it never repairs anything.
    param([string]$Root)

    if ([string]::IsNullOrWhiteSpace($Root)) {
        $Root = Get-DevWSPrivilegedInstallRoot
    }

    $missing = [System.Collections.Generic.List[string]]::new()

    foreach ($name in @(Get-DevWSPrivilegedLibraryNames)) {
        $path = Join-Path $Root "lib\$name"

        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $missing.Add($path) | Out-Null
        }
    }

    foreach ($name in @(Get-DevWSPrivilegedWorkerNames)) {
        $path = Join-Path $Root "workers\$name"

        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $missing.Add($path) | Out-Null
        }
    }

    foreach ($name in @(Get-DevWSPrivilegedHelperNames)) {
        $path = Join-Path $Root "helpers\$name"

        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $missing.Add($path) | Out-Null
        }
    }

    $dllPath = Join-Path $Root "native\DevWS.Native.dll"

    if (-not (Test-Path -LiteralPath $dllPath -PathType Leaf)) {
        $missing.Add($dllPath) | Out-Null
    }

    if ($missing.Count -gt 0) {
        throw "The DevWS privileged runtime at '$Root' is incomplete; missing: $($missing -join ', '). Run install.ps1 to repair the protected runtime."
    }
}

function Assert-DevWSWorkerLibraryRoot {
    # Called by every installed worker immediately after its library root is
    # resolved. Repository execution is allowed for development/tests; an
    # installed privileged host must resolve the exact privileged lib root and
    # carry a complete privileged runtime; user-writable installed layouts are
    # rejected outright.
    param([Parameter(Mandatory)][string]$LibDir)

    switch (Get-DevWSPathsLayout) {
        "repository" {
            return
        }
        "installed-privileged" {
            if (-not (Test-DevWSPathUnderRoot -Path $LibDir -Root (Get-DevWSPrivilegedLibRoot))) {
                throw "DevWS worker libraries resolved to '$LibDir' instead of the privileged lib root '$(Get-DevWSPrivilegedLibRoot)'; refusing to continue."
            }

            Assert-DevWSPrivilegedRuntimeComplete
        }
        "installed-normal" {
            throw "DevWS privileged workers must not run from the user-writable install layout ('$LibDir'). Run install.ps1."
        }
        default {
            throw "DevWS worker libraries resolved from an unsupported layout ('$LibDir'); refusing to continue."
        }
    }
}

function Get-DevWSAppRoot {
    # Repository: <repo>\src ; installed normal: <root>\app ; installed
    # privileged: <privileged root>.
    return (Split-Path -Parent $PSScriptRoot)
}

$script:DevWSOverrideHonorDecisionCache = $null

function Get-DevWSOverrideHonorDecision {
    # Pure decision table for the Medium-authority DEVWS_* path overrides
    # (DEVWS_STATE_ROOT / DEVWS_RUNTIME_ROOT / DEVWS_LAUNCH_TRACE):
    #
    #   repository layout  -> honored (fixture/test injection route)
    #   installed layouts  -> honored ONLY when the current process token
    #                         integrity is POSITIVELY Medium. High, System,
    #                         Low, Unknown, unsupported and unreadable token
    #                         labels all deny (fail-closed: an unprovable
    #                         integrity must never grant a potentially
    #                         privileged process an attacker-chosen path).
    #
    # DEVWS_CONFIG is deliberately NOT covered here: it remains intentional
    # user-controlled Class B input.
    param(
        [Parameter(Mandatory)][string]$Layout,
        [Parameter(Mandatory)][bool]$MediumIntegrityConfirmed
    )

    if ($Layout -eq 'repository') {
        return $true
    }

    if ($Layout -eq 'installed-normal' -or $Layout -eq 'installed-privileged') {
        return $MediumIntegrityConfirmed
    }

    return $false
}

function Test-DevWSInstalledOverrideContext {
    # Cached per-process gate for the Medium-authority overrides above. The
    # token label is read through Get-DevWSProcessIntegrityLevel (the native
    # token reader; it never uses an external tool). A failed or unreadable
    # inspection denies, and the deny is cached for the process lifetime so a
    # failure can never later become an allow decision. Repository execution
    # never performs a token read.
    $layout = Get-DevWSPathsLayout
    $cache  = $script:DevWSOverrideHonorDecisionCache

    if ($null -ne $cache -and [string]$cache.Layout -eq $layout) {
        return [bool]$cache.Decision
    }

    $medium = $false

    if ($layout -ne 'repository') {
        try {
            $level  = Get-DevWSProcessIntegrityLevel
            $medium = ($null -ne $level -and $level.IsMedium -eq $true)
        }
        catch {
            $medium = $false
        }
    }

    $decision = Get-DevWSOverrideHonorDecision -Layout $layout -MediumIntegrityConfirmed $medium
    $script:DevWSOverrideHonorDecisionCache = [pscustomobject]@{ Layout = $layout; Decision = $decision }
    return $decision
}

function Get-DevWSStateRoot {
    # Disposable runtime state. The state overrides are honored only through
    # the Medium-authority gate: repository fixtures keep the raw injection
    # route, installed Medium keeps its user-authority override, and installed
    # High / unknown / unsupported contexts always resolve the known-folder-
    # derived default (Public Security Phase 2-E). Overrides are only
    # inspected (and can only trigger a token read) when actually present.
    $override = $env:DEVWS_STATE_ROOT

    if ([string]::IsNullOrWhiteSpace($override)) {
        # DEVWS_RUNTIME_ROOT is the legacy alias for the same override.
        $override = $env:DEVWS_RUNTIME_ROOT
    }

    if (-not [string]::IsNullOrWhiteSpace($override) -and (Test-DevWSInstalledOverrideContext)) {
        return $override.Trim()
    }

    return (Join-Path (Get-DevWSInstallRoot) "state")
}

function Get-DevWSRuntimeRoot {
    # Runtime state/generated files (request/result exchange, capture output,
    # generated AHK scripts, runtime HWND state) are disposable and live under
    # the state root.
    return (Get-DevWSStateRoot)
}

# ---------------------------------------------------------------------------
# Protected privileged-state foundation (Public Security Phase 2-A)
# ---------------------------------------------------------------------------
#
# HIGH AUTHORITY / MEDIUM READ-ONLY mutable state root:
#
#   %ProgramData%\DevWS\privileged-state\<current-user-SID>\
#
# Phase 2-A establishes (creates, secures and validates) this foundation. It is
# deliberately EMPTY in this phase: no runtime artifact (runtime state, capture
# artifacts, cwd tracking, worker exchange) uses it yet; later Phase-2 subphases
# relocate High-authored artifacts here.
#
# Security contract:
#   owner             BUILTIN\Administrators (S-1-5-32-544)
#   SYSTEM            FullControl      (S-1-5-18)
#   Administrators    FullControl      (S-1-5-32-544)
#   target user SID   ReadAndExecute   (directory and children, never
#                                      inherit-only, never write-capable)
#   inheritance       protected: no inherited ACEs
#   no DENY ACEs; identities are SIDs, never localized account names; the path
#   is derived only from the registry-backed ProgramData known folder plus the
#   current Windows SID, never from environment variables or user text.
#
# The elevated installer creates/validates the foundation; doctor/health
# validates it read-only. Repository/test fixtures may inject a base root
# through an explicit -TestBaseRoot parameter; installed layouts refuse that
# override (there is deliberately no environment-variable route).

function Get-DevWSCurrentUserSid {
    # The current Windows user SID. Never a username, never derived from
    # environment text. A resolution failure fails closed.
    $identity = [System.Security.Principal.WindowsIdentity]::GetCurrent()

    if ($null -eq $identity -or $null -eq $identity.User -or [string]::IsNullOrWhiteSpace($identity.User.Value)) {
        throw "The current Windows user SID could not be resolved; the DevWS protected state root cannot be derived."
    }

    return $identity.User.Value
}

function Get-DevWSPrivilegedStateBaseRoot {
    # <ProgramData>\DevWS\privileged-state, derived ONLY from the registry-backed
    # ProgramData known folder. Repository/tests may inject a fixture base root
    # with -TestBaseRoot or the repository-only DEVWS_PROTECTED_STATE_ROOT seam
    # (the value is the fixture's own base directory; 'privileged-state' is
    # appended). Installed layouts refuse both: no environment variable,
    # parameter or caller metadata can redirect installed High writes.
    param([string]$TestBaseRoot)

    if (-not [string]::IsNullOrWhiteSpace($TestBaseRoot)) {
        if ((Get-DevWSPathsLayout) -ne "repository") {
            throw "The DevWS protected state root cannot be redirected outside the repository layout; refusing to use '$TestBaseRoot'."
        }

        return (Join-Path $TestBaseRoot.Trim() "privileged-state")
    }

    if ((Test-DevWSPathsOverrideAllowed) -and -not [string]::IsNullOrWhiteSpace($env:DEVWS_PROTECTED_STATE_ROOT)) {
        return (Join-Path $env:DEVWS_PROTECTED_STATE_ROOT.Trim() "privileged-state")
    }

    $programData = [Environment]::GetFolderPath('CommonApplicationData')

    if ([string]::IsNullOrWhiteSpace($programData)) {
        throw "The ProgramData folder could not be resolved; cannot locate the DevWS privileged state root."
    }

    return (Join-Path (Join-Path $programData "DevWS") "privileged-state")
}

function Get-DevWSPrivilegedStateRoot {
    # <base>\<current-user-SID>. The SID may be supplied explicitly by fixture
    # callers; production callers use the current Windows user SID.
    param(
        [string]$TestBaseRoot,
        [string]$UserSid = ""
    )

    if ([string]::IsNullOrWhiteSpace($UserSid)) {
        $UserSid = Get-DevWSCurrentUserSid
    }
    else {
        try { $null = [System.Security.Principal.SecurityIdentifier]::new($UserSid) }
        catch { throw "The supplied protected state user SID '$UserSid' is not a valid security identifier." }
    }

    return (Join-Path (Get-DevWSPrivilegedStateBaseRoot -TestBaseRoot $TestBaseRoot) $UserSid)
}

function Resolve-DevWSSecurityIdentifier {
    # Accepts an SDDL SID string or an account-name string and returns a
    # SecurityIdentifier; returns $null when the identity cannot be resolved.
    param([string]$Identity)

    if ([string]::IsNullOrWhiteSpace($Identity)) { return $null }

    try { return [System.Security.Principal.SecurityIdentifier]::new($Identity) } catch { }

    try { return ([System.Security.Principal.NTAccount]::new($Identity)).Translate([System.Security.Principal.SecurityIdentifier]) } catch { }

    return $null
}

function New-DevWSPrivilegedStateDirectorySecurity {
    # Pure construction of the expected protected-state security descriptor.
    # Does not touch the filesystem, so tests can cover the policy without
    # elevation.
    #
    #   Kind "Base": the DEVWS containers (%ProgramData%\DevWS and
    #       privileged-state); BUILTIN\Users gets read+execute/list so the
    #       Medium user can read what later phases store beneath.
    #   Kind "User": one per-user SID root; the target user SID gets
    #       read+execute/list.
    #
    # All three ACEs apply to the object itself and inherit to children
    # (ContainerInherit|ObjectInherit, never inherit-only).
    param(
        [ValidateSet("Base", "User")]
        [string]$Kind = "Base",
        [string]$UserSid = ""
    )

    if ([string]::IsNullOrWhiteSpace($UserSid)) { $UserSid = Get-DevWSCurrentUserSid }

    $system  = [System.Security.Principal.SecurityIdentifier]::new("S-1-5-18")
    $admins  = [System.Security.Principal.SecurityIdentifier]::new("S-1-5-32-544")
    $users   = [System.Security.Principal.SecurityIdentifier]::new("S-1-5-32-545")
    $readAndExecute = [System.Security.AccessControl.FileSystemRights]::ReadAndExecute
    $fullControl    = [System.Security.AccessControl.FileSystemRights]::FullControl

    $trustee = $users

    if ($Kind -eq "User") {
        try { $trustee = [System.Security.Principal.SecurityIdentifier]::new($UserSid) }
        catch { throw "The supplied protected state user SID '$UserSid' is not a valid security identifier." }
    }

    $security = New-Object System.Security.AccessControl.DirectorySecurity
    $security.SetAccessRuleProtection($true, $false)   # protected DACL, no inherited ACEs
    $security.SetOwner($admins)

    $inherit = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'
    $none    = [System.Security.AccessControl.PropagationFlags]::None
    $allow   = [System.Security.AccessControl.AccessControlType]::Allow

    $security.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($system, $fullControl, $inherit, $none, $allow)))
    $security.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($admins, $fullControl, $inherit, $none, $allow)))
    $security.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule($trustee, $readAndExecute, $inherit, $none, $allow)))

    return $security
}

function Test-DevWSPrivilegedStateSecurity {
    # Semantic (not textual) validation of one protected-state security
    # descriptor. ACE enumeration order and SDDL spelling are irrelevant; the
    # required rights, trustees, inheritance and protection flags are what
    # matter. Returns { Ok; Errors; Owner; Kind }.
    param(
        [Parameter(Mandatory)]
        $Security,
        [ValidateSet("Base", "User")]
        [string]$Kind = "Base",
        [string]$UserSid = ""
    )

    if ([string]::IsNullOrWhiteSpace($UserSid)) { $UserSid = Get-DevWSCurrentUserSid }

    $errors = [System.Collections.Generic.List[string]]::new()

    # -- owner -------------------------------------------------------------
    # A freshly constructed descriptor exposes the owner through GetOwner();
    # descriptors that came from Get-Acl may carry an account-name string.
    $ownerSid = $null

    try { $ownerSid = $Security.GetOwner([System.Security.Principal.SecurityIdentifier]) } catch { $ownerSid = $null }

    if ($null -eq $ownerSid) {
        $ownerSid = Resolve-DevWSSecurityIdentifier -Identity ([string]$Security.Owner)
    }

    if ($null -eq $ownerSid) {
        $errors.Add("the owner '$($Security.Owner)' could not be resolved to a SID; expected BUILTIN\Administrators (S-1-5-32-544)")
    }
    elseif ($ownerSid.Value -ne "S-1-5-32-544") {
        $errors.Add("owner is '$($ownerSid.Value)'; expected BUILTIN\Administrators (S-1-5-32-544)")
    }

    # -- inheritance protection --------------------------------------------
    if (-not [bool]$Security.AreAccessRulesProtected) {
        $errors.Add("the DACL is not protected: inherited ACEs are still present")
    }

    # -- access rules ------------------------------------------------------
    try { $rules = @($Security.GetAccessRules($true, $true, [System.Security.Principal.SecurityIdentifier])) }
    catch { $rules = @($Security.GetAccessRules($true, $true, [System.Security.Principal.NTAccount])) }

    $fullControl    = [System.Security.AccessControl.FileSystemRights]::FullControl
    $readAndExecute = [System.Security.AccessControl.FileSystemRights]::ReadAndExecute
    $synchronize    = [System.Security.AccessControl.FileSystemRights]::Synchronize
    $inheritMask    = [System.Security.AccessControl.InheritanceFlags]'ContainerInherit, ObjectInherit'

    $forbiddenBits = @(
        ,@("WriteData",                    [System.Security.AccessControl.FileSystemRights]::WriteData)
        ,@("AppendData",                   [System.Security.AccessControl.FileSystemRights]::AppendData)
        ,@("WriteExtendedAttributes",      [System.Security.AccessControl.FileSystemRights]::WriteExtendedAttributes)
        ,@("WriteAttributes",              [System.Security.AccessControl.FileSystemRights]::WriteAttributes)
        ,@("DeleteSubdirectoriesAndFiles", [System.Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles)
        ,@("Delete",                       [System.Security.AccessControl.FileSystemRights]::Delete)
        ,@("ChangePermissions",            [System.Security.AccessControl.FileSystemRights]::ChangePermissions)
        ,@("TakeOwnership",                [System.Security.AccessControl.FileSystemRights]::TakeOwnership)
    )

    $expectedTrustees = [ordered]@{
        "S-1-5-18"     = "SYSTEM"
        "S-1-5-32-544" = "BUILTIN\Administrators"
    }

    if ($Kind -eq "User") {
        $expectedTrustees[$UserSid] = "target user SID"
    }
    else {
        $expectedTrustees["S-1-5-32-545"] = "BUILTIN\Users"
    }

    $byTrustee = @{}

    foreach ($rule in $rules) {
        $trusteeSid = Resolve-DevWSSecurityIdentifier -Identity ([string]$rule.IdentityReference)

        if ($null -eq $trusteeSid) {
            $errors.Add("an access rule identity '$($rule.IdentityReference)' could not be resolved to a SID")
            continue
        }

        $sidValue = $trusteeSid.Value

        if ($rule.AccessControlType -eq [System.Security.AccessControl.AccessControlType]::Deny) {
            $errors.Add("unexpected DENY access rule for '$sidValue'")
            continue
        }

        if (-not $expectedTrustees.Contains($sidValue)) {
            $errors.Add("unexpected access rule for '$sidValue' (rights '$($rule.FileSystemRights)')")
            continue
        }

        if (-not $byTrustee.ContainsKey($sidValue)) { $byTrustee[$sidValue] = [System.Collections.Generic.List[object]]::new() }
        $byTrustee[$sidValue].Add($rule) | Out-Null
    }

    foreach ($expected in $expectedTrustees.Keys) {
        $label = $expectedTrustees[$expected]

        if (-not $byTrustee.ContainsKey($expected)) {
            $errors.Add("missing access rule for $label ($expected)")
            continue
        }

        $rights = [System.Security.AccessControl.FileSystemRights]0

        foreach ($rule in $byTrustee[$expected]) {
            $ruleConformant = $true

            if ([bool]$rule.IsInherited) {
                $errors.Add("an access rule for $label is inherited; only explicit ACEs apply to the protected state root")
                $ruleConformant = $false
            }

            if ($rule.InheritanceFlags -ne $inheritMask) {
                $errors.Add("an access rule for $label must have exactly ContainerInherit|ObjectInherit inheritance (got '$($rule.InheritanceFlags)')")
                $ruleConformant = $false
            }

            if ($rule.PropagationFlags -ne [System.Security.AccessControl.PropagationFlags]::None) {
                $errors.Add("an access rule for $label must not use propagation flags (got '$($rule.PropagationFlags)')")
                $ruleConformant = $false
            }

            if ($ruleConformant) {
                $rights = $rights -bor $rule.FileSystemRights
            }
        }

        if ($expected -in @("S-1-5-18", "S-1-5-32-544")) {
            if (([int]$rights -band [int]$fullControl) -ne [int]$fullControl) {
                $errors.Add("$label does not have FullControl")
            }
            continue
        }

        # Target user (or BUILTIN\Users): read+execute/list only.
        $extra = [int]$rights -band (-bnot ([int]$readAndExecute -bor [int]$synchronize))

        if ($extra -ne 0) {
            $granted = [System.Collections.Generic.List[string]]::new()

            foreach ($pair in $forbiddenBits) {
                if (([int]$rights -band [int]$pair[1]) -ne 0) { $granted.Add($pair[0]) }
            }

            if ($granted.Count -eq 0) { $granted.Add(("0x{0:X}" -f $extra)) }

            $errors.Add("$label grants unexpected write-capable rights: $($granted -join ', ')")
        }

        if (([int]$rights -band [int]$readAndExecute) -ne [int]$readAndExecute) {
            $errors.Add("$label is missing part of the required read+execute/list access")
        }
    }

    return [pscustomobject]@{
        Ok     = ($errors.Count -eq 0)
        Errors = @($errors)
        Owner  = $(if ($null -ne $ownerSid) { $ownerSid.Value } else { [string]$Security.Owner })
        Kind   = $Kind
    }
}

function Get-DevWSProtectedStateComponentChain {
    # The protected rooted path contract:
    #
    #   installed:  <ProgramData>\DevWS\privileged-state\<SID>
    #               anchor = <ProgramData>; components = [DevWS, privileged-state, <SID>]
    #   fixtures:   <TestBaseRoot>\privileged-state\<SID>
    #               anchor = <TestBaseRoot>; components = [privileged-state, <SID>]
    #
    # The installed route is recognized deterministically by the ProgramData
    # known folder (the fixture route always lives outside the real DevWS
    # container), so the DevWS container itself is created/validated with the
    # base security policy instead of being blindly trusted.
    param([Parameter(Mandatory)][string]$Root)

    $baseRoot = Split-Path -Parent $Root

    if ([string]::IsNullOrWhiteSpace($baseRoot) -or (Split-Path -Leaf $baseRoot) -ine "privileged-state") {
        throw "The protected state root '$Root' does not follow the <anchor>\privileged-state\<SID> contract."
    }

    $programData = [Environment]::GetFolderPath('CommonApplicationData')
    $expectedDevWS = Join-Path $programData "DevWS"

    if ([string]::IsNullOrWhiteSpace($programData) -eq $false -and
        (Split-Path -Parent $baseRoot) -ieq $expectedDevWS) {
        return [pscustomobject]@{
            Anchor     = $programData
            Components = @($expectedDevWS, $baseRoot, $Root)
            Installed  = $true
        }
    }

    $anchor = Split-Path -Parent $baseRoot

    if ([string]::IsNullOrWhiteSpace($anchor)) {
        throw "The protected state root '$Root' does not follow the <anchor>\privileged-state\<SID> contract."
    }

    return [pscustomobject]@{
        Anchor     = $anchor
        Components = @($baseRoot, $Root)
        Installed  = $false
    }
}

function Test-DevWSProtectedStatePathSafety {
    # Read-only structural walk of one protected-state component chain: the
    # anchor and every EXISTING component must be an ordinary directory (never
    # a file) and never a reparse point. Missing components are reported
    # separately from unsafe ones. Returns { Ok; Errors; Missing; Anchor;
    # Components; Complete }.
    param([Parameter(Mandatory)][string]$Root)

    if (-not [System.IO.Path]::IsPathRooted($Root)) {
        throw "The protected state root '$Root' must be an absolute path."
    }

    $chain = Get-DevWSProtectedStateComponentChain -Root $Root
    $errors = [System.Collections.Generic.List[string]]::new()
    $missing = [System.Collections.Generic.List[string]]::new()
    $complete = $true

    $allComponents = @($chain.Anchor) + @($chain.Components)

    foreach ($component in $allComponents) {
        if (-not (Test-Path -LiteralPath $component)) {
            if ($component -ieq $chain.Anchor) {
                $errors.Add("the trusted anchor '$component' does not exist")
            }
            else {
                $missing.Add($component)
                $complete = $false
            }

            continue
        }

        $item = $null

        try { $item = Get-Item -LiteralPath $component -Force -ErrorAction Stop }
        catch {
            $errors.Add("'$component' could not be inspected: $($_.Exception.Message)")
            continue
        }

        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            $errors.Add("'$component' is a reparse point (junction/symlink); the protected state path must be ordinary directories only")
            continue
        }

        if (-not $item.PSIsContainer) {
            $errors.Add("'$component' is not a directory")
        }
    }

    return [pscustomobject]@{
        Ok         = ($errors.Count -eq 0)
        Errors     = @($errors)
        Missing    = @($missing)
        Anchor     = $chain.Anchor
        Components = @($chain.Components)
        Complete   = $complete
    }
}

function Get-DevWSProtectedStateComponentKind {
    # Component position policy: the SID root carries the per-user policy; the
    # containers above it carry the base policy.
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]]$Components,
        [Parameter(Mandatory)]
        [string]$Component
    )

    if ($Component -ieq [string]$Components[$Components.Count - 1]) { return "User" }

    return "Base"
}

function Get-DevWSProtectedStateObjectIdentity {
    # Stable identity of one path object through a native handle opened WITHOUT
    # following reparse points (a junction/symlink is inspected as itself).
    # Returns { Ok; VolumeSerial; FileIndex; Attributes; IsDirectory; IsReparse;
    # Error }. The volume serial + file index identify the exact object for
    # before/after comparisons during validation.
    param([Parameter(Mandatory)][string]$Path)

    Initialize-DevWSPrivilegeNativeRuntime

    $volumeSerial = [uint32]0
    $fileIndex    = [uint64]0
    $attributes   = [uint32]0
    $win32Error   = 0

    $ok = [DevWSPrivilegeNative]::TryOpenPathIdentity($Path, [ref]$volumeSerial, [ref]$fileIndex, [ref]$attributes, [ref]$win32Error)

    return [pscustomobject]@{
        Ok           = [bool]$ok
        VolumeSerial = $volumeSerial
        FileIndex    = $fileIndex
        Attributes   = $attributes
        IsDirectory  = (([int]$attributes -band 0x10) -ne 0)    # FILE_ATTRIBUTE_DIRECTORY
        IsReparse    = (([int]$attributes -band 0x400) -ne 0)   # FILE_ATTRIBUTE_REPARSE_POINT
        Error        = $win32Error
    }
}

function New-DevWSProtectedStateExclusiveDirectory {
    # Authoritative exclusive secure create (native CreateDirectoryW with the
    # final self-relative SDDL; the kernel performs the create atomically):
    #
    #   'Created'       -> THIS call created the exact directory with the
    #                      supplied security descriptor
    #   'AlreadyExists' -> another object is already at the path; the supplied
    #                      descriptor was NOT applied to it and the object must
    #                      be validated as untrusted input
    #
    # Used by the initializer and by explicit callers (fresh installs and
    # disposable POCs). Any other failure throws.
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Sddl
    )

    Initialize-DevWSPrivilegeNativeRuntime

    $win32Error = 0
    $result = [int][DevWSPrivilegeNative]::SecureCreateDirectory($Path, $Sddl, [ref]$win32Error)

    switch ($result) {
        0 { return "Created" }
        1 { return "AlreadyExists" }
        default {
            $message = ""

            try { $message = [System.ComponentModel.Win32Exception]::new($win32Error).Message } catch { }

            throw "The protected state directory '$Path' could not be created securely (Win32 ${win32Error}: $message)."
        }
    }
}

function Get-DevWSProtectedStateObjectInspection {
    # Handle-bound inspection with an EXPLICITLY OWNED lifetime: opens the
    # exact path WITHOUT following reparse points and reads BOTH the object
    # identity (volume serial + file index + attributes) and the owner/DACL
    # SDDL from THE SAME open handle, whose share mode omits FILE_SHARE_DELETE
    # (so a concurrent rename/delete cannot coexist with the inspection, and
    # an already-open delete-capable handle makes the open fail closed).
    # Identity and security can therefore never describe different objects -
    # there is no separate path-based ACL lookup.
    #
    # The returned object OWNS the open handle until Dispose() is called: the
    # CALLER MUST dispose it in a finally block, and the handle must stay open
    # across the complete semantic ACL validation (the whole
    # Test-DevWSPrivilegedStateSecurity decision), not merely across the
    # identity/descriptor read. Dispose() is idempotent (SafeFileHandle closes
    # exactly once) and a failed inspection owns no handle.
    #
    # Returns { Ok; VolumeSerial; FileIndex; Attributes; Sddl; IsDirectory;
    # IsReparse; Error; Scope } with an idempotent Dispose() method.
    param([Parameter(Mandatory)][string]$Path)

    Initialize-DevWSPrivilegeNativeRuntime

    $scope = [DevWSPrivilegeNative]::OpenAndInspectPath($Path)

    $inspection = [pscustomobject]@{
        Ok           = [bool]$scope.IsValid
        VolumeSerial = [uint32]$scope.VolumeSerial
        FileIndex    = [uint64]$scope.FileIndex
        Attributes   = [uint32]$scope.Attributes
        Sddl         = $scope.Sddl
        IsDirectory  = [bool]$scope.IsDirectory
        IsReparse    = [bool]$scope.IsReparse
        Error        = [int]$scope.Win32Error
        Scope        = $scope
    }

    $inspection | Add-Member -MemberType ScriptMethod -Name Dispose -Value { $this.Scope.Dispose() }

    return $inspection
}

function Test-DevWSProtectedStateAnchorSafety {
    # Anchor delete-child invariant (Public Security Phase 2-A):
    #   %ProgramData% itself must not grant the same-user MEDIUM token
    #   FILE_DELETE_CHILD (nor DELETE / WRITE_DAC / WRITE_OWNER) against the
    #   resolved anchor, or a validated DevWS container could still be removed
    #   or renamed through the parent.
    #
    # This is a REAL Windows access check (AccessCheck with the linked filtered
    # Medium token when the caller is elevated, otherwise a duplicated
    # impersonation copy of the current Medium token) evaluated on one
    # no-delete-shared open handle - never textual ACE matching. If the
    # Medium token cannot be obtained reliably the check
    # fails closed with an actionable error. There is no environment bypass;
    # repository fixtures never reach this production path (their chain is not
    # "installed"), so no fixture seam is needed here.
    #
    # TokenSource names exactly which subject was checked:
    #   linked-medium    - the linked filtered token of an elevated caller
    #   duplicate-medium - a duplicated impersonation copy of a Medium caller
    #   unavailable      - neither could be obtained (the check failed closed)
    #
    # Returns { Ok; Errors; TokenSource }.
    param([Parameter(Mandatory)][string]$Anchor)

    Initialize-DevWSPrivilegeNativeRuntime

    $errors = [System.Collections.Generic.List[string]]::new()

    $volumeSerial = [uint32]0
    $fileIndex    = [uint64]0
    $attributes   = [uint32]0
    $hasDeleteChild = $false
    $hasDelete      = $false
    $hasWriteDac    = $false
    $hasWriteOwner  = $false
    $tokenObtained  = $false
    $usedLinkedToken = $false
    $win32Error     = 0

    $ok = [DevWSPrivilegeNative]::TryInspectAnchorAccess(
        $Anchor,
        [ref]$volumeSerial, [ref]$fileIndex, [ref]$attributes,
        [ref]$hasDeleteChild, [ref]$hasDelete, [ref]$hasWriteDac, [ref]$hasWriteOwner,
        [ref]$tokenObtained, [ref]$usedLinkedToken, [ref]$win32Error)

    $tokenSource = $(if (-not $tokenObtained) { "unavailable" } elseif ($usedLinkedToken) { "linked-medium" } else { "duplicate-medium" })

    if (-not $ok) {
        if (-not $tokenObtained) {
            $errors.Add("The required Medium (filtered) token could not be obtained reliably for the anchor access check on '$Anchor' (Win32 $win32Error); refusing to assume the anchor is safe.")
        }
        else {
            $errors.Add("The anchor '$Anchor' could not be inspected for the delete-child invariant (Win32 $win32Error).")
        }

        return [pscustomobject]@{ Ok = $false; Errors = @($errors); TokenSource = $tokenSource }
    }

    $attributeFlags = [int]$attributes

    if (($attributeFlags -band 0x10) -eq 0) {
        $errors.Add("The anchor '$Anchor' is not an ordinary directory.")
    }

    if ($hasDeleteChild) {
        $errors.Add("The current user's Medium token has FILE_DELETE_CHILD against the anchor '$Anchor'; the protected state boundary cannot be established while the parent grants delete-child authority.")
    }

    if ($hasDelete) {
        $errors.Add("The current user's Medium token has DELETE against the anchor '$Anchor'.")
    }

    if ($hasWriteDac) {
        $errors.Add("The current user's Medium token has WRITE_DAC against the anchor '$Anchor'.")
    }

    if ($hasWriteOwner) {
        $errors.Add("The current user's Medium token has WRITE_OWNER against the anchor '$Anchor'.")
    }

    return [pscustomobject]@{ Ok = ($errors.Count -eq 0); Errors = @($errors); TokenSource = $tokenSource }
}

function Test-DevWSProtectedStateComponent {
    # Handle-bound, semantic validation of ONE protected-state component:
    #
    #   open exact path without following reparse
    #       -> hold a stable handle WITHOUT FILE_SHARE_DELETE
    #       -> read identity + attributes + owner/DACL from THAT SAME handle
    #       -> semantic ACL validation on the handle's descriptor
    #       -> decision established
    #       -> dispose (finally: every success, rejection, parsing exception
    #          and error path releases the handle exactly once)
    #
    # The validation handle REMAINS OPEN for the COMPLETE semantic security
    # decision (including the whole Test-DevWSPrivilegedStateSecurity call),
    # not merely across the identity/descriptor read. Identity and security
    # therefore provably describe the SAME filesystem object, no path-based ACL
    # lookup is used, and the no-delete-share hold blocks a concurrent
    # rename/delete for the full decision; an incompatible already-open handle
    # fails this open closed.
    #
    # Stability after a successful validation: the validated policy grants the
    # target user no write, no DELETE, no DeleteSubdirectoriesAndFiles, no
    # ChangePermissions and no TakeOwnership, the owner is
    # BUILTIN\Administrators, and (for the installed chain) the anchor denies
    # the Medium token FILE_DELETE_CHILD/DELETE/WRITE_DAC/WRITE_OWNER - so a
    # validated component cannot be renamed, deleted, replaced or re-DACL'd by
    # Medium while the installer descends into it. An untrusted existing
    # component is therefore never used as a parent for a High write.
    #
    # Returns { Ok; Errors; Stable }.
    param(
        [Parameter(Mandatory)][string]$Component,
        [Parameter(Mandatory)][ValidateSet("Base", "User")][string]$Kind,
        [string]$UserSid = ""
    )

    if ([string]::IsNullOrWhiteSpace($UserSid)) { $UserSid = Get-DevWSCurrentUserSid }

    $errors = [System.Collections.Generic.List[string]]::new()

    $inspection = Get-DevWSProtectedStateObjectInspection -Path $Component

    try {
        if (-not $inspection.Ok) {
            $errors.Add("The protected state component '$Component' could not be inspected through a stable handle-bound open (Win32 $($inspection.Error)); refusing to continue.")
            return [pscustomobject]@{ Ok = $false; Errors = @($errors); Stable = $false }
        }

        if ($inspection.IsReparse) {
            $errors.Add("The protected state component '$Component' is a reparse point; refusing to adopt it (remove it deliberately and re-run install.ps1).")
        }

        if (-not $inspection.IsDirectory) {
            $errors.Add("The protected state component '$Component' is not a directory; refusing to adopt it.")
        }

        if ($errors.Count -gt 0) {
            return [pscustomobject]@{ Ok = $false; Errors = @($errors); Stable = $false }
        }

        # Security comes from the SAME handle as the identity (self-relative
        # SDDL); that handle stays open until this function's finally block.
        $security = $null

        try {
            $security = New-Object System.Security.AccessControl.DirectorySecurity
            $security.SetSecurityDescriptorSddlForm([string]$inspection.Sddl)
        }
        catch {
            $security = $null
        }

        if ($null -eq $security) {
            $errors.Add("The protected state component '$Component' security descriptor could not be parsed from the stable handle inspection; refusing to continue.")
            return [pscustomobject]@{ Ok = $false; Errors = @($errors); Stable = $false }
        }

        $ownerSid = $null

        try { $ownerSid = $security.GetOwner([System.Security.Principal.SecurityIdentifier]) } catch { $ownerSid = $null }

        if ($null -eq $ownerSid) {
            $ownerSid = Resolve-DevWSSecurityIdentifier -Identity ([string]$security.Owner)
        }

        if ($null -eq $ownerSid -or $ownerSid.Value -ne "S-1-5-32-544") {
            $ownerDisplay = $(if ($null -ne $ownerSid) { $ownerSid.Value } else { [string]$security.Owner })
            $errors.Add("The protected state component '$Component' is owned by '$ownerDisplay' instead of BUILTIN\Administrators; refusing to adopt or take ownership of it.")
        }

        # The semantic security decision runs while the validation handle is
        # still held (no FILE_SHARE_DELETE): a competing delete-capable open
        # cannot coexist with it.
        $securityValidation = Test-DevWSPrivilegedStateSecurity -Security $security -Kind $Kind -UserSid $UserSid

        foreach ($securityError in @($securityValidation.Errors)) {
            $errors.Add("$Component`: $securityError")
        }

        return [pscustomobject]@{ Ok = ($errors.Count -eq 0); Errors = @($errors); Stable = ($errors.Count -eq 0) }
    }
    finally {
        $inspection.Dispose()
    }
}

function Test-DevWSPrivilegedStateRoot {
    # Read-only full validation of one protected state root: exact SID-derived
    # leaf, structural path safety from the anchor down, the per-component
    # handle-bound stable security contract (see
    # Test-DevWSProtectedStateComponent) and - for the INSTALLED chain - the
    # anchor delete-child invariant (Test-DevWSProtectedStateAnchorSafety:
    # a real Medium-token access check; fixtures never reach it because their
    # chain is not "installed").
    # Returns { Ok; Errors; Root; UserSid; Present }.
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$UserSid = ""
    )

    if ([string]::IsNullOrWhiteSpace($UserSid)) { $UserSid = Get-DevWSCurrentUserSid }

    $errors = [System.Collections.Generic.List[string]]::new()

    if ((Split-Path -Leaf $Root) -ine $UserSid) {
        $errors.Add("'$Root' is not the protected state root for the current user SID '$UserSid'")
    }

    $chain = $null

    try { $chain = Get-DevWSProtectedStateComponentChain -Root $Root }
    catch { $errors.Add($_.Exception.Message) }

    if ($null -ne $chain -and [bool]$chain.Installed) {
        $anchorValidation = Test-DevWSProtectedStateAnchorSafety -Anchor $chain.Anchor

        foreach ($anchorError in @($anchorValidation.Errors)) {
            $errors.Add($anchorError)
        }
    }

    $safety = Test-DevWSProtectedStatePathSafety -Root $Root

    foreach ($safetyError in @($safety.Errors)) { $errors.Add($safetyError) }
    foreach ($missingComponent in @($safety.Missing)) { $errors.Add("missing protected state component '$missingComponent' (run install.ps1)") }

    $present = $safety.Complete

    if ($present) {
        foreach ($component in @($safety.Components)) {
            $kind = Get-DevWSProtectedStateComponentKind -Components $safety.Components -Component $component
            $componentValidation = Test-DevWSProtectedStateComponent -Component $component -Kind $kind -UserSid $UserSid

            foreach ($componentError in @($componentValidation.Errors)) {
                $errors.Add($componentError)
            }
        }
    }

    return [pscustomobject]@{
        Ok      = ($errors.Count -eq 0)
        Errors  = @($errors)
        Root    = $Root
        UserSid = $UserSid
        Present = $present
    }
}

function Assert-DevWSPrivilegedStateRoot {
    # Throwing wrapper for callers that want fail-closed semantics.
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$UserSid = ""
    )

    $validation = Test-DevWSPrivilegedStateRoot -Root $Root -UserSid $UserSid

    if (-not $validation.Ok) {
        throw ("The DevWS protected state root is not valid:" + [Environment]::NewLine + "  - " + ($validation.Errors -join ([Environment]::NewLine + "  - ")))
    }

    return $validation
}

function Initialize-DevWSPrivilegedStateRoot {
    # Elevated installer entry point. Creates missing components through the
    # authoritative EXCLUSIVE secure create primitive (native CreateDirectoryW
    # with the final SDDL; the kernel performs the create atomically) and
    # validates existing components through the stable component validator.
    #
    # Race behavior: the create result - not any preliminary existence check -
    # is authoritative. 'Created' means this call created the exact directory
    # with the intended security descriptor; 'AlreadyExists' (including a
    # Medium process winning the race for C:\ProgramData\DevWS) is treated
    # exactly like any other pre-existing component and must pass the exact
    # owner/DACL/inheritance/reparse validation or the installer refuses. The
    # supplied descriptor is never applied to an existing object.
    #
    # Pre-existing-path policy (fail closed; the installer is a creator and
    # validator, never a security-repair utility):
    #   - missing component
    #       -> exclusive secure create; Created is recorded only after the
    #          object is immediately re-validated through a stable handle
    #   - exclusive create reports AlreadyExists (raced/pre-existing)
    #       -> validate as untrusted input: ordinary non-reparse directory,
    #          exact owner, exact ACL and inheritance; otherwise refuse
    #   - existing + wrong owner / wrong ACL / inheritance change / reparse /
    #     non-directory -> refuse (never Set-Acl, never take ownership)
    #
    # After a component validates it is Medium-immutable (no write, no DELETE,
    # no DELETE_CHILD, no WRITE_DAC, no ownership), so it is safe as the trusted
    # parent for the next descendant.
    #
    # Returns { Root; BaseRoot; UserSid; Created; Existing }.
    param(
        [string]$TestBaseRoot,
        [string]$UserSid = "",
        [scriptblock]$CreateAction = $null   # test seam: returns 'Created'/'AlreadyExists'/'Failure'
    )

    if ([string]::IsNullOrWhiteSpace($UserSid)) { $UserSid = Get-DevWSCurrentUserSid }

    $baseRoot = Get-DevWSPrivilegedStateBaseRoot -TestBaseRoot $TestBaseRoot
    $root     = Join-Path $baseRoot $UserSid
    $chain    = Get-DevWSProtectedStateComponentChain -Root $root
    $components = @($chain.Components)
    $componentCount = $components.Count

    if ($componentCount -lt 2 -or
        (Split-Path -Leaf $components[$componentCount - 1]) -cne $UserSid -or
        (Split-Path -Leaf $components[$componentCount - 2]) -ine "privileged-state" -or
        ($componentCount -gt 2 -and (Split-Path -Leaf $components[0]) -ine "DevWS")) {
        throw "The protected state path '$root' does not follow the expected <anchor>[\DevWS]\privileged-state\<SID> shape."
    }

    $anchor = $chain.Anchor
    $anchorIdentity = Get-DevWSProtectedStateObjectIdentity -Path $anchor

    if (-not $anchorIdentity.Ok -or -not $anchorIdentity.IsDirectory -or $anchorIdentity.IsReparse) {
        throw "The trusted anchor '$anchor' does not exist or is not an ordinary directory; refusing to create the protected state root."
    }

    if ([bool]$chain.Installed) {
        # Production anchor delete-child invariant: the resolved ProgramData
        # directory must not grant the same-user MEDIUM token FILE_DELETE_CHILD
        # (nor DELETE / WRITE_DAC / WRITE_OWNER) - verified with a real
        # access check on the linked filtered token - BEFORE any protected
        # component is created beneath it. Repository fixtures are never
        # "installed" chains, so there is no configuration or environment
        # bypass for the production path.
        $anchorSafety = Test-DevWSProtectedStateAnchorSafety -Anchor $anchor

        if (-not $anchorSafety.Ok) {
            throw ("The trusted anchor '$anchor' does not establish the protected state delete-child invariant:" + [Environment]::NewLine + "  - " + ($anchorSafety.Errors -join ([Environment]::NewLine + "  - ")))
        }
    }

    $created  = [System.Collections.Generic.List[string]]::new()
    $existing = [System.Collections.Generic.List[string]]::new()

    foreach ($component in @($chain.Components)) {
        $kind = Get-DevWSProtectedStateComponentKind -Components $chain.Components -Component $component
        $security = New-DevWSPrivilegedStateDirectorySecurity -Kind $kind -UserSid $UserSid

        # Optimization only: the exclusive create result below stays
        # authoritative for whether THIS invocation created the component.
        $observedMissing = -not (Test-Path -LiteralPath $component)

        if ($observedMissing) {
            $sddl = $security.GetSecurityDescriptorSddlForm(
                [System.Security.AccessControl.AccessControlSections]::Owner -bor
                [System.Security.AccessControl.AccessControlSections]::Access)

            $createResult = "Failure"

            if ($null -ne $CreateAction) {
                $createResult = [string](& $CreateAction $component $sddl)
            }
            else {
                $createResult = New-DevWSProtectedStateExclusiveDirectory -Path $component -Sddl $sddl
            }

            if ($createResult -eq "Created") {
                # Immediate validation through a stable handle: a path enters
                # Created only when this invocation created it AND it carries
                # the exact expected security here and now.
                $createdValidation = Test-DevWSProtectedStateComponent -Component $component -Kind $kind -UserSid $UserSid

                if (-not $createdValidation.Ok) {
                    throw ("The protected state component '$component' was created but failed immediate validation:" + [Environment]::NewLine + "  - " + ($createdValidation.Errors -join ([Environment]::NewLine + "  - ")))
                }

                $created.Add($component) | Out-Null
                continue
            }

            if ($createResult -ne "AlreadyExists") {
                throw "The protected state directory '$component' could not be created securely (result '$createResult')."
            }

            # 'AlreadyExists': fall through and validate the raced/pre-existing
            # object as untrusted input. The supplied security descriptor was
            # never applied to it.
        }

        $validation = Test-DevWSProtectedStateComponent -Component $component -Kind $kind -UserSid $UserSid

        if (-not $validation.Ok) {
            throw ("Protected state component '$component' has unexpected security. Refusing to repair it automatically; remove or repair it explicitly from an administrator shell and rerun install.ps1." + [Environment]::NewLine + "  - " + ($validation.Errors -join ([Environment]::NewLine + "  - ")))
        }

        $existing.Add($component) | Out-Null
    }

    $final = Test-DevWSPrivilegedStateRoot -Root $root -UserSid $UserSid

    if (-not $final.Ok) {
        throw ("The DevWS protected state root failed validation:" + [Environment]::NewLine + "  - " + ($final.Errors -join ([Environment]::NewLine + "  - ")))
    }

    return [pscustomobject]@{
        Root     = $root
        BaseRoot = $baseRoot
        UserSid  = $UserSid
        Created  = @($created)
        Existing = @($existing)
    }
}

function Test-DevWSProtectedStateRootRemovable {
    # Read-only removal planning for uninstall: a protected state root may be
    # removed only when it is structurally safe, carries the expected
    # security, and is empty. Returns { Ok; Reason }.
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$UserSid = ""
    )

    if ([string]::IsNullOrWhiteSpace($UserSid)) { $UserSid = Get-DevWSCurrentUserSid }

    $validation = Test-DevWSPrivilegedStateRoot -Root $Root -UserSid $UserSid

    if (-not $validation.Ok) {
        return [pscustomobject]@{ Ok = $false; Reason = "not a trusted DevWS protected state root ($($validation.Errors -join '; '))" }
    }

    $children = @(Get-ChildItem -LiteralPath $Root -Force -ErrorAction Stop)

    if ($children.Count -gt 0) {
        return [pscustomobject]@{ Ok = $false; Reason = "the protected state root is not empty ($($children.Count) entries); protected runtime state is preserved" }
    }

    return [pscustomobject]@{ Ok = $true; Reason = "empty and security-validated" }
}

# ---------------------------------------------------------------------------
# Protected capture publications and runtime cache (Public Security Phase 2-B)
# ---------------------------------------------------------------------------
#
# HIGH AUTHORITY / MEDIUM READ-ONLY publications:
#
#   <protected state root>\runtime-state.json
#   <protected state root>\captures\<operationId>\
#       publication.identity.json
#       capture-elevated.txt
#       capture-elevated.snapshots.json
#
# Installed paths derive ONLY from the registry-backed ProgramData known folder
# and the current Windows SID: environment overrides, request metadata and
# caller-supplied output paths never redirect them. Repository fixtures use the
# explicit -TestBaseRoot seam (refused outside the repository layout). The
# claim-transition and retention coordination is one small cross-process named
# mutex (Local\DevWS.CaptureClaim.v1) - no service, no queue, no lock file.

function Get-DevWSProtectedRuntimeStatePath {
    # The protected runtime cache file. Installed High writers and the Medium
    # status reader resolve it through this accessor; legacy LocalAppData
    # runtime state is never authority.
    param([string]$TestBaseRoot)
    return (Join-Path (Get-DevWSPrivilegedStateRoot -TestBaseRoot $TestBaseRoot) "runtime-state.json")
}

function Assert-DevWSProtectedOperationId {
    # Strict grammar before any path construction, with domain-exact value
    # validation (never merely a character pattern):
    #   broker  - a genuinely positive canonical Int64 decimal string
    #             (digits only, no leading zeros, within Int64 range);
    #   worker  - a canonical LOWERCASE GUID (case-sensitive).
    # Separators, dots, ADS syntax and stray characters can never reach the
    # filesystem.
    param([Parameter(Mandatory)][AllowEmptyString()][string]$OperationId)

    if ($OperationId -cmatch '^[0-9]+$') {
        $value = [long]0

        if ([long]::TryParse($OperationId, [ref]$value) -and $value -gt 0 -and $value.ToString() -ceq $OperationId) {
            return
        }

        throw "Refusing a protected capture operation id outside the strict grammar: '$OperationId'."
    }

    if ($OperationId -cmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
        return
    }

    throw "Refusing a protected capture operation id outside the strict grammar: '$OperationId'."
}

function Get-DevWSProtectedCapturesRoot {
    param([string]$TestBaseRoot)
    return (Join-Path (Get-DevWSPrivilegedStateRoot -TestBaseRoot $TestBaseRoot) "captures")
}

function Get-DevWSProtectedCaptureClaimPath {
    param(
        [Parameter(Mandatory)][string]$OperationId,
        [string]$TestBaseRoot
    )

    Assert-DevWSProtectedOperationId -OperationId $OperationId
    return (Join-Path (Get-DevWSProtectedCapturesRoot -TestBaseRoot $TestBaseRoot) $OperationId)
}

function Test-DevWSCapturePublicationIdentity {
    # Case-sensitive canonical lowercase GUID (uppercase or mixed-case values
    # are never accepted as publication identities).
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Publication)
    return ($Publication -cmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
}

function Assert-DevWSProtectedStateWritable {
    # Complete pre-write boundary gate for the protected publication root: the
    # FULL P2-A protected-root contract is revalidated through the single
    # authoritative validator - structural safety, the semantic owner/DACL
    # policy of EVERY component from the trusted anchor down (the DevWS
    # container, the privileged-state container and the SID root) and the
    # installed anchor Medium effective-access invariant. Any drift or missing
    # component fails closed before a single file is touched; nothing is ever
    # repaired, adopted or taken over, and this deliberately adds no second,
    # weaker policy.
    param([Parameter(Mandatory)][string]$Root)

    $validation = Test-DevWSPrivilegedStateRoot -Root $Root

    if (-not $validation.Ok) {
        throw ("The protected publication boundary rejected the write: " + (@($validation.Errors) -join ' '))
    }
}

function Assert-DevWSRuntimeStatePathAllowed {
    # Installed layouts accept only the protected runtime-cache path; the
    # repository layout keeps the historical state-root path (and its test
    # overrides). This closes Medium/env/-Path redirection of High writes.
    param([Parameter(Mandatory)][string]$Path)

    if ((Get-DevWSPathsLayout) -eq 'repository') {
        return
    }

    $protected = Get-DevWSProtectedRuntimeStatePath

    if (-not [string]::Equals([System.IO.Path]::GetFullPath($Path), [System.IO.Path]::GetFullPath($protected), [StringComparison]::OrdinalIgnoreCase)) {
        throw "The DevWS runtime cache cannot be redirected outside the protected state root in an installed layout; refusing '$Path'."
    }
}

function Get-DevWSProtectedPublicationScope {
    # The publication lifetime anchor: one owned, no-delete-shared, no-reparse
    # handle on the exact claim directory, held until Dispose. In addition to
    # the object type and reparse rejection, the claim directory's SEMANTIC
    # security (owner + the exact P2-A protected-state policy) is validated
    # from THAT SAME handle's descriptor - through the same policy
    # implementation as every other protected component, no second policy -
    # so the handle that made the security decision is exactly the handle the
    # caller keeps holding across artifact consumption. The claim cannot be
    # deleted, renamed or reclaimed while this scope is held.
    #
    # Ownership discipline: the handle is owned by this function until the
    # validation succeeds; EVERY unsuccessful exit - including an exception
    # thrown BY the semantic validation itself - disposes it in the finally
    # block, and every successful exit transfers the still-live scope to the
    # caller (which disposes it in its own finally).
    param([Parameter(Mandatory)][string]$ClaimPath)

    $inspection = Get-DevWSProtectedStateObjectInspection -Path $ClaimPath
    $transferred = $false

    try {
        if (-not $inspection.Ok) {
            throw "The protected capture claim could not be held open (Win32 $($inspection.Error)); refusing the operation."
        }

        if ($inspection.IsReparse) {
            throw "The protected capture claim path is a reparse point; refusing the operation."
        }

        if (-not $inspection.IsDirectory) {
            throw "The protected capture claim is not a directory; refusing the operation."
        }

        $security = $null

        try {
            $security = New-Object System.Security.AccessControl.DirectorySecurity
            $security.SetSecurityDescriptorSddlForm([string]$inspection.Sddl)
        }
        catch {
            $security = $null
        }

        if ($null -eq $security) {
            throw "The protected capture claim security descriptor could not be parsed; refusing the operation."
        }

        $ownerSid = $null

        try { $ownerSid = $security.GetOwner([System.Security.Principal.SecurityIdentifier]) } catch { $ownerSid = $null }

        if ($null -eq $ownerSid) {
            $ownerSid = Resolve-DevWSSecurityIdentifier -Identity ([string]$security.Owner)
        }

        if ($null -eq $ownerSid -or $ownerSid.Value -ne "S-1-5-32-544") {
            throw "The protected capture claim is not owned by BUILTIN\Administrators; refusing the operation."
        }

        $securityValidation = Test-DevWSPrivilegedStateSecurity -Security $security -Kind User

        if (-not $securityValidation.Ok) {
            throw ("The protected capture claim does not satisfy the protected-state policy: " + (@($securityValidation.Errors) -join ' '))
        }

        $transferred = $true
        return $inspection
    }
    finally {
        if (-not $transferred) {
            $inspection.Dispose()
        }
    }
}

function Set-DevWSProtectedPublicationIdentity {
    # Strict publication identity manifest, written atomically inside the
    # claim. High-generated; never caller-influenced.
    param(
        [Parameter(Mandatory)][string]$ClaimPath,
        [Parameter(Mandatory)][string]$Publication
    )

    if (-not (Test-DevWSCapturePublicationIdentity -Publication $Publication)) {
        throw "Refusing to stamp a malformed publication identity."
    }

    $manifestPath = Join-Path $ClaimPath "publication.identity.json"
    $payload = [ordered]@{ version = 1; publication = $Publication } | ConvertTo-Json -Compress
    $tempPath = "$manifestPath.tmp"

    try {
        [System.IO.File]::WriteAllText($tempPath, $payload, [System.Text.UTF8Encoding]::new($false))
        [System.IO.File]::Move($tempPath, $manifestPath, $true)
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) { Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue }
    }
}

function Get-DevWSProtectedPublicationIdentity {
    # Strict reader: missing, corrupt, malformed or non-version-1 identity
    # refuses with an actionable error. Every failure mode is fail closed.
    param([Parameter(Mandatory)][string]$ClaimPath)

    $manifestPath = Join-Path $ClaimPath "publication.identity.json"

    if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
        throw "The protected capture publication identity is missing; refusing the read."
    }

    try {
        $parsed = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        throw "The protected capture publication identity is corrupt; refusing the read."
    }

    if ($null -eq $parsed -or $parsed -isnot [System.Management.Automation.PSCustomObject]) {
        throw "The protected capture publication identity is malformed; refusing the read."
    }

    $isIntegerVersion = ($parsed.version -is [int]) -or ($parsed.version -is [long])

    if (-not $isIntegerVersion -or [long]$parsed.version -ne 1) {
        throw "The protected capture publication identity is malformed; refusing the read."
    }

    if ($parsed.publication -isnot [string] -or -not (Test-DevWSCapturePublicationIdentity -Publication ([string]$parsed.publication))) {
        throw "The protected capture publication identity is malformed; refusing the read."
    }

    return [string]$parsed.publication
}

function Get-DevWSCaptureClaimMutexName {
    # Cross-process claim-transition/retention mutex (interactive session
    # scope). Production name; tests pass their own -MutexName.
    return "Local\DevWS.CaptureClaim.v1"
}

function Get-DevWSCaptureClaimTimeoutSeconds {
    # Bounded: the critical sections are microsecond-scale (create + handle
    # acquisition, or a small retention scan); a stuck owner fails actionably.
    return 30
}

function Invoke-DevWSWithCaptureClaimLock {
    # Smallest safe cross-process coordination for the claim transition: while
    # ANY process is inside exclusive-create + lifetime-handle acquisition, no
    # retention may run; retention itself always runs under the same lock.
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [int]$TimeoutSeconds = (Get-DevWSCaptureClaimTimeoutSeconds),
        [string]$MutexName = (Get-DevWSCaptureClaimMutexName)
    )

    if ($TimeoutSeconds -lt 1) {
        throw "The capture claim lock timeout must be at least 1 second."
    }

    if ([string]::IsNullOrWhiteSpace($MutexName)) {
        throw "The capture claim lock mutex name must not be empty."
    }

    $mutex    = [System.Threading.Mutex]::new($false, $MutexName)
    $acquired = $false

    try {
        try {
            $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))
        }
        catch [System.Threading.AbandonedMutexException] {
            $acquired = $true
        }

        if (-not $acquired) {
            throw "Timed out after $TimeoutSeconds seconds waiting for another DevWS capture claim transition; no protected publication was created or removed."
        }

        return (& $ScriptBlock)
    }
    finally {
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Invoke-DevWSProtectedCaptureRetentionCore {
    # Bounded retention core (callers hold the claim lock): keep the newest
    # KeepRecent publications; expire anything older than RetentionMinutes.
    # The current claim is never touched. Every candidate is gated by the
    # delete-capable probe so a held publication is skipped completely - its
    # children are never deleted. Capacity exhaustion is reported for the
    # caller to fail closed on.
    param(
        [Parameter(Mandatory)][string]$CapturesRoot,
        [string]$CurrentOperationId = "",
        [int]$KeepRecent = 8,
        [int]$RetentionMinutes = 60,
        [int]$MaxPublications = 64
    )

    $removed = [System.Collections.Generic.List[string]]::new()
    $skipped = [System.Collections.Generic.List[string]]::new()

    if (Test-Path -LiteralPath $CapturesRoot -PathType Container) {
        Initialize-DevWSPrivilegeNativeRuntime

        $now = [DateTime]::UtcNow
        $dirs = @(Get-ChildItem -LiteralPath $CapturesRoot -Directory -Force -ErrorAction SilentlyContinue | Sort-Object CreationTimeUtc -Descending)
        $rank = 0

        foreach ($dir in $dirs) {
            $rank++

            if (-not [string]::IsNullOrWhiteSpace($CurrentOperationId) -and $dir.Name -ieq $CurrentOperationId) {
                continue
            }

            $ageMinutes = ($now - $dir.CreationTimeUtc).TotalMinutes

            if ($rank -gt $KeepRecent -or $ageMinutes -gt $RetentionMinutes) {
                # Unexpected reparse candidate: never follow it and never
                # recursively remove it; skip (reported) and leave it for a
                # human to remove deliberately.
                if ([bool]($dir.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                    $skipped.Add($dir.Name) | Out-Null
                    continue
                }

                $probe = [DevWSPrivilegeNative]::OpenClaimDeleteProbe($dir.FullName)

                if (-not $probe.IsOpen) {
                    $probe.Dispose()
                    $skipped.Add($dir.Name) | Out-Null
                    continue
                }

                try {
                    Remove-Item -LiteralPath $dir.FullName -Recurse -Force -ErrorAction Stop
                    $removed.Add($dir.Name) | Out-Null
                }
                catch {
                    $skipped.Add($dir.Name) | Out-Null
                }
                finally {
                    $probe.Dispose()
                }
            }
        }
    }

    $count = 0

    if (Test-Path -LiteralPath $CapturesRoot -PathType Container) {
        $count = @(Get-ChildItem -LiteralPath $CapturesRoot -Directory -Force -ErrorAction SilentlyContinue).Count
    }

    return [pscustomobject]@{
        Removed      = @($removed)
        Skipped      = @($skipped)
        Count        = $count
        OverCapacity = ($count -ge $MaxPublications)
    }
}

function Invoke-DevWSProtectedCaptureRetention {
    # Public wrapper: one bounded retention pass under the claim lock.
    param(
        [Parameter(Mandatory)][string]$CapturesRoot,
        [string]$CurrentOperationId = "",
        [int]$KeepRecent = 8,
        [int]$RetentionMinutes = 60,
        [int]$MaxPublications = 64,
        [int]$LockTimeoutSeconds = (Get-DevWSCaptureClaimTimeoutSeconds),
        [string]$MutexName = (Get-DevWSCaptureClaimMutexName)
    )

    return (Invoke-DevWSWithCaptureClaimLock -TimeoutSeconds $LockTimeoutSeconds -MutexName $MutexName -ScriptBlock {
        Invoke-DevWSProtectedCaptureRetentionCore `
            -CapturesRoot $CapturesRoot `
            -CurrentOperationId $CurrentOperationId `
            -KeepRecent $KeepRecent `
            -RetentionMinutes $RetentionMinutes `
            -MaxPublications $MaxPublications
    })
}

function New-DevWSProtectedCaptureClaim {
    # The authoritative claim: pre-write boundary validation, bounded
    # retention, capacity fail-closed, kernel-atomic exclusive creation, and
    # immediate lifetime-handle acquisition - all under the claim lock, so no
    # retention can delete the claim between creation and handle acquisition
    # (and a fresh claim is anyway never rank/age eligible). AlreadyExists is a
    # collision/replay refusal: never overwrite, never adopt, never reuse.
    param(
        [Parameter(Mandatory)][string]$OperationId,
        [string]$TestBaseRoot,
        [int]$MaxPublications = 64
    )

    Assert-DevWSProtectedOperationId -OperationId $OperationId

    $stateRoot = Get-DevWSPrivilegedStateRoot -TestBaseRoot $TestBaseRoot
    Assert-DevWSProtectedStateWritable -Root $stateRoot

    $capturesRoot = Join-Path $stateRoot "captures"

    if (-not (Test-Path -LiteralPath $capturesRoot -PathType Container)) {
        $security = New-DevWSPrivilegedStateDirectorySecurity -Kind User
        $sddl = $security.GetSecurityDescriptorSddlForm([System.Security.AccessControl.AccessControlSections]::Owner -bor [System.Security.AccessControl.AccessControlSections]::Access)
        $null = New-DevWSProtectedStateExclusiveDirectory -Path $capturesRoot -Sddl $sddl
    }

    # EVERY existing container - pre-existing, just created, or raced by a
    # competing creator - must satisfy the exact semantic owner/DACL policy
    # before its first use. An insecure container is refused, never repaired,
    # adopted, deleted or overwritten.
    $containerValidation = Test-DevWSProtectedStateComponent -Component $capturesRoot -Kind User

    if (-not $containerValidation.Ok) {
        throw ("The protected captures container refused the write: " + (@($containerValidation.Errors) -join ' '))
    }

    return (Invoke-DevWSWithCaptureClaimLock -ScriptBlock {
        $sweep = Invoke-DevWSProtectedCaptureRetentionCore `
            -CapturesRoot $capturesRoot `
            -CurrentOperationId $OperationId `
            -MaxPublications $MaxPublications

        if ($sweep.OverCapacity) {
            throw "The protected captures directory is at its bounded capacity ($($sweep.Count)/$MaxPublications); refusing a new claim."
        }

        $claimPath = Join-Path $capturesRoot $OperationId
        $security = New-DevWSPrivilegedStateDirectorySecurity -Kind User
        $sddl = $security.GetSecurityDescriptorSddlForm([System.Security.AccessControl.AccessControlSections]::Owner -bor [System.Security.AccessControl.AccessControlSections]::Access)
        $result = New-DevWSProtectedStateExclusiveDirectory -Path $claimPath -Sddl $sddl

        if ($result -eq 'AlreadyExists') {
            throw "The capture operation id '$OperationId' is already claimed by another publication; refusing to overwrite or adopt it."
        }

        # Immediate lifetime acquisition INSIDE the lock: the transition from
        # exclusive creation to a held no-delete-share handle cannot be
        # interleaved with retention.
        $scope = Get-DevWSProtectedPublicationScope -ClaimPath $claimPath

        return [pscustomobject]@{ ClaimPath = $claimPath; Scope = $scope }
    })
}


function Get-DevWSHelpersRoot {
    # Layout-local helpers root. Repository: <repo>\src\helpers. Installed
    # normal: <root>\helpers (medium-only helper copies). Installed
    # privileged: <privileged root>\helpers.
    if ((Test-DevWSPathsOverrideAllowed) -and -not [string]::IsNullOrWhiteSpace($env:DEVWS_HELPERS_ROOT)) {
        return $env:DEVWS_HELPERS_ROOT.Trim()
    }

    switch (Get-DevWSPathsLayout) {
        "repository" {
            return (Join-Path (Get-DevWSAppRoot) "helpers")
        }
        "installed-privileged" {
            return (Get-DevWSPrivilegedHelpersRoot)
        }
        default {
            return (Join-Path (Get-DevWSInstallRoot) "helpers")
        }
    }
}

function Get-DevWSWorkersRoot {
    # Layout-local workers root. Repository: <repo>\src\workers. Installed
    # normal: <root>\workers (legacy location; superseded by the privileged
    # root after the Public Security Phase 1 migration). Installed privileged:
    # <privileged root>\workers.
    if ((Test-DevWSPathsOverrideAllowed) -and -not [string]::IsNullOrWhiteSpace($env:DEVWS_WORKERS_ROOT)) {
        return $env:DEVWS_WORKERS_ROOT.Trim()
    }

    switch (Get-DevWSPathsLayout) {
        "repository" {
            return (Join-Path (Get-DevWSAppRoot) "workers")
        }
        "installed-privileged" {
            return (Get-DevWSPrivilegedWorkersRoot)
        }
        default {
            return (Join-Path (Get-DevWSInstallRoot) "workers")
        }
    }
}

function Get-DevWSWindowHelperPath {
    # The window-helper AHK script is executed at BOTH integrity levels
    # (Medium app focus + High terminal focus), so each layout uses its own
    # root: installed normal -> user helpers, installed privileged ->
    # privileged helpers, repository -> repository helpers.
    return (Join-Path (Get-DevWSHelpersRoot) "window-helper.ahk")
}

function Get-DevWSResetWindowHelperPath {
    # The reset/close helper is High-reachable only (reset closes managed
    # terminals); installed layouts always use the protected copy.
    if ((Get-DevWSPathsLayout) -in @("installed-normal", "installed-privileged")) {
        return (Join-Path (Get-DevWSPrivilegedHelpersRoot) "reset-window.ahk")
    }

    return (Join-Path (Get-DevWSHelpersRoot) "reset-window.ahk")
}

function Get-DevWSBinRoot {
    return (Join-Path (Get-DevWSInstallRoot) "bin")
}

function Get-DevWSBackupRoot {
    return (Join-Path (Get-DevWSStateRoot) "backups")
}

function Get-DevWSInstallMetadataPath {
    return (Join-Path (Get-DevWSStateRoot) "install-metadata.json")
}

function Get-DevWSStartupPath {
    if ((Test-DevWSPathsOverrideAllowed) -and -not [string]::IsNullOrWhiteSpace($env:DEVWS_STARTUP_PATH)) {
        return $env:DEVWS_STARTUP_PATH.Trim()
    }

    return (Join-Path ([Environment]::GetFolderPath('ApplicationData')) "Microsoft\Windows\Start Menu\Programs\Startup")
}

function Get-DevWSLegacyShimPath {
    return (Join-Path ([Environment]::GetFolderPath('UserProfile')) ".local\bin\ws.cmd")
}

function Get-DevWSCanonicalConfigPath {
    return (Join-Path ([Environment]::GetFolderPath('UserProfile')) ".config\devws\workspace.json")
}

function Get-DevWSInstalledAppScriptPath {
    return (Join-Path (Get-DevWSInstallRoot) "app\ws.ps1")
}

function Get-DevWSBindingsAhkPath {
    # Generated derived hotkey state; canonical config is the source of truth.
    return (Join-Path (Get-DevWSStateRoot) "hotkeys\bindings.ahk")
}

function Get-DevWSTrustedAutoHotkeyRoots {
    # Administrator-protected roots a machine-wide AutoHotkey installation may
    # live under. System32 is deliberately excluded: AutoHotkey is never a
    # system executable.
    $roots = [System.Collections.Generic.List[string]]::new()

    foreach ($base in @([Environment]::GetFolderPath('ProgramFiles'), [Environment]::GetFolderPath('ProgramFilesX86'))) {
        if (-not [string]::IsNullOrWhiteSpace($base)) {
            $roots.Add($base) | Out-Null
        }
    }

    return $roots.ToArray()
}

function Get-DevWSAutoHotkeyInstallRecord {
    # Read-only discovery of the official installer's recorded directory.
    #
    # Machine (HKLM, native 64-bit view) is the only trust authority. The
    # per-user record is read only to improve a failure message: an HKCU path is
    # never returned as executable authority.
    #
    # Returns { Scope; Present; InstallDir; Error }. `Present` means the
    # AutoHotkey key itself exists; a present record with an empty/malformed
    # InstallDir is an explicit broken installation, not a missing one.
    param(
        [Parameter(Mandatory)]
        [ValidateSet('Machine', 'User')]
        [string]$Scope
    )

    $hive = if ($Scope -eq 'Machine') {
        [Microsoft.Win32.RegistryHive]::LocalMachine
    }
    else {
        [Microsoft.Win32.RegistryHive]::CurrentUser
    }

    $base = $null

    try {
        $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey($hive, [Microsoft.Win32.RegistryView]::Registry64)
        $key = $base.OpenSubKey('Software\AutoHotkey', $false)

        if ($null -eq $key) {
            return [pscustomobject]@{ Scope = $Scope; Present = $false; InstallDir = ''; Error = '' }
        }

        try {
            $value = $key.GetValue('InstallDir', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)

            if ($null -eq $value) {
                return [pscustomobject]@{ Scope = $Scope; Present = $true; InstallDir = ''; Error = 'the record has no InstallDir value' }
            }

            if ($value -isnot [string]) {
                return [pscustomobject]@{ Scope = $Scope; Present = $true; InstallDir = ''; Error = 'the InstallDir value is not a string' }
            }

            return [pscustomobject]@{ Scope = $Scope; Present = $true; InstallDir = ([string]$value).Trim(); Error = '' }
        }
        finally {
            $key.Dispose()
        }
    }
    catch {
        return [pscustomobject]@{ Scope = $Scope; Present = $false; InstallDir = ''; Error = $_.Exception.Message }
    }
    finally {
        if ($null -ne $base) { $base.Dispose() }
    }
}

function Test-DevWSTrustedAutoHotkeyPath {
    # Pure candidate assessment for the installed runtime interpreter.
    #
    # Accepted: an existing absolute `AutoHotkey64.exe` beneath an
    # administrator-protected Program Files root whose file metadata reports
    # major version 2. Token/user identity is never consulted; the root is the
    # authority. No hash and no publisher check is performed (DevWS does not own
    # AutoHotkey's bytes and supported versions update independently).
    param(
        [AllowNull()][AllowEmptyString()][string]$Path,
        [string[]]$TrustedRoots = @(Get-DevWSTrustedAutoHotkeyRoots),
        [scriptblock]$GetVersionInfo = { param($CandidatePath) (Get-Item -LiteralPath $CandidatePath -ErrorAction Stop).VersionInfo }
    )

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return [pscustomobject]@{ Ok = $false; Reason = 'the AutoHotkey executable path is empty'; Path = '' }
    }

    if (-not [System.IO.Path]::IsPathRooted($Path)) {
        return [pscustomobject]@{ Ok = $false; Reason = "the AutoHotkey executable '$Path' is not an absolute path"; Path = $Path }
    }

    try {
        $full = [System.IO.Path]::GetFullPath($Path)
    }
    catch {
        return [pscustomobject]@{ Ok = $false; Reason = "the AutoHotkey executable path '$Path' could not be normalized"; Path = $Path }
    }

    if ((Split-Path -Leaf $full) -ine 'AutoHotkey64.exe') {
        return [pscustomobject]@{ Ok = $false; Reason = "the AutoHotkey executable '$full' must be named AutoHotkey64.exe"; Path = $full }
    }

    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        return [pscustomobject]@{ Ok = $false; Reason = "the AutoHotkey executable '$full' does not exist"; Path = $full }
    }

    $matchedRoot = ''

    foreach ($root in @($TrustedRoots)) {
        if (-not [string]::IsNullOrWhiteSpace($root) -and (Test-DevWSPathUnderRoot -Path $full -Root $root)) {
            $matchedRoot = $root
            break
        }
    }

    if ([string]::IsNullOrWhiteSpace($matchedRoot)) {
        return [pscustomobject]@{ Ok = $false; Reason = "the AutoHotkey executable '$full' is outside the administrator-protected Program Files roots"; Path = $full }
    }

    # Best-effort reparse rejection from the executable up to its trusted root.
    # This is attribute-based, not handle-based, so it cannot prove a
    # TOCTOU-free result; it only refuses the ordinary junction/symlink shapes.
    $current = $full

    while (-not [string]::IsNullOrWhiteSpace($current)) {
        $item = Get-Item -LiteralPath $current -Force -ErrorAction SilentlyContinue

        if ($null -ne $item -and (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
            return [pscustomobject]@{ Ok = $false; Reason = "the AutoHotkey executable '$full' is or is beneath a reparse point ('$current')"; Path = $full }
        }

        if ($current -ieq $matchedRoot) { break }

        $parent = Split-Path -Parent $current

        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $current) { break }

        $current = $parent
    }

    try {
        $versionInfo = & $GetVersionInfo $full
    }
    catch {
        return [pscustomobject]@{ Ok = $false; Reason = "the version metadata of '$full' could not be read"; Path = $full }
    }

    $major = 0

    try {
        $major = [Math]::Max([int]$versionInfo.FileMajorPart, [int]$versionInfo.ProductMajorPart)
    }
    catch {
        $major = 0
    }

    if ($major -ne 2) {
        return [pscustomobject]@{ Ok = $false; Reason = "the AutoHotkey executable '$full' is not AutoHotkey v2 (reported major version $major)"; Path = $full }
    }

    return [pscustomobject]@{ Ok = $true; Reason = ''; Path = $full }
}

function Resolve-DevWSTrustedAutoHotkeyPath {
    # Installed-layout AutoHotkey resolver.
    #
    # Discovery order:
    #   1. an explicit machine-wide (HKLM) installation record;
    #   2. otherwise the canonical all-users default derived from the Program
    #      Files known folder.
    #
    # An explicit machine-wide record is NEVER silently reinterpreted: a stale,
    # malformed or untrusted record fails with an actionable error instead of
    # falling back. HKCU is diagnostic input only and can never redirect the
    # result.
    param(
        $MachineRecord,
        $UserRecord,
        [string[]]$TrustedRoots = @(Get-DevWSTrustedAutoHotkeyRoots),
        [string]$ProgramFilesRoot = '',
        [scriptblock]$GetVersionInfo = { param($CandidatePath) (Get-Item -LiteralPath $CandidatePath -ErrorAction Stop).VersionInfo }
    )

    if ($null -eq $MachineRecord) {
        $MachineRecord = Get-DevWSAutoHotkeyInstallRecord -Scope Machine
    }

    if ($null -ne $MachineRecord -and -not [string]::IsNullOrWhiteSpace([string]$MachineRecord.Error)) {
        throw ("The machine-wide AutoHotkey registry record (HKLM\Software\AutoHotkey) could not be read: " + [string]$MachineRecord.Error + ". Repair the AutoHotkey for all users installation.")
    }

    if ($null -ne $MachineRecord -and [bool]$MachineRecord.Present) {
        $installDir = [string]$MachineRecord.InstallDir

        if ([string]::IsNullOrWhiteSpace($installDir)) {
            throw "The machine-wide AutoHotkey registry record (HKLM\Software\AutoHotkey) is malformed: it has no usable InstallDir value. Reinstall AutoHotkey v2 for all users under Program Files."
        }

        if ($installDir.IndexOf('%') -ge 0) {
            throw "The machine-wide AutoHotkey registry record (HKLM\Software\AutoHotkey) points at '$installDir'; environment-variable forms are not accepted. Reinstall AutoHotkey v2 for all users under Program Files."
        }

        if (-not [System.IO.Path]::IsPathRooted($installDir)) {
            throw "The machine-wide AutoHotkey registry record (HKLM\Software\AutoHotkey) points at '$installDir', which is not an absolute path. Reinstall AutoHotkey v2 for all users under Program Files."
        }

        $candidate = Join-Path $installDir 'v2\AutoHotkey64.exe'
        $assessment = Test-DevWSTrustedAutoHotkeyPath -Path $candidate -TrustedRoots $TrustedRoots -GetVersionInfo $GetVersionInfo

        if (-not $assessment.Ok) {
            throw ("The machine-wide AutoHotkey installation recorded at '$installDir' is not usable: " + $assessment.Reason + ". Reinstall AutoHotkey v2 for all users under an administrator-protected Program Files location, or repair the HKLM\Software\AutoHotkey record.")
        }

        return $assessment.Path
    }

    if ([string]::IsNullOrWhiteSpace($ProgramFilesRoot)) {
        $ProgramFilesRoot = [Environment]::GetFolderPath('ProgramFiles')
    }

    if ([string]::IsNullOrWhiteSpace($ProgramFilesRoot)) {
        throw "The Windows Program Files folder could not be resolved, so the machine-wide AutoHotkey installation cannot be located."
    }

    $fallback = Join-Path $ProgramFilesRoot 'AutoHotkey\v2\AutoHotkey64.exe'
    $assessment = Test-DevWSTrustedAutoHotkeyPath -Path $fallback -TrustedRoots $TrustedRoots -GetVersionInfo $GetVersionInfo

    if ($assessment.Ok) {
        return $assessment.Path
    }

    # Diagnostic only: a current-user installation is never authority.
    if ($null -eq $UserRecord) {
        $UserRecord = Get-DevWSAutoHotkeyInstallRecord -Scope User
    }

    $userHint = ''

    if ($null -ne $UserRecord -and [bool]$UserRecord.Present -and -not [string]::IsNullOrWhiteSpace([string]$UserRecord.InstallDir)) {
        $userDir = [string]$UserRecord.InstallDir
        $userCandidate = Join-Path $userDir 'v2\AutoHotkey64.exe'

        if (Test-Path -LiteralPath $userCandidate -PathType Leaf) {
            $userHint = " AutoHotkey v2 is installed only for the current user ('$userDir'). DevWS elevated window operations execute AutoHotkey from High-integrity workers, so installed DevWS requires an all-users AutoHotkey v2 installation under an administrator-protected Program Files location."
        }
    }

    throw ("No trusted machine-wide AutoHotkey v2 installation was found: " + $assessment.Reason + "." + $userHint + " Install AutoHotkey v2 for all users under an administrator-protected Program Files location.")
}

function Get-DevWSAutoHotkeyPath {
    # Canonical runtime entry point.
    #
    # The repository-only DEVWS_AHK_PATH override is honoured exactly where it
    # always was (development and hosted CI); installed layouts ignore it and
    # use the trusted machine-wide resolver, so a High-integrity worker can
    # never be redirected to a user-controlled executable.
    if ((Test-DevWSPathsOverrideAllowed) -and -not [string]::IsNullOrWhiteSpace($env:DEVWS_AHK_PATH)) {
        return $env:DEVWS_AHK_PATH.Trim()
    }

    return Resolve-DevWSTrustedAutoHotkeyPath
}

function Get-DevWSWindowsTerminalPath {
    # Installed layouts resolve the canonical per-user execution alias from the
    # registry-backed Local AppData known folder; the DEVWS_WT_PATH override is
    # honored only in the repository layout. The alias is an AppExecLink that
    # normal file I/O cannot replace (Public Pass B POC); it is the sanctioned
    # Windows Terminal entry point and is validated by health/doctor.
    if ((Test-DevWSPathsOverrideAllowed) -and -not [string]::IsNullOrWhiteSpace($env:DEVWS_WT_PATH)) {
        return $env:DEVWS_WT_PATH.Trim()
    }

    return (Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) "Microsoft\WindowsApps\wt.exe")
}

function Get-DevWSTrustedExecutableRoots {
    # Administrator-protected locations a privileged PowerShell executable may
    # live in: Program Files (includes the PowerShell package directory) and
    # %SystemRoot%\System32 only. Arbitrary descendants of %SystemRoot% are
    # deliberately NOT trusted.
    $roots = [System.Collections.Generic.List[string]]::new()
    $systemRoot = [Environment]::GetFolderPath('Windows')

    foreach ($base in @([Environment]::GetFolderPath('ProgramFiles'), [Environment]::GetFolderPath('ProgramFilesX86'))) {
        if (-not [string]::IsNullOrWhiteSpace($base)) {
            $roots.Add($base) | Out-Null
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($systemRoot)) {
        $roots.Add((Join-Path $systemRoot 'System32')) | Out-Null
    }

    return $roots.ToArray()
}

function Test-DevWSTrustedExecutablePath {
    # Central validation policy for executables that a privileged context may
    # launch: absolute, existing, named exactly `pwsh.exe`, under Program
    # Files / Program Files (x86) / %SystemRoot%\System32, and major version
    # >= 7. This is a policy floor, not an identity check; callers obtain the
    # candidate from a trusted source (the running PSHOME) and may additionally
    # request runtime verification (Resolve-DevWSTrustedPowerShellPath
    # -VerifyRuntime).
    param([AllowNull()][AllowEmptyString()][string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not [System.IO.Path]::IsPathRooted($Path)) {
        return $false
    }

    try {
        $full = [System.IO.Path]::GetFullPath($Path)
    }
    catch {
        return $false
    }

    if ((Split-Path -Leaf $full) -ine "pwsh.exe") {
        return $false
    }

    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        return $false
    }

    $underTrustedRoot = $false

    foreach ($root in @(Get-DevWSTrustedExecutableRoots)) {
        if (Test-DevWSPathUnderRoot -Path $full -Root $root) {
            $underTrustedRoot = $true
            break
        }
    }

    if (-not $underTrustedRoot) {
        return $false
    }

    try {
        $versionInfo = (Get-Item -LiteralPath $full -ErrorAction Stop).VersionInfo
        $major = [Math]::Max([int]$versionInfo.FileMajorPart, [int]$versionInfo.ProductMajorPart)
    }
    catch {
        return $false
    }

    return ($major -ge 7)
}

function Get-DevWSTrustedWindowsTerminalRoots {
    # Administrator-protected Windows-packaging locations a trusted Windows
    # Terminal launcher may live in.
    $roots = [System.Collections.Generic.List[string]]::new()

    foreach ($base in @([Environment]::GetFolderPath('ProgramFiles'), [Environment]::GetFolderPath('ProgramFilesX86'))) {
        if (-not [string]::IsNullOrWhiteSpace($base)) {
            $roots.Add((Join-Path $base 'WindowsApps')) | Out-Null
        }
    }

    return $roots.ToArray()
}

# ---------------------------------------------------------------------------
# Privileged external identity (Security Phase 1 final closure)
# ---------------------------------------------------------------------------
#
# Windows Terminal trust is bound to the OFFICIAL Microsoft package identity:
# a package name match alone is never identity, filesystem protection alone is
# never package identity, and package-cmdlet enumeration order is never
# trusted. The package query goes through the OS appmodel APIs exported by
# kernel32 - no PowerShell command discovery, no module autoload, no PATH, no
# alias/function indirection - so a user-defined package cmdlet (or a poisoned
# module path or PATH entry) cannot influence the trusted resolver.
$script:DevWSOfficialWindowsTerminalPackageName       = "Microsoft.WindowsTerminal"
$script:DevWSOfficialWindowsTerminalPackageFamilyName = "Microsoft.WindowsTerminal_8wekyb3d8bbwe"
$script:DevWSOfficialWindowsTerminalPublisherId       = "8wekyb3d8bbwe"
$script:DevWSOfficialWingetPackageFamilyName          = "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe"
$script:DevWSOfficialWingetPublisherId                = "8wekyb3d8bbwe"

function Initialize-DevWSPrivilegeNativeRuntime {
    # Privileged identity interop (Windows Terminal package query + process
    # token integrity) ships in the single shared native assembly
    # (src\native\devws-privilege-identity.cs, compiled into DevWS.Native.dll);
    # the shared loader owns layout, compilation and byte loading. Normal hosts
    # already load the loader library; a narrowly scoped host that only
    # dot-sourced devws-paths gets it dot-sourced from THIS file's own trusted
    # lib directory - an exact sibling file, never PATH or module discovery.
    if ($null -ne ([System.Management.Automation.PSTypeName]'DevWSPrivilegeNative').Type) {
        return
    }

    $nativeLoader = Join-Path $PSScriptRoot "devws-native.ps1"

    if (-not (Test-Path -LiteralPath $nativeLoader -PathType Leaf)) {
        throw "The DevWS native runtime loader is missing next to '$PSScriptRoot'; cannot perform privileged identity checks."
    }

    . $nativeLoader

    Initialize-DevWSNativeRuntime
}

function Get-DevWSPackageRecords {
    # Queries the registered instances of one package family for the current
    # user through the OS appmodel APIs. Every record exposes Name /
    # PackageFamilyName / PublisherId / Version / Architecture / PackageFullName
    # / InstallLocation; the family name is verified a second time through
    # PackageFamilyNameFromFullName, and the name/version/architecture/publisher
    # fields are parsed from the documented full-name format (machine data,
    # never localized display strings).
    param(
        [Parameter(Mandatory)][string]$PackageFamilyName,
        [Parameter(Mandatory)][string]$Label
    )

    Initialize-DevWSPrivilegeNativeRuntime

    $pfn = [string]$PackageFamilyName
    $records = [System.Collections.Generic.List[object]]::new()

    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $count = [uint32]0
        $bufferLength = [uint32]0

        $rc = [DevWSPrivilegeNative]::FindPackagesByPackageFamily(
            $pfn, [DevWSPrivilegeNative]::PackageFilterHead, [ref]$count, [IntPtr]::Zero, [ref]$bufferLength, [IntPtr]::Zero, [IntPtr]::Zero)

        if ($rc -eq 0 -and $count -eq 0) {
            return $records.ToArray()
        }

        if ($rc -ne 122) {
            throw "The registered $Label could not be queried (Win32 $rc): $([System.ComponentModel.Win32Exception]::new($rc).Message)"
        }

        $namesPtr = [System.Runtime.InteropServices.Marshal]::AllocHGlobal([int]$count * [IntPtr]::Size)
        $buffer = [System.Runtime.InteropServices.Marshal]::AllocHGlobal([int][Math]::Max(2, $bufferLength * 2))

        try {
            $rc2 = [DevWSPrivilegeNative]::FindPackagesByPackageFamily(
                $pfn, [DevWSPrivilegeNative]::PackageFilterHead, [ref]$count, $namesPtr, [ref]$bufferLength, $buffer, [IntPtr]::Zero)

            if ($rc2 -eq 122 -and $attempt -lt 2) {
                continue
            }

            if ($rc2 -ne 0) {
                throw "The registered $Label changed while it was being enumerated (Win32 $rc2); refusing to continue."
            }

            for ($index = 0; $index -lt $count; $index++) {
                $stringPtr = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($namesPtr, $index * [IntPtr]::Size)
                $fullName = [System.Runtime.InteropServices.Marshal]::PtrToStringUni($stringPtr)

                $name = $null
                $version = $null
                $architecture = $null
                $publisherId = $null

                if (-not [string]::IsNullOrWhiteSpace($fullName) -and
                    $fullName -match '^(?<name>.+)_(?<version>\d+(?:\.\d+)*)_(?<arch>[^_]+)__(?<publisher>[^_]+)$') {
                    $name = $Matches['name']
                    $version = $Matches['version']
                    $architecture = $Matches['arch']
                    $publisherId = $Matches['publisher']
                }

                $verifiedFamily = $null

                if (-not [string]::IsNullOrWhiteSpace($fullName)) {
                    try {
                        $familyLength = [uint32]0
                        [void][DevWSPrivilegeNative]::PackageFamilyNameFromFullName($fullName, [ref]$familyLength, $null)
                        $familyBuilder = [System.Text.StringBuilder]::new([int]$familyLength)
                        $familyRc = [DevWSPrivilegeNative]::PackageFamilyNameFromFullName($fullName, [ref]$familyLength, $familyBuilder)

                        if ($familyRc -eq 0) {
                            $verifiedFamily = $familyBuilder.ToString()
                        }
                    }
                    catch {
                        $verifiedFamily = $null
                    }
                }

                $installLocation = $null

                if (-not [string]::IsNullOrWhiteSpace($fullName)) {
                    try {
                        $pathLength = [uint32]0
                        [void][DevWSPrivilegeNative]::GetPackagePathByFullName($fullName, [ref]$pathLength, $null)
                        $pathBuilder = [System.Text.StringBuilder]::new([int]$pathLength)
                        $pathRc = [DevWSPrivilegeNative]::GetPackagePathByFullName($fullName, [ref]$pathLength, $pathBuilder)

                        if ($pathRc -eq 0) {
                            $installLocation = $pathBuilder.ToString()
                        }
                    }
                    catch {
                        $installLocation = $null
                    }
                }

                $records.Add([pscustomobject]@{
                    Name              = $name
                    PackageFamilyName = $verifiedFamily
                    PublisherId       = $publisherId
                    Version           = $version
                    Architecture      = $architecture
                    PackageFullName   = $fullName
                    InstallLocation   = $installLocation
                }) | Out-Null
            }

            return $records.ToArray()
        }
        finally {
            [System.Runtime.InteropServices.Marshal]::FreeHGlobal($namesPtr)
            [System.Runtime.InteropServices.Marshal]::FreeHGlobal($buffer)
        }
    }

    return $records.ToArray()
}

function Get-DevWSWindowsTerminalPackageRecords {
    # Windows Terminal-specific wrapper over the generic appmodel package query.
    return (Get-DevWSPackageRecords -PackageFamilyName $script:DevWSOfficialWindowsTerminalPackageFamilyName -Label "Windows Terminal package family")
}

function Get-DevWSWingetPackageRecords {
    # App Installer / Windows Package Manager-specific wrapper.
    return (Get-DevWSPackageRecords -PackageFamilyName $script:DevWSOfficialWingetPackageFamilyName -Label "Windows Package Manager (App Installer) package family")
}

function Select-DevWSTrustedWindowsTerminalPackage {
    # Pure package-selection policy. Input: package-like records (Name,
    # PackageFamilyName, PublisherId, InstallLocation). Output:
    #   { Ok; ReasonCode; Reason; Package }.
    #
    # Identity requires ALL of: exact official name, exact official package
    # family, exact official publisher id, and a non-empty ABSOLUTE
    # InstallLocation. Enumeration order is never trusted (no
    # Select-Object -First 1); duplicates of the same registered identity are
    # normalized, and more than one distinct identity is a hard ambiguity
    # failure.
    param(
        [AllowNull()]
        [AllowEmptyCollection()]
        [object[]]$Packages
    )

    $list = @()
    if ($null -ne $Packages) { $list = @($Packages) }

    $makeResult = {
        param($ok, $code, $reason, $package)
        [pscustomobject]@{
            Ok         = [bool]$ok
            ReasonCode = [string]$code
            Reason     = [string]$reason
            Package    = $package
        }
    }

    if ($list.Count -eq 0) {
        return (& $makeResult $false "not-registered" "No registered package was found for the official Windows Terminal package family '$($script:DevWSOfficialWindowsTerminalPackageFamilyName)'." $null)
    }

    $official = [System.Collections.Generic.List[object]]::new()
    $failureCodes = [System.Collections.Generic.List[string]]::new()
    $failureReasons = [System.Collections.Generic.List[string]]::new()

    foreach ($record in $list) {
        if ($null -eq $record) {
            $failureCodes.Add("malformed-record") | Out-Null
            $failureReasons.Add("a null package record was returned") | Out-Null
            continue
        }

        $field = {
            param($object, $name)
            foreach ($property in @($object.PSObject.Properties)) {
                if ($property.Name -ieq $name) { return $property.Value }
            }
            return $null
        }

        $name = & $field $record "Name"
        $family = & $field $record "PackageFamilyName"
        $publisher = & $field $record "PublisherId"
        $location = & $field $record "InstallLocation"

        if ([string]::IsNullOrWhiteSpace([string]$name)) {
            $failureCodes.Add("malformed-record") | Out-Null
            $failureReasons.Add("a package record is missing required identity fields") | Out-Null
            continue
        }

        if ([string]$name -ine [string]$script:DevWSOfficialWindowsTerminalPackageName) {
            $failureCodes.Add("name-mismatch") | Out-Null
            $failureReasons.Add("a package named '$name' is not the official Windows Terminal package") | Out-Null
            continue
        }

        if ([string]::IsNullOrWhiteSpace([string]$family) -or
            [string]$family -ine [string]$script:DevWSOfficialWindowsTerminalPackageFamilyName) {
            $failureCodes.Add("family-mismatch") | Out-Null
            $failureReasons.Add("a package named '$name' is registered with family '$(if ([string]::IsNullOrWhiteSpace([string]$family)) { '<missing>' } else { $family })' instead of the official family '$($script:DevWSOfficialWindowsTerminalPackageFamilyName)'") | Out-Null
            continue
        }

        if ([string]$publisher -ine [string]$script:DevWSOfficialWindowsTerminalPublisherId) {
            $failureCodes.Add("publisher-mismatch") | Out-Null
            $failureReasons.Add("the official family reported publisher id '$publisher' instead of '$($script:DevWSOfficialWindowsTerminalPublisherId)'") | Out-Null
            continue
        }

        $normalizedLocation = $null

        try {
            $normalizedLocation = [System.IO.Path]::GetFullPath([string]$location)
        }
        catch {
            $normalizedLocation = $null
        }

        if ([string]::IsNullOrWhiteSpace([string]$location) -or
            $null -eq $normalizedLocation -or
            -not [System.IO.Path]::IsPathRooted([string]$location)) {
            $failureCodes.Add("invalid-install-location") | Out-Null
            $failureReasons.Add("the official package record has a missing or non-absolute InstallLocation") | Out-Null
            continue
        }

        $official.Add($record) | Out-Null
    }

    if ($official.Count -eq 0) {
        $code = "not-registered"

        foreach ($candidateCode in @("malformed-record", "family-mismatch", "publisher-mismatch", "name-mismatch", "invalid-install-location")) {
            if ($failureCodes.Contains($candidateCode)) {
                $code = $candidateCode
                break
            }
        }

        return (& $makeResult $false $code ("No trusted Windows Terminal package was found: " + ($failureReasons -join "; ") + ".") $null)
    }

    # Normalize duplicate representations of the same registered identity:
    # one distinct (InstallLocation, Version, Architecture) must remain.
    $byIdentity = [ordered]@{}

    foreach ($record in $official) {
        $key = (([System.IO.Path]::GetFullPath([string]$record.InstallLocation)).TrimEnd('\').ToLowerInvariant() + "|" + ([string]$record.Version).ToLowerInvariant() + "|" + ([string]$record.Architecture).ToLowerInvariant())

        if (-not $byIdentity.Contains($key)) {
            $byIdentity[$key] = $record
        }
    }

    if ($byIdentity.Count -gt 1) {
        $locations = @($byIdentity.Values | ForEach-Object { [string]$_.InstallLocation } | Sort-Object -Unique)
        return (& $makeResult $false "ambiguous" ("Multiple distinct official Windows Terminal package registrations were found (" + ($locations -join ", ") + "); refusing to choose an enumeration order.") $null)
    }

    $selectedKeys = @($byIdentity.Keys | Sort-Object)
    $selected = $byIdentity[[string]$selectedKeys[0]]

    return (& $makeResult $true "ok" "The official Windows Terminal package registration was selected." $selected)
}

function Test-DevWSTrustedWindowsTerminalCandidate {
    # Pure policy for a trusted Windows Terminal launcher: exactly
    # `WindowsTerminal.exe`, under an administrator-protected WindowsApps
    # root, existing as a normal file, with NO reparse point anywhere on the
    # path from the trusted root down to the candidate (a junction or symlink
    # substitute is rejected even when the final file itself is ordinary).
    param(
        [AllowNull()][AllowEmptyString()][string]$Path,
        [AllowNull()][AllowEmptyCollection()][string[]]$TrustedRoots,
        [string]$Leaf = 'WindowsTerminal.exe'
    )

    if ([string]::IsNullOrWhiteSpace($Path) -or -not [System.IO.Path]::IsPathRooted($Path)) {
        return $false
    }

    try {
        $full = [System.IO.Path]::GetFullPath($Path)
    }
    catch {
        return $false
    }

    if ((Split-Path -Leaf $full) -ine $Leaf) {
        return $false
    }

    $roots = @($TrustedRoots | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    if ($roots.Count -eq 0) {
        return $false
    }

    $matchedRoot = $null

    foreach ($root in $roots) {
        if (Test-DevWSPathUnderRoot -Path $full -Root $root) {
            $matchedRoot = [System.IO.Path]::GetFullPath($root).TrimEnd('\')
            break
        }
    }

    if ($null -eq $matchedRoot) {
        return $false
    }

    # Walk every component from the trusted root down to the candidate and
    # reject reparse points (junctions, symlinks, AppExecLink substitutes).
    $relative = $full.Substring($matchedRoot.Length).TrimStart('\')
    $cursor = $matchedRoot

    foreach ($segment in @($relative -split '\\')) {
        if ([string]::IsNullOrWhiteSpace($segment)) {
            continue
        }

        $cursor = Join-Path $cursor $segment
        $item = Get-Item -LiteralPath $cursor -Force -ErrorAction SilentlyContinue

        if ($null -eq $item) {
            return $false
        }

        if ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
            return $false
        }
    }

    return $true
}

function Resolve-DevWSTrustedWindowsTerminalPath {
    # Single authoritative Windows Terminal resolver for installed execution.
    #
    # The installer-time and High-launch identity contract is:
    #   official package identity  (Name + PackageFamilyName + PublisherId)
    #   + the registered InstallLocation
    #   + an administrator-protected WindowsApps root
    #   + a non-reparse WindowsTerminal.exe path.
    #
    # Step 1 (package identity) chooses the directory through the OS appmodel
    # APIs - never command discovery, never enumeration order. Step 2
    # (filesystem validation) proves that the SELECTED directory/candidate is
    # protected and structurally safe; there is no independent search for some
    # matching executable.
    #
    # Race model: once the official package identity and the protected
    # non-reparse candidate are established, a Medium attacker cannot modify or
    # replace files under the selected WindowsApps package root, so the
    # remaining validate-to-Process.Start interval is safe under the Phase-1
    # threat model (administrators/SYSTEM are trusted).
    #
    # Repository execution keeps the explicit stub injection (DEVWS_WT_PATH)
    # for tests; -Installed forces the installed-mode resolution (used by
    # installer prerequisites).
    param([switch]$Installed)

    if (-not $Installed -and (Get-DevWSPathsLayout) -eq "repository") {
        return (Get-DevWSWindowsTerminalPath)
    }

    try {
        $records = @(Get-DevWSWindowsTerminalPackageRecords)
    }
    catch {
        throw "The registered Windows Terminal package could not be queried without command discovery (native appmodel query failed): $($_.Exception.Message) Refusing to launch an unverified terminal host."
    }

    $selection = Select-DevWSTrustedWindowsTerminalPackage -Packages $records

    if (-not $selection.Ok) {
        switch ([string]$selection.ReasonCode) {
            "not-registered" {
                throw "Windows Terminal is not registered for this user for the official package family '$($script:DevWSOfficialWindowsTerminalPackageFamilyName)'. Install Windows Terminal (Microsoft Store) or run install.ps1; refusing to launch an unverified terminal host."
            }
            "family-mismatch" {
                throw "A package named '$($script:DevWSOfficialWindowsTerminalPackageName)' is registered without the official Microsoft package family '$($script:DevWSOfficialWindowsTerminalPackageFamilyName)' (publisher id '$($script:DevWSOfficialWindowsTerminalPublisherId)'); refusing to launch an unverified terminal host. $($selection.Reason)"
            }
            "publisher-mismatch" {
                throw "The official Windows Terminal package family reported a non-official publisher identity; refusing to launch an unverified terminal host. $($selection.Reason)"
            }
            "invalid-install-location" {
                throw "The registered official Windows Terminal package has a missing or malformed InstallLocation; refusing to launch an unverified terminal host. Run install.ps1 after repairing the Windows Terminal installation."
            }
            "ambiguous" {
                throw "$($selection.Reason)"
            }
            default {
                throw "The registered Windows Terminal package registration could not be validated; refusing to launch an unverified terminal host. $($selection.Reason)"
            }
        }
    }

    $package = $selection.Package
    $installLocation = [System.IO.Path]::GetFullPath([string]$package.InstallLocation)
    $candidate = Join-Path $installLocation "WindowsTerminal.exe"
    $roots = @(Get-DevWSTrustedWindowsTerminalRoots)

    $locationUnderTrustedRoot = $false

    foreach ($root in $roots) {
        if (Test-DevWSPathUnderRoot -Path $installLocation -Root $root) {
            $locationUnderTrustedRoot = $true
            break
        }
    }

    if (-not $locationUnderTrustedRoot) {
        throw "The registered Windows Terminal package install location '$installLocation' is not under an administrator-protected WindowsApps root; refusing to launch an unverified terminal host."
    }

    if (-not (Test-DevWSTrustedWindowsTerminalCandidate -Path $candidate -TrustedRoots $roots)) {
        throw "The registered Windows Terminal package executable '$candidate' failed the protected-path policy (missing file, wrong executable name, or a reparse-point component); refusing to launch an unverified terminal host."
    }

    return $candidate
}

function Resolve-DevWSTrustedWingetPath {
    # Resolves the Windows Package Manager executable from the registered
    # official App Installer package. The executable is never discovered
    # through PATH, a user app-execution alias, or module autoload. The package
    # family and publisher are verified by the appmodel query; the selected
    # package directory must be under an administrator-protected WindowsApps
    # root; and winget.exe must be an ordinary non-reparse file.
    #
    # Returns the absolute winget.exe path or throws an actionable error.
    $records = @(Get-DevWSWingetPackageRecords)
    $roots = @(Get-DevWSTrustedWindowsTerminalRoots)
    $candidates = [System.Collections.Generic.List[object]]::new()

    foreach ($record in $records) {
        if ($null -eq $record) { continue }
        if ([string]$record.Name -ne 'Microsoft.DesktopAppInstaller') { continue }
        if ([string]$record.PackageFamilyName -ne $script:DevWSOfficialWingetPackageFamilyName) { continue }
        if ([string]$record.PublisherId -ne $script:DevWSOfficialWingetPublisherId) { continue }
        if ([string]$record.Architecture -ine 'x64') { continue }
        if ([string]::IsNullOrWhiteSpace([string]$record.InstallLocation)) { continue }

        $version = $null
        if (-not [version]::TryParse([string]$record.Version, [ref]$version)) { continue }

        $candidate = Join-Path ([string]$record.InstallLocation) 'winget.exe'

        if (-not (Test-DevWSTrustedWindowsTerminalCandidate -Path $candidate -TrustedRoots $roots -Leaf 'winget.exe')) {
            continue
        }

        $candidates.Add([pscustomobject]@{
            Path    = [System.IO.Path]::GetFullPath($candidate)
            Version = $version
        }) | Out-Null
    }

    if ($candidates.Count -eq 0) {
        throw ("WinGet (Microsoft App Installer) is not available for this user, or its winget.exe failed the protected WindowsApps path checks. " +
            "Install or update App Installer from the Microsoft Store, or install AutoHotkey v2 for all users manually.")
    }

    $selected = @($candidates | Sort-Object -Property @{ Expression = { $_.Version }; Descending = $true }, @{ Expression = { $_.Path }; Descending = $false })[0]
    return [string]$selected.Path
}

function Resolve-DevWSTrustedPowerShellPath {
    # Single owner of the trusted-PowerShell resolution policy. The default
    # candidate is the running PowerShell installation ($PSHOME), which for an
    # installed High worker is the administrator-protected package directory it
    # was started from. -VerifyRuntime additionally executes the candidate once
    # (installer-time validation) and requires it to report major >= 7 through
    # $PSVersionTable.
    param(
        [string]$CandidatePath,
        [switch]$VerifyRuntime
    )

    if ([string]::IsNullOrWhiteSpace($CandidatePath)) {
        $CandidatePath = Join-Path $PSHOME "pwsh.exe"
    }

    if (-not (Test-DevWSTrustedExecutablePath -Path $CandidatePath)) {
        throw "The PowerShell executable '$CandidatePath' is not a trusted privileged-execution candidate: it must be an absolute existing pwsh.exe under Program Files or System32 with major version 7 or newer. Run install.ps1."
    }

    $full = [System.IO.Path]::GetFullPath($CandidatePath)

    if ($VerifyRuntime) {
        $output = & $full -NoLogo -NoProfile -NonInteractive -Command '[string]$PSVersionTable.PSVersion.Major' 2>&1
        $exitCode = $LASTEXITCODE
        $reported = ([string]($output | Out-String)).Trim()

        if ($exitCode -ne 0 -or $reported -notmatch '^\d+$' -or [int]$reported -lt 7) {
            throw "The PowerShell executable '$full' failed runtime verification (exit $exitCode, reported '$reported'); expected a working PowerShell 7+ installation. Run install.ps1 from a PowerShell 7 shell."
        }
    }

    return $full
}

function Get-DevWSProcessIntegrityLevel {
    # Current-process token integrity label, read DIRECTLY from the process
    # token through the native layer (TokenIntegrityLevel -> SID). No external
    # identity tool or other executable is involved, and there is no PATH,
    # module or command discovery: the helper is safe to call from a High
    # security context. Host-integrity expectations: normal CLI/coordinator =>
    # Medium, broker/workers => High. An unreadable label resolves to Unknown,
    # never a guessed level.
    $sid = $null
    $name = 'Unknown'

    try {
        Initialize-DevWSPrivilegeNativeRuntime

        $token = [IntPtr]::Zero

        if ([DevWSPrivilegeNative]::OpenProcessToken([DevWSPrivilegeNative]::GetCurrentProcess(), [uint32]0x0008, [ref]$token)) {
            try {
                $needed = 0
                [void][DevWSPrivilegeNative]::GetTokenInformation($token, 25, [IntPtr]::Zero, 0, [ref]$needed)
                $buffer = [System.Runtime.InteropServices.Marshal]::AllocHGlobal($needed)

                try {
                    if ([DevWSPrivilegeNative]::GetTokenInformation($token, 25, $buffer, $needed, [ref]$needed)) {
                        $sidPtr = [System.Runtime.InteropServices.Marshal]::ReadIntPtr($buffer)
                        $stringPtr = [IntPtr]::Zero

                        if ([DevWSPrivilegeNative]::ConvertSidToStringSid($sidPtr, [ref]$stringPtr)) {
                            try {
                                $sid = [System.Runtime.InteropServices.Marshal]::PtrToStringUni($stringPtr)
                            }
                            finally {
                                [void][DevWSPrivilegeNative]::LocalFree($stringPtr)
                            }
                        }
                    }
                }
                finally {
                    [System.Runtime.InteropServices.Marshal]::FreeHGlobal($buffer)
                }
            }
            finally {
                [void][DevWSPrivilegeNative]::CloseHandle($token)
            }
        }
    }
    catch {
        $sid = $null
    }

    $name = switch ($sid) {
        'S-1-16-4096'  { 'Low'; break }
        'S-1-16-8192'  { 'Medium'; break }
        'S-1-16-12288' { 'High'; break }
        'S-1-16-16384' { 'System'; break }
        'S-1-16-2048'  { 'Untrusted'; break }
        default        { 'Unknown' }
    }

    return [pscustomobject]@{
        Sid      = $sid
        Name     = $name
        IsHigh   = ($sid -eq 'S-1-16-12288')
        IsMedium = ($sid -eq 'S-1-16-8192')
    }
}

function Get-DevWSTrustedSystemExecutable {
    # Central rule for Windows system executables that privileged code may
    # launch: an exact file name (never a path), resolved under the OS-known
    # %SystemRoot%\System32 folder. Never PATH, never the process environment.
    param(
        [Parameter(Mandatory)]
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name) -or $Name -match '[\\/:]' -or $Name -ne (Split-Path -Leaf $Name)) {
        throw "A trusted system executable must be a plain file name (got '$Name')."
    }

    $systemRoot = [Environment]::GetFolderPath('Windows')

    if ([string]::IsNullOrWhiteSpace($systemRoot)) {
        throw "The Windows folder could not be resolved; cannot locate the trusted system executable '$Name'."
    }

    $full = Join-Path (Join-Path $systemRoot "System32") $Name

    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) {
        throw "The trusted system executable '$full' was not found; refusing to resolve it through PATH."
    }

    return $full
}

function Write-DevWSLaunchTrace {
    # Opt-in benchmark/diagnostic trace (DEVWS_LAUNCH_TRACE = file path).
    # Disabled in normal runs: one environment lookup per call, no output.
    # Public Security Phase 2-E: the override is honored only through the
    # Medium-authority gate - repository fixtures and installed Medium keep
    # the diagnostic trace, while an installed High process never writes an
    # attacker-steerable destination (no new protected trace file; the trace
    # stays optional and best-effort, and can never fail an operation).
    param(
        [Parameter(Mandatory)]
        [string]$Event,
        [System.Collections.IDictionary]$Data
    )

    $path = $env:DEVWS_LAUNCH_TRACE

    if ([string]::IsNullOrWhiteSpace($path)) {
        return
    }

    if (-not (Test-DevWSInstalledOverrideContext)) {
        return
    }

    try {
        $record = [ordered]@{
            event = $Event
            utcMs = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()
            pid   = $PID
        }

        if ($null -ne $Data) {
            foreach ($key in @($Data.Keys)) {
                $record[[string]$key] = $Data[$key]
            }
        }

        (($record | ConvertTo-Json -Compress -Depth 4) + [Environment]::NewLine) |
            Add-Content -LiteralPath $path -Encoding UTF8 -ErrorAction SilentlyContinue
    }
    catch {
        # Tracing is best-effort and never affects launch semantics.
    }
}
