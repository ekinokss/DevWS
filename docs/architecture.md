# DevWS Architecture

This document describes how DevWS is put together: the components, how windows and
applications are identified, where the integrity boundaries are, and which failures are
refused rather than guessed. It describes the **current** implementation; it is not a
development log.

Companion documents: [configuration.md](configuration.md) for the configuration schema and
validation rules, [cli.md](cli.md) for command semantics,
[workspace-sets-design.md](workspace-sets-design.md) for the workspace-set model.

---

## 1. Scope and design principles

DevWS is a Windows-only orchestrator for a configured desktop workspace. Its design
principles are:

- **Explicit operations.** Nothing happens in the background. There is no watcher, no
  polling loop over your desktop, and no automatic window rearrangement. Every side
  effect is the result of a command.
- **Configuration over convention.** Terminals, tabs, applications, geometry and hotkeys
  all come from configuration. The runtime does not assume a fixed number of terminals,
  a fixed set of applications, or any particular command.
- **Identity over titles.** A window is identified by a durable identity, never by the
  title text a running program happens to display.
- **Refuse rather than guess.** Ambiguity, unsafe topologies and untrusted executables
  produce an actionable refusal before any side effect.
- **Least standing privilege.** The command-line surface runs at the user's normal
  integrity. The small amount of work that genuinely needs elevation is pre-authorised
  once, at install time, instead of prompting per command.

## 2. Component model

```text
        you
         │  ws <command>
         ▼
 ┌───────────────────┐        ┌────────────────────────────┐
 │  CLI  (Medium)    │        │  Windows Terminal windows  │
 │  ws.ps1           │───────▶│  (managed, elevated)       │
 └───────────────────┘        └────────────────────────────┘
         │                                ▲
         │  named pipe                    │
         ▼                                │
 ┌───────────────────┐        ┌──────────┴─────────────────┐
 │  Coordinator      │        │  Elevated broker  (High)   │
 │  (Medium, warm)   │───────▶│  terminal planning/kickoff │
 └───────────────────┘        └────────────────────────────┘
                                          ▲
                                          │ authenticated one-shot pipes
                                          │
                              ┌───────────┴───────────────┐
                              │  4 short-lived workers    │
                              │  (High, task-launched)    │
                              └───────────────────────────┘
```

| Component | Integrity | Lifetime | Role |
| --- | --- | --- | --- |
| **CLI** (`ws.ps1`) | Medium (user) | one process per command | Parses the command, loads and validates configuration, performs config-only work, and drives lifecycle operations. |
| **Coordinator** | Medium (user) | persistent, per user session | Optional warm host for the hotkey launch path. It removes process-start latency and runs the same canonical launch transaction as the CLI. |
| **Elevated broker** | High (administrator) | persistent, started at logon | Owns the terminal half of a launch behind a prepare/go barrier, and executes terminal focus and capture. |
| **Short-lived workers** | High (administrator) | one process per operation | Launch helper, capture, focus and reset. Each serves exactly one authenticated request and exits. |
| **AutoHotkey host** | Medium (user) | persistent | Global hotkeys, plus the two window operations that are not implemented natively (see §13). |
| **Native assembly** | loaded by the calling component | per process | In-process Win32 and Windows API interop (see §12). |

The CLI and the coordinator share one implementation of the launch transaction, so the
cold path and the warm path cannot drift apart.

## 3. Integrity boundary

DevWS uses the ordinary Windows integrity model rather than a custom privilege scheme.

**Medium integrity — user-writable:**

- the CLI and all normal libraries;
- the coordinator;
- the canonical configuration file;
- the user-owned installed runtime under `%LOCALAPPDATA%\DevWS`, including `bin` and the
  disposable state root;
- the generated hotkey include and the AutoHotkey host.

**High integrity — administrator-protected:**

- the privileged runtime under `%ProgramFiles%\DevWS\privileged`: the five worker scripts,
  the high-reachability library set, the two high-integrity AutoHotkey helpers and a copy
  of the native assembly;
- the privileged state root under `%ProgramData%\DevWS\privileged-state\<SID>`: the
  elevated runtime cache, capture publications and the terminal working-directory
  authority.

The rule that keeps these separate is simple and enforced at runtime: **a high-integrity
DevWS process loads code only from the administrator-protected privileged root.** Workers
resolve their libraries from the directory next to them and fail closed if the privileged
runtime is incomplete or misplaced. There is no fallback to a user-writable copy, and the
path overrides used for development are ignored by installed layouts.

The privileged state root is created and validated with an explicit security policy:
owned by the administrators group, full control for the system and administrators, read
and execute for the target user, a protected DACL with no inherited entries, and no
reparse points anywhere in the chain. Components that already exist are validated as
untrusted input — DevWS never silently repairs, re-owns or re-permissions them.

## 4. Terminal identity

A terminal's configuration `windowId` is its **durable identity**. It is not the visible
window title: long-running programs change titles freely, so titles are never used as
permanent identity.

A terminal's presence is decided in this order:

1. **Validated runtime state** — the last known window handle recorded for this terminal
   in this set.
2. **Non-creating UI Automation discovery** — searching existing Windows Terminal windows
   for a tab whose configured name matches the terminal's `windowId`.

A stored window handle is trusted only after revalidation: the window must still exist,
must belong to Windows Terminal, and must be associated with the configured `windowId`
through UI Automation. A foreign application that happens to expose a same-named tab is
never accepted.

Runtime state is keyed by the scoped identity `<set-id>/<terminal-id>`, so the same item
id in two sets can never share a cached handle. Runtime state is disposable: losing it
costs a discovery pass, never correctness.

Configured tabs have a canonical managed title family — the window id for tab 0 and a
suffixed form for later tabs — generated and parsed by exactly one pair of helpers, with a
configuration-wide collision invariant so that one terminal cannot impersonate another's
managed titles.

## 5. Application identity and ownership

Applications are matched by an explicit rule from configuration:

- `exe` — executable name;
- `processPathContains` — process-path substring.

Matching only decides which windows are *eligible*. Resolution is exact and
ownership-aware:

- a **dedicated** application uses its unique owned window, or adopts exactly one matching
  unowned window;
- a **shared** application uses the single eligible window not owned by any dedicated
  item;
- multiple plausible candidates are an **ambiguity**, and DevWS refuses instead of picking
  one.

Ownership is bound to the lifetime of the window itself, through a window property
carrying the scoped identity. There is no durable ownership database and no generated
instance id; lookup is bounded to the configured identities rather than scanning arbitrary
windows.

Applications are rediscovered from their match rules on every operation. There is no
persistent application-to-window map to go stale.

## 6. Lifecycle semantics

The lifecycle commands are deliberately asymmetric:

| Command | Creates missing items | Moves existing windows | Destructive |
| --- | --- | --- | --- |
| `ws launch` | yes | yes (applies the effective layout) | no |
| `ws focus` | **no** | **no** | no |
| `ws save` / `ws save-layout` | no | no | no |
| `ws reset*` | recreates | yes | **yes** |

`launch` preserves existing terminal sessions: only genuinely missing items are created.
`focus` brings existing items forward and never launches, moves or resizes anything.
Reset commands close and recreate the targeted terminals from current configuration.

Configuration-only commands (`enable`, `disable`, `remove`, the `set-*` family, `rename`,
the `clone-*` family, `add-*`, `set-geometry`, `reset-layout`, `edit`) never launch, close,
focus, move or resize a window and never restart a running application.

Live side effects of a launch are serialised by a bounded, launch-only named mutex, so two
simultaneous launches cannot interleave their terminal work. It is not a queue and not a
lock file, and it does not provide ordering guarantees.

## 7. Configuration and state separation

Canonical configuration and runtime state are different things in different places:

- **Canonical configuration** — `%USERPROFILE%\.config\devws\workspace.json`. This is the
  only file that describes intent. It contains no window handles and no live observations.
- **User runtime state** — under `%LOCALAPPDATA%\DevWS\state`. Disposable. The terminal
  handle cache, generated hotkeys, installer metadata and backups live here.
- **Privileged state** — under `%ProgramData%\DevWS\privileged-state\<SID>`. The elevated
  runtime cache, capture publications and the working-directory authority.

Configuration is saved atomically: the serialised result is validated and then replaced in
one step. A failed capture, a failed validation or an interrupted operation leaves the
previous configuration intact. Configuration mutations never silently reset live
terminals, and no command migrates the schema except the installer.

## 8. Privileged transport

Two named-pipe planes connect the user-integrity side to the high-integrity side. Both
pipes are created with an explicit security descriptor granting access only to the current
user and the system account, with a mandatory label that prevents low-integrity write-up.

**Broker pipe** — a fixed name. The broker holds at most one pending transactional plan,
has no active-workspace state, never polls, and exits cleanly when the deployed code
changes underneath it so that a stale host cannot serve outdated behaviour.

**Worker pipes** — one pipe per operation, named with the operation and the current user's
identifier. The name is an identifier, never a secret.

Worker requests are authenticated in the direction that matters most. Before it transmits
a single byte, the **caller authenticates the worker** from the connected pipe handle
itself: the kernel-reported server process, a retained minimal-rights handle to that
process, exact high integrity, the current user's identity, the caller's session, the
canonical trusted PowerShell image, and the exact fixed task action with the protected
worker script — all revalidated immediately before the first request byte. Because the
handle pins the process object, a recycled process id cannot satisfy the check.

A worker accepts exactly one request, validates it strictly against a versioned schema with
a hard encoded-size ceiling, acknowledges acceptance **before** its first side effect, then
returns a correlated final frame and exits.

Caller-visible outcomes distinguish what actually happened: not transmitted, rejected,
accepted-then-uncertain, and completed. Only failures that occurred before transmission may
be retried. After uncertainty DevWS never repeats work automatically, because a duplicate
terminal or application launch is worse than a reported uncertainty.

**Boundary note.** The broker pipe admits any same-user medium-integrity process, and the
broker does not authenticate its clients beyond that operating-system admission. This is a
deliberate, documented boundary: it means a same-user process could interfere with the
user's own launch path. It is not a privilege boundary crossing — the interfering process
remains at the user's own integrity — and it is recorded in
[future-work.md](future-work.md).

## 9. Layout capture and all-or-nothing persistence

Capture is the operation that reads the real on-screen rectangles of the managed windows.

Capture workers publish one line per item:

```text
<id>|MISSING
<id>|INVALID|<x>|<y>|<w>|<h>
<id>|<x>|<y>|<w>|<h>
```

Persistence is **all-or-nothing**. `ws save-layout` and the geometry half of `ws save`
update the canonical configuration only after **every** enabled item has been captured
successfully. If any enabled item cannot be captured, or if the monitor topology changes
between the start and the end of the capture, nothing is written and the previous
configuration survives untouched.

Elevated capture writes its results into the administrator-protected state root rather than
into a user-writable location. Each capture is an exclusive, per-operation publication with
a high-integrity identity stamped by the writer; the user-integrity reader consumes only
its own completed operation, verifies the identity under a held handle, and never deletes
or repairs privileged artefacts.

`ws save` additionally persists the reliable tracked working directory and active tab of
each managed terminal, each resolved independently per configured tab. Unavailable
information is never invented: a tab whose working directory cannot be established keeps
its existing effective path. The whole save is one atomic canonical write preceded by a
final revalidation.

## 10. Trusted executable and package resolution

A high-integrity process must not launch an executable chosen by a user-writable value or
by a search path.

- **PowerShell** — resolved to an absolute `pwsh.exe` under the program-files roots or the
  system directory, with a minimum major version, optionally executed once to verify that
  it actually runs. Scheduled-task actions use that absolute path. There is no `PATH`
  lookup.
- **System tools** — resolved from the system directory, never from `PATH`.
- **Windows Terminal** — resolved through the operating system's package APIs by the
  official Microsoft package identity and publisher, then correlated with the protected
  package location and a non-reparse executable candidate immediately before every launch.
  A foreign or repackaged build is refused.

Resolution fails closed: if a trusted candidate cannot be established, the operation stops
before starting any process.

## 11. Fail-closed behaviour

The following are refused rather than approximated:

- an invalid or unrecognised configuration — never overwritten, never silently migrated by
  a normal command;
- a privileged runtime that is incomplete or in the wrong place;
- a protected state component with the wrong owner, a drifted access control list, an
  unexpected reparse point, or an unexpected object type;
- a profile-aware launch or reset on an unsafe or ambiguous monitor topology;
- an ambiguous application match;
- a trusted-executable or trusted-package candidate that cannot be validated;
- a working directory that does not exist, checked before the first creative or
  destructive step of a launch or reset.

In each case the operation stops before its first side effect and reports what is wrong and
what to do about it.

## 12. Native interop

A single generated .NET assembly carries the project's Win32 and Windows API interop. It is
compiled from the tracked C# sources in `src/native` at install time and loaded by the
calling component; repository execution compiles the same sources in-process.

The assembly provides: window existence and geometry, process-name lookup, restore and move,
exact-title lookup, application-window candidate enumeration, window ownership properties,
fast managed-terminal window enumeration, monitor topology observation, the secure
named-pipe primitives, privilege and package identity queries, and the pipe peer-identity
queries used by worker authentication.

Two design rules apply:

- **The assembly never contains policy.** It returns facts; matching, ownership and all
  lifecycle decisions stay in the PowerShell layer.
- **Loaded bytes are validated structurally.** The installer checks the compiled assembly
  for the complete required type and method surface before promoting it, and a failed
  generation leaves the previous installed runtime intact.

## 13. AutoHotkey's role

AutoHotkey v2 is a required runtime dependency, and its role is deliberately small:

- **Global hotkeys** — the persistent hotkey host, including generated per-set launch
  shortcuts. This is the main reason the dependency remains.
- **Exact-window focus** — activating an already-identified window.
- **Exact-window close** — the close/reset path, which must preserve Windows Terminal's
  multi-tab close-confirmation behaviour.

Everything else that used to involve an external helper — window existence, process name,
rectangle capture, restore, move and exact-title lookup — is now in-process in the native
assembly. The helper scripts are strictly descendant-free, and their output is captured in
memory rather than through temporary files.

Replacing AutoHotkey entirely is a recognised future option, not a committed plan; see
[future-work.md](future-work.md).

## 14. Scheduled tasks and privilege grants

Exactly five DevWS-managed scheduled tasks are created at install time:

| Task | Purpose |
| --- | --- |
| `DevWorkspace-ElevatedHelper` | Launch helper (the pre-barrier fallback path). |
| `DevWorkspace-ElevatedCapture` | Reads window geometry and tab state. |
| `DevWorkspace-ElevatedFocus` | Brings managed windows forward. |
| `DevWorkspace-ElevatedReset` | Closes and recreates managed terminals. |
| `DevWorkspace-ElevatedBroker` | Persistent broker; owns the terminal half of a launch. |

Each runs as the installing user, interactively, at the highest available run level, with a
single-instance policy, and with an action built from an absolute trusted PowerShell path
and a protected worker script. The broker additionally starts at logon, has no execution
time limit, is battery-safe and restarts on failure.

DevWS never reads, modifies or removes scheduled tasks it does not own. In particular an
external `AdminTerminal` task is left completely alone.

## 15. Security boundaries at a glance

| Boundary | Rule |
| --- | --- |
| User-writable configuration | **Input, not code.** DevWS executes what the configuration names, under the defined trust model described in [SECURITY.md](../SECURITY.md). Configuration is deliberately user-controlled. |
| User runtime | Disposable, user-writable, never authoritative for privileged decisions. |
| Privileged code | Only from the administrator-protected root; never from a user-writable copy. |
| Privileged state | Administrator-protected, validated on every authoritative read, never silently repaired. |
| Privileged transport | Authenticated in the direction that matters; strictly framed; acceptance precedes side effects. |
| Executables | Absolute and validated; never resolved through `PATH`. |
| Failures | Refused before the first side effect. |

This document describes behaviour, not a guarantee of fitness for any particular purpose.
Known limitations are listed in [future-work.md](future-work.md).
