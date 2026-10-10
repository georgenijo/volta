import Charts
import Foundation
import SwiftUI

extension FleetTelemetrySeries {
    var isFleetTelemetry: Bool { source == "fleet_telemetry" }

    /// GPS-bearing telemetry only. Slow signal-only rows never receive a made-up
    /// coordinate. A known receiver gap marks the first position after it as a
    /// route break, even if its timestamp is close to the previous position.
    func drivePath() -> [DrivePoint] {
        guard isFleetTelemetry else { return [] }
        let positioned = samples.filter {
            guard let lat = $0.latitude, let lon = $0.longitude else { return false }
            return lat.isFinite && lon.isFinite && (-90...90).contains(lat) && (-180...180).contains(lon)
        }.sorted { $0.t < $1.t }
        return positioned.enumerated().map { index, sample in
            let previous = index > 0 ? positioned[index - 1].t : nil
            let crossesGap = previous.map { prior in
                gaps.contains { $0.start <= sample.t && $0.end >= prior }
            } ?? false
            let level = sample.batteryLevel.flatMap { value in
                value.isFinite && (0...100).contains(value) ? Int(value.rounded()) : nil
            }
            return DrivePoint(
                t: sample.t,
                latitude: sample.latitude!,
                longitude: sample.longitude!,
                speedKph: sample.speedKph,
                powerKw: sample.powerKw,
                elevationM: sample.elevationM,
                batteryLevel: level,
                routeBreakBefore: sample.routeBreakBefore || crossesGap
            )
        }
    }

    /// A telemetry field replaces the legacy field only when the bounded data
    /// actually returned to this client spans the same time within one legacy
    /// sample interval (capped at the gap threshold), is at
    /// least as dense, and has no worse gaps. Older servers have no coverage
    /// proof, so their telemetry remains supplemental.
    func shouldPrefer(metric key: String, over legacy: RecordedMetricCoverage) -> Bool {
        guard isFleetTelemetry, !truncated,
              let envelope = coverage, let candidate = envelope.metrics[key],
              candidate.returnedSampleCount > 0, !candidate.truncated,
              envelope.sessionEnd > envelope.sessionStart else { return false }
        let sessionSeconds = envelope.sessionEnd.timeIntervalSince(envelope.sessionStart)
        let candidateCoverage = candidate.end.timeIntervalSince(candidate.start) / sessionSeconds
        guard candidateCoverage >= 0.95 else { return false }
        let returnedSeries = TelemetryMetricSeries(self, field: invalidField(for: key)) {
            metricValue(key, in: $0)
        }
        let returnedDates = returnedSeries.points.map(\.t)
        let returnedCoveredSeconds = Dictionary(grouping: returnedSeries.points, by: \.segment).values.reduce(0.0) { total, run in
            total + zip(run, run.dropFirst()).reduce(0.0) { $0 + $1.1.t.timeIntervalSince($1.0.t) }
        }
        // Fail closed if the payload and its coverage proof disagree. This also
        // guarantees that each metric's advertised source boundaries survived
        // bounded row selection.
        guard returnedDates.count == candidate.returnedSampleCount,
              let returnedStart = returnedDates.first, let returnedEnd = returnedDates.last,
              abs(returnedStart.timeIntervalSince(candidate.start)) <= 0.001,
              abs(returnedEnd.timeIntervalSince(candidate.end)) <= 0.001 else { return false }
        guard legacy.count > 0 else { return true }

        let tolerance = 0.001
        let boundaryTolerance = min(legacy.sampleIntervalSeconds ?? 0, TripTimeline.gapThreshold)
        let leadingShortfall = max(0, candidate.start.timeIntervalSince(legacy.start))
        let trailingShortfall = max(0, legacy.end.timeIntervalSince(candidate.end))
        // Independent recording cadences rarely share exact endpoints. Accept
        // only the actual boundary loss within one legacy interval; this does
        // not excuse any loss of covered time inside the candidate span.
        let returnedDensity = Double(returnedDates.count)
            / max(sessionSeconds / 60, 1.0 / 60)
        guard leadingShortfall <= boundaryTolerance + tolerance,
              trailingShortfall <= boundaryTolerance + tolerance,
              returnedCoveredSeconds + leadingShortfall + trailingShortfall + tolerance >= legacy.coveredSeconds,
              returnedDensity + tolerance >= legacy.densityPerMinute,
              candidate.gapCount <= legacy.gapCount else { return false }
        switch (candidate.returnedMaxIntervalSeconds ?? candidate.maxIntervalSeconds, legacy.maxIntervalSeconds) {
        case let (candidate?, legacy?): return candidate <= legacy + tolerance
        case (nil, nil): return true
        case (nil, _?): return candidate.returnedSampleCount <= 1 && legacy.count <= 1
        case (_?, nil): return false
        }
    }

    private func metricValue(_ key: String, in sample: FleetTelemetrySample) -> Double? {
        switch key {
        case "latitude": sample.latitude
        case "longitude": sample.longitude
        case "speedKph": sample.speedKph
        case "powerKw": sample.powerKw
        case "elevationM": sample.elevationM
        case "batteryLevel": sample.batteryLevel
        case "energyRemainingKwh": sample.energyRemainingKwh
        case "batteryTempMinC": sample.batteryTempMinC
        case "batteryTempMaxC": sample.batteryTempMaxC
        case "insideTempC": sample.insideTempC
        case "outsideTempC": sample.outsideTempC
        case "voltage": sample.voltage
        case "currentA": sample.currentA
        case "ratedRangeKm": sample.ratedRangeKm
        case "longitudinalAccelerationMps2": sample.longitudinalAccelerationMps2
        case "lateralAccelerationMps2": sample.lateralAccelerationMps2
        default: nil
        }
    }

    private func invalidField(for key: String) -> String? {
        switch key {
        case "latitude", "longitude": "Location"
        case "speedKph": "VehicleSpeed"
        case "powerKw": "Power"
        case "batteryLevel": "BatteryLevel"
        case "energyRemainingKwh": "EnergyRemaining"
        case "batteryTempMinC": "ModuleTempMin"
        case "batteryTempMaxC": "ModuleTempMax"
        case "insideTempC": "InsideTemp"
        case "outsideTempC": "OutsideTemp"
        case "voltage": "ChargerVoltage"
        case "currentA": "ChargeAmps"
        case "ratedRangeKm": "RatedRange"
        case "longitudinalAccelerationMps2": "LongitudinalAcceleration"
        case "lateralAccelerationMps2": "LateralAcceleration"
        default: nil
        }
    }
}

/// Comparable facts derived from the exact legacy values available on device.
/// Dates include lead/tail coverage; max interval catches sparse fragments even
/// when neither source declares a receiver gap.
struct RecordedMetricCoverage: Equatable, Sendable {
    var start: Date
    var end: Date
    var count: Int
    var densityPerMinute: Double
    var maxIntervalSeconds: Double?
    /// Median positive observation interval, independent of rare large gaps.
    var sampleIntervalSeconds: Double?
    var gapCount: Int
    var coveredSeconds: TimeInterval

    static func values(in timeline: TripTimeline, value: (DrivePoint) -> Double?) -> Self {
        let signal = TripSignal(timeline, value: value)
        let dates = timeline.points.indices.compactMap { index in
            signal.values[index] == nil ? nil : timeline.points[index].t
        }
        return make(dates, sessionSeconds: timeline.spanSeconds, gapCount: signal.gapRanges.count,
                    coveredSeconds: signal.coveredSeconds)
    }

    static func dates(_ dates: [Date], sessionStart: Date, sessionEnd: Date) -> Self {
        let ordered = dates.sorted()
        let covered = zip(ordered, ordered.dropFirst()).reduce(0.0) {
            let interval = $1.1.timeIntervalSince($1.0)
            return $0 + (interval <= TripTimeline.gapThreshold ? interval : 0)
        }
        return make(ordered, sessionSeconds: max(0, sessionEnd.timeIntervalSince(sessionStart)),
                    gapCount: dateGapCount(ordered, sessionStart: sessionStart, sessionEnd: sessionEnd),
                    coveredSeconds: covered)
    }

    private static func make(_ dates: [Date], sessionSeconds: TimeInterval, gapCount: Int,
                             coveredSeconds: TimeInterval) -> Self {
        let ordered = dates.sorted()
        let origin = ordered.first ?? .distantFuture
        let end = ordered.last ?? .distantPast
        let intervals = zip(ordered, ordered.dropFirst()).map { $1.timeIntervalSince($0) }
        let positiveIntervals = intervals.filter { $0 > 0 }.sorted()
        let cadence: Double?
        if positiveIntervals.isEmpty {
            cadence = nil
        } else {
            let middle = positiveIntervals.count / 2
            cadence = positiveIntervals.count.isMultiple(of: 2)
                ? (positiveIntervals[middle - 1] + positiveIntervals[middle]) / 2
                : positiveIntervals[middle]
        }
        return Self(start: origin, end: end, count: ordered.count,
                    densityPerMinute: Double(ordered.count) / max(sessionSeconds / 60, 1.0 / 60),
                    maxIntervalSeconds: intervals.max(), sampleIntervalSeconds: cadence,
                    gapCount: gapCount, coveredSeconds: coveredSeconds)
    }

    private static func dateGapCount(_ dates: [Date], sessionStart: Date, sessionEnd: Date) -> Int {
        guard let first = dates.first, let last = dates.last else { return 0 }
        var count = first.timeIntervalSince(sessionStart) > TripTimeline.gapThreshold ? 1 : 0
        count += zip(dates, dates.dropFirst()).count { $1.timeIntervalSince($0) > TripTimeline.gapThreshold }
        if sessionEnd.timeIntervalSince(last) > TripTimeline.gapThreshold { count += 1 }
        return count
    }
}

/// One telemetry signal at its own cadence. Missing values, explicit route
/// breaks, declared receiver gaps, and unexplained intervals over two minutes
/// all end a segment. Other signals' rows do not interrupt this signal's own
/// cadence; nil is never filled or emitted as a value.
struct TelemetryMetricSeries: Equatable, Sendable {
    struct Point: Identifiable, Equatable, Sendable {
        var id: Int
        var t: Date
        var value: Double
        var segment: Int
    }

    var points: [Point]
    var gaps: [FleetTelemetryGap]
    var downsampled: Bool
    var truncated: Bool

    init(_ telemetry: FleetTelemetrySeries?, field: String? = nil,
         value: (FleetTelemetrySample) -> Double?) {
        guard let telemetry, telemetry.isFleetTelemetry else {
            points = []; gaps = []; downsampled = false; truncated = false; return
        }
        let samples = telemetry.samples.enumerated().sorted {
            $0.element.t == $1.element.t ? $0.offset < $1.offset : $0.element.t < $1.element.t
        }
        var result: [Point] = []
        var segment = 0
        var previousRecorded: Date?
        var invalidSinceRecorded = false
        for (_, sample) in samples {
            if let field, sample.invalidFields.contains(field) {
                if previousRecorded != nil { invalidSinceRecorded = true }
                continue
            }
            guard let raw = value(sample), raw.isFinite else {
                continue
            }
            let crossesGap = previousRecorded.map { prior in
                telemetry.gaps.contains { $0.start <= sample.t && $0.end >= prior }
            } ?? false
            if previousRecorded != nil,
               invalidSinceRecorded || sample.routeBreakBefore || crossesGap
                || sample.t.timeIntervalSince(previousRecorded!) > TripTimeline.gapThreshold {
                segment += 1
            }
            result.append(Point(id: result.count, t: sample.t, value: raw, segment: segment))
            previousRecorded = sample.t
            invalidSinceRecorded = false
        }
        points = result
        gaps = telemetry.gaps
        downsampled = telemetry.downsampled
        truncated = telemetry.truncated
    }

    var values: [Double] { points.map(\.value) }
    var isEmpty: Bool { points.isEmpty }
    var segmentCount: Int { Set(points.map(\.segment)).count }

    /// The chart may select only a nearby recorded value, and never a value
    /// across a receiver-declared gap.
    func nearestPoint(to date: Date, maxDistance: TimeInterval = TripTimeline.gapThreshold) -> Point? {
        guard !gaps.contains(where: { $0.start <= date && date <= $0.end }),
              let nearest = points.min(by: {
                  abs($0.t.timeIntervalSince(date)) < abs($1.t.timeIntervalSince(date))
              }),
              abs(nearest.t.timeIntervalSince(date)) <= maxDistance else { return nil }
        return nearest
    }
}

struct TelemetryTrace {
    var label: String
    var color: Color
    var series: TelemetryMetricSeries
}

enum TelemetryAcceleration {
    /// Symmetric around zero so braking/acceleration and left/right forces are
    /// visually comparable. A minimum ±1 m/s² keeps near-zero traces legible.
    static func domain(_ values: [Double]) -> ClosedRange<Double> {
        let peak = values.filter(\.isFinite).map(abs).max() ?? 0
        let bound = max(1, peak * 1.1)
        return -bound...bound
    }
}

enum TelemetryChartDomain {
    static func range(sessionStart: Date, sessionEnd: Date) -> ClosedRange<Date> {
        sessionStart...max(sessionEnd, sessionStart.addingTimeInterval(1))
    }
}

enum TelemetryChartSelection {
    static func date(minute: Double?, sessionStart: Date) -> Date? {
        minute.map { sessionStart.addingTimeInterval($0 * 60) }
    }

    static func minute(date: Date?, sessionStart: Date, sessionEnd: Date) -> Double? {
        date.map { min(max(0, $0.timeIntervalSince(sessionStart) / 60),
                       max(0, sessionEnd.timeIntervalSince(sessionStart) / 60)) }
    }
}

/// Gap-aware chart for one or more Fleet Telemetry signals. It deliberately
/// does not interpolate across a receiver gap or a lapse beyond the signal's
/// supported cadence.
struct TelemetryMetricChart: View {
    var traces: [TelemetryTrace]
    var unit: String
    var domain: ClosedRange<Double>
    var sessionStart: Date
    var sessionEnd: Date
    var digits: Int = 1
    var showsZero = false
    var height: CGFloat = 140
    /// Drive charts share this elapsed-minute scrub with the map and replay.
    /// Charge charts omit it and keep a local selection.
    var scrub: Binding<Double?>? = nil
    var selectionMinute: Double? = nil

    @State private var localSelected: Date?

    private var xDomain: ClosedRange<Date> {
        TelemetryChartDomain.range(sessionStart: sessionStart, sessionEnd: sessionEnd)
    }

    private var selected: Date? {
        if scrub != nil { return TelemetryChartSelection.date(minute: selectionMinute, sessionStart: sessionStart) }
        return localSelected
    }

    private var chartSelection: Binding<Date?> {
        guard let scrub else { return $localSelected }
        return Binding(get: {
            TelemetryChartSelection.date(minute: selectionMinute, sessionStart: sessionStart)
        }, set: { date in
            scrub.wrappedValue = TelemetryChartSelection.minute(date: date, sessionStart: sessionStart,
                                                                 sessionEnd: sessionEnd)
        })
    }

    private var nearest: (TelemetryTrace, TelemetryMetricSeries.Point)? {
        guard let selected else { return nil }
        return traces.compactMap { trace in trace.series.nearestPoint(to: selected).map { (trace, $0) } }
            .min { abs($0.1.t.timeIntervalSince(selected)) < abs($1.1.t.timeIntervalSince(selected)) }
    }

    var body: some View {
        Chart {
            ForEach(Array(allGaps.enumerated()), id: \.offset) { _, gap in
                RectangleMark(xStart: .value("Gap start", gap.start), xEnd: .value("Gap end", gap.end))
                    .foregroundStyle(Color.white.opacity(0.045))
            }
            ForEach(Array(traces.enumerated()), id: \.offset) { _, trace in
                ForEach(trace.series.points) { point in
                    LineMark(x: .value("Time", point.t), y: .value(unit, point.value),
                             series: .value("Trace", "\(trace.label)-\(point.segment)"))
                        .interpolationMethod(.linear)
                        .foregroundStyle(trace.color)
                        .lineStyle(StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
                }
                ForEach(lonePoints(trace.series)) { point in
                    PointMark(x: .value("Time", point.t), y: .value(unit, point.value))
                        .foregroundStyle(trace.color).symbolSize(28)
                }
            }
            if showsZero, domain.lowerBound < 0 {
                RuleMark(y: .value("Zero", 0)).foregroundStyle(Color.white.opacity(0.18))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }
            if let nearest {
                RuleMark(x: .value("Selected", nearest.1.t)).foregroundStyle(Color.white.opacity(0.3))
                PointMark(x: .value("Selected", nearest.1.t), y: .value(unit, nearest.1.value))
                    .foregroundStyle(nearest.0.color).symbolSize(60)
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(spacing: 1) {
                            Text("\(nearest.0.label) · \(VoltaFormat.number(nearest.1.value, digits: digits)) \(unit)")
                                .font(.system(size: 12, weight: .bold)).foregroundStyle(.white)
                            Text(nearest.1.t.historyTime).font(.system(size: 10, weight: .medium))
                                .foregroundStyle(HistoryTheme.secondary)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(HistoryTheme.cardRaised, in: .rect(cornerRadius: 8))
                    }
            }
        }
        .chartYScale(domain: domain)
        .chartXScale(domain: xDomain)
        .chartXSelection(value: chartSelection)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisValueLabel(format: .voltaClock)
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(HistoryTheme.secondary)
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { _ in
                AxisGridLine(stroke: StrokeStyle(lineWidth: 1)).foregroundStyle(HistoryTheme.hairline)
                AxisValueLabel().font(.system(size: 10, weight: .medium)).foregroundStyle(HistoryTheme.secondary)
            }
        }
        .frame(height: height)
    }

    private var allGaps: [FleetTelemetryGap] {
        var seen = Set<String>()
        return traces.flatMap(\.series.gaps).filter {
            seen.insert("\($0.start.timeIntervalSinceReferenceDate)-\($0.end.timeIntervalSinceReferenceDate)").inserted
        }.sorted { $0.start < $1.start }
    }

    private func lonePoints(_ series: TelemetryMetricSeries) -> [TelemetryMetricSeries.Point] {
        let counts = Dictionary(grouping: series.points, by: \.segment).mapValues(\.count)
        return series.points.filter { counts[$0.segment] == 1 }
    }
}
