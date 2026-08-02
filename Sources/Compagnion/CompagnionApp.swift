import SwiftUI
import AppKit

@main
struct CompagnionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var monitor = SessionMonitor()
    @StateObject private var notifier = Notifier()

    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra {
            ContentView(monitor: monitor) {
                openSettings()
            }
            .onAppear { connectNotifier() }
        } label: {
            MenuBarLabel(monitor: monitor)
        }
        .menuBarExtraStyle(.window)

        Window("Compagnion Settings", id: Self.settingsWindowID) {
            SettingsView(monitor: monitor, notifier: notifier)
                .onAppear { notifier.refreshAuthorization() }
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

    private func connectNotifier() {
        guard monitor.onWaitingEpisodeStart == nil else { return }
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
    }
}

/// Status-bar icon: reflects the most urgent state across all sessions.
struct MenuBarLabel: View {
    @ObservedObject var monitor: SessionMonitor

    var body: some View {
        if monitor.waitingCount > 0 {
            Image(systemName: "exclamationmark.circle.fill")
            Text("\(monitor.waitingCount)")
        } else if quotaIsCritical {
            // Only surfaced when nothing is waiting — attention takes priority.
            Image(systemName: "exclamationmark.triangle.fill")
        } else if monitor.busyCount > 0 {
            Image(systemName: "asterisk.circle.fill")
        } else if monitor.displays.isEmpty {
            Image(systemName: "asterisk.circle")
                .opacity(0.5)
        } else {
            Image(systemName: "asterisk.circle")
        }
    }

    private var quotaIsCritical: Bool {
        guard let usage = monitor.accountUsage, !usage.isStale else { return false }
        return [usage.fiveHourFraction, usage.sevenDayFraction]
            .compactMap { $0 }
            .contains { $0 >= 0.90 }
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
