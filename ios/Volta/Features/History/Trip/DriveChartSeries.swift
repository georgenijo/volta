import Foundation

/// Signals the drive detail charts plot. Raw values are the `DriveCharts.series` keys.
enum DriveChartMetric: String, CaseIterable, Sendable {
    case energyRemainingKwh, batteryLevel, batteryTempMinC, batteryTempMaxC, insideTempC, outsideTempC
    case ratedRangeKm, speedKph, elevationM, powerKw
}

/// Builds the continuous step series the drive detail charts draw.
///
/// Every series is seeded at the drive start with its first known value, holds
/// each value until the next change (forward-fill) and runs to the drive end.
/// A missing sample never breaks the line: the last value simply carries on.
/// Points are kept only where the value changes, plus the final point at `end`.
enum DriveChartSeries {
    typealias Point = DriveCharts.Point

    /// A step series from unordered, possibly sparse samples.
    ///
    /// - Non-finite and nil values are ignored; a series with none is empty.
    /// - The seed (at `start`) is the latest value at or before `start`, else
    ///   the first value after it.
    /// - Samples after `end` are ignored. Samples sharing a timestamp resolve to
    ///   the last one in input order.
    static func stepSeries(_ samples: [(t: Date, v: Double?)], start: Date, end: Date) -> [Point] {
        let known = samples.enumerated()
            .compactMap { offset, sample -> (Date, Double, Int)? in
                guard let v = sample.v, v.isFinite else { return nil }
                return (sample.t, v, offset)
            }
            .sorted { ($0.0, $0.2) < ($1.0, $1.2) }
        guard !known.isEmpty else { return [] }
        let finish = max(start, end)
        let seed = known.last(where: { $0.0 <= start })?.1 ?? known[0].1
        var out = [Point(t: start, v: seed)]
        var index = 0
        while index < known.count {
            let (t, _, _) = known[index]
            // The last row at this timestamp wins.
            var last = index
            while last + 1 < known.count, known[last + 1].0 == t { last += 1 }
            let v = known[last].1
            index = last + 1
            guard t > start, t <= finish else { continue }
            if v != out[out.count - 1].v { out.append(Point(t: t, v: v)) }
        }
        if let tail = out.last, tail.t < finish { out.append(Point(t: finish, v: tail.v)) }
        return out
    }

    /// Re-normalizes a series that is already in step form (e.g. from the server).
    static func normalized(_ points: [Point], start: Date, end: Date) -> [Point] {
        stepSeries(points.map { ($0.t, Optional($0.v)) }, start: start, end: end)
    }

    /// The chart series for a drive. Server `charts` win metric by metric; any
    /// metric the server didn't send is built from the telemetry samples or the
    /// legacy path, whichever recorded more values for it. Empty metrics are omitted.
    static func build(_ detail: DriveDetail) -> DriveCharts {
        let s = detail.summary
        let start = detail.charts?.start ?? s.start
        let end = detail.charts?.end ?? s.end ?? s.start.addingTimeInterval(s.durationMin * 60)
        var series: [String: [Point]] = [:]
        for metric in DriveChartMetric.allCases {
            if let server = detail.charts?.series[metric.rawValue] {
                let points = normalized(server, start: start, end: end)
                if !points.isEmpty { series[metric.rawValue] = points; continue }
            }
            let telemetry = (detail.telemetry?.samples ?? []).map { ($0.t, telemetryValue($0, metric)) }
            let path = detail.path.map { ($0.t, pathValue($0, metric)) }
            let telemetryCount = telemetry.count { $0.1?.isFinite == true }
            let pathCount = path.count { $0.1?.isFinite == true }
            let samples = telemetryCount >= pathCount ? telemetry : path
            let points = stepSeries(samples, start: start, end: end)
            if !points.isEmpty { series[metric.rawValue] = points }
        }
        return DriveCharts(start: start, end: end, series: series)
    }

    static func telemetryValue(_ sample: FleetTelemetrySample, _ metric: DriveChartMetric) -> Double? {
        switch metric {
        case .energyRemainingKwh: sample.energyRemainingKwh
        case .batteryLevel: sample.batteryLevel
        case .batteryTempMinC: sample.batteryTempMinC
        case .batteryTempMaxC: sample.batteryTempMaxC
        case .insideTempC: sample.insideTempC
        case .outsideTempC: sample.outsideTempC
        case .ratedRangeKm: sample.ratedRangeKm
        case .speedKph: sample.speedKph
        case .elevationM: sample.elevationM
        case .powerKw: sample.powerKw
        }
    }

    static func pathValue(_ point: DrivePoint, _ metric: DriveChartMetric) -> Double? {
        switch metric {
        case .speedKph: point.speedKph
        case .powerKw: point.powerKw
        case .elevationM: point.elevationM
        case .batteryLevel: point.batteryLevel.map(Double.init)
        default: nil
        }
    }

    /// The step value at `t`: the last point at or before it (the first point before the series starts).
    static func value(_ points: [Point], at t: Date) -> Double? {
        guard let first = points.first else { return nil }
        var lo = 0, hi = points.count - 1
        guard t >= first.t else { return first.v }
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if points[mid].t <= t { lo = mid } else { hi = mid - 1 }
        }
        return points[lo].v
    }
}

/// Range efficiency: how the rated range actually fell against an ideal that
/// loses exactly the distance driven.
struct DriveRangeEfficiency: Equatable, Sendable {
    struct Point: Equatable, Sendable {
        var t: Date
        var actualKm: Double
        var idealKm: Double
    }

    var points: [Point]
    /// Distance ÷ rated range used × 100; nil when the range did not drop.
    var percent: Double?

    /// - Parameters:
    ///   - range: rated range step series (km).
    ///   - speed: speed step series (km/h), used for the shape of distance over time.
    ///   - distanceKm: the drive's odometer distance.
    ///
    /// Distance so far integrates the speed step series, then scales it so it
    /// ends at the odometer distance: speed gives the shape (when the car was
    /// moving), the odometer gives the total. Without a speed series the
    /// distance grows linearly with time. Nil without at least one range value.
    static func compute(range: [DriveCharts.Point], speed: [DriveCharts.Point], distanceKm: Double,
                        start: Date, end: Date, step: TimeInterval = 15) -> DriveRangeEfficiency? {
        guard let startRange = range.first?.v, let endRange = range.last?.v, end > start else { return nil }
        let total = end.timeIntervalSince(start)
        var times = Set(range.map(\.t))
        var t = start
        while t < end { times.insert(t); t = t.addingTimeInterval(step) }
        times.insert(end)
        let sorted = times.filter { $0 >= start && $0 <= end }.sorted()

        // Cumulative integral of the step speed (km/h × h) at each time.
        var integral: [Double] = []
        var acc = 0.0
        var previous = start
        for time in sorted {
            if !speed.isEmpty, time > previous {
                acc += integrate(speed, from: previous, to: time)
            }
            integral.append(acc)
            previous = time
        }
        let integralTotal = acc
        let odometer = max(0, distanceKm.isFinite ? distanceKm : 0)
        let points = zip(sorted, integral).map { time, done -> Point in
            let fraction = integralTotal > 0 ? done / integralTotal : time.timeIntervalSince(start) / total
            let driven = odometer * fraction
            return Point(t: time, actualKm: DriveChartSeries.value(range, at: time) ?? startRange, idealKm: startRange - driven)
        }
        let used = startRange - endRange
        return DriveRangeEfficiency(points: points, percent: used > 0 && odometer > 0 ? odometer / used * 100 : nil)
    }

    /// ∫ speed dt over [a, b] in km, for a step series in km/h.
    private static func integrate(_ speed: [DriveCharts.Point], from a: Date, to b: Date) -> Double {
        var sum = 0.0
        var cursor = a
        var value = DriveChartSeries.value(speed, at: a) ?? 0
        for p in speed where p.t > a && p.t < b {
            sum += max(0, value) * p.t.timeIntervalSince(cursor) / 3600
            cursor = p.t
            value = p.v
        }
        sum += max(0, value) * b.timeIntervalSince(cursor) / 3600
        return sum
    }
}
