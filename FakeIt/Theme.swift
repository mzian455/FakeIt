import SwiftUI

enum FakeItTheme {
    static let background = Color(red: 0.051, green: 0.051, blue: 0.051)
    static let card = Color(red: 0.102, green: 0.102, blue: 0.180)
    /// Legacy neon accents (maps / small highlights only).
    static let accent = Color(red: 0.0, green: 0.831, blue: 1.0)
    static let secondaryAccent = Color(red: 0.482, green: 0.184, blue: 0.745)
    /// Primary actions — calm system-style blue (less “gaming UI”).
    static let actionBlue = Color(red: 0.23, green: 0.48, blue: 0.96)
    static let panelStroke = Color.white.opacity(0.09)
    static let panelSurface = Color(red: 0.11, green: 0.11, blue: 0.13)
    static let textPrimary = Color.white
    static let textSecondary = Color(red: 0.627, green: 0.627, blue: 0.690)

    static func displayFont(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    /// App wordmark — SF for a tool-style, professional look.
    static func brandTitleFont(_ size: CGFloat) -> Font {
        .system(size: size, weight: .semibold, design: .default)
    }

    static func bodyFont(_ size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    static let spoofGradient = LinearGradient(
        colors: [accent, secondaryAccent],
        startPoint: .leading,
        endPoint: .trailing
    )

    static let spring = Animation.spring(response: 0.3, dampingFraction: 0.7)
}
