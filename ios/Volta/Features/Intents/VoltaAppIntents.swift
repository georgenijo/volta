import AppIntents
import SwiftUI

// Siri and Shortcuts actions. These live in the app target only, so the
// system performs them in the app process, where the device token is.

// MARK: - Read intents

/// Shared body of the read intents: answer from the cached reading.
@MainActor
enum VehicleReadAnswer {
    static func reading() async throws -> (VehicleReadout, Bool) {
        let reading = try await VehicleIntentService.shared.reading()
        return (VehicleReadout(reading.snapshot), reading.isDemo)
    }

    /// The spoken answer. Demo answers say they are demo data.
    static func dialog(_ kind: VehicleIntentSnippet.Kind, readout: VehicleReadout, isDemo: Bool) -> String {
        let text = switch kind {
        case .battery: readout.batteryDialog
        case .range: readout.rangeDialog
        case .charging: readout.chargingDialog
        case .location: readout.locationDialog
        case .security: readout.securityDialog
        }
        return isDemo ? "\(text) This is demo data." : text
    }

    static func answer(_ kind: VehicleIntentSnippet.Kind) async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        let (readout, isDemo) = try await reading()
        let text = dialog(kind, readout: readout, isDemo: isDemo)
        return .result(dialog: IntentDialog("\(text)"),
                       view: VehicleIntentSnippet(kind: kind, readout: readout, isDemo: isDemo))
    }
}

struct CheckBatteryIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Battery"
    static let description = IntentDescription(
        "Tells you your car’s battery level and range from Volta’s latest reading, and how old that reading is. Returns the battery percentage.",
        categoryName: "Status")
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog & ShowsSnippetView {
        let (readout, isDemo) = try await VehicleReadAnswer.reading()
        let text = VehicleReadAnswer.dialog(.battery, readout: readout, isDemo: isDemo)
        return .result(value: readout.snapshot.batteryLevel, dialog: IntentDialog("\(text)"),
                       view: VehicleIntentSnippet(kind: .battery, readout: readout, isDemo: isDemo))
    }
}

struct CheckRangeIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Range"
    static let description = IntentDescription(
        "Tells you your car’s estimated range from Volta’s latest reading.", categoryName: "Status")
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        try await VehicleReadAnswer.answer(.range)
    }
}

struct CheckChargingIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Charging"
    static let description = IntentDescription(
        "Tells you whether your car is charging and, when known, how long until it reaches its limit.",
        categoryName: "Status")
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        try await VehicleReadAnswer.answer(.charging)
    }
}

/// Location is personal, so it needs an unlocked device.
struct LocateVehicleIntent: AppIntent {
    static let title: LocalizedStringResource = "Where’s My Car"
    static let description = IntentDescription(
        "Tells you the place name Volta last recorded for your car. Volta never shares coordinates.",
        categoryName: "Status")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        try await VehicleReadAnswer.answer(.location)
    }
}

struct CheckSecurityIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Locks and Sentry"
    static let description = IntentDescription(
        "Tells you whether your car is locked and whether Sentry Mode is on.", categoryName: "Status")
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ShowsSnippetView {
        try await VehicleReadAnswer.answer(.security)
    }
}

// MARK: - Action intents

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

/// Runs every Siri and Shortcuts command. Whether to ask first comes from
/// `VehicleIntentAction.requiresConfirmation`, never from the intent, so an
/// intent can't forget to ask.
@MainActor
enum VehicleActionRunner {
    /// The command service. Tests substitute one with a stubbed server.
    static var service: @MainActor () -> VehicleIntentService = { .shared }
    /// Shows the system confirmation for `intent`; throws when the person
    /// cancels. Tests substitute it, since the system prompt needs Siri.
    static var requestConfirmation: @MainActor (any AppIntent, VehicleIntentConfirmation) async throws -> Void = { intent, confirmation in
        try await intent.requestConfirmation(actionName: confirmation.actionName,
                                             dialog: IntentDialog("\(confirmation.prompt)"))
    }

    static func run<Intent: AppIntent>(_ action: VehicleIntentAction,
                                       for intent: Intent) async throws -> some IntentResult & ProvidesDialog {
        let text: String
        if action.requiresConfirmation {
            text = try await service().perform(action) { name in
                guard let confirmation = VehicleIntentConfirmation(action, vehicleName: name) else {
                    throw VoltaIntentError.confirmationRequired
                }
                try await requestConfirmation(intent, confirmation)
            }
        } else {
            text = try await service().perform(action, confirm: nil)
        }
        return .result(dialog: IntentDialog("\(text)"))
    }
}

struct LockVehicleIntent: AppIntent {
    static let title: LocalizedStringResource = "Lock Car"
    static let description = IntentDescription("Locks your car.", categoryName: "Controls")
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await VehicleActionRunner.run(.lock, for: self)
    }
}

struct UnlockVehicleIntent: AppIntent {
    static let title: LocalizedStringResource = "Unlock Car"
    static let description = IntentDescription(
        "Unlocks your car. Requires Face ID or your passcode, and asks you to confirm.", categoryName: "Controls")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await VehicleActionRunner.run(.unlock, for: self)
    }
}

enum ClimatePowerState: String, AppEnum {
    case on, off
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Climate"
    static let caseDisplayRepresentations: [ClimatePowerState: DisplayRepresentation] = [
        .on: DisplayRepresentation(title: "Climate On", synonyms: ["on climate", "on the climate", "on my car’s climate"]),
        .off: DisplayRepresentation(title: "Climate Off", synonyms: ["off climate", "off the climate", "off my car’s climate"]),
    ]
}

struct SetClimateIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn Climate On or Off"
    static let description = IntentDescription("Starts or stops your car’s climate.", categoryName: "Controls")
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Parameter(title: "Climate", default: .on)
    var state: ClimatePowerState

    static var parameterSummary: some ParameterSummary { Summary("Turn \(\.$state)") }

    init() {}
    init(state: ClimatePowerState) { self.state = state }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await VehicleActionRunner.run(state == .on ? .climateOn : .climateOff, for: self)
    }
}

enum ChargingCommand: String, AppEnum {
    case start, stop
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Charging"
    static let caseDisplayRepresentations: [ChargingCommand: DisplayRepresentation] = [
        .start: DisplayRepresentation(title: "Start", synonyms: ["Resume"]),
        .stop: DisplayRepresentation(title: "Stop", synonyms: ["Pause"]),
    ]
}

struct SetChargingIntent: AppIntent {
    static let title: LocalizedStringResource = "Start or Stop Charging"
    static let description = IntentDescription("Starts or stops charging when your car is plugged in.", categoryName: "Controls")
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Parameter(title: "Charging", default: .start)
    var command: ChargingCommand

    static var parameterSummary: some ParameterSummary { Summary("\(\.$command) charging") }

    init() {}
    init(command: ChargingCommand) { self.command = command }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await VehicleActionRunner.run(command == .start ? .chargeStart : .chargeStop, for: self)
    }
}

enum ChargePortCommand: String, AppEnum {
    case open, close
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Charge Port"
    static let caseDisplayRepresentations: [ChargePortCommand: DisplayRepresentation] = [
        .open: DisplayRepresentation(title: "Open Charge Port", synonyms: ["open the charge port", "open my charge port"]),
        .close: DisplayRepresentation(title: "Close Charge Port", synonyms: ["close the charge port", "close my charge port"]),
    ]
}

struct SetChargePortIntent: AppIntent {
    static let title: LocalizedStringResource = "Open or Close Charge Port"
    static let description = IntentDescription("Opens or closes your car’s charge port door.", categoryName: "Controls")
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Parameter(title: "Charge Port", default: .open)
    var command: ChargePortCommand

    static var parameterSummary: some ParameterSummary { Summary("\(\.$command)") }

    init() {}
    init(command: ChargePortCommand) { self.command = command }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await VehicleActionRunner.run(command == .open ? .openChargePort : .closeChargePort, for: self)
    }
}

struct ArmSentryIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn On Sentry Mode"
    static let description = IntentDescription("Turns on Sentry Mode.", categoryName: "Controls")
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await VehicleActionRunner.run(.sentryOn, for: self)
    }
}

struct DisarmSentryIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn Off Sentry Mode"
    static let description = IntentDescription(
        "Turns off Sentry Mode. Requires Face ID or your passcode, and asks you to confirm.", categoryName: "Controls")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await VehicleActionRunner.run(.sentryOff, for: self)
    }
}

struct FlashLightsIntent: AppIntent {
    static let title: LocalizedStringResource = "Flash Lights"
    static let description = IntentDescription("Flashes your car’s exterior lights.", categoryName: "Controls")
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await VehicleActionRunner.run(.flashLights, for: self)
    }
}

struct HonkHornIntent: AppIntent {
    static let title: LocalizedStringResource = "Honk Horn"
    static let description = IntentDescription("Sounds your car’s horn.", categoryName: "Controls")
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await VehicleActionRunner.run(.honk, for: self)
    }
}

struct OpenFrunkIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Frunk"
    static let description = IntentDescription(
        "Opens the front trunk. Requires Face ID or your passcode, and asks you to confirm.", categoryName: "Controls")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await VehicleActionRunner.run(.openFrunk, for: self)
    }
}

struct OpenTrunkIntent: AppIntent {
    static let title: LocalizedStringResource = "Open Trunk"
    static let description = IntentDescription(
        "Actuates the rear trunk. Requires Face ID or your passcode, and asks you to confirm.", categoryName: "Controls")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await VehicleActionRunner.run(.openTrunk, for: self)
    }
}
