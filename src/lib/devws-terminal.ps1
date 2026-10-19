# DevWS terminal dispatch helpers.
#
# Builds Windows Terminal argument lists from config terminal definitions so
# that workers never hard-code tab counts or terminal commands.
#
# Window identity is resolved through runtime HWND state and UI Automation, so
# creation does not need a title-stable tab. Every configured tab is built from
# config, and the configured activeTab is selected last.
#
# Pass 6B: when a per-tab tracking bundle is supplied, EVERY configured tab is
# created through the static cwd shell bootstrap with its own encoded child
# command payload, session id, and publication path. Without a bundle the
# historical untracked construction is preserved (raw builder compatibility
# only; every DevWS production creation path supplies the full bundle).
#
# Pass 6C: each configured tab receives its EFFECTIVE path (the tab's explicit
# override when present, otherwise terminal.path) and its canonical managed
# configured-tab title (<windowId> for tab 0, <windowId>#DevWS:<N> for N>0)
# plus --suppressApplicationTitle.

function ConvertTo-DevWSPowerShellSingleQuoted {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Value
    )

    return "'" + ($Value -replace "'", "''") + "'"
}

function ConvertTo-DevWSTerminalCommandLineToken {
    # Windows Terminal builds a tab command line by joining the argv payload
    # entries and applies its OWN argument quoting: a token containing spaces
    # must be passed RAW as one argv entry (the caller's ArgumentList already
    # protects the process boundary) and WT re-quotes it internally. Embedding
    # literal quotes in the token double-quotes the value and breaks the tab
    # command line (proven live with a disposable window during Security
    # Phase 1 deployment validation). This helper therefore returns the value
    # unchanged; it exists to document that contract at every call site.
    param(
        [AllowNull()]
        [AllowEmptyString()]
        [string]$Value
    )

    return $Value
}

function Get-DevWSPowerShellLaunchToken {
    # The shell executable token used in Windows Terminal tab command lines.
    # Repository execution keeps the historical bare "pwsh" (tests/POCs).
    # Installed layouts use the fully-qualified trusted PowerShell path so
    # privileged launch semantics never depend on the current-user PATH.
    if ((Get-DevWSPathsLayout) -eq "repository") {
        return "pwsh"
    }

    return (ConvertTo-DevWSTerminalCommandLineToken -Value (Resolve-DevWSTrustedPowerShellPath))
}

function Get-DevWSTerminalTabSummary {
    param(
        [Parameter(Mandatory)]
        $Terminal
    )

    $parts = @()

    foreach ($tab in @($Terminal.tabs)) {
        if ($null -eq $tab.command -or [string]::IsNullOrWhiteSpace([string]$tab.command)) {
            $parts += "idle"
        }
        else {
            $label = [string]$tab.command

            if (@($tab.args).Count -gt 0) {
                $label += " " + (@($tab.args) -join " ")
            }

            $parts += $label
        }
    }

    return ($parts -join " + ")
}

function New-DevWSTerminalCreateArguments {
    param(
        [Parameter(Mandatory)]
        $Terminal,
        [AllowNull()]
        [object[]]$TrackingContexts = $null
    )

    $windowId  = [string]$Terminal.windowId
    $activeTab = [int]$Terminal.activeTab

    $tabs = @($Terminal.tabs)

    $contextByTab = $null
    $contexts = @()

    if ($null -ne $TrackingContexts) { $contexts = @($TrackingContexts) }

    if ($contexts.Count -gt 0) {
        if ($contexts.Count -ne $tabs.Count) {
            throw "Terminal '$($Terminal.id)' has $($tabs.Count) configured tab(s) but $($contexts.Count) tracking context(s); every configured tab requires exactly one."
        }

        $contextByTab = @{}

        foreach ($context in $contexts) {
            foreach ($field in @("BootstrapPath", "SetId", "TerminalId", "WindowId", "SessionId", "PublicationPath", "ChildSpecBase64")) {
                $value = $context.$field

                if ($null -eq $value -or [string]::IsNullOrWhiteSpace([string]$value)) {
                    throw "Cwd tracking context is missing '$field'."
                }
            }

            if ([string]$context.WindowId -cne $windowId) {
                throw "Cwd tracking context windowId '$($context.WindowId)' does not match terminal windowId '$windowId'."
            }

            if ([string]$context.TerminalId -ine [string]$Terminal.id) {
                throw "Cwd tracking context terminalId '$($context.TerminalId)' does not match terminal id '$($Terminal.id)'."
            }

            $tabIndexProperty = $context.PSObject.Properties["TabIndex"]

            if ($null -eq $tabIndexProperty -or $null -eq $tabIndexProperty.Value) {
                throw "Cwd tracking context is missing 'TabIndex'."
            }

            $contextTabIndex = [int]$tabIndexProperty.Value

            if ($contextTabIndex -lt 0 -or $contextTabIndex -ge $tabs.Count) {
                throw "Cwd tracking context tabIndex '$contextTabIndex' does not address terminal '$($Terminal.id)' ($($tabs.Count) tab(s))."
            }

            if ($contextByTab.ContainsKey($contextTabIndex)) {
                throw "Terminal '$($Terminal.id)' has duplicate tracking contexts for tab $contextTabIndex."
            }

            $contextByTab[$contextTabIndex] = $context
        }
    }

    $arguments = [System.Collections.Generic.List[string]]::new()

    # Trusted shell token: bare "pwsh" in the repository; the fully-qualified
    # protected PowerShell path in installed layouts (Public Security Phase 1).
    $shellToken = Get-DevWSPowerShellLaunchToken

    $arguments.Add("-w")
    $arguments.Add($windowId)

    for ($tabIndex = 0; $tabIndex -lt $tabs.Count; $tabIndex++) {
        $tab = $tabs[$tabIndex]
        $effectivePath = Get-DevWSTerminalTabEffectivePath -Terminal $Terminal -TabIndex $tabIndex
        $tabTitle      = Get-DevWSTerminalTabTitle -WindowId $windowId -TabIndex $tabIndex

        $arguments.Add("new-tab")
        $arguments.Add("-p")
        $arguments.Add("PowerShell")
        $arguments.Add("-d")
        $arguments.Add($effectivePath)
        $arguments.Add("--title")
        $arguments.Add($tabTitle)
        $arguments.Add("--suppressApplicationTitle")

        if ($null -ne $contextByTab) {
            # Pass 6B tracked tab: static bootstrap + encoded child payload for
            # EVERY configured tab, including idle tabs. The user profile must
            # run normally, so -NoProfile is never used for a tracked tab.
            $context = $contextByTab[$tabIndex]

            if ($null -eq $context) {
                throw "Terminal '$($Terminal.id)' is missing the tracking context for tab $tabIndex."
            }

            $arguments.Add($shellToken)
            $arguments.Add("-NoExit")
            $arguments.Add("-File")
            $arguments.Add((ConvertTo-DevWSTerminalCommandLineToken -Value ([string]$context.BootstrapPath)))
            $arguments.Add("-SetId")
            $arguments.Add([string]$context.SetId)
            $arguments.Add("-TerminalId")
            $arguments.Add([string]$context.TerminalId)
            $arguments.Add("-WindowId")
            $arguments.Add([string]$context.WindowId)
            $arguments.Add("-TabIndex")
            $arguments.Add($tabIndex.ToString())
            $arguments.Add("-SessionId")
            $arguments.Add([string]$context.SessionId)
            $arguments.Add("-PublicationPath")
            $arguments.Add((ConvertTo-DevWSTerminalCommandLineToken -Value ([string]$context.PublicationPath)))
            $arguments.Add("-ChildSpecBase64")
            $arguments.Add([string]$context.ChildSpecBase64)
        }
        elseif ($null -ne $tab.command -and -not [string]::IsNullOrWhiteSpace([string]$tab.command)) {
            $commandLine = "& " + (ConvertTo-DevWSPowerShellSingleQuoted ([string]$tab.command))

            foreach ($argument in @($tab.args)) {
                $commandLine += " " + (ConvertTo-DevWSPowerShellSingleQuoted ([string]$argument))
            }

            $arguments.Add($shellToken)
            $arguments.Add("-NoExit")
            $arguments.Add("-Command")
            $arguments.Add($commandLine)
        }
        else {
            $arguments.Add($shellToken)
        }

        $arguments.Add(";")
    }

    # The separator before focus-tab is REQUIRED: Windows Terminal parses the
    # payload of the final `new-tab` until the next `;`, so without it
    # `focus-tab -t <activeTab>` is passed to that tab's pwsh (observed live as
    # "The argument 'focus-tab' is not recognized..." and exit code 64).
    $arguments.Add("focus-tab")
    $arguments.Add("-t")
    $arguments.Add([string]$activeTab)

    return $arguments.ToArray()
}

function Assert-DevWSElevatedTerminals {
    # Managed terminals are always elevated; the config flag is validated
    # before any live side effect. Shared by the canonical launch transaction.
    param($Terminals)

    foreach ($terminal in @($Terminals)) {
        if (-not [bool]$terminal.elevated) {
            throw "Terminal '$($terminal.id)' has elevated=false. Managed terminals require elevated=true; update this terminal in the workspace config and retry."
        }
    }
}
