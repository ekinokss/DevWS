# WinGet submission preparation (blocked)

This directory contains the historical three-file WinGet manifest for `ekinokss.DevWS`
version `0.2.0`, plus the finalization procedure. It is **not submitted** to
`microsoft/winget-pkgs`. No v0.3.0 WinGet manifest is prepared; do not adapt or submit this
template for the v0.3.0 release candidate.

**Current disposition: blocked. Do not submit this template for the v0.2.0 release.**
WinGet's unattended installation validation runs without elevation and rejects blocking UAC
prompts. DevWS requires same-account administrator elevation, and WinGet-managed elevation
would pre-elevate the process and lose the original caller identity. No WinGet catalog package
exists for DevWS.

## Current state

The committed manifest is a **preparation template**:

- `InstallerUrl` points at the expected final release:
  `https://github.com/ekinokss/DevWS/releases/download/v0.2.0/DevWS-Setup.exe`
- `InstallerSha256` is a zero placeholder and **must be replaced** with the final
  published executable hash before any future submission.
- `ReleaseDate` and `ReleaseNotesUrl` are intentionally omitted until publication.

Do not submit the template, and do not silently replace it with the
`v0.2.0-rc.1` pre-release binary. Any future package must reference an actually
published `v0.2.0` asset.

The files live under the same path shape expected by `microsoft/winget-pkgs`:

```text
packaging/winget/manifests/e/ekinokss/DevWS/0.2.0/
  ekinokss.DevWS.yaml
  ekinokss.DevWS.installer.yaml
  ekinokss.DevWS.locale.en-US.yaml
```

## Manifest characteristics

- `PackageIdentifier: ekinokss.DevWS`
- `PackageVersion: 0.2.0`
- `InstallerType: exe`
- `Architecture: x64`
- `Scope: user` (HKCU Add/Remove Programs registration)
- `ElevationRequirement: elevatesSelf` (the setup handles its own UAC request; WinGet must not pre-elevate it)
- `UpgradeBehavior: install` (in-place update/repair, downgrade refusal)
- `ProductCode: ekinokss.DevWS` (same value at installer and ARP correlation level)
- `DisplayName: DevWS`, `Publisher: ekinokss`
- No `AutoHotkey.AutoHotkey` package dependency
- No `InstallerSwitches` and no invented silent arguments
- Schema: WinGet manifest `1.12.0`

## Package correlation

The live ARP implementation is in:

- `packaging/bootstrapper/ProductIdentity.cs`
- `packaging/bootstrapper/PackageRegistration.cs`

The package writes a 64-bit **HKCU** uninstall key at:

```text
Software\Microsoft\Windows\CurrentVersion\Uninstall\ekinokss.DevWS
```

It records:

- `DisplayName: DevWS`
- `Publisher: ekinokss`
- `DisplayVersion: 0.2.0`
- `UninstallString` / `QuietUninstallString`: the protected persisted
  `DevWS-Setup.exe --uninstall`
- `NoModify=1`, `NoRepair=1`
- `DevWSSourceSha`

The manifest uses `ProductCode: ekinokss.DevWS` and `Scope: user` to match this
registration. No MSI product code or machine-wide ARP registration is invented.

## Elevation and caller identity

`ElevationRequirement: elevatesSelf` is intentional for the current security model. WinGet
must start the setup as the interactive caller, not pre-elevate it. The setup captures the
caller SID, requests `runas` itself, and `UserIdentity.RequireSameElevatedSid()` requires the
elevated process to have the same SID. If UAC selects a different administrator account, the
elevated process rejects the operation and nothing is changed.

Do not change this to `elevationRequired`: pre-elevation would hide the original caller
identity and bypass DevWS's cross-account protection. The WinGet 1.12.0 schema defines
`elevatesSelf` for installers that contain their own elevation logic and says WinGet will not
elevate the installer itself.

That same behavior is why the template is blocked. WinGet validates installation from a
standard, non-elevated context and treats a UAC prompt that blocks progress as a failure. The
setup's own `runas` request is exactly such a prompt. `elevationRequired` is not an acceptable
workaround because WinGet would initiate the elevation without DevWS's `--caller-sid`
handshake; a standard user who supplies a different administrator account would install for
that administrator.

## Validation reference

The published pre-release is suitable for local manifest schema validation, but it is not
the final package and schema success is not WinGet acceptance:

- URL: `https://github.com/ekinokss/DevWS/releases/download/v0.2.0-rc.1/DevWS-Setup.exe`
- SHA-256: `0ddd867691c21be57d98693bfef42d13672db485e36f493d78ceab8558a691f7`

Create a temporary copy outside the repository, replace the URL and placeholder
hash, then validate:

```powershell
$source = 'packaging\winget\manifests\e\ekinokss\DevWS\0.2.0'
$test = Join-Path $env:TEMP ('devws-winget-test-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $test -Force | Out-Null
Copy-Item -Path (Join-Path $source '*.yaml') -Destination $test
$installer = Join-Path $test 'ekinokss.DevWS.installer.yaml'
$text = Get-Content -LiteralPath $installer -Raw
$text = $text.Replace(
  'https://github.com/ekinokss/DevWS/releases/download/v0.2.0/DevWS-Setup.exe',
  'https://github.com/ekinokss/DevWS/releases/download/v0.2.0-rc.1/DevWS-Setup.exe')
$text = $text.Replace(
  '0000000000000000000000000000000000000000000000000000000000000000',
  '0ddd867691c21be57d98693bfef42d13672db485e36f493d78ceab8558a691f7')
[IO.File]::WriteAllText($installer, $text, [Text.UTF8Encoding]::new($false))

winget validate --manifest $test
winget show --manifest $test
```

The temporary copy is for validation only and must not be committed as the final
manifest.

## Final publication values

These values are retained for a future submission only after the elevation model can satisfy
WinGet's unattended validation without losing caller identity. **Do not apply them to the
v0.2.0 release.**

| Value | Required action |
| --- | --- |
| Final GitHub Release URL | Verify `.../releases/download/v0.2.0/DevWS-Setup.exe` |
| Final executable SHA-256 | Replace the zero placeholder |
| Actual release date | Add `ReleaseDate` if useful |
| Final release notes URL | Add `ReleaseNotesUrl` if useful |
| Publisher/signature metadata | No manifest change for Authenticode; `Publisher` remains the ARP publisher `ekinokss`. Do not add a signing-service dependency. |

Do not add `AutoHotkey.AutoHotkey` as a dependency. The setup acquires the
machine-wide prerequisite itself.

## Validation status

Local validation on 2026-10-27:

- `winget validate --manifest` on the committed template: **succeeded with warnings**.
- `winget validate --manifest` on the temporary RC reference copy: **succeeded with warnings**.
- `winget show --manifest` on the RC reference: identified `ekinokss.DevWS` 0.2.0,
  `InstallerType: exe`, the RC URL, and the real RC SHA-256.
- The published RC installer was downloaded separately and its SHA-256 matched
  `0ddd8676…`.

The only schema warning is the missing explicit silent switch. Schema validation does not
exercise installation, elevation, or WinGet's automated validation pipeline.

## Silent-install policy

The community repository expects the installer to complete without user interaction. After
elevation, the DevWS setup has no application-level prompts, but the required Windows UAC
prompt is itself blocking interaction. The validator therefore warns:

```text
Silent and SilentWithProgress switches are not specified for InstallerType exe.
Please make sure the installer can run unattended.
```

Do not add a fake `/silent` switch to silence this warning. A switch cannot suppress UAC,
cannot grant administrator rights, and would not resolve the documented unattended-installation
conflict. The template remains blocked until the installation model changes.

## Submission disposition

**Do not fork `microsoft/winget-pkgs` or open a submission PR for v0.2.0.**

The following steps apply only if a future, separately authorized installer design can
complete WinGet validation without losing the caller-SID guarantee:

1. Publish the applicable GitHub release asset.
2. Update the manifest with the final URL, final SHA-256, and any release date/notes values.
3. Run `winget validate --manifest` and `winget show --manifest` on the complete directory.
4. Run a targeted integration test, including the outer WinGet → DevWS → nested AutoHotkey
   acquisition path. The prior attempt was interrupted by SmartScreen before DevWS executed,
   so that flow is unproven and must not be claimed as passed.
5. Fork `microsoft/winget-pkgs` and submit only the three manifest files under
   `manifests/e/ekinokss/DevWS/0.2.0`.
6. Monitor Microsoft's automated validation and address labels/errors.
7. After catalog acceptance, test ID-based install/uninstall and configuration preservation.

No fork, PR, release, tag, or WinGet submission was created in this preparation.
