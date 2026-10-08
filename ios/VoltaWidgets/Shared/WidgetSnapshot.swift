import Foundation

// Compiled into BOTH the Volta app target and the VoltaWidgets extension.
// Keep this file Foundation-only and independent of ios/Volta/Core so the
// extension never has to compile app code. Values are metric; the snapshot
// carries the user's display units so widgets format exactly like the app.

enum VoltaAppGroup {
    static let identifier = "group.com.georgenijo.volta"
    /// Shared keychain access group (team-prefixed at runtime). Reserved for a
    /// future widget-side network refresh; see VoltaWidgets/README.md.
    static let keychainAccessGroupSuffix = "com.georgenijo.volta.shared"
}

/// Everything a widget needs, written by the app after each successful refresh.
struct WidgetSnapshot: Codable, Hashable, Sendable {
    static let currentVersion = 1

    enum State: String, Codable, Sendable {
        case online, asleep, offline, driving, charging, updating
    }
    enum Charging: String, Codable, Sendable {
        case disconnected, stopped, charging, complete
    }
    enum SegmentKind: String, Codable, Sendable {
        case drive, charge, idle, asleep, offline
    }
    enum DistanceUnit: String, Codable, Sendable { case miles, kilometers }
    enum TemperatureUnit: String, Codable, Sendable { case fahrenheit, celsius }

    struct Today: Codable, Hashable, Sendable {
        var distanceKm: Double
        var driveCount: Int
        var chargeCount: Int
        var energyUsedKwh: Double?
        var efficiencyWhPerKm: Double?
        var energyAddedKwh: Double?
    }

    struct Segment: Codable, Hashable, Sendable {
        var kind: SegmentKind
        var start: Date
        var end: Date
    }

    var version: Int = WidgetSnapshot.currentVersion
    var vehicleId: Int
    var vehicleName: String
    var state: State
    /// When the vehicle data was recorded (VehicleStatus.updatedAt).
    var updatedAt: Date
    /// When the app wrote this snapshot.
    var writtenAt: Date
    var batteryLevel: Int
    var chargeLimit: Int?
    var estRangeKm: Double?
    var ratedRangeKm: Double?
    var chargingState: Charging?
    var chargerPowerKw: Double?
    var minutesToFull: Int?
    var insideTempC: Double?
    var outsideTempC: Double?
    var climateOn: Bool?
    var locked: Bool?
    var sentryMode: Bool?
    var placeName: String?
    var today: Today?
    /// Start of the reporting day `today` covers (see `ReportingDay`). Totals
    /// from another day are never shown as "Today"; nil means unknown.
    var todayDay: Date? = nil
    /// End (exclusive) of that day, computed by the app from the server's
    /// period so the extension needs no time-zone logic. Absent in snapshots
    /// written before `/summary` took `tz`; see `todayReportingDay`.
    var todayDayEnd: Date? = nil
    /// Device zone the local day was computed for; nil for UTC-rule days.
    var todayZone: String? = nil
    /// Last 48h, oldest first.
    var timeline: [Segment]
    var distanceUnit: DistanceUnit = .miles
    var temperatureUnit: TemperatureUnit = .fahrenheit

    var isCharging: Bool { chargingState == .charging || state == .charging }
    /// Range shown in widgets: estimated, falling back to rated.
    var rangeKm: Double? { estRangeKm ?? ratedRangeKm }

    /// Vehicle data older than this is shown as stale in every widget family.
    static let staleAfter: TimeInterval = 3600
    /// The moment this snapshot's vehicle data turns stale.
    var staleAt: Date { updatedAt.addingTimeInterval(Self.staleAfter) }
    func isStale(at now: Date) -> Bool { now >= staleAt }
    func age(at now: Date) -> TimeInterval { max(0, now.timeIntervalSince(updatedAt)) }

    /// The stored reporting day of `today`. Snapshots without `todayDayEnd`
    /// come from builds that only knew the UTC day, so that rule still applies.
    var todayReportingDay: ReportingDay.Day? {
        guard let todayDay else { return nil }
        guard let todayDayEnd else { return ReportingDay.Day(interval: ReportingDay.utcDay(containing: todayDay), zone: nil) }
        guard todayDayEnd > todayDay else { return nil }
        return ReportingDay.Day(interval: DateInterval(start: todayDay, end: todayDayEnd), zone: todayZone)
    }

    /// Today's totals if they are current at `now` in `deviceZone`, else nil.
    func todayTotals(at now: Date, deviceZone: String = TimeZone.current.identifier) -> Today? {
        guard let today, todayReportingDay?.isCurrent(at: now, deviceZone: deviceZone) == true else { return nil }
        return today
    }

    /// Timeline entry dates for the widget provider: regular steps (so the
    /// "updated … ago" text advances) plus the exact moments the data turns
    /// stale and the reporting day ends, so both show up on time.
    static func timelineDates(now: Date, snapshot: WidgetSnapshot?, count: Int = 4) -> [Date] {
        let step: TimeInterval = snapshot?.isCharging == true ? 5 * 60 : 10 * 60
        var dates = (0..<max(1, count)).map { now.addingTimeInterval(Double($0) * step) }
        let last = dates.last!
        var boundaries: [Date] = []
        if let staleAt = snapshot?.staleAt { boundaries.append(staleAt) }
        // Zone changes can't be scheduled; the app reloads widgets when one happens.
        if let dayEnd = snapshot?.todayReportingDay?.interval.end { boundaries.append(dayEnd) }
        for date in boundaries where date > now && date < last && !dates.contains(date) {
            dates.append(date)
        }
        return dates.sorted()
    }
}

/// The reporting day behind "Today" totals. The ONLY place that defines it.
///
/// The app sends `tz` (device zone) to `/summary`; servers that support it
/// count "today" from local midnight and report `periodStart` + `timeZone`,
/// so the day is [periodStart, next midnight in that zone) — 23 or 25 hours
/// on DST days. Older servers ignore `tz`, count from UTC midnight and report
/// no period, so the day is the UTC day containing the request start (in New
/// York that ends at 19:00/20:00 local). The app stores the resulting bounds
/// in the snapshot; the extension only compares instants against them.
///
/// A local day is only "today" in the zone it was computed for: after the
/// device changes zone (travel), its totals are unknown until a refresh in
/// the new zone. UTC-rule days don't depend on the device zone.
enum ReportingDay {
    struct Day: Hashable, Sendable {
        var interval: DateInterval
        /// Device zone the day was requested in; nil for UTC-rule days.
        var zone: String?

        /// Half-open: the end instant already belongs to the next day.
        func isCurrent(at date: Date, deviceZone: String = TimeZone.current.identifier) -> Bool {
            ReportingDay.contains(interval, date) && (zone == nil || zone == deviceZone)
        }
    }

    static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// The day `/summary?range=today` totals cover. `requestedAt`/`requestedZone`
    /// are when and in which device zone (the `tz` sent) the request started.
    /// The device zone, not the server's possibly canonicalized name, is
    /// stored, so it compares with `TimeZone.current` at read time.
    static func day(periodStart: Date?, timeZone: String?, requestedAt: Date, requestedZone: String) -> Day {
        guard periodStart != nil, timeZone != nil else {
            return Day(interval: utcDay(containing: requestedAt), zone: nil)
        }
        return Day(interval: interval(periodStart: periodStart, timeZone: timeZone, requestedAt: requestedAt), zone: requestedZone)
    }

    /// Bounds of that day: [periodStart, next midnight in `timeZone`), or the
    /// UTC day of `requestedAt` when the server reports no period.
    static func interval(periodStart: Date?, timeZone identifier: String?, requestedAt: Date) -> DateInterval {
        guard let periodStart, let identifier else { return utcDay(containing: requestedAt) }
        // The server echoes the zone the app sent (possibly canonicalized);
        // an identifier this OS doesn't know is the device's own zone.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier) ?? .current
        // Next local midnight, or the day's first instant where midnight is skipped.
        guard let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: periodStart)) else {
            return utcDay(containing: requestedAt)
        }
        let end = calendar.startOfDay(for: tomorrow)
        return end > periodStart ? DateInterval(start: periodStart, end: end) : utcDay(containing: requestedAt)
    }

    /// Legacy rule for servers without `tz`: the UTC day containing `date`.
    static func utcDay(containing date: Date) -> DateInterval {
        let start = utcCalendar.startOfDay(for: date)
        let end = utcCalendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return DateInterval(start: start, end: end)
    }

    /// Half-open: the end instant already belongs to the next day.
    static func contains(_ day: DateInterval, _ date: Date) -> Bool {
        day.start <= date && date < day.end
    }
}

/// Reads and writes the snapshot in the App Group container.
enum WidgetSnapshotStore {
    static let fileName = "widget-snapshot.json"
    /// WidgetKit `kind`s, so the app can reload specific widgets if it wants.
    static let homeWidgetKind = "VoltaHomeWidget"
    static let accessoryWidgetKind = "VoltaAccessoryWidget"

    static var fileURL: URL? {
        FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: VoltaAppGroup.identifier)?
            .appendingPathComponent(fileName)
    }

    static func write(_ snapshot: WidgetSnapshot) throws {
        guard let url = fileURL else { throw CocoaError(.fileNoSuchFile) }
        let data = try encoder.encode(snapshot)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    static func read() -> WidgetSnapshot? {
        guard let url = fileURL, let data = try? Data(contentsOf: url) else { return nil }
        guard let snapshot = try? decoder.decode(WidgetSnapshot.self, from: data),
              snapshot.version == WidgetSnapshot.currentVersion else { return nil }
        return snapshot
    }

    /// Call when the device is unpaired so widgets stop showing private data.
    static func clear() {
        guard let url = fileURL else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }
    private static var decoder: JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }
}
