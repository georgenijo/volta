import SwiftUI

/// Observed vehicle state for the controls, and the one path every control
/// (Controls, the Dashboard dock and Now card) sends commands through.
///
/// The Dashboard owns one instance for its vehicle and hands it to Controls,
/// so Controls keeps its state when the window changes between a sheet and a
/// pushed screen (folding or unfolding iPhone Duo).
@MainActor @Observable
final class ControlsModel {
    var status: VehicleStatus?
    var locked: Bool?
    var chargingState: ChargingState?
    var chargeLimit: Int?
    var climateOn: Bool?
    var sentry: Bool?
    /// Driver's cabin temperature setting as last observed (or simulated).
    var cabinTargetC: Double?

    /// A charge limit stepped to but not sent yet; see `stepChargeLimit`.
    private(set) var pendingChargeLimit: Int?
    /// A cabin temperature stepped to but not sent yet.
    private(set) var pendingCabinTargetC: Double?
    /// "Seats, wheel & defrost" is open. Kept here with its unsent
    /// temperatures, so both survive Controls moving between a sheet and a
    /// pushed screen when iPhone Duo folds.
    var climateOpen = false
    var climateDriverDraftC: Double?
    var climatePassengerDraftC: Double?

    /// Pause after the last step before one command is sent.
    @ObservationIgnored var settingDelay: Duration = .milliseconds(1200)
    /// Where sends are recorded; the app-wide log unless a test replaces it.
    @ObservationIgnored var log: VehicleCommandLog = .shared

    @ObservationIgnored private var refreshGeneration = 0
    @ObservationIgnored private var chargeLimitTask: Task<Void, Never>?
    @ObservationIgnored private var cabinTask: Task<Void, Never>?
    @ObservationIgnored private var logKey: String?

    static let chargeLimitRange = 50...100
    static let chargeLimitStep = 5
    static let cabinRangeC: ClosedRange<Double> = 15...28
    static let cabinStepC = 0.5

    init(status: VehicleStatus?) { apply(status) }

    /// The limit to show: what the owner is stepping to, else the observed one.
    var displayedChargeLimit: Int? { pendingChargeLimit ?? chargeLimit }
    /// The cabin temperature to show: what the owner is stepping to, else the observed one.
    var displayedCabinTargetC: Double? { pendingCabinTargetC ?? cabinTargetC }

    func apply(_ status: VehicleStatus?) {
        self.status = status
        guard let status else { return }
        locked = status.locked
        chargingState = status.chargingState
        chargeLimit = status.chargeLimit
        climateOn = status.climateOn
        sentry = status.sentryMode
        cabinTargetC = status.driverTempSettingC
        if let logKey { log.observe(status, key: logKey) }
    }

    /// Takes a status the Dashboard loaded, unless this model already shows a newer one.
    func observe(_ status: VehicleStatus, dataSource: any VoltaDataSource, vehicleID: Int) {
        logKey = VehicleCommandLog.key(backendID: dataSource.commandBackendID, vehicleID: vehicleID)
        guard status.updatedAt >= (self.status?.updatedAt ?? .distantPast) else { return }
        refreshGeneration += 1
        apply(status)
    }

    func refresh(dataSource: any VoltaDataSource, vehicleID: Int,
                 surfaces: (any VehicleSurfaces)? = nil) async {
        logKey = VehicleCommandLog.key(backendID: dataSource.commandBackendID, vehicleID: vehicleID)
        refreshGeneration += 1
        let token = refreshGeneration
        let issued = surfaces?.nextStatusToken()
        guard let fresh = try? await dataSource.status(vehicleID: vehicleID),
              token == refreshGeneration, !Task.isCancelled else { return }
        apply(fresh)
        if let surfaces, let issued {
            surfaces.publish(VehicleRefresh(status: fresh, issued: issued), dataSource: dataSource)
        }
    }

    @discardableResult
    func send(_ command: VehicleCommand, label: String, coordinator: VehicleCommandCoordinator,
              dataSource: any VoltaDataSource, vehicleID: Int,
              surfaces: (any VehicleSurfaces)? = nil, simulate: (() -> Void)? = nil) async -> Bool {
        let key = VehicleCommandLog.key(backendID: dataSource.commandBackendID, vehicleID: vehicleID)
        logKey = key
        refreshGeneration += 1
        // Only a send the coordinator will actually start is logged.
        let entry = coordinator.canStart(command, dataSource: dataSource, vehicleID: vehicleID)
            ? log.begin(command, label: label, key: key) : nil
        let outcome = await coordinator.perform(command, label: label, dataSource: dataSource, vehicleID: vehicleID)
        if let entry { log.finish(entry, with: outcome) }
        switch outcome {
        case .succeeded(let simulated):
            if simulated { simulate?() }
            else { await refresh(dataSource: dataSource, vehicleID: vehicleID, surfaces: surfaces) }
            return true
        case .failed, .unknown:
            return false
        }
    }

    /// Sends `command` with its standard label and, in demo mode, its simulated effect.
    @discardableResult
    func send(_ command: VehicleCommand, coordinator: VehicleCommandCoordinator, dataSource: any VoltaDataSource,
              vehicleID: Int, surfaces: (any VehicleSurfaces)? = nil) async -> Bool {
        await send(command, label: command.controlLabel, coordinator: coordinator, dataSource: dataSource,
                   vehicleID: vehicleID, surfaces: surfaces) { [weak self] in self?.simulate(command) }
    }

    /// What a simulated (demo) command changes locally.
    private func simulate(_ command: VehicleCommand) {
        switch command {
        case .lock: locked = true
        case .unlock: locked = false
        case .climateOn: climateOn = true
        case .climateOff: climateOn = false
        case .sentryOn: sentry = true
        case .sentryOff: sentry = false
        case .chargeStart: chargingState = .charging
        case .chargeStop: chargingState = .stopped
        case .setChargeLimit(let percent): chargeLimit = percent
        case .setTemperatures(let driver, _): cabinTargetC = driver
        default: break
        }
    }

    func setLocked(_ value: Bool, coordinator: VehicleCommandCoordinator, dataSource: any VoltaDataSource,
                   vehicleID: Int, surfaces: (any VehicleSurfaces)? = nil) async {
        await send(value ? .lock : .unlock, coordinator: coordinator, dataSource: dataSource,
                   vehicleID: vehicleID, surfaces: surfaces)
    }

    func setCharging(_ value: Bool, coordinator: VehicleCommandCoordinator, dataSource: any VoltaDataSource,
                     vehicleID: Int, surfaces: (any VehicleSurfaces)? = nil) async {
        await send(value ? .chargeStart : .chargeStop, coordinator: coordinator, dataSource: dataSource,
                   vehicleID: vehicleID, surfaces: surfaces)
    }

    func setClimate(_ value: Bool, coordinator: VehicleCommandCoordinator, dataSource: any VoltaDataSource,
                    vehicleID: Int, surfaces: (any VehicleSurfaces)? = nil) async {
        await send(value ? .climateOn : .climateOff, coordinator: coordinator, dataSource: dataSource,
                   vehicleID: vehicleID, surfaces: surfaces)
    }

    func setSentry(_ value: Bool, coordinator: VehicleCommandCoordinator, dataSource: any VoltaDataSource,
                   vehicleID: Int, surfaces: (any VehicleSurfaces)? = nil) async {
        await send(value ? .sentryOn : .sentryOff, coordinator: coordinator, dataSource: dataSource,
                   vehicleID: vehicleID, surfaces: surfaces)
    }

    /// Sends one charge limit change right away (no pause).
    func adjustChargeLimit(by delta: Int, coordinator: VehicleCommandCoordinator,
                           dataSource: any VoltaDataSource, vehicleID: Int,
                           surfaces: (any VehicleSurfaces)? = nil) async {
        guard let old = chargeLimit else { return }
        let value = Self.clampLimit(old + delta)
        guard value != old else { return }
        await send(.setChargeLimit(percent: value), coordinator: coordinator, dataSource: dataSource,
                   vehicleID: vehicleID, surfaces: surfaces)
    }

    // MARK: Stepped settings

    /// One step of the shared charge limit stepper. Steps only move the shown
    /// value; one command for the final value goes out `settingDelay` after
    /// the last step, so tapping + three times spends one command, not three.
    func stepChargeLimit(by delta: Int, coordinator: VehicleCommandCoordinator,
                         dataSource: any VoltaDataSource, vehicleID: Int,
                         surfaces: (any VehicleSurfaces)? = nil) {
        guard let current = displayedChargeLimit else { return }
        let value = Self.clampLimit(current + delta)
        guard value != current else { return }
        pendingChargeLimit = value
        chargeLimitTask?.cancel()
        let delay = settingDelay
        chargeLimitTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            // Not `commitChargeLimit`: that cancels this task, and the send
            // must not run in a cancelled task.
            self.chargeLimitTask = nil
            await self.sendPendingChargeLimit(coordinator: coordinator, dataSource: dataSource,
                                              vehicleID: vehicleID, surfaces: surfaces)
        }
    }

    /// Sends the stepped charge limit now, if it differs from the observed one.
    func commitChargeLimit(coordinator: VehicleCommandCoordinator, dataSource: any VoltaDataSource,
                           vehicleID: Int, surfaces: (any VehicleSurfaces)? = nil) async {
        chargeLimitTask?.cancel()
        chargeLimitTask = nil
        await sendPendingChargeLimit(coordinator: coordinator, dataSource: dataSource,
                                     vehicleID: vehicleID, surfaces: surfaces)
    }

    private func sendPendingChargeLimit(coordinator: VehicleCommandCoordinator, dataSource: any VoltaDataSource,
                                        vehicleID: Int, surfaces: (any VehicleSurfaces)?) async {
        guard let value = pendingChargeLimit else { return }
        guard value != chargeLimit else { pendingChargeLimit = nil; return }
        // A newer step owns the value when this returns false.
        guard await waitForTurn(coordinator: coordinator, dataSource: dataSource, vehicleID: vehicleID),
              pendingChargeLimit == value else { return }
        defer { if pendingChargeLimit == value { pendingChargeLimit = nil } }
        await sendStepped(.setChargeLimit(percent: value), coordinator: coordinator, dataSource: dataSource,
                          vehicleID: vehicleID, surfaces: surfaces)
    }

    /// Waits for a command already in flight to finish, so a stepped value is
    /// sent after it instead of being refused and dropped. False when this
    /// task was cancelled while waiting.
    private func waitForTurn(coordinator: VehicleCommandCoordinator, dataSource: any VoltaDataSource,
                             vehicleID: Int) async -> Bool {
        var waited = Duration.zero
        while coordinator.isBusy(dataSource: dataSource, vehicleID: vehicleID), waited < Self.turnTimeout {
            do { try await Task.sleep(for: Self.turnPoll) } catch { return false }
            waited += Self.turnPoll
        }
        return !Task.isCancelled
    }

    private static let turnPoll: Duration = .milliseconds(100)
    private static let turnTimeout: Duration = .seconds(30)

    /// Sends a stepped setting. One the coordinator refuses (an unresolved
    /// request, or controls no longer available) is logged as failed, so the
    /// change never disappears without a trace.
    private func sendStepped(_ command: VehicleCommand, coordinator: VehicleCommandCoordinator,
                             dataSource: any VoltaDataSource, vehicleID: Int,
                             surfaces: (any VehicleSurfaces)?) async {
        guard coordinator.canStart(command, dataSource: dataSource, vehicleID: vehicleID) else {
            let key = VehicleCommandLog.key(backendID: dataSource.commandBackendID, vehicleID: vehicleID)
            log.finish(log.begin(command, label: command.controlLabel, key: key), with: .failed)
            return
        }
        await send(command, coordinator: coordinator, dataSource: dataSource, vehicleID: vehicleID, surfaces: surfaces)
    }

    /// One step of the cabin temperature stepper; sent like the charge limit.
    /// Driver and passenger are set to the same temperature.
    func stepCabinTarget(by steps: Int, coordinator: VehicleCommandCoordinator,
                         dataSource: any VoltaDataSource, vehicleID: Int,
                         surfaces: (any VehicleSurfaces)? = nil) {
        guard let current = displayedCabinTargetC else { return }
        let value = min(Self.cabinRangeC.upperBound,
                        max(Self.cabinRangeC.lowerBound, current + Double(steps) * Self.cabinStepC))
        guard value != current else { return }
        pendingCabinTargetC = value
        cabinTask?.cancel()
        let delay = settingDelay
        cabinTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            self.cabinTask = nil
            await self.sendPendingCabinTarget(coordinator: coordinator, dataSource: dataSource,
                                              vehicleID: vehicleID, surfaces: surfaces)
        }
    }

    func commitCabinTarget(coordinator: VehicleCommandCoordinator, dataSource: any VoltaDataSource,
                           vehicleID: Int, surfaces: (any VehicleSurfaces)? = nil) async {
        cabinTask?.cancel()
        cabinTask = nil
        await sendPendingCabinTarget(coordinator: coordinator, dataSource: dataSource,
                                     vehicleID: vehicleID, surfaces: surfaces)
    }

    private func sendPendingCabinTarget(coordinator: VehicleCommandCoordinator, dataSource: any VoltaDataSource,
                                        vehicleID: Int, surfaces: (any VehicleSurfaces)?) async {
        guard let value = pendingCabinTargetC else { return }
        guard value != cabinTargetC else { pendingCabinTargetC = nil; return }
        guard await waitForTurn(coordinator: coordinator, dataSource: dataSource, vehicleID: vehicleID),
              pendingCabinTargetC == value else { return }
        defer { if pendingCabinTargetC == value { pendingCabinTargetC = nil } }
        await sendStepped(.setTemperatures(driverTempC: value, passengerTempC: value), coordinator: coordinator,
                          dataSource: dataSource, vehicleID: vehicleID, surfaces: surfaces)
    }

    private static func clampLimit(_ value: Int) -> Int {
        min(chargeLimitRange.upperBound, max(chargeLimitRange.lowerBound, value))
    }
}

// MARK: - Command wording and confirmations

extension VehicleCommand {
    /// The label a command is sent, logged and announced with.
    var controlLabel: String {
        switch self {
        case .lock: "Lock"
        case .unlock: "Unlock"
        case .climateOn: "Start climate"
        case .climateOff: "Stop climate"
        case .setTemperatures: "Set cabin temperature"
        case .chargeStart: "Start charging"
        case .chargeStop: "Stop charging"
        case .setChargeLimit(let percent): "Set charge limit to \(percent)%"
        case .openChargePort: "Open charge port"
        case .closeChargePort: "Close charge port"
        case .actuateTrunk(.front): "Open frunk"
        case .actuateTrunk(.rear): "Open trunk"
        case .windowControl(.vent): "Vent windows"
        case .windowControl(.close): "Close windows"
        case .honk: "Honk horn"
        case .flash: "Flash lights"
        case .sentryOn: "Arm Sentry"
        case .sentryOff: "Disarm Sentry"
        case .triggerHomeLink: "Activate HomeLink"
        case .wakeUp: "Wake request"
        case .seatHeater(_, let level): "Set seat heat to \(level)"
        case .steeringWheelHeat(let on): on ? "Turn on steering wheel heat" : "Turn off steering wheel heat"
        case .defrost(let on): on ? "Turn on defrost" : "Turn off defrost"
        }
    }
}

/// A command that needs the owner's confirmation before it is sent. The same
/// table serves Controls, the Dashboard dock and the Now card.
struct CommandConfirmation: Identifiable {
    let id = UUID()
    let command: VehicleCommand
    let label: String
    let title: String
    let message: String
    let button: String

    /// The confirmation `command` needs, or nil when it is sent on a tap.
    static func required(for command: VehicleCommand) -> CommandConfirmation? {
        let text: (title: String, message: String)? = switch command {
        case .lock: ("Lock the vehicle?", "This will remotely lock all doors.")
        case .unlock: ("Unlock the vehicle?", "This will remotely unlock all doors. Make sure the vehicle is secure.")
        case .actuateTrunk(.front): ("Open the frunk?", "The frunk can only be closed by hand. Make sure nothing is above it.")
        case .actuateTrunk(.rear): ("Actuate the trunk?", "This sends Tesla's remote trunk actuation command. Check clearance first.")
        case .openChargePort: ("Open the charge port?", "This remotely opens the vehicle's charge port door.")
        case .closeChargePort: ("Close the charge port?", "Make sure no charging connector is inserted.")
        case .windowControl(.vent): ("Vent the windows?", "This slightly opens the windows and may expose the cabin to weather.")
        case .windowControl(.close): ("Close the windows?", "Make sure hands and objects are clear of every window.")
        case .honk: ("Honk the horn?", "This will immediately sound the vehicle horn and may disturb people nearby.")
        case .triggerHomeLink: ("Activate HomeLink now?", "This may open or close a nearby garage door. Confirm the area is clear and you can observe the door.")
        default: nil
        }
        guard let text else { return nil }
        return CommandConfirmation(command: command, label: command.controlLabel, title: text.title,
                                   message: text.message, button: command.controlLabel)
    }
}
