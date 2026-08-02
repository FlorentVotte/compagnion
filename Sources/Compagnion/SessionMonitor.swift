import Foundation

/// One entry from `claude agents --json`. All fields except `cwd` are optional
/// because the shape differs between interactive and background sessions and
/// may evolve between Claude Code versions.
struct ClaudeSession: Decodable, Identifiable, Equatable {
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

@MainActor
final class SessionMonitor: ObservableObject {
    @Published private(set) var sessions: [ClaudeSession] = []
    @Published private(set) var lastError: String?
    @Published private(set) var lastUpdated: Date?

    var waitingCount: Int { sessions.filter(\.needsAttention).count }
    var busyCount: Int { sessions.filter(\.isBusy).count }

    private var timer: Timer?
    private var isRefreshing = false
    private let claudePath: String?

    init(pollInterval: TimeInterval = 3) {
        claudePath = Self.findClaude()
        if claudePath == nil {
            lastError = "claude CLI not found — install Claude Code first"
        }
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
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

    func refresh() {
        guard let claudePath, !isRefreshing else { return }
        isRefreshing = true
        Task.detached(priority: .utility) {
            let result = Self.fetchSessions(claudePath: claudePath)
            await MainActor.run {
                self.isRefreshing = false
                switch result {
                case .success(let sessions):
                    // Attention first, then busy, then the rest; stable by name.
                    self.sessions = sessions.sorted { a, b in
                        func rank(_ s: ClaudeSession) -> Int {
                            if s.needsAttention { return 0 }
                            if s.isBusy { return 1 }
                            if !s.isFinished { return 2 }
                            return 3
                        }
                        if rank(a) != rank(b) { return rank(a) < rank(b) }
                        return a.displayName.localizedCaseInsensitiveCompare(b.displayName) == .orderedAscending
                    }
                    self.lastError = nil
                    self.lastUpdated = Date()
                case .failure(let error):
                    self.lastError = error.localizedDescription
                }
            }
        }
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
}
