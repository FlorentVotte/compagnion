import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var monitor: SessionMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if monitor.sessions.isEmpty {
                emptyState
            } else {
                ScrollView {
                    VStack(spacing: 2) {
                        ForEach(monitor.sessions) { session in
                            SessionRow(session: session)
                        }
                    }
                    .padding(6)
                }
                .frame(maxHeight: 380)
            }
            Divider()
            footer
        }
        .frame(width: 340)
    }

    private var header: some View {
        HStack {
            Text("Claude Sessions")
                .font(.headline)
            Spacer()
            if monitor.waitingCount > 0 {
                Label("\(monitor.waitingCount)", systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                    .font(.callout.weight(.semibold))
                    .help("Sessions waiting for you")
            }
            if monitor.busyCount > 0 {
                Label("\(monitor.busyCount)", systemImage: "asterisk")
                    .foregroundStyle(.blue)
                    .font(.callout)
                    .help("Sessions working")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: "moon.zzz")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(monitor.lastError ?? "No active Claude Code session")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    private var footer: some View {
        HStack {
            if let error = monitor.lastError, !monitor.sessions.isEmpty {
                Image(systemName: "wifi.exclamationmark")
                    .foregroundStyle(.orange)
                    .help(error)
            } else if let updated = monitor.lastUpdated {
                Text("Updated \(updated, style: .time)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button {
                monitor.refresh()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("Refresh now")
            Button {
                NSApplication.shared.terminate(nil)
            } label: {
                Image(systemName: "power")
            }
            .buttonStyle(.borderless)
            .help("Quit Compagnion")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

struct SessionRow: View {
    let session: ClaudeSession
    @State private var isHovering = false
    @State private var justCopied = false

    private var statusColor: Color {
        if session.needsAttention { return .orange }
        if session.isBusy { return .blue }
        if session.isFinished { return .secondary.opacity(0.5) }
        return .green
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)
                .padding(.top, 5)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.displayName)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if session.kind == "background" {
                        Text("bg")
                            .font(.caption2)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                    Spacer()
                    if let elapsed = session.elapsedLabel {
                        Text(elapsed)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
                Text(session.statusLabel)
                    .font(.caption)
                    .foregroundStyle(session.needsAttention ? .orange : .secondary)
                    .lineLimit(1)
                Text(session.folderLabel)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
            }

            if isHovering {
                Button {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString(session.resumeCommand, forType: .string)
                    justCopied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { justCopied = false }
                } label: {
                    Image(systemName: justCopied ? "checkmark" : "doc.on.doc")
                        .font(.caption)
                }
                .buttonStyle(.borderless)
                .help("Copy command to open this session: \(session.resumeCommand)")
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isHovering ? Color.primary.opacity(0.06) : .clear)
        )
        .onHover { isHovering = $0 }
    }
}
