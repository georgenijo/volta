import Foundation

// Pure arithmetic behind the lease tracker, efficiency by speed, charging
// insights and the charge cycle estimate. No SwiftUI, so VoltaTests can cover
// every rule. Unknown inputs stay unknown: nothing here substitutes zero for a
// missing reading, smooths a sparse bin, or adds amounts across currencies.

// MARK: - Efficiency by speed

enum SpeedEfficiency {
    /// Bins with fewer drives than this are drawn and labelled as sparse.
    static let sparseBelow = 3

    /// One average-speed bin in display units (mph or km/h).
    struct Bin: Identifiable, Hashable, Sendable {
        var lower: Double
        var width: Double
        var distanceKm: Double = 0
        var energyKwh: Double = 0
        var drives: Int = 0

        var id: Double { lower }
        var upper: Double { lower + width }
        var mid: Double { lower + width / 2 }
        var isEmpty: Bool { drives == 0 }
        var isSparse: Bool { drives > 0 && drives < SpeedEfficiency.sparseBelow }
        /// Energy over distance of the bin's drives (distance-weighted, like the
        /// temperature bands); nil for an empty bin, never zero.
        var whPerKm: Double? { drives > 0 && distanceKm > 0 ? energyKwh * 1000 / distanceKm : nil }
    }

    /// 10 mph or 15 km/h: about the same span either way.
    static func binWidth(_ units: UnitPreferences) -> Double { units.distance == .miles ? 10 : 15 }

    /// A drive is comparable when it has an average speed, measured energy and
    /// a real distance (the same distance floor as Battery Climate).
    static func isUsable(_ drive: DriveSummary) -> Bool {
        guard let speed = drive.avgSpeedKph, speed.isFinite, speed > 0,
              let energy = drive.energyUsedKwh, energy.isFinite, energy > 0,
              drive.distanceKm.isFinite, drive.distanceKm > 0.5 else { return false }
        return true
    }

    /// Contiguous bins from the slowest occupied bin to the fastest. Bins in
    /// between with no drives are kept, empty, so a gap reads as a gap.
    static func bins(_ drives: [DriveSummary], units: UnitPreferences) -> [Bin] {
        let width = binWidth(units)
        var map: [Int: Bin] = [:]
        for drive in drives where isUsable(drive) {
            let speed = units.distanceValue(km: drive.avgSpeedKph ?? 0)
            let index = Int((speed / width).rounded(.down))
            var bin = map[index] ?? Bin(lower: Double(index) * width, width: width)
            bin.distanceKm += drive.distanceKm
            bin.energyKwh += drive.energyUsedKwh ?? 0
            bin.drives += 1
            map[index] = bin
        }
        guard let lo = map.keys.min(), let hi = map.keys.max() else { return [] }
        return (lo...hi).map { map[$0] ?? Bin(lower: Double($0) * width, width: width) }
    }
}

// MARK: - Lease mileage

/// The owner's lease figures, entered by hand and stored only on the phone.
struct LeaseTerms: Codable, Hashable, Sendable {
    var start: Date
    var termMonths: Int
    var allowanceKm: Double
    var startOdometerKm: Double

    static let termRange = 1...120

    var isValid: Bool {
        Self.termRange.contains(termMonths) && allowanceKm.isFinite && allowanceKm > 0
            && startOdometerKm.isFinite && startOdometerKm >= 0
    }

    func end(calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .month, value: termMonths, to: start) ?? start
    }
}

struct LeaseProgress: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case notStarted, active, ended }

    /// A pace from fewer days than this is too noisy to project from.
    static let minimumDaysForPace = 7.0
    static let daysPerMonth = 365.25 / 12

    var phase: Phase
    var start: Date
    var end: Date
    var totalDays: Double
    var elapsedDays: Double
    var remainingDays: Double
    /// Odometer now minus the starting odometer. nil when the odometer is
    /// unknown or reads below the starting figure (see `odometerBelowStart`).
    var usedKm: Double?
    var remainingKm: Double?
    /// The allowance spread evenly over the term, up to today.
    var expectedKmToDate: Double
    var allowedKmPerDay: Double
    /// Distance per day so far; nil until `minimumDaysForPace` have passed.
    var actualKmPerDay: Double?
    /// The pace that would use exactly the allowance by the end; nil once ended.
    var neededKmPerDay: Double?
    /// Active: an estimate at the current pace. Ended: the final figure.
    var projectedKmAtEnd: Double?
    /// Positive over the allowance, negative under.
    var projectedOverKm: Double? { projectedKmAtEnd.map { $0 - allowanceKm } }
    var allowanceKm: Double
    var odometerBelowStart: Bool

    /// Used distance ahead (+) or behind (−) an even pace. nil if usage is unknown.
    var aheadOfPaceKm: Double? { usedKm.map { $0 - expectedKmToDate } }
    var usedFraction: Double? { usedKm.map { $0 / allowanceKm } }
    var timeFraction: Double { totalDays > 0 ? min(1, elapsedDays / totalDays) : 0 }
    var isProjectionEstimate: Bool { phase == .active }

    init(terms: LeaseTerms, odometerKm: Double?, now: Date, calendar: Calendar = .current) {
        start = terms.start
        end = terms.end(calendar: calendar)
        allowanceKm = terms.allowanceKm
        totalDays = max(end.timeIntervalSince(start) / 86_400, 0)
        let rawElapsed = now.timeIntervalSince(start) / 86_400
        elapsedDays = min(max(rawElapsed, 0), totalDays)
        remainingDays = max(totalDays - elapsedDays, 0)
        phase = rawElapsed < 0 ? .notStarted : now >= end ? .ended : .active
        allowedKmPerDay = totalDays > 0 ? terms.allowanceKm / totalDays : 0
        expectedKmToDate = allowedKmPerDay * elapsedDays

        // Before the lease starts nothing has been used against it.
        let delta = phase == .notStarted ? nil : odometerKm.flatMap { $0.isFinite ? $0 - terms.startOdometerKm : nil }
        odometerBelowStart = (delta ?? 0) < 0
        usedKm = delta.flatMap { $0 >= 0 ? $0 : nil }
        remainingKm = usedKm.map { terms.allowanceKm - $0 }

        switch phase {
        case .notStarted:
            actualKmPerDay = nil
            neededKmPerDay = nil
            projectedKmAtEnd = nil
        case .active:
            let pace = elapsedDays >= Self.minimumDaysForPace ? usedKm.map { $0 / elapsedDays } : nil
            actualKmPerDay = pace
            neededKmPerDay = remainingKm.flatMap { remainingDays > 0 ? max($0, 0) / remainingDays : nil }
            projectedKmAtEnd = pace.flatMap { pace in usedKm.map { $0 + pace * remainingDays } }
        case .ended:
            actualKmPerDay = usedKm.flatMap { totalDays > 0 ? $0 / totalDays : nil }
            neededKmPerDay = nil
            projectedKmAtEnd = usedKm
        }
    }

    struct Point: Hashable, Sendable {
        var date: Date
        var km: Double
    }

    /// Cumulative recorded distance from the lease start: zero at the start,
    /// then the running total at the end of each recorded day (UTC buckets, as
    /// the server returns them), never past `now`. Days before the lease start
    /// are left out.
    static func cumulative(_ buckets: [MileageBucket], start: Date, now: Date) -> [Point] {
        let calendar = AnalyticsMath.utcCalendar
        var total = 0.0
        var points = [Point(date: start, km: 0)]
        for bucket in buckets.sorted(by: { $0.start < $1.start }) {
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: bucket.start) ?? bucket.start
            guard dayEnd > start, bucket.start <= now, bucket.distanceKm.isFinite, bucket.distanceKm > 0 else { continue }
            total += bucket.distanceKm
            points.append(Point(date: min(max(dayEnd, start), now), km: total))
        }
        return points
    }
}

// MARK: - Charging insights

enum ChargingInsights {
    /// Two sides of one comparison (home / away, or AC / DC fast).
    struct Side: Hashable, Sendable {
        var label: String
        var sessions = 0
        /// Sum over sessions with recorded energy.
        var energyKwh = 0.0
        var energySessions = 0
        /// Sum of recorded costs in the split's currency; nil when none was recorded.
        var cost: Double?
        var costSessions = 0
        /// Sessions with no recorded cost.
        var costUnknown = 0
        /// Sessions priced in a different currency, left out of `cost`.
        var otherCurrency = 0
    }

    struct Split: Hashable, Sendable {
        var first: Side
        var second: Side
        /// The one currency the cost shares are in; nil when nothing is priced.
        var currency: String?

        var sessions: Int { first.sessions + second.sessions }
        var energyKwh: Double { first.energyKwh + second.energyKwh }
        var energyUnknown: Int { sessions - first.energySessions - second.energySessions }
        var costUnknown: Int { first.costUnknown + second.costUnknown }
        var otherCurrency: Int { first.otherCurrency + second.otherCurrency }
        var cost: Double? {
            switch (first.cost, second.cost) {
            case (nil, nil): nil
            case let (a, b): (a ?? 0) + (b ?? 0)
            }
        }

        /// Share of recorded energy on the first side; nil when no energy is recorded.
        var firstEnergyFraction: Double? { energyKwh > 0 ? first.energyKwh / energyKwh : nil }
        /// Share of recorded cost on the first side; nil when nothing is priced or the total is zero.
        var firstCostFraction: Double? {
            guard let total = cost, total > 0 else { return nil }
            return (first.cost ?? 0) / total
        }
    }

    /// The currency with the most priced sessions (ties: the larger total, then
    /// alphabetical). A cost without a currency uses `fallbackCurrency`, as
    /// everywhere else in the app.
    static func primaryCurrency(_ charges: [ChargeSummary], fallbackCurrency: String) -> String? {
        var counts: [String: (count: Int, amount: Double)] = [:]
        for charge in charges {
            guard let cost = charge.cost, cost.isFinite else { continue }
            let currency = charge.currency ?? fallbackCurrency
            counts[currency, default: (0, 0)].count += 1
            counts[currency, default: (0, 0)].amount += cost
        }
        return counts.sorted { a, b in
            if a.value.count != b.value.count { return a.value.count > b.value.count }
            if a.value.amount != b.value.amount { return a.value.amount > b.value.amount }
            return a.key < b.key
        }.first?.key
    }

    static func split(_ charges: [ChargeSummary], first firstLabel: String, second secondLabel: String,
                      fallbackCurrency: String, isFirst: (ChargeSummary) -> Bool) -> Split {
        let currency = primaryCurrency(charges, fallbackCurrency: fallbackCurrency)
        var first = Side(label: firstLabel), second = Side(label: secondLabel)
        for charge in charges {
            func add(_ side: inout Side) {
                side.sessions += 1
                if let energy = charge.energyAddedKwh, energy.isFinite, energy > 0 {
                    side.energyKwh += energy
                    side.energySessions += 1
                }
                guard let cost = charge.cost, cost.isFinite, cost >= 0 else { side.costUnknown += 1; return }
                guard (charge.currency ?? fallbackCurrency) == currency else { side.otherCurrency += 1; return }
                side.cost = (side.cost ?? 0) + cost
                side.costSessions += 1
            }
            if isFirst(charge) { add(&first) } else { add(&second) }
        }
        return Split(first: first, second: second, currency: currency)
    }

    /// Home (a place TeslaMate names "Home") against everywhere else.
    static func homeAway(_ charges: [ChargeSummary], fallbackCurrency: String) -> Split {
        split(charges, first: "Home", second: "Away", fallbackCurrency: fallbackCurrency) { $0.kind == .home }
    }

    /// AC charging against DC fast charging.
    static func acDc(_ charges: [ChargeSummary], fallbackCurrency: String) -> Split {
        split(charges, first: "AC", second: "DC fast", fallbackCurrency: fallbackCurrency) { !$0.fastCharger }
    }

    // MARK: Cost per distance

    struct CostPoint: Identifiable, Hashable, Sendable {
        var start: Date
        var distanceKm: Double
        var cost: Double
        var sessions: Int
        var id: Date { start }
        var costPerKm: Double { cost / distanceKm }
    }

    /// Charging cost per distance driven, bucket by bucket. A bucket is plotted
    /// only when it has driving, at least one charge, and every charge in it
    /// has a recorded cost in `currency`; the others are counted, not guessed.
    struct CostSeries: Hashable, Sendable {
        var currency: String?
        var points: [CostPoint]
        /// Buckets left out because a charge had no recorded cost.
        var unknownCostBuckets = 0
        /// Buckets left out because a charge was priced in another currency.
        var otherCurrencyBuckets = 0
        /// Buckets with driving but no charging session (nothing to price).
        var noChargeBuckets = 0
        /// Buckets with charging but no recorded driving.
        var noDistanceBuckets = 0

        var excludedBuckets: Int { unknownCostBuckets + otherCurrencyBuckets + noChargeBuckets + noDistanceBuckets }
        /// Over the plotted buckets only.
        var costPerKm: Double? {
            let km = points.reduce(0) { $0 + $1.distanceKm }
            return km > 0 ? points.reduce(0) { $0 + $1.cost } / km : nil
        }
    }

    static func costPerDistance(charges: [ChargeSummary], drives: [DriveSummary], bucket component: Calendar.Component,
                                calendar: Calendar, fallbackCurrency: String) -> CostSeries {
        let currency = primaryCurrency(charges, fallbackCurrency: fallbackCurrency)
        func key(_ date: Date) -> Date { calendar.dateInterval(of: component, for: date)?.start ?? date }
        var km: [Date: Double] = [:]
        for drive in drives where drive.distanceKm.isFinite && drive.distanceKm > 0 {
            km[key(drive.start), default: 0] += drive.distanceKm
        }
        let sessions = Dictionary(grouping: charges) { key($0.start) }
        var series = CostSeries(currency: currency, points: [])
        for start in Set(km.keys).union(sessions.keys).sorted() {
            let driven = km[start] ?? 0
            let inBucket = sessions[start] ?? []
            if inBucket.isEmpty { series.noChargeBuckets += 1; continue }
            if inBucket.contains(where: { $0.cost.map { !$0.isFinite || $0 < 0 } ?? true }) { series.unknownCostBuckets += 1; continue }
            if inBucket.contains(where: { ($0.currency ?? fallbackCurrency) != currency }) { series.otherCurrencyBuckets += 1; continue }
            if driven <= 0 { series.noDistanceBuckets += 1; continue }
            series.points.append(CostPoint(start: start, distanceKm: driven, cost: inBucket.reduce(0) { $0 + ($1.cost ?? 0) },
                                           sessions: inBucket.count))
        }
        return series
    }
}

// MARK: - Charge cycles

/// Total energy added divided by today's estimated usable capacity: an
/// equivalent number of full cycles over the sessions TeslaMate recorded.
struct CycleEstimate: Equatable, Sendable {
    var cycles: Double
    var energyAddedKwh: Double
    var capacityKwh: Double
    /// Sessions with recorded energy, out of all sessions loaded.
    var sessionsCounted: Int
    var sessionsTotal: Int
    /// False when not every page of history loaded: the figure is a lower bound.
    var isComplete: Bool

    static func make(charges: [ChargeSummary], usableCapacityKwh: Double?, isComplete: Bool = true) -> CycleEstimate? {
        guard let capacity = usableCapacityKwh, capacity.isFinite, capacity > 0 else { return nil }
        let added = charges.compactMap { $0.energyAddedKwh }.filter { $0.isFinite && $0 > 0 }
        guard !added.isEmpty else { return nil }
        let total = added.reduce(0, +)
        return CycleEstimate(cycles: total / capacity, energyAddedKwh: total, capacityKwh: capacity,
                             sessionsCounted: added.count, sessionsTotal: charges.count, isComplete: isComplete)
    }
}
