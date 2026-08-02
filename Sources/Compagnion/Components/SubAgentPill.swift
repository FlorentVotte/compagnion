import SwiftUI

/// Pill showing the number of active sub-agents spawned by a session.
/// Hidden entirely by callers when `count == 0`.
struct SubAgentPill: View {
    let count: Int

    private var label: String {
        count == 1 ? "1 sub-agent" : "\(count) sub-agents"
    }

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 9))
            Text(label)
                .font(.system(size: 10, weight: .medium))
        }
        .foregroundStyle(Theme.Colors.primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Theme.Colors.primary.opacity(0.1), in: Capsule())
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 10) {
        SubAgentPill(count: 1)
        SubAgentPill(count: 3)
    }
    .padding(20)
}
