# DevWS Command Line Reference

`ws` is the DevWS command line. It reads the canonical configuration, performs the
requested operation, and prints a result. This document is the complete reference for
the command surface.

The command metadata below is generated from the same source the CLI itself uses to
render help, so this document and `ws help` cannot drift apart.

See [configuration.md](configuration.md) for the file these commands read and write, and
[architecture.md](architecture.md) for how the runtime behaves.

---

## Invocation

```powershell
ws <command> [arguments]
```

Running `ws` with no arguments prints a quick reference. `ws help all` lists every
command. `-h`, `--help` and `/?` are accepted as help aliases.

The parser is deliberately literal. Everything after the command and its first argument
is passed through in its original order, so switch-looking tool arguments such as `-w 5`
reach configured commands unchanged instead of being interpreted by the CLI.

---

## Command classes

Commands differ in what they are allowed to touch. Knowing the class is the fastest way
to avoid surprises.

| Class | Touches live windows | Writes configuration | Commands |
| --- | --- | --- | --- |
| **Observational** | no | no | `list` / `show`, `status`, `show-layout`, `bindings`, `sets`, `monitors`, `detect-app`, `doctor` / `health`, `help` |
| **Configuration only** | no | yes | `enable`, `disable`, `remove`, `add-terminal`, `set-path` / `set`, `set-command`, `add-app`, `set-instance-mode`, `set-launch`, `set-match`, `set-app-args`, `rename`, `clone-terminal`, `clone-app`, `set-geometry`, `reset-layout`, `layout-profile`, `add-set`, `clone-set`, `rename-set`, `remove-set`, `set-default`, `edit` |
| **Configuration + generated hotkeys** | no | yes | `bind`, `unbind`, `sync-hotkeys` |
| **Layout capture** | reads window geometry | yes | `save-layout`, `save` |
| **Lifecycle** | **yes** | no | `launch`, `focus` |
| **Destructive** | **yes** | no | `reset`, `reset-terminal`, `reset-terminals` |

A configuration-only command never launches, closes, focuses, moves or resizes a window
and never restarts a running application. The destructive commands close and recreate
terminals by design.

---

## Conventions

**Sets.** Commands that accept an optional set operate on the configured default set when
it is omitted. An explicit set never changes which set is the default.

**Scoped references.** `<set>/<id>` targets an item in a named set, for example
`secondary/notes`. Unqualified ids resolve inside the target set.

**Numeric aliases.** `ws set`, `ws reset` and `ws reset-terminal` also accept a 1-based
terminal number, resolved inside the default set. Application mutations accept stable ids
only.

**Confirmation.** Commands that could remove or destroy something prompt before acting.
`-Force` (and, where accepted, `--force`) skips the prompt. Confirmation protects you; it
is not a safety mechanism for the configuration, which is never left half-written.

**Disabled items.** A disabled item is still listed, but launch, focus and layout capture
ignore it.

---

## Command reference

## Workspace

### `ws launch [set]`

Ensure all enabled items exist and restore their saved layout.

- Existing terminal sessions are preserved; only missing items are created.
- Placement uses the effective layout: the exact topology layout profile when the current monitors match one, otherwise each item's fallback layout.
- A profile-aware set refuses the launch before any side effect when the topology is unsafe or a matched profile rectangle is unreachable; an unreachable fallback rectangle is reported and that item is left unmoved.
- No monitor watcher and no automatic retile: the next explicit launch observes a new topology.
- Omitting [set] uses defaultSet.

```powershell
ws launch
ws launch main
ws launch secondary
```

### `ws focus [set]`

Bring existing items forward without creating or repositioning anything.

- Does not launch missing items and does not move or resize windows.

```powershell
ws focus
ws focus secondary
```

### `ws list [set]`

List configured items in order, including enabled/disabled state.

- Disabled items are shown but ignored by launch, focus, and layout capture.

```powershell
ws list
ws show secondary
```

**Aliases**

- `ws show [set]` — Compatibility alias for ws list.

### `ws status [set]`

Show the current configured and live state of a workspace set.

- Reports terminals and apps with live presence, ambiguity and ownership observations, plus tracked cwd where available.
- Reports broker/coordinator liveness and deployed-generation currency; a stale host is reported, never restarted.
- Strictly observational: never launches, focuses, repairs, or writes anything.

```powershell
ws status
ws status secondary
```

### `ws save-layout [set] [--profile <id>]`

Capture and persist geometry for all enabled items (all-or-nothing).

- Geometry only; terminal cwd and the activeTab are not saved.
- With no profiles the captured geometry updates the fallback item.layout.
- With profiles the storage scope follows the current topology: the exactly matching profile, otherwise the fallback.
- --profile <id> creates or updates that profile; creation requires a complete capture and a stable, safely matchable topology.
- Fails without changing config if any enabled item cannot be captured or if the topology changes during capture.

```powershell
ws save-layout
ws save-layout secondary
ws save-layout --profile docked
```

### `ws save [set] [--profile <id>]`

Save geometry plus reliable tracked per-tab cwd and the configured activeTab.

- Geometry is required and follows the same profile storage routing as ws save-layout.
- Every configured terminal tab resolves its own tracked cwd independently; reliable cwd is opportunistic and always global (terminal.path for tab 0, per-tab overrides only when required), never per profile.
- Unavailable cwd keeps the existing effective path for that tab.
- The configured activeTab is saved only from a reliable managed-tab observation; anything else keeps the existing value.
- Topology stability and per-tab generation both revalidate before one atomic canonical write.

```powershell
ws save
ws save secondary
ws save --profile docked
```

### `ws show-layout [set]`

Show the effective operational geometry for configured items (read-only).

- Shows the current topology fingerprint, the profile/relative/fallback routing, and effective rectangles.
- A sparse matched profile marks the items it omits; their relative intent or absolute fallback still applies. Unreachable rectangles are marked too.
- Relative items also show their mode, monitor identity/instance, basis, normalized rectangle, resolved placement, and any fallback or missing/ambiguous/unavailable reason.
- Relative placement is operational for targeted items. Ordinary set launch targets enabled items; explicit targeted resets follow their own target selection. Skipped placements are marked. There is no live monitor watcher or automatic retile.

```powershell
ws show-layout
ws show-layout secondary
```

## Item configuration

### `ws enable <id>`

Enable a configured item (config only).

- Never launches, closes, moves, or focuses a window.

```powershell
ws enable notes
```

### `ws disable <id>`

Disable a configured item (config only).

- Never closes windows; disabled items are ignored by launch, focus, and layout capture.

```powershell
ws disable notes
```

### `ws remove <id> [-Force]`

Remove a configured item from config.

- Config only: never closes a window and deletes no files.
- Prompts for confirmation unless -Force is supplied.

```powershell
ws remove notes
ws remove notes -Force
```

### `ws add-terminal <id> <path> [command] [args...]`

Add a terminal definition (config only).

- Copies the last terminal layout and does not launch; position the window and run ws save-layout.

```powershell
ws add-terminal notes .
ws add-terminal notes C:\Projects\App npm run dev
```

### `ws set-path <id-or-ref> <path>`

Change a terminal path or one configured tab's path override (config only).

- ws set-path <id-or-ref> --tab <n> <path> sets that configured tab's explicit path override.
- ws set-path <id-or-ref> --tab <n> --clear removes that tab's override; the tab inherits the terminal path again.
- A tab-0 override mirrors into the terminal path for older builds; clearing tab 0 leaves the terminal path unchanged.
- Changing the terminal path preserves existing per-tab overrides.
- References may be set-qualified, for example secondary/notes.
- The ws set compatibility alias also accepts a 1-based terminal number.

```powershell
ws set-path notes .
ws set-path notes --tab 1 C:\Projects\B
ws set 2 C:\Projects\App
```

**Aliases**

- `ws set <id|number> <path>` — Compatibility alias for ws set-path; also accepts a 1-based terminal number.

### `ws set-command <id-or-ref> <command> [args...]`

Replace the first command tab of a terminal (config only).

- Running terminals keep their current command until reset.
- Literal tool arguments such as -w 5 pass through unchanged.

```powershell
ws set-command notes npm run dev
ws set-command notes somecmd -w 5
```

### `ws add-app <id> <launch-kind> <launch-value> <match-kind> <match-value> <instance-mode>`

Add an app with an explicit dedicated/shared mode (config only).

- Launch kinds: exe, appId. Match kinds: exe, processPathContains.
- The instance-mode argument is required; same-id apps across sets share one mode.
- Copies the last app layout; the app is not launched.

```powershell
ws add-app notes exe "C:\Program Files\Notes\Notes.exe" exe Notes.exe dedicated
```

### `ws set-instance-mode <app-id> <dedicated|shared>`

Set the instance mode for every same-id app across sets (config only).

- Running app windows and their ownership tags are not touched.

```powershell
ws set-instance-mode notes shared
```

### `ws set-launch <app-id> <kind> <value>`

Replace an app launch definition (config only).

- The running app is not relaunched; the new definition applies on the next launch.

```powershell
ws set-launch notes exe "C:\Program Files\Notes\Notes.exe"
```

### `ws set-match <app-id> <kind> <value>`

Replace an app match definition (config only).

- No live window lookup and no ownership change.

### `ws set-app-args <app-id> [args...]`

Replace executable launch arguments (config only).

- Only for exe launches; appId launches do not support arguments.
- --clear removes all arguments.

```powershell
ws set-app-args notes --profile work
ws set-app-args notes --clear
```

### `ws rename <old-id> <new-id>`

Rename a configured item (config only).

- Only the config id changes; a terminal windowId and live windows are preserved.

### `ws clone-terminal <source-id> <new-id>`

Clone a terminal definition (config only).

- The clone is not launched and gets a fresh set-qualified windowId.

### `ws clone-app <source-id> <new-id>`

Clone an app definition as a disabled template (config only).

- The clone starts disabled because it shares the source match rule.

## Layout

### `ws set-geometry <id> --x <x> --y <y> --width <width> --height <height> [--layout <profileId|fallback>]`

Set a saved layout rectangle in the fallback or an explicit profile (config only).

- Saved geometry only; the live window is not moved.
- --layout fallback edits item.layout; --layout <profileId> edits that profile's sparse entry (no topology read).
- Without --layout the scope follows the current topology when the set has profiles: matched profile, otherwise fallback; an unmatchable topology refuses the write.

```powershell
ws set-geometry notes --x -7 --y 0 --width 654 --height 1407
ws set-geometry notes --x 0 --y 0 --width 800 --height 600 --layout docked
```

### `ws reset-layout [set] [-Force]`

Restore saved layouts from the bundled default config (config only).

- Matches by id/type; terminals may match by preserved windowId fallback; unmatched items are skipped.
- Restores fallback item.layout only; topology layout profiles are never created, modified or deleted.
- Prompts for confirmation unless -Force is supplied.

```powershell
ws reset-layout
ws reset-layout secondary
```

### `ws layout-profile <list|remove|match> ...`

Manage optional per-set topology layout profiles (config only).

- Subcommands: list [set] (read-only), remove <profile|set/profile> [-Force], match <profile|set/profile>.
- Profiles store absolute geometry for one exact monitor topology; item.layout remains the universal fallback and profiles may be sparse.
- Create/update profiles through 'ws save-layout --profile <id>' so they start from real captured geometry; 'match' re-keys an existing profile to the current topology.
- Config only: never moves windows. The matching profile is applied automatically by 'ws launch' and terminal resets.

```powershell
ws layout-profile list
ws layout-profile remove laptop -Force
ws layout-profile match docked
```

## Workspace sets

### `ws sets`

List configured sets, item counts, and launch hotkeys.

### `ws add-set <id>`

Add an empty workspace set (config only).

- Does not launch anything and does not create a shortcut.

### `ws clone-set <source-set> <new-set>`

Deep-copy a workspace set (config only).

- Cloned terminals get new set-qualified windowIds.

### `ws rename-set <old-set> <new-set>`

Rename a workspace set, preserving its identity (config only).

- Item ids, terminal windowIds, commands, tabs, geometry and layout profiles are preserved exactly.
- defaultSet and every launch binding targeting the set are retargeted automatically; binding hotkeys never change.
- Refuses while a dedicated app of the set still owns a live window; never closes, moves or retags windows.
- A case-only rename keeps the existing tracking and ownership identities unchanged.

### `ws remove-set <id> [-Force]`

Remove a non-default set from config (config only).

- Refuses the default set and the last remaining set.
- Never closes windows; prompts for confirmation unless -Force is supplied.

### `ws set-default <id>`

Change which set bare commands target (config only).

- No window is moved or closed; there is no hidden active-set state.

## Hotkeys

### `ws bind <set> <hotkey>`

Bind an additional set launch hotkey (config + generated hotkeys).

- Canonical config is saved first; the generated hotkey file is then regenerated and reloaded.
- Alt+T and Alt+Shift+T stay reserved.

```powershell
ws bind secondary alt+shift+y
```

### `ws unbind <hotkey>`

Remove a set launch hotkey binding (config + generated hotkeys).

```powershell
ws unbind alt+shift+y
```

### `ws bindings`

List configured additional set launch hotkeys (read-only).

### `ws sync-hotkeys`

Regenerate generated hotkeys from config and reload them.

- Never modifies config; also recovers a stopped AHK hotkey process.

## Tools / diagnostics

### `ws edit`

Edit the workspace config safely (temporary copy + validation).

- Canonical config changes only after validation; derived hotkeys are not synced.
- Editor order: DEVWS_EDITOR, then VS Code (--wait), then Notepad.

```powershell
ws edit
```

### `ws doctor`

Run the non-destructive installation health check.

- Read-only; the exit code reports pass/fail.

```powershell
ws doctor
ws health
```

**Aliases**

- `ws health` — Compatibility alias for ws doctor (same checks and exit code).

### `ws detect-app [filter]`

Inspect visible applications and app-definition suggestions (read-only).

- Shows exact-HWND identity, dedicated ownership, and scoped configured matches with explicit modes.
- Never tags, adopts, launches, or moves anything.

```powershell
ws detect-app
ws detect-app notes
```

### `ws monitors`

Show the current monitor topology and stable monitor identities (read-only).

- Shows the exact topology fingerprint that future layout-profile matching will use.
- Monitor ordinals (DISPLAY1/DISPLAYn) are diagnostic only and never durable identity.
- Read-only: no display settings change, no windows move, no config is read or written.

```powershell
ws monitors
```

## Terminal reset

### `ws reset <id|number|set/id>`

Destructively recreate one managed terminal.

> **Warning.** Destructive: the managed terminal is closed and recreated.

- Closes the managed terminal and recreates it from current config.
- Placement uses the same effective layout as ws launch: the matching topology profile when present, otherwise the fallback layout.
- A profile-aware set refuses the reset before any side effect when the topology is unsafe or a matched profile rectangle is unreachable; an unreachable fallback rectangle recreates the terminal without moving it.
- Numeric references target the default set.

```powershell
ws reset notes
ws reset 2
ws reset secondary/notes
```

**Aliases**

- `ws reset-terminal <id|number|set/id>` — Compatibility alias for ws reset.

### `ws reset-terminals [set] [-Force]`

Destructively recreate all enabled terminals of the target set.

> **Warning.** Destructive: every enabled terminal in the target set is closed and recreated.

- Disabled terminals and other sets are never reset.
- Placement follows the same effective layout as ws launch, resolved once for all selected terminals.
- Prompts for confirmation unless -Force is supplied.

```powershell
ws reset-terminals
ws reset-terminals secondary -Force
```

## Help

### `ws help [<command>|<topic>|all]`

Show the quick reference, command help, topic help, or all commands.

- Topics: items, sets, layout, hotkeys, tools.
- -h, --help, and /? are accepted as help aliases.

```powershell
ws help
ws help launch
ws help hotkeys
ws help all
```

---

## Direct command-group shortcuts

Four read-only shortcuts render exactly the matching help topic. They take no arguments
and never touch the workspace, a host, a monitor or a window.

| Shortcut | Renders |
| --- | --- |
| `ws items` | Item configuration commands |
| `ws layout` | Layout commands |
| `ws hotkeys` | Hotkey commands |
| `ws tools` | Diagnostics and terminal reset commands |

`ws sets` is the operational set listing, not a shortcut; `ws help sets` browses the
set-management commands.

---

## Help topics

| Topic | Direct shortcut | Commands covered |
| --- | --- | --- |
| `items` | `ws items` | enable, disable, remove, add-terminal, set-path, set-command, add-app, set-instance-mode, set-launch, set-match, set-app-args, rename, clone-terminal, clone-app |
| `sets` | — | sets, add-set, clone-set, rename-set, remove-set, set-default |
| `layout` | `ws layout` | save-layout, save, show-layout, set-geometry, reset-layout, layout-profile |
| `hotkeys` | `ws hotkeys` | bind, unbind, bindings, sync-hotkeys |
| `tools` | `ws tools` | edit, doctor, detect-app, monitors, reset, reset-terminals |

---

## Exit codes

| Code | Meaning |
| --- | --- |
| `0` | Success. |
| non-zero | The command failed. The message on standard output or standard error explains why, and the configuration is left unchanged unless the command reported otherwise. |

`ws doctor` and `ws health` use the exit code to report whether the installation health
check passed.

---

## Notes

- `ws save-layout` is geometry only. `ws save` additionally persists reliable tracked
  working directories and the configured active tab.
- `ws reset-layout` restores fallback geometry from the bundled default by id. It never
  creates, modifies or deletes topology layout profiles.
- `ws edit` validates a temporary copy and replaces the canonical file only after a
  successful validation; derived hotkeys are not regenerated by `ws edit`.
- Lifecycle placement always uses the effective layout: the exactly matching topology
  profile when one exists, otherwise the item fallback.
