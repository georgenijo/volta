import SwiftUI
import WidgetKit

/// Widget-local copy of the Volta palette (docs/SPEC.md "Visual language",
/// docs/APPEARANCE.md). The extension does not link the app's DesignSystem, so
/// the few tokens it needs live here, built the same way: each follows the
/// system appearance (light Home Screen widgets and Lock Screen Live
/// Activities in light mode, dark ones in dark mode). The Dynamic Island is
/// always dark, and the system gives it the dark values.
enum WTheme {
    static let background = Color(light: 0xFFFFFF, dark: 0x0E0F11)
    static let card = Color(light: 0xF2F2F7, dark: 0x17191C)
    static let hairline = Color(light: .black.opacity(0.08), dark: .white.opacity(0.08))
    /// Primary text and numerals.
    static let text = Color(light: 0x111111, dark: 0xFFFFFF)
    /// The ink colour for washes and marks at an opacity.
    static let ink = text
    /// Light: 5.2:1 on white, 4.7:1 on a card.
    static let label = Color(light: 0x6C6C70, dark: 0x8A8F98)
    /// The quieter label (timestamps): full `label` in light, where 80% would fall
    /// to 3.5:1 on white; dark keeps main's 80%.
    static let labelDim = Color(light: Color(hex: 0x6C6C70), dark: Color(hex: 0x8A8F98).opacity(0.8))
    static let track = Color(light: Color(hex: 0x787880).opacity(0.20), dark: .white.opacity(0.12))
    static let blue = Color(light: 0x2563EB, dark: 0x3B82F6)
    static let green = Color(light: 0x15803D, dark: 0x22C55E)
    static let amber = Color(light: 0xA84E0A, dark: 0xF59E0B)
    static let red = Color(light: 0xC42B1C, dark: 0xEF4444)

    /// `background` and `text` resolved for one scheme. The Lock Screen tint is
    /// resolved apart from the content's traits, so a dynamic colour there can
    /// disagree with the content; `WActivityChrome` picks these by the content's scheme.
    static func background(_ scheme: ColorScheme) -> Color { scheme == .dark ? Color(hex: 0x0E0F11) : Color(hex: 0xFFFFFF) }
    static func text(_ scheme: ColorScheme) -> Color { scheme == .dark ? Color(hex: 0xFFFFFF) : Color(hex: 0x111111) }

    static let backgroundGradient = LinearGradient(
        colors: [Color(light: 0xFFFFFF, dark: 0x1A1C20), Color(light: 0xF4F4F7, dark: 0x0E0F11)],
        startPoint: .top, endPoint: .bottom)

    static func batteryColor(_ level: Int, charging: Bool) -> Color {
        if charging { return green }
        if level <= 10 { return red }
        if level <= 20 { return amber }
        return blue
    }

    static func color(for kind: WidgetSnapshot.SegmentKind) -> Color {
        switch kind {
        case .drive: red
        case .charge: green
        case .idle: blue.opacity(0.55)
        case .asleep: ink.opacity(0.10)
        case .offline: ink.opacity(0.04)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
    }

    /// `light` in light mode, `dark` in dark mode (the app's `Color(light:dark:)`).
    init(light: Color, dark: Color) {
        let light = UIColor(light), dark = UIColor(dark)
        self.init(uiColor: UIColor { $0.userInterfaceStyle == .dark ? dark : light })
    }

    init(light: UInt32, dark: UInt32) {
        self.init(light: Color(hex: light), dark: Color(hex: dark))
    }
}

/// A Live Activity's Lock Screen tint and system action colour, in the same
/// scheme as its content.
struct WActivityChrome: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content
            .activityBackgroundTint(WTheme.background(scheme).opacity(0.92))
            .activitySystemActionForegroundColor(WTheme.text(scheme))
    }
}

/// A tile's card fill. In the tinted and clear Home Screen modes the system
/// draws every opaque pixel in one tint, so an opaque card would cover its
/// text; there the card is a faint wash instead.
struct WCardBackground: ViewModifier {
    var cornerRadius: CGFloat
    @Environment(\.widgetRenderingMode) private var renderingMode
    func body(content: Content) -> some View {
        content.background(renderingMode == .fullColor ? WTheme.card : WTheme.ink.opacity(0.10),
                           in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

/// Small-caps section label, e.g. "EST. RANGE".
struct WLabel: View {
    var text: String
    var color: Color = WTheme.label
    init(_ text: String, color: Color = WTheme.label) { self.text = text; self.color = color }
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(1.4)
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

/// Big numeral with a small gray unit suffix: "78 %".
struct WNumber: View {
    var value: String
    var unit: String?
    var size: CGFloat
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 2) {
            Text(value)
                .font(.system(size: size, weight: .heavy))
                .tracking(-size * 0.03)
                .foregroundStyle(WTheme.text)
                .contentTransition(.numericText())
            if let unit {
                Text(unit)
                    .font(.system(size: max(11, size * 0.32), weight: .medium))
                    .foregroundStyle(WTheme.label)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
}

/// Thin horizontal bar; `marker` draws a tick (e.g. the charge limit).
struct WBar: View {
    var fraction: Double
    var color: Color = WTheme.blue
    var marker: Double?
    var height: CGFloat = 4
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(WTheme.track)
                Capsule().fill(color)
                    .frame(width: max(height, geo.size.width * min(1, max(0, fraction))))
                    .shadow(color: color.opacity(0.6), radius: 3)
                if let marker {
                    Rectangle().fill(WTheme.ink.opacity(0.7))
                        .frame(width: 1.5, height: height + 6)
                        .offset(x: geo.size.width * min(1, max(0, marker)) - 0.75)
                }
            }
        }
        .frame(height: height)
    }
}
