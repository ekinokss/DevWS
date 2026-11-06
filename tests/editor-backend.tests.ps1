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
        Assert-Equal 9 @($hello.result.supportedOps).Count 'hello advertises nine operations'
        Assert-True ($hello.result.supportedOps -contains 'save') 'hello advertises save'
        Assert-Equal $true $hello.result.capabilities.saveSupported 'hello reports save supported'
        Assert-Equal $false $hello.result.capabilities.readOnly 'hello reports writable capabilities'
        Assert-Equal 30000 $hello.result.limits.saveTimeoutMs 'hello reports the save timeout'

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

        $saveRaw = ([ordered]@{
            protocol = 'devws-editor/1'
            id = 'iso-save'
            op = 'save'
            params = @{ draft = $read.result.document; baseSha256 = [string]$read.result.sha256; confirm = $true }
        } | ConvertTo-Json -Compress -Depth 20)
        $saveExchange = Send-RawLine -Process $process -Raw $saveRaw
        Write-Host "REQUEST $saveRaw"
        Write-Host "RESPONSE $($saveExchange.Raw)"
        $save = $saveExchange.Object

        Assert-Equal $false $save.ok 'save is refused for the bundled default'
        Assert-Equal 'config-not-writable' $save.error.code 'save refuses the read-only bundled default'
        Assert-Equal $null $save.result 'save returns no result'
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
    Write-Host 'P7 editor backend focused tests' -ForegroundColor Cyan

    # 1. Handshake and truthful capabilities.
    $root = New-TempRoot
    $config = New-Config -Windows @(
        (New-Terminal -Id 'abs' -WindowId 'DEVWS-P3-ABS' -Layout ([pscustomobject][ordered]@{ x = 0; y = 0; w = 800; h = 600 }))
    )
    $configPath = Write-TestConfig -Config $config -Directory $root
    $hello = Invoke-One -ConfigPath $configPath -Id 'hello' -Op 'hello'
    Assert-True $hello.ok 'hello succeeds'
    Assert-Equal 'devws-editor/1' $hello.protocol 'hello protocol'
    Assert-Equal 9 @($hello.result.supportedOps).Count 'hello advertises exactly nine operations'
    Assert-True ($hello.result.supportedOps -contains 'read-config') 'hello advertises read-config'
    Assert-True ($hello.result.supportedOps -contains 'save') 'hello advertises save'
    Assert-Equal $true $hello.result.capabilities.saveSupported 'hello says save is supported'
    Assert-Equal $true $hello.result.capabilities.validateSupported 'hello says validate is supported'
    Assert-Equal $true $hello.result.capabilities.convertSupported 'hello says convert is supported'
    Assert-Equal $true $hello.result.capabilities.previewSupported 'hello says preview is supported'
    Assert-Equal $false $hello.result.capabilities.readOnly 'hello says writable capabilities'
    Assert-Equal 30000 $hello.result.limits.saveTimeoutMs 'hello reports the save timeout'

    # 2. inspect metadata and physical-writable vs backend-save distinction.
    $inspect = Invoke-One -ConfigPath $configPath -Id 'inspect' -Op 'inspect'
    Assert-True $inspect.ok 'inspect succeeds'
    Assert-Equal $configPath $inspect.result.config.effectivePath 'inspect effective path'
    Assert-Equal 'env' $inspect.result.config.source 'inspect source'
    Assert-Equal $true $inspect.result.config.writable 'inspect reports physical writability'
    Assert-Equal $true $inspect.result.capabilities.canSave 'inspect advertises save for a writable config'
    Assert-Equal $null $inspect.result.capabilities.reason 'writable inspect has no refusal reason'
    Assert-Equal $false $inspect.result.capabilities.readOnly 'inspect advertises writable capabilities'
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
        Assert-True ($validateHello.result.supportedOps -contains 'save') 'hello advertises save'
        Assert-True ($validateHello.result.supportedOps -contains 'preview') 'hello advertises preview'
        Assert-Equal $true $validateHello.result.capabilities.validateSupported 'hello advertises validate capability'
        Assert-Equal $true $validateHello.result.capabilities.convertSupported 'hello advertises convert capability'
        Assert-Equal $true $validateHello.result.capabilities.previewSupported 'hello advertises preview capability'

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

        $previewMissing = Send-Request -Process $validateProcess -Id 'p1' -Op 'preview'
        Assert-Equal 'request-invalid' $previewMissing.error.code 'preview requires draft and baseSha256'
        $saveRefusal = Send-Request -Process $validateProcess -Id 's1' -Op 'save'
        Assert-Equal 'request-invalid' $saveRefusal.error.code 'save requires draft and baseSha256'
        Send-Request -Process $validateProcess -Id 'vz' -Op 'shutdown' | Out-Null
        $validateProcess.WaitForExit(10000) | Out-Null
    }
    finally {
        Stop-Backend -Process $validateProcess
    }
    Assert-Equal $validateHashBefore (Get-FileSha $configPath) 'validate/convert did not change the config bytes'

    # 12b-preview. Direct protocol preview and server-side allowlist.
    $previewHashBefore = Get-FileSha $configPath
    $previewProcess = Start-Backend -ConfigPath $configPath
    try {
        $previewInspect = Send-Request -Process $previewProcess -Id 'pi' -Op 'inspect'
        $previewRead = Send-Request -Process $previewProcess -Id 'pr' -Op 'read-config' -Params @{ expectedSha256 = $previewInspect.result.config.sha256 }
        $previewBase = [string]$previewInspect.result.config.sha256
        $previewDraft = ($previewRead.result.document | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
        $previewDraft.sets[0].windows[0].layout.x = 25
        $previewResponse = Send-Request -Process $previewProcess -Id 'p1' -Op 'preview' -Params @{ draft = $previewDraft; baseSha256 = $previewBase }
        Assert-True $previewResponse.ok 'preview succeeds for an absolute draft'
        Assert-Equal 1 @($previewResponse.result.diff).Count 'preview reports one fallback change'
        Assert-Equal 'fallback' ([string]$previewResponse.result.diff[0].scope) 'preview diff scope'
        Assert-Equal 0 ([int]$previewResponse.result.savedSet.items[0].rect.x) 'preview saved effective x'
        Assert-Equal 25 ([int]$previewResponse.result.draftSet.items[0].rect.x) 'preview draft effective x'
        Assert-Equal $false ([bool]$previewResponse.result.review.requiresAcknowledgement) 'absolute-only preview with no warnings needs no acknowledgement'
        Assert-Equal $null $previewResponse.result.review.reviewToken 'absolute-only preview has no review token'

        $noopDraft = ($previewRead.result.document | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
        $noopResponse = Send-Request -Process $previewProcess -Id 'p2' -Op 'preview' -Params @{ draft = $noopDraft; baseSha256 = $previewBase }
        Assert-True $noopResponse.ok 'no-op preview succeeds'
        Assert-Equal 0 @($noopResponse.result.diff).Count 'no-op preview has an empty diff'
        Assert-Equal $false ([bool]$noopResponse.result.review.requiresAcknowledgement) 'no-op preview needs no acknowledgement'

        $invalidDraft = ($previewRead.result.document | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
        $invalidDraft.sets[0].windows[0].layout.w = 0
        $invalidPreview = Send-Request -Process $previewProcess -Id 'p2b' -Op 'preview' -Params @{ draft = $invalidDraft; baseSha256 = $previewBase }
        Assert-Equal 'config-invalid' $invalidPreview.error.code 'preview rejects a structurally invalid draft'

        $unauthorizedDraft = ($previewRead.result.document | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
        $unauthorizedDraft.sets[0].windows[0].path = 'C:\Windows\System32'
        $unauthorizedResponse = Send-Request -Process $previewProcess -Id 'p3' -Op 'preview' -Params @{ draft = $unauthorizedDraft; baseSha256 = $previewBase }
        Assert-Equal 'unsupported-mutation' $unauthorizedResponse.error.code 'backend independently rejects an unauthorized path mutation'
        Assert-Contains ([string]$unauthorizedResponse.error.details.path) '/path' 'unauthorized error names the offending path'

        $externalResponse = Send-Request -Process $previewProcess -Id 'p4' -Op 'preview' -Params @{ draft = $noopDraft; baseSha256 = ('A' * 64) }
        Assert-Equal 'external-change' $externalResponse.error.code 'preview rejects a stale base revision'

        $fingerprintResponse = Send-Request -Process $previewProcess -Id 'p5' -Op 'preview' -Params @{ draft = $previewDraft; baseSha256 = $previewBase; baseTopologyFingerprint = ('A' * 64) }
        if ([bool]$previewInspect.result.topology.available) {
            Assert-Equal 'topology-changed' $fingerprintResponse.error.code 'preview rejects a supplied topology mismatch'
        }

        $saveResponse = Send-Request -Process $previewProcess -Id 'p6' -Op 'save'
        Assert-Equal 'request-invalid' $saveResponse.error.code 'save requires draft and baseSha256'
        Send-Request -Process $previewProcess -Id 'p7' -Op 'shutdown' | Out-Null
        $previewProcess.WaitForExit(10000) | Out-Null
    }
    finally {
        Stop-Backend -Process $previewProcess
    }
    Assert-Equal $previewHashBefore (Get-FileSha $configPath) 'preview did not change the config bytes'

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

    # 12d. Pure preview composition, semantic diff, and review binding.
    $previewConfig = New-Config -Windows @(
        (New-Terminal -Id 'abs' -WindowId 'DEVWS-P6-ABS' -Layout ([pscustomobject][ordered]@{ x = 0; y = 0; w = 800; h = 600 })),
        (New-RelativeTerminal -Id 'rel' -WindowId 'DEVWS-P6-REL' -Fallback ([pscustomobject][ordered]@{ x = 0; y = 0; w = 500; h = 400 }) -Identity 'path:TEST/MISSING' -Rect ([pscustomobject][ordered]@{ x = 0; y = 0; w = 0.5; h = 1 }))
    )
    $previewDraft = ($previewConfig | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
    $previewDraft.sets[0].windows[0].layout.x = 25
    $previewCore = Get-EditorPreviewCore -CanonicalConfig $previewConfig -DraftConfig $previewDraft -SetId 'main' -Topology $convTopology -BaseSha256 ('a' * 64) -CurrentSha256 ('a' * 64)
    Assert-True $previewCore.Ok 'pure preview succeeds'
    Assert-Equal 1 @($previewCore.Result.diff).Count 'pure preview diff count'
    Assert-Equal 'fallback' ([string]$previewCore.Result.diff[0].scope) 'pure preview fallback scope'
    Assert-Equal 1 @($previewCore.Warnings).Count 'pure preview warning count'
    Assert-Equal $true ([bool]$previewCore.Result.review.requiresAcknowledgement) 'pure preview requires acknowledgement for anchor warning'
    Assert-Equal 64 ([string]$previewCore.Result.review.warningDigest).Length 'pure preview warning digest length'
    Assert-Equal 64 ([string]$previewCore.Result.review.reviewToken).Length 'pure preview review token length'

    $previewCoreAgain = Get-EditorPreviewCore -CanonicalConfig $previewConfig -DraftConfig $previewDraft -SetId 'main' -Topology $convTopology -BaseSha256 ('a' * 64) -CurrentSha256 ('a' * 64)
    Assert-Equal ([string]$previewCore.Result.review.warningDigest) ([string]$previewCoreAgain.Result.review.warningDigest) 'warning digest is stable'
    Assert-Equal ([string]$previewCore.Result.review.reviewToken) ([string]$previewCoreAgain.Result.review.reviewToken) 'review token is stable'

    Assert-Equal ((@($previewCore.Result.review.warningIds) -join '|')) ((@($previewCoreAgain.Result.review.warningIds) -join '|')) 'warning ids are stable'
    $altTopology = ($convTopology | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
    $altTopology.Fingerprint = ('F' * 64)
    $altTopologyPreview = Get-EditorPreviewCore -CanonicalConfig $previewConfig -DraftConfig $previewDraft -SetId 'main' -Topology $altTopology -BaseSha256 ('a' * 64) -CurrentSha256 ('a' * 64) -BaseTopologyFingerprint $altTopology.Fingerprint
    Assert-True ([string]$previewCore.Result.review.reviewToken -cne [string]$altTopologyPreview.Result.review.reviewToken) 'review token changes with topology fingerprint'
    Assert-Equal ([string]$previewCore.Result.review.warningDigest) ([string]$altTopologyPreview.Result.review.warningDigest) 'topology-only change leaves warning digest stable'

    $noopWithWarnings = Get-EditorPreviewCore -CanonicalConfig $previewConfig -DraftConfig ($previewConfig | ConvertTo-Json -Depth 30 | ConvertFrom-Json) -SetId 'main' -Topology $convTopology -BaseSha256 ('a' * 64) -CurrentSha256 ('a' * 64)
    Assert-True $noopWithWarnings.Ok 'no-op preview with saved warnings succeeds'
    Assert-Equal 0 @($noopWithWarnings.Result.diff).Count 'no-op preview with warnings has no diff'
    Assert-Equal $false ([bool]$noopWithWarnings.Result.review.requiresAcknowledgement) 'no-op preview does not require acknowledgement for saved warnings'

    $previewCoreNewBase = Get-EditorPreviewCore -CanonicalConfig $previewConfig -DraftConfig $previewDraft -SetId 'main' -Topology $convTopology -BaseSha256 ('b' * 64) -CurrentSha256 ('b' * 64)
    Assert-True ([string]$previewCore.Result.review.reviewToken -cne [string]$previewCoreNewBase.Result.review.reviewToken) 'review token changes with revision'

    $noTopologyAbsolute = Get-EditorPreviewCore -CanonicalConfig $previewConfig -DraftConfig $previewDraft -SetId 'main' -Topology $null -BaseSha256 ('a' * 64) -CurrentSha256 ('a' * 64)
    Assert-True $noTopologyAbsolute.Ok 'absolute-only preview succeeds without topology'
    Assert-Equal $null $noTopologyAbsolute.Result.topologyFingerprint 'absolute-only unavailable topology reports null fingerprint'

    $relativeDraft = ($previewConfig | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
    $relativeDraft.sets[0].windows[1].layoutRelative.rect.x = 0.25
    $noTopologyRelative = Get-EditorPreviewCore -CanonicalConfig $previewConfig -DraftConfig $relativeDraft -SetId 'main' -Topology $null -BaseSha256 ('a' * 64) -CurrentSha256 ('a' * 64)
    Assert-Equal 'topology-unavailable' ([string]$noTopologyRelative.Code) 'relative preview without topology refused'

    $relativePreview = Get-EditorPreviewCore -CanonicalConfig $previewConfig -DraftConfig $relativeDraft -SetId 'main' -Topology $convTopology -BaseSha256 ('a' * 64) -CurrentSha256 ('a' * 64) -BaseTopologyFingerprint $convTopology.Fingerprint
    Assert-True $relativePreview.Ok 'relative preview succeeds with topology'
    Assert-Equal 'relative' ([string]$relativePreview.Result.diff[0].scope) 'relative preview diff scope'

    $incompleteTopology = ($convTopology | ConvertTo-Json -Depth 20 | ConvertFrom-Json)
    $incompleteTopology.IdentityComplete = $false
    $incompleteTopology.CorrelationComplete = $false
    $incompleteRelative = Get-EditorPreviewCore -CanonicalConfig $previewConfig -DraftConfig $relativeDraft -SetId 'main' -Topology $incompleteTopology -BaseSha256 ('a' * 64) -CurrentSha256 ('a' * 64) -BaseTopologyFingerprint $incompleteTopology.Fingerprint
    Assert-Equal 'topology-incomplete' ([string]$incompleteRelative.Code) 'relative preview with incomplete topology refused'

    $missingFingerprint = Get-EditorPreviewCore -CanonicalConfig $previewConfig -DraftConfig $relativeDraft -SetId 'main' -Topology $convTopology -BaseSha256 ('a' * 64) -CurrentSha256 ('a' * 64)
    Assert-Equal 'request-invalid' ([string]$missingFingerprint.Code) 'relative preview requires a base topology fingerprint'

    $profileConfig = New-Config -Windows @(
        (New-Terminal -Id 'abs' -WindowId 'DEVWS-P6-PROFILE' -Layout ([pscustomobject][ordered]@{ x = 0; y = 0; w = 800; h = 600 }))
    ) -Profiles @(
        (New-Profile -Id 'docked' -Tokens @($convTopology.Signature -split ';') -Layouts @{ abs = [pscustomobject][ordered]@{ x = 0; y = 0; w = 800; h = 600 } })
    )
    $profileFallbackDraft = ($profileConfig | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
    $profileFallbackDraft.sets[0].windows[0].layout.x = 25
    $profileFallbackPreview = Get-EditorPreviewCore -CanonicalConfig $profileConfig -DraftConfig $profileFallbackDraft -SetId 'main' -Topology $convTopology -BaseSha256 ('a' * 64) -CurrentSha256 ('a' * 64)
    Assert-True $profileFallbackPreview.Ok 'profile fallback preview succeeds'
    Assert-Equal 'fallback' ([string]$profileFallbackPreview.Result.diff[0].scope) 'inactive fallback diff scope'
    Assert-Equal ([int]$profileFallbackPreview.Result.savedSet.items[0].rect.x) ([int]$profileFallbackPreview.Result.draftSet.items[0].rect.x) 'inactive fallback leaves effective rect unchanged'

    $profileEntryDraft = ($profileConfig | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
    $profileEntryDraft.sets[0].layoutProfiles[0].layouts.abs.x = 10
    $profileEntryPreview = Get-EditorPreviewCore -CanonicalConfig $profileConfig -DraftConfig $profileEntryDraft -SetId 'main' -Topology $convTopology -BaseSha256 ('a' * 64) -CurrentSha256 ('a' * 64) -BaseTopologyFingerprint $convTopology.Fingerprint
    Assert-True $profileEntryPreview.Ok 'profile entry preview succeeds'
    Assert-Equal 'profile:docked' ([string]$profileEntryPreview.Result.diff[0].scope) 'profile entry diff scope'
    Assert-Equal 10 ([int]$profileEntryPreview.Result.draftSet.items[0].rect.x) 'profile entry changes effective rect'

    $sparseConfig = New-Config -Windows @(
        (New-Terminal -Id 'abs' -WindowId 'DEVWS-P6-SPARSE' -Layout ([pscustomobject][ordered]@{ x = 0; y = 0; w = 800; h = 600 })),
        (New-RelativeTerminal -Id 'rel' -WindowId 'DEVWS-P6-SPARSE-REL' -Fallback ([pscustomobject][ordered]@{ x = 0; y = 0; w = 500; h = 400 }) -Identity 'path:TEST/RIGHT' -Rect ([pscustomobject][ordered]@{ x = 0; y = 0; w = 0.5; h = 1 }))
    ) -Profiles @(
        (New-Profile -Id 'docked' -Tokens @($convTopology.Signature -split ';') -Layouts @{ abs = [pscustomobject][ordered]@{ x = 0; y = 0; w = 800; h = 600 } })
    )
    $sparseDraft = ($sparseConfig | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
    $sparseDraft.sets[0].windows[1].layout.x = 25
    $sparsePreview = Get-EditorPreviewCore -CanonicalConfig $sparseConfig -DraftConfig $sparseDraft -SetId 'main' -Topology $convTopology -BaseSha256 ('a' * 64) -CurrentSha256 ('a' * 64)
    Assert-True $sparsePreview.Ok 'sparse-profile fallback preview succeeds'
    Assert-Equal 'fallback' ([string]$sparsePreview.Result.diff[0].scope) 'sparse-profile fallback scope'
    Assert-Equal ([int]$sparsePreview.Result.savedSet.items[1].rect.x) ([int]$sparsePreview.Result.draftSet.items[1].rect.x) 'sparse-profile omission leaves effective relative rect unchanged'

    $modeDraft = ($previewConfig | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
    $modeDraft.sets[0].windows[0] | Add-Member -NotePropertyName layoutMode -NotePropertyValue 'relative' -Force
    $modeDraft.sets[0].windows[0] | Add-Member -NotePropertyName layoutRelative -NotePropertyValue ([pscustomobject][ordered]@{
        monitor = [pscustomobject][ordered]@{ identity = 'path:TEST/RIGHT' }
        basis = 'workArea'
        rect = [pscustomobject][ordered]@{ x = 0; y = 0; w = 0.5; h = 1 }
    }) -Force
    $modePreview = Get-EditorPreviewCore -CanonicalConfig $previewConfig -DraftConfig $modeDraft -SetId 'main' -Topology $convTopology -BaseSha256 ('a' * 64) -CurrentSha256 ('a' * 64) -BaseTopologyFingerprint $convTopology.Fingerprint
    Assert-True $modePreview.Ok 'mode conversion preview succeeds'
    Assert-True (@($modePreview.Result.diff | Where-Object { $_.scope -eq 'mode' }).Count -eq 1) 'mode conversion diff includes mode'
    Assert-True (@($modePreview.Result.diff | Where-Object { $_.scope -eq 'relative' }).Count -eq 1) 'mode conversion diff includes relative object'

    $unauthorizedPreviewDraft = ($previewConfig | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
    $unauthorizedPreviewDraft.sets[0].windows[0].tabs[0].args = @('/c', 'calc')
    $unauthorizedPreview = Get-EditorPreviewCore -CanonicalConfig $previewConfig -DraftConfig $unauthorizedPreviewDraft -SetId 'main' -Topology $convTopology -BaseSha256 ('a' * 64) -CurrentSha256 ('a' * 64)
    Assert-Equal 'unsupported-mutation' ([string]$unauthorizedPreview.Code) 'pure preview rejects tab changes'

    $negativeDraft = ($previewConfig | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
    $negativeDraft.sets[0].windows[0].layout.x = -2500
    $negativePreview = Get-EditorPreviewCore -CanonicalConfig $previewConfig -DraftConfig $negativeDraft -SetId 'main' -Topology $convTopology -BaseSha256 ('a' * 64) -CurrentSha256 ('a' * 64)
    Assert-True $negativePreview.Ok 'negative-coordinate preview succeeds'
    Assert-Equal -2500 ([int]$negativePreview.Result.diff[0].after.x) 'negative-coordinate diff preserves x'

    $duplicateTopology = New-SyntheticTopology -Monitors @(
        (New-SyntheticMonitor -Identity 'path:TEST/DUP' -X -1000 -Y 0 -W 1000 -H 800),
        (New-SyntheticMonitor -Identity 'path:TEST/DUP' -X 0 -Y 0 -W 1000 -H 800)
    )
    $ambiguousConfig = New-Config -Windows @(
        (New-RelativeTerminal -Id 'amb' -WindowId 'DEVWS-P6-AMB' -Fallback ([pscustomobject][ordered]@{ x = 10; y = 20; w = 300; h = 400 }) -Identity 'path:TEST/DUP' -Rect ([pscustomobject][ordered]@{ x = 0; y = 0; w = 0.5; h = 1 }))
    )
    $ambiguousDraft = ($ambiguousConfig | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
    $ambiguousDraft.sets[0].windows[0].layoutRelative.rect.x = 0.25
    $ambiguousPreview = Get-EditorPreviewCore -CanonicalConfig $ambiguousConfig -DraftConfig $ambiguousDraft -SetId 'main' -Topology $duplicateTopology -BaseSha256 ('a' * 64) -CurrentSha256 ('a' * 64) -BaseTopologyFingerprint $duplicateTopology.Fingerprint
    Assert-True $ambiguousPreview.Ok 'ambiguous-anchor preview still returns a structural result'
    Assert-True (@($ambiguousPreview.Warnings | Where-Object { $_.code -eq 'anchor-ambiguous' }).Count -ge 1) 'ambiguous anchor warning emitted'
    Assert-Equal $true ([bool]$ambiguousPreview.Result.review.requiresAcknowledgement) 'ambiguous anchor requires acknowledgement'
    Assert-True ([string]$previewCore.Result.review.warningDigest -cne [string]$ambiguousPreview.Result.review.warningDigest) 'warning digest changes with warning context'

    $unreachableConfig = New-Config -Windows @(
        (New-RelativeTerminal -Id 'unreach' -WindowId 'DEVWS-P6-UNREACH' -Fallback ([pscustomobject][ordered]@{ x = 10000; y = 10000; w = 300; h = 400 }) -Identity 'path:TEST/LEFT' -Rect ([pscustomobject][ordered]@{ x = 2; y = 2; w = 0.5; h = 0.5 }))
    )
    $unreachableDraft = ($unreachableConfig | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
    $unreachableDraft.sets[0].windows[0].layoutRelative.rect.x = 2.1
    $unreachablePreview = Get-EditorPreviewCore -CanonicalConfig $unreachableConfig -DraftConfig $unreachableDraft -SetId 'main' -Topology $convTopology -BaseSha256 ('a' * 64) -CurrentSha256 ('a' * 64) -BaseTopologyFingerprint $convTopology.Fingerprint
    Assert-True $unreachablePreview.Ok 'unreachable placement preview still returns a structural result'
    Assert-True (@($unreachablePreview.Warnings | Where-Object { $_.code -eq 'relative-unreachable' }).Count -ge 1) 'unreachable placement warning emitted'

    $fallbackWarningConfig = New-Config -Windows @(
        (New-Terminal -Id 'offscreen' -WindowId 'DEVWS-P6-FB-UNREACH' -Layout ([pscustomobject][ordered]@{ x = 10000; y = 10000; w = 300; h = 400 })),
        (New-Terminal -Id 'docked' -WindowId 'DEVWS-P6-FB-DOCKED' -Layout ([pscustomobject][ordered]@{ x = 0; y = 0; w = 800; h = 600 }))
    ) -Profiles @(
        (New-Profile -Id 'docked' -Tokens @($convTopology.Signature -split ';') -Layouts @{ docked = [pscustomobject][ordered]@{ x = 0; y = 0; w = 800; h = 600 } })
    )
    $fallbackWarningDraft = ($fallbackWarningConfig | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
    $fallbackWarningDraft.sets[0].windows[0].layout.x = 10010
    $fallbackWarningPreview = Get-EditorPreviewCore -CanonicalConfig $fallbackWarningConfig -DraftConfig $fallbackWarningDraft -SetId 'main' -Topology $convTopology -BaseSha256 ('a' * 64) -CurrentSha256 ('a' * 64)
    Assert-True $fallbackWarningPreview.Ok 'unreachable fallback preview still returns a structural result'
    Assert-True (@($fallbackWarningPreview.Warnings | Where-Object { $_.code -eq 'fallback-unreachable' }).Count -ge 1) 'unreachable absolute fallback warning emitted'
    Assert-Equal $true ([bool]$fallbackWarningPreview.Result.review.requiresAcknowledgement) 'unreachable fallback requires acknowledgement'

    $crossSetCanonical = ($previewConfig | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
    $crossSetCanonical.sets += [pscustomobject][ordered]@{
        id = 'other'
        windows = @([pscustomobject][ordered]@{
            id = 'other-item'
            type = 'terminal'
            enabled = $true
            windowId = 'DEVWS-P6-OTHER'
            path = 'C:\Windows'
            elevated = $true
            tabs = @([pscustomobject][ordered]@{ command = $null; args = @() })
            activeTab = 0
            layout = [pscustomobject][ordered]@{ x = 0; y = 0; w = 100; h = 100 }
        })
    }
    $crossSetDraft = ($crossSetCanonical | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
    $crossSetDraft.sets[1].windows[0].layout.x = 50
    $crossSetPreview = Get-EditorPreviewCore -CanonicalConfig $crossSetCanonical -DraftConfig $crossSetDraft -SetId 'main' -Topology $convTopology -BaseSha256 ('a' * 64) -CurrentSha256 ('a' * 64)
    Assert-Equal 'unsupported-mutation' ([string]$crossSetPreview.Code) 'cross-set geometry change rejected'
    Assert-Contains ([string]$crossSetPreview.Details.path) '/sets/1/' 'cross-set error names the other set'

    $unknownDraft = ($previewConfig | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
    $unknownDraft | Add-Member -NotePropertyName 'x-unknown' -NotePropertyValue $true
    $unknownPreview = Get-EditorPreviewCore -CanonicalConfig $previewConfig -DraftConfig $unknownDraft -SetId 'main' -Topology $convTopology -BaseSha256 ('a' * 64) -CurrentSha256 ('a' * 64)
    Assert-Equal 'unsupported-mutation' ([string]$unknownPreview.Code) 'new unknown property rejected'

    $typeDraft = ($previewConfig | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
    $typeDraft.sets[0].windows[0].type = 'app'
    $typePreview = Get-EditorPreviewCore -CanonicalConfig $previewConfig -DraftConfig $typeDraft -SetId 'main' -Topology $convTopology -BaseSha256 ('a' * 64) -CurrentSha256 ('a' * 64)
    Assert-Equal 'unsupported-mutation' ([string]$typePreview.Code) 'structural item type change rejected'

    Assert-True (Test-EditorJsonEqual -Left 0 -Right 0.0) 'numeric zero equivalence'
    Assert-True (Test-EditorJsonEqual -Left ([pscustomobject][ordered]@{ a = 1; b = 2 }) -Right ([pscustomobject][ordered]@{ b = 2; a = 1 })) 'object key order is not semantic'
    $explicitAbsoluteDraft = ($previewConfig | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
    $explicitAbsoluteDraft.sets[0].windows[0] | Add-Member -NotePropertyName layoutMode -NotePropertyValue 'absolute' -Force
    $explicitAbsolutePreview = Get-EditorPreviewCore -CanonicalConfig $previewConfig -DraftConfig $explicitAbsoluteDraft -SetId 'main' -Topology $convTopology -BaseSha256 ('a' * 64) -CurrentSha256 ('a' * 64)
    Assert-Equal 0 @($explicitAbsolutePreview.Result.diff).Count 'explicit absolute is equivalent to absent layoutMode'

    $informationalReview = Get-EditorWarningReview -Warnings @(
        [pscustomobject]@{ id = 'deferred|1'; code = 'deferred-qualification'; requiresAcknowledgement = $true; details = [pscustomobject]@{ setId = 'main' } }
    ) -BaseSha256 ('a' * 64) -TopologyFingerprint $convTopology.Fingerprint -HasChanges $true
    Assert-Equal $false ([bool]$informationalReview.requiresAcknowledgement) 'informational warning excluded from acknowledgement'
    Assert-Equal $null $informationalReview.warningDigest 'informational warning excluded from digest'

    $warningA = [pscustomobject][ordered]@{ id = 'b-warning'; code = 'anchor-missing'; message = 'human message one'; requiresAcknowledgement = $true; details = [pscustomobject][ordered]@{ setId = 'main'; itemId = 'x'; reason = 'missing'; relativeStatus = 'anchor-missing'; placementStatus = 'anchor-missing'; placementReason = 'missing' } }
    $warningB = [pscustomobject][ordered]@{ id = 'a-warning'; code = 'anchor-missing'; message = 'human message two'; requiresAcknowledgement = $true; details = [pscustomobject][ordered]@{ setId = 'main'; itemId = 'y'; reason = 'missing'; relativeStatus = 'anchor-missing'; placementStatus = 'anchor-missing'; placementReason = 'missing' } }
    $warningReviewOne = Get-EditorWarningReview -Warnings @($warningA, $warningB) -BaseSha256 ('a' * 64) -TopologyFingerprint $convTopology.Fingerprint -HasChanges $true
    $warningReviewTwo = Get-EditorWarningReview -Warnings @($warningA, $warningB) -BaseSha256 ('a' * 64) -TopologyFingerprint $convTopology.Fingerprint -HasChanges $true
    Assert-Equal 'a-warning|b-warning' ((@($warningReviewOne.warningIds) -join '|')) 'warning ids are sorted ordinally'
    Assert-Equal ([string]$warningReviewOne.warningDigest) ([string]$warningReviewTwo.warningDigest) 'warning digest is deterministic for identical contexts'

    $warningAMessageChanged = [pscustomobject][ordered]@{ id = 'b-warning'; code = 'anchor-missing'; message = 'completely different human wording'; requiresAcknowledgement = $true; details = [pscustomobject][ordered]@{ setId = 'main'; itemId = 'x'; reason = 'missing'; relativeStatus = 'anchor-missing'; placementStatus = 'anchor-missing'; placementReason = 'missing' } }
    $warningMessageReview = Get-EditorWarningReview -Warnings @($warningAMessageChanged) -BaseSha256 ('a' * 64) -TopologyFingerprint $convTopology.Fingerprint -HasChanges $true
    $warningNoMessageReview = Get-EditorWarningReview -Warnings @($warningA) -BaseSha256 ('a' * 64) -TopologyFingerprint $convTopology.Fingerprint -HasChanges $true
    Assert-Equal ([string]$warningMessageReview.warningDigest) ([string]$warningNoMessageReview.warningDigest) 'human warning message does not affect digest'

    # 12e. P7 guarded save and persistence.
    $saveRoot = New-TempRoot
    $saveConfig = New-Config -Windows @(
        (New-Terminal -Id 'save-abs' -WindowId 'DEVWS-P7-SAVE' -Layout ([pscustomobject][ordered]@{ x = 10; y = 20; w = 500; h = 400 }))
    )
    $saveConfig | Add-Member -NotePropertyName 'x-unknown' -NotePropertyValue ([pscustomobject][ordered]@{ keep = 'yes' })
    $saveConfig.sets[0].windows[0] | Add-Member -NotePropertyName 'x-item-unknown' -NotePropertyValue ([pscustomobject][ordered]@{ keep = 7 })
    $savePath = Write-TestConfig -Config $saveConfig -Directory $saveRoot
    $saveOriginalHash = Get-FileSha $savePath
    $saveProcess = Start-Backend -ConfigPath $savePath

    try {
        $saveInspect = Send-Request -Process $saveProcess -Id 'sv-i' -Op 'inspect'
        $saveRead = Send-Request -Process $saveProcess -Id 'sv-r' -Op 'read-config' -Params @{ expectedSha256 = $saveInspect.result.config.sha256 }
        $saveBase = [string]$saveInspect.result.config.sha256
        $saveDraft = ($saveRead.result.document | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
        $saveDraft.sets[0].windows[0].layout.x = 30

        $savePreview = Send-Request -Process $saveProcess -Id 'sv-p' -Op 'preview' -Params @{ draft = $saveDraft; baseSha256 = $saveBase }
        Assert-True $savePreview.ok 'save fixture preview succeeds'
        Assert-Equal 1 @($savePreview.result.diff).Count 'save fixture preview has one change'
        Assert-Equal $false ([bool]$savePreview.result.review.requiresAcknowledgement) 'absolute save fixture needs no review'

        $missingConfirm = Send-Request -Process $saveProcess -Id 'sv-c0' -Op 'save' -Params @{ draft = $saveDraft; baseSha256 = $saveBase }
        Assert-Equal 'request-invalid' $missingConfirm.error.code 'save requires explicit confirmation'

        $save = Send-Request -Process $saveProcess -Id 'sv-s1' -Op 'save' -Params @{ draft = $saveDraft; baseSha256 = $saveBase; confirm = $true }
        Assert-True $save.ok 'absolute save succeeds'
        Assert-Equal $true $save.result.saved 'save reports saved'
        Assert-Equal $true $save.result.changed 'save reports changed'
        Assert-Equal $saveBase $save.result.previousSha256 'save returns the previous revision'
        Assert-Equal (Get-FileSha $savePath) $save.result.newSha256 'save returns the persisted revision'
        Assert-True ([string]::Equals(([IO.Path]::GetFullPath($savePath)), [string]$save.result.canonicalPath, [StringComparison]::OrdinalIgnoreCase)) 'save returns the effective writable path'

        $savePersisted = Get-DevWSConfig -Location ([pscustomobject]@{ Path = $savePath; IsWritable = $true; IsBundledDefault = $false; Source = 'env' })
        Assert-Equal 30 ([int]$savePersisted.sets[0].windows[0].layout.x) 'save persisted the absolute geometry'
        Assert-Equal 7 ([int]$savePersisted.sets[0].windows[0].'x-item-unknown'.keep) 'save preserved item unknown properties'
        Assert-Equal 'yes' ([string]$savePersisted.'x-unknown'.keep) 'save preserved document unknown properties'

        $saveNewHash = [string]$save.result.newSha256
        $timestampBeforeNoop = (Get-Item -LiteralPath $savePath).LastWriteTimeUtc.Ticks
        $noop = Send-Request -Process $saveProcess -Id 'sv-s2' -Op 'save' -Params @{ draft = $savePersisted; baseSha256 = $saveNewHash; confirm = $true }
        $timestampAfterNoop = (Get-Item -LiteralPath $savePath).LastWriteTimeUtc.Ticks
        Assert-True $noop.ok 'no-op save succeeds'
        Assert-Equal $false $noop.result.changed 'no-op save reports unchanged'
        Assert-Equal $saveNewHash $noop.result.newSha256 'no-op save returns the same revision'
        Assert-Equal $timestampBeforeNoop $timestampAfterNoop 'no-op save does not replace the file'
        Assert-Equal $saveNewHash (Get-FileSha $savePath) 'no-op save leaves the bytes unchanged'

        $stale = Send-Request -Process $saveProcess -Id 'sv-s3' -Op 'save' -Params @{ draft = $saveDraft; baseSha256 = $saveBase; confirm = $true }
        Assert-Equal 'external-change' $stale.error.code 'stale base revision refuses the save'
        Assert-Equal $saveNewHash (Get-FileSha $savePath) 'stale save leaves the persisted bytes unchanged'

        $unauthorized = ($savePersisted | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
        $unauthorized.sets[0].windows[0].path = 'C:\Windows\System32'
        $unauthorizedSave = Send-Request -Process $saveProcess -Id 'sv-s4' -Op 'save' -Params @{ draft = $unauthorized; baseSha256 = $saveNewHash; confirm = $true }
        Assert-Equal 'unsupported-mutation' $unauthorizedSave.error.code 'save independently rejects a non-geometry mutation'
        Assert-Contains ([string]$unauthorizedSave.error.details.path) '/path' 'save refusal names the offending path'
        Assert-Equal $saveNewHash (Get-FileSha $savePath) 'rejected non-geometry save leaves the bytes unchanged'

        $crossSet = ($savePersisted | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
        $crossSet.sets += [pscustomobject][ordered]@{
            id = 'other'
            windows = @([pscustomobject][ordered]@{
                id = 'other-item'; type = 'terminal'; enabled = $true; windowId = 'DEVWS-P7-OTHER'; path = 'C:\Windows'; elevated = $true
                tabs = @([pscustomobject][ordered]@{ command = $null; args = @() }); activeTab = 0
                layout = [pscustomobject][ordered]@{ x = 0; y = 0; w = 100; h = 100 }
            })
        }
        $crossSetSave = Send-Request -Process $saveProcess -Id 'sv-s5' -Op 'save' -Params @{ draft = $crossSet; baseSha256 = $saveNewHash; confirm = $true }
        Assert-Equal 'unsupported-mutation' $crossSetSave.error.code 'save rejects set-membership changes'
        Assert-Equal $saveNewHash (Get-FileSha $savePath) 'cross-set save refusal leaves the bytes unchanged'

        $invalidSaveDraft = ($savePersisted | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
        $invalidSaveDraft.sets[0].windows[0].layout.w = 0
        $invalidSave = Send-Request -Process $saveProcess -Id 'sv-s6' -Op 'save' -Params @{ draft = $invalidSaveDraft; baseSha256 = $saveNewHash; confirm = $true }
        Assert-Equal 'config-invalid' $invalidSave.error.code 'save rejects an invalid draft'
        Assert-Equal $saveNewHash (Get-FileSha $savePath) 'invalid save leaves the bytes unchanged'

        Send-Request -Process $saveProcess -Id 'sv-x' -Op 'shutdown' | Out-Null
        $saveProcess.WaitForExit(10000) | Out-Null
    }
    finally {
        Stop-Backend -Process $saveProcess
    }
    Assert-True ($saveOriginalHash -cne (Get-FileSha $savePath)) 'absolute save changed the disposable fixture'

    # Warning-token enforcement without requiring topology: the changed scope is
    # an absolute fallback, while an unchanged relative item still warns.
    $warnRoot = New-TempRoot
    $warnConfig = New-Config -Windows @(
        (New-Terminal -Id 'warn-abs' -WindowId 'DEVWS-P7-WARN-ABS' -Layout ([pscustomobject][ordered]@{ x = 10; y = 20; w = 300; h = 200 })),
        (New-RelativeTerminal -Id 'warn-rel' -WindowId 'DEVWS-P7-WARN-REL' -Fallback ([pscustomobject][ordered]@{ x = 40; y = 50; w = 400; h = 300 }) -Identity 'path:DEVWS-P7/MISSING' -Rect ([pscustomobject][ordered]@{ x = 0; y = 0; w = 0.5; h = 1 }))
    )
    $warnPath = Write-TestConfig -Config $warnConfig -Directory $warnRoot
    $warnProcess = Start-Backend -ConfigPath $warnPath

    try {
        $warnInspect = Send-Request -Process $warnProcess -Id 'wv-i' -Op 'inspect'
        $warnRead = Send-Request -Process $warnProcess -Id 'wv-r' -Op 'read-config' -Params @{ expectedSha256 = $warnInspect.result.config.sha256 }
        $warnBase = [string]$warnInspect.result.config.sha256
        $warnDraft = ($warnRead.result.document | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
        $warnDraft.sets[0].windows[0].layout.x = 15
        $warnPreview = Send-Request -Process $warnProcess -Id 'wv-p' -Op 'preview' -Params @{ draft = $warnDraft; baseSha256 = $warnBase }
        Assert-True $warnPreview.ok 'warning fixture preview succeeds'
        Assert-Equal $true ([bool]$warnPreview.result.review.requiresAcknowledgement) 'warning fixture requires acknowledgement'
        $warnToken = [string]$warnPreview.result.review.reviewToken
        Assert-Equal 64 $warnToken.Length 'warning fixture returns a review token'

        $noToken = Send-Request -Process $warnProcess -Id 'wv-s1' -Op 'save' -Params @{ draft = $warnDraft; baseSha256 = $warnBase; confirm = $true }
        Assert-Equal 'warnings-not-acknowledged' $noToken.error.code 'save refuses missing warning acknowledgement'
        Assert-Equal $warnBase (Get-FileSha $warnPath) 'missing-token save leaves the bytes unchanged'

        $badToken = Send-Request -Process $warnProcess -Id 'wv-s2' -Op 'save' -Params @{ draft = $warnDraft; baseSha256 = $warnBase; confirm = $true; reviewToken = ('a' * 64) }
        Assert-Equal 'review-stale' $badToken.error.code 'save refuses a stale review token'
        Assert-Equal $warnBase (Get-FileSha $warnPath) 'stale-token save leaves the bytes unchanged'

        $tokenSave = Send-Request -Process $warnProcess -Id 'wv-s3' -Op 'save' -Params @{ draft = $warnDraft; baseSha256 = $warnBase; confirm = $true; reviewToken = $warnToken }
        Assert-True $tokenSave.ok 'save succeeds with the matching review token'
        Assert-Equal $true $tokenSave.result.changed 'token save reports changed'
        $warnPersisted = Get-DevWSConfig -Location ([pscustomobject]@{ Path = $warnPath; IsWritable = $true; IsBundledDefault = $false; Source = 'env' })
        Assert-Equal 15 ([int]$warnPersisted.sets[0].windows[0].layout.x) 'token save persisted the fallback edit'
        Assert-Equal 'relative' ([string]$warnPersisted.sets[0].windows[1].layoutMode) 'token save preserved relative mode'
        Assert-Equal 'path:DEVWS-P7/MISSING' ([string]$warnPersisted.sets[0].windows[1].layoutRelative.monitor.identity) 'token save preserved the unresolved anchor'
        Send-Request -Process $warnProcess -Id 'wv-x' -Op 'shutdown' | Out-Null
        $warnProcess.WaitForExit(10000) | Out-Null
    }
    finally {
        Stop-Backend -Process $warnProcess
    }

    # Profile-entry and relative saves use the host topology when available. The
    # pure preview tests above already cover resolver behavior with synthetic
    # topology; here the same shapes are persisted through the backend.
    $topologyForSave = $warnInspect.result.topology
    if ([bool]$topologyForSave.available -and @($topologyForSave.monitors).Count -gt 0) {
        $saveMonitor = @($topologyForSave.monitors)[0]
        $saveIdentity = [string]$saveMonitor.identity
        $saveFingerprint = [string]$topologyForSave.fingerprint
        $saveSignature = [string]$topologyForSave.signature

        $profileRoot = New-TempRoot
        $profileConfig = New-Config -Windows @(
            (New-Terminal -Id 'profile-item' -WindowId 'DEVWS-P7-PROFILE' -Layout ([pscustomobject][ordered]@{ x = 10; y = 20; w = 500; h = 400 })),
            (New-Terminal -Id 'profile-other' -WindowId 'DEVWS-P7-PROFILE-OTHER' -Layout ([pscustomobject][ordered]@{ x = 60; y = 70; w = 300; h = 200 }))
        ) -Profiles @(
            (New-Profile -Id 'matched' -Tokens @($saveSignature -split ';') -Layouts @{ 'profile-item' = [pscustomobject][ordered]@{ x = 100; y = 110; w = 600; h = 500 } })
        )
        $profilePath = Write-TestConfig -Config $profileConfig -Directory $profileRoot
        $profileProcess = Start-Backend -ConfigPath $profilePath
        try {
            $profileInspect = Send-Request -Process $profileProcess -Id 'pv-i' -Op 'inspect'
            $profileRead = Send-Request -Process $profileProcess -Id 'pv-r' -Op 'read-config' -Params @{ expectedSha256 = $profileInspect.result.config.sha256 }
            $profileDraft = ($profileRead.result.document | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
            $profileDraft.sets[0].layoutProfiles[0].layouts.'profile-item'.x = 135
            $profileSave = Send-Request -Process $profileProcess -Id 'pv-s' -Op 'save' -Params @{
                draft = $profileDraft
                baseSha256 = [string]$profileInspect.result.config.sha256
                topologyFingerprint = $saveFingerprint
                confirm = $true
            }
            Assert-True $profileSave.ok 'profile-entry save succeeds'
            Assert-Equal $true $profileSave.result.changed 'profile-entry save reports changed'
            $profilePersisted = Read-DevWSConfigFile -Path $profilePath
            Assert-Equal 135 ([int]$profilePersisted.sets[0].layoutProfiles[0].layouts.'profile-item'.x) 'profile-entry geometry persisted'
            Assert-Equal 600 ([int]$profilePersisted.sets[0].layoutProfiles[0].layouts.'profile-item'.w) 'unchanged profile-entry geometry preserved'
            Send-Request -Process $profileProcess -Id 'pv-x' -Op 'shutdown' | Out-Null
            $profileProcess.WaitForExit(10000) | Out-Null
        }
        finally {
            Stop-Backend -Process $profileProcess
        }

        $relativeRoot = New-TempRoot
        $relativeConfig = New-Config -Windows @(
            (New-RelativeTerminal -Id 'relative-item' -WindowId 'DEVWS-P7-REL' -Fallback ([pscustomobject][ordered]@{ x = 10; y = 20; w = 500; h = 400 }) -Identity $saveIdentity -Basis 'workArea' -Rect ([pscustomobject][ordered]@{ x = 0; y = 0; w = 0.5; h = 1 }))
        )
        $relativePath = Write-TestConfig -Config $relativeConfig -Directory $relativeRoot
        $relativeProcess = Start-Backend -ConfigPath $relativePath
        try {
            $relativeInspect = Send-Request -Process $relativeProcess -Id 'rv-i' -Op 'inspect'
            $relativeRead = Send-Request -Process $relativeProcess -Id 'rv-r' -Op 'read-config' -Params @{ expectedSha256 = $relativeInspect.result.config.sha256 }
            $relativeDraft = ($relativeRead.result.document | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
            $relativeDraft.sets[0].windows[0].layoutRelative.rect.x = 0.25
            $relativeSave = Send-Request -Process $relativeProcess -Id 'rv-s' -Op 'save' -Params @{
                draft = $relativeDraft
                baseSha256 = [string]$relativeInspect.result.config.sha256
                topologyFingerprint = $saveFingerprint
                confirm = $true
            }
            Assert-True $relativeSave.ok 'relative-geometry save succeeds'
            Assert-Equal $true $relativeSave.result.changed 'relative save reports changed'
            $relativePersisted = Read-DevWSConfigFile -Path $relativePath
            Assert-Equal 'relative' ([string]$relativePersisted.sets[0].windows[0].layoutMode) 'relative mode persisted'
            Assert-Equal 0.25 ([double]$relativePersisted.sets[0].windows[0].layoutRelative.rect.x) 'relative rectangle persisted'
            Assert-Equal $saveIdentity ([string]$relativePersisted.sets[0].windows[0].layoutRelative.monitor.identity) 'relative anchor persisted'

            $modeDraft = ($relativePersisted | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
            $modeDraft.sets[0].windows[0].PSObject.Properties.Remove('layoutRelative')
            $modeDraft.sets[0].windows[0] | Add-Member -NotePropertyName layoutMode -NotePropertyValue 'absolute' -Force
            $modeSave = Send-Request -Process $relativeProcess -Id 'rv-s2' -Op 'save' -Params @{
                draft = $modeDraft
                baseSha256 = (Get-FileSha $relativePath)
                topologyFingerprint = $saveFingerprint
                confirm = $true
            }
            Assert-True $modeSave.ok 'relative-to-absolute save succeeds'
            $modePersisted = Read-DevWSConfigFile -Path $relativePath
            Assert-Equal $false ($null -ne $modePersisted.sets[0].windows[0].PSObject.Properties['layoutRelative']) 'relative-to-absolute save removed layoutRelative'

            $absoluteToRelative = ($modePersisted | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
            $absoluteToRelative.sets[0].windows[0] | Add-Member -NotePropertyName layoutMode -NotePropertyValue 'relative' -Force
            $absoluteToRelative.sets[0].windows[0] | Add-Member -NotePropertyName layoutRelative -NotePropertyValue ([pscustomobject][ordered]@{
                monitor = [pscustomobject][ordered]@{ identity = $saveIdentity }
                basis = 'workArea'
                rect = [pscustomobject][ordered]@{ x = 0.125; y = 0.25; w = 0.5; h = 0.5 }
            }) -Force
            $absoluteSave = Send-Request -Process $relativeProcess -Id 'rv-s3' -Op 'save' -Params @{
                draft = $absoluteToRelative
                baseSha256 = (Get-FileSha $relativePath)
                topologyFingerprint = $saveFingerprint
                confirm = $true
            }
            Assert-True $absoluteSave.ok 'absolute-to-relative save succeeds'
            $absolutePersisted = Read-DevWSConfigFile -Path $relativePath
            Assert-Equal 'relative' ([string]$absolutePersisted.sets[0].windows[0].layoutMode) 'absolute-to-relative mode persisted'
            Assert-Equal 0.125 ([double]$absolutePersisted.sets[0].windows[0].layoutRelative.rect.x) 'absolute-to-relative rectangle persisted'

            $driftDraft = ($absolutePersisted | ConvertTo-Json -Depth 30 | ConvertFrom-Json)
            $driftDraft.sets[0].windows[0].layoutRelative.rect.x = 0.375
            $driftHash = Get-FileSha $relativePath
            $driftSave = Send-Request -Process $relativeProcess -Id 'rv-s4' -Op 'save' -Params @{
                draft = $driftDraft
                baseSha256 = $driftHash
                topologyFingerprint = ('A' * 64)
                confirm = $true
            }
            Assert-Equal 'topology-changed' $driftSave.error.code 'relative save refuses a topology mismatch'
            Assert-Equal $driftHash (Get-FileSha $relativePath) 'topology refusal leaves the bytes unchanged'
            Send-Request -Process $relativeProcess -Id 'rv-x' -Op 'shutdown' | Out-Null
            $relativeProcess.WaitForExit(10000) | Out-Null
        }
        finally {
            Stop-Backend -Process $relativeProcess
        }
    }
    else {
        $script:Skipped++
        Write-Host '  [SKIP] profile/relative persistence cases: host topology is unavailable' -ForegroundColor Yellow
    }

    # Post-commit re-read classification (deterministic helper seam).
    $confirmationBase = [pscustomobject]@{ Sha256 = ('a' * 64); Location = [pscustomobject]@{ Path = 'C:\fixture\workspace.json' } }
    $confirmationMissing = Get-EditorSaveConfirmation -Snapshot $confirmationBase -AfterSnapshot $null
    Assert-Equal 'save-outcome-uncertain' ([string]$confirmationMissing.Code) 'missing post-save re-read is uncertain'
    $confirmationInvalid = Get-EditorSaveConfirmation -Snapshot $confirmationBase -AfterSnapshot ([pscustomobject]@{ Ok = $true; Valid = $false; Sha256 = ('b' * 64) })
    Assert-Equal 'save-outcome-uncertain' ([string]$confirmationInvalid.Code) 'invalid post-save re-read is uncertain'
    $confirmationSame = Get-EditorSaveConfirmation -Snapshot $confirmationBase -AfterSnapshot ([pscustomobject]@{ Ok = $true; Valid = $true; Sha256 = ('a' * 64) })
    Assert-Equal 'save-outcome-uncertain' ([string]$confirmationSame.Code) 'unchanged post-save revision is uncertain'
    $confirmationNew = Get-EditorSaveConfirmation -Snapshot $confirmationBase -AfterSnapshot ([pscustomobject]@{ Ok = $true; Valid = $true; Sha256 = ('b' * 64) })
    Assert-True $confirmationNew.Ok 'changed post-save revision is confirmed'
    Assert-Equal ('b' * 64) ([string]$confirmationNew.Result.newSha256) 'confirmation returns the observed revision'
    Assert-Equal 'C:\fixture\workspace.json' ([string]$confirmationNew.Result.canonicalPath) 'confirmation returns the effective path'
    $confirmationMismatch = Get-EditorSaveConfirmation -Snapshot $confirmationBase -AfterSnapshot ([pscustomobject]@{ Ok = $true; Valid = $true; Sha256 = ('c' * 64) }) -WrittenSha256 ('b' * 64)
    Assert-Equal 'save-outcome-uncertain' ([string]$confirmationMismatch.Code) 'persisted bytes different from the written revision are uncertain'

    # ExpectedSha256 / mutex primitive tests.
    $mutexRoot = New-TempRoot
    $mutexConfig = New-Config -Windows @(
        (New-Terminal -Id 'mutex' -WindowId 'DEVWS-P7-MUTEX' -Layout ([pscustomobject][ordered]@{ x = 10; y = 20; w = 300; h = 200 }))
    )
    $mutexPath = Write-TestConfig -Config $mutexConfig -Directory $mutexRoot
    $mutexHash = Get-FileSha $mutexPath
    $mutexLocation = [pscustomobject]@{ Path = $mutexPath; IsWritable = $true; IsBundledDefault = $false; Source = 'env' }
    $mutexConfig.sets[0].windows[0].layout.x = 25
    $writtenHash = $null
    Save-DevWSConfig -Config $mutexConfig -Location $mutexLocation -ExpectedSha256 $mutexHash -WrittenSha256 ([ref]$writtenHash)
    Assert-Equal 25 ([int](Read-DevWSConfigFile -Path $mutexPath).sets[0].windows[0].layout.x) 'Save-DevWSConfig accepted the matching revision'
    Assert-Equal (Get-FileSha $mutexPath) ([string]$writtenHash) 'Save-DevWSConfig returns the written revision'
    $mutexAfter = Get-FileSha $mutexPath
    try {
        $mutexConfig.sets[0].windows[0].layout.x = 99
        Save-DevWSConfig -Config $mutexConfig -Location $mutexLocation -ExpectedSha256 $mutexHash
        Fail-Test 'Save-DevWSConfig did not refuse a stale revision'
    }
    catch {
        Assert-Equal 'external-change' ([string]$_.Exception.Data['DevWSCode']) 'Save-DevWSConfig refuses a stale revision'
    }
    Assert-Equal $mutexAfter (Get-FileSha $mutexPath) 'stale Save-DevWSConfig leaves the bytes unchanged'
    Assert-Equal $false (Test-Path -LiteralPath "$mutexPath.tmp") 'stale Save-DevWSConfig cleaned the temp file'

    # A participating writer waits on Local\DevWS.Config.Write while another
    # participant holds it, then commits its own expected revision.
    $mutexChildPath = Join-Path $mutexRoot 'child-save.ps1'
    $mutexMarker = Join-Path $mutexRoot 'child-entered.txt'
    $mutexChildError = Join-Path $mutexRoot 'child-error.txt'
    $childConfig = (Read-DevWSConfigFile -Path $mutexPath)
    $childConfig.sets[0].windows[0].layout.x = 44
    $childConfig | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath (Join-Path $mutexRoot 'child.json') -Encoding UTF8
    $childScript = @"
`$ErrorActionPreference = 'Stop'
. '$libRoot\devws-paths.ps1'
. '$libRoot\devws-config.ps1'
[IO.File]::WriteAllText('$mutexMarker', 'entered')
`$cfg = Read-DevWSConfigFile -Path '$(Join-Path $mutexRoot 'child.json')'
`$loc = [pscustomobject]@{ Path = '$mutexPath'; IsWritable = `$true; IsBundledDefault = `$false; Source = 'env' }
Save-DevWSConfig -Config `$cfg -Location `$loc -ExpectedSha256 '$mutexAfter'
"@
    Set-Content -LiteralPath $mutexChildPath -Value $childScript -Encoding UTF8
    $heldMutex = [Threading.Mutex]::new($false, 'Local\DevWS.Config.Write')
    $held = $heldMutex.WaitOne([TimeSpan]::FromSeconds(5))
    Assert-True $held 'test acquired the configuration write mutex'
    $child = $null
    $child = Start-Process -FilePath $pwsh -ArgumentList @('-NoLogo','-NoProfile','-File',$mutexChildPath) -PassThru -RedirectStandardError $mutexChildError
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds(5)
        while (-not (Test-Path -LiteralPath $mutexMarker) -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
        Assert-True (Test-Path -LiteralPath $mutexMarker) 'participating writer reached the save call'
        Start-Sleep -Milliseconds 300
        Assert-Equal $false $child.HasExited 'participating writer waits while the mutex is held'
        $heldMutex.ReleaseMutex(); $held = $false
        Assert-True ($child.WaitForExit(15000)) 'participating writer completes after the mutex is released'
        Assert-Equal 0 $child.ExitCode 'participating writer succeeds'
        Assert-Equal 44 ([int](Read-DevWSConfigFile -Path $mutexPath).sets[0].windows[0].layout.x) 'participating writer persisted under the mutex'
    }
    finally {
        if ($held) { try { $heldMutex.ReleaseMutex() } catch {} }
        $heldMutex.Dispose()
        if ($null -ne $child) {
            if (-not $child.HasExited) { $child.Kill() }
            $child.Dispose()
        }
    }

    $legacyConfig = (Read-DevWSConfigFile -Path $mutexPath)
    $legacyConfig.sets[0].windows[0].layout.x = 55
    Save-DevWSConfig -Config $legacyConfig -Location $mutexLocation
    Assert-Equal 55 ([int](Read-DevWSConfigFile -Path $mutexPath).sets[0].windows[0].layout.x) 'legacy Save-DevWSConfig callers still write'

    # A genuine OS write failure leaves the canonical bytes intact and cleans the temp file.
    $failRoot = New-TempRoot
    $failConfig = New-Config -Windows @(
        (New-Terminal -Id 'fail' -WindowId 'DEVWS-P7-FAIL' -Layout ([pscustomobject][ordered]@{ x = 10; y = 20; w = 300; h = 200 }))
    )
    $failPath = Write-TestConfig -Config $failConfig -Directory $failRoot
    $failHash = Get-FileSha $failPath
    $failConfig.sets[0].windows[0].layout.x = 35
    Set-ItemProperty -LiteralPath $failPath -Name IsReadOnly -Value $true
    try {
        try {
            Save-DevWSConfig -Config $failConfig -Location ([pscustomobject]@{ Path = $failPath; IsWritable = $true; IsBundledDefault = $false; Source = 'env' }) -ExpectedSha256 $failHash
            Fail-Test 'Save-DevWSConfig did not report a read-only replacement failure'
        }
        catch {
            Assert-True ([string]::IsNullOrEmpty([string]$_.Exception.Data['DevWSCode'])) 'read-only replacement is an unclassified save failure'
        }
        Assert-Equal $failHash (Get-FileSha $failPath) 'read-only replacement leaves the bytes unchanged'
        Assert-Equal $false (Test-Path -LiteralPath "$failPath.tmp") 'read-only replacement cleans the temp file'
    }
    finally {
        Set-ItemProperty -LiteralPath $failPath -Name IsReadOnly -Value $false
    }

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
Write-Host ("P7 focused assertions passed: {0}; failed: {1}; skipped: {2}" -f $script:Passed, $script:Failures.Count, $script:Skipped) -ForegroundColor Cyan
if ($script:Failures.Count -gt 0) {
    $script:Failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

exit 0
