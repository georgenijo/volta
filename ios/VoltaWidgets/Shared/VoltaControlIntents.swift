import AppIntents
import Foundation

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
// - on iOS 27 and later also declare `allowedExecutionTargets = .main`;
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
}

/// Implemented by the app; performs one command for the selected vehicle and
/// returns the sentence to speak.
@MainActor
protocol VehicleIntentPerforming: AnyObject {
    func perform(_ action: VehicleIntentAction) async throws -> String
}

/// Where shared intents find the app's command path. Only the app sets it.
@MainActor
enum VoltaIntentHost {
    static var performer: (any VehicleIntentPerforming)?

    static func perform(_ action: VehicleIntentAction) async throws -> String {
        guard let performer else { throw VoltaIntentError.needsApp }
        return try await performer.perform(action)
    }
}

// MARK: - Control intents

/// Lock toggle. Unlocking can come from it, so the whole intent requires an
/// unlocked device; Lock Screen controls ask for Face ID or the passcode.
struct SetVehicleLockIntent: SetValueIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Set Car Lock"
    static let description = IntentDescription("Locks or unlocks your car from Control Center or the Lock Screen.")
    static let isDiscoverable = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @Parameter(title: "Locked")
    var value: Bool

    init() {}
    init(value: Bool) { self.value = value }

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = try await VoltaIntentHost.perform(value ? .lock : .unlock)
        return .result()
    }
}

/// Climate toggle.
struct SetVehicleClimateIntent: SetValueIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Set Car Climate"
    static let description = IntentDescription("Turns your car’s climate on or off from Control Center or the Lock Screen.")
    static let isDiscoverable = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    @Parameter(title: "Climate On")
    var value: Bool

    init() {}
    init(value: Bool) { self.value = value }

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = try await VoltaIntentHost.perform(value ? .climateOn : .climateOff)
        return .result()
    }
}

/// Charge port button: opens the charge port door.
struct OpenChargePortControlIntent: AppIntent, LiveActivityIntent {
    static let title: LocalizedStringResource = "Open Car Charge Port"
    static let description = IntentDescription("Opens your car’s charge port door from Control Center or the Lock Screen.")
    static let isDiscoverable = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed
    @available(iOS 27.0, *)
    static var allowedExecutionTargets: IntentExecutionTargets { .main }

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult {
        _ = try await VoltaIntentHost.perform(.openChargePort)
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
