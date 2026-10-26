# Code signing policy

**Current status: unsigned.** DevWS releases are not currently Authenticode-signed by SignPath or any other certificate authority. This policy describes the intended signing controls if the project is accepted into the SignPath Foundation program. It does not claim that a signature currently exists.

Free code signing provided by [SignPath.io](https://about.signpath.io), certificate by [SignPath Foundation](https://signpath.org).

## Project and source

- Project: **DevWS**
- Source repository: https://github.com/ekinokss/DevWS
- Public pre-release: https://github.com/ekinokss/DevWS/releases/tag/v0.2.0-rc.1
- License: [MIT](LICENSE)
- Platform: Windows 11 x64

DevWS is an open-source, configuration-driven workspace orchestrator for Windows. Release binaries are built from this public repository and its committed build scripts.

## Team roles

- **Authors/committers:** [ekinokss](https://github.com/ekinokss) — repository owner and currently documented maintainer.
- **Reviewers:** [ekinokss](https://github.com/ekinokss) — external contributions are reviewed by a maintainer before merge.
- **Approvers:** [ekinokss](https://github.com/ekinokss) — each signing request must be approved by the maintainer responsible for the release.

No other maintainers are currently documented in the repository. Multi-factor authentication is required for GitHub and SignPath access.

## Intended signing controls

- Signing requests are approved manually for each release.
- The signed artifact is the Windows x64 setup executable produced from the public DevWS repository by the committed GitHub Actions workflow on GitHub-hosted runners.
- SignPath origin verification must bind the artifact to the repository, branch, and exact source commit used for the release.
- The final signed executable is hashed, and `provenance.json` and `SHA256SUMS.txt` are generated after signing. The published installer hash must match the signed bytes.
- Only the exact verified bundle is published. Release assets are not replaced under an existing tag.
- No proprietary components are included. AutoHotkey v2 is an external prerequisite that the packaged setup may acquire through WinGet at install time; it is not bundled or signed by this project.

## Release verification

Every public release publishes `DevWS-Setup.exe`, `LICENSE`, `provenance.json`, and `SHA256SUMS.txt`. Verify the published SHA-256 before running the installer. The current unsigned pre-release may trigger Microsoft Defender SmartScreen; signing is intended to improve publisher identity but will not instantly establish SmartScreen reputation.

## Privacy

See [PRIVACY.md](PRIVACY.md) for the project privacy information.

## Reporting a problem

Report security or signing concerns through the project issue tracker: https://github.com/ekinokss/DevWS/issues
