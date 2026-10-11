import Foundation
import Observation

@MainActor @Observable
final class UserSettings {
    @ObservationIgnored private let defaults: UserDefaults?
    var units: UnitPreferences { didSet { if let data = try? JSONEncoder().encode(units) { defaults?.set(data, forKey: "units") } } }
    var serverURL: String { didSet { defaults?.set(serverURL, forKey: "serverURL") } }
    var appLockEnabled: Bool { didSet { defaults?.set(appLockEnabled, forKey: "appLockEnabled") } }
    var selectedVehicleID: Int? { didSet { defaults?.set(selectedVehicleID, forKey: "selectedVehicleID") } }
    /// The user picked `selectedVehicleID`; only automatic choices may move to
    /// a vehicle that has data. A selection saved before this flag existed has
    /// unknown provenance, so it is kept as the user's.
    var selectedVehicleIsExplicit: Bool { didSet { defaults?.set(selectedVehicleIsExplicit, forKey: "selectedVehicleIsExplicit") } }
    /// Home electricity price per kWh, in the units currency, for sessions the
    /// server didn't price. nil = never set: those costs show as unknown.
    var electricityRate: Double? { didSet { store(electricityRate, forKey: "electricityRate") } }
    /// Supercharger / DC fast price per kWh for unpriced DC fast sessions. nil
    /// falls back to the home rate.
    var dcFastRate: Double? { didSet { store(dcFastRate, forKey: "dcFastRate") } }
    /// The Charging tab's "add your rate" card was dismissed.
    var ratePromptDismissed: Bool { didSet { defaults?.set(ratePromptDismissed, forKey: "ratePromptDismissed") } }
    var emptyDemo: Bool { didSet { defaults?.set(emptyDemo, forKey: "emptyDemo") } }
    var demoMode: Bool { didSet { defaults?.set(demoMode, forKey: "demoMode") } }
    /// Show a Live Activity while the car is being driven (charging always shows one).
    var drivingLiveActivity: Bool { didSet { defaults?.set(drivingLiveActivity, forKey: "drivingLiveActivity") } }
    /// nil keeps launch-only settings entirely in memory.
    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        units = defaults?.data(forKey: "units").flatMap { try? JSONDecoder().decode(UnitPreferences.self, from: $0) } ?? .default
        serverURL = defaults?.string(forKey: "serverURL") ?? ""
        appLockEnabled = defaults?.bool(forKey: "appLockEnabled") ?? false
        let selectedVehicleID = defaults?.object(forKey: "selectedVehicleID") as? Int
        self.selectedVehicleID = selectedVehicleID
        selectedVehicleIsExplicit = defaults?.object(forKey: "selectedVehicleIsExplicit") as? Bool ?? (selectedVehicleID != nil)
        demoMode = defaults?.bool(forKey: "demoMode") ?? false
        // Only a rate the user saved survives; builds before the rate form
        // assumed 0.20 without storing it, and that assumption is dropped.
        electricityRate = ElectricityRates.stored(defaults?.object(forKey: "electricityRate") as? Double)
        dcFastRate = ElectricityRates.stored(defaults?.object(forKey: "dcFastRate") as? Double)
        ratePromptDismissed = defaults?.bool(forKey: "ratePromptDismissed") ?? false
        emptyDemo = defaults?.bool(forKey: "emptyDemo") ?? false
        drivingLiveActivity = defaults?.bool(forKey: "drivingLiveActivity") ?? false
    }

    /// The saved rates, priced in the units currency.
    var rates: ElectricityRates { ElectricityRates(home: electricityRate, dcFast: dcFastRate, currency: units.currency) }

    private func store(_ value: Double?, forKey key: String) {
        if let value { defaults?.set(value, forKey: key) } else { defaults?.removeObject(forKey: key) }
    }
}

/// The user's own electricity prices per kWh. Server prices always win; these
/// only cost sessions the server left unpriced.
struct ElectricityRates: Equatable, Sendable {
    var home: Double?
    var dcFast: Double?
    var currency: String

    /// Anything above this per kWh is a typo, not a tariff, in any currency
    /// (JPY and KRW rates run into the tens and hundreds).
    static let maximum = 1000.0

    /// A usable typed rate: finite, zero (free) or more, at most `maximum`.
    static func validated(_ value: Double?) -> Double? {
        guard let value = stored(value), value <= maximum else { return nil }
        return value
    }

    /// A rate saved earlier: any finite, non-negative value is kept, so a
    /// change to the typing ceiling never drops what the user saved.
    static func stored(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    /// A typed rate: blank clears it, otherwise it must be a usable rate.
    enum Input: Equatable {
        case empty, valid(Double), invalid
    }

    /// Parses the whole field: digits with at most one decimal separator
    /// (either "." or ","), optionally after one leading currency symbol.
    /// Signs, exponents, grouping and anything else are invalid rather than
    /// silently dropped.
    static func input(_ text: String, currency: String = "USD") -> Input {
        var rest = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if rest.isEmpty { return .empty }
        if let prefix = [symbol(for: currency), "$"].first(where: { rest.hasPrefix($0) }) {
            rest = rest.dropFirst(prefix.count).drop { $0.isWhitespace }
        }
        guard rest.wholeMatch(of: /[0-9]*([.,][0-9]*)?/) != nil, rest.contains(where: { $0 != "." && $0 != "," }),
              let value = validated(Double(rest.replacingOccurrences(of: ",", with: ".")))
        else { return .invalid }
        return .valid(value)
    }

    /// "$" for USD, "€" for EUR: the short symbol for field labels.
    static func symbol(for currency: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: "en_US")
        formatter.currencyCode = currency
        return formatter.currencySymbol ?? currency
    }

    /// The rate for one charging session; DC fast uses its own rate when set.
    func perKwh(fastCharger: Bool) -> Double? {
        fastCharger ? (dcFast ?? home) : home
    }

    /// The home rate as a trip rate, for drives (which don't know where the energy came from).
    var homeTripRate: TripRate? {
        home.map { TripRate(perKwh: $0, currency: currency, source: .manual) }
    }
}
