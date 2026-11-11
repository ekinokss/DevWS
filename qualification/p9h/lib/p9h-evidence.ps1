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
