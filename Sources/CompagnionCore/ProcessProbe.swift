import Darwin
import Foundation

/// Whether a pid is running, and if so when it started. The start time is what
/// makes pid reuse detectable: a recycled pid belongs to a process that began
/// long after the session that recorded it.
public enum ProcessState: Equatable, Sendable {
    case alive(started: Date)
    case dead
}

/// Liveness straight from the kernel — no subprocess. Mirrors the `sysctl`
/// idiom already used by `HostAppResolver.parentPid(of:)`.
public enum SystemProcessProbe {
    public static func state(of pid: pid_t) -> ProcessState {
        // Non-positive pids have broadcast semantics in `kill`, so they would
        // spuriously succeed. They are never real session owners.
        guard pid > 0 else { return .dead }
        // EPERM means the process exists but belongs to someone else.
        guard kill(pid, 0) == 0 || errno == EPERM else { return .dead }
        guard let started = startTime(of: pid) else { return .dead }
        return .alive(started: started)
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
