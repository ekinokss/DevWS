# DevWS P9-H replay instrumentation - self-test runner.
#
# Runs the synthetic self-tests, writes a machine-readable report, prints a
# summary, cleans up only its own sandbox, and exits non-zero on any failure.
#
# SAFETY: this runner never launches the installed product, never contacts a VM,
# never disconnects a session and never modifies host configuration. Every
# process it creates is a trivial cmd.exe batch file inside its own temp sandbox.

[CmdletBinding()]
param(
    # Keep the sandbox for inspection instead of deleting it.
    [switch]$KeepSandbox,

    # Explicit sandbox root. Omit for a fresh task-specific temp directory.
    [string]$SandboxRoot = $null
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$libRoot = Join-Path $PSScriptRoot 'lib'
$libFile = Join-Path $libRoot 'p9h.ps1'
if (-not (Test-Path -LiteralPath $libFile -PathType Leaf)) {
    throw "P9-H: module loader not found at '$libFile'."
}

$selftestFile = Join-Path $libRoot 'p9h-selftest.ps1'

. $libFile
. $selftestFile

$createdSandbox = $false
if ([string]::IsNullOrWhiteSpace($SandboxRoot)) {
    $SandboxRoot = Get-P9HSandboxRoot -Name 'run'
    $createdSandbox = $true
}
elseif (-not (Test-Path -LiteralPath $SandboxRoot)) {
    New-Item -ItemType Directory -Path $SandboxRoot -Force | Out-Null
}

$reportPath = Join-Path $SandboxRoot 'selftest-report.json'
$logPath = Join-Path $SandboxRoot 'selftest-console.log'

Write-Host ''
Write-Host 'DevWS P9-H instrumentation self-tests'
Write-Host ('sandbox: ' + $SandboxRoot)
Write-Host ''

$startedAt = Get-P9HUtcStamp
$results = @()
$exitCode = 0

try {
    $results = Invoke-P9HAllSelfTests -SandboxRoot $SandboxRoot
}
catch {
    Write-Host ('FATAL: self-test harness threw: ' + $_.Exception.Message) -ForegroundColor Red
    $exitCode = 2
}

$failed = @($results | Where-Object { $_.result -ne 'PASS' })
$passedCount = @($results | Where-Object { $_.result -eq 'PASS' }).Count

Write-Host ''
Write-Host ('{0,-5} {1,-3} {2}' -f 'ID', '', 'TITLE / EXPECTED -> ACTUAL') -ForegroundColor Cyan
Write-Host ('-' * 110)

foreach ($r in $results) {
    $colour = if ($r.result -eq 'PASS') { 'Green' } else { 'Red' }
    Write-Host ('{0,-5} {1,-3} {2}' -f $r.id, $r.result, $r.title) -ForegroundColor $colour
    if ($r.result -ne 'PASS') {
        Write-Host ('        expected: ' + $r.expected)
        Write-Host ('        actual  : ' + $r.actual)
    }
}

$finishedAt = Get-P9HUtcStamp

$report = [ordered]@{
    schema        = 'p9h.selftest.v1'
    startedAtUtc  = $startedAt
    finishedAtUtc = $finishedAt
    sandbox       = $SandboxRoot
    host          = $env:COMPUTERNAME
    powershell    = $PSVersionTable.PSVersion.ToString()
    total         = @($results).Count
    passed        = $passedCount
    failed        = $failed.Count
    cases         = @($results)
}

Write-P9HArtifact -Path $reportPath -Lines @(($report | ConvertTo-Json -Depth 8))

Write-Host ''
Write-Host ('-' * 110)
Write-Host ('total={0} passed={1} failed={2}' -f @($results).Count, $passedCount, $failed.Count) `
    -ForegroundColor $(if ($failed.Count -eq 0) { 'Green' } else { 'Red' })
Write-Host ('report: ' + $reportPath)

if ($failed.Count -gt 0 -and $exitCode -eq 0) { $exitCode = 1 }

# Cleanup: only ever remove the sandbox this runner created itself.
#
# A detached synthetic descendant can hold an inherited handle on the redirected
# stream files after the launcher exits (this is exactly the P9-G 'inherited
# output handle' condition). Deletion can therefore fail transiently, so cleanup
# retries with backoff and reports honestly if it still cannot remove the tree.
if (-not $KeepSandbox -and $createdSandbox) {
    # Reap only test-owned descendants: those whose command line mentions this
    # sandbox. Never touch an unrelated process with a matching image name.
    try {
        foreach ($proc in @(Get-CimInstance Win32_Process -Filter "Name='ping.exe'" -ErrorAction SilentlyContinue)) {
            if ([string]$proc.CommandLine -match [regex]::Escape($SandboxRoot)) {
                try { Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop } catch { }
            }
        }
    }
    catch { }

    $removed = $false
    for ($attempt = 1; $attempt -le 12; $attempt++) {
        try {
            Remove-Item -LiteralPath $SandboxRoot -Recurse -Force -ErrorAction Stop
            $removed = $true
            break
        }
        catch {
            # The synthetic detached descendant from T3 sleeps ~19 s before
            # exiting. Waiting for it is the honest cleanup: killing an arbitrary
            # ping.exe could destroy an unrelated user process.
            Start-Sleep -Milliseconds (500 * $attempt)
        }
    }

    if ($removed) {
        Write-Host 'sandbox removed.' -ForegroundColor DarkGray
    }
    else {
        Write-Host ('warning: sandbox could not be fully removed (a descendant may still hold a handle): ' + $SandboxRoot) -ForegroundColor Yellow
    }
}
elseif ($KeepSandbox) {
    Write-Host ('sandbox retained: ' + $SandboxRoot) -ForegroundColor Yellow
}

exit $exitCode
