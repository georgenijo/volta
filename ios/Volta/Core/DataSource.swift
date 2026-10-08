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
    /// Phase 1 always throws `VoltaError.commandsUnavailable`.
    func command(vehicleID: Int, name: String, params: [String: String]) async throws
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
