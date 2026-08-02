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
        } else if monitor.busyCount > 0 {
            Image(systemName: "asterisk.circle.fill")
        } else if monitor.sessions.isEmpty {
            Image(systemName: "asterisk.circle")
                .opacity(0.5)
        } else {
            Image(systemName: "asterisk.circle")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar-only app: no Dock icon, no app switcher entry.
        NSApp.setActivationPolicy(.accessory)
    }
}
