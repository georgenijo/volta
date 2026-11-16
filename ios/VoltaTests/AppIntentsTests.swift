import AppIntents
import Synchronization
import XCTest
@testable import Volta

// MARK: - Fixtures

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func snapshot(_ edit: (inout WidgetSnapshot) -> Void = { _ in }) -> WidgetSnapshot {
    var value = WidgetSnapshot(
        vehicleId: 42, vehicleName: "Friday", state: .online,
        updatedAt: now.addingTimeInterval(-4 * 60), writtenAt: now,
        batteryLevel: 72, chargeLimit: 80, estRangeKm: 328, ratedRangeKm: 354,
        chargingState: .disconnected, chargerPowerKw: nil, minutesToFull: nil,
        insideTempC: 21, outsideTempC: 16, climateOn: false, locked: true, sentryMode: true,
        placeName: "Home", today: nil, timeline: [],
        savedPlace: .init(name: "Home", recordedAt: now.addingTimeInterval(-4 * 60)))
    edit(&value)
    return value
}

private func readout(_ edit: (inout WidgetSnapshot) -> Void = { _ in }) -> VehicleReadout {
    VehicleReadout(snapshot(edit), now: now)
}

// MARK: - Spoken answers and control values

final class VehicleReadoutTests: XCTestCase {
    func testBatteryAnswerIncludesRangeUnitAndAge() {
        XCTAssertEqual(readout().batteryDialog,
                       "Friday is at 72% with about 204 miles of estimated range. Updated 4 minutes ago.")
        XCTAssertEqual(readout { $0.distanceUnit = .kilometers }.batteryDialog,
                       "Friday is at 72% with about 328 kilometers of estimated range. Updated 4 minutes ago.")
    }

    func testRangeFallsBackToRatedAndSaysUnknownWhenMissing() {
        XCTAssertEqual(readout { $0.estRangeKm = nil }.rangeDialog,
                       "Friday has about 220 miles of rated range, with the battery at 72%. Updated 4 minutes ago.")
        let unknown = readout { $0.estRangeKm = nil; $0.ratedRangeKm = nil }
        XCTAssertEqual(unknown.rangeDialog, "Friday’s range is unknown. The battery is at 72%. Updated 4 minutes ago.")
        XCTAssertEqual(unknown.batteryDialog, "Friday is at 72%. Range is unknown. Updated 4 minutes ago.")
        XCTAssertNil(unknown.shortRange)
        XCTAssertEqual(unknown.batteryText, "72%", "unknown range is omitted, never shown as 0")
        XCTAssertFalse(unknown.rangeDialog.contains(" 0 "))
    }

    func testChargingAnswerWithAndWithoutTimeRemaining() {
        let charging = readout { $0.chargingState = .charging; $0.chargerPowerKw = 7.7; $0.minutesToFull = 65 }
        XCTAssertEqual(charging.chargingDialog,
                       "Friday is charging at 7.7 kilowatts, now at 72%. About 1 hour, 5 minutes left to reach 80%. Updated 4 minutes ago.")
        XCTAssertEqual(charging.chargingText, "1h 5m left")

        let noTime = readout { $0.chargingState = .charging; $0.chargerPowerKw = nil; $0.minutesToFull = nil }
        XCTAssertEqual(noTime.chargingDialog,
                       "Friday is charging, now at 72%. Time remaining is unknown. Updated 4 minutes ago.")
        XCTAssertEqual(noTime.chargingText, "Charging")

        let noLimit = readout { $0.chargingState = .charging; $0.chargeLimit = nil; $0.minutesToFull = 20 }
        XCTAssertTrue(noLimit.chargingDialog.contains("About 20 minutes left."))
    }

    func testChargingStatesAndUnknown() {
        XCTAssertTrue(readout { $0.chargingState = .complete }.chargingDialog.hasPrefix("Friday has finished charging, at 72%."))
        XCTAssertTrue(readout { $0.chargingState = .stopped }.chargingDialog.hasPrefix("Friday is plugged in but not charging"))
        XCTAssertTrue(readout().chargingDialog.hasPrefix("Friday isn’t plugged in."))
        let unknown = readout { $0.chargingState = nil }
        XCTAssertEqual(unknown.charging, .unknown)
        XCTAssertTrue(unknown.chargingDialog.hasPrefix("Friday’s charging state is unknown."))
        XCTAssertEqual(unknown.chargingText, "Unknown")
        XCTAssertEqual(readout { $0.chargingState = nil; $0.state = .charging }.charging, .charging)
    }

    func testLocationIsSavedPlaceNameOnlyNeverCoordinates() {
        XCTAssertEqual(readout().locationDialog, "Friday is at Home. Located 4 minutes ago.")
        XCTAssertEqual(readout { $0.savedPlace = nil }.locationDialog, "Friday’s location is unknown.")
        XCTAssertNil(readout { $0.savedPlace?.name = "  " }.place)
        XCTAssertEqual(readout { $0.savedPlace?.name = nil }.locationDialog,
                       "Friday isn’t at a saved place. Located 4 minutes ago.")
        XCTAssertEqual(readout { $0.state = .driving }.locationDialog,
                       "Friday is driving. It was last at Home. Located 4 minutes ago.")
        XCTAssertEqual(readout { $0.state = .driving; $0.savedPlace = nil }.locationDialog,
                       "Friday is driving. Its location is unknown.")
        XCTAssertEqual(readout { $0.state = .driving; $0.savedPlace?.name = nil }.locationDialog,
                       "Friday is driving, away from your saved places. Located 4 minutes ago.")
        // Widgets' placeName is never read for speech.
        XCTAssertEqual(readout { $0.placeName = "Elsewhere" }.locationDialog, "Friday is at Home. Located 4 minutes ago.")
        let spoken = readout { $0.savedPlace = nil }.locationDialog
        XCTAssertNil(spoken.range(of: #"\d+\.\d+"#, options: .regularExpression))
        XCTAssertEqual(readout().locationTitle, "Home")
        XCTAssertEqual(readout { $0.savedPlace?.name = nil }.locationTitle, "Not at a saved place")
        XCTAssertEqual(readout { $0.savedPlace = nil }.locationTitle, "Unknown")
    }

    /// Battery and charging updates advance `updatedAt` while the position
    /// stays old; the location answer uses the position's own time.
    func testLocationAgeComesFromThePositionNotTheStatus() {
        let old = readout {
            $0.updatedAt = now.addingTimeInterval(-20)
            $0.savedPlace = .init(name: "Home", recordedAt: now.addingTimeInterval(-26 * 3600))
        }
        XCTAssertEqual(old.ageSentence, "Updated just now.", "the status itself is fresh")
        XCTAssertEqual(old.locationDialog, "Friday is at Home. This location is from 1 day ago, so it may be out of date.")
        XCTAssertFalse(old.locationDialog.contains("just now"))
        XCTAssertTrue(old.locationIsStale)
        XCTAssertEqual(VehicleIntentSnippet.footerText(.location, readout: old), "Located 1 day ago · may be out of date")
        XCTAssertEqual(VehicleIntentSnippet.footerText(.battery, readout: old), "Updated just now")

        let undated = readout { $0.updatedAt = now; $0.savedPlace?.recordedAt = nil }
        XCTAssertEqual(undated.locationDialog, "Friday is at Home. The location’s age is unknown.")
        XCTAssertEqual(VehicleIntentSnippet.footerText(.location, readout: undated), "Location age unknown")
        XCTAssertEqual(VehicleIntentSnippet.footerText(.location, readout: readout { $0.savedPlace = nil }), "Location unknown")
    }

    /// From the bridge to the answer: away from a saved place the status
    /// carries only a street address, which widgets show but Siri never says.
    func testAnAddressFromTheServerIsNeverSpokenOrShown() throws {
        let address = "1 Example Street"
        let status = VehicleStatus(
            vehicleId: 42, state: .online, updatedAt: now, batteryLevel: 72, usableBatteryLevel: nil,
            ratedRangeKm: nil, estRangeKm: 328, chargeLimit: 80, chargingState: .disconnected, chargerPowerKw: nil,
            minutesToFull: nil, insideTempC: nil, outsideTempC: nil, climateOn: nil, driverTempSettingC: nil,
            locked: true, sentryMode: true, odometerKm: nil,
            location: Location(latitude: 37.4419, longitude: -122.1430, heading: 90, address: address, placeName: nil),
            locationUpdatedAt: now.addingTimeInterval(-2 * 60), firmware: nil)
        let bridged = WidgetSnapshot(status: status, vehicleName: "Friday", summary: nil, timeline: nil, now: now)
        XCTAssertEqual(bridged.placeName, address, "widgets still show the address, as before")
        XCTAssertEqual(bridged.savedPlace, .init(name: nil, recordedAt: now.addingTimeInterval(-2 * 60)))

        let answer = VehicleReadout(bridged, now: now)
        XCTAssertEqual(answer.locationDialog, "Friday isn’t at a saved place. Located 2 minutes ago.")
        let texts = [answer.locationDialog, answer.locationTitle, VehicleIntentSnippet.footerText(.location, readout: answer),
                     answer.name, answer.place ?? ""]
        for text in texts {
            for part in address.split(separator: " ") {
                XCTAssertFalse(text.contains(part), "\(text) contains \(part)")
            }
            XCTAssertFalse(text.contains("37.44"))
            XCTAssertFalse(text.contains("122.14"))
        }
    }

    /// Snapshots written before `savedPlace` existed may hold an address in
    /// `placeName`; they are never trusted for speech.
    func testSnapshotsFromEarlierBuildsAreNotSpoken() throws {
        let legacy = snapshot { $0.placeName = "1 Example Street"; $0.savedPlace = nil }
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(legacy)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(fields["savedPlace"], "an earlier build's file has no savedPlace key")
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(WidgetSnapshot.self, from: data)
        XCTAssertEqual(decoded.placeName, "1 Example Street")
        let answer = VehicleReadout(decoded, now: now)
        XCTAssertEqual(answer.locationDialog, "Friday’s location is unknown.")
        XCTAssertEqual(answer.locationTitle, "Unknown")
    }

    func testSecurityAnswerCoversUnknowns() {
        XCTAssertEqual(readout().securityDialog, "Friday is locked, and Sentry Mode is on. Updated 4 minutes ago.")
        XCTAssertEqual(readout { $0.locked = false; $0.sentryMode = false }.securityDialog,
                       "Friday is unlocked, and Sentry Mode is off. Updated 4 minutes ago.")
        XCTAssertEqual(readout { $0.locked = nil; $0.sentryMode = nil }.securityDialog,
                       "Friday’s lock state is unknown, and Sentry Mode is unknown. Updated 4 minutes ago.")
        XCTAssertEqual(readout { $0.locked = nil }.lockText, "Unknown")
        XCTAssertEqual(readout { $0.climateOn = nil }.climateText, "Unknown")
    }

    func testAgeIsAlwaysStatedAndStaleReadingsSaySo() {
        XCTAssertEqual(readout { $0.updatedAt = now.addingTimeInterval(-20) }.ageSentence, "Updated just now.")
        let stale = readout { $0.updatedAt = now.addingTimeInterval(-3 * 3600) }
        XCTAssertTrue(stale.isStale)
        XCTAssertEqual(stale.ageSentence, "This reading is from 3 hours ago, so it may be out of date.")
        XCTAssertTrue(stale.batteryDialog.hasSuffix("This reading is from 3 hours ago, so it may be out of date."))
        XCTAssertEqual(stale.controlValue("Locked"), "Locked · 3h")
        XCTAssertEqual(readout().controlValue("Locked"), "Locked", "fresh control values carry no age")
        // A reading time in the future (clock skew) is "just now", not negative.
        XCTAssertEqual(readout { $0.updatedAt = now.addingTimeInterval(120) }.age, "just now")
    }

    func testToggleLabelsShowPendingRequestsAndUnknown() {
        let fresh = readout()
        XCTAssertEqual(VehicleToggleLabel.lock(observed: nil, isOn: false, readout: nil),
                       .init(text: "Unknown", symbol: "lock"))
        XCTAssertEqual(VehicleToggleLabel.lock(observed: nil, isOn: true, readout: nil).text, "Locking…",
                       "a tap on an unknown lock shows the request, not a state")
        // Unlocking happens in the app, so the locked state says where.
        XCTAssertEqual(VehicleToggleLabel.lock(observed: true, isOn: true, readout: fresh),
                       .init(text: "Unlock in Volta", symbol: "lock.fill", title: "Car Locked"))
        XCTAssertEqual(VehicleToggleLabel.lock(observed: true, isOn: false, readout: fresh).text, "Opening Volta…",
                       "turning the toggle off never claims the car is unlocking")
        XCTAssertEqual(VehicleToggleLabel.lock(observed: false, isOn: false, readout: fresh).text, "Unlocked")
        let stale = readout { $0.updatedAt = now.addingTimeInterval(-2 * 3600) }
        XCTAssertEqual(VehicleToggleLabel.lock(observed: true, isOn: true, readout: stale).title, "Car Locked · 2h")
        XCTAssertEqual(VehicleToggleLabel.climate(observed: nil, isOn: false, readout: nil),
                       .init(text: "Unknown", symbol: "fan"))
        XCTAssertEqual(VehicleToggleLabel.climate(observed: false, isOn: true, readout: fresh).text, "Turning On…")
        XCTAssertEqual(VehicleToggleLabel.climate(observed: true, isOn: true, readout: fresh).text, "On")
    }

    func testVehicleNameFallbackAndPossessive() {
        XCTAssertTrue(readout { $0.vehicleName = " " }.batteryDialog.hasPrefix("Your car is at 72%"))
        XCTAssertTrue(readout { $0.vehicleName = "Atlas"; $0.savedPlace = nil }.locationDialog.hasPrefix("Atlas’ location"))
    }

    @MainActor
    func testDemoAnswersSayTheyAreDemoData() {
        let text = VehicleReadAnswer.dialog(.battery, readout: readout(), isDemo: true)
        XCTAssertTrue(text.hasSuffix("This is demo data."))
        XCTAssertFalse(VehicleReadAnswer.dialog(.battery, readout: readout(), isDemo: false).contains("demo"))
    }
}

// MARK: - Authentication policy

final class IntentAuthenticationPolicyTests: XCTestCase {
    func testSensitiveIntentsRequireAnUnlockedDevice() {
        XCTAssertEqual(UnlockVehicleIntent.authenticationPolicy, .requiresAuthentication)
        XCTAssertEqual(OpenFrunkIntent.authenticationPolicy, .requiresAuthentication)
        XCTAssertEqual(OpenTrunkIntent.authenticationPolicy, .requiresAuthentication)
        XCTAssertEqual(DisarmSentryIntent.authenticationPolicy, .requiresAuthentication)
        // The lock control can unlock, so it is gated as a whole.
        XCTAssertEqual(SetVehicleLockIntent.authenticationPolicy, .requiresAuthentication)
        XCTAssertEqual(LocateVehicleIntent.authenticationPolicy, .requiresAuthentication, "location is personal")
    }

    func testRoutineIntentsRunFromTheLockScreen() {
        XCTAssertEqual(LockVehicleIntent.authenticationPolicy, .alwaysAllowed)
        XCTAssertEqual(SetClimateIntent.authenticationPolicy, .alwaysAllowed)
        XCTAssertEqual(SetVehicleClimateIntent.authenticationPolicy, .alwaysAllowed)
        XCTAssertEqual(OpenChargePortControlIntent.authenticationPolicy, .alwaysAllowed)
        XCTAssertEqual(ArmSentryIntent.authenticationPolicy, .alwaysAllowed)
        XCTAssertEqual(CheckBatteryIntent.authenticationPolicy, .alwaysAllowed)
    }

    func testActionFlagsMatchTheIntents() {
        XCTAssertEqual(Set(VehicleIntentAction.allCases.filter(\.requiresAuthentication)),
                       [.unlock, .openFrunk, .openTrunk, .sentryOff])
        XCTAssertEqual(Set(VehicleIntentAction.allCases.filter(\.requiresConfirmation)),
                       [.unlock, .openFrunk, .openTrunk, .sentryOff])
    }

    /// A device unlock is not consent: every sensitive action is also in the
    /// confirmation list and has a prompt; no other action has one.
    func testEverySensitiveActionAsksForConfirmation() {
        for action in VehicleIntentAction.allCases {
            if action.requiresAuthentication {
                XCTAssertTrue(action.requiresConfirmation, "\(action) is sensitive but not confirmed")
            }
            let confirmation = VehicleIntentConfirmation(action, vehicleName: "Friday")
            XCTAssertEqual(confirmation != nil, action.requiresConfirmation, "\(action)")
            if let confirmation { XCTAssertTrue(confirmation.prompt.contains("Friday")) }
        }
        XCTAssertEqual(VehicleIntentConfirmation(.sentryOff, vehicleName: "Friday")?.prompt,
                       "Turn off Sentry Mode on Friday? It stops watching and recording around the car.")
    }

    func testControlIntentsStayOutOfShortcutsAndRunInTheApp() {
        XCTAssertFalse(SetVehicleLockIntent.isDiscoverable)
        XCTAssertFalse(SetVehicleClimateIntent.isDiscoverable)
        XCTAssertFalse(OpenChargePortControlIntent.isDiscoverable)
        XCTAssertFalse(OpenVoltaIntent.isDiscoverable)
        XCTAssertTrue((SetVehicleLockIntent() as Any) is any LiveActivityIntent)
        XCTAssertTrue((SetVehicleClimateIntent() as Any) is any LiveActivityIntent)
        XCTAssertTrue((OpenChargePortControlIntent() as Any) is any LiveActivityIntent)
    }

    func testActionsMapToTheExistingCommands() {
        XCTAssertEqual(VehicleIntentAction.openFrunk.command, .actuateTrunk(whichTrunk: .front))
        XCTAssertEqual(VehicleIntentAction.openTrunk.command, .actuateTrunk(whichTrunk: .rear))
        XCTAssertEqual(VehicleIntentAction.flashLights.command, .flash)
        for action in VehicleIntentAction.allCases {
            XCTAssertTrue(VehicleCommand.supportedNames.contains(action.command.name), "\(action)")
        }
    }
}

// MARK: - Capability gating

final class VehicleIntentGateTests: XCTestCase {
    private let all = VehicleCommandCapabilities(available: true, reason: nil, commands: Array(VehicleCommand.supportedNames))

    private func check(_ capability: VehicleCommandCapabilities?, simulates: Bool = false, supported: Bool = true,
                       pending: Bool = false, busy: Bool = false) -> VoltaIntentError.Kind? {
        VehicleIntentGate.check(.unlock, capability: capability, simulates: simulates, supportedBySource: supported,
                                hasPending: pending, isBusy: busy)?.kind
    }

    func testReadyCommandPasses() {
        XCTAssertNil(check(all))
    }

    func testServerReasonsAreSpokenPlainly() {
        func kind(_ reason: String?) -> VoltaIntentError.Kind? {
            check(VehicleCommandCapabilities(available: false, reason: reason, commands: []), supported: false)
        }
        XCTAssertEqual(kind("commands_unavailable"), .commandsDisabled)
        XCTAssertEqual(kind("stub_mode"), .commandsDisabled)
        XCTAssertEqual(kind(nil), .commandsDisabled)
        XCTAssertEqual(kind("authorization_required"), .teslaNotLinked)
        XCTAssertEqual(kind("command_scope_required"), .teslaConsentNeeded)
        XCTAssertEqual(kind("reauthorization_required"), .teslaConsentNeeded)
        XCTAssertEqual(kind("vehicle_not_found"), .vehicleNotConfigured)
        XCTAssertEqual(kind("intent_storage_unavailable"), .storageUnavailable)
        XCTAssertEqual(check(nil, supported: false), .commandsDisabled)
        XCTAssertEqual(VehicleIntentGate.reason("authorization_required", action: .lock).message,
                       "Tesla isn’t linked to Volta yet. Open Volta to connect Tesla.")
    }

    func testCommandMissingFromCapabilityListIsRefused() {
        let error = VehicleIntentGate.check(.unlock, capability: VehicleCommandCapabilities(available: true, reason: nil, commands: ["lock"]),
                                            simulates: false, supportedBySource: false, hasPending: false, isBusy: false)
        XCTAssertEqual(error?.kind, .notAllowed)
        XCTAssertEqual(error?.message, "Your Volta server doesn’t allow Volta to unlock. Nothing was sent.")
    }

    func testUnresolvedAndBusyCommandsBlockNewOnes() {
        XCTAssertEqual(check(all, pending: true), .unresolvedCommand)
        XCTAssertEqual(check(all, busy: true), .busy)
    }

    func testDemoSimulatesWithoutServerCapabilities() {
        XCTAssertNil(check(.demo, simulates: true))
    }

    func testSuccessWordingNeverClaimsTheCarAlreadyChanged() {
        XCTAssertEqual(VehicleIntentGate.successDialog(.lock, vehicleName: "Friday", simulated: false), "Locking Friday.")
        XCTAssertEqual(VehicleIntentGate.successDialog(.honk, vehicleName: "Friday", simulated: true),
                       "Simulated in demo mode: honking the horn on Friday. No vehicle was contacted.")
    }

    func testRequestErrorsMapToSpokenReasons() {
        XCTAssertEqual(VehicleIntentService.mapRequestError(VoltaError.unreachable("offline"), action: .lock).kind, .serverUnreachable)
        XCTAssertEqual(VehicleIntentService.mapRequestError(URLError(.timedOut), action: .lock).kind, .serverUnreachable)
        XCTAssertEqual(VehicleIntentService.mapRequestError(VoltaError.unauthorized, action: .lock).kind, .notSignedIn)
    }
}

// MARK: - Service wiring

/// Lets a stub server reach the model it serves.
private final class ModelRef: @unchecked Sendable {
    weak var model: AppModel?
}

@MainActor private final class StubAuthentication: AppAuthenticating {
    var result = true
    var failure: Error?
    func unlock() async throws -> Bool { if let failure { throw failure }; return result }
    func cancel() {}
}

@MainActor private final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

@MainActor private final class IntentSurfaces: VehicleSurfaces {
    var published: [VehicleRefresh] = []
    var issued: UInt64 = 0
    func setContext(_ context: VehicleSurfaceContext) {}
    func nextStatusToken() -> StatusRequestToken { issued += 1; return StatusRequestToken(value: issued) }
    func publish(_ refresh: VehicleRefresh, dataSource: any VoltaDataSource) { published.append(refresh) }
    func drivingActivityPreferenceChanged() {}
}

private final class IntentTokenStore: TokenStoring, Sendable {
    private let token = Mutex<String?>(nil)
    func load() throws -> String? { token.withLock { $0 } }
    func save(_ value: String) throws { token.withLock { $0 = value } }
    func delete() throws { token.withLock { $0 = nil } }
}

/// Forwards to the real service and records which actions reached it.
@MainActor private final class RecordingPerformer: VehicleIntentPerforming {
    var actions: [VehicleIntentAction] = []
    var controlsShown = 0
    private let next: any VehicleIntentPerforming
    init(_ next: any VehicleIntentPerforming) { self.next = next }
    func perform(_ action: VehicleIntentAction,
                 confirm: (@MainActor (String) async throws -> Void)?) async throws -> String {
        actions.append(action)
        return try await next.perform(action, confirm: confirm)
    }
    func showControls() {
        controlsShown += 1
        next.showControls()
    }
}

private final class RequestLog: Sendable {
    private let entries = Mutex<[String]>([])
    func add(_ request: URLRequest) { entries.withLock { $0.append("\(request.httpMethod ?? "GET") \(request.url?.path ?? "")") } }
    var all: [String] { entries.withLock { $0 } }
}

@MainActor final class VehicleIntentServiceTests: XCTestCase {
    private func settings() -> UserSettings {
        let name = "VoltaIntentTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return UserSettings(defaults: defaults)
    }

    private func demoModel() -> AppModel {
        AppModel(settings: settings(), tokenStore: IntentTokenStore(), launchArguments: ["Volta", "-demo-mode", "YES"],
                 surfaces: IntentSurfaces(), commandIntentStore: VehicleCommandIntentStore(inMemory: []))
    }

    /// A paired model whose server answers through `handler`.
    private func pairedModel(surfaces: IntentSurfaces = IntentSurfaces(),
                             willStartCommand: (@Sendable () -> Void)? = nil,
                             appLock: (any AppAuthenticating)? = nil,
                             handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)) throws -> AppModel {
        StubProtocol.handler.withLock { $0 = handler }
        addTeardownBlock { StubProtocol.handler.withLock { $0 = nil } }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        let settings = settings(); settings.serverURL = "https://volta.example"; settings.selectedVehicleID = 42
        if appLock != nil { settings.appLockEnabled = true }
        let store = IntentTokenStore(); try store.save("synthetic-token")
        return AppModel(settings: settings, tokenStore: store, session: URLSession(configuration: config),
                        appLock: appLock ?? AppLock(),
                        launchArguments: ["Volta"], surfaces: surfaces,
                        commandIntentStore: VehicleCommandIntentStore(inMemory: []),
                        willStartCommand: willStartCommand)
    }

    private func json(_ text: String) -> Data { Data(text.utf8) }

    func testDemoReadsAnswerFromSyntheticStatusWithoutTheAppGroup() async throws {
        let model = demoModel()
        let service = VehicleIntentService(model: { model }, readSnapshot: {
            XCTFail("demo never reads the App Group snapshot"); return nil
        }, reloadControls: {})
        let reading = try await service.reading(now: Date())
        XCTAssertTrue(reading.isDemo)
        XCTAssertEqual(reading.snapshot.vehicleName, "Friday")
        XCTAssertEqual(reading.snapshot.batteryLevel, 72)
        XCTAssertEqual(reading.snapshot.placeName, "Home")
        let readout = VehicleReadout(reading.snapshot)
        XCTAssertTrue(readout.batteryDialog.hasPrefix("Friday is at 72% with about 204 miles"))
        XCTAssertTrue(readout.ageSentence.hasPrefix("Updated"))
    }

    func testDemoCommandsAreSimulated() async throws {
        let model = demoModel()
        let reloads = Box(0)
        let service = VehicleIntentService(model: { model }, readSnapshot: { nil }, reloadControls: { reloads.value += 1 })
        let text = try await service.perform(.lock)
        XCTAssertEqual(text, "Simulated in demo mode: locking Friday. No vehicle was contacted.")
        XCTAssertEqual(reloads.value, 1, "controls settle back on the observed state")
    }

    func testUnpairedReadsAndCommandsAskToSignIn() async {
        let model = AppModel(settings: settings(), tokenStore: IntentTokenStore(), launchArguments: ["Volta"],
                             surfaces: IntentSurfaces(), commandIntentStore: VehicleCommandIntentStore(inMemory: []))
        let service = VehicleIntentService(model: { model }, readSnapshot: { snapshot() }, reloadControls: {})
        do { _ = try await service.reading(); XCTFail("expected notSignedIn") }
        catch { XCTAssertEqual((error as? VoltaIntentError)?.kind, .notSignedIn) }
        do { _ = try await service.perform(.lock); XCTFail("expected notSignedIn") }
        catch { XCTAssertEqual((error as? VoltaIntentError)?.kind, .notSignedIn) }
    }

    func testPairedReadsUseTheCachedSnapshotAndSayUnknownWithoutOne() async throws {
        let model = try pairedModel { _ in (500, Data()) }
        let cached = snapshot()
        let service = VehicleIntentService(model: { model }, readSnapshot: { cached }, reloadControls: {})
        let reading = try await service.reading()
        XCTAssertFalse(reading.isDemo)
        XCTAssertEqual(reading.snapshot, cached)

        let empty = VehicleIntentService(model: { model }, readSnapshot: { nil }, reloadControls: {})
        do { _ = try await empty.reading(); XCTFail("expected noReading") }
        catch { XCTAssertEqual((error as? VoltaIntentError)?.kind, .noReading) }
    }

    func testPairedCommandIsRefusedWhenTeslaIsNotLinkedAndNothingIsSent() async throws {
        let log = RequestLog()
        let model = try pairedModel { request in
            log.add(request)
            if request.url?.path == "/v1/vehicles/42/commands" {
                return (200, Data(#"{"available":false,"reason":"authorization_required","commands":[]}"#.utf8))
            }
            return (404, Data())
        }
        let service = VehicleIntentService(model: { model }, readSnapshot: { nil }, reloadControls: {})
        do { _ = try await service.perform(.lock); XCTFail("expected teslaNotLinked") }
        catch { XCTAssertEqual((error as? VoltaIntentError)?.kind, .teslaNotLinked) }
        XCTAssertFalse(log.all.contains { $0.hasPrefix("POST") }, "no command was sent")
    }

    func testPairedCommandOutsideCapabilityListIsRefused() async throws {
        let log = RequestLog()
        let model = try pairedModel { request in
            log.add(request)
            if request.url?.path == "/v1/vehicles/42/commands" {
                return (200, Data(#"{"available":true,"reason":null,"commands":["lock"]}"#.utf8))
            }
            return (404, Data())
        }
        let service = VehicleIntentService(model: { model }, readSnapshot: { nil }, reloadControls: {})
        do { _ = try await service.perform(.honk); XCTFail("expected notAllowed") }
        catch { XCTAssertEqual((error as? VoltaIntentError)?.kind, .notAllowed) }
        XCTAssertFalse(log.all.contains { $0.hasPrefix("POST") })
    }

    func testUnreachableServerIsSpokenAndNothingIsSent() async throws {
        let log = RequestLog()
        let model = try pairedModel { request in
            log.add(request)
            throw URLError(.cannotConnectToHost)
        }
        let service = VehicleIntentService(model: { model }, readSnapshot: { nil }, reloadControls: {})
        do { _ = try await service.perform(.lock); XCTFail("expected serverUnreachable") }
        catch {
            let error = error as? VoltaIntentError
            XCTAssertEqual(error?.kind, .serverUnreachable)
            XCTAssertEqual(error?.message,
                           "Volta couldn’t reach your server so it couldn’t lock. Check that Tailscale is connected, then try again. Nothing was sent.")
        }
        XCTAssertFalse(log.all.contains { $0.hasPrefix("POST") })
    }

    func testPairedCommandSendsThroughTheExistingPathAndReloadsControls() async throws {
        let log = RequestLog()
        let model = try pairedModel { request in
            log.add(request)
            switch (request.httpMethod ?? "GET", request.url?.path ?? "") {
            case ("GET", "/v1/vehicles/42/commands"):
                return (200, Data(#"{"available":true,"reason":null,"commands":["lock","unlock"]}"#.utf8))
            case ("POST", "/v1/vehicles/42/commands/lock"):
                return (200, Data(#"{"ok":true,"command":"lock","requestId":"request_123"}"#.utf8))
            case ("GET", "/v1/vehicles"):
                return (200, try JSONSerialization.data(withJSONObject: [["id": 42, "name": "Friday"]]))
            default:
                return (404, Data())
            }
        }
        let reloads = Box(0)
        let service = VehicleIntentService(model: { model }, readSnapshot: { nil }, reloadControls: { reloads.value += 1 })
        let text = try await service.perform(.lock)
        XCTAssertEqual(text, "Locking Friday.")
        XCTAssertEqual(log.all.filter { $0.hasPrefix("POST") }, ["POST /v1/vehicles/42/commands/lock"])
        XCTAssertEqual(reloads.value, 1, "controls reload after an accepted command")
        let coordinator = model.commandCoordinator
        XCTAssertTrue(coordinator.pending(dataSource: model.dataSource, vehicleID: 42).isEmpty, "intent record cleared")
    }

    func testConfirmationRunsAfterChecksAndCancellingSendsNothing() async throws {
        let log = RequestLog()
        let model = try pairedModel { request in
            log.add(request)
            if request.url?.path == "/v1/vehicles/42/commands" {
                return (200, Data(#"{"available":true,"reason":null,"commands":["actuate_trunk"]}"#.utf8))
            }
            return (404, Data())
        }
        struct Cancelled: Error {}
        let askedFor = Box<String?>(nil)
        let service = VehicleIntentService(model: { model }, readSnapshot: { nil }, reloadControls: {})
        do {
            _ = try await service.perform(.openFrunk) { name in askedFor.value = name; throw Cancelled() }
            XCTFail("expected cancel")
        } catch { XCTAssertTrue(error is Cancelled) }
        XCTAssertEqual(askedFor.value, "your car", "the name falls back when the vehicle list is unavailable")
        XCTAssertFalse(log.all.contains { $0.hasPrefix("POST") })
    }

    /// A server that allows every intent command and accepts any POST.
    private func allowingModel(log: RequestLog, onCapabilities: (@Sendable () -> Void)? = nil,
                               willStartCommand: (@Sendable () -> Void)? = nil) throws -> AppModel {
        try pairedModel(willStartCommand: willStartCommand) { request in
            log.add(request)
            switch (request.httpMethod ?? "GET", request.url?.path ?? "") {
            case ("GET", "/v1/vehicles/42/commands"):
                onCapabilities?()
                return (200, Data(#"{"available":true,"reason":null,"commands":["lock","unlock","actuate_trunk","sentry_on","sentry_off"]}"#.utf8))
            case ("POST", let path) where path.hasPrefix("/v1/vehicles/42/commands/"):
                let name = path.split(separator: "/").last.map(String.init) ?? ""
                return (200, Data(#"{"ok":true,"command":"\#(name)","requestId":"request_1"}"#.utf8))
            case ("GET", "/v1/vehicles"):
                return (200, try JSONSerialization.data(withJSONObject: [["id": 42, "name": "Friday"]]))
            default:
                return (404, Data())
            }
        }
    }

    private func useRunner(_ service: VehicleIntentService,
                           confirm: @escaping @MainActor (any AppIntent, VehicleIntentConfirmation) async throws -> Void) {
        let previousService = VehicleActionRunner.service
        let previousConfirm = VoltaIntentHost.requestConfirmation
        VehicleActionRunner.service = { service }
        VoltaIntentHost.requestConfirmation = confirm
        addTeardownBlock { @MainActor in
            VehicleActionRunner.service = previousService
            VoltaIntentHost.requestConfirmation = previousConfirm
        }
    }

    /// Through each sensitive intent's own `perform()`: the prompt is shown
    /// after the capability checks, and cancelling it sends nothing.
    func testSensitiveIntentsAskBeforeSendingAndCancellingSendsNothing() async throws {
        let log = RequestLog()
        let model = try allowingModel(log: log)
        struct Cancelled: Error {}
        let asked = Box<[VehicleIntentAction]>([])
        let capabilityChecksBeforePrompt = Box<[Bool]>([])
        let runStart = Box(0)
        useRunner(VehicleIntentService(model: { model }, readSnapshot: { nil }, reloadControls: {})) { intent, confirmation in
            asked.value.append(confirmation.action)
            // Only this invocation's requests: its own capability check ran first.
            capabilityChecksBeforePrompt.value.append(log.all.dropFirst(runStart.value).contains("GET /v1/vehicles/42/commands"))
            XCTAssertTrue(confirmation.prompt.contains("Friday"))
            throw Cancelled()
        }
        let runs: [(VehicleIntentAction, () async throws -> Void)] = [
            (.unlock, { _ = try await UnlockVehicleIntent().perform() }),
            (.openFrunk, { _ = try await OpenFrunkIntent().perform() }),
            (.openTrunk, { _ = try await OpenTrunkIntent().perform() }),
            (.sentryOff, { _ = try await DisarmSentryIntent().perform() }),
        ]
        for (action, run) in runs {
            runStart.value = log.all.count
            do { try await run(); XCTFail("\(action) should wait for confirmation") }
            catch { XCTAssertTrue(error is Cancelled, "\(action): \(error)") }
        }
        XCTAssertEqual(asked.value, [.unlock, .openFrunk, .openTrunk, .sentryOff])
        XCTAssertEqual(capabilityChecksBeforePrompt.value, [true, true, true, true])
        XCTAssertFalse(log.all.contains { $0.hasPrefix("POST") }, "nothing was sent")
    }

    func testConfirmedSentryOffSendsAndRoutineIntentsDoNotAsk() async throws {
        let log = RequestLog()
        let model = try allowingModel(log: log)
        let asked = Box<[VehicleIntentAction]>([])
        useRunner(VehicleIntentService(model: { model }, readSnapshot: { nil }, reloadControls: {})) { _, confirmation in
            asked.value.append(confirmation.action)
        }
        _ = try await DisarmSentryIntent().perform()
        _ = try await ArmSentryIntent().perform()
        XCTAssertEqual(asked.value, [.sentryOff], "only the sensitive one asked")
        XCTAssertEqual(log.all.filter { $0.hasPrefix("POST") },
                       ["POST /v1/vehicles/42/commands/sentry_off", "POST /v1/vehicles/42/commands/sentry_on"])
    }

    /// The service itself refuses a confirmation-required action from Siri or
    /// Shortcuts without a confirmation step.
    func testConfirmationRequiredActionsAreRefusedWithoutAPrompt() async throws {
        let log = RequestLog()
        let model = try allowingModel(log: log)
        let service = VehicleIntentService(model: { model }, readSnapshot: { nil }, reloadControls: {})
        for action in VehicleIntentAction.allCases where action.requiresConfirmation {
            do { _ = try await service.perform(action, confirm: nil); XCTFail("\(action) needs confirmation") }
            catch { XCTAssertEqual(error as? VoltaIntentError, .confirmationRequired) }
        }
        XCTAssertTrue(log.all.isEmpty, "refused before any request")
    }

    func testSwitchingToDemoDuringConfirmationSendsNothing() async throws {
        let log = RequestLog()
        let model = try allowingModel(log: log)
        let service = VehicleIntentService(model: { model }, readSnapshot: { nil }, reloadControls: {})
        do {
            _ = try await service.perform(.unlock) { _ in model.tryDemoMode() }
            XCTFail("expected connectionChanged")
        } catch { XCTAssertEqual(error as? VoltaIntentError, .connectionChanged) }
        XCTAssertTrue(model.isDemoMode)
        XCTAssertFalse(log.all.contains { $0.hasPrefix("POST") }, "the real token sent nothing")
    }

    func testDisconnectingDuringConfirmationSendsNothing() async throws {
        let log = RequestLog()
        let model = try allowingModel(log: log)
        let service = VehicleIntentService(model: { model }, readSnapshot: { nil }, reloadControls: {})
        do {
            _ = try await service.perform(.openTrunk) { _ in model.unpair() }
            XCTFail("expected connectionChanged")
        } catch { XCTAssertEqual(error as? VoltaIntentError, .connectionChanged) }
        XCTAssertFalse(model.isPaired)
        XCTAssertFalse(log.all.contains { $0.hasPrefix("POST") })
    }

    func testDisconnectingWhileCapabilitiesLoadSendsNothing() async throws {
        let log = RequestLog()
        let ref = ModelRef()
        let model = try allowingModel(log: log, onCapabilities: {
            // The request is in flight while the person disconnects in the app.
            DispatchQueue.main.sync { MainActor.assumeIsolated { _ = ref.model?.unpair() } }
        })
        ref.model = model
        let service = VehicleIntentService(model: { model }, readSnapshot: { nil }, reloadControls: {})
        do { _ = try await service.perform(.lock); XCTFail("expected connectionChanged") }
        catch { XCTAssertEqual(error as? VoltaIntentError, .connectionChanged) }
        XCTAssertFalse(model.isPaired)
        XCTAssertFalse(log.all.contains { $0.hasPrefix("POST") })
    }

    func testSelectingAnotherCarDuringConfirmationSendsNothing() async throws {
        let log = RequestLog()
        let model = try allowingModel(log: log)
        let service = VehicleIntentService(model: { model }, readSnapshot: { nil }, reloadControls: {})
        do {
            _ = try await service.perform(.unlock) { _ in model.settings.selectedVehicleID = 7 }
            XCTFail("expected connectionChanged")
        } catch { XCTAssertEqual(error as? VoltaIntentError, .connectionChanged) }
        XCTAssertFalse(log.all.contains { $0.hasPrefix("POST") })
    }

    /// Only the connection generation changes (same demo state, same car,
    /// the source replaced by an equivalent one): still nothing is sent.
    func testReplacingTheSourceAloneDuringConfirmationSendsNothing() async throws {
        let model = AppModel(settings: settings(), tokenStore: IntentTokenStore(), launchArguments: ["Volta"],
                             surfaces: IntentSurfaces(), commandIntentStore: VehicleCommandIntentStore(inMemory: []))
        model.tryDemoMode()
        let before = CommandContext(model)
        let service = VehicleIntentService(model: { model }, readSnapshot: { nil }, reloadControls: {})
        do {
            _ = try await service.perform(.unlock) { _ in model.tryDemoMode() }
            XCTFail("expected connectionChanged")
        } catch { XCTAssertEqual(error as? VoltaIntentError, .connectionChanged) }
        let after = CommandContext(model)
        XCTAssertEqual(after.pairingState, before.pairingState)
        XCTAssertEqual(after.selectedVehicleID, before.selectedVehicleID)
        XCTAssertNotEqual(after.connectionGeneration, before.connectionGeneration, "only the generation moved")
        XCTAssertNil(model.commandCoordinator.activity(dataSource: model.dataSource, vehicleID: MockDataSource.vehicleID),
                     "the command never reached the coordinator")
    }

    /// The last window: the app disconnects after every upstream check, just
    /// before the transport starts the POST. The replaced source refuses.
    func testDisconnectingJustBeforeTheTransportSendsNothing() async throws {
        let log = RequestLog()
        let ref = ModelRef()
        let model = try allowingModel(log: log, willStartCommand: {
            DispatchQueue.main.sync { MainActor.assumeIsolated { _ = ref.model?.unpair() } }
        })
        ref.model = model
        let source = model.dataSource
        let service = VehicleIntentService(model: { model }, readSnapshot: { nil }, reloadControls: {})
        do { _ = try await service.perform(.lock); XCTFail("expected connectionChanged") }
        catch {
            XCTAssertEqual(error as? VoltaIntentError, .connectionChanged)
            XCTAssertTrue((error as? VoltaIntentError)?.message.contains("nothing was sent") == true)
        }
        XCTAssertFalse(model.isPaired)
        XCTAssertFalse(log.all.contains { $0.hasPrefix("POST") }, "the POST was never started")
        XCTAssertTrue(model.commandCoordinator.pending(dataSource: source, vehicleID: 42).isEmpty,
                      "a refused send is not left as an unresolved command")
    }

    func testAnInvalidatedSourceRefusesCommandsButStillReads() async throws {
        let log = RequestLog()
        StubProtocol.handler.withLock { $0 = { request in
            log.add(request)
            return (200, Data(#"{"available":true,"reason":null,"commands":["lock"]}"#.utf8))
        } }
        addTeardownBlock { StubProtocol.handler.withLock { $0 = nil } }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        let source = APIDataSource(baseURL: URL(string: "https://volta.example")!, token: "synthetic-token",
                                   session: URLSession(configuration: config))
        let copy = source
        XCTAssertTrue(copy.acceptsCommands)
        source.invalidateCommands()
        XCTAssertFalse(copy.acceptsCommands, "every copy shares the gate")
        do {
            _ = try await copy.command(vehicleID: 42, command: .lock, intentID: UUID())
            XCTFail("expected a refusal")
        } catch let failure as VehicleCommandFailure {
            XCTAssertEqual(failure.code, "connection_changed")
            XCTAssertFalse(failure.isUnresolved, "nothing was sent, so nothing is unresolved")
        }
        XCTAssertTrue(log.all.isEmpty, "no request was made")
        _ = try await copy.commandCapabilities(vehicleID: 42)
        XCTAssertEqual(log.all, ["GET /v1/vehicles/42/commands"], "reads still work")
    }

    private func useControlHost(_ performer: any VehicleIntentPerforming,
                                continueInApp: @escaping @MainActor (any AppIntent) async throws -> Void) {
        let previousPerformer = VoltaIntentHost.performer
        let previousContinue = VoltaIntentHost.continueInApp
        VoltaIntentHost.performer = performer
        VoltaIntentHost.continueInApp = continueInApp
        addTeardownBlock { @MainActor in
            VoltaIntentHost.performer = previousPerformer
            VoltaIntentHost.continueInApp = previousContinue
        }
    }

    /// A control can't show a confirmation, so turning the lock toggle off in
    /// the app process opens Volta's Controls screen and sends nothing.
    func testLockControlUnlockOpensVoltaAndSendsNothing() async throws {
        let log = RequestLog()
        let model = try allowingModel(log: log)
        let reloads = Box(0)
        let recorder = RecordingPerformer(VehicleIntentService(model: { model }, readSnapshot: { nil },
                                                               reloadControls: { reloads.value += 1 }))
        let opened = Box(0)
        useControlHost(recorder) { intent in
            XCTAssertTrue(intent is SetVehicleLockIntent)
            opened.value += 1
        }
        _ = try await SetVehicleLockIntent(value: false).perform()
        XCTAssertEqual(opened.value, 1, "Volta was brought to the front")
        XCTAssertEqual(reloads.value, 1, "the toggle settles back on the observed state")
        XCTAssertEqual(recorder.controlsShown, 1)
        XCTAssertEqual(model.controlsRequest, ControlsRequest(generation: model.connectionGeneration),
                       "the Controls screen is requested for this connection")
        XCTAssertTrue(recorder.actions.isEmpty, "the unlock never reached the command path")
        XCTAssertTrue(log.all.isEmpty, "zero requests")
    }

    /// If the system can't bring Volta forward, the tap fails and still sends nothing.
    func testLockControlUnlockSendsNothingWhenVoltaCannotOpen() async throws {
        let log = RequestLog()
        let model = try allowingModel(log: log)
        struct Unavailable: Error {}
        useControlHost(VehicleIntentService(model: { model }, readSnapshot: { nil }, reloadControls: {})) { _ in
            throw Unavailable()
        }
        do { _ = try await SetVehicleLockIntent(value: false).perform(); XCTFail("expected the error") }
        catch { XCTAssertTrue(error is Unavailable) }
        XCTAssertTrue(log.all.isEmpty, "zero requests")
    }

    func testLockControlStillLocksImmediately() async throws {
        let log = RequestLog()
        let model = try allowingModel(log: log)
        let opened = Box(0)
        useControlHost(VehicleIntentService(model: { model }, readSnapshot: { nil }, reloadControls: {})) { _ in
            opened.value += 1
        }
        _ = try await SetVehicleLockIntent(value: true).perform()
        XCTAssertEqual(opened.value, 0, "locking doesn't open the app")
        XCTAssertEqual(log.all.filter { $0.hasPrefix("POST") }, ["POST /v1/vehicles/42/commands/lock"])
    }

    /// No control route can send an action the confirmation table marks sensitive.
    func testNoControlSendsAConfirmationRequiredAction() async throws {
        let log = RequestLog()
        let model = try allowingModel(log: log)
        let recorder = RecordingPerformer(VehicleIntentService(model: { model }, readSnapshot: { nil }, reloadControls: {}))
        useControlHost(recorder) { _ in }
        for action in VehicleIntentAction.allCases where action.requiresConfirmation {
            try await VoltaIntentHost.performControl(action, for: SetVehicleLockIntent())
        }
        XCTAssertTrue(recorder.actions.isEmpty)
        XCTAssertTrue(log.all.isEmpty)
        // And the control intents only ever map to these actions.
        XCTAssertFalse([VehicleIntentAction.lock, .climateOn, .climateOff, .openChargePort].contains(where: \.requiresConfirmation))
    }

    // MARK: Opening Controls from the lock control

    private func decide(_ request: ControlsRequest? = ControlsRequest(generation: 3), generation: Int = 3,
                        isPaired: Bool = true, isActive: Bool = true, isLocked: Bool = false,
                        hasVehicles: Bool = true, otherSheetUp: Bool = false) -> ControlsRequestDecision {
        AppModel.controlsRequestDecision(request, generation: generation, isPaired: isPaired, isActive: isActive,
                                         isLocked: isLocked, hasVehicles: hasVehicles, otherSheetUp: otherSheetUp)
    }

    func testControlsRequestDecisionCoversEveryBranch() {
        XCTAssertEqual(decide(nil), .idle)
        XCTAssertEqual(decide(), .present)
        XCTAssertEqual(decide(generation: 4), .drop, "made under another connection")
        XCTAssertEqual(decide(isPaired: false), .drop, "no session")
        XCTAssertEqual(decide(isActive: false), .wait, "in the background")
        XCTAssertEqual(decide(isLocked: true), .wait, "locked: do not present")
        XCTAssertEqual(decide(hasVehicles: false), .wait, "vehicles still loading")
        XCTAssertEqual(decide(otherSheetUp: true), .drop, "never stack sheets")
        XCTAssertEqual(decide(generation: 4, isLocked: true), .drop, "a stale request never waits")
    }

    private func vehiclesModel(appLock: StubAuthentication) async throws -> AppModel {
        let model = try pairedModel(appLock: appLock) { request in
            if request.url?.path == "/v1/vehicles" {
                return (200, try JSONSerialization.data(withJSONObject: [["id": 42, "name": "Friday"]]))
            }
            return (404, Data())
        }
        if model.isLocked { appLock.result = true; await model.unlock() }
        await model.loadVehicles()
        XCTAssertFalse(model.vehicles.isEmpty)
        return model
    }

    func testControlsWaitWhileLockedAndShowOnceAfterUnlock() async throws {
        let auth = StubAuthentication()
        let model = try await vehiclesModel(appLock: auth)
        model.didEnterBackground()
        XCTAssertTrue(model.isLocked)
        model.requestControls()
        model.updateControlsRequest(isActive: true, otherSheetUp: false)
        XCTAssertFalse(model.showsRequestedControls, "locked: do not present")
        XCTAssertNotNil(model.controlsRequest, "the request waits")

        auth.result = true
        await model.unlock()
        model.updateControlsRequest(isActive: true, otherSheetUp: false)
        XCTAssertTrue(model.showsRequestedControls, "unlock succeeded: present")
        XCTAssertNil(model.controlsRequest, "consumed")
        model.showsRequestedControls = false  // the person closes it
        model.updateControlsRequest(isActive: true, otherSheetUp: false)
        XCTAssertFalse(model.showsRequestedControls, "presented once")
    }

    func testControlsRequestIsDroppedWhenAuthenticationIsCancelledOrFails() async throws {
        let auth = StubAuthentication()
        let model = try await vehiclesModel(appLock: auth)
        model.didEnterBackground()
        model.requestControls()
        auth.result = false
        await model.unlock()
        XCTAssertNil(model.controlsRequest, "authentication cancelled: dropped")
        auth.result = true
        await model.unlock()
        model.updateControlsRequest(isActive: true, otherSheetUp: false)
        XCTAssertFalse(model.showsRequestedControls, "a later unlock doesn't revive it")

        struct Failed: Error {}
        model.didEnterBackground()
        model.requestControls()
        auth.failure = Failed()
        await model.unlock()
        XCTAssertNil(model.controlsRequest, "authentication failed: dropped")
    }

    func testControlsRequestIsDroppedWhenTheConnectionChanges() async throws {
        let model = try await vehiclesModel(appLock: StubAuthentication())
        model.requestControls()
        model.tryDemoMode()
        model.updateControlsRequest(isActive: true, otherSheetUp: false)
        XCTAssertNil(model.controlsRequest, "generation changed: dropped")
        XCTAssertFalse(model.showsRequestedControls)

        let other = try await vehiclesModel(appLock: StubAuthentication())
        other.requestControls()
        other.unpair()
        other.updateControlsRequest(isActive: true, otherSheetUp: false)
        XCTAssertNil(other.controlsRequest, "disconnected: dropped")
    }

    func testControlsRequestNeverStacksAndClosesWhenLocked() async throws {
        let model = try await vehiclesModel(appLock: StubAuthentication())
        model.requestControls()
        model.updateControlsRequest(isActive: true, otherSheetUp: true)
        XCTAssertNil(model.controlsRequest, "another sheet is up: dropped")
        XCTAssertFalse(model.showsRequestedControls)

        model.requestControls()
        model.updateControlsRequest(isActive: true, otherSheetUp: false)
        XCTAssertTrue(model.showsRequestedControls)
        model.didEnterBackground()
        model.updateControlsRequest(isActive: false, otherSheetUp: true)
        XCTAssertFalse(model.showsRequestedControls, "the app lock closes it rather than leaving it above the overlay")
    }

    /// A command whose Swift task is cancelled before the transport starts it
    /// is never resumed: nothing reaches the network.
    func testACommandCancelledBeforeItStartsIsNeverSent() async throws {
        let log = RequestLog()
        StubProtocol.handler.withLock { $0 = { request in
            log.add(request)
            return (200, Data(#"{"ok":true,"command":"lock","requestId":"request_1"}"#.utf8))
        } }
        addTeardownBlock { StubProtocol.handler.withLock { $0 = nil } }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        let source = APIDataSource(baseURL: URL(string: "https://volta.example")!, token: "synthetic-token",
                                   session: URLSession(configuration: config),
                                   willStartCommand: { withUnsafeCurrentTask { $0?.cancel() } })
        let attempt = Task { try await source.command(vehicleID: 42, command: .lock, intentID: UUID()) }
        do {
            _ = try await attempt.value
            XCTFail("expected a refusal")
        } catch let failure as VehicleCommandFailure {
            XCTAssertEqual(failure.code, "cancelled_before_send")
            XCTAssertFalse(failure.isUnresolved, "nothing was sent, so nothing is unresolved")
        }
        XCTAssertTrue(log.all.isEmpty, "zero POSTs")
        XCTAssertTrue(source.acceptsCommands, "cancellation doesn't invalidate the source")
    }

    func testControlIntentWithoutTheAppFailsClosed() async {
        let previous = VoltaIntentHost.performer
        VoltaIntentHost.performer = nil
        defer { VoltaIntentHost.performer = previous }
        do { try await VoltaIntentHost.performControl(.unlock, for: SetVehicleLockIntent()); XCTFail("expected needsApp") }
        catch { XCTAssertEqual((error as? VoltaIntentError)?.kind, .needsApp) }
    }

    /// The extension never registers a performer. Each control intent run
    /// there must reach no command path and tell the user to open Volta, on
    /// every SDK (with or without `allowedExecutionTargets`).
    func testEveryControlIntentSendsNothingWhereTheAppIsNotRegistered() async throws {
        let log = RequestLog()
        let model = try pairedModel { request in log.add(request); return (500, Data()) }
        let recorder = RecordingPerformer(VehicleIntentService(model: { model }, readSnapshot: { nil }, reloadControls: {}))
        let previous = VoltaIntentHost.performer
        defer { VoltaIntentHost.performer = previous }

        // Registered (app process): the action reaches the app's command path.
        VoltaIntentHost.performer = recorder
        _ = try? await SetVehicleLockIntent(value: true).perform()
        XCTAssertEqual(recorder.actions, [.lock])

        // Not registered (extension process): nothing reaches it, nothing is sent.
        VoltaIntentHost.performer = nil
        recorder.actions = []
        let before = log.all.count
        let runs: [(String, () async throws -> Void)] = [
            ("unlock", { _ = try await SetVehicleLockIntent(value: false).perform() }),
            ("lock", { _ = try await SetVehicleLockIntent(value: true).perform() }),
            ("climate on", { _ = try await SetVehicleClimateIntent(value: true).perform() }),
            ("climate off", { _ = try await SetVehicleClimateIntent(value: false).perform() }),
            ("charge port", { _ = try await OpenChargePortControlIntent().perform() }),
        ]
        for (name, run) in runs {
            do { try await run(); XCTFail("\(name) should fail without the app") }
            catch {
                XCTAssertEqual((error as? VoltaIntentError)?.kind, .needsApp, name)
                XCTAssertEqual((error as? VoltaIntentError)?.message, "Open Volta to send vehicle commands. Nothing was sent.")
            }
        }
        XCTAssertTrue(recorder.actions.isEmpty)
        XCTAssertEqual(log.all.count, before, "no request of any kind left the process")
    }

    /// Which execution path this build compiled. With Xcode 27 (Swift 6.4,
    /// iOS 27 SDK) the control intents name the app as their only target on
    /// iOS 27; with older toolchains they rely on `LiveActivityIntent`.
    func testControlIntentsRunInTheAppOnEveryToolchain() {
        XCTAssertTrue((SetVehicleLockIntent() as Any) is any LiveActivityIntent)
        XCTAssertTrue((SetVehicleClimateIntent() as Any) is any LiveActivityIntent)
        XCTAssertTrue((OpenChargePortControlIntent() as Any) is any LiveActivityIntent)
        #if compiler(>=6.4)
        XCTAssertTrue(VoltaIntentHost.declaresAppOnlyExecution)
        if #available(iOS 27.0, *) {
            XCTAssertEqual(SetVehicleLockIntent.allowedExecutionTargets, .main)
            XCTAssertEqual(SetVehicleClimateIntent.allowedExecutionTargets, .main)
            XCTAssertEqual(OpenChargePortControlIntent.allowedExecutionTargets, .main)
        }
        #else
        XCTAssertFalse(VoltaIntentHost.declaresAppOnlyExecution)
        #endif
    }
}
