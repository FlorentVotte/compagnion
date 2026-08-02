import Foundation

/// One entry from `claude agents --json`. All fields except `cwd` are optional
/// because the shape differs between interactive and background sessions and
/// may evolve between Claude Code versions.
struct ClaudeSession: Decodable, Identifiable, Equatable, Sendable {
    let pid: Int?
    let cwd: String
    let kind: String?
    let startedAt: Double?
    let sessionId: String?
    let name: String?
    let status: String?
    let state: String?
    let waitingFor: String?
    let shortId: String?

    enum CodingKeys: String, CodingKey {
        case pid, cwd, kind, startedAt, sessionId, name, status, state, waitingFor
        case shortId = "id"
    }

    var id: String { sessionId ?? shortId ?? "\(pid ?? 0)-\(cwd)" }

    /// Blocked on the user: permission prompt, question, dialog…
    var needsAttention: Bool {
        if let waitingFor, !waitingFor.isEmpty { return true }
        if status == "waiting" { return true }
        if state == "blocked" { return true }
        return false
    }

    var isBusy: Bool {
        if needsAttention { return false }
        if let status, ["busy", "generating", "working", "running"].contains(status) { return true }
        if state == "working" { return true }
        return false
    }

    var isFinished: Bool {
        if let state, ["done", "failed", "stopped"].contains(state) { return true }
        return false
    }

    var displayName: String {
        if let name, !name.isEmpty { return name }
        return (cwd as NSString).lastPathComponent
    }

    var folderLabel: String {
        cwd.hasPrefix(NSHomeDirectory())
            ? "~" + cwd.dropFirst(NSHomeDirectory().count)
            : cwd
    }

    var statusLabel: String {
        if let waitingFor, !waitingFor.isEmpty { return "waiting — \(waitingFor)" }
        if let status, !status.isEmpty { return status }
        if let state, !state.isEmpty { return state }
        return "unknown"
    }

    var elapsedLabel: String? {
        guard let startedAt else { return nil }
        let seconds = Date().timeIntervalSince1970 - startedAt / 1000
        guard seconds > 0 else { return nil }
        let minutes = Int(seconds / 60)
        if minutes < 1 { return "just started" }
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h \(minutes % 60)m" }
        return "\(hours / 24)d \(hours % 24)h"
    }

    /// Command to paste in a terminal to jump into this session.
    var resumeCommand: String {
        if kind == "background", let shortId { return "claude attach \(shortId)" }
        if let sessionId { return "claude --resume \(sessionId)" }
        return "claude agents"
    }
}

/// Enrichment computed off the main actor, then applied in one hop.
private struct Enrichment: Sendable {
    var identity: [String: SessionIdentity] = [:]
    var context: [String: ContextUsage] = [:]
    var aiTitle: [String: String] = [:]
}

@MainActor
final class SessionMonitor: ObservableObject {
    @Published private(set) var displays: [SessionDisplay] = []
    @Published private(set) var lastError: String?
    @Published private(set) var lastUpdated: Date?
    @Published private(set) var accountUsage: AccountUsage?

    let listener: EventListener

    var waitingCount: Int { displays.filter { $0.badge == .waiting }.count }
    var busyCount: Int { displays.filter { $0.badge == .working }.count }

    /// Raised the first time a session enters a waiting episode, so the
    /// notifier fires once per episode rather than once per poll.
    var onWaitingEpisodeStart: ((SessionDisplay) -> Void)?
    /// The session left the waiting state (or went away) — clear its banner.
    var onWaitingEpisodeEnd: ((String) -> Void)?
    var onTurnFinished: ((SessionDisplay) -> Void)?
    var onSubagentFinished: ((SessionDisplay) -> Void)?

    private let enricher = SessionEnricher()
    private let hostResolver = HostAppResolver()

    private var timer: Timer?
    private var isRefreshing = false
    private let claudePath: String?

    /// Side state keyed by session id, merged into `displays` on every rebuild.
    private var identities: [String: SessionIdentity] = [:]
    private var aiTitles: [String: String] = [:]
    private var contextUsage: [String: ContextUsage] = [:]
    private var subagentCounts: [String: Int] = [:]
    private var waitingOverrides: Set<String> = []
    private var announcedWaiting: Set<String> = []
    private var pendingTools: [String: String] = [:]

    /// Context-window size per session, as reported by the statusline — the
    /// only authoritative source. The last one seen is remembered globally so
    /// the transcript fallback has a better starting guess than 200k for
    /// users who run on a larger window.
    private var windowSizes: [String: Int] = [:]
    private var defaultWindowSize: Int = UserDefaults.standard.object(forKey: SettingsKeys.windowSize) as? Int
        ?? SessionEnricher.windowTiers[0]

    /// Polling is the source of truth; hook events are only the low-latency
    /// edge. With the listener up we can afford a much slower poll.
    private let idlePollInterval: TimeInterval
    private let eventedPollInterval: TimeInterval = 10
    private var currentPollInterval: TimeInterval = 0

    init(pollInterval: TimeInterval = 3, listenerPort: UInt16 = 48765) {
        idlePollInterval = pollInterval
        claudePath = Self.findClaude()
        listener = EventListener(port: listenerPort)
        accountUsage = AccountUsage.load()

        if claudePath == nil {
            lastError = "claude CLI not found — install Claude Code first"
        }

        listener.onEvent = { [weak self] event in
            self?.handle(event)
        }
        listener.start()

        refresh()
        schedulePoll(interval: idlePollInterval)
    }

    static func findClaude() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude",
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private func schedulePoll(interval: TimeInterval) {
        guard interval != currentPollInterval else { return }
        currentPollInterval = interval
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    // MARK: - Polling

    func refresh() {
        schedulePoll(interval: listener.isListening ? eventedPollInterval : idlePollInterval)
        guard let claudePath, !isRefreshing else { return }
        isRefreshing = true
        let sizes = windowSizes
        let fallbackSize = defaultWindowSize
        Task.detached(priority: .utility) { [enricher] in
            let result = Self.fetchSessions(claudePath: claudePath)
            let enrichment: Enrichment
            if case .success(let sessions) = result {
                enrichment = Self.enrich(sessions: sessions, using: enricher, windowSizes: sizes, fallbackSize: fallbackSize)
            } else {
                enrichment = Enrichment()
            }
            await MainActor.run {
                self.apply(result: result, enrichment: enrichment)
            }
        }
    }

    private func apply(result: Result<[ClaudeSession], Error>, enrichment: Enrichment) {
        isRefreshing = false
        switch result {
        case .success(let sessions):
            identities.merge(enrichment.identity) { _, new in new }
            aiTitles.merge(enrichment.aiTitle) { _, new in new }
            // Statusline data is fresher and cheaper than a transcript read,
            // so it wins whenever we have a recent value.
            for (id, usage) in enrichment.context {
                if let existing = contextUsage[id], existing.measuredAt > usage.measuredAt { continue }
                contextUsage[id] = usage
            }
            rebuild(from: sessions)
            lastError = nil
            lastUpdated = Date()
        case .failure(let error):
            lastError = error.localizedDescription
        }
    }

    /// Rebuilds `displays` from the authoritative session list plus side state,
    /// dropping side state for sessions that have gone away.
    private func rebuild(from sessions: [ClaudeSession]) {
        let liveIDs = Set(sessions.map(\.id))
        identities = identities.filter { liveIDs.contains($0.key) }
        aiTitles = aiTitles.filter { liveIDs.contains($0.key) }
        contextUsage = contextUsage.filter { liveIDs.contains($0.key) }
        windowSizes = windowSizes.filter { liveIDs.contains($0.key) }
        subagentCounts = subagentCounts.filter { liveIDs.contains($0.key) }
        pendingTools = pendingTools.filter { liveIDs.contains($0.key) }
        waitingOverrides.formIntersection(liveIDs)
        let vanished = announcedWaiting.subtracting(liveIDs)
        announcedWaiting.formIntersection(liveIDs)
        for id in vanished { onWaitingEpisodeEnd?(id) }
        hostResolver.invalidate(keepingSessionPids: Set(sessions.compactMap(\.pid)))

        var built = sessions.map { session -> SessionDisplay in
            var display = SessionDisplay(session: session)
            if let identity = identities[session.id] {
                display.gitBranch = identity.gitBranch
                display.firstPrompt = identity.firstPrompt
                display.messageCount = identity.messageCount
            }
            display.aiTitle = aiTitles[session.id]
            if let usage = contextUsage[session.id] {
                display.contextFraction = usage.fraction
                display.contextMeasuredAt = usage.measuredAt
            }
            display.subagentCount = subagentCounts[session.id] ?? 0
            display.pendingToolName = pendingTools[session.id]
            // The poll disagreeing with the hook means the episode is over.
            if session.needsAttention {
                display.waitingOverride = false
            } else if waitingOverrides.contains(session.id) {
                display.waitingOverride = true
            }
            return display
        }

        built.sort { a, b in
            func rank(_ d: SessionDisplay) -> Int {
                switch d.badge {
                case .waiting: return 0
                case .working: return 1
                case .idle: return d.session.isFinished ? 3 : 2
                }
            }
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
        }

        displays = built
        announceWaitingEpisodes()
    }

    /// One notification per waiting episode: announce on entry, clear on exit.
    private func announceWaitingEpisodes() {
        let waitingNow = Set(displays.filter { $0.badge == .waiting }.map(\.id))
        for display in displays where display.badge == .waiting && !announcedWaiting.contains(display.id) {
            onWaitingEpisodeStart?(display)
        }
        for id in announcedWaiting.subtracting(waitingNow) {
            onWaitingEpisodeEnd?(id)
        }
        announcedWaiting = waitingNow
    }

    private nonisolated static func enrich(
        sessions: [ClaudeSession],
        using enricher: SessionEnricher,
        windowSizes: [String: Int],
        fallbackSize: Int
    ) -> Enrichment {
        var result = Enrichment()
        for session in sessions {
            guard let sessionId = session.sessionId else { continue }
            if let identity = enricher.identity(cwd: session.cwd, sessionId: sessionId) {
                result.identity[session.id] = identity
            }
            if let path = enricher.transcriptPath(cwd: session.cwd, sessionId: sessionId) {
                let assumed = windowSizes[session.id] ?? fallbackSize
                let tail = enricher.readTail(transcriptPath: path, contextWindowSize: assumed)
                if let usage = tail.usage { result.context[session.id] = usage }
                if let title = tail.aiTitle { result.aiTitle[session.id] = title }
            }
        }
        return result
    }

    private nonisolated static func fetchSessions(claudePath: String) -> Result<[ClaudeSession], Error> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: claudePath)
        process.arguments = ["agents", "--json"]

        // When launched as a .app (Finder), PATH is minimal; the claude
        // launcher may need node/its own dir on PATH.
        var env = ProcessInfo.processInfo.environment
        let extraPaths = [
            (claudePath as NSString).deletingLastPathComponent,
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ]
        env["PATH"] = (extraPaths + [env["PATH"] ?? ""]).joined(separator: ":")
        process.environment = env

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                return .failure(NSError(
                    domain: "Compagnion", code: Int(process.terminationStatus),
                    userInfo: [NSLocalizedDescriptionKey: "claude agents --json exited with \(process.terminationStatus)"]
                ))
            }
            let sessions = try JSONDecoder().decode([ClaudeSession].self, from: data)
            return .success(sessions)
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Events

    private func handle(_ event: CompagnionEvent) {
        switch event {
        case .hook(let hook):
            handle(hook: hook)
        case .statusline(let update):
            handle(statusline: update)
        }
    }

    private func handle(hook: HookEvent) {
        let kind = HookEventKind(eventName: hook.hookEventName, notificationType: hook.notificationType, message: hook.message)
        if let sessionId = hook.sessionId {
            switch kind {
            case .needsAttention:
                waitingOverrides.insert(sessionId)
                if let tool = hook.toolName, !tool.isEmpty { pendingTools[sessionId] = tool }
                applyOverridesImmediately()
            case .turnFinished:
                waitingOverrides.remove(sessionId)
                pendingTools[sessionId] = nil
                applyOverridesImmediately()
                if let display = displays.first(where: { $0.id == sessionId }) {
                    onTurnFinished?(display)
                }
            case .subagentStarted:
                subagentCounts[sessionId, default: 0] += 1
            case .subagentFinished:
                subagentCounts[sessionId] = max(0, (subagentCounts[sessionId] ?? 1) - 1)
                if let display = displays.first(where: { $0.id == sessionId }) {
                    onSubagentFinished?(display)
                }
            case .lifecycle, .other:
                break
            }
        }
        refresh()
    }

    /// Repaints the affected cards without waiting for the poll to come back.
    private func applyOverridesImmediately() {
        var updated = displays
        for index in updated.indices {
            let id = updated[index].id
            updated[index].waitingOverride = waitingOverrides.contains(id)
            updated[index].subagentCount = subagentCounts[id] ?? 0
            updated[index].pendingToolName = pendingTools[id]
        }
        displays = updated
        announceWaitingEpisodes()
    }

    private func handle(statusline: StatuslineUpdate) {
        if let context = statusline.contextWindow {
            let size = context.contextWindowSize ?? defaultWindowSize
            if let reported = context.contextWindowSize {
                if let sessionId = statusline.sessionId { windowSizes[sessionId] = reported }
                if reported != defaultWindowSize {
                    defaultWindowSize = reported
                    UserDefaults.standard.set(reported, forKey: SettingsKeys.windowSize)
                }
            }
            let fraction: Double?
            if let percentage = context.usedPercentage {
                fraction = min(max(percentage / 100, 0), 1)
            } else if let tokens = context.totalInputTokens, size > 0 {
                fraction = min(max(Double(tokens) / Double(size), 0), 1)
            } else {
                fraction = nil
            }
            if let fraction, let sessionId = statusline.sessionId {
                contextUsage[sessionId] = ContextUsage(
                    fraction: fraction,
                    totalInputTokens: context.totalInputTokens ?? Int(fraction * Double(size)),
                    contextWindowSize: size,
                    measuredAt: Date()
                )
                for index in displays.indices where displays[index].id == sessionId {
                    displays[index].contextFraction = fraction
                    displays[index].contextMeasuredAt = Date()
                }
            }
        }

        if let limits = statusline.rateLimits {
            let base = accountUsage ?? AccountUsage(measuredAt: Date())
            let merged = base.merging(
                fiveHour: (limits.fiveHour?.usedPercentage, Self.parseDate(limits.fiveHour?.resetsAt)),
                sevenDay: (limits.sevenDay?.usedPercentage, Self.parseDate(limits.sevenDay?.resetsAt))
            )
            accountUsage = merged
            merged.save()
        }
    }

    private static func parseDate(_ string: String?) -> Date? {
        guard let string else { return nil }
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: string) { return date }
        return ISO8601DateFormatter().date(from: string)
    }

    // MARK: - Jumping to the hosting app

    func activate(_ display: SessionDisplay) {
        guard let pid = display.session.pid else { return }
        hostResolver.activate(sessionPid: pid, cwd: display.session.cwd)
    }

    /// Entry point for a notification click, which only carries the session id.
    func activate(sessionId: String) {
        guard let display = displays.first(where: { $0.id == sessionId }) else { return }
        activate(display)
    }

    func hostAppName(for display: SessionDisplay) -> String? {
        guard let pid = display.session.pid else { return nil }
        return hostResolver.hostApp(for: pid)?.displayName
    }

    func jumpHelp(for display: SessionDisplay) -> String {
        if let name = hostAppName(for: display) { return "Jump to this session in \(name)" }
        return "No window found — right-click to copy \(display.session.resumeCommand)"
    }
}

/// Normalizes the hook event names Claude Code emits into the handful of
/// states the panel cares about. Names verified against Claude Code 2.1.220 —
/// see `.stitch/hooks-reference.md`. Notably there is no `TurnEnd` event, and
/// `PreToolUse` fires on *every* tool call, so it must not imply "waiting".
enum HookEventKind {
    case needsAttention
    case turnFinished
    case subagentStarted
    case subagentFinished
    case lifecycle
    case other

    /// `Notification` matcher values that mean the session is blocked on a human.
    private static let attentionNotifications: Set<String> = [
        "permission_prompt", "idle_prompt", "agent_needs_input", "elicitation_dialog",
    ]

    init(eventName: String, notificationType: String?, message: String?) {
        switch eventName {
        case "Notification":
            let type = (notificationType ?? "").lowercased()
            if Self.attentionNotifications.contains(type) {
                self = .needsAttention
            } else if type == "agent_completed" {
                self = .turnFinished
            } else if type.isEmpty {
                // Older builds omit notification_type; fall back to the text.
                let hint = (message ?? "").lowercased()
                self = hint.contains("permission") || hint.contains("waiting") || hint.contains("input")
                    ? .needsAttention
                    : .other
            } else {
                self = .other
            }
        case "PermissionRequest", "Elicitation":
            self = .needsAttention
        case "PermissionDenied":
            self = .other
        case "Stop", "StopFailure":
            self = .turnFinished
        case "SubagentStart":
            self = .subagentStarted
        case "SubagentStop":
            self = .subagentFinished
        case "SessionStart", "SessionEnd":
            self = .lifecycle
        default:
            self = .other
        }
    }
}
