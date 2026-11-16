# DevWS Long-Term Product Roadmap (Proposal)

**Status:** Discussion draft — not an approved implementation plan or release commitment.  
**Recorded:** 2026-11-03  
**Baseline:** Published, unsigned `v0.3.0` GitHub pre-release (source `5b5d8f6`); `v0.2.0` remains latest stable.

This document records the post-v0.3 brainstorming direction. It is intentionally separate
from [known limitations and deferred work](future-work.md), which describes current
behavior and existing technical debt. The estimates below are planning ranges, not
deadlines, budgets, acceptance results, or authorization to implement a feature.

## 1. What already exists

Do not repackage existing behavior as a new roadmap feature. DevWS v0.3 already has:

- Named, independent workspace sets, set-qualified operations, a configured default set,
  cloning/renaming, and per-set launch hotkeys.
- `ws launch` to ensure enabled terminals and apps exist and apply their effective layout;
  `ws focus` to bring existing items forward without launching or moving them.
- Managed Windows Terminal windows/tabs with durable identities, startup commands,
  per-tab directories, reliable tracked cwd/active-tab saving, and explicit resets.
- Dedicated/shared application matching and ownership, with ambiguity refusals.
- Atomic configuration persistence; geometry capture; absolute fallbacks, exact topology
  profiles, and monitor-relative geometry from v0.3.
- CLI configuration, read-only diagnostics, privileged operation boundaries, and a
  package install/repair/upgrade/uninstall lifecycle.

See [CLI](cli.md), [architecture](architecture.md),
[configuration](configuration.md), and
[workspace sets](workspace-sets-design.md) for the actual contract.

## 2. Working product principles

1. **Explicit and predictable by default.** No surprise window closure, hiding,
   minimization, or background rearrangement. Any future automatic behavior requires a
   separate, opt-in design and a clear way to disable it.
2. **Preserve identity and sessions.** Reuse recognized windows; fail closed on ambiguous
   identity or unsafe topology. Do not quietly turn a focused set into a destructive
   “exclusive workspace” switch.
3. **Keep privilege boundaries intact.** User-controlled configuration is input, not
   privileged code. New UI/automation must not weaken trusted executable resolution,
   protected-state checks, or worker authentication.
4. **Make changes reviewable.** Prefer previews, scoped mutations, validation, and
   recoverable configuration changes over implicit reinterpretation of layouts.
5. **Preserve compatibility.** Existing absolute configurations and the accepted
   install/upgrade/uninstall preservation contract must continue working. Schema and
   migration changes need independent design and acceptance.
6. **Do not equate code completion with qualification.** Features are only called
   accepted where the relevant real-host/guest scenarios and strict tests actually pass.

## 3. Proposed release sequence

The version numbers are placeholders for planning. Every workstream needs a design gate,
bounded implementation passes, hermetic tests, installed-product acceptance, and a
release decision. A **pass** means a reviewable unit of design, implementation, or
verification with evidence; it is not a promise that one agent run will finish the work.

| Tentative release | Main outcome | Rough passes | Not part of the claim |
| --- | --- | ---: | --- |
| **v0.4 — Visual workspace editor** | View monitors/sets, drag and size items, author absolute/relative/profile geometry, inspect and validate the proposed config before saving. | 8–12 | A new window manager or invisible background reflow. |
| **v0.5 — Named snapshots and history** | Explicit named checkpoints of validated configuration and reliable captured workspace state; list, compare, preview, and restore them. | 5–8 | Capturing arbitrary application memory, unsaved documents, or browser/editor sessions. |
| **v0.6 — Adaptive layout controls** | Research and selectively add grid/named-zone intent and explicit missing-monitor/reflow policies, building on v0.3 relative geometry. | 8–12 | Silent automatic remapping to an unrelated display. |
| **v0.7 — Workflow orchestration** | Optional dependencies, readiness/health conditions, timeouts, and explainable launch order for configured items. | 8–12 | A general-purpose elevated script runner or unconstrained hotkey macro framework. |
| **v0.8 — Plan, preview, and recovery** | Inspect intended lifecycle actions before execution, distinguish preflight from side effects, and add scoped recovery/undo where it can be made truthful. | 8–12 | Claiming all-or-nothing live launch rollback when process or application effects cannot be reversed. |
| **v1.0 — Stability decision** | Dedicated compatibility, security, installer, documentation, real-hardware and accessibility acceptance; decide whether a stable 1.0 claim is justified. | Re-estimate separately | Assuming a version number makes deferred behavior qualified. |

The five feature workstreams above sum to **approximately 37–56 passes**, including
their local test and review work. This is an order-of-magnitude forecast, not a fixed
scope or schedule. Cross-release integration and a possible v1.0 stabilization campaign
may require additional passes. Re-estimate after each design/acceptance gate; avoid
starting all workstreams simultaneously.

### v0.4 — Visual editor: first candidate

Possible staged acceptance path:

1. Choose a Windows UI stack and a validated, normal-integrity configuration API.
   Keep existing CLI semantics as the source of truth.
2. Render actual monitor geometry, work areas, topology identity, items, and effective
   rectangles in a read-only view, including missing/ambiguous anchors and fallbacks.
3. Add precise interactive editing for absolute rectangles, normalized relative
   rectangles, and topology-profile overrides without mixing their storage scopes.
4. Validate and preview diffs before one atomic configuration write. Do not move live
   windows as a side effect of editing.
5. Test scaling, negative desktop origins, monitor ordering, keyboard access, malformed
   configurations, and drift between preview and save.
6. Demonstrate an installed-product round trip: CLI-authored config -> visual editor ->
   CLI validation/launch, and vice versa, without changing the privileged trust model.

This is a candidate scope, **not yet an approved specification**. Whether a GUI can
initiate an explicit `ws launch` is a separate UX and security decision.

### Later workstreams: hard boundaries

- **Snapshots:** restoring a checkpoint restores explicitly selected DevWS-controlled
  configuration/state, not an entire OS or third-party application session. History
  needs retention, integrity, migration, and non-destructive preview rules.
- **Adaptive layouts:** v0.3 already has relative coordinates and topology profiles.
  The new work is policy, authoring and/or a layout engine. Automatic observation is an
  optional design question; explicit invocation remains the baseline.
- **Workflows:** readiness must have bounded probes, deterministic failure reporting,
  timeouts/cancellation, and cycle detection. Existing per-tab startup commands remain
  compatible and independent by default.
- **Recovery:** configuration writes already have atomicity, but `ws launch` may have
  performed partial live side effects. Report that honestly. Undo must be limited to
  effects for which ownership and reversibility can be established.

## 4. v0.3 qualification debt carried forward

The v0.3 pre-release was intentionally published with these **not qualified end-to-end**.
They are not silently converted into passes or acceptance by this roadmap:

1. Installed-product CLI/elevated-worker application of a relative placement record.
2. Multi-monitor selection and negative monitor origins.
3. Physical EDID-based monitor identity.
4. Mixed-DPI monitor configurations.
5. Primary-monitor changes.
6. Monitor disconnect/reconnect and topology-change behavior.

Before changing monitor-placement semantics, create a new acceptance matrix, identify
which scenarios are prerequisites, and run the appropriate hardware/guest tests. Closing
the v0.3 pre-release workstream does **not** imply these tests passed.

## 5. Explicit non-goals and design questions

### Not included in the proposed five workstreams

- Generic restoration of Firefox/VS Code/third-party app tabs, unsaved buffers, process
  memory, or arbitrary application state. Application-specific integrations, if ever
  considered, need separate scope and permissions.
- A cross-platform port, unrestricted desktop window manager, automatic destructive
  set switching, self-update, MSI/MSIX, signing, or WinGet publication. These require
  separate product and release decisions.
- Silent reversal of externally observable actions or arbitrary command execution.

### Decisions for future design reviews

| ID | Question |
| --- | --- |
| D-01 | Which Windows-native UI technology and process boundary are appropriate for the editor? |
| D-02 | Should optional hide/park behavior ever exist, and if so how is user consent and restoration handled? |
| D-03 | Where do snapshots live, how are they versioned, and what is the restore contract? |
| D-04 | Which missing-monitor policy is useful without violating durable-anchor intent? |
| D-05 | Is automatic display observation worth a persistent component, or should all reflow remain explicit? |
| D-06 | What are permissible readiness probes and failure semantics for dependencies? |
| D-07 | What reversible live effects can DevWS prove it owns, and how are partial results reported? |

## 6. Definition of done for each release

- The design spells out ownership, privileges, compatibility and failure semantics.
- New behavior is opt-in where it changes an established non-destructive default.
- Deterministic unit/contract tests pass without reduced assertions or hidden skips.
- The strict local gate and relevant installed-product VM/hardware scenarios have
  recorded outcomes; anything not exercised is explicitly deferred and not claimed.
- Configuration remains valid and recoverable; installer upgrade/repair/uninstall
  preservation is rechecked when touched.
- Docs, CLI/help, known limitations, and release notes describe exactly what shipped.
- Scope receives a separate owner-approved release gate. This roadmap alone authorizes
  no implementation, merge, package, tag, or publication.
