# DevWS Configuration

This document is the schema and validation reference for the DevWS canonical workspace
configuration. It describes schema version 3, which is the only schema the runtime accepts.

See [architecture.md](architecture.md) for how the runtime uses this configuration, and
[cli.md](cli.md) for the commands that change it.

---

## 1. The canonical file

```text
%USERPROFILE%\.config\devws\workspace.json
```

This file is the single source of truth for what a workspace contains. It holds intent
only: no window handles, no live observations, no machine state.

**Resolution order** when the CLI loads configuration:

1. an explicit override passed by the caller;
2. the `DEVWS_CONFIG` environment variable;
3. the canonical user configuration;
4. the bundled default shipped with the runtime.

The first two exist for development and testing. A normal installation uses the canonical
file.

**Writes are atomic and validated.** Every configuration mutation validates the complete
resulting document before replacing the file, so an invalid edit cannot be committed. A
failed capture or an interrupted operation leaves the previous file intact.

**The bundled default is never written.** It is a read-only fallback.

## 2. Top-level schema

```json
{
  "version": 3,
  "defaultSet": "main",
  "bindings": [],
  "sets": [
    { "id": "main", "windows": [] }
  ]
}
```

| Field | Type | Required | Rules |
| --- | --- | --- | --- |
| `version` | number | yes | Must be `3`. A version 2 document is recognised only by the installer's migration path; the runtime refuses it with a message telling you to run the installer. |
| `defaultSet` | string | yes | Must be a non-empty id that resolves to exactly one configured set. Uses the stable-id character family. |
| `bindings` | array | yes | Additional set launch hotkeys. Use `[]` for none. |
| `sets` | array | yes | At least one set definition. |

The bundled default is intentionally a **neutral starter**: one empty set, no items, no
bindings, no geometry. It is not an example of a configured workspace.

## 3. Stable identifiers

Set ids, item ids and profile ids share one conservative character family:

- letters, digits, `.`, `_` and `-`;
- the `/` character is **reserved** for set-qualified references such as
  `secondary/notes`, and may not appear inside an id.

Additional rules:

- ids are compared **case-insensitively** for uniqueness;
- a set id is unique among sets;
- an item id is unique within its set (the same id may be reused in another set);
- an application id must not be digit-only — numeric references are reserved for terminal
  aliases;
- profile ids are unique within their set, and the reserved word `fallback` may not be used
  as a profile id.

## 4. Set rules

```json
{
  "id": "main",
  "windows": [ ]
}
```

| Field | Type | Required | Rules |
| --- | --- | --- | --- |
| `id` | string | yes | Stable-id family, unique case-insensitively. |
| `windows` | array | yes | Ordered item definitions. May be empty. |
| `layoutProfiles` | array | no | Optional topology layout profiles; omit the property entirely if unused. |

Item order inside `windows` is meaningful: it is the order used by `ws list`, by launch
planning and by layout capture.

Sets are complete and independent. There is no inheritance between sets, no shared global
item catalogue and no implicit merging.

## 5. Item definitions

Every entry in `windows` is either a **terminal** or an **app**.

Shared fields:

| Field | Type | Required | Rules |
| --- | --- | --- | --- |
| `id` | string | yes | Stable-id family, unique case-insensitively within the set. |
| `type` | string | yes | `terminal` or `app`. |
| `enabled` | boolean | yes | `true` or `false`. Disabled items are listed but ignored by launch, focus and layout capture. |
| `layout` | object | yes | `{ "x", "y", "w", "h" }`, all integers, `w` and `h` greater than zero. |

## 6. Terminal definitions

```json
{
  "id": "work",
  "type": "terminal",
  "enabled": true,
  "windowId": "DevWS-work",
  "path": "C:\\Projects\\Work",
  "elevated": true,
  "tabs": [
    { "command": "pwsh", "args": [ "-NoLogo" ] },
    { "command": null, "args": [] }
  ],
  "activeTab": 0,
  "layout": { "x": 0, "y": 0, "w": 800, "h": 600 }
}
```

| Field | Type | Required | Rules |
| --- | --- | --- | --- |
| `windowId` | string | yes | Non-empty. The durable named-window identity. **Must be unique across every configured set**, not just within one set. |
| `path` | string | yes | Non-empty. The default working directory for the terminal. |
| `elevated` | boolean | yes | Managed terminals must be `true`; the runtime rejects a managed terminal configured as non-elevated. |
| `tabs` | array | yes | At least one tab. |
| `activeTab` | integer | yes | Must address an existing tab (`0 .. tabs.length - 1`). |
| `instanceMode` | — | **forbidden** | Instance modes apply to apps only. A terminal that defines it is rejected. |

A terminal must not define `instanceMode`.

### Tab fields

| Field | Type | Required | Rules |
| --- | --- | --- | --- |
| `command` | string or `null` | yes | `null` means an idle shell tab. A non-null command must be a non-empty string with no newline characters. |
| `args` | array | yes | Strings or numbers, no newline characters. Literal tool arguments such as `-w 5` are preserved and passed through unchanged. |
| `path` | string | no | Optional per-tab working-directory override. Must be an **absolute** path. |

**Effective path rule.** A tab's working directory is its own `path` override when present,
otherwise the terminal's `path`. Every creation, reset, validation and mutation path uses
this one rule, so each configured tab is created in its own effective directory.

The `command`/`args` pair is the tab's **startup intent**: what the tab runs when DevWS
creates it. Once that configured invocation has provably returned, `ws save` may retire the
startup intent for that tab (storing `command: null` and an empty `args`), so a
long-running command is not restarted on every reset. Retirement never affects the tab's
working directory.

### Managed tab titles

DevWS gives each configured tab a canonical managed title: the window id for tab 0, and a
suffixed form for later tabs. These titles are generated and parsed by one pair of helpers,
and configuration validation refuses any pair of terminals where one window id would parse
as a managed title of another. This prevents one terminal from impersonating another's
tabs.

## 7. App definitions

```json
{
  "id": "notes",
  "type": "app",
  "enabled": true,
  "match": { "kind": "exe", "value": "Notes.exe" },
  "launch": {
    "kind": "exe",
    "value": "C:\\Program Files\\Notes\\Notes.exe",
    "args": [ "--restore" ]
  },
  "instanceMode": "dedicated",
  "layout": { "x": 800, "y": 0, "w": 800, "h": 600 }
}
```

| Field | Type | Required | Rules |
| --- | --- | --- | --- |
| `match` | object | yes | `kind` and `value`. |
| `launch` | object | yes | `kind`, `value`, optional `args`. |
| `instanceMode` | string | yes | Exactly `dedicated` or `shared`, lower case. |

### Match kinds

| Kind | Meaning |
| --- | --- |
| `exe` | The executable name of the window's process. |
| `processPathContains` | A substring of the window's process path. |

A match rule only decides which windows are *eligible*. Resolution is ownership-aware and
exact; see [architecture.md](architecture.md) §5.

### Launch kinds

| Kind | Meaning | Arguments |
| --- | --- | --- |
| `exe` | An executable path. | Supported. |
| `appId` | An AppsFolder application id. | **Not supported.** |

### Instance mode

`instanceMode` is mandatory and explicit. DevWS never infers it at runtime and never
silently falls back from one mode to the other.

- `dedicated` — the application belongs to one set; DevWS owns its window and a dedicated
  launch must produce a distinct new window.
- `shared` — one eligible window is deliberately reused across sets. A shared window is
  never tagged as owned.

**Cross-set consistency rules.** Because an application id may appear in several sets:

- every occurrence of the same id must use the **same** mode. One mode per application id,
  configuration-wide;
- if that mode is `shared`, all occurrences must agree on the `match` and `launch` fields
  (layout and enabled state may differ).

These rules are validated, so a configuration cannot express contradictory intent.

## 8. Layout

`layout` is an absolute physical desktop rectangle: `x`, `y` are integers (negative values
are valid on a multi-monitor desktop) and `w`, `h` are positive integers.

Absolute rectangles are precise and work well with manual arrangement followed by
`ws save-layout`, but they are tied to the monitor arrangement they were captured on. That
is what topology layout profiles address.

## 9. Topology layout profiles

An optional per-set array that lets one set carry a different layout for a different monitor
arrangement.

```json
{
  "id": "docked",
  "match": {
    "mode": "exact",
    "monitors": [
      "edid:ACME001@0,0,2560x1440",
      "edid:ACME002@2560,0,1920x1080"
    ]
  },
  "layouts": {
    "work": { "x": 0, "y": 0, "w": 1280, "h": 1440 }
  }
}
```

| Field | Type | Required | Rules |
| --- | --- | --- | --- |
| `id` | string | yes | Stable-id family, unique case-insensitively within the set, may not be `fallback`. |
| `match` | object | yes | `mode` and `monitors`. |
| `layouts` | object | yes | Maps item ids to rectangles. May be empty. |

### Matcher rules

- `match.mode` must be `exact`. Only exact topology matching is supported.
- `match.monitors` must contain at least one topology signature token, and tokens must be
  unique within the profile.
- A token is `<identity>@<x>,<y>,<width>x<height>` with positive width and height, where
  the identity is `edid:` followed by a stable hardware identity, or `path:` followed by a
  normalised display device-path identity.
- **Monitor ordinals are not identities.** A value such as `\\.\DISPLAY1` is a diagnostic
  label only and is never accepted as a durable identity.
- Two profiles in the same set may not match the same topology signature. Profile order
  never resolves a conflict.
- Every key in `layouts` must reference an item id that exists in that set.

### Fallback semantics

`item.layout` remains the **universal fallback** and is mandatory for every item. Profiles
are sparse: an item omitted from a matched profile falls back to its own `item.layout`.

- A set with **no** profiles has no monitor dependency at all.
- A set with profiles samples the monitor topology exactly once per operation, before any
  side effect. An unsafe or ambiguous topology refuses the operation; a matched profile
  rectangle that is unreachable on the current desktop also refuses; an unreachable
  *fallback* rectangle is reported and that item is simply left unmoved.
- There is no monitor watcher and no automatic retiling. The next explicit launch observes
  a new topology.

Create and update profiles through `ws save-layout --profile <id>` so they start from real
captured geometry, and re-key an existing profile with `ws layout-profile match`.

## 10. Bindings

Additional set launch hotkeys, stored in canonical configuration:

```json
{
  "bindings": [
    { "hotkey": "alt+shift+y", "setId": "secondary" }
  ]
}
```

| Field | Type | Required | Rules |
| --- | --- | --- | --- |
| `hotkey` | string | yes | Canonical lower-case form with the modifier order `ctrl+alt+shift+win`, syntactically valid, non-reserved and unique across all bindings. |
| `setId` | string | yes | Must resolve to a configured set. |

Objects must contain exactly these two properties. Unknown properties are rejected.

**Reserved hotkeys.** `Alt+T` and `Alt+Shift+T` are permanently reserved and may not be
bound:

- `Alt+T` is reserved for the external `AdminTerminal` shortcut;
- `Alt+Shift+T` is reserved for launching the default set.

One hotkey may target only one set. The generated AutoHotkey include is derived state — it
is regenerated from configuration and is never the source of truth.

## 11. Validation

Validation has two levels.

**Structural validation** applies to the whole document: the rules in this document. It
covers the schema version, set and item identity, the terminal and app field rules, tab
shape and effective-path structure, layout rectangles, instance-mode consistency across
sets, profile shape, matcher uniqueness and the managed-title collision invariant.

**Operation-scoped validation** applies to what an operation actually touches. The most
important case: the working directories of enabled terminals must exist for a launch or a
reset — but **only for the set being operated on**. A missing directory in an unrelated set
never blocks work on another set, and one terminal's problem never blocks an unrelated
terminal.

Both levels fail closed. Nothing is renamed, normalised or discarded to make an invalid
document valid, and an invalid document is never replaced.

## 12. Migration

Schema migration belongs to the installer, never to a normal command.

| Situation | Behaviour |
| --- | --- |
| Valid current v3 configuration | Preserved **byte-for-byte**. |
| Valid v2 configuration | Recognised and converted with a backup taken first. |
| v3 configuration predating explicit instance modes | Enriched deterministically with a backup taken first; see below. |
| Valid v2 that cannot be represented as valid v3 | Migration refuses, keeps the bytes and names the offending definition. Nothing is renamed or normalised. |
| Invalid or unrecognised configuration | Left untouched and reported. Never migrated over, never replaced by the default. |
| No configuration at all | The bundled neutral starter is installed. |
| `-ResetConfig` | Backs up the existing configuration, then installs the starter. |

A normal `ws` command that meets an unmigrated v2 document fails with a message telling you
to run the installer.

**Instance-mode enrichment.** A structurally valid v3 document that predates mandatory
instance modes is enriched by a deterministic policy, applied per application id:

1. an explicit mode already present for that id propagates to every occurrence of the same
   id (a `shared` propagation additionally requires the definitions to be equivalent);
2. otherwise a bundled-default application with the same id supplies its mode when every
   occurrence matches it exactly;
3. otherwise an application that occurs only once becomes `dedicated`;
4. otherwise enrichment **fails safely**: the bytes are untouched and every affected
   application is named.

Because the shipped starter defines no applications, rule 2 cannot fire for a fresh
installation. Applications that would previously have inherited a bundled default's mode
therefore fall to rule 3 (single occurrence becomes `dedicated`) or rule 4 (refuse). This
is the intended behaviour of the public default: DevWS does not guess an instance mode for
an application it knows nothing about.

Historical v1 migration is **not supported** by the public product. A v1 document is
refused without modifying either the v1 file or the canonical configuration.

## 13. Runtime state is not configuration

Disposable state lives outside the configuration file:

| State | Location | Purpose |
| --- | --- | --- |
| Terminal handle cache | user state root | Remembers which window belongs to which scoped terminal identity. |
| Generated hotkeys | user state root | Derived from `bindings`; regenerated, never edited. |
| Backups | user state root | Byte-exact copies taken before a replacement. |
| Installer metadata | user state root | What the installer owns and changed. |
| Elevated runtime cache | privileged state root | High-integrity runtime observations. |
| Capture publications | privileged state root | Per-operation capture results with a high-integrity identity. |
| Working-directory authority | privileged state root | The expected and published terminal working directories. |

None of it is canonical. Configuration commands never touch it, and losing it costs a
discovery pass rather than correctness.

## 14. A complete synthetic example

Two terminals with different tab setups, one dedicated and one shared application, and a
topology profile:

```json
{
  "version": 3,
  "defaultSet": "main",
  "bindings": [
    { "hotkey": "alt+shift+y", "setId": "secondary" }
  ],
  "sets": [
    {
      "id": "main",
      "windows": [
        {
          "id": "work",
          "type": "terminal",
          "enabled": true,
          "windowId": "DevWS-work",
          "path": "C:\\Projects\\Work",
          "elevated": true,
          "tabs": [
            { "command": "pwsh", "args": [ "-NoLogo" ] },
            { "command": null, "args": [] }
          ],
          "activeTab": 0,
          "layout": { "x": 0, "y": 0, "w": 960, "h": 1040 }
        },
        {
          "id": "notes",
          "type": "terminal",
          "enabled": true,
          "windowId": "DevWS-notes",
          "path": "C:\\Notes",
          "elevated": true,
          "tabs": [
            { "command": null, "args": [] }
          ],
          "activeTab": 0,
          "layout": { "x": 960, "y": 0, "w": 960, "h": 1040 }
        },
        {
          "id": "editor",
          "type": "app",
          "enabled": true,
          "match": { "kind": "exe", "value": "Editor.exe" },
          "launch": {
            "kind": "exe",
            "value": "C:\\Program Files\\Editor\\Editor.exe",
            "args": []
          },
          "instanceMode": "dedicated",
          "layout": { "x": 0, "y": 0, "w": 960, "h": 1040 }
        },
        {
          "id": "browser",
          "type": "app",
          "enabled": true,
          "match": { "kind": "processPathContains", "value": "\\Browser\\" },
          "launch": { "kind": "exe", "value": "browser.exe", "args": [] },
          "instanceMode": "shared",
          "layout": { "x": 960, "y": 0, "w": 960, "h": 1040 }
        }
      ],
      "layoutProfiles": [
        {
          "id": "docked",
          "match": {
            "mode": "exact",
            "monitors": [ "edid:ACME001@0,0,2560x1440" ]
          },
          "layouts": {
            "work": { "x": 0, "y": 0, "w": 1280, "h": 1440 },
            "notes": { "x": 1280, "y": 0, "w": 1280, "h": 1440 }
          }
        }
      ]
    },
    {
      "id": "secondary",
      "windows": []
    }
  ]
}
```

All identifiers, paths and monitor tokens above are synthetic examples. Replace them with
your own; never copy a monitor identity from another machine, because topology matching is
exact.
