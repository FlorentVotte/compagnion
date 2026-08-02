import Foundation

/// Metadata about a session pulled from the undocumented
/// `~/.claude/projects/<slug>/sessions-index.json` file.
struct SessionIdentity: Equatable {
    let firstPrompt: String?     // trimmed to ~80 chars, whitespace/newlines collapsed
    let gitBranch: String?       // nil when empty
    let messageCount: Int?
    let transcriptPath: String?  // absolute path to the .jsonl, if known
}

/// A point-in-time read of a session's context-window fill, derived from the
/// most recent `message.usage` entry in its transcript.
struct ContextUsage: Equatable {
    let fraction: Double         // 0...1 (clamped)
    let totalInputTokens: Int
    let contextWindowSize: Int
    let measuredAt: Date
}

/// Reads undocumented Claude Code project metadata: the per-project
/// `sessions-index.json` and transcript JSONL files under
/// `~/.claude/projects/<slug>/`. Every read is failure-tolerant: any decode
/// error, missing file, or malformed line degrades to `nil`, never throws and
/// never crashes.
///
/// `@unchecked Sendable`: the only shared mutable state is the index cache
/// (`cache`/`cacheOrder`), guarded by `cacheLock`. `FileManager.default` is
/// used read-only (no delegate), which Apple documents as safe to share
/// across threads for plain file queries.
final class SessionEnricher: @unchecked Sendable {

    // MARK: - sessions-index.json shape (version 1, undocumented)

    private struct IndexEntry: Decodable {
        let sessionId: String?
        let fullPath: String?
        let firstPrompt: String?
        let messageCount: Int?
        let gitBranch: String?
    }

    private struct IndexFile: Decodable {
        let entries: [IndexEntry]?
    }

    private struct CachedIndex {
        let mtime: Date
        let entries: [IndexEntry]
    }

    // MARK: - Cache (bounded, LRU by path; keyed implicitly by file mtime)

    private let cacheLock = NSLock()
    private var cache: [String: CachedIndex] = [:]
    private var cacheOrder: [String] = []
    private let cacheLimit = 32

    private let fileManager = FileManager.default

    // MARK: - Public API

    /// cwd with every non-alphanumeric character replaced by `-`. Matches the
    /// convention observed in real `~/.claude/projects/` directory names on
    /// this machine (e.g. `/Users/florent/dev/compagnion` →
    /// `-Users-florent-dev-compagnion`; a leading `/` and every path `/`
    /// separator both become a single `-`).
    static func projectSlug(for cwd: String) -> String {
        String(cwd.map { $0.isLetter || $0.isNumber ? $0 : "-" })
    }

    /// Look up this session's identity in its project's `sessions-index.json`.
    /// Returns `nil` silently if the file is missing, unparsable, or has no
    /// matching entry — callers should degrade to v0.1 display.
    func identity(cwd: String, sessionId: String) -> SessionIdentity? {
        let dir = projectDir(for: cwd)
        guard let entries = loadIndex(path: "\(dir)/sessions-index.json") else { return nil }
        guard let entry = entries.first(where: { $0.sessionId == sessionId }) else { return nil }

        let path = resolvedTranscriptPath(dir: dir, sessionId: sessionId, fullPathHint: entry.fullPath)
        let branch = entry.gitBranch
        return SessionIdentity(
            firstPrompt: Self.collapsedPrompt(entry.firstPrompt),
            gitBranch: (branch?.isEmpty ?? true) ? nil : branch,
            messageCount: entry.messageCount,
            transcriptPath: path
        )
    }

    /// Prefer the index entry's `fullPath`; fall back to
    /// `~/.claude/projects/<slug>/<sessionId>.jsonl` if that file exists.
    /// Works even when `sessions-index.json` doesn't exist for the project
    /// (observed: several projects on this machine have transcripts but no
    /// index file).
    func transcriptPath(cwd: String, sessionId: String) -> String? {
        let dir = projectDir(for: cwd)
        let hint = loadIndex(path: "\(dir)/sessions-index.json")?
            .first(where: { $0.sessionId == sessionId })?.fullPath
        return resolvedTranscriptPath(dir: dir, sessionId: sessionId, fullPathHint: hint)
    }

    /// Compute context-window fill from the tail of a transcript JSONL,
    /// without reading the whole file (transcripts can reach hundreds of MB
    /// and individual lines — image/attachment payloads — can exceed 1 MB).
    /// Seeks from EOF, reads back in 64 KB chunks up to ~1 MB total, and
    /// scans backwards for the most recent non-sidechain line with
    /// `message.usage`. Returns `nil` if none is found in that window.
    func contextUsage(transcriptPath: String, contextWindowSize: Int = 200_000) -> ContextUsage? {
        guard let handle = FileHandle(forReadingAtPath: transcriptPath) else {
            log("contextUsage: cannot open \(transcriptPath)")
            return nil
        }
        defer { try? handle.close() }

        guard let fileSize = try? handle.seekToEnd(), fileSize > 0 else { return nil }

        let chunkSize: UInt64 = 64 * 1024
        let maxTotal: UInt64 = 1024 * 1024
        var collected = Data()
        var offset = fileSize

        while offset > 0 && collected.count < maxTotal {
            let readSize = min(chunkSize, offset)
            offset -= readSize
            do {
                try handle.seek(toOffset: offset)
            } catch {
                break
            }
            guard let chunk = try? handle.read(upToCount: Int(readSize)), !chunk.isEmpty else { break }
            collected = chunk + collected

            if let tokens = Self.latestTotalInputTokens(in: collected, discardFirstPartialLine: offset > 0) {
                let fraction = min(1, max(0, Double(tokens) / Double(contextWindowSize)))
                return ContextUsage(
                    fraction: fraction,
                    totalInputTokens: tokens,
                    contextWindowSize: contextWindowSize,
                    measuredAt: Date()
                )
            }
        }
        log("contextUsage: no usage line found in tail of \(transcriptPath)")
        return nil
    }

    /// Drop all cached index reads. Safe to call from any thread/queue.
    func clearCache() {
        cacheLock.lock()
        cache.removeAll()
        cacheOrder.removeAll()
        cacheLock.unlock()
    }

    // MARK: - Index loading (mtime-cached)

    private func projectDir(for cwd: String) -> String {
        "\(NSHomeDirectory())/.claude/projects/\(Self.projectSlug(for: cwd))"
    }

    private func resolvedTranscriptPath(dir: String, sessionId: String, fullPathHint: String?) -> String? {
        if let fullPathHint, fileManager.fileExists(atPath: fullPathHint) {
            return fullPathHint
        }
        let fallback = "\(dir)/\(sessionId).jsonl"
        return fileManager.fileExists(atPath: fallback) ? fallback : nil
    }

    /// Parsed `sessions-index.json` entries, cached by (path, mtime). Re-checks
    /// mtime at most once per call; re-parses only when it has changed.
    private func loadIndex(path: String) -> [IndexEntry]? {
        guard let attrs = try? fileManager.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date else {
            log("loadIndex: no file at \(path)")
            return nil
        }

        cacheLock.lock()
        if let cached = cache[path], cached.mtime == mtime {
            let entries = cached.entries
            touch(path)
            cacheLock.unlock()
            return entries
        }
        cacheLock.unlock()

        guard let data = fileManager.contents(atPath: path) else {
            log("loadIndex: could not read \(path)")
            return nil
        }
        guard let decoded = try? JSONDecoder().decode(IndexFile.self, from: data),
              let entries = decoded.entries else {
            log("loadIndex: bad JSON in \(path)")
            return nil
        }

        cacheLock.lock()
        cache[path] = CachedIndex(mtime: mtime, entries: entries)
        touch(path)
        if cacheOrder.count > cacheLimit, let oldest = cacheOrder.first {
            cacheOrder.removeFirst()
            cache.removeValue(forKey: oldest)
        }
        cacheLock.unlock()
        return entries
    }

    /// Must be called while holding `cacheLock`.
    private func touch(_ path: String) {
        cacheOrder.removeAll { $0 == path }
        cacheOrder.append(path)
    }

    // MARK: - Parsing helpers

    private static func collapsedPrompt(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let collapsed = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > 80 else { return collapsed }
        return String(collapsed.prefix(80)) + "…"
    }

    /// Scans `data` (a suffix of a transcript file, possibly starting mid-line)
    /// backwards for the most recent line whose JSON has `message.usage` and
    /// is not a sidechain (sub-agent) turn. `discardFirstPartialLine` should be
    /// `true` whenever `data` doesn't start at byte 0 of the file, since the
    /// first line in that case is likely truncated.
    private static func latestTotalInputTokens(in data: Data, discardFirstPartialLine: Bool) -> Int? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if discardFirstPartialLine, !lines.isEmpty {
            lines.removeFirst()
        }

        for line in lines.reversed() {
            guard let lineData = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: lineData),
                  let dict = object as? [String: Any] else {
                continue
            }
            if let isSidechain = dict["isSidechain"] as? Bool, isSidechain {
                continue
            }
            guard let message = dict["message"] as? [String: Any],
                  let usage = message["usage"] as? [String: Any] else {
                continue
            }
            let input = (usage["input_tokens"] as? Int) ?? 0
            let cacheCreation = (usage["cache_creation_input_tokens"] as? Int) ?? 0
            let cacheRead = (usage["cache_read_input_tokens"] as? Int) ?? 0
            return input + cacheCreation + cacheRead
        }
        return nil
    }

    // MARK: - Logging

    private func log(_ message: @autoclosure () -> String) {
        guard ProcessInfo.processInfo.environment["COMPAGNION_DEBUG"] != nil else { return }
        FileHandle.standardError.write("[SessionEnricher] \(message())\n".data(using: .utf8) ?? Data())
    }
}
