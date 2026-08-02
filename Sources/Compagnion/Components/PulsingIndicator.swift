import SwiftUI

/// Small pulsing icon shown next to a working session's name (2 s
/// repeating opacity/scale pulse, `primary` colored).
struct PulsingIndicator: View {
    var systemImage: String = "play.circle.fill"
    @State private var isPulsing = false

    var body: some View {
        Image(systemName: systemImage)
            .foregroundStyle(Theme.Colors.primary)
            .opacity(isPulsing ? 0.35 : 1.0)
            .scaleEffect(isPulsing ? 0.9 : 1.0)
            .onAppear {
                withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                    isPulsing = true
                }
            }
    }
}

#Preview {
    PulsingIndicator()
        .padding(20)
}
