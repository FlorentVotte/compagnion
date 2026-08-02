import AppKit
import Darwin
import Foundation

/// No-op unless `COMPAGNION_DEBUG` is set in the environment — process-tree
/// walks and AppleScript attempts happen on every click, so keep this quiet
/// by default.
private func log(_ message: @autoclosure () -> String) {
    guard ProcessInfo.processInfo.environment["COMPAGNION_DEBUG"] != nil else { return }
    FileHandle.standardError.write(Data(("[HostAppResolver] " + message() + "\n").utf8))
}

/// The GUI application hosting a Claude Code session's terminal (or editor
/// integrated terminal), resolved by walking the process tree upward from
/// the session's pid.
struct HostApp: Equatable {
    let bundleURL: URL
    let bundleIdentifier: String?
    /// pid of the ancestor process whose executable lives inside
    /// `bundleURL` — not necessarily the app's main pid (helper processes
    /// live inside the same bundle), which is why `activate` falls back to
    /// `NSWorkspace.openApplication` when no `NSRunningApplication` matches.
    let pid: pid_t
    let displayName: String
}

/// Resolves a session pid to the GUI app hosting its terminal, with caching.
///
/// Thread safety: `hostApp(for:)` may be called from `SessionMonitor`'s
/// background polling task while `activate` runs on the main actor. All
/// shared mutable state (the cache) is guarded by `lock`, a plain `NSLock`
/// — the critical sections are tiny (dictionary reads/writes of value
/// types), so a single lock is simpler and cheap enough at this scale (a
/// handful of sessions, polled every few seconds) rather than an actor or
/// NSCache.
final class HostAppResolver: @unchecked Sendable {
    /// Best-effort tab/window focus (AppleScript for Terminal/iTerm2, `open
    /// -b` for VS Code/Cursor). Disable to fall back to plain app
    /// activation only — useful if AppleScript automation prompts become
    /// annoying, or for tests.
    static var enableTabFocus = true

    private let lock = NSLock()
    private var cache: [Int: HostApp?] = [:]

    // MARK: - Public API

    /// Cached; returns nil for background agents or any session with no GUI
    /// ancestor (e.g. spawned by a daemon, or the tree walk hit pid 1).
    func hostApp(for sessionPid: Int) -> HostApp? {
        lock.lock()
        if let cached = cache[sessionPid] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let resolved = Self.walkForHostApp(sessionPid: pid_t(sessionPid))
        lock.lock()
        cache[sessionPid] = resolved
        lock.unlock()
        log("resolved session \(sessionPid) -> \(resolved.map { "\($0.displayName) (pid \($0.pid))" } ?? "nil")")
        return resolved
    }

    /// Drops cache entries for sessions that are no longer in `claude
    /// agents --json`, so a pid that's later reused doesn't return a stale
    /// host app.
    func invalidate(keepingSessionPids: Set<Int>) {
        lock.lock()
        cache = cache.filter { keepingSessionPids.contains($0.key) }
        lock.unlock()
    }

    /// Brings the session's hosting app to the front. Returns whether an
    /// activation request was sent (mirrors `NSRunningApplication.activate`'s
    /// own contract: "successfully sent", not "guaranteed visible").
    @discardableResult
    @MainActor
    func activate(sessionPid: Int, cwd: String?) -> Bool {
        guard let host = hostApp(for: sessionPid) else {
            log("activate: no host app for session pid \(sessionPid)")
            return false
        }

        var activated = false
        if let running = NSRunningApplication(processIdentifier: host.pid) {
            // Compagnion is a menu-bar accessory app; yield first so the
            // activation below isn't competing with our own panel.
            NSApp.deactivate()
            activated = running.activate(options: [])
        }

        if !activated {
            activated = openApplicationRequest(at: host.bundleURL)
        }

        if Self.enableTabFocus {
            focusTab(host: host, sessionPid: sessionPid, cwd: cwd)
        }

        log("activate(\(sessionPid)) -> \(host.displayName): \(activated)")
        return activated
    }

    // MARK: - Activation fallback

    /// `NSRunningApplication(processIdentifier:)` only finds pids AppKit
    /// already tracks as "running applications"; the ancestor pid we walked
    /// to can be a helper process inside the bundle that doesn't qualify.
    /// Fire the launch-or-front request asynchronously — blocking the main
    /// actor on its completion handler risks deadlocking if AppKit invokes
    /// it back on the main queue.
    @MainActor
    private func openApplicationRequest(at bundleURL: URL) -> Bool {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.promptsUserIfNeeded = false
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: configuration) { _, error in
            if let error {
                log("openApplication(\(bundleURL.lastPathComponent)) failed: \(error.localizedDescription)")
            }
        }
        return true
    }

    // MARK: - Tab/window focus (best effort)

    @MainActor
    private func focusTab(host: HostApp, sessionPid: Int, cwd: String?) {
        guard let bundleIdentifier = host.bundleIdentifier else { return }

        switch bundleIdentifier {
        case "com.apple.Terminal":
            focusTerminalTab(sessionPid: sessionPid)
        case "com.googlecode.iterm2":
            focusITermTab(sessionPid: sessionPid)
        default:
            if bundleIdentifier.range(of: "com.microsoft.vscode", options: .caseInsensitive) != nil
                || bundleIdentifier.range(of: "com.todesktop", options: .caseInsensitive) != nil
                || bundleIdentifier.range(of: "cursor", options: .caseInsensitive) != nil {
                if let cwd, !cwd.isEmpty {
                    _ = Self.run("/usr/bin/open", ["-b", bundleIdentifier, cwd])
                }
            }
        }
    }

    private func focusTerminalTab(sessionPid: Int) {
        guard let tty = Self.tty(ofPid: pid_t(sessionPid)) else { return }
        let script = """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    try
                        if (tty of t) contains "\(tty)" then
                            set frontmost of w to true
                            set selected tab of w to t
                            return true
                        end if
                    end try
                end repeat
            end repeat
        end tell
        return false
        """
        runAppleScript(script)
    }

    private func focusITermTab(sessionPid: Int) {
        guard let tty = Self.tty(ofPid: pid_t(sessionPid)) else { return }
        let script = """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        try
                            if (tty of s) contains "\(tty)" then
                                select w
                                tell w to select t
                                return true
                            end if
                        end try
                    end repeat
                end repeat
            end repeat
        end tell
        return false
        """
        runAppleScript(script)
    }

    /// Runs an AppleScript defensively: compilation or execution failure
    /// (including the Automation-permission prompt/denial on first use,
    /// `errAEEventNotPermitted`) is logged and swallowed — this must never
    /// block or override the activation result already computed by
    /// `activate`.
    private func runAppleScript(_ source: String) {
        guard let appleScript = NSAppleScript(source: source) else {
            log("AppleScript failed to parse")
            return
        }
        var errorInfo: NSDictionary?
        appleScript.executeAndReturnError(&errorInfo)
        if let errorInfo {
            log("AppleScript error: \(errorInfo)")
        }
    }

    // MARK: - Process tree walk

    /// Walks parents from `sessionPid` until an ancestor's executable path
    /// contains a `.app/` bundle component, skipping `loginwindow` and
    /// Compagnion's own bundle. Stops at pid 1 or after 20 hops.
    private static func walkForHostApp(sessionPid: pid_t) -> HostApp? {
        guard sessionPid > 0 else { return nil }
        let ownBundleURL = Bundle.main.bundleURL.standardizedFileURL

        var pid = sessionPid
        var hops = 0
        while pid > 1 && hops < 20 {
            guard let hop = nextHop(from: pid) else { break }

            if let bundleURL = bundleURL(fromExecutablePath: hop.path) {
                let standardized = bundleURL.standardizedFileURL
                let isLoginwindow = standardized.path.hasPrefix("/System/Library/CoreServices/")
                    && standardized.lastPathComponent.caseInsensitiveCompare("loginwindow.app") == .orderedSame
                let isSelf = standardized == ownBundleURL
                if !isLoginwindow && !isSelf {
                    return makeHostApp(bundleURL: standardized, pid: pid)
                }
            }

            pid = hop.ppid
            hops += 1
        }
        return nil
    }

    private static func makeHostApp(bundleURL: URL, pid: pid_t) -> HostApp {
        let bundle = Bundle(url: bundleURL)
        let displayName = (bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? bundleURL.deletingPathExtension().lastPathComponent
        return HostApp(
            bundleURL: bundleURL,
            bundleIdentifier: bundle?.bundleIdentifier,
            pid: pid,
            displayName: displayName
        )
    }

    /// Truncates an executable path at the end of its first `.app` bundle
    /// component, e.g. `/A/Foo.app/Contents/MacOS/Foo` -> `/A/Foo.app`. Uses
    /// the *first* occurrence so a helper nested inside
    /// `Foo.app/Contents/Frameworks/Foo Helper.app/...` still resolves to
    /// the outer, user-facing bundle.
    private static func bundleURL(fromExecutablePath path: String) -> URL? {
        guard let range = path.range(of: ".app/") else { return nil }
        let bundlePath = String(path[path.startIndex..<range.upperBound].dropLast())
        return URL(fileURLWithPath: bundlePath)
    }

    /// One step of the walk: this pid's parent pid and executable path.
    /// Prefers `sysctl`/`proc_pidpath` (no process spawn, verified working
    /// against a real Claude Code session pid during development); falls
    /// back to `ps -o ppid=,comm= -p <pid>` for whichever half fails (e.g.
    /// a pid owned by another user, or a sandboxing edge case).
    private static func nextHop(from pid: pid_t) -> (ppid: pid_t, path: String)? {
        let sysctlPpid = parentPid(of: pid)
        let pidPath = executablePath(of: pid)
        if let sysctlPpid, let pidPath {
            return (sysctlPpid, pidPath)
        }
        guard let fallback = fallbackPpidAndComm(of: pid) else {
            return nil
        }
        return (sysctlPpid ?? fallback.ppid, pidPath ?? fallback.comm)
    }

    /// `sysctl(CTL_KERN, KERN_PROC, KERN_PROC_PID, pid)` -> `kp_eproc.e_ppid`.
    private static func parentPid(of pid: pid_t) -> pid_t? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let result = mib.withUnsafeMutableBufferPointer { mibPtr -> Int32 in
            sysctl(mibPtr.baseAddress, u_int(mibPtr.count), &info, &size, nil, 0)
        }
        guard result == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    /// `proc_pidpath` — the full executable path for a pid, without
    /// spawning a process.
    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [Int8](repeating: 0, count: Int(MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(MAXPATHLEN))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }

    private static func fallbackPpidAndComm(of pid: pid_t) -> (ppid: pid_t, comm: String)? {
        guard let result = run("/bin/ps", ["-o", "ppid=,comm=", "-p", String(pid)]), result.status == 0 else {
            return nil
        }
        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let firstSpace = trimmed.firstIndex(of: " ") else { return nil }
        guard let ppid = pid_t(trimmed[trimmed.startIndex..<firstSpace]) else { return nil }
        let comm = trimmed[trimmed.index(after: firstSpace)...].trimmingCharacters(in: .whitespaces)
        return (ppid, comm)
    }

    private static func tty(ofPid pid: pid_t) -> String? {
        guard let result = run("/bin/ps", ["-o", "tty=", "-p", String(pid)]), result.status == 0 else {
            return nil
        }
        let trimmed = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "??" else { return nil }
        return trimmed
    }

    // MARK: - Process spawning (ps / open fallbacks)

    /// Runs a short-lived helper process with an augmented PATH (mirrors
    /// `SessionMonitor.fetchSessions`: Finder-launched apps get a minimal
    /// PATH) and a hard watchdog so a hung child can never block the
    /// caller beyond `timeout`.
    private static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 2.0) -> (status: Int32, stdout: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        var env = ProcessInfo.processInfo.environment
        let extraPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/bin", "/usr/bin"]
        env["PATH"] = (extraPaths + [env["PATH"] ?? ""]).joined(separator: ":")
        process.environment = env

        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            log("spawn \(executable) failed: \(error.localizedDescription)")
            return nil
        }

        let watchdog = DispatchWorkItem {
            if process.isRunning {
                process.terminate()
            }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: watchdog)

        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        watchdog.cancel()

        let output = String(data: data, encoding: .utf8) ?? ""
        return (process.terminationStatus, output)
    }
}
