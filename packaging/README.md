# DevWS Setup Bootstrapper (Phase 3 source)

This directory contains the **unreleased** source for the Windows x64 setup lifecycle. It is
not a published DevWS release artifact.

The bootstrapper embeds the tracked DevWS installation payload and invokes the accepted
Phase-1 contracts:

```text
pwsh -NoLogo -NoProfile -NonInteractive -File <protected staging>\install.ps1 -PackageMode
pwsh -NoLogo -NoProfile -NonInteractive -File <protected staging>\uninstall.ps1 -PackageMode
```

It does not implement installation semantics. Configuration migration, privileged runtime
staging, scheduled tasks, PATH, hotkeys, native runtime generation, health checking and
rollback remain owned by the existing PowerShell installer.

## Package identity and lifecycle

| Property | Value |
| --- | --- |
| Product ID / ARP key | `ekinokss.DevWS` |
| Display name | `DevWS` |
| Publisher | `ekinokss` |
| Current source version | `0.2.0` |
| ARP hive/view | `HKCU` 64-bit uninstall view |
| Persisted setup | `%ProgramFiles%\DevWS\setup\<current-user-SID>\DevWS-Setup.exe` |

The product identity and version are source-controlled in `product.json` and embedded into
the executable at build time. The PowerShell runtime and configuration remain per-user;
HKLM is not used for this package identity.

Running the setup without arguments installs, upgrades, or idempotently reinstalls/repairs
the same version. A newer installed version causes a downgrade refusal before
`install.ps1` is invoked. `--uninstall` runs the ordinary default package-mode uninstall,
preserves user configuration/state and removes the ARP registration. The persisted setup is
administrator-owned, grants the target user read/execute only, and is atomically replaced
after a successful installer run.

Post-exit self-removal uses a short-lived protected-stage PowerShell helper; it derives the
exact per-SID lifecycle path from fixed roots, waits for the setup parent to exit, refuses
reparse paths, removes only the lifecycle directory and staging, and does not require a
reboot. Registry values are discovery/ARP state only and are never used as execution
authority.

There is no MSI/MSIX, no Windows Installer product code, no service, no scheduled task, no
self-update, no network acquisition, and no WinGet package in this phase.

## Requirements

- Windows x64 build host
- .NET 10 SDK
- Visual C++ build tools required by Native AOT
- PowerShell 7 on the target machine (machine-wide Program Files or official Microsoft
  PowerShell MSIX)

The generated executable is Native AOT and self-contained. It requires no separately
installed .NET runtime.

## Build

From the repository root:

```powershell
pwsh -NoLogo -NoProfile -File packaging\build-setup.ps1
```

The production build requires a clean committed worktree and derives the payload from
`git archive HEAD` for exactly:

```text
install.ps1
uninstall.ps1
LICENSE
src/**
config/**
```

Generated output is written outside the repository by default. The script prints the source
commit, SDK version, artifact path, size and SHA-256. It does not publish the artifact,
create a WinGet manifest, or attach anything to a GitHub Release.

For a local toolchain outside `PATH`:

```powershell
pwsh -NoLogo -NoProfile -File packaging\build-setup.ps1 -DotNetPath C:\path\to\dotnet.exe
```

## Fixture acceptance

Run from an elevated PowerShell 7 (the fixture exercises the real protected staging and
per-user package lifecycle paths, under build-time-only fixture identities):

```powershell
pwsh -NoLogo -NoProfile -File packaging\test-bootstrapper.ps1
```

The test builds disposable Native AOT executables for fixture versions `0.2.0` and `0.2.1`.
It proves fresh install, same-version reinstall, upgrade, downgrade refusal, install and
uninstall failure preservation, ARP registration, protected SID-qualified setup persistence,
ACL semantics, successful self-removing uninstall, user-data preservation and final residue
cleanup. It also runs the pure archive/trust/version/ARP checks. It never invokes the real
DevWS installer or touches the production `ekinokss.DevWS` registration/lifecycle paths.

## Current scope

- Windows x64 only; x86 and ARM64 are not supported.
- No setup uninstall, repair, upgrade, Add/Remove Programs registration, product codes,
  version comparison or self-update.
- No network acquisition.
- No prerequisite installation.
- No published EXE or WinGet package.
- The public `v0.1.0` source-only distribution statement remains true until an artifact is
  actually published.

## Security boundaries

- Elevation is requested by relaunching the same absolute executable with the fixed
  `--elevated` internal argument. User arguments are not forwarded.
- PowerShell is never resolved through `PATH`. The accepted candidates are exactly the
  machine-wide `%ProgramFiles%\PowerShell\7\pwsh.exe` and the official
  `Microsoft.PowerShell_8wekyb3d8bbwe` MSIX package under `Program Files\WindowsApps`.
- Candidates must be non-reparse normal files with PowerShell major version >= 7 and must
  pass a runtime smoke check with the same absolute executable.
- Payload staging is created under `%ProgramData%\DevWS\setup-staging\<run-guid>` with a
  protected ACL applied at directory creation. Existing insecure ancestors fail closed.
- Archive entries are validated before extraction for traversal, drive/UNC paths,
  duplicate normalized targets, file/directory conflicts and reparse/symlink semantics.
- Cleanup never follows reparse points and leaves a cleanup warning without converting a
  successful installation into a failed one.
