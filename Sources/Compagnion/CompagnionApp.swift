import SwiftUI
import AppKit

@main
struct CompagnionApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var monitor = SessionMonitor()

    var body: some Scene {
        MenuBarExtra {
            ContentView(monitor: monitor)
        } label: {
            MenuBarLabel(monitor: monitor)
        }
        .menuBarExtraStyle(.window)
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
}
