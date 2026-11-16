import Foundation

// The Parked screen's numbers, kept apart from its views so they can be
// tested. Everything here works on the stops the list has loaded; when more
// pages remain the screen says the figures are partial.
//
// Missing is never zero: a stop without a recorded range loss is "not
// recorded", a recorded 0 is "no loss measured", and a stop that is still
// open has no loss yet (its end range is read when the car next drives or
// charges). Rates divide recorded loss by the parked time of only the stops
// that recorded it, through one function, so a row, its place and the totals
// never disagree.

enum ParkedRules {
    /// Shortest stretch of parked time a per-day rate is shown for. Below an
    /// hour the range reading's resolution dominates the rate.
    static let rateMinMinutes: Double = 60
    /// A place counts for the finding, and for amber, only with at least this
    /// much parked time with recorded loss...
    static let notableMinMinutes: Double = 1440
    /// ...spread over at least this many stops with recorded loss.
    static let notableMinStops = 3
    /// "Clearly worse": at least this many times the other rate.
    static let notableRatio = 1.5
    /// The loss chart covers at most this many days, newest last.
    static let chartMaxDays = 90
    /// Places shown before the rest fold into "N other places".
    static let placesShown = 3
}

/// Recorded range loss over some stops, with the parked time it was recorded over.
struct ParkedTally: Equatable {
    /// Parked time of every stop counted.
    var minutes: Double = 0
    var stops = 0
    /// Range lost over the stops that recorded it.
    var lostKm: Double = 0
    /// Parked time of only the stops that recorded a loss.
    var measuredMinutes: Double = 0
    var measuredStops = 0

    init() {}

    init<S: Sequence>(_ stops: S) where S.Element == IdleSummary {
        for stop in stops { add(stop) }
    }

    mutating func add(_ stop: IdleSummary) {
        stops += 1
        minutes += max(0, stop.durationMin)
        // An open stop has no end range yet, whatever the field says.
        guard !stop.isLive, let km = stop.rangeLostKm, km.isFinite else { return }
        lostKm += max(0, km)
        measuredMinutes += max(0, stop.durationMin)
        measuredStops += 1
    }

    static func + (a: ParkedTally, b: ParkedTally) -> ParkedTally {
        var sum = a
        sum.minutes += b.minutes; sum.stops += b.stops
        sum.lostKm += b.lostKm; sum.measuredMinutes += b.measuredMinutes; sum.measuredStops += b.measuredStops
        return sum
    }

    /// Nil when no stop recorded a loss: unknown, not 0.
    var lost: Double? { measuredStops > 0 ? lostKm : nil }
    /// Range lost per 24 h parked, over only the time with a recorded loss.
    var perDayKm: Double? { ParkedTally.rate(lostKm: lost, minutes: measuredMinutes) }
    /// Some, but not all, stops recorded a loss.
    var isPartial: Bool { measuredStops > 0 && measuredStops < stops }
    /// Enough recorded parked time for a rate to be compared with another.
    var isSubstantial: Bool {
        measuredMinutes >= ParkedRules.notableMinMinutes && measuredStops >= ParkedRules.notableMinStops
    }

    /// The one rate function: km lost per day parked, or nil with no loss or
    /// under `ParkedRules.rateMinMinutes` of recorded time.
    static func rate(lostKm: Double?, minutes: Double) -> Double? {
        guard let lostKm, lostKm.isFinite, minutes >= ParkedRules.rateMinMinutes else { return nil }
        return lostKm / (minutes / 1440)
    }
}

/// What one stop's loss line says.
enum ParkedLoss: Equatable {
    /// Still parked: the loss is read when the car next drives or charges.
    case pending
    case notRecorded
    /// Recorded as 0 (the server clamps a gain to 0).
    case noLoss
    /// Lost range, with the per-day rate when the stop was long enough.
    case lost(km: Double, perDayKm: Double?)

    init(_ stop: IdleSummary) {
        if stop.isLive { self = .pending; return }
        let tally = ParkedTally([stop])
        guard let km = tally.lost else { self = .notRecorded; return }
        self = km > 0 ? .lost(km: km, perDayKm: tally.perDayKm) : .noLoss
    }
}

/// Stops grouped by where the car sat. Named places (geofences) group by
/// name; others by their coordinates rounded to about 100 m; the rest by
/// their label. Nothing is geocoded.
struct ParkedPlace: Identifiable, Equatable {
    var id: String
    var name: String
    var tally: ParkedTally
    /// Share of all parked time in the summary.
    var share: Double
    /// The rate is clearly worse than the car's own average (see `ParkedSummary`).
    var isNotable: Bool
    /// How many places an "other places" row stands for; 1 for a real place.
    var placeCount = 1

    var isOthers: Bool { placeCount > 1 }

    static func key(_ stop: IdleSummary) -> String {
        if let name = stop.placeName?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return "name:" + name.lowercased()
        }
        if let lat = stop.latitude, let lon = stop.longitude, lat.isFinite, lon.isFinite {
            return String(format: "loc:%.3f,%.3f", lat, lon)
        }
        return "label:" + stop.placeLabel.lowercased()
    }
}

/// A measured comparison between two places with enough parked time.
struct ParkedFinding: Equatable {
    var higher: ParkedPlace
    var lower: ParkedPlace
    var ratio: Double
}

/// Range lost on one calendar day, attributed to the day each stop ended.
struct ParkedDay: Identifiable, Equatable {
    var day: Date
    /// Nil when stops ended that day but none recorded a loss.
    var lostKm: Double?
    var stops: Int
    var isToday: Bool
    /// The highest day, when it is clearly above the period's daily mean.
    var isHighest = false
    var id: Date { day }
}

/// Share of parked time asleep, over only the stops that recorded it.
struct ParkedAsleep: Equatable {
    var asleepMinutes: Double
    var coveredMinutes: Double
    var coveredStops: Int
    var stops: Int

    var share: Double { coveredMinutes > 0 ? min(1, asleepMinutes / coveredMinutes) : 0 }
}

/// A day of finished stops in the list, newest first.
struct ParkedDayGroup: Identifiable, Equatable {
    var day: Date
    var stops: [IdleSummary]
    var id: Date { day }
}

struct ParkedSummary: Equatable {
    /// Finished stops, newest end first.
    var stops: [IdleSummary]
    /// The stop still open, when the list really has one.
    var open: IdleSummary?
    /// More pages remain, so every figure covers only what is loaded.
    var partial: Bool
    var total: ParkedTally
    /// Derived on the server from range lost; an estimate.
    var energyKwh: PartialSum
    /// Every place, most parked time first.
    var places: [ParkedPlace]
    var finding: ParkedFinding?
    var days: [ParkedDay]
    var asleep: ParkedAsleep?
    /// Highest per-day rate among finished stops with a rate.
    var fastest: IdleSummary?
    var groups: [ParkedDayGroup]

    /// `from` and `to` are the selected range (`to` exclusive, nil for a
    /// range that runs to now).
    init(_ items: [IdleSummary], partial: Bool, from: Date? = nil, to: Date? = nil, now: Date = .now,
         calendar: Calendar = .current) {
        let finished = items.filter { !$0.isLive }.sorted { ($0.end ?? $0.start) > ($1.end ?? $1.start) }
        stops = finished
        open = items.filter(\.isLive).max { $0.start < $1.start }
        self.partial = partial
        let total = ParkedTally(finished)
        self.total = total
        energyKwh = PartialSum(finished.map { $0.rangeLostKm == nil ? nil : $0.energyLostKwh })
        places = Self.places(finished, total: total)
        finding = Self.finding(places)
        days = Self.days(finished, partial: partial, from: from, to: to, now: now, calendar: calendar)
        asleep = Self.asleep(finished)
        fastest = finished
            .compactMap { stop in ParkedTally([stop]).perDayKm.map { (stop, $0) } }
            .filter { $0.1 > 0 }
            .max { $0.1 < $1.1 }?.0
        groups = Dictionary(grouping: finished) { calendar.startOfDay(for: $0.end ?? $0.start) }
            .map { ParkedDayGroup(day: $0.key, stops: $0.value) }
            .sorted { $0.day > $1.day }
    }

    var isEmpty: Bool { stops.isEmpty && open == nil }

    /// Places to list: the first few, then the rest as one "other places" row.
    var shownPlaces: [ParkedPlace] {
        guard places.count > ParkedRules.placesShown + 1 else { return places }
        let rest = places.dropFirst(ParkedRules.placesShown)
        let tally = rest.reduce(ParkedTally()) { $0 + $1.tally }
        let others = ParkedPlace(id: "others", name: "\(rest.count) other places", tally: tally,
                                 share: rest.reduce(0) { $0 + $1.share }, isNotable: false, placeCount: rest.count)
        return Array(places.prefix(ParkedRules.placesShown)) + [others]
    }

    /// Coverage disclosures for the totals.
    var notes: [String] {
        var notes: [String] = []
        if total.isPartial {
            notes.append("Range loss recorded for \(total.measuredStops) of \(total.stops) stops")
        }
        return notes
    }

    private static func places(_ stops: [IdleSummary], total: ParkedTally) -> [ParkedPlace] {
        let grouped = Dictionary(grouping: stops, by: ParkedPlace.key)
        let average = total.perDayKm
        return grouped.map { key, stops in
            let tally = ParkedTally(stops)
            // The most common label names a coordinate group.
            let labels = Dictionary(grouping: stops.map(\.placeLabel), by: { $0 })
            let name = labels.max { a, b in a.value.count == b.value.count ? a.key > b.key : a.value.count < b.value.count }?.key ?? "Unknown location"
            return ParkedPlace(id: key, name: name, tally: tally,
                               share: total.minutes > 0 ? tally.minutes / total.minutes : 0,
                               isNotable: isNotable(tally, average: average))
        }
        .sorted { $0.tally.minutes == $1.tally.minutes ? $0.name < $1.name : $0.tally.minutes > $1.tally.minutes }
    }

    /// Amber rule: enough recorded parked time (as the finding needs) and a
    /// rate at least `notableRatio` times the car's own average for the period.
    static func isNotable(_ tally: ParkedTally, average: Double?) -> Bool {
        guard tally.isSubstantial, let rate = tally.perDayKm, let average, average > 0 else { return false }
        return rate >= average * ParkedRules.notableRatio
    }

    /// The highest and lowest rates among places with enough recorded time,
    /// when they differ by `notableRatio` or more. It compares two places
    /// with each other, not with the car's average, so the higher place is
    /// amber (`isNotable`) only when it also clears that rule.
    static func finding(_ places: [ParkedPlace]) -> ParkedFinding? {
        let eligible = places.filter { $0.tally.isSubstantial && $0.tally.perDayKm != nil }
        guard eligible.count >= 2,
              let high = eligible.max(by: { $0.tally.perDayKm! < $1.tally.perDayKm! }),
              let low = eligible.min(by: { $0.tally.perDayKm! < $1.tally.perDayKm! }),
              high.id != low.id, let lowRate = low.tally.perDayKm, lowRate > 0,
              let highRate = high.tally.perDayKm else { return nil }
        let ratio = highRate / lowRate
        return ratio >= ParkedRules.notableRatio ? ParkedFinding(higher: high, lower: low, ratio: ratio) : nil
    }

    private static func days(_ stops: [IdleSummary], partial: Bool, from: Date?, to: Date?, now: Date,
                             calendar: Calendar) -> [ParkedDay] {
        guard !stops.isEmpty else { return [] }
        let today = calendar.startOfDay(for: now)
        let byDay = Dictionary(grouping: stops) { calendar.startOfDay(for: $0.end ?? $0.start) }
        let earliest = byDay.keys.min() ?? today
        // Before the earliest loaded stop nothing is known while pages remain.
        let first = partial ? earliest : min(earliest, from.map { calendar.startOfDay(for: $0) } ?? earliest)
        // A range that ended in the past stops at its own last day, not today:
        // the days after it are outside the range, not days without loss.
        let rangeEnd = to.map { calendar.startOfDay(for: $0.addingTimeInterval(-1)) } ?? today
        let last = max(min(today, rangeEnd), byDay.keys.max() ?? earliest)
        var days: [ParkedDay] = []
        var day = first
        while day <= last {
            let ended = byDay[day] ?? []
            let tally = ParkedTally(ended)
            days.append(ParkedDay(day: day, lostKm: ended.isEmpty ? 0 : tally.lost, stops: ended.count,
                                  isToday: calendar.isDate(day, inSameDayAs: now)))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        days = Array(days.suffix(ParkedRules.chartMaxDays))
        let values = days.compactMap(\.lostKm)
        if let top = values.max(), top > 0, let index = days.firstIndex(where: { $0.lostKm == top }) {
            let mean = values.reduce(0, +) / Double(values.count)
            days[index].isHighest = top >= mean * ParkedRules.notableRatio
        }
        return days
    }

    private static func asleep(_ stops: [IdleSummary]) -> ParkedAsleep? {
        let covered = stops.filter { $0.asleepMinutes != nil && $0.durationMin > 0 }
        guard !covered.isEmpty else { return nil }
        return ParkedAsleep(asleepMinutes: covered.reduce(0) { $0 + min($1.durationMin, max(0, $1.asleepMinutes ?? 0)) },
                            coveredMinutes: covered.reduce(0) { $0 + $1.durationMin },
                            coveredStops: covered.count, stops: stops.count)
    }
}

// MARK: - Wording

/// The Parked screen's words and numbers in the user's distance unit.
struct ParkedText {
    var units: UnitPreferences

    /// "12 mi" at ten or more, "1.7 mi" below.
    func distance(_ km: Double) -> String {
        let value = units.distanceValue(km: km)
        return "\(VoltaFormat.number(value, digits: value >= 9.95 ? 0 : 1)) \(units.distanceUnit)"
    }

    /// The bare number of `distance`, for "against 3.0".
    func number(_ km: Double) -> String {
        let value = units.distanceValue(km: km)
        return VoltaFormat.number(value, digits: value >= 9.95 ? 0 : 1)
    }

    /// "5.8 mi a day".
    func rate(_ kmPerDay: Double) -> String { "\(distance(kmPerDay)) a day" }

    /// A row's loss, always to a tenth, so a day's rows add up to its header.
    func rowValue(_ km: Double) -> Double { (units.distanceValue(km: km) * 10).rounded() / 10 }

    func rowDistance(_ km: Double) -> String { tenths(rowValue(km)) }

    private func tenths(_ value: Double) -> String { "\(VoltaFormat.number(value, digits: 1)) \(units.distanceUnit)" }

    /// The loss line under a stop's duration.
    func lossLine(_ loss: ParkedLoss) -> String {
        switch loss {
        case .pending: "Loss is measured when the car next drives or charges"
        case .notRecorded: "Loss not recorded"
        case .noLoss: "No loss measured"
        case .lost(let km, let rate):
            rowValue(km) < 0.05
                ? "Under 0.1 \(units.distanceUnit) lost"
                : (["−" + rowDistance(km)] + [rate.map(self.rate)].compactMap { $0 }).joined(separator: " · ")
        }
    }

    /// "2 stops · −2.1 mi": the sum of the rows as shown.
    func dayTotal(_ stops: [IdleSummary]) -> String {
        var parts = ["\(stops.count) \(stops.count == 1 ? "stop" : "stops")"]
        let recorded = stops.compactMap { ParkedTally([$0]).lost }
        if !recorded.isEmpty {
            let sum = recorded.reduce(0) { $0 + rowValue($1) }
            parts.append("−" + tenths(sum))
        }
        return parts.joined(separator: " · ")
    }

    /// "Recorded loss at Work was about twice Home's per day: 5.8 mi a day against 3.0."
    func finding(_ finding: ParkedFinding) -> (headline: String, detail: String) {
        let times: String
        let whole = Int(finding.ratio.rounded())
        if finding.ratio < 1.75 { times = "about 1.5 times" }
        else if whole == 2 { times = "about twice" }
        else { times = "about \(whole) times" }
        let lower = finding.lower.name
        let possessive = lower.hasSuffix("s") ? lower + "’" : lower + "’s"
        let high = finding.higher.tally.perDayKm ?? 0, low = finding.lower.tally.perDayKm ?? 0
        return ("Recorded loss at \(finding.higher.name) was \(times) \(possessive) per day.",
                "\(rate(high)) against \(number(low)).")
    }

    /// "3d 15h", "7h 4m" or "42m".
    static func span(_ minutes: Double) -> String {
        let total = Int(max(0, minutes).rounded())
        if total >= 1440 { return "\(total / 1440)d \(total % 1440 / 60)h" }
        return VoltaFormat.duration(Double(total))
    }

    /// Spoken form of `span`: "3 days 15 hours".
    static func spokenSpan(_ minutes: Double) -> String {
        let total = Int(max(0, minutes).rounded())
        let days = total / 1440, hours = total % 1440 / 60, mins = total % 60
        var parts: [String] = []
        if days > 0 { parts.append("\(days) \(days == 1 ? "day" : "days")") }
        if hours > 0 { parts.append("\(hours) \(hours == 1 ? "hour" : "hours")") }
        if days == 0 && (mins > 0 || parts.isEmpty) { parts.append("\(mins) \(mins == 1 ? "minute" : "minutes")") }
        return parts.joined(separator: " ")
    }
}
