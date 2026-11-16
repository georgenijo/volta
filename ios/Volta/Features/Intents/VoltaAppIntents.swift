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

@MainActor
enum VehicleActionRunner {
    static func run(_ action: VehicleIntentAction,
                    confirm: (@MainActor (String) async throws -> Void)? = nil) async throws -> some IntentResult & ProvidesDialog {
        let text = try await VehicleIntentService.shared.perform(action, confirm: confirm)
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
        try await VehicleActionRunner.run(.lock)
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
        try await VehicleActionRunner.run(.unlock) { name in
            try await requestConfirmation(actionName: .continue,
                dialog: IntentDialog("Unlock \(name)? This unlocks all doors remotely."))
        }
    }
}

enum ClimatePowerState: String, AppEnum {
    case on, off
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Climate"
    static let caseDisplayRepresentations: [ClimatePowerState: DisplayRepresentation] = [
        .on: DisplayRepresentation(title: "On", synonyms: ["Start"]),
        .off: DisplayRepresentation(title: "Off", synonyms: ["Stop"]),
    ]
}

struct SetClimateIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn Climate On or Off"
    static let description = IntentDescription("Starts or stops your car’s climate.", categoryName: "Controls")
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Parameter(title: "Climate", default: .on)
    var state: ClimatePowerState

    static var parameterSummary: some ParameterSummary { Summary("Turn climate \(\.$state)") }

    init() {}
    init(state: ClimatePowerState) { self.state = state }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await VehicleActionRunner.run(state == .on ? .climateOn : .climateOff)
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
        try await VehicleActionRunner.run(command == .start ? .chargeStart : .chargeStop)
    }
}

enum ChargePortCommand: String, AppEnum {
    case open, close
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Charge Port"
    static let caseDisplayRepresentations: [ChargePortCommand: DisplayRepresentation] = [
        .open: "Open",
        .close: DisplayRepresentation(title: "Close", synonyms: ["Shut"]),
    ]
}

struct SetChargePortIntent: AppIntent {
    static let title: LocalizedStringResource = "Open or Close Charge Port"
    static let description = IntentDescription("Opens or closes your car’s charge port door.", categoryName: "Controls")
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    @Parameter(title: "Charge Port", default: .open)
    var command: ChargePortCommand

    static var parameterSummary: some ParameterSummary { Summary("\(\.$command) the charge port") }

    init() {}
    init(command: ChargePortCommand) { self.command = command }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await VehicleActionRunner.run(command == .open ? .openChargePort : .closeChargePort)
    }
}

struct ArmSentryIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn On Sentry Mode"
    static let description = IntentDescription("Turns on Sentry Mode.", categoryName: "Controls")
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await VehicleActionRunner.run(.sentryOn)
    }
}

struct DisarmSentryIntent: AppIntent {
    static let title: LocalizedStringResource = "Turn Off Sentry Mode"
    static let description = IntentDescription(
        "Turns off Sentry Mode. Requires Face ID or your passcode.", categoryName: "Controls")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await VehicleActionRunner.run(.sentryOff)
    }
}

struct FlashLightsIntent: AppIntent {
    static let title: LocalizedStringResource = "Flash Lights"
    static let description = IntentDescription("Flashes your car’s exterior lights.", categoryName: "Controls")
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await VehicleActionRunner.run(.flashLights)
    }
}

struct HonkHornIntent: AppIntent {
    static let title: LocalizedStringResource = "Honk Horn"
    static let description = IntentDescription("Sounds your car’s horn.", categoryName: "Controls")
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    init() {}

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        try await VehicleActionRunner.run(.honk)
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
        try await VehicleActionRunner.run(.openFrunk) { name in
            try await requestConfirmation(actionName: .open,
                dialog: IntentDialog("Open the frunk on \(name)? It can only be closed by hand, so make sure nothing is above it."))
        }
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
        try await VehicleActionRunner.run(.openTrunk) { name in
            try await requestConfirmation(actionName: .open,
                dialog: IntentDialog("Open the trunk on \(name)? Check clearance first."))
        }
    }
}
