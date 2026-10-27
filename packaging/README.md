# DevWS Setup Bootstrapper and Release Candidate

This directory contains the source for the Windows x64 setup lifecycle used to build the
public `v0.2.0-rc.1` pre-release and the published stable unsigned `v0.2.0` GitHub release.
The setup executable is published only through official GitHub Releases, not from this
directory.

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

There is no MSI/MSIX, no Windows Installer product code, no service or scheduled task owned by
the setup itself, no self-update, and no WinGet catalog package. A WinGet submission template
exists under `packaging/winget`, but it is blocked by WinGet's unattended-elevation validation
and is not submitted. Package-mode setup can acquire the machine-wide AutoHotkey v2
prerequisite through the registered WinGet package.

## AutoHotkey prerequisite acquisition

Package mode (`install.ps1 -PackageMode`, used by `DevWS-Setup.exe`) first reuses a
machine-wide AutoHotkey v2 installation that passes the existing trusted resolver. If none
exists, it resolves the registered official Microsoft App Installer package, runs
`winget.exe` directly from the protected WindowsApps package directory, and requests
`AutoHotkey.AutoHotkey --scope machine`. It also passes the protected machine directory with
`/installto` through WinGet's `--custom` switch: AutoHotkey Setup would otherwise follow an
existing per-user registration even when elevated. WinGet verifies the AutoHotkey installer
hash before execution. The existing resolver is then run again before any DevWS mutation.

A current-user-only AutoHotkey installation is never used as elevated executable authority
and is never removed. DevWS uninstall never uninstalls AutoHotkey because it may be shared by
other applications. A future WinGet manifest must not declare `AutoHotkey.AutoHotkey` as a
package dependency: that dependency can install a per-user copy, while the setup itself is
responsible for the machine-wide prerequisite.

## Requirements

- Windows x64 build host
- .NET 10 SDK
- Visual C++ build tools required by Native AOT
- PowerShell 7 on the target machine (machine-wide Program Files or official Microsoft
  PowerShell MSIX)
- WinGet/App Installer on the target machine only when AutoHotkey v2 must be acquired
  machine-wide; an existing trusted machine-wide installation avoids WinGet. WinGet is not
  currently a distribution channel for DevWS itself.
- AutoHotkey v2 for all users on the target machine (acquired by package mode when absent)

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
create a WinGet submission, or attach anything to a GitHub Release.

For a local toolchain outside `PATH`:

```powershell
pwsh -NoLogo -NoProfile -File packaging\build-setup.ps1 -DotNetPath C:\path\to\dotnet.exe
```

## Release-candidate bundle

The release candidate is assembled by wrapping the accepted setup build, not by rebuilding
the payload independently:

```powershell
pwsh -NoLogo -NoProfile -File packaging\build-release.ps1 -OutputDir C:\path\outside\repo
pwsh -NoLogo -NoProfile -File packaging\verify-release.ps1 -BundleDir C:\path\outside\repo -ExpectedSourceSha <sha>
```

The bundle contains exactly:

```text
DevWS-Setup.exe
LICENSE
provenance.json
SHA256SUMS.txt
```

`provenance.json` records the canonical product identity/version, x64/`win-x64`, source
repository, exact source commit, EXE size/SHA-256, and SDK/toolchain values. It contains no
machine/user path or timestamp. `SHA256SUMS.txt` covers exactly the EXE, LICENSE and
provenance file, in that order.

The bundled `LICENSE` is read from the exact `HEAD` Git blob with `git cat-file`, not copied
from the materialized checkout. `verify-release.ps1` compares the bundle bytes with the
`LICENSE` blob at the expected source commit, so checkout EOL settings cannot change release
source bytes.

The verified bundle is retained only as a GitHub Actions artifact on a manually dispatched
run of the bootstrapper workflow. Ordinary feature-branch pushes run the fixture lifecycle
only and do not upload a production candidate. No GitHub Release, tag, WinGet submission,
attestation or binary publication is produced by this pipeline.

The candidate is unsigned by default; Authenticode status is reported by the verifier and
must not be treated as signed. Native AOT output is not claimed to be byte-reproducible.

The setup executable metadata is asserted during the build and release verification:
`ProductName=DevWS`, `CompanyName=ekinokss`, and `FileDescription=DevWS setup`. The
executable filename remains `DevWS-Setup.exe`.

### Optional signed finalization

Signing is optional and is not configured in the current workflow. The same finalizer accepts
an already-built executable, so a future signing service can be inserted without changing the
provenance or checksum contract:

```powershell
# Build the unsigned executable (or obtain it from the external signing service).
pwsh -NoLogo -NoProfile -File packaging\build-setup.ps1 -OutputDir C:\path\outside\repo\unsigned

# Sign C:\path\outside\repo\unsigned\DevWS-Setup.exe externally, then finalize only:
pwsh -NoLogo -NoProfile -File packaging\build-release.ps1 `
  -SetupPath C:\path\outside\repo\signed\DevWS-Setup.exe `
  -RequireSignature `
  -OutputDir C:\path\outside\repo\bundle
```

With `-RequireSignature`, `verify-release.ps1` requires a valid Authenticode signature before
the bundle is accepted. `-ExpectedSignerSubject` can additionally pin the signer subject.
Without `-RequireSignature`, the existing unsigned release construction is unchanged.

The finalizer hashes and writes `provenance.json`/`SHA256SUMS.txt` from the exact executable
bytes it receives. Do not sign, modify, or replace the executable after finalization. The
source-commit check still requires the executable's embedded source SHA to match the committed
`HEAD`, and the canonical four-file bundle and committed LICENSE bytes are preserved.

## WinGet submission preparation

The prepared three-file package manifest and the finalization/submission checklist are in
[`winget/README.md`](winget/README.md). The committed manifest is a template: the final
`v0.2.0` asset URL is expected, while the installer hash and release metadata must be
updated after publication. The public `v0.2.0-rc.1` binary is used only as a local
validation reference, not as the final package.

**The template is not submitted and is not ready for submission.** WinGet's unattended
validation runs the installer without elevation and rejects blocking UAC prompts. DevWS
requires same-account administrator elevation, and WinGet-managed elevation would bypass the
caller-SID check by pre-elevating the process. No WinGet catalog package exists for DevWS.

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
- Supports install, same-version reinstall/repair, upgrade, downgrade refusal, HKCU
  Add/Remove Programs registration, and setup-driven package uninstall with user-data
  preservation.
- No self-update.
- Package-mode setup may acquire AutoHotkey v2 for all users through the registered WinGet
  package. It never uses or removes a current-user-only AutoHotkey installation.
- No MSI/MSIX or Windows Installer product codes, and no WinGet catalog package. The unsigned
  `v0.2.0-rc.1` setup pre-release and the stable `v0.2.0` GitHub release are public.
- The release-candidate Actions artifact is retained for verification. The stable `v0.2.0`
  release is the current published binary; the `v0.2.0-rc.1` pre-release remains available.

## Security boundaries

- Elevation is requested by relaunching the same absolute executable with the fixed
  `--elevated` internal argument. User arguments are not forwarded.
- PowerShell is never resolved through `PATH`. The accepted candidates are exactly the
  machine-wide `%ProgramFiles%\PowerShell\7\pwsh.exe` and the official
  `Microsoft.PowerShell_8wekyb3d8bbwe` MSIX package under `Program Files\WindowsApps`.
- Candidates must be non-reparse normal files with PowerShell major version >= 7 and must
  pass a runtime smoke check with the same absolute executable.
- Payload staging is created under `%ProgramData%\DevWS\setup-staging\<run-guid>`. The
  shared `%ProgramData%\DevWS` base follows the installer's canonical protected-state base
  ACL (SYSTEM/Administrators full control and BUILTIN\Users read/execute only); the
  `setup-staging` subtree and each run directory remain restricted to SYSTEM and
  Administrators. Existing insecure ancestors fail closed without automatic repair.
- Archive entries are validated before extraction for traversal, drive/UNC paths,
  duplicate normalized targets, file/directory conflicts and reparse/symlink semantics.
- Cleanup never follows reparse points and leaves a cleanup warning without converting a
  successful installation into a failed one.
