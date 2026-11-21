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

    /// A colour that follows the system appearance: `light` when iOS is in
    /// light mode, `dark` when it is in dark mode, switching live. This is the
    /// one mechanism for appearance-dependent colour in Volta: tokens below
    /// use it, and feature code that needs a colour no token covers builds it
    /// the same way (never by branching on `colorScheme` by hand).
    init(light: Color, dark: Color) {
        let light = UIColor(light), dark = UIColor(dark)
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }

    /// `init(light:dark:)` from two 0xRRGGBB literals.
    init(light: UInt32, dark: UInt32) {
        self.init(light: Color(hex: light), dark: Color(hex: dark))
    }

    // Values for both modes are listed, with their contrast, in
    // docs/APPEARANCE.md. VoltaTests/AppearanceTests pins each one.

    // MARK: Surfaces

    /// App background: flat dark charcoal in dark mode (sampled from the
    /// Wattly references), the iOS grouped background in light mode.
    static let voltaBackground = Color(light: 0xF2F2F7, dark: 0x171717)
    /// Card surface: one step lighter than the background in dark mode,
    /// white on the grey page in light mode.
    static let voltaCard = Color(light: 0xFFFFFF, dark: 0x202020)
    /// Raised control surface (pill buttons, steppers, selected segment) on
    /// top of a card or background.
    static let voltaRaised = Color(light: 0xE5E5EA, dark: 0x2C2C2C)
    /// 1px hairline borders and dividers.
    static let voltaHairline = Color(light: .black.opacity(0.08), dark: .white.opacity(0.08))
    /// Fill of a button with no outline (capsules, round plates). Translucent,
    /// so it reads one step up from whatever card or background is behind it.
    static let voltaControlFill = Color(light: Color(hex: 0x767680).opacity(0.12), dark: .white.opacity(0.10))
    /// Empty track under a gauge, progress bar or range bar.
    static let voltaTrack = Color(light: Color(hex: 0x787880).opacity(0.20), dark: .white.opacity(0.10))
    /// The ink colour for washes, grid lines and rules at an opacity
    /// (`Color.voltaInk.opacity(0.06)`): white on dark, near-black on light.
    /// Text uses the text tokens instead.
    static let voltaInk = Color(light: 0x111111, dark: 0xFFFFFF)
    /// The opposite of `voltaInk`: a glyph on a plate filled with
    /// `voltaTextPrimary` (an "on" dock tile), a dot on an ink-coloured mark.
    static let voltaInkInverse = Color(light: 0xFFFFFF, dark: 0x000000)
    /// Wash over map tiles so labels recede: black on the dark map, white on
    /// the light map. Used at an opacity (see `voltaMapDim`).
    static let voltaMapWash = Color(light: 0xFFFFFF, dark: 0x000000)
    /// Where a map would be, before it loads or when there is none: a
    /// gradient from this into the page background.
    static let voltaMapBackdrop = Color(light: 0xE4E6EA, dark: 0x1B1E23)
    /// Soft shadow that lifts a white card off the grey page in light mode.
    /// Clear in dark mode, where cards are separated by their fill.
    static let voltaCardShadow = Color(light: .black.opacity(0.06), dark: .clear)
    /// Lifts a white slider thumb off a white surface in light mode; none in dark.
    static let voltaThumbShadow = Color(light: .black.opacity(0.3), dark: .clear)
    /// Shadow under a floating element (a pin, a knob, a callout). Black in
    /// both modes by design: a shadow is the absence of light. Softer in light
    /// mode, where a strong black shadow looks dirty on a pale surface.
    static let voltaShadow = Color(light: .black.opacity(0.55), dark: .black)

    // MARK: Text

    static let voltaTextPrimary = Color(light: 0x111111, dark: 0xFFFFFF)
    /// Dark: 6.1:1 on a card, 5.2:1 on a raised control. Light: 6.5:1 on a
    /// card, 5.8:1 on the background.
    static let voltaTextSecondary = Color(light: 0x5E5E63, dark: 0x9E9E9E)
    /// Quietest gray that still reads as text. Dark: 4.6:1 on a card. Light:
    /// 5.2:1 on a card, 4.7:1 on the background.
    static let voltaTextTertiary = Color(light: 0x6C6C70, dark: 0x888888)
    /// A glyph on a state-coloured fill (a map pin's tint). The dark-mode
    /// state colours are bright, so dark ink; the light-mode ones are deep, so white.
    static let voltaOnState = Color(light: .white, dark: .black.opacity(0.75))
    /// Text and symbols on a saturated fill (a blue button, a charger badge,
    /// a coloured pin). White in both modes by design.
    static let voltaOnAccent = Color.white

    // MARK: Accent and state

    /// Selection, range, links. Light 5.2:1 on a card.
    static let voltaBlue = Color(light: 0x2563EB, dark: 0x3B82F6)
    /// Fill behind white button labels: 5.2:1 in dark mode (where `voltaBlue`
    /// gives 3.7:1), 6.7:1 in light mode.
    static let voltaBlueFill = Color(light: 0x1D4ED8, dark: 0x2563EB)
    /// Small blue text on a blue wash (a tinted pill or a bordered button).
    /// Light 5.2:1 on a 12–18% `voltaBlue` wash; dark is `voltaBlue` unchanged.
    static let voltaBlueText = Color(light: 0x1D4ED8, dark: 0x3B82F6)
    /// Online, on, charging. Light 5.4:1 on a card.
    static let voltaGreen = Color(light: 0x157A3E, dark: 0x5ECB93)
    /// Warm, warnings. Light 5.6:1 on a card.
    static let voltaAmber = Color(light: 0xA84E0A, dark: 0xF59E0B)
    /// Alerts, errors, Sentry. Light 5.7:1 on a card.
    static let voltaRed = Color(light: 0xC42B1C, dark: 0xEF4444)
    /// Regen and secondary series. Light 5.7:1 on a card.
    static let voltaPurple = Color(light: 0x7C3AED, dark: 0xA78BFA)
    /// Climate running, the Dashboard's cool accent. Light 5.5:1 on a card.
    static let voltaTeal = Color(light: 0x0F766E, dark: 0x14B8A6)
}

/// Fills that run along a bar, dark end first.
enum VoltaGradient {
    /// Battery while charging (Dashboard range bar, live charging).
    static let charge: [Color] = [Color(light: 0x0E5C2E, dark: 0x15803D), .voltaGreen, Color(light: 0x34B866, dark: 0xA7F3D0)]
    /// Battery at rest (Dashboard range bar).
    static let range: [Color] = [Color(light: 0x1E40AF, dark: 0x2563EB), .voltaBlue, Color(light: 0x4F8EF7, dark: 0x60A5FA)]
}

extension ShapeStyle where Self == Color {
    static var voltaBackground: Color { .voltaBackground }
    static var voltaCard: Color { .voltaCard }
    static var voltaRaised: Color { .voltaRaised }
    static var voltaHairline: Color { .voltaHairline }
    static var voltaControlFill: Color { .voltaControlFill }
    static var voltaTrack: Color { .voltaTrack }
    static var voltaInk: Color { .voltaInk }
    static var voltaInkInverse: Color { .voltaInkInverse }
    static var voltaMapWash: Color { .voltaMapWash }
    static var voltaMapBackdrop: Color { .voltaMapBackdrop }
    static var voltaTextPrimary: Color { .voltaTextPrimary }
    static var voltaTextSecondary: Color { .voltaTextSecondary }
    static var voltaTextTertiary: Color { .voltaTextTertiary }
    static var voltaOnAccent: Color { .voltaOnAccent }
    static var voltaOnState: Color { .voltaOnState }
    static var voltaBlue: Color { .voltaBlue }
    static var voltaBlueFill: Color { .voltaBlueFill }
    static var voltaBlueText: Color { .voltaBlueText }
    static var voltaGreen: Color { .voltaGreen }
    static var voltaAmber: Color { .voltaAmber }
    static var voltaRed: Color { .voltaRed }
    static var voltaPurple: Color { .voltaPurple }
    static var voltaTeal: Color { .voltaTeal }
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
    /// Breathing room below the last item of a scrolling screen. The system
    /// tab bar already insets scroll content through the safe area.
    static let tabBarClearance: CGFloat = 24
}

enum VoltaRadius {
    /// Metric cards and grouped surfaces.
    static let card: CGFloat = 20
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
    /// Section and field labels in sentence case ("Last 48 hours"). Use
    /// through `voltaLabelStyle()` or `SectionLabel`.
    static let voltaLabel = Font.system(.footnote, weight: .semibold)
    /// Card titles like "Temperatures" (slightly larger than section labels).
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
    /// Sentence case, as written: Volta no longer shouts its labels in
    /// tracked capitals (see DesignSystem/README.md "Design rules").
    func voltaLabelStyle(color: Color = .voltaTextSecondary) -> some View {
        self.font(.voltaLabel)
            .foregroundStyle(color)
    }

    /// Fills the background with the app background, ignoring safe areas.
    func voltaScreenBackground() -> some View {
        background(Color.voltaBackground.ignoresSafeArea())
    }
}
