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
