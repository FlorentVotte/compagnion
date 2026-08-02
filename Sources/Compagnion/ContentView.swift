import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var monitor: SessionMonitor
    var onOpenSettings: () -> Void = {}

    @AppStorage(SettingsKeys.notifyWaiting) private var notifyWaiting = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            sessionList
            footer
        }
        .frame(width: Theme.Metrics.panelWidth)
        .glassBackground()
        // The design is a light panel; it must stay legible under a dark
        // menu bar, so the panel does not follow the system appearance.
        .environment(\.colorScheme, .light)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Compagnion")
                    .font(Theme.Fonts.headline)
                    .foregroundStyle(Theme.Colors.onSurface)
                HStack(spacing: 4) {
                    Image(systemName: "bell.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(notifyWaiting ? Theme.Colors.primary : Theme.Colors.outline)
                    Text(notifyWaiting ? "Alerts ON" : "Alerts OFF")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.Colors.onSurfaceVariant)
                }
            }
            Spacer()
            HStack(spacing: 12) {
                RingGauge(
                    progress: monitor.accountUsage?.fiveHourFraction,
                    caption: "5h Rem.",
                    tooltip: monitor.accountUsage?.fiveHourTooltip ?? AccountUsage.unavailableTooltip,
                    isStale: monitor.accountUsage?.isStale ?? false
                )
                RingGauge(
                    progress: monitor.accountUsage?.sevenDayFraction,
                    caption: "Week",
                    tooltip: monitor.accountUsage?.sevenDayTooltip ?? AccountUsage.unavailableTooltip,
                    isStale: monitor.accountUsage?.isStale ?? false
                )
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Session list

    @ViewBuilder
    private var sessionList: some View {
        if monitor.displays.isEmpty {
            emptyState
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(Array(monitor.displays.enumerated()), id: \.element.id) { index, display in
                        SessionCard(display: display, monitor: monitor)
                        if needsDividerAfter(index) {
                            Rectangle()
                                .fill(Theme.Colors.hairline)
                                .frame(height: 0.5)
                                .opacity(0.5)
                                .padding(.horizontal, 12)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: 420)
        }
    }

    /// Hairline between the "waiting for you" group and everything else.
    private func needsDividerAfter(_ index: Int) -> Bool {
        let displays = monitor.displays
        guard index < displays.count - 1 else { return false }
        return displays[index].badge == .waiting && displays[index + 1].badge != .waiting
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 20))
                .foregroundStyle(Theme.Colors.outline)
            Text(monitor.lastError ?? "No active Claude Code session")
                .font(Theme.Fonts.body)
                .foregroundStyle(Theme.Colors.onSurfaceVariant)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 32)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            Text(refreshLabel)
                .font(Theme.Fonts.meta)
                .foregroundStyle(Theme.Colors.onSurfaceVariant)
                .help(ifPresent: monitor.lastError)
            Spacer()
            HStack(spacing: 8) {
                FooterButton(systemImage: "arrow.clockwise", help: "Refresh now") {
                    monitor.refresh()
                }
                FooterButton(systemImage: "gearshape", help: "Settings") {
                    onOpenSettings()
                }
                FooterButton(systemImage: "power", help: "Quit Compagnion", isDestructive: true) {
                    NSApplication.shared.terminate(nil)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Theme.Colors.outlineVariant.opacity(0.3))
                .frame(height: 1)
        }
    }

    private var refreshLabel: String {
        if monitor.lastError != nil, monitor.displays.isEmpty == false {
            return "Refresh failed — showing last known state"
        }
        guard let updated = monitor.lastUpdated else { return "Never refreshed" }
        let minutes = Int(Date().timeIntervalSince(updated) / 60)
        return minutes < 1 ? "Last refresh: Just now" : "Last refresh: \(minutes)m ago"
    }
}

// MARK: - Session card

struct SessionCard: View {
    let display: SessionDisplay
    @ObservedObject var monitor: SessionMonitor

    @State private var isHovering = false

    private var session: ClaudeSession { display.session }
    private var isWaiting: Bool { display.badge == .waiting }
    private var isIdle: Bool { display.badge == .idle }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            topRow
            bottomRow
        }
        .padding(Theme.Metrics.cardPadding)
        .background(cardBackground)
        .contentShape(Rectangle())
        .scaleEffect(isHovering ? 1 : 1)
        .onHover { isHovering = $0 }
        .onTapGesture { monitor.activate(display) }
        .contextMenu { contextMenu }
        .help(display.tooltip)
    }

    private var topRow: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(session.displayName)
                        .font(Theme.Fonts.headline)
                        .foregroundStyle(Theme.Colors.onSurface)
                        .opacity(isIdle ? 0.6 : 1)
                        .lineLimit(1)
                    if display.badge == .working {
                        PulsingIndicator()
                    }
                }
                pathLine
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 4) {
                StatusBadge(badge: display.badge)
                if let elapsed = display.elapsedLabel {
                    Text(elapsed)
                        .font(Theme.Fonts.mono)
                        .foregroundStyle(Theme.Colors.onSurfaceVariant)
                        .fixedSize()
                }
            }
        }
    }

    private var pathLine: some View {
        HStack(spacing: 4) {
            Text(display.folderName)
            if let branch = display.gitBranch, !branch.isEmpty {
                Text("/").foregroundStyle(Theme.Colors.outlineVariant)
                Text(branch)
            }
        }
        .font(Theme.Fonts.mono)
        .foregroundStyle(Theme.Colors.onSurfaceVariant)
        .opacity(isIdle ? 0.6 : 1)
        .lineLimit(1)
        .truncationMode(.middle)
    }

    private var bottomRow: some View {
        HStack(spacing: 8) {
            ContextBar(fraction: display.contextFraction, isStale: display.contextIsStale, isMuted: isIdle)
            Spacer(minLength: 8)
            if isHovering {
                Image(systemName: "terminal")
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.Colors.primary)
                    .transition(.opacity)
                    .help(monitor.jumpHelp(for: display))
            }
            if display.subagentCount > 0 {
                SubAgentPill(count: display.subagentCount)
            }
        }
        .animation(.easeInOut(duration: 0.15), value: isHovering)
    }

    @ViewBuilder
    private var cardBackground: some View {
        let shape = RoundedRectangle(cornerRadius: Theme.Metrics.cardCornerRadius)
        if isWaiting {
            shape
                .fill(isHovering ? Color.orange.opacity(0.16) : Theme.Colors.waitingBackground)
                .overlay(shape.stroke(Theme.Colors.waitingBorder, lineWidth: 1))
        } else {
            shape.fill(isHovering ? Theme.Colors.secondaryContainer.opacity(0.5) : .clear)
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("Open in \(monitor.hostAppName(for: display) ?? "terminal")") {
            monitor.activate(display)
        }
        Button("Copy resume command") {
            copy(session.resumeCommand)
        }
        Button("Reveal folder in Finder") {
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: session.cwd)
        }
    }

    private func copy(_ string: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }
}

// MARK: - Footer button

struct FooterButton: View {
    let systemImage: String
    let help: String
    var isDestructive = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14))
                .foregroundStyle(foreground)
                .frame(width: Theme.Metrics.footerButtonSize, height: Theme.Metrics.footerButtonSize)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(background)
                )
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
    }

    private var foreground: Color {
        guard isHovering else { return Theme.Colors.onSurfaceVariant }
        return isDestructive ? Theme.Colors.error : Theme.Colors.primary
    }

    private var background: Color {
        guard isHovering else { return .clear }
        return isDestructive
            ? Theme.Colors.errorContainer.opacity(0.5)
            : Theme.Colors.secondaryContainer.opacity(0.5)
    }
}
