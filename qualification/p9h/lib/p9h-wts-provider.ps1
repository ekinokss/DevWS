# DevWS P9-H replay instrumentation - WTS session provider adapter.
#
# Stage 3A. This module is the BRIDGE between the Win32 Terminal Services
# session APIs and the frozen P9-H evidence contract. It adds no new verdict
# rule and relaxes none: the observer (p9h-e1-observer.ps1) keeps consuming the
# provider LINE format it has always parsed, and the provider is responsible for
# producing that format from `WTSINFO` facts.
#
# WHY A DECODER AND A QUERY ARE SEPARATE
#   The native payload decode is pure: bytes in, facts out. The live query is
#   the only part that touches the host, and it is gated. That split is what
#   lets every Stage 3A assertion run with NO live WTS session query at all,
#   while still exercising the exact decode path a live query would use.
#
# DOCUMENTED CONTRACT (wtsapi32.h / winsrv.h)
#   WTSEnumerateSessionsW       enumerate session ids + station names
#   WTSQuerySessionInformationW  return a WTSINFO structure (WTS_INFO_CLASS 24)
#   WTSFreeMemory               release every buffer the WTS API allocated
#
#   typedef struct _WTSINFO {
#       WTS_CONNECTSTATE_CLASS State;      // 4 bytes
#       DWORD SessionId;                   // 4
#       DWORD IncomingBytes;               // 4
#       DWORD OutgoingBytes;               // 4
#       DWORD IncomingFrames;              // 4
#       DWORD OutgoingFrames;              // 4
#       DWORD IncomingCompressedBytes;     // 4
#       DWORD OutgoingCompressedBytes;     // 4
#       WCHAR WinStationName[32];          // WINSTATIONNAME_LENGTH, incl. NUL
#       WCHAR Domain[17];                  // DOMAIN_LENGTH, incl. NUL
#       WCHAR UserName[21];                // USERNAME_LENGTH + 1, incl. NUL
#       LARGE_INTEGER ConnectTime;         // FILETIME
#       LARGE_INTEGER DisconnectTime;      // FILETIME
#       LARGE_INTEGER LastInputTime;       // FILETIME
#       LARGE_INTEGER LogonTime;           // FILETIME
#       LARGE_INTEGER CurrentTime;         // FILETIME
#   } WTSINFO;
#
#   The LARGE_INTEGER members are FILETIME values: 100-nanosecond intervals
#   since 1601-01-01T00:00:00Z. A zero value means "not available", never
#   "the epoch", and is rejected rather than converted.
#
# SAFETY: dot-sourcing this file performs no interop call, allocates nothing and
# contacts no session. Only Invoke-P9HWtsSessionQuery touches the host, and it
# refuses unless the operator supplies the literal real-execution token.

Set-StrictMode -Version Latest

# Documented array lengths from winsrv.h, INCLUDING the null terminator.
$script:P9HWtsStationNameLength = 32   # WINSTATIONNAME_LENGTH
$script:P9HWtsDomainLength = 17        # DOMAIN_LENGTH
$script:P9HWtsUserNameLength = 21      # USERNAME_LENGTH + 1

# WTS_INFO_CLASS.WTSInfo
$script:P9HWtsInfoClassInfo = 24

function Initialize-P9HWtsProviderNative {
    # Compile the layout mirror and the query P/Invoke once per process.
    #
    # Two separate types on purpose: the codec is pure and safe to load in any
    # test, while the API type is only needed (and only instantiated) by the
    # gated live path.
    if (-not ([System.Management.Automation.PSTypeName]'P9HWtsInfoCodec').Type) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Text;

// Mirror of the documented WTSINFO structure (wtsapi32.h). Array lengths are
// the winsrv.h constants INCLUDING their null terminators.
[StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
public struct P9HWtsInfoMirror
{
    public int State;
    public int SessionId;
    public int IncomingBytes;
    public int OutgoingBytes;
    public int IncomingFrames;
    public int OutgoingFrames;
    public int IncomingCompressedBytes;
    public int OutgoingCompressedBytes;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string WinStationName;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 17)] public string Domain;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 21)] public string UserName;
    public long ConnectTime;
    public long DisconnectTime;
    public long LastInputTime;
    public long LogonTime;
    public long CurrentTime;
}

public sealed class P9HWtsInfoFacts
{
    public int State;
    public int SessionId;
    public string WinStationName;
    public string Domain;
    public string UserName;
    public long ConnectTime;
    public long DisconnectTime;
    public long LastInputTime;
    public long LogonTime;
    public long CurrentTime;
}

public static class P9HWtsInfoCodec
{
    public static int Size() { return Marshal.SizeOf(typeof(P9HWtsInfoMirror)); }

    public static int Offset(string fieldName)
    {
        return (int)Marshal.OffsetOf(typeof(P9HWtsInfoMirror), fieldName);
    }

    // Decode one WTSINFO blob at the documented offsets of this architecture.
    // Returns null when the buffer cannot be a WTSINFO of the measured size.
    public static P9HWtsInfoFacts Decode(byte[] payload, int expectedSize)
    {
        if (payload == null || payload.Length != expectedSize) { return null; }

        P9HWtsInfoFacts facts = new P9HWtsInfoFacts();
        facts.State = BitConverter.ToInt32(payload, Offset("State"));
        facts.SessionId = BitConverter.ToInt32(payload, Offset("SessionId"));
        facts.WinStationName = ReadFixedString(payload, Offset("WinStationName"), 32);
        facts.Domain = ReadFixedString(payload, Offset("Domain"), 17);
        facts.UserName = ReadFixedString(payload, Offset("UserName"), 21);
        facts.ConnectTime = BitConverter.ToInt64(payload, Offset("ConnectTime"));
        facts.DisconnectTime = BitConverter.ToInt64(payload, Offset("DisconnectTime"));
        facts.LastInputTime = BitConverter.ToInt64(payload, Offset("LastInputTime"));
        facts.LogonTime = BitConverter.ToInt64(payload, Offset("LogonTime"));
        facts.CurrentTime = BitConverter.ToInt64(payload, Offset("CurrentTime"));
        return facts;
    }

    // A null-terminated UTF-16 fixed buffer: stop at the first terminator and
    // ignore any garbage a provider left after it.
    private static string ReadFixedString(byte[] buffer, int offset, int charCapacity)
    {
        StringBuilder sb = new StringBuilder(charCapacity);
        for (int i = 0; i < charCapacity; i++)
        {
            int at = offset + (i * 2);
            if (at + 1 >= buffer.Length) { break; }
            char c = (char)(buffer[at] | (buffer[at + 1] << 8));
            if (c == '\0') { break; }
            sb.Append(c);
        }
        return sb.ToString();
    }
}
'@ -ErrorAction Stop
    }
}

function New-P9HWtsInfoPayload {
    # Build a synthetic WTSINFO payload with the documented layout.
    #
    # Test-facing, and deliberately explicit: a test states the exact facts it
    # wants (including a zero or malformed logon time) and this writer encodes
    # them at the real offsets. That is how the decoder, the layout cross-check
    # and the FILETIME conversion are all exercised without a live session.
    param(
        [Parameter(Mandatory)][int]$SessionId,
        [Parameter(Mandatory)][int]$State,
        [AllowNull()][AllowEmptyString()][string]$StationName = 'RDP-Tcp#0',
        [AllowNull()][AllowEmptyString()][string]$Domain = '',
        [AllowNull()][AllowEmptyString()][string]$UserName = 'qauser',
        [long]$LogonTime = 0,
        [long]$ConnectTime = 0,
        [long]$DisconnectTime = 0,
        [long]$LastInputTime = 0,
        [long]$CurrentTime = 0,
        # Deliberately break the size, to prove the size check fires.
        [int]$ByteCountOverride = 0
    )

    Initialize-P9HWtsProviderNative

    $size = [P9HWtsInfoCodec]::Size()
    $buffer = [byte[]]::new($size)

    # BitConverter.TryWriteBytes(Span[byte], value) - write the value bytes then
    # copy them into the buffer at the measured offset.
    $writeInt32 = {
        param([int]$value, [string]$field)
        $bytes = [BitConverter]::GetBytes([int]$value)
        [Array]::Copy($bytes, 0, $buffer, [P9HWtsInfoCodec]::Offset($field), 4)
    }
    $writeInt64 = {
        param([long]$value, [string]$field)
        $bytes = [BitConverter]::GetBytes([long]$value)
        [Array]::Copy($bytes, 0, $buffer, [P9HWtsInfoCodec]::Offset($field), 8)
    }

    & $writeInt32 $SessionId 'SessionId'
    & $writeInt32 $State 'State'

    $writeString = {
        param([string]$value, [string]$field, [int]$capacity)
        $at = [P9HWtsInfoCodec]::Offset($field)
        $text = if ([string]::IsNullOrEmpty($value)) { '' } else { $value }
        # Never overrun the documented capacity; truncate explicitly if a test
        # supplies something longer, so the writer cannot corrupt a neighbour.
        if ($text.Length -gt ($capacity - 1)) { $text = $text.Substring(0, $capacity - 1) }
        for ($i = 0; $i -lt $text.Length; $i++) {
            $bytes = [BitConverter]::GetBytes([char]$text[$i])
            $buffer[$at + ($i * 2)] = $bytes[0]
            $buffer[$at + ($i * 2) + 1] = $bytes[1]
        }
    }

    & $writeString $StationName 'WinStationName' $script:P9HWtsStationNameLength
    & $writeString $Domain 'Domain' $script:P9HWtsDomainLength
    & $writeString $UserName 'UserName' $script:P9HWtsUserNameLength

    & $writeInt64 $ConnectTime 'ConnectTime'
    & $writeInt64 $DisconnectTime 'DisconnectTime'
    & $writeInt64 $LastInputTime 'LastInputTime'
    & $writeInt64 $LogonTime 'LogonTime'
    & $writeInt64 $CurrentTime 'CurrentTime'

    if ($ByteCountOverride -gt 0) {
        $resized = [byte[]]::new($ByteCountOverride)
        [Array]::Copy($buffer, $resized, [Math]::Min($ByteCountOverride, $size))
        return $resized
    }

    return $buffer
}

function Get-P9HWtsInfoNativeLayout {
    # Measured layout of the compiled mirror for THIS process architecture.
    #
    # Marshal.SizeOf / Marshal.OffsetOf are the authoritative answers; nothing
    # here is a hardcoded guess, which is what makes the cross-check below a real
    # test of the documented contract rather than a tautology.
    Initialize-P9HWtsProviderNative

    $size = [P9HWtsInfoCodec]::Size()
    $offsets = [ordered]@{}
    foreach ($field in @('State', 'SessionId', 'WinStationName', 'Domain', 'UserName',
            'ConnectTime', 'DisconnectTime', 'LastInputTime', 'LogonTime', 'CurrentTime')) {
        $offsets[$field] = [P9HWtsInfoCodec]::Offset($field)
    }

    return [pscustomobject][ordered]@{
        Size         = $size
        Offsets      = [pscustomobject]$offsets
        Is64Bit      = [Environment]::Is64BitProcess
        PointerSize  = [IntPtr]::Size
        Architecture = if ([Environment]::Is64BitProcess) { 'x64' } else { 'x86' }
    }
}

function Get-P9HWtsInfoExpectedLayout {
    # Layout the DECODER expects, published independently of the compiled mirror
    # so the two can be cross-checked instead of agreeing by construction.
    #
    # Sequential layout with natural alignment:
    #   eight 4-byte scalars                    32 bytes  (offsets 0..31)
    #   WCHAR[32]                               64 bytes  (offset 32)
    #   WCHAR[17]                               34 bytes  (offset 96)
    #   WCHAR[21]                               42 bytes  (offset 130)
    #   -> 172, padded to 176 for the next 8-byte align
    #   five LARGE_INTEGER                      40 bytes  (offsets 176..215)
    #   => 216 bytes total
    $scalarBytes = 8 * 4
    $stationBytes = $script:P9HWtsStationNameLength * 2
    $domainBytes = $script:P9HWtsDomainLength * 2
    $userBytes = $script:P9HWtsUserNameLength * 2
    $stringBytes = $stationBytes + $domainBytes + $userBytes
    $beforeFileTimes = $scalarBytes + $stringBytes
    $alignedTo = 8
    $padded = [int]([Math]::Ceiling($beforeFileTimes / $alignedTo) * $alignedTo)
    $total = $padded + (5 * 8)

    return [pscustomobject][ordered]@{
        Size            = $total
        ScalarBytes     = $scalarBytes
        StringBytes     = $stringBytes
        AlignedTo       = $alignedTo
        FileTimeBytes   = 5 * 8
        StateOffset     = 0
        SessionIdOffset = 4
        StationOffset   = $scalarBytes
        DomainOffset    = $scalarBytes + $stationBytes
        UserOffset      = $scalarBytes + $stationBytes + $domainBytes
        FileTimeOffset  = $padded
    }
}

function Test-P9HWtsInfoLayout {
    # Cross-check the published contract against the measured native mirror.
    #
    # Three failure modes are distinguished, because they mean different things
    # to an operator:
    #   * layout-unsupported   : this host cannot describe WTSINFO at all;
    #   * layout-size-mismatch : the struct packs differently than documented;
    #   * layout-offset-mismatch: a field sits somewhere else than documented.
    try {
        $native = Get-P9HWtsInfoNativeLayout
    }
    catch {
        return [pscustomobject][ordered]@{
            Ok       = $false
            Reason   = 'layout-unsupported'
            Detail   = $_.Exception.Message
            Expected = $null
            Measured = $null
        }
    }

    $expected = Get-P9HWtsInfoExpectedLayout

    if ($native.Size -ne $expected.Size) {
        return [pscustomobject][ordered]@{
            Ok           = $false
            Reason       = 'layout-size-mismatch'
            Detail       = ('documented {0} bytes, measured {1} bytes' -f $expected.Size, $native.Size)
            Expected     = $expected.Size
            Measured     = $native.Size
            Architecture = $native.Architecture
        }
    }

    $checks = @(
        @{ Name = 'State'; Expected = $expected.StateOffset }
        @{ Name = 'SessionId'; Expected = $expected.SessionIdOffset }
        @{ Name = 'WinStationName'; Expected = $expected.StationOffset }
        @{ Name = 'Domain'; Expected = $expected.DomainOffset }
        @{ Name = 'UserName'; Expected = $expected.UserOffset }
        @{ Name = 'ConnectTime'; Expected = $expected.FileTimeOffset }
        @{ Name = 'LogonTime'; Expected = $expected.FileTimeOffset + 24 }
    )

    foreach ($check in $checks) {
        $measured = [int]$native.Offsets.($check.Name)
        if ($measured -ne [int]$check.Expected) {
            return [pscustomobject][ordered]@{
                Ok           = $false
                Reason       = 'layout-offset-mismatch'
                Detail       = ('{0} at {1}, documented {2}' -f $check.Name, $measured, $check.Expected)
                Expected     = $check.Expected
                Measured     = $measured
                Architecture = $native.Architecture
            }
        }
    }

    return [pscustomobject][ordered]@{
        Ok           = $true
        Reason       = 'ok'
        Detail       = ('WTSINFO verified at {0} bytes on {1}' -f $native.Size, $native.Architecture)
        Size         = $native.Size
        Architecture = $native.Architecture
        PointerSize  = $native.PointerSize
        Offsets      = $native.Offsets
    }
}

function ConvertFrom-P9HFileTimeUtc {
    # Convert one FILETIME (100 ns ticks since 1601-01-01Z) to UTC ISO-8601.
    #
    # A FILETIME of zero is the Win32 'not available' sentinel, NOT the epoch:
    # 1601-01-01 is a legal DateTime, so converting blindly would turn 'no logon
    # time' into a plausible-looking timestamp and defeat the identity check.
    # Zero, negative and out-of-range values are rejected explicitly.
    param([Parameter(Mandatory)][long]$FileTime)

    if ($FileTime -eq 0) {
        return [pscustomobject][ordered]@{ Ok = $false; Reason = 'zero'; Value = $null; Detail = $null }
    }

    if ($FileTime -lt 0) {
        return [pscustomobject][ordered]@{ Ok = $false; Reason = 'negative'; Value = $null; Detail = $null }
    }

    try {
        $utc = [datetime]::FromFileTimeUtc($FileTime)
    }
    catch {
        return [pscustomobject][ordered]@{ Ok = $false; Reason = 'out-of-range'; Value = $null; Detail = $_.Exception.Message }
    }

    if ($utc.Kind -ne [System.DateTimeKind]::Utc) {
        return [pscustomobject][ordered]@{ Ok = $false; Reason = 'not-utc'; Value = $null; Detail = $null }
    }

    # Anything at the FILETIME epoch can only be a provider defect, not a real
    # interactive logon.
    if ($utc.Year -lt 1602) {
        return [pscustomobject][ordered]@{ Ok = $false; Reason = 'epoch-invalid'; Value = $null; Detail = $null }
    }

    return [pscustomobject][ordered]@{
        Ok     = $true
        Reason = 'ok'
        Detail = $null
        Value  = $utc.ToString('o', [System.Globalization.CultureInfo]::InvariantCulture)
    }
}

function ConvertFrom-P9HWtsInfoPayload {
    # Decode one WTSINFO payload into a normalized fact record.
    #
    # Every rejection names its cause so a live failure is diagnosable without
    # re-running the query. This function never invents a value for a field it
    # could not read.
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][byte[]]$Payload,
        [ValidateSet('WTSInfo')][string]$InfoClass = 'WTSInfo',
        [AllowNull()]$Layout = $null
    )

    Initialize-P9HWtsProviderNative

    if ($null -eq $Payload -or @($Payload).Length -eq 0) {
        return [pscustomobject][ordered]@{
            Ok = $false; Reason = 'empty-payload'; Detail = $null; Record = $null
            ReturnedBytes = 0; ExpectedBytes = $null
        }
    }

    if ($null -eq $Layout) { $Layout = Get-P9HWtsInfoNativeLayout }

    $size = [int]$Layout.Size
    if (@($Payload).Length -ne $size) {
        return [pscustomobject][ordered]@{
            Ok            = $false
            Reason        = 'struct-size-mismatch'
            Detail        = ('returned {0} bytes, WTSINFO is {1} bytes on {2}' -f @($Payload).Length, $size, [string]$Layout.Architecture)
            Record        = $null
            ReturnedBytes = @($Payload).Length
            ExpectedBytes = $size
        }
    }

    $facts = [P9HWtsInfoCodec]::Decode($Payload, $size)
    if ($null -eq $facts) {
        return [pscustomobject][ordered]@{
            Ok = $false; Reason = 'decode-failed'; Detail = $null; Record = $null
            ReturnedBytes = @($Payload).Length; ExpectedBytes = $size
        }
    }

    $logon = ConvertFrom-P9HFileTimeUtc -FileTime ([long]$facts.LogonTime)
    $connect = ConvertFrom-P9HFileTimeUtc -FileTime ([long]$facts.ConnectTime)

    $state = [int]$facts.State
    $stateName = if ($script:P9HWtsStateName.ContainsKey($state)) { $script:P9HWtsStateName[$state] } else { "Unknown($state)" }

    # The account is qualified exactly once, here, so downstream matching sees a
    # stable value and never has to guess whether a domain was included.
    $userName = [string]$facts.UserName
    $domain = [string]$facts.Domain
    $account = $userName
    if (-not [string]::IsNullOrWhiteSpace($domain) -and -not [string]::IsNullOrWhiteSpace($userName)) {
        $account = ('{0}\{1}' -f $domain, $userName)
    }

    $record = [pscustomobject][ordered]@{
        SessionId         = [int]$facts.SessionId
        StationName       = [string]$facts.WinStationName
        State             = $state
        StateName         = $stateName
        Domain            = $domain
        User              = $account
        UserName          = $userName
        LogonTime         = if ($logon.Ok) { $logon.Value } else { $null }
        LogonTimeRaw      = [long]$facts.LogonTime
        LogonReason       = $logon.Reason
        LogonSource       = if ($logon.Ok) { 'wtsinfo' } else { ('wtsinfo-' + $logon.Reason) }
        ConnectTime       = if ($connect.Ok) { $connect.Value } else { $null }
        ConnectTimeRaw    = [long]$facts.ConnectTime
        DisconnectTimeRaw = [long]$facts.DisconnectTime
        LastInputTimeRaw  = [long]$facts.LastInputTime
        CurrentTimeRaw    = [long]$facts.CurrentTime
        InfoClass         = $InfoClass
        LayoutBytes       = $size
        Architecture      = [string]$Layout.Architecture
    }

    return [pscustomobject][ordered]@{
        Ok = $true; Reason = 'ok'; Detail = $null; Record = $record
        ReturnedBytes = @($Payload).Length; ExpectedBytes = $size
    }
}

function ConvertTo-P9HWtsProviderLine {
    # Render a decoded fact record as the provider LINE the observer consumes.
    #
    # This is the ONLY integration point with the frozen observer: it emits
    #   <id>|<station>|state=<n>|user=<account>[|logon=<ISO-8601 UTC>]
    # and nothing else. When a logon time is unavailable the trailing segment is
    # OMITTED, which ConvertFrom-P9HLogonTimeField already reports as 'absent'.
    # That keeps a capability gap visible instead of fabricating a timestamp.
    param([Parameter(Mandatory)]$Record)

    $segment = '{0}|{1}|{2}' -f [int]$Record.SessionId, [string]$Record.StationName, ('state=' + [int]$Record.State)
    $userText = [string]$Record.User
    $segment = $segment + '|' + $(if ([string]::IsNullOrWhiteSpace($userText)) { 'user=' } else { 'user=' + $userText })

    $logonText = [string]$Record.LogonTime
    if (-not [string]::IsNullOrWhiteSpace($logonText)) {
        $segment = $segment + '|logon=' + $logonText
    }

    return $segment
}

function Get-P9HWtsProviderCapability {
    # Report whether this host exposes a usable WTSINFO contract.
    #
    # Capability is a LAYOUT question, not a live query: it compiles and measures
    # the mirror and reports what it found. An unsupported layout is reported as
    # an explicit capability gap, which is what the stage requires instead of a
    # fabricated logon time.
    $layout = Test-P9HWtsInfoLayout
    if (-not $layout.Ok) {
        return [pscustomobject][ordered]@{
            Available          = $false
            Capability         = 'unsupported'
            Reason             = $layout.Reason
            Detail             = $layout.Detail
            LogonTimeSupported = $false
            Architecture       = if ($null -ne $layout.PSObject.Properties['Architecture']) { $layout.Architecture } else { $null }
            Size               = $null
        }
    }

    return [pscustomobject][ordered]@{
        Available          = $true
        Capability         = 'wtsinfo'
        Reason             = 'ok'
        Detail             = $layout.Detail
        LogonTimeSupported = $true
        Architecture       = $layout.Architecture
        Size               = $layout.Size
    }
}

function Invoke-P9HWtsSessionQuery {
    # LIVE WTS query. Refuses unless the operator supplies the literal
    # real-execution token.
    #
    # Stage 3A never calls this. Its only Stage 3A exercise is the refusal path,
    # which is what guarantees the adapter cannot touch a live session by
    # accident. Native buffers are released on EVERY path: the WTSINFO block is
    # freed with WTSFreeMemory in a finally block inside the interop helper, so
    # it is released for success, failure and a partial success alike.
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$AuthorizationToken,
        [Parameter(Mandatory)][int]$SessionId,
        [string]$Action = 'WTS session query'
    )

    $null = Assert-P9HRealExecutionAuthorized -AuthorizationToken $AuthorizationToken -Action $Action

    if (-not ([System.Management.Automation.PSTypeName]'P9HWtsApi').Type) {
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class P9HWtsApi
{
    [DllImport("wtsapi32.dll", SetLastError = true)]
    private static extern bool WTSQuerySessionInformationW(
        IntPtr hServer, int sessionId, int wtsInfoClass,
        out IntPtr ppBuffer, out int pBytesReturned);

    [DllImport("wtsapi32.dll")]
    private static extern void WTSFreeMemory(IntPtr pMemory);

    // Returns the raw WTSINFO bytes for one session, or null with the Win32
    // error code. The buffer is released on every path.
    public static byte[] QueryWtsInfo(int sessionId, int wtsInfoClass, out int win32Error)
    {
        win32Error = 0;
        IntPtr buffer = IntPtr.Zero;
        int bytes = 0;

        try
        {
            if (!WTSQuerySessionInformationW(IntPtr.Zero, sessionId, wtsInfoClass, out buffer, out bytes))
            {
                win32Error = Marshal.GetLastWin32Error();
                return null;
            }

            if (buffer == IntPtr.Zero || bytes <= 0) { return null; }

            byte[] payload = new byte[bytes];
            Marshal.Copy(buffer, payload, 0, bytes);
            return payload;
        }
        finally
        {
            // Documented release for every buffer this API returns.
            if (buffer != IntPtr.Zero) { WTSFreeMemory(buffer); }
        }
    }
}
'@ -ErrorAction Stop
    }

    $win32Error = 0
    $payload = [P9HWtsApi]::QueryWtsInfo($SessionId, $script:P9HWtsInfoClassInfo, [ref]$win32Error)

    if ($null -eq $payload) {
        return [pscustomobject][ordered]@{
            Ok         = $false
            Reason     = 'native-query-failed'
            Win32Error = $win32Error
            Detail     = ('WTSQuerySessionInformationW failed for session {0} (Win32 {1})' -f $SessionId, $win32Error)
            Record     = $null
        }
    }

    return ConvertFrom-P9HWtsInfoPayload -Payload $payload -Layout (Get-P9HWtsInfoNativeLayout)
}

function Get-P9HWtsProviderCapture {
    # Produce provider lines for a target session from already-decoded records.
    #
    # Separate from any live query so the whole observer path can be exercised
    # from synthetic facts. `-Records` are fact records (from the decoder or a
    # test) and the result is the exact line array New-P9HObserverRecord takes.
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Records,
        [Parameter(Mandatory)][int]$TargetSessionId
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $targets = [System.Collections.Generic.List[object]]::new()

    foreach ($record in @($Records)) {
        if ($null -eq $record) { continue }
        $lines.Add((ConvertTo-P9HWtsProviderLine -Record $record)) | Out-Null
        if ([int]$record.SessionId -eq $TargetSessionId) { $targets.Add($record) | Out-Null }
    }

    return [pscustomobject][ordered]@{
        Lines           = @($lines)
        TargetRecords   = @($targets)
        TargetCount     = $targets.Count
        RecordCount     = @($Records).Count
        TargetSessionId = $TargetSessionId
    }
}
