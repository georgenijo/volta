import Foundation

/// This calendar month's charging next to last month's: the number of
/// charges, the energy added, what it cost and home's share of the energy.
///
/// The rules are Charging Insights' own: months are bucketed by when each
/// session started, in the user's calendar and time zone. Costs come only from
/// what the server recorded. A session without a cost is counted but never
/// priced, and amounts in different currencies are never added together (a
/// month totals its dominant currency and lists the others). Home is
/// `ChargingInsights.homeAway`. A figure nothing was recorded for is nil,
/// shown as an em dash, never zero.
struct ChargingRecap: Equatable, Sendable {
    struct Month: Equatable, Sendable {
        /// The calendar month, start inclusive and end exclusive.
        var interval: DateInterval
        var sessions: Int
        /// Recorded energy added; nil when no session recorded any.
        var energyKwh: Double?
        /// Sessions without recorded energy, left out of `energyKwh`.
        var energyUnknown: Int
        /// The month's dominant currency (`ChargingInsights.primaryCurrency`);
        /// nil when no session has both a cost and a currency.
        var currency: String?
        /// Recorded costs in `currency`; nil when nothing is priced in it.
        var cost: Double?
        /// Sessions with no recorded cost: counted, not priced.
        var unpriced: Int
        /// Sessions with a cost but no recorded currency, left out of `cost`.
        var currencyUnknown: Int
        /// Sessions priced in a currency other than `currency`, by code, left out of `cost`.
        var otherCurrencies: [String: Int]
        /// Home's share of the recorded energy; nil when no energy was recorded.
        var homeShare: Double?

        init(interval: DateInterval, charges: [ChargeSummary]) {
            self.interval = interval
            let split = ChargingInsights.homeAway(charges)
            sessions = split.sessions
            energyKwh = split.sessions > split.energyUnknown ? split.energyKwh : nil
            energyUnknown = split.energyUnknown
            currency = split.currency
            cost = split.cost
            unpriced = split.costUnknown
            currencyUnknown = split.currencyUnknown
            var others: [String: Int] = [:]
            for charge in charges where ChargingInsights.cost(charge) != nil {
                guard let code = ChargingInsights.currency(charge), code != split.currency else { continue }
                others[code, default: 0] += 1
            }
            otherCurrencies = others
            homeShare = split.firstEnergyFraction
        }

        var isEmpty: Bool { sessions == 0 }

        /// Every session has a recorded cost in `currency`.
        var isFullyPriced: Bool {
            cost != nil && unpriced == 0 && currencyUnknown == 0 && otherCurrencies.isEmpty
        }

        /// Home share as the whole percentage the card shows.
        var homePercent: Int? { homeShare.map { Int(($0 * 100).rounded()) } }
    }

    var current: Month
    var previous: Month
    /// False when not every page of sessions loaded: the figures are lower
    /// bounds and no change is claimed.
    var isComplete: Bool

    /// Buckets `charges` into the calendar month containing `now` and the one
    /// before it; sessions outside both are ignored.
    init(charges: [ChargeSummary], now: Date, calendar: Calendar, isComplete: Bool = true) {
        let thisMonth = Self.month(containing: now, calendar: calendar)
        let lastMonth = Self.month(containing: thisMonth.start.addingTimeInterval(-1), calendar: calendar)
        func within(_ interval: DateInterval) -> [ChargeSummary] {
            charges.filter { $0.start >= interval.start && $0.start < interval.end }
        }
        current = Month(interval: thisMonth, charges: within(thisMonth))
        previous = Month(interval: lastMonth, charges: within(lastMonth))
        self.isComplete = isComplete
    }

    static func month(containing date: Date, calendar: Calendar) -> DateInterval {
        calendar.dateInterval(of: .month, for: date) ?? DateInterval(start: date, duration: 0)
    }

    /// From the start of last month, the range the recap needs loaded.
    static func range(now: Date, calendar: Calendar) -> DateRange {
        let thisMonth = month(containing: now, calendar: calendar)
        return DateRange(from: month(containing: thisMonth.start.addingTimeInterval(-1), calendar: calendar).start, to: nil)
    }

    // MARK: Changes against last month

    /// A change is shown only when both months have sessions and every page loaded.
    private var comparable: Bool { isComplete && !current.isEmpty && !previous.isEmpty }

    var sessionsChange: Int? { comparable ? current.sessions - previous.sessions : nil }

    var energyChange: Double? {
        guard comparable, let now = current.energyKwh, let before = previous.energyKwh else { return nil }
        return now - before
    }

    /// Only between two months whose every session is priced in the same
    /// currency: a partly priced month's total would show a change that is
    /// really a missing price.
    var costChange: Double? {
        guard comparable, current.isFullyPriced, previous.isFullyPriced, current.currency == previous.currency,
              let now = current.cost, let before = previous.cost else { return nil }
        return now - before
    }

    /// In whole percentage points, between the percentages shown.
    var homeShareChange: Int? {
        guard comparable, let now = current.homePercent, let before = previous.homePercent else { return nil }
        return now - before
    }

    // MARK: Words

    /// "November so far": the current month always is.
    func title(calendar: Calendar, locale: Locale = .autoupdatingCurrent) -> String {
        "\(Self.monthName(current.interval.start, calendar: calendar, locale: locale)) so far"
    }

    /// "vs October".
    func comparison(calendar: Calendar, locale: Locale = .autoupdatingCurrent) -> String {
        "vs \(Self.monthName(previous.interval.start, calendar: calendar, locale: locale))"
    }

    static func monthName(_ date: Date, calendar: Calendar, locale: Locale = .autoupdatingCurrent) -> String {
        var style = Date.FormatStyle.dateTime.month(.wide)
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        style.locale = locale
        return date.formatted(style)
    }

    /// What the figures leave out, in the order the card lists it.
    func notes(calendar: Calendar, locale: Locale = .autoupdatingCurrent) -> [String] {
        var notes: [String] = []
        if !isComplete { notes.append("Not every session could be loaded, so these figures are lower bounds.") }
        let month = current
        if month.unpriced > 0 { notes.append("\(ChargingInsights.sessions(month.unpriced)) unpriced") }
        if month.currencyUnknown > 0 {
            notes.append("\(ChargingInsights.sessions(month.currencyUnknown)) with a cost but no currency, not added")
        }
        for (code, count) in month.otherCurrencies.sorted(by: { $0.key < $1.key }) {
            notes.append("\(ChargingInsights.sessions(count)) priced in \(code), not added")
        }
        if month.energyUnknown > 0 { notes.append("\(ChargingInsights.sessions(month.energyUnknown)) without recorded energy") }
        if isComplete, !month.isEmpty, previous.isEmpty {
            notes.append("No charges in \(Self.monthName(previous.interval.start, calendar: calendar, locale: locale)) to compare with.")
        }
        return notes
    }

    static let minus = "\u{2212}"

    /// "+3", "−2", "Same".
    static func changeText(_ change: Int) -> String {
        change == 0 ? "Same" : (change > 0 ? "+" : minus) + "\(abs(change))"
    }

    /// "+12.4 kWh", "−3 kWh", "Same". Rounded as shown before deciding it is the same.
    static func energyChangeText(_ change: Double) -> String {
        let digits = abs(change) >= 100 ? 0 : 1
        let shown = VoltaFormat.number(abs(change), digits: digits)
        guard abs(change) >= (digits == 0 ? 0.5 : 0.05) else { return "Same" }
        return (change > 0 ? "+" : minus) + shown + " kWh"
    }

    /// "+$4.20", "−$6.00", "Same".
    static func costChangeText(_ change: Double, currency: String) -> String {
        guard abs(change) >= 0.005 else { return "Same" }
        return (change > 0 ? "+" : minus) + VoltaFormat.money(abs(change), currency: currency)
    }

    /// "+8 points", "−1 point", "Same".
    static func pointsChangeText(_ change: Int) -> String {
        guard change != 0 else { return "Same" }
        return (change > 0 ? "+" : minus) + "\(abs(change)) point\(abs(change) == 1 ? "" : "s")"
    }
}
