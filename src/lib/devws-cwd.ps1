# DevWS Phase 9/Pass 6B terminal cwd tracking state.
#
# Public Security Phase 2-C: the AUTHORITATIVE expected generations and shell
# publications live in the administrator-protected per-user ProgramData tree
# (`<SID root>\cwd\sessions\...` / `<SID root>\cwd\publications\...`) in every
# installed layout. The legacy user-owned state paths below are retained ONLY
# for repository fixtures and are never imported, promoted or used as fallback
# by installed code (Policy A cutover). Path construction, the logical-ID key
# mapping and the path budget live in the dependency-free leaf
# `devws-cwd-paths.ps1`; this library owns the ownership/authorization
# orchestration on top of the existing P2-A protected-state primitives.
#
# Historical legacy layout (repository fixtures only):
#
#   state\cwd-sessions\<setId>\<terminalId>.json        (tab 0, historical)
#   state\cwd-sessions\<setId>\<terminalId>\<tabIndex>.json  (tabs 1+)
#       Controller-owned expected session/generation record. Only DevWS
#       controller/worker logic writes it. The managed shell never sees or
#       writes this path.
#
#   state\cwd\<setId>\<terminalId>.json                 (tab 0, historical)
#   state\cwd\<setId>\<terminalId>\<tabIndex>.json      (tabs 1+)
#       Shell-owned cwd publication. Only the managed tracked tab shell writes
#       it (through the staged cwd-shell-bootstrap.ps1 helper).
#
# Tab 0 permanently keeps the historical terminal-level path SHAPE so current
# builds keep operating on the same authoritative tab-0 pair semantics; tabs
# 1+ are additive disposable state.
#
# A publication is accepted only when it matches the expected generation
# exactly (set, terminal, window, session, and - for indexed tabs - the
# configured tab index), the cwd is a real absolute directory, and the recorded
# publisher process is still alive with the same process start time. Anything
# uncertain resolves to unavailable; the resolver never guesses and never falls
# back to configured/caller/process cwd.
#
# The expected record may also carry a startupSpecSha256 identity: the SHA-256
# of the exact UTF-8 child-spec JSON for the configured startup command. That
# fingerprint is controller-owned; `ws save` startup-intent retirement compares
# it against the CURRENT configured command+args. It is NOT required for cwd
# availability.
#
# This library is tracking state only: it never writes canonical config. `ws
# save` consumes the resolved tracked cwd through these helpers.
#
# Required libraries (dot-source first): devws-paths.ps1, devws-cwd-paths.ps1.

function Get-DevWSCwdBootstrapPath {
    # Static staged shell bootstrap helper (never generated at runtime). It is
    # executed inside the HIGH tracked shell, so installed layouts always
    # resolve the administrator-protected privileged copy; only repository
    # execution uses the repository helper.
    if ((Get-DevWSPathsLayout) -in @("installed-normal", "installed-privileged")) {
        return (Join-Path (Get-DevWSPrivilegedHelpersRoot) "cwd-shell-bootstrap.ps1")
    }

    return (Join-Path (Get-DevWSHelpersRoot) "cwd-shell-bootstrap.ps1")
}

function Get-DevWSCwdStorageMode {
    # 'protected' for every installed layout and for repository fixtures that
    # explicitly request protected authority; 'legacy' only for the repository
    # default (fixture compatibility). Installed layouts never accept a
    # caller-supplied fixture base: devws-paths.ps1 refuses -TestBaseRoot
    # outside the repository layout. The P2-A/B repository-only
    # DEVWS_PROTECTED_STATE_ROOT seam deliberately does NOT steer cwd
    # authority; protected cwd fixtures must pass -TestBaseRoot explicitly.
    param([string]$TestBaseRoot)

    if (-not [string]::IsNullOrWhiteSpace($TestBaseRoot)) {
        if ((Get-DevWSPathsLayout) -ne "repository") {
            throw "The protected cwd state root cannot be redirected outside the repository layout; refusing to use '$TestBaseRoot'."
        }

        return "protected"
    }

    if ((Get-DevWSPathsLayout) -ne "repository") { return "protected" }

    return "legacy"
}

function Resolve-DevWSCwdProtectedSidRoot {
    # Installed: the authoritative ProgramData + current-SID chain. Repository:
    # the explicit fixture base or the repository-only seam. Nothing else can
    # redirect this resolution.
    param([string]$TestBaseRoot)

    return (Get-DevWSPrivilegedStateRoot -TestBaseRoot $TestBaseRoot)
}

function Get-DevWSCwdSessionRoot {
    param([string]$TestBaseRoot)

    if ((Get-DevWSCwdStorageMode -TestBaseRoot $TestBaseRoot) -eq "protected") {
        $sidRoot = Resolve-DevWSCwdProtectedSidRoot -TestBaseRoot $TestBaseRoot
        return (Join-Path (Join-Path $sidRoot "cwd") "sessions")
    }

    return (Join-Path (Get-DevWSStateRoot) "cwd-sessions")
}

function Get-DevWSCwdPublicationRoot {
    param([string]$TestBaseRoot)

    if ((Get-DevWSCwdStorageMode -TestBaseRoot $TestBaseRoot) -eq "protected") {
        $sidRoot = Resolve-DevWSCwdProtectedSidRoot -TestBaseRoot $TestBaseRoot
        return (Join-Path (Join-Path $sidRoot "cwd") "publications")
    }

    return (Join-Path (Get-DevWSStateRoot) "cwd")
}

function Get-DevWSCwdSessionPath {
    param(
        [Parameter(Mandatory)]
        [string]$SetId,
        [Parameter(Mandatory)]
        [string]$TerminalId,
        [int]$TabIndex = 0,
        [string]$TestBaseRoot
    )

    if ($TabIndex -lt 0) {
        throw "A configured tab index cannot be negative (got $TabIndex)."
    }

    if ((Get-DevWSCwdStorageMode -TestBaseRoot $TestBaseRoot) -eq "protected") {
        $sidRoot = Resolve-DevWSCwdProtectedSidRoot -TestBaseRoot $TestBaseRoot
        return (Get-DevWSCwdProtectedPath -SidRoot $sidRoot -Kind "sessions" -SetId $SetId -TerminalId $TerminalId -TabIndex $TabIndex)
    }

    $setRoot = Join-Path (Get-DevWSCwdSessionRoot) $SetId

    if ($TabIndex -eq 0) {
        # Tab 0 permanently keeps the historical Phase-9 terminal-level path.
        return (Join-Path $setRoot ($TerminalId + ".json"))
    }

    return (Join-Path (Join-Path $setRoot $TerminalId) ($TabIndex.ToString() + ".json"))
}

function Get-DevWSCwdPublicationPath {
    param(
        [Parameter(Mandatory)]
        [string]$SetId,
        [Parameter(Mandatory)]
        [string]$TerminalId,
        [int]$TabIndex = 0,
        [string]$TestBaseRoot
    )

    if ($TabIndex -lt 0) {
        throw "A configured tab index cannot be negative (got $TabIndex)."
    }

    if ((Get-DevWSCwdStorageMode -TestBaseRoot $TestBaseRoot) -eq "protected") {
        $sidRoot = Resolve-DevWSCwdProtectedSidRoot -TestBaseRoot $TestBaseRoot
        return (Get-DevWSCwdProtectedPath -SidRoot $sidRoot -Kind "publications" -SetId $SetId -TerminalId $TerminalId -TabIndex $TabIndex)
    }

    $setRoot = Join-Path (Get-DevWSCwdPublicationRoot) $SetId

    if ($TabIndex -eq 0) {
        # Tab 0 permanently keeps the historical Phase-9 terminal-level path.
        return (Join-Path $setRoot ($TerminalId + ".json"))
    }

    return (Join-Path (Join-Path $setRoot $TerminalId) ($TabIndex.ToString() + ".json"))
}

function Test-DevWSCwdProtectedChainTrust {
    # Read-side descendant authorization. Before ANY descendant decision the
    # COMPLETE P2-A protected-root contract is revalidated through the single
    # authoritative validator (structural safety, the DevWS container, the
    # privileged-state container, the current-user SID root, owner/DACL,
    # inheritance, directory type, reparse safety and - for installed chains -
    # the ProgramData anchor Medium effective-access invariant). Only then
    # does the minimal per-leaf descendant walk run through the existing
    # handle-bound P2-A component validator with the exact Kind User policy.
    # Readers never create, repair or modify anything; any failure yields a
    # fail-closed reason for the tolerant resolver instead of an exception.
    param(
        [Parameter(Mandatory)][string]$SidRoot,
        [Parameter(Mandatory)][ValidateSet("sessions", "publications")][string]$Kind,
        [Parameter(Mandatory)][string]$SetId,
        [Parameter(Mandatory)][string]$TerminalId,
        [int]$TabIndex = 0
    )

    $rootTrust = $null

    try {
        $rootTrust = Test-DevWSPrivilegedStateRoot -Root $SidRoot
    }
    catch {
        $rootTrust = $null
    }

    if ($null -eq $rootTrust -or -not [bool]$rootTrust.Ok) {
        $rootErrors = $(if ($null -ne $rootTrust) { @($rootTrust.Errors) } else { @("the protected root validation could not run") })

        return [pscustomobject]@{ Ok = $false; Reason = "root-invalid"; Component = $SidRoot; Errors = $rootErrors }
    }

    $budget = Test-DevWSCwdProtectedPathBudget -SidRoot $SidRoot

    if (-not [bool]$budget.Ok) {
        return [pscustomobject]@{ Ok = $false; Reason = [string]$budget.Reason; Component = ""; Errors = @() }
    }

    foreach ($component in @(Get-DevWSCwdProtectedChain -SidRoot $SidRoot -Kind $Kind -SetId $SetId -TerminalId $TerminalId -TabIndex $TabIndex)) {
        if (-not (Test-Path -LiteralPath $component)) {
            return [pscustomobject]@{ Ok = $false; Reason = "chain-missing"; Component = $component; Errors = @() }
        }

        $validation = Test-DevWSProtectedStateComponent -Component $component -Kind User

        if (-not [bool]$validation.Ok) {
            return [pscustomobject]@{ Ok = $false; Reason = "chain-invalid"; Component = $component; Errors = @($validation.Errors) }
        }
    }

    return [pscustomobject]@{ Ok = $true; Reason = "ok"; Component = ""; Errors = @() }
}

function Initialize-DevWSCwdProtectedChain {
    # Write-side descendant authorization: validate the full P2-A SID-root and
    # anchor contract first, then create-or-validate every addressed descendant
    # exactly once with the accepted exclusive secure-directory primitive.
    # Missing components are created High-side and immediately validated;
    # AlreadyExists is treated as untrusted input and validated; an insecure
    # existing component is refused, never repaired, taken over or deleted.
    param(
        [Parameter(Mandatory)][string]$SidRoot,
        [Parameter(Mandatory)][ValidateSet("sessions", "publications")][string]$Kind,
        [Parameter(Mandatory)][string]$SetId,
        [Parameter(Mandatory)][string]$TerminalId,
        [int]$TabIndex = 0
    )

    Assert-DevWSProtectedStateWritable -Root $SidRoot
    Assert-DevWSCwdProtectedPathBudget -SidRoot $SidRoot -Operation "initialize protected cwd $Kind hierarchy" | Out-Null

    $security = New-DevWSPrivilegedStateDirectorySecurity -Kind User
    $sddl = $security.GetSecurityDescriptorSddlForm([System.Security.AccessControl.AccessControlSections]::Owner -bor [System.Security.AccessControl.AccessControlSections]::Access)

    foreach ($component in @(Get-DevWSCwdProtectedChain -SidRoot $SidRoot -Kind $Kind -SetId $SetId -TerminalId $TerminalId -TabIndex $TabIndex)) {
        if (Test-Path -LiteralPath $component) {
            $validation = Test-DevWSProtectedStateComponent -Component $component -Kind User

            if (-not [bool]$validation.Ok) {
                throw ("The protected cwd directory '$component' refused the write: " + (@($validation.Errors) -join ' '))
            }

            continue
        }

        $result = New-DevWSProtectedStateExclusiveDirectory -Path $component -Sddl $sddl

        if ($result -eq "Failure") {
            throw "The protected cwd directory '$component' could not be created."
        }

        $validation = Test-DevWSProtectedStateComponent -Component $component -Kind User

        if (-not [bool]$validation.Ok) {
            throw ("The newly created protected cwd directory '$component' failed validation: " + (@($validation.Errors) -join ' '))
        }
    }
}

function Test-DevWSCwdProtectedLeafSafety {
    # Unexpected objects at an authoritative destination are refused before
    # any read or write: the leaf must remain inside the validated parent and
    # must not be a directory or a reparse object.
    param(
        [Parameter(Mandatory)][string]$SidRoot,
        [Parameter(Mandatory)][string]$LeafPath
    )

    if (-not (Test-DevWSCwdProtectedContainment -SidRoot $SidRoot -Path $LeafPath)) {
        return [pscustomobject]@{ Ok = $false; Reason = "leaf-outside-root" }
    }

    if (Test-Path -LiteralPath $LeafPath) {
        $item = Get-Item -LiteralPath $LeafPath -Force

        if ($item.PSIsContainer) {
            return [pscustomobject]@{ Ok = $false; Reason = "leaf-is-directory" }
        }

        if ([bool]($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            return [pscustomobject]@{ Ok = $false; Reason = "leaf-is-reparse" }
        }
    }

    return [pscustomobject]@{ Ok = $true; Reason = "ok" }
}

function New-DevWSCwdSessionId {
    return [guid]::NewGuid().ToString()
}

function Write-DevWSCwdJsonAtomic {
    # Atomic disposable-state write: unique temp file, UTF-8 without BOM,
    # validated serialization, then a bounded replace retry because a Windows
    # reader without delete-sharing can transiently block the replace.
    #
    # -NoCreateDirectory is the protected-mode contract: trusted protected
    # ancestors are created only through the exclusive secure-directory
    # primitive (never New-Item -Force), so a missing parent is a hard refusal.
    # An unexpected directory or reparse object at the destination is always
    # refused before any write.
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        $Object,
        [int]$RetryCount = 6,
        [int]$RetryDelayMilliseconds = 40,
        [switch]$NoCreateDirectory
    )

    $directory = Split-Path -Parent $Path

    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        if ($NoCreateDirectory) {
            throw "The destination directory '$directory' does not exist; a protected cwd write never creates trusted ancestors through ordinary directory creation."
        }

        New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    if (Test-Path -LiteralPath $Path) {
        $existingItem = Get-Item -LiteralPath $Path -Force

        if ($existingItem.PSIsContainer -or [bool]($existingItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            throw "Refusing a cwd state write through an unexpected filesystem object at '$Path'."
        }
    }

    $json = $Object | ConvertTo-Json -Depth 8 -Compress

    # Never publish content we cannot read back.
    $null = $json | ConvertFrom-Json -ErrorAction Stop

    $tempPath = Join-Path $directory (".cwd-" + [string]$PID + "-" + [guid]::NewGuid().ToString("N") + ".tmp")

    try {
        [System.IO.File]::WriteAllText($tempPath, $json, [System.Text.UTF8Encoding]::new($false))

        $attempt = 0

        while ($true) {
            $attempt++

            try {
                [System.IO.File]::Move($tempPath, $Path, $true)
                break
            }
            catch {
                # A Windows reader without delete-sharing can surface either a
                # sharing violation (IOException) or access denied; both are
                # transient here. [System.IO.File]::Move failures arrive
                # wrapped in MethodInvocationException, so unwrap first.
                $moveError = $_.Exception

                if ($moveError -is [System.Management.Automation.MethodInvocationException] -and $null -ne $moveError.InnerException) {
                    $moveError = $moveError.InnerException
                }

                $isTransient = ($moveError -is [System.IO.IOException]) -or ($moveError -is [System.UnauthorizedAccessException])

                if (-not $isTransient -or $attempt -ge $RetryCount) { throw }
                Start-Sleep -Milliseconds $RetryDelayMilliseconds
            }
        }
    }
    finally {
        if (Test-Path -LiteralPath $tempPath) {
            Remove-Item -LiteralPath $tempPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Write-DevWSCwdSessionRecord {
    # Controller-owned expected generation. Failure here is a real error.
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        $Record,
        [switch]$NoCreateDirectory
    )

    Write-DevWSCwdJsonAtomic -Path $Path -Object $Record -NoCreateDirectory:$NoCreateDirectory
}

function Write-DevWSCwdPublication {
    # Shell-owned cwd publication. The bootstrap catches failures; this helper
    # is also used directly by tests.
    param(
        [Parameter(Mandatory)]
        [string]$Path,
        [Parameter(Mandatory)]
        $Record,
        [switch]$NoCreateDirectory
    )

    Write-DevWSCwdJsonAtomic -Path $Path -Object $Record -NoCreateDirectory:$NoCreateDirectory
}

function New-DevWSCwdTrackingSession {
    # Create a fresh generation for one set/terminal/configured-tab identity.
    # Returns the context the tracked shell needs; the expected session record
    # is written atomically first, then any previous publication is removed
    # best-effort. Correctness never depends on that deletion: an old shell may
    # republish its old token, and the separate expected generation invalidates
    # it. Tab 0 uses the historical terminal-level shape; tabs 1+ use indexed
    # paths and carry their configured tabIndex in the record.
    #
    # Installed layouts (and repository fixtures that request protected
    # authority) write ONLY into the administrator-protected cwd namespace:
    # the full P2-A SID-root contract is validated, the path budget is
    # enforced before any mutation, and every addressed descendant is
    # created-or-validated through the exclusive secure-directory primitive.
    param(
        [Parameter(Mandatory)]
        [string]$SetId,
        [Parameter(Mandatory)]
        [string]$TerminalId,
        [Parameter(Mandatory)]
        [string]$WindowId,
        [int]$TabIndex = 0,
        [AllowNull()]
        [AllowEmptyString()]
        [string]$StartupSpecSha256 = $null,
        [string]$TestBaseRoot
    )

    if ($TabIndex -lt 0) {
        throw "A configured tab index cannot be negative (got $TabIndex)."
    }

    $mode = Get-DevWSCwdStorageMode -TestBaseRoot $TestBaseRoot
    $protected = ($mode -eq "protected")

    if ($protected) {
        $sidRoot = Resolve-DevWSCwdProtectedSidRoot -TestBaseRoot $TestBaseRoot
        Assert-DevWSCwdProtectedPathBudget -SidRoot $sidRoot -Operation "create expected generation for '$SetId'/'$TerminalId' tab $TabIndex" | Out-Null
    }

    $sessionId       = New-DevWSCwdSessionId
    $sessionPath     = Get-DevWSCwdSessionPath -SetId $SetId -TerminalId $TerminalId -TabIndex $TabIndex -TestBaseRoot $TestBaseRoot
    $publicationPath = Get-DevWSCwdPublicationPath -SetId $SetId -TerminalId $TerminalId -TabIndex $TabIndex -TestBaseRoot $TestBaseRoot

    if ($protected) {
        Initialize-DevWSCwdProtectedChain -SidRoot $sidRoot -Kind "sessions" -SetId $SetId -TerminalId $TerminalId -TabIndex $TabIndex
        Initialize-DevWSCwdProtectedChain -SidRoot $sidRoot -Kind "publications" -SetId $SetId -TerminalId $TerminalId -TabIndex $TabIndex

        $leafCheck = Test-DevWSCwdProtectedLeafSafety -SidRoot $sidRoot -LeafPath $sessionPath

        if (-not [bool]$leafCheck.Ok) {
            throw "The protected cwd expected-record destination refused the write ($($leafCheck.Reason))."
        }

        # Collision fail-closed: a leaf whose key collides with a DIFFERENT
        # logical identity is never overwritten or adopted.
        $existing = Read-DevWSCwdSessionRecord -Path $sessionPath

        if ($null -ne $existing) {
            $existingSet      = [string](Get-DevWSCwdPropertyValue $existing "setId")
            $existingTerminal = [string](Get-DevWSCwdPropertyValue $existing "terminalId")

            if ($existingSet -ine $SetId -or $existingTerminal -ine $TerminalId) {
                throw "The protected cwd expected-record destination already carries a different logical identity ('$existingSet'/'$existingTerminal'); refusing to overwrite it."
            }
        }
    }

    $record = [ordered]@{
        version    = 1
        setId      = $SetId
        terminalId = $TerminalId
        windowId   = $WindowId
    }

    if ($TabIndex -gt 0) {
        $record.tabIndex = $TabIndex
    }

    $record.sessionId = $sessionId

    if (-not [string]::IsNullOrWhiteSpace($StartupSpecSha256)) {
        $record.startupSpecSha256 = [string]$StartupSpecSha256
    }

    Write-DevWSCwdSessionRecord -Path $sessionPath -Record $record -NoCreateDirectory:$protected

    if (Test-Path -LiteralPath $publicationPath -PathType Leaf) {
        Remove-Item -LiteralPath $publicationPath -Force -ErrorAction SilentlyContinue
    }

    return [pscustomobject]@{
        SetId             = $SetId
        TerminalId        = $TerminalId
        WindowId          = $WindowId
        TabIndex          = $TabIndex
        SessionId         = $sessionId
        SessionPath       = $sessionPath
        PublicationPath   = $publicationPath
        StartupSpecSha256 = $(if ([string]::IsNullOrWhiteSpace($StartupSpecSha256)) { $null } else { [string]$StartupSpecSha256 })
    }
}

function Read-DevWSCwdStateFile {
    # Tolerant reader used by the resolver: distinguishes missing/empty/
    # unreadable/malformed from a parsed record so the resolver can return a
    # stable reason instead of throwing.
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject]@{ Ok = $false; Reason = "missing"; Record = $null }
    }

    try {
        $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    }
    catch {
        return [pscustomobject]@{ Ok = $false; Reason = "unreadable"; Record = $null }
    }

    if ([string]::IsNullOrWhiteSpace($raw)) {
        return [pscustomobject]@{ Ok = $false; Reason = "empty"; Record = $null }
    }

    try {
        $record = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return [pscustomobject]@{ Ok = $false; Reason = "malformed"; Record = $null }
    }

    if ($null -eq $record) {
        return [pscustomobject]@{ Ok = $false; Reason = "malformed"; Record = $null }
    }

    return [pscustomobject]@{ Ok = $true; Reason = "ok"; Record = $record }
}

function Read-DevWSCwdSessionRecord {
    param([Parameter(Mandatory)][string]$Path)

    $read = Read-DevWSCwdStateFile -Path $Path
    if (-not $read.Ok) { return $null }
    return $read.Record
}

function Read-DevWSCwdPublication {
    param([Parameter(Mandatory)][string]$Path)

    $read = Read-DevWSCwdStateFile -Path $Path
    if (-not $read.Ok) { return $null }
    return $read.Record
}

function Get-DevWSCwdPropertyValue {
    param($Record, [string]$Name)

    if ($null -eq $Record) { return $null }

    if ($Record -is [System.Collections.IDictionary]) {
        if (-not $Record.Contains($Name)) { return $null }
        return $Record[$Name]
    }

    $property = $Record.PSObject.Properties[$Name]
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Get-DevWSCwdProcessIdentity {
    # Process acquisition layer. The pure record-pair validator accepts any
    # injected identity object, so tests never need real processes.
    param([int]$ProcessId)

    if ($ProcessId -le 0) {
        return [pscustomobject]@{ Alive = $false; StartTimeUtc = $null }
    }

    try {
        $process = Get-Process -Id $ProcessId -ErrorAction Stop
        return [pscustomobject]@{ Alive = $true; StartTimeUtc = $process.StartTime.ToUniversalTime() }
    }
    catch {
        return [pscustomobject]@{ Alive = $false; StartTimeUtc = $null }
    }
}

function Test-DevWSCwdExpectedGeneration {
    # Shared Pass 6D expected-side identity contract for ONE controller-owned
    # expected record of one set/terminal/configured tab. The pair validators
    # (initial resolution) and the `ws save` final generation gate both consume
    # this one definition instead of duplicating the rules.
    #
    # TabIndex -1 skips the configured-tab reconciliation (plain historical
    # pair validation); TabIndex >= 0 applies the Pass 6B/6C rules:
    #   - tab N > 0 requires an exact tabIndex match;
    #   - tab 0 accepts a missing/empty/0 tabIndex and rejects non-zero values.
    #
    # Optional ExpectedSessionId / ExpectedWindowId additionally require the
    # record to retain an initially accepted generation identity.
    #
    # Returns { Ok; Reason } with the established reason vocabulary:
    # expected-missing / expected-unreadable / expected-malformed /
    # expected-empty / expected-version / expected-schema / set-mismatch /
    # terminal-mismatch / tab-mismatch / session-mismatch / window-mismatch.
    param(
        $Expected,
        [string]$ExpectedReadError = "",
        [Parameter(Mandatory)]
        [string]$SetId,
        [Parameter(Mandatory)]
        [string]$TerminalId,
        [int]$TabIndex = -1,
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ExpectedSessionId = $null,
        [AllowNull()]
        [AllowEmptyString()]
        [string]$ExpectedWindowId = $null
    )

    if (-not [string]::IsNullOrWhiteSpace($ExpectedReadError)) {
        return [pscustomobject]@{ Ok = $false; Reason = "expected-$ExpectedReadError" }
    }

    if ($null -eq $Expected) {
        return [pscustomobject]@{ Ok = $false; Reason = "expected-missing" }
    }

    if ($TabIndex -ge 0) {
        $expectedTab = [string](Get-DevWSCwdPropertyValue $Expected "tabIndex")

        if ($TabIndex -gt 0) {
            if ([string]::IsNullOrWhiteSpace($expectedTab) -or $expectedTab -ne $TabIndex.ToString()) {
                return [pscustomobject]@{ Ok = $false; Reason = "tab-mismatch" }
            }
        }
        elseif ($null -ne (Get-DevWSCwdPropertyValue $Expected "tabIndex") -and $expectedTab -ne "" -and $expectedTab -ne "0") {
            return [pscustomobject]@{ Ok = $false; Reason = "tab-mismatch" }
        }
    }

    if ([string](Get-DevWSCwdPropertyValue $Expected "version") -ne "1") {
        return [pscustomobject]@{ Ok = $false; Reason = "expected-version" }
    }

    foreach ($field in @("setId", "terminalId", "windowId", "sessionId")) {
        $value = Get-DevWSCwdPropertyValue $Expected $field

        if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) {
            return [pscustomobject]@{ Ok = $false; Reason = "expected-schema" }
        }
    }

    if ([string](Get-DevWSCwdPropertyValue $Expected "setId") -ine $SetId) {
        return [pscustomobject]@{ Ok = $false; Reason = "set-mismatch" }
    }

    if ([string](Get-DevWSCwdPropertyValue $Expected "terminalId") -ine $TerminalId) {
        return [pscustomobject]@{ Ok = $false; Reason = "terminal-mismatch" }
    }

    if (-not [string]::IsNullOrEmpty($ExpectedSessionId) -and [string](Get-DevWSCwdPropertyValue $Expected "sessionId") -cne $ExpectedSessionId) {
        return [pscustomobject]@{ Ok = $false; Reason = "session-mismatch" }
    }

    if (-not [string]::IsNullOrEmpty($ExpectedWindowId) -and [string](Get-DevWSCwdPropertyValue $Expected "windowId") -cne $ExpectedWindowId) {
        return [pscustomobject]@{ Ok = $false; Reason = "window-mismatch" }
    }

    return [pscustomobject]@{ Ok = $true; Reason = "ok" }
}

function Test-DevWSCwdRecordPair {
    # Pure validation of one expected/publication pair. Filesystem checks for
    # the cwd are included; process liveness is injected through
    # ProcessIdentity so unit tests can exercise every branch deterministically.
    #
    # Pass 6D: optional TabIndex >= 0 adds the configured-tab reconciliation.
    # The publication side is checked here; the expected side is delegated to
    # the shared Test-DevWSCwdExpectedGeneration.
    param(
        $Expected,
        [string]$ExpectedReadError = "",
        $Publication,
        [string]$PublicationReadError = "",
        [Parameter(Mandatory)]
        [string]$SetId,
        [Parameter(Mandatory)]
        [string]$TerminalId,
        [int]$TabIndex = -1,
        $ProcessIdentity
    )

    $result = [ordered]@{
        Status    = "unavailable"
        Reason    = "unavailable"
        Cwd       = $null
        SessionId = $null
        WindowId  = $null
    }

    if ($TabIndex -ge 0 -and $null -ne $Publication) {
        $publicationTab = [string](Get-DevWSCwdPropertyValue $Publication "tabIndex")

        if ($TabIndex -gt 0) {
            if ([string]::IsNullOrWhiteSpace($publicationTab) -or $publicationTab -ne $TabIndex.ToString()) {
                $result.Reason = "tab-mismatch"
                return [pscustomobject]$result
            }
        }
        elseif ($null -ne (Get-DevWSCwdPropertyValue $Publication "tabIndex") -and $publicationTab -ne "" -and $publicationTab -ne "0") {
            $result.Reason = "tab-mismatch"
            return [pscustomobject]$result
        }
    }

    $expectedCheck = Test-DevWSCwdExpectedGeneration `
        -Expected $Expected `
        -ExpectedReadError $ExpectedReadError `
        -SetId $SetId `
        -TerminalId $TerminalId `
        -TabIndex $TabIndex

    if (-not [bool]$expectedCheck.Ok) {
        $result.Reason = [string]$expectedCheck.Reason
        return [pscustomobject]$result
    }

    if (-not [string]::IsNullOrWhiteSpace($PublicationReadError)) {
        $result.Reason = "publication-$PublicationReadError"
        return [pscustomobject]$result
    }

    if ($null -eq $Publication) {
        $result.Reason = "publication-missing"
        return [pscustomobject]$result
    }

    if ([string](Get-DevWSCwdPropertyValue $Publication "version") -ne "1") {
        $result.Reason = "publication-version"
        return [pscustomobject]$result
    }

    foreach ($field in @("setId", "terminalId", "windowId", "sessionId", "shellPid", "shellStartTimeUtc")) {
        $value = Get-DevWSCwdPropertyValue $Publication $field

        if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) {
            $result.Reason = "publication-schema"
            return [pscustomobject]$result
        }
    }

    if ([string](Get-DevWSCwdPropertyValue $Publication "setId") -ine $SetId) {
        $result.Reason = "set-mismatch"
        return [pscustomobject]$result
    }

    if ([string](Get-DevWSCwdPropertyValue $Publication "terminalId") -ine $TerminalId) {
        $result.Reason = "terminal-mismatch"
        return [pscustomobject]$result
    }

    if ([string](Get-DevWSCwdPropertyValue $Publication "windowId") -cne [string](Get-DevWSCwdPropertyValue $Expected "windowId")) {
        $result.Reason = "window-mismatch"
        return [pscustomobject]$result
    }

    if ([string](Get-DevWSCwdPropertyValue $Publication "sessionId") -cne [string](Get-DevWSCwdPropertyValue $Expected "sessionId")) {
        $result.Reason = "session-mismatch"
        return [pscustomobject]$result
    }

    $cwd = [string](Get-DevWSCwdPropertyValue $Publication "cwd")

    if ([string]::IsNullOrWhiteSpace($cwd)) {
        $result.Reason = "cwd-empty"
        return [pscustomobject]$result
    }

    if (-not [System.IO.Path]::IsPathRooted($cwd)) {
        $result.Reason = "cwd-relative"
        return [pscustomobject]$result
    }

    if (Test-Path -LiteralPath $cwd -PathType Leaf) {
        $result.Reason = "cwd-not-directory"
        return [pscustomobject]$result
    }

    if (-not (Test-Path -LiteralPath $cwd -PathType Container)) {
        $result.Reason = "cwd-missing"
        return [pscustomobject]$result
    }

    $shellPidRaw = [string](Get-DevWSCwdPropertyValue $Publication "shellPid")
    $shellPid    = 0

    if (-not [int]::TryParse($shellPidRaw, [ref]$shellPid) -or $shellPid -le 0) {
        $result.Reason = "publication-schema"
        return [pscustomobject]$result
    }

    if ($null -eq $ProcessIdentity -or -not [bool]$ProcessIdentity.Alive) {
        $result.Reason = "shell-dead"
        return [pscustomobject]$result
    }

    $recordedStartRaw = [string](Get-DevWSCwdPropertyValue $Publication "shellStartTimeUtc")

    try {
        $recordedStart = [datetime]::Parse(
            $recordedStartRaw,
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AdjustToUniversal
        )
    }
    catch {
        $result.Reason = "shell-identity-malformed"
        return [pscustomobject]$result
    }

    $liveStart = $ProcessIdentity.StartTimeUtc
    $startDelta = [math]::Abs(([datetime]$liveStart).ToUniversalTime().Subtract($recordedStart).TotalSeconds)

    if ($startDelta -gt 2.0) {
        $result.Reason = "shell-identity-mismatch"
        return [pscustomobject]$result
    }

    $result.Status    = "available"
    $result.Reason    = "ok"
    $result.Cwd       = $cwd
    # Read-only accepted-generation identity, used by the `ws save` transaction
    # for its final expected-generation revalidation. Never persisted to
    # canonical config and never shown in normal user output.
    $result.SessionId = [string](Get-DevWSCwdPropertyValue $Expected "sessionId")
    $result.WindowId  = [string](Get-DevWSCwdPropertyValue $Expected "windowId")
    return [pscustomobject]$result
}

function Test-DevWSCwdTabRecordPair {
    # Pass 6B per-configured-tab identity wrapper. Pass 6D moved the actual
    # tabIndex reconciliation into Test-DevWSCwdRecordPair (publication side)
    # and Test-DevWSCwdExpectedGeneration (expected side) so the `ws save`
    # final generation gate shares the same rules; this wrapper preserves the
    # public API and callers.
    #
    #   - indexed tabs (TabIndex > 0) require an exact tabIndex match in BOTH
    #     the expected record and the publication;
    #   - tab 0 records may omit tabIndex for historical compatibility, but a
    #     record carrying a non-zero tabIndex is never accepted as tab 0.
    #
    # Returns the same shape as Test-DevWSCwdRecordPair.
    param(
        $Expected,
        [string]$ExpectedReadError = "",
        $Publication,
        [string]$PublicationReadError = "",
        [Parameter(Mandatory)]
        [string]$SetId,
        [Parameter(Mandatory)]
        [string]$TerminalId,
        [int]$TabIndex = 0,
        $ProcessIdentity
    )

    if ($TabIndex -lt 0) {
        throw "A configured tab index cannot be negative (got $TabIndex)."
    }

    return Test-DevWSCwdRecordPair `
        -Expected $Expected `
        -ExpectedReadError $ExpectedReadError `
        -Publication $Publication `
        -PublicationReadError $PublicationReadError `
        -SetId $SetId `
        -TerminalId $TerminalId `
        -TabIndex $TabIndex `
        -ProcessIdentity $ProcessIdentity
}

function Resolve-DevWSTrackedCwd {
    # Read-only resolver for the `ws save` consumer. Returns
    # { status = available|unavailable; reason; cwd; sessionId; windowId;
    #   tabIndex; startupState; startupSpecSha256 } and never throws for
    # malformed, transient, stale, or dead-shell state.
    #
    # TabIndex omitted/0 keeps the historical tab-0 behavior and result shape;
    # TabIndex > 0 resolves indexed tab state. Startup metadata is an
    # independent capability level: a missing or malformed startupState /
    # startupSpecSha256 never invalidates an otherwise-valid cwd.
    #
    # Installed layouts read protected authority ONLY: derived paths require
    # the addressed protected directory chain to validate first, and any
    # protected path/ACL/budget failure becomes a fail-closed `unavailable`
    # result. Explicit -SessionPath/-PublicationPath remain a low-level
    # repository/test seam.
    param(
        [Parameter(Mandatory)]
        [string]$SetId,
        [Parameter(Mandatory)]
        [string]$TerminalId,
        [int]$TabIndex = 0,
        [string]$SessionPath,
        [string]$PublicationPath,
        [string]$TestBaseRoot
    )

    if ($TabIndex -lt 0) {
        throw "A configured tab index cannot be negative (got $TabIndex)."
    }

    $mode = "legacy"

    try {
        $mode = Get-DevWSCwdStorageMode -TestBaseRoot $TestBaseRoot
    }
    catch {
        return [pscustomobject]@{
            Status            = "unavailable"
            Reason            = "protected-root-unavailable"
            Cwd               = $null
            SessionId         = $null
            WindowId          = $null
            TabIndex          = $TabIndex
            StartupState      = $null
            StartupSpecSha256 = $null
        }
    }

    # Installed authority derives exclusively from the protected ProgramData/SID
    # namespace. Explicit -SessionPath/-PublicationPath arguments exist ONLY
    # for repository fixtures and are refused (tolerant unavailable, never an
    # exception) in every other layout - a supplied pathname is never trusted
    # merely because it is normalized or appears to live under ProgramData.
    $layout = Get-DevWSPathsLayout

    if ($layout -ne "repository" -and
        (-not [string]::IsNullOrWhiteSpace($SessionPath) -or -not [string]::IsNullOrWhiteSpace($PublicationPath))) {
        return [pscustomobject]@{
            Status            = "unavailable"
            Reason            = "explicit-path-refused"
            Cwd               = $null
            SessionId         = $null
            WindowId          = $null
            TabIndex          = $TabIndex
            StartupState      = $null
            StartupSpecSha256 = $null
        }
    }

    $protected = ($mode -eq "protected")
    $sidRoot   = $null

    if ($protected) {
        try {
            $sidRoot = Resolve-DevWSCwdProtectedSidRoot -TestBaseRoot $TestBaseRoot
        }
        catch {
            return [pscustomobject]@{
                Status            = "unavailable"
                Reason            = "protected-root-unavailable"
                Cwd               = $null
                SessionId         = $null
                WindowId          = $null
                TabIndex          = $TabIndex
                StartupState      = $null
                StartupSpecSha256 = $null
            }
        }
    }

    $derivedSession     = [string]::IsNullOrWhiteSpace($SessionPath)
    $derivedPublication = [string]::IsNullOrWhiteSpace($PublicationPath)

    if ($protected -and ($derivedSession -or $derivedPublication)) {
        $kinds = [System.Collections.Generic.List[string]]::new()

        if ($derivedSession)     { $kinds.Add("sessions") }
        if ($derivedPublication) { $kinds.Add("publications") }

        foreach ($kind in $kinds) {
            $trust = Test-DevWSCwdProtectedChainTrust -SidRoot $sidRoot -Kind $kind -SetId $SetId -TerminalId $TerminalId -TabIndex $TabIndex

            if (-not [bool]$trust.Ok) {
                $reason = $(switch ([string]$trust.Reason) {
                    "chain-missing"          { "protected-chain-missing" }
                    "chain-invalid"          { "protected-chain-invalid" }
                    "root-invalid"           { "protected-root-invalid" }
                    "protected-root-budget"  { "protected-path-budget" }
                    "protected-path-budget"  { "protected-path-budget" }
                    default                  { "protected-chain-unavailable" }
                })

                return [pscustomobject]@{
                    Status            = "unavailable"
                    Reason            = $reason
                    Cwd               = $null
                    SessionId         = $null
                    WindowId          = $null
                    TabIndex          = $TabIndex
                    StartupState      = $null
                    StartupSpecSha256 = $null
                }
            }
        }
    }

    if ($derivedSession) {
        $SessionPath = Get-DevWSCwdSessionPath -SetId $SetId -TerminalId $TerminalId -TabIndex $TabIndex -TestBaseRoot $TestBaseRoot
    }

    if ($derivedPublication) {
        $PublicationPath = Get-DevWSCwdPublicationPath -SetId $SetId -TerminalId $TerminalId -TabIndex $TabIndex -TestBaseRoot $TestBaseRoot
    }

    if ($protected) {
        foreach ($leaf in @(
            @{ Derived = $derivedSession; Path = $SessionPath },
            @{ Derived = $derivedPublication; Path = $PublicationPath }
        )) {
            if (-not [bool]$leaf.Derived) { continue }

            $leafCheck = Test-DevWSCwdProtectedLeafSafety -SidRoot $sidRoot -LeafPath ([string]$leaf.Path)

            if (-not [bool]$leafCheck.Ok) {
                return [pscustomobject]@{
                    Status            = "unavailable"
                    Reason            = "protected-leaf-" + [string]$leafCheck.Reason
                    Cwd               = $null
                    SessionId         = $null
                    WindowId          = $null
                    TabIndex          = $TabIndex
                    StartupState      = $null
                    StartupSpecSha256 = $null
                }
            }
        }
    }

    $expectedRead    = Read-DevWSCwdStateFile -Path $SessionPath
    $publicationRead = Read-DevWSCwdStateFile -Path $PublicationPath

    $shellPid = 0

    if ($publicationRead.Ok) {
        $shellPidRaw = [string](Get-DevWSCwdPropertyValue $publicationRead.Record "shellPid")

        if (-not [int]::TryParse($shellPidRaw, [ref]$shellPid) -or $shellPid -le 0) {
            $shellPid = 0
        }
    }

    $identity = Get-DevWSCwdProcessIdentity -ProcessId $shellPid

    $pair = Test-DevWSCwdTabRecordPair `
        -Expected $expectedRead.Record `
        -ExpectedReadError $(if ($expectedRead.Ok) { "" } else { $expectedRead.Reason }) `
        -Publication $publicationRead.Record `
        -PublicationReadError $(if ($publicationRead.Ok) { "" } else { $publicationRead.Reason }) `
        -SetId $SetId `
        -TerminalId $TerminalId `
        -TabIndex $TabIndex `
        -ProcessIdentity $identity

    # Independent startup-metadata capability (never required for cwd).
    $startupState = $null

    if ($publicationRead.Ok) {
        $startupStateRaw = [string](Get-DevWSCwdPropertyValue $publicationRead.Record "startupState")

        if ($startupStateRaw -in @("idle", "startup-child-active", "startup-child-returned")) {
            $startupState = $startupStateRaw
        }
    }

    $startupSpecSha256 = $null

    if ($expectedRead.Ok) {
        $startupSpecRaw = [string](Get-DevWSCwdPropertyValue $expectedRead.Record "startupSpecSha256")

        if (-not [string]::IsNullOrWhiteSpace($startupSpecRaw)) {
            $startupSpecSha256 = $startupSpecRaw
        }
    }

    return [pscustomobject]@{
        Status            = [string]$pair.Status
        Reason            = [string]$pair.Reason
        Cwd               = $(if ($null -ne $pair.Cwd) { [string]$pair.Cwd } else { $null })
        SessionId         = $(if ($null -ne $pair.SessionId) { [string]$pair.SessionId } else { $null })
        WindowId          = $(if ($null -ne $pair.WindowId) { [string]$pair.WindowId } else { $null })
        TabIndex          = $TabIndex
        StartupState      = $startupState
        StartupSpecSha256 = $startupSpecSha256
    }
}

function ConvertTo-DevWSCwdChildSpecJson {
    # THE canonical serialization of the intended startup child (command +
    # ordered args). The Base64 payload and the startup-spec fingerprint both
    # derive from these exact UTF-8 JSON bytes; never hash a shell-joined
    # command string and never normalize argument distinctions away.
    #
    # Normalization matches the actual child invocation semantics: a null or
    # whitespace-only command becomes null, and every argument (including
    # numbers in the config model) becomes its canonical string form.
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Command,
        [AllowEmptyCollection()]
        [object[]]$Arguments = @()
    )

    $normalizedCommand = $null

    if (-not [string]::IsNullOrWhiteSpace($Command)) {
        $normalizedCommand = [string]$Command
    }

    $normalizedArguments = @()

    foreach ($argument in @($Arguments)) {
        $normalizedArguments += [string]$argument
    }

    $spec = [ordered]@{
        command = $normalizedCommand
        args    = $normalizedArguments
    }

    return ($spec | ConvertTo-Json -Compress -Depth 4)
}

function ConvertTo-DevWSCwdChildSpecBase64 {
    # One safe encoded child command payload for a tracked shell. Never build a
    # giant quoted command line; the bootstrap decodes this JSON and invokes
    # the ARRAY directly, so switch-looking arguments, spaces, quotes, Unicode,
    # empty args, and argument order are preserved exactly.
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Command,
        [AllowEmptyCollection()]
        [object[]]$Arguments = @()
    )

    $json = ConvertTo-DevWSCwdChildSpecJson -Command $Command -Arguments $Arguments
    return [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($json))
}

function Get-DevWSCwdChildSpecFingerprint {
    # Deterministic startup-spec identity: SHA-256 over the exact UTF-8
    # child-spec JSON bytes. The controller-owned expected record carries this
    # value so the `ws save` startup-intent retirement predicate can compare it
    # against the CURRENT configured command+args without relying on the live
    # session generation (config-only mutations do not rotate the tracking
    # generation).
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Command,
        [AllowEmptyCollection()]
        [object[]]$Arguments = @()
    )

    $json  = ConvertTo-DevWSCwdChildSpecJson -Command $Command -Arguments $Arguments
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $sha   = [System.Security.Cryptography.SHA256]::Create()

    try {
        return ([System.BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '')
    }
    finally {
        $sha.Dispose()
    }
}

function Test-DevWSCwdChildSpecFingerprintFormat {
    # Strict recorded-fingerprint format check for the OPTIONAL startup-intent
    # retirement consumer: exactly 64 hexadecimal characters. The resolver
    # reports any non-empty expected `startupSpecSha256` string verbatim, so the
    # retirement predicate is the validation boundary. A malformed value only
    # ever makes retirement unavailable; it never affects cwd state.
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $false
    }

    return ($Value -cmatch '^[0-9A-Fa-f]{64}$')
}

function ConvertFrom-DevWSCwdChildSpecBase64 {
    # Pure decode used by tests (and available for diagnostics). The staged
    # bootstrap helper decodes the same payload standalone.
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Base64
    )

    $result = [ordered]@{
        Ok        = $false
        Reason    = "malformed"
        Command   = $null
        Arguments = @()
    }

    if ([string]::IsNullOrWhiteSpace($Base64)) {
        $result.Reason = "missing"
        return [pscustomobject]$result
    }

    try {
        $json = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Base64))
        $spec = $json | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        $result.Reason = "malformed"
        return [pscustomobject]$result
    }

    if ($null -eq $spec -or
        $null -eq $spec.PSObject.Properties["command"] -or
        $null -eq $spec.PSObject.Properties["args"]) {
        $result.Reason = "schema"
        return [pscustomobject]$result
    }

    $command = $spec.command

    if ($null -ne $command -and $command -isnot [string]) {
        $result.Reason = "schema"
        return [pscustomobject]$result
    }

    $arguments = @()

    foreach ($argument in @($spec.args)) {
        if ($null -ne $argument -and $argument -isnot [string]) {
            $result.Reason = "schema"
            return [pscustomobject]$result
        }

        $arguments += [string]$argument
    }

    $result.Ok        = $true
    $result.Reason    = "ok"
    $result.Command   = $(if ($null -eq $command -or [string]::IsNullOrWhiteSpace([string]$command)) { $null } else { [string]$command })
    $result.Arguments = $arguments
    return [pscustomobject]$result
}

function New-DevWSCwdTrackingContext {
    # Convenience for the launch/reset workers: require the staged bootstrap,
    # create the new generation for ONE configured tab, and build the full
    # tracking context for New-DevWSTerminalCreateArguments. The configured
    # tab command/args are encoded exactly, and the deterministic startup-spec
    # fingerprint of that exact spec is recorded in the controller-owned
    # expected record.
    param(
        [Parameter(Mandatory)]
        [string]$SetId,
        [Parameter(Mandatory)]
        [string]$TerminalId,
        [Parameter(Mandatory)]
        [string]$WindowId,
        [Parameter(Mandatory)]
        $Terminal,
        [int]$TabIndex = 0,
        [string]$BootstrapPath,
        [string]$TestBaseRoot
    )

    if ($TabIndex -lt 0) {
        throw "A configured tab index cannot be negative (got $TabIndex)."
    }

    if ([string]::IsNullOrWhiteSpace($BootstrapPath)) {
        $BootstrapPath = Get-DevWSCwdBootstrapPath
    }

    if (-not (Test-Path -LiteralPath $BootstrapPath -PathType Leaf)) {
        throw "DevWS cwd tracking bootstrap helper is missing: $BootstrapPath. Refusing to create an untracked terminal."
    }

    $tabs = @($Terminal.tabs)

    if ($TabIndex -gt 0 -and $TabIndex -ge $tabs.Count) {
        throw "Configured tab index $TabIndex does not exist on terminal '$TerminalId' ($($tabs.Count) tab(s))."
    }

    $tab          = if ($TabIndex -lt $tabs.Count) { $tabs[$TabIndex] } else { $null }
    $childCommand = $null
    $childArgs    = @()

    if ($null -ne $tab) {
        $childCommand = $tab.command
        $childArgs    = @($tab.args)
    }

    $startupSpecSha256 = Get-DevWSCwdChildSpecFingerprint -Command $childCommand -Arguments $childArgs

    $tracking = New-DevWSCwdTrackingSession `
        -SetId $SetId `
        -TerminalId $TerminalId `
        -WindowId $WindowId `
        -TabIndex $TabIndex `
        -StartupSpecSha256 $startupSpecSha256 `
        -TestBaseRoot $TestBaseRoot

    return [pscustomobject]@{
        BootstrapPath     = $BootstrapPath
        SetId             = $tracking.SetId
        TerminalId        = $tracking.TerminalId
        WindowId          = $tracking.WindowId
        TabIndex          = [int]$tracking.TabIndex
        SessionId         = $tracking.SessionId
        SessionPath       = $tracking.SessionPath
        PublicationPath   = $tracking.PublicationPath
        StartupSpecSha256 = $startupSpecSha256
        ChildSpecBase64   = (ConvertTo-DevWSCwdChildSpecBase64 -Command $childCommand -Arguments $childArgs)
    }
}

function New-DevWSCwdTrackingContexts {
    # Terminal-level tracking bundle: one context per configured tab, in
    # configured order. This is internal elevated-host launch-plan data; it is
    # NEVER sent over the broker wire.
    param(
        [Parameter(Mandatory)]
        [string]$SetId,
        [Parameter(Mandatory)]
        [string]$TerminalId,
        [Parameter(Mandatory)]
        [string]$WindowId,
        [Parameter(Mandatory)]
        $Terminal,
        [string]$BootstrapPath,
        [string]$TestBaseRoot
    )

    if ([string]::IsNullOrWhiteSpace($BootstrapPath)) {
        $BootstrapPath = Get-DevWSCwdBootstrapPath
    }

    if (-not (Test-Path -LiteralPath $BootstrapPath -PathType Leaf)) {
        throw "DevWS cwd tracking bootstrap helper is missing: $BootstrapPath. Refusing to create an untracked terminal."
    }

    $contexts = [System.Collections.Generic.List[object]]::new()
    $tabs     = @($Terminal.tabs)

    for ($tabIndex = 0; $tabIndex -lt $tabs.Count; $tabIndex++) {
        $contexts.Add((New-DevWSCwdTrackingContext `
            -SetId $SetId `
            -TerminalId $TerminalId `
            -WindowId $WindowId `
            -Terminal $Terminal `
            -TabIndex $tabIndex `
            -BootstrapPath $BootstrapPath `
            -TestBaseRoot $TestBaseRoot)) | Out-Null
    }

    # Plain enumeration: callers wrap with @() (or bind [object[]]) so single
    # and multi-tab terminals behave identically at every call site.
    return $contexts.ToArray()
}
