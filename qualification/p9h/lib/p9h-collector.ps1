# DevWS P9-H replay instrumentation - trial collector.
#
# Stage 3A. Binds a completed trial's artifacts into the EXISTING
# `artifact-index.jsonl` through the EXISTING `Add-P9HArtifactRole` mechanism.
#
# There is deliberately no second manifest and no new binding rule: Stage 2.4 /
# 2.4.1 froze that contract, and this module only decides WHICH paths fill the
# seven required N2 roles and refuses when one is absent.
#
# ARTIFACT ORIGIN vs CAPTURE (Stage 3A.1 correction)
#   Stage 3A labelled all seven N2 roles "product", which is factually wrong: the
#   exit record is written by the qualification recorder, the window and process
#   inventories are OS facts the qualification tooling observes, and the fixture
#   is a qualification-defined input. The model below separates WHO PRODUCED the
#   observation from WHO CAPTURED it:
#
#     origin      - the authority that produced the file's content
#                   fixture | product | operating-system | qualification
#     capturedBy  - the component that wrote the artifact into the trial
#                   qualification-launcher | qualification-recorder |
#                   qualification-observer | qualification-collector
#
#   This is a REPORTING correction only. The seven required roles, their
#   SHA-256 binding, and their acceptance meaning are unchanged, and nothing in
#   a verdict reads these fields.
#
#   * The trace and stdout are product-generated; qualification only captures
#     them. The collector records role/path/digest and never edits the bytes.
#   * Window and process inventories are operating-system facts observed by the
#     qualification tooling: neither "product" nor "collector" describes them.
#   * The exit record is authored by the qualification recorder, so describing it
#     as a product-generated file would be inaccurate.
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

# Closed vocabularies, so a typo cannot silently introduce a new category.
$script:P9HArtifactOrigins = @(
    'fixture'
    'product'
    'operating-system'
    'qualification'
)

$script:P9HArtifactCapturers = @(
    'qualification-launcher'
    'qualification-recorder'
    'qualification-observer'
    'qualification-capture'
    'qualification-collector'
)

function Get-P9HArtifactOriginModel {
    # The authoritative role -> origin/capturedBy mapping.
    #
    # Returned as data so the plan, the manifest and the tests all read ONE
    # table instead of restating the classification in three places.
    return @(
        [pscustomobject][ordered]@{
            Role = 'fixture'; Origin = 'fixture'; CapturedBy = 'qualification-launcher'
            Why = 'qualification-defined input describing the intended layout state'
        }
        [pscustomobject][ordered]@{
            Role = 'stdout'; Origin = 'product'; CapturedBy = 'qualification-launcher'
            Why = 'product output captured by the qualification launcher'
        }
        [pscustomobject][ordered]@{
            Role = 'pre-windows'; Origin = 'operating-system'; CapturedBy = 'qualification-observer'
            Why = 'pre-launch window inventory: an OS fact observed by qualification'
        }
        [pscustomobject][ordered]@{
            Role = 'post-windows'; Origin = 'operating-system'; CapturedBy = 'qualification-observer'
            Why = 'post-launch window inventory: an OS fact observed by qualification'
        }
        [pscustomobject][ordered]@{
            Role = 'exit-record'; Origin = 'qualification'; CapturedBy = 'qualification-recorder'
            Why = 'lifecycle exit record authored by the qualification recorder'
        }
        [pscustomobject][ordered]@{
            Role = 'new-processes'; Origin = 'operating-system'; CapturedBy = 'qualification-observer'
            Why = 'new-process inventory: an OS fact observed by qualification'
        }
        [pscustomobject][ordered]@{
            Role = 'trace'; Origin = 'product'; CapturedBy = 'qualification-capture'
            Why = 'product-generated events captured by qualification tooling'
        }
    )
}

function Get-P9HArtifactOriginForRole {
    # Look up the origin model for one role.
    param([Parameter(Mandatory)][string]$Role)

    $match = @((Get-P9HArtifactOriginModel) | Where-Object { $_.Role -eq $Role })
    if ($match.Count -ne 1) {
        return [pscustomobject][ordered]@{
            Role = $Role; Origin = $null; CapturedBy = $null
            Why = 'unclassified role'; Known = $false
        }
    }

    return [pscustomobject][ordered]@{
        Role = $match[0].Role
        Origin = $match[0].Origin
        CapturedBy = $match[0].CapturedBy
        Why = $match[0].Why
        Known = $true
    }
}

function Get-P9HCollectorRolePlan {
    # The seven required N2 roles, each mapped to an expected path and its
    # accurate origin/capturedBy classification.
    #
    # Returned as data so a caller can inspect or print the contract before
    # touching the index. Order is the frozen contract order. The origin fields
    # come from the single origin model, so the plan and the manifest can never
    # disagree about who produced an artifact.
    param(
        [AllowNull()][string]$FixturePath = $null,
        [AllowNull()][string]$StdoutPath = $null,
        [AllowNull()][string]$PreWindowPath = $null,
        [AllowNull()][string]$PostWindowPath = $null,
        [AllowNull()][string]$ExitRecordPath = $null,
        [AllowNull()][string]$NewProcessPath = $null,
        [AllowNull()][string]$TracePath = $null
    )

    $paths = [ordered]@{
        'fixture'       = $FixturePath
        'stdout'        = $StdoutPath
        'pre-windows'   = $PreWindowPath
        'post-windows'  = $PostWindowPath
        'exit-record'   = $ExitRecordPath
        'new-processes' = $NewProcessPath
        'trace'         = $TracePath
    }

    $plan = [System.Collections.Generic.List[object]]::new()
    foreach ($role in $script:P9HRequiredN2Roles) {
        $origin = Get-P9HArtifactOriginForRole -Role $role
        $plan.Add([pscustomobject][ordered]@{
                Role       = $role
                Path       = $paths[$role]
                Origin     = $origin.Origin
                CapturedBy = $origin.CapturedBy
                OriginNote = $origin.Why
            }) | Out-Null
    }

    return @($plan)
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
        $origin = Get-P9HArtifactOriginForRole -Role ([string]$item.Role)
        $entry = Add-P9HArtifactRole -Context $Context -Path ([string]$item.Path) -Role ([string]$item.Role)
        $rows.Add([pscustomobject][ordered]@{
                role       = [string]$item.Role
                origin      = $origin.Origin
                capturedBy  = $origin.CapturedBy
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
                origin     = 'qualification'
                capturedBy = 'qualification-observer'
                kind       = 'supporting-provenance'
                file       = [System.IO.Path]::GetFileName($ObservationLogPath)
                path       = (Resolve-Path -LiteralPath $ObservationLogPath).Path
                bytes      = (Get-Item -LiteralPath $ObservationLogPath).Length
                sha256     = Get-P9HFileSha256 -Path $ObservationLogPath
            }
            Add-P9HArtifactLine -Path $observationPath -Line ($entry | ConvertTo-Json -Compress -Depth 4)
            $rows.Add([pscustomobject][ordered]@{
                    role       = 'e1-observation-log'
                    origin     = 'qualification'
                    capturedBy = 'qualification-observer'
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

    # Group by WHO PRODUCED the content, then report who captured it. A reviewer
    # can therefore tell a product-generated trace from a qualification-authored
    # exit record without inferring it from a role name.
    $byOrigin = [ordered]@{}
    foreach ($originName in $script:P9HArtifactOrigins) {
        $byOrigin[$originName] = @($BoundRoles | Where-Object { $_.origin -eq $originName })
    }

    # Per-role classification, so the report is explicit rather than aggregated.
    $roleClassification = @(foreach ($role in $script:P9HRequiredN2Roles) {
            $model = Get-P9HArtifactOriginForRole -Role $role
            $bound = @($BoundRoles | Where-Object { $_.role -eq $role }) | Select-Object -First 1
            [pscustomobject][ordered]@{
                role       = $role
                origin     = $model.Origin
                capturedBy = $model.CapturedBy
                why        = $model.Why
                sha256     = if ($bound) { [string]$bound.sha256 } else { $null }
            }
        })

    $supporting = @($BoundRoles | Where-Object { $script:P9HRequiredN2Roles -notcontains $_.role })

    return [pscustomobject][ordered]@{
        schema             = 'p9h.collector-manifest.v2'
        stage              = '3A.1'
        trialId            = [string]$Context.TrialId
        utc                = Get-P9HUtcStamp
        requiredN2Roles    = @($script:P9HRequiredN2Roles)
        originVocabulary   = @($script:P9HArtifactOrigins)
        capturerVocabulary = @($script:P9HArtifactCapturers)
        roleClassification = @($roleClassification)
        byOrigin           = [pscustomobject]$byOrigin
        supportingProvenance = @($supporting)
        observationLogPath = $ObservationLogPath
        wtsCapability      = $WtsCapability
        note               = 'Origin names who produced the content; capturedBy names the qualification component that wrote it. Product-origin artifacts (stdout, trace) are bound by role/path/digest only: the collector never rewrites their bytes, invents product events, or invents a product trial id. The exit record is qualification-authored, not product-generated. The E1 observation log is supporting provenance and is never counted as an N2 role.'
    }
}
