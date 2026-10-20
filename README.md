# DevWS

**A configuration-driven workspace orchestrator for Windows.**

DevWS restores and manages a complete multi-window development environment — Windows
Terminal windows and tabs, desktop applications, window geometry and global hotkeys —
from a single declarative configuration file.

You describe the workspace once; DevWS brings it back on demand.

> **Status: pre-release.** DevWS has no published release yet. The repository is a
> source-first project: there is no installer package, no release binary and no
> distribution channel. Everything below describes the current source.

---

## The problem

A working development environment is usually a specific arrangement of windows: a few
terminals opened in specific project directories, each with the commands you always run
there, plus a browser and an editor placed exactly where you want them.

Recreating that arrangement by hand after a reboot, a crash or a monitor change is
tedious and error-prone. DevWS replaces the manual work with configuration:

- which windows and tabs should exist;
- what each one runs and where it starts;
- where each one belongs on screen;
- which applications should be opened alongside them.

## What DevWS does

- **Workspace sets** — several independent workspaces (for example a daily driver and a
  separate project), each a complete definition, each launchable on its own.
- **Managed terminals** — Windows Terminal windows and tabs created from configuration,
  with per-tab working directories and startup commands, and a stable named-window
  identity so live windows are recognised rather than duplicated.
- **Managed applications** — desktop applications matched by executable or process path,
  launched when missing, and placed at their saved geometry.
- **Layout capture** — save the real on-screen rectangles after arranging windows by
  hand, then restore them later.
- **Topology layout profiles** — optional per-set layouts keyed to an exact monitor
  topology, with a universal fallback layout for everything else.
- **Live-state saving** — persist window geometry plus the reliable tracked working
  directory and active tab of each managed terminal.
- **Global hotkeys** — a managed AutoHotkey host plus generated per-set launch hotkeys.
- **Read-only inspection** — `ws status`, `ws list`, `ws show-layout`, `ws monitors` and
  `ws detect-app` report what is configured and what is actually live, without changing
  anything.
- **Privileged operations without per-command UAC** — elevation is performed by a small
  number of pre-authorised scheduled tasks instead of prompting on every command.

DevWS is deliberately explicit: nothing happens in the background. There is no daemon
watching your desktop, no automatic window rearrangement, and no hidden "active
workspace" state. Every change is the result of a command you ran.

## Platform

**Windows only.** DevWS drives Windows Terminal, the Windows scheduled-task service,
Win32 window management, Windows integrity levels and the Windows registry. It does not
run on Linux or macOS, and it is not portable to them.

## Prerequisites

| Requirement | Notes |
| --- | --- |
| **Windows** | DevWS is validated on Windows 11. No older Windows release is currently claimed as supported. |
| **PowerShell 7+** | Required to run the CLI and the installer. Windows PowerShell 5.1 is not sufficient. |
| **Windows Terminal** | The genuine Microsoft Store / packaged Windows Terminal. DevWS resolves it through the official package identity and refuses to launch an untrusted executable. |
| **AutoHotkey v2** | Required for global hotkeys and for the window focus/close helpers. DevWS does not install it. |
| **Administrator rights for installation** | The installer creates or updates DevWS-managed scheduled tasks and writes to a protected location. Normal `ws` commands do **not** require elevation. |

DevWS never installs third-party software for you. If a prerequisite is missing the
installer stops before making any change and tells you what is missing.

## Installing

Installation is a single elevated PowerShell session run from the repository root:

```powershell
pwsh
.\install.ps1
```

Run it from an **Administrator** PowerShell. The installer does not self-elevate; if it
is not elevated it prints the exact command to re-run.

The installer is idempotent and preserve-oriented. In particular it does **not** replace
an existing valid configuration:

- an existing valid configuration is preserved byte-for-byte;
- a supported older configuration is migrated with a backup taken first;
- an unrecognised or invalid configuration is left untouched and reported.

See [docs/installer.md](docs/installer.md) for the full contract.

## First run: a neutral, empty workspace

DevWS ships a deliberately minimal default configuration:

```json
{
  "version": 3,
  "defaultSet": "main",
  "bindings": [],
  "sets": [
    {
      "id": "main",
      "windows": []
    }
  ]
}
```

This is a **starter**, not an example workspace. It defines one empty set and no items,
so a fresh install never imposes somebody else's terminals, applications or screen
geometry. A workspace that is not configured yet simply has nothing to launch.

## First useful commands

```powershell
# See what is configured (a fresh install has no items yet)
ws list

# Add a terminal at a directory, then a second one
ws add-terminal work C:\Projects\Work
ws add-terminal notes C:\Notes

# Configure what the first tab of a terminal should run
ws set-command work npm run dev

# Arrange the windows by hand, then save the geometry
ws save-layout

# Bring the workspace up (creates only what is missing)
ws launch

# Bring the existing windows forward without creating or moving anything
ws focus

# What is configured, and what is actually live right now
ws status
```

Every configuration command is config-only: `ws add-terminal`, `ws set-command`,
`ws enable`, `ws rename` and friends never open, close, move or resize a window. Only
the lifecycle commands (`ws launch`, `ws focus`, `ws reset*`) touch live windows, and the
reset commands are destructive by design.

The complete command surface is documented in [docs/cli.md](docs/cli.md). Running `ws`
with no arguments shows a quick reference; `ws help all` lists every command.

## Workspace sets

A **set** is a complete, independent workspace definition with its own ordered items.
Exactly one set is the configured default, which is what a bare command targets:

```powershell
ws sets                       # list the configured sets
ws add-set secondary          # add an empty set
ws clone-set main secondary   # or start from a copy
ws set-default secondary      # change what bare commands target

ws launch secondary           # operate on one set explicitly
ws status secondary
ws enable secondary/notes     # set-qualified reference
```

Sets coexist. Launching one set never closes, minimises or hides another, and there is no
hidden "currently active set" — only the configured default. See
[docs/workspace-sets-design.md](docs/workspace-sets-design.md).

## Terminals and applications

**Terminals** are Windows Terminal windows identified by a durable named-window id, with
one or more configured tabs. Each tab can have its own working directory and startup
command, and DevWS tracks which tabs it manages so live windows are matched by identity
rather than by whatever title a running program happens to display.

**Applications** are desktop applications described by a match rule (executable name or
process-path substring) and a launch rule (executable plus arguments, or an AppsFolder
application id). Every application has an explicit instance mode:

- `dedicated` — the application belongs to one set and DevWS owns its window;
- `shared` — one eligible window is deliberately reused across sets.

DevWS never guesses: an ambiguous match is refused rather than resolved by a heuristic.

## Capturing layout

Layout is captured from reality rather than typed in by hand:

1. run `ws launch` (or arrange the windows yourself);
2. drag and resize windows until they look right;
3. run `ws save-layout` to store the geometry, or `ws save` to store geometry **plus** the
   reliable tracked working directory and active tab of each managed terminal.

Geometry capture is all-or-nothing: if any enabled item cannot be captured, nothing is
written. `ws show-layout` previews exactly which rectangles the next launch or terminal
reset will apply.

If your monitors change, optional **topology layout profiles** let a set carry a different
layout per monitor arrangement, while `item.layout` remains the universal fallback. A set
with no profiles has no monitor dependency at all.

## Hotkeys

DevWS manages one AutoHotkey v2 script in your Startup folder. One shortcut is built in
and permanently reserved:

| Hotkey | Behaviour |
| --- | --- |
| `Alt+Shift+T` | Launches or restores the default set. |

`Alt+T` has **no built-in DevWS behaviour**. It is ordinary binding space and can be
assigned to a workspace set like any other hotkey:

Additional per-set launch hotkeys are configured and generated:

```powershell
ws bind secondary alt+shift+y
ws bind main alt+t
ws bindings
ws sync-hotkeys
```

DevWS does not depend on, create, modify or remove any external scheduled task in order
to provide a hotkey.

## Privileged operations

Some work must happen at high integrity: managed terminals are elevated, and closing,
recreating or focusing elevated windows requires elevation. DevWS performs that work
through a small set of **pre-authorised scheduled tasks** created at install time, so
ordinary commands stay UAC-free.

Privileged code and privileged state live in administrator-protected locations, separate
from the user-writable CLI, configuration and state. The trust boundaries are described in
[docs/architecture.md](docs/architecture.md).

## Where things live

| Path | Purpose |
| --- | --- |
| `%USERPROFILE%\.config\devws\workspace.json` | Canonical workspace configuration |
| `%LOCALAPPDATA%\DevWS` | User-owned installed runtime, helpers, `bin` and disposable state |
| `%ProgramFiles%\DevWS\privileged` | Administrator-protected privileged runtime |
| `%ProgramData%\DevWS\privileged-state\<SID>` | Administrator-protected privileged state |

## Documentation

| Document | Contents |
| --- | --- |
| [docs/architecture.md](docs/architecture.md) | Component model, identity, trust boundaries and security model |
| [docs/cli.md](docs/cli.md) | Complete command reference |
| [docs/configuration.md](docs/configuration.md) | Configuration schema and validation rules |
| [docs/installer.md](docs/installer.md) | Installer and uninstaller contract |
| [docs/workspace-sets-design.md](docs/workspace-sets-design.md) | The workspace-set product model |
| [docs/future-work.md](docs/future-work.md) | Known limitations and deliberately deferred work |
| [docs/windows-integration-checklist.md](docs/windows-integration-checklist.md) | Manual validation checklist for behaviour that cannot be unit-tested |
| [CONTRIBUTING.md](CONTRIBUTING.md) | Development environment, tests and contribution guidance |
| [SECURITY.md](SECURITY.md) | Security model summary and how to report a problem |
| [PROVENANCE.md](PROVENANCE.md) | Where this source came from and how the repository is maintained |
| [CHANGELOG.md](CHANGELOG.md) | Changes, kept truthful and release-free until a release exists |

## License

MIT. See [LICENSE](LICENSE).
