import AppKit
import Foundation

/// No-op unless `COMPAGNION_DEBUG` is set — mirrors the other components'
/// loggers.
func monitorLog(_ message: @autoclosure () -> String) {
    guard ProcessInfo.processInfo.environment["COMPAGNION_DEBUG"] != nil else { return }
    FileHandle.standardError.write(Data(("[SessionMonitor] " + message() + "\n").utf8))
}

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
    var model: [String: String] = [:]
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
    /// Alive-but-idle sessions; finished background agents don't count as
    /// idle — nothing will ever happen in them again.
    var idleCount: Int { displays.filter { $0.badge == .idle && !$0.session.isFinished }.count }

    /// Raised the first time a session enters a waiting episode, so the
    /// notifier fires once per episode rather than once per poll.
    var onWaitingEpisodeStart: ((SessionDisplay) -> Void)?
    /// The session left the waiting state (or went away) — clear its banner.
    var onWaitingEpisodeEnd: ((String) -> Void)?
    /// Second argument is the turn's `last_assistant_message`, when the Stop
    /// hook carried one — notification preview material.
    var onTurnFinished: ((SessionDisplay, String?) -> Void)?
    var onTurnFailed: ((SessionDisplay) -> Void)?
    var onSubagentFinished: ((SessionDisplay) -> Void)?
    /// A permission request is being held for remote Allow/Deny.
    var onApprovalRequested: ((SessionDisplay?, PendingApproval) -> Void)?
    /// The held request was answered (from anywhere) or timed out.
    var onApprovalResolved: ((PendingApproval) -> Void)?

    private let enricher = SessionEnricher()
    private let hostResolver = HostAppResolver()

    private var timer: Timer?
    private var isRefreshing = false
    private let claudePath: String?

    /// Side state keyed by session id, merged into `displays` on every rebuild.
    private var identities: [String: SessionIdentity] = [:]
    private var aiTitles: [String: String] = [:]
    private var contextUsage: [String: ContextUsage] = [:]
    /// Short model labels per session. The statusline one wins (it reflects a
    /// live `/model` switch immediately); the transcript one fills the gap
    /// for sessions that haven't produced a statusline push this run.
    private var modelFromStatusline: [String: String] = [:]
    private var modelFromTranscript: [String: String] = [:]
    private var subagentCounts: [String: Int] = [:]
    /// Hook-reported waiting episodes, by session id, stamped when the hook
    /// landed. Bridges the gap until the poll can confirm — see `rebuild`.
    private var waitingOverrides: [String: Date] = [:]
    private var announcedWaiting: Set<String> = []
    private var pendingTools: [String: String] = [:]
    /// Live tool call per session (PreToolUse → PostToolUse/Failure window).
    private var activities: [String: ToolActivity] = [:]
    /// Question a session is asking (elicitation), verbatim.
    private var questions: [String: String] = [:]
    /// Sessions whose last turn died on an API error (StopFailure).
    private var failures: Set<String> = []
    /// Held permission requests awaiting remote Allow/Deny.
    private var pendingApprovals: [PendingApproval] = []
    private var approvalResponders: [UUID: @Sendable (Data) -> Void] = [:]
    private var approvalTimeouts: [UUID: Task<Void, Never>] = [:]

    /// How long a held PermissionRequest waits for a remote decision before
    /// falling through to the normal terminal prompt. Must stay under
    /// `EventListener.approvalBackstopSeconds` (62) and the installed hook
    /// timeout (65).
    private let approvalHoldSeconds: TimeInterval = 60
    /// A PreToolUse with no matching PostToolUse (missed event, crashed tool)
    /// shouldn't show as "running" forever.
    private let activityExpiry: TimeInterval = 10 * 60

    /// How long a hook-set waiting override survives polls that disagree with
    /// it. Must exceed one `eventedPollInterval` so at least one full poll —
    /// started *after* the hook landed — gets to confirm before we conclude
    /// the user answered without any hook firing (permission approvals emit
    /// no hook; the next installed event is Stop, potentially minutes away).
    private let waitingOverrideGrace: TimeInterval = 15

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
        listener.onPermissionDecision = { [weak self] hook, respond in
            guard let self else { respond(Data("{}".utf8)); return }
            self.handleApprovalRequest(hook, respond: respond)
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
            modelFromTranscript.merge(enrichment.model) { _, new in new }
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
        modelFromStatusline = modelFromStatusline.filter { liveIDs.contains($0.key) }
        modelFromTranscript = modelFromTranscript.filter { liveIDs.contains($0.key) }
        subagentCounts = subagentCounts.filter { liveIDs.contains($0.key) }
        pendingTools = pendingTools.filter { liveIDs.contains($0.key) }
        waitingOverrides = waitingOverrides.filter { liveIDs.contains($0.key) }
        activities = activities.filter { liveIDs.contains($0.key) }
        questions = questions.filter { liveIDs.contains($0.key) }
        failures.formIntersection(liveIDs)
        for approval in pendingApprovals where !liveIDs.contains(approval.sessionId) {
            resolveApproval(approval.id, decision: nil)  // session gone — fail open
        }
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
            display.modelName = modelFromStatusline[session.id] ?? modelFromTranscript[session.id]
            if let usage = contextUsage[session.id] {
                display.contextFraction = usage.fraction
                display.contextMeasuredAt = usage.measuredAt
            }
            // Reconcile hook overrides against this fresh poll. Poll agrees →
            // the override has served its purpose. Poll disagrees → keep the
            // override only while it's younger than the grace window (it may
            // have landed while this poll was already in flight); past that,
            // the user answered without any hook firing and the episode is
            // over. A held approval pins the override for its whole lifetime.
            if pendingApprovals.contains(where: { $0.sessionId == session.id }) {
                display.waitingOverride = true
            } else if session.needsAttention {
                waitingOverrides.removeValue(forKey: session.id)
            } else if let overrideSetAt = waitingOverrides[session.id] {
                if Date().timeIntervalSince(overrideSetAt) > waitingOverrideGrace {
                    waitingOverrides.removeValue(forKey: session.id)
                    pendingTools.removeValue(forKey: session.id)
                    questions.removeValue(forKey: session.id)
                } else {
                    display.waitingOverride = true
                }
            }
            decorate(&display)
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
                if let modelId = tail.modelId,
                   let name = SessionDisplay.shortModelName(fromId: modelId) {
                    result.model[session.id] = name
                }
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
                waitingOverrides[sessionId] = Date()
                if let tool = hook.toolName, !tool.isEmpty { pendingTools[sessionId] = tool }
                applyOverridesImmediately()
            case .turnFinished:
                waitingOverrides.removeValue(forKey: sessionId)
                pendingTools[sessionId] = nil
                activities.removeValue(forKey: sessionId)
                questions.removeValue(forKey: sessionId)
                failures.remove(sessionId)
                applyOverridesImmediately()
                if let display = displays.first(where: { $0.id == sessionId }) {
                    onTurnFinished?(display, hook.lastAssistantMessage)
                }
            case .turnFailed:
                activities.removeValue(forKey: sessionId)
                failures.insert(sessionId)
                applyOverridesImmediately()
                if let display = displays.first(where: { $0.id == sessionId }) {
                    onTurnFailed?(display)
                }
            case .activityStart:
                if let tool = hook.toolName, !tool.isEmpty {
                    activities[sessionId] = ToolActivity(toolName: tool, summary: hook.toolInputSummary, startedAt: Date())
                }
                failures.remove(sessionId)
                applyOverridesImmediately()
                return  // fires on EVERY tool call — never trigger a poll
            case .activityEnd:
                activities.removeValue(forKey: sessionId)
                applyOverridesImmediately()
                return  // same frequency as activityStart
            case .question:
                if let message = hook.message, !message.isEmpty { questions[sessionId] = message }
                waitingOverrides[sessionId] = Date()
                applyOverridesImmediately()
            case .questionResolved:
                questions.removeValue(forKey: sessionId)
                waitingOverrides.removeValue(forKey: sessionId)
                applyOverridesImmediately()
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

    // MARK: - Remote Allow/Deny

    /// Called by the listener with the held `PermissionRequest` responder.
    /// Answers inertly right away unless remote approval is enabled AND the
    /// user is plausibly away from that session's terminal.
    private func handleApprovalRequest(_ hook: HookEvent, respond: @escaping @Sendable (Data) -> Void) {
        let inert = Data("{}".utf8)
        guard UserDefaults.standard.bool(forKey: SettingsKeys.remoteApproval),
              let sessionId = hook.sessionId else {
            monitorLog("approval: inert (remote=\(UserDefaults.standard.bool(forKey: SettingsKeys.remoteApproval)) session=\(hook.sessionId ?? "nil"))")
            respond(inert)
            return
        }
        // At the terminal → answer inertly so the normal prompt shows with
        // zero added latency; the hold is for when the user is elsewhere.
        if let pid = displays.first(where: { $0.id == sessionId })?.session.pid,
           let host = hostResolver.hostApp(for: pid),
           NSWorkspace.shared.frontmostApplication?.bundleURL?.standardizedFileURL == host.bundleURL {
            monitorLog("approval: inert (user is at \(host.displayName))")
            respond(inert)
            return
        }
        monitorLog("approval: holding for session \(sessionId)")

        let approval = PendingApproval(
            id: UUID(),
            sessionId: sessionId,
            toolName: hook.toolName,
            summary: hook.toolInputSummary,
            receivedAt: Date()
        )
        pendingApprovals.append(approval)
        approvalResponders[approval.id] = respond
        waitingOverrides[sessionId] = Date()
        if let tool = hook.toolName, !tool.isEmpty { pendingTools[sessionId] = tool }
        // The approval notification (with Allow/Deny buttons) replaces the
        // generic "needs you" one for this episode.
        announcedWaiting.insert(sessionId)
        applyOverridesImmediately()
        onApprovalRequested?(displays.first { $0.id == sessionId }, approval)

        approvalTimeouts[approval.id] = Task { [weak self, holdSeconds = approvalHoldSeconds] in
            try? await Task.sleep(for: .seconds(holdSeconds))
            guard !Task.isCancelled else { return }
            self?.resolveApproval(approval.id, decision: nil)
        }
    }

    /// Resolves a held permission request: `true` → allow, `false` → deny,
    /// `nil` → give up and let the terminal prompt take over.
    func resolveApproval(_ id: UUID, decision: Bool?) {
        guard let index = pendingApprovals.firstIndex(where: { $0.id == id }) else { return }
        let approval = pendingApprovals.remove(at: index)
        approvalTimeouts.removeValue(forKey: id)?.cancel()

        if let respond = approvalResponders.removeValue(forKey: id) {
            respond(Self.approvalResponseBody(decision: decision))
        }
        if let decision {
            // An explicit decision unblocks (or interrupts) the session —
            // don't leave the orange card lingering until the next poll.
            waitingOverrides.removeValue(forKey: approval.sessionId)
            pendingTools.removeValue(forKey: approval.sessionId)
            Self.auditLog(approval, allowed: decision)
        }
        applyOverridesImmediately()
        onApprovalResolved?(approval)
        refresh()
    }

    private static func approvalResponseBody(decision: Bool?) -> Data {
        guard let decision else { return Data("{}".utf8) }
        // Shape verified against the 2.1.220 binary's PermissionRequest
        // hook-output zod schema.
        let payload: [String: Any] = [
            "hookSpecificOutput": [
                "hookEventName": "PermissionRequest",
                "decision": decision
                    ? ["behavior": "allow"]
                    : ["behavior": "deny", "message": "Denied from Compagnion"],
            ],
        ]
        return (try? JSONSerialization.data(withJSONObject: payload)) ?? Data("{}".utf8)
    }

    /// Every remote decision leaves a trace the user can audit.
    private nonisolated static func auditLog(_ approval: PendingApproval, allowed: Bool) {
        let entry: [String: Any] = [
            "at": ISO8601DateFormatter().string(from: Date()),
            "sessionId": approval.sessionId,
            "tool": approval.toolName ?? "?",
            "summary": approval.summary ?? "",
            "decision": allowed ? "allow" : "deny",
        ]
        guard var data = try? JSONSerialization.data(withJSONObject: entry) else { return }
        data.append(Data("\n".utf8))
        let url = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/Compagnion/approvals.jsonl")
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url)
        }
    }

    /// Copies the hook-fed side state onto one display row.
    private func decorate(_ display: inout SessionDisplay) {
        let id = display.id
        display.subagentCount = subagentCounts[id] ?? 0
        display.pendingToolName = pendingTools[id]
        if let activity = activities[id] {
            if Date().timeIntervalSince(activity.startedAt) > activityExpiry {
                activities.removeValue(forKey: id)
            } else {
                display.activity = activity
            }
        }
        display.question = questions[id]
        display.hadError = failures.contains(id)
        display.pendingApproval = pendingApprovals.first { $0.sessionId == id }
    }

    /// Repaints the affected cards without waiting for the poll to come back.
    private func applyOverridesImmediately() {
        var updated = displays
        for index in updated.indices {
            updated[index].waitingOverride = waitingOverrides[updated[index].id] != nil
            decorate(&updated[index])
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

        if let model = statusline.model, let sessionId = statusline.sessionId {
            let name = model.displayName.flatMap(SessionDisplay.shortModelName(fromDisplayName:))
                ?? model.id.flatMap(SessionDisplay.shortModelName(fromId:))
            if let name {
                modelFromStatusline[sessionId] = name
                for index in displays.indices where displays[index].id == sessionId {
                    displays[index].modelName = name
                }
            }
        }

        if let limits = statusline.rateLimits {
            let base = accountUsage ?? AccountUsage(measuredAt: Date())
            let merged = base.merging(
                fiveHour: (limits.fiveHour?.usedPercentage, limits.fiveHour?.resetsAt),
                sevenDay: (limits.sevenDay?.usedPercentage, limits.sevenDay?.resetsAt)
            )
            accountUsage = merged
            merged.save()
        }
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
/// states the panel cares about. Names verified against Claude Code 2.1.220.
/// Notably there is no `TurnEnd` event, and
/// `PreToolUse` fires on *every* tool call, so it must not imply "waiting".
enum HookEventKind {
    case needsAttention
    case turnFinished
    case turnFailed
    case activityStart
    case activityEnd
    case question
    case questionResolved
    case subagentStarted
    case subagentFinished
    case lifecycle
    case other

    /// `Notification` matcher values that mean the session is blocked on a human.
    private static let attentionNotifications: Set<String> = [
        "permission_prompt", "idle_prompt", "agent_needs_input",
    ]

    init(eventName: String, notificationType: String?, message: String?) {
        switch eventName {
        case "Notification":
            let type = (notificationType ?? "").lowercased()
            if Self.attentionNotifications.contains(type) {
                self = .needsAttention
            } else if type == "elicitation_dialog" {
                // The `message` carries the question being asked.
                self = .question
            } else if type == "elicitation_complete" || type == "elicitation_response" {
                self = .questionResolved
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
        case "PermissionRequest":
            self = .needsAttention
        case "Elicitation":
            self = .question
        case "ElicitationResult":
            self = .questionResolved
        case "PreToolUse":
            self = .activityStart
        case "PostToolUse", "PostToolUseFailure":
            self = .activityEnd
        case "PermissionDenied":
            self = .other
        case "Stop":
            self = .turnFinished
        case "StopFailure":
            self = .turnFailed
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
