import AppIntents
import Foundation
import os

// Compiled into BOTH the app and the widget extension: Control Center and Lock
// Screen controls need these types to exist in the extension, but the work
// must happen in the app.
//
// Credentials stay in the app. The device token is a WhenUnlockedThisDeviceOnly
// Keychain item without an access group, so only the app process can read it.
// The control intents therefore:
// - conform to `LiveActivityIntent`, which the system performs in the app's
//   process, launching it in the background if needed (vehicle commands also
//   drive the charging Live Activity);
// - when built with Xcode 27 (Swift 6.4, iOS 27 SDK), which has
//   `IntentExecutionTargets`, also declare `allowedExecutionTargets = .main`
//   for iOS 27 devices (see the end of this file); older toolchains rely on
//   the other two;
// - forward to `VoltaIntentHost.performer`, which only the app registers. If
//   one ever runs in the extension anyway, it fails with a clear message and
//   sends nothing.

/// The vehicle commands Siri, Shortcuts and controls can send.
enum VehicleIntentAction: String, Codable, CaseIterable, Sendable {
    case lock, unlock
    case climateOn, climateOff
    case chargeStart, chargeStop
    case openChargePort, closeChargePort
    case sentryOn, sentryOff
    case flashLights, honk
    case openFrunk, openTrunk

    /// Actions that must not run from a locked device.
    var requiresAuthentication: Bool {
        switch self {
        case .unlock, .openFrunk, .openTrunk, .sentryOff: true
        default: false
        }
    }

    /// Actions Siri and Shortcuts send only after the person confirms, so an
    /// unattended automation can't run them. The single list: the action
    /// runner asks whenever this is true, and the command service refuses
    /// these actions without a confirmation step. A device unlock is not
    /// consent; every authenticated action must also be listed here.
    var requiresConfirmation: Bool {
        switch self {
        case .unlock, .openFrunk, .openTrunk, .sentryOff: true
        default: false
        }
    }

    /// "lock", "turn on climate": the phrase after "couldn't" / "Volta will".
    var verbPhrase: String {
        switch self {
        case .lock: "lock"
        case .unlock: "unlock"
        case .climateOn: "turn on climate"
        case .climateOff: "turn off climate"
        case .chargeStart: "start charging"
        case .chargeStop: "stop charging"
        case .openChargePort: "open the charge port"
        case .closeChargePort: "close the charge port"
        case .sentryOn: "turn on Sentry Mode"
        case .sentryOff: "turn off Sentry Mode"
        case .flashLights: "flash the lights"
        case .honk: "honk the horn"
        case .openFrunk: "open the frunk"
        case .openTrunk: "open the trunk"
        }
    }

    /// The label the command coordinator records ("Lock", "Start climate").
    var label: String {
        switch self {
        case .lock: "Lock"
        case .unlock: "Unlock"
        case .climateOn: "Start climate"
        case .climateOff: "Stop climate"
        case .chargeStart: "Start charging"
        case .chargeStop: "Stop charging"
        case .openChargePort: "Open charge port"
        case .closeChargePort: "Close charge port"
        case .sentryOn: "Arm Sentry"
        case .sentryOff: "Disarm Sentry"
        case .flashLights: "Flash lights"
        case .honk: "Honk horn"
        case .openFrunk: "Open frunk"
        case .openTrunk: "Open trunk"
        }
    }
}

/// A failure Siri speaks and Shortcuts shows. Messages are chosen by the
/// client; server text is never repeated.
struct VoltaIntentError: Error, Equatable, CustomLocalizedStringResourceConvertible {
    enum Kind: Equatable, Sendable {
        case notSignedIn, deviceLocked, noReading
        case commandsDisabled, teslaNotLinked, teslaConsentNeeded, vehicleNotConfigured
        case notAllowed, serverUnreachable, unresolvedCommand, busy, storageUnavailable
        case commandFailed, outcomeUnknown, needsApp
        case confirmationRequired, connectionChanged
    }

    var kind: Kind
    var message: String

    var localizedStringResource: LocalizedStringResource { "\(message)" }

    static let notSignedIn = VoltaIntentError(kind: .notSignedIn,
        message: "Volta isn’t connected to your server. Open Volta to sign in.")
    static let deviceLocked = VoltaIntentError(kind: .deviceLocked,
        message: "Unlock your iPhone, then try again.")
    static let noReading = VoltaIntentError(kind: .noReading, message: VehicleReadoutUnknown.noReadingDialog)
    static let needsApp = VoltaIntentError(kind: .needsApp,
        message: "Open Volta to send vehicle commands. Nothing was sent.")
    static let confirmationRequired = VoltaIntentError(kind: .confirmationRequired,
        message: "This command needs your confirmation, so nothing was sent.")
    static let connectionChanged = VoltaIntentError(kind: .connectionChanged,
        message: "Volta’s connection changed while this command was being prepared, so nothing was sent. Try again.")
}

/// What Siri asks before sending an action that requires confirmation.
struct VehicleIntentConfirmation: Equatable, Sendable {
    enum Verb: Equatable, Sendable { case `continue`, open, turnOff }
    var action: VehicleIntentAction
    var verb: Verb
    var prompt: String

    /// The prompt for every action that requires confirmation; nil otherwise.
    init?(_ action: VehicleIntentAction, vehicleName name: String) {
        guard action.requiresConfirmation else { return nil }
        self.action = action
        switch action {
        case .unlock:
            (verb, prompt) = (.continue, "Unlock \(name)? This unlocks all doors remotely.")
        case .openFrunk:
            (verb, prompt) = (.open, "Open the frunk on \(name)? It can only be closed by hand, so make sure nothing is above it.")
        case .openTrunk:
            (verb, prompt) = (.open, "Open the trunk on \(name)? Check clearance first.")
        case .sentryOff:
            (verb, prompt) = (.turnOff, "Turn off Sentry Mode on \(name)? It stops watching and recording around the car.")
        default:
            return nil
        }
    }

    var actionName: ConfirmationActionName {
        switch verb {
        case .continue: .continue
        case .open: .open
        case .turnOff: .turnOff
        }
    }
}

/// Implemented by the app; performs one command for the selected vehicle and
/// returns the sentence to speak. `confirm` runs after every check passes and
/// before anything is sent; it receives the vehicle name and throws to cancel.
/// Actions that require confirmation are refused when it is nil.
@MainActor
protocol VehicleIntentPerforming: AnyObject {
    func perform(_ action: VehicleIntentAction,
                 confirm: (@MainActor (String) async throws -> Void)?) async throws -> String
    /// Shows Volta's Controls screen the next time the app is in front.
    func showControls()
}

/// Where shared intents find the app's command path. Only the app sets it.
@MainActor
enum VoltaIntentHost {
    static var performer: (any VehicleIntentPerforming)?
    /// Action names and the process only; never vehicle data or credentials.
    static let log = Logger(subsystem: "com.georgenijo.volta", category: "intents")

    /// Shows the system confirmation for `intent`; throws when the person
    /// cancels or the system can't ask. Tests substitute it.
    static var requestConfirmation: @MainActor (any AppIntent, VehicleIntentConfirmation) async throws -> Void = { intent, confirmation in
        try await intent.requestConfirmation(actionName: confirmation.actionName,
                                             dialog: IntentDialog("\(confirmation.prompt)"))
    }

    /// The confirmation step for `action`, from the one table
    /// (`requiresConfirmation`); nil for actions that send without asking.
    /// Every route (Siri, Shortcuts, controls) gets its step here.
    static func confirmStep(_ action: VehicleIntentAction,
                            for intent: some AppIntent) -> (@MainActor (String) async throws -> Void)? {
        guard action.requiresConfirmation else { return nil }
        return { name in
            guard let confirmation = VehicleIntentConfirmation(action, vehicleName: name) else {
                throw VoltaIntentError.confirmationRequired
            }
            do { try await requestConfirmation(intent, confirmation) }
            catch {
                log.info("Confirmation for \(action.rawValue, privacy: .public) ended: \(String(describing: type(of: error)), privacy: .public)")
                throw error
            }
        }
    }

    /// Brings Volta to the front for `intent`. Tests substitute it.
    static var continueInApp: @MainActor (any AppIntent) async throws -> Void = { intent in
        try await intent.continueInForeground(nil, alwaysConfirm: false)
    }

    /// What a control does when tapped. Controls can't ask for confirmation
    /// (the system cancels the request without showing it), so an action
    /// that requires one is never sent from a control: the tap opens Volta's
    /// Controls screen instead, where the person confirms it.
    static func performControl(_ action: VehicleIntentAction, for intent: some AppIntent) async throws {
        let process = ProcessInfo.processInfo.processName
        guard let performer else {
            log.error("Control action \(action.rawValue, privacy: .public) reached \(process, privacy: .public) without the app; nothing sent")
            throw VoltaIntentError.needsApp
        }
        if action.requiresConfirmation {
            log.info("Control action \(action.rawValue, privacy: .public) needs confirmation; opening Volta, nothing sent")
            performer.showControls()
            try await continueInApp(intent)
            return
        }
        log.info("Control action \(action.rawValue, privacy: .public) running in \(process, privacy: .public)")
        _ = try await performer.perform(action, confirm: nil)
    }
}

// MARK: - Control intents

/// Lock toggle. Locking is immediate. Unlocking needs confirmation, which a
/// control can't show, so turning it off sends nothing and opens Volta's
/// Controls screen. It still requires an unlocked device as a whole.
struct SetVehicleLockIntent: SetValueIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Set Car Lock"
    static let description = IntentDescription("Locks your car, or opens Volta to unlock it, from Control Center or the Lock Screen.")
    static let isDiscoverable = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    /// Runs in the background; comes to the front only to unlock in the app.
    static let supportedModes: IntentModes = [.background, .foreground(.dynamic)]

    @Parameter(title: "Locked")
    var value: Bool

    init() {}
    init(value: Bool) { self.value = value }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await VoltaIntentHost.performControl(value ? .lock : .unlock, for: self)
        return .result()
    }
}

/// Climate toggle.
struct SetVehicleClimateIntent: SetValueIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Set Car Climate"
    static let description = IntentDescription("Turns your car’s climate on or off from Control Center or the Lock Screen.")
    static let isDiscoverable = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Parameter(title: "Climate On")
    var value: Bool

    init() {}
    init(value: Bool) { self.value = value }

    @MainActor
    func perform() async throws -> some IntentResult {
        try await VoltaIntentHost.performControl(value ? .climateOn : .climateOff, for: self)
        return .result()
    }
}

/// Charge port button: opens the charge port door.
struct OpenChargePortControlIntent: AppIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Open Car Charge Port"
    static let description = IntentDescription("Opens your car’s charge port door from Control Center or the Lock Screen.")
    static let isDiscoverable = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        try await VoltaIntentHost.performControl(.openChargePort, for: self)
        return .result()
    }
}

/// Battery control: opens Volta. Sends nothing to the car.
struct OpenVoltaIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Volta"
    static let description = IntentDescription("Opens Volta to your car’s dashboard.")
    static let isDiscoverable = false
    static let supportedModes: IntentModes = .foreground(.immediate)

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult { .result() }
}

// MARK: - Execution target (newer SDKs only)

// `IntentExecutionTargets` first ships in the iOS 27 SDK, which comes with
// Xcode 27 and Swift 6.4. Xcode 26.x (Swift 6.2/6.3, iOS 26.x SDK) doesn't
// declare the type. Swift can't test for a type, and the AppIntents module
// version doesn't separate the two (the iOS 26.5 SDK's is already 300+), so
// the compiler version that ships with the SDK is the gate. Without these
// declarations the control intents still run in the app process through
// `LiveActivityIntent`, and the extension still sends nothing.
#if compiler(>=6.4)
extension VoltaIntentHost {
    /// True when this build tells the system to run control intents in the app only.
    static let declaresAppOnlyExecution = true
}

extension SetVehicleLockIntent {
    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
}

extension SetVehicleClimateIntent {
    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
}

extension OpenChargePortControlIntent {
    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }
}
#else
extension VoltaIntentHost {
    /// False: this toolchain's SDK has no execution targets; `LiveActivityIntent` alone
    /// places control intents in the app process.
    static let declaresAppOnlyExecution = false
}
#endif
