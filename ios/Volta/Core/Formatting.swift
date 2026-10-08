import Foundation
import SwiftUI

struct UnitPreferences: Codable, Hashable, Sendable {
    enum Distance: String, Codable, Sendable, CaseIterable { case miles, kilometers }
    enum Temperature: String, Codable, Sendable, CaseIterable { case fahrenheit, celsius }
    var distance: Distance = .miles
    var temperature: Temperature = .fahrenheit
    var currency: String = "USD"
    static let `default` = UnitPreferences()

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
    func formatMoney(_ amount: Double?, currency: String? = nil) -> String {
        VoltaFormat.money(amount, currency: currency ?? self.currency)
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
    static func relativeDate(_ date: Date, now: Date = .now) -> String {
        let formatter = RelativeDateTimeFormatter(); formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }
    static func money(_ amount: Double?, currency: String = "USD") -> String {
        guard let amount else { return "—" }; return amount.formatted(.currency(code: currency))
    }
}
