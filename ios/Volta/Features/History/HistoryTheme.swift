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
    static let track = Color.voltaInk.opacity(0.08)  // a step quieter than `voltaTrack`, as it always was

    static let blue = Color.voltaBlue
    static let green = Color.voltaGreen
    static let amber = Color.voltaAmber
    static let red = Color.voltaRed
    /// Regen / secondary series only.
    static let purple = Color.voltaPurple

    static let cardRadius: CGFloat = VoltaRadius.card
    static let gutter: CGFloat = VoltaSpacing.lg
    /// Room for MainShell's floating tab bar.
    static let bottomInset: CGFloat = VoltaSpacing.tabBarClearance
}

// MARK: - Card

struct HistoryCard<Content: View>: View {
    var padding: CGFloat = 16
    /// A state colour for the card's border. Cards carry no tinted glow
    /// (DesignSystem/README.md "Design rules"); the border may take the state.
    var tint: Color? = nil
    @ViewBuilder var content: Content

    var body: some View {
        Card(padding: padding) { content }
            .overlay {
                if let tint {
                    RoundedRectangle(cornerRadius: VoltaRadius.card, style: .continuous)
                        .strokeBorder(tint.opacity(0.5), lineWidth: 1)
                        .allowsHitTesting(false)
                }
            }
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
                Text(trailing)
                    .font(.caption)
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
    var color: Color = .voltaTextPrimary

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

/// Labeled stat: a value over its sentence-case label.
struct HistoryStat: View {
    var label: String
    var value: String
    var unit: String? = nil
    var size: CGFloat = 20
    var alignment: HorizontalAlignment = .leading

    var body: some View {
        VStack(alignment: alignment, spacing: 6) {
            HistoryValue(value: value, unit: unit, size: size)
            Text(label)
                .voltaLabelStyle()
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

/// Thin 0–100 % track with a filled segment between two battery levels.
/// No glow; the segment settles into place as it appears.
struct BatteryRangeBar: View {
    var from: Int?
    var to: Int?
    var tint: Color = HistoryTheme.blue
    var height: CGFloat = 6
    @State private var settled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { proxy in
            let lo = Double(min(from ?? 0, to ?? 0)) / 100
            let hi = Double(max(from ?? 0, to ?? 0)) / 100
            let shown = settled || reduceMotion
            ZStack(alignment: .leading) {
                Capsule().fill(HistoryTheme.track)
                if from != nil, to != nil {
                    Capsule()
                        .fill(tint)
                        .frame(width: max(height, proxy.size.width * (hi - lo) * (shown ? 1 : 0)))
                        .offset(x: proxy.size.width * lo)
                }
            }
        }
        .frame(height: height)
        .onAppear {
            guard !settled else { return }
            withAnimation(VoltaMotion.animation(VoltaMotion.settle.delay(0.1), reduceMotion: reduceMotion)) { settled = true }
        }
    }
}

/// "74% → 72%" over a 0–100 % track with the segment between them, and the
/// track's own ends labelled, so the bar's position reads as the battery level.
struct BatteryRangeView: View {
    var from: Int?
    var to: Int?
    var tint: Color = HistoryTheme.blue

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(reading)
                .font(.system(.subheadline, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(from == nil && to == nil ? HistoryTheme.secondary : Color.voltaTextPrimary)
            BatteryRangeBar(from: from, to: to, tint: tint)
            HStack {
                Text("0%")
                Spacer(minLength: 8)
                Text("100%")
            }
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(HistoryTheme.tertiary)
        }
    }

    private var reading: String {
        switch (from, to) {
        case let (f?, t?): "\(f)% → \(t)%"
        case let (f?, nil): "\(f)% → —"
        case let (nil, t?): "— → \(t)%"
        default: "Battery not recorded"
        }
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
            Text(title)
        }
        .font(.caption2.weight(.semibold))
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
                .foregroundStyle(Color.voltaInk.opacity(0.88))
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

    /// `.voltaFocusIn(index)` for the first screenful of a list; rows past it
    /// appear as they are, so scrolling a long list never waits on them.
    @ViewBuilder func historyFocusIn(_ index: Int) -> some View {
        if index <= VoltaMotion.maxStaggered { voltaFocusIn(index) } else { self }
    }
}

// MARK: - Headline figures

/// A headline number that rolls up as it appears (`RollingNumber`), or an
/// em dash when unknown. Style it with `.font` and `.foregroundStyle`.
///
///     HistoryRollingFigure(value: 231) { VoltaFormat.number($0, digits: 0) }
///         .font(.system(size: 60, weight: .bold))
struct HistoryRollingFigure: View {
    var value: Double?
    var format: (Double) -> String

    var body: some View {
        if let value, value.isFinite {
            RollingNumber(value: value, format: format)
        } else {
            Text("—")
        }
    }
}
