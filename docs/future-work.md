# DevWS Known Limitations and Deferred Work

This document records what DevWS does **not** currently do, what is known to be fragile, and
which design areas are deliberately deferred. It is a candid inventory, not a roadmap
commitment.

Items are grouped by kind. Nothing here is a promise; several items may never be worth
doing.

---

## 1. Known limitations

These are behaviours a user can actually meet.

### 1.1 PowerShell package-update resilience

DevWS scheduled tasks must launch an **absolute, trusted** PowerShell executable, so the
installer resolves one and records its full path in all five managed task actions.

If PowerShell is installed as a **packaged (Microsoft Store / MSIX) application**, its
executable lives in a **version-stamped** directory. When the package updates, that directory
is replaced, and the recorded path no longer exists. The managed tasks then cannot start,
which means elevated operations — terminal launches, capture, focus and reset — stop working
until the installer is re-run to re-register the task actions.

Observed behaviour in that situation:

- `ws doctor` / `ws health` reports the scheduled-task executable check as failing, so the
  problem is visible rather than silent;
- ordinary configuration-only commands continue to work;
- the fix is to re-run `install.ps1` from an elevated PowerShell.

**This is not solved.** Addressing it requires an architecture decision, because every
candidate solution changes how a high-integrity process obtains its interpreter — and that
is exactly the kind of decision that must not be made casually. Candidate directions, none
of which is chosen:

- prefer a non-packaged PowerShell installation, and document that preference;
- introduce a protected indirection that resolves a validated interpreter at task-run time;
- add an explicit repair path that re-registers the managed task actions.

Until one of those is designed and reviewed, treat a packaged PowerShell installation as a
known operational fragility.

### 1.2 `Alt+T` depends on an external task DevWS does not create

The managed hotkey script maps `Alt+T` to an external scheduled task named `AdminTerminal`.

DevWS **never creates, modifies or removes** that task. It is not a DevWS feature, and the
installer does not verify that it exists — the health check only confirms that the hotkey
still points at it.

Consequence: on a machine that does not already have an `AdminTerminal` task, `Alt+T`
silently does nothing useful, and the health check still passes. Treat it as a legacy
integration assumption rather than an installed capability.

### 1.3 The native assembly is not byte-reproducible

The native assembly is compiled from tracked C# sources with PowerShell's `Add-Type`.
Compiling identical sources twice is **not** guaranteed to produce identical bytes.

Consequences:

- installation validates the assembly's required type and method surface rather than a hash;
- the two installed copies are verified to be identical to each other, not to a published
  digest;
- a published checksum for this assembly would not be independently reproducible.

The initial public product is **source-oriented**, so this is currently an accepted
limitation rather than a blocker. Making builds reproducible would mean introducing a
different compilation route and a build-time dependency the project has so far avoided.

A related detail: the C# sources are not covered by the repository's end-of-line policy,
which pins the line endings of the text types the installer stages. A checkout on a machine
with different line-ending settings can therefore materialise the C# sources differently.
This is harmless today because the assembly is not compared by hash, but it would need to be
settled before any reproducible-binary claim.

### 1.4 No monitor watcher, no automatic reflow, no tiling

DevWS has no background monitor observer. Topology is sampled at the start of an operation
that needs it, and nothing happens between operations.

There is no automatic reflow, no tiling engine, no grid layout and no named zones. Layout is
an absolute rectangle per item, plus optional per-topology profiles. If your monitors change
while DevWS is idle, the next explicit launch or reset observes the new arrangement — DevWS
will not rearrange anything by itself.

### 1.5 AutoHotkey remains a required dependency

AutoHotkey v2 is required for global hotkeys and for two window operations. Most window work
has already moved in-process, but the dependency has not been removed. See §3.

### 1.6 Managed terminals must be elevated

A managed terminal must be configured as elevated. A non-elevated managed terminal is
rejected with an actionable error rather than silently accepted. This is a consequence of the
privileged model: elevated windows cannot be managed by a normal-integrity process.

### 1.7 Application-id launches cannot take arguments

An application launched by AppsFolder application id cannot carry launch arguments. Use an
executable launch definition when arguments are required.

---

## 2. Bounded security notes

These are deliberate, documented properties of the current design. They are recorded so that
a reviewer does not have to rediscover them — not because they are unnoticed defects.

### 2.1 Broker pipe admission is by operating-system policy, not mutual authentication

The persistent broker's named pipe admits any **same-user, medium-integrity** process, and
the broker does not additionally authenticate its clients. A same-user process could
therefore interfere with the user's own launch path — for example by occupying the pipe name
or the broker's single-instance primitive.

Impact is bounded: an interfering process is still running at the user's own integrity, so
this is misdirection or denial of service against your own session, **not** a privilege
boundary crossing.

This asymmetry is deliberate. The short-lived **worker** transport does authenticate in the
direction that matters: the caller validates the worker's identity from the connected pipe
handle before transmitting anything. Extending equivalent mutual authentication to the
broker is a recognised future hardening item.

### 2.2 Privileged operations intentionally consume user-controlled configuration

The canonical configuration is a user-writable file, and privileged operations read it. That
is intentional: DevWS exists to launch the workspace *you* configured, including configured
commands in elevated terminals.

The consequence is worth stating plainly: **configuration is input, not code, and it is
deliberately user-controlled.** A same-user process that can write the configuration can
influence what a privileged operation is asked to do. DevWS does not attempt to
cryptographically protect the configuration from its own user, because that would break the
product's purpose.

What the design *does* do is refuse to treat configuration as executable authority: the
privileged runtime, the executables it launches, and the privileged state it reads are all
resolved from administrator-protected sources rather than from user-writable values.

### 2.3 The scheduled-task definition is trusted as administrator-controlled

Worker authentication derives the expected worker identity from the scheduled task's own
declaration, on the basis that a medium-integrity process can read but not modify that
declaration. That assumption rests on the task's access control, not on anything DevWS
verifies cryptographically. It is worth re-confirming for any deployment where task
permissions have been changed from the installer's defaults.

### 2.4 The native assembly is validated structurally, not by identity

Installation validates the assembly's required surface, and loading trusts the file in the
administrator-protected location. There is no signature or publisher check on the generated
assembly. See §1.3 for the reproducibility angle.

### 2.5 Lower-priority hardening items

Recorded for completeness, each with bounded impact:

- Some state writers use a predictable temporary-file suffix. Inside the
  administrator-protected roots this is mitigated by the directory permissions; in
  user-owned state the exposure is limited to the user's own data.
- AutoHotkey helper invocations build an argument string by concatenation without escaping
  embedded quote characters, and the AutoHotkey executable itself is checked for existence
  rather than verified by hash.
- The exact-title locator accepts a matching window by title without a process check, so a
  same-user process could race a same-titled window. Impact is limited to that user's own
  windows.
- The worker transport provides no exactly-once guarantee after an uncertain outcome. It
  never repeats work automatically, because a duplicate launch is worse than a reported
  uncertainty; the guarantee is explicitly "no automatic duplicate execution".
- Development-only path overrides are honoured only in a repository checkout. Installed
  high-integrity processes ignore them and fall back to known-folder-derived paths; installed
  medium-integrity processes keep their user-authority overrides by design.

---

## 3. Deferred design areas

These are research topics, not scheduled work. None should be pulled into an implementation
without an explicit design decision.

### 3.1 Monitor-relative layouts

Today's geometry is an absolute rectangle, captured by arranging windows and running
`ws save-layout`. Topology profiles already make a set carry several layouts, but each one is
still absolute.

A future layout model could express intent *relative to a monitor* — normalised coordinates,
or a grid of rows and columns, or named zones. Open questions that must be answered together
before such a model ships:

- how a monitor is identified durably (hardware identity, device path, configured alias,
  dynamic primary role — ordinals are not durable);
- whether coordinates are relative to the full monitor rectangle or the work area;
- how display scaling and DPI differences are handled;
- what happens when a resolution changes, a monitor is rearranged, or a laptop is docked;
- whether a returning monitor should move windows automatically or only on the next explicit
  launch;
- how windows are kept reachable when a requested monitor is absent;
- how deliberate negative gaps and border overlaps are represented.

### 3.2 Missing-monitor policy

Monitor-relative layouts force an explicit policy for an absent monitor. Candidates, with
their trade-offs:

| Policy | Advantage | Cost |
| --- | --- | --- |
| Fail | Deterministic; never rearranges a careful desktop | Inconvenient for docked and laptop workflows |
| Skip | Non-destructive; partial workspaces still restore | A new window may appear somewhere unexpected |
| Fall back to primary | Keeps windows reachable | Several windows may overlap |
| Configured fallback monitor | Predictable for known setups | More configuration, and still needs a last resort |
| Collapse and retile | Potentially the best experience | Needs a real layout engine; hardest to make deterministic |

No policy is chosen. This must be decided **before** any monitor-relative mode ships.

### 3.3 Grid, tiling and named-zone engines

A grid could let configuration describe intent instead of pixels. It would also make
monitor-relative placement and missing-monitor retiling share one engine.

The honest counter-arguments: manual arrangement plus `ws save-layout` is already
ergonomic; window borders, taskbars, DPI and rounding make exact tiling less clean than the
arithmetic suggests; applications enforce minimum sizes; deliberate small overlaps are a
legitimate layout; and a grid engine has a tendency to grow into a full window manager.
There is also an unresolved question about what `ws save-layout` should mean for a
grid-managed item. The strong preference, if this is ever built, is to **never silently
change an item's layout mode**.

### 3.4 Reducing or removing the AutoHotkey dependency

AutoHotkey is currently used for three things:

- the persistent global hotkey host;
- exact-window focus;
- exact-window close/reset, preserving Windows Terminal's multi-tab close confirmation.

Everything else has already moved in-process. Three options should be compared without a
preselected winner:

- **A. Keep AutoHotkey as it is.** Lowest churn, keeps the current helper and hotkey host.
- **B. Make the window runtime AutoHotkey-free while keeping one small hotkey host.** Splits
  the concerns but does not remove the dependency.
- **C. Remove AutoHotkey entirely**, most likely replacing global hotkeys with a small
  native `RegisterHotKey` host.

Option C has real costs: DevWS would own a compiled binary, which needs a build, install and
update story and resident-process lifecycle handling. A native close implementation is
technically feasible but would add dialog machinery to preserve the current confirmation
behaviour.

Measured evidence should inform any decision: in a controlled comparison, the AutoHotkey
focus helper succeeded in every trial while naive in-process alternatives failed, and the
approaches that did work required synthetic input, undocumented APIs or z-order manipulation.

### 3.5 Launch-performance residuals

Profiling of the launch path left a small number of measured residuals — the first
native-assembly compile in a fresh process, the first global UI Automation fallback, and
active-tab selection. They are recorded for a possible future revisit and are **not**
unfinished work. Revisiting them is worthwhile only if a fresh profile shows an end-to-end
opportunity, because the remaining worker time is already overlapped by the application path.

---

## 4. Deliberately out of scope

Some things DevWS will not do without an intentional product decision:

- becoming a general-purpose window manager;
- a background daemon that continuously rearranges your desktop;
- capturing or restoring general application session state;
- an application plugin or adapter framework;
- arbitrary user-scripted hotkey actions.
