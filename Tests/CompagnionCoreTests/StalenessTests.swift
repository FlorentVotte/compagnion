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
