import Foundation

/// Synthetic data only. All distances, temperatures and energy remain metric.
struct MockDataSource: VoltaDataSource {
    static let vehicleID = 1
    let empty: Bool
    let now: Date
    init(empty: Bool = false, now: Date = .now) { self.empty = empty; self.now = now }
    private var home: String { "Palo Alto, CA" }
    private func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }
    private func check(_ id: Int) throws { if id != Self.vehicleID { throw VoltaError.notFound } }

    func vehicles() async throws -> [Vehicle] {
        #if DEBUG
        // Screenshot aid: `-demoNoVehicles YES` shows the no-vehicle screen.
        if UserDefaults.standard.bool(forKey: "demoNoVehicles") { return [] }
        #endif
        let friday = Vehicle(id: Self.vehicleID, name: "Friday", model: "Model Y", trim: "Long Range AWD", exteriorColor: "Midnight Silver Metallic", vinSuffix: "DEMO01", firmware: "2026.32.6", hasData: true)
        return Self.listsNoDataVehicle ? [Self.noDataVehicle, friday] : [friday]
    }
    /// Screenshot aid (DEBUG): `-demoNoDataVehicle YES` lists a second car first
    /// that has never reported a battery reading, like a newly added Tesla.
    static var listsNoDataVehicle: Bool {
        #if DEBUG
        UserDefaults.standard.bool(forKey: "demoNoDataVehicle")
        #else
        false
        #endif
    }
    static let noDataVehicle = Vehicle(id: 2, name: "Tesla", vinSuffix: "DEMO02", hasData: false)
    func status(vehicleID: Int) async throws -> VehicleStatus {
        if Self.listsNoDataVehicle && vehicleID == Self.noDataVehicle.id {
            throw VoltaError.server(code: "data_unavailable", message: "TeslaMate has not recorded a battery observation for this vehicle")
        }
        try check(vehicleID)
        return VehicleStatus(vehicleId: vehicleID, state: .online, updatedAt: now, batteryLevel: 72, usableBatteryLevel: 71, ratedRangeKm: 354, estRangeKm: 328, chargeLimit: 80, chargingState: .disconnected, chargerPowerKw: nil, minutesToFull: nil, insideTempC: 21, outsideTempC: 16, climateOn: false, driverTempSettingC: 20, locked: true, sentryMode: true, odometerKm: 38642, location: Location(latitude: 37.4419, longitude: -122.1430, heading: 115, address: home, placeName: "Home"), firmware: "2026.32.6")
    }
    private var allDrives: [DriveSummary] {
        guard !empty else { return [] }
        return (0..<60).map { i in
            let km = i % 9 == 8 ? 126.4 : 12.8 + Double(i % 7) * 3.1
            let duration = km / 0.76
            let start = ago(Double(i / 2) * 24 + (i % 2 == 0 ? 2 : 10))
            return driveOverview(TripFixtures.summary(DriveSummary(id: i + 1, start: start, end: start.addingTimeInterval(duration * 60), startAddress: i % 2 == 0 ? "Union City, CA" : home, endAddress: i % 2 == 0 ? home : "Union City, CA", distanceKm: km, durationMin: duration, startBatteryLevel: 80, endBatteryLevel: max(20, 80 - Int(km / 4.7)), energyUsedKwh: km * 0.164, efficiencyWhPerKm: 164, maxSpeedKph: 104, avgSpeedKph: 45.6, outsideTempAvgC: 12 + Double(i % 10))))
        }
    }
    private func driveOverview(_ base: DriveSummary) -> DriveSummary {
        var drive = base
        drive.startCity = "Palo Alto"
        drive.endCity = "Mountain View"
        drive.ratedWhPerKm = 164
        drive.energySource = "teslamate_rated_range"
        let path = TripFixtures.detail(base)?.path
        drive.route = path.map { points in
            let stride = max(1, Int(ceil(Double(points.count) / 60)))
            return points.enumerated().filter { $0.offset % stride == 0 || $0.offset == points.count - 1 }
                .map { DriveRoutePoint(t: $0.element.t, latitude: $0.element.latitude, longitude: $0.element.longitude, routeBreakBefore: $0.element.routeBreakBefore) }
        } ?? (0...24).map { i in
            let fraction = Double(i) / 24
            return DriveRoutePoint(t: drive.start.addingTimeInterval(drive.durationMin * 60 * fraction), latitude: 37.4419 + fraction * 0.16, longitude: -122.1430 + fraction * 0.135)
        }
        return drive
    }
    private var allCharges: [ChargeSummary] {
        guard !empty else { return [] }
        return (0..<15).map { i in
            let fast = i % 5 == 4; let energy = fast ? 43.2 : 22.6
            let start = ago(Double(i) * 48 + 15)
            let duration = fast ? 27.0 : 190.0
            return ChargeSummary(id: i + 1, start: start, end: start.addingTimeInterval(duration * 60), address: fast ? "Mountain View, CA" : home, placeName: fast ? "Mountain View Supercharger" : "Home", energyAddedKwh: energy, energyUsedKwh: energy / 0.92, startBatteryLevel: fast ? 22 : 49, endBatteryLevel: 80, durationMin: duration, maxPowerKw: fast ? 176 : 7.7, fastCharger: fast, cost: energy * (fast ? 0.41 : 0.23), currency: "USD", outsideTempAvgC: 16)
        }
    }
    private func page<T: Codable & Hashable & Sendable>(_ items: [T], cursor: String?) throws -> Page<T> {
        let offset: Int
        if let cursor { guard let value = Int(cursor), value >= 0, value <= items.count else { throw VoltaError.server(code: "invalid_cursor", message: "Invalid demo cursor.") }; offset = value } else { offset = 0 }
        let end = min(offset + 30, items.count)
        return Page(items: Array(items[offset..<end]), nextCursor: end < items.count ? String(end) : nil)
    }
    private func within(_ date: Date, _ range: DateRange) -> Bool { (range.from.map { date >= $0 } ?? true) && (range.to.map { date <= $0 } ?? true) }
    func summary(vehicleID: Int, range: SummaryRange) async throws -> ActivitySummary {
        try check(vehicleID)
        // Like a server given the device's `tz`: today starts at local midnight.
        let calendar = Calendar.current
        let cutoff = range == .today ? calendar.startOfDay(for: now) : ago(range == .sevenDays ? 168 : 720)
        let drives = allDrives.filter { $0.start >= cutoff }; let charges = allCharges.filter { $0.start >= cutoff }
        let distance = drives.reduce(0) { $0 + $1.distanceKm }
        return ActivitySummary(range: range, distanceKm: distance, driveCount: drives.count, chargeCount: charges.count, energyUsedKwh: drives.reduce(0) { $0 + ($1.energyUsedKwh ?? 0) }, efficiencyWhPerKm: distance > 0 ? 164 : nil, energyAddedKwh: charges.reduce(0) { $0 + ($1.energyAddedKwh ?? 0) }, chargeCost: charges.reduce(0) { $0 + ($1.cost ?? 0) }, currency: "USD", periodStart: cutoff, periodEnd: now, timeZone: calendar.timeZone.identifier)
    }
    func drives(vehicleID: Int, range: DateRange, cursor: String?) async throws -> Page<DriveSummary> { try check(vehicleID); return try page(allDrives.filter { within($0.start, range) }, cursor: cursor) }
    func drive(id: Int) async throws -> DriveDetail {
        guard let drive = allDrives.first(where: { $0.id == id }) else { throw VoltaError.notFound }
        if let fixture = TripFixtures.detail(drive) { return fixture }
        let path = (0...24).map { i in
            let fraction = Double(i) / 24
            return DrivePoint(t: drive.start.addingTimeInterval(drive.durationMin * 60 * fraction), latitude: 37.4419 + fraction * 0.16, longitude: -122.1430 + fraction * 0.135, speedKph: i == 0 || i == 24 ? 0 : 72, powerKw: 12.5, elevationM: 35 + sin(fraction * .pi) * 28, batteryLevel: 80 - Int(fraction * 8))
        }
        return DriveDetail(summary: drive, path: path, elevationGainM: 86)
    }
    func charges(vehicleID: Int, range: DateRange, cursor: String?) async throws -> Page<ChargeSummary> { try check(vehicleID); return try page(allCharges.filter { within($0.start, range) }, cursor: cursor) }
    func charge(id: Int) async throws -> ChargeDetail {
        guard let charge = allCharges.first(where: { $0.id == id }) else { throw VoltaError.notFound }
        let samples = (0...20).map { i in
            let f = Double(i) / 20; let power = (charge.maxPowerKw ?? 7.7) * (charge.fastCharger ? 1 - f * 0.75 : 1)
            return ChargeSample(t: charge.start.addingTimeInterval(charge.durationMin * 60 * f), batteryLevel: Int(Double(charge.startBatteryLevel ?? 49) + f * Double(80 - (charge.startBatteryLevel ?? 49))), powerKw: power, voltage: charge.fastCharger ? 375 : 240, currentA: power * 1000 / (charge.fastCharger ? 375 : 240), ratedRangeKm: 250 + f * 143)
        }
        let telemetrySamples = (0...max(1, Int(charge.durationMin))).map { minute in
            let f = Double(minute) / max(charge.durationMin, 1)
            let power = (charge.maxPowerKw ?? 7.7) * (charge.fastCharger ? 1 - f * 0.75 : 1)
            let level = Double(charge.startBatteryLevel ?? 49) + f * Double(80 - (charge.startBatteryLevel ?? 49))
            return FleetTelemetrySample(
                t: charge.start.addingTimeInterval(Double(minute) * 60), latitude: nil, longitude: nil,
                speedKph: nil, powerKw: power, elevationM: nil, batteryLevel: level,
                energyRemainingKwh: level * 0.75, batteryTempMinC: 22 + level / 40,
                batteryTempMaxC: 27 + level / 30,
                insideTempC: 20.5, outsideTempC: charge.outsideTempAvgC,
                voltage: charge.fastCharger ? 375 : 240,
                currentA: power * 1000 / (charge.fastCharger ? 375 : 240), ratedRangeKm: 250 + f * 143,
                routeBreakBefore: false
            )
        }
        return ChargeDetail(summary: charge, samples: samples, efficiency: 0.92,
                            telemetry: FleetTelemetrySeries(source: "fleet_telemetry", samples: telemetrySamples,
                                                            gaps: [], truncated: false))
    }
    func idles(vehicleID: Int, range: DateRange, cursor: String?) async throws -> Page<IdleSummary> {
        try check(vehicleID)
        // Derive idle windows from the same drive/charge intervals used by the timeline.
        let events = (allDrives.map { ($0.start, $0.end ?? now) } + allCharges.map { ($0.start, $0.end ?? now) }).sorted { $0.0 < $1.0 }
        var position = ago(720)
        var gaps: [(Date, Date)] = []
        for (start, end) in events {
            if start.timeIntervalSince(position) >= 600 { gaps.append((position, start)) }
            position = max(position, end)
        }
        if !empty && now.timeIntervalSince(position) >= 600 { gaps.append((position, now)) }
        let items = gaps.reversed().enumerated().map { i, gap in
            let minutes = gap.1.timeIntervalSince(gap.0) / 60
            let loss = minutes / 1440 * 0.8
            return IdleSummary(id: i + 1, start: gap.0, end: gap.1, address: home, placeName: "Home", durationMin: minutes, startBatteryLevel: 74, endBatteryLevel: 74 - Int(loss.rounded()), rangeLostKm: loss * 4.9, energyLostKwh: loss * 0.735, sentryMinutes: min(80, minutes), climateMinutes: 0, asleepMinutes: max(0, minutes - 80))
        }
        return try page(items.filter { within($0.start, range) }, cursor: cursor)
    }
    func timeline(vehicleID: Int, hours: Int) async throws -> [TimelineSegment] {
        try check(vehicleID); guard !empty, hours > 0 else { return [] }
        let cutoff = ago(Double(hours))
        let events = allDrives.map { TimelineSegment(kind: .drive, start: $0.start, end: $0.end ?? now) } + allCharges.map { TimelineSegment(kind: .charge, start: $0.start, end: $0.end ?? now) }
        var result: [TimelineSegment] = []; var position = cutoff
        for event in events.filter({ $0.end > cutoff && $0.start < now }).sorted(by: { $0.start < $1.start }) {
            let start = max(event.start, position); let end = min(event.end, now)
            if start > position { result.append(TimelineSegment(kind: .asleep, start: position, end: start)) }
            if end > start { result.append(TimelineSegment(kind: event.kind, start: start, end: end)); position = end }
        }
        if position < now { result.append(TimelineSegment(kind: .idle, start: position, end: now)) }
        return result.reversed()
    }
    func battery(vehicleID: Int) async throws -> BatteryHealth {
        try check(vehicleID)
        let history: [BatteryHealthPoint] = empty ? [] : (0...24).map { i in BatteryHealthPoint(date: ago(Double(24 - i) * 730), ratedRangeAt100Km: 521 - Double(i) * 1.3, capacityKwh: 78.1 - Double(i) * 0.19) }
        return BatteryHealth(capacityNewKwh: empty ? nil : 78.1, capacityNowKwh: empty ? nil : 73.54, healthPercent: empty ? nil : 94.16, ratedRangeAt100Km: empty ? nil : 489.8, history: history, avgIdleDrainPctPerDay: empty ? nil : 0.8)
    }
    func mileage(vehicleID: Int, bucket: MileageBucketSize) async throws -> [MileageBucket] {
        try check(vehicleID); guard !empty else { return [] }
        // Bucket on UTC, Monday-start weeks, like the server's date_trunc.
        let component = AnalyticsMath.component(for: bucket)
        let calendar = AnalyticsMath.utcCalendar
        let grouped = Dictionary(grouping: allDrives) { calendar.dateInterval(of: component, for: $0.start)!.start }
        return grouped.map { start, drives in MileageBucket(start: start, distanceKm: drives.reduce(0) { $0 + $1.distanceKm }, driveCount: drives.count, energyUsedKwh: drives.reduce(0) { $0 + ($1.energyUsedKwh ?? 0) }) }.sorted { $0.start > $1.start }
    }
    func firmware(vehicleID: Int) async throws -> [FirmwareUpdate] {
        try check(vehicleID); return empty ? [] : [FirmwareUpdate(version: "2026.32.6", installedAt: ago(120), previousVersion: "2026.26.8"), FirmwareUpdate(version: "2026.26.8", installedAt: ago(1056), previousVersion: "2026.20.6"), FirmwareUpdate(version: "2026.20.6", installedAt: ago(2136), previousVersion: "2026.14.9")]
    }
    func places(vehicleID: Int) async throws -> [Place] {
        try check(vehicleID); return empty ? [] : [Place(id: 1, name: "Home", latitude: 37.4419, longitude: -122.1430, radiusM: 120, costPerKwh: 0.23), Place(id: 2, name: "Mountain View Supercharger", latitude: 37.4148, longitude: -122.0782, radiusM: 150, costPerKwh: 0.41)]
    }
    func command(vehicleID: Int, name: String, params: [String: String]) async throws { throw VoltaError.commandsUnavailable }
}
