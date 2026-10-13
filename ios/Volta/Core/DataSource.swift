import SwiftUI

/// Everything screens read. `APIDataSource` (Core/Networking) talks to
/// volta-api; `MockDataSource` serves previews and demo mode.
protocol VoltaDataSource: Sendable {
    func vehicles() async throws -> [Vehicle]
    func status(vehicleID: Int) async throws -> VehicleStatus
    func summary(vehicleID: Int, range: SummaryRange) async throws -> ActivitySummary
    func timeline(vehicleID: Int, hours: Int) async throws -> [TimelineSegment]
    func drives(vehicleID: Int, range: DateRange, cursor: String?) async throws -> Page<DriveSummary>
    func drive(id: Int) async throws -> DriveDetail
    func charges(vehicleID: Int, range: DateRange, cursor: String?) async throws -> Page<ChargeSummary>
    func charge(id: Int) async throws -> ChargeDetail
    func idles(vehicleID: Int, range: DateRange, cursor: String?) async throws -> Page<IdleSummary>
    func battery(vehicleID: Int) async throws -> BatteryHealth
    func mileage(vehicleID: Int, bucket: MileageBucketSize) async throws -> [MileageBucket]
    func firmware(vehicleID: Int) async throws -> [FirmwareUpdate]
    func places(vehicleID: Int) async throws -> [Place]
    func service(vehicleID: Int) async throws -> ServiceState
    func addService(vehicleID: Int, item: ServiceItemInput) async throws
    func completeService(vehicleID: Int, itemID: String, event: ServiceEventInput) async throws
    func updateService(vehicleID: Int, itemID: String, item: ServiceItemInput) async throws
    func deleteService(vehicleID: Int, itemID: String) async throws
    func updateServiceEvent(vehicleID: Int, eventID: String, event: ServiceEventInput) async throws
    func deleteServiceEvent(vehicleID: Int, eventID: String) async throws
    func chargerLocations(vehicleID: Int) async throws -> [ChargerLocation]
    func chargerSessions(vehicleID: Int, locationID: String, cursor: String?) async throws -> Page<ChargeSummary>
    /// Stable local identity for isolating saved command intents by backend.
    var commandBackendID: String { get }
    /// Demo sources may simulate supported actions, but are never live-ready.
    var simulatesVehicleCommands: Bool { get }
    func commandCapabilities(vehicleID: Int) async throws -> VehicleCommandCapabilities
    func command(vehicleID: Int, command: VehicleCommand, intentID: UUID) async throws -> VehicleCommandResult
}

enum VoltaError: LocalizedError, Equatable {
    case commandsUnavailable
    case unauthorized
    case notFound
    case server(code: String, message: String)
    case transport(String)

    var errorDescription: String? {
        switch self {
        case .commandsUnavailable: "Vehicle commands aren't connected yet."
        case .unauthorized: "This device is no longer paired."
        case .notFound: "Not found."
        case .server(_, let message): message
        case .transport(let message): message
        }
    }
}

private struct DataSourceKey: EnvironmentKey {
    static let defaultValue: any VoltaDataSource = MockDataSource()
}

private struct VehicleIDKey: EnvironmentKey {
    static let defaultValue: Int = MockDataSource.vehicleID
}

extension EnvironmentValues {
    var dataSource: any VoltaDataSource {
        get { self[DataSourceKey.self] }
        set { self[DataSourceKey.self] = newValue }
    }
    /// The currently selected vehicle.
    var vehicleID: Int {
        get { self[VehicleIDKey.self] }
        set { self[VehicleIDKey.self] = newValue }
    }
}

// Read-only test sources need not implement service writes.
extension VoltaDataSource {
    var commandBackendID: String { String(reflecting: type(of: self)) }
    var simulatesVehicleCommands: Bool { false }
    func commandCapabilities(vehicleID: Int) async throws -> VehicleCommandCapabilities { .unavailable }
    func command(vehicleID: Int, command: VehicleCommand, intentID: UUID) async throws -> VehicleCommandResult {
        throw VehicleCommandFailure(status: 501, code: "commands_unavailable", requestID: nil,
                                    retryAfter: nil, replayed: false)
    }
    func service(vehicleID: Int) async throws -> ServiceState { throw VoltaError.server(code: "service_unavailable", message: "Service storage is unavailable") }
    func addService(vehicleID: Int, item: ServiceItemInput) async throws { throw VoltaError.server(code: "service_unavailable", message: "Service storage is unavailable") }
    func completeService(vehicleID: Int, itemID: String, event: ServiceEventInput) async throws { throw VoltaError.server(code: "service_unavailable", message: "Service storage is unavailable") }
    func updateService(vehicleID: Int, itemID: String, item: ServiceItemInput) async throws { throw VoltaError.commandsUnavailable }
    func deleteService(vehicleID: Int, itemID: String) async throws { throw VoltaError.commandsUnavailable }
    func updateServiceEvent(vehicleID: Int, eventID: String, event: ServiceEventInput) async throws { throw VoltaError.commandsUnavailable }
    func deleteServiceEvent(vehicleID: Int, eventID: String) async throws { throw VoltaError.commandsUnavailable }
    func chargerLocations(vehicleID: Int) async throws -> [ChargerLocation] { throw VoltaError.notFound }
    func chargerSessions(vehicleID: Int, locationID: String, cursor: String?) async throws -> Page<ChargeSummary> { throw VoltaError.notFound }
}
