# Changelog

All notable changes to DevWS are recorded here.

This project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) conventions and
uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [0.3.0] - 2026-10-30

### Added

- **Monitor-relative layouts** — schema-v3 items may set `layoutMode: "relative"` and
  `layoutRelative` with a durable monitor identity (`edid:` or `path:`), an optional instance
  tie-breaker, a `workArea` or `monitor` basis, and nontrivial normalized `x`/`y`/`w`/`h`
  fractions. Exact topology profiles still win; otherwise a relative item resolves its anchor
  and falls back to the mandatory absolute `item.layout` when the anchor is absent or
  unreachable. `ws set-geometry --relative`, `ws show-layout`, fallback-scope save, targeted
  reset and clone operations preserve the relative intent. The schema version remains 3.
- **Terminal presence observability** — structured UI Automation reads retain the raw tab
  element count (including duplicate names), report per-tab name-read failures, and distinguish
  missing, inaccessible, ambiguous and failed observations. A present-but-inaccessible window
  is no longer treated as missing, and an inconclusive observation does not trigger a duplicate
  creation kick. `ws status` and launch planning expose the source, diagnostic and counts.
- **Native terminal method-surface validation** — generated native assemblies must expose
  `DevWSTerminalNative.IsWindowsTerminalTopLevelHwnd(long)`. Installer candidate validation and
  installed-runtime loading fail closed with `install.ps1` guidance when an older or partial
  assembly is present.

### Changed

- **Presence source reporting** — state, snapshot and UIA associations carry their actual source
  and structured diagnostics; an empty successful UIA read remains distinct from an access
  failure.
- **Configuration compatibility** — relative layout fields are additive to schema version 3.
  Existing absolute configurations remain valid without migration. v0.2 binaries treat the new
  fields as opaque and can drop or ignore relative intent on clone or save; relative semantics
  are not downgrade-safe.

### Fixed

- The presence model now distinguishes an inaccessible elevated Windows Terminal from a missing
  window; `ws status` reports `inaccessible` and the launch plan does not create a duplicate
  window when observation is inconclusive.
- A failed per-tab `Current.Name` getter is counted as an incomplete read instead of being
  silently converted to an empty name.

### Notes

- This is a v0.3.0 release candidate prepared from the approved terminal-presence reliability
  fix. It is not tagged or published. The stable binary remains v0.2.0.
- Guest upgrade/repair/uninstall acceptance, live Medium/High terminal observation and the
  hardware scenarios RH-03 (mixed scaling) and RH-05 (primary-monitor change) remain release
  gates. Path identities are validated; physical EDID behavior is not claimed.
- Windows 11 x64 only; unsigned; same-account administrator elevation required. No WinGet
  catalog package, MSI/MSIX identity, self-update or attestation is available.

## [0.2.0] - 2026-10-27

### Added

- **Package-mode installer contract** — `install.ps1 -PackageMode` performs the ordinary
  non-interactive install/update path for a future package/bootstrap layer, while
  `uninstall.ps1 -PackageMode` performs the ordinary default uninstall non-interactively and
  preserves configuration and state. Package mode does not self-elevate, never resets or
  purges, and rejects destructive or alternate-mode combinations before mutation. The setup
  executable is distributed as the `v0.2.0-rc.1` pre-release and the published stable
  `v0.2.0` GitHub release; no WinGet catalog package exists.
- **Package-mode AutoHotkey acquisition** — `install.ps1 -PackageMode` now reuses an existing
  trusted machine-wide AutoHotkey v2 installation or acquires one through the registered
  WinGet/App Installer package with an explicit machine scope and protected machine install
  directory. The installed result is revalidated by the existing trusted resolver before any
  DevWS change. User-scope AutoHotkey is neither used nor removed, and DevWS uninstall
  continues to leave AutoHotkey installed. Source-mode installation keeps its
  manual-prerequisite behavior.
- **Thin setup bootstrapper source** — a Native AOT Windows x64 bootstrapper under
  `packaging/` that resolves trusted PowerShell, requests elevation, stages the embedded
  DevWS source payload in protected ProgramData storage, extracts it safely and invokes
  `install.ps1 -PackageMode`. The unsigned `v0.2.0-rc.1` setup pre-release is public. A
  WinGet submission template is prepared but is not submitted; WinGet's unattended validation
  cannot accept the installer's same-account UAC prompt.
- **Windows package lifecycle source** — per-user `ekinokss.DevWS` ARP registration, a
  protected SID-qualified persisted setup executable, numeric version policy (fresh,
  same-version repair, upgrade and downgrade refusal), setup-driven package uninstall, and
  protected post-exit self-removal. The existing PowerShell install/uninstall engines and
  user-data preservation semantics are unchanged.
- **Release-candidate artifact pipeline** — commit-bound setup builds produce a
  four-file candidate (`DevWS-Setup.exe`, `LICENSE`, `provenance.json`, `SHA256SUMS.txt`) with
  independent verification and privacy/path checks. Manual bootstrapper runs retain the
  verified candidate as a 30-day GitHub Actions artifact and re-verify the downloaded copy.
  The unsigned `v0.2.0-rc.1` pre-release was produced from this pipeline. The stable unsigned
  `v0.2.0` GitHub release was published from the same pipeline on 2026-10-27; no attestation
  or WinGet catalog package is published.

### Distribution

- The stable release is an unsigned Windows 11 x64 GitHub release, published on 2026-10-27 at
  https://github.com/ekinokss/DevWS/releases/tag/v0.2.0. The executable is not
  Authenticode-signed and may trigger Microsoft Defender SmartScreen.
- Installation requires administrator elevation under the same Windows account that starts
  setup. UAC elevation using a different administrator account is intentionally rejected.
- Download only from official GitHub Releases and verify the published SHA-256.
- A first-party Scoop bucket is available at https://github.com/ekinokss/scoop-bucket. It is
  distinct from the `ScoopInstaller/Nonportable` community bucket and requires an elevated
  Scoop session under the same Windows account.
- AutoHotkey v2 is acquired machine-wide through WinGet when a trusted all-users installation
  is absent; this requires network connectivity and the documented prerequisites.
- No WinGet catalog package is currently available. The prepared WinGet template is blocked by
  the installer's same-account elevation requirement and must not be submitted as-is.

## [0.1.0] - 2026-10-21

### Added

- **Workspace sets** — independent, named workspace definitions with a configured default and
  set-qualified commands, so several complete environments can coexist without a hidden
  "active set".
- **Managed terminals** — Windows Terminal windows and tabs created from configuration, with
  per-tab working directories and startup commands, and a durable named-window identity used
  for matching and adoption of live windows.
- **Managed applications** — executable and AppsFolder launches with explicit `dedicated` or
  `shared` instance modes, saved geometry, and refusal of ambiguous matches.
- **Layout and topology** — all-or-nothing layout capture, deterministic restore, optional
  per-monitor-topology layout profiles, and a universal fallback layout.
- **Live-state saving** — geometry plus the reliable tracked working directory and active tab
  of each managed terminal.
- **Global hotkeys** — a managed AutoHotkey v2 Startup host, one built-in `Alt+Shift+T`
  shortcut, and generated per-set launch bindings. `Alt+T` is ordinary binding space.
- **Read-only inspection** — `ws list`, `ws status`, `ws show-layout`, `ws monitors`,
  `ws detect-app`, `ws doctor` and `ws health`.
- **Privileged operations without per-command UAC** — a small set of pre-authorised scheduled
  tasks and a persistent broker, with the privileged runtime separated from the user-writable
  CLI and configuration.
- **Installer lifecycle** — install, idempotent update, stale-interpreter task repair,
  health/doctor, default uninstall, reinstall and purge uninstall.
- **Hermetic test suite and permanent hosted CI** — a canonical suite with explicit case
  accounting, a strict zero-skip local gate, and a pinned, hash-verified AutoHotkey
  provisioning step for hosted Windows.

### Security

- Administrator-protected privileged runtime and privileged state, with protected access
  control, owner validation and reparse-point refusal.
- Authenticated short-lived worker transport: the caller validates the connected worker's
  kernel-reported process identity, image, user, session, integrity and exact task action
  before transmitting anything.
- Absolute trusted executable resolution for privileged PowerShell and machine-wide
  AutoHotkey; no `PATH`, alias or user-writable lookup.
- Fail-closed handling for ambiguous configuration, unsafe topologies, untrusted candidates
  and unvalidated protected-state components.

### Changed

- The bundled configuration is a neutral starter: one empty set, no bindings and no geometry.
  A fresh installation does not impose a personal workspace.
- A valid canonical configuration is preserved byte-for-byte on install and update. Supported
  older configurations are migrated only with a backup, and invalid or unrecognised
  configurations are left untouched.
- Test results report six mutually exclusive outcomes and enforce both accounting partitions.
  The strict release run treats any runtime skip as incomplete coverage.
- Hosted CI accepts only the named linked-Medium protected-state integration skip that the
  hosted token model cannot exercise; the strict local gate requires that case to execute.

### Notes

- DevWS is Windows-only and distributed as source. There is no MSI, MSIX, setup executable,
  package-manager package or committed binary bundle.
- The generated native assembly is compiled at installation time. Its bytes are not
  guaranteed to be reproducible, so DevWS does not publish or promise a binary digest.
- Historical v1 configuration migration is not supported by the public product. A v1 document
  is refused without modifying either the v1 file or the canonical configuration.
- The disposable installer-lifecycle acceptance covered clean install, 25/25 installed health,
  genuine linked-Medium protected-state validation, the exact five-task topology, idempotent
  update, real `-RepairTasks`, default uninstall, reinstall and purge. The optional
  real-window lifecycle smoke was not observed and is not claimed as passed.
