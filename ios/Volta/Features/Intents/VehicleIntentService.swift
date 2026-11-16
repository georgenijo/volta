import Foundation
import UIKit
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

    /// How long an intent waits for the car's answer before saying the
    /// request is still on its way. Siri stops an intent after about ten
    /// seconds and Shortcuts after thirty, and either one cancels the intent
    /// when it does (as does a second tap on a running shortcut). A sleeping
    /// car takes longer than that to wake and answer.
    static let answerWithin: Duration = .seconds(8)

    private let model: @MainActor () -> AppModel
    private let readSnapshot: @MainActor () -> WidgetSnapshot?
    private let reloadControls: @MainActor () -> Void
    private let answerWithin: Duration
    private let holdBackgroundTime: @MainActor (String) -> @MainActor () -> Void
    /// Commands (and replays) intents started that may still be running,
    /// by backend and vehicle. They outlive the intent that started them.
    private var sends: [String: IntentCommandSend] = [:]
    /// Results that arrived after their intent stopped waiting, told with
    /// the next command for that car.
    private var lateReports: [String: LateReport] = [:]
    private struct LateReport {
        var command: VehicleCommand
        var accepted: Bool
        var text: String
        var at: Date
        /// The request's own activity when its result arrived (nil if another
        /// command had already replaced it). Any later command changes the
        /// car's activity, and the result is then no longer the latest.
        var activity: VehicleCommandCoordinator.Activity?
    }
    /// A repeat of a command the car accepted this recently is answered
    /// with that result instead of being sent again.
    static let repeatWindow: TimeInterval = 120
    /// An unresolved request is replayed unattended only this soon after it
    /// was made, while performing it late still matches what the person
    /// asked for. Older ones wait for Controls. Well inside commander's
    /// 24-hour receipt lifetime, so a replay never acts twice.
    static let unattendedReplayAge: TimeInterval = 10 * 60
    /// Work that continues after an intent answers (publishing the observed
    /// status, reloading controls). Tests await it.
    private var followUps: [UUID: Task<Void, Never>] = [:]

    init(model: @escaping @MainActor () -> AppModel,
         readSnapshot: @escaping @MainActor () -> WidgetSnapshot? = { WidgetSnapshotStore.read() },
         reloadControls: @escaping @MainActor () -> Void = { ControlCenter.shared.reloadAllControls() },
         answerWithin: Duration = VehicleIntentService.answerWithin,
         holdBackgroundTime: @escaping @MainActor (String) -> @MainActor () -> Void = BackgroundTime.hold) {
        self.model = model
        self.readSnapshot = readSnapshot
        self.reloadControls = reloadControls
        self.answerWithin = answerWithin
        self.holdBackgroundTime = holdBackgroundTime
    }

    /// Waits for every command and follow-up an intent left running.
    func finishBackgroundWork() async {
        while let task = followUps.values.first { await task.value }
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

    /// The lock control's unlock: nothing is sent, so reload the controls to
    /// settle the toggle back on the observed state.
    func showControls() {
        model().requestControls()
        reloadControls()
    }

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
        var deadline = ContinuousClock.now.advanced(by: answerWithin)
        // Every await below can let the app change pairing, demo mode, data
        // source or vehicle. Recheck after each one; a stale target sends nothing.
        let context = CommandContext(model)
        // Finding the car and refreshing what it allows are reads, held to the
        // same deadline: a slow server must not use up the intent's time.
        guard let target = try await Self.prepare(until: deadline, { try await self.commandTarget(model: model) }) else {
            throw VehicleIntentGate.preparationTimedOut(vehicleName: nil)
        }
        try context.ensureCurrent(model)
        let command = action.command
        let coordinator = model.commandCoordinator
        let simulates = target.dataSource.simulatesVehicleCommands
        if !simulates {
            guard let refreshed = try await Self.prepare(until: deadline, {
                await coordinator.refreshCapabilities(dataSource: target.dataSource, vehicleID: target.vehicleID)
            }) else { throw VehicleIntentGate.preparationTimedOut(vehicleName: target.vehicleName) }
            try context.ensureCurrent(model)
            if let failure = refreshed { throw Self.mapRequestError(failure, action: action) }
        }
        let key = Self.key(target)
        var preface = ""
        if let late = lateReports.removeValue(forKey: key) {
            // Only while that result is still the car's latest command: nothing
            // sent since (from Controls or elsewhere), and nothing unresolved.
            let latest = sends[key] == nil
                && late.activity != nil
                && coordinator.activity(dataSource: target.dataSource, vehicleID: target.vehicleID) == late.activity
                && !coordinator.isBusy(dataSource: target.dataSource, vehicleID: target.vehicleID)
                && coordinator.pending(dataSource: target.dataSource, vehicleID: target.vehicleID).isEmpty
            if latest, late.accepted, late.command == command, Date.now.timeIntervalSince(late.at) < Self.repeatWindow {
                return VehicleIntentGate.alreadyDoneDialog(phrase: action.verbPhrase, vehicleName: target.vehicleName)
            }
            preface = late.text + " "
        }
        // An earlier command for this car is settled first: waited for while
        // it runs, or replayed with its own key when its result was lost.
        switch try await settleEarlier(before: action, target: target, coordinator: coordinator,
                                       model: model, context: context, deadline: deadline) {
        case .clear(let report?): preface += report + " "
        case .clear(nil): break
        case .alreadyDone(let report): return preface + report
        }
        if let blocked = VehicleIntentGate.check(
            action,
            capability: coordinator.capability(dataSource: target.dataSource, vehicleID: target.vehicleID),
            simulates: simulates,
            supportedBySource: coordinator.supports(command, dataSource: target.dataSource, vehicleID: target.vehicleID),
            hasPending: !coordinator.pending(dataSource: target.dataSource, vehicleID: target.vehicleID).isEmpty,
            isBusy: coordinator.isBusy(dataSource: target.dataSource, vehicleID: target.vehicleID)) {
            throw blocked.prefixed(preface)
        }
        if let confirm {
            try await confirm(target.vehicleName)
            try context.ensureCurrent(model)
            // Cancelled as the confirmation finished: nothing is started.
            try Task.checkCancellation()
            // The wait for the person's answer isn't the car's time.
            deadline = ContinuousClock.now.advanced(by: answerWithin)
        }
        let requestID = UUID()
        let delivery = start(command: command, phrase: action.verbPhrase, target: target, model: model, context: context,
                             requestID: requestID) {
            await coordinator.perform(command, label: action.label, dataSource: target.dataSource, vehicleID: target.vehicleID,
                                      intentID: requestID)
        }
        let outcome: VehicleCommandCoordinator.Outcome
        switch await waitForOwn(delivery, until: deadline) {
        case .answered(let answer): outcome = answer
        case .onItsWay: return preface + VehicleIntentGate.stillWaitingDialog(action, vehicleName: target.vehicleName)
        case .takenBack:
            throw VoltaIntentError(kind: .serverUnreachable, message: preface
                + "Volta couldn’t start sending the request to \(action.verbPhrase) to \(target.vehicleName) in time, so nothing was sent. Try again in a moment.")
        }
        switch outcome {
        case .succeeded(let simulated):
            return preface + VehicleIntentGate.successDialog(action, vehicleName: target.vehicleName, simulated: simulated)
        case .failed:
            // The source was replaced after the last check; it refused to send.
            if CommandContext(model) != context { throw VoltaIntentError.connectionChanged.prefixed(preface) }
            throw VoltaIntentError(kind: .commandFailed, message: preface + (delivery.message
                ?? "Volta couldn’t send the request to \(action.verbPhrase) to \(target.vehicleName). Nothing was sent."))
        case .unknown:
            throw VoltaIntentError(kind: .outcomeUnknown,
                message: preface + VehicleIntentGate.unknownDialog(action, vehicleName: target.vehicleName))
        }
    }

    enum Settled: Equatable {
        /// Nothing earlier blocks this command; the report, if any, says what became of it.
        case clear(String?)
        /// The earlier command was this same one, and the car just accepted it.
        case alreadyDone(String)
    }

    /// Settles every earlier command for this car before a new one is sent,
    /// within the intent's time. Throws, with nothing new sent, when one is
    /// still unanswered or can't be checked without the person.
    func settleEarlier(before action: VehicleIntentAction, target: IntentCommandTarget,
                       coordinator: VehicleCommandCoordinator, model: AppModel,
                       context: CommandContext, deadline: ContinuousClock.Instant) async throws -> Settled {
        let key = Self.key(target)
        let name = target.vehicleName
        var reports: [String] = []
        var joined: String? { reports.isEmpty ? nil : reports.joined(separator: " ") }
        func blocked(_ kind: VoltaIntentError.Kind, _ message: String) -> VoltaIntentError {
            VoltaIntentError(kind: kind, message: ([joined].compactMap { $0 } + [message]).joined(separator: " "))
        }
        func activity() -> VehicleCommandCoordinator.Activity? {
            coordinator.activity(dataSource: target.dataSource, vehicleID: target.vehicleID)
        }
        // The last earlier request the car accepted here, with the activity it
        // left. It answers a repeat only if it is still the car's latest.
        var accepted: (command: VehicleCommand, phrase: String, report: Int, activity: VehicleCommandCoordinator.Activity?)?
        func settled(_ outcome: VehicleCommandCoordinator.Outcome, by send: IntentCommandSend) {
            guard let report = VehicleIntentGate.earlierReport(outcome, phrase: send.phrase, vehicleName: name,
                                                               detail: send.message) else { return }
            reports.append(report)
            if case .succeeded = outcome { accepted = (send.command, send.phrase, reports.count - 1, send.activity) }
        }
        // A command an earlier intent started, still running in this process.
        if let running = sends[key] {
            guard let outcome = await running.wait(until: deadline) else {
                throw blocked(.busy, "\(name) hasn’t answered your earlier request to \(running.phrase) yet, so nothing new was sent. Try again in a moment.")
            }
            try context.ensureCurrent(model)
            settled(outcome, by: running)
        }
        if coordinator.isBusy(dataSource: target.dataSource, vehicleID: target.vehicleID) {
            throw blocked(.busy, "Volta is still sending another command to \(name), so nothing new was sent. Try again in a moment.")
        }
        // Commands whose result was lost (the app stopped, or the request was
        // cut off). Replaying with the same key returns the server's saved
        // result and never acts twice.
        for record in coordinator.pending(dataSource: target.dataSource, vehicleID: target.vehicleID) {
            let phrase = VehicleIntentGate.requestPhrase(record.command, label: record.label)
            // A replay the server never received performs the command now, so
            // only a recent request for a command that is harmless late.
            let recent = Date.now.timeIntervalSince(record.createdAt) < Self.unattendedReplayAge
            guard recent, record.command.replaysUnattended, record.command.allowsSavedRetry, !record.isExpired() else {
                throw blocked(.unresolvedCommand,
                    "Your earlier request to \(phrase) has no confirmed result, so nothing new was sent. Open Volta’s Controls to check it.")
            }
            if let notBefore = record.retryNotBefore, notBefore > .now {
                let seconds = max(1, Int(notBefore.timeIntervalSinceNow.rounded(.up)))
                throw blocked(.unresolvedCommand,
                    "Tesla asked Volta to wait before checking your earlier request to \(phrase), so nothing new was sent. Try again in \(seconds) seconds.")
            }
            let replay = start(command: record.command, phrase: phrase, target: target, model: model, context: context,
                               requestID: record.intentID) {
                await coordinator.retry(record.intentID, dataSource: target.dataSource, vehicleID: target.vehicleID)
            }
            let outcome: VehicleCommandCoordinator.Outcome
            switch await waitForOwn(replay, until: deadline) {
            case .answered(let answer): outcome = answer
            case .onItsWay:
                throw blocked(.busy, "Volta is checking your earlier request to \(phrase) with \(name), so nothing new was sent. Try again in a moment.")
            case .takenBack:
                throw blocked(.busy, "Volta couldn’t check your earlier request to \(phrase) with \(name) in time, so nothing new was sent. Try again in a moment.")
            }
            try context.ensureCurrent(model)
            if case .unknown = outcome {
                throw blocked(.unresolvedCommand, VehicleIntentGate.stillUnresolvedDialog(phrase: phrase, detail: replay.message))
            }
            settled(outcome, by: replay)
        }
        // A repeat of the request the car just accepted isn't sent again, but
        // only while nothing else has run since (from Controls, say) and
        // nothing is left unresolved.
        if let accepted, accepted.command == action.command, accepted.activity != nil, accepted.activity == activity(),
           !coordinator.isBusy(dataSource: target.dataSource, vehicleID: target.vehicleID),
           coordinator.pending(dataSource: target.dataSource, vehicleID: target.vehicleID).isEmpty {
            reports.remove(at: accepted.report)
            return .alreadyDone(([joined].compactMap { $0 }
                + [VehicleIntentGate.alreadyDoneDialog(phrase: accepted.phrase, vehicleName: name)]).joined(separator: " "))
        }
        return .clear(joined)
    }

    /// Starts a send that finishes even if the intent waiting for it is
    /// cancelled or stops waiting: once a request is on its way, its answer
    /// must be recorded, or the command stays unresolved. Background time
    /// keeps the app running until the answer arrives.
    private func start(command: VehicleCommand, phrase: String, target: IntentCommandTarget, model: AppModel,
                       context: CommandContext, requestID: UUID,
                       _ work: @escaping @MainActor () async -> VehicleCommandCoordinator.Outcome) -> IntentCommandSend {
        let key = Self.key(target)
        let send = IntentCommandSend(command: command, phrase: phrase)
        sends[key] = send
        let release = holdBackgroundTime("Volta vehicle command")
        let coordinator = model.commandCoordinator
        let id = UUID()
        let before = coordinator.activity(dataSource: target.dataSource, vehicleID: target.vehicleID)
        followUps[id] = Task { @MainActor [weak self] in
            // The task runs after the caller's last check. If pairing, the
            // connection or the selected car changed in between, send nothing;
            // the caller reports the change. No await between this check and
            // the send, so nothing can change in between.
            let current = CommandContext(model) == context
            let outcome: VehicleCommandCoordinator.Outcome = if current {
                await CommandStartGate.$current.withValue(send.startGate) { await work() }
            } else {
                .failed
            }
            // Only this request's own activity speaks for it: one refused before
            // it starts leaves an earlier activity in place, and a command that
            // ran before this task resumed (from Controls, say) replaces it.
            let after = coordinator.activity(dataSource: target.dataSource, vehicleID: target.vehicleID)
            let own = after?.id == requestID ? after : nil
            let message = own != before ? own?.message : nil
            let heard = send.finish(outcome, message: message, activity: own)
            guard let self else { release(); return }
            defer { self.followUps[id] = nil }
            if self.sends[key] === send { self.sends[key] = nil }
            if current, !heard, !send.startGate.wasAbandoned, let report = VehicleIntentGate.earlierReport(outcome, phrase: phrase, vehicleName: target.vehicleName,
                                                                    detail: message) {
                let accepted = if case .succeeded = outcome { true } else { false }
                self.lateReports[key] = LateReport(command: command, accepted: accepted, text: report, at: .now,
                                                   activity: own)
            }
            if case .succeeded(simulated: false) = outcome { await self.publishObservedStatus(model: model, target: target) }
            // Controls show the requested state while the action runs; reload so
            // they settle on what the snapshot observes, whatever the outcome.
            self.reloadControls()
            release()
        }
        return send
    }

    enum OwnWait { case answered(VehicleCommandCoordinator.Outcome), onItsWay, takenBack }

    /// Waits for a send this intent started. When the intent is cancelled, or
    /// the deadline passes, before the request actually started, it is taken
    /// back and nothing is sent; once started, it runs to its answer.
    private func waitForOwn(_ send: IntentCommandSend, until deadline: ContinuousClock.Instant) async -> OwnWait {
        let gate = send.startGate
        let outcome = await withTaskCancellationHandler {
            await send.wait(until: deadline)
        } onCancel: {
            gate.abandon()
        }
        if let outcome { return .answered(outcome) }
        return gate.abandon() ? .takenBack : .onItsWay
    }

    /// Runs a read the intent needs before sending, until `deadline`. Past
    /// it, nil comes back and the read finishes on its own; it sends nothing.
    static func prepare<T: Sendable>(until deadline: ContinuousClock.Instant,
                                     _ operation: @escaping @MainActor () async throws -> T) async throws -> T? {
        try await PreparationRace<T>().run(until: deadline, operation)
    }

    nonisolated static func key(_ target: IntentCommandTarget) -> String {
        "\(target.dataSource.commandBackendID)|\(target.vehicleID)"
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
        // Only a list fetched from the server may choose or confirm the car;
        // one restored from the saved dashboard may only name it (below).
        var vehicles = model.hasFetchedVehicles ? model.vehicles : []
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
            ?? model.vehicles.first { $0.id == vehicleID }?.name
            ?? (snapshot?.vehicleId == vehicleID ? snapshot?.vehicleName : nil)
            ?? "your car"
        return IntentCommandTarget(dataSource: source, vehicleID: vehicleID, vehicleName: name)
    }

    /// After an accepted command, refresh the observed status so widgets and
    /// controls show what the car reports (not what was requested). Runs after
    /// the intent answered, so a slow or failing status read never delays it.
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
        // A command still on its way isn't unresolved; say which it is.
        if isBusy {
            return VoltaIntentError(kind: .busy,
                message: "Volta is still sending another command to the car, so nothing new was sent. Try again in a moment.")
        }
        if hasPending {
            return VoltaIntentError(kind: .unresolvedCommand,
                message: "An earlier command has no confirmed result, so nothing new was sent. Open Volta’s Controls to check it.")
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

    /// The intent stopped waiting, but the request is on its way and its
    /// answer is still recorded. Never claims that the car acted.
    static func stillWaitingDialog(_ action: VehicleIntentAction, vehicleName name: String) -> String {
        "Volta sent the request to \(action.verbPhrase) to \(name), but the car hasn’t answered yet; it may be waking up. "
            + "Run this again in a moment to hear the result. It won’t be sent twice."
    }

    /// Finding the car or checking what it allows took longer than the
    /// intent may run. Only reads had been made.
    static func preparationTimedOut(vehicleName name: String?) -> VoltaIntentError {
        VoltaIntentError(kind: .serverUnreachable,
            message: "Your Volta server didn’t answer in time, so nothing was sent\(name.map { " to \($0)" } ?? ""). Try again in a moment.")
    }

    /// The request went out and no answer came back.
    static func unknownDialog(_ action: VehicleIntentAction, vehicleName name: String) -> String {
        let check = action.command.replaysUnattended
            ? "If you run another command in the next ten minutes, Volta checks this one with the server first, without sending it twice; after that, check it in Volta’s Controls."
            : "Open Volta’s Controls to check it before sending another command."
        return "Volta couldn’t confirm whether \(name) received the request to \(action.verbPhrase). \(check)"
    }

    /// The earlier request was this same command, and the car accepted it.
    static func alreadyDoneDialog(phrase: String, vehicleName name: String) -> String {
        "\(name) accepted your earlier request to \(phrase), so Volta didn’t send it again."
    }

    /// What became of an earlier request, said before the next answer; nil
    /// while it is unknown (it is checked again instead).
    static func earlierReport(_ outcome: VehicleCommandCoordinator.Outcome, phrase: String, vehicleName name: String,
                              detail: String?) -> String? {
        switch outcome {
        case .succeeded(let simulated):
            simulated ? "Demo mode simulated your earlier request to \(phrase)." : "\(name) accepted your earlier request to \(phrase)."
        case .failed:
            "Your earlier request to \(phrase) didn’t go through: \(detail ?? "Volta couldn’t send it.")"
        case .unknown:
            nil
        }
    }

    /// A replay of a lost result came back without an answer either.
    static func stillUnresolvedDialog(phrase: String, detail: String?) -> String {
        let prefix = "The saved request still has no confirmed result. "
        let reason = detail.map { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : $0 }
        return ["Your earlier request to \(phrase) still has no confirmed result, so nothing new was sent.", reason]
            .compactMap { $0 }.joined(separator: " ")
    }

    /// "turn on climate" for a saved command, from the intent wording when
    /// one matches, otherwise its Controls label.
    static func requestPhrase(_ command: VehicleCommand, label: String) -> String {
        VehicleIntentAction.allCases.first { $0.command == command }?.verbPhrase ?? label.lowercased()
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

/// One command or replay an intent started. It runs to its answer even if
/// every intent waiting for it is cancelled or gives up.
@MainActor
final class IntentCommandSend {
    let command: VehicleCommand
    let phrase: String
    /// Lets the intent that started it take the request back until it starts.
    let startGate = CommandStartGate()
    private(set) var outcome: VehicleCommandCoordinator.Outcome?
    private(set) var message: String?
    /// This request's own activity when the answer arrived; nil when another
    /// command had already replaced it.
    private(set) var activity: VehicleCommandCoordinator.Activity?
    private var waiters: [UUID: CheckedContinuation<VehicleCommandCoordinator.Outcome?, Never>] = [:]

    init(command: VehicleCommand, phrase: String) {
        self.command = command
        self.phrase = phrase
    }

    /// Records the answer; true when an intent was still waiting to hear it.
    @discardableResult
    func finish(_ outcome: VehicleCommandCoordinator.Outcome, message: String?,
                activity: VehicleCommandCoordinator.Activity? = nil) -> Bool {
        self.outcome = outcome
        self.message = message
        self.activity = activity
        let waiting = waiters
        waiters = [:]
        for waiter in waiting.values { waiter.resume(returning: outcome) }
        return !waiting.isEmpty
    }

    /// The answer, or nil when `deadline` passes or the waiting task is cancelled first.
    func wait(until deadline: ContinuousClock.Instant) async -> VehicleCommandCoordinator.Outcome? {
        if let outcome { return outcome }
        let id = UUID()
        let timer = Task { [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            self?.stopWaiting(id)
        }
        defer { timer.cancel() }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if let outcome { continuation.resume(returning: outcome) }
                else if Task.isCancelled { continuation.resume(returning: nil) }
                else { waiters[id] = continuation }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.stopWaiting(id) }
        }
    }

    private func stopWaiting(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(returning: nil)
    }
}

/// One read raced against a deadline; whichever ends first answers.
@MainActor
private final class PreparationRace<T: Sendable> {
    private var continuation: CheckedContinuation<T?, any Error>?
    private var timer: Task<Void, Never>?

    func run(until deadline: ContinuousClock.Instant,
             _ operation: @escaping @MainActor () async throws -> T) async throws -> T? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                Task { @MainActor in
                    do { self.finish(.success(try await operation())) }
                    catch { self.finish(.failure(error)) }
                }
                timer = Task { @MainActor in
                    try? await Task.sleep(until: deadline, clock: .continuous)
                    self.finish(.success(nil))
                }
            }
        } onCancel: {
            Task { @MainActor in self.finish(.failure(CancellationError())) }
        }
    }

    private func finish(_ result: Result<T?, any Error>) {
        timer?.cancel()
        guard let continuation else { return }
        self.continuation = nil
        continuation.resume(with: result)
    }
}

/// Keeps the app running in the background until a command's answer
/// arrives, after the intent that sent it has already returned.
@MainActor
enum BackgroundTime {
    static func hold(_ name: String) -> @MainActor () -> Void {
        let task = Holder()
        task.id = UIApplication.shared.beginBackgroundTask(withName: name) { task.end() }
        return { task.end() }
    }

    private final class Holder {
        var id = UIBackgroundTaskIdentifier.invalid
        func end() {
            guard id != .invalid else { return }
            UIApplication.shared.endBackgroundTask(id)
            id = .invalid
        }
    }
}

extension VoltaIntentError {
    /// The same failure, after what the person needs to hear first.
    func prefixed(_ preface: String) -> VoltaIntentError {
        preface.isEmpty ? self : VoltaIntentError(kind: kind, message: preface + message)
    }
}
