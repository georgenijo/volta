import SwiftUI

// MARK: - BigNumber

/// Large heavy white numeral with a small gray unit suffix: "78 %", "276 mi".
/// The size follows Dynamic Type (scaled from `size` relative to .largeTitle).
///
///     BigNumber("78", unit: "%", size: 84)
///     BigNumber("—", unit: "Wh/mi", size: 48)
struct BigNumber: View {
    var value: String
    var unit: String?
    var weight: Font.Weight
    var color: Color
    @ScaledMetric(relativeTo: .largeTitle) private var scaledSize: CGFloat = 48

    init(_ value: String, unit: String? = nil, size: CGFloat = 48,
         weight: Font.Weight = .heavy, color: Color = .voltaTextPrimary) {
        self.value = value
        self.unit = unit
        self.weight = weight
        self.color = color
        _scaledSize = ScaledMetric(wrappedValue: size, relativeTo: .largeTitle)
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: max(2, scaledSize * 0.06)) {
            Text(value)
                .font(.system(size: scaledSize, weight: weight))
                .tracking(-scaledSize * 0.03)
                .foregroundStyle(color)
                .monospacedDigit()
                .contentTransition(.numericText())
            if let unit {
                Text(unit)
                    .font(.system(size: max(12, scaledSize * 0.36), weight: .regular))
                    .foregroundStyle(Color.voltaTextSecondary)
            }
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - TemperatureScale

/// One temperature track with labelled ends and a lettered marker per
/// reading, so cabin, outside and battery read against the same scale.
/// Markers are tags on stems, not slider thumbs: nothing here is draggable.
/// Tags that would overlap slide apart; their stems still point at the value.
///
///     TemperatureScale(markers: [.init(id: "C", fraction: 0.4), .init(id: "O", fraction: 0.3)],
///                      lowLabel: "23°F", highLabel: "113°F")
struct TemperatureScale: View {
    struct Marker: Identifiable, Equatable {
        var id: String
        /// 0...1 along the track.
        var fraction: Double
    }

    var markers: [Marker]
    var lowLabel: String
    var highLabel: String

    /// Cold to hot. These hues appear only on this scale and in the reading
    /// words beside it, so blue-to-red always means temperature.
    static let colors: [Color] = [.voltaBlue, .voltaBlue, .voltaGreen, .voltaGreen, .voltaAmber, .voltaRed]

    @ScaledMetric(relativeTo: .caption2) private var tag: CGFloat = 18
    /// False until the scale appears, so the markers glide in from the cold end.
    @State private var settled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let stem: CGFloat = 9
    private let track: CGFloat = 6

    var body: some View {
        VStack(spacing: VoltaSpacing.xs) {
            GeometryReader { geo in
                let w = geo.size.width
                let shown = settled || reduceMotion
                let points = markers.map { CGFloat(min(max(shown ? $0.fraction : 0, 0), 1)) * w }
                let centers = Self.spread(points, width: w, tag: tag)
                ZStack(alignment: .topLeading) {
                    Capsule()
                        .fill(LinearGradient(colors: Self.colors, startPoint: .leading, endPoint: .trailing))
                        .frame(height: track)
                        .offset(y: tag + stem)
                    Path { path in
                        for (x, c) in zip(points, centers) {
                            path.move(to: CGPoint(x: c, y: tag))
                            path.addLine(to: CGPoint(x: x, y: tag + stem - 2))
                            path.addLine(to: CGPoint(x: x, y: tag + stem + track + 2))
                        }
                    }
                    .stroke(Color.voltaTextPrimary, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                    ForEach(Array(markers.enumerated()), id: \.element.id) { index, marker in
                        Text(marker.id)
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(Color.voltaTextPrimary)
                            .frame(width: tag, height: tag)
                            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Color.voltaRaised))
                            .position(x: centers[index], y: tag / 2)
                    }
                }
            }
            .frame(height: tag + stem + track + 2)
            HStack {
                Text(lowLabel)
                Spacer()
                Text(highLabel)
            }
            .font(.caption2)
            .foregroundStyle(Color.voltaTextTertiary)
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.8, bounce: 0.2), value: markers)
        .accessibilityHidden(true)
        .onAppear {
            guard !settled else { return }
            withAnimation(reduceMotion ? nil : .spring(duration: 0.9, bounce: 0.2).delay(0.15)) { settled = true }
        }
    }

    /// Tag centres: each as close to its value as it can be without touching
    /// its neighbour, all inside the track.
    static func spread(_ points: [CGFloat], width: CGFloat, tag: CGFloat) -> [CGFloat] {
        guard !points.isEmpty else { return [] }
        let gap = tag + 3
        let order = points.indices.sorted { points[$0] < points[$1] }
        var placed = order.map { min(max(points[$0], tag / 2), width - tag / 2) }
        for i in placed.indices.dropFirst() { placed[i] = max(placed[i], placed[i - 1] + gap) }
        if let last = placed.last, last > width - tag / 2 {
            placed[placed.count - 1] = width - tag / 2
            for i in placed.indices.reversed().dropFirst() { placed[i] = min(placed[i], placed[i + 1] - gap) }
        }
        var result = points
        for (slot, index) in order.enumerated() { result[index] = placed[slot] }
        return result
    }
}

// MARK: - LevelBar

/// A capacity bar: filled from the start of the track to the value, with
/// both ends labelled so the fill has a meaning. Nil draws an empty track.
///
///     LevelBar(value: 0.3, color: .voltaGreen, lowLabel: "160 efficient", highLabel: "400 heavy")
struct LevelBar: View {
    var value: Double?
    var color: Color
    var lowLabel: String
    var highLabel: String
    @State private var settled = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: VoltaSpacing.xs) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.voltaTrack)
                    if let value {
                        Capsule().fill(color)
                            .frame(width: max(6, geo.size.width * CGFloat(min(max(value, 0), 1)) * (settled || reduceMotion ? 1 : 0)))
                    }
                }
            }
            .frame(height: 6)
            HStack {
                Text(lowLabel)
                Spacer(minLength: VoltaSpacing.sm)
                Text(highLabel)
            }
            .font(.caption2)
            .foregroundStyle(Color.voltaTextTertiary)
            .lineLimit(1)
        }
        .animation(reduceMotion ? nil : .spring(duration: 0.8, bounce: 0.15), value: value)
        .accessibilityHidden(true)
        .onAppear {
            guard !settled else { return }
            withAnimation(reduceMotion ? nil : .spring(duration: 0.9, bounce: 0.15).delay(0.15)) { settled = true }
        }
    }
}

/// Small centered stat: numeral over a small-caps caption ("0 / MI").
///
///     StatColumn(value: "12", caption: "mi")
struct StatColumn: View {
    var value: String
    var caption: String
    var body: some View {
        VStack(spacing: VoltaSpacing.sm) {
            BigNumber(value, size: 34, weight: .bold)
            Text(caption)
                .font(.caption)
                .tracking(1.5)
                .foregroundStyle(Color.voltaTextSecondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

#Preview("Metrics") {
    ScrollView {
        VStack(spacing: 16) {
            HStack { BigNumber("78", unit: "%", size: 84); Spacer(); BigNumber("276", unit: "mi", size: 30, weight: .semibold) }
            TemperatureScale(markers: [.init(id: "O", fraction: 0.26), .init(id: "C", fraction: 0.32),
                                       .init(id: "B", fraction: 0.47)],
                             lowLabel: "23°F", highLabel: "113°F")
            LevelBar(value: 0.3, color: .voltaGreen, lowLabel: "160 efficient", highLabel: "400 heavy")
            HStack { StatColumn(value: "0", caption: "MI"); StatColumn(value: "0", caption: "CHARGES"); StatColumn(value: "—", caption: "Wh/mi") }
        }
        .padding(VoltaSpacing.screen)
    }
    .voltaScreenBackground()
}
