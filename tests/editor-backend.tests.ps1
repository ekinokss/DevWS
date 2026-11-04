param(
    [string]$RepoRoot = (Split-Path $PSScriptRoot -Parent)
)

$ErrorActionPreference = 'Stop'
$script:Passed = 0
$script:Skipped = 0
$script:Failures = [System.Collections.Generic.List[string]]::new()

function Fail-Test([string]$Message) {
    $script:Failures.Add($Message) | Out-Null
    Write-Host "  [FAIL] $Message" -ForegroundColor Red
}

function Assert-True($Condition, [string]$Message) {
    if ($Condition) { $script:Passed++ } else { Fail-Test $Message }
}

function Assert-Equal($Expected, $Actual, [string]$Message) {
    if ("$Expected" -ceq "$Actual") { $script:Passed++ } else { Fail-Test "$Message (expected '$Expected', got '$Actual')" }
}

function Assert-Contains([string]$Text, [string]$Needle, [string]$Message) {
    if ($Text.Contains($Needle)) { $script:Passed++ } else { Fail-Test "$Message (missing '$Needle')" }
}

function Assert-NotContains([string]$Text, [string]$Needle, [string]$Message) {
    if (-not $Text.Contains($Needle)) { $script:Passed++ } else { Fail-Test "$Message (unexpected '$Needle')" }
}

$libRoot = Join-Path $RepoRoot 'src\lib'
. (Join-Path $libRoot 'devws-paths.ps1')
. (Join-Path $libRoot 'devws-config.ps1')
. (Join-Path $libRoot 'devws-native.ps1')
. (Join-Path $libRoot 'devws-monitor.ps1')
. (Join-Path $libRoot 'devws-relative-layout.ps1')
. (Join-Path $libRoot 'devws-layout-profile.ps1')
. (Join-Path $RepoRoot 'src\editor\editor-projection.ps1')

$backend = Join-Path $RepoRoot 'src\editor\ws-editor-backend.ps1'
$pwsh = Join-Path $PSHOME 'pwsh.exe'
$script:TempRoots = [System.Collections.Generic.List[string]]::new()

function New-TempRoot {
    $path = Join-Path $env:TEMP ('devws-p3-test-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $path -Force | Out-Null
    $script:TempRoots.Add($path) | Out-Null
    return $path
}

function New-Terminal {
    param(
        [string]$Id,
        [string]$WindowId,
        $Layout,
        [string]$Path = 'C:\Windows'
    )

    return [pscustomobject][ordered]@{
        id = $Id
        type = 'terminal'
        enabled = $true
        windowId = $WindowId
        path = $Path
        elevated = $true
        tabs = @([pscustomobject][ordered]@{ command = $null; args = @() })
        activeTab = 0
        layout = $Layout
    }
}

function New-RelativeTerminal {
    param(
        [string]$Id,
        [string]$WindowId,
        $Fallback,
        [string]$Identity,
        [string]$Basis = 'workArea',
        $Rect
    )

    $terminal = New-Terminal -Id $Id -WindowId $WindowId -Layout $Fallback
    $terminal | Add-Member -NotePropertyName layoutMode -NotePropertyValue 'relative'
    $terminal | Add-Member -NotePropertyName layoutRelative -NotePropertyValue ([pscustomobject][ordered]@{
        monitor = [pscustomobject][ordered]@{ identity = $Identity }
        basis = $Basis
        rect = $Rect
    })
    return $terminal
}

function New-Config {
    param(
        [object[]]$Windows,
        [object[]]$Profiles = @()
    )

    $set = [pscustomobject][ordered]@{
        id = 'main'
        windows = @($Windows)
    }

    if (@($Profiles).Count -gt 0) {
        $set | Add-Member -NotePropertyName layoutProfiles -NotePropertyValue @($Profiles)
    }

    return [pscustomobject][ordered]@{
        version = 3
        defaultSet = 'main'
        bindings = @()
        sets = @($set)
    }
}

function New-Profile {
    param(
        [string]$Id,
        [string[]]$Tokens,
        [hashtable]$Layouts
    )

    return [pscustomobject][ordered]@{
        id = $Id
        match = [pscustomobject][ordered]@{
            mode = 'exact'
            monitors = @($Tokens)
        }
        layouts = [pscustomobject]$Layouts
    }
}

function Write-TestConfig {
    param($Config, [string]$Directory)

    $path = Join-Path $Directory 'workspace.json'
    $Config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $path -Encoding UTF8
    return $path
}

function Get-FileSha([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Start-Backend {
    param(
        [string]$ConfigPath = $null,
        [string]$UserProfile = $null
    )

    $psi = [System.Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = $pwsh
    $psi.ArgumentList.Add('-NoLogo')
    $psi.ArgumentList.Add('-NoProfile')
    $psi.ArgumentList.Add('-File')
    $psi.ArgumentList.Add($backend)
    $psi.UseShellExecute = $false
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardInputEncoding = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $psi.StandardErrorEncoding = [System.Text.UTF8Encoding]::new($false)

    $psi.Environment.Remove('DEVWS_CONFIG') | Out-Null
    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
        $psi.Environment['DEVWS_CONFIG'] = $ConfigPath
    }
    if (-not [string]::IsNullOrWhiteSpace($UserProfile)) {
        $psi.Environment['USERPROFILE'] = $UserProfile
    }

    $process = [System.Diagnostics.Process]::Start($psi)
    return $process
}

function Send-Raw {
    param($Process, [string]$Raw)

    $Process.StandardInput.WriteLine($Raw)
    $Process.StandardInput.Flush()
    $line = $Process.StandardOutput.ReadLine()

    if ($null -eq $line) {
        $stderr = $Process.StandardError.ReadToEnd()
        throw "Backend returned no response. stderr: $stderr"
    }

    return ($line | ConvertFrom-Json -Depth 32 -ErrorAction Stop)
}

function Send-Request {
    param($Process, [string]$Id, [string]$Op, $Params = @{})

    $request = [ordered]@{
        protocol = 'devws-editor/1'
        id = $Id
        op = $Op
        params = $Params
    }

    return Send-Raw -Process $Process -Raw ($request | ConvertTo-Json -Compress -Depth 20)
}

function Stop-Backend {
    param($Process)

    try {
        if (-not $Process.HasExited) {
            $Process.StandardInput.Close()
            if (-not $Process.WaitForExit(10000)) {
                $Process.Kill()
            }
        }
    }
    finally {
        $Process.Dispose()
    }
}

function Invoke-One {
    param(
        [string]$ConfigPath,
        [string]$Id,
        [string]$Op,
        $Params = @{}
    )

    $process = Start-Backend -ConfigPath $ConfigPath
    try {
        return Send-Request -Process $process -Id $Id -Op $Op -Params $Params
    }
    finally {
        Stop-Backend -Process $process
    }
}

function New-SyntheticTopology {
    param([object[]]$Monitors)

    $virtualLeft = (@($Monitors | ForEach-Object { $_.MonitorRect.x }) | Measure-Object -Minimum).Minimum
    $virtualTop = (@($Monitors | ForEach-Object { $_.MonitorRect.y }) | Measure-Object -Minimum).Minimum
    $virtualRight = (@($Monitors | ForEach-Object { $_.MonitorRect.x + $_.MonitorRect.w }) | Measure-Object -Maximum).Maximum
    $virtualBottom = (@($Monitors | ForEach-Object { $_.MonitorRect.y + $_.MonitorRect.h }) | Measure-Object -Maximum).Maximum

    $tokens = @($Monitors | ForEach-Object {
        "$($_.IdentityToken)@$($_.MonitorRect.x),$($_.MonitorRect.y),$($_.MonitorRect.w)x$($_.MonitorRect.h)"
    } | Sort-Object)

    $signature = $tokens -join ';'
    $fingerprint = (Get-EditorSha256Hex -Bytes ([Text.Encoding]::UTF8.GetBytes($signature))).ToUpperInvariant()

    return [pscustomobject][ordered]@{
        Available = $true
        IdentityComplete = $true
        CorrelationComplete = $true
        IdentityAmbiguous = $false
        Signature = $signature
        Fingerprint = $fingerprint
        VirtualScreenRect = [pscustomobject][ordered]@{
            x = [int]$virtualLeft
            y = [int]$virtualTop
            w = [int]($virtualRight - $virtualLeft)
            h = [int]($virtualBottom - $virtualTop)
        }
        Monitors = @($Monitors)
    }
}

function New-SyntheticMonitor {
    param(
        [string]$Identity,
        [int]$X,
        [int]$Y,
        [int]$W,
        [int]$H,
        [int]$WorkH = $H,
        [bool]$Primary = $false
    )

    return [pscustomobject][ordered]@{
        IdentityToken = $Identity
        DevicePathInstance = $Identity.Substring(5)
        FriendlyName = 'Synthetic'
        Primary = $Primary
        MonitorRect = [pscustomobject][ordered]@{ x = $X; y = $Y; w = $W; h = $H }
        WorkRect = [pscustomobject][ordered]@{ x = $X; y = $Y; w = $W; h = $WorkH }
        ScalePercent = 100
        OutputTechnology = 'Synthetic'
    }
}

try {
    Write-Host 'P3 editor backend focused tests' -ForegroundColor Cyan

    # 1. Handshake and truthful capabilities.
    $root = New-TempRoot
    $config = New-Config -Windows @(
        (New-Terminal -Id 'abs' -WindowId 'DEVWS-P3-ABS' -Layout ([pscustomobject][ordered]@{ x = 0; y = 0; w = 800; h = 600 }))
    )
    $configPath = Write-TestConfig -Config $config -Directory $root
    $hello = Invoke-One -ConfigPath $configPath -Id 'hello' -Op 'hello'
    Assert-True $hello.ok 'hello succeeds'
    Assert-Equal 'devws-editor/1' $hello.protocol 'hello protocol'
    Assert-Equal 5 @($hello.result.supportedOps).Count 'hello advertises exactly five operations'
    Assert-True ($hello.result.supportedOps -contains 'read-config') 'hello advertises read-config'
    Assert-True (-not ($hello.result.supportedOps -contains 'save')) 'hello does not advertise save'
    Assert-Equal $false $hello.result.capabilities.saveSupported 'hello says save is unsupported'
    Assert-Equal $false $hello.result.capabilities.validateSupported 'hello says validate is unsupported'
    Assert-Equal $true $hello.result.capabilities.readOnly 'hello says read-only'

    # 2. inspect metadata and physical-writable vs backend-save distinction.
    $inspect = Invoke-One -ConfigPath $configPath -Id 'inspect' -Op 'inspect'
    Assert-True $inspect.ok 'inspect succeeds'
    Assert-Equal $configPath $inspect.result.config.effectivePath 'inspect effective path'
    Assert-Equal 'env' $inspect.result.config.source 'inspect source'
    Assert-Equal $true $inspect.result.config.writable 'inspect reports physical writability'
    Assert-Equal $false $inspect.result.capabilities.canSave 'inspect does not advertise save'
    Assert-Equal 1 @($inspect.result.sets).Count 'inspect sets'
    Assert-Equal 'main' $inspect.result.sets[0].id 'inspect set id'
    Assert-True ($null -ne $inspect.result.topology.PSObject.Properties['available']) 'inspect reports topology availability'
    if ([bool]$inspect.result.topology.available) {
        Assert-True (@($inspect.result.topology.monitors).Count -ge 1) 'inspect reports monitors when topology is available'
    }
    else {
        $script:Skipped++
        Write-Host '  [SKIP] inspect monitor details: monitor topology unavailable on this host' -ForegroundColor Yellow
    }

    # 3. read-config exact hash and unknown-property preservation.
    $config.sets[0].windows[0] | Add-Member -NotePropertyName note -NotePropertyValue 'café "quoted"'
    $configPath = Write-TestConfig -Config $config -Directory $root
    $hash = Get-FileSha $configPath
    $read = Invoke-One -ConfigPath $configPath -Id 'read' -Op 'read-config' -Params @{ expectedSha256 = $hash }
    Assert-True $read.ok 'read-config succeeds'
    Assert-Equal $hash $read.result.sha256 'read-config hash'
    Assert-Equal 'café "quoted"' $read.result.document.sets[0].windows[0].note 'unknown property preserved'
    Assert-Equal 1 @($read.result.document.sets).Count 'document set count'

    # 4. revision mismatch.
    $config.sets[0].windows[0].layout.w = 801
    $configPath = Write-TestConfig -Config $config -Directory $root
    $stale = Invoke-One -ConfigPath $configPath -Id 'stale' -Op 'read-config' -Params @{ expectedSha256 = $hash }
    Assert-Equal $false $stale.ok 'stale read refused'
    Assert-Equal 'external-change' $stale.error.code 'stale read code'

    $changedHash = Get-FileSha $configPath
    $changedProject = Invoke-One -ConfigPath $configPath -Id 'changed-project' -Op 'project'
    Assert-True $changedProject.ok 'project succeeds after an external change'
    Assert-Equal $changedHash $changedProject.result.configRevision 'project binds the new revision'
    Assert-True ($changedHash -ne $inspect.result.config.sha256) 'project revision differs from the inspected revision'

    # 5. malformed envelopes and unsupported operations.
    $process = Start-Backend -ConfigPath $configPath
    try {
        $malformed = Send-Raw -Process $process -Raw '{'
        Assert-Equal 'request-invalid' $malformed.error.code 'malformed JSON refused'

        $badProtocol = Send-Request -Process $process -Id 'p' -Op 'hello'
        $badProtocol = Send-Raw -Process $process -Raw '{"protocol":"devws-editor/2","id":"p","op":"hello","params":{}}'
        Assert-Equal 'protocol-version-unsupported' $badProtocol.error.code 'wrong protocol refused'

        $badId = Send-Raw -Process $process -Raw '{"protocol":"devws-editor/1","id":"bad id","op":"hello","params":{}}'
        Assert-Equal 'request-invalid' $badId.error.code 'invalid id refused'

        $unknownOp = Send-Request -Process $process -Id 'u' -Op 'bogus'
        Assert-Equal 'unsupported-operation' $unknownOp.error.code 'unknown op refused'

        $unknownField = Send-Raw -Process $process -Raw '{"protocol":"devws-editor/1","id":"x","op":"hello","params":{},"extra":1}'
        Assert-Equal 'request-invalid' $unknownField.error.code 'unknown top-level field refused'

        $unknownParam = Send-Request -Process $process -Id 'y' -Op 'project' -Params @{ setId = 'main'; extra = 1 }
        Assert-Equal 'request-invalid' $unknownParam.error.code 'unknown project param refused'

        $duplicateId = Send-Request -Process $process -Id 'u' -Op 'hello'
        Assert-Equal 'request-invalid' $duplicateId.error.code 'duplicate id refused'
        Assert-Equal 'duplicate-request-id' $duplicateId.error.details.reason 'duplicate id reason'

        foreach ($op in @('validate', 'preview', 'convert', 'save')) {
            $refused = Send-Request -Process $process -Id $op -Op $op
            Assert-Equal 'unsupported-operation' $refused.error.code "$op refused"
        }

        $shutdown = Send-Request -Process $process -Id 'z' -Op 'shutdown'
        Assert-True $shutdown.ok 'shutdown succeeds'
        Assert-True ($process.WaitForExit(10000)) 'shutdown exits process'
        Assert-Equal 0 $process.ExitCode 'shutdown exit code'
        Assert-Equal '' $process.StandardOutput.ReadToEnd().Trim() 'stdout carries only protocol responses'
        Assert-Equal '' $process.StandardError.ReadToEnd().Trim() 'stderr stays empty on the success path'
    }
    finally {
        Stop-Backend -Process $process
    }

    # 5b. Multiple sequential requests in one process, with ID correlation.
    $sequenceProcess = Start-Backend -ConfigPath $configPath
    try {
        $seqHello = Send-Request -Process $sequenceProcess -Id 'seq-1' -Op 'hello'
        $seqInspect = Send-Request -Process $sequenceProcess -Id 'seq-2' -Op 'inspect'
        $seqProject = Send-Request -Process $sequenceProcess -Id 'seq-3' -Op 'project'
        Assert-Equal 'seq-1' $seqHello.id 'sequential hello id'
        Assert-Equal 'seq-2' $seqInspect.id 'sequential inspect id'
        Assert-Equal 'seq-3' $seqProject.id 'sequential project id'
        Send-Request -Process $sequenceProcess -Id 'seq-4' -Op 'shutdown' | Out-Null
        $sequenceProcess.WaitForExit(10000) | Out-Null
    }
    finally {
        Stop-Backend -Process $sequenceProcess
    }

    # 5c. Oversized request is refused and terminates the connection.
    $oversizedRequestProcess = Start-Backend -ConfigPath $configPath
    try {
        $oversizedLine = '{"protocol":"devws-editor/1","id":"big","op":"hello","params":{"pad":"' + ('x' * 4194305) + '"}}'
        $oversizedResponse = Send-Raw -Process $oversizedRequestProcess -Raw $oversizedLine
        Assert-Equal 'request-too-large' $oversizedResponse.error.code 'oversized request refused'
        Assert-True ($oversizedRequestProcess.WaitForExit(10000)) 'oversized request closes connection'
    }
    finally {
        Stop-Backend -Process $oversizedRequestProcess
    }

    # 5e. Exactly 4 MiB of content before CRLF is parsed, not rejected as oversized.
    $boundaryProcess = Start-Backend -ConfigPath $configPath
    try {
        $boundaryPrefix = '{"protocol":"devws-editor/1","id":"boundary","op":"hello","params":{"pad":"'
        $boundarySuffix = '"}}'
        $boundaryLine = $boundaryPrefix + ('x' * (4194304 - $boundaryPrefix.Length - $boundarySuffix.Length)) + $boundarySuffix
        Assert-Equal 4194304 $boundaryLine.Length 'boundary request content is exactly 4 MiB'
        $boundaryResponse = Send-Raw -Process $boundaryProcess -Raw $boundaryLine
        Assert-Equal 'request-invalid' $boundaryResponse.error.code '4 MiB CRLF request is parsed, not rejected as oversized'
        Send-Request -Process $boundaryProcess -Id 'boundary-shutdown' -Op 'shutdown' | Out-Null
        $boundaryProcess.WaitForExit(10000) | Out-Null
    }
    finally {
        Stop-Backend -Process $boundaryProcess
    }

    # 5d. JSON-depth violation is refused.
    $deepProcess = Start-Backend -ConfigPath $configPath
    try {
        $deep = '{"protocol":"devws-editor/1","id":"deep","op":"hello","params":' + ('{"a":' * 40) + '1' + ('}' * 40) + '}'
        $deepResponse = Send-Raw -Process $deepProcess -Raw $deep
        Assert-Equal 'request-invalid' $deepResponse.error.code 'deep JSON refused'
        Send-Request -Process $deepProcess -Id 'deep-shutdown' -Op 'shutdown' | Out-Null
        $deepProcess.WaitForExit(10000) | Out-Null
    }
    finally {
        Stop-Backend -Process $deepProcess
    }

    # 6. Missing canonical config with bundled default.
    #
    # NOT EXECUTED (environment limitation): Get-DevWSCanonicalConfigPath uses
    # [Environment]::GetFolderPath('UserProfile'), which resolves from the
    # Windows shell profile and ignores a child-process USERPROFILE override.
    # Isolating this case would require touching the real canonical config,
    # which P3 forbids. The bundled-default path is exercised by the resolver
    # unit coverage in the canonical suite; this specific end-to-end case is
    # recorded as skipped rather than silently asserted.
    $script:Skipped++
    Write-Host '  [SKIP] bundled-default end-to-end case: child USERPROFILE is not honored by GetFolderPath; real canonical config must not be touched' -ForegroundColor Yellow

    # 7. Missing config path.
    $missingPath = Join-Path $root 'missing.json'
    $missing = Invoke-One -ConfigPath $missingPath -Id 'missing' -Op 'inspect'
    Assert-Equal 'config-unavailable' $missing.error.code 'missing config refused'

    # 8. Invalid config.
    $invalidRoot = New-TempRoot
    $invalid = New-Config -Windows @(
        (New-Terminal -Id 'bad' -WindowId 'DEVWS-P3-BAD' -Layout ([pscustomobject][ordered]@{ x = 0; y = 0; w = -5; h = 600 }))
    )
    $invalidPath = Write-TestConfig -Config $invalid -Directory $invalidRoot
    $invalidResponse = Invoke-One -ConfigPath $invalidPath -Id 'invalid' -Op 'inspect'
    Assert-Equal 'config-invalid' $invalidResponse.error.code 'invalid config refused'

    # 9. Oversized config.
    $oversizedRoot = New-TempRoot
    $oversizedPath = Join-Path $oversizedRoot 'workspace.json'
    $oversizedText = '{"version":3,"defaultSet":"main","bindings":[],"sets":[],"pad":"' + ('x' * 4194305) + '"}'
    [IO.File]::WriteAllText($oversizedPath, $oversizedText, [Text.UTF8Encoding]::new($false))
    $oversized = Invoke-One -ConfigPath $oversizedPath -Id 'large' -Op 'read-config' -Params @{ expectedSha256 = ('0' * 64) }
    Assert-Equal 'config-too-large' $oversized.error.code 'oversized config refused'

    # 10. Projection parity on the real topology.
    $topology = $null
    try { $topology = Get-DevWSMonitorTopology } catch { $topology = $null }
    $parityPath = $configPath
    $parityHash = Get-FileSha $configPath
    $parityRunner = {
        $hostTokens = @($topology.Signature -split ';')
        $primaryIdentity = [string]$topology.Monitors[0].IdentityToken
        $parityWindows = @(
            (New-Terminal -Id 'abs' -WindowId 'DEVWS-P3-ABS2' -Layout ([pscustomobject][ordered]@{ x = 0; y = 0; w = 800; h = 600 })),
            (New-RelativeTerminal -Id 'rel' -WindowId 'DEVWS-P3-REL' -Fallback ([pscustomobject][ordered]@{ x = 10; y = 20; w = 300; h = 400 }) -Identity $primaryIdentity -Rect ([pscustomobject][ordered]@{ x = 0; y = 0; w = 0.5; h = 1 })),
            (New-Terminal -Id 'prof' -WindowId 'DEVWS-P3-PROF' -Layout ([pscustomobject][ordered]@{ x = 0; y = 0; w = 400; h = 300 }))
        )
        $parityProfile = New-Profile -Id 'docked' -Tokens $hostTokens -Layouts @{
            rel = [pscustomobject][ordered]@{ x = 200; y = 200; w = 600; h = 600 }
            prof = [pscustomobject][ordered]@{ x = 100; y = 100; w = 500; h = 500 }
        }
        $parityConfig = New-Config -Windows $parityWindows -Profiles @($parityProfile)
        Assert-DevWSConfig -Config $parityConfig -Source 'p3 parity fixture'
        $parityPath = Write-TestConfig -Config $parityConfig -Directory $root
        $parityHash = Get-FileSha $parityPath
        $parityResponse = Invoke-One -ConfigPath $parityPath -Id 'parity' -Op 'project' -Params @{ setId = 'main' }
        Assert-True $parityResponse.ok 'parity project succeeds'
        Assert-Equal $parityHash $parityResponse.result.configRevision 'parity revision'
        Assert-True (-not ($parityResponse.result.PSObject.Properties.Name -contains 'warnings')) 'project keeps warnings in the envelope'
        Assert-Equal 0 @($parityResponse.warnings).Count 'project reports an empty envelope warning list'
        Assert-Equal 'matched' $parityResponse.result.set.profileMatch.status 'profile matched'
        Assert-Equal 'docked' $parityResponse.result.set.profileMatch.profileId 'profile id'
        $parityItems = @{}
        foreach ($item in @($parityResponse.result.set.items)) { $parityItems[$item.itemId] = $item }
        Assert-Equal 'profile' $parityItems['rel'].source 'relative item profile precedence'
        Assert-Equal 200 $parityItems['rel'].rect.x 'relative profile rect x'
        Assert-Equal 'profile' $parityItems['prof'].source 'absolute profile precedence'
        Assert-Equal 'fallback' $parityItems['abs'].source 'sparse profile omission falls back'

        $expectedModel = Get-DevWSEffectiveLayout -SetId 'main' -Set $parityConfig.sets[0] -Topology $topology
        $expectedItems = @{}
        foreach ($item in @($expectedModel.Items)) { $expectedItems[$item.ItemId] = $item }
        foreach ($id in @('abs', 'rel', 'prof')) {
            Assert-Equal $expectedItems[$id].Rect.x $parityItems[$id].rect.x "$id parity x"
            Assert-Equal $expectedItems[$id].Rect.y $parityItems[$id].rect.y "$id parity y"
            Assert-Equal $expectedItems[$id].Rect.w $parityItems[$id].rect.w "$id parity w"
            Assert-Equal $expectedItems[$id].Rect.h $parityItems[$id].rect.h "$id parity h"
            Assert-Equal $expectedItems[$id].Source $parityItems[$id].source "$id parity source"
            Assert-Equal $expectedItems[$id].PlacementStatus $parityItems[$id].placementStatus "$id parity placement"
        }
    }

    if ([bool]$topology.Available) {
        . $parityRunner
    }
    else {
        $script:Skipped++
        Write-Host '  [SKIP] host-topology projection parity: monitor topology unavailable on this host' -ForegroundColor Yellow
    }

    # 11. Unknown set.
    $unknownSet = Invoke-One -ConfigPath $parityPath -Id 'unknown-set' -Op 'project' -Params @{ setId = 'missing' }
    Assert-Equal 'set-not-found' $unknownSet.error.code 'unknown set refused'

    # 12. Synthetic negative origin, relative resolution, missing/ambiguous/unreachable.
    $left = New-SyntheticMonitor -Identity 'path:TEST/LEFT' -X -1920 -Y 0 -W 1920 -H 1080 -WorkH 1040 -Primary $false
    $right = New-SyntheticMonitor -Identity 'path:TEST/RIGHT' -X 0 -Y 0 -W 2560 -H 1440 -WorkH 1400 -Primary $true
    $synthetic = New-SyntheticTopology -Monitors @($left, $right)
    $negativeWindows = @(
        (New-RelativeTerminal -Id 'neg' -WindowId 'DEVWS-P3-NEG' -Fallback ([pscustomobject][ordered]@{ x = 10; y = 20; w = 300; h = 400 }) -Identity 'path:TEST/LEFT' -Rect ([pscustomobject][ordered]@{ x = 0; y = 0; w = 0.5; h = 1 }))
    )
    $negativeConfig = New-Config -Windows $negativeWindows
    $negativeSet = $negativeConfig.sets[0]
    $negativeProjection = Get-EditorProjection -Config $negativeConfig -Set $negativeSet -Topology $synthetic -ConfigRevision ('a' * 64)
    Assert-Equal -1920 $negativeProjection.set.items[0].rect.x 'negative-origin resolved x'
    Assert-Equal 960 $negativeProjection.set.items[0].rect.w 'negative-origin resolved width'

    $missingConfig = New-Config -Windows @(
        (New-RelativeTerminal -Id 'miss' -WindowId 'DEVWS-P3-MISS' -Fallback ([pscustomobject][ordered]@{ x = 10; y = 20; w = 300; h = 400 }) -Identity 'path:TEST/MISSING' -Rect ([pscustomobject][ordered]@{ x = 0; y = 0; w = 0.5; h = 1 }))
    )
    $missingProjection = Get-EditorProjection -Config $missingConfig -Set $missingConfig.sets[0] -Topology $synthetic -ConfigRevision ('b' * 64)
    Assert-Equal 'anchor-missing' $missingProjection.set.items[0].relativeStatus 'missing anchor status'
    Assert-Equal 'relative-fallback' $missingProjection.set.items[0].source 'missing anchor fallback source'
    Assert-True (@($missingProjection.warnings).Count -ge 1) 'missing anchor warning emitted'

    $dupLeft = New-SyntheticMonitor -Identity 'path:TEST/DUP' -X -1000 -Y 0 -W 1000 -H 800
    $dupRight = New-SyntheticMonitor -Identity 'path:TEST/DUP' -X 0 -Y 0 -W 1000 -H 800
    $dupTopology = New-SyntheticTopology -Monitors @($dupLeft, $dupRight)
    $ambiguousConfig = New-Config -Windows @(
        (New-RelativeTerminal -Id 'amb' -WindowId 'DEVWS-P3-AMB' -Fallback ([pscustomobject][ordered]@{ x = 10; y = 20; w = 300; h = 400 }) -Identity 'path:TEST/DUP' -Rect ([pscustomobject][ordered]@{ x = 0; y = 0; w = 0.5; h = 1 }))
    )
    $ambiguousProjection = Get-EditorProjection -Config $ambiguousConfig -Set $ambiguousConfig.sets[0] -Topology $dupTopology -ConfigRevision ('c' * 64)
    Assert-Equal 'anchor-ambiguous' $ambiguousProjection.set.items[0].relativeStatus 'ambiguous anchor status'
    Assert-True (@($ambiguousProjection.warnings).Count -ge 1) 'ambiguous anchor warning emitted'

    $unreachableConfig = New-Config -Windows @(
        (New-RelativeTerminal -Id 'unreach' -WindowId 'DEVWS-P3-UNREACH' -Fallback ([pscustomobject][ordered]@{ x = 10000; y = 10000; w = 300; h = 400 }) -Identity 'path:TEST/LEFT' -Rect ([pscustomobject][ordered]@{ x = 2; y = 2; w = 0.5; h = 0.5 }))
    )
    $unreachableProjection = Get-EditorProjection -Config $unreachableConfig -Set $unreachableConfig.sets[0] -Topology $synthetic -ConfigRevision ('d' * 64)
    Assert-Equal $false $unreachableProjection.set.items[0].applyGeometry 'unreachable placement skips'
    Assert-True (@($unreachableProjection.warnings).Count -ge 1) 'unreachable warning emitted'

    $unavailableProjection = Get-EditorProjection -Config $missingConfig -Set $missingConfig.sets[0] -Topology $null -ConfigRevision ('e' * 64)
    Assert-Equal $false $unavailableProjection.topology.available 'unavailable topology represented'
    Assert-Equal $false $unavailableProjection.set.items[0].applyGeometry 'relative item not applied without topology'

    $incomplete = New-SyntheticTopology -Monitors @($left)
    $incomplete.IdentityComplete = $false
    $incomplete.CorrelationComplete = $false
    $incompleteProjection = Get-EditorProjection -Config $negativeConfig -Set $negativeConfig.sets[0] -Topology $incomplete -ConfigRevision ('f' * 64)
    Assert-Equal $false $incompleteProjection.topology.identityComplete 'incomplete topology identity state represented'
    Assert-Equal $false $incompleteProjection.topology.correlationComplete 'incomplete topology correlation state represented'
    Assert-Equal 'resolved' $incompleteProjection.set.items[0].relativeStatus 'present identity still resolves under incomplete topology'

    # 13. Non-mutation and static isolation.
    $beforeHash = Get-FileSha $parityPath
    $process = Start-Backend -ConfigPath $parityPath
    try {
        Send-Request -Process $process -Id 'n1' -Op 'inspect' | Out-Null
        Send-Request -Process $process -Id 'n2' -Op 'read-config' -Params @{ expectedSha256 = $parityHash } | Out-Null
        Send-Request -Process $process -Id 'n3' -Op 'project' | Out-Null
        Send-Request -Process $process -Id 'n4' -Op 'shutdown' | Out-Null
        $process.WaitForExit(10000) | Out-Null
    }
    finally {
        Stop-Backend -Process $process
    }
    Assert-Equal $beforeHash (Get-FileSha $parityPath) 'config bytes unchanged across P3 requests'

    $backendText = Get-Content -LiteralPath $backend -Raw
    $projectionText = Get-Content -LiteralPath (Join-Path $RepoRoot 'src\editor\editor-projection.ps1') -Raw
    $allowlist = @('devws-paths.ps1', 'devws-config.ps1', 'devws-native.ps1', 'devws-monitor.ps1', 'devws-relative-layout.ps1', 'devws-layout-profile.ps1')
    $libraryBlock = [regex]::Match($backendText, '(?s)foreach \(\$library in @\((.*?)\)\) \{').Groups[1].Value
    $loadedLibraries = @([regex]::Matches($libraryBlock, "'([^']+\.ps1)'") | ForEach-Object { $_.Groups[1].Value })
    Assert-Equal $allowlist.Count $loadedLibraries.Count 'backend dot-sources exactly six approved libraries'
    Assert-Equal ($allowlist -join ',') ($loadedLibraries -join ',') 'backend library allowlist is exact and ordered'
    Assert-Equal 1 ([regex]::Matches($backendText, '\. \$libraryPath')).Count 'backend has exactly one library dot-source site'
    Assert-Equal 1 ([regex]::Matches($backendText, '\. \(Join-Path \$editorRoot ''editor-projection\.ps1''\)')).Count 'backend loads exactly one internal helper'

    foreach ($forbidden in @('devws-launch.ps1', 'devws-lifecycle.ps1', 'devws-terminal.ps1', 'devws-worker-protocol.ps1', 'devws-broker-protocol.ps1', 'devws-coordinator.ps1', 'devws-uia.ps1', 'devws-window-ops.ps1', 'devws-install.ps1', 'NamedPipeClientStream', 'DevWorkspace-Elevated', 'DevWS.Coordinator', 'Invoke-DevWSWorkerRequest', 'Start-Process', 'SetWindowPos', 'GetWindowRect', 'Invoke-Expression')) {
        Assert-NotContains $backendText $forbidden "backend excludes $forbidden"
        Assert-NotContains $projectionText $forbidden "projection helper excludes $forbidden"
    }

    # 14. EOF clean exit.
    $eofProcess = Start-Backend -ConfigPath $configPath
    $eofProcess.StandardInput.Close()
    Assert-True ($eofProcess.WaitForExit(10000)) 'EOF exits backend'
    Assert-Equal 0 $eofProcess.ExitCode 'EOF exit code'
    $eofProcess.Dispose()
}
finally {
    foreach ($root in $script:TempRoots) {
        if (Test-Path -LiteralPath $root) {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Write-Host ""
Write-Host ("P3 focused assertions passed: {0}; failed: {1}; skipped: {2}" -f $script:Passed, $script:Failures.Count, $script:Skipped) -ForegroundColor Cyan
if ($script:Failures.Count -gt 0) {
    $script:Failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

exit 0
