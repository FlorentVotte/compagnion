import XCTest
@testable import CompagnionCore

final class ProcessProbeTests: XCTestCase {
    func testLiveProcessReportsAliveWithPlausibleStart() {
        let me = pid_t(ProcessInfo.processInfo.processIdentifier)
        guard case .alive(let started) = SystemProcessProbe.state(of: me) else {
            return XCTFail("the test process itself must report alive")
        }
        XCTAssertLessThanOrEqual(started, Date())
        XCTAssertLessThan(Date().timeIntervalSince(started), 3600)
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
}
