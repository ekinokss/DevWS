# DevWS CLI help metadata and rendering.
#
# Dependency-free presentation leaf loaded by src/ws.ps1 (library-load
# section). No config, runtime-state, window or task dependencies; the
# only side effect is help/error output through Write-Host.
#
# Extracted verbatim from ws.ps1 in Engineering Pass 3B.

function Show-DevWSHelp {
    # Progressive help entry point:
    #   ws / ws help        -> concise quick reference
    #   ws help all         -> complete grouped command surface
    #   ws help <topic>     -> related commands for a topic
    #   ws help <command>   -> contextual command help
    param(
        [string]$Target
    )

    $targetText = ([string]$Target).Trim()

    if ([string]::IsNullOrWhiteSpace($targetText)) {
        Show-DevWSHelpQuick
        return
    }

    if ($targetText -ieq "all") {
        Show-DevWSHelpAll
        return
    }

    $topic = Get-DevWSHelpTopicByName -Name $targetText

    if ($null -ne $topic) {
        Show-DevWSHelpTopic -Topic $topic
        return
    }

    $command = @(Get-DevWSHelpCommandInfo | Where-Object { $_.Name -ieq $targetText })

    if ($command.Count -eq 0) {
        $command = @(Get-DevWSHelpCommandInfo | Where-Object {
            @($_.Aliases | Where-Object { $_.Name -ieq $targetText }).Count -gt 0
        })
    }

    if ($command.Count -gt 0) {
        Show-DevWSHelpCommand -Command $command[0]
        return
    }

    if ($targetText -in @("-h", "--help", "/?")) {
        Show-DevWSHelpCommand -Command (@(Get-DevWSHelpCommandInfo | Where-Object { $_.Name -eq "help" })[0])
        return
    }

    $message = @(
        "Unknown help topic or command '$targetText'.",
        "",
        'Run `ws help` for the quick reference.',
        'Run `ws help all` for all commands.'
    ) -join [Environment]::NewLine

    throw $message
}

function Get-DevWSHelpCommandInfo {
    # Single help-only source of truth. Command dispatch stays explicit in the
    # dispatch switch; this metadata only describes the existing command
    # surface. Aliases live on their canonical entry and are deliberately kept
    # out of the concise quick reference.
    return @(
        [pscustomobject]@{
            Name     = "launch"
            Usage    = "ws launch [set]"
            Summary  = "Ensure all enabled items exist and restore their saved layout."
            Section  = "Workspace"
            Aliases  = @()
            Details  = @(
                "Existing terminal sessions are preserved; only missing items are created.",
                "Placement uses the effective layout: the exact topology layout profile when the current monitors match one, otherwise each item's fallback layout.",
                "A profile-aware set refuses the launch before any side effect when the topology is unsafe or a matched profile rectangle is unreachable; an unreachable fallback rectangle is reported and that item is left unmoved.",
                "No monitor watcher and no automatic retile: the next explicit launch observes a new topology.",
                "Omitting [set] uses defaultSet."
            )
            Examples = @("ws launch", "ws launch main", "ws launch secondary")
            Warning  = $null
        }

        [pscustomobject]@{
            Name     = "focus"
            Usage    = "ws focus [set]"
            Summary  = "Bring existing items forward without creating or repositioning anything."
            Section  = "Workspace"
            Aliases  = @()
            Details  = @(
                "Does not launch missing items and does not move or resize windows."
            )
            Examples = @("ws focus", "ws focus secondary")
            Warning  = $null
        }

        [pscustomobject]@{
            Name     = "list"
            Usage    = "ws list [set]"
            Summary  = "List configured items in order, including enabled/disabled state."
            Section  = "Workspace"
            Aliases  = @(
                [pscustomobject]@{
                    Name    = "show"
                    Usage   = "ws show [set]"
                    Summary = "Compatibility alias for ws list."
                }
            )
            Details  = @(
                "Disabled items are shown but ignored by launch, focus, and layout capture."
            )
            Examples = @("ws list", "ws show secondary")
            Warning  = $null
        }

        [pscustomobject]@{
            Name     = "status"
            Usage    = "ws status [set]"
            Summary  = "Show the current configured and live state of a workspace set."
            Section  = "Workspace"
            Aliases  = @()
            Details  = @(
                "Reports terminals and apps with live presence, ambiguity and ownership observations, plus tracked cwd where available.",
                "Reports broker/coordinator liveness and deployed-generation currency; a stale host is reported, never restarted.",
                "Strictly observational: never launches, focuses, repairs, or writes anything."
            )
            Examples = @("ws status", "ws status secondary")
            Warning  = $null
        }

        [pscustomobject]@{
            Name     = "save-layout"
            Usage    = "ws save-layout [set] [--profile <id>]"
            Summary  = "Capture and persist geometry for all enabled items (all-or-nothing)."
            Section  = "Workspace"
            Aliases  = @()
            Details  = @(
                "Geometry only; terminal cwd and the activeTab are not saved.",
                "With no profiles the captured geometry updates the fallback item.layout.",
                "With profiles the storage scope follows the current topology: the exactly matching profile, otherwise the fallback.",
                "--profile <id> creates or updates that profile; creation requires a complete capture and a stable, safely matchable topology.",
                "Fails without changing config if any enabled item cannot be captured or if the topology changes during capture."
            )
            Examples = @("ws save-layout", "ws save-layout secondary", "ws save-layout --profile docked")
            Warning  = $null
        }

        [pscustomobject]@{
            Name     = "save"
            Usage    = "ws save [set] [--profile <id>]"
            Summary  = "Save geometry plus reliable tracked per-tab cwd and the configured activeTab."
            Section  = "Workspace"
            Aliases  = @()
            Details  = @(
                "Geometry is required and follows the same profile storage routing as ws save-layout.",
                "Every configured terminal tab resolves its own tracked cwd independently; reliable cwd is opportunistic and always global (terminal.path for tab 0, per-tab overrides only when required), never per profile.",
                "Unavailable cwd keeps the existing effective path for that tab.",
                "The configured activeTab is saved only from a reliable managed-tab observation; anything else keeps the existing value.",
                "Topology stability and per-tab generation both revalidate before one atomic canonical write."
            )
            Examples = @("ws save", "ws save secondary", "ws save --profile docked")
            Warning  = $null
        }

        [pscustomobject]@{
            Name     = "show-layout"
            Usage    = "ws show-layout [set]"
            Summary  = "Show the effective saved geometry for configured items (read-only)."
            Section  = "Workspace"
            Aliases  = @()
            Details  = @(
                "Shows the current topology fingerprint, the layout source (profile or fallback), and effective rectangles.",
                "A sparse matched profile marks items that still fall back; unreachable rectangles are marked too.",
                "Launch and terminal resets apply exactly these effective rectangles; there is no live monitor watcher or automatic retile."
            )
            Examples = @("ws show-layout", "ws show-layout secondary")
            Warning  = $null
        }

        [pscustomobject]@{
            Name     = "enable"
            Usage    = "ws enable <id>"
            Summary  = "Enable a configured item (config only)."
            Section  = "Item configuration"
            Aliases  = @()
            Details  = @(
                "Never launches, closes, moves, or focuses a window."
            )
            Examples = @("ws enable notes")
            Warning  = $null
        }

        [pscustomobject]@{
            Name     = "disable"
            Usage    = "ws disable <id>"
            Summary  = "Disable a configured item (config only)."
            Section  = "Item configuration"
            Aliases  = @()
            Details  = @(
                "Never closes windows; disabled items are ignored by launch, focus, and layout capture."
            )
            Examples = @("ws disable notes")
            Warning  = $null
        }

        [pscustomobject]@{
            Name     = "remove"
            Usage    = "ws remove <id> [-Force]"
            Summary  = "Remove a configured item from config."
            Section  = "Item configuration"
            Aliases  = @()
            Details  = @(
                "Config only: never closes a window and deletes no files.",
                "Prompts for confirmation unless -Force is supplied."
            )
            Examples = @("ws remove notes", "ws remove notes -Force")
            Warning  = $null
        }

        [pscustomobject]@{
            Name     = "add-terminal"
            Usage    = "ws add-terminal <id> <path> [command] [args...]"
            Summary  = "Add a terminal definition (config only)."
            Section  = "Item configuration"
            Aliases  = @()
            Details  = @(
                "Copies the last terminal layout and does not launch; position the window and run ws save-layout."
            )
            Examples = @("ws add-terminal notes .", "ws add-terminal notes C:\Projects\App npm run dev")
            Warning  = $null
        }

        [pscustomobject]@{
            Name     = "set-path"
            Usage    = "ws set-path <id-or-ref> <path>"
            Summary  = "Change a terminal path or one configured tab's path override (config only)."
            Section  = "Item configuration"
            Aliases  = @(
                [pscustomobject]@{
                    Name    = "set"
                    Usage   = "ws set <id|number> <path>"
                    Summary = "Compatibility alias for ws set-path; also accepts a 1-based terminal number."
                }
            )
            Details  = @(
                "ws set-path <id-or-ref> --tab <n> <path> sets that configured tab's explicit path override.",
                "ws set-path <id-or-ref> --tab <n> --clear removes that tab's override; the tab inherits the terminal path again.",
                "A tab-0 override mirrors into the terminal path for older builds; clearing tab 0 leaves the terminal path unchanged.",
                "Changing the terminal path preserves existing per-tab overrides.",
                "References may be set-qualified, for example secondary/notes.",
                "The ws set compatibility alias also accepts a 1-based terminal number."
            )
            Examples = @("ws set-path notes .", "ws set-path notes --tab 1 C:\Projects\B", "ws set 2 C:\Projects\App")
            Warning  = $null
        }

        [pscustomobject]@{
            Name     = "set-command"
            Usage    = "ws set-command <id-or-ref> <command> [args...]"
            Summary  = "Replace the first command tab of a terminal (config only)."
            Section  = "Item configuration"
            Aliases  = @()
            Details  = @(
                "Running terminals keep their current command until reset.",
                "Literal tool arguments such as -w 5 pass through unchanged."
            )
            Examples = @("ws set-command notes npm run dev", "ws set-command notes somecmd -w 5")
            Warning  = $null
        }

        [pscustomobject]@{
            Name     = "add-app"
            Usage    = "ws add-app <id> <launch-kind> <launch-value> <match-kind> <match-value> <instance-mode>"
            Summary  = "Add an app with an explicit dedicated/shared mode (config only)."
            Section  = "Item configuration"
            Aliases  = @()
            Details  = @(
                "Launch kinds: exe, appId. Match kinds: exe, processPathContains.",
                "The instance-mode argument is required; same-id apps across sets share one mode.",
                "Copies the last app layout; the app is not launched."
            )
            Examples = @('ws add-app notes exe "C:\Program Files\Notes\Notes.exe" exe Notes.exe dedicated')
            Warning  = $null
        }

        [pscustomobject]@{
            Name     = "set-instance-mode"
            Usage    = "ws set-instance-mode <app-id> <dedicated|shared>"
            Summary  = "Set the instance mode for every same-id app across sets (config only)."
            Section  = "Item configuration"
            Aliases  = @()
            Details  = @(
                "Running app windows and their ownership tags are not touched."
            )
            Examples = @("ws set-instance-mode notes shared")
            Warning  = $null
        }

        [pscustomobject]@{
            Name     = "set-launch"
            Usage    = "ws set-launch <app-id> <kind> <value>"
            Summary  = "Replace an app launch definition (config only)."
            Section  = "Item configuration"
            Aliases  = @()
            Details  = @(
                "The running app is not relaunched; the new definition applies on the next launch."
            )
            Examples = @('ws set-launch notes exe "C:\Program Files\Notes\Notes.exe"')
            Warning  = $null
        }

        [pscustomobject]@{
            Name     = "set-match"
            Usage    = "ws set-match <app-id> <kind> <value>"
            Summary  = "Replace an app match definition (config only)."
            Section  = "Item configuration"
            Aliases  = @()
            Details  = @(
                "No live window lookup and no ownership change."
            )
            Examples = @()
            Warning  = $null
        }

        [pscustomobject]@{
            Name     = "set-app-args"
            Usage    = "ws set-app-args <app-id> [args...]"
            Summary  = "Replace executable launch arguments (config only)."
            Section  = "Item configuration"
            Aliases  = @()
            Details  = @(
                "Only for exe launches; appId launches do not support arguments.",
                "--clear removes all arguments."
            )
            Examples = @("ws set-app-args notes --profile work", "ws set-app-args notes --clear")
            Warning  = $null
        }

        [pscustomobject]@{
            Name     = "rename"
            Usage    = "ws rename <old-id> <new-id>"
            Summary  = "Rename a configured item (config only)."
            Section  = "Item configuration"
            Aliases  = @()
            Details  = @(
                "Only the config id changes; a terminal windowId and live windows are preserved."
            )
            Examples = @()
            Warning  = $null
        }

        [pscustomobject]@{
            Name     = "clone-terminal"
            Usage    = "ws clone-terminal <source-id> <new-id>"
            Summary  = "Clone a terminal definition (config only)."
            Section  = "Item configuration"
            Aliases  = @()
            Details  = @(
                "The clone is not launched and gets a fresh set-qualified windowId."
            )
            Examples = @()
            Warning  = $null
        }

        [pscustomobject]@{
            Name     = "clone-app"
            Usage    = "ws clone-app <source-id> <new-id>"
            Summary  = "Clone an app definition as a disabled template (config only)."
            Section  = "Item configuration"
            Aliases  = @()
            Details  = @(
                "The clone starts disabled because it shares the source match rule."
            )
            Examples = @()
            Warning  = $null
        }

        [pscustomobject]@{
            Name     = "set-geometry"
            Usage    = "ws set-geometry <id> --x <x> --y <y> --width <width> --height <height> [--layout <profileId|fallback>]"
            Summary  = "Set a saved layout rectangle in the fallback or an explicit profile (config only)."
            Section  = "Layout"
            Aliases  = @()
            Details  = @(
                "Saved geometry only; the live window is not moved.",
                "--layout fallback edits item.layout; --layout <profileId> edits that profile's sparse entry (no topology read).",
                "Without --layout the scope follows the current topology when the set has profiles: matched profile, otherwise fallback; an unmatchable topology refuses the write."
            )
            Examples = @("ws set-geometry notes --x -7 --y 0 --width 654 --height 1407", "ws set-geometry notes --x 0 --y 0 --width 800 --height 600 --layout docked")
            Warning  = $null
        }

        [pscustomobject]@{
            Name     = "reset-layout"
            Usage    = "ws reset-layout [set] [-Force]"
            Summary  = "Restore saved layouts from the bundled default config (config only)."
            Section  = "Layout"
            Aliases  = @()
            Details  = @(
                "Matches by id/type; terminals may match by preserved windowId fallback; unmatched items are skipped.",
                "Restores fallback item.layout only; topology layout profiles are never created, modified or deleted.",
                "Prompts for confirmation unless -Force is supplied."
            )
            Examples = @("ws reset-layout", "ws reset-layout secondary")
            Warning  = $null
        }

        [pscustomobject]@{
            Name     = "layout-profile"
            Usage    = "ws layout-profile <list|remove|match> ..."
            Summary  = "Manage optional per-set topology layout profiles (config only)."
            Section  = "Layout"
            Aliases  = @()
            Details  = @(
                "Subcommands: list [set] (read-only), remove <profile|set/profile> [-Force], match <profile|set/profile>.",
                "Profiles store absolute geometry for one exact monitor topology; item.layout remains the universal fallback and profiles may be sparse.",
                "Create/update profiles through 'ws save-layout --profile <id>' so they start from real captured geometry; 'match' re-keys an existing profile to the current topology.",
                "Config only: never moves windows. The matching profile is applied automatically by 'ws launch' and terminal resets."
            )
            Examples = @("ws layout-profile list", "ws layout-profile remove laptop -Force", "ws layout-profile match docked")
            Warning  = $null
        }

        [pscustomobject]@{
            Name     = "sets"
            Usage    = "ws sets"
            Summary  = "List configured sets, item counts, and launch hotkeys."
            Section  = "Workspace sets"
            Aliases  = @()
            Details  = @()
            Examples = @()
            Warning  = $null
        }

        [pscustomobject]@{
            Name     = "add-set"
            Usage    = "ws add-set <id>"
            Summary  = "Add an empty workspace set (config only)."
            Section  = "Workspace sets"
            Aliases  = @()
            Details  = @(
                "Does not launch anything and does not create a shortcut."
            )
            Examples = @()
            Warning  = $null
        }

        [pscustomobject]@{
            Name     = "clone-set"
            Usage    = "ws clone-set <source-set> <new-set>"
            Summary  = "Deep-copy a workspace set (config only)."
            Section  = "Workspace sets"
            Aliases  = @()
            Details  = @(
                "Cloned terminals get new set-qualified windowIds."
            )
            Examples = @()
            Warning  = $null
        }

        [pscustomobject]@{
            Name     = "rename-set"
            Usage    = "ws rename-set <old-set> <new-set>"
            Summary  = "Rename a workspace set, preserving its identity (config only)."
            Section  = "Workspace sets"
            Aliases  = @()
            Details  = @(
                "Item ids, terminal windowIds, commands, tabs, geometry and layout profiles are preserved exactly.",
                "defaultSet and every launch binding targeting the set are retargeted automatically; binding hotkeys never change.",
                "Refuses while a dedicated app of the set still owns a live window; never closes, moves or retags windows.",
                "A case-only rename keeps the existing tracking and ownership identities unchanged."
            )
            Examples = @()
            Warning  = $null
        }

        [pscustomobject]@{
            Name     = "remove-set"
            Usage    = "ws remove-set <id> [-Force]"
            Summary  = "Remove a non-default set from config (config only)."
            Section  = "Workspace sets"
            Aliases  = @()
            Details  = @(
                "Refuses the default set and the last remaining set.",
                "Never closes windows; prompts for confirmation unless -Force is supplied."
            )
            Examples = @()
            Warning  = $null
        }

        [pscustomobject]@{
            Name     = "set-default"
            Usage    = "ws set-default <id>"
            Summary  = "Change which set bare commands target (config only)."
            Section  = "Workspace sets"
            Aliases  = @()
            Details  = @(
                "No window is moved or closed; there is no hidden active-set state."
            )
            Examples = @()
            Warning  = $null
        }

        [pscustomobject]@{
            Name     = "bind"
            Usage    = "ws bind <set> <hotkey>"
            Summary  = "Bind an additional set launch hotkey (config + generated hotkeys)."
            Section  = "Hotkeys"
            Aliases  = @()
            Details  = @(
                "Canonical config is saved first; the generated hotkey file is then regenerated and reloaded.",
                "Alt+T and Alt+Shift+T stay reserved."
            )
            Examples = @("ws bind secondary alt+shift+y")
            Warning  = $null
        }

        [pscustomobject]@{
            Name     = "unbind"
            Usage    = "ws unbind <hotkey>"
            Summary  = "Remove a set launch hotkey binding (config + generated hotkeys)."
            Section  = "Hotkeys"
            Aliases  = @()
            Details  = @()
            Examples = @("ws unbind alt+shift+y")
            Warning  = $null
        }

        [pscustomobject]@{
            Name     = "bindings"
            Usage    = "ws bindings"
            Summary  = "List configured additional set launch hotkeys (read-only)."
            Section  = "Hotkeys"
            Aliases  = @()
            Details  = @()
            Examples = @()
            Warning  = $null
        }

        [pscustomobject]@{
            Name     = "sync-hotkeys"
            Usage    = "ws sync-hotkeys"
            Summary  = "Regenerate generated hotkeys from config and reload them."
            Section  = "Hotkeys"
            Aliases  = @()
            Details  = @(
                "Never modifies config; also recovers a stopped AHK hotkey process."
            )
            Examples = @()
            Warning  = $null
        }

        [pscustomobject]@{
            Name     = "edit"
            Usage    = "ws edit"
            Summary  = "Edit the workspace config safely (temporary copy + validation)."
            Section  = "Tools / diagnostics"
            Aliases  = @()
            Details  = @(
                "Canonical config changes only after validation; derived hotkeys are not synced.",
                "Editor order: DEVWS_EDITOR, then VS Code (--wait), then Notepad."
            )
            Examples = @("ws edit")
            Warning  = $null
        }

        [pscustomobject]@{
            Name     = "doctor"
            Usage    = "ws doctor"
            Summary  = "Run the non-destructive installation health check."
            Section  = "Tools / diagnostics"
            Aliases  = @(
                [pscustomobject]@{
                    Name    = "health"
                    Usage   = "ws health"
                    Summary = "Compatibility alias for ws doctor (same checks and exit code)."
                }
            )
            Details  = @(
                "Read-only; the exit code reports pass/fail."
            )
            Examples = @("ws doctor", "ws health")
            Warning  = $null
        }

        [pscustomobject]@{
            Name     = "detect-app"
            Usage    = "ws detect-app [filter]"
            Summary  = "Inspect visible applications and app-definition suggestions (read-only)."
            Section  = "Tools / diagnostics"
            Aliases  = @()
            Details  = @(
                "Shows exact-HWND identity, dedicated ownership, and scoped configured matches with explicit modes.",
                "Never tags, adopts, launches, or moves anything."
            )
            Examples = @("ws detect-app", "ws detect-app notes")
            Warning  = $null
        }

        [pscustomobject]@{
            Name     = "monitors"
            Usage    = "ws monitors"
            Summary  = "Show the current monitor topology and stable monitor identities (read-only)."
            Section  = "Tools / diagnostics"
            Aliases  = @()
            Details  = @(
                "Shows the exact topology fingerprint that future layout-profile matching will use.",
                "Monitor ordinals (DISPLAY1/DISPLAYn) are diagnostic only and never durable identity.",
                "Read-only: no display settings change, no windows move, no config is read or written."
            )
            Examples = @("ws monitors")
            Warning  = $null
        }

        [pscustomobject]@{
            Name     = "reset"
            Usage    = "ws reset <id|number|set/id>"
            Summary  = "Destructively recreate one managed terminal."
            Section  = "Terminal reset"
            Aliases  = @(
                [pscustomobject]@{
                    Name    = "reset-terminal"
                    Usage   = "ws reset-terminal <id|number|set/id>"
                    Summary = "Compatibility alias for ws reset."
                }
            )
            Details  = @(
                "Closes the managed terminal and recreates it from current config.",
                "Placement uses the same effective layout as ws launch: the matching topology profile when present, otherwise the fallback layout.",
                "A profile-aware set refuses the reset before any side effect when the topology is unsafe or a matched profile rectangle is unreachable; an unreachable fallback rectangle recreates the terminal without moving it.",
                "Numeric references target the default set."
            )
            Examples = @("ws reset notes", "ws reset 2", "ws reset secondary/notes")
            Warning  = "Destructive: the managed terminal is closed and recreated."
        }

        [pscustomobject]@{
            Name     = "reset-terminals"
            Usage    = "ws reset-terminals [set] [-Force]"
            Summary  = "Destructively recreate all enabled terminals of the target set."
            Section  = "Terminal reset"
            Aliases  = @()
            Details  = @(
                "Disabled terminals and other sets are never reset.",
                "Placement follows the same effective layout as ws launch, resolved once for all selected terminals.",
                "Prompts for confirmation unless -Force is supplied."
            )
            Examples = @("ws reset-terminals", "ws reset-terminals secondary -Force")
            Warning  = "Destructive: every enabled terminal in the target set is closed and recreated."
        }

        [pscustomobject]@{
            Name     = "help"
            Usage    = "ws help [<command>|<topic>|all]"
            Summary  = "Show the quick reference, command help, topic help, or all commands."
            Section  = "Help"
            Aliases  = @()
            Details  = @(
                "Topics: items, sets, layout, hotkeys, tools.",
                "-h, --help, and /? are accepted as help aliases."
            )
            Examples = @("ws help", "ws help launch", "ws help hotkeys", "ws help all")
            Warning  = $null
        }
    )
}

function Get-DevWSHelpTopicInfo {
    # Progressive-help topics. Direct = $true marks the topics that are also
    # executable top-level navigation shortcuts (`ws items` etc.); this is the
    # single source of truth for the dispatcher, quick-help rows, suggestion
    # candidates, help-all discovery and the drift invariant test. `sets` is
    # deliberately NOT direct: `ws sets` stays the operational set listing and
    # `ws help sets` remains the set-management topic.
    return @(
        [pscustomobject]@{
            Name            = "items"
            Title           = "Item configuration"
            Direct          = $true
            ShortcutSummary = "Item configuration"
            Commands        = @(
                "enable", "disable", "remove", "add-terminal", "set-path", "set-command",
                "add-app", "set-instance-mode", "set-launch", "set-match", "set-app-args",
                "rename", "clone-terminal", "clone-app"
            )
        }

        [pscustomobject]@{
            Name            = "sets"
            Title           = "Workspace sets"
            Direct          = $false
            ShortcutSummary = $null
            Commands        = @("sets", "add-set", "clone-set", "rename-set", "remove-set", "set-default")
        }

        [pscustomobject]@{
            Name            = "layout"
            Title           = "Layout"
            Direct          = $true
            ShortcutSummary = "Layout and topology profiles"
            Commands        = @("save-layout", "save", "show-layout", "set-geometry", "reset-layout", "layout-profile")
        }

        [pscustomobject]@{
            Name            = "hotkeys"
            Title           = "Hotkeys"
            Direct          = $true
            ShortcutSummary = "Hotkey bindings"
            Commands        = @("bind", "unbind", "bindings", "sync-hotkeys")
        }

        [pscustomobject]@{
            Name            = "tools"
            Title           = "Tools and terminal reset"
            Direct          = $true
            ShortcutSummary = "Diagnostics and terminal reset"
            Commands        = @("edit", "doctor", "detect-app", "monitors", "reset", "reset-terminals")
        }
    )
}

function Get-DevWSHelpTopicByName {
    # ONE case-insensitive topic resolution shared by `ws help <topic>` and the
    # direct command-group shortcuts; $null when no topic has that name.
    param([AllowEmptyString()][string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return $null
    }

    foreach ($topic in @(Get-DevWSHelpTopicInfo)) {
        if (([string]$topic.Name) -ieq $Name) {
            return $topic
        }
    }

    return $null
}

function Get-DevWSHelpDirectTopicInfo {
    # Direct (executable) command-group shortcuts in topic order: the single
    # source of truth shared by quick help, the dispatcher, suggestions,
    # help-all discovery and the drift invariant test.
    return @(Get-DevWSHelpTopicInfo | Where-Object { [bool]$_.Direct })
}

function Test-DevWSHelpDirectTopic {
    # True when a token names a direct command-group shortcut. The ws.ps1
    # dispatcher routes on this helper instead of a second hardcoded list.
    param([AllowEmptyString()][string]$Name)

    $topic = Get-DevWSHelpTopicByName -Name $Name

    if ($null -eq $topic) {
        return $false
    }

    return [bool]$topic.Direct
}

function Get-DevWSHelpColumnWidth {
    param(
        [AllowEmptyCollection()]
        [string[]]$Values = @(),
        [int]$Minimum = 18,
        [int]$Maximum = 54
    )

    $width = $Minimum

    foreach ($value in @($Values)) {
        $needed = ([string]$value).Length + 2

        if ($needed -gt $width) {
            $width = $needed
        }
    }

    if ($width -gt $Maximum) {
        $width = $Maximum
    }

    return $width
}

function Write-DevWSHelpEntry {
    param(
        [Parameter(Mandatory)]
        [string]$Left,
        [string]$Right,
        [int]$Width = 21
    )

    if ($Left.Length + 2 -gt $Width) {
        Write-Host ("  " + $Left) -ForegroundColor Green
        Write-Host ("      " + ([string]$Right))
        return
    }

    $padding = $Width - $Left.Length

    Write-Host ("  " + $Left + (" " * $padding)) -NoNewline -ForegroundColor Green
    Write-Host ([string]$Right)
}

function Show-DevWSHelpQuick {
    # Concise quick reference. Every entry row is a real command, a direct
    # command-group shortcut (metadata-driven) or an explicit help invocation;
    # the drift invariant test rejects any advertised token the top-level
    # dispatcher cannot execute.
    Write-Host ""
    Write-Host "WS" -ForegroundColor Cyan -NoNewline
    Write-Host "  DevWS workspace manager"
    Write-Host ""
    Write-Host "Usage:" -ForegroundColor Yellow
    Write-Host "  ws <command> [args]"
    Write-Host "  ws <group>"
    Write-Host "  ws help <command|group|all>"
    Write-Host ""
    Write-Host "Common" -ForegroundColor Yellow
    Write-DevWSHelpEntry "launch [set]" "Restore a workspace"
    Write-DevWSHelpEntry "focus [set]" "Focus existing windows"
    Write-DevWSHelpEntry "status [set]" "Show live state"
    Write-DevWSHelpEntry "save [set]" "Save layout and cwd"
    Write-DevWSHelpEntry "list [set]" "Show configured items"
    Write-Host ""
    Write-Host "Command groups" -ForegroundColor Yellow

    foreach ($topic in @(Get-DevWSHelpDirectTopicInfo)) {
        Write-DevWSHelpEntry ([string]$topic.Name) ([string]$topic.ShortcutSummary)
    }

    Write-Host ""
    Write-Host "Workspace sets" -ForegroundColor Yellow
    Write-DevWSHelpEntry "sets" "List workspace sets"
    Write-DevWSHelpEntry "help sets" "Browse set-management commands"
    Write-Host ""
    Write-Host "Utilities" -ForegroundColor Yellow
    Write-DevWSHelpEntry "edit" "Edit the config"
    Write-DevWSHelpEntry "doctor" "Check the installation"
    Write-Host ""
    Write-Host "Help" -ForegroundColor Yellow
    Write-DevWSHelpEntry "help <command>" "Detailed command help"
    Write-DevWSHelpEntry "help <group>" "Browse a command group"
    Write-DevWSHelpEntry "help all" "Show every command"
    Write-Host ""
}

function Show-DevWSHelpAll {
    $commands = Get-DevWSHelpCommandInfo

    Write-Host ""
    Write-Host "WS" -ForegroundColor Cyan -NoNewline
    Write-Host "  DevWS workspace manager"
    Write-Host ""
    Write-Host "All commands" -ForegroundColor Yellow

    foreach ($section in @(
        "Workspace",
        "Item configuration",
        "Layout",
        "Workspace sets",
        "Hotkeys",
        "Tools / diagnostics",
        "Terminal reset"
    )) {
        $entries = @($commands | Where-Object { $_.Section -eq $section })

        if ($entries.Count -eq 0) {
            continue
        }

        Write-Host ""
        Write-Host $section -ForegroundColor Yellow

        $width = Get-DevWSHelpColumnWidth -Values @($entries | ForEach-Object { $_.Usage })

        foreach ($entry in $entries) {
            Write-DevWSHelpEntry -Left $entry.Usage -Right $entry.Summary -Width $width
        }
    }

    $aliasRows = @()

    # Navigation discoverability: direct command-group shortcuts are honest
    # top-level entry points, not operational commands. `sets` is intentionally
    # absent here (it stays a real command; its topic remains under `ws help`).
    $directTopics = @(Get-DevWSHelpDirectTopicInfo)

    if ($directTopics.Count -gt 0) {
        Write-Host ""
        Write-Host "Command groups" -ForegroundColor Yellow

        $groupWidth = Get-DevWSHelpColumnWidth -Values @($directTopics | ForEach-Object { [string]$_.Name })

        foreach ($topic in $directTopics) {
            Write-DevWSHelpEntry -Left ([string]$topic.Name) -Right ([string]$topic.ShortcutSummary) -Width $groupWidth
        }

        Write-Host ""
        Write-Host '  ws sets lists sets; ws help sets shows set-management commands.' -ForegroundColor DarkGray
    }

    foreach ($entry in $commands) {
        foreach ($alias in @($entry.Aliases)) {
            $aliasRows += $alias
        }
    }

    if ($aliasRows.Count -gt 0) {
        Write-Host ""
        Write-Host "Compatibility aliases" -ForegroundColor Yellow

        $aliasWidth = Get-DevWSHelpColumnWidth -Values @($aliasRows | ForEach-Object { $_.Usage })

        foreach ($alias in $aliasRows) {
            Write-DevWSHelpEntry -Left $alias.Usage -Right $alias.Summary -Width $aliasWidth
        }
    }

    $helpEntry = @($commands | Where-Object { $_.Name -eq "help" })[0]

    Write-Host ""
    Write-Host "Help" -ForegroundColor Yellow
    Write-DevWSHelpEntry -Left $helpEntry.Usage -Right $helpEntry.Summary -Width 36
    Write-Host ""
    Write-Host "Help topics: items, sets, layout, hotkeys, tools" -ForegroundColor DarkGray
    Write-Host ""
}

function Show-DevWSHelpTopic {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Topic
    )

    $commands = Get-DevWSHelpCommandInfo
    $entries  = @()

    foreach ($name in @($Topic.Commands)) {
        $entry = @($commands | Where-Object { $_.Name -eq $name })

        if ($entry.Count -gt 0) {
            $entries += $entry[0]
        }
    }

    Write-Host ""
    Write-Host $Topic.Title -ForegroundColor Yellow
    Write-Host ("─" * 56) -ForegroundColor DarkGray
    Write-Host ""

    $width = Get-DevWSHelpColumnWidth -Values @($entries | ForEach-Object { $_.Usage })

    foreach ($entry in $entries) {
        Write-DevWSHelpEntry -Left $entry.Usage -Right $entry.Summary -Width $width
    }

    Write-Host ""
    Write-Host 'Run `ws help <command>` for details.' -ForegroundColor DarkGray
    Write-Host 'Run `ws help all` for the complete command list.' -ForegroundColor DarkGray
    Write-Host ""
}

function Show-DevWSHelpCommand {
    param(
        [Parameter(Mandatory)]
        [pscustomobject]$Command
    )

    Write-Host ""
    Write-Host $Command.Usage -ForegroundColor Green
    Write-Host ""
    Write-Host $Command.Summary

    if (-not [string]::IsNullOrWhiteSpace([string]$Command.Warning)) {
        Write-Host ""
        Write-Host ([string]$Command.Warning) -ForegroundColor Red
    }

    if (@($Command.Details).Count -gt 0) {
        Write-Host ""

        foreach ($detail in @($Command.Details)) {
            Write-Host ("  " + $detail)
        }
    }

    $aliases = @($Command.Aliases)

    if ($aliases.Count -gt 0) {
        $label = if ($aliases.Count -eq 1) { "Alias: " } else { "Aliases: " }

        Write-Host ""
        Write-Host ($label + (($aliases | ForEach-Object { $_.Name }) -join ", ")) -ForegroundColor DarkGray
    }

    $examples = @($Command.Examples)

    if ($examples.Count -gt 0) {
        Write-Host ""
        Write-Host "Examples:" -ForegroundColor Yellow

        foreach ($example in $examples) {
            Write-Host ("  " + $example)
        }
    }

    Write-Host ""
}

function Get-DevWSLevenshteinDistance {
    param(
        [Parameter(Mandatory)]
        [string]$Left,
        [Parameter(Mandatory)]
        [string]$Right
    )

    $leftLength  = $Left.Length
    $rightLength = $Right.Length

    if ($leftLength -eq 0) {
        return $rightLength
    }

    if ($rightLength -eq 0) {
        return $leftLength
    }

    $previous = New-Object 'int[]' ($rightLength + 1)

    for ($column = 0; $column -le $rightLength; $column++) {
        $previous[$column] = $column
    }

    for ($row = 1; $row -le $leftLength; $row++) {
        $current = New-Object 'int[]' ($rightLength + 1)
        $current[0] = $row

        for ($column = 1; $column -le $rightLength; $column++) {
            if ($Left[$row - 1] -eq $Right[$column - 1]) {
                $cost = 0
            }
            else {
                $cost = 1
            }

            $deletion     = $previous[$column] + 1
            $insertion    = $current[$column - 1] + 1
            $substitution = $previous[$column - 1] + $cost

            $current[$column] = [Math]::Min([Math]::Min($deletion, $insertion), $substitution)
        }

        $previous = $current
    }

    return $previous[$rightLength]
}

function Get-DevWSCommandSuggestion {
    param(
        [string]$CommandName
    )

    $name = ([string]$CommandName).Trim().ToLowerInvariant()

    if ([string]::IsNullOrWhiteSpace($name)) {
        return @()
    }

    if ($name.Length -le 3) {
        $maxDistance = 1
    }
    elseif ($name.Length -le 8) {
        $maxDistance = 2
    }
    else {
        $maxDistance = 3
    }

    $commands = Get-DevWSHelpCommandInfo
    $known    = @()

    foreach ($command in $commands) {
        $known += $command.Name

        foreach ($alias in @($command.Aliases)) {
            $known += $alias.Name
        }
    }

    # Direct command-group shortcuts are executable navigation tokens too.
    # Unique candidates only: `sets` already arrives through the command
    # catalog and is deliberately not duplicated from the topic metadata.
    foreach ($topic in @(Get-DevWSHelpDirectTopicInfo)) {
        $known += [string]$topic.Name
    }

    $suggestions = @()

    foreach ($candidate in @($known | Sort-Object -Unique)) {
        $distance = Get-DevWSLevenshteinDistance -Left $name -Right $candidate

        if ($distance -ge 1 -and $distance -le $maxDistance) {
            $suggestions += [pscustomobject]@{
                Name     = $candidate
                Distance = $distance
            }
        }
    }

    return @(
        $suggestions |
            Sort-Object -Property Distance, Name |
            Select-Object -First 3 |
            ForEach-Object { $_.Name }
    )
}
