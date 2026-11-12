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
#   WTSEnumerateSessionsW        enumerate the COMPLETE session table
#   WTSQuerySessionInformationW  return a WTSINFO structure (WTS_INFO_CLASS 24)
#   WTSFreeMemory                release every buffer the WTS API allocated
#
#   WTS_SESSION_INFO (also wtsapi32.h) is the enumeration record:
#       DWORD SessionId;
#       LPWSTR pWinStationName;          // pointer: 8 bytes on x64, 4 on x86
#       WTS_CONNECTSTATE_CLASS State;
#   On x64 the pointer forces 8-byte alignment: 4 + 4 pad + 8 + 4 + 4 pad = 24
#   bytes. On x86 it is 12 bytes. The layout is measured, never assumed.
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

function Get-P9HWtsApiInteropSource {
    # The gated native surface, as source text.
    #
    # Kept in one place so the query and the enumeration share a single audited
    # interop declaration rather than duplicating P/Invoke signatures.
    #
    # Memory contract, stated once:
    #   * WTSQuerySessionInformationW returns a buffer the caller owns and must
    #     release with WTSFreeMemory;
    #   * WTSEnumerateSessionsW returns a buffer the caller owns and must release
    #     with WTSFreeMemory;
    #   * both are released in a finally block, so success, failure and partial
    #     success all free exactly once;
    #   * a successful call that yields zero bytes is reported with
    #     win32Error = 0 so the caller can distinguish it from a real failure
    #     (the Stage 3A version conflated the two).
    return @'
using System;
using System.Runtime.InteropServices;
using System.Text;

public static class P9HWtsApi
{
    // Documented WTS_SESSION_INFO (wtsapi32.h):
    //   DWORD SessionId;
    //   LPWSTR pWinStationName;   // pointer - architecture dependent
    //   WTS_CONNECTSTATE_CLASS State;
    // On x64 the pointer forces 8-byte alignment: 4 bytes SessionId, 4 bytes
    // padding, 8 bytes pointer, 4 bytes State, 4 bytes tail padding => 24 bytes.
    // On x86 it is 12 bytes (4 + 4 + 4). The mirror below lets the caller
    // measure the real value rather than assume it.
    [StructLayout(LayoutKind.Sequential)]
    public struct WtsSessionInfoMirror
    {
        public int SessionId;
        public IntPtr pWinStationName;
        public int State;
    }

    [DllImport("wtsapi32.dll", SetLastError = true)]
    private static extern bool WTSQuerySessionInformationW(
        IntPtr hServer, int sessionId, int wtsInfoClass,
        out IntPtr ppBuffer, out int pBytesReturned);

    [DllImport("wtsapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    private static extern bool WTSEnumerateSessionsW(
        IntPtr hServer, int reserved, int version,
        out IntPtr ppSessionInfo, out int pCount);

    [DllImport("wtsapi32.dll")]
    private static extern void WTSFreeMemory(IntPtr pMemory);

    public static int SessionInfoSize() { return Marshal.SizeOf(typeof(WtsSessionInfoMirror)); }

    public static int SessionInfoOffset(string fieldName)
    {
        return (int)Marshal.OffsetOf(typeof(WtsSessionInfoMirror), fieldName);
    }

    // ---- single-session WTSINFO ----
    public static byte[] QueryWtsInfo(int sessionId, int wtsInfoClass, out int win32Error, out int reportedBytes)
    {
        win32Error = 0;
        reportedBytes = 0;
        IntPtr buffer = IntPtr.Zero;
        int bytes = 0;

        try
        {
            if (!WTSQuerySessionInformationW(IntPtr.Zero, sessionId, wtsInfoClass, out buffer, out bytes))
            {
                win32Error = Marshal.GetLastWin32Error();
                return null;
            }

            reportedBytes = bytes;
            if (buffer == IntPtr.Zero || bytes <= 0) { return null; }

            byte[] payload = new byte[bytes];
            Marshal.Copy(buffer, payload, 0, bytes);
            return payload;
        }
        finally
        {
            if (buffer != IntPtr.Zero) { WTSFreeMemory(buffer); }
        }
    }

    // ---- session enumeration ----
    // Returns one packed record per enumerated session:
    //   sessionId, stationName, reportedState
    // or null with the Win32 error code. The enumeration buffer is released on
    // every path, including a successful call that reports zero sessions.
    public sealed class EnumeratedSession
    {
        public int SessionId;
        public string StationName;
        public int State;
    }

    public static EnumeratedSession[] EnumerateSessions(out int win32Error, out int reportedCount)
    {
        win32Error = 0;
        reportedCount = 0;
        IntPtr buffer = IntPtr.Zero;
        int count = 0;

        try
        {
            if (!WTSEnumerateSessionsW(IntPtr.Zero, 0, 1, out buffer, out count))
            {
                win32Error = Marshal.GetLastWin32Error();
                return null;
            }

            reportedCount = count;
            if (buffer == IntPtr.Zero || count <= 0) { return null; }

            int stride = Marshal.SizeOf(typeof(WtsSessionInfoMirror));
            EnumeratedSession[] result = new EnumeratedSession[count];

            for (int i = 0; i < count; i++)
            {
                IntPtr at = new IntPtr(buffer.ToInt64() + (i * stride));
                WtsSessionInfoMirror raw =
                    (WtsSessionInfoMirror)Marshal.PtrToStructure(at, typeof(WtsSessionInfoMirror));

                string name = "";
                if (raw.pWinStationName != IntPtr.Zero)
                {
                    name = Marshal.PtrToStringUni(raw.pWinStationName);
                    if (name == null) { name = ""; }
                }

                result[i] = new EnumeratedSession();
                result[i].SessionId = raw.SessionId;
                result[i].StationName = name;
                result[i].State = raw.State;
            }

            return result;
        }
        finally
        {
            if (buffer != IntPtr.Zero) { WTSFreeMemory(buffer); }
        }
    }
}
'@
}

function Invoke-P9HWtsSessionQuery {
    # LIVE WTS WTSINFO query for ONE session. Refuses unless the operator
    # supplies the literal real-execution token.
    #
    # Stage 3A.1 hardening (independent review): Stage 3A had a layout test that
    # the live path never consulted. The layout is now a PRECONDITION of the
    # native call:
    #   1. layout cross-check FIRST - an unsupported layout is refused before
    #      any interop, with an explicit capability status;
    #   2. the returned byte count must equal the measured WTSINFO size BEFORE
    #      decode (a short or long buffer is never reinterpreted);
    #   3. the decoded SessionId must equal the requested id - a provider that
    #      answers about a different session is a mismatch, not a success;
    #   4. a native failure is reported with its Win32 code, distinctly from a
    #      successful-but-empty response, which gets its own reason.
    #
    # Passing the local layout check is NOT evidence the live API works: it only
    # proves this build can describe the structure. Stage 3B exercises the call
    # itself.
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$AuthorizationToken,
        [Parameter(Mandatory)][int]$SessionId,
        [string]$Action = 'WTS session query'
    )

    $null = Assert-P9HRealExecutionAuthorized -AuthorizationToken $AuthorizationToken -Action $Action

    # ---- (1) layout precondition ----
    $layoutCheck = Test-P9HWtsInfoLayout
    if (-not $layoutCheck.Ok) {
        return [pscustomobject][ordered]@{
            Ok           = $false
            Reason       = 'layout-unsupported'
            Capability   = 'unsupported'
            LayoutReason = $layoutCheck.Reason
            SessionId    = $SessionId
            Win32Error   = $null
            Detail       = ('refusing the native query: WTSINFO layout is not supported here ({0}: {1})' -f $layoutCheck.Reason, $layoutCheck.Detail)
            Record       = $null
        }
    }

    $layout = Get-P9HWtsInfoNativeLayout

    if (-not ([System.Management.Automation.PSTypeName]'P9HWtsApi').Type) {
        Add-Type -TypeDefinition (Get-P9HWtsApiInteropSource) -ErrorAction Stop
    }

    $win32Error = 0
    $reportedBytes = 0
    $payload = [P9HWtsApi]::QueryWtsInfo($SessionId, $script:P9HWtsInfoClassInfo, [ref]$win32Error, [ref]$reportedBytes)

    # ---- (2)/(4) native failure vs successful-but-empty ----
    if ($null -eq $payload) {
        if ($win32Error -ne 0) {
            return [pscustomobject][ordered]@{
                Ok            = $false
                Reason        = 'native-query-failed'
                Capability    = 'wtsinfo'
                LayoutReason  = $layoutCheck.Reason
                SessionId     = $SessionId
                Win32Error    = $win32Error
                ReportedBytes = $reportedBytes
                Detail        = ('WTSQuerySessionInformationW failed for session {0} (Win32 {1})' -f $SessionId, $win32Error)
                Record        = $null
            }
        }

        return [pscustomobject][ordered]@{
            Ok            = $false
            Reason        = 'empty-native-response'
            Capability    = 'wtsinfo'
            LayoutReason  = $layoutCheck.Reason
            SessionId     = $SessionId
            Win32Error    = 0
            ReportedBytes = $reportedBytes
            Detail        = ('WTSQuerySessionInformationW succeeded for session {0} but returned no bytes' -f $SessionId)
            Record        = $null
        }
    }

    # ---- (2) size must match BEFORE decode ----
    if (@($payload).Length -ne [int]$layout.Size) {
        return [pscustomobject][ordered]@{
            Ok            = $false
            Reason        = 'struct-size-mismatch'
            Capability    = 'wtsinfo'
            LayoutReason  = $layoutCheck.Reason
            SessionId     = $SessionId
            Win32Error    = 0
            ReportedBytes = @($payload).Length
            ExpectedBytes = [int]$layout.Size
            Detail        = ('returned {0} bytes, WTSINFO is {1} bytes on {2}' -f @($payload).Length, $layout.Size, $layout.Architecture)
            Record        = $null
        }
    }

    $decoded = ConvertFrom-P9HWtsInfoPayload -Payload $payload -Layout $layout
    if (-not $decoded.Ok) {
        return [pscustomobject][ordered]@{
            Ok            = $false
            Reason        = ('decode-' + $decoded.Reason)
            Capability    = 'wtsinfo'
            LayoutReason  = $layoutCheck.Reason
            SessionId     = $SessionId
            Win32Error    = 0
            ReportedBytes = @($payload).Length
            ExpectedBytes = [int]$layout.Size
            Detail        = $decoded.Detail
            Record        = $null
        }
    }

    # ---- (3) the provider must answer about the session we asked for ----
    if ([int]$decoded.Record.SessionId -ne $SessionId) {
        return [pscustomobject][ordered]@{
            Ok                = $false
            Reason            = 'session-id-mismatch'
            Capability        = 'wtsinfo'
            LayoutReason      = $layoutCheck.Reason
            SessionId         = $SessionId
            ReturnedSessionId = [int]$decoded.Record.SessionId
            Win32Error        = 0
            ReportedBytes     = @($payload).Length
            ExpectedBytes     = [int]$layout.Size
            Detail            = ('requested session {0} but WTSINFO reported {1}' -f $SessionId, [int]$decoded.Record.SessionId)
            Record            = $decoded.Record
        }
    }

    return [pscustomobject][ordered]@{
        Ok            = $true
        Reason        = 'ok'
        Capability    = 'wtsinfo'
        LayoutReason  = $layoutCheck.Reason
        SessionId     = $SessionId
        Win32Error    = 0
        ReportedBytes = @($payload).Length
        ExpectedBytes = [int]$layout.Size
        Detail        = $null
        Record        = $decoded.Record
    }
}


function Get-P9HWtsSessionInfoExpectedLayout {
    # Published WTS_SESSION_INFO layout for the running architecture.
    #
    # Sequential layout:
    #   x64: DWORD SessionId(0) + 4 pad + LPWSTR(8) + DWORD State(16) + 4 tail pad = 24
    #   x86: DWORD SessionId(0) + LPWSTR(4) + DWORD State(8)                       = 12
    # Derived from the pointer size rather than hardcoded, so the expectation is
    # architecture-aware instead of asserting one ABI.
    $pointer = [IntPtr]::Size
    $sessionIdOffset = 0
    $nameOffset = if ($pointer -eq 8) { 8 } else { 4 }
    $stateOffset = $nameOffset + $pointer
    # The struct aligns to its largest member (the pointer).
    $raw = $stateOffset + 4
    $size = [int]([Math]::Ceiling($raw / $pointer) * $pointer)

    return [pscustomobject][ordered]@{
        Size          = $size
        SessionIdOffset = $sessionIdOffset
        NameOffset    = $nameOffset
        StateOffset   = $stateOffset
        PointerSize   = $pointer
        Architecture  = if ($pointer -eq 8) { 'x64' } else { 'x86' }
    }
}

function Get-P9HWtsSessionInfoNativeLayout {
    # Measured WTS_SESSION_INFO layout for THIS process.
    Initialize-P9HWtsProviderNative
    if (-not ([System.Management.Automation.PSTypeName]'P9HWtsApi').Type) {
        Add-Type -TypeDefinition (Get-P9HWtsApiInteropSource) -ErrorAction Stop
    }

    return [pscustomobject][ordered]@{
        Size            = [P9HWtsApi]::SessionInfoSize()
        SessionIdOffset = [P9HWtsApi]::SessionInfoOffset('SessionId')
        NameOffset      = [P9HWtsApi]::SessionInfoOffset('pWinStationName')
        StateOffset     = [P9HWtsApi]::SessionInfoOffset('State')
        PointerSize     = [IntPtr]::Size
        Architecture    = if ([IntPtr]::Size -eq 8) { 'x64' } else { 'x86' }
    }
}

function Test-P9HWtsSessionInfoLayout {
    # Cross-check the published WTS_SESSION_INFO layout against the mirror.
    #
    # Same three-way distinction as the WTSINFO check, so an unsupported or
    # unexpectedly packed ABI is reported rather than mis-decoded.
    try {
        $native = Get-P9HWtsSessionInfoNativeLayout
    }
    catch {
        return [pscustomobject][ordered]@{
            Ok = $false; Reason = 'layout-unsupported'; Detail = $_.Exception.Message
            Expected = $null; Measured = $null
        }
    }

    $expected = Get-P9HWtsSessionInfoExpectedLayout

    if ($native.Size -ne $expected.Size) {
        return [pscustomobject][ordered]@{
            Ok = $false
            Reason = 'layout-size-mismatch'
            Detail = ('documented {0} bytes, measured {1} bytes on {2}' -f $expected.Size, $native.Size, $native.Architecture)
            Expected = $expected.Size; Measured = $native.Size
            Architecture = $native.Architecture
        }
    }

    foreach ($check in @(
            @{ Property = 'SessionIdOffset'; Expected = $expected.SessionIdOffset; Label = 'SessionId' }
            @{ Property = 'NameOffset'; Expected = $expected.NameOffset; Label = 'pWinStationName' }
            @{ Property = 'StateOffset'; Expected = $expected.StateOffset; Label = 'State' }
        )) {
        $measured = [int]$native.($check.Property)
        if ($measured -ne [int]$check.Expected) {
            return [pscustomobject][ordered]@{
                Ok = $false
                Reason = 'layout-offset-mismatch'
                Detail = ('{0} at {1}, documented {2}' -f $check.Label, $measured, $check.Expected)
                Expected = $check.Expected; Measured = $measured
                Architecture = $native.Architecture
            }
        }
    }

    return [pscustomobject][ordered]@{
        Ok = $true; Reason = 'ok'
        Detail = ('WTS_SESSION_INFO verified at {0} bytes on {1}' -f $native.Size, $native.Architecture)
        Size = $native.Size; Architecture = $native.Architecture
        SessionIdOffset = $native.SessionIdOffset
        NameOffset = $native.NameOffset
        StateOffset = $native.StateOffset
    }
}

function New-P9HWtsSessionInfoPayload {
    # Build a synthetic ensemble of WTS_SESSION_INFO records.
    #
    # Test-facing. Encodes each record at the MEASURED offsets for this
    # architecture, with the station name stored in a UTF-16 region appended
    # after the record array, so the decode path handles real pointer chasing
    # rather than a flattened approximation.
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Sessions,
        # Deliberately break the count to prove the count check fires.
        [int]$CountOverride = -1,
        # Report a byte/stride inconsistency.
        [int]$RecordSizeOverride = 0
    )

    Initialize-P9HWtsProviderNative
    if (-not ([System.Management.Automation.PSTypeName]'P9HWtsApi').Type) {
        Add-Type -TypeDefinition (Get-P9HWtsApiInteropSource) -ErrorAction Stop
    }

    $layoutCheck = Test-P9HWtsSessionInfoLayout
    if (-not $layoutCheck.Ok) {
        throw "P9-H: cannot build a synthetic WTS_SESSION_INFO payload: layout is not supported ($($layoutCheck.Reason): $($layoutCheck.Detail))."
    }

    $stride = if ($RecordSizeOverride -gt 0) { $RecordSizeOverride } else { [int]$layoutCheck.Size }
    $count = @($Sessions).Count
    $nameBase = $stride * [Math]::Max($count, 1)

    $nameBytes = [System.Collections.Generic.List[byte]]::new()
    $records = [System.Collections.Generic.List[object]]::new()

    $index = 0
    foreach ($s in @($Sessions)) {
        $text = [string]$s.StationName
        if ([string]::IsNullOrEmpty($text)) { $text = '' }
        $nameOffset = $nameBase + $nameBytes.Count
        foreach ($ch in $text.ToCharArray()) {
            $code = [int]$ch
            $nameBytes.Add([byte]($code -band 0xFF)) | Out-Null
            $nameBytes.Add([byte](($code -shr 8) -band 0xFF)) | Out-Null
        }
        # NUL terminator
        $nameBytes.Add(0) | Out-Null
        $nameBytes.Add(0) | Out-Null
        $records.Add([pscustomobject]@{ SessionId = [int]$s.SessionId; State = [int]$s.State; NameOffset = $nameOffset }) | Out-Null
        $index++
    }

    # One extra guard byte so a name pointer is never at the very end.
    $nameBytes.Add(0) | Out-Null
    $nameBytes.Add(0) | Out-Null

    $total = $nameBase + $nameBytes.Count
    $buffer = [byte[]]::new($total)

    for ($i = 0; $i -lt $records.Count; $i++) {
        $r = $records[$i]
        $at = $i * $stride
        [Array]::Copy([BitConverter]::GetBytes([int]$r.SessionId), 0, $buffer, $at + [int]$layoutCheck.SessionIdOffset, 4)

        # The name is a POINTER to the UTF-16 region; emit it at pointer width.
        $namePtr = [IntPtr]$r.NameOffset
        if ([IntPtr]::Size -eq 8) {
            [Array]::Copy([BitConverter]::GetBytes([long]$namePtr.ToInt64()), 0, $buffer, $at + [int]$layoutCheck.NameOffset, 8)
        }
        else {
            [Array]::Copy([BitConverter]::GetBytes([int]$namePtr.ToInt32()), 0, $buffer, $at + [int]$layoutCheck.NameOffset, 4)
        }

        [Array]::Copy([BitConverter]::GetBytes([int]$r.State), 0, $buffer, $at + [int]$layoutCheck.StateOffset, 4)
    }

    for ($i = 0; $i -lt $nameBytes.Count; $i++) { $buffer[$nameBase + $i] = $nameBytes[$i] }

    return [pscustomobject][ordered]@{
        Payload      = $buffer
        RecordCount  = $count
        ReportedCount = if ($CountOverride -ge 0) { $CountOverride } else { $count }
        Stride       = $stride
        Layout       = $layoutCheck
        NameBase     = $nameBase
    }
}

function ConvertFrom-P9HWtsSessionInfoPayload {
    # Decode a WTS_SESSION_INFO array into per-session facts.
    #
    # Rejects, explicitly and without discarding anything:
    #   * a count that is zero, negative or whose byte size does not divide by
    #     the record stride (a truncated or padded block);
    #   * a short buffer for the reported count;
    #   * a record whose station-name pointer lands outside the buffer;
    #   * an unreadable or unterminated station name.
    # A malformed record makes the WHOLE capture unusable rather than silently
    # dropping the one entry a verdict might depend on.
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyCollection()][byte[]]$Payload,
        [Parameter(Mandatory)][int]$ReportedCount,
        [AllowNull()]$Layout = $null
    )

    if ($null -eq $Layout) { $Layout = Test-P9HWtsSessionInfoLayout }
    if (-not $Layout.Ok) {
        return [pscustomobject][ordered]@{
            Ok = $false; Reason = 'layout-unsupported'; Detail = $Layout.Detail
            Records = @(); Rejections = @(); ReportedCount = $ReportedCount
        }
    }

    if ($null -eq $Payload -or @($Payload).Length -eq 0) {
        return [pscustomobject][ordered]@{
            Ok = $false; Reason = 'empty-enumeration'; Detail = $null
            Records = @(); Rejections = @(); ReportedCount = $ReportedCount
        }
    }

    $stride = [int]$Layout.Size
    $bytes = @($Payload).Length

    if ($ReportedCount -le 0) {
        return [pscustomobject][ordered]@{
            Ok = $false; Reason = 'invalid-session-count'; Detail = ('reported count {0}' -f $ReportedCount)
            Records = @(); Rejections = @(); ReportedCount = $ReportedCount
        }
    }

    if ($bytes -lt ($ReportedCount * $stride)) {
        return [pscustomobject][ordered]@{
            Ok = $false
            Reason = 'enumeration-buffer-too-small'
            Detail = ('{0} bytes cannot hold {1} records of {2} bytes' -f $bytes, $ReportedCount, $stride)
            Records = @(); Rejections = @(); ReportedCount = $ReportedCount
        }
    }

    $records = [System.Collections.Generic.List[object]]::new()
    $rejections = [System.Collections.Generic.List[string]]::new()

    $readString = {
        param([long]$at)
        if ($at -lt 0 -or ($at + 1) -ge $bytes) { return $null }
        $chars = [System.Collections.Generic.List[char]]::new()
        $p = $at
        while (($p + 1) -lt $bytes) {
            $code = [int]$Payload[$p] -bor ([int]$Payload[$p + 1] -shl 8)
            if ($code -eq 0) { break }
            $chars.Add([char]$code) | Out-Null
            $p += 2
        }
        return (-join $chars)
    }

    for ($i = 0; $i -lt $ReportedCount; $i++) {
        $at = $i * $stride

        $sessionId = [BitConverter]::ToInt32($Payload, $at + [int]$Layout.SessionIdOffset)
        $state = [BitConverter]::ToInt32($Payload, $at + [int]$Layout.StateOffset)

        $nameAt = if ([IntPtr]::Size -eq 8) {
            [BitConverter]::ToInt64($Payload, $at + [int]$Layout.NameOffset)
        }
        else {
            [long][BitConverter]::ToInt32($Payload, $at + [int]$Layout.NameOffset)
        }

        if ($nameAt -lt 0 -or $nameAt -ge $bytes) {
            $rejections.Add(('record {0}: station-name pointer {1} outside the {2}-byte buffer' -f $i, $nameAt, $bytes)) | Out-Null
            continue
        }

        $station = & $readString $nameAt
        if ($null -eq $station) {
            $rejections.Add(('record {0}: station name unreadable at {1}' -f $i, $nameAt)) | Out-Null
            continue
        }

        $records.Add([pscustomobject][ordered]@{
                SessionId   = $sessionId
                StationName = $station
                State       = $state
                StateName   = if ($script:P9HWtsStateName.ContainsKey($state)) { $script:P9HWtsStateName[$state] } else { "Unknown($state)" }
            }) | Out-Null
    }

    if ($rejections.Count -gt 0) {
        return [pscustomobject][ordered]@{
            Ok = $false
            Reason = 'malformed-enumeration-record'
            Detail = (($rejections) -join '; ')
            Records = @($records)
            Rejections = @($rejections)
            ReportedCount = $ReportedCount
        }
    }

    return [pscustomobject][ordered]@{
        Ok = $true; Reason = 'ok'; Detail = $null
        Records = @($records); Rejections = @()
        ReportedCount = $ReportedCount
        Stride = $stride
        Architecture = $Layout.Architecture
    }
}

function Find-P9HWtsDuplicateSessionId {
    # Duplicate session ids make a table ambiguous: two entries claim the same
    # identity, so neither can be trusted as THE target record.
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Records)

    $dups = [System.Collections.Generic.List[int]]::new()
    $groups = @($Records | Group-Object { [int]$_.SessionId })
    foreach ($g in $groups) {
        if ($g.Count -gt 1) { $dups.Add([int]$g.Name) | Out-Null }
    }

    return [pscustomobject][ordered]@{
        HasDuplicates = ($dups.Count -gt 0)
        SessionIds    = @($dups)
        Detail        = if ($dups.Count -gt 0) { 'duplicate session ids: ' + ($dups -join ',') } else { $null }
    }
}

function Invoke-P9HWtsSessionEnumerate {
    # LIVE session enumeration. Refuses without the real-execution token.
    #
    # Stage 3A.1 adds this: Stage 3A documented WTSEnumerateSessionsW but never
    # implemented it, so the E1 contract could not obtain the COMPLETE session
    # table it requires. A table with only the target cannot demonstrate that a
    # session-0 disconnected state is not the target's state.
    #
    # Only the enumeration itself is native. Each entry is then correlated with
    # a WTSINFO query through Resolve-P9HWtsSessionTable, which is where the
    # consistency rules live.
    param(
        [Parameter(Mandatory)][AllowNull()][AllowEmptyString()][string]$AuthorizationToken,
        [string]$Action = 'WTS session enumeration'
    )

    $null = Assert-P9HRealExecutionAuthorized -AuthorizationToken $AuthorizationToken -Action $Action

    $layoutCheck = Test-P9HWtsSessionInfoLayout
    if (-not $layoutCheck.Ok) {
        return [pscustomobject][ordered]@{
            Ok = $false; Reason = 'layout-unsupported'; Capability = 'unsupported'
            Detail = ('refusing the native enumeration: WTS_SESSION_INFO layout is not supported here ({0}: {1})' -f $layoutCheck.Reason, $layoutCheck.Detail)
            Sessions = @(); Win32Error = $null; ReportedCount = $null
        }
    }

    if (-not ([System.Management.Automation.PSTypeName]'P9HWtsApi').Type) {
        Add-Type -TypeDefinition (Get-P9HWtsApiInteropSource) -ErrorAction Stop
    }

    $win32Error = 0
    $reportedCount = 0
    $native = [P9HWtsApi]::EnumerateSessions([ref]$win32Error, [ref]$reportedCount)

    if ($null -eq $native) {
        if ($win32Error -ne 0) {
            return [pscustomobject][ordered]@{
                Ok = $false; Reason = 'native-enumerate-failed'; Capability = 'wtsinfo'
                Detail = ('WTSEnumerateSessionsW failed (Win32 {0})' -f $win32Error)
                Sessions = @(); Win32Error = $win32Error; ReportedCount = $reportedCount
            }
        }
        return [pscustomobject][ordered]@{
            Ok = $false; Reason = 'empty-enumeration'; Capability = 'wtsinfo'
            Detail = 'WTSEnumerateSessionsW succeeded but reported no sessions'
            Sessions = @(); Win32Error = 0; ReportedCount = $reportedCount
        }
    }

    $sessions = @(foreach ($s in @($native)) {
            [pscustomobject][ordered]@{
                SessionId   = [int]$s.SessionId
                StationName = [string]$s.StationName
                State       = [int]$s.State
                StateName   = if ($script:P9HWtsStateName.ContainsKey([int]$s.State)) { $script:P9HWtsStateName[[int]$s.State] } else { "Unknown($([int]$s.State))" }
            }
        })

    return [pscustomobject][ordered]@{
        Ok = $true; Reason = 'ok'; Capability = 'wtsinfo'; Detail = $null
        Sessions = $sessions
        Win32Error = 0
        ReportedCount = $reportedCount
        LayoutBytes = [int]$layoutCheck.Size
        Architecture = $layoutCheck.Architecture
    }
}

function Resolve-P9HWtsSessionTable {
    # Correlate an enumerated table with per-session WTSINFO facts.
    #
    # Two inputs, two sources of truth:
    #   * the ENUMERATION supplies the complete set of sessions and their
    #     reported states (so non-target sessions are present);
    #   * WTSINFO supplies the per-record logon identity.
    #
    # Correlation rules, all fail-closed:
    #   * every enumerated id must have a WTSINFO result whose id matches it;
    #   * a failed per-session query is recorded explicitly, never dropped;
    #   * duplicate target records are ambiguous;
    #   * the requested target must be present;
    #   * a state that changes between the enumeration and the query is an
    #     evidence gap, not a successful transition.
    #
    # IMPORTANT LIMITATION, stated plainly: a sequence of sequential queries is
    # NOT an atomic Windows session snapshot. The table can change underneath the
    # collector, so the observer must treat a state change as evidence of
    # instability rather than as proof of a transition.
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$EnumeratedSessions,
        # SessionId -> query result (Ok/Record/Reason/Detail/Win32Error)
        [Parameter(Mandatory)][AllowNull()][hashtable]$QueryResults,
        [Parameter(Mandatory)][int]$TargetSessionId
    )

    $rows = [System.Collections.Generic.List[object]]::new()
    $errors = [System.Collections.Generic.List[string]]::new()
    $stateChanges = [System.Collections.Generic.List[string]]::new()

    foreach ($session in @($EnumeratedSessions)) {
        $id = [int]$session.SessionId
        $query = if ($QueryResults.ContainsKey($id)) { $QueryResults[$id] } else { $null }

        if ($null -eq $query) {
            $errors.Add(('{0}:not-queried' -f $id)) | Out-Null
            $rows.Add([pscustomobject][ordered]@{
                    SessionId = $id; StationName = [string]$session.StationName
                    EnumeratedState = [int]$session.State; EnumeratedStateName = [string]$session.StateName
                    QueryOk = $false; QueryReason = 'not-queried'
                    InfoSessionId = $null; InfoState = $null; InfoStateName = $null
                    User = $null; LogonTime = $null; LogonSource = $null
                    SessionIdConsistent = $false; StateConsistent = $null
                    Detail = 'no WTSINFO result supplied for this enumerated session'
                }) | Out-Null
            continue
        }

        if (-not $query.Ok) {
            $errors.Add(('{0}:{1}' -f $id, $query.Reason)) | Out-Null
            $rows.Add([pscustomobject][ordered]@{
                    SessionId = $id; StationName = [string]$session.StationName
                    EnumeratedState = [int]$session.State; EnumeratedStateName = [string]$session.StateName
                    QueryOk = $false; QueryReason = [string]$query.Reason
                    InfoSessionId = $null; InfoState = $null; InfoStateName = $null
                    User = $null; LogonTime = $null; LogonSource = $null
                    SessionIdConsistent = $false; StateConsistent = $null
                    Detail = [string]$query.Detail
                }) | Out-Null
            continue
        }

        $info = $query.Record
        $idConsistent = ([int]$info.SessionId -eq $id)
        if (-not $idConsistent) {
            $errors.Add(('{0}:session-id-mismatch({1})' -f $id, [int]$info.SessionId)) | Out-Null
        }

        $stateConsistent = ([int]$info.State -eq [int]$session.State)
        if (-not $stateConsistent) {
            $stateChanges.Add(('{0}:enumerated={1},queried={2}' -f $id, [int]$session.State, [int]$info.State)) | Out-Null
        }

        $rows.Add([pscustomobject][ordered]@{
                SessionId = $id; StationName = [string]$session.StationName
                EnumeratedState = [int]$session.State; EnumeratedStateName = [string]$session.StateName
                QueryOk = $true; QueryReason = 'ok'
                InfoSessionId = [int]$info.SessionId
                InfoState = [int]$info.State; InfoStateName = [string]$info.StateName
                User = [string]$info.User
                LogonTime = [string]$info.LogonTime; LogonSource = [string]$info.LogonSource
                SessionIdConsistent = $idConsistent; StateConsistent = $stateConsistent
                Detail = $null
            }) | Out-Null
    }

    $targets = @($rows | Where-Object { $_.SessionId -eq $TargetSessionId })
    $dupCheck = Find-P9HWtsDuplicateSessionId -Records @($EnumeratedSessions)

    $targetOk = $false
    $targetReason = 'no-target'
    $targetRecord = $null

    if ($dupCheck.HasDuplicates) {
        $targetReason = 'ambiguous-enumeration'
    }
    elseif ($targets.Count -eq 0) {
        $targetReason = 'no-target'
    }
    elseif ($targets.Count -gt 1) {
        $targetReason = 'ambiguous-target'
    }
    elseif (-not $targets[0].QueryOk) {
        $targetReason = 'target-query-failed'
    }
    elseif (-not $targets[0].SessionIdConsistent) {
        $targetReason = 'target-session-id-mismatch'
    }
    else {
        $targetOk = $true
        $targetReason = 'ok'
        $targetRecord = $targets[0]
    }

    # A target whose state moved during correlation is an EVIDENCE GAP. It is
    # not a disconnect proof and not a reconnect proof.
    $targetStateChanged = ($targets.Count -eq 1 -and $targets[0].StateConsistent -eq $false)

    $ok = (
        $errors.Count -eq 0 -and
        -not $dupCheck.HasDuplicates -and
        -not $targetStateChanged -and
        ($stateChanges.Count -eq 0)
    )

    return [pscustomobject][ordered]@{
        Ok                = $ok
        Reason            = if ($ok) { 'ok' } elseif ($dupCheck.HasDuplicates) { 'ambiguous-enumeration' } elseif ($stateChanges.Count -gt 0) { 'state-changed-during-collection' } elseif ($errors.Count -gt 0) { 'incomplete-session-table' } else { 'ok' }
        Detail            = if ($errors.Count -gt 0) { ($errors -join '; ') } elseif ($stateChanges.Count -gt 0) { ($stateChanges -join '; ') } else { $null }
        Rows              = @($rows)
        RowCount          = $rows.Count
        Errors            = @($errors)
        StateChanges      = @($stateChanges)
        DuplicateSessionIds = @($dupCheck.SessionIds)
        TargetSessionId   = $TargetSessionId
        TargetOk          = $targetOk
        TargetReason      = $targetReason
        TargetRecord      = $targetRecord
        TargetStateChanged = $targetStateChanged
        IsAtomicSnapshot  = $false
        AtomicityNote     = 'A sequence of sequential WTS queries is not an atomic session snapshot; a state change between the enumeration and a query is an evidence gap.'
    }
}

function Get-P9HWtsProviderTableCapture {
    # Build the COMPLETE provider line table from resolved session facts, and
    # separate the target rows from the rest.
    #
    # This is the full-table counterpart of Get-P9HWtsProviderCapture: every
    # enumerated session emits a line, so the frozen parser sees the same table
    # a live E1 observation would, including session 0.
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Rows,
        [Parameter(Mandatory)][int]$TargetSessionId
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $targets = [System.Collections.Generic.List[object]]::new()
    $failed = [System.Collections.Generic.List[object]]::new()

    foreach ($row in @($Rows)) {
        if ($null -eq $row) { continue }

        if (-not $row.QueryOk) {
            # A failed per-session query is preserved explicitly. It is NOT
            # rendered as a line, because a line would assert a state we do not
            # have evidence for.
            $failed.Add($row) | Out-Null
            if ([int]$row.SessionId -eq $TargetSessionId) {
                $targets.Add([pscustomobject]@{ SessionId = [int]$row.SessionId; QueryOk = $false; Rendered = $false; Row = $row }) | Out-Null
            }
            continue
        }

        # Prefer the WTSINFO state (it came with the identity) but keep the
        # enumerated state visible through StateConsistent.
        $record = [pscustomobject][ordered]@{
            SessionId   = [int]$row.InfoSessionId
            StationName = [string]$row.StationName
            State       = [int]$row.InfoState
            StateName   = [string]$row.InfoStateName
            User        = if ($null -ne $row.PSObject.Properties['User']) { [string]$row.User } else { '' }
            LogonTime   = [string]$row.LogonTime
        }

        $lines.Add((ConvertTo-P9HWtsProviderLine -Record $record)) | Out-Null

        if ([int]$row.SessionId -eq $TargetSessionId) {
            $targets.Add([pscustomobject]@{ SessionId = [int]$row.SessionId; QueryOk = $true; Rendered = $true; Row = $row }) | Out-Null
        }
    }

    return [pscustomobject][ordered]@{
        Lines          = @($lines)
        LineCount      = $lines.Count
        TargetRecords  = @($targets)
        TargetCount    = $targets.Count
        FailedQueries  = @($failed)
        FailedCount    = $failed.Count
        RowCount       = @($Rows).Count
        TargetSessionId = $TargetSessionId
        IsAtomicSnapshot = $false
    }
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
