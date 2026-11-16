import Foundation

/// Tyre pressure history shaped for the Tires screen: periods, the plotted
/// statistic, segments that break at every gap, the change over the period,
/// and a wheel that reads apart from the others. Pure and unit-tested; the
/// view only draws what this returns. Pressures stay in bar here; the view
/// converts with the app's pressure unit.
enum TireHistoryMath {
    enum Period: String, CaseIterable, Hashable, Sendable {
        case month = "30D", quarter = "90D", year = "1Y", all = "All"
        var days: Int? {
            switch self {
            case .month: 30
            case .quarter: 90
            case .year: 365
            case .all: nil
            }
        }
        var title: String {
            switch self {
            case .month: "last 30 days"
            case .quarter: "last 90 days"
            case .year: "last 12 months"
            case .all: "all recorded history"
            }
        }

        /// Local midnight `days - 1` days before today, so today counts as a day.
        func from(now: Date, calendar: Calendar) -> Date? {
            days.flatMap { calendar.date(byAdding: .day, value: -$0 + 1, to: calendar.startOfDay(for: now)) }
        }
    }

    /// Which reading of each day the line follows. The day's lowest reading is
    /// usually the one taken coldest, before driving warms the tyres, so it is
    /// the closest the record gets to a cold pressure. It is still a reading,
    /// not a placard pressure.
    enum Statistic: String, CaseIterable, Hashable, Sendable {
        case low = "Daily low", average = "Average"
        func value(_ p: TirePressureHistory.Point) -> Double { self == .low ? p.minBar : p.avgBar }

        /// The line's name for buckets of this size: weekly buckets hold a
        /// week's lowest or mean reading, not a day's.
        func title(_ bucket: TirePressureHistory.Bucket) -> String {
            switch (self, bucket) {
            case (.low, .day): "Daily low"
            case (.low, .week): "Weekly low"
            case (.average, .day): "Daily average"
            case (.average, .week): "Weekly average"
            }
        }
    }

    /// What the Maintenance rotation item says is due. Either interval can
    /// fall due first, so a reached deadline always wins: 600 miles left does
    /// not hide a date two weeks past.
    struct RotationStatus: Hashable, Sendable {
        var text: String
        var isDue: Bool
    }

    static func rotationStatus(remainingKm: Double?, remainingDays: Int?, distance: (Double) -> String) -> RotationStatus {
        func days(_ n: Int) -> String { "\(n) day\(n == 1 ? "" : "s")" }
        var past: [String] = []
        if let km = remainingKm, km <= 0 { past.append("\(distance(-km)) past the distance") }
        if let d = remainingDays, d < 0 { past.append("\(days(-d)) past the date") }
        if !past.isEmpty { return RotationStatus(text: "Due: " + past.joined(separator: ", "), isDue: true) }
        if remainingDays == 0 { return RotationStatus(text: "Due today", isDue: true) }
        switch (remainingKm, remainingDays) {
        case let (km?, d?): return RotationStatus(text: "Due in \(distance(km)) or \(days(d)), whichever comes first", isDue: false)
        case let (km?, nil): return RotationStatus(text: "Due in \(distance(km))", isDue: false)
        case let (nil, d?): return RotationStatus(text: "Due in \(days(d))", isDue: false)
        case (nil, nil): return RotationStatus(text: "Due unknown. Record the last rotation in Maintenance.", isDue: false)
        }
    }

    struct Plot: Hashable, Sendable, Identifiable {
        var id: Int
        var start: Date
        var bar: Double
        var lowBar: Double
        var highBar: Double
        var readings: Int
        var segment: Int
    }

    /// The calendar the server bucketed in, so a missing day is measured in
    /// the same days the buckets were made of.
    static func calendar(for history: TirePressureHistory, fallback: Calendar = .current) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = history.timeZone.flatMap(TimeZone.init(identifier:)) ?? fallback.timeZone
        return calendar
    }

    /// Points in time order with a new segment wherever a bucket is missing
    /// between two recorded ones: a line never bridges days without readings.
    static func plots(_ points: [TirePressureHistory.Point], bucket: TirePressureHistory.Bucket,
                      statistic: Statistic, calendar: Calendar) -> [Plot] {
        let sorted = points.filter { $0.minBar.isFinite && $0.avgBar.isFinite && $0.maxBar.isFinite }.sorted { $0.start < $1.start }
        let step = bucket == .week ? 7 : 1
        var segment = 0
        var out: [Plot] = []
        for (index, p) in sorted.enumerated() {
            if index > 0 {
                let previous = sorted[index - 1].start
                let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: previous),
                                                   to: calendar.startOfDay(for: p.start)).day ?? .max
                if days > step { segment += 1 }
            }
            out.append(Plot(id: index, start: p.start, bar: statistic.value(p), lowBar: p.minBar, highBar: p.maxBar,
                            readings: p.readings, segment: segment))
        }
        return out
    }

    /// Plots that have no neighbour in their segment: drawn as dots, since a
    /// line needs two points.
    static func isolated(_ plots: [Plot]) -> [Plot] {
        let counts = Dictionary(grouping: plots, by: \.segment).mapValues(\.count)
        return plots.filter { counts[$0.segment] == 1 }
    }

    struct Change: Hashable, Sendable {
        var deltaBar: Double
        var from: Date
        var to: Date
        /// Calendar days from the first reading to the last, counting both ends:
        /// a first reading 89 days before the last is a change "in 90 days".
        /// Counted from the readings, not bucket starts, so a weekly bucket
        /// whose readings began on its Sunday counts from that Sunday.
        var days: Int
    }

    /// First recorded value against the last in the period. Nil with fewer
    /// than two recorded buckets.
    static func change(_ points: [TirePressureHistory.Point], statistic: Statistic, calendar: Calendar) -> Change? {
        let sorted = points.sorted { $0.start < $1.start }
        guard let first = sorted.first, let last = sorted.last, last.start > first.start else { return nil }
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: first.firstAt),
                                           to: calendar.startOfDay(for: last.lastAt)).day ?? 0
        return Change(deltaBar: statistic.value(last) - statistic.value(first), from: first.start, to: last.start, days: days + 1)
    }

    /// The wheels that dropped at least `apartThresholdBar` more than the
    /// median of the others, measured between the first and last buckets every
    /// reporting wheel shares. Comparing each wheel's own first and last would
    /// flag a wheel merely for having readings before a cold spell the others
    /// missed; a seasonal drop moves every tyre together and marks none.
    static func unusualDrops(_ history: TirePressureHistory, statistic: Statistic) -> Set<TireWheel> {
        let present = TireWheel.allCases.filter { !history.wheels[$0].isEmpty }
        guard present.count >= 2 else { return [] }
        let byWheel = Dictionary(uniqueKeysWithValues: present.map { wheel in
            (wheel, Dictionary(history.wheels[wheel].map { ($0.start, $0) }, uniquingKeysWith: { _, last in last }))
        })
        let shared = present.dropFirst().reduce(Set(byWheel[present[0]]!.keys)) { $0.intersection(byWheel[$1]!.keys) }.sorted()
        guard let first = shared.first, let last = shared.last, last > first else { return [] }
        let deltas = Dictionary(uniqueKeysWithValues: present.map { wheel in
            (wheel, statistic.value(byWheel[wheel]![last]!) - statistic.value(byWheel[wheel]![first]!))
        })
        var result = Set<TireWheel>()
        for (wheel, delta) in deltas {
            let others = deltas.filter { $0.key != wheel }.map(\.value).sorted()
            let median = others.count.isMultiple(of: 2) ? (others[others.count / 2 - 1] + others[others.count / 2]) / 2 : others[others.count / 2]
            if delta <= -apartThresholdBar + 1e-9, delta - median <= -apartThresholdBar + 1e-9 { result.insert(wheel) }
        }
        return result
    }

    /// Readings closer than this to the others are ordinary sensor spread.
    static let apartThresholdBar = 0.2
    /// Same-moment readings a bucket needs before its comparison counts.
    static let minPeerReadings = 10
    /// Consecutive buckets a wheel must read apart in before it is flagged:
    /// three days, or two weeks.
    static func persistence(_ bucket: TirePressureHistory.Bucket) -> Int { bucket == .week ? 2 : 3 }

    struct Apart: Hashable, Sendable {
        var wheel: TireWheel
        /// This wheel minus the others, read at the same moments (negative: lower).
        var deltaBar: Double
        /// This wheel's and the others' mean over those same-moment readings.
        var wheelBar: Double
        var othersBar: Double
        /// The newest bucket in the run.
        var on: Date
        /// Buckets in a row the wheel has read apart.
        var buckets: Int
        /// How many other tyres took part in every comparison of the run; nil
        /// when that varied or the server did not say.
        var otherWheels: Int? = nil
    }

    /// The wheel that has read at least `apartThresholdBar` from the other
    /// tyres, compared at the same moments (never one wheel's daily low against
    /// another's), in each of the last `persistence` buckets in a row, the
    /// newest being the latest or the one before it. Buckets with fewer than
    /// `minPeerReadings` same-moment readings do not count. The furthest apart
    /// wins.
    static func apart(_ history: TirePressureHistory, calendar: Calendar) -> Apart? {
        let step = history.bucket == .week ? 7 : 1, need = persistence(history.bucket)
        guard let newest = TireWheel.allCases.flatMap({ history.wheels[$0].map(\.start) }).max() else { return nil }
        func daysBetween(_ a: Date, _ b: Date) -> Int {
            calendar.dateComponents([.day], from: calendar.startOfDay(for: a), to: calendar.startOfDay(for: b)).day ?? .max
        }
        var best: Apart?
        for wheel in TireWheel.allCases {
            let covered = history.wheels[wheel]
                .filter { ($0.peerReadings ?? 0) >= minPeerReadings && $0.peerDeltaBar?.isFinite == true && $0.peerBar?.isFinite == true }
                .sorted { $0.start > $1.start }
            guard covered.count >= need, daysBetween(covered[0].start, newest) <= step else { continue }
            let run = Array(covered.prefix(need))
            let deltas = run.compactMap(\.peerDeltaBar)
            guard zip(run, run.dropFirst()).allSatisfy({ daysBetween($1.start, $0.start) == step }),
                  deltas.allSatisfy({ abs($0) >= apartThresholdBar - 1e-9 }),
                  deltas.allSatisfy({ ($0 < 0) == (deltas[0] < 0) }),
                  let delta = run[0].peerDeltaBar, let others = run[0].peerBar else { continue }
            if best.map({ abs(delta) > abs($0.deltaBar) }) ?? true {
                let counts = run.map(\.peerWheels)
                best = Apart(wheel: wheel, deltaBar: delta, wheelBar: others + delta, othersBar: others, on: run[0].start, buckets: need,
                             otherWheels: counts.allSatisfy { $0 != nil && $0 == counts[0] } ? counts[0] : nil)
            }
        }
        return best
    }

    /// The banner for a wheel reading apart: the same-moment gap, both
    /// values, and the wheel's own change over the period when it moved. The
    /// gap is the difference of the two values as shown, so the sentence never
    /// disagrees with its own numbers.
    /// `isCurrent` means the run ends in the current day (or week, for weekly
    /// buckets), which reads "today" ("this week").
    static func apartMessage(_ apart: Apart, change: Change?, isCurrent: Bool,
                             bucket: TirePressureHistory.Bucket = .day, units: UnitPreferences) -> String {
        let wheelShown = displayed(apart.wheelBar, units: units), othersShown = displayed(apart.othersBar, units: units)
        let gap = othersShown - wheelShown
        let digits = units.pressure == .bar ? 1 : 0
        func number(_ v: Double) -> String { VoltaFormat.number(v, digits: digits) }
        let others = switch apart.otherWheels {
        case 3?: "the other three"
        case 2?: "the other two"
        default: "the other tires"
        }
        let date = apart.on.formatted(.dateTime.month(.abbreviated).day())
        let when = switch (bucket, isCurrent) {
        case (.day, true): "today"
        case (.day, false): "on \(date)"
        case (.week, true): "this week"
        case (.week, false): "in the week of \(date)"
        }
        var sentence = "\(apart.wheel.title) is \(number(abs(gap))) \(units.pressureUnit) \(gap > 0 ? "below" : "above") \(others) \(when) (\(number(wheelShown)) vs \(number(othersShown)) \(units.pressureUnit))"
        if let change, displayed(abs(change.deltaBar), units: units) > 0 {
            sentence += " and has \(change.deltaBar < 0 ? "dropped" : "risen") \(pressureText(abs(change.deltaBar), units: units)) in \(change.days) day\(change.days == 1 ? "" : "s")"
        }
        return sentence + ". Check it with a gauge when cold."
    }

    /// Bar span for the chart: the recorded low/high values and the low-guide
    /// line, padded, never collapsing to a point.
    static func yDomain(_ plots: [Plot], guide: Double?) -> ClosedRange<Double> {
        let values = plots.flatMap { [$0.lowBar, $0.highBar, $0.bar] } + (guide.map { [$0] } ?? [])
        guard let lo = values.min(), let hi = values.max() else { return 2...3.5 }
        let pad = max(0.1, (hi - lo) * 0.15)
        return (lo - pad)...(hi + pad)
    }

    /// Bar to one decimal (TeslaMate's resolution), psi to whole pounds. A
    /// signed change shows + or −, and a change that rounds to nothing shows 0.
    static func pressureText(_ bar: Double, units: UnitPreferences, signed: Bool = false) -> String {
        let digits = units.pressure == .bar ? 1 : 0
        let value = displayed(bar, units: units)
        let sign = value < 0 ? "−" : signed && value > 0 ? "+" : ""
        return "\(sign)\(VoltaFormat.number(abs(value), digits: digits)) \(units.pressureUnit)"
    }

    /// A pressure in the app's unit, rounded as it is shown: bar to one
    /// decimal, psi to whole pounds.
    static func displayed(_ bar: Double, units: UnitPreferences) -> Double {
        let scale = units.pressure == .bar ? 10.0 : 1.0
        return (units.pressureValue(bar: bar) * scale).rounded() / scale
    }

    /// The service item that tracks tyre rotation, if the owner keeps one.
    static func rotationItem(_ items: [ServiceItem]) -> ServiceItem? {
        items.first { item in
            let name = item.name.lowercased()
            return name.contains("rotation") || name.contains("rotate")
        }
    }
}
