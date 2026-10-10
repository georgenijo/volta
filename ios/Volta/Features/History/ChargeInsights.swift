import Foundation

// Display facts for one charging session, derived only from recorded values
// and the user's own electricity rate. No geocoding and no third-party calls.

// MARK: - Place

enum ChargePlace {
    /// Street first (as the server recorded it), then the place name, then the
    /// first component of the address.
    static func title(_ charge: ChargeSummary) -> String {
        if let street = nonEmpty(charge.street) { return street }
        if let place = nonEmpty(charge.placeName) { return place }
        if let address = nonEmpty(charge.address) { return firstComponent(address) }
        return "Unknown location"
    }

    /// "Brand or place · city", without repeating the title.
    static func subtitle(_ charge: ChargeSummary) -> String? {
        let title = title(charge)
        var parts: [String] = []
        if let place = nonEmpty(charge.placeName), !same(place, title) { parts.append(place) }
        if let city = nonEmpty(charge.city) {
            if !same(city, title), !parts.contains(where: { same($0, city) }) { parts.append(city) }
        } else if let address = nonEmpty(charge.address) {
            // No recorded city: show what the address adds beyond the title.
            let components = address.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if let first = components.first, same(first, title) {
                let rest = components.dropFirst().joined(separator: ", ")
                if !rest.isEmpty { parts.append(rest) }
            } else if !same(address, title) {
                parts.append(address)
            }
        }
        if parts.isEmpty, charge.kind == .home { parts.append("Home charger") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    static func firstComponent(_ address: String) -> String {
        let first = address.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return first.isEmpty ? address : first
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        return t
    }

    private static func same(_ a: String, _ b: String) -> Bool { a.caseInsensitiveCompare(b) == .orderedSame }
}

// MARK: - State of charge

/// A start→end SoC bar: the faint track up to the lower level, a filled segment
/// for the charge added. Levels are clamped to 0…100.
struct ChargeSocBar: Equatable {
    var start: Int
    var end: Int

    init?(start: Int?, end: Int?) {
        guard let start, let end else { return nil }
        self.start = min(100, max(0, start))
        self.end = min(100, max(0, end))
    }

    /// Fractions of the full bar.
    var lower: Double { Double(min(start, end)) / 100 }
    var upper: Double { Double(max(start, end)) / 100 }
    /// Percentage points added (negative if the level fell).
    var delta: Int { end - start }
}

// MARK: - Cost

/// Recorded session cost, or an estimate from the energy added and the user's
/// electricity rate. Price per kWh is always per kWh added to the battery, so a
/// recorded cost and an estimate compare like for like.
struct ChargeCost: Equatable {
    var amount: Double
    var currency: String
    var isEstimated: Bool
    var pricePerKwh: Double?

    static func resolve(_ charge: ChargeSummary, fallbackRate: Double, fallbackCurrency: String) -> ChargeCost? {
        let added = charge.energyAddedKwh.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        if let cost = charge.cost, cost.isFinite, cost >= 0 {
            return ChargeCost(amount: cost, currency: charge.currency ?? fallbackCurrency, isEstimated: false,
                              pricePerKwh: added.map { cost / $0 })
        }
        guard let added, fallbackRate.isFinite, fallbackRate > 0 else { return nil }
        return ChargeCost(amount: added * fallbackRate, currency: fallbackCurrency, isEstimated: true, pricePerKwh: fallbackRate)
    }
}

// MARK: - Energy flow

/// Energy drawn from the grid versus energy that reached the battery.
struct ChargeEnergyFlow: Equatable {
    enum GridSource: Equatable {
        /// `energyFromGridKwh`, measured at the charger.
        case measured
        /// TeslaMate's integrated charger energy (AC sessions only).
        case recorded
        /// Added energy divided by `assumedEfficiency`.
        case estimated
    }

    /// Typical end-to-end charging efficiency used when grid energy wasn't measured.
    static let assumedEfficiency = 0.91

    var addedKwh: Double
    var gridKwh: Double
    var gridSource: GridSource

    var lossKwh: Double { max(0, gridKwh - addedKwh) }
    var lossFraction: Double? { gridKwh > 0 ? lossKwh / gridKwh : nil }
    var efficiency: Double? { gridKwh > 0 ? min(1, addedKwh / gridKwh) : nil }
    var isEstimated: Bool { gridSource == .estimated }

    static func resolve(_ charge: ChargeSummary) -> ChargeEnergyFlow? {
        guard let added = charge.energyAddedKwh, added.isFinite, added > 0 else { return nil }
        if let grid = charge.energyFromGridKwh, grid.isFinite, grid > 0 {
            return ChargeEnergyFlow(addedKwh: added, gridKwh: grid, gridSource: .measured)
        }
        // TeslaMate integrates DC charger power on the battery side, so its
        // "used" figure is only a grid measurement for AC sessions, and only
        // when it is physically plausible (at least the energy added).
        if !charge.fastCharger, let used = charge.energyUsedKwh, used.isFinite, used >= added {
            return ChargeEnergyFlow(addedKwh: added, gridKwh: used, gridSource: .recorded)
        }
        return ChargeEnergyFlow(addedKwh: added, gridKwh: added / assumedEfficiency, gridSource: .estimated)
    }
}

// MARK: - Curve points

/// One plotted value. `segment` changes at every recording gap; charts key
/// their series on it so a line or area never joins across a gap.
struct ChargeCurvePoint: Identifiable, Hashable {
    var id: Int
    var t: Date
    var value: Double
    var segment: Int
}

enum ChargeCurve {
    /// Builds plot points from ONE source: sorted by time, one value per
    /// instant (the last recorded), finite only, clipped to the session window,
    /// and split into segments wherever consecutive samples are further apart
    /// than `gap` or a declared boundary in `breaks` lies between them.
    /// Unsorted or concatenated sources would otherwise make an area mark fold
    /// back in time and draw a stray wedge.
    static func points(_ raw: [(t: Date, value: Double?)], start: Date, end: Date,
                       gap: TimeInterval? = nil, breaks: [ClosedRange<Date>] = []) -> [ChargeCurvePoint] {
        let window = start...max(end, start)
        var byInstant: [Date: Double] = [:]
        for (t, value) in raw {
            guard let value, value.isFinite, window.contains(t) else { continue }
            byInstant[t] = value
        }
        let ordered = byInstant.sorted { $0.key < $1.key }
        let threshold = gap ?? gapThreshold(ordered.map(\.key))
        var result: [ChargeCurvePoint] = []
        var segment = 0
        for (index, entry) in ordered.enumerated() {
            if index > 0 {
                let prior = ordered[index - 1].key
                if entry.key.timeIntervalSince(prior) > threshold
                    || breaks.contains(where: { $0.lowerBound <= entry.key && $0.upperBound >= prior }) {
                    segment += 1
                }
            }
            result.append(ChargeCurvePoint(id: index, t: entry.key, value: entry.value, segment: segment))
        }
        return result
    }

    /// Fleet Telemetry keeps its own segments (gaps, invalid fields, breaks);
    /// this only clips to the session and renumbers.
    static func points(_ series: TelemetryMetricSeries, start: Date, end: Date) -> [ChargeCurvePoint] {
        let window = start...max(end, start)
        var kept: [TelemetryMetricSeries.Point] = []
        for p in series.points where window.contains(p.t) && p.value.isFinite {
            // One value per instant (the last), as for recorded samples.
            if let last = kept.last, last.t == p.t { kept[kept.count - 1] = p } else { kept.append(p) }
        }
        return kept.sorted { $0.t < $1.t }.enumerated().map { index, p in
            ChargeCurvePoint(id: index, t: p.t, value: p.value, segment: p.segment)
        }
    }

    enum Source: Equatable { case telemetry, samples }

    /// Receiver-declared outages, plus instants where the telemetry block
    /// flagged `field` invalid. Recorded samples are split at these so a
    /// fallback chart never draws a line across a known outage, however short.
    static func boundaries(_ telemetry: FleetTelemetrySeries?, field: String) -> [ClosedRange<Date>] {
        guard let telemetry, telemetry.isFleetTelemetry else { return [] }
        let gaps = telemetry.gaps.filter { $0.end >= $0.start }.map { $0.start...$0.end }
        let invalid = telemetry.samples.filter { $0.invalidFields.contains(field) }.map { $0.t...$0.t }
        return gaps + invalid
    }

    /// Seconds actually recorded: the sum of each segment's own span, so time
    /// across a gap does not count as coverage.
    static func coveredSeconds(_ points: [ChargeCurvePoint]) -> TimeInterval {
        zip(points, points.dropFirst()).reduce(0) { total, pair in
            pair.0.segment == pair.1.segment ? total + max(0, pair.1.t.timeIntervalSince(pair.0.t)) : total
        }
    }

    /// Every chart plots exactly one source, never both merged. Fleet
    /// Telemetry wins when the time its segments actually cover is at least
    /// 90% of what is achievable: the session span, or less if the recorded
    /// samples cover less. Samples are the fallback when telemetry is absent
    /// or only covers part of the session (including sparse fragments at the
    /// two ends with nothing in between).
    static func choose(telemetry: [ChargeCurvePoint], samples: [ChargeCurvePoint],
                       start: Date, end: Date) -> (points: [ChargeCurvePoint], source: Source) {
        guard telemetry.count >= 2 else { return (samples, .samples) }
        guard samples.count >= 2 else { return (telemetry, .telemetry) }
        let session = max(0, end.timeIntervalSince(start))
        let achievable = min(session, coveredSeconds(samples))
        return coveredSeconds(telemetry) >= achievable * 0.9 ? (telemetry, .telemetry) : (samples, .samples)
    }

    /// A lapse longer than four typical intervals (at least two minutes) is a gap.
    static func gapThreshold(_ dates: [Date]) -> TimeInterval {
        let intervals = zip(dates, dates.dropFirst()).map { $1.timeIntervalSince($0) }.filter { $0 > 0 }.sorted()
        guard !intervals.isEmpty else { return TripTimeline.gapThreshold }
        return max(TripTimeline.gapThreshold, intervals[intervals.count / 2] * 4)
    }

    /// Min/max-preserving reduction applied per segment, so peaks survive and
    /// segments stay separate.
    static func reduced(_ points: [ChargeCurvePoint], maxPoints: Int = 360) -> [ChargeCurvePoint] {
        guard points.count > maxPoints else { return points }
        let segments = Dictionary(grouping: points, by: \.segment).sorted { $0.key < $1.key }
        var out: [ChargeCurvePoint] = []
        for (segment, run) in segments {
            let budget = max(4, maxPoints * run.count / points.count)
            let kept = HistorySeries.downsample(run.map { HistoryChartPoint(t: $0.t, value: $0.value) }, maxPoints: budget)
            out += kept.map { ChargeCurvePoint(id: 0, t: $0.t, value: $0.value, segment: segment) }
        }
        return out.enumerated().map { index, p in
            var copy = p; copy.id = index; return copy
        }
    }

    /// Zero-based power axis that always contains the recorded peak (no fixed
    /// cap), rounded up to a readable tick.
    static func powerDomain(_ values: [Double], summaryPeak: Double? = nil) -> ClosedRange<Double> {
        let peak = max(values.filter(\.isFinite).max() ?? 0, summaryPeak.flatMap { $0.isFinite ? $0 : nil } ?? 0)
        guard peak > 0 else { return 0...10 }
        let step = tickStep(peak * 1.12)
        return 0...(ceil(peak * 1.12 / step) * step)
    }

    static func tickStep(_ top: Double) -> Double {
        switch top {
        case ..<4: 1
        case ..<12: 2
        case ..<30: 5
        case ..<60: 10
        case ..<150: 25
        case ..<300: 50
        default: 100
        }
    }

    static func peak(_ points: [ChargeCurvePoint]) -> ChargeCurvePoint? {
        points.max { $0.value < $1.value }
    }

    /// At least two live readings above `floor`. With `requireVariation` (DC
    /// sessions) the values must also change: a constant trace there is a
    /// stale reading (e.g. the last AC voltage), not a series.
    static func isMeaningful(_ points: [ChargeCurvePoint], above floor: Double, requireVariation: Bool = true) -> Bool {
        let live = points.filter { $0.value > floor }
        guard live.count >= 2, let lo = live.map(\.value).min(), let hi = live.map(\.value).max() else { return false }
        return !requireVariation || hi - lo > 0.001
    }
}

extension TelemetryMetricSeries {
    /// Only the points (and gaps) inside the session, so a series never runs
    /// into the drive that follows.
    func clipped(start: Date, end: Date) -> TelemetryMetricSeries {
        var copy = self
        let window = start...max(end, start)
        copy.points = points.filter { window.contains($0.t) }
        copy.gaps = gaps.filter { $0.end >= start && $0.start <= end }
        return copy
    }
}
