# DevWS P9-H replay instrumentation - trial collector.
#
# Stage 3A. Binds a completed trial's artifacts into the EXISTING
# `artifact-index.jsonl` through the EXISTING `Add-P9HArtifactRole` mechanism.
#
# There is deliberately no second manifest and no new binding rule: Stage 2.4 /
# 2.4.1 froze that contract, and this module only decides WHICH paths fill the
# seven required N2 roles and refuses when one is absent.
#
# TWO DISTINCT PROVENANCE CLASSES
#   * product      - bytes the product itself emitted (trace, stdout, exit
#                    record, window/process inventories, fixture). The collector
#                    records only a role, path and digest; it never writes or
#                    edits these files, and it never invents a product event or
#                    a product trial id.
#   * collector    - metadata the collector authors ABOUT the trial (the role
#                    binding, the E1 observation log reference). This is marked
#                    explicitly so a reviewer can tell an observation made by the
#                    collector from one made by the product.
#
# The E1 observation log is bound as supporting provenance only. It is NOT one
# of the seven N2 roles and can never substitute for N2 evidence.

Set-StrictMode -Version Latest

$script:P9HRequiredN2Roles = @(
    'fixture'
    'stdout'
    'pre-windows'
    'post-windows'
    'exit-record'
    'new-processes'
    'trace'
)

function Get-P9HCollectorRolePlan {
    # The seven required N2 roles, each mapped to an expected path.
    #
    # Returned as data so a caller can inspect or print the contract before
    # touching the index. Order is the frozen contract order.
    param(
        [AllowNull()][string]$FixturePath = $null,
        [AllowNull()][string]$StdoutPath = $null,
        [AllowNull()][string]$PreWindowPath = $null,
        [AllowNull()][string]$PostWindowPath = $null,
        [AllowNull()][string]$ExitRecordPath = $null,
        [AllowNull()][string]$NewProcessPath = $null,
        [AllowNull()][string]$TracePath = $null
    )

    return @(
        [pscustomobject][ordered]@{ Role = 'fixture'; Path = $FixturePath; Provenance = 'product' }
        [pscustomobject][ordered]@{ Role = 'stdout'; Path = $StdoutPath; Provenance = 'product' }
        [pscustomobject][ordered]@{ Role = 'pre-windows'; Path = $PreWindowPath; Provenance = 'product' }
        [pscustomobject][ordered]@{ Role = 'post-windows'; Path = $PostWindowPath; Provenance = 'product' }
        [pscustomobject][ordered]@{ Role = 'exit-record'; Path = $ExitRecordPath; Provenance = 'product' }
        [pscustomobject][ordered]@{ Role = 'new-processes'; Path = $NewProcessPath; Provenance = 'product' }
        [pscustomobject][ordered]@{ Role = 'trace'; Path = $TracePath; Provenance = 'product' }
    )
}

function Assert-P9HCollectorArtifactsPresent {
    # Refuse to bind an incomplete trial.
    #
    # The check runs BEFORE anything is written, so a refusal never leaves a
    # half-populated index that a later verdict could mistake for a complete
    # binding. Every missing role is reported, not just the first.
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Plan
    )

    $missing = [System.Collections.Generic.List[string]]::new()
    $empty = [System.Collections.Generic.List[string]]::new()

    foreach ($item in @($Plan)) {
        $path = [string]$item.Path
        if ([string]::IsNullOrWhiteSpace($path)) {
            $empty.Add([string]$item.Role) | Out-Null
            continue
        }
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $missing.Add([string]$item.Role) | Out-Null
        }
    }

    if ($missing.Count -gt 0 -or $empty.Count -gt 0) {
        $parts = @()
        if ($empty.Count -gt 0) { $parts += ('not-supplied:' + ($empty -join ',')) }
        if ($missing.Count -gt 0) { $parts += ('missing:' + ($missing -join ',')) }
        return [pscustomobject][ordered]@{
            Ok             = $false
            Reason         = 'collector-artifacts-incomplete'
            Detail         = ($parts -join ';')
            MissingRoles   = @($missing)
            NotSuppliedRoles = @($empty)
            BoundRoles     = @()
        }
    }

    return [pscustomobject][ordered]@{
        Ok             = $true
        Reason         = 'ok'
        Detail         = $null
        MissingRoles   = @()
        NotSuppliedRoles = @()
        BoundRoles     = @()
    }
}

function Add-P9HCollectorArtifactRoles {
    # Bind all seven required N2 roles into the trial's existing index.
    #
    # Uses Add-P9HArtifactRole unchanged, so the resulting index is exactly the
    # one the Stage 2.4.1 provenance gate verifies - same schema, same digests,
    # same append-only semantics, same trialId.
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Plan,
        [AllowNull()][string]$ObservationLogPath = $null
    )

    $precheck = Assert-P9HCollectorArtifactsPresent -Plan $Plan
    if (-not $precheck.Ok) { return $precheck }

    $rows = [System.Collections.Generic.List[object]]::new()

    foreach ($item in @($Plan)) {
        $entry = Add-P9HArtifactRole -Context $Context -Path ([string]$item.Path) -Role ([string]$item.Role)
        $rows.Add([pscustomobject][ordered]@{
                role       = [string]$item.Role
                provenance = [string]$item.Provenance
                path       = [string]$entry.path
                sha256     = [string]$entry.sha256
                bytes      = $entry.bytes
            }) | Out-Null
    }

    # Supporting E1 provenance goes to a SEPARATE, explicitly-named index.
    #
    # It is deliberately NOT written into artifact-index.jsonl: that index has a
    # closed seven-role contract (`Add-P9HArtifactRole` validates the role set),
    # and widening it would be exactly the contract change this stage forbids.
    # A separate file also makes substitution structurally impossible - nothing
    # that reads the N2 index can ever observe an E1 record.
    $observationBound = $false
    $observationPath = $null
    if (-not [string]::IsNullOrWhiteSpace($ObservationLogPath)) {
        if (Test-Path -LiteralPath $ObservationLogPath -PathType Leaf) {
            $observationPath = Join-Path $Context.Directory 'e1-observation-index.jsonl'
            $entry = [ordered]@{
                utc        = Get-P9HUtcStamp
                trialId    = [string]$Context.TrialId
                role       = 'e1-observation-log'
                provenance = 'collector'
                kind       = 'supporting-provenance'
                file       = [System.IO.Path]::GetFileName($ObservationLogPath)
                path       = (Resolve-Path -LiteralPath $ObservationLogPath).Path
                bytes      = (Get-Item -LiteralPath $ObservationLogPath).Length
                sha256     = Get-P9HFileSha256 -Path $ObservationLogPath
            }
            Add-P9HArtifactLine -Path $observationPath -Line ($entry | ConvertTo-Json -Compress -Depth 4)
            $rows.Add([pscustomobject][ordered]@{
                    role       = 'e1-observation-log'
                    provenance = 'collector'
                    path       = [string]$entry.path
                    sha256     = [string]$entry.sha256
                    bytes      = $entry.bytes
                }) | Out-Null
            $observationBound = $true
        }
    }

    return [pscustomobject][ordered]@{
        Ok             = $true
        Reason         = 'ok'
        Detail         = $null
        MissingRoles   = @()
        NotSuppliedRoles = @()
        BoundRoles     = @($rows)
        ObservationLogBound = $observationBound
        ObservationIndexPath = $observationPath
        N2RoleCount    = @($rows | Where-Object { $script:P9HRequiredN2Roles -contains $_.role }).Count
    }
}

function Test-P9HCollectorBinding {
    # Verify this collector's own binding with the FROZEN Stage 2.4.1 gate.
    #
    # This is a convenience wrapper, not a second implementation: it calls
    # Get-P9HArtifactBinding with the same seven roles and the same paths, so a
    # collector that bound the wrong artifact fails exactly as an evaluator would
    # report it.
    param(
        [Parameter(Mandatory)][string]$TrialId,
        [Parameter(Mandatory)][string]$ArtifactIndexPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Plan
    )

    $expected = @{}
    foreach ($item in @($Plan)) {
        $expected[[string]$item.Role] = [string]$item.Path
    }

    return Get-P9HArtifactBinding -TrialId $TrialId -ArtifactIndexPath $ArtifactIndexPath `
        -RequiredRoles $script:P9HRequiredN2Roles -ExpectedPaths $expected
}

function New-P9HCollectorManifest {
    # Describe what the collector recorded, separated by provenance class.
    #
    # Explicitly distinguishes collector-recorded metadata from native product
    # observations, which is what a reviewer needs to see. This is a report, not
    # evidence: it is never consumed by a verdict.
    param(
        [Parameter(Mandatory)]$Context,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$BoundRoles,
        [AllowNull()][object]$WtsCapability = $null,
        [AllowNull()][string]$ObservationLogPath = $null
    )

    $product = @($BoundRoles | Where-Object { $_.provenance -eq 'product' })
    $collector = @($BoundRoles | Where-Object { $_.provenance -eq 'collector' })

    return [pscustomobject][ordered]@{
        schema            = 'p9h.collector-manifest.v1'
        stage             = '3A'
        trialId           = [string]$Context.TrialId
        utc               = Get-P9HUtcStamp
        requiredN2Roles   = @($script:P9HRequiredN2Roles)
        productArtifacts  = @($product)
        collectorMetadata = @($collector)
        observationLogPath = $ObservationLogPath
        wtsCapability     = $WtsCapability
        note              = 'Product artifacts are bound by role/path/digest only; the collector never rewrites their bytes, invents product events, or invents a product trial id. The E1 observation log is supporting provenance and is never counted as an N2 role.'
    }
}
