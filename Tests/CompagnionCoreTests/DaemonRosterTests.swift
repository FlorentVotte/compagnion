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
