# Hide Dead Sessions Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Drop a session from the Compagnion panel when its owning process is provably gone, so a background agent killed while `blocked` can no longer hold the attention slot forever.

**Architecture:** A new `CompagnionCore` library target holds a pure decision function plus two thin readers (the daemon roster file, and a `sysctl` process probe). The executable calls it from the existing off-main-actor poll task and filters the session list before rebuilding `displays`. Every failure path fails open — nothing is hidden unless liveness is affirmatively disproven.

**Tech Stack:** Swift 6.3.3 toolchain, SwiftPM (`swift-tools-version:5.9`, unchanged), XCTest, Darwin `sysctl`/`kill`.

## Global Constraints

- **Every `swift` invocation must be prefixed with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.** This machine's
  `xcode-select` points at `/Library/Developer/CommandLineTools`, which lacks the
  `PreviewsMacros` plugin the `#Preview` macros in `Sources/Compagnion/Components/`
  require; without the prefix `swift build` fails with 36 unrelated macro errors.
  Shell state does not persist between tool calls, so prefix each command rather
  than exporting once.
- Keep `swift-tools-version:5.9`. Do **not** bump to 6.0 — that enables Swift 6 language-mode strictness, which the existing `@MainActor`/`Sendable` code has not been audited against.
- Use **XCTest**, not swift-testing (swift-testing needs tools-version 6.0).
- Platform floor stays `.macOS(.v14)`.
- Every failure path fails open: any throw, `nil`, parse failure, or `sysctl` error results in `.show`.
- `procStart` strings parse with **both** `Locale(identifier: "en_US_POSIX")` **and** `TimeZone(identifier: "UTC")`. Parsing in the system zone is off by the UTC offset and would hide every live session.
- Compagnion never writes to `~/.claude`. This work only decides what to display.
- Tolerances, copied verbatim from the spec: `dispatchGrace = 60`, `procStartTolerance = 2`, `startedAtTolerance = 60`.
- Match existing codebase idiom: `sysctl` via `mib.withUnsafeMutableBufferPointer` (see `HostAppResolver.parentPid(of:)`), debug logging via the file-local `monitorLog`/`log` pattern gated on `COMPAGNION_DEBUG`.

## Deviation from the approved spec — read before starting

The spec's architecture table says `ClaudeSession.swift` is **moved** into `CompagnionCore` and that `Staleness.visibility` takes a `ClaudeSession`. **This plan does not do that.** Instead `CompagnionCore` defines a 4-field `SessionFacts` value type, and `SessionMonitor` maps `ClaudeSession → SessionFacts` at the call site.

Rationale — same behaviour, materially less risk:

- Moving `ClaudeSession` across a target boundary requires `public` on the struct, all 10 stored properties, and 8 computed members, plus a hand-written public memberwise initialiser (the synthesised one is internal, and `Decodable` only gives `init(from:)`).
- Four files reference `ClaudeSession`/`SessionDisplay` (`SessionMonitor`, `SessionDisplay`, `ContentView`, `Notifier`); all four would need `import CompagnionCore`. The `SessionFacts` approach touches only `SessionMonitor`.
- `CompagnionCore` stays ignorant of the CLI JSON shape, so tests construct a 4-field struct rather than round-tripping a 10-field `Decodable`.

Everything else follows the spec exactly. `Visibility` keeps its spec name but carries a reason string (`case hide(reason: String)`) to serve the spec's own observability requirement.

## File Structure

| File | Responsibility |
|---|---|
| `Package.swift` (modify) | three targets: `CompagnionCore` library, `Compagnion` exe depending on it, `CompagnionCoreTests` |
| `Sources/CompagnionCore/ProcessProbe.swift` (create) | `ProcessState`; `SystemProcessProbe.state(of:)` via `kill` + `sysctl` |
| `Sources/CompagnionCore/DaemonRoster.swift` (create) | `RosterWorker`, `Roster`, `Roster.decode(_:)`, `DaemonRoster.load()`, UTC `procStart` parsing |
| `Sources/CompagnionCore/Staleness.swift` (create) | `SessionFacts`, `Visibility`, `Staleness.visibility(of:roster:now:probe:)` — pure |
| `Sources/Compagnion/SessionMonitor.swift` (modify) | compute `hidden` off-actor; filter in `rebuild` before `liveIDs` |
| `Tests/CompagnionCoreTests/ProcessProbeTests.swift` (create) | live / reaped / non-positive / cross-user pids, and the fail-open seam |
| `Tests/CompagnionCoreTests/DaemonRosterTests.swift` (create) | decode, UTC parse, malformed bytes, unreadable path |
| `Tests/CompagnionCoreTests/StalenessTests.swift` (create) | every policy branch + the real `50ac7c18` fixture |

---

### Task 1: Package split and the process probe

**Files:**
- Modify: `Package.swift`
- Create: `Sources/CompagnionCore/ProcessProbe.swift`
- Test: `Tests/CompagnionCoreTests/ProcessProbeTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `public enum ProcessState: Equatable, Sendable { case alive(started: Date?); case dead }` and `public enum SystemProcessProbe { public static func state(of pid: pid_t) -> ProcessState }`. Later tasks pass `SystemProcessProbe.state(of:)` as a `(pid_t) -> ProcessState` closure. `started` is optional because `kill` can prove a process alive while `sysctl` yields no start time; reporting `.dead` there would hide a live session, violating the fail-open constraint. `nil` means "alive, start time unknown" and Task 3 must fall through to `.show`.

- [ ] **Step 1: Restructure `Package.swift`**

```swift
// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Compagnion",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "CompagnionCore",
            path: "Sources/CompagnionCore"
        ),
        .executableTarget(
            name: "Compagnion",
            dependencies: ["CompagnionCore"],
            path: "Sources/Compagnion"
        ),
        .testTarget(
            name: "CompagnionCoreTests",
            dependencies: ["CompagnionCore"],
            path: "Tests/CompagnionCoreTests"
        ),
    ]
)
```

- [ ] **Step 2: Write the failing test**

Create `Tests/CompagnionCoreTests/ProcessProbeTests.swift`:

```swift
import XCTest
@testable import CompagnionCore

final class ProcessProbeTests: XCTestCase {
    func testLiveProcessReportsAliveWithPlausibleStart() {
        let me = pid_t(ProcessInfo.processInfo.processIdentifier)
        guard case .alive(let started) = SystemProcessProbe.state(of: me),
              let start = started else {
            return XCTFail("the test process itself must report alive with a start time")
        }
        XCTAssertLessThanOrEqual(start, Date())
        XCTAssertLessThan(Date().timeIntervalSince(start), 3600)
    }

    func testReapedProcessReportsDead() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/true")
        try process.run()
        let pid = process.processIdentifier
        process.waitUntilExit()
        XCTAssertEqual(SystemProcessProbe.state(of: pid), .dead)
    }

    /// `kill(0, 0)` signals the whole process group and `kill(-1, 0)` every
    /// process the user owns; both return success and would read as "alive",
    /// which would keep a dead session visible forever.
    func testNonPositivePidsReportDead() {
        XCTAssertEqual(SystemProcessProbe.state(of: 0), .dead)
        XCTAssertEqual(SystemProcessProbe.state(of: -1), .dead)
    }

    /// A process owned by another user makes `kill` fail with EPERM, which the
    /// probe must read as "exists" rather than "gone". launchd is always pid 1
    /// and always root-owned, so this exercises the EPERM branch for real.
    /// (If the suite ever runs as root, `kill` returns 0 instead and the
    /// process is still alive, so the assertion holds either way.)
    func testCrossUserProcessReportsAlive() {
        guard case .alive(let started) = SystemProcessProbe.state(of: 1) else {
            return XCTFail("launchd must report alive, not dead")
        }
        XCTAssertNotNil(started, "sysctl reads start times across users on macOS")
    }

    /// The regression guard for fail-open. When `kill` confirms a pid but the
    /// start-time lookup yields nothing, the probe must still say alive —
    /// collapsing that to `.dead` is precisely what hid a live session. No real
    /// pid can produce this state, so the lookup is injected. Revert
    /// `state(of:startTime:)`'s last line to a `guard let … else { .dead }` and
    /// this is the test that fails.
    func testConfirmedPidWithNoStartTimeStaysAlive() {
        let me = pid_t(ProcessInfo.processInfo.processIdentifier)
        XCTAssertEqual(
            SystemProcessProbe.state(of: me, startTime: { _ in nil }),
            .alive(started: nil)
        )
    }

    /// The injected seam must not weaken the guards in front of it: a
    /// non-positive pid is dead no matter what the lookup would return.
    func testNonPositivePidStaysDeadEvenWithAStartTimeAvailable() {
        XCTAssertEqual(
            SystemProcessProbe.state(of: 0, startTime: { _ in Date() }),
            .dead
        )
    }
}
```

- [ ] **Step 3: Run the test to verify it fails**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ProcessProbeTests`
Expected: FAIL to compile — "cannot find 'SystemProcessProbe' in scope".

- [ ] **Step 4: Write the implementation**

Create `Sources/CompagnionCore/ProcessProbe.swift`:

```swift
import Darwin
import Foundation

/// Whether a pid is running, and if so when it started. The start time is what
/// makes pid reuse detectable: a recycled pid belongs to a process that began
/// long after the session that recorded it.
///
/// `started` is optional because the two syscalls can disagree: `kill` may
/// prove a process exists while `sysctl` returns nothing for it. Reporting
/// `.dead` in that case would hide a session that is genuinely alive, so
/// "alive, start time unknown" has to be representable — callers then cannot
/// judge pid reuse and must show the session.
public enum ProcessState: Equatable, Sendable {
    case alive(started: Date?)
    case dead
}

/// Liveness straight from the kernel — no subprocess. Mirrors the `sysctl`
/// idiom already used by `HostAppResolver.parentPid(of:)`.
public enum SystemProcessProbe {
    public static func state(of pid: pid_t) -> ProcessState {
        state(of: pid, startTime: startTime(of:))
    }

    /// The start-time lookup is injected so the fail-open contract is testable.
    /// No real pid can be alive while the kernel withholds its start time —
    /// `sysctl` succeeds whenever the process exists — so without this seam,
    /// changing the last line back to `guard let started … else { .dead }`
    /// would pass the entire suite while silently hiding live sessions again.
    static func state(of pid: pid_t, startTime: (pid_t) -> Date?) -> ProcessState {
        // Non-positive pids have broadcast semantics in `kill`, so they would
        // spuriously succeed. They are never real session owners.
        guard pid > 0 else { return .dead }
        // EPERM means the process exists but belongs to someone else.
        guard kill(pid, 0) == 0 || errno == EPERM else { return .dead }
        // `kill` has established the process exists. A missing start time makes
        // pid reuse unjudgeable, not the process dead — pass the uncertainty up
        // rather than converting it into a hide.
        return .alive(started: startTime(pid))
    }

    /// `sysctl(CTL_KERN, KERN_PROC, KERN_PROC_PID, pid)` -> `kp_proc.p_starttime`.
    private static func startTime(of pid: pid_t) -> Date? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let result = mib.withUnsafeMutableBufferPointer { mibPtr -> Int32 in
            sysctl(mibPtr.baseAddress, u_int(mibPtr.count), &info, &size, nil, 0)
        }
        guard result == 0, size > 0 else { return nil }
        let started = info.kp_proc.p_starttime
        guard started.tv_sec != 0 else { return nil }
        return Date(
            timeIntervalSince1970: Double(started.tv_sec) + Double(started.tv_usec) / 1_000_000
        )
    }
}
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter ProcessProbeTests`
Expected: PASS, 6 tests.

- [ ] **Step 6: Verify the app still builds and bundles**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./make-app.sh`
Expected: both succeed. `make-app.sh` resolves the binary via `swift build --show-bin-path`, so the added targets do not affect it.

- [ ] **Step 7: Commit**

```bash
git add Package.swift Sources/CompagnionCore/ProcessProbe.swift Tests/CompagnionCoreTests/ProcessProbeTests.swift
git commit -m "Add CompagnionCore with a kernel-level process liveness probe"
```

---

### Task 2: Daemon roster reader

**Files:**
- Create: `Sources/CompagnionCore/DaemonRoster.swift`
- Test: `Tests/CompagnionCoreTests/DaemonRosterTests.swift`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `public struct RosterWorker { public let pid: pid_t; public let procStart: String; public var procStartDate: Date? }`, `public struct Roster { public let proto: Int; public let workers: [String: RosterWorker]; public static func decode(_ data: Data) throws -> Roster }`, and `public enum DaemonRoster { public static func load(path: String = defaultPath) -> Roster?; public static let defaultPath: String }`. Task 3 consumes `Roster`; Task 4 calls `DaemonRoster.load()`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/CompagnionCoreTests/DaemonRosterTests.swift`:

```swift
import XCTest
@testable import CompagnionCore

final class DaemonRosterTests: XCTestCase {
    /// Shape observed on a real machine, trimmed. Unknown keys must be ignored,
    /// and auth tokens are deliberately absent — we never need them.
    private let sample = Data("""
    {
      "proto": 1,
      "supervisorPid": 50791,
      "updatedAt": 1784705794307,
      "workers": {
        "50ac7c18": {
          "pid": 21249,
          "procStart": "Wed Jul  8 14:25:15 2026",
          "sessionId": "50ac7c18-805e-483a-8129-f240229ee951",
          "cwd": "/Users/florent/dev/merge-queue-viewer",
          "cliVersion": "2.1.204"
        }
      }
    }
    """.utf8)

    private func utcDate(
        _ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int, _ second: Int
    ) -> Date {
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day
        components.hour = hour; components.minute = minute; components.second = second
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: components)!
    }

    func testDecodesWorkerPidAndIgnoresUnknownKeys() throws {
        let roster = try Roster.decode(sample)
        XCTAssertEqual(roster.proto, 1)
        XCTAssertEqual(roster.workers.count, 1)
        XCTAssertEqual(roster.workers["50ac7c18"]?.pid, 21249)
        XCTAssertEqual(roster.workers["50ac7c18"]?.procStart, "Wed Jul  8 14:25:15 2026")
    }

    /// The landmine: procStart is stored in UTC with a space-padded day and
    /// English month names, regardless of system locale.
    func testProcStartParsesAsUTC() throws {
        let worker = try XCTUnwrap(try Roster.decode(sample).workers["50ac7c18"])
        XCTAssertEqual(worker.procStartDate, utcDate(2026, 7, 8, 14, 25, 15))
    }

    /// Parsing the same string in the system zone yields an instant off by the
    /// UTC offset, which would make live sessions look like reused pids and be
    /// hidden. Skipped where the machine is already UTC.
    func testProcStartIsNotParsedInTheSystemZone() throws {
        let expected = utcDate(2026, 7, 8, 14, 25, 15)
        try XCTSkipIf(TimeZone.current.secondsFromGMT(for: expected) == 0)
        var components = DateComponents()
        components.year = 2026; components.month = 7; components.day = 8
        components.hour = 14; components.minute = 25; components.second = 15
        var local = Calendar(identifier: .gregorian)
        local.timeZone = .current
        let wrong = local.date(from: components)!
        let worker = try XCTUnwrap(try Roster.decode(sample).workers["50ac7c18"])
        XCTAssertNotEqual(worker.procStartDate, wrong)
    }

    func testUnparseableProcStartYieldsNilRatherThanThrowing() throws {
        let data = Data("""
        {"proto": 1, "workers": {"abc": {"pid": 5, "procStart": "not a date"}}}
        """.utf8)
        let worker = try XCTUnwrap(try Roster.decode(data).workers["abc"])
        XCTAssertNil(worker.procStartDate)
    }

    func testTruncatedBytesThrow() {
        XCTAssertThrowsError(try Roster.decode(Data(#"{"proto": 1, "workers":"#.utf8)))
    }

    func testMissingWorkersKeyThrows() {
        XCTAssertThrowsError(try Roster.decode(Data(#"{"proto": 1}"#.utf8)))
    }

    func testLoadReturnsNilForAnUnreadablePath() {
        XCTAssertNil(DaemonRoster.load(path: "/nonexistent/compagnion-test/roster.json"))
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter DaemonRosterTests`
Expected: FAIL to compile — "cannot find 'Roster' in scope".

- [ ] **Step 3: Write the implementation**

Create `Sources/CompagnionCore/DaemonRoster.swift`:

```swift
import Foundation

/// One supervised background worker, as recorded by the Claude Code daemon.
/// Only the two fields needed to prove liveness are decoded; the file also
/// carries sockets and auth tokens, which we deliberately ignore.
public struct RosterWorker: Decodable, Equatable, Sendable {
    public let pid: pid_t
    public let procStart: String

    /// `"Wed Jul  8 14:25:15 2026"` — UTC, English, space-padded day.
    /// `nil` when the string does not parse, which callers treat as "unknown"
    /// and therefore show the session.
    public var procStartDate: Date? { Self.parse(procStart) }

    static func parse(_ raw: String) -> Date? {
        let normalized = raw
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter.date(from: normalized)
    }
}

/// `~/.claude/daemon/roster.json`. When this file parses it is treated as
/// authoritative about which background jobs are supervised; a job with no
/// entry here is not running. `supervisorPid` is deliberately not decoded —
/// see the design doc.
public struct Roster: Decodable, Equatable, Sendable {
    public let proto: Int
    public let workers: [String: RosterWorker]

    public static func decode(_ data: Data) throws -> Roster {
        try JSONDecoder().decode(Roster.self, from: data)
    }
}

public enum DaemonRoster {
    public static let defaultPath = NSHomeDirectory() + "/.claude/daemon/roster.json"

    /// `nil` for any failure — missing, unreadable, or unexpected shape. The
    /// caller must then hide nothing.
    public static func load(path: String = defaultPath) -> Roster? {
        guard let data = FileManager.default.contents(atPath: path) else { return nil }
        return try? Roster.decode(data)
    }
}
```

Note: `FileManager.contents(atPath:)` returns `Data?`, so a missing file yields `nil` without throwing.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter DaemonRosterTests`
Expected: PASS, 7 tests (one may report as skipped if the machine runs UTC).

- [ ] **Step 5: Confirm the fixture still matches the real file**

The fixture is only as good as its resemblance to reality. Verify the live roster exposes the two fields this decoder depends on:

```bash
python3 -c "
import json, pathlib
d = json.loads(pathlib.Path.home().joinpath('.claude/daemon/roster.json').read_text())
print('proto', d['proto'])
print({k: {'pid': v['pid'], 'procStart': v['procStart']} for k, v in d['workers'].items()})
"
```

Expected: prints `proto 1` and each worker's `pid` and `procStart`, matching the fixture's shape. A missing file is also fine — `load()` returns `nil` and nothing is hidden. If `proto` is not 1, stop and re-read the file: the format has changed and the decoder may need updating.

- [ ] **Step 6: Commit**

```bash
git add Sources/CompagnionCore/DaemonRoster.swift Tests/CompagnionCoreTests/DaemonRosterTests.swift
git commit -m "Read the daemon roster, parsing procStart as UTC"
```

---

### Task 3: The staleness policy

**Files:**
- Create: `Sources/CompagnionCore/Staleness.swift`
- Test: `Tests/CompagnionCoreTests/StalenessTests.swift`

**Interfaces:**
- Consumes: `ProcessState` (Task 1), `Roster`/`RosterWorker` (Task 2).
- Produces: `public struct SessionFacts { public let id: String; public let pid: pid_t?; public let shortId: String?; public let startedAt: Date?; public init(id:pid:shortId:startedAt:) }`, `public enum Visibility: Equatable { case show; case hide(reason: String) }`, and `public enum Staleness { public static func visibility(of: SessionFacts, roster: Roster?, now: Date, probe: (pid_t) -> ProcessState) -> Visibility }` plus the three tolerance constants. Task 4 calls exactly this.

- [ ] **Step 1: Write the failing tests**

Create `Tests/CompagnionCoreTests/StalenessTests.swift`:

```swift
import XCTest
@testable import CompagnionCore

final class StalenessTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_785_746_000)

    private func facts(
        pid: pid_t? = nil,
        shortId: String? = nil,
        startedAt: Date? = nil
    ) -> SessionFacts {
        SessionFacts(id: "session-uuid", pid: pid, shortId: shortId, startedAt: startedAt)
    }

    private func roster(
        pid: pid_t,
        procStart: String,
        key: String = "50ac7c18"
    ) -> Roster {
        let json = """
        {"proto": 1, "workers": {"\(key)": {"pid": \(pid), "procStart": "\(procStart)"}}}
        """
        return try! Roster.decode(Data(json.utf8))
    }

    private func alive(_ started: Date) -> (pid_t) -> ProcessState {
        { _ in .alive(started: started) }
    }
    private let dead: (pid_t) -> ProcessState = { _ in .dead }

    private func isHidden(_ visibility: Visibility) -> Bool {
        if case .hide = visibility { return true }
        return false
    }

    // MARK: - Interactive sessions (pid present in the poll)

    func testInteractiveWithLiveMatchingPidShows() {
        let started = now.addingTimeInterval(-600)
        let result = Staleness.visibility(
            of: facts(pid: 1789, startedAt: started.addingTimeInterval(1)),
            roster: nil, now: now, probe: alive(started)
        )
        XCTAssertEqual(result, .show)
    }

    func testInteractiveWithDeadPidHides() {
        let result = Staleness.visibility(
            of: facts(pid: 1789, startedAt: now.addingTimeInterval(-600)),
            roster: nil, now: now, probe: dead
        )
        XCTAssertTrue(isHidden(result))
    }

    func testInteractiveWithReusedPidHides() {
        // Process started an hour after the session claims to have begun.
        let result = Staleness.visibility(
            of: facts(pid: 1789, startedAt: now.addingTimeInterval(-4200)),
            roster: nil, now: now, probe: alive(now.addingTimeInterval(-600))
        )
        XCTAssertTrue(isHidden(result))
    }

    func testInteractiveWithNoStartedAtShowsRatherThanGuessing() {
        let result = Staleness.visibility(
            of: facts(pid: 1789, startedAt: nil),
            roster: nil, now: now, probe: alive(now.addingTimeInterval(-600))
        )
        XCTAssertEqual(result, .show)
    }

    /// `kill` proved the process alive but `sysctl` returned no start time.
    /// Reuse is unjudgeable, so the session must stay visible even though its
    /// `startedAt` is nowhere near the (unknown) process start.
    func testAliveWithUnknownStartTimeShows() {
        let result = Staleness.visibility(
            of: facts(pid: 1789, startedAt: now.addingTimeInterval(-4200)),
            roster: nil, now: now, probe: { _ in .alive(started: nil) }
        )
        XCTAssertEqual(result, .show)
    }

    // MARK: - Background agents (short id only)

    func testBackgroundShowsWhenRosterIsUnreadable() {
        let result = Staleness.visibility(
            of: facts(shortId: "50ac7c18", startedAt: now.addingTimeInterval(-2_200_000)),
            roster: nil, now: now, probe: dead
        )
        XCTAssertEqual(result, .show)
    }

    func testBackgroundWithNoWorkerEntryHides() {
        let result = Staleness.visibility(
            of: facts(shortId: "50ac7c18", startedAt: now.addingTimeInterval(-2_200_000)),
            roster: roster(pid: 1, procStart: "Wed Jul  8 14:25:15 2026", key: "someone-else"),
            now: now, probe: dead
        )
        XCTAssertTrue(isHidden(result))
    }

    func testBackgroundWithDeadRosterPidHides() {
        let result = Staleness.visibility(
            of: facts(shortId: "50ac7c18", startedAt: now.addingTimeInterval(-2_200_000)),
            roster: roster(pid: 21249, procStart: "Wed Jul  8 14:25:15 2026"),
            now: now, probe: dead
        )
        XCTAssertTrue(isHidden(result))
    }

    func testBackgroundWithLiveMatchingRosterPidShows() {
        var components = DateComponents()
        components.year = 2026; components.month = 7; components.day = 8
        components.hour = 14; components.minute = 25; components.second = 15
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let procStart = calendar.date(from: components)!

        let result = Staleness.visibility(
            of: facts(shortId: "50ac7c18", startedAt: now.addingTimeInterval(-2_200_000)),
            roster: roster(pid: 21249, procStart: "Wed Jul  8 14:25:15 2026"),
            now: now, probe: alive(procStart.addingTimeInterval(1))
        )
        XCTAssertEqual(result, .show)
    }

    func testBackgroundWithReusedRosterPidHides() {
        let result = Staleness.visibility(
            of: facts(shortId: "50ac7c18", startedAt: now.addingTimeInterval(-2_200_000)),
            roster: roster(pid: 21249, procStart: "Wed Jul  8 14:25:15 2026"),
            now: now, probe: alive(now.addingTimeInterval(-60))
        )
        XCTAssertTrue(isHidden(result))
    }

    func testBackgroundWithUnparseableProcStartShows() {
        let result = Staleness.visibility(
            of: facts(shortId: "50ac7c18", startedAt: now.addingTimeInterval(-2_200_000)),
            roster: roster(pid: 21249, procStart: "not a date"),
            now: now, probe: alive(now.addingTimeInterval(-60))
        )
        XCTAssertEqual(result, .show)
    }

    func testFreshlyDispatchedJobShowsDespiteNoWorkerEntry() {
        let result = Staleness.visibility(
            of: facts(shortId: "brand-new", startedAt: now.addingTimeInterval(-5)),
            roster: roster(pid: 1, procStart: "Wed Jul  8 14:25:15 2026"),
            now: now, probe: dead
        )
        XCTAssertEqual(result, .show)
    }

    func testJobOlderThanTheGraceIsJudged() {
        let result = Staleness.visibility(
            of: facts(shortId: "brand-new", startedAt: now.addingTimeInterval(-61)),
            roster: roster(pid: 1, procStart: "Wed Jul  8 14:25:15 2026"),
            now: now, probe: dead
        )
        XCTAssertTrue(isHidden(result))
    }

    func testSessionWithNeitherPidNorShortIdShows() {
        let result = Staleness.visibility(
            of: facts(), roster: nil, now: now, probe: dead
        )
        XCTAssertEqual(result, .show)
    }

    // MARK: - The two tolerances are not interchangeable

    /// 30s of drift sits inside the interactive band (60s) and outside the
    /// background one (2s), so this pair is what pins each branch to its own
    /// constant. Swap the two between branches and both of these fail while
    /// every other test in the suite still passes.
    func testInteractiveToleratesDriftThatWouldCondemnABackgroundAgent() {
        let started = now.addingTimeInterval(-600)
        let result = Staleness.visibility(
            of: facts(pid: 1789, startedAt: started.addingTimeInterval(30)),
            roster: nil, now: now, probe: alive(started)
        )
        XCTAssertEqual(result, .show)
    }

    /// The mirror image: the same 30s measured against a roster `procStart` is
    /// well beyond the ±2s process-clock band, so the agent must be hidden.
    func testBackgroundRejectsDriftThatWouldPassForInteractive() {
        var components = DateComponents()
        components.year = 2026; components.month = 7; components.day = 8
        components.hour = 14; components.minute = 25; components.second = 15
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let procStart = calendar.date(from: components)!

        let result = Staleness.visibility(
            of: facts(shortId: "50ac7c18", startedAt: now.addingTimeInterval(-2_200_000)),
            roster: roster(pid: 21249, procStart: "Wed Jul  8 14:25:15 2026"),
            now: now, probe: alive(procStart.addingTimeInterval(30))
        )
        XCTAssertTrue(isHidden(result))
    }

    // MARK: - The observed regression

    /// The real 26-day-old phantom: background agent blocked, roster worker
    /// present, its pid long dead.
    func testTheObserved50ac7c18CaseHidesWithAReason() {
        let result = Staleness.visibility(
            of: SessionFacts(
                id: "50ac7c18-805e-483a-8129-f240229ee951",
                pid: nil,
                shortId: "50ac7c18",
                startedAt: Date(timeIntervalSince1970: 1_783_520_714.938)
            ),
            roster: roster(pid: 21249, procStart: "Wed Jul  8 14:25:15 2026"),
            now: now,
            probe: dead
        )
        guard case .hide(let reason) = result else {
            return XCTFail("the observed phantom must be hidden")
        }
        XCTAssertTrue(reason.contains("21249"), "reason should name the pid, got: \(reason)")
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter StalenessTests`
Expected: FAIL to compile — "cannot find 'SessionFacts' in scope".

- [ ] **Step 3: Write the implementation**

Create `Sources/CompagnionCore/Staleness.swift`:

```swift
import Foundation

/// The only things the policy needs to know about a polled session. Keeping
/// this separate from `ClaudeSession` means Core never learns the CLI's JSON
/// shape, and tests construct four fields instead of ten.
public struct SessionFacts: Equatable, Sendable {
    /// The id the panel keys rows by — `sessionId` when present.
    public let id: String
    /// Present for interactive sessions; background agents have none.
    public let pid: pid_t?
    /// The daemon short id, which is how the roster keys workers.
    public let shortId: String?
    public let startedAt: Date?

    public init(id: String, pid: pid_t?, shortId: String?, startedAt: Date?) {
        self.id = id
        self.pid = pid
        self.shortId = shortId
        self.startedAt = startedAt
    }
}

public enum Visibility: Equatable, Sendable {
    case show
    /// Carries why, for the debug log — hiding is otherwise invisible.
    case hide(reason: String)
}

/// Decides whether a polled session still has a process behind it.
///
/// Pure: the roster arrives as a value and liveness as a closure, so every
/// branch is testable without touching the filesystem or spawning processes.
/// Fails open everywhere — a session is hidden only when its death is
/// affirmatively established.
public enum Staleness {
    /// A job written to `jobs/` but not yet registered in the roster must not
    /// be mistaken for a dead one.
    public static let dispatchGrace: TimeInterval = 60
    /// `procStart` is the process clock itself, so the band is tight.
    public static let procStartTolerance: TimeInterval = 2
    /// `startedAt` marks when the *session* began, about a second after its
    /// process; a reused pid is off by far more than this.
    public static let startedAtTolerance: TimeInterval = 60

    public static func visibility(
        of facts: SessionFacts,
        roster: Roster?,
        now: Date,
        probe: (pid_t) -> ProcessState
    ) -> Visibility {
        // A pid in the poll is direct evidence; no private file needed.
        if let pid = facts.pid {
            return judge(
                pid: pid,
                against: facts.startedAt,
                tolerance: startedAtTolerance,
                label: "pid \(pid)",
                probe: probe
            )
        }

        // Background agents: the roster is the only place a pid exists.
        guard let shortId = facts.shortId else { return .show }
        guard let roster else { return .show }
        if let startedAt = facts.startedAt, now.timeIntervalSince(startedAt) < dispatchGrace {
            return .show
        }
        guard let worker = roster.workers[shortId] else {
            return .hide(reason: "roster has no worker entry")
        }
        return judge(
            pid: worker.pid,
            against: worker.procStartDate,
            tolerance: procStartTolerance,
            label: "roster pid \(worker.pid)",
            probe: probe
        )
    }

    /// Shared tail: a live pid still has to have started when the record says.
    private static func judge(
        pid: pid_t,
        against expectedStart: Date?,
        tolerance: TimeInterval,
        label: String,
        probe: (pid_t) -> ProcessState
    ) -> Visibility {
        switch probe(pid) {
        case .dead:
            return .hide(reason: "\(label) is not running")
        case .alive(let started):
            // Cannot judge reuse without both a start time for the live process
            // and a reference point to compare it against, so show.
            guard let started, let expectedStart else { return .show }
            let drift = abs(started.timeIntervalSince(expectedStart))
            guard drift > tolerance else { return .show }
            return .hide(reason: "\(label) started \(Int(drift))s from its record — reused pid")
        }
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test --filter StalenessTests`
Expected: PASS, 17 tests.

- [ ] **Step 5: Run the whole suite**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
Expected: PASS, 30 tests across three suites (6 probe + 7 roster + 17 staleness; the roster suite reports one skip on a UTC machine).

- [ ] **Step 6: Commit**

```bash
git add Sources/CompagnionCore/Staleness.swift Tests/CompagnionCoreTests/StalenessTests.swift
git commit -m "Decide session visibility from provable process liveness"
```

---

### Task 4: Wire the policy into the poll

**Files:**
- Modify: `Sources/Compagnion/SessionMonitor.swift` (add import; `refresh()` ~237-255; `apply(result:enrichment:)` ~257-276; `rebuild(from:)` ~280-352)

**Interfaces:**
- Consumes: `SessionFacts`, `Visibility`, `Staleness.visibility(of:roster:now:probe:)`, `DaemonRoster.load()`, `SystemProcessProbe.state(of:)`.
- Produces: no new public API; behaviour change only.

- [ ] **Step 1: Import Core and add the off-actor computation**

In `Sources/Compagnion/SessionMonitor.swift`, add to the imports at the top:

```swift
import CompagnionCore
```

Then add this method next to the existing `enrich`/`fetchSessions` statics:

```swift
    /// Ids of sessions whose owning process is provably gone. Runs off the main
    /// actor: reads the daemon roster and probes pids. Hides nothing unless
    /// death is established — see `Staleness`.
    private nonisolated static func hiddenIDs(in sessions: [ClaudeSession], now: Date) -> Set<String> {
        let roster = DaemonRoster.load()
        var hidden: Set<String> = []
        for session in sessions {
            let facts = SessionFacts(
                id: session.id,
                pid: session.pid.map { pid_t($0) },
                shortId: session.shortId,
                startedAt: session.startedAt.map { Date(timeIntervalSince1970: $0 / 1000) }
            )
            guard case .hide(let reason) = Staleness.visibility(
                of: facts,
                roster: roster,
                now: now,
                probe: SystemProcessProbe.state(of:)
            ) else { continue }
            hidden.insert(session.id)
            monitorLog("hiding \(session.shortId ?? session.id): \(reason)")
        }
        return hidden
    }
```

- [ ] **Step 2: Compute it in `refresh()` and thread it through `apply`**

Replace the body of the `Task.detached` block in `refresh()` with:

```swift
        Task.detached(priority: .utility) { [enricher] in
            let result = Self.fetchSessions(claudePath: claudePath)
            // Both are `let`, assigned once on each branch: the closure below
            // captures them, and capturing a `var` is an error in the Swift 6
            // language mode. This mirrors how `enrichment` was already handled.
            let enrichment: Enrichment
            let hidden: Set<String>
            if case .success(let sessions) = result {
                enrichment = Self.enrich(sessions: sessions, using: enricher, windowSizes: sizes, fallbackSize: fallbackSize)
                hidden = Self.hiddenIDs(in: sessions, now: Date())
            } else {
                enrichment = Enrichment()
                hidden = []
            }
            await MainActor.run {
                self.apply(result: result, enrichment: enrichment, hidden: hidden)
            }
        }
```

Change `apply`'s signature and its one call to `rebuild`:

```swift
    private func apply(result: Result<[ClaudeSession], Error>, enrichment: Enrichment, hidden: Set<String>) {
```

```swift
            rebuild(from: sessions, hidden: hidden)
```

- [ ] **Step 3: Filter in `rebuild` before `liveIDs` is computed**

Change the signature and the first two lines:

```swift
    private func rebuild(from sessions: [ClaudeSession], hidden: Set<String>) {
        // Filtering before `liveIDs` means a hidden session also sheds its side
        // state below, and any approval held for it resolves fail-open — a dead
        // process cannot answer one.
        let visible = hidden.isEmpty ? sessions : sessions.filter { !hidden.contains($0.id) }
        let liveIDs = Set(visible.map(\.id))
```

Then replace the two later uses of `sessions` in the same method with `visible`:

```swift
        hostResolver.invalidate(keepingSessionPids: Set(visible.compactMap(\.pid)))
```

```swift
        var built = visible.map { session -> SessionDisplay in
```

Leave every other line of `rebuild` untouched.

- [ ] **Step 4: Build and confirm the suite still passes**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift build && DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test`
Expected: both succeed. If the compiler reports `pid_t` conversion errors, `ClaudeSession.pid` is `Int?` — the `map { pid_t($0) }` in Step 1 is the conversion.

- [ ] **Step 5: Confirm no live session is hidden**

This step passes on *absence* of output, so it is only meaningful if you first prove the app actually polled. A run that failed to start, or was killed before its first poll, produces the same empty result as a success. `timeout`/`gtimeout` are **not** available on this machine — run in the background, wait, then kill, and keep the **unfiltered** log:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer COMPAGNION_DEBUG=1 \
  swift run > /tmp/step5.log 2>&1 &
RUN=$!
sleep 25            # the evented poll interval is 10s; this covers at least two
kill $RUN 2>/dev/null; wait $RUN 2>/dev/null
grep -ciE '\[SessionMonitor\]|\[EventListener\]' /tmp/step5.log   # must be > 0: proof it ran
grep -i 'hiding' /tmp/step5.log                                   # must be EMPTY
```

Expected: the first grep is greater than zero, proving real poll activity, and the second produces **no output** — the live interactive sessions must not be hidden. If the first grep is 0, the run never polled and the step proved nothing; investigate before continuing. If any `hiding` line names a live session, **stop and report BLOCKED**: that is a false positive, the one outcome this feature must never produce.

- [ ] **Step 6: Reproduce the original bug and confirm it is now hidden**

Restore the real phantom from the backups taken during investigation:

```bash
tar xzf ~/.claude/backups/jobs-50ac7c18-2026-08-03T10-36-04.tar.gz -C ~/.claude/jobs
# Count records, not matching lines: the pretty-printed JSON mentions 50ac7c18
# on two lines per record (`id` and `sessionId`), so `grep -c` reports 2.
/Users/florent/.local/bin/claude agents --json | python3 -c \
  "import json,sys; print(sum(1 for s in json.load(sys.stdin) if s.get('id') == '50ac7c18'))"
# expect exactly 1 — the CLI still reports the dead agent
```

Then run with debug logging, again in the background with the unfiltered log kept:

```bash
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer COMPAGNION_DEBUG=1 \
  swift run > /tmp/step6.log 2>&1 &
RUN=$!
sleep 25
kill $RUN 2>/dev/null; wait $RUN 2>/dev/null
grep -i 'hiding' /tmp/step6.log
```

Expected: a line `hiding 50ac7c18: roster has no worker entry` (the roster entry was removed during cleanup, so this exercises the roster-authority branch), and **no card for it in the panel**. Confirm the menu bar shows no `!` from it.

Clean up again afterwards:

```bash
rm -rf ~/.claude/jobs/50ac7c18
ls -d ~/.claude/jobs/50ac7c18 2>&1 | tail -1        # expect "No such file or directory"
/Users/florent/.local/bin/claude agents --json | python3 -c \
  "import json,sys; print(sum(1 for s in json.load(sys.stdin) if s.get('id') == '50ac7c18'))"
# expect 0 — and leave ~/.claude exactly as it was found
```

- [ ] **Step 7: Verify the release bundle**

Run: `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer ./make-app.sh`
Expected: succeeds and produces `Compagnion.app`.

- [ ] **Step 8: Commit**

```bash
git add Sources/Compagnion/SessionMonitor.swift
git commit -m "Drop sessions whose owning process is provably gone"
```

---

## Self-review notes

Spec coverage checked section by section: architecture (Tasks 1-3), policy table including both tolerances and the grace period (Task 3), integration and filter ordering (Task 4), observability via `monitorLog` with reasons (Tasks 3-4), fail-open error handling (every task), the three named regression tests — UTC parse, malformed roster, real `50ac7c18` fixture (Tasks 2-3), and manual verification from the backups (Task 4, Step 6).

Two spec items are intentionally not implemented, both recorded above: `ClaudeSession` is **not** moved into Core (see the deviation section), and `supervisorPid` is **not** decoded (the spec already explains why).

One spec limitation is worth restating for the implementer: interactive sessions are judged against `startedAt` from the poll rather than the more precise `procStart` in `~/.claude/sessions/<pid>.json`. That second file is deliberately not read.
