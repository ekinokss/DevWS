# Phase 6 — real-monitor acceptance plan

Status: **prepared, not executed**. Phase 6 hardening and compatibility
verification are complete. Real-hardware acceptance requires separate
supervisory approval.

This plan prepares the section 11.7 matrix in
[`monitor-relative-layout-design.md`](monitor-relative-layout-design.md).
Synthetic tests remain the immediate verification path. No display
configuration, live window movement, installer execution, or VM provisioning
may be performed without approval.

## Safety and isolation

- Use a disposable Windows test host or a fresh acceptance VM. Do not use the
  development host's normal desktop for destructive checks.
- Use disposable test windows and a disposable DevWS config/state root
  (`DEVWS_CONFIG`, `DEVWS_STATE_ROOT`, or a documented installed layout).
- Do not run a production installer or publish any artifact.
- Do not recreate the retired Phase 5 VM automatically. A fresh VM proposal
  must first state OS image, CPU/RAM/disk, network isolation, display-topology
  controls, snapshot/rollback method, and disposal date.
- Capture monitor topology and config before each scenario; restore the
  snapshot or saved config afterwards.
- Never change the user's monitor arrangement without explicit approval.
- Keep evidence local. Do not upload to `gdrive:devws/`.

## Prerequisites

1. Windows 10/11 x64 test environment with the approved DevWS build and a
   disposable terminal/app fixture set.
2. A reversible way to change display topology.
3. Snapshot/rollback or a documented manual restore for display and DevWS
   state.
4. Commands: `ws launch`, `ws save-layout`, `ws save`, `ws show-layout`,
   `ws reset-layout`, and `ws reset-terminals`.
5. Evidence template: timestamp, host, display signature, config before/after,
   command output, captured rectangles, verdict, and cleanup.
6. A bounded evidence directory and cleanup owner.

### Proposed acceptance VM (not provisioned)

If a fresh VM is required, propose and approve this resource envelope first:

- Windows 11 x64, 4 vCPU, 8 GB RAM, 64 GB dynamically allocated disk.
- Isolated virtual network with no access to the primary LAN; updates may be
  staged offline.
- Two virtual displays at different resolutions/scaling (for example
  2560x1440 at 150% and 1920x1080 at 100%) with reversible topology changes.
- Snapshot before acceptance; restore or dispose within seven days of
  completion. No production credentials, no cloud archive access, and no
  upload of evidence.

## Matrix

| ID | Scenario | Action | Expected result |
| --- | --- | --- | --- |
| RH-01 | Single monitor 1920x1080, 100% | Launch, arrange, save-layout, show-layout, reset terminal | Absolute geometry applied; relative target resolves; show-layout matches launch/reset. |
| RH-02 | Dual monitors, different resolutions, secondary at negative x, taskbar on secondary | Save/relaunch a relative item on secondary | Fractions follow the secondary work area; negative origin preserved; no primary remap. |
| RH-03 | Mixed scaling 150% + 100% | Save/restore half-work-area layouts for both bases | Virtualized rectangles resolve proportionally; no DPI-awareness change. |
| RH-04 | Resolution change | Capture at 1920x1080, change to 2560x1440, relaunch | Fractions scale; fallback unchanged; no auto-retile before explicit launch. |
| RH-05 | Primary-monitor change | Swap primary role and relaunch | Durable identity still wins; no role-based remap. |
| RH-06 | Disconnect/reconnect | Disconnect anchored monitor, launch, reconnect, launch | Reachable fallback or skip while absent; relative resumes only on next explicit launch. |
| RH-07 | Missing relative anchor | Launch/reset with disconnected anchor | Reachable absolute fallback only; otherwise skip with warning; no guessed monitor. |
| RH-08 | Ambiguous duplicate identities | Two identical models without instance; then add instance | Ambiguous case refuses/falls back; instance disambiguates; no ordinal selection. |
| RH-09 | Window spanning two monitors | Fallback save across boundary | Greatest visible area wins; equal-area tie refuses; span/negative fractions retained. |
| RH-10 | Wholly off-screen window | Save with an existing resolvable anchor | Existing anchor retained; no clamping; absolute fallback mandatory. |
| RH-11 | Exact profile override | Match a profile with an entry; compare relative item | Profile entry wins; sparse omission falls back to relative; unreachable entry refuses. |
| RH-12 | Absolute fallback | Missing/unreachable relative target with reachable/unreachable fallback | Reachable fallback moves; both unreachable skips; never moves to wrong monitor. |
| RH-13 | Targeted terminal reset | Reset one terminal and whole set; inspect elevated worker | Same frozen absolute rectangles; one normal-side topology snapshot; elevated worker has no topology read. |
| RH-14 | Profile-targeted save | Save matched and explicit profiles with relative items | Only `profile.layouts` changes; `item.layout` and `layoutRelative` byte-identical. |
| RH-15 | Fallback-scope save | `save-layout --layout fallback` with mixed items | Relative items dual-write; absolute items update only item.layout; profiles untouched. |
| RH-16 | show-layout versus launch/reset | Run show-layout immediately before operation | Same source, apply flag and effective rectangles. |
| RH-17 | Work-area-only change | Move taskbar and save/launch | Work-area basis follows; monitor basis does not; A/B save refuses mid-capture work-area change. |
| RH-18 | Duplicate monitors with port change | Move one monitor to another port | Unique identity resolves; duplicate identity plus stale instance refuses; no guessing. |

## Procedure template

1. Record environment, monitor signature/fingerprint and config hash.
2. Launch the disposable fixture set and arrange only test windows.
3. Run the scenario action with output capture.
4. Compare expected and actual rectangles, sources and warnings.
5. Restore display topology and config snapshot.
6. Record PASS/FAIL, deviations, timing, and cleanup.
7. Stop on unintended non-fixture movement, an unrestorable display change, or
   any installer/privilege action.

## Acceptance criteria

- No non-fixture window moves, closes or is retagged.
- Profile > relative > absolute precedence holds.
- Relative anchors never use ordinals or guessed monitors.
- Profile-free absolute launch/save remains zero-topology.
- Relative lifecycle planning uses one topology acquisition; successful A/B
  save uses two.
- `show-layout` matches the frozen lifecycle placement.
- Elevated reset receives absolute rectangles only.
- No automatic retiling or background monitor watcher is observed.
- Every scenario has reversible cleanup evidence.

A release decision remains separate. Do not tag, publish, update package
managers, or upload evidence without explicit authorization.
