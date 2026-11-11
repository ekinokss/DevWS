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
  rules (8 cases), date handling (3 cases).
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
