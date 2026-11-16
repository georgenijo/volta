import Foundation
import WidgetKit

extension AppModel {
    /// The one model for the process: the UI and every App Intent share it, so
    /// intents see the same pairing, demo state and command coordinator (an
    /// in-flight or unresolved command blocks both).
    static let shared = AppModel()
}

/// What Siri and Shortcuts answer from: the App Group snapshot the widgets use,
/// or, in demo mode, a snapshot built from the synthetic demo status (demo data
/// never reaches the App Group).
struct VehicleReading: Sendable {
    var snapshot: WidgetSnapshot
    var isDemo: Bool
}

/// The vehicle a command goes to.
struct IntentCommandTarget: Sendable {
    var dataSource: any VoltaDataSource
    var vehicleID: Int
    var vehicleName: String
}

/// App-process side of every App Intent. Reads answer from the cached snapshot;
/// commands go through the shared `VehicleCommandCoordinator`, exactly like the
/// Controls sheet (durable intent record first, capability gating, replay rules).
@MainActor
final class VehicleIntentService: VehicleIntentPerforming {
    static let shared = VehicleIntentService { AppModel.shared }

    private let model: @MainActor () -> AppModel
    private let readSnapshot: @MainActor () -> WidgetSnapshot?
    private let reloadControls: @MainActor () -> Void

    init(model: @escaping @MainActor () -> AppModel,
         readSnapshot: @escaping @MainActor () -> WidgetSnapshot? = { WidgetSnapshotStore.read() },
         reloadControls: @escaping @MainActor () -> Void = { ControlCenter.shared.reloadAllControls() }) {
        self.model = model
        self.readSnapshot = readSnapshot
        self.reloadControls = reloadControls
    }

    // MARK: Reads

    func reading(now: Date = .now) async throws -> VehicleReading {
        let model = model()
        if model.isDemoMode {
            let source = model.dataSource
            let vehicleID = MockDataSource.vehicleID
            let status = try await source.status(vehicleID: vehicleID)
            let name = (try? await source.vehicles())?.first { $0.id == vehicleID }?.name ?? "Friday"
            let snapshot = WidgetSnapshot(status: status, vehicleName: name, summary: nil, timeline: nil,
                                          units: model.units, now: now)
            return VehicleReading(snapshot: snapshot, isDemo: true)
        }
        guard model.isPaired || model.needsCredentialRetry else { throw VoltaIntentError.notSignedIn }
        guard let snapshot = readSnapshot() else { throw VoltaIntentError.noReading }
        return VehicleReading(snapshot: snapshot, isDemo: false)
    }

    // MARK: Commands

    func showControls() { model().controlsRequested = true }

    /// Sends without a confirmation step; refused for actions that need one.
    func perform(_ action: VehicleIntentAction) async throws -> String {
        try await perform(action, confirm: nil)
    }

    /// Every route: Siri, Shortcuts and controls. `confirm` runs after every
    /// check passes and before anything is sent; it receives the vehicle name
    /// and throws to cancel. Actions that require confirmation are refused
    /// without it, whichever route sent them.
    func perform(_ action: VehicleIntentAction,
                 confirm: (@MainActor (String) async throws -> Void)?) async throws -> String {
        guard confirm != nil || !action.requiresConfirmation else { throw VoltaIntentError.confirmationRequired }
        return try await send(action, confirm: confirm)
    }

    private func send(_ action: VehicleIntentAction,
                      confirm: (@MainActor (String) async throws -> Void)?) async throws -> String {
        let model = model()
        // Launched in the background before first unlock: retry the Keychain
        // before capturing the context, since restoring replaces the source.
        if !model.isDemoMode, model.needsCredentialRetry { model.restorePairing() }
        // Every await below can let the app change pairing, demo mode, data
        // source or vehicle. Recheck after each one; a stale target sends nothing.
        let context = CommandContext(model)
        let target = try await commandTarget(model: model)
        try context.ensureCurrent(model)
        let command = action.command
        let coordinator = model.commandCoordinator
        let simulates = target.dataSource.simulatesVehicleCommands
        if !simulates {
            let failure = await coordinator.refreshCapabilities(dataSource: target.dataSource, vehicleID: target.vehicleID)
            try context.ensureCurrent(model)
            if let failure { throw Self.mapRequestError(failure, action: action) }
        }
        if let blocked = VehicleIntentGate.check(
            action,
            capability: coordinator.capability(dataSource: target.dataSource, vehicleID: target.vehicleID),
            simulates: simulates,
            supportedBySource: coordinator.supports(command, dataSource: target.dataSource, vehicleID: target.vehicleID),
            hasPending: !coordinator.pending(dataSource: target.dataSource, vehicleID: target.vehicleID).isEmpty,
            isBusy: coordinator.isBusy(dataSource: target.dataSource, vehicleID: target.vehicleID)) {
            throw blocked
        }
        if let confirm {
            try await confirm(target.vehicleName)
            try context.ensureCurrent(model)
        }
        let outcome = await coordinator.perform(command, label: action.label, dataSource: target.dataSource,
                                                vehicleID: target.vehicleID)
        // Controls show the requested state while the action runs; reload so
        // they settle on what the snapshot observes, whatever the outcome.
        defer { reloadControls() }
        let message = coordinator.activity(dataSource: target.dataSource, vehicleID: target.vehicleID)?.message
        switch outcome {
        case .succeeded(let simulated):
            if !simulated { await publishObservedStatus(model: model, target: target) }
            return VehicleIntentGate.successDialog(action, vehicleName: target.vehicleName, simulated: simulated)
        case .failed:
            // The source was replaced after the last check; it refused to send.
            if CommandContext(model) != context { throw VoltaIntentError.connectionChanged }
            throw VoltaIntentError(kind: .commandFailed, message: message ?? "Volta couldn’t \(action.verbPhrase) \(target.vehicleName).")
        case .unknown:
            throw VoltaIntentError(kind: .outcomeUnknown, message: message
                ?? "The outcome is unknown. It may have completed; check the vehicle before trying again.")
        }
    }

    /// The selected vehicle. Never falls back to the demo vehicle id while paired.
    func commandTarget(model: AppModel) async throws -> IntentCommandTarget {
        if model.isDemoMode {
            let source = model.dataSource
            let name = (try? await source.vehicles())?.first { $0.id == MockDataSource.vehicleID }?.name ?? "Friday"
            return IntentCommandTarget(dataSource: source, vehicleID: MockDataSource.vehicleID, vehicleName: name)
        }
        if model.needsCredentialRetry { throw VoltaIntentError.deviceLocked }
        guard model.isPaired else { throw VoltaIntentError.notSignedIn }
        let source = model.dataSource
        var vehicles = model.vehicles
        var vehicleID = model.settings.selectedVehicleID ?? Vehicle.automaticChoice(in: vehicles)?.id
        if vehicleID == nil || !vehicles.contains(where: { $0.id == vehicleID }) {
            do { vehicles = try await source.vehicles() }
            catch { if vehicleID == nil { throw Self.mapRequestError(error, action: nil) } }
            vehicleID = vehicleID ?? Vehicle.automaticChoice(in: vehicles)?.id
        }
        guard let vehicleID else {
            throw VoltaIntentError(kind: .vehicleNotConfigured, message: "Volta doesn’t have a vehicle yet. Open Volta to finish setup.")
        }
        let snapshot = readSnapshot()
        let name = vehicles.first { $0.id == vehicleID }?.name
            ?? (snapshot?.vehicleId == vehicleID ? snapshot?.vehicleName : nil)
            ?? "your car"
        return IntentCommandTarget(dataSource: source, vehicleID: vehicleID, vehicleName: name)
    }

    /// After an accepted command, refresh the observed status so widgets and
    /// controls show what the car reports (not what was requested).
    private func publishObservedStatus(model: AppModel, target: IntentCommandTarget) async {
        if !model.hasLoadedVehicles { await model.loadVehicles() }
        if let surfaces = model.refreshSurfaces {
            let issued = surfaces.nextStatusToken()
            if let status = try? await target.dataSource.status(vehicleID: target.vehicleID) {
                surfaces.publish(VehicleRefresh(status: status, issued: issued), dataSource: target.dataSource)
            }
        }
    }

    nonisolated static func mapRequestError(_ error: any Error, action: VehicleIntentAction?) -> VoltaIntentError {
        switch error {
        case let error as VoltaIntentError: return error
        case VoltaError.unauthorized:
            return VoltaIntentError(kind: .notSignedIn, message: "This device is no longer paired with your Volta server. Open Volta to sign in again.")
        case is CancellationError:
            return VoltaIntentError(kind: .commandFailed, message: "The request was cancelled. Nothing was sent.")
        default:
            let what = action.map { " so it couldn’t \($0.verbPhrase)" } ?? ""
            return VoltaIntentError(kind: .serverUnreachable,
                message: "Volta couldn’t reach your server\(what). Check that Tailscale is connected, then try again. Nothing was sent.")
        }
    }
}

/// What a command was prepared against. If any part changes while the
/// command awaits (the person disconnects, switches to demo mode, re-pairs or
/// picks another car), the prepared target is stale and nothing is sent.
@MainActor
struct CommandContext: Equatable {
    var pairingState: AppModel.PairingState
    var connectionGeneration: Int
    var selectedVehicleID: Int?

    init(_ model: AppModel) {
        pairingState = model.pairingState
        connectionGeneration = model.connectionGeneration
        selectedVehicleID = model.settings.selectedVehicleID
    }

    func ensureCurrent(_ model: AppModel) throws {
        guard CommandContext(model) == self else { throw VoltaIntentError.connectionChanged }
    }
}

/// Pure checks and wording, shared by every action intent and unit tested.
enum VehicleIntentGate {
    /// Why `action` can't be sent now, or nil when it can.
    static func check(_ action: VehicleIntentAction, capability: VehicleCommandCapabilities?, simulates: Bool,
                      supportedBySource: Bool, hasPending: Bool, isBusy: Bool) -> VoltaIntentError? {
        if !simulates {
            guard let capability else { return reason(nil, action: action) }
            if !capability.available { return reason(capability.reason, action: action) }
        }
        if !supportedBySource {
            return VoltaIntentError(kind: .notAllowed,
                message: "Your Volta server doesn’t allow Volta to \(action.verbPhrase). Nothing was sent.")
        }
        if hasPending {
            return VoltaIntentError(kind: .unresolvedCommand,
                message: "An earlier command has no confirmed result. Open Volta to check it before sending another.")
        }
        if isBusy {
            return VoltaIntentError(kind: .busy, message: "Another command is still being sent. Try again in a moment.")
        }
        return nil
    }

    /// Spoken reason for a server-reported unavailability.
    static func reason(_ code: String?, action: VehicleIntentAction) -> VoltaIntentError {
        switch code {
        case "authorization_required":
            VoltaIntentError(kind: .teslaNotLinked, message: "Tesla isn’t linked to Volta yet. Open Volta to connect Tesla.")
        case "reauthorization_required", "command_scope_required", "permission_denied":
            VoltaIntentError(kind: .teslaConsentNeeded,
                message: "Volta needs your permission to control the car. Open Volta and choose Enable vehicle controls.")
        case "vehicle_not_found":
            VoltaIntentError(kind: .vehicleNotConfigured, message: "This car isn’t set up for commands on your Volta server.")
        case "intent_storage_unavailable":
            VoltaIntentError(kind: .storageUnavailable, message: "Secure command storage is unavailable, so nothing was sent.")
        case "stub_mode":
            VoltaIntentError(kind: .commandsDisabled,
                message: "Your Volta server is in simulation mode, so live vehicle commands are off. Nothing was sent.")
        default:
            VoltaIntentError(kind: .commandsDisabled,
                message: "Vehicle commands are turned off on your Volta server. Nothing was sent.")
        }
    }

    /// "Locking Friday." Accepted means Tesla took the request; the car's
    /// observed state may lag, so the wording never claims it already happened.
    static func successDialog(_ action: VehicleIntentAction, vehicleName name: String, simulated: Bool) -> String {
        let text = realDialog(action, vehicleName: name)
        guard simulated else { return text }
        return "Simulated in demo mode: \(text.prefix(1).lowercased())\(text.dropFirst()) No vehicle was contacted."
    }

    private static func realDialog(_ action: VehicleIntentAction, vehicleName name: String) -> String {
        switch action {
        case .lock: "Locking \(name)."
        case .unlock: "Unlocking \(name)."
        case .climateOn: "Turning on climate in \(name)."
        case .climateOff: "Turning off climate in \(name)."
        case .chargeStart: "Starting to charge \(name)."
        case .chargeStop: "Stopping charging for \(name)."
        case .openChargePort: "Opening the charge port on \(name)."
        case .closeChargePort: "Closing the charge port on \(name)."
        case .sentryOn: "Turning on Sentry Mode for \(name)."
        case .sentryOff: "Turning off Sentry Mode for \(name)."
        case .flashLights: "Flashing the lights on \(name)."
        case .honk: "Honking the horn on \(name)."
        case .openFrunk: "Opening the frunk on \(name)."
        case .openTrunk: "Opening the trunk on \(name)."
        }
    }
}

extension VehicleIntentAction {
    /// The typed command the existing command path sends.
    var command: VehicleCommand {
        switch self {
        case .lock: .lock
        case .unlock: .unlock
        case .climateOn: .climateOn
        case .climateOff: .climateOff
        case .chargeStart: .chargeStart
        case .chargeStop: .chargeStop
        case .openChargePort: .openChargePort
        case .closeChargePort: .closeChargePort
        case .sentryOn: .sentryOn
        case .sentryOff: .sentryOff
        case .flashLights: .flash
        case .honk: .honk
        case .openFrunk: .actuateTrunk(whichTrunk: .front)
        case .openTrunk: .actuateTrunk(whichTrunk: .rear)
        }
    }
}
