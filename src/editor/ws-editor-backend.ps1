# DevWS v0.4 P6 read-only editor backend.
#
# Normal-integrity, stdin/stdout JSON Lines protocol host. This file deliberately
# loads only the six approved DevWS libraries plus the local projection helper.
# It performs no configuration writes, no worker/broker/coordinator contact, and
# no live-window operations. P6 adds authoritative `preview`; P5 added structural `validate` and authoritative
# relative-geometry `convert`; `save` and `preview` remain unimplemented.

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:Protocol = 'devws-editor/1'
$script:BackendVersion = '0.4.0-p6'
$script:MaxRequestBytes = 4194304
$script:MaxResponseBytes = 16777216
$script:MaxJsonDepth = 32
$script:MaxConfigBytes = 4194304
$script:SupportedOps = @('hello', 'inspect', 'read-config', 'project', 'validate', 'preview', 'convert', 'shutdown')
$script:UnsupportedOps = @('save')

[Console]::InputEncoding = [System.Text.UTF8Encoding]::new($false, $true)
[Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false)
$OutputEncoding = [Console]::OutputEncoding

$editorRoot = $PSScriptRoot
$libRoot = Join-Path (Split-Path $editorRoot -Parent) 'lib'

foreach ($library in @(
    'devws-paths.ps1',
    'devws-config.ps1',
    'devws-native.ps1',
    'devws-monitor.ps1',
    'devws-relative-layout.ps1',
    'devws-layout-profile.ps1'
)) {
    $libraryPath = Join-Path $libRoot $library

    if (-not (Test-Path -LiteralPath $libraryPath -PathType Leaf)) {
        throw "Required editor backend library is missing: $libraryPath"
    }

    . $libraryPath
}

. (Join-Path $editorRoot 'editor-projection.ps1')

$script:Stdin = [Console]::OpenStandardInput()
$script:ReadChunk = [byte[]]::new(65536)
$script:ReadChunkOffset = 0
$script:ReadChunkCount = 0
$script:SeenRequestIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)

function New-EditorError {
    param(
        [Parameter(Mandatory)][string]$Code,
        [Parameter(Mandatory)][string]$Message,
        [bool]$Retryable = $false,
        $Details = $null
    )

    $errorObject = [ordered]@{
        code      = $Code
        message   = $Message
        retryable = $Retryable
    }

    if ($null -ne $Details) {
        $errorObject['details'] = $Details
    }

    return [pscustomobject]$errorObject
}

function Write-EditorResponse {
    param(
        $Id,
        $Op,
        [bool]$Ok,
        $Result = $null,
        [object[]]$Warnings = @(),
        $ErrorObject = $null
    )

    $response = [ordered]@{
        protocol = $script:Protocol
        id       = $Id
        ok       = $Ok
        op       = $Op
        result   = $Result
        warnings = @($Warnings)
        error    = $ErrorObject
    }

    $json = $response | ConvertTo-Json -Compress -Depth $script:MaxJsonDepth
    $byteCount = [System.Text.Encoding]::UTF8.GetByteCount($json)

    if ($byteCount -gt $script:MaxResponseBytes) {
        $fallback = [ordered]@{
            protocol = $script:Protocol
            id       = $Id
            ok       = $false
            op       = $Op
            result   = $null
            warnings = @()
            error    = New-EditorError -Code 'response-too-large' -Message "The response exceeded $($script:MaxResponseBytes) bytes." -Details ([ordered]@{ byteCount = $byteCount })
        }
        $json = $fallback | ConvertTo-Json -Compress -Depth 8
    }

    [Console]::Out.WriteLine($json)
    [Console]::Out.Flush()
}

function Read-EditorRequestLine {
    # Byte-bounded chunked line reader. The 4 MiB cap is enforced before a line
    # can be accumulated past the limit, and chunks keep maximum-size requests
    # well inside the protocol read-timeout budget.
    $line = [System.IO.MemoryStream]::new()
    $sawAny = $false

    while ($true) {
        if ($script:ReadChunkOffset -ge $script:ReadChunkCount) {
            $script:ReadChunkCount = $script:Stdin.Read($script:ReadChunk, 0, $script:ReadChunk.Length)
            $script:ReadChunkOffset = 0

            if ($script:ReadChunkCount -le 0) {
                if (-not $sawAny -and $line.Length -eq 0) {
                    $line.Dispose()
                    return $null
                }

                break
            }
        }

        $available = $script:ReadChunkCount - $script:ReadChunkOffset
        $newlineIndex = [System.Array]::IndexOf($script:ReadChunk, [byte]10, $script:ReadChunkOffset, $available)

        if ($newlineIndex -ge 0) {
            $take = $newlineIndex - $script:ReadChunkOffset
            $contentLength = $line.Length + $take

            # A CR immediately before LF is a line terminator, not content. The
            # CR may be in this chunk or at the end of the previous chunk.
            if ($take -gt 0) {
                if ($script:ReadChunk[$newlineIndex - 1] -eq 13) {
                    $contentLength--
                }
            }
            elseif ($line.Length -gt 0 -and $line.GetBuffer()[$line.Length - 1] -eq 13) {
                $contentLength--
            }

            if ($contentLength -gt $script:MaxRequestBytes) {
                $line.Dispose()
                return [pscustomobject]@{ TooLarge = $true; InvalidUtf8 = $false; Line = $null }
            }

            if ($take -gt 0) {
                $line.Write($script:ReadChunk, $script:ReadChunkOffset, $take)
            }

            $script:ReadChunkOffset = $newlineIndex + 1
            $sawAny = $true
            break
        }

        $take = $available
        $contentTake = $take

        # Allow one trailing CR to span a chunk boundary before its LF.
        if ($take -gt 0 -and $script:ReadChunk[$script:ReadChunkOffset + $take - 1] -eq 13) {
            $contentTake = $take - 1
        }

        if ($line.Length + $contentTake -gt $script:MaxRequestBytes) {
            $line.Dispose()
            return [pscustomobject]@{ TooLarge = $true; InvalidUtf8 = $false; Line = $null }
        }

        if ($take -gt 0) {
            $line.Write($script:ReadChunk, $script:ReadChunkOffset, $take)
        }

        $script:ReadChunkOffset = $script:ReadChunkCount
        $sawAny = $true
    }

    if ($line.Length -gt 0 -and $line.GetBuffer()[$line.Length - 1] -eq 13) {
        $line.SetLength($line.Length - 1)
    }

    $bytes = $line.ToArray()
    $line.Dispose()

    try {
        $text = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    }
    catch {
        return [pscustomobject]@{ TooLarge = $false; InvalidUtf8 = $true; Line = $null }
    }

    return [pscustomobject]@{ TooLarge = $false; InvalidUtf8 = $false; Line = $text }
}

function Test-EditorEnvelope {
    param($Request)

    if ($null -eq $Request -or $Request -isnot [System.Management.Automation.PSCustomObject]) {
        return New-EditorError -Code 'request-invalid' -Message 'The request must be a JSON object.'
    }

    $names = @($Request.PSObject.Properties.Name)
    $allowed = @('protocol', 'id', 'op', 'params')
    $unknown = @($names | Where-Object { $_ -notin $allowed })

    if ($unknown.Count -gt 0) {
        return New-EditorError -Code 'request-invalid' -Message "Unknown request field(s): $($unknown -join ', ')."
    }

    foreach ($required in $allowed) {
        if ($names -notcontains $required) {
            return New-EditorError -Code 'request-invalid' -Message "Missing request field '$required'."
        }
    }

    if ($Request.protocol -isnot [string] -or $Request.protocol -cne $script:Protocol) {
        return New-EditorError -Code 'protocol-version-unsupported' -Message "Unsupported protocol '$($Request.protocol)'; expected '$($script:Protocol)'."
    }

    if ($Request.id -isnot [string] -or $Request.id -notmatch '^[A-Za-z0-9._-]{1,64}$') {
        return New-EditorError -Code 'request-invalid' -Message "Request 'id' must be 1-64 characters from [A-Za-z0-9._-]."
    }

    if ($Request.op -isnot [string] -or [string]::IsNullOrWhiteSpace($Request.op)) {
        return New-EditorError -Code 'request-invalid' -Message "Request 'op' must be a non-empty string."
    }

    if ($null -eq $Request.params -or $Request.params -isnot [System.Management.Automation.PSCustomObject]) {
        return New-EditorError -Code 'request-invalid' -Message "Request 'params' must be a JSON object."
    }

    return $null
}

function Test-EditorParams {
    param(
        [string]$Op,
        $Params
    )

    $names = @($Params.PSObject.Properties | ForEach-Object { [string]$_.Name })

    if ($Op -in @('hello', 'inspect', 'shutdown')) {
        if ($names.Count -gt 0) {
            return New-EditorError -Code 'request-invalid' -Message "Operation '$Op' does not accept parameters."
        }
        return $null
    }

    if ($Op -eq 'read-config') {
        $unknown = @($names | Where-Object { $_ -ne 'expectedSha256' })
        if ($unknown.Count -gt 0) {
            return New-EditorError -Code 'request-invalid' -Message "Unknown read-config parameter(s): $($unknown -join ', ')."
        }
        if ($names -notcontains 'expectedSha256') {
            return New-EditorError -Code 'request-invalid' -Message "read-config requires 'expectedSha256'."
        }
        if ($Params.expectedSha256 -isnot [string] -or $Params.expectedSha256 -notmatch '^[0-9a-f]{64}$') {
            return New-EditorError -Code 'request-invalid' -Message "read-config 'expectedSha256' must be 64 lowercase hexadecimal characters."
        }
        return $null
    }

    if ($Op -eq 'project') {
        $unknown = @($names | Where-Object { $_ -ne 'setId' })
        if ($unknown.Count -gt 0) {
            return New-EditorError -Code 'request-invalid' -Message "Unknown project parameter(s): $($unknown -join ', ')."
        }
        if ($names -contains 'setId' -and ($Params.setId -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Params.setId))) {
            return New-EditorError -Code 'request-invalid' -Message "project 'setId' must be a non-empty string when supplied."
        }
        return $null
    }

    if ($Op -eq 'preview') {
        $unknown = @($names | Where-Object { $_ -notin @('draft', 'baseSha256', 'setId', 'baseTopologyFingerprint') })
        if ($unknown.Count -gt 0) {
            return New-EditorError -Code 'request-invalid' -Message "Unknown preview parameter(s): $($unknown -join ', ')."
        }
        if ($names -notcontains 'draft' -or $Params.draft -isnot [System.Management.Automation.PSCustomObject]) {
            return New-EditorError -Code 'request-invalid' -Message "preview requires a 'draft' JSON object."
        }
        if ($names -notcontains 'baseSha256' -or $Params.baseSha256 -isnot [string] -or $Params.baseSha256 -notmatch '^[0-9a-f]{64}$') {
            return New-EditorError -Code 'request-invalid' -Message "preview 'baseSha256' must be 64 lowercase hexadecimal characters."
        }
        if ($names -contains 'setId' -and ($Params.setId -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Params.setId))) {
            return New-EditorError -Code 'request-invalid' -Message "preview 'setId' must be a non-empty string when supplied."
        }
        if ($names -contains 'baseTopologyFingerprint' -and ($Params.baseTopologyFingerprint -isnot [string] -or $Params.baseTopologyFingerprint -notmatch '^[0-9A-Fa-f]{64}$')) {
            return New-EditorError -Code 'request-invalid' -Message "preview 'baseTopologyFingerprint' must be 64 hexadecimal characters."
        }

        $draftBytes = [System.Text.Encoding]::UTF8.GetByteCount(($Params.draft | ConvertTo-Json -Compress -Depth $script:MaxJsonDepth))
        if ($draftBytes -gt $script:MaxConfigBytes) {
            return New-EditorError -Code 'request-invalid' -Message "The preview draft is $draftBytes bytes; the limit is $($script:MaxConfigBytes) bytes." -Details ([ordered]@{ sizeBytes = $draftBytes })
        }

        return $null
    }

    if ($Op -eq 'validate') {
        $unknown = @($names | Where-Object { $_ -ne 'draft' })
        if ($unknown.Count -gt 0) {
            return New-EditorError -Code 'request-invalid' -Message "Unknown validate parameter(s): $($unknown -join ', ')."
        }
        if ($names -notcontains 'draft' -or $Params.draft -isnot [System.Management.Automation.PSCustomObject]) {
            return New-EditorError -Code 'request-invalid' -Message "validate requires a 'draft' JSON object."
        }

        $draftBytes = [System.Text.Encoding]::UTF8.GetByteCount(($Params.draft | ConvertTo-Json -Compress -Depth $script:MaxJsonDepth))
        if ($draftBytes -gt $script:MaxConfigBytes) {
            return New-EditorError -Code 'request-invalid' -Message "The validate draft is $draftBytes bytes; the limit is $($script:MaxConfigBytes) bytes." -Details ([ordered]@{ sizeBytes = $draftBytes })
        }

        return $null
    }

    if ($Op -eq 'convert') {
        $unknown = @($names | Where-Object { $_ -notin @('rect', 'anchor', 'selectAnchor', 'basis', 'topologyFingerprint') })
        if ($unknown.Count -gt 0) {
            return New-EditorError -Code 'request-invalid' -Message "Unknown convert parameter(s): $($unknown -join ', ')."
        }
        if ($names -notcontains 'rect' -or $Params.rect -isnot [System.Management.Automation.PSCustomObject]) {
            return New-EditorError -Code 'request-invalid' -Message "convert requires a 'rect' JSON object."
        }

        $hasAnchor = $names -contains 'anchor'
        $hasSelectAnchor = $names -contains 'selectAnchor'

        if ($hasAnchor -eq $hasSelectAnchor) {
            return New-EditorError -Code 'request-invalid' -Message "convert requires exactly one of 'anchor' or 'selectAnchor'."
        }

        if ($hasAnchor) {
            if ($Params.anchor -isnot [System.Management.Automation.PSCustomObject]) {
                return New-EditorError -Code 'request-invalid' -Message "convert 'anchor' must be a JSON object with 'identity' and optional 'instance'."
            }
            $anchorNames = @($Params.anchor.PSObject.Properties.Name)
            $unknownAnchor = @($anchorNames | Where-Object { $_ -notin @('identity', 'instance') })
            if ($unknownAnchor.Count -gt 0) {
                return New-EditorError -Code 'request-invalid' -Message "Unknown convert anchor field(s): $($unknownAnchor -join ', ')."
            }
            if ($anchorNames -notcontains 'identity' -or $Params.anchor.identity -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Params.anchor.identity)) {
                return New-EditorError -Code 'request-invalid' -Message "convert 'anchor.identity' must be a non-empty string."
            }
            if ($anchorNames -contains 'instance' -and ($Params.anchor.instance -isnot [string] -or [string]::IsNullOrWhiteSpace([string]$Params.anchor.instance))) {
                return New-EditorError -Code 'request-invalid' -Message "convert 'anchor.instance' must be a non-empty string when supplied."
            }
        }
        elseif ($Params.selectAnchor -isnot [bool] -or -not [bool]$Params.selectAnchor) {
            return New-EditorError -Code 'request-invalid' -Message "convert 'selectAnchor' must be true when 'anchor' is omitted."
        }

        if ($names -notcontains 'basis' -or $Params.basis -isnot [string] -or $Params.basis -notin @('workArea', 'monitor')) {
            return New-EditorError -Code 'request-invalid' -Message "convert 'basis' must be 'workArea' or 'monitor'."
        }

        if ($names -contains 'topologyFingerprint' -and ($Params.topologyFingerprint -isnot [string] -or $Params.topologyFingerprint -notmatch '^[0-9A-Fa-f]{64}$')) {
            return New-EditorError -Code 'request-invalid' -Message "convert 'topologyFingerprint' must be 64 hexadecimal characters."
        }

        return $null
    }

    return $null
}

function Get-EditorHello {
    $configWritable = $false
    $topologyReadable = $false

    try {
        $location = Resolve-DevWSConfigLocation -StartPath $editorRoot
        $configWritable = [bool]$location.IsWritable
    }
    catch {
        $configWritable = $false
    }

    try {
        $topology = Get-DevWSMonitorTopology
        $topologyReadable = [bool]$topology.Available
    }
    catch {
        $topologyReadable = $false
    }

    return [pscustomobject][ordered]@{
        backendVersion = $script:BackendVersion
        protocol       = $script:Protocol
        supportedOps   = $script:SupportedOps
        limits         = [pscustomobject][ordered]@{
            maxRequestBytes  = $script:MaxRequestBytes
            maxResponseBytes = $script:MaxResponseBytes
            maxJsonDepth     = $script:MaxJsonDepth
            maxConfigBytes   = $script:MaxConfigBytes
            maxInflight      = 1
            readTimeoutMs    = 10000
            saveTimeoutMs    = $null
        }
        capabilities   = [pscustomobject][ordered]@{
            configWritable    = $configWritable
            topologyReadable  = $topologyReadable
            readOnly          = $true
            saveSupported     = $false
            validateSupported = $true
            previewSupported  = $true
            convertSupported  = $true
        }
    }
}

function Get-EditorInspectResult {
    param($Snapshot)

    try {
        $topology = Get-DevWSMonitorTopology
    }
    catch {
        $topology = $null
    }

    $configMetadata = Get-EditorConfigMetadata -Snapshot $Snapshot
    $sets = Get-EditorSetMetadata -Config $Snapshot.Config -DefaultSetId ([string]$Snapshot.Config.defaultSet)

    return [pscustomobject][ordered]@{
        config       = $configMetadata
        sets         = @($sets)
        topology     = Get-EditorTopologyProjection -Topology $topology
        capabilities = [pscustomobject][ordered]@{
            canSave      = $false
            canProject   = $true
            canValidate  = $true
            canPreview   = $true
            canConvert   = $true
            readOnly     = $true
            reason       = 'p6-preview-read-only'
        }
    }
}

function ConvertTo-EditorRectArgument {
    # Convert a protocol rectangle object into the integer shape expected by the
    # existing relative-layout functions. Width/height must be greater than 0;
    # negative origins are valid.
    param($Value)

    if ($null -eq $Value -or $Value -isnot [System.Management.Automation.PSCustomObject]) {
        return [pscustomobject]@{ Ok = $false; Rect = $null; Message = "The rectangle must be a JSON object with 'x', 'y', 'w', and 'h'." }
    }

    $names = @($Value.PSObject.Properties.Name)

    if ($names.Count -ne 4 -or $names -notcontains 'x' -or $names -notcontains 'y' -or $names -notcontains 'w' -or $names -notcontains 'h') {
        return [pscustomobject]@{ Ok = $false; Rect = $null; Message = "The rectangle must contain exactly 'x', 'y', 'w', and 'h'." }
    }

    foreach ($field in @('x', 'y', 'w', 'h')) {
        $number = $Value.$field

        if (-not (Test-DevWSInteger -Value $number) -or $number -lt [int]::MinValue -or $number -gt [int]::MaxValue) {
            return [pscustomobject]@{ Ok = $false; Rect = $null; Message = "The rectangle field '$field' must be a 32-bit integer." }
        }
    }

    if ([long]$Value.w -le 0 -or [long]$Value.h -le 0) {
        return [pscustomobject]@{ Ok = $false; Rect = $null; Message = "The rectangle width and height must be greater than 0." }
    }

    return [pscustomobject][ordered]@{
        Ok      = $true
        Rect    = [pscustomobject][ordered]@{
            x = [int]$Value.x
            y = [int]$Value.y
            w = [int]$Value.w
            h = [int]$Value.h
        }
        Message = $null
    }
}

function Invoke-EditorOperation {
    param(
        [string]$Op,
        $Params
    )

    switch ($Op) {
        'hello' {
            return [pscustomobject]@{ Ok = $true; Result = (Get-EditorHello); Warnings = @(); ErrorObject = $null }
        }

        'inspect' {
            $snapshot = Read-EditorConfigSnapshot -StartPath $editorRoot -MaxBytes $script:MaxConfigBytes

            if (-not $snapshot.Ok) {
                $details = [ordered]@{
                    code      = [string]$snapshot.Code
                    sizeBytes = if ($null -ne $snapshot.PSObject.Properties['SizeBytes']) { $snapshot.SizeBytes } else { $null }
                }
                return [pscustomobject]@{
                    Ok          = $false
                    Result      = $null
                    Warnings    = @()
                    ErrorObject = New-EditorError -Code $snapshot.Code -Message $snapshot.Message -Details $details
                }
            }

            if (-not $snapshot.Valid) {
                $details = [ordered]@{
                    config           = Get-EditorConfigMetadata -Snapshot $snapshot
                    validationErrors = @($snapshot.ValidationError)
                }
                return [pscustomobject]@{
                    Ok          = $false
                    Result      = $null
                    Warnings    = @()
                    ErrorObject = New-EditorError -Code 'config-invalid' -Message $snapshot.ValidationError -Details $details
                }
            }

            return [pscustomobject]@{
                Ok          = $true
                Result      = (Get-EditorInspectResult -Snapshot $snapshot)
                Warnings    = @()
                ErrorObject = $null
            }
        }

        'read-config' {
            $snapshot = Read-EditorConfigSnapshot -StartPath $editorRoot -MaxBytes $script:MaxConfigBytes

            if (-not $snapshot.Ok) {
                return [pscustomobject]@{
                    Ok          = $false
                    Result      = $null
                    Warnings    = @()
                    ErrorObject = New-EditorError -Code $snapshot.Code -Message $snapshot.Message
                }
            }

            if (-not $snapshot.Valid) {
                $details = [ordered]@{
                    config           = Get-EditorConfigMetadata -Snapshot $snapshot
                    validationErrors = @($snapshot.ValidationError)
                }
                return [pscustomobject]@{
                    Ok          = $false
                    Result      = $null
                    Warnings    = @()
                    ErrorObject = New-EditorError -Code 'config-invalid' -Message $snapshot.ValidationError -Details $details
                }
            }

            if ([string]$Params.expectedSha256 -cne [string]$snapshot.Sha256) {
                return [pscustomobject]@{
                    Ok          = $false
                    Result      = $null
                    Warnings    = @()
                    ErrorObject = New-EditorError -Code 'external-change' -Message 'The effective configuration changed since it was inspected. Nothing was returned.' -Details ([ordered]@{
                        expectedSha256 = [string]$Params.expectedSha256
                        actualSha256   = [string]$snapshot.Sha256
                    })
                }
            }

            return [pscustomobject]@{
                Ok          = $true
                Result      = [pscustomobject][ordered]@{
                    sha256    = [string]$snapshot.Sha256
                    sizeBytes = [int]$snapshot.SizeBytes
                    document  = $snapshot.Config
                }
                Warnings    = @()
                ErrorObject = $null
            }
        }

        'project' {
            $snapshot = Read-EditorConfigSnapshot -StartPath $editorRoot -MaxBytes $script:MaxConfigBytes

            if (-not $snapshot.Ok) {
                return [pscustomobject]@{
                    Ok          = $false
                    Result      = $null
                    Warnings    = @()
                    ErrorObject = New-EditorError -Code $snapshot.Code -Message $snapshot.Message
                }
            }

            if (-not $snapshot.Valid) {
                return [pscustomobject]@{
                    Ok          = $false
                    Result      = $null
                    Warnings    = @()
                    ErrorObject = New-EditorError -Code 'config-invalid' -Message $snapshot.ValidationError
                }
            }

            try {
                $setReference = if ($Params.PSObject.Properties.Name -contains 'setId') { [string]$Params.setId } else { $null }
                $target = Resolve-DevWSTargetSet -Config $snapshot.Config -Set $setReference
            }
            catch {
                return [pscustomobject]@{
                    Ok          = $false
                    Result      = $null
                    Warnings    = @()
                    ErrorObject = New-EditorError -Code 'set-not-found' -Message $_.Exception.Message -Details ([ordered]@{ setId = [string]$Params.setId })
                }
            }

            try {
                $topology = Get-DevWSMonitorTopology
            }
            catch {
                $topology = $null
            }

            $projection = Get-EditorProjection `
                -Config $snapshot.Config `
                -Set $target `
                -Topology $topology `
                -ConfigRevision ([string]$snapshot.Sha256)

            $projectionResult = [pscustomobject][ordered]@{
                configRevision = $projection.configRevision
                setId          = $projection.setId
                set            = $projection.set
                topology       = $projection.topology
            }

            return [pscustomobject]@{
                Ok          = $true
                Result      = $projectionResult
                Warnings    = @($projection.warnings)
                ErrorObject = $null
            }
        }

        'preview' {
            $snapshot = Read-EditorConfigSnapshot -StartPath $editorRoot -MaxBytes $script:MaxConfigBytes

            if (-not $snapshot.Ok) {
                return [pscustomobject]@{
                    Ok          = $false
                    Result      = $null
                    Warnings    = @()
                    ErrorObject = New-EditorError -Code $snapshot.Code -Message $snapshot.Message
                }
            }

            if (-not $snapshot.Valid) {
                return [pscustomobject]@{
                    Ok          = $false
                    Result      = $null
                    Warnings    = @()
                    ErrorObject = New-EditorError -Code 'config-invalid' -Message $snapshot.ValidationError
                }
            }

            if ([string]$Params.baseSha256 -cne [string]$snapshot.Sha256) {
                return [pscustomobject]@{
                    Ok          = $false
                    Result      = $null
                    Warnings    = @()
                    ErrorObject = New-EditorError -Code 'external-change' -Message 'The canonical configuration changed since the draft was created.' -Details ([ordered]@{
                        expectedSha256 = [string]$Params.baseSha256
                        actualSha256   = [string]$snapshot.Sha256
                    })
                }
            }

            $draftValidation = Get-EditorDraftValidation -Draft $Params.draft -StartPath $editorRoot

            if (-not [bool]$draftValidation.valid) {
                return [pscustomobject]@{
                    Ok          = $false
                    Result      = $null
                    Warnings    = @()
                    ErrorObject = New-EditorError -Code 'config-invalid' -Message 'The proposed draft is not structurally valid.' -Details ([ordered]@{
                        validationErrors = @($draftValidation.errors)
                    })
                }
            }

            $setId = if ($null -ne $Params.PSObject.Properties['setId']) {
                [string]$Params.setId
            } else {
                [string]$snapshot.Config.defaultSet
            }

            $topology = $null
            try {
                $topology = Get-DevWSMonitorTopology
            }
            catch {
                $topology = $null
            }

            $baseTopologyFingerprint = if ($null -ne $Params.PSObject.Properties['baseTopologyFingerprint']) {
                [string]$Params.baseTopologyFingerprint
            } else {
                $null
            }

            $preview = Get-EditorPreviewCore `
                -CanonicalConfig $snapshot.Config `
                -DraftConfig $Params.draft `
                -SetId $setId `
                -Topology $topology `
                -BaseSha256 ([string]$Params.baseSha256) `
                -CurrentSha256 ([string]$snapshot.Sha256) `
                -BaseTopologyFingerprint $baseTopologyFingerprint

            if (-not [bool]$preview.Ok) {
                return [pscustomobject]@{
                    Ok          = $false
                    Result      = $null
                    Warnings    = @()
                    ErrorObject = New-EditorError -Code ([string]$preview.Code) -Message ([string]$preview.Message) -Details $preview.Details
                }
            }

            return [pscustomobject]@{
                Ok          = $true
                Result      = $preview.Result
                Warnings    = @($preview.Warnings)
                ErrorObject = $null
            }
        }

        'validate' {
            $validation = Get-EditorDraftValidation -Draft $Params.draft -StartPath $editorRoot

            return [pscustomobject]@{
                Ok          = $true
                Result      = [pscustomobject][ordered]@{
                    valid        = [bool]$validation.valid
                    saveEligible = [bool]$validation.saveEligible
                    errors       = @($validation.errors)
                }
                Warnings    = @()
                ErrorObject = $null
            }
        }

        'convert' {
            $rectArgument = ConvertTo-EditorRectArgument -Value $Params.rect

            if (-not [bool]$rectArgument.Ok) {
                return [pscustomobject]@{
                    Ok          = $false
                    Result      = $null
                    Warnings    = @()
                    ErrorObject = New-EditorError -Code 'invalid-rect' -Message ([string]$rectArgument.Message)
                }
            }

            try {
                $topology = Get-DevWSMonitorTopology
            }
            catch {
                $topology = $null
            }

            $selectAnchor = $false
            if ($null -ne $Params.PSObject.Properties['selectAnchor']) {
                $selectAnchor = [bool]$Params.selectAnchor
            }

            $fingerprint = if ($null -ne $Params.PSObject.Properties['topologyFingerprint']) {
                [string]$Params.topologyFingerprint
            } else {
                $null
            }

            $converted = Get-EditorConvert `
                -Rect $rectArgument.Rect `
                -Anchor $(if ($null -ne $Params.PSObject.Properties['anchor']) { $Params.anchor } else { $null }) `
                -SelectAnchor $selectAnchor `
                -Basis ([string]$Params.basis) `
                -TopologyFingerprint $fingerprint `
                -Topology $topology

            if (-not [bool]$converted.Ok) {
                return [pscustomobject]@{
                    Ok          = $false
                    Result      = $null
                    Warnings    = @()
                    ErrorObject = New-EditorError -Code ([string]$converted.Code) -Message ([string]$converted.Message) -Details $converted.Details
                }
            }

            return [pscustomobject]@{
                Ok          = $true
                Result      = $converted.Result
                Warnings    = @()
                ErrorObject = $null
            }
        }

        'shutdown' {
            return [pscustomobject]@{ Ok = $true; Result = [pscustomobject]@{ stopped = $true }; Warnings = @(); ErrorObject = $null }
        }

        default {
            return [pscustomobject]@{
                Ok          = $false
                Result      = $null
                Warnings    = @()
                ErrorObject = New-EditorError -Code 'unsupported-operation' -Message "Operation '$Op' is not implemented in P6." -Details ([ordered]@{
                    operation    = $Op
                    phase        = 'P6'
                    supportedOps = $script:SupportedOps
                })
            }
        }
    }
}

$exitCode = 0

try {
    while ($true) {
        $script:CurrentRequestId = $null
        $script:CurrentRequestOp = $null
        $read = Read-EditorRequestLine

        if ($null -eq $read) {
            break
        }

        if ($read.TooLarge) {
            Write-EditorResponse -Id $null -Op $null -Ok $false -ErrorObject (New-EditorError -Code 'request-too-large' -Message "The request exceeded $($script:MaxRequestBytes) bytes; the connection will close.")
            break
        }

        if ($read.InvalidUtf8) {
            Write-EditorResponse -Id $null -Op $null -Ok $false -ErrorObject (New-EditorError -Code 'request-invalid' -Message 'The request is not valid UTF-8.')
            continue
        }

        if ([string]::IsNullOrWhiteSpace($read.Line)) {
            continue
        }

        $request = $null

        try {
            $request = $read.Line | ConvertFrom-Json -Depth $script:MaxJsonDepth -ErrorAction Stop
        }
        catch {
            Write-EditorResponse -Id $null -Op $null -Ok $false -ErrorObject (New-EditorError -Code 'request-invalid' -Message "Malformed JSON request: $($_.Exception.Message)")
            continue
        }

        $envelopeError = Test-EditorEnvelope -Request $request

        if ($null -ne $envelopeError) {
            Write-EditorResponse -Id $(if ($null -ne $request -and $null -ne $request.PSObject.Properties['id']) { $request.id } else { $null }) `
                -Op $(if ($null -ne $request -and $null -ne $request.PSObject.Properties['op']) { $request.op } else { $null }) `
                -Ok $false `
                -ErrorObject $envelopeError
            continue
        }

        $op = [string]$request.op
        $params = $request.params
        $script:CurrentRequestId = [string]$request.id
        $script:CurrentRequestOp = $op

        if (-not $script:SeenRequestIds.Add([string]$request.id)) {
            Write-EditorResponse -Id $request.id -Op $op -Ok $false -ErrorObject (New-EditorError -Code 'request-invalid' -Message "Request id '$($request.id)' was already used on this connection." -Details ([ordered]@{
                reason = 'duplicate-request-id'
            }))
            continue
        }

        if ($op -in $script:UnsupportedOps) {
            Write-EditorResponse -Id $request.id -Op $op -Ok $false -ErrorObject (New-EditorError -Code 'unsupported-operation' -Message "Operation '$op' is not implemented in P6." -Details ([ordered]@{
                operation    = $op
                phase        = 'P6'
                supportedOps = $script:SupportedOps
            }))
            continue
        }

        if ($op -notin $script:SupportedOps) {
            Write-EditorResponse -Id $request.id -Op $op -Ok $false -ErrorObject (New-EditorError -Code 'unsupported-operation' -Message "Operation '$op' is not implemented." -Details ([ordered]@{
                operation    = $op
                phase        = 'P6'
                supportedOps = $script:SupportedOps
            }))
            continue
        }

        $paramError = Test-EditorParams -Op $op -Params $params

        if ($null -ne $paramError) {
            Write-EditorResponse -Id $request.id -Op $op -Ok $false -ErrorObject $paramError
            continue
        }

        $outcome = Invoke-EditorOperation -Op $op -Params $params

        Write-EditorResponse -Id $request.id -Op $op -Ok ([bool]$outcome.Ok) -Result $outcome.Result -Warnings @($outcome.Warnings) -ErrorObject $outcome.ErrorObject

        if ($op -eq 'shutdown') {
            break
        }
    }
}
catch {
    [Console]::Error.WriteLine("editor backend failure: $($_.Exception.Message)")
    Write-EditorResponse -Id $script:CurrentRequestId -Op $script:CurrentRequestOp -Ok $false -ErrorObject (New-EditorError -Code 'backend-internal' -Message 'The editor backend encountered an internal error.')
    $exitCode = 1
}

exit $exitCode
