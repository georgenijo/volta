import SwiftUI

/// Private visual tokens and small building blocks for the History feature.
/// They mirror docs/SPEC.md "Visual language"; shared equivalents live in
/// DesignSystem/ (owned by Screens A).
enum HistoryTheme {
    static let background = Color.voltaBackground
    static let card = Color.voltaCard
    static let cardRaised = Color.voltaRaised
    static let hairline = Color.voltaHairline
    static let secondary = Color.voltaTextSecondary
    static let tertiary = Color.voltaTextTertiary
    static let track = Color.white.opacity(0.08)

    static let blue = Color.voltaBlue
    static let green = Color.voltaGreen
    static let amber = Color.voltaAmber
    static let red = Color.voltaRed
    /// Regen / secondary series only.
    static let purple = Color(hex: 0xA78BFA)

    static let cardRadius: CGFloat = VoltaRadius.card
    static let gutter: CGFloat = VoltaSpacing.lg
    /// Room for MainShell's floating tab bar.
    static let bottomInset: CGFloat = VoltaSpacing.tabBarClearance
}

// MARK: - Card

struct HistoryCard<Content: View>: View {
    var padding: CGFloat = 16
    var tint: Color? = nil
    @ViewBuilder var content: Content

    var body: some View {
        Card(padding: padding, tint: tint) { content }
    }
}

// MARK: - Labels and numbers

struct HistorySectionLabel: View {
    var title: String
    var systemImage: String? = nil
    var trailing: String? = nil

    var body: some View {
        HStack(spacing: 8) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 12, weight: .semibold))
            }
            Text(title).voltaLabelStyle()
            Spacer(minLength: 8)
            if let trailing {
                Text(trailing.uppercased())
                    .font(.system(size: 11, weight: .semibold))
                    .tracking(1.2)
                    .monospacedDigit()
            }
        }
        .foregroundStyle(HistoryTheme.secondary)
    }
}

/// Big white number with a small gray unit, e.g. "22.6 kWh".
struct HistoryValue: View {
    var value: String
    var unit: String? = nil
    var size: CGFloat = 22
    var color: Color = .white

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
            Text(value)
                .font(.system(size: size, weight: .heavy))
                .tracking(size > 28 ? -1 : -0.3)
                .foregroundStyle(color)
                .monospacedDigit()
            if let unit, !unit.isEmpty {
                Text(unit)
                    .font(.system(size: max(11, size * 0.42), weight: .medium))
                    .foregroundStyle(HistoryTheme.secondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
    }
}

/// Labeled stat: small-caps caption over a value.
struct HistoryStat: View {
    var label: String
    var value: String
    var unit: String? = nil
    var size: CGFloat = 20
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: 6) {
            HistoryValue(value: value, unit: unit, size: size)
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(1.3)
                .foregroundStyle(HistoryTheme.secondary)
                .lineLimit(1)
        }
    }
}

/// A row of equally spaced, centered totals (dashboard "Activity" style).
struct HistoryTotalsRow: View {
    struct Item: Identifiable {
        var label: String
        var value: String
        var unit: String?
        var id: String { label }
    }
    var items: [Item]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(items) { item in
                HistoryStat(label: item.label, value: item.value, unit: item.unit, size: 28, alignment: .center)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Battery range bar

/// Thin track with a filled segment between two battery levels.
struct BatteryRangeBar: View {
    var from: Int?
    var to: Int?
    var tint: Color = HistoryTheme.blue
    var height: CGFloat = 6

    var body: some View {
        GeometryReader { proxy in
            let lo = Double(min(from ?? 0, to ?? 0)) / 100
            let hi = Double(max(from ?? 0, to ?? 0)) / 100
            ZStack(alignment: .leading) {
                Capsule().fill(HistoryTheme.track)
                if from != nil, to != nil {
                    Capsule()
                        .fill(LinearGradient(colors: [tint.opacity(0.55), tint], startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(height, proxy.size.width * (hi - lo)))
                        .offset(x: proxy.size.width * lo)
                        .shadow(color: tint.opacity(0.45), radius: 4)
                }
            }
        }
        .frame(height: height)
    }
}

/// "49% → 80%" with the bar underneath.
struct BatteryRangeView: View {
    var from: Int?
    var to: Int?
    var tint: Color = HistoryTheme.blue

    var body: some View {
        HStack(spacing: 10) {
            Text(from.map { "\($0)%" } ?? "—")
                .frame(width: 34, alignment: .leading)
            BatteryRangeBar(from: from, to: to, tint: tint)
            Text(to.map { "\($0)%" } ?? "—")
                .frame(width: 34, alignment: .trailing)
        }
        .font(.system(size: 12, weight: .semibold))
        .monospacedDigit()
        .foregroundStyle(HistoryTheme.secondary)
    }
}

// MARK: - Chips

struct HistoryBadge: View {
    var title: String
    var systemImage: String? = nil
    var tint: Color

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage) }
            Text(title.uppercased()).tracking(0.8)
        }
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(tint)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(tint.opacity(0.14), in: .capsule)
    }
}

/// Inline metric used in list cards: icon + value.
struct HistoryInlineMetric: View {
    var systemImage: String
    var text: String
    var tint: Color = HistoryTheme.secondary

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: systemImage)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(tint)
            Text(text)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white.opacity(0.88))
                .monospacedDigit()
        }
        .lineLimit(1)
    }
}

/// Circular icon tile used at the leading edge of list cards.
struct HistoryIconTile: View {
    var systemImage: String?
    var text: String? = nil
    var tint: Color

    var body: some View {
        ZStack {
            Circle().fill(tint.opacity(0.14))
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
            } else if let text {
                Text(text).font(.system(size: 17, weight: .bold))
            }
        }
        .foregroundStyle(tint)
        .frame(width: 38, height: 38)
    }
}

extension View {
    func historyScreenBackground() -> some View { voltaScreenBackground() }
}
