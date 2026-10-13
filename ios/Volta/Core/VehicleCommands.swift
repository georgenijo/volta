import Foundation
import Observation
import SwiftUI

/// The only vehicle commands the iOS client can construct. Each case encodes
/// the command's flat, typed API body; callers cannot pass arbitrary fields.
enum VehicleCommand: Codable, Equatable, Hashable, Sendable {
    case lock
    case unlock
    case climateOn
    case climateOff
    case setTemperatures(driverTempC: Double, passengerTempC: Double)
    case chargeStart
    case chargeStop
    case setChargeLimit(percent: Int)
    case openChargePort
    case closeChargePort
    case actuateTrunk(whichTrunk: Trunk)
    case windowControl(command: WindowAction)
    case honk
    case flash
    case sentryOn
    case sentryOff
    case triggerHomeLink(latitude: Double, longitude: Double)
    case wakeUp
    case seatHeater(heater: Int, level: Int)
    case steeringWheelHeat(on: Bool)
    case defrost(on: Bool)

    enum Trunk: String, Codable, Sendable { case front, rear }
    enum WindowAction: String, Codable, Sendable { case vent, close }

    var name: String {
        switch self {
        case .lock: "lock"
        case .unlock: "unlock"
        case .climateOn: "climate_on"
        case .climateOff: "climate_off"
        case .setTemperatures: "set_temps"
        case .chargeStart: "charge_start"
        case .chargeStop: "charge_stop"
        case .setChargeLimit: "set_charge_limit"
        case .openChargePort: "open_charge_port"
        case .closeChargePort: "close_charge_port"
        case .actuateTrunk: "actuate_trunk"
        case .windowControl: "window_control"
        case .honk: "honk"
        case .flash: "flash"
        case .sentryOn: "sentry_on"
        case .sentryOff: "sentry_off"
        case .triggerHomeLink: "trigger_homelink"
        case .wakeUp: "wake_up"
        case .seatHeater: "seat_heater"
        case .steeringWheelHeat: "steering_wheel_heat"
        case .defrost: "defrost"
        }
    }

    static let supportedNames: Set<String> = [
        "lock", "unlock", "climate_on", "climate_off", "set_temps",
        "charge_start", "charge_stop", "set_charge_limit", "open_charge_port",
        "close_charge_port", "actuate_trunk", "window_control", "honk", "flash",
        "sentry_on", "sentry_off", "trigger_homelink", "wake_up", "seat_heater",
        "steering_wheel_heat", "defrost",
    ]

    func encodedBody() throws -> Data {
        let encoder = JSONEncoder()
        switch self {
        case .lock, .unlock, .climateOn, .climateOff, .chargeStart, .chargeStop,
             .openChargePort, .closeChargePort, .honk, .flash, .sentryOn, .sentryOff,
             .wakeUp:
            return Data("{}".utf8)
        case .setTemperatures(let driver, let passenger):
            guard (15...28).contains(driver), (15...28).contains(passenger),
                  driver.isFinite, passenger.isFinite else { throw VehicleCommandEncodingError.invalidParameters }
            return try encoder.encode(Temperatures(driverTempC: driver, passengerTempC: passenger))
        case .setChargeLimit(let percent):
            guard (50...100).contains(percent) else { throw VehicleCommandEncodingError.invalidParameters }
            return try encoder.encode(ChargeLimit(percent: percent))
        case .actuateTrunk(let whichTrunk):
            return try encoder.encode(TrunkBody(whichTrunk: whichTrunk))
        case .windowControl(let command):
            return try encoder.encode(WindowBody(command: command))
        case .triggerHomeLink(let latitude, let longitude):
            guard (-90...90).contains(latitude), (-180...180).contains(longitude),
                  latitude.isFinite, longitude.isFinite else { throw VehicleCommandEncodingError.invalidParameters }
            return try encoder.encode(HomeLink(latitude: latitude, longitude: longitude))
        case .seatHeater(let heater, let level):
            guard (0...5).contains(heater), (0...3).contains(level) else { throw VehicleCommandEncodingError.invalidParameters }
            return try encoder.encode(SeatHeater(heater: heater, level: level))
        case .steeringWheelHeat(let on), .defrost(let on):
            return try encoder.encode(BooleanBody(on: on))
        }
    }

    private struct Temperatures: Encodable { let driverTempC: Double; let passengerTempC: Double }
    private struct ChargeLimit: Encodable { let percent: Int }
    private struct TrunkBody: Encodable { let whichTrunk: Trunk }
    private struct WindowBody: Encodable { let command: WindowAction }
    private struct HomeLink: Encodable { let latitude: Double; let longitude: Double }
    private struct SeatHeater: Encodable { let heater: Int; let level: Int }
    private struct BooleanBody: Encodable { let on: Bool }
}

enum VehicleCommandEncodingError: Error { case invalidParameters }

struct VehicleCommandCapabilities: Codable, Equatable, Sendable {
    var available: Bool
    var reason: String?
    var commands: [String]

    func supports(_ command: VehicleCommand) -> Bool {
        available && commands.contains(command.name)
    }

    static let unavailable = VehicleCommandCapabilities(available: false, reason: "commands_unavailable", commands: [])
    static let demo = VehicleCommandCapabilities(available: false, reason: "stub_mode", commands: Array(VehicleCommand.supportedNames).sorted())
}

struct VehicleCommandResult: Equatable, Sendable {
    var command: String
    var requestID: String?
    var replayed: Bool
}

/// Command-only failure metadata. Messages are selected by the client from the
/// stable code; server text is never displayed.
struct VehicleCommandFailure: Error, Equatable, Sendable {
    var status: Int?
    var code: String
    var requestID: String?
    var retryAfter: String?
    var replayed: Bool

    var isUnresolved: Bool {
        ["command_outcome_unknown", "command_in_progress", "request_cancelled",
         "rate_limited", "tesla_rate_limited"].contains(code)
    }

    var message: String {
        switch code {
        case "command_outcome_unknown": "The outcome is unknown. It may have completed; check the vehicle before trying again."
        case "command_in_progress": "This request is still in progress. Check its result again shortly."
        case "request_cancelled": "The request was cancelled before acceptance. You can retry this same request."
        case "rate_limited", "tesla_rate_limited": "Tesla is limiting requests. Wait before trying this same request again."
        case "command_budget_unavailable": "Command accounting is unavailable, so the request was not sent."
        case "command_budget_exhausted": "The monthly Fleet API command budget has been reached."
        case "command_not_sent": "The command service timed out before sending anything. Try a new deliberate request."
        case "authorization_required": "Connect Tesla to enable vehicle controls."
        case "reauthorization_required", "command_scope_required", "permission_denied": "Reconnect Tesla to grant vehicle command access."
        case "virtual_key_missing": "Pair Volta's virtual key in the Tesla app before using controls."
        case "vehicle_asleep": "The vehicle did not wake. Check it, then try a new request later."
        case "vehicle_offline": "The vehicle is offline. Check its connectivity before trying again."
        case "vehicle_unavailable", "command_rejected": "Tesla rejected this action for the vehicle's current state."
        case "vehicle_not_found": "This vehicle is not configured for commands."
        case "commands_unavailable", "stub_mode": "Vehicle commands are not enabled on this server."
        case "idempotency_conflict", "invalid_command", "invalid_params", "idempotency_key_required": "Volta could not safely submit this control request."
        case "oauth_unavailable", "oauth_invalid_response", "region_unavailable", "upstream_unavailable", "storage_unavailable": "The command service is temporarily unavailable."
        case "unauthorized": "The command service could not authenticate. Your Volta pairing was kept."
        default: "The vehicle command could not be completed."
        }
    }
}

struct PendingVehicleCommand: Codable, Equatable, Identifiable, Sendable {
    var id: UUID { intentID }
    var intentID: UUID
    var backendID: String
    var vehicleID: Int
    var command: VehicleCommand
    var label: String
    var createdAt: Date
    var retryNotBefore: Date? = nil

    func isExpired(at now: Date = .now) -> Bool {
        now.timeIntervalSince(createdAt) >= VehicleCommandIntentStore.maximumReplayAge
    }
}

@MainActor
final class VehicleCommandIntentStore {
    enum StoreError: Error { case applicationSupportUnavailable }
    nonisolated static let maximumReplayAge: TimeInterval = 24 * 60 * 60

    private enum Backing { case file(URL?); case memory }
    private let backing: Backing
    private var memoryRecords: [PendingVehicleCommand]

    /// Production storage. A nil URL means the Application Support location
    /// could not be resolved; every operation then fails closed.
    init(fileURL: URL? = nil) {
        if let fileURL {
            backing = .file(fileURL)
        } else {
            let root = try? FileManager.default.url(for: .applicationSupportDirectory,
                                                    in: .userDomainMask, appropriateFor: nil, create: false)
            backing = .file(root?.appendingPathComponent("VehicleCommands", isDirectory: true)
                .appendingPathComponent("pending-v1.json"))
        }
        memoryRecords = []
    }

    /// Explicit test seam; production never selects this backing implicitly.
    init(inMemory records: [PendingVehicleCommand]) {
        backing = .memory
        memoryRecords = records
    }

    func all(backendID: String, vehicleID: Int) throws -> [PendingVehicleCommand] {
        try load().filter { $0.backendID == backendID && $0.vehicleID == vehicleID }
            .sorted { $0.createdAt < $1.createdAt }
    }

    func upsert(_ record: PendingVehicleCommand) throws {
        var values = try load()
        values.removeAll { $0.intentID == record.intentID }
        values.append(record)
        try save(values)
    }

    func remove(_ intentID: UUID) throws {
        try save(try load().filter { $0.intentID != intentID })
    }

    private func load() throws -> [PendingVehicleCommand] {
        switch backing {
        case .memory:
            return memoryRecords
        case .file(let optionalURL):
            guard let url = optionalURL else { throw StoreError.applicationSupportUnavailable }
            guard FileManager.default.fileExists(atPath: url.path) else { return [] }
            // A corrupt or partially unreadable file must never look empty.
            return try JSONDecoder().decode([PendingVehicleCommand].self, from: Data(contentsOf: url))
        }
    }

    private func save(_ values: [PendingVehicleCommand]) throws {
        switch backing {
        case .memory:
            memoryRecords = values
        case .file(let optionalURL):
            guard let url = optionalURL else { throw StoreError.applicationSupportUnavailable }
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            let data = try JSONEncoder().encode(values)
            try data.write(to: url, options: [.atomic])
            let handle = try FileHandle(forWritingTo: url)
            try handle.synchronize()
            try handle.close()
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        }
    }
}

@MainActor @Observable
final class VehicleCommandCoordinator {
    enum Phase: Equatable, Sendable { case pending, success, simulated, failure, unknown }

    struct Activity: Equatable, Identifiable, Sendable {
        var id: UUID
        var command: VehicleCommand
        var label: String
        var phase: Phase
        var message: String
        var canRetry: Bool
        var retryNotBefore: Date? = nil
        var requiresAcknowledgement: Bool = false
    }

    enum Outcome: Equatable, Sendable { case succeeded(simulated: Bool), failed, unknown }

    private struct Context: Hashable { var backendID: String; var vehicleID: Int }

    private(set) var capabilities: [String: VehicleCommandCapabilities] = [:]
    private(set) var activities: [String: Activity] = [:]
    private var inFlight: Set<String> = []
    private var storageUnavailable = false
    @ObservationIgnored private let store: VehicleCommandIntentStore

    init(store: VehicleCommandIntentStore? = nil) {
        self.store = store ?? VehicleCommandIntentStore()
    }

    func capability(dataSource: any VoltaDataSource, vehicleID: Int) -> VehicleCommandCapabilities? {
        capabilities[key(dataSource: dataSource, vehicleID: vehicleID)]
    }

    func activity(dataSource: any VoltaDataSource, vehicleID: Int) -> Activity? {
        activities[key(dataSource: dataSource, vehicleID: vehicleID)]
    }

    func pending(dataSource: any VoltaDataSource, vehicleID: Int) -> [PendingVehicleCommand] {
        do { return try store.all(backendID: dataSource.commandBackendID, vehicleID: vehicleID) }
        catch {
            storageUnavailable = true
            return []
        }
    }

    func isBusy(dataSource: any VoltaDataSource, vehicleID: Int) -> Bool {
        inFlight.contains(key(dataSource: dataSource, vehicleID: vehicleID))
    }

    func supports(_ command: VehicleCommand, dataSource: any VoltaDataSource, vehicleID: Int) -> Bool {
        guard !storageUnavailable else { return false }
        if dataSource.simulatesVehicleCommands { return VehicleCommand.supportedNames.contains(command.name) }
        return capability(dataSource: dataSource, vehicleID: vehicleID)?.supports(command) == true
    }

    func canStart(_ command: VehicleCommand, dataSource: any VoltaDataSource, vehicleID: Int) -> Bool {
        supports(command, dataSource: dataSource, vehicleID: vehicleID)
            && pending(dataSource: dataSource, vehicleID: vehicleID).isEmpty
            && !isBusy(dataSource: dataSource, vehicleID: vehicleID)
    }

    func refreshCapabilities(dataSource: any VoltaDataSource, vehicleID: Int) async {
        let id = key(dataSource: dataSource, vehicleID: vehicleID)
        do {
            capabilities[id] = try await dataSource.commandCapabilities(vehicleID: vehicleID)
        } catch is CancellationError {
            return
        } catch {
            if capabilities[id] == nil { capabilities[id] = .unavailable }
        }
        let saved = pending(dataSource: dataSource, vehicleID: vehicleID)
        if storageUnavailable {
            capabilities[id] = VehicleCommandCapabilities(available: false, reason: "intent_storage_unavailable", commands: [])
            activities[id] = Activity(id: UUID(), command: .wakeUp, label: "Command storage", phase: .failure,
                                      message: "Secure command storage is unavailable. No vehicle command will be sent.",
                                      canRetry: false)
            return
        }
        if let record = saved.first {
            let expired = record.isExpired()
            activities[id] = Activity(id: record.intentID, command: record.command, label: record.label,
                                      phase: .unknown,
                                      message: expired
                                        ? "This unresolved request is over 24 hours old and can no longer be replayed. Check the vehicle before allowing new commands."
                                        : "This request has no confirmed result. Check the vehicle or check the saved request again.",
                                      canRetry: !expired, retryNotBefore: record.retryNotBefore,
                                      requiresAcknowledgement: expired)
        }
    }

    func perform(_ command: VehicleCommand, label: String, dataSource: any VoltaDataSource,
                 vehicleID: Int) async -> Outcome {
        guard pending(dataSource: dataSource, vehicleID: vehicleID).isEmpty else { return .failed }
        let record = PendingVehicleCommand(intentID: UUID(), backendID: dataSource.commandBackendID,
                                           vehicleID: vehicleID, command: command, label: label, createdAt: .now)
        return await send(record, dataSource: dataSource)
    }

    func retry(_ intentID: UUID, dataSource: any VoltaDataSource, vehicleID: Int) async -> Outcome {
        guard let record = pending(dataSource: dataSource, vehicleID: vehicleID).first(where: { $0.intentID == intentID }) else {
            return .failed
        }
        guard !record.isExpired() else {
            let id = key(dataSource: dataSource, vehicleID: vehicleID)
            activities[id] = Activity(id: record.intentID, command: record.command, label: record.label,
                                      phase: .unknown,
                                      message: "This unresolved request is over 24 hours old and can no longer be replayed. Check the vehicle before allowing new commands.",
                                      canRetry: false, requiresAcknowledgement: true)
            return .unknown
        }
        guard record.retryNotBefore.map({ $0 <= .now }) ?? true else { return .unknown }
        return await send(record, dataSource: dataSource, isReplay: true)
    }

    func clearActivity(dataSource: any VoltaDataSource, vehicleID: Int) {
        guard pending(dataSource: dataSource, vehicleID: vehicleID).isEmpty else { return }
        activities.removeValue(forKey: key(dataSource: dataSource, vehicleID: vehicleID))
    }

    func acknowledgeCheckedVehicle(_ intentID: UUID, dataSource: any VoltaDataSource, vehicleID: Int) {
        guard pending(dataSource: dataSource, vehicleID: vehicleID).contains(where: { $0.intentID == intentID }) else { return }
        do {
            try store.remove(intentID)
            activities.removeValue(forKey: key(dataSource: dataSource, vehicleID: vehicleID))
        } catch {
            storageUnavailable = true
        }
    }

    private func send(_ record: PendingVehicleCommand, dataSource: any VoltaDataSource, isReplay: Bool = false) async -> Outcome {
        let id = key(dataSource: dataSource, vehicleID: record.vehicleID)
        guard !inFlight.contains(id), supports(record.command, dataSource: dataSource, vehicleID: record.vehicleID),
              isReplay || pending(dataSource: dataSource, vehicleID: record.vehicleID).isEmpty else {
            return .failed
        }
        inFlight.insert(id)
        do {
            // This completed atomic write is the gate before any network send.
            try store.upsert(record)
        } catch {
            storageUnavailable = true
            capabilities[id] = VehicleCommandCapabilities(available: false, reason: "intent_storage_unavailable", commands: [])
            activities[id] = Activity(id: record.intentID, command: record.command, label: record.label,
                                      phase: .failure,
                                      message: "Secure command storage is unavailable. Nothing was sent.", canRetry: false)
            inFlight.remove(id)
            return .failed
        }
        activities[id] = Activity(id: record.intentID, command: record.command, label: record.label,
                                  phase: .pending, message: "Sending \(record.label.lowercased())…", canRetry: false)
        defer { inFlight.remove(id) }
        do {
            _ = try await dataSource.command(vehicleID: record.vehicleID, command: record.command, intentID: record.intentID)
            do { try store.remove(record.intentID) }
            catch { storageUnavailable = true }
            let simulated = dataSource.simulatesVehicleCommands
            activities[id] = Activity(id: record.intentID, command: record.command, label: record.label,
                                      phase: simulated ? .simulated : .success,
                                      message: simulated ? "Demo simulated \(record.label.lowercased()). No vehicle was contacted."
                                                         : "\(record.label) accepted. Observed status may take time to update.",
                                      canRetry: false)
            return .succeeded(simulated: simulated)
        } catch let failure as VehicleCommandFailure {
            var unresolvedRecord = record
            if failure.isUnresolved {
                unresolvedRecord.retryNotBefore = Self.retryDate(failure.retryAfter)
                do { try store.upsert(unresolvedRecord) }
                catch { storageUnavailable = true }
            } else {
                do { try store.remove(record.intentID) }
                catch { storageUnavailable = true }
            }
            if ["commands_unavailable", "authorization_required", "reauthorization_required",
                "command_scope_required", "vehicle_not_found", "stub_mode"].contains(failure.code) {
                capabilities[id] = VehicleCommandCapabilities(available: false, reason: failure.code, commands: [])
            }
            let unknown = failure.isUnresolved
            activities[id] = Activity(id: record.intentID, command: record.command, label: record.label,
                                      phase: unknown ? .unknown : .failure, message: failure.message,
                                      canRetry: unknown, retryNotBefore: unresolvedRecord.retryNotBefore)
            return unknown ? .unknown : .failed
        } catch {
            activities[id] = Activity(id: record.intentID, command: record.command, label: record.label,
                                      phase: .unknown,
                                      message: "The outcome is unknown. It may have completed; check the vehicle before trying again.",
                                      canRetry: true)
            return .unknown
        }
    }

    private func key(dataSource: any VoltaDataSource, vehicleID: Int) -> String {
        "\(dataSource.commandBackendID)|\(vehicleID)"
    }

    private static func retryDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        if let seconds = TimeInterval(value) { return .now.addingTimeInterval(max(0, seconds)) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter.date(from: value)
    }
}

extension EnvironmentValues {
    @Entry var vehicleCommandCoordinator: VehicleCommandCoordinator? = nil
}
