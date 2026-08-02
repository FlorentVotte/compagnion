import SwiftUI

/// Session status shown by `StatusBadge`, mirroring the Stitch design's
/// three card states.
enum SessionBadge {
    case waiting
    case working
    case idle
}

/// Small uppercase status chip shown top-right of each session card.
/// `.waiting` renders as a filled chip; `.working`/`.idle` are plain text.
struct StatusBadge: View {
    let badge: SessionBadge

    private var text: String {
        switch badge {
        case .waiting: return "WAITING FOR YOU"
        case .working: return "WORKING"
        case .idle: return "IDLE"
        }
    }

    private var color: Color {
        switch badge {
        case .waiting: return Theme.Colors.waitingText
        case .working: return Theme.Colors.primary
        case .idle: return Theme.Colors.outline
        }
    }

    var body: some View {
        Text(text)
            .font(Theme.Fonts.badge)
            .foregroundStyle(color)
            .padding(.horizontal, badge == .waiting ? 6 : 0)
            .padding(.vertical, badge == .waiting ? 2 : 0)
            .background {
                if badge == .waiting {
                    Capsule().fill(Color.orange.opacity(0.15))
                }
            }
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 10) {
        StatusBadge(badge: .waiting)
        StatusBadge(badge: .working)
        StatusBadge(badge: .idle)
    }
    .padding(20)
}
