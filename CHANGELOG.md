# Changelog

All notable changes to DevWS are recorded here.

This project follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) conventions and
uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

**There is no released version yet.** DevWS is pre-release: no installer package, no release
binary and no distribution channel exist. The section below records the state of the
repository; it does not describe a release.

---

## [Unreleased]

### Added

- Public project documentation: a project overview, an architecture and security-model
  reference, a complete command reference generated from the CLI's own command metadata, a
  configuration schema and validation reference, an installer and uninstaller contract, the
  workspace-set product model, a known-limitations and deferred-work register, and a manual
  validation checklist.
- Contributor guidance and a security policy.
- A read-only environment probe for comparing a test environment with a validated one.
- A neutral shared test fixture so behavioural tests no longer depend on the shipped default
  configuration.

### Changed

- The shipped default configuration is now a **neutral starter** — one empty set, no items, no
  bindings and no geometry — instead of a personal workspace. A fresh installation no longer
  imposes any particular terminals, applications or screen geometry.
- The test harness now reports six mutually exclusive case outcomes (discovered, selected,
  passed, failed, runtime-skipped, filter-excluded) and enforces both partition equations. A
  runtime skip is never counted as a pass.
- Added a `-RequireFullCoverage` switch: with it, any runtime skip makes the run exit
  non-zero, so an incomplete run cannot be mistaken for a complete one.
- Configuration-dependent test expectations were re-derived for the neutral starter, and
  several write-refusal cases now run against the real shipped default.

### Removed

- Personal identifiers, machine-specific identifiers and personal workspace content from
  source comments, fixtures and the bundled configuration.

### Notes

- Historical v1 configuration migration is **not supported** by the public product. A v1
  document is refused without modifying either the v1 file or the canonical configuration.
- Existing valid v3 configurations are preserved byte-for-byte.
- Bundled-template instance-mode inference can no longer supply a mode, because the neutral
  starter defines no applications; see
  [docs/configuration.md](docs/configuration.md) §12.
