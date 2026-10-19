# DevWS capture file handling.
#
# Capture workers write one line per item:
#   <id>|MISSING
#   <id>|INVALID|<x>|<y>|<w>|<h>
#   <id>|<x>|<y>|<w>|<h>
#
# `save-layout` must only update canonical config after every enabled item has
# been captured successfully (docs/architecture.md section 9).

function Read-DevWSCaptureFile {
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Capture file was not created: $Path"
    }

    $result = @{}

    foreach ($line in Get-Content -LiteralPath $Path) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }

        $parts = $line -split '\|'
        $name = $parts[0]

        if ($parts.Count -ge 2 -and $parts[1] -eq "MISSING") {
            throw "Workspace window '$name' was not found."
        }

        if ($parts.Count -ge 2 -and $parts[1] -eq "INVALID") {
            throw "Workspace window '$name' is minimized or has invalid geometry."
        }

        if ($parts.Count -ne 5) {
            throw "Invalid geometry returned for '$name': $line"
        }

        try {
            $rect = [pscustomobject]@{
                x = [int]$parts[1]
                y = [int]$parts[2]
                w = [int]$parts[3]
                h = [int]$parts[4]
            }
        }
        catch {
            throw "Invalid geometry returned for '$name': $line"
        }

        if ($result.ContainsKey($name)) {
            throw "Duplicate geometry returned for '$name'."
        }

        $result[$name] = $rect
    }

    return $result
}

function Assert-DevWSCaptureComplete {
    param(
        [Parameter(Mandatory)]
        $Captured,
        [AllowEmptyCollection()]
        [string[]]$RequiredIds = @(),
        [string]$SourceLabel = "Workspace"
    )

    $missing = @($RequiredIds | Where-Object { -not $Captured.ContainsKey($_) } | Sort-Object)

    if ($missing.Count -gt 0) {
        throw "$SourceLabel geometry was not captured for: $($missing -join ', ')."
    }
}

function Read-DevWSTabSnapshotFile {
    # Pass 6D tolerant reader for the OPTIONAL elevated active-tab snapshot
    # sidecar (capture-elevated.snapshots.json). This artifact is disposable
    # runtime state, never canonical, and every failure mode collapses to
    # "no observations" - parsing must never turn a valid geometry capture
    # into a save failure.
    #
    # The shape is validated strictly, never coerced:
    #   - the top level must be a JSON object;
    #   - version must be the genuine integer 1 (a string "1", a floating
    #     1.0, a boolean, or a missing value all fail closed);
    #   - terminals must be an actual JSON array (a single object is NOT an
    #     implicit one-element array; one-element arrays stay arrays in the
    #     PowerShell JSON model);
    #   - each record's id must be a genuine non-empty string (numeric or
    #     otherwise coerced ids never become terminal identities).
    #
    # Returns a case-insensitive Hashtable keyed by terminal id. Each usable
    # key maps to the record object (windowId/status/selectedConfiguredTabIndex
    # are correlated by the caller with genuine-type checks); a key present
    # with a $null value marks a duplicated id, which the caller must treat as
    # unavailable (never first-wins/last-wins).
    param(
        [Parameter(Mandatory)]
        [string]$Path
    )

    $map = [System.Collections.Hashtable]::new([System.StringComparer]::OrdinalIgnoreCase)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $map
    }

    try {
        $raw = [System.IO.File]::ReadAllText($Path, [System.Text.Encoding]::UTF8)
    }
    catch {
        return $map
    }

    if ([string]::IsNullOrWhiteSpace($raw)) {
        return $map
    }

    try {
        $parsed = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return $map
    }

    if ($null -eq $parsed -or $parsed -isnot [System.Management.Automation.PSCustomObject]) {
        return $map
    }

    if (-not (Test-DevWSInteger $parsed.version) -or [long]$parsed.version -ne 1) {
        return $map
    }

    $terminals = $parsed.terminals

    if ($null -eq $terminals -or $terminals -isnot [System.Array]) {
        return $map
    }

    foreach ($entry in @($terminals)) {
        if ($null -eq $entry -or $entry -isnot [System.Management.Automation.PSCustomObject]) {
            continue
        }

        $id = $entry.id

        if ($id -isnot [string] -or [string]::IsNullOrWhiteSpace($id)) {
            continue
        }

        if ($map.ContainsKey($id)) {
            $map[$id] = $null
            continue
        }

        $map[$id] = $entry
    }

    return $map
}

function Get-DevWSBrokerCapturePublication {
    # Completion correlation for the broker capture path: only an
    # AcceptedAndCompleted, ok=true operation carrying a well-formed
    # High-generated publication identity authorizes a protected read.
    # Uncertain, failed, rejected and identity-less completions never do.
    param([Parameter(Mandatory)]$Operation)

    if ([string]$Operation.Status -eq "AcceptedButUncertain") {
        throw "Terminal capture completion is uncertain: the elevated broker accepted the operation but did not report FINAL. No fallback was attempted and no canonical save may proceed."
    }

    if ([string]$Operation.Status -ne "AcceptedAndCompleted") {
        throw "The elevated broker did not accept the capture operation; no publication identity is available."
    }

    if (-not [bool]$Operation.Ok) {
        throw "Elevated capture failed: $([string]$Operation.Message)"
    }

    $publication = [string]$Operation.Publication

    if (-not (Test-DevWSCapturePublicationIdentity -Publication $publication)) {
        throw "Elevated capture completed without a publication identity; refusing the read (no fallback, no canonical save)."
    }

    return $publication
}

function Get-DevWSWorkerCapturePublication {
    # Completion correlation for the scheduled-worker fallback: the Medium
    # caller reads ONLY its own completed worker operation id (canonical
    # lower-case GUID) and the publication identity returned through the
    # existing result-data mechanism. Anything else refuses.
    param([Parameter(Mandatory)]$Result)

    $requestId = [string]$Result.requestId

    if ($requestId -cnotmatch '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$') {
        throw "Refusing a scheduled capture result without a canonical worker operation id."
    }

    $publication = ""

    if ($null -ne $Result.data -and $null -ne $Result.data.publication) {
        $publication = [string]$Result.data.publication
    }

    if (-not (Test-DevWSCapturePublicationIdentity -Publication $publication)) {
        throw "Scheduled capture completed without a publication identity; refusing the read."
    }

    return [pscustomobject]@{ OperationId = $requestId; Publication = $publication }
}

function Read-DevWSProtectedCapturePublication {
    # Identity-stable protected consumption: open the owned no-delete-shared
    # scope on the exact claim FIRST, verify the publication identity under
    # that scope, then consume the geometry AND the optional snapshot while the
    # SAME scope remains held. Dispose in finally on every path.
    param(
        [Parameter(Mandatory)][string]$OperationId,
        [Parameter(Mandatory)][string]$ExpectedPublication,
        [string]$TestBaseRoot
    )

    if (-not (Test-DevWSCapturePublicationIdentity -Publication $ExpectedPublication)) {
        throw "Refusing a protected capture read without a well-formed expected publication identity."
    }

    # The complete protected chain must be trustworthy before any claim
    # scope decision; a drifted intermediate or root refuses the read.
    Assert-DevWSProtectedStateWritable -Root (Get-DevWSPrivilegedStateRoot -TestBaseRoot $TestBaseRoot)

    # The captures PARENT must satisfy the exact P2-A user policy as well: an
    # already-published claim is refused if the parent has since drifted
    # (user-write or delete-child grant, wrong owner, unprotected/inherited
    # ACL rules, unexpected reparse). The drifted parent is never repaired,
    # recreated or modified, and the claim's held lifetime across identity and
    # artifact consumption is unchanged.
    $capturesParentValidation = Test-DevWSProtectedStateComponent -Component (Get-DevWSProtectedCapturesRoot -TestBaseRoot $TestBaseRoot) -Kind User

    if (-not $capturesParentValidation.Ok) {
        throw ("The protected captures parent refused the publication read: " + (@($capturesParentValidation.Errors) -join ' '))
    }

    $claimPath = Get-DevWSProtectedCaptureClaimPath -OperationId $OperationId -TestBaseRoot $TestBaseRoot
    $scope = Get-DevWSProtectedPublicationScope -ClaimPath $claimPath

    try {
        $identity = Get-DevWSProtectedPublicationIdentity -ClaimPath $claimPath

        if ($identity -ine $ExpectedPublication) {
            throw "The protected capture publication identity does not match the completed operation; refusing the read."
        }

        $geometryPath = Join-Path $claimPath "capture-elevated.txt"

        if (-not (Test-Path -LiteralPath $geometryPath -PathType Leaf)) {
            throw "Elevated capture finished but produced no geometry file."
        }

        $geometry  = Read-DevWSCaptureFile -Path $geometryPath
        $snapshots = Read-DevWSTabSnapshotFile -Path (Join-Path $claimPath "capture-elevated.snapshots.json")

        return [pscustomobject]@{
            Ok        = $true
            Geometry  = $geometry
            Snapshots = $snapshots
        }
    }
    finally {
        $scope.Dispose()
    }
}
