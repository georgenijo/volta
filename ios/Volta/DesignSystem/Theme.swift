import SwiftUI

// Volta design tokens. See DesignSystem/README.md for usage.
// Values follow docs/SPEC.md "Visual language".

// MARK: - Color

extension Color {
    /// Builds a color from a 0xRRGGBB literal.
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }

    /// App background, near-black charcoal.
    static let voltaBackground = Color(hex: 0x0E0F11)
    /// Card surface (bottom of the lit gradient), one step lighter than the background.
    static let voltaCard = Color(hex: 0x141518)
    /// Top of the card's lit gradient.
    static let voltaCardTop = Color(hex: 0x1A1C20)
    /// Soft mint for route starts, high scores and positive accents.
    static let voltaMint = Color(hex: 0x34D399)
    /// Raised control surface (pill buttons, steppers) on top of a card or background.
    static let voltaRaised = Color(hex: 0x23262B)
    /// 1px hairline borders and dividers.
    static let voltaHairline = Color.white.opacity(0.08)

    static let voltaTextPrimary = Color.white
    static let voltaTextSecondary = Color(hex: 0x8A8F98)
    static let voltaTextTertiary = Color(hex: 0x5C6068)

    static let voltaBlue = Color(hex: 0x3B82F6)
    static let voltaGreen = Color(hex: 0x22C55E)
    static let voltaAmber = Color(hex: 0xF59E0B)
    static let voltaRed = Color(hex: 0xEF4444)
}

extension ShapeStyle where Self == Color {
    static var voltaBackground: Color { .voltaBackground }
    static var voltaCard: Color { .voltaCard }
    static var voltaRaised: Color { .voltaRaised }
    static var voltaHairline: Color { .voltaHairline }
    static var voltaTextPrimary: Color { .voltaTextPrimary }
    static var voltaTextSecondary: Color { .voltaTextSecondary }
    static var voltaTextTertiary: Color { .voltaTextTertiary }
    static var voltaBlue: Color { .voltaBlue }
    static var voltaGreen: Color { .voltaGreen }
    static var voltaAmber: Color { .voltaAmber }
    static var voltaRed: Color { .voltaRed }
}

// MARK: - Spacing and radius

enum VoltaSpacing {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
    /// Horizontal inset for screen content.
    static let screen: CGFloat = 20
    /// Bottom inset that keeps scroll content clear of the floating tab bar.
    static let tabBarClearance: CGFloat = 110
}

enum VoltaRadius {
    /// Metric cards and grouped surfaces.
    static let card: CGFloat = 24
    /// Pill buttons and steppers.
    static let control: CGFloat = 12
    /// Wide action buttons (charge port Open/Close).
    static let wideButton: CGFloat = 14
}

// MARK: - Typography

extension Font {
    /// Heavy, tight numerals (BigNumber). Size is in points; wrap in
    /// `@ScaledMetric` at the call site to follow Dynamic Type.
    static func voltaNumeral(_ size: CGFloat) -> Font {
        .system(size: size, weight: .heavy, design: .default)
    }
    /// Small-caps section label (11pt semibold). Pair with `.tracking(1.5)`,
    /// or just use `SectionLabel`.
    static let voltaLabel = Font.system(.caption2, weight: .semibold)
    /// Card titles like "PACK TEMP" (slightly larger than section labels).
    static let voltaCardTitle = Font.system(.caption, weight: .semibold)
    /// Row titles in lists.
    static let voltaRowTitle = Font.system(.callout, weight: .medium)
    /// Row subtitles in lists.
    static let voltaRowSubtitle = Font.system(.subheadline)
    /// Centered screen titles in headers ("Charging", "CONTROLS").
    static let voltaScreenTitle = Font.system(.headline, weight: .semibold)
    /// Unit suffixes next to numerals.
    static let voltaUnit = Font.system(.subheadline, weight: .regular)
}

extension View {
    /// Applies the small-caps label treatment: uppercase, 11pt semibold, +1.5 tracking, gray.
    func voltaLabelStyle(color: Color = .voltaTextSecondary) -> some View {
        self.font(.voltaLabel)
            .tracking(1.5)
            .textCase(.uppercase)
            .foregroundStyle(color)
    }

    /// Fills the background with the app background, ignoring safe areas.
    func voltaScreenBackground() -> some View {
        background(Color.voltaBackground.ignoresSafeArea())
    }
}
