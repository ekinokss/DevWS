# DevWS Installer and Uninstaller

This document is the contract for `install.ps1` and `uninstall.ps1`: what they require,
what they write, what they deliberately leave alone, and how to check the result.

See [architecture.md](architecture.md) for why the runtime is split the way it is, and
[configuration.md](configuration.md) for the configuration rules the installer applies.

---

## 1. Running the installer

```powershell
# from the repository root, in an Administrator PowerShell
pwsh
.\install.ps1
```

```powershell
install.ps1                      # install or idempotently update
install.ps1 -ResetConfig         # back up the current config, then install the starter
install.ps1 -ResetConfig -Force  # same, skipping the reset confirmation
install.ps1 -HealthCheck         # report status without changing anything
install.ps1 -RepairTasks         # repair stale managed task PowerShell bindings only
```

The installer **does not self-elevate**. If it is not running as an administrator it stops
before making any change and prints the exact command to re-run.

`-HealthCheck` is non-destructive, is safe to run at any time, and does not require
elevation. The same health implementation backs `ws doctor` and `ws health`.

`-RepairTasks` is an isolated repair mode (see §6.1). It requires elevation, never falls
through into the nine-step install/update flow, and cannot be combined with `-ResetConfig`,
`-Force` or `-HealthCheck`.

## 2. Prerequisites

All prerequisites are checked **before anything is modified**. A failure aborts with an
actionable message and leaves the machine untouched.

| Prerequisite | Check |
| --- | --- |
| **Windows** | The process is running on Windows. |
| **PowerShell 7+** | Major version 7 or newer. |
| **Windows Terminal** | A genuine registered Microsoft **stable** package is resolved through the operating system's package APIs, its publisher identity is validated, and a non-reparse `WindowsTerminal.exe` under the protected package location is confirmed. A foreign, repackaged or unregistered build is refused. No minimum Windows Terminal version is claimed. |
| **AutoHotkey v2** | A machine-wide (all-users) installation whose recorded directory resolves to an existing `v2\AutoHotkey64.exe` under an administrator-protected Program Files root, with file metadata reporting major version 2. DevWS never installs it, does not own or test the upstream AutoHotkey installer, and rejects a current-user-only installation for installed operation. The accepted contract is the installed machine-wide state. |
| **Administrator** | Checked after the prerequisites and before any modification. |

DevWS never installs third-party software for you, and there is no onboarding wizard.

## 3. What gets installed where

### User-owned runtime — `%LOCALAPPDATA%\DevWS`

| Path | Contents |
| --- | --- |
| `app\ws.ps1` | The CLI entry point. |
| `app\coordinator.ps1` | The optional warm coordinator host. |
| `app\config\workspace.default.json` | The bundled neutral starter configuration. |
| `app\lib\*.ps1` | 34 runtime libraries. |
| `app\native\DevWS.Native.dll` | Generated native assembly (see §5). |
| `helpers\window-helper.ahk` | The user-integrity window focus helper. |
| `bin\ws.cmd` | The command shim, generated for this install root. |
| `state\` | Disposable state: installer metadata, backups, generated hotkeys, the terminal handle cache and other runtime artefacts. |

The source-managed manifest for this root contains **39 entries**.

### Administrator-protected privileged runtime — `%ProgramFiles%\DevWS\privileged`

| Path | Contents |
| --- | --- |
| `workers\*.ps1` | The four short-lived workers and the persistent broker. |
| `lib\*.ps1` | 19 libraries reachable from high-integrity code. |
| `helpers\` | `cwd-shell-bootstrap.ps1`, `reset-window.ahk`, `window-helper.ahk`. |
| `native\DevWS.Native.dll` | A second copy of the generated assembly. |

The source-managed manifest for this root contains **27 entries**. This is the only place a
high-integrity DevWS process loads code from.

### Administrator-protected privileged state — `%ProgramData%\DevWS\privileged-state\<SID>`

Created and validated during installation with an explicit security policy: owned by the
administrators group, full control for the system and administrators, read and execute for
the installing user, a protected DACL with no inherited entries, and no reparse points
anywhere in the chain.

The foundation is created **empty**. The elevated runtime cache, capture publications and
the terminal working-directory authority appear here only when a high-integrity operation
first needs them.

Components that already exist are validated as untrusted input. The installer never
silently repairs, re-owns or re-permissions them; a drifted component is reported and an
administrator must resolve it deliberately before re-running.

### Canonical configuration — `%USERPROFILE%\.config\devws\workspace.json`

See §4. The installer preserves a valid configuration and never rewrites it casually.

### Legacy v1 directory — `%USERPROFILE%\.ws`

**Never** created, modified or deleted by install, update or uninstall.

## 4. Configuration behaviour

The installer is the only component that may migrate the configuration schema.

| Situation | Action |
| --- | --- |
| Valid current v3 configuration | `preserve` — left **byte-for-byte** unchanged. |
| v3 configuration predating explicit instance modes | Backed up, then enriched deterministically, validated, replaced atomically. |
| v3 whose instance modes cannot be inferred safely | Fails safely; bytes kept; the affected applications are named. Nothing is guessed. |
| Valid v2 configuration | Backed up, converted to v3, validated, replaced atomically. |
| Valid v2 that cannot be represented as v3 | Fails safely; bytes kept; the offending definition is named. |
| Invalid or unrecognised configuration | Fails safely; bytes kept; never replaced, never migrated over. |
| No configuration, no legacy v1 | Installs the bundled neutral starter. |
| `-ResetConfig` | Backs up the existing configuration, then installs the starter. |

Reruns are idempotent: an already-valid configuration is preserved, and backups are not
duplicated.

## 5. The generated native assembly

The native assembly is compiled from the tracked C# sources in `src/native` during
installation:

1. a candidate is compiled in a fresh PowerShell child process;
2. the compiled bytes are validated structurally — the complete required type and method
   surface must be present;
3. only then is it promoted atomically to the user root, and a byte-identical copy is
   placed in the privileged root.

A failed generation leaves the previously installed runtime intact.

**The compilation is not byte-reproducible.** Compiling the same sources twice does not
guarantee identical bytes. Installation therefore validates the *surface* of the assembly
rather than a hash, and the two installed copies are verified to be identical to each
other. See [future-work.md](future-work.md).

## 6. Scheduled tasks

Exactly five DevWS-managed tasks are created or updated:

```text
DevWorkspace-ElevatedHelper
DevWorkspace-ElevatedCapture
DevWorkspace-ElevatedFocus
DevWorkspace-ElevatedReset
DevWorkspace-ElevatedBroker
```

Each runs as the installing user, interactively, at the highest available run level, with a
single-instance policy, and with an action built from an **absolute trusted PowerShell path**
plus a **protected worker script**. There is no `PATH` lookup.

The broker additionally starts at logon, has no execution time limit, is battery-safe and
restarts on failure. Before the installer replaces the privileged runtime it stops the
managed broker task so the new code takes effect; it never kills processes by name.

The previous task definitions are exported to the backup directory once. Reinstalls reuse
that backup rather than creating a chain.

**Tasks DevWS does not own are never read, modified or removed.** DevWS has no dependency
on any external scheduled task.

### 6.1 Repairing the task interpreter after a PowerShell update

Each action records an **absolute** trusted `pwsh.exe`. A packaged (Microsoft Store / MSIX)
PowerShell installation lives in a version-stamped directory, so a package update can leave
the tasks pointing at a path that no longer exists.

`install.ps1 -RepairTasks`, run from an elevated PowerShell 7 shell, rewrites exactly those
bindings:

- it resolves and runtime-verifies the **currently running** PowerShell installation through
  the existing trusted-executable policy;
- it refuses unless the machine really is an installed DevWS instance: the installed app host,
  all five protected worker scripts, and install metadata with a recorded privileged root
  must be present;
- it refuses if any of the five tasks is missing, or if a same-named task does not have the
  complete DevWS-managed shape apart from the interpreter path (wrong worker, extra argument,
  different principal, settings or triggers). Nothing is overwritten in that case;
- it captures every task definition first, re-registers only the stale ones through the same
  canonical definition builder the installer uses, verifies each result, and only then
  updates `privileged.powerShellPath` in the install metadata;
- on any failure it restores every changed definition from its captured XML and restores the
  metadata bytes;
- it restarts the broker only if the broker was running before the repair.

It does **not** copy application files, rebuild the native assembly, stage the privileged
runtime, create protected state, migrate configuration, or touch `PATH`, the legacy shim,
hotkeys, AutoHotkey or Windows Terminal. It never runs any part of the uninstall path. When
every task and the metadata already agree with the current interpreter, it reports a no-op
and changes nothing.

The task actions remain absolute. This is a repair command, not dynamic interpreter
resolution, and it does not make package updates self-healing.

## 7. User PATH and the command shim

- The installer ensures `%LOCALAPPDATA%\DevWS\bin` is on the **user** `PATH`, prepending it
  when it is missing. Comparison is case- and trailing-slash-insensitive, unrelated entries
  are preserved and duplicates are not created.
- Installer metadata records whether *this* installation added the entry. Uninstall removes
  it only when DevWS owns it.
- A legacy `%USERPROFILE%\.local\bin\ws.cmd` is migrated **only** when its content is
  exactly the known historical shim; it is backed up first and replaced with a forwarding
  shim. Any other content is left untouched and reported by the health check.

## 8. Hotkeys

DevWS manages exactly one Startup script, `TerminalShortcut.ahk`:

- `Alt+Shift+T` sends a launch request to the warm coordinator over a current-user-only
  local pipe, and falls back to a hidden CLI launch if the coordinator is unavailable;
- `Alt+T` has no built-in action; it is ordinary binding space for configured sets;
- the same script starts the coordinator once at login;
- a generated include file carries additional per-set hotkeys, and a missing generated file
  never breaks the built-in shortcut.

The installer regenerates the include from canonical configuration before installing the
core script. Recognised historical content — including an older core that carried a retired
external-task binding — is upgraded in place; unknown content is left untouched and
reported. Backups are taken before replacing a legacy `.ws` hotkey, and no backup files are
left in the Startup folder.

## 9. Health check

`install.ps1 -HealthCheck`, `ws doctor` and `ws health` run the same **25 checks**:

1. Windows
2. PowerShell 7+
3. Windows Terminal launcher is the trusted package executable
4. AutoHotkey v2 executable
5. Installed app host scripts (`ws.ps1`, `coordinator.ps1`)
6. Installed app libraries and native runtime
7. Installed helpers (medium copy and privileged routes)
8. Installed scheduled-task workers (privileged root)
9. Administrator-protected privileged runtime is complete
10. Privileged native runtime validates
11. Protected privileged-state foundation is administrator-controlled
12. Installed `bin\ws.cmd`
13. State directory
14. Canonical workspace config exists
15. Canonical workspace config validates
16. DevWS bin on the user `PATH`
17. Five DevWorkspace scheduled tasks exist
18. Scheduled tasks point at installed workers and match managed settings
19. Scheduled tasks run with highest privileges
20. Scheduled tasks use the absolute trusted PowerShell executable
21. `TerminalShortcut.ahk` exists
22. `TerminalShortcut` `Alt+Shift+T` targets installed DevWS
23. `TerminalShortcut` has no retired external scheduled-task binding
24. Generated set launch bindings match canonical config
25. Installed `ws list` runs read-only

The check only reads files, tasks and `PATH`, and runs the read-only `ws list`. It never
launches a workspace, moves a window, resets a terminal or closes anything.

Check 20 distinguishes a stale interpreter binding from other task damage. When the recorded
interpreter is missing, or a task still has the complete managed shape but executes a
different `pwsh.exe`, the message names `install.ps1 -RepairTasks`. Any other definition
drift is reported as a general installer problem instead, so a foreign task is never
presented as a routine package update.

## 10. Uninstall

```powershell
uninstall.ps1          # remove DevWS files, tasks and integrations; keep configuration
uninstall.ps1 -Purge   # also remove canonical configuration, state and backups
uninstall.ps1 -Force   # skip the confirmation prompt
```

Uninstall requires elevation, because it removes scheduled tasks and files under the
program-files root.

**Removed:**

- the five DevWorkspace tasks, stopping the managed broker task first when it is running;
- the installed `app\`, `helpers\`, `bin\` and worker files;
- the user `PATH` entry, but only when the installer added it;
- the privileged runtime, through an explicit guard that requires the path to be rooted,
  to end in `privileged` under a `DevWS` parent, and not to contain the install root;
- DevWS-owned shim and hotkey integration, restoring pre-install backups when they exist;
- with `-Purge` only: the canonical configuration and the state/backups tree.

**Always preserved:**

- `%USERPROFILE%\.ws` (the legacy v1 directory) — under every option, including `-Purge`;
- the canonical configuration and disposable state, unless `-Purge` is used;
- unrelated Startup scripts and scheduled tasks;
- Windows Terminal settings;
- your PowerShell profile;
- another user's protected state directory.

The protected state root is removed only when it revalidates and is empty. A non-empty or
invalid root is preserved with a message so nothing of value is destroyed by an uninstall.

**Residue.** A default uninstall leaves the `%LOCALAPPDATA%\DevWS` directory itself and,
unless `-Purge` is used, the disposable state and backups. This is intentional: the
configuration and the state are yours, not the installer's.

## 11. Idempotency and update semantics

- Existing valid configuration is preserved byte-for-byte.
- `PATH` entries and tasks are not duplicated.
- Backups are not repeated.
- Unrelated tasks, `PATH` entries and Startup files are untouched.
- Privileged files are staged and parse-validated **before** any target is replaced, and
  promotion is a per-file atomic replace.
- A failed installation rolls back exactly the protected-state components it created in
  that run, deepest first, and never removes a pre-existing component.

## 12. Installer metadata

`state\install-metadata.json` records what this installation owns and changed: the install
root, install and update timestamps, whether DevWS added the `PATH` entry, legacy shim and
hotkey backup locations, task definition backups, and what happened to the configuration.
It never contains the workspace configuration itself.

## 13. Acceptance and manual validation

The installer lifecycle was acceptance-tested on a disposable Windows 11 VM: clean install,
25/25 installed health, genuine linked-Medium protected-state validation, the exact five-task
topology, idempotent update, real `-RepairTasks`, default uninstall, reinstall, purge, and a
final residue/ownership audit. The optional real-window lifecycle smoke was **not observed**
in that environment and is not claimed as passed.

Behaviour that cannot be covered by automated tests — real windows, real tasks, real
monitor topologies — is listed in
[windows-integration-checklist.md](windows-integration-checklist.md).
