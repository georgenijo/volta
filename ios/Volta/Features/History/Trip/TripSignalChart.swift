import Charts
import SwiftUI

/// One line on a drive detail chart, already in display units.
struct TripTrace: Identifiable {
    var id: String { label }
    var label: String
    var color: Color
    var points: [DriveCharts.Point]
    /// Bottom-to-top line colours (speed); nil draws `color`.
    var gradient: [Color]? = nil
    var dashed = false
    /// Gradient area under the line, down to the chart floor.
    var fill = false
    var interpolation: InterpolationMethod = .stepEnd
    /// End-point dot colour; nil uses `color`.
    var endDot: Color? = nil
}

/// The flat Wattly-style signal chart: step lines, a gradient area, an
/// end-point dot, y labels on the left and an elapsed-minute x axis.
struct TripSignalChart: View {
    var traces: [TripTrace]
    var start: Date
    var end: Date
    var domain: ClosedRange<Double>
    var axisLabel: (Double) -> String
    /// Shade between the first two traces (range efficiency).
    var fillBetween = false
    var height: CGFloat = 132
    var tooltip: ((Double) -> String?)? = nil
    @Binding var scrub: Double?
    var focusMinute: Double?

    private var totalMinutes: Double { max(end.timeIntervalSince(start) / 60, 1) }
    private func minute(_ t: Date) -> Double { t.timeIntervalSince(start) / 60 }

    var body: some View {
        Chart {
            if fillBetween, traces.count >= 2 {
                ForEach(Array(zip(traces[0].points, traces[1].points).enumerated()), id: \.offset) { _, pair in
                    AreaMark(x: .value("Minute", minute(pair.0.t)),
                             yStart: .value("Ideal", pair.1.v), yEnd: .value("Actual", pair.0.v),
                             series: .value("Band", "band"))
                        .interpolationMethod(.linear)
                        .foregroundStyle(traces[0].color.opacity(0.22))
                }
            }
            ForEach(traces) { trace in
                if trace.fill {
                    ForEach(Array(trace.points.enumerated()), id: \.offset) { _, p in
                        AreaMark(x: .value("Minute", minute(p.t)), yStart: .value("Floor", domain.lowerBound),
                                 yEnd: .value(trace.label, p.v), series: .value("Area", trace.label))
                            .interpolationMethod(trace.interpolation)
                            .foregroundStyle(LinearGradient(colors: [(trace.gradient?.last ?? trace.color).opacity(0.30),
                                                                     trace.color.opacity(0.02)],
                                                            startPoint: .top, endPoint: .bottom))
                    }
                }
                ForEach(Array(trace.points.enumerated()), id: \.offset) { _, p in
                    LineMark(x: .value("Minute", minute(p.t)), y: .value(trace.label, p.v), series: .value("Trace", trace.label))
                        .interpolationMethod(trace.interpolation)
                        .foregroundStyle(lineStyle(trace))
                        .lineStyle(StrokeStyle(lineWidth: trace.dashed ? 1.2 : 2, lineCap: .round, lineJoin: .round,
                                               dash: trace.dashed ? [4, 3] : []))
                }
                if !trace.dashed, let last = trace.points.last {
                    PointMark(x: .value("Minute", minute(last.t)), y: .value(trace.label, last.v))
                        .foregroundStyle(trace.endDot ?? trace.color)
                        .symbolSize(42)
                }
            }
            if let focusMinute {
                RuleMark(x: .value("Selected", focusMinute))
                    .foregroundStyle(Color.white.opacity(0.35))
                    .annotation(position: .top, spacing: 2, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        if let text = tooltip?(focusMinute) { TripChartTooltip(text: text, minute: focusMinute) }
                    }
            }
        }
        .chartXScale(domain: 0...totalMinutes)
        .chartYScale(domain: domain)
        .chartXSelection(value: $scrub)
        .chartXAxis {
            AxisMarks(values: axisMinutes) { value in
                AxisValueLabel(anchor: .topLeading, collisionResolution: .disabled) {
                    if let m = value.as(Double.self) { Text(TripChart.minuteLabel(m)) }
                }
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(HistoryTheme.tertiary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 0.5)).foregroundStyle(Color.white.opacity(0.06))
                AxisValueLabel(horizontalSpacing: 6) {
                    if let v = value.as(Double.self) { Text(axisLabel(v)) }
                }
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(HistoryTheme.tertiary)
            }
        }
        .chartPlotStyle { plot in
            plot.overlay(alignment: .bottom) { Rectangle().fill(Color.white.opacity(0.12)).frame(height: 1) }
        }
        .frame(height: height)
    }

    /// 0m, then every stride: starting at zero so the first label is always "0m".
    private var axisMinutes: [Double] {
        Array(stride(from: 0, through: totalMinutes, by: TripChartSeries.axisStride(totalMinutes)))
    }

    private func lineStyle(_ trace: TripTrace) -> AnyShapeStyle {
        if let gradient = trace.gradient {
            AnyShapeStyle(LinearGradient(colors: gradient, startPoint: .bottom, endPoint: .top))
        } else {
            AnyShapeStyle(trace.color.opacity(trace.dashed ? 0.55 : 1))
        }
    }
}

private struct TripChartTooltip: View {
    var text: String
    var minute: Double
    var body: some View {
        VStack(spacing: 1) {
            Text(text).font(.system(size: 12, weight: .semibold)).monospacedDigit().foregroundStyle(.white)
            Text(TripChart.minuteLabel(minute)).font(.system(size: 10, weight: .medium)).foregroundStyle(HistoryTheme.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(HistoryTheme.cardRaised, in: .rect(cornerRadius: 8))
    }
}

/// Legend row under a chart: "● INSIDE  ● OUTSIDE", or a dash for a dashed trace.
struct TripChartLegend: View {
    struct Item: Identifiable {
        var id: String { label }
        var label: String
        var color: Color
        var dashed = false
    }
    var items: [Item]

    var body: some View {
        HStack(spacing: 22) {
            ForEach(items) { item in
                HStack(spacing: 9) {
                    if item.dashed {
                        Rectangle().fill(item.color).frame(width: 12, height: 1.2)
                    } else {
                        Circle().fill(item.color).frame(width: 6, height: 6)
                    }
                    Text(item.label).tripLabel()
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

enum TripSignalDomain {
    /// min…max with breathing room, never collapsed to a point.
    static func padded(_ values: [Double], minSpan: Double = 1, pad: Double = 0.15) -> ClosedRange<Double> {
        guard let lo = values.min(), let hi = values.max() else { return 0...1 }
        let span = max(hi - lo, minSpan)
        let mid = (hi + lo) / 2
        let half = span / 2 * (1 + pad * 2)
        return (mid - half)...(mid + half)
    }

    /// From zero to just above the max.
    static func zeroBased(_ values: [Double]) -> ClosedRange<Double> {
        let hi = max(values.max() ?? 1, 1)
        return min(0, values.min() ?? 0)...(hi * 1.08)
    }
}
