import SwiftUI

/// Widget-local copy of the Volta palette (docs/SPEC.md "Visual language").
/// The extension does not link the app's DesignSystem, so the few tokens it
/// needs live here.
enum WTheme {
    static let background = Color(hex: 0x0E0F11)
    static let card = Color(hex: 0x17191C)
    static let hairline = Color.white.opacity(0.08)
    static let label = Color(hex: 0x8A8F98)
    static let track = Color.white.opacity(0.12)
    static let blue = Color(hex: 0x3B82F6)
    static let green = Color(hex: 0x22C55E)
    static let amber = Color(hex: 0xF59E0B)
    static let red = Color(hex: 0xEF4444)

    static let backgroundGradient = LinearGradient(
        colors: [Color(hex: 0x1A1C20), background], startPoint: .top, endPoint: .bottom)

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
        case .asleep: Color.white.opacity(0.10)
        case .offline: Color.white.opacity(0.04)
        }
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: 1)
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
                .foregroundStyle(.white)
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
                    Rectangle().fill(.white.opacity(0.7))
                        .frame(width: 1.5, height: height + 6)
                        .offset(x: geo.size.width * min(1, max(0, marker)) - 0.75)
                }
            }
        }
        .frame(height: height)
    }
}
