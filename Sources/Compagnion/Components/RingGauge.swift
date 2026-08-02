import SwiftUI

/// Circular percentage gauge (header usage rings: "5h Rem.", "Week").
/// Renders "–" while `progress` is unknown; dims to ~50% opacity when the
/// underlying value is `isStale` (too old to trust at face value).
struct RingGauge: View {
    let progress: Double?
    let caption: String
    var tooltip: String? = nil
    var isStale: Bool = false

    private var strokeColor: Color {
        guard let progress else { return Theme.Colors.outline }
        return Theme.quotaColor(for: progress)
    }

    private var valueLabel: String {
        guard let progress else { return "–" }
        return "\(Int((progress * 100).rounded()))%"
    }

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                Circle()
                    .stroke(Theme.Colors.hairline, lineWidth: Theme.Metrics.gaugeStroke)
                Circle()
                    .trim(from: 0, to: progress ?? 0)
                    .stroke(
                        strokeColor,
                        style: StrokeStyle(lineWidth: Theme.Metrics.gaugeStroke, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    .animation(.easeInOut(duration: 0.4), value: progress)
                Text(valueLabel)
                    .font(Theme.Fonts.gaugeValue)
                    .foregroundStyle(Theme.Colors.onSurface)
            }
            .frame(width: Theme.Metrics.gaugeSize, height: Theme.Metrics.gaugeSize)

            Text(caption)
                .font(Theme.Fonts.gaugeCaption)
                .foregroundStyle(Theme.Colors.onSurfaceVariant)
        }
        .opacity(isStale ? 0.5 : 1)
        .help(ifPresent: tooltip)
    }
}

#Preview {
    HStack(spacing: 16) {
        RingGauge(progress: 0.35, caption: "5h Rem.")
        RingGauge(progress: 0.82, caption: "Week", tooltip: "resets Monday")
        RingGauge(progress: nil, caption: "5h Rem.")
        RingGauge(progress: 0.95, caption: "Week", isStale: true)
    }
    .padding(20)
}
