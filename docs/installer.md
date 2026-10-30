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
install.ps1 -PackageMode         # non-interactive ordinary install/update for a future package layer
```

The installer **does not self-elevate**. If it is not running as an administrator it stops
before making any change and prints the exact command to re-run.

`-HealthCheck` is non-destructive, is safe to run at any time, and does not require
elevation. The same health implementation backs `ws doctor` and `ws health`.

`-RepairTasks` is an isolated repair mode (see §6.1). It requires elevation, never falls
through into the nine-step install/update flow, and cannot be combined with `-ResetConfig`,
`-Force` or `-HealthCheck`.

### Package integration contract

`install.ps1 -PackageMode` is the stable non-interactive contract for the DevWS setup
bootstrapper. It performs the ordinary install/idempotent-update path:
package-mode machine-wide AutoHotkey acquisition when needed, prerequisite validation,
elevation, configuration preservation/migration, the existing nine-step installer and the
mandatory health check. It has no separate installation implementation and never resets a
valid configuration.

`uninstall.ps1 -PackageMode` is the corresponding non-interactive default uninstall contract.
It performs the ordinary uninstall without the confirmation prompt and preserves the canonical
workspace configuration, disposable state/backups, `%USERPROFILE%\.ws` and unrelated resources
exactly as a default uninstall does. It never implies `-Purge` or `-Force`.

Package mode does **not** self-elevate. The invoking package/bootstrap layer must run it from
an elevated PowerShell. Package mode can acquire the machine-wide AutoHotkey v2 prerequisite
through WinGet when it is absent; PowerShell 7 and Windows Terminal remain caller-managed
prerequisites. Package mode cannot reset or purge: the installer rejects `-PackageMode` with
`-ResetConfig`, `-Force`, `-HealthCheck` or `-RepairTasks`, and the uninstaller rejects it
with `-Purge` or `-Force`, before any machine mutation.

Direct source/interactive use of `install.ps1` and `uninstall.ps1` remains supported and
unchanged. The v0.2 source and the public `v0.2.0-rc.1` pre-release contain a
`DevWS-Setup.exe` build. The unsigned stable `v0.2.0` GitHub release is published. The v0.3.0
release candidate uses the same package-mode contract and is not published. A WinGet
submission template exists under `packaging/winget`, but no WinGet catalog package exists and
the template is not submitted. This contract fixes the arguments,
non-interactive behavior and exit status the setup wrapper uses. Exit code `0` means the
requested package-mode operation completed; any nonzero exit means it did not.

### Setup bootstrapper source

The v0.2 integration branch and the `release/v0.3.0-preparation` branch contain the same thin
Windows x64 setup bootstrapper source at `packaging/bootstrapper`. It embeds the DevWS
installation payload and invokes `install.ps1 -PackageMode`; it does not replace the PowerShell
installer's semantics. It does not install PowerShell 7 or Windows Terminal, but package mode
can acquire the machine-wide AutoHotkey v2 prerequisite through WinGet, and it does not ship a
WinGet package. The setup source provides install, same-version reinstall/repair, upgrade,
downgrade refusal, HKCU Add/Remove Programs registration, setup-driven package uninstall,
and a protected persisted setup; see the lifecycle section below. The current build is
x64-only.

The unsigned Windows x64 setup is published as the stable `v0.2.0` GitHub release:
https://github.com/ekinokss/DevWS/releases/tag/v0.2.0. The `v0.2.0-rc.1` pre-release remains
available. The v0.3.0 candidate is prepared from the same source and is not published. No
WinGet catalog package is available; the prepared WinGet template is blocked by WinGet's
unattended validation and is not submitted. See
[`packaging/README.md`](../packaging/README.md) for build and fixture-test instructions.

The setup requests elevation itself. It captures the caller SID before elevation and the
elevated child rejects any different Windows account before staging or changing anything.
UAC elevation using another administrator account is therefore intentionally rejected.
Running setup from an already-elevated process installs for that elevated account; the setup
does not claim a different interactive caller in that case.

### Package lifecycle

The setup source models a per-user Windows package lifecycle. Its stable identity is
`ekinokss.DevWS`, display name `DevWS`, publisher `ekinokss`, and current candidate version
`0.3.0`. Discovery state is written to the 64-bit current-user uninstall key; no HKLM
registration or Windows Installer product code is used.

A successful install persists the setup executable at
`%ProgramFiles%\DevWS\setup\<current-user-SID>\DevWS-Setup.exe` with an administrator-owned
protected ACL. The target user can read and execute it but cannot write, replace, rename,
delete, change permissions or take ownership. The same version reruns the idempotent
PowerShell install for repair. Upgrades are allowed; downgrades are refused before the
PowerShell installer is called. The ARP entry is discovery state only and is never trusted
as executable authority.

`--uninstall` runs the ordinary package-mode uninstall, removes the ARP entry, then uses a
protected post-exit helper to remove the per-SID setup directory without a reboot. Package
uninstall preserves canonical configuration, state/backups, `%USERPROFILE%\.ws` and unrelated
resources exactly as the frozen Phase-1 contract requires. The unsigned v0.2.0 setup is
publicly available as the stable GitHub release; the v0.2.0-rc.1 pre-release remains
available. The v0.3.0 candidate is not published. No WinGet catalog package is available.
Self-update and MSI/MSIX/Windows Installer identity are not implemented.

### Release-candidate artifact pipeline

The v0.2 branch and the `release/v0.3.0-preparation` branch use
`packaging/build-release.ps1` to wrap `build-setup.ps1` and assemble a commit-bound release
candidate containing exactly `DevWS-Setup.exe`, `LICENSE`, `provenance.json` and
`SHA256SUMS.txt`. `packaging/verify-release.ps1` independently verifies the bundle, source SHA,
version, checksums, provenance and privacy/path hygiene, and runs only the non-mutating
`--version` and `--help` surfaces.

A manually dispatched bootstrapper workflow validates and retains this candidate as an Actions
artifact for 30 days, then downloads and re-verifies the exact artifact in a separate job.
Normal feature-branch pushes run only fixture lifecycle validation. The candidate is unsigned
and no Native AOT reproducibility is claimed. The workflow produced the unsigned
`v0.2.0-rc.1` pre-release and the stable unsigned `v0.2.0` GitHub release. The v0.3.0 candidate
is built and verified locally but is not uploaded or published. No `v0.3.0` GitHub Release,
Windows Installer identity, attestation or WinGet catalog package exists.

### Release state

**CURRENT v0.3.0 RELEASE CANDIDATE (UNPUBLISHED):**

- local four-file release candidate containing `DevWS-Setup.exe`, `LICENSE`,
  `provenance.json` and `SHA256SUMS.txt`
- product version `0.3.0`, Native AOT Windows x64, commit-bound provenance
- not tagged, not uploaded, not published and not installed on the development host
- guest cross-version upgrade, live Medium/High terminal-presence, elevated-reset and
  installer-lifecycle acceptance remain release gates

**PUBLIC v0.2.0-rc.1 PRE-RELEASE:**

- `DevWS-Setup.exe` build
- install
- same-version reinstall/repair
- upgrade
- downgrade refusal
- HKCU Add/Remove Programs registration
- setup-driven package uninstall
- protected persisted setup
- release-candidate Actions artifact pipeline

**PUBLISHED STABLE v0.2.0 GITHUB RELEASE:**

- unsigned Windows 11 x64 GitHub release bundle
- the same install, reinstall/repair, upgrade, downgrade-refusal, HKCU ARP, package-uninstall
  and persisted-setup behavior accepted for the v0.2 line
- commit-bound release-candidate artifact and downloaded-artifact verification

**NOT PUBLISHED OR NOT AVAILABLE:**

- `v0.3.0` tag, GitHub Release, release asset or published installer
- signed `v0.2.0` or `v0.3.0` installer
- WinGet catalog package: the submission template is prepared but blocked by WinGet's
  unattended-elevation validation and is not submitted

**NOT IMPLEMENTED:**

- self-update
- MSI/MSIX or Windows Installer identity

The published v0.1.0 remains a historical source release. The unsigned `v0.2.0` GitHub release
is the current stable public binary; the `v0.2.0-rc.1` pre-release remains available. The
v0.3.0 candidate is not published.

## 2. Prerequisites

All prerequisites are checked **before any DevWS modification**. A failure aborts with an
actionable message. Package mode first validates the non-AutoHotkey prerequisites, then may
acquire AutoHotkey v2 for all users through WinGet, and only then proceeds. Source mode never
acquires software and leaves the machine untouched on failure.

| Prerequisite | Check |
| --- | --- |
| **Windows** | The process is running on Windows. |
| **PowerShell 7+** | Major version 7 or newer. |
| **Windows Terminal** | A genuine registered Microsoft **stable** package is resolved through the operating system's package APIs, its publisher identity is validated, and a non-reparse `WindowsTerminal.exe` under the protected package location is confirmed. A foreign, repackaged or unregistered build is refused. No minimum Windows Terminal version is claimed. |
| **AutoHotkey v2** | A machine-wide (all-users) installation whose recorded directory resolves to an existing `v2\AutoHotkey64.exe` under an administrator-protected Program Files root, with file metadata reporting major version 2. Package mode acquires it through WinGet when it is absent, then revalidates it through this resolver. A current-user-only installation is rejected and is neither used nor removed. The accepted contract is the installed machine-wide state. |
| **Administrator** | Checked before package-mode AutoHotkey acquisition and before any DevWS modification. |

Source installation never installs third-party software. Package mode may acquire
AutoHotkey v2 for all users through the registered WinGet package; it does not install
PowerShell 7 or Windows Terminal, and it does not remove a user-scope AutoHotkey
installation. There is no onboarding wizard.

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
uninstall.ps1              # remove DevWS files, tasks and integrations; keep configuration
uninstall.ps1 -Purge       # also remove canonical configuration, state and backups
uninstall.ps1 -Force       # skip the confirmation prompt
uninstall.ps1 -PackageMode # non-interactive default uninstall for a future package layer
```

Uninstall requires elevation, because it removes scheduled tasks and files under the
program-files root.

Before removing the installed runtime or its integrations, uninstall stops the
DevWS-owned user-session processes:

- a candidate is selected only when the script the host actually executes is
  the exact installed target: the PowerShell `-File` script operand (or its
  first positional script), or AutoHotkey's script operand. The coordinator or
  `TerminalShortcut.ahk` path appearing only as an unrelated argument,
  `-Command` text, or script parameter is never a target;
- the process image, actual command line, owner SID, and exact kernel creation
  time are read through a process handle. Termination uses that same verified
  handle, so a PID that exited and was reused can never redirect cleanup to a
  replacement process;
- the warm coordinator is contacted only when at least one verified
  coordinator process exists. The named-pipe server PID must match a verified
  coordinator before any shutdown frame is sent, and the shutdown
  acknowledgement PID must match that server;
- an unrelated same-user pipe server that happens to use the expected pipe
  name is never sent a shutdown command;
- unrelated PowerShell and AutoHotkey processes are never selected by image
  name alone;
- a missing or already-exited process is a safe no-op;
- an unresponsive, stale, inaccessible, ownership-unverifiable, or
  identity-changed known coordinator/hotkey process makes uninstall fail
  closed before any task, file, PATH, configuration, or state mutation.

The managed hotkey launcher is stopped before the coordinator so it cannot
restart the coordinator during removal. The five scheduled tasks (including
the managed broker), the managed hotkey file, PATH entry, runtime files, and
privileged state are then handled in the existing order. Repeated uninstall
remains safe.

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
- unrelated PowerShell and AutoHotkey processes;
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

For v0.2.0, the installer lifecycle was acceptance-tested on a disposable Windows 11 VM:
clean install, 25/25 installed health, genuine linked-Medium protected-state validation, the
exact five-task topology, idempotent update, real `-RepairTasks`, default uninstall, reinstall,
purge, and a final residue/ownership audit. The optional real-window lifecycle smoke was
**not observed** in that environment and is not claimed as passed.

The v0.3.0 candidate has not yet completed its guest cross-version upgrade, live Medium/High
terminal-presence, elevated-reset or lifecycle acceptance. Hardware scenarios RH-03 (mixed
150%/100% scaling) and RH-05 (primary-monitor change) remain outstanding. Durable path
identities are validated; physical EDID behavior is not claimed from path-only evidence.

Behaviour that cannot be covered by automated tests — real windows, real tasks, real
monitor topologies — is listed in
[windows-integration-checklist.md](windows-integration-checklist.md).
