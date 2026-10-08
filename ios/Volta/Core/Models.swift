import Foundation

// Swift mirror of docs/API.md. Metric units throughout; convert for display
// with UnitPreferences. Optional means "not recorded", never zero.

struct Device: Codable, Hashable, Sendable, Identifiable {
    var id: Int
    var name: String
    var createdAt: Date
    var lastSeenAt: Date?
}

struct PairResponse: Codable, Sendable {
    var token: String
    var device: Device
}

struct Vehicle: Codable, Hashable, Sendable, Identifiable {
    var id: Int
    var name: String
    var model: String?
    var trim: String?
    var exteriorColor: String?
    var vinSuffix: String?
    var firmware: String?
    /// false: the server has no battery reading for this car yet, so status
    /// returns 409 `data_unavailable`. nil: a server that predates the field.
    var hasData: Bool? = nil
}

extension Vehicle {
    /// Where an automatic (not user-chosen) selection lands: the first vehicle,
    /// in server order, not known to lack data. Never hides a car: with no
    /// vehicle reporting data it is simply the first.
    static func automaticChoice(in vehicles: [Vehicle]) -> Vehicle? {
        vehicles.first { $0.hasData != false } ?? vehicles.first
    }
}

enum VehicleState: String, Codable, Sendable {
    case online, asleep, offline, driving, charging, updating
}

enum ChargingState: String, Codable, Sendable {
    case disconnected, stopped, charging, complete
}

struct Location: Codable, Hashable, Sendable {
    var latitude: Double
    var longitude: Double
    var heading: Double?
    var address: String?
    var placeName: String?
}

struct VehicleStatus: Codable, Hashable, Sendable {
    var vehicleId: Int
    var state: VehicleState
    var updatedAt: Date
    var batteryLevel: Int
    var usableBatteryLevel: Int?
    var ratedRangeKm: Double?
    var estRangeKm: Double?
    var chargeLimit: Int?
    var chargingState: ChargingState?
    var chargerPowerKw: Double?
    var minutesToFull: Int?
    var insideTempC: Double?
    var outsideTempC: Double?
    var climateOn: Bool?
    var driverTempSettingC: Double?
    var locked: Bool?
    var sentryMode: Bool?
    var odometerKm: Double?
    var location: Location?
    var firmware: String?
}

enum SummaryRange: String, Codable, Sendable, CaseIterable, Identifiable {
    case today, sevenDays = "7d", thirtyDays = "30d"
    var id: String { rawValue }
}

struct ActivitySummary: Codable, Hashable, Sendable {
    var range: SummaryRange
    var distanceKm: Double
    var driveCount: Int
    var chargeCount: Int
    var energyUsedKwh: Double?
    var efficiencyWhPerKm: Double?
    var energyAddedKwh: Double?
    var chargeCost: Double?
    var currency: String?
    /// Bounds the totals cover and the zone they were computed in; nil on
    /// servers without `tz` support (those count `today` from UTC midnight).
    var periodStart: Date? = nil
    var periodEnd: Date? = nil
    var timeZone: String? = nil
}

enum TimelineKind: String, Codable, Sendable {
    case drive, charge, idle, asleep, offline
}

struct TimelineSegment: Codable, Hashable, Sendable {
    var kind: TimelineKind
    var start: Date
    var end: Date
}

struct Page<T: Codable & Sendable & Hashable>: Codable, Hashable, Sendable {
    var items: [T]
    var nextCursor: String?
}

struct DriveSummary: Codable, Hashable, Sendable, Identifiable {
    var id: Int
    var start: Date
    var end: Date?
    var startAddress: String?
    var endAddress: String?
    var distanceKm: Double
    var durationMin: Double
    var startBatteryLevel: Int?
    var endBatteryLevel: Int?
    var energyUsedKwh: Double?
    var efficiencyWhPerKm: Double?
    var maxSpeedKph: Double?
    var avgSpeedKph: Double?
    var outsideTempAvgC: Double?
}

struct DrivePoint: Codable, Hashable, Sendable {
    var t: Date
    var latitude: Double
    var longitude: Double
    var speedKph: Double?
    var powerKw: Double?
    var elevationM: Double?
    var batteryLevel: Int?
}

struct DriveDetail: Codable, Hashable, Sendable {
    var summary: DriveSummary
    var path: [DrivePoint]
    var elevationGainM: Double?

    // The API flattens summary fields into the detail object.
    init(summary: DriveSummary, path: [DrivePoint], elevationGainM: Double?) {
        self.summary = summary; self.path = path; self.elevationGainM = elevationGainM
    }
    private enum Keys: String, CodingKey { case path, elevationGainM }
    init(from decoder: Decoder) throws {
        summary = try DriveSummary(from: decoder)
        let c = try decoder.container(keyedBy: Keys.self)
        path = try c.decode([DrivePoint].self, forKey: .path)
        elevationGainM = try c.decodeIfPresent(Double.self, forKey: .elevationGainM)
    }
    func encode(to encoder: Encoder) throws {
        try summary.encode(to: encoder)
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(path, forKey: .path)
        try c.encodeIfPresent(elevationGainM, forKey: .elevationGainM)
    }
}

struct ChargeSummary: Codable, Hashable, Sendable, Identifiable {
    var id: Int
    var start: Date
    var end: Date?
    var address: String?
    var placeName: String?
    var energyAddedKwh: Double?
    var energyUsedKwh: Double?
    var startBatteryLevel: Int?
    var endBatteryLevel: Int?
    var durationMin: Double
    var maxPowerKw: Double?
    var fastCharger: Bool
    var cost: Double?
    var currency: String?
    var outsideTempAvgC: Double?
    /// Optional; added by a server follow-up. Absent means "not sent", not 0,0.
    var latitude: Double? = nil
    var longitude: Double? = nil
}

struct ChargeSample: Codable, Hashable, Sendable {
    var t: Date
    var batteryLevel: Int?
    var powerKw: Double?
    var voltage: Double?
    var currentA: Double?
    var ratedRangeKm: Double?
}

struct ChargeDetail: Codable, Hashable, Sendable {
    var summary: ChargeSummary
    var samples: [ChargeSample]
    var efficiency: Double?

    init(summary: ChargeSummary, samples: [ChargeSample], efficiency: Double?) {
        self.summary = summary; self.samples = samples; self.efficiency = efficiency
    }
    private enum Keys: String, CodingKey { case samples, efficiency }
    init(from decoder: Decoder) throws {
        summary = try ChargeSummary(from: decoder)
        let c = try decoder.container(keyedBy: Keys.self)
        samples = try c.decode([ChargeSample].self, forKey: .samples)
        efficiency = try c.decodeIfPresent(Double.self, forKey: .efficiency)
    }
    func encode(to encoder: Encoder) throws {
        try summary.encode(to: encoder)
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(samples, forKey: .samples)
        try c.encodeIfPresent(efficiency, forKey: .efficiency)
    }
}

struct IdleSummary: Codable, Hashable, Sendable, Identifiable {
    var id: Int
    var start: Date
    var end: Date?
    var address: String?
    var placeName: String?
    var durationMin: Double
    var startBatteryLevel: Int?
    var endBatteryLevel: Int?
    var rangeLostKm: Double?
    var energyLostKwh: Double?
    var sentryMinutes: Double?
    var climateMinutes: Double?
    var asleepMinutes: Double?
    /// Optional; added by a server follow-up. Absent means "not sent", not 0,0.
    var latitude: Double? = nil
    var longitude: Double? = nil
}

struct BatteryHealthPoint: Codable, Hashable, Sendable {
    var date: Date
    var ratedRangeAt100Km: Double
    var capacityKwh: Double?
}

struct BatteryHealth: Codable, Hashable, Sendable {
    var capacityNewKwh: Double?
    var capacityNowKwh: Double?
    var healthPercent: Double?
    var ratedRangeAt100Km: Double?
    var history: [BatteryHealthPoint]
    var avgIdleDrainPctPerDay: Double?
}

enum MileageBucketSize: String, Codable, Sendable, CaseIterable {
    case day, week, month
}

struct MileageBucket: Codable, Hashable, Sendable {
    var start: Date
    var distanceKm: Double
    var driveCount: Int
    var energyUsedKwh: Double?
}

struct FirmwareUpdate: Codable, Hashable, Sendable {
    var version: String
    var installedAt: Date
    var previousVersion: String?
}

struct Place: Codable, Hashable, Sendable, Identifiable {
    var id: Int
    var name: String
    var latitude: Double
    var longitude: Double
    var radiusM: Double?
    var costPerKwh: Double?
}

struct DateRange: Hashable, Sendable {
    var from: Date?
    var to: Date?
}

// Health is unauthenticated; lastDataAt remains optional when no data exists.
struct HealthResponse: Codable, Hashable, Sendable {
    var ok: Bool
    var version: String
    var teslamate: TeslaMateHealth
}
struct TeslaMateHealth: Codable, Hashable, Sendable {
    var reachable: Bool
    var lastDataAt: Date?
}
