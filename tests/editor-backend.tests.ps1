param(
    [string]$RepoRoot = (Split-Path $PSScriptRoot -Parent),
    [switch]$IsolatedBundledDefault
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

function Send-RawLine {
    # Returns both the exact response line and its parsed object. Used by the
    # isolated CI case so the hosted log carries the actual protocol exchange.
    param($Process, [string]$Raw)

    $Process.StandardInput.WriteLine($Raw)
    $Process.StandardInput.Flush()
    $line = $Process.StandardOutput.ReadLine()

    if ($null -eq $line) {
        $stderr = $Process.StandardError.ReadToEnd()
        throw "Backend returned no response. stderr: $stderr"
    }

    return [pscustomobject]@{
        Raw    = $line
        Object = ($line | ConvertFrom-Json -Depth 32 -ErrorAction Stop)
    }
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

function Invoke-IsolatedBundledDefaultTest {
    # Hosted-only acceptance case. It must run on a fresh Windows runner where
    # the real canonical path is absent. It never deletes or modifies a
    # canonical file; an existing file is an environmental conflict that fails
    # the test closed.
    Write-Host 'P3-R isolated bundled-default end-to-end test' -ForegroundColor Cyan

    if (-not [string]::IsNullOrWhiteSpace($env:DEVWS_CONFIG)) {
        throw "Refusing to run: DEVWS_CONFIG is set to '$($env:DEVWS_CONFIG)'. The isolated case requires the real canonical/bundled resolver path."
    }

    $canonicalPath = Get-DevWSCanonicalConfigPath

    if ([string]::IsNullOrWhiteSpace($canonicalPath)) {
        throw 'Refusing to run: the canonical configuration path could not be resolved.'
    }

    $canonicalExistsBefore = Test-Path -LiteralPath $canonicalPath -PathType Leaf

    if ($canonicalExistsBefore) {
        throw "Refusing to run: canonical configuration already exists at '$canonicalPath'. No file was deleted, renamed, overwritten, or modified."
    }

    $canonicalDirectory = Split-Path -Parent $canonicalPath
    $canonicalDirectoryExistedBefore = Test-Path -LiteralPath $canonicalDirectory -PathType Container
    $canonicalDirectoryBefore = @(
        if ($canonicalDirectoryExistedBefore) {
            Get-ChildItem -LiteralPath $canonicalDirectory -Force |
                ForEach-Object {
                    if ($_.PSIsContainer) { $_.Name + '|dir' }
                    else { $_.Name + '|' + (Get-FileSha $_.FullName) }
                } |
                Sort-Object
        }
    )

    $bundledPath = Find-DevWSBundledDefaultConfig -StartPath $RepoRoot

    if ([string]::IsNullOrWhiteSpace($bundledPath) -or -not (Test-Path -LiteralPath $bundledPath -PathType Leaf)) {
        throw "Refusing to run: the repository bundled default was not found from '$RepoRoot'."
    }

    $location = Resolve-DevWSConfigLocation -StartPath $RepoRoot
    $bundledResolved = (Resolve-Path -LiteralPath $bundledPath).Path
    $locationResolved = (Resolve-Path -LiteralPath $location.Path).Path

    Write-Host "canonicalPath=$canonicalPath"
    Write-Host 'canonicalPathCategory=user-profile'
    Write-Host "canonicalExistsBefore=$canonicalExistsBefore"
    Write-Host "canonicalDirectoryExistsBefore=$canonicalDirectoryExistedBefore"
    Write-Host "bundledPath=$bundledResolved"
    Write-Host "configSource=$($location.Source)"
    Write-Host "locationWritable=$($location.IsWritable)"

    Assert-Equal 'default' ([string]$location.Source) 'the real resolver selects the bundled default'
    Assert-Equal $bundledResolved $locationResolved 'the resolver returns the repository bundled default'
    Assert-Equal $false ([bool]$location.IsWritable) 'the bundled default is not writable'

    $bundledBefore = Get-FileSha $bundledPath
    $bundledSize = (Get-Item -LiteralPath $bundledPath).Length
    $expectedDocument = Get-Content -LiteralPath $bundledPath -Raw | ConvertFrom-Json -Depth 20
    $expectedDocumentJson = $expectedDocument | ConvertTo-Json -Depth 20 -Compress
    $configDirectory = Join-Path $RepoRoot 'config'
    $configSnapshotBefore = @(
        Get-ChildItem -LiteralPath $configDirectory -File |
            ForEach-Object { $_.Name + '=' + (Get-FileSha $_.FullName) } |
            Sort-Object
    )

    Write-Host "bundledSha256Before=$bundledBefore"
    Write-Host "bundledSizeBytes=$bundledSize"

    $resolverTopology = $null
    try { $resolverTopology = Get-DevWSMonitorTopology } catch { $resolverTopology = $null }

    $process = Start-Backend -ConfigPath $null
    $shutdownSeen = $false

    try {
        $helloRaw = ([ordered]@{ protocol = 'devws-editor/1'; id = 'iso-hello'; op = 'hello'; params = @{} } | ConvertTo-Json -Compress -Depth 20)
        $helloExchange = Send-RawLine -Process $process -Raw $helloRaw
        Write-Host "REQUEST $helloRaw"
        Write-Host "RESPONSE $($helloExchange.Raw)"
        $hello = $helloExchange.Object

        Assert-True $hello.ok 'hello succeeds'
        Assert-Equal 'devws-editor/1' $hello.protocol 'hello protocol'
        Assert-Equal 7 @($hello.result.supportedOps).Count 'hello advertises seven operations'
        Assert-True (-not ($hello.result.supportedOps -contains 'save')) 'hello does not advertise save'
        Assert-Equal $false $hello.result.capabilities.saveSupported 'hello reports save unsupported'
        Assert-Equal $null $hello.result.limits.saveTimeoutMs 'hello reports no save timeout'

        $inspectRaw = ([ordered]@{ protocol = 'devws-editor/1'; id = 'iso-inspect'; op = 'inspect'; params = @{} } | ConvertTo-Json -Compress -Depth 20)
        $inspectExchange = Send-RawLine -Process $process -Raw $inspectRaw
        Write-Host "REQUEST $inspectRaw"
        Write-Host "RESPONSE $($inspectExchange.Raw)"
        $inspect = $inspectExchange.Object

        Assert-True $inspect.ok 'inspect succeeds with the bundled default'
        Assert-Equal 'default' $inspect.result.config.source 'inspect source is default'
        Assert-Equal $canonicalPath $inspect.result.config.canonicalPath 'inspect reports the real canonical path'
        Assert-Equal $false $inspect.result.config.canonicalExists 'inspect reports canonical absent'
        Assert-Equal $false $inspect.result.config.writable 'inspect reports the bundled default not writable'
        Assert-Equal $false $inspect.result.capabilities.canSave 'inspect does not advertise save'
        Assert-Equal $true $inspect.result.capabilities.canProject 'inspect advertises projection'
        Assert-Equal $bundledResolved $inspect.result.config.effectivePath 'inspect effective path is the bundled default'
        Assert-Equal $bundledBefore $inspect.result.config.sha256 'inspect hash matches the bundled bytes'
        Assert-Equal $bundledSize $inspect.result.config.sizeBytes 'inspect size matches the bundled bytes'
        Assert-Equal 3 $inspect.result.config.version 'inspect reports schema v3'
        Assert-Equal 'main' $inspect.result.config.defaultSet 'inspect reports main as default'
        Assert-Equal $true $inspect.result.config.valid 'inspect reports a valid bundled default'
        Assert-Equal 1 @($inspect.result.sets).Count 'inspect reports one set'
        Assert-Equal 'main' $inspect.result.sets[0].id 'inspect reports main'
        Assert-Equal 0 $inspect.result.sets[0].itemCount 'inspect reports an empty main set'
        Assert-Equal 0 @($inspect.result.sets[0].profileIds).Count 'inspect reports no profiles'
        Assert-True ($null -ne $inspect.result.topology.PSObject.Properties['available']) 'inspect reports topology availability'
        Assert-Equal $false (Test-Path -LiteralPath $canonicalPath -PathType Leaf) 'inspect did not create the canonical file'

        $readRaw = ([ordered]@{
            protocol = 'devws-editor/1'
            id = 'iso-read'
            op = 'read-config'
            params = @{ expectedSha256 = [string]$inspect.result.config.sha256 }
        } | ConvertTo-Json -Compress -Depth 20)
        $readExchange = Send-RawLine -Process $process -Raw $readRaw
        Write-Host "REQUEST $readRaw"
        Write-Host "RESPONSE $($readExchange.Raw)"
        $read = $readExchange.Object

        Assert-True $read.ok 'read-config succeeds with the bundled default'
        Assert-Equal $inspect.result.config.sha256 $read.result.sha256 'read-config returns the inspected hash'
        Assert-Equal $bundledSize $read.result.sizeBytes 'read-config returns the bundled size'
        Assert-Equal $expectedDocumentJson ($read.result.document | ConvertTo-Json -Depth 20 -Compress) 'read-config returns the complete bundled document'
        Assert-Equal $false (Test-Path -LiteralPath $canonicalPath -PathType Leaf) 'read-config did not create the canonical file'

        $projectRaw = ([ordered]@{ protocol = 'devws-editor/1'; id = 'iso-project'; op = 'project'; params = @{} } | ConvertTo-Json -Compress -Depth 20)
        $projectExchange = Send-RawLine -Process $process -Raw $projectRaw
        Write-Host "REQUEST $projectRaw"
        Write-Host "RESPONSE $($projectExchange.Raw)"
        $project = $projectExchange.Object

        Assert-True $project.ok 'project succeeds with the bundled default'
        Assert-Equal $inspect.result.config.sha256 $project.result.configRevision 'project uses the inspected revision'
        Assert-Equal 'main' $project.result.setId 'project selects main'
        Assert-Equal 'main' $project.result.set.id 'project set id is main'
        Assert-Equal $true $project.result.set.isDefault 'project marks main as default'
        Assert-Equal 0 @($project.result.set.items).Count 'project returns the empty bundled set'
        Assert-Equal 0 @($project.warnings).Count 'project has no warnings for the empty set'

        $expectedModel = Get-DevWSEffectiveLayout -SetId 'main' -Set $expectedDocument.sets[0] -Topology $resolverTopology
        Assert-Equal ([string]$expectedModel.Status) ([string]$project.result.set.profileMatch.status) 'project profile status matches the resolver'
        Assert-Equal ([string]$expectedModel.ProfileId) ([string]$project.result.set.profileMatch.profileId) 'project profile id matches the resolver'
        Assert-Equal ([bool]$expectedModel.ProfileAware) ([bool]$project.result.set.profileAware) 'project profile awareness matches the resolver'
        Assert-Equal @($expectedModel.Items).Count @($project.result.set.items).Count 'project item count matches the resolver'
        Assert-Equal $false (Test-Path -LiteralPath $canonicalPath -PathType Leaf) 'project did not create the canonical file'

        $saveRaw = ([ordered]@{ protocol = 'devws-editor/1'; id = 'iso-save'; op = 'save'; params = @{} } | ConvertTo-Json -Compress -Depth 20)
        $saveExchange = Send-RawLine -Process $process -Raw $saveRaw
        Write-Host "REQUEST $saveRaw"
        Write-Host "RESPONSE $($saveExchange.Raw)"
        $save = $saveExchange.Object

        Assert-Equal $false $save.ok 'save is refused'
        Assert-Equal 'unsupported-operation' $save.error.code 'save is unsupported'
        Assert-Equal $null $save.result 'save returns no result'
        Assert-True (-not ($save.error.details.supportedOps -contains 'save')) 'save refusal does not advertise save'
        Assert-Equal $false (Test-Path -LiteralPath $canonicalPath -PathType Leaf) 'save did not create the canonical file'

        $shutdownRaw = ([ordered]@{ protocol = 'devws-editor/1'; id = 'iso-shutdown'; op = 'shutdown'; params = @{} } | ConvertTo-Json -Compress -Depth 20)
        $shutdownExchange = Send-RawLine -Process $process -Raw $shutdownRaw
        Write-Host "REQUEST $shutdownRaw"
        Write-Host "RESPONSE $($shutdownExchange.Raw)"
        $shutdown = $shutdownExchange.Object

        Assert-True $shutdown.ok 'shutdown succeeds'
        Assert-Equal $true $shutdown.result.stopped 'shutdown reports stopped'
        $shutdownSeen = $true
        $exited = $process.WaitForExit(10000)
        Assert-True $exited 'shutdown exits the backend'

        if ($exited) {
            Assert-Equal 0 $process.ExitCode 'backend exit code is zero'
            Assert-Equal '' $process.StandardOutput.ReadToEnd().Trim() 'stdout contains no extra output'
            Assert-Equal '' $process.StandardError.ReadToEnd().Trim() 'stderr is empty'
        }
    }
    finally {
        Stop-Backend -Process $process
    }

    Assert-True $shutdownSeen 'shutdown was exercised'
    Assert-Equal $false (Test-Path -LiteralPath $canonicalPath -PathType Leaf) 'canonical file is still absent after shutdown'
    $canonicalDirectoryExistedAfter = Test-Path -LiteralPath $canonicalDirectory -PathType Container
    $canonicalDirectoryAfter = @(
        if ($canonicalDirectoryExistedAfter) {
            Get-ChildItem -LiteralPath $canonicalDirectory -Force |
                ForEach-Object {
                    if ($_.PSIsContainer) { $_.Name + '|dir' }
                    else { $_.Name + '|' + (Get-FileSha $_.FullName) }
                } |
                Sort-Object
        }
    )
    $configSnapshotAfter = @(
        Get-ChildItem -LiteralPath $configDirectory -File |
            ForEach-Object { $_.Name + '=' + (Get-FileSha $_.FullName) } |
            Sort-Object
    )

    Assert-Equal $canonicalDirectoryExistedBefore $canonicalDirectoryExistedAfter 'canonical directory existence is unchanged'
    Assert-Equal ($canonicalDirectoryBefore -join '|') ($canonicalDirectoryAfter -join '|') 'canonical directory contents are unchanged'
    Assert-Equal $bundledBefore (Get-FileSha $bundledPath) 'bundled default bytes are unchanged'
    Assert-Equal ($configSnapshotBefore -join '|') ($configSnapshotAfter -join '|') 'repository config files are unchanged'

    Write-Host "canonicalExistsAfter=$(Test-Path -LiteralPath $canonicalPath -PathType Leaf)"
    Write-Host "bundledSha256After=$(Get-FileSha $bundledPath)"

    if ($script:Failures.Count -gt 0) {
        $script:Failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
        throw "P3-R isolated bundled-default test failed with $($script:Failures.Count) failure(s)."
    }

    Write-Host ("P3-R bundled-default assertions passed: {0}; failed: 0; skipped: 0" -f $script:Passed) -ForegroundColor Cyan
}

if ($IsolatedBundledDefault) {
    try {
        Invoke-IsolatedBundledDefaultTest
    }
    catch {
        Write-Host "P3-R isolated bundled-default test FAILED: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }

    exit 0
}

try {
    Write-Host 'P5 editor backend focused tests' -ForegroundColor Cyan

    # 1. Handshake and truthful capabilities.
    $root = New-TempRoot
    $config = New-Config -Windows @(
        (New-Terminal -Id 'abs' -WindowId 'DEVWS-P3-ABS' -Layout ([pscustomobject][ordered]@{ x = 0; y = 0; w = 800; h = 600 }))
    )
    $configPath = Write-TestConfig -Config $config -Directory $root
    $hello = Invoke-One -ConfigPath $configPath -Id 'hello' -Op 'hello'
    Assert-True $hello.ok 'hello succeeds'
    Assert-Equal 'devws-editor/1' $hello.protocol 'hello protocol'
    Assert-Equal 7 @($hello.result.supportedOps).Count 'hello advertises exactly seven operations'
    Assert-True ($hello.result.supportedOps -contains 'read-config') 'hello advertises read-config'
    Assert-True (-not ($hello.result.supportedOps -contains 'save')) 'hello does not advertise save'
    Assert-Equal $false $hello.result.capabilities.saveSupported 'hello says save is unsupported'
    Assert-Equal $true $hello.result.capabilities.validateSupported 'hello says validate is supported'
    Assert-Equal $true $hello.result.capabilities.convertSupported 'hello says convert is supported'
    Assert-Equal $false $hello.result.capabilities.previewSupported 'hello says preview is unsupported'
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

        foreach ($op in @('preview', 'save')) {
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
    # NOT EXECUTED on an ordinary developer machine: Get-DevWSCanonicalConfigPath
    # uses [Environment]::GetFolderPath('UserProfile'), which resolves from the
    # Windows shell profile and ignores a child-process USERPROFILE override.
    # Isolating this case here would require touching the real canonical config,
    # which P3 forbids. The dedicated hosted CI job runs this same file with
    # -IsolatedBundledDefault on a fresh windows-latest runner; that mode fails
    # closed if the canonical file already exists. The developer-machine case
    # remains an explicit skip rather than a false pass.
    $script:Skipped++
    Write-Host '  [SKIP] bundled-default end-to-end case on this developer machine: child USERPROFILE is not honored by GetFolderPath; see the isolated hosted CI job' -ForegroundColor Yellow

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

    # 12b. P5 structural validate and authoritative convert.
    $validateHashBefore = Get-FileSha $configPath
    $validateProcess = Start-Backend -ConfigPath $configPath
    try {
        $validateHello = Send-Request -Process $validateProcess -Id 'vh' -Op 'hello'
        Assert-True ($validateHello.result.supportedOps -contains 'validate') 'hello advertises validate'
        Assert-True ($validateHello.result.supportedOps -contains 'convert') 'hello advertises convert'
        Assert-True (-not ($validateHello.result.supportedOps -contains 'save')) 'hello still omits save'
        Assert-True (-not ($validateHello.result.supportedOps -contains 'preview')) 'hello still omits preview'
        Assert-Equal $true $validateHello.result.capabilities.validateSupported 'hello advertises validate capability'
        Assert-Equal $true $validateHello.result.capabilities.convertSupported 'hello advertises convert capability'
        Assert-Equal $false $validateHello.result.capabilities.previewSupported 'hello omits preview capability'

        $validateInspect = Send-Request -Process $validateProcess -Id 'vi' -Op 'inspect'
        $validDraft = ($config | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
        $validResult = Send-Request -Process $validateProcess -Id 'v1' -Op 'validate' -Params @{ draft = $validDraft }
        Assert-True $validResult.ok 'validate succeeds for a valid draft'
        Assert-Equal $true $validResult.result.valid 'valid draft reports valid'
        Assert-Equal 0 @($validResult.result.errors).Count 'valid draft has no errors'

        $unknownDraft = ($config | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
        $unknownDraft | Add-Member -NotePropertyName 'x-unknown' -NotePropertyValue ([pscustomobject][ordered]@{ keep = $true })
        $unknownResult = Send-Request -Process $validateProcess -Id 'v2' -Op 'validate' -Params @{ draft = $unknownDraft }
        Assert-Equal $true $unknownResult.result.valid 'unknown top-level properties are preserved and accepted'

        $invalidDraft = ($config | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
        $invalidDraft.sets[0].windows[0].layout.w = 0
        $invalidResult = Send-Request -Process $validateProcess -Id 'v3' -Op 'validate' -Params @{ draft = $invalidDraft }
        Assert-True $invalidResult.ok 'structurally invalid draft is a successful validate response'
        Assert-Equal $false $invalidResult.result.valid 'invalid draft reports invalid'
        Assert-True (@($invalidResult.result.errors).Count -ge 1) 'invalid draft has canonical errors'
        Assert-Contains $invalidResult.result.errors[0].message 'layout.w' 'canonical layout.w message preserved'
        Assert-Equal 'main' $invalidResult.result.errors[0].setId 'canonical set context'
        Assert-Equal 'abs' $invalidResult.result.errors[0].itemId 'canonical item context'

        $missingDraft = Send-Request -Process $validateProcess -Id 'v4' -Op 'validate'
        Assert-Equal 'request-invalid' $missingDraft.error.code 'missing draft refused'

        $topologyAvailable = [bool]$validateInspect.result.topology.available -and @($validateInspect.result.topology.monitors).Count -gt 0

        if ($topologyAvailable) {
        $primary = @($validateInspect.result.topology.monitors | Where-Object { $_.primary } | Select-Object -First 1)
        if ($primary.Count -eq 0) { $primary = @($validateInspect.result.topology.monitors | Select-Object -First 1) }
        Assert-True ($primary.Count -eq 1) 'host primary monitor available for convert'

        $basis = $primary[0].workRect
        $convertRect = [ordered]@{ x = [int]$basis.x; y = [int]$basis.y; w = [int]$basis.w; h = [int]$basis.h }
        $anchor = [ordered]@{ identity = [string]$primary[0].identity }
        if (-not ([string]$primary[0].identity).StartsWith('path:', [StringComparison]::Ordinal)) {
            $anchor['instance'] = [string]$primary[0].instance
        }
        $fingerprint = [string]$validateInspect.result.topology.fingerprint
        $converted = Send-Request -Process $validateProcess -Id 'c1' -Op 'convert' -Params @{ rect = $convertRect; anchor = $anchor; basis = 'workArea'; topologyFingerprint = $fingerprint }
        Assert-True $converted.ok 'convert succeeds for an explicit anchor'
        Assert-Equal ([string]$primary[0].identity) ([string]$converted.result.anchor.identity) 'convert preserves the anchor identity'
        Assert-Equal 0.0 ([double]$converted.result.normalized.x) 'convert normalized x'
        Assert-Equal 0.0 ([double]$converted.result.normalized.y) 'convert normalized y'
        Assert-Equal 1.0 ([double]$converted.result.normalized.w) 'convert normalized w'
        Assert-Equal 1.0 ([double]$converted.result.normalized.h) 'convert normalized h'
        Assert-Equal ([int]$basis.x) ([int]$converted.result.roundTripRect.x) 'convert round-trip x'
        Assert-Equal ([int]$basis.y) ([int]$converted.result.roundTripRect.y) 'convert round-trip y'
        Assert-Equal ([int]$basis.w) ([int]$converted.result.roundTripRect.w) 'convert round-trip width'
        Assert-Equal ([int]$basis.h) ([int]$converted.result.roundTripRect.h) 'convert round-trip height'
        Assert-Equal $true ([bool]$converted.result.reachable) 'convert reachability metadata'

        $selected = Send-Request -Process $validateProcess -Id 'c2' -Op 'convert' -Params @{ rect = $convertRect; selectAnchor = $true; basis = 'workArea'; topologyFingerprint = $fingerprint }
        Assert-True $selected.ok 'selectAnchor conversion succeeds'
        Assert-Equal ([string]$primary[0].identity) ([string]$selected.result.anchor.identity) 'selectAnchor chooses the visible monitor'

        $invalidRect = Send-Request -Process $validateProcess -Id 'c3' -Op 'convert' -Params @{ rect = [ordered]@{ x = 0; y = 0; w = 0; h = 10 }; anchor = $anchor; basis = 'workArea' }
        Assert-Equal 'invalid-rect' $invalidRect.error.code 'convert invalid rect refused'

        $missingAnchor = Send-Request -Process $validateProcess -Id 'c4' -Op 'convert' -Params @{ rect = $convertRect; anchor = [ordered]@{ identity = 'path:DEVWS-TEST/MISSING' }; basis = 'workArea' }
        Assert-Equal 'anchor-missing' $missingAnchor.error.code 'convert missing anchor refused'

        $wrongFingerprint = Send-Request -Process $validateProcess -Id 'c5' -Op 'convert' -Params @{ rect = $convertRect; anchor = $anchor; basis = 'workArea'; topologyFingerprint = ('A' * 64) }
        Assert-Equal 'topology-changed' $wrongFingerprint.error.code 'convert fingerprint drift refused'
        }
        else {
            Write-Host '  [SKIP] convert requires a host monitor topology' -ForegroundColor Yellow
        }

        $previewRefusal = Send-Request -Process $validateProcess -Id 'p1' -Op 'preview'
        Assert-Equal 'unsupported-operation' $previewRefusal.error.code 'preview remains unimplemented'
        $saveRefusal = Send-Request -Process $validateProcess -Id 's1' -Op 'save'
        Assert-Equal 'unsupported-operation' $saveRefusal.error.code 'save remains unimplemented'
        Send-Request -Process $validateProcess -Id 'vz' -Op 'shutdown' | Out-Null
        $validateProcess.WaitForExit(10000) | Out-Null
    }
    finally {
        Stop-Backend -Process $validateProcess
    }
    Assert-Equal $validateHashBefore (Get-FileSha $configPath) 'validate/convert did not change the config bytes'

    # 12c. Synthetic convert math and anchor refusals (no host topology needed).
    $convLeft = New-SyntheticMonitor -Identity 'path:TEST/LEFT' -X -1920 -Y 0 -W 1920 -H 1080 -WorkH 1040 -Primary $false
    $convRight = New-SyntheticMonitor -Identity 'path:TEST/RIGHT' -X 0 -Y 0 -W 2560 -H 1440 -WorkH 1400 -Primary $true
    $convTopology = New-SyntheticTopology -Monitors @($convLeft, $convRight)
    $convAnchor = [pscustomobject][ordered]@{ identity = 'path:TEST/LEFT' }

    $fractionConvert = Get-EditorConvert `
        -Rect ([pscustomobject][ordered]@{ x = -1920; y = 0; w = 640; h = 1040 }) `
        -Anchor $convAnchor `
        -SelectAnchor $false `
        -Basis 'workArea' `
        -TopologyFingerprint $convTopology.Fingerprint `
        -Topology $convTopology
    Assert-True $fractionConvert.Ok 'synthetic convert succeeds'
    Assert-True ([Math]::Abs([double]$fractionConvert.Result.normalized.x - 0.0) -lt 0.000001) 'synthetic normalized x'
    Assert-True ([Math]::Abs([double]$fractionConvert.Result.normalized.w - 0.333333) -lt 0.000001) 'synthetic six-decimal normalized width'
    Assert-Equal -1920 ([int]$fractionConvert.Result.roundTripRect.x) 'synthetic round-trip x'
    Assert-Equal 640 ([int]$fractionConvert.Result.roundTripRect.w) 'synthetic round-trip width'
    Assert-Equal $true ([bool]$fractionConvert.Result.reachable) 'synthetic reachability'

    $negativeConvert = Get-EditorConvert `
        -Rect ([pscustomobject][ordered]@{ x = -2000; y = -20; w = 300; h = 300 }) `
        -Anchor $convAnchor `
        -SelectAnchor $false `
        -Basis 'workArea' `
        -TopologyFingerprint $convTopology.Fingerprint `
        -Topology $convTopology
    Assert-True $negativeConvert.Ok 'negative-origin synthetic convert succeeds'
    Assert-True ([double]$negativeConvert.Result.normalized.x -lt 0) 'negative-origin normalized x remains negative'
    Assert-Equal $true ([bool]$negativeConvert.Result.reachable) 'negative-origin reachability'

    $selectedConvert = Get-EditorConvert `
        -Rect ([pscustomobject][ordered]@{ x = 0; y = 0; w = 800; h = 800 }) `
        -Anchor $null `
        -SelectAnchor $true `
        -Basis 'workArea' `
        -TopologyFingerprint $convTopology.Fingerprint `
        -Topology $convTopology
    Assert-True $selectedConvert.Ok 'synthetic selectAnchor succeeds'
    Assert-Equal 'path:TEST/RIGHT' ([string]$selectedConvert.Result.anchor.identity) 'selectAnchor chooses the visible monitor'

    $ambiguousTopology = New-SyntheticTopology -Monitors @(
        (New-SyntheticMonitor -Identity 'path:TEST/DUP' -X -1000 -Y 0 -W 1000 -H 800),
        (New-SyntheticMonitor -Identity 'path:TEST/DUP' -X 0 -Y 0 -W 1000 -H 800)
    )
    $ambiguousConvert = Get-EditorConvert `
        -Rect ([pscustomobject][ordered]@{ x = 0; y = 0; w = 500; h = 500 }) `
        -Anchor ([pscustomobject][ordered]@{ identity = 'path:TEST/DUP' }) `
        -SelectAnchor $false `
        -Basis 'monitor' `
        -TopologyFingerprint $ambiguousTopology.Fingerprint `
        -Topology $ambiguousTopology
    Assert-Equal $false ([bool]$ambiguousConvert.Ok) 'ambiguous synthetic anchor refused'
    Assert-Equal 'anchor-ambiguous' ([string]$ambiguousConvert.Code) 'ambiguous synthetic anchor code'

    $unpersistableTopology = New-SyntheticTopology -Monitors @(
        (New-SyntheticMonitor -Identity 'dummy' -X 0 -Y 0 -W 1000 -H 800)
    )
    $unpersistableConvert = Get-EditorConvert `
        -Rect ([pscustomobject][ordered]@{ x = 0; y = 0; w = 500; h = 500 }) `
        -Anchor ([pscustomobject][ordered]@{ identity = 'dummy' }) `
        -SelectAnchor $false `
        -Basis 'monitor' `
        -TopologyFingerprint $unpersistableTopology.Fingerprint `
        -Topology $unpersistableTopology
    Assert-Equal $false ([bool]$unpersistableConvert.Ok) 'unpersistable synthetic anchor refused'
    Assert-Equal 'anchor-unpersistable' ([string]$unpersistableConvert.Code) 'unpersistable synthetic anchor code'

    $staleConvert = Get-EditorConvert `
        -Rect ([pscustomobject][ordered]@{ x = 0; y = 0; w = 500; h = 500 }) `
        -Anchor $convAnchor `
        -SelectAnchor $false `
        -Basis 'workArea' `
        -TopologyFingerprint ('A' * 64) `
        -Topology $convTopology
    Assert-Equal 'topology-changed' ([string]$staleConvert.Code) 'synthetic topology drift refused'

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
    Assert-Equal $beforeHash (Get-FileSha $parityPath) 'config bytes unchanged across P3/P5 read-only requests'

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
Write-Host ("P5 focused assertions passed: {0}; failed: {1}; skipped: {2}" -f $script:Passed, $script:Failures.Count, $script:Skipped) -ForegroundColor Cyan
if ($script:Failures.Count -gt 0) {
    $script:Failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

exit 0
