import Foundation

/// What the panel draws for one session: the authoritative row from
/// `claude agents --json` plus whatever enrichment happened to be available.
/// Every enriched field is optional on purpose — the UI must render correctly
/// from the poll alone, and must never fabricate a number it doesn't have.
struct SessionDisplay: Identifiable, Equatable {
    let session: ClaudeSession

    /// Phase 3 — from `~/.claude/projects/<slug>/sessions-index.json`.
    var gitBranch: String?
    var firstPrompt: String?
    var messageCount: Int?

    /// Phase 5 — statusline-reported, or computed from the transcript tail.
    var contextFraction: Double?
    var contextMeasuredAt: Date?

    /// Phase 5 — live count from SubagentStart/SubagentStop hook events.
    var subagentCount: Int = 0

    /// A hook told us this session is blocked on the user. Hooks land within
    /// milliseconds; the poll that confirms it may be seconds away, so the
    /// event wins until the next poll agrees or clears it.
    var waitingOverride = false

    /// Tool named by the hook that blocked this session, e.g. "Bash". The poll
    /// only reports a coarse `waitingFor`, so this is the better label when
    /// the event got here first.
    var pendingToolName: String?

    var id: String { session.id }

    init(session: ClaudeSession) {
        self.session = session
    }

    var badge: SessionBadge {
        if session.needsAttention || waitingOverride { return .waiting }
        if session.isBusy { return .working }
        return .idle
    }

    /// A context value nobody has refreshed in a while is shown, but marked.
    var contextIsStale: Bool {
        guard let contextMeasuredAt else { return false }
        return Date().timeIntervalSince(contextMeasuredAt) > 120
    }

    /// Last path component of the cwd — the design shows `folder / branch`,
    /// not the full path (which lives in the tooltip).
    var folderName: String {
        (session.cwd as NSString).lastPathComponent
    }

    /// "14m elapsed" while active, "45m ago" once idle — matches the design.
    var elapsedLabel: String? {
        guard let raw = session.elapsedLabel else { return nil }
        return badge == .idle ? "\(raw) ago" : "\(raw) elapsed"
    }

    var tooltip: String {
        var lines = [session.cwd]
        if let firstPrompt, !firstPrompt.isEmpty { lines.append(firstPrompt) }
        if let messageCount { lines.append("\(messageCount) messages") }
        if session.kind == "background" { lines.append("background agent") }
        return lines.joined(separator: "\n")
    }
}
