import Foundation

/// One pricing policy for cards, totals and detail. Never sum different currencies.
enum DrivePricing {
    static func rate(_ drive: DriveSummary, fallback: Double) -> TripRate {
        if let value = drive.electricityRatePerKwh, value.isFinite, value >= 0,
           let currency = TripRate.isoCurrency(drive.rateCurrency) {
            return TripRate(perKwh: value, currency: currency, source: .chargeAverage)
        }
        return TripRate(perKwh: fallback.isFinite && fallback >= 0 ? fallback : 0.20, currency: "USD", source: .manual)
    }
    static func cost(_ drive: DriveSummary, fallback: Double) -> Double? {
        rate(drive, fallback: fallback).cost(energyKwh: drive.costableEnergyKwh)
    }
    static func total(_ drives: [DriveSummary], fallback: Double) -> (display: String, note: String?) {
        var sums: [String: Double] = [:]
        var known = 0
        for drive in drives {
            let rate = rate(drive, fallback: fallback)
            guard let cost = rate.cost(energyKwh: drive.costableEnergyKwh) else { continue }
            sums[rate.currency, default: 0] += cost
            known += 1
        }
        let display = sums.sorted { $0.key < $1.key }.map { VoltaFormat.money($0.value, currency: $0.key) }.joined(separator: " + ")
        return (display.isEmpty ? "—" : display, known < drives.count ? "Cost available for \(known) of \(drives.count) drives" : nil)
    }
}

extension DriveSummary {
    /// An unchanged coarse energy reading over a moving drive does not establish zero use.
    var costableEnergyKwh: Double? {
        guard let energyUsedKwh, energyUsedKwh.isFinite,
              energyUsedKwh > 0 || (energyUsedKwh == 0 && distanceKm == 0) else { return nil }
        return energyUsedKwh
    }
    var energyProvenance: String {
        switch energySource {
        case "teslamate_rated_range": "Estimated from TeslaMate rated-range change × car efficiency"
        case "fleet_lifetime_energy": "Estimated from Fleet Telemetry lifetime energy-used counter"
        case "fleet_energy_remaining": "Estimated net battery energy from Fleet Telemetry energy remaining; regeneration and temperature affect this value"
        default: "Energy source not supplied by this server"
        }
    }
    var startPlace: String { startCity ?? startAddress ?? "Start not recorded" }
    var endPlace: String { endCity ?? endAddress ?? "End not recorded" }
    /// Server score combines efficiency, smoothness and speed. Missing is unknown.
    var efficiencyScore: Int? {
        guard let score = driveScore ?? legacyDriveScore, (0...100).contains(score) else { return nil }
        return score
    }

}

struct Roadtrip: Identifiable, Hashable {
    var drives: [DriveSummary]
    var id: Int { drives[0].id }
    var distanceKm: Double { drives.reduce(0) { $0 + $1.distanceKm } }
    /// Closed drives chained across 0–120 minute stops, ≥100 km total. Unknown endpoints split chains.
    static func group(_ input: [DriveSummary]) -> [Roadtrip] {
        let sorted = input.sorted { ($0.start, $0.id) < ($1.start, $1.id) }
        var chains: [[DriveSummary]] = []
        var canJoin = false
        for drive in sorted {
            guard let end = drive.end, end >= drive.start else { canJoin = false; continue }
            if canJoin, let last = chains.last?.last, let finish = last.end,
               drive.start >= finish, drive.start.timeIntervalSince(finish) <= 7200 {
                chains[chains.count - 1].append(drive)
            } else { chains.append([drive]) }
            canJoin = true
        }
        return chains.filter { $0.reduce(0) { $0 + $1.distanceKm } >= 100 }
            .map { Roadtrip(drives: $0) }.reversed()
    }
}

struct DriveDay: Identifiable {
    var date: Date
    var distanceKm: Double
    var count: Int
    var id: Date { date }
    static func days(_ drives: [DriveSummary], calendar: Calendar = .current) -> [DriveDay] {
        Dictionary(grouping: drives, by: { calendar.startOfDay(for: $0.start) })
            .map { DriveDay(date: $0.key, distanceKm: $0.value.reduce(0) { $0 + $1.distanceKm }, count: $0.value.count) }
            .sorted { $0.date < $1.date }
    }
}
