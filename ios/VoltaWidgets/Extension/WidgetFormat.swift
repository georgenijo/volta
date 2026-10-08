import Foundation

/// Formatting helpers mirroring ios/Volta/Core/Formatting.swift, driven by the
/// units stored in the snapshot.
struct WidgetUnits: Hashable, Sendable {
    var miles: Bool
    var fahrenheit: Bool

    init(miles: Bool = true, fahrenheit: Bool = true) { self.miles = miles; self.fahrenheit = fahrenheit }
    init(_ snapshot: WidgetSnapshot) {
        miles = snapshot.distanceUnit == .miles
        fahrenheit = snapshot.temperatureUnit == .fahrenheit
    }

    var distanceUnit: String { miles ? "mi" : "km" }
    var temperatureUnit: String { fahrenheit ? "°F" : "°C" }

    func distance(_ km: Double?) -> String {
        guard let km else { return "—" }
        return Int((miles ? km / 1.609344 : km).rounded()).formatted()
    }
    func distanceWithUnit(_ km: Double?, digits: Int = 0) -> String {
        guard let km else { return "—" }
        let v = miles ? km / 1.609344 : km
        return "\(v.formatted(.number.precision(.fractionLength(digits)))) \(distanceUnit)"
    }
    func temperature(_ c: Double?) -> String {
        guard let c else { return "—" }
        return "\(Int((fahrenheit ? c * 9 / 5 + 32 : c).rounded()))°"
    }
}

enum WidgetFormat {
    static func energy(_ kwh: Double?) -> String {
        guard let kwh else { return "—" }
        return "\(kwh.formatted(.number.precision(.fractionLength(1)))) kWh"
    }
    static func power(_ kw: Double?) -> String {
        guard let kw else { return "—" }
        return "\(kw.formatted(.number.precision(.fractionLength(kw >= 20 ? 0 : 1)))) kW"
    }
    /// "80%" or "—" when the value is unknown.
    static func percent(_ value: Int?) -> String {
        guard let value else { return "—" }
        return "\(value)%"
    }
    /// Frozen elapsed time, e.g. "1:07:12" or "23:05"; "—" for negative input.
    static func duration(_ seconds: TimeInterval) -> String {
        guard seconds >= 0, seconds.isFinite else { return "—" }
        let total = Int(seconds)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
    /// Compact data age for tight spaces: "45m", "3h", "2d".
    static func shortAge(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds / 60))
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 48 * 60 { return "\(minutes / 60)h" }
        return "\(minutes / 1440)d"
    }
    static func minutes(_ m: Int?) -> String {
        guard let m else { return "—" }
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }

    /// "4 min ago" relative to the timeline entry's date (static per entry,
    /// so it never shows a ticking seconds counter).
    static func relative(_ date: Date, to now: Date) -> String {
        if now.timeIntervalSince(date) < 60 { return "just now" }
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: now)
    }

    static func stateText(_ s: WidgetSnapshot) -> String {
        if s.chargingState == .charging { return "Charging" }
        if s.chargingState == .complete { return "Charged" }
        switch s.state {
        case .online: return s.sentryMode == true ? "Sentry" : "Parked"
        case .asleep: return "Asleep"
        case .offline: return "Offline"
        case .driving: return "Driving"
        case .charging: return "Charging"
        case .updating: return "Updating"
        }
    }

    static func stateSymbol(_ s: WidgetSnapshot) -> String {
        if s.isCharging { return "bolt.fill" }
        switch s.state {
        case .driving: return "steeringwheel"
        case .asleep: return "moon.zzz.fill"
        case .offline: return "wifi.slash"
        case .updating: return "arrow.down.circle"
        default: return s.sentryMode == true ? "shield.lefthalf.filled" : "parkingsign"
        }
    }
}
