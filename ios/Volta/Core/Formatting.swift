import Foundation
import SwiftUI
import Synchronization

struct UnitPreferences: Codable, Hashable, Sendable {
    enum Distance: String, Codable, Sendable, CaseIterable { case miles, kilometers }
    enum Pressure: String, Codable, Sendable, CaseIterable { case psi, bar }
    enum Temperature: String, Codable, Sendable, CaseIterable { case fahrenheit, celsius }
    var distance: Distance = .miles
    var temperature: Temperature = .fahrenheit
    var pressure: Pressure? = nil
    var currency: String = "USD"
    static let `default` = UnitPreferences()

    var pressureUnit: String { pressure == .bar ? "bar" : "psi" }
    func pressureValue(bar: Double) -> Double { pressure == .bar ? bar : bar * 14.5037738 }
    var distanceUnit: String { distance == .miles ? "mi" : "km" }
    var temperatureUnit: String { temperature == .fahrenheit ? "°F" : "°C" }
    var efficiencyUnit: String { distance == .miles ? "Wh/mi" : "Wh/km" }
    func distanceValue(km: Double) -> Double { distance == .miles ? km / 1.609344 : km }
    func temperatureValue(celsius: Double) -> Double { temperature == .fahrenheit ? celsius * 9 / 5 + 32 : celsius }
    func efficiencyValue(whPerKm: Double) -> Double { distance == .miles ? whPerKm * 1.609344 : whPerKm }
    func formatDistance(_ km: Double?, fractionDigits: Int = 1) -> String {
        guard let km else { return "—" }
        return "\(VoltaFormat.number(distanceValue(km: km), digits: fractionDigits)) \(distanceUnit)"
    }
    func formatTemperature(_ celsius: Double?) -> String {
        guard let celsius else { return "—" }
        return "\(VoltaFormat.number(temperatureValue(celsius: celsius), digits: 0))\(temperatureUnit)"
    }
    func formatEfficiency(_ whPerKm: Double?) -> String {
        guard let whPerKm else { return "—" }
        return "\(VoltaFormat.number(efficiencyValue(whPerKm: whPerKm), digits: 0)) \(efficiencyUnit)"
    }
}

private struct UnitsKey: EnvironmentKey { static let defaultValue = UnitPreferences.default }
extension EnvironmentValues {
    var units: UnitPreferences {
        get { self[UnitsKey.self] }
        set { self[UnitsKey.self] = newValue }
    }
}

enum VoltaFormat {
    static func number(_ value: Double, digits: Int = 1) -> String {
        value.formatted(.number.precision(.fractionLength(max(0, digits))))
    }
    static func distance(_ km: Double?, units: UnitPreferences = .default, fractionDigits: Int = 1) -> String {
        units.formatDistance(km, fractionDigits: fractionDigits)
    }
    static func temperature(_ celsius: Double?, units: UnitPreferences = .default) -> String { units.formatTemperature(celsius) }
    static func energy(_ kwh: Double?, fractionDigits: Int = 1) -> String {
        guard let kwh else { return "—" }; return "\(number(kwh, digits: fractionDigits)) kWh"
    }
    static func efficiency(_ whPerKm: Double?, units: UnitPreferences = .default) -> String { units.formatEfficiency(whPerKm) }
    static func duration(minutes: Double?) -> String {
        guard let minutes else { return "—" }
        let total = Int(max(0, minutes).rounded())
        return total >= 60 ? "\(total / 60)h \(total % 60)m" : "\(total)m"
    }
    static func duration(_ minutes: Double?) -> String { duration(minutes: minutes) }
    /// Spelled-out duration for detail lines: "28 min", "1 h 5 min".
    static func longDuration(_ minutes: Double?) -> String {
        guard let minutes else { return "—" }
        let total = Int(max(0, minutes).rounded())
        return total >= 60 ? "\(total / 60) h \(total % 60) min" : "\(total) min"
    }
    static func relativeDate(_ date: Date, now: Date = .now) -> String {
        let formatter = RelativeDateTimeFormatter(); formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }
    static func money(_ amount: Double?, currency: String = "USD") -> String {
        guard let amount else { return "—" }; return amount.formatted(.currency(code: currency))
    }
    /// Clock time, always 24-hour ("14:05") whatever the locale's 12/24-hour
    /// default; digits and separator still follow the locale.
    static func clock(_ date: Date, timeZone: TimeZone = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) -> String {
        formatter(template: "HHmm", timeZone: timeZone, locale: locale).string(from: date)
    }
    /// Abbreviated date with a 24-hour time, e.g. "Oct 9, 2026, 14:05".
    static func dateTime(_ date: Date, timeZone: TimeZone = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) -> String {
        formatter(template: "yMMMdHHmm", timeZone: timeZone, locale: locale).string(from: date)
    }
    /// Month, day and a 24-hour time, e.g. "Oct 9, 14:05".
    static func dayTime(_ date: Date, timeZone: TimeZone = .autoupdatingCurrent, locale: Locale = .autoupdatingCurrent) -> String {
        formatter(template: "MMMdHHmm", timeZone: timeZone, locale: locale).string(from: date)
    }
    private static func formatter(template: String, timeZone: TimeZone, locale: Locale) -> DateFormatter {
        // An explicit `H` skeleton keeps the 24-hour cycle; `j` would follow the locale.
        cachedFormatter(template: template, locale: locale, timeZone: timeZone)
    }

    private struct FormatterKey: Hashable {
        var template: String, locale: String, timeZone: String, calendar: String?
    }
    private struct FormatterCache: @unchecked Sendable {
        // DateFormatter is thread-safe for formatting; it is never mutated
        // after it is stored here.
        var formatters: [FormatterKey: DateFormatter] = [:]
    }
    private static let formatters = Mutex(FormatterCache())

    /// A `DateFormatter` for a localized template, built once per template,
    /// locale, time zone and calendar. Building one and resolving its template
    /// costs about 90 µs; reusing it about 1 µs. Keys use identifiers, so a
    /// change of the device's locale or time zone gets a fresh formatter, as
    /// building one per call did.
    static func cachedFormatter(template: String, locale: Locale, timeZone: TimeZone, calendar: Calendar? = nil) -> DateFormatter {
        let key = FormatterKey(template: template, locale: locale.identifier, timeZone: timeZone.identifier,
                               calendar: calendar.map { "\($0.identifier)" })
        return formatters.withLock { cache in
            if let formatter = cache.formatters[key] { return formatter }
            let formatter = DateFormatter()
            formatter.locale = locale
            if let calendar { formatter.calendar = calendar }
            formatter.timeZone = timeZone
            formatter.setLocalizedDateFormatFromTemplate(template)
            cache.formatters[key] = formatter
            return formatter
        }
    }
}

/// `VoltaFormat.clock` as a format style, for chart axis labels.
struct VoltaClockFormat: FormatStyle {
    func format(_ value: Date) -> String { VoltaFormat.clock(value) }
}

extension FormatStyle where Self == VoltaClockFormat {
    static var voltaClock: VoltaClockFormat { VoltaClockFormat() }
}
