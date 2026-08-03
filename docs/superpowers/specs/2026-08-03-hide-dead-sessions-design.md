# Hide sessions whose owning process is provably gone

Date: 2026-08-03
Status: approved, ready for implementation planning

## The problem

A background agent that dies while blocked leaves a record Claude Code never
reaps, and Compagnion renders it forever.

Observed on a release build: a card for background agent `50ac7c18`
(`aws-github-oauth-migration`, cwd `~/dev/merge-queue-viewer`) started
2026-07-08 and still displayed 26 days later. Its process (pid 21249) and the
daemon supervisor (pid 50791) were both long dead, and the daemon runtime
directory `/tmp/cc-daemon-502/` no longer existed.

Compagnion was not at fault. `rebuild(from:)` wipes and rebuilds `displays`
from `claude agents --json` on every poll, caching nothing across polls, and
the CLI genuinely still reported the session. The stale record lived in
Claude Code's own state:

- `~/.claude/jobs/50ac7c18/state.json` held `state: "blocked"`.
- `claude agents --json` hides jobs in terminal states — sibling jobs
  `fba4238b` (`done`) and `51ebb748` (`failed`) never appeared — but `blocked`
  is not terminal. The agent was killed *while* blocked, so it never wrote a
  final state, and nothing performs a liveness check on the recorded pid.

The damage is worse than a stray card. `state == "blocked"` makes
`ClaudeSession.needsAttention` true, which makes `SessionDisplay.badge`
`.waiting`, which pins the row to sort rank 0 at the top of the panel and
counts it in `waitingCount` — a permanent `!` in the menu bar. Background
entries carry no `pid` in the CLI JSON, so `activate()` returns early and the
card cannot even be clicked through. A dead agent held the attention slot for
26 days with no way to dismiss it.

## Goal

When Compagnion can establish that the process behind a session is gone, drop
the session from the panel entirely. When it cannot establish that, show the
session. Never hide on absence of evidence.

Hiding — rather than demoting or badging — was chosen deliberately, and it
sets the bar for detection: a false positive silently hides a session that
really does need attention, which is the app's core purpose.

## Evidence gathered

Each of these was verified on the affected machine before the design was
settled; several overturned an earlier version of it.

1. **Interactive sessions carry their own pid.** The CLI JSON includes `pid`
   and `startedAt`, and `~/.claude/sessions/<pid>.json` additionally records
   `procStart`. Liveness for interactive sessions is therefore provable
   without reading any private file.

2. **Background agents have no pid anywhere except the roster.**
   `jobs/<short>/state.json` carries `createdAt`, `updatedAt`, `state`,
   `tempo` and `needs`, but no pid.

3. **The roster is not what makes the CLI list a job.** With the
   `50ac7c18` entry removed from `~/.claude/daemon/roster.json` and only
   `jobs/50ac7c18/` restored, `claude agents --json` still listed the session.
   So the roster is a supervision record, not the listing authority.

   **Correction, added after review.** An earlier version of this document
   drew a further conclusion from that experiment — that a missing roster
   entry must therefore mean "not running", because otherwise "this exact bug
   would survive". That was wrong, and the preserved backup proves it: the
   original roster (`roster.json.pre-compagnion-cleanup-2026-08-03T10-36-04`)
   **did** contain `50ac7c18 → pid 21249, procStart "Wed Jul  8 14:25:15 2026"`.
   The observed phantom is caught by the **dead-pid** branch. The state in
   which the entry was absent was one the investigation itself created by
   deleting it; no conclusion about the original bug follows from it.

   A missing entry is therefore treated as **unknown → show**. See "Rejected:
   hiding on roster silence" below for why the alternative was dropped.

4. **Process argv cannot attribute a session.** Live `claude` processes have
   bare `claude` as their command line, with no session id, so enumerating
   processes is not a route to liveness.

5. **`procStart` is stored in UTC, in English.** `~/.claude/sessions/1789.json`
   recorded `"Mon Aug  3 08:30:39 2026"` for a process whose true start was
   `2026-08-03 08:30:39 +0000`. Parsing that string in the system time zone
   yields an instant off by exactly the UTC offset — 7200 s on this machine —
   which would make every *live* session look like pid reuse and be hidden.
   The day field is space-padded and the month/weekday names are English
   regardless of system locale, so the parser must pin both `en_US_POSIX` and
   UTC.

6. **The mechanism works unprivileged.** `kill(pid, 0)` and
   `sysctl(CTL_KERN, KERN_PROC, KERN_PROC_PID, pid)` return liveness and
   `p_starttime` for dead and live pids as expected. The app is not sandboxed
   (no container directory), so neither call needs an entitlement, and neither
   requires spawning a subprocess.

## Architecture

A new `CompagnionCore` library target holds the models and the policy. The
existing executable target depends on it; a new test target tests it.

```
Package.swift
├─ CompagnionCore      (library)  ← models + pure policy
├─ Compagnion          (exe)  → CompagnionCore
└─ CompagnionCoreTests (test) → CompagnionCore
```

| Unit | Purpose | Depends on |
|---|---|---|
| `Staleness.swift` | also defines `SessionFacts`, the four fields the policy needs from a polled session | Foundation |
| `ProcessProbe.swift` | `kill(pid,0)` + `sysctl(KERN_PROC_PID)` → `.alive(started:)` / `.dead` | Darwin |
| `DaemonRoster.swift` | `static decode(Data) throws -> Roster`, plus a thin disk loader returning `nil` on any failure | Foundation |
| `Staleness.swift` | the pure decision | Core models only |

The boundary that matters is between policy and probes. `Staleness` performs
no I/O; it receives the roster as a value and the process probe as a closure:

`ClaudeSession` stays in the executable. An earlier draft moved it into Core so
the policy could take one directly; that was rejected during planning because it
would require making the struct and eighteen members `public` plus a
hand-written memberwise initialiser, and adding imports to four files. Instead
Core defines the four facts the policy actually needs, and `SessionMonitor` maps
across at the call site — which also keeps Core ignorant of the CLI's JSON shape.

```swift
public struct SessionFacts: Equatable, Sendable {
    public let id: String        // what the panel keys rows by
    public let pid: pid_t?       // interactive only; background agents have none
    public let shortId: String?  // how the roster keys workers
    public let startedAt: Date?
}

public struct RosterWorker: Equatable {
    public let pid: pid_t
    public let procStart: String   // "Wed Jul  8 14:25:15 2026", UTC, English
}

public struct Roster: Equatable {
    public let proto: Int
    public let workers: [String: RosterWorker]   // keyed by daemon short id
}

public enum ProcessState: Equatable {
    /// Optional: `kill` can prove a process exists while `sysctl` yields no
    /// start time. Reporting `.dead` there would hide a live session, so
    /// "alive, start time unknown" has to be representable — callers then
    /// cannot judge pid reuse and must show.
    case alive(started: Date?)
    case dead
}

public enum Visibility: Equatable {
    case show
    case hide(reason: String)   // the reason feeds the debug log
}

public struct Staleness {
    public static let procStartTolerance: TimeInterval = 2
    public static let startedAtTolerance: TimeInterval = 60

    public static func visibility(
        of facts: SessionFacts,
        roster: Roster?,
        now: Date,
        probe: (pid_t) -> ProcessState
    ) -> Visibility
}
```

Every branch is therefore testable with no real processes and no filesystem.

`supervisorPid` is deliberately not decoded or consulted. Doing so would add a
second, independent inference — "a worker cannot outlive its supervisor" — that
was never verified, and a dead supervisor's workers already fail the pid probe.

Only one private file is read: `~/.claude/daemon/roster.json`. `state.json` is
not needed: nothing in the surviving policy depends on a job's own record.

## The policy

```
session has a pid (interactive):
    probe dead                          → hide
    alive, start − startedAt > 60s       → hide   (pid reuse)
    otherwise                           → SHOW

session has only a short id (background):
    roster nil (unreadable/absent)      → SHOW   ← fail open
    no worker entry                     → SHOW   ← fail open
    entry, probe dead                   → hide
    entry, |start − procStart| > 2s      → hide   (pid reuse)
    entry, alive and matching           → SHOW

neither pid nor short id               → SHOW
```

Every route to `hide` requires a pid the record itself supplied, probed and
found gone or recycled. Absence of information — no roster, no entry, no start
time — always shows.

The two tolerances differ on purpose. `startedAt` marks when the *session*
began, roughly a second after its process started (measured across four live
sessions: +0.40, +0.58, +1.08, +1.26 s), so a 60 s band absorbs that gap
without admitting a reused pid. `procStart` is the process clock itself, so
±2 s is appropriate.

**The interactive comparison is one-sided.** A recycled pid always belongs to a
process that started *later* than the session that recorded it, so only
`start − startedAt > tolerance` indicates reuse. Using `abs()` would also
condemn the opposite case — a session whose `startedAt` is newer than its host
process, which happens legitimately when a long-lived `claude` process begins a
new session — and hide a live session for it. The background comparison keeps
`abs()`, because there `procStart` is the same process's own recorded start and
drift in either direction means the record does not match the process.

## Rejected: hiding on roster silence

An earlier version of this design hid a background agent when the roster parsed
but held no worker entry for it, treating the roster as authoritative about what
is supervised. That rule was **dropped before merge**, for three reasons:

1. It is not what fixes the observed bug. The original roster listed the
   phantom with a dead pid (finding 3), so the dead-pid branch catches it.
2. It is an inference, not proof, and it rested on a further unverified premise
   — that a job the roster does not supervise cannot be running — which was
   never tested by killing a real supervisor. The design's whole premise is
   *hide only on proof*.
3. It carried the entire false-positive risk. Roster entries **are** dropped
   over time (job `51ebb748`, created 2026-06-30, has a live `jobs/` directory
   and no roster entry), so a live worker whose entry is dropped by a roster
   rewrite would have been hidden — and, per the corrected note on
   self-healing below, would have stayed hidden with no visible signal.

The cost of dropping it is accepted: a dead `blocked` job whose roster entry is
eventually dropped becomes undetectable again and needs manual cleanup. That is
strictly better than silently hiding a live session.

A consequence worth recording: the 60 s `dispatchGrace` existed **only** to
avoid hiding a freshly dispatched job that had not yet registered a worker.
With a missing entry now showing unconditionally, the grace protects nothing and
was removed rather than left as dead configuration.

## Integration

The roster read and the pid probes run inside the `Task.detached` that
`refresh()` already uses for `fetchSessions` and `enrich`. They produce a
`hidden: Set<String>` which is passed to `apply` as a **separate parameter**,
not as a field on `Enrichment` — `Enrichment` carries per-session display data
merged into the side-state dictionaries, whereas visibility is a decision about
the session list itself, and conflating them would mean `apply` merging a value
it must instead act on. `apply` forwards it to `rebuild`. No file I/O and no
`sysctl` on the main actor.

`rebuild` filters before computing `liveIDs`:

```swift
let visible = sessions.filter { !hidden.contains($0.id) }
let liveIDs = Set(visible.map(\.id))
```

That ordering matters: a hidden session also sheds its side state
(`identities`, `contextUsage`, `waitingOverrides`, `activities`, …) through
the existing `liveIDs` filters, and any held approval for it resolves
fail-open via the existing loop over `pendingApprovals`. Both are correct — a
dead process cannot answer a permission request.

Nothing is permanently blacklisted and no dismissal state is persisted: the
decision is recomputed from scratch on every poll, so a session reappears as
soon as the evidence changes.

**Correction, added after review.** An earlier version of this document claimed
the design was "self-healing" on the grounds that every hook event calls
`refresh()`, and a session that emits a hook is alive by definition, so a
hidden id reappears on the next poll. That reasoning does not hold in general.
Re-probing re-derives the decision from the *same* evidence; a hook event does
not change what `kill` and `sysctl` report. Recovery therefore depends on the
underlying evidence changing, which is a much weaker guarantee than
"self-healing" implies.

Where it does hold: every surviving `hide` route requires a probe that found a
pid gone or recycled. If that pid is in fact alive, the very next probe says so
and the session returns — so the surviving branches are self-correcting on their
own terms. The claim was false specifically for the roster-silence rule, whose
evidence (an absent entry) no amount of re-probing would revisit. That rule has
been removed, which is what makes the weaker statement above sufficient.

## Observability

Hiding is invisible by construction, so each suppression logs one line via the
existing `monitorLog` (active only under `COMPAGNION_DEBUG`, matching the
convention already used by the other components):

```
[SessionMonitor] hiding 50ac7c18: roster pid 21249 is not running
```

The reason is included, distinguishing "pid dead" from "procStart mismatch", so
a misfire can be diagnosed from a debug run. The session's identity comes from
the log prefix, so the reason string does not repeat it.

The roster's `proto` version is also logged when it is not 1. This matters
because `proto` is a required key: if the daemon renames or drops it, decoding
fails, `load()` returns `nil`, nothing is hidden, and the original bug returns
with no other signal. The line is the only announcement that the decoder has
gone stale.

## Error handling

Every failure path fails open — any throw, `nil`, parse failure, or `sysctl`
error results in `.show`. Specifically: `roster.json` missing, unreadable,
truncated, or of an unexpected shape yields `nil` and hides nothing; a
`procStart` string that fails to parse is treated as a mismatch-unknown and
shows the session; a `sysctl` failure on a pid that `kill(pid,0)` reported
alive shows the session.

## Testing

`CompagnionCoreTests` covers every branch of the policy with a fake probe and
fixture roster bytes:

- interactive: live pid with matching `startedAt` → show; dead pid → hide;
  live pid that started well *after* its `startedAt` → hide (reuse); live pid
  that started well *before* its `startedAt` → show (a new session inside a
  long-lived process is not reuse)
- background: `roster` nil → show; no worker entry → show; entry with dead
  pid → hide; entry with mismatched `procStart` → hide; entry alive and
  matching → show
- session with neither pid nor short id → show
- probe reports alive with no start time → show, on both paths

Three regressions get dedicated tests:

1. **UTC parse.** `"Wed Jul  8 14:25:15 2026"` must resolve to
   `2026-07-08T14:25:15Z`, not to that wall-clock time in the local zone.
   This test would fail on the natural but wrong implementation.
2. **Malformed roster.** Truncated and shape-mismatched bytes must throw from
   `decode`, surface as `nil`, and hide nothing.
3. **The real case.** A fixture built from the observed `50ac7c18` roster
   worker and CLI row (auth tokens redacted) must resolve to `.hide`, and the
   same row with the worker entry pointing at a live pid must resolve to
   `.show`.
4. **One-sidedness.** A live pid that started *before* its session's
   `startedAt` by more than the tolerance must `.show`; only the *later*
   direction is reuse. Reverting to `abs()` must fail this test.

Manual verification closes the loop against the true original state, which is
preserved in two backups — both are needed, because the phantom is caught by the
dead-pid branch and that requires its roster entry:

- `~/.claude/backups/roster.json.pre-compagnion-cleanup-2026-08-03T10-36-04`
  (contains `50ac7c18 → pid 21249`, long dead)
- `~/.claude/backups/jobs-50ac7c18-2026-08-03T10-36-04.tar.gz`

Restoring only the jobs record, as an earlier round of verification did, exercises
nothing once the roster-silence rule is gone: with no worker entry the session
correctly shows.

## Out of scope

- **Compagnion never writes to `~/.claude`.** Reaping the underlying Claude
  Code record stays a manual, backed-up operation. The app only decides what
  to display.
- No dismiss UI, and no persisted ignore list. This is acceptable because every
  surviving `hide` route rests on a probe of a pid the record supplied, so it is
  revisited on every poll and corrects itself the moment the pid answers. It
  would **not** have been acceptable alongside the roster-silence rule, whose
  evidence never changed — which is part of why that rule was dropped.
- No visual treatment for hidden sessions; hidden is hidden.
- Jobs in terminal states (`done`, `failed`) need nothing; the CLI already
  filters them.
- `fba4238b`, a second dead worker still in the roster, is left alone: its
  state is `done`, so it cannot produce a phantom card.

## Known limitations

1. **A dead job whose roster entry is dropped is undetectable.** Since the
   roster-silence rule was rejected, a `blocked` job that outlives its worker
   entry produces a phantom card again and needs manual cleanup. Roster entries
   demonstrably are dropped over time (`51ebb748`). This is the accepted cost of
   never hiding on absence of evidence.
2. **Private format dependency.** `roster.json` is undocumented and carries
   `proto: 1`, a required key. If its shape changes, `decode` fails, everything
   shows, and this bug silently returns. That is the safe failure direction. The
   `proto` value is logged when it is not 1, which is the only announcement that
   the decoder has gone stale — and it appears only under `COMPAGNION_DEBUG`.
3. **Interactive sessions rely on `startedAt` rather than the more precise
   `procStart`** in `~/.claude/sessions/<pid>.json`. Reading that second
   private file was rejected as unnecessary: a one-sided 60 s tolerance on a
   value already present in the poll is sufficient to catch pid reuse, since a
   reused pid implies a process that started much later than the recorded
   session.
4. **The integration is not covered by automated tests.** There is no test
   target for the executable, so the millisecond conversion, the id-vs-shortId
   keying, and the filter-before-`liveIDs` ordering in `rebuild` are verified
   only by the manual run recorded above. This follows the project's existing
   pattern of testing pure logic and exercising the main-actor wiring by hand,
   but it is worth knowing the next time `rebuild` is touched.
