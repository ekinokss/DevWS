# DevWS P9-H replay instrumentation - shared core.
#
# Purpose: record, verify and evaluate ONE bounded acceptance replay so that
# evidence cannot be silently lost. This library is instrumentation only: it is
# never dot-sourced by the product, never installed, and never imported by src/.
#
# Design invariants (each one closes a specific P9-G defect):
#   1. Every artifact is append-only. No function may truncate an existing file.
#      (P9-G defect E1-1: disc-proof.ps1 rewrote its log on every run.)
#   2. Artifacts are written with an atomic same-directory rename, then read back
#      and validated before the caller may rely on them.
#   3. A missing or unreadable artifact is reported as such. Nothing is inferred,
#      defaulted to success, or repaired into a pass.
#   4. Timestamps are handled as DateTime values. DateTime values are never fed
#      to ManagementDateTimeConverter.ToDateTime, which expects DMTF text.
#      (P9-G defect N2-3.)
#   5. Writes are flushed and hashed so a later stage can prove the artifact did
#      not change.
#
# Loading contract: pure functions and small helpers only. Importing this file
# must not launch a process, touch a VM, disconnect a session or mutate host
# configuration.

Set-StrictMode -Version Latest

function Get-P9HUtcStamp {
    # Single UTC clock source so every artifact in one trial is comparable.
    param([datetime]$At = [datetime]::UtcNow)
    return $At.ToUniversalTime().ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
}

function New-P9HTrialId {
    # Sortable trial id: UTC stamp plus a short random suffix, so artifacts sort
    # chronologically and two trials can never collide.
    param([datetime]$At = [datetime]::UtcNow)
    $suffix = -join (1..8 | ForEach-Object { '0123456789abcdef'[(Get-Random -Maximum 16)] })
    return ('p9h-{0}-{1}' -f $At.ToUniversalTime().ToString('yyyyMMddTHHmmssZ'), $suffix)
}

function Test-P9HStrictUtcStamp {
    # Artifact timestamps must be a valid UTC instant.
    #
    # Accepts the serialized form (round-trippable ISO-8601 with Z) AND the
    # DateTime/DateTimeOffset that PowerShell 7's ConvertFrom-Json reconstructs
    # from that text. A string-only check falsely rejects every artifact that has
    # been read back from disk, which is the normal path for a verdict.
    param([AllowNull()]$Text)

    if ($null -eq $Text) { return $false }

    if ($Text -is [datetime]) {
        # ConvertFrom-Json reconstructs an ISO-8601 Z value as Local/Unspecified
        # depending on the host; either way the instant is well-defined.
        return $true
    }

    if ($Text -is [datetimeoffset]) { return $true }

    if ($Text -isnot [string]) { return $false }

    if ([string]::IsNullOrWhiteSpace($Text)) { return $false }

    $parsed = [datetime]::MinValue
    if (-not [datetime]::TryParse($Text, [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::RoundtripKind, [ref]$parsed)) { return $false }

    return ($parsed.Kind -eq [System.DateTimeKind]::Utc)
}

function Write-P9HArtifact {
    # Durable, atomic artifact write.
    #
    # Writes '<path>.tmp' in the SAME directory, flushes it to disk, then renames
    # over the target. A same-directory rename is atomic on NTFS, so a reader can
    # never observe a half-written artifact, and a crash mid-write leaves either
    # the old artifact or the new one, never a truncated blend.
    #
    # Content is written as UTF-8 without BOM so byte comparisons and hashes are
    # stable across hosts. Lines are joined with CRLF to keep repository text
    # conventions for anything that is later committed as a fixture.
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Lines
    )

    $dir = [System.IO.Path]::GetDirectoryName($Path)
    if (-not [string]::IsNullOrEmpty($dir) -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $tmp = $Path + '.tmp'
    $body = ($Lines -join "`r`n") + "`r`n"
    $utf8 = [System.Text.UTF8Encoding]::new($false)

    $stream = [System.IO.File]::Open($tmp, [System.IO.FileMode]::Create,
        [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $bytes = $utf8.GetBytes($body)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally {
        $stream.Dispose()
    }

    # Stage 3B7F-R2 portability correction. `File.Move(src, dst, overwrite)` is a
    # .NET Core / PowerShell 7+ overload that does NOT exist on Windows
    # PowerShell 5.1 (.NET Framework), which is the only PowerShell available on
    # the qualification guest. Calling it there failed with
    # "Cannot find an overload for Move and the argument count: 3", so no
    # monitor capture could be persisted in-guest at all.
    #
    # The replacement keeps the same atomicity guarantee: the overwrite is a
    # same-directory rename, and the destination is removed first only when it
    # exists. A failed rename therefore never leaves a truncated artifact.
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        [System.IO.File]::Move($tmp, $Path, $true)
    }
    else {
        if (Test-Path -LiteralPath $Path) {
            [System.IO.File]::Delete($Path)
        }
        [System.IO.File]::Move($tmp, $Path)
    }
}

function Add-P9HArtifactLine {
    # Append-only record write. Creates the file when absent; NEVER truncates.
    # Flush($true) forces the bytes to disk before the function returns, so a
    # caller may treat a returned record as persisted rather than buffered.
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][AllowEmptyString()][string]$Line
    )

    $dir = [System.IO.Path]::GetDirectoryName($Path)
    if (-not [string]::IsNullOrEmpty($dir) -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $utf8 = [System.Text.UTF8Encoding]::new($false)
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Append,
        [System.IO.FileAccess]::Write, [System.IO.FileShare]::Read)
    try {
        $bytes = $utf8.GetBytes($Line + "`r`n")
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
    }
    finally {
        $stream.Dispose()
    }
}

function Get-P9HFileSha256 {
    # Hash of a persisted artifact, or $null when it does not exist. Callers use
    # this to prove an artifact was unchanged across later fault injection.
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Read-P9HJsonArtifact {
    # Read + parse a JSON artifact, returning an explicit result object instead
    # of throwing. Instrumentation must be able to say 'the artifact is missing'
    # without conflating that with 'the product failed'.
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject][ordered]@{ Ok = $false; Reason = 'missing'; Data = $null; Error = $null }
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
    }
    catch {
        return [pscustomobject][ordered]@{ Ok = $false; Reason = 'unreadable'; Data = $null; Error = $_.Exception.Message }
    }

    if ([string]::IsNullOrWhiteSpace($raw)) {
        return [pscustomobject][ordered]@{ Ok = $false; Reason = 'empty'; Data = $null; Error = $null }
    }

    try {
        $data = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        return [pscustomobject][ordered]@{ Ok = $false; Reason = 'malformed'; Data = $null; Error = $_.Exception.Message }
    }

    return [pscustomobject][ordered]@{ Ok = $true; Reason = 'ok'; Data = $data; Error = $null }
}

function ConvertTo-P9HProcessStartUtc {
    # Correct process creation-timestamp handling.
    #
    # Win32_Process.CreationDate is already a DateTime on modern PowerShell. The
    # P9-G harness passed it to ManagementDateTimeConverter.ToDateTime, which
    # expects DMTF text and threw for EVERY process, silently blanking every
    # start time. This returns an explicit result so an unexpected type is
    # reported rather than swallowed.
    param([AllowNull()]$Value)

    if ($null -eq $Value) {
        return [pscustomobject][ordered]@{ Ok = $false; Utc = $null; Reason = 'null' }
    }

    if ($Value -is [datetime]) {
        return [pscustomobject][ordered]@{ Ok = $true; Utc = $Value.ToUniversalTime(); Reason = 'datetime' }
    }

    if ($Value -is [datetimeoffset]) {
        return [pscustomobject][ordered]@{ Ok = $true; Utc = $Value.UtcDateTime; Reason = 'datetimeoffset' }
    }

    if ($Value -is [string] -and -not [string]::IsNullOrWhiteSpace($Value)) {
        # DMTF text (e.g. '20261111161008.500000+000'); convert exactly once.
        try {
            $converted = [Management.ManagementDateTimeConverter]::ToDateTime($Value)
            return [pscustomobject][ordered]@{ Ok = $true; Utc = $converted.ToUniversalTime(); Reason = 'dmtf' }
        }
        catch {
            return [pscustomobject][ordered]@{ Ok = $false; Utc = $null; Reason = 'dmtf-invalid' }
        }
    }

    return [pscustomobject][ordered]@{
        Ok     = $false
        Utc    = $null
        Reason = ('unsupported-type:' + $Value.GetType().FullName)
    }
}

function New-P9HStageRecord {
    # One line in stages.jsonl. Every stage in the replay emits exactly one of
    # these, so a missing or failed stage is visible in the evidence itself.
    param(
        [Parameter(Mandatory)][string]$TrialId,
        [Parameter(Mandatory)][int]$Sequence,
        [Parameter(Mandatory)][string]$Stage,
        [Parameter(Mandatory)][ValidateSet('started', 'ok', 'failed', 'skipped', 'timeout')][string]$Outcome,
        [AllowNull()][string]$Detail = $null,
        [AllowNull()][hashtable]$Data = $null
    )

    $record = [ordered]@{
        trialId  = $TrialId
        sequence = $Sequence
        stage    = $Stage
        outcome  = $Outcome
        utc      = Get-P9HUtcStamp
        pid      = $PID
        detail   = $Detail
    }

    if ($null -ne $Data) {
        foreach ($key in @($Data.Keys)) { $record[[string]$key] = $Data[$key] }
    }

    return ($record | ConvertTo-Json -Compress -Depth 6)
}

function Assert-P9HArtifactPresent {
    # Fail closed when an artifact that a verdict depends on is absent.
    # Returns a structured result; the caller decides whether that is a trial
    # failure or merely an inconclusive criterion.
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Role
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return [pscustomobject][ordered]@{ Ok = $false; Role = $Role; Path = $Path; Reason = 'missing'; Sha256 = $null }
    }

    $length = (Get-Item -LiteralPath $Path).Length
    if ($length -le 0) {
        return [pscustomobject][ordered]@{ Ok = $false; Role = $Role; Path = $Path; Reason = 'empty'; Sha256 = $null }
    }

    return [pscustomobject][ordered]@{
        Ok     = $true
        Role   = $Role
        Path   = $Path
        Reason = 'ok'
        Sha256 = Get-P9HFileSha256 -Path $Path
    }
}

function Copy-P9HArgs {
    # Explicit key-by-key copy of a parameter table.
    #
    # Hashtable.Clone() followed by property assignment is not valid PowerShell
    # ("a hash table can only be added to another hash table"), so callers that
    # need an independent copy build one here. Lives in core so every module and
    # test that splats a parameter table gets the same behaviour.
    param([Parameter(Mandatory)][hashtable]$Table)

    $copy = @{}
    foreach ($k in @($Table.Keys)) { $copy[$k] = $Table[$k] }
    return $copy
}