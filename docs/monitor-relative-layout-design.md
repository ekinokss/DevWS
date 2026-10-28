# DevWS Monitor-Relative Layouts

Design proposal for v0.3. **Status: revised supervisory review draft (revision 2,
28 October 2026). Not implemented.**

Revision 2 addresses the three review questions: downgrade guarantees, profile/topology
refusal, and save scope. No production schema, runtime, CLI, installer or release change
has been made.

Investigation baseline: `main` at `85e307736bc46011403458bde538d10e5abe9e93` (verified
clean before review). This document is the only added file from the investigation.

This document proposes a backward-compatible, explicit monitor-relative layout capability
for DevWS. It does not change the production configuration schema, CLI, runtime, installer,
releases, tags or distribution repositories. The current release remains authoritative.

---

## 1. Executive summary

The recommended design is:

- keep schema version 3 and add two optional per-item fields:
  `layoutMode` (`"absolute"` or `"relative"`) and `layoutRelative`;
- keep the mandatory absolute `item.layout` as the universal fallback, and keep every
  existing configuration valid without migration;
- anchor a relative layout to a durable monitor identity (`edid:` or `path:`), with an
  optional device-path instance as a tie-breaker for identical monitors;
- store normalized fractions of an explicitly chosen basis rectangle, either the monitor
  work area or the full monitor rectangle;
- resolve exact topology profiles first, then relative layouts, then absolute fallback;
- preserve the existing strict refusal contract for profile-enabled lifecycle operations;
  no relative-only bypass is part of this design;
- for profile-free relative sets, fall back to the absolute layout with a warning when a
  relative anchor is missing or ambiguous; never silently remap to a different monitor;
- re-anchor relative layouts during fallback-scope `ws save-layout` / `ws save` from the
  captured window position, and dual-write the absolute fallback only in that scope;
  profile-targeted saves never write the universal fallback or relative fields;
- keep DPI awareness unchanged, keep all resolution normal-side, and keep the launch/reset
  path frozen, explicit and free of monitor watchers.

The main decisions still required before implementation are listed in section 8. The
recommended implementation sequence is in section 10 and the targeted test strategy is in
section 11.

### 1.1 Review resolutions (28 October 2026)

1. **Downgrade behavior.** The compatibility guarantee is structural/load compatibility and
   a deterministic absolute fallback, not semantic preservation of relative intent. Old
   binaries load additive v3 relative configurations, ignore the relative fields, and use
   the existing profile/absolute placement semantics. Older layout-writing commands update
   absolute or profile geometry only and can leave relative metadata stale; when the user
   upgrades again, relative mode resumes. The new implementation must explicitly copy relative
   fields in every item-cloning helper. `reset-layout` and `set-geometry --mode absolute`
   are the only intentional clearers. Tests cover clone/copy behavior, stale divergence and
   installer preservation.
2. **Profile/topology behavior.** Profile-enabled lifecycle operations keep the existing
   strict refusal contract unchanged. Unavailable, incomplete or ambiguous topology,
   duplicate matchers, and unreachable matched profile entries all refuse before side
   effects, even when every target item is relative. No relative-only bypass is approved.
   Profile-free relative sets handle per-item degradation separately: when topology is
   unavailable, a relative item warns and sets `ApplyGeometry = false` because reachability
   cannot be established; absolute items in the same set keep their existing behavior.
   When topology is available but an anchor is missing, ambiguous or unusable, the absolute
   fallback is used only after the existing reachability rules. Save re-anchors from the
   capture and refuses only when it cannot select an anchor safely. Profile-free absolute
   sets retain the zero-topology path.
3. **Save scope.** A profile-targeted save (implicit matched profile or explicit
   `--profile <id>`) writes only that profile's absolute entries. It never updates
   `item.layout` or `layoutRelative`. A fallback-scope save (no profile match, or explicit
   `--layout fallback`) is the only place relative dual-write occurs: relative items update
   `layoutRelative` and `item.layout`; absolute items update `item.layout`. A
   profile-targeted save therefore cannot unexpectedly modify universal fallbacks.

| Review question | Detailed resolution |
| --- | --- |
| Downgrade behavior and copy guarantees | Sections 3.8, 6.11, 7.3-7.5, 11.1, 11.5 and 11.6 |
| Profile/topology refusal | Sections 6.6, 6.7 and 11.3 |
| Save scope and dual-write | Sections 6.8.1, 7.7 and 11.4 |

---

## 2. Scope and invariants

### 2.1 In scope

- A per-item way to express placement relative to one monitor.
- Durable monitor reference across reconnects, reordering, primary-role changes and
  resolution changes.
- Coexistence with existing absolute geometry and topology layout profiles.
- Save, show, launch/reset and authoring behaviour for the new mode.
- Migration and downgrade semantics.
- Failure handling for missing, ambiguous, unreachable and unsafe placements.

### 2.2 Out of scope

- A general-purpose window manager.
- A background monitor watcher or automatic desktop rearrangement.
- Automatic retiling, automatic window snapping, or automatic movement when a monitor is
  plugged in or removed.
- Per-monitor DPI awareness changes or a physical-pixel coordinate contract.
- Relative layouts inside topology profile entries in phase 1.
- Grid/zone presets, named layouts, monitor aliases, or application-specific rules.
- Changes to releases, tags or distribution repositories.

### 2.3 Invariants

1. Every enabled item continues to have a valid absolute `item.layout`.
2. Existing v3 configurations remain valid and behave identically.
3. A relative mode is never inferred from geometry. It must be declared explicitly.
4. A missing or ambiguous monitor never causes a silent move to another monitor.
5. Lifecycle operations sample topology at most once and freeze the decision.
6. No background process observes or rearranges the desktop.
7. Absolute rectangles crossing the elevated broker remain absolute integers; the
   privileged worker never resolves monitor identities.

---

## 3. What exists today

### 3.1 Configuration and absolute geometry

- `item.layout` is mandatory and is an absolute outer-window rectangle
  `{ x, y, w, h }` with integer `x`/`y` (negative values allowed) and positive `w`/`h`.
- `layoutProfiles` is an optional per-set array. Each profile matches one exact monitor
  topology and stores sparse absolute rectangles keyed by item id.
- `item.layout` remains the universal fallback. A matched profile entry overrides it for
  that item; an item omitted from a matched profile falls back to its absolute layout.
- Schema version 3 is the only runtime schema. The installer preserves a valid v3 config
  byte-for-byte and migrates only v2 or historical pre-instance-mode v3 documents.

Relevant implementation: `src/lib/devws-config.ps1`,
`src/lib/devws-layout-profile.ps1`, `docs/configuration.md` sections 8-9.

### 3.2 Monitor identity and topology

The monitor identity chain is fixed:

1. meaningful EDID serial string or numeric serial ->
   `edid:<manufacturer>-<product>-<serial>`;
2. otherwise the normalized display device path ->
   `path:<hardwareId>/<instance>`;
3. otherwise identity is unavailable.

Ordinals such as `\\.\DISPLAY1`, source/target ids, adapter LUIDs, the primary bit,
friendly names and resolution are never identities. The topology signature is the
ordinal-sorted multiset of `<identity>@<x>,<y>,<width>x<height>` and its SHA-256
fingerprint. It deliberately excludes work area, taskbar state, DPI, primary role, friendly
name, LUIDs and target ids. Identical identity tokens at different monitor rectangles are
legal; the same identity at the same rectangle is flagged ambiguous.

Relevant implementation: `src/lib/devws-monitor.ps1`,
`src/native/devws-monitor.cs`.

### 3.3 Profile matching and write routing

- Only `match.mode: "exact"` is supported. Matcher tokens are canonical
  `<edid|path identity>@<x>,<y>,<width>x<height>` strings.
- Two profiles in one set may not have the same matcher signature. Profile order never
  resolves a conflict.
- A profile-aware set samples topology once per operation.
- An unsafe or ambiguous topology refuses a profile-aware launch/reset before side effects.
- An unreachable profile rectangle refuses the operation.
- An unreachable fallback rectangle produces a warning and leaves that item unmoved.

### 3.4 Capture, save and save-layout

- Capture is all-or-nothing. Every enabled item must produce a valid rectangle.
- `ws save-layout` writes geometry only. `ws save` also persists reliable tracked working
  directories and the active tab.
- For profile-aware sets, save samples topology A, captures, then samples topology B and
  requires the signature/fingerprint to be stable before the single canonical write.
- A set with no profiles uses the legacy fallback path and performs no monitor sampling.
- Capture currently records only absolute rectangles. It does not record a monitor anchor.

### 3.5 Launch and reset

- One lifecycle layout plan is frozen before side effects.
- A profile-free set has a hard legacy fast path: no monitor access, no reachability gate,
  every item keeps `item.layout`.
- A profile-aware set resolves the exact profile or fallback per item and freezes the
  effective absolute rectangles.
- The frozen plan crosses the coordinator/broker boundary as absolute integer rectangles.
  No worker re-samples topology.

### 3.6 `show-layout`

`ws show-layout` currently displays the effective absolute rectangle and whether it came
from a matched profile or the fallback. It does not display a layout mode, a monitor anchor
or a normalized rectangle.

### 3.7 DPI and coordinate space

A measured probe on the development host found PowerShell 7.6.7 to be DPI-unaware
(`GetProcessDpiAwareness` = 0, thread awareness = 0). DevWS captures and applies absolute
geometry in that same virtualized coordinate space. Changing process DPI awareness would
reinterpret every existing absolute layout and is therefore a compatibility risk.

The conclusion for this design is: **do not change DPI awareness**. Relative fractions must
be computed over the monitor/work rectangles as observed by the current DevWS process, not
over raw physical pixels. `DpiEffective` and `ScalePercent` are diagnostics only.

### 3.8 Compatibility hook already present

The current v3 item validator validates known fields but does not reject unknown item
properties. `ConvertFrom-Json` / `ConvertTo-Json` and `Set-DevWSLayout` preserve unknown
item properties. A probe using a config containing `layoutMode` and `layoutRelative`
confirmed:

- the current validator accepts the document;
- both fields survive a JSON round-trip;
- `Set-DevWSLayout` updates `layout` without removing the relative fields.

This is the foundation of the recommended downgrade story. It is an implicit compatibility
contract today, so the implementation should make it explicit and test it. The important
exception is cloning: the current clone helpers reconstruct items from known fields and drop
unknown item properties. The new implementation must copy `layoutMode` and `layoutRelative`
explicitly in every clone/copy path (section 7.4).

---

## 4. Problem scenarios

| Scenario | Today | What is needed |
| --- | --- | --- |
| Dock/undock an external monitor | Exact profile if one exists, otherwise the absolute fallback may land off-screen or on the wrong monitor. | A relative layout that follows the monitor identity and falls back safely when it is absent. |
| Resolution change | The profile matcher includes the monitor rectangle, so a changed rectangle misses; absolute geometry no longer matches the new desktop. | Proportional placement that survives resolution changes. |
| Display reordering | Profile matcher misses; absolute coordinates may point at a different monitor. | Identity-based anchoring that ignores position and order. |
| Primary monitor changes | Profile matcher misses; absolute fallback may be on the old primary. | Identity-based anchoring that ignores the primary bit. |
| Taskbar moves or changes height | Profile may still match because work area is excluded; absolute or profile geometry may overlap the taskbar. | Optional work-area basis that adapts to the current work area. |
| Display scaling changes | Profile may miss when the virtualized monitor rectangle changes; absolute geometry may be wrong. | Fractions over the current virtualized rectangle. |
| Monitor absent | Absolute fallback is used; a profile-aware set may refuse. | Explicit fallback policy that preserves reachability. |
| Two identical monitors | Profile signature distinguishes them by rectangle; no durable per-item anchor exists. | Identity plus an optional device-path instance tie-breaker. |
| Deliberate overlap or off-screen window | Absolute geometry supports it. | Fractions must allow values outside `[0,1]` and must not clamp. |
| Window has a minimum size | The OS/app enforces it at placement time. | Treat the relative rectangle as a target request, not a guarantee. |

The goal is to make DevWS more useful across changing monitor setups, not to become a
general-purpose window manager.

---

## 5. Design alternatives

### 5.1 Status quo: more exact profiles

Keep absolute geometry and create more topology profiles.

**Pros:** no new schema, no new failure modes, exact control per topology.
**Cons:** profile explosion; every resolution, reorder or primary change can miss; does not
address unknown or one-off setups; users must manually re-key profiles.

**Verdict:** does not meet the goal.

### 5.2 Per-item relative mode with normalized fractions (recommended)

Add an explicit per-item mode, an anchor monitor and a normalized rectangle. Keep the
absolute layout as fallback.

**Pros:** adapts to resolution, reorder and primary changes; proportional placement is
intuitive for halves/quarters; additive v3 schema; old binaries can ignore the new fields
and use absolute fallback; works with existing profiles as a fallback layer.
**Cons:** two geometry representations; capture must re-anchor; floating-point rounding;
profiles can override relative items when they match.

**Verdict:** recommended.

### 5.3 Monitor-local pixel coordinates

Store `x`, `y`, `w`, `h` in pixels relative to the monitor origin, optionally anchored to an
edge or corner.

**Pros:** fixed window size across resolutions; simple mental model for "800 px from the
left"; good for fixed-size tool windows.
**Cons:** overflows smaller monitors; requires clamping or reachability fallback; does not
scale proportional layouts; position can become invalid after resolution changes.

**Verdict:** useful as a future additive `unit: "pixels"` option, not phase 1. Proportional
placement is the better default for the stated goal.

### 5.4 Grid or named zones

Express layouts as named zones such as left half, right third, top-left, or a custom grid.

**Pros:** simple for common arrangements; robust and easy to explain.
**Cons:** cannot represent arbitrary rectangles, deliberate gaps or border overlaps;
requires a new zone vocabulary, UI and schema; migration and profile interaction are
significant.

**Verdict:** possible future UX layer on top of relative rectangles, not a replacement.

### 5.5 Relative layouts inside topology profiles

Extend profile `layouts` entries to accept relative rectangles.

**Pros:** one profile can carry adaptive entries for a known topology; could adapt to
work-area changes within a matched profile.
**Cons:** the profile schema is strict and rejects unknown properties today; old binaries
would reject the config; exact topology matching already includes the monitor rectangle, so
the additional benefit is narrow; precedence becomes more complex.

**Verdict:** defer. Keep profiles absolute in phase 1.

### 5.6 Separate sidecar file

Store relative intent in a second file next to `workspace.json`.

**Pros:** leaves the v3 schema untouched; old binaries ignore the sidecar entirely.
**Cons:** two sources of truth; atomicity across two files; backup/restore and installer
interaction; profile interaction; user confusion when one file is stale or missing.

**Verdict:** reject.

### 5.7 New schema version 4

Make relative layout a first-class v4 schema and migrate v3 configurations.

**Pros:** clean validation model; could make profiles relative too; explicit version
boundary.
**Cons:** old binaries refuse the config; installer migration and release/distribution work;
larger testing surface; unnecessary for an additive optional feature.

**Verdict:** defer unless reviewers require a strict schema or relative profiles. The
recommended v3 extension is smaller and downgrade-friendlier.

### 5.8 Automatic monitor watcher

Watch display changes and rearrange windows when a monitor is connected or disconnected.

**Pros:** immediate adaptation.
**Cons:** violates DevWS's explicit-operation philosophy; surprising background movement;
hard to make safe around full-screen apps, games and remote sessions.

**Verdict:** reject.

### 5.9 Alternative comparison

| Option | Resolution change | Reorder / primary | Work area | Fixed size | Schema impact | Old binary can read | Complexity |
| --- | --- | --- | --- | --- | --- | --- | --- |
| More exact profiles | profile miss | profile miss | no | yes | none | yes | low |
| Relative fractions | yes | yes | explicit basis | proportional | additive v3 | yes | medium |
| Monitor-local pixels | position only | yes | explicit basis | yes | additive v3 | yes | medium |
| Grid/zones | limited | yes | no | discrete | new schema/CLI | no | high |
| Relative in profiles | profile miss | profile miss | partial | proportional | strict profile change | no | high |
| Sidecar | yes | yes | explicit basis | proportional | none | yes | high |
| Schema v4 | yes | yes | explicit basis | configurable | migration | no | high |
| Watcher | yes | yes | yes | n/a | none | n/a | high + philosophy risk |

---

## 6. Recommended architecture

### 6.1 Schema

Keep `version: 3`. Add two optional item fields. `layout` remains mandatory and unchanged.

```json
{
  "id": "ide",
  "type": "app",
  "enabled": true,
  "layout": { "x": 2560, "y": 0, "w": 1280, "h": 1400 },
  "layoutMode": "relative",
  "layoutRelative": {
    "monitor": {
      "identity": "edid:DEL-A1B2-ABC123",
      "instance": "DELA1B2/5&2b7c1d0&0&UID4353"
    },
    "basis": "workArea",
    "rect": { "x": 0.5, "y": 0.0, "w": 0.5, "h": 1.0 }
  }
}
```

Field rules:

| Field | Type | Required | Rules |
| --- | --- | --- | --- |
| `layout` | object | yes | Unchanged: absolute `{x,y,w,h}`, integers, `w`/`h` > 0. Universal fallback. |
| `layoutMode` | string | no | `"absolute"` or `"relative"` exactly. Absent means `"absolute"`. |
| `layoutRelative` | object | conditional | Required when `layoutMode` is `"relative"`; forbidden when `"absolute"` or absent. |
| `layoutRelative.monitor` | object | yes | Exactly `identity` and optional `instance`. |
| `monitor.identity` | string | yes | Non-empty durable token with an `edid:` or `path:` prefix; never an ordinal. |
| `monitor.instance` | string | no | Device-path instance `<hardwareId>/<instance>`; for EDID anchors only. |
| `layoutRelative.basis` | string | yes | `"workArea"` or `"monitor"` exactly. |
| `layoutRelative.rect` | object | yes | `{x,y,w,h}`, finite numbers, `w`/`h` > 0; `x`/`y`/`w`/`h` are fractions of the basis rectangle. |

Validation rules:

- `layoutMode` absent plus `layoutRelative` present is an error; relative mode is explicit,
  never inferred.
- `layoutMode: "relative"` without `layoutRelative` is an error.
- `layoutMode: "absolute"` with `layoutRelative` is an error.
- `rect.x`/`y` may be negative or greater than 1. `x + w` may exceed 1. No `[0,1]`
  clamping and no monitor-bounds clamping; deliberate overlaps and off-screen placement are
  representable.
- `rect.w`/`h` must be finite and greater than 0.
- `monitor.identity` is matched exactly (ordinal) against the current identity token.
  Serial case is preserved; generated tokens are canonical.
- `monitor.instance`, when present, must match `^[^/\\#\s]+/[^/\\#\s]+$` and is compared
  case-insensitively. It is forbidden when `identity` starts with `path:` because the
  instance is already embedded there.
- Unknown item properties remain tolerated, preserving the current compatibility contract.
  Do not introduce a strict item allowlist in v3. Profiles keep their existing strict
  allowlist and their absolute-only `layouts`.
- Disabled items are validated structurally but ignored by lifecycle and capture.

### 6.2 Why keep version 3

The current v3 item validator and save path tolerate unknown item properties, and the
installer preserves valid v3 documents byte-for-byte. An additive optional field therefore
gives a genuinely useful downgrade path:

- new DevWS reads old configurations and treats absent fields as absolute;
- old DevWS reads new configurations, ignores the relative fields, and uses the mandatory
  absolute fallback;
- no installer migration, no schema-version bump, no release-level config conversion.

This is deliberately different from a v4 schema, which old binaries would refuse. The
trade-off is that the compatibility contract must be made explicit and tested, and old
binaries cannot understand relative intent. That is acceptable for a new feature whose
fallback is always present.

### 6.3 Monitor anchor resolution

The anchor is a durable monitor identity plus an optional physical path instance.

Resolution algorithm for one anchor against one topology snapshot:

1. If the topology is unavailable, return `unavailable`.
2. Collect monitors whose `IdentityToken` equals `monitor.identity` exactly.
3. If `monitor.instance` is present:
   - prefer a candidate whose `DevicePathInstance` matches case-insensitively;
   - if exactly one such candidate exists, resolve it;
   - if more than one exists, return `ambiguous`;
   - if none exists but exactly one identity candidate exists, resolve that candidate (the
     monitor moved ports but is still the same hardware);
   - if none exists and multiple identity candidates exist, return `ambiguous`;
   - if there are no identity candidates, return `missing`.
4. If `monitor.instance` is absent:
   - exactly one identity candidate -> resolve;
   - multiple identity candidates -> `ambiguous`;
   - no candidates -> `missing`.
5. Validate the selected monitor's basis rectangle (`WorkRect` or `MonitorRect`). A
   non-positive width/height returns `basis-unavailable`.

Design reasons:

- EDID identity survives reconnects, port changes (when the serial is unique), reordering
  and primary changes.
- The device-path instance disambiguates identical EDID identities and follows the physical
  port. It is a tie-breaker, not the primary identity.
- If a monitor moves to another port and its identity is unique, the instance mismatch is
  tolerated. If two identical monitors exist, the ambiguity is reported rather than guessed.
- A `path:` identity is inherently port-dependent; it is still durable across reconnects to
  the same port and is the only identity available when EDID has no meaningful serial.
  `show-layout` should mark path-based anchors as less durable.
- Monitor ordinals, primary role, friendly name, resolution, LUIDs and target ids are never
  used for resolution.

Capture should write `monitor.instance` whenever the identity is EDID-based and the
instance is available. Writing it always gives deterministic duplicate-monitor behavior.

### 6.4 Coordinate model

Relative rectangles are normalized fractions of the chosen basis:

- `basis: "workArea"` uses the monitor's `WorkRect` (taskbar/dock excluded).
- `basis: "monitor"` uses the full `MonitorRect` (edge-to-edge; useful for borderless or
  deliberately overlapping layouts).
- `basis` is required; there is no implicit default. Examples use `workArea`.

Capture (`rect` is the captured outer window rectangle):

```text
left   = (rect.x - basis.x) / basis.w
top    = (rect.y - basis.y) / basis.h
right  = (rect.x + rect.w - basis.x) / basis.w
bottom = (rect.y + rect.h - basis.y) / basis.h
store x = left, y = top, w = right - left, h = bottom - top
```

Restore (edge-based rounding):

```text
left   = Round(basis.x + x * basis.w)
right  = Round(basis.x + (x + w) * basis.w)
top    = Round(basis.y + y * basis.h)
bottom = Round(basis.y + (y + h) * basis.h)
w      = max(1, right - left)
h      = max(1, bottom - top)
```

Rounding and precision:

- Use `MidpointRounding.AwayFromZero`, never banker's rounding.
- Round the left/top/right/bottom edges, then derive width/height. This preserves the
  requested edges better than rounding position and size independently.
- Store fractions rounded to 6 decimal places. At 8K width, 6 decimals is well below one
  pixel, and it avoids noisy repeated-save churn.
- Serialize numbers invariantly (`ConvertTo-Json` already uses invariant culture; verified
  with a `de-DE` thread culture probe). CLI rendering of fractions must also use invariant
  formatting.
- Reject values whose resolved coordinates do not fit `Int32`.
- Minimum 1 px width/height keeps the resulting rectangle valid. Do not query or fight
  application minimum sizes; the relative rectangle is a target request, and the actual
  captured rectangle on the next save reflects what Windows/apps enforced.

Geometry semantics:

- `GetWindowRect` / `SetWindowPos` operate on the outer window rectangle today; relative
  capture and restore use the same rectangle, so no new frame/client distinction is
  introduced.
- Negative monitor origins (for example a monitor at `x = -1920`) work directly because the
  basis origin is subtracted.
- Deliberate overlap is represented by overlapping fractions.
- A window spanning monitors can be represented relative to one anchor with `w > 1` or
  `x < 0`. Multi-anchor spans are not modeled; they are inherently ambiguous when the
  topology changes.
- No clamping to the work area or monitor is performed. Reachability is diagnostic and
  policy-driven, not geometric correction. It continues to use monitor rectangles, not work
  areas, preserving the existing reachability semantics.

### 6.5 DPI and coordinate contract

- Do not change process DPI awareness. The current process is DPI-unaware, and all existing
  absolute layouts are captured and applied in that space.
- Relative fractions are fractions of the monitor/work rectangle in the current DevWS
  virtual-screen coordinate space, not of raw physical pixels.
- `DpiEffective` / `ScalePercent` are not used in the coordinate math. Using them to convert
  fractions would double-apply Windows DPI virtualization.
- A scaling change that changes the virtualized monitor/work rectangle automatically
  changes the resolved absolute rectangle; a scaling change that does not change the
  virtualized rectangle leaves the resolved rectangle unchanged. Both are consistent with
  the process's coordinate space.
- Physical-pixel exactness is not promised. Windows may apply DPI virtualization when a
  window is moved across monitors with different scaling; DevWS already lives with this for
  absolute layouts.
- If DevWS ever adopts per-monitor DPI awareness, that is a breaking coordinate-space change
  and needs a versioned migration, not a silent reinterpretation.

### 6.6 Resolution precedence and profiles

Recommended per-item precedence:

1. **Matched exact profile entry.** If the current topology matches a profile and that
   profile has an entry for the item, use the profile's absolute rectangle. An unreachable
   profile rectangle refuses the operation, as today.
2. **Relative layout.** If there is no profile entry for the item and `layoutMode` is
   `"relative"`, resolve the anchor and use the computed absolute rectangle.
3. **Absolute fallback.** Otherwise use `item.layout`. If it is unreachable, skip movement
   with a warning, as today.

Set-level profile selection is unchanged. A profile match remains an exact-topology
statement and takes precedence over relative intent. Relative mode is a fallback layer for
topologies that are not covered by a profile entry. This preserves existing profile
semantics and avoids changing profile capture/routing in phase 1.

Consequences:

- A profile entry can intentionally override a relative item for one exact topology.
- `ws save-layout --profile <id>` captures all enabled items, including relative items, as
  absolute profile entries. The profile is an exact snapshot. It leaves `item.layout` and
  `layoutRelative` untouched. The relative fields remain for other topologies but are not
  used on the matched topology.
- An unreachable matched profile entry still refuses, even if the relative fallback would be
  reachable. The exact profile is explicit configuration, not a suggestion.
- Profile-enabled sets retain the existing strict refusal contract. If topology is
  unavailable, incomplete or ambiguous, if two profiles share a matcher, or if a matched
  profile rectangle is unreachable, launch/reset refuses before any side effect. This holds
  even when every target item is relative; relative fallback never relaxes profile safety.
  A relative-only bypass is not part of this design and would require a separate,
  explicitly approved change.
- On a safely matchable topology, if a matched profile omits an item and that item is
  relative, the relative layer is used. A missing or ambiguous relative anchor then degrades
  to the absolute fallback with a warning, as described in section 6.7. This is an
  item-level fallback, not a profile refusal.
- Relative layouts are not accepted inside profile `layouts` in phase 1. Profiles remain
  absolute-only, and their strict schema is not extended.
- A taskbar/work-area change may not invalidate an exact profile matcher (work area is not
  part of the signature), so a matched profile's absolute entry still wins on that topology.
  Users who want work-area adaptation on a profiled topology should omit that item from the
  profile or avoid profiling that topology. This is a documented trade-off of exact
  profiles, not a silent mode switch.

### 6.7 Missing, ambiguous and unreachable policy

The policy depends first on whether the set has profiles. Profile-enabled lifecycle safety
is unchanged; profile-free relative sets have separate per-item fallback rules.

#### 6.7.1 Profile-enabled sets

Profile-enabled launch/reset retains the strict refusal contract:

- topology unavailable -> refuse before side effects;
- topology incomplete -> refuse;
- topology ambiguous -> refuse;
- duplicate profile matchers -> refuse;
- matched profile entry unreachable -> refuse;
- this applies even if every target item is relative; no relative-only bypass is approved.

When topology is safely matchable:

- a matched profile entry wins and no relative anchor is needed;
- if the matched profile omits an item and the item is relative, the relative layer is used;
- a missing or ambiguous relative anchor -> absolute fallback warning; if that fallback is
  also unreachable, skip movement with a warning;
- an unreachable relative target -> the same absolute fallback path.

Profile-enabled save/save-layout keeps the existing profile-aware topology and write-scope
refusals. A profile-targeted save writes absolute profile entries only. A fallback-scope
save that dual-writes relative items additionally requires a uniquely selectable anchor from
the captured rectangle (or a resolvable stored anchor when the capture is fully off-screen)
and a stable topology A/B relative key; otherwise it refuses all-or-nothing.

#### 6.7.2 Profile-free relative sets

Launch/reset never refuses the whole profile-free operation solely because a relative anchor
is missing or topology is unavailable. It degrades per item:

- topology unavailable (`Available = false`, no monitor rectangles) -> warn and set
  `ApplyGeometry = false` for the relative item. Reachability cannot be established, so the
  absolute fallback is not applied blindly. Absolute items in the same set keep their
  existing absolute-placement behavior.
- anchor missing, ambiguous or unusable on an available topology -> use the absolute
  fallback only after applying the existing reachability rules; skip if the fallback is
  unreachable.
- relative target unreachable -> the same absolute fallback path after reachability.
- absolute fallback unreachable -> skip movement with warning.

Save/save-layout is different because it persists intent and re-anchors from the captured
rectangle:

- topology unavailable -> refuse all-or-nothing;
- no unique anchor can be selected from the capture (tie for greatest visible area, or zero
  visible area with no resolvable stored anchor) -> refuse all-or-nothing;
- topology A/B changes -> refuse;
- otherwise re-anchor from the captured rectangle and dual-write in fallback scope. A
  stored anchor that is absent from the current topology does not by itself block the save
  when the captured rectangle is visible on exactly one monitor.

#### 6.7.3 Profile-free absolute sets

No topology access. Existing absolute behavior and the zero-topology fast path are unchanged.

#### 6.7.4 Policy summary

| Set kind / operation | Topology unavailable | Missing or ambiguous anchor | Relative target unreachable |
| --- | --- | --- | --- |
| Profile-enabled launch/reset | Refuse (existing) | On a matchable topology with no profile entry: absolute fallback warning; skip if fallback unreachable | Absolute fallback warning; skip if fallback unreachable |
| Profile-free relative launch/reset | Warn + `ApplyGeometry = false` for the relative item; absolute items keep existing behavior | Absolute fallback only after reachability; skip if fallback unreachable | Absolute fallback only after reachability; skip if fallback unreachable |
| Profile-free relative save/save-layout | Refuse | Re-anchor from capture; refuse only if selection is ambiguous or zero-visible without a resolvable stored anchor | Re-anchor from capture; same selection rule |
| Profile-free absolute launch/reset/save | No topology access | n/a | n/a |

`show-layout` reports the effective fallback and reason for each degraded item. For a
profile-enabled set it also reports the profile/topology status; it never implies that a
refused profile operation was applied.

Alternative missing-monitor policies considered:

- **Refuse the whole operation.** Safest for intent, but makes dock/undock and laptop use
  fragile. Reject.
- **Skip movement.** Avoids a wrong placement but leaves the OS default position. Use only
  when the absolute fallback is also unreachable.
- **Nearest-monitor remap.** Adaptive, but silently moves windows to a monitor the user did
  not choose. Reject.
- **Absolute fallback with a warning (recommended).** Predictable, uses the universal
  fallback, and preserves the explicit-operation model.

Policy principles:

- Missing anchor is not a reason to move a window to a different monitor. The absolute
  fallback is predictable; nearest-monitor remapping is not.
- A relative item is a fallback-capable item, not a hard profile. Therefore an unreachable
  relative target degrades to the absolute fallback with a warning, rather than refusing the
  whole operation.
- Persisting a relative layout requires a resolved anchor. Save refuses rather than writing
  a half-correct relative target.

### 6.8 Capture, save and save-layout

`ws save-layout` and the geometry half of `ws save` gain relative-aware capture. The
re-anchor steps below apply only when a relative item is written to **fallback scope**;
profile-targeted saves write absolute profile entries and do not re-anchor relative items.

1. Capture all enabled items as today (all-or-nothing).
2. For each relative item written to fallback scope, choose the anchor for the captured
   rectangle:
   - compute the visible intersection area with each monitor's full monitor rectangle;
   - choose the monitor with the strictly greatest visible area;
   - a tie for greatest area refuses the save;
   - if the captured rectangle has no visible area, keep the item's existing anchor if it
     resolves uniquely; otherwise refuse.
3. Preserve the item's `basis`. Compute the normalized rectangle against the chosen
   monitor's basis rectangle.
4. Write `layoutRelative` with the chosen identity and instance (when available), and
   dual-write `item.layout` to the captured absolute rectangle.
5. Do not change `layoutMode`.
6. Validate the complete in-memory document and perform exactly one canonical save.

Topology sampling and stability:

- A set with no profiles and no relative items keeps the legacy zero-topology save path.
- A set with relative items written to fallback scope samples topology A before capture and
  topology B before commit. The stability key must include each relative anchor's resolution
  and the relevant basis rectangles; the existing profile signature/fingerprint is not
  sufficient because it excludes work area.
- A set with profiles keeps the existing full matchable/stability gate. If a fallback-scope
  save also updates relative items, both the profile gate and the relative key must pass.
- If topology A/B differ, the save refuses and leaves the canonical file unchanged.

#### 6.8.1 Save target versus item mode

| Save target | Absolute item | Relative item | Geometry fields written |
| --- | --- | --- | --- |
| Profile-targeted: implicit matched profile or explicit `--profile <id>` | Absolute entry in `profile.layouts` | Absolute entry in `profile.layouts` (exact-topology snapshot); `layoutRelative` and `item.layout` untouched | `profile.layouts` only |
| Fallback scope: no profiles, no profile match, or explicit `--layout fallback` | `item.layout` | `layoutRelative` + `item.layout` | Universal fallback only |

Rules:

- **A profile-targeted save never dual-writes.** It must not update `item.layout` or
  `layoutRelative`, even when the item is relative. The profile entry is an exact-topology
  absolute snapshot; the relative layout remains the fallback for other topologies.
- **Relative dual-write is fallback-scope only.** A fallback-scope save updates
  `layoutRelative` and `item.layout` for a relative item, and `item.layout` for an absolute
  item. It does not modify profile entries.
- A profile-targeted save of a relative item does not convert the item to absolute and does
  not clear `layoutRelative`.
- Because a profile-targeted save never re-anchors, it does not run relative re-anchor or
  relative dual-write logic; it only needs the existing profile topology/write-scope
  validation.
- `ws save` follows the same table for geometry. Its cwd/path/active-tab work is independent
  and never changes the save scope.
- `--layout fallback` is the explicit way to reach fallback scope while a profile matches.
  Without it, a profile-targeted save intentionally leaves relative/fallback fields
  untouched.
- Recommended addition: `ws save-layout --layout fallback` (and `ws save --layout fallback`)
  forces fallback scope, so users can refresh relative/absolute fallbacks even while an exact
  profile matches.

`ws save` applies the same geometry gate before its cwd/active-tab work. If relative
resolution or re-anchoring fails, no cwd, path, active-tab or geometry mutation is
persisted.

### 6.9 `ws show-layout`

`show-layout` remains read-only and should display the effective policy and the rectangle
that launch/reset would apply, not just stored intent. When launch would refuse (for example
an unreachable profile entry), it should show that refusal condition rather than implying a
placement. Proposed fields per item:

- item id and type, as today;
- effective absolute rectangle, as today;
- source: `profile '<id>'`, `relative`, or `fallback`;
- for relative items: full anchor identity, optional instance, basis, and the normalized
  rectangle;
- when relative resolution degrades: the reason (`anchor missing`, `anchor ambiguous`,
  `topology unavailable`, `relative target unreachable`) and the fallback rectangle; for
  `topology unavailable` on a profile-free relative item, state that no geometry will be
  applied because reachability cannot be established;
- existing `[disabled]` and `[unreachable]` markers;
- a note when a path-based anchor is less durable than an EDID anchor.

Sketch:

```text
Saved layout for set 'main'
  topology    fingerprint 1a2b3c4d5e6f
  layout      profile 'docked' (exact topology match)
  profiles    docked, laptop

  ide            app       x=2560 y=0 w=1280 h=1400  [profile 'docked']
  terminal       terminal  x=0 y=0 w=1280 h=1400     [relative edid:DEL-A1B2-ABC123 workArea 0,0,0.5,1]
  notes          app       x=0 y=0 w=800 h=600       [relative anchor missing -> fallback]
```

Formatting requirements:

- Fractions use invariant culture and at most 6 decimal places.
- Negative absolute coordinates render as-is.
- Full identity tokens are shown, as `ws monitors` already does.
- The output must not imply that relative intent was applied when the fallback was used.

### 6.10 Launch and reset

- Topology is required when the target set has profiles or any enabled target item has
  `layoutMode: "relative"`.
- Profile-free absolute sets keep the existing hard fast path with zero monitor access.
- Profile-free relative sets take exactly one topology snapshot and freeze the resolved
  absolute rectangles. There is no second sample during placement.
- Profile-aware sets keep the existing unsafe-topology refusal and exact-profile behaviour.
- When topology is unavailable for a profile-free set, each relative item records a
  deterministic warning and `ApplyGeometry = false` because reachability cannot be
  established. Absolute items in that set keep their existing absolute-placement behavior.
- When topology is available but a relative anchor is missing, ambiguous or unusable, the
  plan records a warning and uses the absolute fallback only after reachability; it uses
  `ApplyGeometry = false` if the fallback is unreachable.
- The frozen plan still carries only absolute integer rectangles. The elevated broker and
  reset worker never see anchor metadata and never sample topology.
- A monitor change after the plan is frozen does not trigger rearrangement. The next
  explicit launch/reset observes the new topology.
- Terminal reset uses the same lifecycle plan and therefore the same relative resolution as
  a full launch.

### 6.11 Authoring and reset

Recommended minimal CLI surface:

```text
ws set-geometry <id> --relative --anchor <identity> [--instance <instance>]
                --basis workArea|monitor
                --x <fx> --y <fy> --width <fw> --height <fh>
ws set-geometry <id> --mode absolute
```

- `--relative` requires an anchor and a basis. All four fractions are supplied explicitly;
  the command remains config-only and does not sample topology or read live windows. It
  validates syntax and stores intent; it does not prove the anchor is currently present.
  `show-layout` and launch report that separately.
- `--relative` and `--layout <profileId>` are mutually exclusive: `--relative` edits the
  item's fallback relative layout, while `--layout` edits an absolute profile entry.
- `--mode absolute` removes `layoutRelative` and sets `layoutMode: "absolute"`.
  `item.layout` is preserved unless new absolute coordinates are supplied. Existing items
  may still omit `layoutMode`; both forms mean absolute.
- Plain `ws set-geometry` on a relative item refuses with an actionable message rather than
  silently editing a fallback that will not be used.
- `--layout <profileId>` continues to edit an absolute profile entry, regardless of the
  item's mode.
- `ws save-layout` remains the capture path that refreshes relative rectangles from live
  windows.

Alternative: a dedicated `ws layout-mode <id> relative|absolute` command that can capture
the current window and establish the anchor. This is friendlier but adds a command and live
capture semantics. It can be deferred if the explicit `set-geometry --relative` form is
accepted.

`ws reset-layout`:

- continues to restore absolute `item.layout` from the bundled default by id/type/windowId;
- for each matched item, removes `layoutRelative` and sets/removes `layoutMode` so the item
  is absolute again;
- leaves `layoutProfiles` untouched, as today;
- reports which items had relative mode cleared;
- remains config-only and moves no windows.

Rationale: the bundled default is absolute-only. If reset copied only `item.layout` but left
relative mode active, a launch would ignore the reset and reapply the old relative target.
Clearing relative fields is the only coherent meaning of "restore the baseline" for a
relative item. This is an explicit reset operation, not a silent mode switch.

Copy and mutation coverage:

| Operation | Required behavior |
| --- | --- |
| `Clone-DevWSTerminal` / `ws clone-terminal` | Copy `layoutMode` and a deep copy of `layoutRelative`. |
| `Clone-DevWSApp` / `ws clone-app` | Copy `layoutMode` and a deep copy of `layoutRelative`. |
| `Copy-DevWSTerminalDefinition` / `Copy-DevWSAppDefinition` (used by `clone-set`) | Copy both fields; do not reconstruct the item from known non-relative fields only. |
| `Clone-DevWSSet` | Preserve both fields through the definition-copy helpers. |
| `add-terminal` / `add-app` | Create absolute items with no relative fields. |
| `reset-layout` | Intentionally clear both fields for matched items, restoring the absolute baseline. |
| `set-geometry --mode absolute` | Intentionally clear `layoutRelative` and set absolute mode. |
| `rename`, `set-*` and other field mutations | Preserve both fields. |
| `ws edit` | Validate both fields and write them through the atomic save. |
| `Copy-DevWSLayout` | Remain absolute-only; do not overload it. Add `Copy-DevWSRelativeLayout` for a deep copy of `monitor`, `basis` and `rect`. |

A clone helper that copies only `layout` is a compatibility bug in the new implementation.
The new code should use a shared item-copy helper, or explicitly copy both fields in every
reconstruction site. The installer's historical-v3 instance-mode enrichment mutates items in
place and must preserve both fields; that path also needs a regression test.

### 6.12 Security and trust boundary

- Anchor resolution is normal-side, read-only and uses the existing monitor topology
  library.
- The privileged broker and reset worker receive absolute integer rectangles only. They do
  not need monitor identity, topology or relative math.
- The existing lifecycle-plan shape validation remains sufficient: resolved rectangles are
  ordinary absolute rectangles with positive width/height.
- No new display configuration mutation API, no new privileged surface, and no new
  background process.

---

## 7. Migration, downgrade and copy behavior

### 7.1 Existing configurations

- A v3 document without `layoutMode`/`layoutRelative` is unchanged and behaves exactly as
  today. No migration, no rewrite, no installer action.
- The installer's valid-v3 preservation path remains valid. The implementation must add a
  regression test that a valid v3 document containing the new fields survives installer
  validation/migration byte-for-byte where the current installer already preserves v3.
- `layoutMode` is optional and absent means absolute. No existing item needs a new field.

### 7.2 New code reading old configurations

- Absent `layoutMode` means absolute. No topology sampling is added for profile-free
  absolute sets.
- Existing profiles, save routing, launch/reset and show-layout output remain unchanged
  except for the new optional display of mode/anchor data.

### 7.3 Downgrade compatibility guarantees

The guarantee is **structural/load compatibility plus a deterministic absolute fallback**,
not semantic preservation of relative intent. This distinction is part of the contract.

| Contract | Guarantee | Verification |
| --- | --- | --- |
| Load a relative v3 document in an old binary | Guaranteed: unknown item properties are tolerated, and `item.layout` remains mandatory. | Compatibility fixture plus previous-release smoke test. |
| Launch/reset in an old binary | Guaranteed structural behavior: relative fields are ignored; existing profile/absolute placement semantics are used, with `item.layout` as the universal fallback. | Fixture launch plan / previous-release smoke test. |
| Read/write/reset preservation | Guaranteed for fields the old command does not rewrite: unknown item properties survive parse, save and `Set-DevWSLayout`. | Round-trip, old-save and old-reset regression tests. |
| Old clone behavior | **Not guaranteed**: the current clone helpers reconstruct items from known fields and drop `layoutMode`/`layoutRelative`; the clone becomes absolute. | Documented; new-code clone tests plus a previous-release smoke check. |
| Old save/reset semantic fidelity | **Not guaranteed**: old fallback-scope writes update absolute geometry only; old profile-targeted writes update profile entries only. In either case `layoutRelative` is not updated and can become stale. | Stale-divergence regression test. |
| Schema migration | No migration. The document stays version 3; the installer preserves it. | Installer preservation test. |

"Old binary" here means the v0.2.0/current baseline, which treats unknown item properties as
opaque. The v0.2.0 release target (`1ec4392d...`) and current `main` have identical
`devws-config.ps1`, `devws-mutation.ps1`, `devws-layout-profile.ps1` and
`devws-lifecycle-layout.ps1` for this contract (verified by diff), so the source-level
behavior above is also the release behavior. This is not a promise that arbitrary future
binaries will preserve unknown fields; the compatibility contract must remain tested.

### 7.4 Required copy behavior in the new implementation

Section 6.11 contains the full copy matrix. The implementation requirements are:

- `Copy-DevWSLayout` remains absolute-only. Add `Copy-DevWSRelativeLayout` for a deep copy
  of `monitor`, `basis` and `rect`.
- `Clone-DevWSTerminal` and `Clone-DevWSApp` must copy `layoutMode` and
  `layoutRelative` explicitly.
- `Copy-DevWSTerminalDefinition` and `Copy-DevWSAppDefinition`, and therefore
  `Clone-DevWSSet`, must copy both fields. Reconstructing an item from only its known
  non-relative fields is a bug.
- `add-terminal` and `add-app` create absolute items with no relative fields.
- `reset-layout` and `set-geometry --mode absolute` are the only intentional clearers.
- `rename`, `set-*` and `ws edit` must preserve the fields.
- The installer's historical-v3 instance-mode enrichment mutates items in place; it must
  preserve both fields and needs a regression test.

Tests must cover each clone path independently: clone-terminal, clone-app, clone-set, and
the item-definition copy helpers. A source item with a relative anchor must produce a clone
with the same mode, anchor, basis and normalized rectangle, and the clone must remain
independent for later edits.

### 7.5 Stale relative metadata after older writes

An old `save-layout`, `save` or `reset-layout` can update `item.layout` while leaving
`layoutRelative` untouched. After re-upgrading:

- relative mode resumes;
- the relative layer is used on topologies without a matching profile entry;
- the newer absolute `item.layout` remains the fallback when the relative anchor is
  missing, ambiguous or unreachable.

This is intentional and is not silently "repaired." The relative fields are the explicit
intent; old code cannot update them. A user who wants the old absolute behavior before
downgrading should run:

```text
ws set-geometry <id> --mode absolute
```

or remove `layoutMode`/`layoutRelative`. A future `ws doctor` stale-relative check is
deferred. The test suite must simulate an old absolute-only write and verify that the
relative fields remain byte-identical and that a new-code resolver still uses them.

### 7.6 Future schema version

A v4 schema is only warranted if DevWS needs one of the deferred capabilities:

- relative entries inside profiles;
- fixed-pixel relative units;
- a strict item allowlist;
- per-monitor DPI-aware coordinate space;
- a different anchor model (aliases, zones, multi-anchor spans).

None of those is required for the first relative-layout release.

### 7.7 Operation matrix

| Operation | Old absolute config | New relative config (old binary) | New relative config (new binary) |
| --- | --- | --- | --- |
| Load / list / show | Unchanged | Loads; relative ignored | Loads; relative visible |
| Launch / reset | Absolute | Ignores relative; existing profile/absolute semantics | Profile > relative > absolute |
| Save-layout, fallback scope | Absolute | Updates absolute only; relative stale | Updates relative + absolute |
| Save-layout, profile-targeted | Absolute | Updates profile only; relative/fallback unchanged | Updates profile only; relative/fallback untouched |
| Save, fallback scope | Absolute | Updates absolute and cwd/active-tab; relative stale | Same plus relative geometry |
| Save, profile-targeted | Absolute | Updates profile and cwd/active-tab; relative/fallback unchanged | Updates profile and cwd/active-tab; relative/fallback untouched |
| Reset-layout | Absolute | Updates absolute only; relative stale | Clears relative for matched items |
| Clone | Copies absolute | Drops relative fields | Copies relative fields |
| Installer | Preserves v3 | Preserves v3; relative ignored | Preserves v3; relative active |

---

## 8. Decisions required before implementation

These are the implementation decisions and their recommended exact wording. The provisional
approval settles the direction of D1, D6 and D8; the table records the details that must
still be confirmed before code changes. The recommendation column is the design team's
recommendation, not a final approval. D1-D10 and D12-D14 are needed before phase 1. D11
(the authoring CLI) is needed before phase 5; phases 1-4 can proceed with the schema and
internal behaviour first.

| ID | Decision | Recommendation | Main alternative | Why it matters |
| --- | --- | --- | --- | --- |
| D1 | Schema version and shape | Stay v3; add optional `layoutMode` + `layoutRelative` per item | v4 schema; sidecar | Controls migration, downgrade and installer work. v3 additive gives structural compatibility to old binaries; semantic relative support does not downgrade. |
| D2 | Mode authority | Explicit per-item mode; absent means absolute; no inference | Infer from presence of relative object | Prevents silent mode switches and inconsistent configs. |
| D3 | Anchor reference | Durable `identity` plus optional `instance` tie-breaker | Identity only; ordinal; topology token | Duplicate identical monitors are otherwise ambiguous. Ordinals are not durable. |
| D4 | Coordinate basis | Required per-item `basis`: `workArea` or `monitor` | Global default; work area only | Taskbar and borderless layouts need different bases; explicit is safer. |
| D5 | Units | Normalized fractions for phase 1 | Monitor-local pixels; hybrid | Fractions meet the resolution/rearrangement goal; pixels are a future fixed-size option. |
| D6 | Precedence and profile safety | Matched profile entry > relative > absolute fallback; profile-enabled lifecycle keeps strict refusal and no relative-only bypass | Relative > profile; allow relative-only bypass on unsafe topology | Preserves existing exact-profile semantics and the approved refusal contract. |
| D7 | Missing/ambiguous policy | Profile-free relative launch/reset: unavailable topology -> warn + `ApplyGeometry = false` for the relative item, absolute items unchanged; missing/ambiguous anchor on an available topology -> absolute fallback only after reachability; never remap. Save re-anchors from capture; refuses only when no unique anchor can be selected. | Refuse; skip; nearest monitor | Keeps explicit operations usable across dock/undock without surprising moves or unsafe persistence. |
| D8 | Save scope and re-anchor | Profile-targeted save writes profile entries only and never dual-writes; fallback-scope relative save re-anchors by greatest visible area and dual-writes `layoutRelative` + `item.layout`; tie/zero-visible without anchor refuses | Allow any save to update the fallback; preserve stored anchor always | Keeps exact-profile snapshots separate from universal fallback writes. |
| D9 | Topology sampling | One snapshot for launch/reset; A/B stability for save; relative key includes basis rects; profile-enabled A/B gate unchanged | Always sample; no stability check | Preserves the profile-free fast path and prevents half-correct saves. |
| D10 | Reset behaviour | Restore absolute layout and clear relative fields for matched items; profiles untouched | Leave relative mode; refuse reset | Otherwise reset-layout would not affect the next launch. |
| D11 | Authoring surface | `set-geometry --relative` plus `--mode absolute`; recommended `save-layout --layout fallback` | Dedicated `layout-mode` command | Keeps CLI surface small; exact choice can be finalized before phase 5. |
| D12 | Rounding/precision | Edge-based, 6-decimal capture, away-from-zero, 1 px minimum | Round position/size independently; more decimals | Deterministic round-trips and stable config files. |
| D13 | DPI contract | No awareness change; fractions over current virtualized coordinates | Switch to per-monitor DPI awareness | Changing awareness would reinterpret every existing absolute layout. |
| D14 | Downgrade and copy contract | Structural/load compatibility only: old binaries load relative v3, ignore relative fields, use profile/absolute placement, and may leave relative stale on writes. No semantic downgrade guarantee. New clone helpers must copy relative fields. | Bump to v4 and refuse old binaries | Honest guarantees, explicit copy behavior and regression tests; no silent claim of semantic fidelity. |

Three decisions deserve particular review:

- **D6:** The approved direction keeps the exact-profile layer first. Profile-enabled
  lifecycle operations retain the existing strict refusal contract; there is no
  relative-only bypass in this design. Making `layoutMode` absolutely authoritative would
  be a separate product decision and would require a different save split.
- **D8:** Save scope is now explicit: profile-targeted saves never dual-write, and only
  fallback-scope saves update universal fallbacks. Re-anchoring remains a fallback-scope
  behavior. The alternative is to preserve the stored anchor always, which is simpler but
  counterintuitive when a user drags a window to another monitor and saves.
- **D14:** Downgrade compatibility is structural, not semantic. Old binaries can load and
  run relative configurations through the absolute fallback, but they cannot preserve
  relative intent, and old clones can drop the new fields. The new implementation must copy
  relative fields explicitly and tests must assert the documented behavior.

---

## 9. Deferred details

These are intentionally not required for the first implementation:

- monitor-local pixel units and a fixed-size mode (`unit: "pixels"`);
- relative rectangles inside profiles;
- grid/zone presets or named zones;
- monitor aliases or a user-facing anchor label;
- multi-anchor spans for windows crossing several monitors;
- automatic re-anchoring when a monitor returns;
- nearest-monitor remapping;
- querying application minimum sizes via `WM_GETMINMAXINFO`;
- per-monitor DPI awareness or physical-pixel placement;
- stale-relative detection in `ws doctor`;
- automatic profile selection or a bypass for relative-only target sets on unsafe topologies
  (requires explicit approval);
- `ws save-layout --exclude-relative` or other sparse profile capture controls;
- v4 migration tooling and installer changes;
- analytics or telemetry.

---

## 10. Incremental implementation plan

The sequence is designed so each phase is independently reviewable and the existing
behaviour remains intact until the relevant phase is accepted.

### Phase 0 -- Design sign-off

- Review this document and settle decisions D1-D14.
- Freeze the schema shape, anchor semantics, precedence, profile refusal contract, fallback
  policy, save scope, re-anchor rule and clone/copy contract.
- Do not modify production files.

**Exit:** approved decisions recorded; no code changed.

### Phase 1 -- Schema and pure model

- Extend `src/lib/devws-config.ps1` with validation for the optional fields. Do not add a
  strict item allowlist.
- Add a pure relative-layout library, for example `src/lib/devws-relative-layout.ps1`, with:
  - anchor parsing and monitor resolution;
  - capture/restore fraction math and edge rounding;
  - save re-anchor selection;
  - relative topology stability keys;
  - deterministic reason/status objects;
  - `Copy-DevWSRelativeLayout` for a deep copy of `monitor`, `basis` and `rect`.
- Reuse the existing topology model in `src/lib/devws-monitor.ps1`; do not add native code.
- Add the new library to the installer's library manifest and test fixtures. No installer
  behaviour change.
- Add a `relative-layouts` test group with pure tests, including the old-baseline
  compatibility fixture and the stale-relative fixture.

**Exit:** old absolute configs valid and unchanged; pure math/resolution tests pass; full
existing suite green; no CLI behaviour change yet.

### Phase 2 -- Read-only visibility

- Extend `Get-DevWSEffectiveLayout` and `Get-DevWSEffectiveLayoutLines` to resolve relative
  items and expose mode/anchor/basis/fraction/source/fallback reason.
- Extend `ws show-layout` output; keep effective rectangles as the applied truth.
- Optionally show the device-path instance in `ws monitors` for anchor debugging.
- Add display tests, including negative coordinates and invariant decimal formatting.

**Exit:** `ws show-layout` explains exactly what launch/reset would apply; no launch
behaviour changed.

### Phase 3 -- Lifecycle resolution

- Extend `New-DevWSLifecycleLayoutPlan` and the frozen-plan helpers to be relative-aware.
- Keep the profile-free absolute fast path with zero topology access.
- For relative sets, sample topology once and freeze absolute rectangles.
- Emit deterministic warnings for missing/ambiguous anchors and unreachable relative
  targets; use absolute fallback only after reachability. For profile-free relative items on
  unavailable topology, warn and set `ApplyGeometry = false`; absolute items in the same set
  keep their existing behavior.
- Keep profile-aware unsafe-topology refusal unchanged.
- Update launch trace fields if useful (relative item count, fallback reasons).

**Exit:** launch, terminal reset and elevated broker paths apply the same frozen rectangles;
topology provider call-count tests pass; no background sampling.

### Phase 4 -- Capture and save

- Extend `Get-DevWSLayoutSavePlan`, `Confirm-DevWSLayoutSaveTopology` and the save functions
  to require topology for relative sets and to use the relative stability key.
- Implement the section 6.8.1 save-scope table exactly: profile-targeted saves write only
  `profile.layouts` and must not touch `item.layout` or `layoutRelative`; fallback-scope
  saves re-anchor and dual-write `layoutRelative` + `item.layout` for relative items.
- Add `--layout fallback` support if accepted in D11.
- Keep all-or-nothing behaviour and one canonical write.
- Ensure `ws save` geometry failure aborts before cwd/active-tab persistence.

**Exit:** save/save-layout tests cover re-anchor, tie refusal, missing anchor, topology
change, profile-targeted no-dual-write, fallback dual-write and atomicity; profile-free
absolute saves still do zero topology reads.

### Phase 5 -- Authoring, reset and mutation coverage

- Add `set-geometry --relative` and `--mode absolute` (or the approved alternative).
- Update `ws reset-layout` to clear relative fields for matched items.
- Update clone/copy paths per section 6.11: `Copy-DevWSLayout` stays absolute-only, add
  `Copy-DevWSRelativeLayout`, and update `Clone-DevWSTerminal`, `Clone-DevWSApp`,
  `Copy-DevWSTerminalDefinition`, `Copy-DevWSAppDefinition` and `Clone-DevWSSet` to copy
  both fields.
- Update help text, `docs/configuration.md`, `docs/cli.md`, `docs/architecture.md` and
  `docs/future-work.md`.
- Add CLI, reset, clone and help tests, including one test per clone path.

**Exit:** users can create, update and remove relative mode without hand-editing JSON;
reset is coherent; clone intent is preserved; docs match behaviour.

### Phase 6 -- Hardening and release readiness

- Run the targeted and full test suites.
- Run the real-host matrix in section 11.
- Verify installer valid-v3 preservation and a downgrade smoke test with the previous
  release binary: load, list/show, fallback launch/reset, absolute-only save/reset, and the
  documented clone limitation.
- Simulate an old absolute-only write and verify the stale-relative behavior in section 7.5.
- Measure launch/save overhead for relative sets; confirm profile-free absolute sets are
  unchanged.
- Update `CHANGELOG.md` and release notes only when implementation is approved.
- Do not create a tag or release without separate supervisory approval.

**Exit:** all gates green; design decisions and deferred items recorded; release decision
remains separate.

---

## 11. Targeted testing strategy

Most tests can use the existing synthetic topology model, injected `TopologyProvider`,
capture fixtures and CLI harness. Real monitors are only needed for the final smoke matrix.

### 11.1 Schema and compatibility

- Existing v3 absolute config validates and behaves identically.
- Valid relative `workArea` and `monitor` examples validate.
- Reject: missing `layoutRelative` in relative mode; relative object in absolute mode;
  relative object without `layoutMode`; invalid mode; invalid basis; non-finite or
  non-numeric fractions; zero/negative width/height; malformed identity; ordinal identity;
  malformed or forbidden instance; unknown fields inside `layoutRelative`.
- Confirm unknown item properties are still tolerated; add a compatibility fixture and a
  comment documenting the contract.
- Confirm `layoutMode`/`layoutRelative` survive `Save-DevWSConfig` round-trip and validation.
- Confirm invariant JSON number formatting under a comma-decimal culture.
- Confirm valid v3 relative configs survive installer validation/preservation.
- Confirm profile `layouts` still reject non-absolute rectangles and unknown profile
  properties.
- Old-baseline compatibility fixture: the prior validator/save path loads a relative v3
  document, `show-layout` uses absolute/profile placement, and an absolute-only save/reset
  leaves `layoutRelative` byte-identical.
- Clone compatibility fixture: the legacy clone shape drops relative fields; the new clone
  helpers copy them. This distinction is documented, not treated as a defect in old code.

### 11.2 Pure math and anchor resolution

- Same-topology capture/restore round-trip within 1 px, for both bases.
- Resolution change (for example 1920x1080 -> 2560x1440): left half, right half, quarter and
  full-work-area layouts resolve proportionally.
- Negative monitor origin (`x = -1920`, `y = -100`), negative fractions, off-screen windows
  and `w > 1` spans.
- Work-area basis adapts when the taskbar moves; monitor basis does not.
- Edge-based rounding at half-pixel midpoints; minimum 1 px; no banker's rounding.
- Duplicate identical EDID tokens: instance resolves; missing instance is ambiguous; port
  change with a unique identity resolves; port change with duplicate identities is
  ambiguous.
- Path-only identity resolves; monitor missing; basis rectangle invalid; Int32 overflow.
- Unavailable topology returns a structured `unavailable` status with no monitor rectangles;
  it never fabricates a basis or a reachability decision.
- Primary-role change, display reorder and topology order change do not affect resolution.
- DPI proxy tests: same fractions with virtualized rectangles at different scale percentages
  resolve proportionally; `ScalePercent` does not alter the math.
- Save re-anchor: strictly greatest visible area wins; tie refuses; zero visible keeps an
  existing resolvable anchor; zero visible with no anchor refuses.

### 11.3 Lifecycle

- Profile-free absolute set: topology provider is never called (existing guarantee).
- Profile-free relative set: exactly one topology call; plan frozen; no post-plan calls.
- Profile-free relative set, topology unavailable: relative items warn and set
  `ApplyGeometry = false`; absolute items in the same set retain existing absolute
  placement; no whole-operation refusal.
- Profile-free relative set, missing anchor on an available topology: absolute fallback
  only after reachability; skip if the fallback is unreachable; no `SetWindowPos` on the
  wrong monitor.
- Profile-free relative set, ambiguous anchor on an available topology: same.
- Relative target unreachable: absolute fallback; both unreachable -> `ApplyGeometry=false`.
- Matched profile entry wins over relative.
- Matched profile omits item -> relative is used.
- No profile match -> relative is used.
- Profile-enabled unsafe topology still refuses before side effects, even when every target
  item is relative; no relative-only bypass.
- Unreachable profile entry still refuses.
- Profile-enabled matchable topology, no profile entry, missing relative anchor: absolute
  fallback warning, not a profile refusal.
- Terminal reset and app launch consume the same frozen absolute rectangles.
- Elevated broker/reset worker receive only absolute integers; no topology calls.
- No monitor watcher: a topology change after plan creation does not move anything.

### 11.4 Save and save-layout

- A fallback-scope relative save re-anchors to the monitor with the greatest visible area
  and writes both `layoutRelative` and `item.layout`.
- Save tie and zero-visible-without-resolvable-anchor cases refuse with a byte-identical
  config; a missing stored anchor does not refuse when the captured rectangle selects a
  unique monitor.
- Profile-free relative save with unavailable topology refuses without writing.
- Profile-enabled save with unsafe/unmatchable topology keeps the existing refusal.
- Save refuses when topology A/B relative key changes (anchor moved, basis changed, monitor
  removed).
- **Profile-targeted save writes only `profile.layouts`.** For every relative item, both
  `item.layout` and `layoutRelative` remain byte-identical. This applies to an implicit
  matched-profile save and an explicit `--profile <id>` save.
- **Fallback-scope save writes only universal fallback fields.** It updates
  `layoutRelative` + `item.layout` for relative items and `item.layout` for absolute items;
  profile entries remain unchanged.
- A profile-targeted save of a relative item writes an absolute profile entry but does not
  convert the item to absolute or clear relative fields.
- `--layout fallback` works while a profile matches and is the explicit route to fallback
  dual-write.
- All-or-nothing with one uncapturable item leaves the config unchanged.
- `ws save` geometry failure leaves cwd/path/active-tab unchanged; a profile-targeted
  `ws save` updates cwd/active-tab but not universal geometry.
- Profile-free absolute save does zero topology reads.
- Relative save writes `instance` when available; path-only anchors omit it.

### 11.5 Display, CLI and mutation

- `show-layout` shows mode, anchor, instance, basis, normalized rectangle, effective absolute
  rectangle, source and fallback reason.
- Negative coordinates and large values render correctly; fractions use invariant decimals.
- `set-geometry --relative` parses fractional values and validates anchor/basis.
- Plain `set-geometry` on a relative item refuses with actionable text.
- `--mode absolute` clears relative mode and preserves or replaces `item.layout` as
  specified.
- `--layout <profile>` still edits an absolute profile entry.
- `reset-layout` restores absolute geometry, clears relative fields for matched items and
  preserves profiles.
- Each clone path copies `layoutMode` and a deep copy of `layoutRelative`: clone-terminal,
  clone-app, clone-set, and the definition-copy helpers. Mutating the clone's anchor or
  rectangle must not mutate the source.
- `add-*` defaults to absolute; `Copy-DevWSLayout` remains absolute-only.
- Help text and `docs/cli.md` mention the new surface.

### 11.6 Downgrade and release compatibility

Test the exact guarantees in section 7.3, including the non-guarantees:

- The previous release binary can load a new relative v3 config; `show-layout`/`list` use
  existing profile/absolute placement and do not crash.
- Previous-release `save-layout`/`save`/`reset-layout` update absolute or profile geometry
  only and leave `layoutRelative` unchanged; a re-upgrade uses the relative layer again.
- Simulate the stale-divergence case: mutate `item.layout` only, assert `layoutRelative` is
  byte-identical and the new resolver still uses it; assert the newer absolute value remains
  the fallback.
- Previous-release clone behavior drops relative fields; this is documented as not
  guaranteed and is not silently "fixed" in old code.
- New clone helpers copy both fields; tests cover terminal, app, set and definition copies.
- New binary reads old configs byte-for-byte and only rewrites when an explicit mutation
  occurs.
- Installer migration/repair of a valid v3 config preserves relative fields, including the
  historical-v3 instance-mode enrichment path.
- No changes to tags, releases or distribution repositories are made by the design work.

### 11.7 Real-host smoke matrix

- Single monitor, 1920x1080, 100%.
- Two monitors, different resolutions, secondary at a negative x origin, taskbar on the
  secondary.
- Mixed DPI (for example 150% + 100%).
- Dock/undock, primary switch, display reorder and resolution change.
- Identical-model monitors if available (otherwise synthetic coverage).
- Deliberate overlap and a mostly off-screen window.
- Verify monitor unplug does not move anything until the next explicit launch; verify the
  next launch uses the absolute fallback for a profile-free relative set, while a
  profile-enabled set retains its strict refusal contract on unsafe topology.
- Verify a profile-targeted save leaves universal fallback/relative geometry unchanged and a
  fallback-scope save updates relative + absolute.
- Verify `show-layout` matches what launch/reset actually applies.
- Verify an elevated terminal reset uses the same resolved rectangles.

### 11.8 Suggested targeted commands

```powershell
pwsh -NoLogo -NoProfile -File tests\run-tests.ps1 -Group relative-layouts
pwsh -NoLogo -NoProfile -File tests\run-tests.ps1 -Group validation,config-persistence,monitors
pwsh -NoLogo -NoProfile -File tests\run-tests.ps1 -Group layout-profiles,lifecycle-layouts
pwsh -NoLogo -NoProfile -File tests\run-tests.ps1 -Group cli-smoke,cli-mutations,config-mutations,capture,save-snapshot
```

The exact group names can be adjusted when the test group is added; the point is to keep
pure, lifecycle, save and CLI coverage independently runnable.

---

## 12. Risks and open questions

| Risk | Impact | Mitigation |
| --- | --- | --- |
| Unknown-item-field tolerance is an implicit contract | A future strict validator could break downgrade | Document it, add a regression test, and keep v4 as the fallback if strictness is required. |
| Semantic downgrade is not guaranteed | Users may expect old binaries to preserve relative intent | State the structural-only guarantee; test old save/reset divergence; recommend `--mode absolute` before downgrade. |
| Old clone drops relative fields | A clone made by an old binary becomes absolute | Document the non-guarantee; new clone helpers copy both fields; test each clone path. |
| Profile precedence surprises relative users | A relative item is placed absolutely on a matched profile | Document "exact profile > relative > fallback"; show the source in `show-layout`; no change without explicit approval. |
| Relative-only bypass pressure for profile-enabled sets | Could weaken the existing refusal contract | Keep the strict contract; any bypass requires a separate explicit approval. |
| Profile-targeted save accidentally dual-writes | A profile snapshot could mutate the universal fallback | Enforce the save-scope table; test `item.layout`/`layoutRelative` byte-identical after profile saves. |
| Duplicate identical monitors | Anchor may be ambiguous | Write `instance`; resolve exact instance first; degrade to absolute fallback with a clear warning. |
| Device-path instance changes across ports or docks | Anchor may become ambiguous or missing | Unique EDID identity still resolves; ambiguous cases fall back; expose diagnostics. |
| DPI virtualization differs from physical pixels | Placement may not match physical expectations | Keep awareness unchanged; document the virtualized coordinate contract; defer per-monitor DPI awareness. |
| Work-area changes resize work-area-based layouts | Unexpected size changes when taskbar auto-hides/moves | Choose `monitor` basis for fixed/edge-to-edge intent; document. |
| Save re-anchor changes the anchor when a window spans monitors | Surprising re-anchor | Strict greatest-area rule; tie refusal; explicit `set-geometry --relative` for manual control. |
| Old save/reset leaves relative metadata stale | Re-upgrade resumes older relative intent | Document; recommend `--mode absolute` before downgrade; a doctor check is deferred. |
| Floating-point precision or culture | Config churn or malformed JSON | 6-decimal capture, edge rounding, invariant serialization and formatting tests. |
| Application minimum sizes | Requested rectangle is not achieved | Treat as a target; capture actual geometry on save; defer min-size queries. |
| Virtual displays / RDP lack durable identity | Relative anchor unavailable | Fall back to absolute layout with a warning. |
| Profile-enabled unsafe topology blocks relative-only targets | Relative fallback unavailable in that edge case | Approved strict refusal contract; document; no bypass without explicit approval. |
| Config bloat from dual representation | Larger config and two sources of truth | Keep relative fields optional; document absolute fallback as authoritative for old readers. |
| Performance regression for profile-free absolute sets | Launch overhead | Preserve the hard fast path; add topology-call-count tests. |

### Remaining decisions for independent review

The approved direction settles additive v3, opt-in mode, mandatory absolute fallback,
profile-first precedence, greatest-visible-area anchoring, no DPI-awareness change, no
watcher, and the zero-topology fast path. The remaining review items are:

1. Confirm the exact downgrade wording: structural/load compatibility only, with stale
   relative metadata explicitly allowed.
2. Confirm the clone-copy contract and the requirement to test every clone path.
3. Confirm that profile-enabled lifecycle refusal remains strict with no relative-only
   bypass.
4. Confirm the profile-targeted versus fallback-scope save table.
5. Approve `set-geometry --relative` plus `--mode absolute` (D11), or choose a dedicated
   `layout-mode` command.
6. Should `instance` always be written for EDID anchors, or only when duplicate identities
   are present?
7. Should `save-layout --layout fallback` be part of the first implementation?
8. Is fixed-pixel relative placement required in v0.3, or deferred?
9. Are relative entries inside profiles required in v0.3, or deferred?
10. Is the virtualized-coordinate/DPI contract acceptable, or is a separate physical-pixel
    design required?

---

## 13. Recommendation

Revision 2 resolves the three review questions in section 1.1 and in the revised
profile/topology, save-scope and downgrade sections. This revision is committed on the
design-only branch `docs/monitor-relative-layout-design`; implementation remains blocked
pending independent review.

Proceed with the additive v3 design in phases after that review, starting with schema
validation and the pure relative-layout model. Do not implement lifecycle or save behavior
until the remaining decisions in section 12 are settled; settle D11 before phase 5. Do not
change DPI awareness, add a monitor watcher, or modify releases, tags or distribution
repositories as part of this feature.

The recommended architecture keeps DevWS's existing strengths:

- absolute geometry remains the universal, inspectable fallback;
- topology profiles remain exact and safe;
- relative mode is explicit and opt-in;
- every operation remains explicit and frozen;
- missing monitors degrade predictably instead of silently rearranging the desktop.

**Stop here for supervisory review. No production code, schema, CLI, runtime, installer,
release, tag or distribution change has been made.**
