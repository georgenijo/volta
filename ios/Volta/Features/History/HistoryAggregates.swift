import Foundation

/// A sum over records whose measurement may be missing. `value` is nil when
/// no record has the measurement, so "nothing recorded" renders as "—"
/// instead of a fake zero.
struct PartialSum: Equatable {
    var value: Double?
    var known: Int
    var total: Int

    init<S: Sequence>(_ values: S) where S.Element == Double? {
        var sum = 0.0, known = 0, total = 0
        for value in values {
            total += 1
            if let value { sum += value; known += 1 }
        }
        self.value = known > 0 ? sum : nil
        self.known = known
        self.total = total
    }

    /// Some, but not all, records carry the measurement.
    var isPartial: Bool { known > 0 && known < total }
}

/// Charge costs grouped by currency; never adds amounts in different currencies.
enum CostTotal: Equatable {
    case none
    case single(amount: Double, currency: String)
    case mixed([String: Double])

    /// Costs without a currency are in the user's configured currency (the
    /// same fallback the rows use).
    init(_ charges: [ChargeSummary], fallbackCurrency: String) {
        var byCurrency: [String: Double] = [:]
        for charge in charges {
            guard let cost = charge.cost else { continue }
            byCurrency[(charge.currency ?? fallbackCurrency).uppercased(), default: 0] += cost
        }
        switch byCurrency.count {
        case 0: self = .none
        case 1: self = .single(amount: byCurrency.first!.value, currency: byCurrency.first!.key)
        default: self = .mixed(byCurrency)
        }
    }

    var display: String {
        switch self {
        case .none: "—"
        case .single(let amount, let currency): VoltaFormat.money(amount, currency: currency)
        case .mixed: "Mixed"
        }
    }

    /// Per-currency breakdown for mixed totals, e.g. "$40.12 + €10.00".
    var breakdown: String? {
        guard case .mixed(let byCurrency) = self else { return nil }
        return byCurrency.sorted { $0.key < $1.key }
            .map { VoltaFormat.money($0.value, currency: $0.key) }
            .joined(separator: " + ")
    }
}

/// Totals header for the Charging list.
struct ChargingTotals: Equatable {
    var energyAddedKwh: PartialSum
    var cost: CostTotal
    var costKnown: Int
    var sessions: Int

    init(_ charges: [ChargeSummary], fallbackCurrency: String) {
        energyAddedKwh = PartialSum(charges.map(\.energyAddedKwh))
        cost = CostTotal(charges, fallbackCurrency: fallbackCurrency)
        costKnown = charges.filter { $0.cost != nil }.count
        sessions = charges.count
    }

    var notes: [String] {
        var notes: [String] = []
        if energyAddedKwh.isPartial {
            notes.append("Energy recorded for \(energyAddedKwh.known) of \(sessions) sessions")
        }
        if costKnown > 0 && costKnown < sessions {
            notes.append("Cost recorded for \(costKnown) of \(sessions) sessions")
        }
        if let breakdown = cost.breakdown { notes.append("Cost by currency: \(breakdown)") }
        return notes
    }
}

/// Totals header for the Drives list.
struct DriveTotals: Equatable {
    var distanceKm: Double
    var drives: Int
    var score: Int?
    var scoredDrives: Int
    var energyUsedKwh: PartialSum
    /// Wh/km over only the drives that recorded energy.
    var efficiencyWhPerKm: Double?

    init(_ drives: [DriveSummary]) {
        distanceKm = drives.reduce(0) { $0 + $1.distanceKm }
        self.drives = drives.count
        let scored = drives.filter { $0.efficiencyScore != nil && $0.distanceKm.isFinite && $0.distanceKm > 0 }
        scoredDrives = scored.count
        let scoredKm = scored.reduce(0) { $0 + $1.distanceKm }
        score = scoredKm > 0
            ? Int((scored.reduce(0) { $0 + Double($1.efficiencyScore!) * $1.distanceKm } / scoredKm).rounded())
            : nil
        energyUsedKwh = PartialSum(drives.map(\.costableEnergyKwh))
        let measured = drives.filter { $0.costableEnergyKwh != nil }
        let km = measured.reduce(0) { $0 + $1.distanceKm }
        let kwh = measured.reduce(0) { $0 + ($1.costableEnergyKwh ?? 0) }
        efficiencyWhPerKm = km > 0 ? kwh * 1000 / km : nil
    }

    /// Coverage disclosures for the score and efficiency, shown whether or
    /// not more pages remain.
    var notes: [String] {
        var notes: [String] = []
        if scoredDrives > 0 && scoredDrives < drives {
            notes.append("Score from \(scoredDrives) of \(drives) drives, weighted by distance")
        }
        if energyUsedKwh.isPartial {
            notes.append("Efficiency from the \(energyUsedKwh.known) of \(drives) drives with recorded energy")
        }
        return notes
    }
}

/// Totals header for the Idles list.
struct IdleTotals: Equatable {
    var parkedMinutes: Double
    var rangeLostKm: PartialSum
    var sessions: Int
    /// Sessions with both battery endpoints recorded.
    var drainKnown: Int
    /// Battery % per 24h over only the time with a recorded drain.
    var drainPerDay: Double?

    init(_ idles: [IdleSummary]) {
        sessions = idles.count
        parkedMinutes = idles.reduce(0) { $0 + $1.durationMin }
        rangeLostKm = PartialSum(idles.map(\.rangeLostKm))
        let measured = idles.filter { $0.drain != nil }
        drainKnown = measured.count
        let minutes = measured.reduce(0) { $0 + $1.durationMin }
        let drain = measured.reduce(0) { $0 + ($1.drain ?? 0) }
        drainPerDay = minutes >= 60 ? Double(drain) / (minutes / 1440) : nil
    }

    var notes: [String] {
        var notes: [String] = []
        if rangeLostKm.isPartial {
            notes.append("Range loss recorded for \(rangeLostKm.known) of \(sessions) sessions")
        }
        if drainKnown > 0 && drainKnown < sessions {
            notes.append("Drain rate from the \(drainKnown) of \(sessions) sessions with battery data")
        }
        return notes
    }
}

enum HistoryTotalsScope {
    /// Heading for a totals block. Totals cover only loaded pages, so when a
    /// cursor remains the whole block is labeled partial.
    static func title(period: String, hasMore: Bool, noun: String) -> String {
        hasMore ? "Loaded \(noun) · partial" : period
    }
}

extension BatteryEndpoints {
    /// Start level on the left, end level on the right, regardless of direction.
    var batteryEndpoints: (from: Int?, to: Int?) { (startBatteryLevel, endBatteryLevel) }
}

protocol BatteryEndpoints {
    var startBatteryLevel: Int? { get }
    var endBatteryLevel: Int? { get }
}

extension DriveSummary: BatteryEndpoints {}
extension ChargeSummary: BatteryEndpoints {}
extension IdleSummary: BatteryEndpoints {}

enum ChargeMath {
    /// Rated range gained between the first and last samples that recorded
    /// range. Needs two distinct measurements; one sample is unknown, not +0.
    static func rangeAddedKm(_ samples: [ChargeSample]) -> Double? {
        let measured = samples.compactMap { s in s.ratedRangeKm.flatMap { $0.isFinite ? (t: s.t, km: $0) : nil } }
        guard measured.count >= 2, let first = measured.first, let last = measured.last, last.t > first.t else { return nil }
        return last.km - first.km
    }
}

/// Regenerated energy integrated over the drive's power samples.
struct RegenEstimate: Equatable {
    var kwh: Double
    /// Intervals whose starting sample recorded power.
    var measuredIntervals: Int
    var totalIntervals: Int

    var isPartial: Bool { measuredIntervals < totalIntervals }

    /// Nil when no interval recorded power: missing data is unknown, not 0 kWh.
    init?(_ path: [DrivePoint]) {
        var kwh = 0.0, measured = 0, total = 0
        for (a, b) in zip(path, path.dropFirst()) {
            let seconds = b.t.timeIntervalSince(a.t)
            guard seconds > 0 else { continue }
            total += 1
            guard let power = a.powerKw, power.isFinite else { continue }
            measured += 1
            if power < 0 { kwh += -power * seconds / 3600 }
        }
        guard measured > 0 else { return nil }
        self.kwh = kwh
        measuredIntervals = measured
        totalIntervals = total
    }

    var note: String? {
        isPartial ? "Regen from the \(measuredIntervals) of \(totalIntervals) intervals with recorded power" : nil
    }
}
