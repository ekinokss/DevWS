# DevWS Manual Validation Checklist

Automated coverage lives in `tests/run-tests.ps1` and is hermetic: it never launches a
workspace, moves a real window, registers a task or writes to your configuration.

This document covers the behaviour that genuinely needs a real Windows desktop session:
real Windows Terminal windows, real scheduled tasks, real elevation and real monitor
topologies. Use it after changing installer behaviour, the lifecycle, or anything that
touches identity, privilege or window management.

**Nothing here runs automatically.** Steps marked destructive will close windows or remove
installed files; run them deliberately.

---

## Status legend

| Label | Meaning |
| --- | --- |
| **Automated** | Covered by the hermetic test suite; no desktop needed. |
| **Needs a desktop** | Requires a real interactive session with Windows Terminal. |
| **Needs elevation** | Requires an Administrator PowerShell. |
| **Destructive** | Closes windows, removes files, or changes the installed system. |
| **Manual only** | Cannot reasonably be automated; verify by observation. |

---

## 0. Before you start

Record the current state so you can tell what your change did:

- [ ] the canonical configuration exists and note its hash;
- [ ] the current user `PATH`;
- [ ] the five managed `DevWorkspace-*` task definitions;
- [ ] the Startup folder contents;
- [ ] the currently open Windows Terminal windows.

**Needs a desktop.**

If you have a legacy `%USERPROFILE%\.ws` directory, note its hash too — it must never change.

## 1. Prerequisites

- [ ] Run the installer from an Administrator PowerShell in the repository root.
- [ ] A non-elevated shell is told the exact command to re-run, and **nothing** is modified.
- [ ] With a prerequisite missing, the installer aborts before any modification and names
      what is missing.

**Needs elevation.**

## 2. Installed layout

- [ ] `%LOCALAPPDATA%\DevWS` contains `app\`, `helpers\`, `bin\` and `state\`.
- [ ] `%ProgramFiles%\DevWS\privileged` contains `workers\`, `lib\`, `helpers\` and
      `native\`.
- [ ] Both `DevWS.Native.dll` copies exist.
- [ ] Every installed `.ps1` file parses.

**Automated** for the parse and file-set checks; **needs elevation** to read the privileged
root.

## 3. Configuration preservation

- [ ] With a valid current configuration, the installer reports `preserve` and the file's
      bytes are unchanged.
- [ ] With a supported older configuration, the installer takes a backup before replacing
      anything.
- [ ] With an invalid configuration, the installer fails safely and leaves the bytes alone.

**Automated** for the decision model; **needs a desktop** to confirm against your real
configuration.

## 4. Scheduled tasks

- [ ] Exactly five `DevWorkspace-*` tasks exist.
- [ ] Each runs as the installing user, interactively, at the highest run level.
- [ ] Each action uses an absolute trusted PowerShell path and a protected worker script.
- [ ] No task outside the five DevWS-managed tasks is read, created, modified or removed.
- [ ] After a packaged PowerShell update, `install.ps1 -RepairTasks` rewrites all five task
      actions to the new absolute interpreter while leaving every other managed property
      intact, and `install.ps1 -HealthCheck` reports the executable check green again.
- [ ] `install.ps1 -RepairTasks` refuses, and changes nothing, when one managed task is
      missing or a same-named task has a foreign definition.

**Needs elevation.**

## 5. User `PATH` and the command shim

- [ ] `%LOCALAPPDATA%\DevWS\bin` is on the user `PATH`, exactly once.
- [ ] Unrelated `PATH` entries are preserved.
- [ ] `ws` resolves to the installed shim in a fresh shell.
- [ ] A legacy shim is migrated only when it is the recognised historical content; anything
      else is left alone and reported.

**Needs a desktop.**

## 6. Hotkeys

- [ ] `TerminalShortcut.ahk` exists in the Startup folder.
- [ ] `Alt+Shift+T` launches or restores the default set.
- [ ] `Alt+T` has no built-in action and can be bound to a set with `ws bind`.
- [ ] An additional binding created with `ws bind` actually fires, and `ws unbind` removes
      it.
- [ ] No backup files are left in the Startup folder.

**Manual only.**

## 7. Health check

- [ ] `install.ps1 -HealthCheck` reports all checks passing.
- [ ] `ws doctor` and `ws health` report the same result and the same exit code.
- [ ] The check does not create runtime-state files.

**Needs a desktop.**

## 8. Read-only commands

- [ ] `ws list` lists configured items in order and does not change anything.
- [ ] `ws show-layout` reports the effective rectangles and the topology decision.
- [ ] `ws status` reports configured and live state, and reports a stale host rather than
      restarting it.
- [ ] `ws monitors` reports the current topology and its fingerprint.
- [ ] `ws detect-app` lists visible applications without tagging, adopting or launching
      anything.

**Needs a desktop.**

## 9. Focus

- [ ] `ws focus` brings existing items forward.
- [ ] It creates nothing.
- [ ] It moves and resizes nothing.

**Needs a desktop.**

## 10. Launch with existing terminals

- [ ] `ws launch` moves and restores the existing windows.
- [ ] Existing terminal sessions are **preserved** — no new window appears for a terminal
      that already exists.
- [ ] The configured active tab is selected.

**Needs a desktop.**

## 11. Launch with missing terminals

- [ ] Close one managed terminal, then `ws launch`.
- [ ] The missing terminal is recreated with its configured tabs, directories and commands.
- [ ] The other terminals are not duplicated.
- [ ] Placement follows the effective layout.

**Needs a desktop.**

## 12. Repeated launch

- [ ] Run `ws launch` twice in a row.
- [ ] No duplicate windows appear.
- [ ] Nothing is closed or rearranged unexpectedly.

**Needs a desktop.**

## 13. Layout capture

- [ ] Arrange the windows by hand.
- [ ] `ws save-layout` stores the geometry.
- [ ] `ws show-layout` reflects the new rectangles.
- [ ] `ws save` additionally stores reliable working directories and the configured active
      tab.
- [ ] If an enabled item cannot be captured, **nothing** is written.

**Needs a desktop.**

## 14. Configuration-only mutations

- [ ] `ws disable <id>` then `ws list` shows the item disabled — and no window closed.
- [ ] `ws set-path` and `ws set-command` change configuration without touching live
      terminals.
- [ ] `ws rename` changes the id and preserves the terminal's live window.
- [ ] `ws add-terminal` adds a definition without launching it.

**Needs a desktop.**

## 15. Terminal reset

- [ ] `ws reset <id>` closes and recreates exactly that terminal.
- [ ] Other terminals are untouched.
- [ ] The recreated terminal has the configured tabs, directories and commands.
- [ ] Placement follows the effective layout.

**Needs a desktop. Destructive.**

## 16. Reinstall idempotency

- [ ] Re-run the installer.
- [ ] The configuration is preserved byte-for-byte.
- [ ] No duplicate `PATH` entries or tasks appear.
- [ ] The health check still passes.

**Needs elevation.**

## 17. Uninstall

- [ ] `uninstall.ps1` removes the tasks, the installed files and DevWS-owned integrations.
- [ ] It preserves the canonical configuration, disposable state and the legacy
      `%USERPROFILE%\.ws` directory.
- [ ] It restores pre-install shim and hotkey backups when they exist.
- [ ] `-Purge` additionally removes the canonical configuration and state.
- [ ] Even `-Purge` never removes `%USERPROFILE%\.ws`.

**Needs elevation. Destructive.**

## 18. Privilege boundary

- [ ] A normal-integrity process cannot write to the privileged runtime or the privileged
      state root.
- [ ] A normal-integrity process cannot replace a managed task's action target.
- [ ] The privileged runtime refuses to load libraries from a user-writable location.

**Needs elevation to set up; verify with a normal-integrity shell.**

---

## Recording a validation run

When you record a result, say which steps you actually ran, on which Windows build, and
which you deliberately skipped. A checklist that claims everything passed without saying
what was executed is worse than no checklist.
