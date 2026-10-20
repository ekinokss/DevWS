# DevWS Security

This document summarises the DevWS security model and explains how to report a problem.

For the full component and boundary description, see
[docs/architecture.md](docs/architecture.md). For known limitations and bounded security
notes, see [docs/future-work.md](docs/future-work.md) §2.

---

## 1. Reporting a vulnerability

Please report suspected security vulnerabilities **privately**. Do not open a public issue for
an undisclosed vulnerability, and do not include exploit details in a public discussion.

The preferred channel is **GitHub private vulnerability reporting**: open the repository's
**Security** tab and choose **Report a vulnerability**. That creates a private advisory visible
to the maintainers without disclosing the report publicly.

If the private reporting control is not available, contact the maintainer through GitHub and
ask for a private channel. Do not post the details publicly while a private channel is being
arranged.

There is no bug bounty and no response-time commitment.

When you report, include:

- what you observed and why you believe it is a security issue;
- the exact commands or steps to reproduce it;
- your Windows version and PowerShell version;
- whether the issue requires an elevated session.

Please do not disclose a suspected vulnerability publicly before it has been assessed.

## 2. What DevWS is, from a security standpoint

DevWS is a **local desktop automation tool**. It has:

- no network listener and no remote API;
- no server component and no cloud service;
- no telemetry;
- no authentication system, because there is no remote party to authenticate.

Everything it does happens on the machine it runs on, on behalf of the user who installed it.

## 3. The integrity model

DevWS uses the ordinary Windows integrity model rather than a custom privilege scheme.

| Layer | Integrity | Contains |
| --- | --- | --- |
| User runtime | Medium (the user) | CLI, coordinator, libraries, configuration, disposable state |
| Privileged runtime | High (administrator) | Workers, broker, high-reachability libraries, helpers, native assembly |
| Privileged state | Administrator-protected | Elevated runtime cache, capture publications, working-directory authority |

Three rules enforce the split:

1. **A high-integrity DevWS process loads code only from the administrator-protected
   privileged root.** There is no fallback to a user-writable copy.
2. **Executables are resolved absolutely and validated**, never through `PATH` and never from
   a user-writable value. AutoHotkey follows the same rule for installed operation: it must
   come from the machine-wide all-users installation under an administrator-protected
   Program Files root, be an existing `AutoHotkey64.exe`, and report major version 2.
   Current-user installations, aliases and the repository-only `DEVWS_AHK_PATH` override are
   never used by an installed High-integrity process.
3. **Privileged state is validated on every authoritative read** and is never silently
   repaired, re-owned or re-permissioned.

## 4. What is deliberately user-controlled

The canonical configuration file is user-writable, and privileged operations read it. This is
intentional: DevWS exists to launch the workspace *you* configured, including configured
commands in elevated terminals.

Stated plainly: **configuration is input, not code.** A same-user process that can write your
configuration can influence what a privileged operation is asked to do. DevWS does not try to
cryptographically protect the configuration from its own user, because that would defeat the
product's purpose.

What the design does instead is refuse to treat configuration as executable authority: the
privileged runtime, the executables it launches and the privileged state it reads all come
from administrator-protected sources, never from user-writable values.

## 5. Threat boundaries that matter

| Boundary | Property |
| --- | --- |
| User → privileged code | A user-writable file can never become privileged code. The privileged runtime is complete-or-nothing, and a high-integrity process refuses to load from a user-writable path. |
| User → privileged state | The privileged state root is administrator-owned with a protected access control list. Unexpected components are refused, not repaired. |
| Privileged worker → caller | The caller authenticates the worker from the connected pipe handle — kernel-reported process, a retained handle, exact high integrity, user identity, session, image and the exact fixed task action — before transmitting a single byte. |
| Configuration → privileged execution | Configuration is trusted as *input*; it cannot change which code or which executables the privileged side will use. |
| Failure → side effect | Ambiguity, unsafe topologies and untrusted candidates refuse **before** the first side effect. |

## 6. Known, documented boundaries

These are deliberate properties, recorded so a reviewer does not have to rediscover them:

- **The broker pipe admits any same-user, medium-integrity process**, and the broker does not
  additionally authenticate its clients. A same-user process could interfere with the user's
  own launch path. Impact is bounded: the interfering process is still at the user's own
  integrity, so this is misdirection or denial of service against your own session, not a
  privilege-boundary crossing. The short-lived worker transport does authenticate in the
  direction that matters.
- **The scheduled-task declaration is trusted as administrator-controlled.** Worker
  authentication derives the expected worker identity from the task's own declaration, on the
  basis that a medium-integrity process can read but not modify it. This rests on the task's
  access control, not on a cryptographic check, and is worth re-confirming if task
  permissions are changed from the installer's defaults.
- **The generated native assembly is validated structurally, not by identity.** It is not
  signed, and its compilation is not byte-reproducible.

Lower-priority items — predictable temporary-file suffixes in some state writers, argument
quoting in the AutoHotkey helper invocation, the exact-title locator, and the absence of an
exactly-once guarantee after an uncertain worker outcome — are listed with their bounded
impact in [docs/future-work.md](docs/future-work.md) §2.5.

## 7. What DevWS will not do

- It will not install third-party software for you.
- It will not modify scheduled tasks, Startup scripts or Windows Terminal settings that it
  does not own.
- It will not delete your configuration or your legacy rollback directory, even on uninstall.
- It will not silently repair a protected-state component that has drifted; it refuses and
  tells you.
- It will not guess when a match is ambiguous, a topology is unsafe, or an executable cannot
  be trusted.

## 8. Supported versions

DevWS is pre-1.0. Security fixes target the current `0.1.x` line on `main`; there is no
long-term support branch and no back-porting policy. Because DevWS is distributed as source,
there are no supported binary, package or installer artefacts. Users should run a current
source checkout and re-run the installer after security-relevant updates.
