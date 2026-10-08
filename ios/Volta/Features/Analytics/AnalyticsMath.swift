import Foundation

/// Pure calculations behind the Analytics screens, kept free of SwiftUI so
/// VoltaTests can cover them. Unknown inputs (nil) stay unknown in outputs.
enum AnalyticsMath {
    // MARK: Stats totals

    /// How many records carried a measurement, out of how many there were.
    struct Coverage: Equatable, Sendable {
        var measured: Int
        var total: Int

        /// Some, but not all, records were measured: a sum is a lower bound.
        var isPartial: Bool { measured > 0 && measured < total }
        var isComplete: Bool { measured == total }
        /// Visible qualifier for a partially measured total, e.g. "Partial — 3 of 5 measured".
        var qualifier: String? { isPartial ? "Partial — \(measured) of \(total) measured" : nil }
    }

    struct Totals: Equatable, Sendable {
        var distanceKm: Double
        var driveMinutes: Double
        /// Sum over drives with measured energy; nil when none has it. See `energyUsedCoverage`.
        var energyUsedKwh: Double?
        var energyUsedCoverage: Coverage
        /// Sum over charges with measured energy; nil when none has it. See `energyAddedCoverage`.
        var energyAddedKwh: Double?
        var energyAddedCoverage: Coverage
        /// Energy over distance of only the drives that have measured energy.
        var efficiencyWhPerKm: Double?
        /// Known charge costs grouped by currency, largest first. Empty when every cost is unknown.
        var costs: [CurrencyAmount]
        var costCoverage: Coverage

        /// The single total cost, or nil when costs are unknown or span several currencies.
        var singleCost: CurrencyAmount? { costs.count == 1 ? costs[0] : nil }

        /// Charging cost per km driven. Charges aren't tied to drives, so this is only
        /// meaningful when every charge's cost is known and in one currency; otherwise nil.
        var costPerKm: CurrencyAmount? {
            guard costCoverage.total > 0, costCoverage.isComplete, let single = singleCost, distanceKm > 0 else { return nil }
            return CurrencyAmount(currency: single.currency, amount: single.amount / distanceKm)
        }
    }

    struct CurrencyAmount: Equatable, Hashable, Sendable {
        var currency: String
        var amount: Double
    }

    static func totals(drives: [DriveSummary], charges: [ChargeSummary], fallbackCurrency: String) -> Totals {
        let measured = drives.filter { $0.energyUsedKwh != nil }
        let measuredEnergy = measured.reduce(0) { $0 + ($1.energyUsedKwh ?? 0) }
        let measuredDistance = measured.reduce(0) { $0 + $1.distanceKm }
        let added = charges.compactMap(\.energyAddedKwh)
        return Totals(
            distanceKm: drives.reduce(0) { $0 + $1.distanceKm },
            driveMinutes: drives.reduce(0) { $0 + $1.durationMin },
            energyUsedKwh: measured.isEmpty ? nil : measuredEnergy,
            energyUsedCoverage: Coverage(measured: measured.count, total: drives.count),
            energyAddedKwh: added.isEmpty ? nil : added.reduce(0, +),
            energyAddedCoverage: Coverage(measured: added.count, total: charges.count),
            efficiencyWhPerKm: measuredDistance > 0 && measuredEnergy > 0 ? measuredEnergy * 1000 / measuredDistance : nil,
            costs: costsByCurrency(charges, fallbackCurrency: fallbackCurrency),
            costCoverage: Coverage(measured: charges.filter { $0.cost != nil }.count, total: charges.count)
        )
    }

    /// Sums known costs per currency. A charge with a cost but no currency uses the fallback.
    static func costsByCurrency(_ charges: [ChargeSummary], fallbackCurrency: String) -> [CurrencyAmount] {
        var sums: [String: Double] = [:]
        for charge in charges {
            guard let cost = charge.cost else { continue }
            sums[charge.currency ?? fallbackCurrency, default: 0] += cost
        }
        return sums.map { CurrencyAmount(currency: $0.key, amount: $0.value) }
            .sorted { $0.amount != $1.amount ? $0.amount > $1.amount : $0.currency < $1.currency }
    }

    // MARK: Mileage buckets

    /// Server timestamps are UTC and Postgres `date_trunc('week')` starts weeks on
    /// Monday (ISO 8601). Label, chart, and select buckets on this calendar so a
    /// bucket starting at UTC midnight never renders as the previous local day and
    /// weeks run Monday–Sunday like the server's.
    static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .iso8601)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        calendar.firstWeekday = 2 // Monday
        calendar.minimumDaysInFirstWeek = 4
        return calendar
    }()

    static func component(for size: MileageBucketSize) -> Calendar.Component {
        switch size {
        case .day: .day
        case .week: .weekOfYear
        case .month: .month
        }
    }

    /// Each returned bucket with its explicit interval, oldest first. A bucket ends at
    /// the next bucket's start or one bucket length after its own start, whichever is
    /// first. The chart draws these exact intervals and selection uses them too, so a
    /// bar and its tap target always agree.
    static func intervals(_ buckets: [MileageBucket], size: MileageBucketSize) -> [(bucket: MileageBucket, interval: DateInterval)] {
        let sorted = buckets.sorted { $0.start < $1.start }
        return sorted.indices.map { index in
            let start = sorted[index].start
            var end = utcCalendar.date(byAdding: component(for: size), value: 1, to: start) ?? start
            if index + 1 < sorted.count { end = min(end, sorted[index + 1].start) }
            return (sorted[index], DateInterval(start: start, end: max(end, start)))
        }
    }

    /// The returned bucket whose interval contains `date`; taps in an empty gap select nothing.
    static func bucket(containing date: Date, in buckets: [MileageBucket], size: MileageBucketSize) -> MileageBucket? {
        intervals(buckets, size: size).last { $0.interval.start <= date && date < $0.interval.end }?.bucket
    }

    // MARK: Warranty

    /// Storage scope for a paired server: lowercased scheme and host, explicit or
    /// default port, and path without trailing slashes, so two servers on one host
    /// (different ports or sub-paths) never share locally stored values.
    static func serverScope(_ serverURL: String) -> String {
        guard let components = URLComponents(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(), let host = components.host?.lowercased(), !host.isEmpty
        else { return serverURL }
        let port = components.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : nil)
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        let hostPart = host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host
        return "\(scheme)://\(hostPart)" + (port.map { ":\($0)" } ?? "") + path
    }

    enum CoverageStatus: Equatable, Sendable {
        case active, expired, unknown
    }

    /// Expired when any known limit is exceeded; active only when both limits are
    /// known and within range; otherwise unknown.
    static func coverageStatus(purchaseDate: Date?, odometerKm: Double?, years: Double, limitKm: Double, now: Date = .now) -> CoverageStatus {
        let distanceExceeded = odometerKm.map { $0 >= limitKm }
        let timeExceeded = purchaseDate.map { now.timeIntervalSince($0) >= years * 365.25 * 86_400 }
        if distanceExceeded == true || timeExceeded == true { return .expired }
        if distanceExceeded == false && timeExceeded == false { return .active }
        return .unknown
    }
}

// MARK: Pagination

/// Items from a cursor-paged endpoint, plus whether every page was read.
struct PagedResult<T: Sendable>: Sendable {
    var items: [T]
    /// False when the safety cap stopped paging or the server repeated a cursor.
    var isComplete: Bool
}

/// Follows `nextCursor` until the server returns nil. The cap only guards against
/// a misbehaving server; hitting it reports `isComplete == false` instead of
/// pretending the partial list is everything.
func fetchAllPages<T: Codable & Hashable & Sendable>(
    maxPages: Int = 10_000,
    _ fetch: @Sendable (String?) async throws -> Page<T>
) async throws -> PagedResult<T> {
    var items: [T] = []
    var cursor: String? = nil
    var seen: Set<String> = []
    for _ in 0..<maxPages {
        try Task.checkCancellation()
        let page = try await fetch(cursor)
        items += page.items
        guard let next = page.nextCursor else { return PagedResult(items: items, isComplete: true) }
        guard seen.insert(next).inserted else { return PagedResult(items: items, isComplete: false) }
        cursor = next
    }
    return PagedResult(items: items, isComplete: false)
}
