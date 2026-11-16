import Foundation

/// Charge curves of several sessions shaped for one chart. Every curve comes
/// from the same single-source choice the session's own page makes
/// (`ChargeCurve.curve`), so a session never looks different here than there.
/// Nothing is joined across a recording gap, nothing is invented where the
/// record is silent, and a session without a recorded curve says so.
enum ChargeComparison {
    /// One colour per slot, so the cap is the number of distinguishable series.
    static let maxSessions = 5

    /// Sessions the screen offers to fill a comparison with, newest first.
    static let suggestionCount = 3

    // MARK: Grouping

    /// The kind groups the screen filters by: home, AC away from home, DC fast
    /// (Tesla and other networks together).
    enum KindGroup: String, CaseIterable, Hashable, Sendable {
        case home, away, fast

        init(_ charge: ChargeSummary) {
            switch ChargerKind(charge) {
            case .home: self = .home
            case .supercharger, .dcFast: self = .fast
            case .publicAC, .unknown: self = .away
            }
        }

        var title: String {
            switch self {
            case .home: "Home"
            case .away: "Away AC"
            case .fast: "DC fast"
            }
        }
    }

    /// Identity of a charging place from what the server recorded: home, then
    /// the place (geofence) name, then the address, then the coordinate to about
    /// 100 m. Nil when nothing was recorded, which matches no other session.
    static func placeKey(_ charge: ChargeSummary) -> String? {
        if charge.isAtHome { return "home" }
        func clean(_ s: String?) -> String? {
            guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
            return t.lowercased()
        }
        if let place = clean(charge.placeName) { return "place:" + place }
        if let address = clean(charge.address) { return "address:" + address }
        if let lat = charge.latitude, let lon = charge.longitude, lat.isFinite, lon.isFinite,
           (-90...90).contains(lat), (-180...180).contains(lon) {
            return "at:" + String(format: "%.3f,%.3f", lat, lon)
        }
        return nil
    }

    enum Filter: Hashable, Sendable {
        case all
        /// Sessions recorded at the anchor session's place.
        case samePlace
        case kind(KindGroup)
    }

    /// `candidates` narrowed by `filter`, newest first. The same-place filter
    /// needs an anchor with a recorded place; without one it matches nothing.
    static func filtered(_ candidates: [ChargeSummary], by filter: Filter, anchor: ChargeSummary?) -> [ChargeSummary] {
        let kept: [ChargeSummary]
        switch filter {
        case .all: kept = candidates
        case .samePlace:
            guard let key = anchor.flatMap(placeKey) else { return [] }
            kept = candidates.filter { placeKey($0) == key }
        case .kind(let group): kept = candidates.filter { KindGroup($0) == group }
        }
        return kept.sorted { $0.start > $1.start }
    }

    /// What "Compare with…" adds to `seed`: the newest finished sessions at the
    /// same place, topped up with the same kind of charger, never the seed itself.
    static func suggestions(for seed: ChargeSummary, among candidates: [ChargeSummary],
                            count: Int = suggestionCount - 1) -> [ChargeSummary] {
        let others = candidates.filter { $0.id != seed.id && $0.end != nil }
        var picked = filtered(others, by: .samePlace, anchor: seed).prefix(count).map { $0 }
        if picked.count < count {
            let ids = Set(picked.map(\.id))
            picked += filtered(others, by: .kind(KindGroup(seed)), anchor: seed)
                .filter { !ids.contains($0.id) }.prefix(count - picked.count)
        }
        return picked
    }

    /// The newest finished sessions of one kind, for Charging Insights' shortcuts.
    static func latest(_ charges: [ChargeSummary], group: KindGroup?, count: Int = suggestionCount) -> [ChargeSummary] {
        let finished = charges.filter { $0.end != nil }
        return Array(filtered(finished, by: group.map(Filter.kind) ?? .all, anchor: nil).prefix(count))
    }

    /// Home against away: the newest home sessions and the newest away ones
    /// (AC or DC), alternating so both sides are present.
    static func homeAgainstAway(_ charges: [ChargeSummary], perSide: Int = 2) -> [ChargeSummary] {
        let finished = charges.filter { $0.end != nil }.sorted { $0.start > $1.start }
        let home = finished.filter(\.isAtHome).prefix(perSide), away = finished.filter { !$0.isAtHome }.prefix(perSide)
        guard !home.isEmpty, !away.isEmpty else { return [] }
        return Array(home) + Array(away)
    }

    /// Adds or removes `session`, keeping selection order (it fixes colours).
    /// Adding past the cap does nothing.
    static func toggled(_ selection: [ChargeSummary], _ session: ChargeSummary, cap: Int = maxSessions) -> [ChargeSummary] {
        if selection.contains(where: { $0.id == session.id }) { return selection.filter { $0.id != session.id } }
        guard selection.count < cap else { return selection }
        return selection + [session]
    }

    /// Colour slots for `ids`: a session keeps its slot while it stays chosen,
    /// and a newly chosen one takes the lowest free slot, so removing one
    /// session never recolours the others.
    static func slots(_ ids: [Int], previous: [Int: Int], count: Int = maxSessions) -> [Int: Int] {
        var result = previous.filter { ids.contains($0.key) && $0.value < count }
        for id in ids where result[id] == nil {
            guard let free = (0..<count).first(where: { !result.values.contains($0) }) else { break }
            result[id] = free
        }
        return result
    }

    /// Unique ids in order, capped: duplicates and anything past the cap are dropped.
    static func capped(_ sessions: [ChargeSummary], cap: Int = maxSessions) -> [ChargeSummary] {
        var seen = Set<Int>()
        return Array(sessions.filter { seen.insert($0.id).inserted }.prefix(cap))
    }

    // MARK: Curves

    /// One plotted value: x is charge level in percent or minutes since the
    /// session began. `segment` changes at every break; marks key on it.
    struct Point: Hashable, Sendable, Identifiable {
        var id: Int
        var x: Double
        var kW: Double
        var segment: Int
    }

    /// A power reading with the charge level the car had at that moment.
    struct Paired: Hashable, Sendable {
        var t: Date
        var soc: Double
        var kW: Double
        var segment: Int
    }

    /// One session's comparable curve.
    struct SessionCurve: Hashable, Sendable {
        /// Mean power at each whole percent; empty without charge-level readings.
        var bySoc: [Point]
        /// Power against minutes since the session began, reduced for drawing.
        var byTime: [Point]
        var paired: [Paired]
        /// The recorded power and charge-level series, for the window figures.
        var power: [ChargeCurvePoint] = []
        var soc: [ChargeCurvePoint] = []
        var peakKw: Double?
        var socAtPeak: Double?
        var source: ChargeCurve.Source
        var hasPower: Bool { byTime.count >= 2 }
        var hasSoc: Bool { bySoc.count >= 2 }
        var socRange: ClosedRange<Double>? {
            guard let lo = paired.map(\.soc).min(), let hi = paired.map(\.soc).max(), hi > lo else { return nil }
            return lo...hi
        }
    }

    /// Readings no further than this from a power sample may give its charge level.
    static let pairWindow: TimeInterval = TripTimeline.gapThreshold
    /// Missing whole percents larger than this split a line instead of bridging it.
    static let maxPercentStep = 3

    static func curve(_ detail: ChargeDetail) -> SessionCurve {
        let summary = detail.summary
        let start = summary.start, end = summary.end ?? summary.start.addingTimeInterval(summary.durationMin * 60)
        let power = ChargeCurve.curve(telemetry: detail.telemetry, samples: detail.samples, field: "Power", start: start, end: end,
                                      telemetryValue: { $0.powerKw }, sampleValue: { $0.powerKw })
        let soc = ChargeCurve.curve(telemetry: detail.telemetry, samples: detail.samples, field: "BatteryLevel", start: start, end: end,
                                    telemetryValue: { $0.batteryLevel }, sampleValue: { $0.batteryLevel.map(Double.init) })
        let paired = pair(power: power.points, soc: soc.points)
        let peak = ChargeCurve.peak(power.points)
        let socAtPeak = peak.flatMap { ChargeCurve.socAtPeak(power: power.points, soc: soc.points, shownPeak: $0.value) }
        let byTime = ChargeCurve.reduced(power.points, maxPoints: 240).map {
            Point(id: $0.id, x: $0.t.timeIntervalSince(start) / 60, kW: $0.value, segment: $0.segment)
        }
        return SessionCurve(bySoc: binned(paired), byTime: byTime, paired: paired, power: power.points, soc: soc.points, peakKw: peak?.value,
                            socAtPeak: socAtPeak, source: power.source)
    }

    /// Each power reading with the charge level at that instant: linear between
    /// the readings just before and just after it, when both lie in one unbroken
    /// stretch of charge-level readings and the nearer is within `pairWindow`.
    /// A power reading in a charge-level gap gets no level and is left out.
    /// Segments renumber whenever either series' segment changes.
    static func pair(power: [ChargeCurvePoint], soc: [ChargeCurvePoint], window: TimeInterval = pairWindow) -> [Paired] {
        guard soc.count >= 2 else { return [] }
        var result: [Paired] = []
        var lastKey: (Int, Int)? = nil, segment = -1
        var j = 0
        for p in power {
            while j + 1 < soc.count && soc[j + 1].t <= p.t { j += 1 }
            let before = soc[j]
            guard before.t <= p.t else { continue }
            let after = j + 1 < soc.count ? soc[j + 1] : nil
            let level: Double
            if before.t == p.t {
                level = before.value
            } else if let after, after.segment == before.segment {
                guard min(p.t.timeIntervalSince(before.t), after.t.timeIntervalSince(p.t)) <= window else { continue }
                let f = p.t.timeIntervalSince(before.t) / after.t.timeIntervalSince(before.t)
                level = before.value + (after.value - before.value) * f
            } else {
                continue
            }
            let key = (p.segment, before.segment)
            if lastKey.map({ $0 != key }) ?? true { segment += 1; lastKey = key }
            result.append(Paired(t: p.t, soc: min(100, max(0, level)), kW: p.value, segment: segment))
        }
        return result
    }

    /// Mean power per whole percent, per unbroken stretch, in charge-level
    /// order. A jump of more than `maxPercentStep` percents starts a new line.
    static func binned(_ paired: [Paired]) -> [Point] {
        var out: [Point] = []
        var segment = -1
        let runs: [Int: [Paired]] = Dictionary(grouping: paired, by: \.segment)
        for key in runs.keys.sorted() {
            let byPercent: [Int: [Paired]] = Dictionary(grouping: runs[key] ?? []) { (p: Paired) -> Int in Int(p.soc.rounded(.down)) }
            var bins: [(percent: Int, kW: Double)] = []
            for (percent, readings) in byPercent {
                let total: Double = readings.reduce(0) { $0 + $1.kW }
                bins.append((percent, total / Double(readings.count)))
            }
            bins.sort { $0.percent < $1.percent }
            var previous: Int? = nil
            for bin in bins {
                if previous.map({ bin.percent - $0 > maxPercentStep }) ?? true { segment += 1 }
                out.append(Point(id: out.count, x: Double(bin.percent), kW: bin.kW, segment: segment))
                previous = bin.percent
            }
        }
        return out
    }

    // MARK: Comparing

    /// The charge-level window every curve with charge levels covers, inset to
    /// whole multiples of five. Nil when fewer than two such curves overlap by
    /// at least ten points.
    static func commonWindow(_ curves: [SessionCurve]) -> ClosedRange<Int>? {
        let ranges = curves.compactMap(\.socRange)
        guard ranges.count >= 2, let lo = ranges.map(\.lowerBound).max(), let hi = ranges.map(\.upperBound).min() else { return nil }
        let start = Int((lo / 5).rounded(.up)) * 5, end = Int((hi / 5).rounded(.down)) * 5
        return end - start >= 10 ? start...end : nil
    }

    /// One session's pass through a charge window: when it crossed the lower
    /// and upper levels (each interpolated between the readings either side)
    /// and the energy delivered in between.
    struct WindowSpan: Hashable, Sendable {
        var start: Date
        var end: Date
        var energyKWh: Double
        var minutes: Double { end.timeIntervalSince(start) / 60 }
        /// Power averaged over the time spent in the window, not over percents:
        /// a session that lingers at low power counts that time.
        var averageKw: Double? {
            let hours = end.timeIntervalSince(start) / 3600
            return hours > 0 ? energyKWh / hours : nil
        }
    }

    /// The span of one session across `window`. The crossings come from the
    /// charge-level readings (interpolated between the readings either side),
    /// and the energy from every power reading between them, so sparse charge
    /// levels never thin out the power that is averaged. Nil unless both
    /// series are recorded without a break from crossing to crossing (a gap
    /// anywhere inside, even one that skips no percent, leaves the figures
    /// unknown). A crossing at the very first reading counts only when that
    /// reading is exactly at the level.
    static func span(power: [ChargeCurvePoint], soc: [ChargeCurvePoint], across window: ClosedRange<Int>) -> WindowSpan? {
        let lo = Double(window.lowerBound), hi = Double(window.upperBound)
        guard hi > lo, let k = soc.firstIndex(where: { $0.value >= lo }), let m = soc[k...].firstIndex(where: { $0.value >= hi }),
              let start = crossing(soc, at: k, level: lo), let end = crossing(soc, at: m, level: hi), end > start else { return nil }
        // Charge level unbroken from the reading that fixes the lower crossing
        // (the one before `k` only when the level is interpolated) to the upper.
        let first = soc[k].value == lo ? k : k - 1
        guard soc[first...m].allSatisfy({ $0.segment == soc[first].segment }) else { return nil }
        // Power unbroken over the same time, with a reading at or beyond each end.
        guard let p0 = power.lastIndex(where: { $0.t <= start }), let p1 = power.firstIndex(where: { $0.t >= end }), p0 < p1,
              power[p0...p1].allSatisfy({ $0.segment == power[p0].segment }) else { return nil }
        func kW(at t: Date) -> Double {
            guard let i = power.lastIndex(where: { $0.t <= t }) else { return power[p0].value }
            guard power[i].t < t, i + 1 < power.count else { return power[i].value }
            let a = power[i], b = power[i + 1]
            return a.value + (b.value - a.value) * t.timeIntervalSince(a.t) / b.t.timeIntervalSince(a.t)
        }
        // Trapezoids from the lower crossing, through every power reading inside, to the upper one.
        let inside = power[p0...p1].filter { $0.t > start && $0.t < end }.map { (t: $0.t, kW: $0.value) }
        let path = [(t: start, kW: kW(at: start))] + inside + [(t: end, kW: kW(at: end))]
        let energy = zip(path, path.dropFirst()).reduce(0.0) { total, step in
            total + (step.0.kW + step.1.kW) / 2 * step.1.t.timeIntervalSince(step.0.t) / 3600
        }
        return WindowSpan(start: start, end: end, energyKWh: energy)
    }

    static func span(_ curve: SessionCurve, across window: ClosedRange<Int>) -> WindowSpan? {
        span(power: curve.power, soc: curve.soc, across: window)
    }

    /// When the charge level reached `level`: reading `index` (the first at
    /// or above it) when exactly at it, else interpolated from the one before
    /// in the same stretch. Nil when the level was passed before the record began.
    private static func crossing(_ soc: [ChargeCurvePoint], at index: Int, level: Double) -> Date? {
        let after = soc[index]
        if after.value == level { return after.t }
        guard index > 0 else { return nil }
        let before = soc[index - 1]
        guard before.segment == after.segment, after.value > before.value else { return nil }
        let f = (level - before.value) / (after.value - before.value)
        return before.t.addingTimeInterval(after.t.timeIntervalSince(before.t) * f)
    }

    /// Time-weighted mean power across `window`; nil when the window is not
    /// covered in one unbroken stretch.
    static func averageKw(_ curve: SessionCurve, in window: ClosedRange<Int>) -> Double? {
        span(curve, across: window)?.averageKw
    }

    /// Minutes from the lower to the upper crossing; nil when not covered in
    /// one unbroken stretch.
    static func minutes(_ curve: SessionCurve, across window: ClosedRange<Int>) -> Double? {
        span(curve, across: window)?.minutes
    }

    // MARK: Axes

    enum Axis: String, CaseIterable, Hashable, Sendable {
        case soc = "Charge %", time = "Time"
    }

    /// The x span of the drawn curves: charge level padded out to tens, or
    /// zero to the longest session's minutes.
    static func xDomain(_ curves: [SessionCurve], axis: Axis) -> ClosedRange<Double> {
        let xs = curves.flatMap { axis == .soc ? $0.bySoc.map(\.x) : $0.byTime.map(\.x) }
        guard let lo = xs.min(), let hi = xs.max() else { return axis == .soc ? 0...100 : 0...60 }
        switch axis {
        case .soc:
            let start = max(0, (lo / 10).rounded(.down) * 10), end = min(100, (hi / 10).rounded(.up) * 10)
            return start...max(end, start + 10)
        case .time:
            // Rounded up to a whole tick so the last tick is the axis end.
            let top = max(hi, 1), step = timeStep(top)
            return 0...((top / step).rounded(.up) * step)
        }
    }

    private static let timeSteps: [Double] = [5, 10, 15, 20, 30, 60, 120, 240]
    private static func timeStep(_ span: Double) -> Double { timeSteps.first { span / $0 <= 5 } ?? (span / 5).rounded(.up) }

    // MARK: Panels

    /// Peaks further apart than this share no useful scale.
    static let splitRatio = 5.0

    /// When the highest peak is more than `splitRatio` times the lowest, the
    /// sessions split into two panels at the widest gap between peaks: the fast
    /// ones keep their scale and the slow ones get their own. Nil keeps one panel.
    static func panels(_ peaks: [(id: Int, kW: Double)]) -> (high: [Int], low: [Int])? {
        let sorted = peaks.filter { $0.kW > 0 && $0.kW.isFinite }.sorted { $0.kW < $1.kW }
        guard let lo = sorted.first, let hi = sorted.last, hi.kW > splitRatio * lo.kW else { return nil }
        var cut = 1, widest = 0.0
        for i in 1..<sorted.count where sorted[i].kW / sorted[i - 1].kW > widest {
            widest = sorted[i].kW / sorted[i - 1].kW; cut = i
        }
        let ids = sorted.map(\.id)
        return (high: Array(ids[cut...]), low: Array(ids[..<cut]))
    }

    // MARK: Names

    /// A short name for each session: "Nov 15", or "Nov 15, 8:10 AM" when two
    /// chosen sessions began on the same day.
    static func shortNames(_ sessions: [(id: Int, start: Date)], calendar: Calendar = .current) -> [Int: String] {
        var day = Date.FormatStyle.dateTime.month(.abbreviated).day()
        day.timeZone = calendar.timeZone
        var time = Date.FormatStyle.dateTime.hour().minute()
        time.timeZone = calendar.timeZone
        let counts = Dictionary(grouping: sessions) { calendar.startOfDay(for: $0.start) }.mapValues(\.count)
        return Dictionary(uniqueKeysWithValues: sessions.map { s in
            let name = s.start.formatted(day)
            return (s.id, (counts[calendar.startOfDay(for: s.start)] ?? 0) > 1 ? "\(name), \(s.start.formatted(time))" : name)
        })
    }

    // MARK: Verdict

    /// Which session crossed the shared window quickest, in whole minutes as the
    /// table shows them, and by how much it beat the next quickest.
    struct Verdict: Hashable, Sendable {
        var leader: Int
        var runnerUp: Int
        var minutes: Int
        var margin: Int
    }

    /// Nil unless at least two sessions take part and every one has a time for
    /// the window: a session whose record breaks inside it might have been
    /// quicker, so no winner is named.
    static func verdict(_ times: [(id: Int, minutes: Double?)]) -> Verdict? {
        guard times.allSatisfy({ $0.minutes != nil }) else { return nil }
        let known = times.compactMap { t in t.minutes.map { (id: t.id, minutes: Int($0.rounded())) } }
            .sorted { $0.minutes < $1.minutes }
        guard known.count >= 2 else { return nil }
        return Verdict(leader: known[0].id, runnerUp: known[1].id, minutes: known[0].minutes, margin: known[1].minutes - known[0].minutes)
    }

    /// The sentence after the leader's name, e.g. " was quickest from 45 to
    /// 80%: 18 min, 2 min faster than Nov 5." A tie says so.
    static func verdictTail(_ verdict: Verdict, window: ClosedRange<Int>, runnerUp: String) -> String {
        let range = "from \(window.lowerBound) to \(window.upperBound)%"
        if verdict.margin == 0 { return " and \(runnerUp) were equally quick \(range): \(verdict.minutes) min each." }
        return " was quickest \(range): \(verdict.minutes) min, \(verdict.margin) min faster than \(runnerUp)."
    }

    // MARK: Line labels

    /// End-of-line label positions (in points, larger is lower), moved apart
    /// to at least `minGap` while keeping their order and staying `within`.
    static func nudged(_ ys: [Double], minGap: Double, within bounds: ClosedRange<Double>) -> [Double] {
        guard !ys.isEmpty else { return [] }
        let order = ys.indices.sorted { ys[$0] < ys[$1] }
        var placed = order.map { min(max(ys[$0], bounds.lowerBound), bounds.upperBound) }
        for i in placed.indices.dropFirst() where placed[i] - placed[i - 1] < minGap { placed[i] = placed[i - 1] + minGap }
        // Pushed past the bottom: shift the stack back up from there.
        if let last = placed.last, last > bounds.upperBound {
            placed[placed.count - 1] = bounds.upperBound
            for i in placed.indices.dropLast().reversed() where placed[i + 1] - placed[i] < minGap { placed[i] = placed[i + 1] - minGap }
        }
        var out = ys
        for (rank, index) in order.enumerated() { out[index] = placed[rank] }
        return out
    }

    /// Gridline values for the x axis: tens or twenties of
    /// percent, or a round number of minutes, at most six marks.
    static func xTicks(_ domain: ClosedRange<Double>, axis: Axis) -> [Double] {
        let span = domain.upperBound - domain.lowerBound
        guard span > 0 else { return [domain.lowerBound] }
        let step = axis == .soc ? ([10.0, 20, 25, 50].first { span / $0 <= 5 } ?? (span / 5).rounded(.up)) : timeStep(span)
        let first = (domain.lowerBound / step).rounded(.up) * step
        return Array(stride(from: first, through: domain.upperBound + 1e-9, by: step))
    }

    /// The value nearest `x` on one curve, if a drawn point lies within `tolerance`.
    static func value(near x: Double, in points: [Point], tolerance: Double) -> Point? {
        guard let p = points.min(by: { abs($0.x - x) < abs($1.x - x) }), abs(p.x - x) <= tolerance else { return nil }
        return p
    }
}
