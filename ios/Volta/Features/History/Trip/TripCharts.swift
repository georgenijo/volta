import Charts
import SwiftUI

/// One plotted value at an elapsed time. `segment` keeps lines from joining across gaps.
struct TripChartPoint: Identifiable, Hashable, Sendable {
    var minute: Double
    var value: Double
    var segment: Int
    /// Index into `TripTimeline.points`; unique, unlike timestamps in raw data.
    var id: Int
}

/// The scrub position shared by the map and every chart, resolved once against
/// the full normalized timeline (never against a chart's reduced plotting
/// points). `index` is nil when the position lies in a gap with no sample.
struct TripSelection: Equatable, Sendable {
    /// Where the finger is, in elapsed minutes.
    var minute: Double
    /// Index into `TripTimeline.points`.
    var index: Int?
    /// Elapsed minute of the selected sample, when there is one.
    var sampleMinute: Double?

    init(minute: Double, timeline: TripTimeline) {
        self.minute = minute
        index = timeline.sampleIndex(atMinute: minute)
        sampleMinute = index.map { timeline.elapsedMinutes(timeline.points[$0]) }
    }
}

/// A chartable series for one signal: points grouped by that signal's own
/// segments, plus that signal's gap ranges (shaded, never interpolated across).
/// Plotted points may be reduced for drawing; values for a selection always
/// come from `signal`, which holds every recorded sample.
struct TripChartSeries: Equatable, Sendable {
    var points: [TripChartPoint]
    var gaps: [ClosedRange<Double>]
    var totalMinutes: Double
    var signal: TripSignal
    /// Every source sample's elapsed minute. This keeps a per-metric telemetry
    /// series on the same session clock even when the map uses legacy rows (or
    /// vice versa); indices from different sources are never treated as equal.
    private var sampleMinutes: [Double]

    init(_ timeline: TripTimeline, maxPointsPerSegment: Int = 400, value: (DrivePoint) -> Double?) {
        let signal = TripSignal(timeline, value: value)
        var out: [TripChartPoint] = []
        for (n, run) in signal.segments.enumerated() {
            let pts = run.map { i in
                TripChartPoint(minute: timeline.elapsedMinutes(timeline.points[i]), value: signal.values[i]!, segment: n, id: i)
            }
            out.append(contentsOf: Self.downsample(pts, maxPoints: maxPointsPerSegment))
        }
        points = out
        gaps = signal.gapRanges
        totalMinutes = max(timeline.totalMinutes, out.last?.minute ?? 0)
        self.signal = signal
        sampleMinutes = timeline.points.map(timeline.elapsedMinutes)
    }

    var values: [Double] { points.map(\.value) }
    var isEmpty: Bool { points.isEmpty }

    /// This signal's recorded value at the shared selection; nil when the
    /// selected sample didn't record it (or there is no sample there).
    func value(at selection: TripSelection?) -> Double? { signal.value(at: sampleIndex(at: selection?.minute)) }

    func sampleMinute(at selection: TripSelection?) -> Double? {
        sampleIndex(at: selection?.minute).map { sampleMinutes[$0] }
    }

    private func sampleIndex(at minute: Double?) -> Int? {
        guard let minute, !sampleMinutes.isEmpty,
              !gaps.contains(where: { $0.lowerBound < minute && minute < $0.upperBound }) else { return nil }
        var lo = 0, hi = sampleMinutes.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if sampleMinutes[mid] < minute { lo = mid + 1 } else { hi = mid }
        }
        let candidates = [lo - 1, lo].filter(sampleMinutes.indices.contains)
        guard let best = candidates.min(by: { abs(sampleMinutes[$0] - minute) < abs(sampleMinutes[$1] - minute) }),
              abs(sampleMinutes[best] - minute) <= TripTimeline.gapThreshold / 2 / 60 else { return nil }
        return best
    }

    /// Disclosure under a chart whose signal is not densely recorded; nil when it is.
    static func coverageNote(_ series: TripChartSeries, title: String) -> String? {
        let signal = series.signal
        guard !signal.isDense, signal.observationCount > 0 else { return nil }
        let samples = "\(signal.observationCount.formatted()) sample\(signal.observationCount == 1 ? "" : "s")"
        let gaps = signal.gapRanges.count
        var note = "\(title) recorded for \(TripAnalysis.percent(signal.coverage)) of the trip · \(samples)"
        if gaps > 0 { note += " · \(gaps) gap\(gaps == 1 ? "" : "s") shaded, not joined" }
        return note
    }

    func inGap(_ minute: Double) -> Bool { gaps.contains { $0.contains(minute) && $0.upperBound - $0.lowerBound > 0 } }

    /// Same min/max-preserving reduction as `HistorySeries.downsample`, per segment.
    static func downsample(_ points: [TripChartPoint], maxPoints: Int) -> [TripChartPoint] {
        let mapped = points.map { HistoryChartPoint(t: Date(timeIntervalSinceReferenceDate: $0.minute * 60), value: $0.value) }
        let kept = Set(HistorySeries.downsample(mapped, maxPoints: maxPoints).map(\.t.timeIntervalSinceReferenceDate))
        return points.filter { kept.contains($0.minute * 60) }
    }

    /// Axis tick spacing in minutes for a trip of `minutes`.
    static func axisStride(_ minutes: Double) -> Double {
        switch minutes {
        case ...15: 5
        case ...60: 10
        case ...180: 30
        default: 60
        }
    }
}

/// Trip time-series chart: elapsed-minutes x-axis, a shared scrub selection,
/// lines broken at gaps, shaded gap ranges.
struct TripChart: View {
    var series: TripChartSeries
    var color: Color
    var gradient: [Color]? = nil
    var unit: String
    var digits: Int = 0
    var step: Bool = false
    var showsZero: Bool = false
    var yDomain: ClosedRange<Double>
    var height: CGFloat = 130
    /// Raw scrub position (elapsed minutes), written by this chart's gesture.
    @Binding var scrub: Double?
    /// The scrub resolved once by the parent against the full timeline.
    var selection: TripSelection?

    private var interpolation: InterpolationMethod { step ? .stepEnd : .monotone }

    private var lineStyle: AnyShapeStyle {
        if let gradient { AnyShapeStyle(LinearGradient(colors: gradient, startPoint: .bottom, endPoint: .top)) }
        else { AnyShapeStyle(color) }
    }

    var body: some View {
        let base = yDomain.lowerBound
        let value = series.value(at: selection)
        Chart {
            ForEach(Array(series.gaps.enumerated()), id: \.offset) { _, gap in
                RectangleMark(xStart: .value("Gap start", gap.lowerBound), xEnd: .value("Gap end", gap.upperBound))
                    .foregroundStyle(Color.white.opacity(0.045))
            }
            ForEach(series.points) { p in
                AreaMark(x: .value("Minute", p.minute), yStart: .value("Base", base), yEnd: .value(unit, p.value),
                         series: .value("Segment", p.segment))
                    .interpolationMethod(interpolation)
                    .foregroundStyle(LinearGradient(colors: [color.opacity(0.28), color.opacity(0)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Minute", p.minute), y: .value(unit, p.value), series: .value("Segment", p.segment))
                    .interpolationMethod(interpolation)
                    .foregroundStyle(lineStyle)
                    .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            }
            // Lone samples (a segment of one) would otherwise be invisible.
            ForEach(loneSamples) { p in
                PointMark(x: .value("Minute", p.minute), y: .value(unit, p.value))
                    .foregroundStyle(color)
                    .symbolSize(28)
            }
            if showsZero, yDomain.lowerBound < 0 {
                RuleMark(y: .value("Zero", 0))
                    .foregroundStyle(Color.white.opacity(0.18))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            if let selection {
                let minute = series.sampleMinute(at: selection) ?? selection.minute
                RuleMark(x: .value("Selected", minute))
                    .foregroundStyle(Color.white.opacity(0.3))
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        tooltip(value, selection: selection)
                    }
                if let value {
                    PointMark(x: .value("Selected", minute), y: .value(unit, value))
                        .foregroundStyle(color)
                        .symbolSize(60)
                }
            }
        }
        .chartXScale(domain: 0...max(series.totalMinutes, 1))
        .chartYScale(domain: yDomain)
        .chartXSelection(value: $scrub)
        .chartXAxis {
            AxisMarks(values: .stride(by: TripChartSeries.axisStride(series.totalMinutes))) { value in
                AxisValueLabel {
                    if let m = value.as(Double.self) {
                        Text(TripChart.minuteLabel(m))
                    }
                }
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

    private var loneSamples: [TripChartPoint] {
        let counts = Dictionary(grouping: series.points, by: \.segment).mapValues(\.count)
        return series.points.filter { counts[$0.segment] == 1 }
    }

    static func minuteLabel(_ minute: Double) -> String {
        let m = Int(minute.rounded())
        return m >= 120 && m % 60 == 0 ? "\(m / 60)h" : "\(m)m"
    }

    static func tooltipText(_ value: Double?, selection: TripSelection, unit: String, digits: Int) -> String {
        if let value { return "\(VoltaFormat.number(value, digits: digits)) \(unit)" }
        return selection.index == nil ? "No sample" : "Not recorded"
    }

    private func tooltip(_ value: Double?, selection: TripSelection) -> some View {
        VStack(spacing: 1) {
            Text(TripChart.tooltipText(value, selection: selection, unit: unit, digits: digits))
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(value == nil ? HistoryTheme.secondary : .white)
            Text(TripChart.minuteLabel(selection.sampleMinute ?? selection.minute))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(HistoryTheme.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(HistoryTheme.cardRaised, in: .rect(cornerRadius: 8))
    }
}

enum TripChartDomain {
    /// Tight domain for battery/elevation: padded min…max.
    static func padded(_ values: [Double], minPad: Double = 2) -> ClosedRange<Double> {
        guard let lo = values.min(), let hi = values.max() else { return 0...1 }
        let pad = max(minPad, (hi - lo) * 0.2)
        return (lo - pad)...(hi + pad)
    }

    /// Zero-based domain for speed/power.
    static func zeroBased(_ values: [Double]) -> ClosedRange<Double> {
        let lo = min(0, values.min() ?? 0)
        let hi = max(values.max() ?? 1, lo + 1)
        return lo...(hi + (hi - lo) * 0.1)
    }
}
