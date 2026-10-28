# DevWS Workspace Sets

A **workspace set** is a complete, independent definition of a desktop workspace. This
document describes the set model as the product behaves today: what a set owns, how sets
relate to each other and to live windows, and which behaviours are deliberately excluded.

See [configuration.md](configuration.md) for the schema, [cli.md](cli.md) for the commands,
and [architecture.md](architecture.md) for identity and lifecycle behaviour.

---

## 1. Why sets exist

One machine often carries more than one working context: a daily driver, a focused project,
a presentation layout, a laptop-versus-docked arrangement. Modelling those as edits to a
single workspace means switching contexts by rewriting it, which is fragile and destroys the
context you were not using.

A set is the unit of that decision. Each set is a self-contained description; the machine
holds several of them side by side, and you choose which one to bring up.

## 2. What a set contains

```json
{
  "id": "main",
  "windows": [ ],
  "layoutProfiles": [ ]
}
```

A set owns:

- an ordered list of **items** — terminals and applications;
- each item's enabled state, match/launch configuration and instance mode;
- each item's saved **fallback geometry** (`item.layout`);
- optional **topology layout profiles** for specific monitor arrangements.

Sets are complete definitions, not overlays. There is no shared global item catalogue, no
inheritance between sets and no implicit merging: what a set launches is exactly what it
defines.

Item order is meaningful. It is the order used by `ws list`, by launch planning and by
layout capture.

## 3. The default set

Exactly one set is the configured **default**, named by `defaultSet`.

- A command that accepts an optional set operates on the default set when the set is
  omitted.
- Naming a set explicitly never changes which set is the default.
- There is **no hidden active-set state**. `ws set-default` changes the default and nothing
  else; it does not move, close or rearrange a single window.

The default is a configuration fact, not a runtime mode. That matters because it means two
terminals never disagree about what "the workspace" is: they both read the same file.

## 4. Referring to items

Two reference forms exist:

| Form | Meaning |
| --- | --- |
| `<id>` | An item in the target set. The target set is the default set unless a set was named. |
| `<set>/<id>` | An item in the named set. |

Because item ids only need to be unique *within* a set, the same id may legitimately exist in
several sets — and the set-qualified form is what disambiguates them.

```powershell
ws enable notes                 # in the default set
ws enable secondary/notes       # in the secondary set
ws launch secondary             # operate on a whole set
```

Numeric aliases (`ws set 2 …`, `ws reset 2`) resolve inside the default set only.
Application mutations accept stable ids only, never numbers.

## 5. Identity across sets

Two kinds of identity matter, and both are set-aware.

**Terminal window identity.** A terminal's `windowId` is a Windows Terminal named-window
identity and must be unique across **every** configured set. Newly created terminal
definitions receive set-qualified generated identities, so a terminal created in one set can
never collide with a terminal created in another. Existing identities are never regenerated:
renaming or reconfiguring a terminal preserves its `windowId` so a live window stays
discoverable.

**Runtime and ownership state.** Live state is keyed by the scoped identity
`<set-id>/<terminal-id>`, and application ownership is recorded under a scoped identity as
well. The same item id in two sets therefore never shares a cached window handle or an
ownership record.

## 6. Terminals and applications inside a set

**Terminals are always set-dedicated.** A managed terminal belongs to exactly one set, which
is what makes per-set launch, focus and reset unambiguous.

**Applications are explicitly `shared` or `dedicated`:**

- a **dedicated** application belongs to one set; DevWS owns its window and a dedicated
  launch must produce a distinct new window;
- a **shared** application deliberately reuses one eligible window across sets, so several
  sets can place the same application at different geometry without fighting over it.

The mode is mandatory and explicit, one mode per application id across the whole
configuration. DevWS never infers capability and never silently falls back from dedicated
to shared.

## 7. Geometry, profiles and the fallback

Every item has a mandatory `item.layout`: an absolute rectangle. This is the **universal
fallback** and the only geometry a set needs.

A set may additionally define **topology layout profiles**. Each profile matches one exact
monitor arrangement and stores sparse overrides — only the items that differ. Everything
else falls back.

That produces three useful properties:

- a set with **no** profiles and no targeted relative items has no monitor dependency at
  all; a relative item uses one topology snapshot per launch/reset, while absolute items
  keep their legacy placement;
- a set with profiles still works on an unknown monitor arrangement, because the fallback
  always applies;
- a profile is never partially applied: an operation either matches exactly one profile or
  uses the fallback.

Lifecycle placement resolves the effective layout **once**, before any side effect, and then
applies exactly those rectangles. An unsafe or ambiguous topology refuses the operation
before anything moves; a matched profile rectangle that is unreachable on the current
desktop also refuses; an unreachable fallback rectangle is reported and the item is left
unmoved rather than being dropped somewhere arbitrary.

## 8. Saving state

Two commands persist state, and the difference matters:

| Command | Persists |
| --- | --- |
| `ws save-layout [set] [--profile <id>]` | Geometry only. |
| `ws save [set] [--profile <id>]` | Geometry **plus** the reliable tracked working directory of each configured tab and the reliable configured active tab. |

Both are all-or-nothing on geometry: if any enabled item cannot be captured, nothing is
written. Both route the geometry through the same profile/fallback policy as the effective
layout.

Working-directory saving is opportunistic and never invents information. Each configured tab
resolves its own tracked directory independently; a tab whose directory cannot be
established keeps its existing effective path. Working-directory state is global to the
terminal, never per profile, because a directory is not a function of your monitors.

Saving never moves a window and never restarts a terminal.

## 9. Set management

| Command | Behaviour |
| --- | --- |
| `ws sets` | Lists configured sets with item counts and launch hotkeys. |
| `ws add-set <id>` | Adds an empty set. Nothing is launched and no shortcut is created. |
| `ws clone-set <source> <new>` | Deep-copies a set. Cloned terminals receive fresh set-qualified window identities, so the clone can never adopt the source's live windows. |
| `ws rename-set <old> <new>` | Renames a set **in place**, preserving its identity. |
| `ws remove-set <id> [-Force]` | Removes a non-default set. Refuses the default set and the last remaining set. |
| `ws set-default <id>` | Changes which set bare commands target. |

`rename-set` is deliberately *not* clone-and-remove. The set object keeps its position, and
every item id, terminal `windowId`, path, tab definition, command, active tab, enabled flag,
application match/launch/mode, fallback geometry and layout profile is preserved exactly.
Only the set id, the `defaultSet` reference when it pointed at the set, and any launch
binding that targeted the set are rewritten — binding hotkeys themselves never change.

Renaming refuses while a dedicated application of that set still owns a live window, because
the ownership record is scoped to the old identity and silently re-tagging windows is worse
than an actionable refusal. DevWS never closes, moves or retags a window to make a rename
succeed. A case-only rename keeps the existing tracking and ownership identities unchanged.

## 10. Sets coexist

Sets are independent, and independence is enforced rather than assumed:

- launching one set never closes, minimises or hides another;
- disabling or removing an item never closes its window;
- removing a set never closes windows;
- `ws focus` on one set does not disturb another;
- there is no destructive "switch set" operation and no `close-set`.

The practical consequence is that a machine can hold several live workspaces at once, and
bringing one up is never a reason for another to disappear.

## 11. Explicit non-goals

The following are **not** part of the set model and would require an intentional design
change to add:

- destructive set switching, and any operation that closes or hides other sets;
- a `close-set` command;
- hidden active-set state;
- nested sets, set inheritance, or set composition such as `base + work`;
- a global item catalogue with per-set override layers;
- live linkage between a set and its clone;
- automatic application multi-window capability detection;
- automatic dedicated-to-shared fallback;
- per-set application dependency declarations;
- arbitrary hotkey macros or actions beyond set launch bindings.

Remaining layout research (missing-monitor retiling, grids and named zones) is collected in
[future-work.md](future-work.md).
