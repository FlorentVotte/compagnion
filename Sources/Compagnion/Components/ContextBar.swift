import SwiftUI

/// Horizontal context-usage bar + "NN% Context" label shown on each session
/// card. When `fraction` is unknown, the track renders dimmed at zero fill
/// and the label is omitted rather than inventing a number.
struct ContextBar: View {
    let fraction: Double?
    var isStale: Bool = false

    private var clamped: Double {
        min(max(fraction ?? 0, 0), 1)
    }

    private var fillColor: Color {
        Theme.contextColor(for: fraction ?? 0)
    }

    private var label: String? {
        guard let fraction else { return nil }
        return "\(Int((fraction * 100).rounded()))% Context"
    }

    var body: some View {
        HStack(spacing: 6) {
            Capsule()
                .fill(Theme.Colors.surfaceContainer)
                .frame(width: Theme.Metrics.contextBarWidth, height: Theme.Metrics.contextBarHeight)
                .overlay(alignment: .leading) {
                    GeometryReader { proxy in
                        Capsule()
                            .fill(fillColor)
                            .frame(width: proxy.size.width * clamped)
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: fraction)

            if let label {
                Text(label)
                    .font(Theme.Fonts.mono)
                    .foregroundStyle(Theme.Colors.onSurfaceVariant)
            }

            if isStale {
                Circle()
                    .fill(Theme.Colors.outline)
                    .frame(width: 4, height: 4)
                    .help("Value may be out of date")
            }
        }
        .opacity(fraction == nil ? 0.4 : 1)
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 10) {
        ContextBar(fraction: 0.12)
        ContextBar(fraction: 0.82)
        ContextBar(fraction: 0.95, isStale: true)
        ContextBar(fraction: nil)
    }
    .padding(20)
}
