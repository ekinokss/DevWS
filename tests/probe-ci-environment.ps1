# DevWS CI environment probe (NON-DESTRUCTIVE, READ-ONLY).
#
# Records the environment facts the canonical test suite depends on, so that a CI
# environment can be compared with a validated environment instead of being
# assumed equivalent. It creates one disposable window and destroys it; it writes
# nothing, changes no ACL, and touches no scheduled task, pipe, service, installed
# runtime, canonical configuration or DevWS protected state.
#
# Provenance labels, so a reader can always separate measurement from context:
#   OBSERVED     measured in the process running this probe, now
#   EXPECTATION  documented or inferred context, NOT measured here
#   UNMEASURED   a fact this probe deliberately does not establish
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
        [Parameter(Mandatory)][ValidateSet('OBSERVED', 'EXPECTATION', 'UNMEASURED')][string]$Provenance
    )

    $script:ProbeFindings.Add([pscustomobject]@{
        Area        = $Area
        Observation = $Observation
        Evidence    = $Evidence
        Provenance  = $Provenance
    }) | Out-Null
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$libDir   = Join-Path $repoRoot 'src\lib'
. (Join-Path $libDir 'devws-paths.ps1')
. (Join-Path $libDir 'devws-native.ps1')

# ---------------------------------------------------------------------------
# 1. Process integrity and elevation
# ---------------------------------------------------------------------------
$identity    = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal   = [Security.Principal.WindowsPrincipal]::new($identity)
$isAdmin     = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$integrity   = 'Unknown'

try { $integrity = [string](Get-DevWSProcessIntegrityLevel) } catch { $integrity = "Unknown ($($_.Exception.Message))" }

Add-Finding -Area 'integrity' -Provenance 'OBSERVED' `
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

Add-Finding -Area 'anchor-access-check' -Provenance 'OBSERVED' `
    -Observation ("Test-DevWSProtectedStateAnchorSafety Ok={0}; TokenSource={1}; errors={2}" -f $anchorOk, $anchorSource, $anchorErrors.Count) `
    -Evidence 'production Test-DevWSProtectedStateAnchorSafety (read-only AccessCheck on the resolved ProgramData anchor)'

Add-Finding -Area 'linked-medium-token' -Provenance 'OBSERVED' `
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

Add-Finding -Area 'window-station' -Provenance 'OBSERVED' `
    -Observation ("window station = '{0}'; disposable HWND created = {1} ({2})" -f $windowStation, $hwndCreated, $hwndDetail) `
    -Evidence 'GetProcessWindowStation + GetUserObjectInformationW + CreateWindowExW/DestroyWindow'

# ---------------------------------------------------------------------------
# 4. Third-party runtimes the suite can use when present
# ---------------------------------------------------------------------------
$ahkPath = $null
try { $ahkPath = [string](Get-DevWSAutoHotkeyPath) } catch { $ahkPath = '<resolver failed>' }
$ahkPresent = $false
try { $ahkPresent = Test-Path -LiteralPath $ahkPath -PathType Leaf } catch { $ahkPresent = $false }

Add-Finding -Area 'autohotkey' -Provenance 'OBSERVED' `
    -Observation ("AutoHotkey v2 present = {0} (resolved path {1})" -f $ahkPresent, $(if ($ahkPresent) { $ahkPath } else { '<absent>' })) `
    -Evidence 'Get-DevWSAutoHotkeyPath + Test-Path (existence only)'

# Windows Terminal is resolved through the production trusted-package logic, so
# the observation matches what an installed DevWS would actually require.
$wtOk     = $false
$wtDetail = ''
try {
    $wtDetail = [string](Resolve-DevWSTrustedWindowsTerminalPath -Installed)
    $wtOk = $true
}
catch {
    $wtDetail = ($_.Exception.Message -replace "`r?`n", ' ')
    if ($wtDetail.Length -gt 200) { $wtDetail = $wtDetail.Substring(0, 200) + '...' }
}

Add-Finding -Area 'windows-terminal' -Provenance 'OBSERVED' `
    -Observation ("trusted Windows Terminal resolved = {0} ({1})" -f $wtOk, $(if ($wtOk) { $wtDetail } else { 'refused: ' + $wtDetail })) `
    -Evidence 'production Resolve-DevWSTrustedWindowsTerminalPath -Installed (official package identity + protected non-reparse candidate)'

# ---------------------------------------------------------------------------
# 5. UAC policy (read-only) - explains the observed token model
# ---------------------------------------------------------------------------
$uacParts = @()
try {
    $uacKey = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    foreach ($name in @('EnableLUA', 'ConsentPromptBehaviorAdmin', 'FilterAdministratorToken', 'LocalAccountTokenFilterPolicy')) {
        $value = '<absent>'
        try { $value = [string](Get-ItemProperty -LiteralPath $uacKey -Name $name -ErrorAction Stop).$name } catch { $value = '<absent>' }
        $uacParts += ("{0}={1}" -f $name, $value)
    }
}
catch {
    $uacParts += ("read failed: {0}" -f ($_.Exception.Message -replace "`r?`n", ' '))
}

Add-Finding -Area 'uac-policy' -Provenance 'OBSERVED' `
    -Observation ($uacParts -join '; ') `
    -Evidence 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System (read-only registry inspection; values are reported, never changed)'

# ---------------------------------------------------------------------------
# 6. Host and runner context
# ---------------------------------------------------------------------------
$gitHead = '<unavailable>'
try {
    $headText = (git -C $repoRoot rev-parse HEAD 2>$null) -join ''
    if (-not [string]::IsNullOrWhiteSpace($headText)) { $gitHead = $headText.Trim() }
}
catch {
    $gitHead = '<unavailable>'
}

Add-Finding -Area 'host' -Provenance 'OBSERVED' `
    -Observation ("OS={0}; architecture={1}; PowerShell={2}; IsGitWorkTree={3}; probed HEAD={4}" -f `
        [Environment]::OSVersion.VersionString, [Runtime.InteropServices.RuntimeInformation]::OSArchitecture, `
        $PSVersionTable.PSVersion.ToString(), (Test-Path -LiteralPath (Join-Path $repoRoot '.git')), $gitHead) `
    -Evidence 'Environment/PSVersionTable + RuntimeInformation + presence of a .git directory + git rev-parse HEAD'

# Selected CI context variables only. No wholesale environment dump, and no
# value that could carry a credential.
$contextVars = [ordered]@{
    GITHUB_ACTIONS  = $env:GITHUB_ACTIONS
    GITHUB_WORKFLOW = $env:GITHUB_WORKFLOW
    GITHUB_JOB      = $env:GITHUB_JOB
    GITHUB_SHA      = $env:GITHUB_SHA
    GITHUB_REF      = $env:GITHUB_REF
    RUNNER_OS       = $env:RUNNER_OS
    RUNNER_ARCH     = $env:RUNNER_ARCH
    RUNNER_IMAGE    = $env:RUNNER_IMAGE
    ImageOS         = $env:ImageOS
    ImageVersion    = $env:ImageVersion
}
$contextParts = @($contextVars.GetEnumerator() | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.Value) } |
    ForEach-Object { "{0}={1}" -f $_.Key, $_.Value })

Add-Finding -Area 'ci-context' -Provenance 'OBSERVED' `
    -Observation ($(if ($contextParts.Count -eq 0) { 'not running under GitHub Actions (no runner context variables set)' } else { $contextParts -join '; ' })) `
    -Evidence 'selected GITHUB_* / RUNNER_* / Image* variables only'

# ---------------------------------------------------------------------------
# 7. Context that is deliberately NOT an observation
# ---------------------------------------------------------------------------
Add-Finding -Area 'hosted-runner-context' -Provenance 'EXPECTATION' `
    -Observation 'GitHub-hosted Windows runners are documented to run jobs with administrator rights and UAC disabled. Whether that configuration can produce the linked filtered Medium token the protected-state check prefers is a property of the runner image: read it from the observations above, never assume it.' `
    -Evidence 'Upstream GitHub documentation. Not a measurement of this process.'

Add-Finding -Area 'diagnostic-workflow' -Provenance 'EXPECTATION' `
    -Observation 'A manual-only diagnostic workflow (.github/workflows/runner-environment-probe.yml) dispatches this probe on windows-latest. It collects evidence; it is not a CI gate, and no CI compatibility is claimed until its results are reviewed.' `
    -Evidence 'The workflow file exists in this repository. Whether any given run completed is visible in the Actions run history, not in this probe.'

Add-Finding -Area 'suite-compatibility' -Provenance 'UNMEASURED' `
    -Observation 'Whether the canonical hermetic suite passes on a GitHub-hosted Windows runner is NOT established here. This probe records environment facts only; no test matrix exists yet.' `
    -Evidence 'Deliberate scope boundary of the measurement phase.'

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
Write-Output ('OBSERVED: {0}   EXPECTATION: {1}   UNMEASURED: {2}' -f `
    @($script:ProbeFindings | Where-Object { $_.Provenance -eq 'OBSERVED' }).Count, `
    @($script:ProbeFindings | Where-Object { $_.Provenance -eq 'EXPECTATION' }).Count, `
    @($script:ProbeFindings | Where-Object { $_.Provenance -eq 'UNMEASURED' }).Count)
