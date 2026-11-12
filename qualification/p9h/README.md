# DevWS P9-H replay instrumentation

Isolated measurement tooling for the P9-H acceptance replay. **This is not product code.**
Nothing here is installed, imported by `src/`, or referenced by the product manifest.

## Why it exists

The P9-G replay produced two verdict-impacting instrumentation failures. Both were
bookkeeping defects, not product defects, and each is closed structurally here.

| P9-G defect | Root cause | Closed by |
| --- | --- | --- |
| E1-1 | `disc-proof.ps1` began with `Set-Content`, truncating the previous run's records | Append-only writes (`Add-P9HArtifactLine`), never truncating |
| E1-2 | `CloseMainWindow` treated as a completed disconnect (it raises a confirmation dialog) | `tsdiscon <id>` behind an authorization gate |
| E1-3 | The decisive observation was lost before archiving | Records are flushed and read back before any verdict |
| E1-4 | Session 0 `Services` state 4 read as session 3 disconnected | `Test-P9HTargetDisconnected` keys on session id **and** user **and** logon time |
| E1-5 | E1 PASS expression had no disconnect term | `Get-P9HE1Verdict` requires `DisconnectProven` |
| E1-6 | Reconnect permitted after the command was issued | `Assert-P9HReconnectPermitted` re-derives proof from the persisted log |
| N2-1/2 | Exit code held only in memory | `Write-P9HExitRecord` runs before any inventory |
| N2-3/4 | `ManagementDateTimeConverter.ToDateTime` on a `DateTime` blanked every start time | `ConvertTo-P9HProcessStartUtc` + inventory `Outcome=degraded` classification |
| N2-5 | Post-launch serialization hung | Stages are bounded and independently journaled |
| N2-6 | Final result file never written | Exit record is the first artifact, atomically persisted |

### Stage 2.1 corrections (independent review of PR #21)

Stage 2 passed 42 synthetic tests yet contained paths where the instrumentation either could
not execute the intended sequence or could issue an unsupported verdict. Each is fixed and
guarded by a test that fails when the defect is reintroduced.

| Defect | Consequence in Stage 2 | Correction |
| --- | --- | --- |
| Circular reconnect gate | `Assert-P9HReconnectPermitted` used the FINAL proof, which required the post-reconnect record — impossible before reconnecting. The replay could never pass its own gate. | Proof split into A (pre-reconnect authorization: pre Active + target state 4, no post required) and B (final transition proof). Verified: reintroducing the defect makes `A1` fail while `F1` still passes. |
| Session identity not end to end | The matcher understood a logon time, but the parser produced only 4 fields, so real records never carried one and identity silently degraded to (session, user). | Raw line carries an optional `logon=` field; the v2 observation schema persists the observed logon **and its source**; matching, persistence, readback, authorization and verdict all consume the same pinned identity. Missing/unverifiable logon **fails closed**. |
| `negativeOrigin` not in the predicate | A topology with no negative-origin monitor could still PASS. | Added to `$tokensSatisfied`, computed from per-monitor rectangles on both sides. |
| Session check only "not 0" | Captures from an unrelated non-zero session could PASS. | Captures must bind to the target session id and to each other; `sessionMatchesTarget` and `sessionConsistent` are required. |
| Asserted booleans trusted | `tokenSetBytes`/`tokenRectBytes`/`identityComplete` were accepted without the raw observations. | Capture schema validated; tokens must be present and non-empty; rect/negative-origin derived from `parsedMonitors` when available; timestamp and trial provenance are blocking. |
| `windowsAttributed` unused + `.Count -ge 0` | The tautology meant N2-B could PASS with no attributable window or process. | Process attribution (new process with a recovered start time) and window attribution (`Select-P9HAttributableWindow`) are now first-class PASS inputs. |
| N2-A `$fallbackApplied = $false` initialiser | An unreadable post-window artifact read as "fallback not applied", allowing PASS on absent evidence. | Tri-state (`$null` = not observed) plus `PostStateObserved`; nothing is inferred from a missing observation. |
| Malformed trace lines silently skipped | A partial trace could be claimed as a whole transaction. | Any malformed trace line fails the trace as a whole. |
| Foreign trace trial id recorded but not blocking | A trace from another trial could contribute to a PASS. | `trace-trial-mismatch` is now a blocking condition. |

Two defects were found while *writing* these fixes, and are also covered:

- `ConvertFrom-Json` reconstructs ISO-8601 text as `DateTime`, so string-only comparisons produced
  a false `pre-logon-mismatch` and a false `disconnect-timestamp-invalid`. Logon and timestamp
  comparisons now normalize `DateTime`/`DateTimeOffset`/string before comparing.
- `[Parameter(Mandatory)]` with a default value **prompts** interactively instead of failing. Three
  such parameters were reintroduced during this correction and were removed again.

### Stage 2.2 corrections (independent review of PR #21 @ 75ed689)

Stage 2.1 fixed the circular gate, but several verdict predicates still allowed an authoritative
PASS without the evidence they claimed to require. Each counterexample below was reproduced against
`75ed689` and now rejects.

| False-PASS path on 2.1 | Reproduction | Correction |
| --- | --- | --- |
| `$traceOk` computed but never required by the N2-B predicate | all required events valid + one malformed line → **N2B=PASS** | `Test-P9HLaunchTrace` validates the whole trace (parse, required-event presence and uniqueness, causal order, single planId, single trialId, clean completion) and `trace.Ok` is a required PASS term |
| Duplicate / contradicting finalization events | two `stage2-terminal-final` with different outcomes → **PASS** | a repeated lifecycle event fails as `trace-duplicate-event` |
| Invalid event order | `terminal-final` before `broker-ready` → **PASS** | rank-ordered causal check → `trace-order-invalid` |
| Incompatible plan ids | four different `planId` values → **PASS** | one planId required → `trace-plan-id-conflict` |
| Process attribution by "new non-cmd process with a start time" | unrelated `WindowsTerminal.exe` opened by the user → **PASS** | `Get-P9HLaunchAttribution` requires the launch identity in argv (`-SetId`, `-TerminalId`, `-WindowId`) **and** a recovered start time |
| `-WindowRequired 'no'` caller bypass | zero observed windows still → **PASS** | parameter removed; window evidence is unconditional |
| E1 fell back to asserted `tokenRectBytes` | fabricated `x=-9999` summary, no monitor records → **PASS** | `parsedMonitors` are the authoritative source; a summary-only capture is rejected |
| Capture omitting `trialId` bypassed provenance | absent field on both captures → **PASS** | trial id is required, identical across pre/post/observer, and must match the trial under test |
| No capture↔transition chronology | pre-capture timestamped three hours in the future → **PASS** | the pre-capture must precede the persisted disconnect and the post-capture must follow the post-reconnect observation |

**Attribution model (source-backed).** A terminal is created through the elevated broker, so it is
*not* a direct child of the `cmd.exe` launcher; parentage is neither assumed nor inferred from
process names. The product itself supplies the authoritative links
(`src/lib/devws-terminal.ps1`, `devws-terminal-launch.ps1`): the broker plans each terminal by its
`windowId`, and the child shell is launched with explicit
`-SetId / -TerminalId / -WindowId / -SessionId / -PublicationPath` arguments — the same identity the
product validates before trusting a tracked tab. Attribution therefore requires all three ids in the
observed command line plus a recovered creation time; the window must then belong to that attributed
PID and be absent from the pre-launch inventory.

**Test totals: 70 → 87.** New: W1–W14 (trace validity and causal attribution, including the positive
detached-terminal case) and X1–X12 (window-omission, raw-monitor contract, trial and timestamp
provenance). All 70 Stage 2.1 cases are retained unchanged.

## Layout

```
qualification/p9h/
  Invoke-SelfTests.ps1        runner: synthetic validation, cleanup, non-zero on failure
  lib/
    p9h.ps1                   loader (side-effect free)
    p9h-core.ps1              time, trial ids, atomic/append-only IO, artifact readers
    p9h-e1-observer.ps1       WTS table parsing, strict target matching, disconnect proof
    p9h-e1-state.ps1          disconnect plan, tsdiscon gate, wait-for-proof, reconnect gate
    p9h-n2-recorder.ps1       launcher spec, exit record, process-recorded launch
    p9h-n2-inventory.ps1      process/window inventory, delta, attribution
    p9h-verdict.ps1           E1 and N2-A/N2-B verdict rules
    p9h-evidence.ps1          trial context, stage journal, artifact index
    p9h-wts-provider.ps1      WTSINFO/WTS_SESSION_INFO layout, enumeration, decode, provider lines
    p9h-collector.ps1         trial collector: seven N2 roles, origin model, E1 provenance
    p9h-fault.ps1             fault-injection harness
    p9h-selftest.ps1          the test cases
```

## Safety model

- **Importing is inert.** `. lib/p9h.ps1` starts no process and touches no VM.
- **Real actions need a literal token.** `Invoke-P9HControlledDisconnect` and
  `Invoke-P9HProductLaunchRecorded` throw unless given the exact authorization phrase.
  Stage 2 never supplies it.
- **No implicit session targets.** A missing session id is an error, never "current session".
- **Bounded waits everywhere.** Timeouts are their own outcome and never become exit code 0.
- **Append-only evidence.** No function deletes or truncates a prior record.
- **Atomic persistence.** Artifacts are written temp-then-renamed in the same directory, then
  read back and validated before a caller may rely on them.

## Running the self-tests

```powershell
pwsh -NoLogo -NoProfile -File .\qualification\p9h\Invoke-SelfTests.ps1
```

Add `-KeepSandbox` to retain the evidence tree. The runner exits non-zero if any case fails,
and removes only the sandbox it created.

The tests use trivial `cmd.exe` batch files in a unique temp directory. They never launch the
installed product, never contact Hyper-V, never disconnect a session, and never change host
configuration.

## What is verified, and what is not

- **IMPLEMENTED:** every component above.
- **SYNTHETICALLY VERIFIED:** exit recording (0, 7, nonzero, timeout, detached child, large
  output, spaces, unicode, quoted args), fault containment (throwing inventory, hanging
  serializer, malformed and missing records), WTS predicate strictness (12 cases), verdict
  rules (8 cases), cross-trial evidence binding (8 cases), shared provenance and artifact-index
  integrity (11 cases), date handling (3 cases).
- **NOT YET PHYSICALLY VERIFIED:** `tsdiscon` behaviour against a real session, PowerShell
  Direct capture from a Hyper-V host, real Terminal Services event delivery, and real
  installed-`ws` launch behaviour. Those require a separately authorized guest replay.

## Known limitations

- The WTS observer consumes a provider-supplied table. In a real replay that provider queries
  WTS through PowerShell Direct; that path is unimplemented here and unproven.
- Logon-time matching depends on the provider supplying a per-record logon timestamp. If a real
  WTS query cannot supply one, the identity tuple degrades to (session id, user) and the
  limitation must be recorded rather than silently accepted.
- Evidence durability is bounded by the OS filesystem. A catastrophic host failure can still
  lose artifacts; the design states this rather than claiming otherwise.

### Stage 2.3 corrections (independent review of PR #21 @ 8e0f156)

Two of these are verdict weaknesses; one is a **lost-regression** finding that matters as much as
the code fixes.

#### The N-series was silently dropped (70 -> 87 instead of 70 -> 96)

Stage 2.2 replaced the whole verdict test function, so the nine N-series cases disappeared while the
total *rose*. Nothing complained. Restored in full, with N8's expectation adapted to the stricter
contract below. The registry is now guarded automatically:

- `Test-P9HTestRegistry` checks the **runtime** results (unique ids, exact count, every series
  present) **and** the **source** literals in the test file, and fails as a case (`R1`) if a
  registered case never ran or a series vanished.
- Registered total is **100** (96 + W15, W16, X13, X14 for the new corrections).

#### N2-A accepted an empty window inventory

`Windows=[]` satisfied every N2-A predicate, so "no window was observed" passed a criterion that
requires **positively observed window creation and attribution**.

| Counterexample | Then | Now |
| --- | --- | --- |
| Valid but empty post-window inventory | **N2A=PASS** | `no-newly-observed-attributed-window` |
| Missing pre-window inventory | synthesized an empty baseline | `pre-window-observation-unavailable` |

N2-A now needs a readable **pre and post** inventory, a newly observed HWND whose PID is causally
attributed, and the fallback rectangle absent from *that* window.

#### Attribution ignored the launch window

`Get-P9HLaunchAttribution` received `LauncherPid`/`LaunchedAtUtc` but never used them, so a **stale**
process carrying the matching `-WindowId/-TerminalId/-SetId` argv from an earlier run counted as
newly created.

| Counterexample | Then | Now |
| --- | --- | --- |
| Same argv, created 5 h before the launch | **ProcessAttributed=True** | `creation-time-outside-launch-window` |

Attribution now requires: launch identity in argv **and** a recovered creation time **and** that time
inside `[launchedAt - tolerance, exitedAt + tolerance]` **and** a PID different from the launcher.
Parentage is still never inferred - the terminal is created by the elevated broker.

#### Trace identity requirements were invented, then hardened

Stage 2.2 required a per-event `trialId`. **DevWS never emits one** - verified by reading
`src/lib/devws-paths.ps1` and every `Write-DevWSLaunchTrace` call site: zero occurrences of any trial
identifier, and `planId` appears only on `stage2-broker-ready`/`stage2-broker-replanned`. That made
every **real** production trace invalid.

`Test-P9HLaunchTrace` now validates using only fields the product emits:

| Requirement | Source |
| --- | --- |
| Framework fields `event`, `utcMs`, `pid` | `Write-DevWSLaunchTrace` |
| Non-empty `planId` on `stage2-broker-ready` | `devws-launch.ps1:650` |
| Consistent `planId` on `stage2-broker-replanned` | `devws-launch.ps1:698` |
| Transaction identity `set` consistent across the plan and `transaction-end` | `devws-launch.ps1:569,901` |
| Causal order: event rank **and** monotonic `utcMs` | emitted by every event |
| Clean completion: `finalized=1`, `failures=0`, `broker=true`, `uncertain=false` | `devws-launch.ps1:770,901` |

| Counterexample | Then | Now |
| --- | --- | --- |
| Production-shaped trace (no `trialId`) | **INCONCLUSIVE** (real traces rejected) | eligible for PASS |
| Trace with no `planId` anywhere | PASS | `trace-plan-id-missing` |

#### Two further defects found while writing the fixes

- `ConvertFrom-Json` turns an ISO-8601 `Z` string into a `DateTime` with `Kind=Local` whose ticks are
  **local** wall-clock ticks. Unconditional `ToUniversalTime()` double-applied the offset and pushed
  valid process start times out of the launch window. `ConvertTo-P9HUtcOrNull` now honours `Kind`.
- `$null -ne $value` is **not** a presence test when `$value` is an array: comparing `$null` with
  `@()` yields `@()` (falsy). A valid but empty `Windows` array therefore looked like a missing
  inventory and blocked every attribution path. Presence is now tested on the property object
  (`Test-P9HHasProperty`).

### Stage 2.4 corrections (cross-trial evidence binding)

`Test-P9HExitRecord` verified that an exit record **has** a `trialId` field, never that it equals the
trial being evaluated. A verdict about trial B could therefore PASS on trial A's exit record.

| Counterexample | Stage 2.3 | Now |
| --- | --- | --- |
| Exit record from trial A, evaluating trial B | **N2B=PASS** | `exit-record-trial-mismatch:<id>` |
| `TrialId` omitted from the invocation | **N2B=PASS** | refused by the binder / `trial-id-missing` |

`TrialId` is now `[Parameter(Mandatory)]` on the N2 verdict, and the exit record's own id is compared
explicitly.

#### Binding a product trace that carries no trial identity

DevWS emits **no** per-event `trialId` (verified against every `Write-DevWSLaunchTrace` call site).
Rather than invent a product field, the binding is authored by the **collector** in the artifact index
that already exists for each trial — there is no second manifest:

```
Add-P9HArtifactRole -Context <trial> -Path <artifact> -Role fixture|stdout|pre-windows|
                                                  post-windows|exit-record|new-processes|trace
```

Each entry records the role, the **absolute path**, the byte count and the SHA-256 of the captured
bytes. Before a verdict can PASS, `Get-P9HArtifactBinding` re-reads that index and requires, for all
seven roles:

1. the role is recorded;
2. the record belongs to **this** trial;
3. the caller is using the **recorded path** (`ExpectedPaths` pinning);
4. the file still exists; and
5. its current SHA-256 **equals** the recorded digest.

| Counterexample | Result |
| --- | --- |
| Trace substituted from another trial | `binding-mismatch:trace:path` or `digest` |
| Artifact rewritten after binding | `binding-mismatch:trace:digest` |
| Another trial's artifact index supplied | `binding-mismatch:*:trial` |
| No index supplied | `artifact-index-not-supplied` → INCONCLUSIVE |

A missing, incomplete or mismatched binding yields **INCONCLUSIVE**, never PASS. Existing source-backed
correlation (`planId` on `stage2-broker-ready` vs `stage2-broker-replanned`, `set` across the plan and
`transaction-end`, `-SetId`/`-TerminalId`/`-WindowId` in the child argv, creation time inside the launch
window) remains required; the binding adds provenance, not a replacement.

**Limitation, stated plainly:** this proves the artifacts a verdict reads are the ones the collector
captured for that trial. It does **not** prove they were captured from a live guest — that is the
Stage 3 live collector's job, which must write the same index through `Add-P9HArtifactRole`.

### Stage 2.4.1 corrections (shared provenance, fail-closed)

Three narrow defects remained after Stage 2.4. Each is a false-PASS path, so each is closed rather
than documented.

#### N2-A did not consult the binding

Stage 2.4 gated **N2-B** on `$binding.Ok`, but the **N2-A** (placement) chain never read it. A
placement result could therefore become authoritative on artifacts that were never attributed to
the trial.

```
N2-A measurement otherwise valid, artifact index ABSENT
  before: N2A=PASS
  after : N2A=INCONCLUSIVE  artifact-binding:artifact-index-not-supplied

N2-A measurement otherwise valid, artifact index from ANOTHER trial
  before: N2A=PASS
  after : N2A=INCONCLUSIVE  artifact-binding:binding-mismatch:<role>:trial=<foreign-id>
```

Both verdicts now consult **one** shared gate, `Get-P9HTrialProvenance`, instead of duplicating
slightly different trial-binding logic. The gate checks provenance and trial identity **only** — it
never reads the exit code, terminal finalization or any other lifecycle success signal. That is what
keeps the two measurements independent:

```
N2-A measurement valid, captured exit code 3, complete same-trial binding
  N2A=PASS   (placement is still independently evaluated)
  N2B=FAIL   (lifecycle outcome is not success)
```

An exit-record outcome other than success therefore never automatically implies a failed placement
measurement. Historical P9-G measurements are **not** retroactively reclassified.

#### An empty `trialId` in a required index entry was not a mismatch

The verifier compared the recorded trial id only when it was non-empty, so a blank id silently
satisfied the binding. Every required entry must now carry a **nonempty** id that equals the
requested trial exactly:

| Recorded `trialId` | Before | Now |
| --- | --- | --- |
| property absent | accepted | `trial-id-missing` |
| `""` | accepted | `trial-id-missing` |
| `"   "` | accepted | `trial-id-missing` |
| another trial's id | rejected | `foreign-trial` |
| exactly the requested id | accepted | accepted |

Each surfaces as `binding-mismatch:<role>:trial-missing` or `binding-mismatch:<role>:trial=<id>`.

#### Malformed index records were skipped silently

The parser caught a malformed JSONL record and continued, so uninterpretable provenance disappeared
from a verdict. A malformed record is now an explicit failure that names the line and the reason:

```
artifact-index-malformed:line 1
```

The raw index is preserved byte-for-byte. Nothing is truncated, rewritten or repaired, so a
historical index is evidence rather than an input to be sanitized.

| Counterexample | Result |
| --- | --- |
| Truncated JSON before the seven valid entries | `artifact-index-malformed:line 1` |
| Truncated JSON appended after the valid entries | `artifact-index-malformed:line 8` |
| A required role absent | `binding-incomplete:trace` |
| All seven roles valid and same-trial | accepted, 7/7 verified |

These are covered by the P-series (P1-P11), which also proves the N2-A/N2-B independence above and
retains the N2-B cross-trial protection.

## Stage 3A — offline WTS provider and collector integration

Stage 3A connects a native `WTSINFO` provider to the frozen evidence contract. **No live session
query, RDP action, `tsdiscon`, PowerShell Direct call or installed-product launch occurs in this
stage**; every assertion runs from synthetic bytes or synthetic facts.

### Provider contract (documented APIs only)

| API | Use |
| --- | --- |
| `WTSEnumerateSessionsW` | session ids and station names |
| `WTSQuerySessionInformationW` (`WTSInfo`, class 24) | one `WTSINFO` structure |
| `WTSFreeMemory` | release every buffer the API allocated |

`WTSINFO` is modelled with the documented field order and the `winsrv.h` array lengths *including*
their terminators (`WINSTATIONNAME_LENGTH` 32, `DOMAIN_LENGTH` 17, `USERNAME_LENGTH + 1` 21). On x64
that is **216 bytes**, with `State` at 0, `SessionId` at 4, `WinStationName` at 32, `Domain` at 96,
`UserName` at 130, `ConnectTime` at 176 and `LogonTime` at 200.

The layout is cross-checked rather than assumed: `Test-P9HWtsInfoLayout` compares the published
offsets against `Marshal.SizeOf` / `Marshal.OffsetOf` results for the *current* process architecture
and distinguishes three failures — `layout-unsupported`, `layout-size-mismatch` and
`layout-offset-mismatch`. A host that cannot describe `WTSINFO` reports an explicit capability gap
(`Get-P9HWtsProviderCapability` → `Capability = 'unsupported'`) instead of inventing a logon time.

### FILETIME conversion

`LogonTime` is a `FILETIME`: 100-nanosecond intervals since 1601-01-01Z. **Zero is the Win32
"not available" sentinel, not the epoch.** Converting it blindly would turn a missing logon time into
a plausible 1601 timestamp and defeat the identity check, so zero, negative and out-of-range values
are rejected explicitly and the record carries `LogonSource = 'wtsinfo-zero'` (or the specific
reason) rather than a fabricated value.

### Provider → observer integration

`ConvertTo-P9HWtsProviderLine` is the only integration point. It emits the line format the frozen
observer has always parsed:

```
<id>|<station>|state=<n>|user=<account>[|logon=<ISO-8601 UTC>]
```

When a logon time is unavailable the trailing `|logon=` segment is **omitted**, which
`ConvertFrom-P9HLogonTimeField` already reports as `absent`. That keeps the capability gap visible.
No observer function was modified: `ConvertFrom-P9HWtsLine`, `Get-P9HTargetSessionRecord`,
`New-P9HObserverRecord`, `Get-P9HReconnectAuthorizationProof` and `Get-P9HDisconnectProof` are
unchanged, and every E1 predicate still fails closed on missing provider evidence.

### Collector integration

`Add-P9HCollectorArtifactRoles` binds the seven required N2 roles through the **existing**
`Add-P9HArtifactRole` mechanism — no second manifest, no new binding rule, same schema and digests:

```
fixture, stdout, pre-windows, post-windows, exit-record, new-processes, trace
```

Two provenance classes are kept distinct and reported by `New-P9HCollectorManifest`:

- **product** — bytes the product emitted. The collector records only role/path/digest; it never
  rewrites them, never invents a product event, and never invents a product trial id.
- **collector** — metadata the collector authors about the trial.

The E1 observation log is bound as **supporting provenance only**, into a separate
`e1-observation-index.jsonl`. It is deliberately *not* written into `artifact-index.jsonl`, whose
seven-role contract is closed: a separate file makes it structurally impossible for an E1 record to
be counted as N2 evidence.

A trial with any missing artifact is refused **before** anything is written
(`collector-artifacts-incomplete`), so a partial index can never be mistaken for a complete binding.

### Tests: Q1–Q15 (provider) and K1–K15 (collector)

| Series | Coverage |
| --- | --- |
| Q1–Q2 | valid payload with nonzero logon; exact UTC round-trip |
| Q3–Q6 | zero, negative, empty payload, struct-size mismatch |
| Q7 | published layout vs measured native mirror |
| Q8 | provider line round-trips through the frozen parser |
| Q9–Q11 | duplicate ids (ambiguous), wrong user, reused id with different logon |
| Q12 | missing provider logon fails closed for authoritative matching |
| Q13–Q14 | live query refused without authorization; Win32 error preserved |
| Q15 | capability reported explicitly |
| K1–K3 | seven roles bound; verified by the frozen gate; tamper detected |
| K4–K5 | incomplete trial refused; E1 log never enters the N2 index |
| K6–K7 | manifest separates provenance; product bytes never rewritten |
| K8–K9 | Active → Disconnected → Active proven; session 0 cannot substitute |
| K10–K13 | no authorization without persisted evidence; provider error and interrupted writes preserved; cross-trial refused |
| K14–K15 | collector-bound trial preserves N2-A independence and can satisfy both verdicts |

The registry guard now covers **149** registered cases; the full run executes 150 including `R1`.
All Stage 2.x cases are retained unchanged.

## Stage 3A.1 — complete enumeration and provenance corrections

Independent review of Stage 3A found three defects. All three are closed.

### 1. `WTSEnumerateSessionsW` was documented but not implemented

Stage 3A declared the enumeration API in prose and implemented only the single-session query. The
E1 contract needs the **complete** session table, because a table containing only the target cannot
demonstrate that session 0's disconnected state is not the target's state.

`Invoke-P9HWtsSessionEnumerate` now implements it against the documented `WTS_SESSION_INFO` record:

```
DWORD SessionId;
LPWSTR pWinStationName;          // pointer: 8 bytes on x64, 4 on x86
WTS_CONNECTSTATE_CLASS State;
```

The pointer forces 8-byte alignment, so the record is **24 bytes on x64** (`SessionId` 0,
`pWinStationName` 8, `State` 16) and **12 bytes on x86**. The stride is derived from the pointer size
and then **measured** with `Marshal.SizeOf`/`OffsetOf`; `Test-P9HWtsSessionInfoLayout` distinguishes
`layout-unsupported`, `layout-size-mismatch` and `layout-offset-mismatch`.

Decoding rejects, explicitly: a zero or negative count, a buffer too small for the reported count, a
station-name pointer outside the buffer, and an unreadable name. A malformed record makes the **whole
capture** unusable rather than silently dropping the entry a verdict might depend on.

`Resolve-P9HWtsSessionTable` correlates the enumeration with per-session `WTSINFO` results:

| Rule | Failure |
| --- | --- |
| Enumerated id must equal its `WTSINFO` id | `target-session-id-mismatch` |
| Duplicate ids make the table ambiguous | `ambiguous-enumeration` |
| A failed per-session query is recorded, never dropped | `incomplete-session-table` |
| The target must be present | `no-target` |
| A state that moved between enumeration and query | `state-changed-during-collection` |

**Stated limitation:** a sequence of sequential WTS queries is **not** an atomic Windows session
snapshot. `IsAtomicSnapshot` is always `false`, and a state change is classified as an **evidence
gap**, never as a successful transition. The observer is therefore required to treat instability as
instability.

`Get-P9HWtsProviderTableCapture` emits one provider line for **every** enumerated session, so the
frozen parser sees the same table a live observation would — including session 0.

### 2. Layout verification now gates the live query

Stage 3A had `Test-P9HWtsInfoLayout` but the live path never called it. `Invoke-P9HWtsSessionQuery`
now:

1. validates the layout **before** any interop and refuses with an explicit capability status;
2. rejects a returned byte count that does not equal the measured `WTSINFO` size **before** decode;
3. rejects a decoded `SessionId` that does not equal the requested id;
4. distinguishes a native failure (Win32 code preserved) from a successful-but-empty response
   (`empty-native-response`).

Passing the local layout check is **not** evidence that the live API works; it only proves this build
can describe the structure. Zero, negative and out-of-range FILETIME rejection is unchanged.

### 3. Artifact origin was misclassified

Stage 3A labelled all seven N2 roles `product`, which is factually wrong: the exit record is written
by the qualification recorder, the inventories are OS facts the qualification tooling observes, and
the fixture is a qualification-defined input.

The model now separates **who produced** the content from **who captured** it:

| Role | `origin` | `capturedBy` |
| --- | --- | --- |
| `fixture` | `fixture` | `qualification-launcher` |
| `stdout` | `product` | `qualification-launcher` |
| `pre-windows` | `operating-system` | `qualification-observer` |
| `post-windows` | `operating-system` | `qualification-observer` |
| `exit-record` | `qualification` | `qualification-recorder` |
| `new-processes` | `operating-system` | `qualification-observer` |
| `trace` | `product` | `qualification-capture` |

This is a **reporting** correction only. The seven required roles, their SHA-256 binding and their
acceptance meaning are unchanged, and no verdict reads these fields. `New-P9HCollectorManifest`
reports the classification per role and grouped by origin, and K6 now asserts each role's origin
instead of a bare count — including the specific proof that a collector-authored exit record is never
described as product-generated.

### Tests: Y1–Y16 (plus a rewritten K6)

| ID | Coverage |
| --- | --- |
| Y1 | full two-session enumeration with session 0 present |
| Y2 | target Active + session 0 Disconnected yields no target disconnect proof |
| Y3 | genuinely disconnected target yields correct target evidence |
| Y4 | enumeration failure preserves the Win32 error |
| Y5 | duplicate target session ids rejected as ambiguous |
| Y6 | enumerated/`WTSINFO` session-id mismatch fails closed |
| Y7 | missing target logon time still blocks authoritative matching |
| Y8 | per-session query failure preserved without losing other observations |
| Y9 | a state change during collection is an evidence gap |
| Y10 | layout mismatch prevents the native path |
| Y11 | empty/invalid successful buffers are explicit, distinct failures |
| Y12 | exact per-role origin classification |
| Y13 | the collector exit record is never described as product |
| Y14 | E1/N2 index separation with the seven-role digest binding intact |
| Y15 | live enumeration refuses without authorization |
| Y16 | full-table output drives the frozen E1 proofs end to end |
| K6 | per-role origin assertions (replacing the count-only check) |

The registry guard now covers **165** registered cases; the full run executes 166 including `R1`.
All 149 Stage 3A cases are retained unchanged.