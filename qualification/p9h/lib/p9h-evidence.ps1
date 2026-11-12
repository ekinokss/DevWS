# DevWS P9-H replay instrumentation - trial identity and artifact manager.
#
# Closes P9-G defect E1-1 at the trial level: a trial directory is created once
# and every artifact inside it is append-only or atomically replaced. Nothing in
# this module deletes prior evidence.
#
# Also provides the stage-status journal, so each stage in a replay reports its
# own outcome independently. A stage that never ran is 'absent', never 'ok'.

Set-StrictMode -Version Latest

function New-P9HTrialContext {
    # Create (or reopen) a trial directory and freeze its identity.
    #
    # -RootDirectory is the parent evidence root. The trial directory is
    # <root>/<trialId>. Reopening an existing trial id is allowed so a later
    # stage can attach to the same evidence set, but never wipes it.
    param(
        [Parameter(Mandatory)][string]$RootDirectory,
        [AllowNull()][AllowEmptyString()][string]$TrialId = $null,
        [Parameter(Mandatory)][ValidateSet('e1', 'n2', 'combined', 'selftest')][string]$Kind
    )

    if ([string]::IsNullOrWhiteSpace($TrialId)) { $TrialId = New-P9HTrialId }

    $dir = Join-Path $RootDirectory $TrialId
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $manifestPath = Join-Path $dir 'trial-manifest.json'
    $existed = Test-Path -LiteralPath $manifestPath

    if (-not $existed) {
        $manifest = [ordered]@{
            trialId       = $TrialId
            schema        = 'p9h.trial.v1'
            kind          = $Kind
            createdUtc    = Get-P9HUtcStamp
            rootDirectory = (Resolve-Path -LiteralPath $dir).Path
            host          = $env:COMPUTERNAME
            productVersion = $null
        }
        Write-P9HArtifact -Path $manifestPath -Lines @(($manifest | ConvertTo-Json -Depth 6))
    }

    return [pscustomobject][ordered]@{
        TrialId      = $TrialId
        Kind         = $Kind
        Directory    = (Resolve-Path -LiteralPath $dir).Path
        ManifestPath = $manifestPath
        StagesPath   = (Join-Path $dir 'stages.jsonl')
        Reopened     = $existed
    }
}

function Add-P9HStageStatus {
    # Append one stage outcome. Never rewrites the journal.
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][int]$Sequence,
        [Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory)][ValidateSet('started', 'ok', 'failed', 'skipped', 'timeout')][string]$Outcome,
        [AllowNull()][string]$Detail = $null,
        [AllowNull()][hashtable]$Data = $null
    )

    $line = New-P9HStageRecord -TrialId $Context.TrialId -Sequence $Sequence -Stage $Stage `
        -Outcome $Outcome -Detail $Detail -Data $Data
    Add-P9HArtifactLine -Path $Context.StagesPath -Line $line
    return $line
}

function Get-P9HArtifactPath {
    # Canonical artifact path inside a trial directory.
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Name
    )
    return (Join-Path $Context.Directory $Name)
}

function Add-P9HArtifactManifestEntry {
    # Record an artifact's role and hash so the archive step can prove exactly
    # which files belonged to the trial. Append-only; a second entry for the same
    # path is allowed and shows the file changed.
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Role
    )

    $entry = [ordered]@{
        utc     = Get-P9HUtcStamp
        role    = $Role
        file    = [System.IO.Path]::GetFileName($Path)
        bytes   = if (Test-Path -LiteralPath $Path -PathType Leaf) { (Get-Item -LiteralPath $Path).Length } else { $null }
        sha256  = Get-P9HFileSha256 -Path $Path
        present = (Test-Path -LiteralPath $Path -PathType Leaf)
    }

    Add-P9HArtifactLine -Path (Join-Path $Context.Directory 'artifact-index.jsonl') `
        -Line ($entry | ConvertTo-Json -Compress -Depth 4)

    return $entry
}

function Get-P9HTrialArtifactInventory {
    # List every artifact in the trial with size and hash, excluding the index
    # itself so the inventory stays stable across repeated calls.
    param([Parameter(Mandatory)]$Context)

    $files = @(Get-ChildItem -LiteralPath $Context.Directory -Recurse -File -ErrorAction SilentlyContinue |
        Sort-Object FullName)

    $rows = foreach ($f in $files) {
        [pscustomobject][ordered]@{
            file    = $f.FullName.Substring($Context.Directory.Length + 1).Replace('\', '/')
            bytes   = $f.Length
            sha256  = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            modifiedUtc = $f.LastWriteTimeUtc.ToString('o')
        }
    }

    return [pscustomobject][ordered]@{
        TrialId = $Context.TrialId
        Count   = @($rows).Count
        Artifacts = @($rows)
    }
}

function Write-P9HArtifactIndex {
    # Rewrite the flat SHA-256 manifest (the one artifact that is regenerated
    # rather than appended), atomically, so a tree comparison is possible.
    param([Parameter(Mandatory)]$Context)

    $inv = Get-P9HTrialArtifactInventory -Context $Context
    $lines = foreach ($a in $inv.Artifacts) {
        if ($a.file -eq 'SHA256SUMS.txt') { continue }
        '{0}  {1}' -f $a.sha256, $a.file
    }

    Write-P9HArtifact -Path (Join-Path $Context.Directory 'SHA256SUMS.txt') -Lines @($lines)
    return @($lines).Count
}

# =====================================================================
# Trial artifact binding (Stage 2.4)
#
# The product trace carries NO trial identity: DevWS emits `event`, `utcMs`,
# `pid` plus per-event data, and nothing else (verified against every
# Write-DevWSLaunchTrace call site). A verdict therefore cannot learn which
# trial a trace belongs to from the trace itself.
#
# The binding is instead RECORDED BY THE COLLECTOR, in the artifact index that
# already exists for every trial (`artifact-index.jsonl`), and VERIFIED before a
# verdict may PASS:
#   * the collector records, per artifact, an explicit role and the SHA-256 of
#     the bytes it captured;
#   * the evaluator re-hashes the same paths at verdict time and requires
#     equality, so a trace (or exit record) swapped in from another trial no
#     longer matches its recorded digest;
#   * the recorded trial identity is the trial directory itself, which is also
#     the identity written into the exit record.
#
# This is deliberately the SAME index used by Write-P9HArtifactIndex, so there
# is exactly one manifest per trial.
# =====================================================================

$script:P9HArtifactRoles = @(
    'fixture'
    'stdout'
    'pre-windows'
    'post-windows'
    'exit-record'
    'new-processes'
    'trace'
)

function Add-P9HArtifactRole {
    # Record one artifact's ROLE, absolute path and digest in the existing
    # artifact index. Collector-authored: no product field is invented.
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet('fixture', 'stdout', 'pre-windows', 'post-windows', 'exit-record', 'new-processes', 'trace')][string]$Role
    )

    $full = if (Test-Path -LiteralPath $Path -PathType Leaf) { (Resolve-Path -LiteralPath $Path).Path } else { [System.IO.Path]::GetFullPath($Path) }
    $present = Test-Path -LiteralPath $Path -PathType Leaf

    $entry = [ordered]@{
        utc     = Get-P9HUtcStamp
        trialId = $Context.TrialId
        role    = $Role
        file    = [System.IO.Path]::GetFileName($Path)
        path    = $full
        bytes   = if ($present) { (Get-Item -LiteralPath $Path).Length } else { $null }
        sha256  = if ($present) { Get-P9HFileSha256 -Path $Path } else { $null }
        present = $present
    }

    Add-P9HArtifactLine -Path (Join-Path $Context.Directory 'artifact-index.jsonl') `
        -Line ($entry | ConvertTo-Json -Compress -Depth 4)

    return $entry
}

function Get-P9HArtifactBinding {
    # Verify that the artifacts a verdict depends on are the ones the collector
    # captured for THIS trial.
    #
    # Stage 2.4.1: integrity is explicit and fail-closed.
    #   * EVERY required role must carry a NONEMPTY trialId that equals the
    #     requested trial. A missing, empty, whitespace or foreign id is a
    #     mismatch - never silently accepted.
    #   * A malformed index line is a HARD failure reported with its line number.
    #     The raw index is preserved as-is; nothing is truncated, rewritten or
    #     repaired.
    #   * The caller's path for each role must equal the recorded path, so a
    #     substituted artifact cannot borrow another artifact's digest.
    param(
        [Parameter(Mandatory)][string]$TrialId,
        [Parameter(Mandatory)][string]$ArtifactIndexPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$RequiredRoles,
        [AllowNull()][hashtable]$ExpectedPaths = $null
    )

    $result = [ordered]@{
        Ok           = $false
        Reason       = $null
        TrialId      = $TrialId
        IndexPresent = $false
        IndexLines   = 0
        BadLines     = @()
        Roles        = @()
        MissingRoles = @()
        Mismatches   = @()
    }

    if ([string]::IsNullOrWhiteSpace($TrialId)) {
        $result.Reason = 'trial-id-missing'
        return [pscustomobject]$result
    }

    if (-not (Test-Path -LiteralPath $ArtifactIndexPath -PathType Leaf)) {
        $result.Reason = 'artifact-index-missing'
        return [pscustomobject]$result
    }
    $result.IndexPresent = $true

    # ---- index integrity: a bad line is a hard failure, not a skip ----
    $rawLines = @(Get-Content -LiteralPath $ArtifactIndexPath)
    $result.IndexLines = $rawLines.Count
    $parsed = [System.Collections.Generic.List[object]]::new()
    $bad = [System.Collections.Generic.List[string]]::new()

    for ($i = 0; $i -lt $rawLines.Count; $i++) {
        $line = $rawLines[$i]
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $rec = $line | ConvertFrom-Json -ErrorAction Stop
            if ($null -eq $rec) { throw 'null record' }
            $parsed.Add($rec) | Out-Null
        }
        catch {
            $bad.Add(('line {0}: {1}' -f ($i + 1), $_.Exception.Message))
        }
    }

    $result.BadLines = @($bad)
    if ($bad.Count -gt 0) {
        $result.Reason = 'artifact-index-malformed:' + (($bad | ForEach-Object { ($_ -split ':')[0] }) -join ',')
        return [pscustomobject]$result
    }

    # Latest entry wins for a role, which is what an append-only index means.
    $byRole = @{}
    foreach ($rec in $parsed) {
        $r = [string](Get-P9HProp -Object $rec -Name 'role')
        if ([string]::IsNullOrWhiteSpace($r)) { continue }
        $byRole[$r] = $rec
    }

    $rows = [System.Collections.Generic.List[object]]::new()
    $missing = [System.Collections.Generic.List[string]]::new()
    $mismatch = [System.Collections.Generic.List[string]]::new()

    foreach ($role in $RequiredRoles) {
        if (-not $byRole.ContainsKey($role)) {
            $missing.Add($role)
            $rows.Add([pscustomobject][ordered]@{ role = $role; status = 'not-recorded'; path = $null; expected = $null; actual = $null })
            continue
        }

        $rec = $byRole[$role]
        $recordedTrial = [string](Get-P9HProp -Object $rec -Name 'trialId')

        # Nonempty AND exactly equal. Whitespace-only is treated as absent.
        if ([string]::IsNullOrWhiteSpace($recordedTrial)) {
            $mismatch.Add(('{0}:trial-missing' -f $role))
            $rows.Add([pscustomobject][ordered]@{ role = $role; status = 'trial-id-missing'; path = $null; expected = $TrialId; actual = $recordedTrial })
            continue
        }

        if (-not [string]::Equals($recordedTrial, $TrialId, [System.StringComparison]::Ordinal)) {
            $mismatch.Add(('{0}:trial={1}' -f $role, $recordedTrial))
            $rows.Add([pscustomobject][ordered]@{ role = $role; status = 'foreign-trial'; path = $null; expected = $TrialId; actual = $recordedTrial })
            continue
        }

        $recordedPath = [string](Get-P9HProp -Object $rec -Name 'path')
        $recordedSha = [string](Get-P9HProp -Object $rec -Name 'sha256')

        if ([string]::IsNullOrWhiteSpace($recordedSha)) {
            $missing.Add(('{0}:no-digest' -f $role))
            $rows.Add([pscustomobject][ordered]@{ role = $role; status = 'no-recorded-digest'; path = $recordedPath; expected = $null; actual = $null })
            continue
        }

        # Path pinning: the caller must be using the artifact the collector bound.
        if ($null -ne $ExpectedPaths -and $ExpectedPaths.ContainsKey($role)) {
            $expectedPath = [string]$ExpectedPaths[$role]
            if (-not [string]::IsNullOrWhiteSpace($expectedPath) -and -not [string]::IsNullOrWhiteSpace($recordedPath)) {
                $expectedFull = [System.IO.Path]::GetFullPath($expectedPath)
                $recordedFull = [System.IO.Path]::GetFullPath($recordedPath)
                if (-not [string]::Equals($expectedFull, $recordedFull, [System.StringComparison]::OrdinalIgnoreCase)) {
                    $mismatch.Add(('{0}:path' -f $role))
                    $rows.Add([pscustomobject][ordered]@{ role = $role; status = 'path-mismatch'; path = $expectedFull; expected = $recordedFull; actual = $expectedFull })
                    continue
                }
            }
        }

        if ([string]::IsNullOrWhiteSpace($recordedPath) -or -not (Test-Path -LiteralPath $recordedPath -PathType Leaf)) {
            $missing.Add(('{0}:file-missing' -f $role))
            $rows.Add([pscustomobject][ordered]@{ role = $role; status = 'file-missing'; path = $recordedPath; expected = $recordedSha; actual = $null })
            continue
        }

        $actual = Get-P9HFileSha256 -Path $recordedPath
        if (-not [string]::Equals($actual, $recordedSha, [System.StringComparison]::Ordinal)) {
            $mismatch.Add(('{0}:digest' -f $role))
            $rows.Add([pscustomobject][ordered]@{ role = $role; status = 'digest-mismatch'; path = $recordedPath; expected = $recordedSha; actual = $actual })
            continue
        }

        $rows.Add([pscustomobject][ordered]@{ role = $role; status = 'verified'; path = $recordedPath; expected = $recordedSha; actual = $actual })
    }

    $result.Roles = @($rows)
    $result.MissingRoles = @($missing)
    $result.Mismatches = @($mismatch)

    if ($missing.Count -gt 0) { $result.Reason = 'binding-incomplete:' + ($missing -join ',') }
    elseif ($mismatch.Count -gt 0) { $result.Reason = 'binding-mismatch:' + ($mismatch -join ',') }
    else { $result.Ok = $true; $result.Reason = 'verified' }

    return [pscustomobject]$result
}