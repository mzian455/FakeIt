import SwiftUI

enum FakeItTheme {
    static let background = Color(red: 0.051, green: 0.051, blue: 0.051)
    static let card = Color(red: 0.102, green: 0.102, blue: 0.180)
    static let accent = Color(red: 0.0, green: 0.831, blue: 1.0)
    static let secondaryAccent = Color(red: 0.482, green: 0.184, blue: 0.745)
    static let textPrimary = Color.white
    static let textSecondary = Color(red: 0.627, green: 0.627, blue: 0.690)

    static func displayFont(_ size: CGFloat, weight: Font.Weight = .semibold) -> Font {
        .system(size: size, weight: weight, design: .default)
    }

    /// Orbitron-Bold (bundled variable font) — geometric / boxy sci‑fi display.
    static func brandTitleFont(_ size: CGFloat) -> Font {
        Font.custom("Orbitron-Bold", size: size)
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
