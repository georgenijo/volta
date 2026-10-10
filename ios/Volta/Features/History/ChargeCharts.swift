import Charts
import SwiftUI

/// The charge curve: power (line + soft fill, left axis) and state of charge
/// (line, right axis) over the session, with the peak labelled. Both series
/// come from one source each and are already sorted, clipped and segmented
/// (`ChargeCurve.points`); every mark is keyed by segment so nothing joins
/// across a gap or folds back in time.
struct ChargeCurveChart: View {
    var power: [ChargeCurvePoint]
    var soc: [ChargeCurvePoint]
    var sessionStart: Date
    var sessionEnd: Date
    var powerColor: Color
    var socColor: Color
    var summaryPeak: Double? = nil
    var gradient: [Color]? = nil
    var height: CGFloat = 200

    @State private var selected: Date?

    private var domain: ClosedRange<Double> { ChargeCurve.powerDomain(power.map(\.value), summaryPeak: summaryPeak) }
    private var top: Double { domain.upperBound }
    private var xDomain: ClosedRange<Date> { TelemetryChartDomain.range(sessionStart: sessionStart, sessionEnd: sessionEnd) }
    private var peak: ChargeCurvePoint? { ChargeCurve.peak(power) }

    private func socY(_ percent: Double) -> Double { min(100, max(0, percent)) / 100 * top }

    private var powerTicks: [Double] {
        let step = ChargeCurve.tickStep(top)
        return Array(stride(from: 0, through: top, by: step))
    }

    private var socTicks: [Double] { [0, 50, 100].map { socY($0) } }

    private var stroke: AnyShapeStyle {
        gradient.map { AnyShapeStyle(LinearGradient(colors: $0, startPoint: .leading, endPoint: .trailing)) } ?? AnyShapeStyle(powerColor)
    }

    private func nearest(_ points: [ChargeCurvePoint], to date: Date) -> ChargeCurvePoint? {
        guard let p = points.min(by: { abs($0.t.timeIntervalSince(date)) < abs($1.t.timeIntervalSince(date)) }),
              abs(p.t.timeIntervalSince(date)) <= TripTimeline.gapThreshold else { return nil }
        return p
    }

    var body: some View {
        let selectedPower = selected.flatMap { nearest(power, to: $0) }
        let selectedSoc = selected.flatMap { nearest(soc, to: $0) }
        Chart {
            ForEach(power) { p in
                AreaMark(x: .value("Time", p.t), y: .value("kW", p.value),
                         series: .value("Series", "power-fill-\(p.segment)"), stacking: .unstacked)
                    .interpolationMethod(.monotone)
                    .foregroundStyle(LinearGradient(colors: [powerColor.opacity(0.22), powerColor.opacity(0.0)],
                                                    startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("Time", p.t), y: .value("kW", p.value), series: .value("Series", "power-\(p.segment)"))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(stroke)
                    .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            }
            ForEach(soc) { p in
                LineMark(x: .value("Time", p.t), y: .value("kW", socY(p.value)), series: .value("Series", "soc-\(p.segment)"))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(socColor)
                    .lineStyle(StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round, dash: [4, 3]))
            }
            if let peak, selected == nil {
                PointMark(x: .value("Time", peak.t), y: .value("kW", peak.value))
                    .foregroundStyle(powerColor)
                    .symbolSize(46)
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .fit(to: .chart))) {
                        Text("\(VoltaFormat.number(peak.value, digits: peak.value >= 20 ? 0 : 1)) kW peak")
                            .font(.system(size: 11, weight: .bold)).monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(HistoryTheme.cardRaised, in: .capsule)
                    }
                    .accessibilityLabel("Peak power")
                    .accessibilityValue("\(VoltaFormat.number(peak.value, digits: 0)) kilowatts at \(peak.t.historyTime)")
            }
            if let selected, selectedPower != nil || selectedSoc != nil {
                RuleMark(x: .value("Selected", (selectedPower ?? selectedSoc)?.t ?? selected))
                    .foregroundStyle(Color.white.opacity(0.28))
                    .annotation(position: .top, spacing: 2, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(spacing: 1) {
                            HStack(spacing: 6) {
                                if let p = selectedPower {
                                    Text("\(VoltaFormat.number(p.value, digits: p.value >= 20 ? 0 : 1)) kW")
                                }
                                if let s = selectedSoc {
                                    Text("\(VoltaFormat.number(s.value, digits: 0))%").foregroundStyle(socColor)
                                }
                            }
                            .font(.system(size: 12, weight: .bold)).monospacedDigit().foregroundStyle(.white)
                            Text(((selectedPower ?? selectedSoc)?.t ?? selected).historyTime)
                                .font(.system(size: 10, weight: .medium)).foregroundStyle(HistoryTheme.secondary)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(HistoryTheme.cardRaised, in: .rect(cornerRadius: 8))
                    }
                if let p = selectedPower {
                    PointMark(x: .value("Time", p.t), y: .value("kW", p.value)).foregroundStyle(powerColor).symbolSize(50)
                }
                if let s = selectedSoc {
                    PointMark(x: .value("Time", s.t), y: .value("kW", socY(s.value))).foregroundStyle(socColor).symbolSize(40)
                }
            }
        }
        .chartYScale(domain: domain)
        .chartXScale(domain: xDomain)
        .chartXSelection(value: $selected)
        .chartXAxis {
            ChargeTimeAxis.marks(start: sessionStart, end: sessionEnd)
        }
        .chartYAxis {
            AxisMarks(position: .leading, values: powerTicks) { value in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [2, 4])).foregroundStyle(Color.white.opacity(0.06))
                AxisValueLabel {
                    if let v = value.as(Double.self) { Text(VoltaFormat.number(v, digits: 0)) }
                }
                .font(.system(size: 10, weight: .medium)).foregroundStyle(HistoryTheme.tertiary)
            }
            AxisMarks(position: .trailing, values: socTicks) { value in
                AxisValueLabel {
                    if let v = value.as(Double.self), top > 0 { Text("\(Int((v / top * 100).rounded()))%") }
                }
                .font(.system(size: 10, weight: .medium)).foregroundStyle(socColor.opacity(0.8))
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Charge curve, power and state of charge over time")
    }
}

/// Battery temperature as step lines (min and max module temperature) with the
/// band between them. Telemetry reports module temperatures as discrete steps,
/// so the line holds each value until the next reading.
struct ChargeTemperatureChart: View {
    var minimum: [ChargeCurvePoint]
    var maximum: [ChargeCurvePoint]
    var unit: String
    var sessionStart: Date
    var sessionEnd: Date
    var height: CGFloat = 130

    @State private var selected: Date?

    struct BandPoint: Identifiable {
        var id: Int
        var t: Date
        var low: Double
        var high: Double
        var segment: Int
    }

    /// Instants where both min and max were recorded, in the same segment.
    static func band(minimum: [ChargeCurvePoint], maximum: [ChargeCurvePoint]) -> [BandPoint] {
        let highs = Dictionary(maximum.map { ($0.t, $0) }, uniquingKeysWith: { _, last in last })
        var band: [BandPoint] = []
        for low in minimum {
            guard let high = highs[low.t] else { continue }
            band.append(BandPoint(id: band.count, t: low.t, low: min(low.value, high.value), high: max(low.value, high.value),
                                  segment: low.segment))
        }
        return band
    }

    private var domain: ClosedRange<Double> { TripChartDomain.padded((minimum + maximum).map(\.value), minPad: 2) }

    var body: some View {
        let band = Self.band(minimum: minimum, maximum: maximum)
        Chart {
            ForEach(band) { p in
                AreaMark(x: .value("Time", p.t), yStart: .value(unit, p.low), yEnd: .value(unit, p.high),
                         series: .value("Series", "band-\(p.segment)"))
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(LinearGradient(colors: [HistoryTheme.red.opacity(0.14), HistoryTheme.blue.opacity(0.14)],
                                                    startPoint: .top, endPoint: .bottom))
            }
            ForEach(maximum) { p in
                LineMark(x: .value("Time", p.t), y: .value(unit, p.value), series: .value("Series", "max-\(p.segment)"))
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(HistoryTheme.red)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            ForEach(minimum) { p in
                LineMark(x: .value("Time", p.t), y: .value(unit, p.value), series: .value("Series", "min-\(p.segment)"))
                    .interpolationMethod(.stepEnd)
                    .foregroundStyle(HistoryTheme.blue)
                    .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
            if let selected, let reading = reading(at: selected) {
                RuleMark(x: .value("Selected", reading.t))
                    .foregroundStyle(Color.white.opacity(0.28))
                    .annotation(position: .top, spacing: 2, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(spacing: 1) {
                            Text(reading.label).font(.system(size: 12, weight: .bold)).monospacedDigit().foregroundStyle(.white)
                            Text(reading.t.historyTime).font(.system(size: 10, weight: .medium)).foregroundStyle(HistoryTheme.secondary)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(HistoryTheme.cardRaised, in: .rect(cornerRadius: 8))
                    }
            }
        }
        .chartYScale(domain: domain)
        .chartXScale(domain: TelemetryChartDomain.range(sessionStart: sessionStart, sessionEnd: sessionEnd))
        .chartXSelection(value: $selected)
        .chartXAxis {
            ChargeTimeAxis.marks(start: sessionStart, end: sessionEnd)
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [2, 4])).foregroundStyle(Color.white.opacity(0.06))
                AxisValueLabel().font(.system(size: 10, weight: .medium)).foregroundStyle(HistoryTheme.tertiary)
            }
        }
        .frame(height: height)
    }

    /// The step value in effect at `date`: the last reading at or before it.
    private func reading(at date: Date) -> (t: Date, label: String)? {
        func held(_ points: [ChargeCurvePoint]) -> ChargeCurvePoint? {
            points.last { $0.t <= date } ?? points.first
        }
        let low = held(minimum), high = held(maximum)
        guard let t = [low?.t, high?.t].compactMap({ $0 }).max() else { return nil }
        let parts = [low.map { "min \(VoltaFormat.number($0.value, digits: 0))°" }, high.map { "max \(VoltaFormat.number($0.value, digits: 0))°" }]
        return (t, parts.compactMap { $0 }.joined(separator: " · "))
    }
}

/// One labelled line in a `ChargeTraceChart`.
struct ChargeTrace: Identifiable {
    var label: String
    var color: Color
    var points: [ChargeCurvePoint]
    var id: String { label }
}

/// Segmented lines (no fill) for secondary charge signals.
struct ChargeTraceChart: View {
    var traces: [ChargeTrace]
    var unit: String
    var digits: Int = 0
    var minPad: Double = 2
    var sessionStart: Date
    var sessionEnd: Date
    var height: CGFloat = 120

    @State private var selected: Date?

    private func nearest(_ points: [ChargeCurvePoint], to date: Date) -> ChargeCurvePoint? {
        guard let p = points.min(by: { abs($0.t.timeIntervalSince(date)) < abs($1.t.timeIntervalSince(date)) }),
              abs(p.t.timeIntervalSince(date)) <= TripTimeline.gapThreshold else { return nil }
        return p
    }

    var body: some View {
        let readings = selected.map { date in
            traces.compactMap { trace in nearest(trace.points, to: date).map { (trace: trace, point: $0) } }
        } ?? []
        Chart {
            ForEach(traces) { trace in
                ForEach(trace.points) { p in
                    LineMark(x: .value("Time", p.t), y: .value(unit, p.value),
                             series: .value("Series", "\(trace.label)-\(p.segment)"))
                        .interpolationMethod(.linear)
                        .foregroundStyle(trace.color)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            }
            if let first = readings.first {
                RuleMark(x: .value("Selected", first.point.t))
                    .foregroundStyle(Color.white.opacity(0.28))
                    .annotation(position: .top, spacing: 2, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(spacing: 1) {
                            HStack(spacing: 6) {
                                ForEach(readings, id: \.trace.id) { reading in
                                    Text("\(VoltaFormat.number(reading.point.value, digits: digits)) \(unit)")
                                        .foregroundStyle(traces.count > 1 ? reading.trace.color : .white)
                                }
                            }
                            .font(.system(size: 12, weight: .bold)).monospacedDigit()
                            Text(first.point.t.historyTime).font(.system(size: 10, weight: .medium)).foregroundStyle(HistoryTheme.secondary)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(HistoryTheme.cardRaised, in: .rect(cornerRadius: 8))
                    }
            }
        }
        .chartYScale(domain: TripChartDomain.padded(traces.flatMap { $0.points.map(\.value) }, minPad: minPad))
        .chartXScale(domain: TelemetryChartDomain.range(sessionStart: sessionStart, sessionEnd: sessionEnd))
        .chartXSelection(value: $selected)
        .chartXAxis {
            ChargeTimeAxis.marks(start: sessionStart, end: sessionEnd)
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1, dash: [2, 4])).foregroundStyle(Color.white.opacity(0.06))
                AxisValueLabel().font(.system(size: 10, weight: .medium)).foregroundStyle(HistoryTheme.tertiary)
            }
        }
        .frame(height: height)
    }
}

/// Start→end state-of-charge bar: a faint track to the start level, the added
/// charge as a lit segment, percent labels at both ends.
struct ChargeSocBarView: View {
    var bar: ChargeSocBar
    var colors: [Color]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                label("\(bar.start)%", caption: "Start")
                Spacer()
                Text(bar.delta >= 0 ? "+\(bar.delta)%" : "\(bar.delta)%")
                    .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                    .foregroundStyle(colors.last ?? HistoryTheme.blue)
                Spacer()
                label("\(bar.end)%", caption: "End", trailing: true)
            }
            GeometryReader { geo in
                let w = geo.size.width
                SweepIn { p in
                    ZStack(alignment: .leading) {
                        Capsule().fill(HistoryTheme.track)
                        Capsule().fill(Color.white.opacity(0.16)).frame(width: max(0, w * bar.lower))
                        Capsule()
                            .fill(LinearGradient(colors: bar.delta >= 0 ? colors : colors.reversed(), startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(8, w * (bar.upper - bar.lower) * p))
                            .offset(x: w * bar.lower)
                            .shadow(color: (colors.last ?? HistoryTheme.blue).opacity(0.5), radius: 6)
                    }
                }
            }
            .frame(height: 10)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery \(bar.start)% to \(bar.end)%")
    }

    private func label(_ value: String, caption: String, trailing: Bool = false) -> some View {
        VStack(alignment: trailing ? .trailing : .leading, spacing: 2) {
            Text(value).font(.system(size: 22, weight: .bold)).fontWidth(.expanded).monospacedDigit().foregroundStyle(.white)
            Text(caption).font(.system(size: 10, weight: .semibold)).tracking(1).textCase(.uppercase).foregroundStyle(HistoryTheme.tertiary)
        }
    }
}

/// Session start, middle and end as x-axis labels, the outer two anchored to
/// the plot edges so they're never truncated.
enum ChargeTimeAxis {
    static func ticks(start: Date, end: Date) -> [Date] {
        let span = end.timeIntervalSince(start)
        guard span > 60 else { return [start] }
        return [start, start.addingTimeInterval(span / 2), end]
    }

    @AxisContentBuilder
    static func marks(start: Date, end: Date) -> some AxisContent {
        AxisMarks(values: ticks(start: start, end: end)) { value in
            AxisValueLabel(format: .dateTime.hour().minute(),
                           anchor: value.index == 0 ? .topLeading : value.index == value.count - 1 ? .topTrailing : .top)
                .font(.system(size: 10, weight: .medium)).foregroundStyle(HistoryTheme.tertiary)
        }
    }
}
