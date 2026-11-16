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

    /// A drive is comparable when it has finished (an open drive's figures are
    /// still growing), an average speed, measured energy and a real distance
    /// (the same distance floor as Battery Climate).
    static func isUsable(_ drive: DriveSummary) -> Bool {
        guard drive.end != nil, let speed = drive.avgSpeedKph, speed.isFinite, speed > 0,
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

/// A calendar day with no time of day or time zone, as written on a contract.
struct CivilDate: Codable, Hashable, Comparable, Sendable {
    var year: Int
    var month: Int
    var day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year; self.month = month; self.day = day
    }

    /// The day `date` falls on in `calendar`'s time zone; the time of day is dropped.
    init(_ date: Date, calendar: Calendar) {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        self.init(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    var isValid: Bool { (1...12).contains(month) && (1...31).contains(day) && (1900...3000).contains(year) }

    /// Midnight at the start of this day in `calendar`'s time zone.
    func start(in calendar: Calendar) -> Date {
        let date = calendar.date(from: DateComponents(year: year, month: month, day: day)) ?? .distantPast
        return calendar.startOfDay(for: date)
    }

    static func < (a: CivilDate, b: CivilDate) -> Bool { (a.year, a.month, a.day) < (b.year, b.month, b.day) }
}

/// The owner's lease figures, entered by hand and stored only on the phone.
///
/// The start is a civil date. The lease runs from midnight at the start of
/// that day to midnight at the start of the same day `termMonths` later, both
/// in the phone's time zone; that one boundary is used for the pace, the
/// chart and which drives count.
struct LeaseTerms: Codable, Hashable, Sendable {
    var startDay: CivilDate
    var termMonths: Int
    var allowanceKm: Double
    var startOdometerKm: Double

    static let termRange = 1...120

    var isValid: Bool {
        startDay.isValid && Self.termRange.contains(termMonths) && allowanceKm.isFinite && allowanceKm > 0
            && startOdometerKm.isFinite && startOdometerKm >= 0
    }

    func start(calendar: Calendar = .current) -> Date { startDay.start(in: calendar) }

    func end(calendar: Calendar = .current) -> Date {
        let start = start(calendar: calendar)
        return calendar.date(byAdding: .month, value: termMonths, to: start).map { calendar.startOfDay(for: $0) } ?? start
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
    /// Odometer now minus the starting odometer, in any phase after the start.
    /// nil when the odometer is unknown or reads below the starting figure
    /// (see `odometerBelowStart`). After the lease ends this includes any
    /// driving since the end.
    var sinceStartKm: Double?
    /// Distance used against the allowance. Only known while the lease runs:
    /// once it has ended, today's odometer includes driving after the end and
    /// Volta has no reading from the last day, so the final figure is unknown.
    var usedKm: Double?
    var remainingKm: Double?
    /// The allowance spread evenly over the term, up to today.
    var expectedKmToDate: Double
    var allowedKmPerDay: Double
    /// Distance per day so far; nil until `minimumDaysForPace` have passed.
    var actualKmPerDay: Double?
    /// The most distance per day that still finishes on the allowance; active only.
    var neededKmPerDay: Double?
    /// An estimate at the current pace; active only.
    var projectedKmAtEnd: Double?
    /// Positive over the allowance, negative under.
    var projectedOverKm: Double? { projectedKmAtEnd.map { $0 - allowanceKm } }
    var allowanceKm: Double
    var odometerBelowStart: Bool

    /// Used distance ahead (+) or behind (−) an even pace. nil if usage is unknown.
    var aheadOfPaceKm: Double? { usedKm.map { $0 - expectedKmToDate } }
    var usedFraction: Double? { usedKm.map { $0 / allowanceKm } }
    var timeFraction: Double { totalDays > 0 ? min(1, elapsedDays / totalDays) : 0 }
    var isProjectionEstimate: Bool { projectedKmAtEnd != nil }

    init(terms: LeaseTerms, odometerKm: Double?, now: Date, calendar: Calendar = .current) {
        start = terms.start(calendar: calendar)
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
        sinceStartKm = delta.flatMap { $0 >= 0 ? $0 : nil }
        usedKm = phase == .active ? sinceStartKm : nil
        remainingKm = usedKm.map { terms.allowanceKm - $0 }

        if phase == .active {
            let pace = elapsedDays >= Self.minimumDaysForPace ? usedKm.map { $0 / elapsedDays } : nil
            actualKmPerDay = pace
            neededKmPerDay = remainingKm.flatMap { remainingDays > 0 ? max($0, 0) / remainingDays : nil }
            projectedKmAtEnd = pace.flatMap { pace in usedKm.map { $0 + pace * remainingDays } }
        } else {
            actualKmPerDay = nil
            neededKmPerDay = nil
            projectedKmAtEnd = nil
        }
    }

    struct Point: Hashable, Sendable {
        var date: Date
        var km: Double
    }

    /// Recorded drive distance inside the lease, added up by local day.
    ///
    /// A drive counts when it starts in [`start`, min(`end`, `now`)). The
    /// series begins at zero at the start of the first day with a recorded
    /// drive and steps up at the end of each day with driving, so nothing is
    /// drawn for days before TeslaMate recorded anything.
    static func recorded(_ drives: [DriveSummary], start: Date, end: Date, now: Date, calendar: Calendar = .current) -> [Point] {
        let until = min(end, now)
        var byDay: [Date: Double] = [:]
        for drive in drives where drive.start >= start && drive.start < until && drive.distanceKm.isFinite && drive.distanceKm > 0 {
            byDay[calendar.startOfDay(for: drive.start), default: 0] += drive.distanceKm
        }
        guard let first = byDay.keys.min() else { return [] }
        var total = 0.0
        var points = [Point(date: max(first, start), km: 0)]
        for day in byDay.keys.sorted() {
            total += byDay[day] ?? 0
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: day) ?? day
            points.append(Point(date: min(dayEnd, until), km: total))
        }
        return points
    }
}

// MARK: - Charging places

extension ChargeSummary {
    /// Home is a charging place TeslaMate names exactly "Home", ignoring case
    /// and surrounding whitespace ("Home Depot" is not home). The one rule
    /// Charging History's Home filter and Charging Insights share.
    static func isHomePlace(_ name: String?) -> Bool {
        guard let name = name?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return name.compare("Home", options: .caseInsensitive) == .orderedSame
    }

    var isAtHome: Bool { Self.isHomePlace(placeName) }
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
        /// Sessions with a cost but no recorded currency, left out of `cost`.
        var currencyUnknown = 0
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
        var currencyUnknown: Int { first.currencyUnknown + second.currencyUnknown }
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

    /// A usable recorded cost, or nil.
    static func cost(_ charge: ChargeSummary) -> Double? {
        guard let cost = charge.cost, cost.isFinite, cost >= 0 else { return nil }
        return cost
    }

    /// The recorded currency code, or nil. A missing currency stays unknown:
    /// it is never assumed to be the display currency.
    static func currency(_ charge: ChargeSummary) -> String? {
        guard let code = charge.currency?.trimmingCharacters(in: .whitespacesAndNewlines), !code.isEmpty else { return nil }
        return code.uppercased()
    }

    /// The currency with the most priced sessions (ties: the larger total, then
    /// alphabetical). Only sessions with both a cost and a currency count.
    static func primaryCurrency(_ charges: [ChargeSummary]) -> String? {
        var counts: [String: (count: Int, amount: Double)] = [:]
        for charge in charges {
            guard let cost = cost(charge), let currency = currency(charge) else { continue }
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
                      isFirst: (ChargeSummary) -> Bool) -> Split {
        let primary = primaryCurrency(charges)
        var first = Side(label: firstLabel), second = Side(label: secondLabel)
        for charge in charges {
            func add(_ side: inout Side) {
                side.sessions += 1
                if let energy = charge.energyAddedKwh, energy.isFinite, energy > 0 {
                    side.energyKwh += energy
                    side.energySessions += 1
                }
                guard let cost = cost(charge) else { side.costUnknown += 1; return }
                guard let code = currency(charge) else { side.currencyUnknown += 1; return }
                guard code == primary else { side.otherCurrency += 1; return }
                side.cost = (side.cost ?? 0) + cost
                side.costSessions += 1
            }
            if isFirst(charge) { add(&first) } else { add(&second) }
        }
        return Split(first: first, second: second, currency: primary)
    }

    /// Location only (see `ChargeSummary.isHomePlace`): a fast charger at home is still home.
    static func isHome(_ charge: ChargeSummary) -> Bool { charge.isAtHome }

    /// Home against everywhere else.
    static func homeAway(_ charges: [ChargeSummary]) -> Split {
        split(charges, first: "Home", second: "Away", isFirst: isHome)
    }

    /// What the cost section says besides its figures: which sessions are left
    /// out of the total and why. When nothing is priced in a known currency,
    /// the reason the cost is unknown. nil when every session is priced in the
    /// split's currency.
    static func costNote(_ split: Split) -> String? {
        var parts: [String] = []
        if split.costUnknown > 0 { parts.append("\(sessions(split.costUnknown)) without a recorded cost") }
        if split.currencyUnknown > 0 { parts.append("\(sessions(split.currencyUnknown)) with a cost but no recorded currency") }
        if split.otherCurrency > 0 { parts.append("\(sessions(split.otherCurrency)) priced in another currency") }
        if let currency = split.currency {
            return parts.isEmpty ? nil : "Cost shares are in \(currency) and leave out \(list(parts))."
        }
        // Without a currency to total in, the reason is either missing costs or missing currencies.
        guard split.currencyUnknown > 0 else { return "Unknown: no session in this period has a recorded cost." }
        return "Unknown: \(list(parts)), so nothing can be added up."
    }

    static func sessions(_ n: Int) -> String { "\(n) session\(n == 1 ? "" : "s")" }

    /// "a", "a and b", "a, b and c".
    static func list(_ parts: [String]) -> String {
        guard parts.count > 1, let last = parts.last else { return parts.first ?? "" }
        return parts.dropLast().joined(separator: ", ") + " and " + last
    }

    /// AC charging against DC fast charging.
    static func acDc(_ charges: [ChargeSummary]) -> Split {
        split(charges, first: "AC", second: "DC fast") { !$0.fastCharger }
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
        /// Buckets left out because a charge had a cost but no recorded currency.
        var unknownCurrencyBuckets = 0
        /// Buckets left out because a charge was priced in another currency.
        var otherCurrencyBuckets = 0
        /// Buckets with driving but no charging session (nothing to price).
        var noChargeBuckets = 0
        /// Buckets with charging but no recorded driving.
        var noDistanceBuckets = 0

        var excludedBuckets: Int {
            unknownCostBuckets + unknownCurrencyBuckets + otherCurrencyBuckets + noChargeBuckets + noDistanceBuckets
        }
        /// Over the plotted buckets only.
        var costPerKm: Double? {
            let km = points.reduce(0) { $0 + $1.distanceKm }
            return km > 0 ? points.reduce(0) { $0 + $1.cost } / km : nil
        }
    }

    /// Why no cost per distance can be shown, when no bucket was plotted.
    static func costPerDistanceUnavailable(_ series: CostSeries, bucketNoun noun: String) -> String {
        if series.currency == nil {
            return series.unknownCurrencyBuckets > 0
                ? "Recorded costs in this period have no currency, so cost per distance is unknown."
                : "No session in this period has a recorded cost, so cost per distance is unknown."
        }
        return "No \(noun) in this period had driving and a recorded cost for every session."
    }

    static func costPerDistance(charges: [ChargeSummary], drives: [DriveSummary], bucket component: Calendar.Component,
                                calendar: Calendar) -> CostSeries {
        let primary = primaryCurrency(charges)
        func key(_ date: Date) -> Date { calendar.dateInterval(of: component, for: date)?.start ?? date }
        var km: [Date: Double] = [:]
        for drive in drives where drive.distanceKm.isFinite && drive.distanceKm > 0 {
            km[key(drive.start), default: 0] += drive.distanceKm
        }
        let sessions = Dictionary(grouping: charges) { key($0.start) }
        var series = CostSeries(currency: primary, points: [])
        for start in Set(km.keys).union(sessions.keys).sorted() {
            let driven = km[start] ?? 0
            let inBucket = sessions[start] ?? []
            if inBucket.isEmpty { series.noChargeBuckets += 1; continue }
            if inBucket.contains(where: { cost($0) == nil }) { series.unknownCostBuckets += 1; continue }
            if inBucket.contains(where: { currency($0) == nil }) { series.unknownCurrencyBuckets += 1; continue }
            if inBucket.contains(where: { currency($0) != primary }) { series.otherCurrencyBuckets += 1; continue }
            if driven <= 0 { series.noDistanceBuckets += 1; continue }
            series.points.append(CostPoint(start: start, distanceKm: driven, cost: inBucket.reduce(0) { $0 + (cost($1) ?? 0) },
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
