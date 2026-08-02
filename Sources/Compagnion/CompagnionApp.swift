import SwiftUI
import AppKit

/// Owns the app-lifetime model objects and wires them together in `init`,
/// which runs at launch (the MenuBarExtra *label* is built eagerly). The
/// wiring must NOT live in the panel content's `onAppear`: window-style
/// MenuBarExtra content is built lazily on first click, so notifications
/// would stay dead on a fresh launch — including launch-at-login — until the
/// user happened to open the panel once.
@MainActor
final class AppModel: ObservableObject {
    let monitor: SessionMonitor
    let notifier: Notifier

    init() {
        let monitor = SessionMonitor()
        let notifier = Notifier()
        monitor.onWaitingEpisodeStart = { [notifier] display in
            notifier.notifyWaiting(display)
        }
        monitor.onWaitingEpisodeEnd = { [notifier] sessionId in
            notifier.clearWaiting(sessionId: sessionId)
        }
        monitor.onTurnFinished = { [notifier] display, message in
            notifier.notifyTurnFinished(display, message: message)
        }
        monitor.onTurnFailed = { [notifier] display in
            notifier.notifyTurnFailed(display)
        }
        monitor.onSubagentFinished = { [notifier] display in
            notifier.notifySubagentFinished(display)
        }
        monitor.onApprovalRequested = { [notifier] display, approval in
            notifier.notifyApproval(display, approval: approval)
        }
        monitor.onApprovalResolved = { [notifier] approval in
            notifier.clearApproval(approval)
        }
        notifier.onOpenSession = { [monitor] sessionId in
            monitor.activate(sessionId: sessionId)
        }
        notifier.onApprovalDecision = { [monitor] approvalId, allow in
            monitor.resolveApproval(approvalId, decision: allow)
        }
        self.monitor = monitor
        self.notifier = notifier

        // Dev harness: COMPAGNION_PREVIEW=1 shows the panel in a regular
        // window so UI work can be screenshotted/iterated without clicking
        // the status item. Inert in normal launches.
        if ProcessInfo.processInfo.environment["COMPAGNION_PREVIEW"] != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [monitor] in
                let host = NSHostingController(rootView: ContentView(monitor: monitor))
                let window = NSWindow(contentViewController: host)
                window.title = "PanelPreview"
                window.setFrameOrigin(NSPoint(x: 100, y: 150))
                window.makeKeyAndOrderFront(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}

@main
struct CompagnionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            ContentView(monitor: model.monitor) {
                openSettings()
            }
        } label: {
            MenuBarLabel(monitor: model.monitor)
        }
        .menuBarExtraStyle(.window)

        Window("Compagnion Settings", id: Self.settingsWindowID) {
            SettingsView(monitor: model.monitor, notifier: model.notifier)
                .onAppear { model.notifier.refreshAuthorization() }
        }
        .windowResizability(.contentSize)
        .defaultPosition(.center)
    }

    static let settingsWindowID = "settings"

    private func openSettings() {
        // A menu-bar-only app has no Dock icon, so the settings window would
        // open behind everything without an explicit activation.
        NSApp.setActivationPolicy(.regular)
        openWindow(id: Self.settingsWindowID)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Status-bar label: one compact segment per session state — waiting
/// (most urgent, leftmost), working, idle — each with its count.
/// Zero-count segments are omitted entirely.
///
/// Rendered to a *template* `NSImage` via `ImageRenderer`: the menu bar
/// tints template images itself (white on a dark bar, near-black on a light
/// one), which fixed colors can't match for legibility. States are told
/// apart by their icons and ordering, not by color.
struct MenuBarLabel: View {
    @ObservedObject var monitor: SessionMonitor

    var body: some View {
        Image(nsImage: renderedImage)
    }

    private var renderedImage: NSImage {
        let renderer = ImageRenderer(content: MenuBarSegments(
            waiting: monitor.waitingCount,
            working: monitor.busyCount,
            idle: monitor.idleCount,
            quotaCritical: quotaIsCritical
        ))
        renderer.scale = NSScreen.main?.backingScaleFactor ?? 2
        guard let image = renderer.nsImage else { return NSImage() }
        image.isTemplate = true
        return image
    }

    private var quotaIsCritical: Bool {
        guard let usage = monitor.accountUsage, !usage.isStale else { return false }
        return [usage.fiveHourFraction, usage.sevenDayFraction]
            .compactMap { $0 }
            .contains { $0 >= 0.90 }
    }
}

private struct MenuBarSegments: View {
    let waiting: Int
    let working: Int
    let idle: Int
    let quotaCritical: Bool

    var body: some View {
        // Solid black at varying opacity: template rendering keeps only the
        // alpha channel, so opacity is the one dimension that survives —
        // idle sessions recede, the rest stay at full strength.
        HStack(spacing: 8) {
            if waiting > 0 {
                segment("exclamationmark.circle.fill", waiting, opacity: 1)
            }
            if working > 0 {
                segment("asterisk.circle.fill", working, opacity: 1)
            }
            if idle > 0 {
                segment("moon.zzz", idle, opacity: 0.55)
            }
            if quotaCritical {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.black)
            }
            if waiting == 0 && working == 0 && idle == 0 && !quotaCritical {
                Image(systemName: "asterisk.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(.black.opacity(0.45))
            }
        }
        .padding(.horizontal, 1)
        .fixedSize()
    }

    private func segment(_ systemName: String, _ count: Int, opacity: Double) -> some View {
        HStack(spacing: 2.5) {
            Image(systemName: systemName)
                .font(.system(size: 12.5, weight: .semibold))
            Text("\(count)")
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(.black.opacity(opacity))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only app: no Dock icon, no app switcher entry.
        NSApp.setActivationPolicy(.accessory)
    }

    /// Closing the settings window drops us back to menu-bar-only.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { NSApp.setActivationPolicy(.accessory) }
        return false
    }
}
