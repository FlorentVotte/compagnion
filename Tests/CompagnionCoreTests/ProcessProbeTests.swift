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
}
