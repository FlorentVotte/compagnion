import SwiftUI
import AppKit

struct ContentView: View {
    @ObservedObject var monitor: SessionMonitor
    var onOpenSettings: () -> Void = {}

    @AppStorage(SettingsKeys.notifyWaiting) private var notifyWaiting = true

    /// Measured card heights keyed by session id — cards vary in height
    /// (question/approval rows), so the 2.5-card cap uses real sizes. Keyed
    /// by id, not row index: the list reorders and changes while the panel
    /// is closed, and index-keyed heights would go stale.
    @State private var cardHeights: [String: CGFloat] = [:]
    /// Full height of the list content (cards + padding), measured so the
    /// ScrollView can be given an exact height. A ScrollView's ideal height
    /// is zero — `.frame(maxHeight:)` alone collapses it in contexts that
    /// propose nothing, like a window sized to its content.
    @State private var listContentHeight: CGFloat?

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
                // A plain VStack on purpose: the 2.5-card cap needs every
                // card measured. A LazyVStack under a small cap never
                // materializes the rows below the fold, so their heights
                // could never be measured and the cap could never recover.
                VStack(spacing: 8) {
                    ForEach(Array(monitor.displays.enumerated()), id: \.element.id) { index, display in
                        SessionCard(display: display, monitor: monitor)
                            .onGeometryChange(for: CGFloat.self) { proxy in
                                proxy.size.height
                            } action: { height in
                                cardHeights[display.id] = height
                            }
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
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { height in
                    listContentHeight = height
                }
            }
            .scrollIndicators(.automatic)
            .frame(height: resolvedListHeight)
        }
    }

    /// Exact list height: the content when it fits, the 2.5-card cap when it
    /// doesn't. `nil` (no constraint) only before the first measurement.
    private var resolvedListHeight: CGFloat? {
        guard let listContentHeight else { return nil }
        return min(listContentHeight, listCapHeight)
    }

    /// Caps the list at 2.5 cards: two full cards plus half of the third,
    /// so a cut-off card signals there is more to scroll. With two or fewer
    /// sessions the list fits its content (the cap is never reached).
    private var listCapHeight: CGFloat {
        let displays = monitor.displays
        guard displays.count > 2 else { return Theme.Metrics.maxListHeight }
        let heights = displays.prefix(3).compactMap { cardHeights[$0.id] }
        guard heights.count == 3 else { return Theme.Metrics.maxListHeight }
        let topPadding: CGFloat = 12
        let rowSpacing: CGFloat = 8
        return topPadding + heights[0] + rowSpacing + heights[1] + rowSpacing + heights[2] / 2
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
            if let question = display.question, isWaiting {
                questionRow(question)
            }
            if let approval = display.pendingApproval {
                approvalRow(approval)
            }
            if let activity = display.activity, display.badge == .working {
                activityRow(activity)
            }
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

    /// The question the session is asking, verbatim.
    private func questionRow(_ question: String) -> some View {
        (Text("Asking: ").bold() + Text(question))
            .font(Theme.Fonts.body)
            .foregroundStyle(Theme.Colors.waitingText)
            .lineLimit(3)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// A held permission request: the command + Allow/Deny, right here.
    private func approvalRow(_ approval: PendingApproval) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let summary = approval.summary {
                Text(summary)
                    .font(Theme.Fonts.mono)
                    .foregroundStyle(Theme.Colors.onSurface)
                    .lineLimit(2)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Button("Allow") { monitor.resolveApproval(approval.id, decision: true) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .tint(Theme.Colors.primary)
                Button("Deny") { monitor.resolveApproval(approval.id, decision: false) }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .foregroundStyle(Theme.Colors.error)
                Spacer()
                TimelineView(.periodic(from: approval.receivedAt, by: 1)) { context in
                    let remaining = max(0, 60 - Int(context.date.timeIntervalSince(approval.receivedAt)))
                    Text("terminal prompt in \(remaining)s")
                        .font(Theme.Fonts.meta)
                        .foregroundStyle(Theme.Colors.onSurfaceVariant)
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Theme.Colors.waitingChip.opacity(0.5))
        )
    }

    /// What the session is doing right now, with a live seconds counter.
    private func activityRow(_ activity: ToolActivity) -> some View {
        TimelineView(.periodic(from: activity.startedAt, by: 1)) { context in
            HStack(spacing: 4) {
                Image(systemName: "gearshape.2")
                    .font(.system(size: 9))
                Text(activity.summary.map { "\(activity.toolName) — \($0)" } ?? activity.toolName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text("· \(max(0, Int(context.date.timeIntervalSince(activity.startedAt))))s")
                    .foregroundStyle(Theme.Colors.outline)
            }
            .font(Theme.Fonts.mono)
            .foregroundStyle(Theme.Colors.onSurfaceVariant)
        }
    }

    private var topRow: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(display.title)
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
            if let model = display.modelName {
                Text(model)
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(Theme.Colors.onSurfaceVariant)
                    .opacity(isIdle ? 0.6 : 1)
                    .lineLimit(1)
                    .fixedSize()
            }
            ContextBar(fraction: display.contextFraction, isStale: display.contextIsStale, isMuted: isIdle)
            if display.hadError {
                Label("API error", systemImage: "exclamationmark.octagon.fill")
                    .font(Theme.Fonts.meta)
                    .foregroundStyle(Theme.Colors.error)
                    .help("The last turn ended on an API error")
            }
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
