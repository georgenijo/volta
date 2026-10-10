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
    var packTempMaxC: Double? = nil
    var packTempMinC: Double? = nil
    var energyRemainingKwh: Double? = nil
    var chargePortDoorOpen: Bool? = nil
    var chargePortLatch: String? = nil
    var tpms: TirePressures? = nil
    var telemetryFreshness: TelemetryFreshness? = nil
}

struct TireReading: Codable, Hashable, Sendable {
    var pressureBar: Double?
    var updatedAt: Date?
    /// Visual guide only; the door placard is the authority for cold pressure.
    var isLow: Bool { pressureBar.map { $0 < 2.5 } ?? false }
}
struct TirePressures: Codable, Hashable, Sendable {
    var fl: TireReading
    var fr: TireReading
    var rl: TireReading
    var rr: TireReading
}
struct TelemetryFreshness: Codable, Hashable, Sendable {
    var connected: Bool
    var lastSeenAt: Date?
    var recordedAt: [String: Date]
    var label: String {
        if connected { return "Telemetry connected" }
        return lastSeenAt.map { "Last telemetry as of \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "Telemetry disconnected · no observations yet"
    }
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
    var startCity: String? = nil
    var endCity: String? = nil
    var ratedWhPerKm: Double? = nil
    var electricityRatePerKwh: Double? = nil
    var rateCurrency: String? = nil
    var energySource: String? = nil
    var driveScore: Int? = nil
    /// Compatibility with servers that sent the score under the earlier key.
    var legacyDriveScore: Int? = nil
    var route: [DriveRoutePoint]? = nil

    enum CodingKeys: String, CodingKey {
        case id, start, end, startAddress, endAddress, distanceKm, durationMin
        case startBatteryLevel, endBatteryLevel, energyUsedKwh, efficiencyWhPerKm
        case maxSpeedKph, avgSpeedKph, outsideTempAvgC, startCity, endCity, ratedWhPerKm
        case electricityRatePerKwh, rateCurrency, energySource, driveScore, route
        case legacyDriveScore = "efficiencyScore"
    }
}

struct DriveRoutePoint: Codable, Hashable, Sendable {
    var t: Date
    var latitude: Double
    var longitude: Double
    var routeBreakBefore: Bool? = nil
}

struct DrivePoint: Codable, Hashable, Sendable {
    var t: Date
    var latitude: Double
    var longitude: Double
    var speedKph: Double?
    var powerKw: Double?
    var elevationM: Double?
    var batteryLevel: Int?
    /// True when the receiver says this sample begins after a known stream gap.
    /// Optional keeps old `path` payloads source-compatible.
    var routeBreakBefore: Bool? = nil
}

/// Fleet Telemetry stays separate from TeslaMate's historical path/samples.
/// A sample may contain a slow signal without a position; nil remains unknown.
struct FleetTelemetrySample: Codable, Hashable, Sendable {
    var t: Date
    var latitude: Double?
    var longitude: Double?
    var speedKph: Double?
    var powerKw: Double?
    var elevationM: Double?
    var batteryLevel: Double?
    var energyRemainingKwh: Double?
    var batteryTempMinC: Double?
    var batteryTempMaxC: Double?
    var insideTempC: Double?
    var outsideTempC: Double?
    var voltage: Double?
    var currentA: Double?
    var ratedRangeKm: Double?
    var longitudinalAccelerationMps2: Double? = nil
    var lateralAccelerationMps2: Double? = nil
    var routeBreakBefore: Bool
    /// Tesla field names that were reported but rejected/conflicted at `t`.
    /// Absent on older servers means no explicit invalid-field evidence.
    var invalidFields: [String] = []
}

extension FleetTelemetrySample {
    private enum CodingKeys: String, CodingKey {
        case t, latitude, longitude, speedKph, powerKw, elevationM, batteryLevel, energyRemainingKwh
        case batteryTempMinC, batteryTempMaxC, insideTempC, outsideTempC, voltage, currentA, ratedRangeKm
        case longitudinalAccelerationMps2, lateralAccelerationMps2
        case routeBreakBefore, invalidFields
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        t = try c.decode(Date.self, forKey: .t)
        latitude = try c.decodeIfPresent(Double.self, forKey: .latitude)
        longitude = try c.decodeIfPresent(Double.self, forKey: .longitude)
        speedKph = try c.decodeIfPresent(Double.self, forKey: .speedKph)
        powerKw = try c.decodeIfPresent(Double.self, forKey: .powerKw)
        elevationM = try c.decodeIfPresent(Double.self, forKey: .elevationM)
        batteryLevel = try c.decodeIfPresent(Double.self, forKey: .batteryLevel)
        energyRemainingKwh = try c.decodeIfPresent(Double.self, forKey: .energyRemainingKwh)
        batteryTempMinC = try c.decodeIfPresent(Double.self, forKey: .batteryTempMinC)
        batteryTempMaxC = try c.decodeIfPresent(Double.self, forKey: .batteryTempMaxC)
        insideTempC = try c.decodeIfPresent(Double.self, forKey: .insideTempC)
        outsideTempC = try c.decodeIfPresent(Double.self, forKey: .outsideTempC)
        voltage = try c.decodeIfPresent(Double.self, forKey: .voltage)
        currentA = try c.decodeIfPresent(Double.self, forKey: .currentA)
        ratedRangeKm = try c.decodeIfPresent(Double.self, forKey: .ratedRangeKm)
        longitudinalAccelerationMps2 = try c.decodeIfPresent(Double.self, forKey: .longitudinalAccelerationMps2)
        lateralAccelerationMps2 = try c.decodeIfPresent(Double.self, forKey: .lateralAccelerationMps2)
        routeBreakBefore = try c.decodeIfPresent(Bool.self, forKey: .routeBreakBefore) ?? false
        invalidFields = try c.decodeIfPresent([String].self, forKey: .invalidFields) ?? []
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(t, forKey: .t)
        try c.encodeIfPresent(latitude, forKey: .latitude)
        try c.encodeIfPresent(longitude, forKey: .longitude)
        try c.encodeIfPresent(speedKph, forKey: .speedKph)
        try c.encodeIfPresent(powerKw, forKey: .powerKw)
        try c.encodeIfPresent(elevationM, forKey: .elevationM)
        try c.encodeIfPresent(batteryLevel, forKey: .batteryLevel)
        try c.encodeIfPresent(energyRemainingKwh, forKey: .energyRemainingKwh)
        try c.encodeIfPresent(batteryTempMinC, forKey: .batteryTempMinC)
        try c.encodeIfPresent(batteryTempMaxC, forKey: .batteryTempMaxC)
        try c.encodeIfPresent(insideTempC, forKey: .insideTempC)
        try c.encodeIfPresent(outsideTempC, forKey: .outsideTempC)
        try c.encodeIfPresent(voltage, forKey: .voltage)
        try c.encodeIfPresent(currentA, forKey: .currentA)
        try c.encodeIfPresent(ratedRangeKm, forKey: .ratedRangeKm)
        try c.encodeIfPresent(longitudinalAccelerationMps2, forKey: .longitudinalAccelerationMps2)
        try c.encodeIfPresent(lateralAccelerationMps2, forKey: .lateralAccelerationMps2)
        try c.encode(routeBreakBefore, forKey: .routeBreakBefore)
        if !invalidFields.isEmpty { try c.encode(invalidFields, forKey: .invalidFields) }
    }
}

struct FleetTelemetryGap: Codable, Hashable, Sendable {
    var start: Date
    var end: Date
    var reason: String
}

/// Coverage of one numeric field before the server's bounded response is
/// downsampled. `returnedSampleCount` is the number of values the client can
/// actually draw or analyse; the other fields describe the complete source.
struct FleetTelemetryMetricCoverage: Codable, Hashable, Sendable {
    var start: Date
    var end: Date
    var sourceSampleCount: Int
    var returnedSampleCount: Int
    /// Null for a zero-duration session; density is undefined, not zero.
    var densityPerMinute: Double?
    var maxIntervalSeconds: Double?
    var returnedMaxIntervalSeconds: Double? = nil
    var gapCount: Int
    var downsampled: Bool
    /// True when the bounded gaps array omitted a known gap intersecting this
    /// metric's span. Metric values are downsampled across the whole session,
    /// never prefix-truncated.
    var truncated: Bool
}

struct FleetTelemetryCoverage: Codable, Hashable, Sendable {
    var sessionStart: Date
    var sessionEnd: Date
    var sampleStart: Date
    var sampleEnd: Date
    var sourceSampleCount: Int
    var returnedSampleCount: Int
    /// Keys are FleetTelemetrySample JSON fields (`speedKph`, `powerKw`, ...).
    var metrics: [String: FleetTelemetryMetricCoverage]
}

struct FleetTelemetrySeries: Codable, Hashable, Sendable {
    var source: String
    var samples: [FleetTelemetrySample]
    var gaps: [FleetTelemetryGap]
    /// Absent on older servers. Without it the client keeps complete legacy
    /// history rather than guessing that a telemetry fragment is better.
    var coverage: FleetTelemetryCoverage? = nil
    var downsampled: Bool = false
    var truncated: Bool

    private enum CodingKeys: String, CodingKey { case source, samples, gaps, coverage, downsampled, truncated }

    init(source: String, samples: [FleetTelemetrySample], gaps: [FleetTelemetryGap],
         coverage: FleetTelemetryCoverage? = nil, downsampled: Bool = false, truncated: Bool) {
        self.source = source
        self.samples = samples
        self.gaps = gaps
        self.coverage = coverage
        self.downsampled = downsampled
        self.truncated = truncated
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        source = try c.decode(String.self, forKey: .source)
        samples = try c.decode([FleetTelemetrySample].self, forKey: .samples)
        gaps = try c.decode([FleetTelemetryGap].self, forKey: .gaps)
        coverage = try c.decodeIfPresent(FleetTelemetryCoverage.self, forKey: .coverage)
        downsampled = try c.decodeIfPresent(Bool.self, forKey: .downsampled) ?? false
        truncated = try c.decodeIfPresent(Bool.self, forKey: .truncated) ?? false
    }
}

struct DriveDetail: Codable, Hashable, Sendable {
    var summary: DriveSummary
    var path: [DrivePoint]
    var elevationGainM: Double?
    var telemetry: FleetTelemetrySeries?

    // The API flattens summary fields into the detail object.
    init(summary: DriveSummary, path: [DrivePoint], elevationGainM: Double?, telemetry: FleetTelemetrySeries? = nil) {
        self.summary = summary; self.path = path; self.elevationGainM = elevationGainM; self.telemetry = telemetry
    }
    private enum Keys: String, CodingKey { case path, elevationGainM, telemetry }
    init(from decoder: Decoder) throws {
        summary = try DriveSummary(from: decoder)
        let c = try decoder.container(keyedBy: Keys.self)
        path = try c.decode([DrivePoint].self, forKey: .path)
        elevationGainM = try c.decodeIfPresent(Double.self, forKey: .elevationGainM)
        // Telemetry is supplemental. An incompatible or malformed block must
        // not discard the successfully decoded legacy detail.
        telemetry = try? c.decodeIfPresent(FleetTelemetrySeries.self, forKey: .telemetry)
    }
    func encode(to encoder: Encoder) throws {
        try summary.encode(to: encoder)
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(path, forKey: .path)
        try c.encodeIfPresent(elevationGainM, forKey: .elevationGainM)
        try c.encodeIfPresent(telemetry, forKey: .telemetry)
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
    var telemetry: FleetTelemetrySeries?

    init(summary: ChargeSummary, samples: [ChargeSample], efficiency: Double?, telemetry: FleetTelemetrySeries? = nil) {
        self.summary = summary; self.samples = samples; self.efficiency = efficiency; self.telemetry = telemetry
    }
    private enum Keys: String, CodingKey { case samples, efficiency, telemetry }
    init(from decoder: Decoder) throws {
        summary = try ChargeSummary(from: decoder)
        let c = try decoder.container(keyedBy: Keys.self)
        samples = try c.decode([ChargeSample].self, forKey: .samples)
        efficiency = try c.decodeIfPresent(Double.self, forKey: .efficiency)
        // Telemetry is supplemental. An incompatible or malformed block must
        // not discard the successfully decoded legacy detail.
        telemetry = try? c.decodeIfPresent(FleetTelemetrySeries.self, forKey: .telemetry)
    }
    func encode(to encoder: Encoder) throws {
        try summary.encode(to: encoder)
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(samples, forKey: .samples)
        try c.encodeIfPresent(efficiency, forKey: .efficiency)
        try c.encodeIfPresent(telemetry, forKey: .telemetry)
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
