# WinGet submission preparation

This directory contains the three-file WinGet manifest for `ekinokss.DevWS` version
`0.2.0`, plus the finalization procedure. It is **not submitted** to
`microsoft/winget-pkgs`.

## Current state

The committed manifest is a **preparation template**:

- `InstallerUrl` points at the expected final release:
  `https://github.com/ekinokss/DevWS/releases/download/v0.2.0/DevWS-Setup.exe`
- `InstallerSha256` is a zero placeholder and **must be replaced** with the final
  published executable hash before submission.
- `ReleaseDate` and `ReleaseNotesUrl` are intentionally omitted until publication.

Do not submit the template, and do not silently replace it with the
`v0.2.0-rc.1` pre-release binary. The final package must reference the actual
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
- `ElevationRequirement: elevationRequired` (protected runtime and scheduled tasks)
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

The earlier local-manifest experiment showed that ID-based uninstall may not
correlate until the package is in the catalog; name-based uninstall worked. Do not
re-investigate that local-manifest limitation here. Verify ID-based install and
uninstall after catalog acceptance.

## Validation reference

The published pre-release is suitable for local manifest validation, but it is not
the final package:

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

Replace or add these values when the final `v0.2.0` release exists:

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
- Only the silent-switch warning below remains.

## Silent-install policy

The community repository expects the installer to complete without
application-level user interaction. The DevWS setup already has a no-argument,
non-interactive install path after OS elevation; it has no application prompts.
It does not expose a `/silent` switch.

`winget validate` therefore warns:

```text
Silent and SilentWithProgress switches are not specified for InstallerType exe.
Please make sure the installer can run unattended.
```

Do not add a fake switch. If repository validation or review requires an explicit
silent argument, the smallest future correction is to add a harmless `/silent`
accepted by the bootstrapper in a separate authorized product change. That change
is not part of this preparation.

## Submission checklist

1. **Publish the final `v0.2.0` release asset** using the approved signed or
   unsigned release pipeline.
2. **Update the manifest** with the final URL, final SHA-256, and any release
   date/notes values.
3. **Validate:** run `winget validate --manifest` on the complete directory and
   `winget show --manifest` to confirm identity, scope, elevation, and hash.
4. **Run one targeted final integration test** with the final asset. The outer
   WinGet → DevWS → nested AutoHotkey acquisition flow is still unproven because
   the previous attempt was interrupted by SmartScreen before DevWS executed. Do
   not claim it passed.
5. **Fork `microsoft/winget-pkgs` and create a PR** containing only the three
   manifest files under `manifests/e/ekinokss/DevWS/0.2.0`. Do not include this
   README or any non-manifest file.
6. **Monitor Microsoft's automated validation** and address labels/errors.
   The known silent-switch warning may require maintainer confirmation or a
   future explicit switch.
7. **After catalog acceptance**, test `winget install ekinokss.DevWS` and
   `winget uninstall ekinokss.DevWS` using the catalog package, including
   ID-based correlation and configuration preservation.

No fork, PR, release, tag, or WinGet submission was created in this preparation.
