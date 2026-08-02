import AppKit
import Foundation
import UserNotifications

/// No-op unless `COMPAGNION_DEBUG` is set — mirrors `EventListener`'s logger.
private func log(_ message: @autoclosure () -> String) {
    guard ProcessInfo.processInfo.environment["COMPAGNION_DEBUG"] != nil else { return }
    FileHandle.standardError.write(Data(("[Notifier] " + message() + "\n").utf8))
}

/// Local macOS notifications for the three moments a session wants a human:
/// blocked on input, a turn finishing, a sub-agent finishing. Every toggle is
/// read from `SettingsKeys` (owned by the settings UI) so this class never
/// invents its own preference storage.
///
/// `UNUserNotificationCenter.current()` traps at runtime
/// ("bundleProxyForCurrentProcess is nil") unless the executable is running
/// inside a real `.app` bundle with a `CFBundleIdentifier` — exactly the case
/// during `swift run` development. Verified empirically: a bare `swiftc`
/// binary run directly reports `Bundle.main.bundleIdentifier == nil`; the
/// same binary copied into a minimal `Some.app/Contents/MacOS/` with an
/// `Info.plist` reports the identifier from that plist. So `center` is
/// computed exactly once, at `init`, gated on `Bundle.main.bundleIdentifier`
/// — every other method reads that one stored optional and no-ops when nil.
@MainActor
final class Notifier: NSObject, ObservableObject {
    enum Authorization: Equatable {
        case notDetermined
        case authorized
        case denied
        case unavailable(String)
    }

    private static let unavailableReason = "Notifications require the packaged Compagnion.app — run ./make-app.sh"

    /// Category carrying the "Open" action; every notification we post uses it.
    private static let categoryIdentifier = "compagnion.session"
    /// Also matches a tap on the notification body itself — see `didReceive`.
    private static let openActionIdentifier = "compagnion.open"
    private static let waitingIdentifierPrefix = "compagnion.waiting."
    private nonisolated static let sessionIdKey = "sessionId"

    @Published private(set) var authorization: Authorization

    /// Invoked when the user clicks a notification (body or "Open" action),
    /// passed the session id, so the app can activate its hosting app.
    var onOpenSession: ((String) -> Void)?

    /// Sessions with a live "needs you" notification — guards against
    /// re-announcing the same waiting episode on every poll tick.
    private var announcedWaiting: Set<String> = []

    /// The one guarded handle onto `UNUserNotificationCenter.current()`. Only
    /// ever set here, in `init`; every other member reads this instead of
    /// touching the notification center directly.
    private let center: UNUserNotificationCenter?

    override init() {
        // First launch should already match PLAN.md's defaults even before
        // the settings UI has been opened once.
        UserDefaults.standard.register(defaults: [
            SettingsKeys.notifyWaiting: true,
            SettingsKeys.notifyTurnFinished: false,
            SettingsKeys.notifySubagentFinished: false,
        ])

        if Bundle.main.bundleIdentifier != nil {
            center = UNUserNotificationCenter.current()
            authorization = .notDetermined
        } else {
            center = nil
            authorization = .unavailable(Self.unavailableReason)
        }

        super.init()

        guard let center else { return }
        center.delegate = self
        let openAction = UNNotificationAction(identifier: Self.openActionIdentifier, title: "Open", options: [.foreground])
        let category = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [openAction],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])
        refreshAuthorization()
    }

    // MARK: - Authorization

    /// Never called at launch — only when the user flips a notification
    /// toggle on in Settings.
    func requestAuthorizationIfNeeded() async {
        guard let center else { return }
        guard authorization == .notDetermined else { return }
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound])
            authorization = granted ? .authorized : .denied
        } catch {
            log("requestAuthorization failed: \(error)")
            refreshAuthorization()
        }
    }

    func refreshAuthorization() {
        guard let center else { return }
        center.getNotificationSettings { [weak self] settings in
            Task { @MainActor in
                guard let self else { return }
                switch settings.authorizationStatus {
                case .authorized, .provisional, .ephemeral:
                    self.authorization = .authorized
                case .denied:
                    self.authorization = .denied
                case .notDetermined:
                    self.authorization = .notDetermined
                @unknown default:
                    self.authorization = .notDetermined
                }
            }
        }
    }

    // MARK: - Notifying

    /// "⟡ {name} needs you" — the tool the hook reported, else the reason the
    /// poll reported (`ClaudeSession.waitingFor`), else just the folder.
    func notifyWaiting(_ display: SessionDisplay) {
        guard UserDefaults.standard.bool(forKey: SettingsKeys.notifyWaiting) else { return }
        guard let center else { return }

        let hint = (display.pendingToolName ?? display.session.waitingFor)?
            .trimmingCharacters(in: .whitespaces)
        let body: String
        if let hint, !hint.isEmpty {
            body = "\(hint) · \(display.folderName)"
        } else {
            body = display.folderName
        }

        deliver(
            center: center,
            identifier: Self.waitingIdentifier(for: display.id),
            title: "⟡ \(display.session.displayName) needs you",
            body: body,
            sessionId: display.id
        )
        announcedWaiting.insert(display.id)
    }

    /// "✓ {name} finished" — folder + elapsed time.
    func notifyTurnFinished(_ display: SessionDisplay) {
        guard UserDefaults.standard.bool(forKey: SettingsKeys.notifyTurnFinished) else { return }
        guard let center else { return }

        var body = display.folderName
        if let elapsed = display.elapsedLabel { body += " · \(elapsed)" }

        deliver(
            center: center,
            identifier: "compagnion.turnFinished.\(display.id).\(UUID().uuidString)",
            title: "✓ \(display.session.displayName) finished",
            body: body,
            sessionId: display.id
        )
    }

    /// "{name}: sub-agent finished".
    func notifySubagentFinished(_ display: SessionDisplay) {
        guard UserDefaults.standard.bool(forKey: SettingsKeys.notifySubagentFinished) else { return }
        guard let center else { return }

        deliver(
            center: center,
            identifier: "compagnion.subagentFinished.\(display.id).\(UUID().uuidString)",
            title: "\(display.session.displayName): sub-agent finished",
            body: display.folderName,
            sessionId: display.id
        )
    }

    /// Called once a session leaves the waiting state: drops the de-dup
    /// entry and pulls back any notification the user hasn't dismissed yet.
    func clearWaiting(sessionId: String) {
        announcedWaiting.remove(sessionId)
        guard let center else { return }
        let identifier = Self.waitingIdentifier(for: sessionId)
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    private static func waitingIdentifier(for sessionId: String) -> String {
        waitingIdentifierPrefix + sessionId
    }

    private func deliver(center: UNUserNotificationCenter, identifier: String, title: String, body: String, sessionId: String) {
        // "Waiting" notifications are on by default, but macOS only shows the
        // permission prompt when we ask. Nobody has necessarily opened
        // Settings, so ask the first time we actually have something to say —
        // and deliver anyway: if the user allows, the request lands.
        if authorization == .notDetermined {
            Task { await requestAuthorizationIfNeeded() }
        }

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.categoryIdentifier = Self.categoryIdentifier
        content.userInfo = [Self.sessionIdKey: sessionId]

        // Deliver immediately — no scheduling trigger.
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        center.add(request) { error in
            if let error { log("failed to deliver \(identifier): \(error)") }
        }
    }
}

// MARK: - UNUserNotificationCenterDelegate

extension Notifier: UNUserNotificationCenterDelegate {
    /// Show the banner (+ sound) even while Compagnion is the frontmost app.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    /// The user clicked the notification body or the "Open" action — either
    /// way, jump to the session's hosting app.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let sessionId = response.notification.request.content.userInfo[Self.sessionIdKey] as? String
        completionHandler()
        guard let sessionId else { return }
        Task { @MainActor in
            self.onOpenSession?(sessionId)
        }
    }
}
