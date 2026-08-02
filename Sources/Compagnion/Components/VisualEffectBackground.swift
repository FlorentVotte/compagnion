import SwiftUI
import AppKit

/// Thin `NSViewRepresentable` wrapper around `NSVisualEffectView`, used to
/// give the panel its translucent "glass" background.
struct VisualEffectBackground: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var blendingMode: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blendingMode
        view.state = .active
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
    }
}

extension View {
    /// Applies the panel's tinted glass background in one call: the blurred
    /// `NSVisualEffectView` material with `Theme.Colors.surface` at ~75%
    /// opacity layered on top, matching the Stitch design's `.glass` class.
    func glassBackground(material: NSVisualEffectView.Material = .popover) -> some View {
        background(
            ZStack {
                VisualEffectBackground(material: material)
                Theme.Colors.surface.opacity(0.75)
            }
        )
    }
}

#Preview {
    Text("Compagnion")
        .padding(40)
        .glassBackground()
}
