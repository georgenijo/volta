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
        placeName: "Home", today: nil, timeline: [])
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

    func testLocationIsPlaceNameOnlyNeverCoordinates() {
        XCTAssertEqual(readout().locationDialog, "Friday is at Home. Updated 4 minutes ago.")
        XCTAssertEqual(readout { $0.placeName = nil }.locationDialog, "Friday’s location is unknown. Updated 4 minutes ago.")
        XCTAssertNil(readout { $0.placeName = "  " }.place)
        XCTAssertEqual(readout { $0.state = .driving }.locationDialog,
                       "Friday is driving. It was last at Home. Updated 4 minutes ago.")
        XCTAssertEqual(readout { $0.state = .driving; $0.placeName = nil }.locationDialog,
                       "Friday is driving. Its location is unknown. Updated 4 minutes ago.")
        // The snapshot has no coordinate fields; nothing numeric beyond the age appears.
        let spoken = readout { $0.placeName = nil }.locationDialog
        XCTAssertNil(spoken.range(of: #"\d+\.\d+"#, options: .regularExpression))
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
        XCTAssertEqual(VehicleToggleLabel.lock(observed: true, isOn: true, readout: fresh),
                       .init(text: "Locked", symbol: "lock.fill"))
        XCTAssertEqual(VehicleToggleLabel.lock(observed: true, isOn: false, readout: fresh).text, "Unlocking…")
        XCTAssertEqual(VehicleToggleLabel.lock(observed: false, isOn: false, readout: fresh).text, "Unlocked")
        let stale = readout { $0.updatedAt = now.addingTimeInterval(-2 * 3600) }
        XCTAssertEqual(VehicleToggleLabel.lock(observed: true, isOn: true, readout: stale).text, "Locked · 2h")
        XCTAssertEqual(VehicleToggleLabel.climate(observed: nil, isOn: false, readout: nil),
                       .init(text: "Unknown", symbol: "fan"))
        XCTAssertEqual(VehicleToggleLabel.climate(observed: false, isOn: true, readout: fresh).text, "Turning On…")
        XCTAssertEqual(VehicleToggleLabel.climate(observed: true, isOn: true, readout: fresh).text, "On")
    }

    func testVehicleNameFallbackAndPossessive() {
        XCTAssertTrue(readout { $0.vehicleName = " " }.batteryDialog.hasPrefix("Your car is at 72%"))
        XCTAssertTrue(readout { $0.vehicleName = "Atlas"; $0.placeName = nil }.locationDialog.hasPrefix("Atlas’ location"))
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
    private let next: any VehicleIntentPerforming
    init(_ next: any VehicleIntentPerforming) { self.next = next }
    func perform(_ action: VehicleIntentAction) async throws -> String {
        actions.append(action)
        return try await next.perform(action)
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
                             handler: @escaping @Sendable (URLRequest) throws -> (Int, Data)) throws -> AppModel {
        StubProtocol.handler.withLock { $0 = handler }
        addTeardownBlock { StubProtocol.handler.withLock { $0 = nil } }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        let settings = settings(); settings.serverURL = "https://volta.example"; settings.selectedVehicleID = 42
        let store = IntentTokenStore(); try store.save("synthetic-token")
        return AppModel(settings: settings, tokenStore: store, session: URLSession(configuration: config),
                        launchArguments: ["Volta"], surfaces: surfaces,
                        commandIntentStore: VehicleCommandIntentStore(inMemory: []))
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
        do { _ = try await service.perform(.unlock); XCTFail("expected teslaNotLinked") }
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
        do { _ = try await service.perform(.openFrunk); XCTFail("expected notAllowed") }
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

    func testControlIntentWithoutTheAppFailsClosed() async {
        let previous = VoltaIntentHost.performer
        VoltaIntentHost.performer = nil
        defer { VoltaIntentHost.performer = previous }
        do { _ = try await VoltaIntentHost.perform(.unlock); XCTFail("expected needsApp") }
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
