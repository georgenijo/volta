import Foundation

/// Where a trip cost's electricity rate came from, in precedence order.
enum TripCostRateSource: Equatable, Sendable {
    /// The server's rate for this drive (energy-weighted average of priced charges before it).
    case server
    /// Cost ÷ energy added of the latest priced charge before the drive.
    case previousCharge
    /// The user's home rate (Settings).
    case home
    /// The user's DC fast-charging rate (Settings), when no home rate is set.
    case dcFast
    /// Nothing known: `TripCostEstimate.defaultRatePerKwh`.
    case estimated

    /// Small uppercase label under the cost bars.
    var label: String {
        switch self {
        case .server: "FROM CHARGE HISTORY"
        case .previousCharge: "FROM PREVIOUS CHARGE"
        case .home: "HOME RATE"
        case .dcFast: "DC FAST RATE"
        case .estimated: "ESTIMATED"
        }
    }
}

/// Assumptions for the fuel-equivalent comparison. There is no fuel setting yet,
/// so the defaults stand in: a 25 mpg car at $4.50 per US gallon.
struct FuelComparison: Equatable, Sendable {
    var milesPerGallon: Double
    var pricePerGallon: Double
    /// Currency of `pricePerGallon`; the comparison is only drawn when it matches the electricity rate.
    var currency: String

    static let `default` = FuelComparison(milesPerGallon: 25, pricePerGallon: 4.50, currency: "USD")

    /// Fuel cost to drive `distanceKm`, or nil for a non-positive economy or a bad distance.
    func cost(distanceKm: Double) -> Double? {
        guard distanceKm.isFinite, distanceKm >= 0, milesPerGallon.isFinite, milesPerGallon > 0,
              pricePerGallon.isFinite, pricePerGallon >= 0 else { return nil }
        return distanceKm / 1.609344 / milesPerGallon * pricePerGallon
    }
}

/// A drive's electricity cost, always estimated when energy is known, plus the
/// fuel-equivalent comparison.
struct TripCostEstimate: Equatable, Sendable {
    static let defaultRatePerKwh = 0.30
    static let defaultCurrency = "USD"

    var ratePerKwh: Double
    var currency: String
    var source: TripCostRateSource
    var electric: Double
    /// Nil when the distance is unusable or the fuel price is in another currency.
    var fuel: Double?

    /// Fuel minus electric; negative when electricity cost more.
    var savings: Double? { fuel.map { $0 - electric } }

    /// Electric relative to fuel, in percent: -69 means 69% cheaper. Nil without a positive fuel cost.
    var percentVsFuel: Double? {
        guard let fuel, fuel > 0 else { return nil }
        return (electric - fuel) / fuel * 100
    }

    /// The rate chain. The first usable rate wins:
    /// 1. `server`: the drive's own server rate (the existing precedence, kept);
    /// 2. `previousCharge`: the latest priced charge before the drive (may be free);
    /// 3. `homeRate`, then 4. `dcFastRate` from Settings, priced in `settingsCurrency`;
    /// 5. `defaultRatePerKwh` in `defaultCurrency` (a USD figure, whatever Settings says).
    ///
    /// A rate is usable when it is finite and ≥ 0. Returns nil only when the
    /// energy used is unknown, negative or not finite.
    static func make(energyKwh: Double?, distanceKm: Double,
                     server: TripRate?, previousCharge: TripRate?,
                     homeRate: Double?, dcFastRate: Double?, settingsCurrency: String,
                     fuel: FuelComparison = .default) -> TripCostEstimate? {
        guard let energyKwh, energyKwh.isFinite, energyKwh >= 0 else { return nil }
        func usable(_ value: Double?) -> Double? { value.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } }
        let chosen: (Double, String, TripCostRateSource)
        if let rate = server, let value = usable(rate.perKwh) {
            chosen = (value, rate.currency, .server)
        } else if let rate = previousCharge, let value = usable(rate.perKwh) {
            chosen = (value, rate.currency, .previousCharge)
        } else if let value = usable(homeRate) {
            chosen = (value, settingsCurrency, .home)
        } else if let value = usable(dcFastRate) {
            chosen = (value, settingsCurrency, .dcFast)
        } else {
            chosen = (defaultRatePerKwh, defaultCurrency, .estimated)
        }
        let (rate, currency, source) = chosen
        let fuelCost = fuel.currency == currency ? fuel.cost(distanceKm: distanceKm) : nil
        return TripCostEstimate(ratePerKwh: rate, currency: currency, source: source,
                                electric: energyKwh * rate, fuel: fuelCost)
    }
}
