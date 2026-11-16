import Foundation

// File formats Data Management writes on the phone. Values are metric with the
// unit in the column name, times are ISO 8601 in UTC, and an unknown value is
// an empty field, never zero.

// MARK: - CSV

enum CSVExport {
    /// RFC 4180: a field holding a comma, quote, CR or LF is quoted, with
    /// quotes doubled. Rows end in CRLF. Checked on Unicode scalars: Swift
    /// treats "\r\n" as one Character, equal to neither "\r" nor "\n".
    static func escape(_ field: String) -> String {
        guard field.unicodeScalars.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func row(_ fields: [String]) -> String {
        fields.map(escape).joined(separator: ",") + "\r\n"
    }

    static func document(header: [String], rows: [[String]]) -> String {
        row(header) + rows.map(row).joined()
    }

    /// Free text (addresses, place names). A leading `=`, `+`, `-`, `@`, tab or
    /// CR would make a spreadsheet read the cell as a formula, so such text is
    /// prefixed with an apostrophe. Numbers never go through here.
    static func text(_ value: String?) -> String {
        guard let value else { return "" }
        guard let first = value.unicodeScalars.first, "=+-@\t\r".unicodeScalars.contains(first) else { return value }
        return "'" + value
    }

    private static let posix = Locale(identifier: "en_US_POSIX")

    /// Plain decimal: no grouping, a dot, up to `digits` fraction digits.
    static func number(_ value: Double?, digits: Int = 3) -> String {
        guard let value, value.isFinite else { return "" }
        return value.formatted(.number.locale(posix).grouping(.never).precision(.fractionLength(0...max(0, digits))))
    }

    static func integer(_ value: Int?) -> String { value.map(String.init) ?? "" }

    static func bool(_ value: Bool?) -> String { value.map { $0 ? "true" : "false" } ?? "" }

    static func date(_ value: Date?) -> String {
        value.map { $0.formatted(.iso8601) } ?? ""
    }

    static func drives(_ drives: [DriveSummary]) -> String {
        document(header: ["id", "start_utc", "end_utc", "start_address", "end_address", "distance_km", "duration_min",
                          "start_battery_pct", "end_battery_pct", "energy_used_kwh", "efficiency_wh_per_km",
                          "avg_speed_kph", "max_speed_kph", "outside_temp_avg_c", "drive_score"],
                 rows: drives.sorted { $0.start < $1.start }.map { d in
                     [String(d.id), date(d.start), date(d.end), text(d.startAddress), text(d.endAddress),
                      number(d.distanceKm), number(d.durationMin, digits: 1), integer(d.startBatteryLevel), integer(d.endBatteryLevel),
                      number(d.energyUsedKwh), number(d.efficiencyWhPerKm, digits: 1), number(d.avgSpeedKph, digits: 1),
                      number(d.maxSpeedKph, digits: 1), number(d.outsideTempAvgC, digits: 1), integer(d.driveScore)]
                 })
    }

    static func charges(_ charges: [ChargeSummary]) -> String {
        document(header: ["id", "start_utc", "end_utc", "place_name", "address", "energy_added_kwh", "energy_used_kwh",
                          "energy_from_grid_kwh", "start_battery_pct", "end_battery_pct", "duration_min", "max_power_kw",
                          "avg_power_kw", "dc_fast", "cost", "currency", "outside_temp_avg_c", "source"],
                 rows: charges.sorted { $0.start < $1.start }.map { c in
                     [String(c.id), date(c.start), date(c.end), text(c.placeName), text(c.address), number(c.energyAddedKwh),
                      number(c.energyUsedKwh), number(c.energyFromGridKwh), integer(c.startBatteryLevel), integer(c.endBatteryLevel),
                      number(c.durationMin, digits: 1), number(c.maxPowerKw, digits: 1), number(c.avgPowerKw, digits: 1),
                      bool(c.fastCharger), number(c.cost, digits: 2), text(c.cost == nil ? nil : c.currency),
                      number(c.outsideTempAvgC, digits: 1), text(c.source)]
                 })
    }

    static func idles(_ idles: [IdleSummary]) -> String {
        document(header: ["id", "start_utc", "end_utc", "place_name", "address", "duration_min", "start_battery_pct",
                          "end_battery_pct", "range_lost_km", "energy_lost_kwh", "sentry_min", "climate_min", "asleep_min"],
                 rows: idles.sorted { $0.start < $1.start }.map { i in
                     [String(i.id), date(i.start), date(i.end), text(i.placeName), text(i.address), number(i.durationMin, digits: 1),
                      integer(i.startBatteryLevel), integer(i.endBatteryLevel), number(i.rangeLostKm), number(i.energyLostKwh),
                      number(i.sentryMinutes, digits: 1), number(i.climateMinutes, digits: 1), number(i.asleepMinutes, digits: 1)]
                 })
    }
}

// MARK: - GPX

enum GPXExport {
    struct Point: Equatable {
        var t: Date
        var latitude: Double
        var longitude: Double
        var elevationM: Double?
        var breakBefore: Bool
    }

    /// Longer than this between two positions is a gap in the recording: the
    /// same threshold the trip screens use, so no line crosses missing data.
    static let gapThreshold = TripTimeline.gapThreshold

    /// The drive's recorded positions: TeslaMate's path, or, when that is
    /// empty, the Fleet Telemetry samples that carry a position. Invalid
    /// coordinates are dropped. `breakBefore` is set at a recorded break, a gap
    /// longer than `gapThreshold`, and after a dropped point that carried a break.
    static func points(_ detail: DriveDetail) -> [Point] {
        let path = detail.path.map {
            Point(t: $0.t, latitude: $0.latitude, longitude: $0.longitude, elevationM: $0.elevationM, breakBefore: $0.routeBreakBefore ?? false)
        }
        let telemetry = (detail.telemetry?.samples ?? []).map { s in
            Point(t: s.t, latitude: s.latitude ?? .nan, longitude: s.longitude ?? .nan, elevationM: s.elevationM, breakBefore: s.routeBreakBefore)
        }
        var result: [Point] = []
        var pendingBreak = false
        for var point in (path.isEmpty ? telemetry : path).sorted(by: { $0.t < $1.t }) {
            guard isValid(point) else {
                pendingBreak = pendingBreak || point.breakBefore
                continue
            }
            let gap = result.last.map { point.t.timeIntervalSince($0.t) > gapThreshold } ?? false
            point.breakBefore = !result.isEmpty && (point.breakBefore || pendingBreak || gap)
            pendingBreak = false
            result.append(point)
        }
        return result
    }

    private static func isValid(_ p: Point) -> Bool {
        p.latitude.isFinite && p.longitude.isFinite && abs(p.latitude) <= 90 && abs(p.longitude) <= 180
            && !(p.latitude == 0 && p.longitude == 0)
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
    }

    private static func coordinate(_ value: Double) -> String { CSVExport.number(value, digits: 7) }

    /// GPX 1.1 with one track; a new segment starts at every break `points` marks.
    /// nil when the drive has no recorded position.
    static func document(_ detail: DriveDetail, name: String) -> String? {
        let points = points(detail)
        guard !points.isEmpty else { return nil }
        var segments: [[Point]] = [[]]
        for point in points {
            if point.breakBefore, !(segments.last?.isEmpty ?? true) { segments.append([]) }
            segments[segments.count - 1].append(point)
        }
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="Volta" xmlns="http://www.topografix.com/GPX/1/1">
          <metadata>
            <name>\(escape(name))</name>
            <time>\(CSVExport.date(detail.summary.start))</time>
          </metadata>
          <trk>
            <name>\(escape(name))</name>

        """
        for segment in segments {
            xml += "    <trkseg>\n"
            for p in segment {
                xml += "      <trkpt lat=\"\(coordinate(p.latitude))\" lon=\"\(coordinate(p.longitude))\">"
                if let ele = p.elevationM, ele.isFinite { xml += "<ele>\(CSVExport.number(ele, digits: 1))</ele>" }
                xml += "<time>\(CSVExport.date(p.t))</time></trkpt>\n"
            }
            xml += "    </trkseg>\n"
        }
        xml += "  </trk>\n</gpx>\n"
        return xml
    }

    /// "Volta drive 2026-10-01 14:05" in the phone's time zone; no addresses.
    static func name(for drive: DriveSummary, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        "Volta drive " + stamp(drive.start, timeZone: timeZone, format: "yyyy-MM-dd HH:mm")
    }

    static func fileName(for drive: DriveSummary, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        "volta-drive-\(stamp(drive.start, timeZone: timeZone, format: "yyyy-MM-dd-HHmm")).gpx"
    }

    private static func stamp(_ date: Date, timeZone: TimeZone, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter.string(from: date)
    }
}
