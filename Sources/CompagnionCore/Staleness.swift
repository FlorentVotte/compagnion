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
    /// `procStart` is the process clock itself, so the band is tight.
    public static let procStartTolerance: TimeInterval = 2
    /// `startedAt` marks when the *session* began, about a second after its
    /// process; a reused pid is off by far more than this.
    public static let startedAtTolerance: TimeInterval = 60

    public static func visibility(
        of facts: SessionFacts,
        roster: Roster?,
        probe: (pid_t) -> ProcessState
    ) -> Visibility {
        // A pid in the poll is direct evidence; no private file needed.
        if let pid = facts.pid {
            return judge(
                pid: pid,
                against: facts.startedAt,
                tolerance: startedAtTolerance,
                laterOnly: true,
                label: "pid \(pid)",
                probe: probe
            )
        }

        // Background agents: the roster is the only place a pid exists.
        guard let shortId = facts.shortId else { return .show }
        guard let roster else { return .show }
        // A missing entry is absence of evidence, not evidence of death —
        // roster generations drop entries for older jobs, so silence here would
        // condemn a live worker whose entry was merely forgotten. See the
        // spec's "Rejected: hiding on roster silence".
        guard let worker = roster.workers[shortId] else { return .show }
        return judge(
            pid: worker.pid,
            against: worker.procStartDate,
            tolerance: procStartTolerance,
            laterOnly: false,
            label: "roster pid \(worker.pid)",
            probe: probe
        )
    }

    /// Shared tail: a live pid still has to have started when the record says.
    ///
    /// `laterOnly` picks the comparison. A recycled pid always belongs to a
    /// process that started *later* than the record, and on the interactive
    /// path the reverse is legitimate — a long-lived `claude` process beginning
    /// a new session — so only the later direction condemns. On the background
    /// path `procStart` is the same process's own recorded start, so drift
    /// either way means the record does not describe this process.
    private static func judge(
        pid: pid_t,
        against expectedStart: Date?,
        tolerance: TimeInterval,
        laterOnly: Bool,
        label: String,
        probe: (pid_t) -> ProcessState
    ) -> Visibility {
        switch probe(pid) {
        case .dead:
            return .hide(reason: "\(label) is not running")
        case .alive(let started):
            // No start time for the live process, no reference point, or an
            // unparseable one — cannot judge reuse, so show.
            guard let started, let expectedStart else { return .show }
            let drift = started.timeIntervalSince(expectedStart)
            let excess = laterOnly ? drift : abs(drift)
            guard excess > tolerance else { return .show }
            // %.0f rather than Int(): converting a non-finite or absurd
            // interval would trap and take down the poll task.
            return .hide(
                reason: "\(label) started \(String(format: "%.0f", excess))s from its record — reused pid"
            )
        }
    }
}
