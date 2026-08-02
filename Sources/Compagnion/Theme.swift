import SwiftUI

/// Design-system tokens for the Compagnion menu-bar panel, matching the
/// Stitch design (`.stitch/designs/menu-bar-panel.html`). Namespaced so call
/// sites read `Theme.Colors.primary`, `Theme.Fonts.headline`, etc.
enum Theme {
    enum Colors {
        static let surface = Color(hex: "#FCF9F8")
        static let onSurface = Color(hex: "#1C1B1B")
        static let onSurfaceVariant = Color(hex: "#414755")
        static let outline = Color(hex: "#717786")
        static let outlineVariant = Color(hex: "#C1C6D7")
        static let surfaceContainer = Color(hex: "#F0EDED")
        static let secondaryContainer = Color(hex: "#DFDFE4")
        static let primary = Color(hex: "#0058BC")
        static let error = Color(hex: "#BA1A1A")
        static let errorContainer = Color(hex: "#FFDAD6")
        static let hairline = Color(hex: "#E5E5EA")

        // Waiting-for-you accent (orange family; no exact hex given in the
        // token table, so system orange is used as the base).
        static let waiting = Color.orange
        static let waitingText = Color(hex: "#EA580C")
        static let waitingBackground = Color.orange.opacity(0.08)
        static let waitingBorder = Color.orange.opacity(0.25)
    }

    enum Fonts {
        /// Session name / panel title — 15 pt semibold.
        static let headline = Font.system(size: 15, weight: .semibold)
        /// Default body copy — 13 pt regular.
        static let body = Font.system(size: 13, weight: .regular)
        /// Section labels — 12 pt medium.
        static let label = Font.system(size: 12, weight: .medium)
        /// Folder/branch, context percentage — 11 pt monospaced.
        static let mono = Font.system(size: 11, weight: .regular, design: .monospaced)
        /// Footer meta text ("Last refresh: ...") — 11 pt regular, non-mono.
        static let meta = Font.system(size: 11, weight: .regular)
        /// Status chips (WAITING/WORKING/IDLE) — 10 pt bold uppercase.
        static let badge = Font.system(size: 10, weight: .bold)
        /// Percentage inside a ring gauge — 9 pt monospaced.
        static let gaugeValue = Font.system(size: 9, weight: .regular, design: .monospaced)
        /// Caption under a ring gauge ("5h Rem.", "Week") — 9 pt medium.
        static let gaugeCaption = Font.system(size: 9, weight: .medium)
    }

    enum Metrics {
        static let panelWidth: CGFloat = 400
        /// Max height of the scrollable session list content (not the whole panel).
        static let maxListHeight: CGFloat = 600
        static let cardCornerRadius: CGFloat = 12
        static let cardPadding: CGFloat = 12
        static let contextBarWidth: CGFloat = 96
        static let contextBarHeight: CGFloat = 6
        static let gaugeSize: CGFloat = 32
        static let gaugeStroke: CGFloat = 2
        static let footerButtonSize: CGFloat = 28
    }

    /// Context-fill color ramp shared by `ContextBar` and `RingGauge`:
    /// primary below 70%, orange 70–90%, error at/above 90%.
    static func contextColor(for fraction: Double) -> Color {
        if fraction >= 0.90 {
            return Colors.error
        } else if fraction >= 0.70 {
            return Colors.waiting
        } else {
            return Colors.primary
        }
    }
}

extension View {
    /// Applies `.help` only when `text` is non-nil, so call sites can pass
    /// an optional tooltip through without branching at the call site.
    @ViewBuilder
    func help(ifPresent text: String?) -> some View {
        if let text {
            self.help(text)
        } else {
            self
        }
    }
}

extension Color {
    /// Creates a `Color` from a `#RRGGBB` or `#RRGGBBAA` hex string. Falls
    /// back to opaque black on malformed input (no force unwraps).
    init(hex: String) {
        var sanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if sanitized.hasPrefix("#") {
            sanitized.removeFirst()
        }

        var value: UInt64 = 0
        Scanner(string: sanitized).scanHexInt64(&value)

        let r, g, b, a: Double
        switch sanitized.count {
        case 8:
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
            a = Double(value & 0xFF) / 255
        case 6:
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1
        default:
            r = 0
            g = 0
            b = 0
            a = 1
        }

        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
