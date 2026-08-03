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
