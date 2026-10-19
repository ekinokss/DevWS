# DevWS set launch bindings: hotkey grammar, deterministic AHK translation,
# generated derived state, and sync orchestration.
#
# Canonical config is the source of truth (`bindings` in workspace.json).
# The AutoHotkey file under the state root is derived state and is always
# regenerated from config; never edit it by hand.
#
# One managed Startup script (TerminalShortcut.ahk) remains the only
# persistent AutoHotkey process. It already owns Alt+T (AdminTerminal) and
# Alt+Shift+T (bare `ws launch`); this library only produces the optional
# generated include that adds explicit-set launch hotkeys.

function ConvertTo-DevWSBindingHotkey {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Hotkey
    )

    $raw = "$Hotkey"

    if ([string]::IsNullOrWhiteSpace($raw)) {
        throw "A hotkey is required, for example 'alt+shift+y' (one or more modifiers plus exactly one key)."
    }

    $modifierOrder = @("ctrl", "alt", "shift", "win")
    $namedKeys     = @("space", "tab", "enter", "esc", "backspace", "up", "down", "left", "right", "home", "end", "pgup", "pgdn", "insert", "delete")

    $tokens = @()

    foreach ($part in $raw.Split("+")) {
        $token = $part.Trim().ToLowerInvariant()

        if ([string]::IsNullOrEmpty($token)) {
            throw "Hotkey '$raw' contains an empty token. Use one or more modifiers and exactly one key, separated by '+', for example 'alt+shift+y'."
        }

        $tokens += $token
    }

    $modifiers = @($tokens | Where-Object { $modifierOrder -contains $_ })
    $keys      = @($tokens | Where-Object { $modifierOrder -notcontains $_ })

    if ($modifiers.Count -eq 0) {
        throw "Hotkey '$raw' needs at least one modifier (ctrl, alt, shift or win)."
    }

    foreach ($modifier in @($modifierOrder)) {
        if (@($modifiers | Where-Object { $_ -eq $modifier }).Count -gt 1) {
            throw "Hotkey '$raw' repeats the modifier '$modifier'. Each modifier may appear only once."
        }
    }

    if ($keys.Count -eq 0) {
        throw "Hotkey '$raw' is missing its key. Use one or more modifiers plus exactly one key, for example 'alt+shift+y'."
    }

    if ($keys.Count -gt 1) {
        throw "Hotkey '$raw' has more than one key ('$($keys -join "', '")'). Use exactly one non-modifier key."
    }

    $key = $keys[0]
    $keyOk = $false

    if ($key -match '^[a-z]$') {
        $keyOk = $true
    }
    elseif ($key -match '^[0-9]$') {
        $keyOk = $true
    }
    elseif ($key -match '^f([1-9]|1[0-9]|2[0-4])$') {
        $keyOk = $true
    }
    elseif ($namedKeys -contains $key) {
        $keyOk = $true
    }

    if (-not $keyOk) {
        throw "Hotkey '$raw' uses unsupported key '$key'. Supported keys: a-z, 0-9, f1-f24, space, tab, enter, esc, backspace, up, down, left, right, home, end, pgup, pgdn, insert, delete."
    }

    $canonicalModifiers = @($modifierOrder | Where-Object { $modifiers -contains $_ })

    return (($canonicalModifiers + $key) -join "+")
}

function Test-DevWSReservedBindingHotkey {
    param(
        [Parameter(Mandatory)]
        [string]$Hotkey
    )

    $canonical = ConvertTo-DevWSBindingHotkey -Hotkey $Hotkey

    return ($canonical -eq "alt+t" -or $canonical -eq "alt+shift+t")
}

function Get-DevWSReservedBindingHotkeyReason {
    param(
        [Parameter(Mandatory)]
        [string]$Hotkey
    )

    $canonical = ConvertTo-DevWSBindingHotkey -Hotkey $Hotkey

    if ($canonical -eq "alt+t") {
        return "Alt+T is permanently reserved for the AdminTerminal elevated terminal shortcut."
    }

    if ($canonical -eq "alt+shift+t") {
        return "Alt+Shift+T is permanently reserved for the bare 'ws launch' shortcut that follows defaultSet."
    }

    return ""
}

function ConvertTo-DevWSAhkKeyName {
    param(
        [Parameter(Mandatory)]
        [string]$Key
    )

    $map = @{
        "space"     = "Space"
        "tab"       = "Tab"
        "enter"     = "Enter"
        "esc"       = "Esc"
        "backspace" = "Backspace"
        "up"        = "Up"
        "down"      = "Down"
        "left"      = "Left"
        "right"     = "Right"
        "home"      = "Home"
        "end"       = "End"
        "pgup"      = "PgUp"
        "pgdn"      = "PgDn"
        "insert"    = "Insert"
        "delete"    = "Delete"
    }

    if ($map.ContainsKey($Key)) {
        return $map[$Key]
    }

    if ($Key -match '^f([1-9]|1[0-9]|2[0-4])$') {
        return $Key.ToUpperInvariant()
    }

    # Letters and digits are emitted directly.
    return $Key
}

function ConvertTo-DevWSAhkBindingHotkey {
    param(
        [Parameter(Mandatory)]
        [string]$Hotkey
    )

    $canonical = ConvertTo-DevWSBindingHotkey -Hotkey $Hotkey
    $parts     = $canonical.Split("+")

    $symbols = @{
        "ctrl"  = "^"
        "alt"   = "!"
        "shift" = "+"
        "win"   = "#"
    }

    $ahk = ""

    for ($i = 0; $i -lt $parts.Count - 1; $i++) {
        $ahk += $symbols[$parts[$i]]
    }

    $ahk += ConvertTo-DevWSAhkKeyName -Key $parts[$parts.Count - 1]

    return $ahk
}

function ConvertTo-DevWSAhkSingleQuotedString {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value
    )

    if ("$Value".Contains("`r") -or "$Value".Contains("`n")) {
        throw "Cannot quote a value containing line breaks for AutoHotkey."
    }

    # AutoHotkey v2 uses the backtick as the escape character in both string
    # delimiters; a single-quoted string only needs backticks and single
    # quotes escaped.
    $escaped = "$Value".Replace("``", "````").Replace("'", "``'")

    return "'$escaped'"
}

function New-DevWSBindingsAhkContent {
    param(
        [AllowEmptyCollection()]
        [object[]]$Bindings = @(),
        [Parameter(Mandatory)]
        [string]$AppScriptPath
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("; Generated by DevWS from workspace config. Do not edit.")
    $lines.Add("; Derived state; regenerate with: ws sync-hotkeys")

    foreach ($binding in @($Bindings)) {
        if ($null -eq $binding) {
            continue
        }

        $hotkey = ConvertTo-DevWSAhkBindingHotkey -Hotkey ([string]$binding.hotkey)
        $setId  = [string]$binding.setId

        $command = 'pwsh.exe -NoLogo -NoProfile -WindowStyle Hidden -File "' + $AppScriptPath + '" launch ' + $setId
        $lines.Add($hotkey + "::Run(" + (ConvertTo-DevWSAhkSingleQuotedString -Value $command) + ', , "Hide")')
    }

    return (($lines -join "`r`n") + "`r`n")
}

function Get-DevWSBindingsContentFromConfig {
    param(
        [Parameter(Mandatory)]
        $Config,
        [Parameter(Mandatory)]
        [string]$AppScriptPath
    )

    $bindings = @()

    if ($null -ne $Config) {
        $property = $Config.PSObject.Properties["bindings"]

        if ($null -ne $property -and $null -ne $property.Value) {
            $bindings = @($property.Value)
        }
    }

    return (New-DevWSBindingsAhkContent -Bindings $bindings -AppScriptPath $AppScriptPath)
}

function Test-DevWSBindingsInSync {
    param(
        [Parameter(Mandatory)]
        $Config,
        [Parameter(Mandatory)]
        [string]$AppScriptPath,
        [Parameter(Mandatory)]
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    $expected = Get-DevWSBindingsContentFromConfig -Config $Config -AppScriptPath $AppScriptPath

    return ((Get-Content -LiteralPath $Path -Raw) -eq $expected)
}

function Write-DevWSBindingsState {
    param(
        [Parameter(Mandatory)]
        $Config,
        [Parameter(Mandatory)]
        [string]$AppScriptPath,
        [Parameter(Mandatory)]
        [string]$Path
    )

    $expected = Get-DevWSBindingsContentFromConfig -Config $Config -AppScriptPath $AppScriptPath
    $current  = $null

    if (Test-Path -LiteralPath $Path -PathType Leaf) {
        $current = Get-Content -LiteralPath $Path -Raw
    }

    if ($current -eq $expected) {
        return [pscustomobject]@{
            Status = "current"
            Path   = $Path
        }
    }

    Write-DevWSTextFileAtomic -Path $Path -Content $expected

    return [pscustomobject]@{
        Status = "written"
        Path   = $Path
    }
}

function Sync-DevWSBindings {
    param(
        [Parameter(Mandatory)]
        $Config,
        [string]$InstallRoot = (Get-DevWSInstallRoot),
        [string]$StateRoot = (Get-DevWSStateRoot),
        [string]$StartupPath = (Get-DevWSStartupPath),
        [switch]$SkipReload
    )

    # The managed core script stays the single persistent AutoHotkey process;
    # sync only reconciles the derived include it points at.
    $appScriptPath = Join-Path $InstallRoot "app\ws.ps1"
    $bindingsPath  = Join-Path $StateRoot "hotkeys\bindings.ahk"
    $corePath      = Join-Path $StartupPath "TerminalShortcut.ahk"

    if (-not (Test-Path -LiteralPath $corePath -PathType Leaf)) {
        throw "The managed Startup hotkey script was not found at '$corePath'. Run install.ps1 to (re)install the DevWS hotkey integration; derived hotkeys were not changed."
    }

    $coreContent = Get-Content -LiteralPath $corePath -Raw

    if (-not (Test-DevWSManagedHotkeyContent -Content $coreContent -InstallRoot $InstallRoot)) {
        throw "The Startup hotkey script '$corePath' is not recognized as DevWS-managed. Run install.ps1 to (re)install the DevWS hotkey integration; the file was left untouched."
    }

    if (-not (Test-DevWSManagedHotkeyIncludeContract -Content $coreContent -BindingsPath $bindingsPath)) {
        throw "The DevWS Startup hotkey script does not include the generated bindings contract expected by this version (expected: $(Get-DevWSManagedHotkeyIncludeLine -BindingsPath $bindingsPath)). Run install.ps1 to update the hotkey integration; the file was left untouched."
    }

    $writeResult = Write-DevWSBindingsState -Config $Config -AppScriptPath $appScriptPath -Path $bindingsPath
    $reloaded    = $false

    if (-not $SkipReload) {
        $reloaded = [bool](Start-DevWSInstalledHotkey -HotkeyPath $corePath)
    }

    return [pscustomobject]@{
        Status   = $writeResult.Status
        Path     = $bindingsPath
        CorePath = $corePath
        Reloaded = $reloaded
    }
}
