import Foundation

/// Installs / removes Compagnion's Claude Code integration: a handful of
/// HTTP hooks in `~/.claude/settings.json` (see `.stitch/hooks-reference.md`
/// for the verified event names, matcher values, and HTTP-hook JSON shape)
/// plus a statusline-forwarding shell script.
///
/// ⚠️ Compagnion is a passive observer. Every hook this installer writes
/// carries only `{"type": "http", "url": ..., "timeout": 3}` — no `command`,
/// no scripting, nothing that could return a `decision`/`hookSpecificOutput`
/// body. Per the reference doc, a 2xx JSON response from an HTTP hook is
/// parsed exactly like a command hook's and CAN allow/deny/block a tool call
/// or a Stop — so this only works because `EventListener` always answers
/// with a bare `{}` (inert: no `decision`, no `hookSpecificOutput`). Never
/// change that response shape without re-reading this comment. `timeout` is
/// kept at 3 seconds (not the 5s used in the reference doc's illustrative
/// example) because blocking events wait on our listener before failing
/// open.
enum IntegrationInstaller {

    // MARK: - Configuration

    /// `~/.claude/settings.json`. A `static var` (not `let`) so tests can
    /// point it at a scratch fixture instead of the user's real file.
    nonisolated(unsafe) static var defaultSettingsURL: URL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".claude/settings.json")

    /// Where the statusline forwarder script is installed. Also overridable
    /// for tests.
    nonisolated(unsafe) static var forwarderURL: URL = URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent("Library/Application Support/Compagnion/statusline-forward.sh")

    static func endpoint(port: UInt16) -> String {
        "http://127.0.0.1:\(port)/event"
    }

    /// Seconds, not milliseconds — verified against the installed binary's
    /// `HttpHookSchema` doc-string ("Timeout in seconds for this specific
    /// request"). See `.stitch/hooks-reference.md` §3.
    private static let hookTimeoutSeconds = 3

    /// One matcher covering every `notification_type` that means "blocked on
    /// a human" (`permission_prompt`, `idle_prompt`, `agent_needs_input`)
    /// plus `agent_completed`, per `.stitch/hooks-reference.md` §2. Matchers
    /// are regex, so a single alternation is one group instead of four.
    private static let notificationMatcher = "permission_prompt|idle_prompt|agent_needs_input|agent_completed"

    private struct HookEventSpec {
        let name: String
        let matcher: String?
    }

    /// Events with a matcher concept get `"*"` (catch everything); events
    /// without one (`Stop`, `StopFailure`, `SessionStart`, `SessionEnd` —
    /// see reference §5) omit `matcher` entirely, matching the recommended
    /// fragment's convention.
    private static let hookEventSpecs: [HookEventSpec] = [
        HookEventSpec(name: "PermissionRequest", matcher: "*"),
        HookEventSpec(name: "Notification", matcher: notificationMatcher),
        HookEventSpec(name: "Stop", matcher: nil),
        HookEventSpec(name: "StopFailure", matcher: nil),
        HookEventSpec(name: "SubagentStart", matcher: "*"),
        HookEventSpec(name: "SubagentStop", matcher: "*"),
        HookEventSpec(name: "SessionStart", matcher: nil),
        HookEventSpec(name: "SessionEnd", matcher: nil),
    ]

    /// Compagnion-owned key holding the pre-install `statusLine` value so
    /// uninstall can restore it exactly (or remove the key if there wasn't
    /// one). Underscore-prefixed and namespaced to avoid ever colliding with
    /// a real Claude Code settings key.
    private static let statuslineMarkerKey = "_compagnionOriginalStatusLine"

    private static let maxBackups = 5

    typealias JSONObject = [String: Any]

    // MARK: - Public API

    static func inspect(settingsURL: URL = defaultSettingsURL, port: UInt16 = 48765) -> IntegrationReport {
        let backupURL = mostRecentBackup(settingsURL: settingsURL)
        guard let settings = try? loadSettings(from: settingsURL) else {
            return IntegrationReport(
                state: .notInstalled,
                statuslineForwarded: false,
                hooksDisabledBySettings: false,
                backupURL: backupURL
            )
        }

        let endpointString = endpoint(port: port)
        let hooks = settings["hooks"] as? JSONObject ?? [:]

        var missing: [String] = []
        for spec in hookEventSpecs {
            let groups = hooks[spec.name] as? [JSONObject] ?? []
            let present = groups.contains { group in
                (group["hooks"] as? [JSONObject] ?? []).contains { hookEntry in
                    (hookEntry["url"] as? String) == endpointString
                }
            }
            if !present { missing.append(spec.name) }
        }

        let state: IntegrationState
        if missing.isEmpty {
            state = .installed
        } else if missing.count == hookEventSpecs.count {
            state = .notInstalled
        } else {
            state = .partial(missing: missing)
        }

        let currentStatusLine = settings["statusLine"] as? JSONObject
        let statuslineForwarded = (currentStatusLine?["command"] as? String) == forwarderURL.path

        let hooksDisabled = (settings["disableAllHooks"] as? Bool) == true
            || (settings["allowManagedHooksOnly"] as? Bool) == true

        return IntegrationReport(
            state: state,
            statuslineForwarded: statuslineForwarded,
            hooksDisabledBySettings: hooksDisabled,
            backupURL: backupURL
        )
    }

    /// Additive, idempotent install. Throws (leaving the file untouched) if
    /// the existing settings file can't be parsed. Returns the backup URL
    /// written just before the new content was saved.
    @discardableResult
    static func install(settingsURL: URL = defaultSettingsURL, port: UInt16 = 48765) throws -> URL {
        var settings = try loadSettings(from: settingsURL)
        let backupURL = try writeBackup(settingsURL: settingsURL)

        let endpointString = endpoint(port: port)
        var hooks = settings["hooks"] as? JSONObject ?? [:]
        for spec in hookEventSpecs {
            var groups = hooks[spec.name] as? [JSONObject] ?? []
            mergeHookEntry(into: &groups, matcher: spec.matcher, endpoint: endpointString)
            hooks[spec.name] = groups
        }
        settings["hooks"] = hooks

        try installStatusline(into: &settings, port: port)

        try writeSettings(settings, to: settingsURL)
        pruneOldBackups(settingsURL: settingsURL)
        return backupURL
    }

    /// Removes exactly the hook entries and statusline wiring this installer
    /// added (identified by the endpoint URL), prunes any matcher/event
    /// containers left empty, restores the original `statusLine`, and
    /// deletes the forwarder script. Never touches an entry that doesn't
    /// carry Compagnion's URL.
    static func uninstall(settingsURL: URL = defaultSettingsURL, port: UInt16 = 48765) throws {
        var settings = try loadSettings(from: settingsURL)
        _ = try writeBackup(settingsURL: settingsURL)

        let endpointString = endpoint(port: port)
        if var hooks = settings["hooks"] as? JSONObject {
            for (eventName, value) in hooks {
                guard let groups = value as? [JSONObject] else { continue }
                let prunedGroups = groups.compactMap { group -> JSONObject? in
                    guard var hooksArray = group["hooks"] as? [JSONObject] else { return group }
                    hooksArray.removeAll { entry in
                        (entry["url"] as? String) == endpointString && (entry["type"] as? String) == "http"
                    }
                    guard !hooksArray.isEmpty else { return nil }
                    var group = group
                    group["hooks"] = hooksArray
                    return group
                }
                if prunedGroups.isEmpty {
                    hooks.removeValue(forKey: eventName)
                } else {
                    hooks[eventName] = prunedGroups
                }
            }
            if hooks.isEmpty {
                settings.removeValue(forKey: "hooks")
            } else {
                settings["hooks"] = hooks
            }
        }

        uninstallStatusline(from: &settings)

        if !restoreVerbatimBackup(matching: settings, settingsURL: settingsURL) {
            try writeSettings(settings, to: settingsURL)
        }
        try? FileManager.default.removeItem(at: forwarderURL)
        pruneOldBackups(settingsURL: settingsURL)
    }

    /// Re-serializing loses the user's own formatting: `JSONSerialization`
    /// sorts keys and re-indents, so an install/uninstall cycle would leave a
    /// large, purely cosmetic diff in a file we promised to leave alone.
    /// When a backup parses to exactly the content we're about to write, copy
    /// its bytes instead — that is the user's file, character for character.
    private static func restoreVerbatimBackup(matching settings: JSONObject, settingsURL: URL) -> Bool {
        let target = settings as NSDictionary
        for backup in allBackups(settingsURL: settingsURL) {
            guard let data = try? Data(contentsOf: backup),
                  let parsed = try? JSONSerialization.jsonObject(with: data) as? JSONObject,
                  target.isEqual(parsed as NSDictionary)
            else { continue }
            do {
                try data.write(to: settingsURL, options: .atomic)
                return true
            } catch {
                return false
            }
        }
        return false
    }

    // MARK: - Hook merging

    /// Adds Compagnion's hook entry to whichever existing group already
    /// shares this event's matcher, or appends a new `{matcher, hooks}`
    /// group. Hooks merge across settings files and within a single file's
    /// event array (reference §5) — so an existing group (the user's own
    /// hooks for this event) is extended, never replaced. No-ops if our URL
    /// is already present anywhere in this event's groups.
    private static func mergeHookEntry(into groups: inout [JSONObject], matcher: String?, endpoint: String) {
        let alreadyPresent = groups.contains { group in
            (group["hooks"] as? [JSONObject] ?? []).contains { ($0["url"] as? String) == endpoint }
        }
        guard !alreadyPresent else { return }

        let ourHook: JSONObject = ["type": "http", "url": endpoint, "timeout": hookTimeoutSeconds]

        if let index = groups.firstIndex(where: { ($0["matcher"] as? String) == matcher }) {
            var group = groups[index]
            var hooksArray = group["hooks"] as? [JSONObject] ?? []
            hooksArray.append(ourHook)
            group["hooks"] = hooksArray
            groups[index] = group
        } else {
            var newGroup: JSONObject = ["hooks": [ourHook]]
            if let matcher {
                newGroup["matcher"] = matcher
            }
            groups.append(newGroup)
        }
    }

    // MARK: - Statusline

    private static func installStatusline(into settings: inout JSONObject, port: UInt16) throws {
        let currentStatusLine = settings["statusLine"] as? JSONObject
        let alreadyInstalled = (currentStatusLine?["command"] as? String) == forwarderURL.path

        let originalCommand: String?
        if alreadyInstalled {
            // Re-running install must not overwrite the original we already
            // captured — just refresh the script (e.g. in case the port
            // changed) from what's stored.
            if let marker = settings[statuslineMarkerKey] as? JSONObject,
               let original = marker["statusLine"] as? JSONObject {
                originalCommand = (original["type"] as? String) == "command" ? original["command"] as? String : nil
            } else {
                originalCommand = nil
            }
        } else {
            originalCommand = (currentStatusLine?["type"] as? String) == "command"
                ? currentStatusLine?["command"] as? String
                : nil

            var marker: JSONObject = ["present": currentStatusLine != nil]
            if let currentStatusLine {
                marker["statusLine"] = currentStatusLine
            }
            settings[statuslineMarkerKey] = marker
            settings["statusLine"] = ["type": "command", "command": forwarderURL.path] as JSONObject
        }

        try writeForwarderScript(port: port, originalCommand: originalCommand)
    }

    private static func uninstallStatusline(from settings: inout JSONObject) {
        guard let marker = settings[statuslineMarkerKey] as? JSONObject else {
            // Never installed by Compagnion (or already reverted) — leave
            // whatever statusLine the user has untouched.
            return
        }
        if (marker["present"] as? Bool) == true, let original = marker["statusLine"] {
            settings["statusLine"] = original
        } else {
            settings.removeValue(forKey: "statusLine")
        }
        settings.removeValue(forKey: statuslineMarkerKey)
    }

    private static func writeForwarderScript(port: UInt16, originalCommand: String?) throws {
        let directory = forwarderURL.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            throw IntegrationInstallerError.forwarderScriptFailed(path: directory.path, reason: error.localizedDescription)
        }

        let contents = forwarderScriptContents(port: port, originalCommand: originalCommand)
        do {
            try contents.write(to: forwarderURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: forwarderURL.path)
        } catch {
            throw IntegrationInstallerError.forwarderScriptFailed(path: forwarderURL.path, reason: error.localizedDescription)
        }
    }

    /// Embeds `originalCommand` as a POSIX single-quoted literal (rather
    /// than PLAN.md's `eval` sketch, which breaks on quotes/apostrophes in
    /// the original command) so `sh -c '<literal>'` reproduces exactly what
    /// Claude Code itself would have run.
    private static func forwarderScriptContents(port: UInt16, originalCommand: String?) -> String {
        var script = """
        #!/bin/sh
        # Installed by Compagnion — DO NOT EDIT BY HAND.
        # Regenerated by IntegrationInstaller on every install/uninstall.
        #
        # Forwards Claude Code's statusline JSON to Compagnion's local
        # listener, then chains to the statusline command that was
        # configured before Compagnion installed this forwarder (if any),
        # so its output still becomes the visible status line text.

        INPUT=$(cat)
        printf '%s' "$INPUT" | curl -s -m 1 -X POST "\(endpoint(port: port))" \\
            -H 'Content-Type: application/json' -d @- >/dev/null 2>&1 &

        """
        if let originalCommand, !originalCommand.isEmpty {
            script += "printf '%s' \"$INPUT\" | sh -c \(shellSingleQuoted(originalCommand))\n"
        } else {
            script += "# No original statusline command was configured.\n"
        }
        return script
    }

    private static func shellSingleQuoted(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - Settings I/O

    private static func loadSettings(from url: URL) throws -> JSONObject {
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }

        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw IntegrationInstallerError.unreadableSettings(path: url.path, reason: error.localizedDescription)
        }
        guard !data.isEmpty else { return [:] }

        let parsed: Any
        do {
            parsed = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw IntegrationInstallerError.malformedSettings(path: url.path, reason: error.localizedDescription)
        }
        guard let object = parsed as? JSONObject else {
            throw IntegrationInstallerError.malformedSettings(
                path: url.path,
                reason: "the top-level JSON value is not an object"
            )
        }
        return object
    }

    /// Serializes with `.sortedKeys` + `.prettyPrinted` (stable, diffable),
    /// re-parses the result to confirm it's valid JSON, then writes
    /// atomically. Never writes anything that hasn't round-tripped.
    private static func writeSettings(_ settings: JSONObject, to url: URL) throws {
        let data: Data
        do {
            data = try JSONSerialization.data(withJSONObject: settings, options: [.prettyPrinted, .sortedKeys])
        } catch {
            throw IntegrationInstallerError.serializationFailed(reason: error.localizedDescription)
        }
        guard (try? JSONSerialization.jsonObject(with: data)) != nil else {
            throw IntegrationInstallerError.serializationFailed(reason: "re-parse check failed after serialization")
        }
        do {
            try data.write(to: url, options: .atomic)
        } catch {
            throw IntegrationInstallerError.unwritableSettings(path: url.path, reason: error.localizedDescription)
        }
    }

    // MARK: - Backups

    private static func writeBackup(settingsURL: URL) throws -> URL {
        let originalData: Data
        if FileManager.default.fileExists(atPath: settingsURL.path) {
            do {
                originalData = try Data(contentsOf: settingsURL)
            } catch {
                throw IntegrationInstallerError.unreadableSettings(path: settingsURL.path, reason: error.localizedDescription)
            }
        } else {
            originalData = Data("{}".utf8)
        }

        let backupURL = settingsURL.deletingLastPathComponent()
            .appendingPathComponent(backupFilename(for: settingsURL))
        do {
            try originalData.write(to: backupURL, options: .atomic)
        } catch {
            throw IntegrationInstallerError.backupFailed(path: backupURL.path, reason: error.localizedDescription)
        }
        return backupURL
    }

    private static func backupFilename(for settingsURL: URL) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let timestamp = formatter.string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return "\(settingsURL.lastPathComponent).compagnion-backup-\(timestamp)"
    }

    private static func backupPrefix(for settingsURL: URL) -> String {
        "\(settingsURL.lastPathComponent).compagnion-backup-"
    }

    private static func allBackups(settingsURL: URL) -> [URL] {
        let directory = settingsURL.deletingLastPathComponent()
        guard let entries = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return []
        }
        let prefix = backupPrefix(for: settingsURL)
        // ISO-8601 timestamps sort lexicographically in chronological order.
        return entries
            .filter { $0.lastPathComponent.hasPrefix(prefix) }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
    }

    private static func mostRecentBackup(settingsURL: URL) -> URL? {
        allBackups(settingsURL: settingsURL).first
    }

    /// Keeps at most `maxBackups` most-recent Compagnion backups next to
    /// `settingsURL`; prunes only files matching Compagnion's own naming
    /// pattern, never anything else in the directory.
    private static func pruneOldBackups(settingsURL: URL) {
        let backups = allBackups(settingsURL: settingsURL)
        guard backups.count > maxBackups else { return }
        for stale in backups.dropFirst(maxBackups) {
            try? FileManager.default.removeItem(at: stale)
        }
    }
}

// MARK: - Model

enum IntegrationState: Equatable {
    case notInstalled
    case installed
    case partial(missing: [String])
}

struct IntegrationReport: Equatable {
    let state: IntegrationState
    let statuslineForwarded: Bool
    let hooksDisabledBySettings: Bool
    let backupURL: URL?
}

enum IntegrationInstallerError: LocalizedError {
    case malformedSettings(path: String, reason: String)
    case unreadableSettings(path: String, reason: String)
    case unwritableSettings(path: String, reason: String)
    case backupFailed(path: String, reason: String)
    case forwarderScriptFailed(path: String, reason: String)
    case serializationFailed(reason: String)

    var errorDescription: String? {
        switch self {
        case .malformedSettings(let path, let reason):
            return "Claude Code's settings file (\(path)) isn't valid JSON (\(reason)). Nothing was changed — fix or remove the file, then try again."
        case .unreadableSettings(let path, let reason):
            return "Couldn't read \(path): \(reason)."
        case .unwritableSettings(let path, let reason):
            return "Couldn't write \(path): \(reason). Your settings were not modified."
        case .backupFailed(let path, let reason):
            return "Couldn't write a safety backup to \(path): \(reason). Nothing was changed."
        case .forwarderScriptFailed(let path, let reason):
            return "Couldn't write the status line forwarder script at \(path): \(reason)."
        case .serializationFailed(let reason):
            return "Internal error preparing settings.json for writing: \(reason)."
        }
    }
}
