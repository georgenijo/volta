import Charts
import SwiftUI

struct HistoryChartPoint: Identifiable, Hashable {
    var t: Date
    var value: Double
    var id: Date { t }
}

enum HistorySeries {
    /// Min/max-preserving downsample: splits the series into time-ordered
    /// buckets and keeps each bucket's lowest and highest point (plus the
    /// first and last point), so peaks and dips survive. O(n).
    static func downsample(_ points: [HistoryChartPoint], maxPoints: Int = 500) -> [HistoryChartPoint] {
        guard maxPoints >= 4, points.count > maxPoints else { return points }
        let interior = points.count - 2
        let buckets = (maxPoints - 2) / 2
        let size = Int((Double(interior) / Double(buckets)).rounded(.up))
        var keep: [Int] = [0]
        var start = 1
        while start < points.count - 1 {
            let end = min(start + size, points.count - 1)
            var lo = start, hi = start
            for i in start..<end {
                if points[i].value < points[lo].value { lo = i }
                if points[i].value > points[hi].value { hi = i }
            }
            keep.append(min(lo, hi))
            if lo != hi { keep.append(max(lo, hi)) }
            start = end
        }
        keep.append(points.count - 1)
        return keep.map { points[$0] }
    }

    /// Y domain including zero, padded 8% above the max.
    static func domain(_ points: [HistoryChartPoint]) -> ClosedRange<Double> {
        var lo = 0.0, hi = -Double.infinity
        for p in points {
            lo = min(lo, p.value)
            hi = max(hi, p.value)
        }
        if !hi.isFinite { hi = 1 }
        hi = max(hi, lo + 1)
        return lo...(hi + (hi - lo) * 0.08)
    }
}

/// Smooth line + soft gradient area time-series used on detail screens.
/// Long series are downsampled and the Y domain is computed once in `init`,
/// not per mark.
struct HistoryLineChart: View {
    var points: [HistoryChartPoint]
    var color: Color
    var unit: String
    var height: CGFloat = 150
    var digits: Int = 0
    /// Draw a zero baseline (e.g. power with regen).
    var showsZero: Bool = false
    private let domain: ClosedRange<Double>

    @State private var selected: Date?

    init(points: [HistoryChartPoint], color: Color, unit: String, yDomain: ClosedRange<Double>? = nil,
         height: CGFloat = 150, digits: Int = 0, showsZero: Bool = false) {
        let plotted = HistorySeries.downsample(points)
        self.points = plotted
        self.color = color
        self.unit = unit
        self.height = height
        self.digits = digits
        self.showsZero = showsZero
        self.domain = yDomain ?? HistorySeries.domain(plotted)
    }

    private var selectedPoint: HistoryChartPoint? {
        guard let selected else { return nil }
        return points.min { abs($0.t.timeIntervalSince(selected)) < abs($1.t.timeIntervalSince(selected)) }
    }

    var body: some View {
        let base = domain.lowerBound
        return Chart {
            ForEach(points) { p in
                AreaMark(x: .value("Time", p.t), yStart: .value("Base", base), yEnd: .value(unit, p.value))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [color.opacity(0.32), color.opacity(0.0)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Time", p.t), y: .value(unit, p.value))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(color)
                    .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            }
            if showsZero, domain.lowerBound < 0 {
                RuleMark(y: .value("Zero", 0))
                    .foregroundStyle(Color.white.opacity(0.18))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            if let p = selectedPoint {
                RuleMark(x: .value("Selected", p.t))
                    .foregroundStyle(Color.white.opacity(0.25))
                PointMark(x: .value("Selected", p.t), y: .value(unit, p.value))
                    .foregroundStyle(color)
                    .symbolSize(70)
                    .annotation(position: .top, spacing: 6, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(spacing: 1) {
                            Text("\(VoltaFormat.number(p.value, digits: digits)) \(unit)")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                            Text(p.t.historyTime)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(HistoryTheme.secondary)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(HistoryTheme.cardRaised, in: .rect(cornerRadius: 8))
                    }
            }
        }
        .chartYScale(domain: domain)
        .chartXSelection(value: $selected)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(format: .dateTime.hour().minute())
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(HistoryTheme.secondary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(HistoryTheme.hairline)
                AxisValueLabel()
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(HistoryTheme.secondary)
            }
        }
        .frame(height: height)
    }
}

/// Card wrapper: small-caps title, optional headline value, chart.
struct HistoryChartCard<Accessory: View, Plot: View>: View {
    var title: String
    var systemImage: String
    var value: String? = nil
    var unit: String? = nil
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var chart: Plot

    var body: some View {
        HistoryCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center) {
                    HistorySectionLabel(title: title, systemImage: systemImage)
                        .fixedSize()
                    Spacer()
                    accessory
                }
                if let value {
                    HistoryValue(value: value, unit: unit, size: 26)
                }
                chart
            }
        }
    }
}

extension HistoryChartCard where Accessory == EmptyView {
    init(title: String, systemImage: String, value: String? = nil, unit: String? = nil, @ViewBuilder chart: () -> Plot) {
        self.init(title: title, systemImage: systemImage, value: value, unit: unit, accessory: { EmptyView() }, chart: chart)
    }
}

/// Placeholder shown in chart cards while the detail request is in flight.
struct HistoryChartPlaceholder: View {
    var height: CGFloat = 150
    var message: String? = nil
    var retry: (() -> Void)? = nil

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12).fill(HistoryTheme.track.opacity(0.5))
            if let message {
                VStack(spacing: 10) {
                    Text(message)
                        .font(.system(size: 13))
                        .foregroundStyle(HistoryTheme.secondary)
                        .multilineTextAlignment(.center)
                    if let retry {
                        PillButton("Retry", systemImage: "arrow.clockwise", action: retry)
                    }
                }
                .padding()
            } else {
                ProgressView().tint(HistoryTheme.secondary)
            }
        }
        .frame(height: height)
    }
}

/// Grid of stats separated by hairlines, inside one card.
struct HistoryStatGrid: View {
    struct Item: Identifiable {
        var label: String
        var value: String
        var unit: String? = nil
        var systemImage: String
        var id: String { label }
    }
    var items: [Item]
    var columns: Int = 3

    var body: some View {
        HistoryCard(padding: 0) {
            let rows = stride(from: 0, to: items.count, by: columns).map { Array(items[$0..<min($0 + columns, items.count)]) }
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    if index > 0 { HairlineDivider() }
                    HStack(spacing: 0) {
                        ForEach(Array(row.enumerated()), id: \.element.id) { i, item in
                            if i > 0 {
                                Rectangle().fill(HistoryTheme.hairline).frame(width: 1)
                            }
                            VStack(alignment: .leading, spacing: 8) {
                                HStack(spacing: 5) {
                                    Image(systemName: item.systemImage)
                                        .font(.system(size: 10, weight: .semibold))
                                    Text(item.label).voltaLabelStyle()
                                        .tracking(1.1)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.8)
                                }
                                .foregroundStyle(HistoryTheme.secondary)
                                HistoryValue(value: item.value, unit: item.unit, size: 20)
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if row.count < columns {
                            ForEach(0..<(columns - row.count), id: \.self) { _ in
                                Rectangle().fill(HistoryTheme.hairline).frame(width: 1)
                                Color.clear.frame(maxWidth: .infinity)
                            }
                        }
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

/// Detail-screen top bar: back button, centered title.
struct HistoryDetailHeader: View {
    var title: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VoltaHeader(title) {
            GlassCircleButton(systemImage: "chevron.left", size: 48, accessibilityLabel: "Back") { dismiss() }
        } trailing: {
            Color.clear.frame(width: 48, height: 48)
        }
    }
}
