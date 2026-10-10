import Foundation

/// Preview/demo helper: serves mock data but fails every history list and
/// detail request, to exercise error states.
struct HistoryPreviewFailingSource: VoltaDataSource {
    private let base = MockDataSource()
    private var failure: VoltaError { .transport("The server didn't respond. Check that you're on the tailnet.") }

    func vehicles() async throws -> [Vehicle] { try await base.vehicles() }
    func status(vehicleID: Int) async throws -> VehicleStatus { try await base.status(vehicleID: vehicleID) }
    func summary(vehicleID: Int, range: SummaryRange) async throws -> ActivitySummary { try await base.summary(vehicleID: vehicleID, range: range) }
    func timeline(vehicleID: Int, hours: Int) async throws -> [TimelineSegment] { try await base.timeline(vehicleID: vehicleID, hours: hours) }
    func drives(vehicleID: Int, range: DateRange, cursor: String?) async throws -> Page<DriveSummary> { throw failure }
    func drive(id: Int) async throws -> DriveDetail { throw failure }
    func charges(vehicleID: Int, range: DateRange, cursor: String?) async throws -> Page<ChargeSummary> { throw failure }
    func charge(id: Int) async throws -> ChargeDetail { throw failure }
    func idles(vehicleID: Int, range: DateRange, cursor: String?) async throws -> Page<IdleSummary> { throw failure }
    func battery(vehicleID: Int) async throws -> BatteryHealth { try await base.battery(vehicleID: vehicleID) }
    func mileage(vehicleID: Int, bucket: MileageBucketSize) async throws -> [MileageBucket] { try await base.mileage(vehicleID: vehicleID, bucket: bucket) }
    func firmware(vehicleID: Int) async throws -> [FirmwareUpdate] { try await base.firmware(vehicleID: vehicleID) }
    func places(vehicleID: Int) async throws -> [Place] { try await base.places(vehicleID: vehicleID) }
    func command(vehicleID: Int, name: String, params: [String: String]) async throws { throw VoltaError.commandsUnavailable }
}

extension MockDataSource {
    /// A representative fixture for detail-screen previews.
    static func previewCharge(fast: Bool = false) -> ChargeSummary {
        ChargeSummary(id: fast ? 10 : 1, start: .now.addingTimeInterval(-6 * 3600), end: .now.addingTimeInterval(-5 * 3600),
                      address: fast ? "Mountain View, CA" : "Palo Alto, CA", placeName: fast ? "Mountain View Supercharger" : "Home",
                      energyAddedKwh: fast ? 43.2 : 22.6, energyUsedKwh: fast ? 46.9 : 24.6,
                      startBatteryLevel: fast ? 22 : 49, endBatteryLevel: 80, durationMin: fast ? 27 : 190,
                      maxPowerKw: fast ? 176 : 7.7, fastCharger: fast, cost: fast ? 17.71 : 5.20,
                      currency: "USD", outsideTempAvgC: 16, source: "teslamate", avgPowerKw: fast ? 96 : 7.1,
                      city: fast ? "Mountain View" : "Palo Alto", street: fast ? "250 Sample Blvd" : "100 Example Ave",
                      energyFromGridKwh: fast ? nil : 25.1)
    }
}
