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
    /// Category for held permission requests: Allow / Deny buttons.
    private static let approvalCategoryIdentifier = "compagnion.approval"
    private nonisolated static let allowActionIdentifier = "compagnion.allow"
    private nonisolated static let denyActionIdentifier = "compagnion.deny"
    private static let waitingIdentifierPrefix = "compagnion.waiting."
    private static let approvalIdentifierPrefix = "compagnion.approval."
    private nonisolated static let sessionIdKey = "sessionId"
    private nonisolated static let approvalIdKey = "approvalId"

    @Published private(set) var authorization: Authorization

    /// Invoked when the user clicks a notification (body or "Open" action),
    /// passed the session id, so the app can activate its hosting app.
    var onOpenSession: ((String) -> Void)?

    /// Invoked when the user answers a held permission request from the
    /// notification's Allow/Deny buttons.
    var onApprovalDecision: ((UUID, Bool) -> Void)?

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
            SettingsKeys.notifyError: true,
            SettingsKeys.remoteApproval: false,
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
        let sessionCategory = UNNotificationCategory(
            identifier: Self.categoryIdentifier,
            actions: [openAction],
            intentIdentifiers: [],
            options: []
        )
        let allowAction = UNNotificationAction(identifier: Self.allowActionIdentifier, title: "Allow", options: [])
        let denyAction = UNNotificationAction(identifier: Self.denyActionIdentifier, title: "Deny", options: [.destructive])
        let approvalCategory = UNNotificationCategory(
            identifier: Self.approvalCategoryIdentifier,
            actions: [allowAction, denyAction, openAction],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([sessionCategory, approvalCategory])
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

    /// "⟡ {name} needs you" — the question being asked, else the pending
    /// command, else the tool/waiting reason, else just the folder.
    func notifyWaiting(_ display: SessionDisplay) {
        guard UserDefaults.standard.bool(forKey: SettingsKeys.notifyWaiting) else { return }
        guard let center else { return }

        let body: String
        if let question = display.question, !question.isEmpty {
            body = "Asking: \(Self.preview(question))"
        } else if let tool = display.pendingToolName, let summary = display.activity?.summary ?? display.pendingApproval?.summary {
            body = "\(tool): \(Self.preview(summary)) · \(display.folderName)"
        } else if let hint = (display.pendingToolName ?? display.session.waitingFor)?
            .trimmingCharacters(in: .whitespaces), !hint.isEmpty {
            body = "\(hint) · \(display.folderName)"
        } else {
            body = display.folderName
        }

        deliver(
            center: center,
            identifier: Self.waitingIdentifier(for: display.id),
            title: "⟡ \(display.title) needs you",
            body: body,
            sessionId: display.id
        )
        announcedWaiting.insert(display.id)
    }

    /// "⟡ {name} wants to run {tool}" with Allow/Deny buttons — for a held
    /// permission request. Gated on the same toggle as waiting notifications:
    /// remote approval is pointless if you can't see the request.
    func notifyApproval(_ display: SessionDisplay?, approval: PendingApproval) {
        guard UserDefaults.standard.bool(forKey: SettingsKeys.notifyWaiting) else { return }
        guard let center else { return }

        let name = display?.title ?? "A Claude session"
        var body = approval.summary.map(Self.preview) ?? "Permission requested"
        if let folder = display?.folderName { body += " · \(folder)" }

        let content = UNMutableNotificationContent()
        content.title = "⟡ \(name) wants to run \(approval.toolName ?? "a tool")"
        content.body = body
        content.sound = .default
        content.categoryIdentifier = Self.approvalCategoryIdentifier
        content.interruptionLevel = .timeSensitive
        content.userInfo = [
            Self.sessionIdKey: approval.sessionId,
            Self.approvalIdKey: approval.id.uuidString,
        ]
        if authorization == .notDetermined {
            Task { await requestAuthorizationIfNeeded() }
        }
        let request = UNNotificationRequest(
            identifier: Self.approvalIdentifier(for: approval.id),
            content: content,
            trigger: nil
        )
        center.add(request) { error in
            if let error { log("failed to deliver approval: \(error)") }
        }
    }

    /// The held request was resolved (from the panel, a timeout, or the
    /// session vanishing) — retract the actionable notification.
    func clearApproval(_ approval: PendingApproval) {
        guard let center else { return }
        let identifier = Self.approvalIdentifier(for: approval.id)
        center.removeDeliveredNotifications(withIdentifiers: [identifier])
        center.removePendingNotificationRequests(withIdentifiers: [identifier])
    }

    /// "✓ {name} finished" — the turn's closing words when we have them,
    /// else folder + elapsed time.
    func notifyTurnFinished(_ display: SessionDisplay, message: String?) {
        guard UserDefaults.standard.bool(forKey: SettingsKeys.notifyTurnFinished) else { return }
        guard let center else { return }

        var body: String
        if let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            body = Self.preview(message)
        } else {
            body = display.folderName
            if let elapsed = display.elapsedLabel { body += " · \(elapsed)" }
        }

        deliver(
            center: center,
            identifier: "compagnion.turnFinished.\(display.id).\(UUID().uuidString)",
            title: "✓ \(display.title) finished",
            body: body,
            sessionId: display.id
        )
    }

    /// "✗ {name} hit an error" — the turn died on an API error (StopFailure).
    func notifyTurnFailed(_ display: SessionDisplay) {
        guard UserDefaults.standard.bool(forKey: SettingsKeys.notifyError) else { return }
        guard let center else { return }

        deliver(
            center: center,
            identifier: "compagnion.turnFailed.\(display.id).\(UUID().uuidString)",
            title: "✗ \(display.title) hit an API error",
            body: "\(display.folderName) · the turn did not finish",
            sessionId: display.id
        )
    }

    /// Notification bodies get one compact line, however long the source is.
    private nonisolated static func preview(_ text: String) -> String {
        let oneLine = text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return oneLine.count > 140 ? String(oneLine.prefix(140)) + "…" : oneLine
    }

    /// "{name}: sub-agent finished".
    func notifySubagentFinished(_ display: SessionDisplay) {
        guard UserDefaults.standard.bool(forKey: SettingsKeys.notifySubagentFinished) else { return }
        guard let center else { return }

        deliver(
            center: center,
            identifier: "compagnion.subagentFinished.\(display.id).\(UUID().uuidString)",
            title: "\(display.title): sub-agent finished",
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

    private static func approvalIdentifier(for id: UUID) -> String {
        approvalIdentifierPrefix + id.uuidString
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

    /// Allow/Deny actions resolve the held permission request; a tap on the
    /// body (or "Open") jumps to the session's hosting app.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let userInfo = response.notification.request.content.userInfo
        let sessionId = userInfo[Self.sessionIdKey] as? String
        let approvalId = (userInfo[Self.approvalIdKey] as? String).flatMap(UUID.init(uuidString:))
        let action = response.actionIdentifier
        completionHandler()

        Task { @MainActor in
            switch action {
            case Self.allowActionIdentifier:
                if let approvalId { self.onApprovalDecision?(approvalId, true) }
            case Self.denyActionIdentifier:
                if let approvalId { self.onApprovalDecision?(approvalId, false) }
            default:
                if let sessionId { self.onOpenSession?(sessionId) }
            }
        }
    }
}
