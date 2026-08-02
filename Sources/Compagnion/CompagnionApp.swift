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
        monitor.onTurnFinished = { [notifier] display in
            notifier.notifyTurnFinished(display)
        }
        monitor.onSubagentFinished = { [notifier] display in
            notifier.notifySubagentFinished(display)
        }
        notifier.onOpenSession = { [monitor] sessionId in
            monitor.activate(sessionId: sessionId)
        }
        self.monitor = monitor
        self.notifier = notifier
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
/// (orange, most urgent, leftmost), working (blue), idle (gray) — each with
/// its count. Zero-count segments are omitted entirely.
///
/// Rendered to a non-template `NSImage` via `ImageRenderer`: the menu bar
/// template-renders SwiftUI label content to monochrome, which would erase
/// the state colors that make the segments readable at a glance. The fixed
/// colors are mid-tone on purpose — legible against both the light and dark
/// menu bar, which a pre-rendered image can't adapt to.
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
        image.isTemplate = false
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

    private static let waitingColor = Color(red: 0.92, green: 0.45, blue: 0.09)
    private static let workingColor = Color(red: 0.25, green: 0.52, blue: 0.95)
    private static let idleColor = Color(red: 0.56, green: 0.56, blue: 0.58)

    var body: some View {
        HStack(spacing: 8) {
            if waiting > 0 {
                segment("exclamationmark.circle.fill", waiting, Self.waitingColor)
            }
            if working > 0 {
                segment("asterisk.circle.fill", working, Self.workingColor)
            }
            if idle > 0 {
                segment("moon.zzz", idle, Self.idleColor)
            }
            if quotaCritical {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Self.waitingColor)
            }
            if waiting == 0 && working == 0 && idle == 0 && !quotaCritical {
                Image(systemName: "asterisk.circle")
                    .font(.system(size: 13))
                    .foregroundStyle(Self.idleColor.opacity(0.8))
            }
        }
        .padding(.horizontal, 1)
        .fixedSize()
    }

    private func segment(_ systemName: String, _ count: Int, _ color: Color) -> some View {
        HStack(spacing: 2.5) {
            Image(systemName: systemName)
                .font(.system(size: 12.5, weight: .semibold))
            Text("\(count)")
                .font(.system(size: 11.5, weight: .semibold, design: .rounded))
        }
        .foregroundStyle(color)
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
