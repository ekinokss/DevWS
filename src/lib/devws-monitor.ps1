# DevWS read-only monitor topology foundation (Pass 5B).
#
# Scope:
#   - one bounded, coherent native snapshot (GDI monitors + QDC active paths)
#   - read-only registry EDID lookup keyed by the QDC monitor-device-path instance
#   - deterministic identity normalization (locked Pass 5A fallback chain):
#       meaningful EDID serial -> edid:<manufacturer>-<product>-<serial>
#       else                   -> path:<hardwareId>/<instance>
#       else                   -> identity unavailable
#   - one normalized, testable topology model (rects, work areas, DPI, facts)
#   - canonical topology signature + SHA-256 fingerprint built only from a
#     fully representable, fully identified active-monitor multiset
#   - pure reachability primitives (visible-area union math, no clamping)
#
# This library is deliberately free of workspace-config awareness, profile
# selection, window operations, host contact and display mutation. Every
# function is observational; nothing here writes, launches, focuses, closes,
# resizes or reconfigures anything.
#
# QDC coherence: the native layer retries
# GetDisplayConfigBufferSizes -> QueryDisplayConfig boundedly when the topology
# changed between the two calls (ERROR_INSUFFICIENT_BUFFER); an incoherent
# capture surfaces as an explicit acquisition error and never as a partial
# topology.

function Initialize-DevWSMonitorNative {
    # Guarded subsystem access to the shared native runtime; a duplicate loader
    # or per-command compilation is never introduced.
    if ($null -ne ([System.Management.Automation.PSTypeName]'DevWSMonitorNative').Type) {
        return
    }

    Initialize-DevWSNativeRuntime
}

function Get-DevWSMonitorOutputTechnologyName {
    # Read-only diagnostic mapping of DISPLAYCONFIG_OUTPUT_TECHNOLOGY values.
    param([uint32]$Value)

    if ([int64]$Value -eq 2147483648) { return "Internal" }
    if ([int64]$Value -gt 2147483647) { return "Unknown" }

    switch ([int]$Value) {
        0 { return "HD15" }
        1 { return "SVID" }
        2 { return "Composite" }
        3 { return "Component" }
        4 { return "DVI" }
        5 { return "HDMI" }
        6 { return "LVDS" }
        8 { return "D_JPN" }
        9 { return "SDI" }
        10 { return "DisplayPortExternal" }
        11 { return "DisplayPortEmbedded" }
        12 { return "UDIExternal" }
        13 { return "UDIEmbedded" }
        14 { return "SDTV dongle" }
        15 { return "Miracast" }
        16 { return "IndirectWired" }
        17 { return "IndirectVirtual" }
        18 { return "DisplayPortUsbTunnel" }
        default { return "Unknown" }
    }
}

function ConvertFrom-DevWSMonitorDevicePath {
    # QDC monitor device path ->
    #   \\?\DISPLAY#<hardware-id>#<instance-id>#{interface-guid}
    # Normalized to the interface-GUID-independent instance:
    #   <hardware-id>/<INSTANCE-ID>
    # Case is normalized (uppercase invariant) so identical paths with
    # different source casing yield identical identities. Malformed or
    # unparseable paths are rejected ($null); a GDI ordinal such as
    # \\.\DISPLAY1 is never accepted as a device path.
    param([string]$DevicePath)

    if ([string]::IsNullOrWhiteSpace($DevicePath)) { return $null }
    if ($DevicePath -notmatch '^\\\\\?\\DISPLAY#([^#\\\s]+)#([^#\\\s]+)') { return $null }

    $hardwareId = $Matches[1].ToUpperInvariant()
    $instance   = $Matches[2].ToUpperInvariant()

    return [pscustomobject]@{
        HardwareId = $hardwareId
        Instance   = "$hardwareId/$instance"
    }
}

function ConvertFrom-DevWSMonitorEdidBytes {
    # Minimal deterministic EDID parse: manufacturer id, product code, serial
    # number, serial-string descriptor and monitor-name descriptor. The header
    # magic is verified; missing, short or malformed data returns $null and the
    # caller falls back to the device-path identity (EDID is never fatal).
    param([byte[]]$Bytes)

    if ($null -eq $Bytes -or $Bytes.Length -lt 128) { return $null }

    $header = @(0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00)

    for ($index = 0; $index -lt $header.Count; $index++) {
        if ([int]$Bytes[$index] -ne $header[$index]) { return $null }
    }

    $bits = ([int]$Bytes[8] -shl 8) -bor [int]$Bytes[9]
    $letter1 = [char](64 + (($bits -shr 10) -band 0x1F))
    $letter2 = [char](64 + (($bits -shr 5) -band 0x1F))
    $letter3 = [char](64 + ($bits -band 0x1F))

    $manufacturer = "$letter1$letter2$letter3"
    $product      = ('{0:X4}' -f ((([int]$Bytes[11]) -shl 8) -bor [int]$Bytes[10]))
    $serialNumber = [uint32]([int]$Bytes[12] -bor ([int]$Bytes[13] -shl 8) -bor ([int]$Bytes[14] -shl 16) -bor ([int]$Bytes[15] -shl 24))

    $serialString = ''
    $monitorName  = ''

    foreach ($offset in @(54, 72, 90, 108)) {
        if (($offset + 18) -gt $Bytes.Length) { break }
        if ($Bytes[$offset] -ne 0 -or $Bytes[$offset + 1] -ne 0 -or $Bytes[$offset + 2] -ne 0) { continue }

        $tag = [int]$Bytes[$offset + 3]
        $textBytes = @($Bytes[($offset + 5)..($offset + 17)])
        $terminator = -1

        for ($index = 0; $index -lt $textBytes.Count; $index++) {
            if ($textBytes[$index] -eq 10) { $terminator = $index; break }
        }

        if ($terminator -eq 0) {
            $textBytes = @()
        }
        elseif ($terminator -gt 0) {
            $textBytes = @($textBytes[0..($terminator - 1)])
        }

        $text = (@($textBytes | Where-Object { $_ -ne 0 } | ForEach-Object { [char]$_ }) -join '').Trim()

        if ($tag -eq 0xFF) { $serialString = $text }
        if ($tag -eq 0xFC) { $monitorName = $text }
    }

    return [pscustomobject]@{
        Manufacturer = $manufacturer
        Product      = $product
        SerialNumber = $serialNumber
        SerialString = $serialString
        MonitorName  = $monitorName
        RawLength    = $Bytes.Length
    }
}

function Test-DevWSZeroOnlyText {
    param([string]$Text)

    if ([string]::IsNullOrEmpty($Text)) { return $true }

    foreach ($character in $Text.ToCharArray()) {
        if ($character -ne '0') { return $false }
    }

    return $true
}

function Get-DevWSMonitorMeaningfulSerial {
    # Meaningful-serial rules (locked): an all-zero or blank serial string and
    # the numeric placeholders 0x00000000 and 0x01010101 are not identities. A
    # valid serial string is preferred over a meaningful numeric serial, which
    # is rendered as an invariant uppercase hex value.
    param($Edid)

    if ($null -eq $Edid) { return $null }

    $serialString = [string]$Edid.SerialString

    if (-not [string]::IsNullOrWhiteSpace($serialString)) {
        $trimmed = $serialString.Trim()

        if (-not (Test-DevWSZeroOnlyText -Text $trimmed)) {
            return $trimmed
        }
    }

    $numeric = [uint32]$Edid.SerialNumber

    if ($numeric -ne [uint32]0 -and $numeric -ne [uint32]0x01010101) {
        return ('0x{0:X8}' -f $numeric)
    }

    return $null
}

function Get-DevWSMonitorIdentityToken {
    # Locked composite identity chain: edid-serial token -> device-path token
    # -> identity unavailable. Never an ordinal, LUID, target id, resolution,
    # friendly name or primary role.
    param(
        $Edid,
        [string]$DevicePathInstance
    )

    $serial = Get-DevWSMonitorMeaningfulSerial -Edid $Edid

    if ($null -ne $serial -and $null -ne $Edid) {
        $manufacturer = [string]$Edid.Manufacturer
        $product      = [string]$Edid.Product

        if (-not [string]::IsNullOrWhiteSpace($manufacturer) -and -not [string]::IsNullOrWhiteSpace($product)) {
            return [pscustomobject]@{
                Token  = "edid:$manufacturer-$product-$serial"
                Source = "edid"
            }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($DevicePathInstance)) {
        return [pscustomobject]@{
            Token  = "path:$DevicePathInstance"
            Source = "path"
        }
    }

    return [pscustomobject]@{
        Token  = $null
        Source = "unavailable"
    }
}

function Read-DevWSMonitorEdid {
    # Read-only EDID lookup keyed from the QDC monitor-device-path instance:
    #   HKLM\SYSTEM\CurrentControlSet\Enum\DISPLAY\<hardwareId>\<instance>\Device Parameters\EDID
    # Missing, denied or malformed data returns $null; never throws.
    param([string]$DevicePathInstance)

    if ([string]::IsNullOrWhiteSpace($DevicePathInstance)) { return $null }

    $parts = @($DevicePathInstance -split '/', 2)

    if ($parts.Count -ne 2) { return $null }

    $keyPath = "HKLM:\SYSTEM\CurrentControlSet\Enum\DISPLAY\$($parts[0])\$($parts[1])\Device Parameters"

    $bytes = $null

    try {
        $bytes = Get-ItemPropertyValue -LiteralPath $keyPath -Name 'EDID' -ErrorAction Stop
    }
    catch {
        return $null
    }

    return ConvertFrom-DevWSMonitorEdidBytes -Bytes $bytes
}

function New-DevWSMonitorRect {
    param(
        [Parameter(Mandatory)][int]$X,
        [Parameter(Mandatory)][int]$Y,
        [Parameter(Mandatory)][int]$W,
        [Parameter(Mandatory)][int]$H
    )

    return [pscustomobject]@{
        x = $X
        y = $Y
        w = $W
        h = $H
    }
}

function New-DevWSMonitorTopologyUnavailable {
    param(
        [Parameter(Mandatory)][int]$Attempts,
        [Parameter(Mandatory)][int]$ErrorCode,
        [Parameter(Mandatory)][string]$ErrorText
    )

    return [pscustomobject]@{
        Available             = $false
        Attempts              = $Attempts
        ErrorCode             = $ErrorCode
        Error                 = $ErrorText
        Monitors              = @()
        IdentityComplete      = $false
        CorrelationComplete   = $false
        IdentityAmbiguous     = $false
        Signature             = $null
        Fingerprint           = $null
        VirtualScreenRect     = $null
        UncorrelatedPathCount = 0
    }
}

function ConvertTo-DevWSMonitorTopologyModel {
    # Pure normalization: raw GDI rows + QDC path rows + per-instance EDID map
    # -> one testable topology model. No Win32, no registry, no writes; tests
    # inject synthetic rows directly.
    param(
        [AllowEmptyCollection()][object[]]$GdiRows = @(),
        [AllowEmptyCollection()][object[]]$PathRows = @(),
        [int]$Attempts = 0,
        [int]$ErrorCode = 0,
        $EdidByInstance = $null
    )

    if ($null -eq $EdidByInstance) {
        $EdidByInstance = @{}
    }

    if ($ErrorCode -ne 0) {
        return New-DevWSMonitorTopologyUnavailable `
            -Attempts $Attempts `
            -ErrorCode $ErrorCode `
            -ErrorText "QueryDisplayConfig could not capture a coherent active topology (Win32 error $ErrorCode after $Attempts attempt(s))."
    }

    $gdiList  = @($GdiRows)
    $pathList = @($PathRows)

    # Correlation bookkeeping (case-normalized device names; never array order).
    $pathByGdiName = @{}
    $pathNameCount = @{}

    foreach ($pathRow in $pathList) {
        $nameKey = ([string]$pathRow.GdiDeviceName).ToUpperInvariant()

        if (-not $pathNameCount.ContainsKey($nameKey)) {
            $pathNameCount[$nameKey] = 0
            $pathByGdiName[$nameKey] = $pathRow
        }

        $pathNameCount[$nameKey] = [int]$pathNameCount[$nameKey] + 1
    }

    $gdiNameCount = @{}

    foreach ($gdiRow in $gdiList) {
        $nameKey = ([string]$gdiRow.GdiDeviceName).ToUpperInvariant()

        if (-not $gdiNameCount.ContainsKey($nameKey)) {
            $gdiNameCount[$nameKey] = 0
        }

        $gdiNameCount[$nameKey] = [int]$gdiNameCount[$nameKey] + 1
    }

    $duplicateNames = $false

    foreach ($count in @($gdiNameCount.Values) + @($pathNameCount.Values)) {
        if ([int]$count -gt 1) { $duplicateNames = $true }
    }

    $unmatchedPathCount = 0

    foreach ($nameKey in @($pathNameCount.Keys)) {
        if (-not $gdiNameCount.ContainsKey($nameKey)) {
            $unmatchedPathCount += [int]$pathNameCount[$nameKey]
        }
    }

    $gdiWithoutPath = 0

    foreach ($nameKey in @($gdiNameCount.Keys)) {
        if (-not $pathNameCount.ContainsKey($nameKey)) {
            $gdiWithoutPath += [int]$gdiNameCount[$nameKey]
        }
    }

    $monitors = [System.Collections.Generic.List[object]]::new()

    foreach ($gdiRow in $gdiList) {
        $nameKey = ([string]$gdiRow.GdiDeviceName).ToUpperInvariant()
        $pathRow = $null

        if ($pathByGdiName.ContainsKey($nameKey)) {
            $pathRow = $pathByGdiName[$nameKey]
        }

        $devicePath         = $null
        $devicePathInstance = $null

        if ($null -ne $pathRow) {
            $devicePath = [string]$pathRow.MonitorDevicePath

            $parsedPath = ConvertFrom-DevWSMonitorDevicePath -DevicePath $devicePath

            if ($null -ne $parsedPath) {
                $devicePathInstance = [string]$parsedPath.Instance
            }
        }

        $edid = $null

        if ($null -ne $devicePathInstance -and $EdidByInstance.ContainsKey($devicePathInstance)) {
            $edid = $EdidByInstance[$devicePathInstance]
        }

        $identity = Get-DevWSMonitorIdentityToken -Edid $edid -DevicePathInstance $devicePathInstance

        $outputTechnologyValue = [uint32]0
        $friendlyName          = $null
        $targetAvailable       = $false
        $connectorInstance     = [uint32]0
        $sourceAdapterLuid     = $null
        $sourceId              = [uint32]0
        $targetAdapterLuid     = $null
        $targetId              = [uint32]0
        $sourceMode            = $null
        $targetActive          = $null

        if ($null -ne $pathRow) {
            $outputTechnologyValue = [uint32]$pathRow.OutputTechnology
            $friendlyName          = [string]$pathRow.FriendlyName
            $targetAvailable       = [bool]$pathRow.TargetAvailable
            $connectorInstance     = [uint32]$pathRow.ConnectorInstance
            $sourceAdapterLuid     = [string]$pathRow.SourceAdapterLuid
            $sourceId              = [uint32]$pathRow.SourceId
            $targetAdapterLuid     = [string]$pathRow.TargetAdapterLuid
            $targetId              = [uint32]$pathRow.TargetId
            $sourceMode            = New-DevWSMonitorRect -X ([int]$pathRow.SourceModePositionX) -Y ([int]$pathRow.SourceModePositionY) -W ([int]$pathRow.SourceModeWidth) -H ([int]$pathRow.SourceModeHeight)
            $targetActive          = [pscustomobject]@{ w = [int]$pathRow.TargetActiveWidth; h = [int]$pathRow.TargetActiveHeight }
        }

        $dpiEffective = [uint32]0
        $scalePercent = $null

        if ([bool]$gdiRow.DpiOk -and [uint32]$gdiRow.DpiEffectiveX -gt 0) {
            $dpiEffective = [uint32]$gdiRow.DpiEffectiveX
            $scalePercent = [int][Math]::Round(100.0 * [double]$dpiEffective / 96.0)
        }

        $monitorRect = New-DevWSMonitorRect -X ([int]$gdiRow.MonitorLeft) -Y ([int]$gdiRow.MonitorTop) -W ([int]$gdiRow.MonitorRight - [int]$gdiRow.MonitorLeft) -H ([int]$gdiRow.MonitorBottom - [int]$gdiRow.MonitorTop)
        $workRect    = New-DevWSMonitorRect -X ([int]$gdiRow.WorkLeft) -Y ([int]$gdiRow.WorkTop) -W ([int]$gdiRow.WorkRight - [int]$gdiRow.WorkLeft) -H ([int]$gdiRow.WorkBottom - [int]$gdiRow.WorkTop)

        $monitors.Add([pscustomobject]@{
            GdiDeviceName         = [string]$gdiRow.GdiDeviceName
            Primary               = [bool]$gdiRow.Primary
            MonitorRect           = $monitorRect
            WorkRect              = $workRect
            Width                 = $monitorRect.w
            Height                = $monitorRect.h
            DpiOk                 = [bool]$gdiRow.DpiOk
            DpiEffective          = $dpiEffective
            ScalePercent          = $scalePercent
            OutputTechnology      = (Get-DevWSMonitorOutputTechnologyName -Value $outputTechnologyValue)
            OutputTechnologyValue = $outputTechnologyValue
            IsInternal            = ([uint32]$outputTechnologyValue -eq 2147483648)
            FriendlyName          = $friendlyName
            DevicePath            = $devicePath
            DevicePathInstance    = $devicePathInstance
            IdentityToken         = $identity.Token
            IdentitySource        = $identity.Source
            Edid                  = $edid
            ConnectorInstance     = $connectorInstance
            TargetAvailable       = $targetAvailable
            SourceAdapterLuid     = $sourceAdapterLuid
            SourceId              = $sourceId
            TargetAdapterLuid     = $targetAdapterLuid
            TargetId              = $targetId
            SourceMode            = $sourceMode
            TargetActive          = $targetActive
        }) | Out-Null
    }

    # Identity completeness: at least one active monitor exists and every
    # representable monitor carries a usable identity token.
    $identityComplete = ($gdiList.Count -gt 0)

    foreach ($monitor in $monitors) {
        if ([string]::IsNullOrWhiteSpace([string]$monitor.IdentityToken)) {
            $identityComplete = $false
        }
    }

    $correlationComplete = ($gdiList.Count -gt 0) -and (-not $duplicateNames) -and ($unmatchedPathCount -eq 0) -and ($gdiWithoutPath -eq 0)

    # Ambiguity: the exact same identity token at the exact same monitor
    # rectangle. Same-model duplicates at different positions stay legal.
    $compositionCount  = @{}
    $identityAmbiguous = $false

    foreach ($monitor in $monitors) {
        if ([string]::IsNullOrWhiteSpace([string]$monitor.IdentityToken)) { continue }

        $compositionKey = "$($monitor.IdentityToken)@$($monitor.MonitorRect.x),$($monitor.MonitorRect.y),$($monitor.MonitorRect.w)x$($monitor.MonitorRect.h)"

        if (-not $compositionCount.ContainsKey($compositionKey)) {
            $compositionCount[$compositionKey] = 0
        }

        $compositionCount[$compositionKey] = [int]$compositionCount[$compositionKey] + 1
    }

    foreach ($count in @($compositionCount.Values)) {
        if ([int]$count -gt 1) { $identityAmbiguous = $true }
    }

    # The canonical signature is the ordinal-sorted multiset of
    #   <identityToken>@<x>,<y>,<width>x<height>
    # and exists only for a fully representable, fully identified topology.
    # Work area, taskbar, friendly name, primary bit, DPI, refresh, output
    # technology, LUIDs and target ids are deliberately NOT part of it.
    $signature   = $null
    $fingerprint = $null

    if ($identityComplete -and $correlationComplete -and $monitors.Count -gt 0) {
        $tokens = [System.Collections.Generic.List[string]]::new()

        foreach ($monitor in $monitors) {
            $tokens.Add("$($monitor.IdentityToken)@$($monitor.MonitorRect.x),$($monitor.MonitorRect.y),$($monitor.MonitorRect.w)x$($monitor.MonitorRect.h)") | Out-Null
        }

        $tokenArray = $tokens.ToArray()
        [System.Array]::Sort($tokenArray, [System.StringComparer]::Ordinal)

        $signature = ($tokenArray -join ';')

        $sha = [System.Security.Cryptography.SHA256]::Create()

        try {
            $fingerprint = ([System.BitConverter]::ToString($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($signature)))).Replace('-', '')
        }
        finally {
            $sha.Dispose()
        }
    }

    # Virtual desktop rectangle: union of monitor rects in virtual-screen
    # coordinates (negative origins stay negative; nothing is normalized).
    $virtualRect = $null

    if ($monitors.Count -gt 0) {
        $minX      = [int](@($monitors | ForEach-Object { $_.MonitorRect.x }) | Measure-Object -Minimum).Minimum
        $minY      = [int](@($monitors | ForEach-Object { $_.MonitorRect.y }) | Measure-Object -Minimum).Minimum
        $maxRight  = [int](@($monitors | ForEach-Object { $_.MonitorRect.x + $_.MonitorRect.w }) | Measure-Object -Maximum).Maximum
        $maxBottom = [int](@($monitors | ForEach-Object { $_.MonitorRect.y + $_.MonitorRect.h }) | Measure-Object -Maximum).Maximum
        $virtualRect = New-DevWSMonitorRect -X $minX -Y $minY -W ($maxRight - $minX) -H ($maxBottom - $minY)
    }

    return [pscustomobject]@{
        Available             = $true
        Attempts              = $Attempts
        ErrorCode             = 0
        Error                 = $null
        Monitors              = @($monitors.ToArray())
        IdentityComplete      = $identityComplete
        CorrelationComplete   = $correlationComplete
        IdentityAmbiguous     = $identityAmbiguous
        Signature             = $signature
        Fingerprint           = $fingerprint
        VirtualScreenRect     = $virtualRect
        UncorrelatedPathCount = $unmatchedPathCount
    }
}

function Get-DevWSMonitorNativeSnapshot {
    # One bounded, coherent, read-only native snapshot; raw rows only.
    Initialize-DevWSMonitorNative

    $gdiRows      = @([DevWSMonitorNative]::GetGdiMonitorRows())
    $pathSnapshot = [DevWSMonitorNative]::GetActivePathSnapshot()

    return [pscustomobject]@{
        GdiRows   = $gdiRows
        PathRows  = @($pathSnapshot.Paths)
        Attempts  = [int]$pathSnapshot.Attempts
        ErrorCode = [int]$pathSnapshot.ErrorCode
    }
}

function Get-DevWSMonitorTopology {
    # Public read-only topology: one native snapshot, read-only EDID lookups
    # for the active device-path instances, then pure normalization. Never
    # writes, never mutates display configuration, never touches windows.
    $snapshot = Get-DevWSMonitorNativeSnapshot

    $edidByInstance = @{}

    foreach ($pathRow in @($snapshot.PathRows)) {
        $parsedPath = ConvertFrom-DevWSMonitorDevicePath -DevicePath ([string]$pathRow.MonitorDevicePath)

        if ($null -eq $parsedPath) { continue }
        if ($edidByInstance.ContainsKey($parsedPath.Instance)) { continue }

        $edidByInstance[$parsedPath.Instance] = Read-DevWSMonitorEdid -DevicePathInstance $parsedPath.Instance
    }

    return ConvertTo-DevWSMonitorTopologyModel `
        -GdiRows $snapshot.GdiRows `
        -PathRows $snapshot.PathRows `
        -Attempts $snapshot.Attempts `
        -ErrorCode $snapshot.ErrorCode `
        -EdidByInstance $edidByInstance
}

function Get-DevWSMonitorRectUnionArea {
    # Exact union area of a rectangle set (coordinate compression). Overlapping
    # rectangles are never double-counted; deterministic for any input order.
    param([AllowEmptyCollection()][object[]]$Rects = @())

    $rectList = @($Rects | Where-Object { $null -ne $_ -and [int]$_.w -gt 0 -and [int]$_.h -gt 0 })

    if ($rectList.Count -eq 0) { return [long]0 }

    $xs = @($rectList | ForEach-Object { [long]$_.x; [long]($_.x + $_.w) } | Sort-Object -Unique)
    $ys = @($rectList | ForEach-Object { [long]$_.y; [long]($_.y + $_.h) } | Sort-Object -Unique)

    $area = [long]0

    for ($xIndex = 0; $xIndex -lt ($xs.Count - 1); $xIndex++) {
        $stripWidth = $xs[$xIndex + 1] - $xs[$xIndex]
        $midX = ($xs[$xIndex] + $xs[$xIndex + 1]) / 2.0

        for ($yIndex = 0; $yIndex -lt ($ys.Count - 1); $yIndex++) {
            $midY = ($ys[$yIndex] + $ys[$yIndex + 1]) / 2.0
            $covered = $false

            foreach ($rect in $rectList) {
                if ($midX -gt [long]$rect.x -and $midX -lt ([long]$rect.x + [long]$rect.w) -and
                    $midY -gt [long]$rect.y -and $midY -lt ([long]$rect.y + [long]$rect.h)) {
                    $covered = $true
                    break
                }
            }

            if ($covered) {
                $area += $stripWidth * ($ys[$yIndex + 1] - $ys[$yIndex])
            }
        }
    }

    return $area
}

function Get-DevWSRectVisibleMetrics {
    # Visible geometry of one candidate rectangle against the active monitor
    # rectangles: clipped intersections, their exact union area, the union
    # bounding size and the visible ratio. No clamping and no remapping.
    param(
        [Parameter(Mandatory)]$Rect,
        [AllowEmptyCollection()][object[]]$MonitorRects = @()
    )

    $rectWidth  = [int]$Rect.w
    $rectHeight = [int]$Rect.h
    $totalArea  = [long]0

    if ($rectWidth -gt 0 -and $rectHeight -gt 0) {
        $totalArea = [long]$rectWidth * [long]$rectHeight
    }

    $clipped = [System.Collections.Generic.List[object]]::new()

    foreach ($monitor in @($MonitorRects)) {
        if ($null -eq $monitor) { continue }

        $left   = [Math]::Max([int]$Rect.x, [int]$monitor.x)
        $top    = [Math]::Max([int]$Rect.y, [int]$monitor.y)
        $right  = [Math]::Min([int]$Rect.x + [int]$Rect.w, [int]$monitor.x + [int]$monitor.w)
        $bottom = [Math]::Min([int]$Rect.y + [int]$Rect.h, [int]$monitor.y + [int]$monitor.h)

        if ($right -gt $left -and $bottom -gt $top) {
            $clipped.Add([pscustomobject]@{ x = $left; y = $top; w = $right - $left; h = $bottom - $top }) | Out-Null
        }
    }

    $visibleArea   = Get-DevWSMonitorRectUnionArea -Rects $clipped.ToArray()
    $visibleWidth  = 0
    $visibleHeight = 0

    if ($clipped.Count -gt 0) {
        $minX          = [int](@($clipped | ForEach-Object { $_.x }) | Measure-Object -Minimum).Minimum
        $minY          = [int](@($clipped | ForEach-Object { $_.y }) | Measure-Object -Minimum).Minimum
        $maxRight      = [int](@($clipped | ForEach-Object { $_.x + $_.w }) | Measure-Object -Maximum).Maximum
        $maxBottom     = [int](@($clipped | ForEach-Object { $_.y + $_.h }) | Measure-Object -Maximum).Maximum
        $visibleWidth  = $maxRight - $minX
        $visibleHeight = $maxBottom - $minY
    }

    $visibleRatio = 0.0

    if ($totalArea -gt 0) {
        $visibleRatio = $visibleArea / [double]$totalArea
    }

    return [pscustomobject]@{
        TotalArea     = [long]$totalArea
        VisibleArea   = [long]$visibleArea
        VisibleRatio  = [double]$visibleRatio
        VisibleWidth  = [int]$visibleWidth
        VisibleHeight = [int]$visibleHeight
    }
}

function Test-DevWSRectReachable {
    # Accepted Pass 5A reachability rule (binary, no clamping):
    #   reachable iff visibleArea > 0
    #   AND (visibleRatio >= 0.25 OR (visibleWidth >= 100 AND visibleHeight >= 40))
    param(
        [Parameter(Mandatory)]$Rect,
        [AllowEmptyCollection()][object[]]$MonitorRects = @()
    )

    $metrics = Get-DevWSRectVisibleMetrics -Rect $Rect -MonitorRects $MonitorRects

    $reachable = $false

    if ($metrics.VisibleArea -gt 0) {
        if ($metrics.VisibleRatio -ge 0.25 -or ($metrics.VisibleWidth -ge 100 -and $metrics.VisibleHeight -ge 40)) {
            $reachable = $true
        }
    }

    return [pscustomobject]@{
        Reachable     = $reachable
        VisibleArea   = $metrics.VisibleArea
        VisibleRatio  = $metrics.VisibleRatio
        VisibleWidth  = $metrics.VisibleWidth
        VisibleHeight = $metrics.VisibleHeight
    }
}
