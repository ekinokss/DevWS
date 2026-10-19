# DevWS CI environment probe (NON-DESTRUCTIVE, READ-ONLY).
#
# Records the environment facts the canonical test suite depends on, so that a
# CI environment can be compared with the validated local environment instead of
# being assumed equivalent. It creates one disposable window and destroys it; it
# writes nothing, changes no ACL, touches no task, pipe, service or protected
# state.
#
# Usage: pwsh -NoLogo -NoProfile -File tests/probe-ci-environment.ps1 [-AsJson]

[CmdletBinding()]
param(
    [switch]$AsJson
)

$ErrorActionPreference = 'Stop'

$script:ProbeFindings = [System.Collections.Generic.List[object]]::new()

function Add-Finding {
    param(
        [Parameter(Mandatory)][string]$Area,
        [Parameter(Mandatory)][string]$Observation,
        [Parameter(Mandatory)][string]$Evidence,
        [Parameter(Mandatory)][ValidateSet('LOCAL OBSERVATION', 'GITHUB-HOSTED ASSUMPTION')][string]$Provenance
    )

    $script:ProbeFindings.Add([pscustomobject]@{
        Area       = $Area
        Observation = $Observation
        Evidence   = $Evidence
        Provenance = $Provenance
    }) | Out-Null
}

# ---------------------------------------------------------------------------
# 1. Process integrity and elevation
# ---------------------------------------------------------------------------
$identity    = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal   = [Security.Principal.WindowsPrincipal]::new($identity)
$isAdmin     = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$integrity   = 'Unknown'

$libDir = Join-Path (Split-Path -Parent $PSScriptRoot) 'src\lib'
. (Join-Path $libDir 'devws-paths.ps1')
. (Join-Path $libDir 'devws-native.ps1')

try { $integrity = [string](Get-DevWSProcessIntegrityLevel) } catch { $integrity = "Unknown ($($_.Exception.Message))" }

Add-Finding -Area 'integrity' -Provenance 'LOCAL OBSERVATION' `
    -Observation ("IsAdministrator={0}; integrity={1}; sessionId={2}; userInteractive={3}" -f $isAdmin, $integrity, (Get-Process -Id $PID).SessionId, [Environment]::UserInteractive) `
    -Evidence 'WindowsPrincipal.IsInRole + Get-DevWSProcessIntegrityLevel (native token read)'

# ---------------------------------------------------------------------------
# 2. Protected-state anchor access check and Medium-token source
# ---------------------------------------------------------------------------
$anchorOk     = $null
$anchorSource = $null
$anchorErrors = @()
$anchorPath   = $null

try {
    # The anchor is the container ABOVE the privileged-state root
    # (<anchor>\privileged-state\<SID>). Derived from the registry-backed
    # ProgramData known folder, never from an environment variable.
    $anchorPath = Split-Path -Parent (Get-DevWSPrivilegedStateBaseRoot)
    $anchor = Test-DevWSProtectedStateAnchorSafety -Anchor $anchorPath
    $anchorOk     = [bool]$anchor.Ok
    $anchorSource = [string]$anchor.TokenSource
    $anchorErrors = @($anchor.Errors)
}
catch {
    $anchorErrors = @($_.Exception.Message)
}

Add-Finding -Area 'anchor-access-check' -Provenance 'LOCAL OBSERVATION' `
    -Observation ("Test-DevWSProtectedStateAnchorSafety Ok={0}; TokenSource={1}; errors={2}" -f $anchorOk, $anchorSource, $anchorErrors.Count) `
    -Evidence 'production Test-DevWSProtectedStateAnchorSafety (read-only AccessCheck on the resolved ProgramData anchor)'

Add-Finding -Area 'linked-medium-token' -Provenance 'LOCAL OBSERVATION' `
    -Observation ("linked filtered Medium token available = {0}" -f ($anchorSource -eq 'linked-medium')) `
    -Evidence 'TokenSource value: linked-medium (elevated caller) vs duplicate-medium (already Medium) vs unavailable'

# ---------------------------------------------------------------------------
# 3. Desktop / window-station availability and disposable HWND creation
# ---------------------------------------------------------------------------
$windowStation = 'unknown'
try {
    Add-Type -Namespace DevWSProbe -Name Win -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode, SetLastError = true)]
public static extern System.IntPtr CreateWindowExW(int dwExStyle, string lpClassName, string lpWindowName, int dwStyle, int x, int y, int nWidth, int nHeight, System.IntPtr hWndParent, System.IntPtr hMenu, System.IntPtr hInstance, System.IntPtr lpParam);

[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
public static extern bool DestroyWindow(System.IntPtr hWnd);

[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
public static extern System.IntPtr GetProcessWindowStation();

[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true)]
public static extern bool GetUserObjectInformationW(System.IntPtr hObj, int nIndex, System.Text.StringBuilder pvInfo, int nLength, out int lpnLengthNeeded);
'@ -ErrorAction Stop

    $sb = [System.Text.StringBuilder]::new(256)
    $needed = 0
    if ([DevWSProbe.Win]::GetUserObjectInformationW([DevWSProbe.Win]::GetProcessWindowStation(), 2, $sb, 256, [ref]$needed)) {
        $windowStation = $sb.ToString()
    }
}
catch {
    $windowStation = "unavailable ($($_.Exception.Message))"
}

$hwndCreated = $false
$hwndDetail  = ''
try {
    # WS_POPUP (0x80000000) top-level window of the built-in STATIC class: no
    # window-class registration is required.
    $hwnd = [DevWSProbe.Win]::CreateWindowExW(0, 'STATIC', '', 0x80000000, 0, 0, 10, 10, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero, [IntPtr]::Zero)
    if ($hwnd -ne [IntPtr]::Zero) {
        $hwndCreated = $true
        $hwndDetail  = ("hwnd=0x{0:X}" -f $hwnd.ToInt64())
        [void][DevWSProbe.Win]::DestroyWindow($hwnd)
    }
    else {
        $hwndDetail = ("CreateWindowExW failed, win32={0}" -f [Runtime.InteropServices.Marshal]::GetLastWin32Error())
    }
}
catch {
    $hwndDetail = $_.Exception.Message
}

Add-Finding -Area 'window-station' -Provenance 'LOCAL OBSERVATION' `
    -Observation ("window station = '{0}'; disposable HWND created = {1} ({2})" -f $windowStation, $hwndCreated, $hwndDetail) `
    -Evidence 'GetProcessWindowStation + GetUserObjectInformationW + CreateWindowExW/DestroyWindow'

# ---------------------------------------------------------------------------
# 4. Optional third-party runtimes
# ---------------------------------------------------------------------------
$ahkPath = $null
try { $ahkPath = [string](Get-DevWSAutoHotkeyPath) } catch { $ahkPath = '<resolver failed>' }
$ahkPresent = $false
try { $ahkPresent = Test-Path -LiteralPath $ahkPath -PathType Leaf } catch { $ahkPresent = $false }

Add-Finding -Area 'autohotkey' -Provenance 'LOCAL OBSERVATION' `
    -Observation ("AutoHotkey v2 present = {0} (resolved path {1})" -f $ahkPresent, $(if ($ahkPresent) { $ahkPath } else { '<absent>' })) `
    -Evidence 'Get-DevWSAutoHotkeyPath + Test-Path (existence only)'

# ---------------------------------------------------------------------------
# 5. Host facts
# ---------------------------------------------------------------------------
Add-Finding -Area 'host' -Provenance 'LOCAL OBSERVATION' `
    -Observation ("OS={0}; PSVersion={1}; IsGitWorkTree={2}" -f [Environment]::OSVersion.VersionString, $PSVersionTable.PSVersion.ToString(), (Test-Path -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) '.git'))) `
    -Evidence 'Environment/PSVersionTable + presence of a .git directory'

# ---------------------------------------------------------------------------
# 6. Declared, NOT measured, CI assumptions
# ---------------------------------------------------------------------------
Add-Finding -Area 'github-runner' -Provenance 'GITHUB-HOSTED ASSUMPTION' `
    -Observation 'GitHub-hosted Windows runners are documented to execute as an administrator with UAC disabled; that configuration may NOT provide the linked filtered Medium token.' `
    -Evidence 'DOCUMENTATION ONLY - no GitHub-hosted runner has been measured for this project.'

Add-Finding -Area 'github-runner' -Provenance 'GITHUB-HOSTED ASSUMPTION' `
    -Observation 'A GitHub-hosted Windows runner has no Windows Terminal, no AutoHotkey v2 and no DevWS scheduled tasks; window-station and HWND-creation behaviour is unmeasured there.' `
    -Evidence 'DOCUMENTATION / INFERENCE ONLY - requires an actual CI run to confirm.'

Add-Finding -Area 'github-runner' -Provenance 'GITHUB-HOSTED ASSUMPTION' `
    -Observation 'No GitHub Actions workflow exists for this candidate, so no CI behaviour has been measured and none is claimed.' `
    -Evidence 'No .github/workflows directory exists in the candidate.'

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------
if ($AsJson) {
    $script:ProbeFindings | ConvertTo-Json -Depth 5
    return
}

Write-Output ''
Write-Output 'DevWS CI environment probe (read-only)'
Write-Output ('=' * 78)
foreach ($f in $script:ProbeFindings) {
    Write-Output ('[{0}] {1}' -f $f.Provenance, $f.Area)
    Write-Output ('    {0}' -f $f.Observation)
    Write-Output ('    evidence: {0}' -f $f.Evidence)
}
Write-Output ('=' * 78)
Write-Output ('LOCAL OBSERVATIONS: {0}   GITHUB-HOSTED ASSUMPTIONS: {1}' -f `
    @($script:ProbeFindings | Where-Object { $_.Provenance -eq 'LOCAL OBSERVATION' }).Count, `
    @($script:ProbeFindings | Where-Object { $_.Provenance -eq 'GITHUB-HOSTED ASSUMPTION' }).Count)
