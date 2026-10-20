# Contributing to DevWS

Thanks for taking a look. DevWS is a Windows-only PowerShell project with a small,
deliberately structured codebase and a large hermetic test suite.

This document covers what you need to build, test and change it safely. For what the
product *does*, start with [README.md](README.md).

---

## 1. Development environment

| Requirement | Notes |
| --- | --- |
| **Windows** | DevWS drives Windows Terminal, the scheduled-task service, Win32 window management and Windows integrity levels. There is no cross-platform build. |
| **PowerShell 7+** | Required. The CLI and the test suite both require PowerShell 7; Windows PowerShell 5.1 is not supported. |
| **An elevated shell for the full test suite** | The suite creates its protected-state fixtures through the production initializer, which expects an elevated session. It does not detect and skip on a non-elevated session, so run the suite from an **Administrator** PowerShell. |
| **Windows Terminal and AutoHotkey v2** *(optional locally)* | A few tests exercise the real Windows Terminal package resolution and the real AutoHotkey host. When they are unavailable locally, the affected cases skip visibly rather than passing silently. Hosted CI provisions a pinned portable AutoHotkey so that case executes there. |

You do **not** need to install DevWS to work on it.

A clean `-RequireFullCoverage` run needs both a genuine packaged **stable** Windows Terminal
and an all-users AutoHotkey v2 installation. The repository-layout `DEVWS_AHK_PATH` override
is a development/hosted-CI convenience only; installed High-integrity processes ignore it.

## 2. Repository layout

```text
src/
  ws.ps1              CLI entry point and dispatcher
  coordinator/        persistent user-integrity host
  lib/                runtime libraries (the bulk of the implementation)
  native/             C# interop sources compiled into the native assembly
  workers/            privileged workers and the persistent broker
  helpers/            AutoHotkey helpers and the tracked-shell bootstrap
  hotkeys/            the managed Startup hotkey script
  shim/               the generated command shim template
config/
  workspace.default.json   the bundled neutral starter configuration
tests/
  run-tests.ps1            the complete hermetic test suite
  fixtures/                shared test fixtures
  probe-ci-environment.ps1 read-only environment probe
install.ps1 / uninstall.ps1
docs/
```

Libraries in `src/lib` are dot-sourced in a fixed order by `src/ws.ps1`. Dependency order
matters: a library may only assume that the libraries before it are already loaded.

## 3. Running the CLI from a checkout

The CLI resolves the repository layout from its own location, so you can run it directly:

```powershell
pwsh -NoLogo -NoProfile -File .\src\ws.ps1 list
pwsh -NoLogo -NoProfile -File .\src\ws.ps1 help all
```

Point it at a scratch configuration instead of your real one:

```powershell
$env:DEVWS_CONFIG = "$env:TEMP\devws-scratch.json"
pwsh -NoLogo -NoProfile -File .\src\ws.ps1 list
```

Development path overrides are honoured **only** in a repository checkout. Installed
high-integrity processes ignore them deliberately.

## 4. Running the tests

```powershell
# the canonical full run
pwsh -NoLogo -NoProfile -File .\tests\run-tests.ps1

# list the deterministic group catalogue
pwsh -NoLogo -NoProfile -File .\tests\run-tests.ps1 -ListGroups

# run selected groups (execution order always follows the catalogue)
pwsh -NoLogo -NoProfile -File .\tests\run-tests.ps1 -Group configuration,lifecycle

# release gate: treat any runtime skip as a coverage failure
pwsh -NoLogo -NoProfile -File .\tests\run-tests.ps1 -RequireFullCoverage
```

The suite is **hermetic by construction**. It installs process-local fakes for the
privileged-broker client surface, so ordinary tests never contact the live broker, its task
or its mutex. It writes only into a temporary test root and restores the environment
afterwards. It must never touch your real installation, configuration or installed tasks.

Documentation-only changes still run the canonical suite; the public documentation set,
cross-document links and source-referenced document paths are covered by it.

The suite is expected to run in an elevated PowerShell. It creates its protected-state
fixtures through the production initializer and asserts the elevated token path.

### Hosted CI

`.github/workflows/ci.yml` is the permanent gate. It runs on GitHub-hosted `windows-latest`
for pull requests, pushes to `main` and manual dispatch, with `contents: read` only, no
secrets and no self-hosted runners.

The workflow provisions AutoHotkey v2 as a **pinned portable ZIP** (`v2.0.30`, verified by
SHA-256) extracted under `RUNNER_TEMP`, and passes the resolved `AutoHotkey64.exe` through
the supported repository-layout override (`DEVWS_AHK_PATH`). Nothing is installed
system-wide and no installer is executed.

Hosted Windows is a High-integrity Administrator whose UAC/token model does not provide the
genuine same-user linked filtered Medium token that a normal UAC-enabled elevated workstation
has. `Test-DevWSProtectedStateAnchorSafety` correctly fails closed there
(`TokenSource=unavailable`). The hosted gate therefore accepts **exactly one** runtime skip:
the real Medium-token protected-state integration case, and only when its reason states that
a reliable Medium authority is unavailable. Any other skip, more than one skip, any test
failure, or any filter exclusion fails the gate.

That skip describes the runner, not the product. The protected-state check is unchanged and
still refuses to assume safety when it cannot obtain a reliable Medium subject.

## 5. Reading the test result

The suite reports six mutually exclusive numbers, and the terminology matters:

```text
Case accounting:
  discovered       : every Test-Case reached
  selected         : discovered and not excluded by -Group (bodies entered)
  passed           : selected; assertions ran and all held
  failed           : selected; an assertion or the body raised
  runtime-skipped  : selected; the body left early WITHOUT completing its assertions
  filter-excluded  : not selected; the body was never entered
```

Two partition equations are enforced, and a violation is a harness defect:

```text
discovered = selected + filter-excluded
selected   = passed + failed + runtime-skipped
```

**A runtime skip is not a pass.** A case skips when a precondition outside the suite's
control is unmet — no usable window station, an optional third-party runtime absent, or a
documentation invariant that does not apply. The suite says so explicitly:

```text
N selected case(s) passed. M selected case(s) were skipped at runtime and did NOT
complete their assertions, so coverage is NOT complete.
```

Use `-RequireFullCoverage` whenever you need a result you can call complete: with that
switch, any runtime skip makes the run exit non-zero. Without it, a run with skips still
exits zero, and the summary tells you coverage is incomplete.

**Hosted CI is not a substitute for release acceptance.** Hosted runners validate the
fail-closed hosted environment plus every portable test; they do not exercise the positive
linked-Medium security path. Maintainer and release validation must still run
`-RequireFullCoverage` on a normal UAC-enabled elevated Windows environment, where that path
executes and zero skips are required.

## 6. Changing the suite

- **Never weaken, delete or bypass an assertion to get a green run.** If a check is wrong,
  change it deliberately and say why in the commit message.
- **Never convert a skip into a pass.** If a precondition genuinely cannot be met, use the
  skip mechanism so the result stays visible.
- Keep the deterministic `-Group` / `-ListGroups` interface working. Execution order follows
  the catalogue, not the argument order.
- Keep assertions deterministic. A test that depends on a live broker, a running terminal or
  your real configuration does not belong in the suite.
- Prefer a source-level contract over a timing-sensitive check when the contract is what you
  actually care about.

## 7. Security-sensitive areas

Change these carefully, and expect review:

- **Privilege boundaries** — what runs at which integrity, and which root a high-integrity
  process may load code from.
- **Protected state** — ownership, access control and validation of the privileged state
  root. Components that already exist are validated as untrusted input and must never be
  silently repaired, re-owned or re-permissioned.
- **Worker transport** — the named-pipe protocol, framing limits and, above all, the
  identity validation the caller performs on the connected worker before transmitting
  anything.
- **Trusted resolution** — how a privileged process chooses the executables and packages it
  launches. There is no `PATH` lookup and no user-writable source.
- **Fail-closed behaviour** — ambiguity, unsafe topologies and untrusted candidates must
  refuse before the first side effect.

Production security checks are not to be relaxed so that a test passes. If a security check
and a test disagree, the check is the product and the test is wrong.

## 8. Style and conventions

- **Line endings.** `.ps1`, `.ahk`, `.cmd` and `.json` are pinned to CRLF by
  `.gitattributes`, independent of your `core.autocrlf` setting, because installed files are
  compared byte-for-byte. Do not change that policy to tidy a local diff.
- **PowerShell.** Match the surrounding code: comment-based rationale for non-obvious
  decisions, explicit validation before side effects, and no new dependency on
  `PATH`-resolved executables in privileged paths.
- **Comment the *why*.** A comment that restates the code is noise; a comment that records
  why an obvious-looking alternative was rejected is valuable.
- **Keep the CLI parser literal.** Tool arguments must pass through unchanged; do not add
  binder features that reinterpret them.
- **Config-only means config-only.** A configuration command must never launch, close,
  focus, move or resize a window.

## 9. Fixtures must be synthetic

Every fixture, example and test must use **invented** identifiers and paths.

Do not commit:

- your real user-profile paths or your account name;
- your real monitor identities, device paths or hardware identifiers;
- your real project names, applications or command lines;
- any credential, token, key or certificate;
- anything copied from a real machine's state files.

Use obviously synthetic values. The repository enforces this with generic publication
invariants, and a fixture that trips them is a bug in the fixture.

## 10. Documentation

If you change behaviour that the documentation describes, update the documentation in the
same change. Two files are referenced directly from production source comments and must keep
their paths:

- `docs/architecture.md`
- `docs/configuration.md`

`docs/cli.md` is generated from the same command metadata the CLI uses to render help, so
command documentation cannot drift from the implementation. If you add or change a command,
change the metadata rather than hand-editing the reference.

## 11. Commits

- Keep changes scoped and reviewable.
- Explain *why* in the commit message, especially for security-relevant changes.
- Do not amend or rewrite published history.
- Do not commit generated artefacts, local state or editor files.

## 12. Reporting a problem

For anything security-related, read [SECURITY.md](SECURITY.md) first. For everything else, a
clear issue report with your Windows version, PowerShell version and the exact command you
ran is the most useful thing you can provide.
