import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @ObservedObject var monitor: SessionMonitor
    @ObservedObject var notifier: Notifier

    @AppStorage(SettingsKeys.notifyWaiting) private var notifyWaiting = true
    @AppStorage(SettingsKeys.notifyTurnFinished) private var notifyTurnFinished = false
    @AppStorage(SettingsKeys.notifySubagentFinished) private var notifySubagentFinished = false
    @AppStorage(SettingsKeys.notifyError) private var notifyError = true
    @AppStorage(SettingsKeys.remoteApproval) private var remoteApproval = false

    @State private var report: IntegrationReport?
    @State private var busy = false
    @State private var message: Message?
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    private struct Message: Identifiable {
        let id = UUID()
        let text: String
        let isError: Bool
    }

    var body: some View {
        Form {
            integrationSection
            notificationsSection
            approvalSection
            generalSection
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 560)
        .task { refreshReport() }
    }

    // MARK: - Remote approval

    private var approvalSection: some View {
        Section {
            Toggle("Allow and deny permission requests from Compagnion", isOn: $remoteApproval)
                .onChange(of: remoteApproval) { _, enabled in requestAuthorization(if: enabled) }
        } header: {
            Text("Remote approval")
        } footer: {
            Text("Off by default. When enabled, a permission request in a session whose terminal is NOT the frontmost app is held for up to 60 seconds so you can Allow or Deny it from the notification or the panel; otherwise (or on timeout) the normal terminal prompt appears. Every remote decision is recorded in ~/Library/Application Support/Compagnion/approvals.jsonl.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Integration

    private var integrationSection: some View {
        Section {
            LabeledContent("Status") {
                HStack(spacing: 6) {
                    Image(systemName: statusIcon)
                        .foregroundStyle(statusColor)
                    Text(statusText)
                }
            }

            LabeledContent("Listener") {
                Text(monitor.listener.isListening
                     ? "Listening on 127.0.0.1:\(String(monitor.listener.port))"
                     : monitor.listener.lastError ?? "Not listening")
                .foregroundStyle(monitor.listener.isListening ? Color.secondary : Color.red)
            }

            if report?.hooksDisabledBySettings == true {
                Label(
                    "Hooks are disabled in your Claude Code settings (disableAllHooks / allowManagedHooksOnly). Compagnion's hooks will not fire until that is changed.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
                .font(.callout)
            }

            HStack {
                Button("Set up integration") { install() }
                    .disabled(busy || report?.state == .installed)
                Button("Remove") { uninstall() }
                    .disabled(busy || report?.state == .notInstalled)
                if busy { ProgressView().controlSize(.small) }
                Spacer()
                Button("Re-check") { refreshReport() }
                    .disabled(busy)
            }

            if let message {
                Text(message.text)
                    .font(.callout)
                    .foregroundStyle(message.isError ? .red : .secondary)
                    .textSelection(.enabled)
            }
        } header: {
            Text("Claude Code integration")
        } footer: {
            Text("Adds HTTP hooks and a status line forwarder to ~/.claude/settings.json, both pointing at Compagnion's local listener. A timestamped backup is written before every change, and removal restores the previous state exactly.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var statusIcon: String {
        switch report?.state {
        case .installed: return "checkmark.circle.fill"
        case .partial: return "exclamationmark.circle.fill"
        case .notInstalled, .none: return "circle.dashed"
        }
    }

    private var statusColor: Color {
        switch report?.state {
        case .installed: return .green
        case .partial: return .orange
        case .notInstalled, .none: return .secondary
        }
    }

    private var statusText: String {
        switch report?.state {
        case .installed:
            return report?.statuslineForwarded == true
                ? "Installed"
                : "Hooks installed, status line not forwarded"
        case .partial(let missing):
            return "Partially installed — missing \(missing.joined(separator: ", "))"
        case .notInstalled:
            return "Not installed"
        case .none:
            return "Checking…"
        }
    }

    // MARK: - Notifications

    private var notificationsSection: some View {
        Section("Notifications") {
            if case .unavailable(let reason) = notifier.authorization {
                Label(reason, systemImage: "info.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if notifier.authorization == .denied {
                Label(
                    "Notifications are turned off for Compagnion in System Settings → Notifications.",
                    systemImage: "bell.slash"
                )
                .font(.callout)
                .foregroundStyle(.orange)
            }

            Toggle("A session is waiting for you", isOn: $notifyWaiting)
            Toggle("A session finished its turn", isOn: $notifyTurnFinished)
            Toggle("A session hit an API error", isOn: $notifyError)
            Toggle("A sub-agent finished", isOn: $notifySubagentFinished)
        }
        .onChange(of: notifyWaiting) { _, enabled in requestAuthorization(if: enabled) }
        .onChange(of: notifyTurnFinished) { _, enabled in requestAuthorization(if: enabled) }
        .onChange(of: notifyError) { _, enabled in requestAuthorization(if: enabled) }
        .onChange(of: notifySubagentFinished) { _, enabled in requestAuthorization(if: enabled) }
    }

    private func requestAuthorization(if enabled: Bool) {
        guard enabled else { return }
        Task { await notifier.requestAuthorizationIfNeeded() }
    }

    // MARK: - General

    private var generalSection: some View {
        Section("General") {
            Toggle("Launch Compagnion at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in setLaunchAtLogin(enabled) }
        }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Registration only works from a signed bundle in /Applications or
            // ~/Applications; report rather than silently flipping back.
            launchAtLogin = SMAppService.mainApp.status == .enabled
            message = Message(text: "Could not change login item: \(error.localizedDescription)", isError: true)
        }
    }

    // MARK: - Actions

    private func refreshReport() {
        report = IntegrationInstaller.inspect(port: monitor.listener.port)
    }

    private func install() {
        busy = true
        message = nil
        do {
            let backup = try IntegrationInstaller.install(port: monitor.listener.port)
            message = Message(text: "Installed. Backup saved to \(backup.lastPathComponent).", isError: false)
        } catch {
            message = Message(text: error.localizedDescription, isError: true)
        }
        busy = false
        refreshReport()
    }

    private func uninstall() {
        busy = true
        message = nil
        do {
            try IntegrationInstaller.uninstall(port: monitor.listener.port)
            message = Message(text: "Removed. Your previous settings were restored.", isError: false)
        } catch {
            message = Message(text: error.localizedDescription, isError: true)
        }
        busy = false
        refreshReport()
    }
}
