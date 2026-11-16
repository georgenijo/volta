import XCTest
import Synchronization
@testable import Volta

private final class SelectionTokenStore: TokenStoring, Sendable {
    private let token = Mutex<String?>(nil)
    func load() throws -> String? { token.withLock { $0 } }
    func save(_ value: String) throws { token.withLock { $0 = value } }
    func delete() throws { token.withLock { $0 = nil } }
}

/// Synthetic account: car 1 has never reported a battery reading, car 2 has.
private func vehiclesJSON(firstHasData: Bool = false) -> Data {
    try! JSONSerialization.data(withJSONObject: [
        ["id": 1, "name": "Tesla", "hasData": firstHasData],
        ["id": 2, "name": "Friday", "model": "Model Y", "hasData": true],
    ])
}

@MainActor final class VehicleSelectionTests: XCTestCase {
    private func settings(_ name: String = "VoltaSelectionTests.\(UUID())") -> UserSettings {
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return UserSettings(defaults: UserDefaults(suiteName: name)!)
    }

    /// A restored pairing whose `/v1/vehicles` responses come from `vehicles`.
    private func pairedModel(_ settings: UserSettings, saved: MemorySavedDashboards? = nil,
                             environment: [String: String] = [:],
                             vehicles: @escaping @Sendable () -> Data) throws -> AppModel {
        let status = try DecodingTests.fixture("status")
        StubProtocol.handler.withLock {
            $0 = { request in request.url?.path == "/v1/vehicles" ? (200, vehicles()) : (200, status) }
        }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        settings.serverURL = "https://volta.example"
        let store = SelectionTokenStore(); try store.save("synthetic-token")
        return AppModel(settings: settings, tokenStore: store, session: URLSession(configuration: config),
                        launchArguments: ["Volta"], launchEnvironment: environment, surfaces: NoSurfaces(),
                        savedDashboards: saved)
    }

    /// What the first dashboard would receive as the startup vehicle list.
    private func handedOff(_ model: AppModel, vehicleID: Int) async -> [Int]? {
        await model.takeInitialDashboardVehicles(vehicleID: vehicleID)?.vehicles?()?.map(\.id)
    }

    /// The saved-dashboard key `pairedModel` restores.
    private var pairedBackend: String {
        SavedDashboard.backendKey(APIDataSource(baseURL: URL(string: "https://volta.example")!,
                                                token: "synthetic-token").commandBackendID)
    }

    private func savedDashboard(backend: String, vehicleID: Int = 2) -> SavedDashboard {
        SavedDashboard(backend: backend, vehicleID: vehicleID, savedAt: .now.addingTimeInterval(-300),
                       vehicles: [Vehicle(id: 1, name: "Tesla"), Vehicle(id: 2, name: "Saved Friday")],
                       status: VehicleStatus(vehicleId: vehicleID, state: .asleep, updatedAt: .now.addingTimeInterval(-600),
                                             batteryLevel: 64, usableBatteryLevel: nil, ratedRangeKm: 300, estRangeKm: nil,
                                             chargeLimit: 80, chargingState: nil, chargerPowerKw: nil, minutesToFull: nil,
                                             insideTempC: nil, outsideTempC: nil, climateOn: nil, driverTempSettingC: nil,
                                             locked: true, sentryMode: nil, odometerKm: nil, location: nil, firmware: nil),
                       timeline: [], summaries: [], todayRequestedAt: nil, todayRequestedZone: nil)
    }

    func testHasDataDecodesAndOlderServersAreUnknown() throws {
        let decoder = APIDataSource.makeDecoder()
        XCTAssertNil(try decoder.decode(Vehicle.self, from: Data(#"{"id":1,"name":"A"}"#.utf8)).hasData)
        XCTAssertEqual(try decoder.decode(Vehicle.self, from: Data(#"{"id":1,"name":"A","hasData":false}"#.utf8)).hasData, false)
    }

    func testAutomaticChoicePrefersDataWithoutHidingCars() {
        let none = Vehicle(id: 1, name: "Tesla", hasData: false), data = Vehicle(id: 2, name: "Friday", hasData: true)
        let unknown = Vehicle(id: 3, name: "Old server")
        XCTAssertEqual(Vehicle.automaticChoice(in: [none, data])?.id, 2)
        XCTAssertEqual(Vehicle.automaticChoice(in: [none, Vehicle(id: 2, name: "B", hasData: false)])?.id, 1)
        XCTAssertEqual(Vehicle.automaticChoice(in: [unknown, data])?.id, 3, "older servers keep first-vehicle order")
        XCTAssertNil(Vehicle.automaticChoice(in: []))
    }

    func testFirstLoadSelectsVehicleWithDataAndListsEveryCar() async throws {
        let settings = settings()
        let model = try pairedModel(settings) { vehiclesJSON() }
        await model.loadVehicles()
        XCTAssertEqual(model.vehicles.map(\.id), [1, 2])
        XCTAssertEqual(model.selectedVehicleID, 2); XCTAssertEqual(model.selectedVehicle?.name, "Friday")
        XCTAssertFalse(settings.selectedVehicleIsExplicit)
    }

    func testStartupVehicleListIsHandedToDashboardOnlyOnce() async throws {
        let model = try pairedModel(settings()) { vehiclesJSON() }
        await model.loadVehicles()
        let first = await handedOff(model, vehicleID: 2)
        XCTAssertEqual(first, [1, 2])
        let second = await handedOff(model, vehicleID: 2)
        XCTAssertNil(second)
        await model.loadVehicles()
        let later = await handedOff(model, vehicleID: 2)
        XCTAssertNil(later, "later account refreshes must not seed a future remount")
    }

    func testVehicleSwitchDiscardsUnusedStartupHandoff() async throws {
        let model = try pairedModel(settings()) { vehiclesJSON() }
        await model.loadVehicles()
        model.select(model.vehicles[0])
        let afterSwitch = await handedOff(model, vehicleID: 1)
        XCTAssertNil(afterSwitch, "a new dashboard after switching fetches current metadata")
    }

    func testStartupHandoffCannotSurviveAccountChangeOrBackground() async throws {
        let model = try pairedModel(settings()) { vehiclesJSON() }
        await model.loadVehicles()
        model.didEnterBackground()
        let afterBackground = await handedOff(model, vehicleID: 2)
        XCTAssertNil(afterBackground)
        let other = try pairedModel(settings()) { vehiclesJSON() }
        await other.loadVehicles()
        other.tryDemoMode()
        let afterDemo = await handedOff(other, vehicleID: 2)
        XCTAssertNil(afterDemo)
    }

    func testSavedDashboardMountsTheShellBeforeTheVehicleListLoads() async throws {
        let saved = MemorySavedDashboards(savedDashboard(backend: pairedBackend))
        let settings = settings()
        settings.selectedVehicleID = 2
        let model = try pairedModel(settings, saved: saved) { vehiclesJSON() }
        XCTAssertEqual(model.vehicles.map(\.name), ["Tesla", "Saved Friday"], "the shell can mount in the first frame")
        XCTAssertFalse(model.hasLoadedVehicles)
        XCTAssertEqual(model.surfaceContext, .vehicle(id: 2, name: "Saved Friday"))
        let start = model.takeInitialDashboardVehicles(vehicleID: 2)
        XCTAssertEqual(start?.saved?.status.batteryLevel, 64)
        XCTAssertNotNil(start?.store)
        XCTAssertEqual(start?.prefetch?.vehicleID, 2, "the dashboard's status was requested at launch")
        start?.prefetch?.cancel()
        XCTAssertNil(model.takeInitialDashboardVehicles(vehicleID: 2)?.saved, "only the first dashboard shows it")
        await model.loadVehicles()
        XCTAssertEqual(model.vehicles.map(\.name), ["Tesla", "Friday"], "the fresh list replaces the saved one")
    }

    func testDashboardMountedEarlyAwaitsTheStartupVehicleRequest() async throws {
        let saved = MemorySavedDashboards(savedDashboard(backend: pairedBackend))
        let settings = settings()
        settings.selectedVehicleID = 2
        let model = try pairedModel(settings, saved: saved) { vehiclesJSON() }
        let load = Task { await model.loadVehicles() }
        await Task.yield()
        XCTAssertTrue(model.isLoadingVehicles)
        let handoff = model.takeInitialDashboardVehicles(vehicleID: 2)?.vehicles
        XCTAssertNotNil(handoff, "a dashboard mounted from saved vehicles reuses the request in flight")
        let ids = await handoff?()?.map(\.id)
        XCTAssertEqual(ids, [1, 2])
        await load.value
        let again = await handedOff(model, vehicleID: 2)
        XCTAssertNil(again)
    }

    func testSavedDashboardIsIgnoredForAnotherBackendOrWhileLocked() throws {
        let other = MemorySavedDashboards(savedDashboard(backend: SavedDashboard.backendKey("another-server")))
        let model = try pairedModel(settings(), saved: other) { vehiclesJSON() }
        XCTAssertTrue(model.vehicles.isEmpty)
        XCTAssertNil(model.takeInitialDashboardVehicles(vehicleID: 2)?.saved)

        let locked = settings()
        locked.appLockEnabled = true
        let lockedModel = try pairedModel(locked, saved: MemorySavedDashboards(savedDashboard(backend: pairedBackend))) { vehiclesJSON() }
        XCTAssertTrue(lockedModel.isLocked)
        XCTAssertTrue(lockedModel.vehicles.isEmpty, "nothing loads behind the lock screen")
    }

    func testRestoredPairingSendsOneVehicleRequestBeforeTheRootViewAppears() async throws {
        let calls = Mutex(0)
        let model = try pairedModel(settings()) { calls.withLock { $0 += 1 }; return vehiclesJSON() }
        await waitUntil { model.hasLoadedVehicles }
        XCTAssertEqual(calls.withLock { $0 }, 1, "sent while the first frame is built")
        await model.loadVehicles()
        XCTAssertEqual(calls.withLock { $0 }, 1, "the root view's first load finds it already done")
        XCTAssertEqual(model.vehicles.map(\.id), [1, 2])
        await model.loadVehicles()
        XCTAssertEqual(calls.withLock { $0 }, 2, "later loads ask the server again")
    }

    /// The shell mounts from the saved list, so the dashboard's task and the
    /// root view's task may run in either order, before or after the answer.
    func testStartupSendsOneVehicleRequestWhicheverViewAsksFirst() async throws {
        for schedule in ["dashboard first", "root first", "after the answer"] {
            let calls = Mutex(0)
            let settings = settings()
            settings.selectedVehicleID = 2
            let model = try pairedModel(settings, saved: MemorySavedDashboards(savedDashboard(backend: pairedBackend))) {
                calls.withLock { $0 += 1 }; return vehiclesJSON()
            }
            XCTAssertEqual(model.vehicles.map(\.name), ["Tesla", "Saved Friday"], schedule)
            switch schedule {
            case "dashboard first":
                let start = model.takeInitialDashboardVehicles(vehicleID: 2)
                await model.loadVehicles()
                let list = await start?.vehicles?()
                XCTAssertEqual(list?.map(\.name), ["Tesla", "Friday"], schedule)
            case "root first":
                let root = Task { await model.loadVehicles() }
                let list = await model.takeInitialDashboardVehicles(vehicleID: 2)?.vehicles?()
                await root.value
                XCTAssertEqual(list?.map(\.name), ["Tesla", "Friday"], schedule)
            default:
                await waitUntil { model.hasLoadedVehicles }
                let list = await model.takeInitialDashboardVehicles(vehicleID: 2)?.vehicles?()
                await model.loadVehicles()
                XCTAssertEqual(list?.map(\.name), ["Tesla", "Friday"], schedule)
            }
            XCTAssertEqual(calls.withLock { $0 }, 1, schedule)
            await model.loadVehicles()
            XCTAssertEqual(calls.withLock { $0 }, 2, "\(schedule): later loads ask the server again")
        }
    }

    func testPrewarmedLaunchSendsNothingUntilTheAppIsOpened() async throws {
        let calls = Mutex(0)
        let settings = settings()
        settings.selectedVehicleID = 2
        let model = try pairedModel(settings, saved: MemorySavedDashboards(savedDashboard(backend: pairedBackend)),
                                    environment: ["ActivePrewarm": "1"]) { calls.withLock { $0 += 1 }; return vehiclesJSON() }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(calls.withLock { $0 }, 0, "a prewarmed process may be suspended for hours")
        XCTAssertEqual(model.vehicles.count, 2, "the saved list is local and still shown")
        let start = model.takeInitialDashboardVehicles(vehicleID: 2)
        XCTAssertNil(start?.prefetch)
        XCTAssertNotNil(start?.saved)
        await model.loadVehicles()
        _ = await start?.vehicles?()
        XCTAssertEqual(calls.withLock { $0 }, 1, "the opened app sends one request")
    }

    func testLockedLaunchSendsNoVehicleRequest() async throws {
        let calls = Mutex(0)
        let locked = settings()
        locked.appLockEnabled = true
        let model = try pairedModel(locked) { calls.withLock { $0 += 1 }; return vehiclesJSON() }
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertTrue(model.isLocked)
        XCTAssertEqual(calls.withLock { $0 }, 0)
    }

    /// A bounded wait for background requests, not a timing assertion.
    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(1)) }
    }

    func testLaunchPrefetchIsDiscardedOnBackgroundOrVehicleSwitch() throws {
        let settings = settings()
        settings.selectedVehicleID = 2
        let model = try pairedModel(settings, saved: MemorySavedDashboards(savedDashboard(backend: pairedBackend))) { vehiclesJSON() }
        model.didEnterBackground()
        XCTAssertNil(model.takeInitialDashboardVehicles(vehicleID: 2)?.prefetch)

        let switching = self.settings()
        switching.selectedVehicleID = 2
        let other = try pairedModel(switching, saved: MemorySavedDashboards(savedDashboard(backend: pairedBackend))) { vehiclesJSON() }
        other.selectedVehicleID = 1
        let start = other.takeInitialDashboardVehicles(vehicleID: 1)
        XCTAssertNil(start?.prefetch)
        XCTAssertNil(start?.saved)
    }

    func testTheSavedDashboardStoreFollowsTheSelectedCar() async throws {
        let saved = MemorySavedDashboards()
        let settings = settings()
        settings.selectedVehicleID = 2
        let model = try pairedModel(settings, saved: saved) { vehiclesJSON() }
        await model.loadVehicles()
        XCTAssertEqual(saved.acceptedVehicleID, 2)
        model.select(Vehicle(id: 1, name: "Tesla"))
        XCTAssertEqual(saved.acceptedVehicleID, 1, "a refresh for the previous car can no longer save")
    }

    func testUnpairAndDemoModeForgetTheSavedDashboard() throws {
        let saved = MemorySavedDashboards(savedDashboard(backend: pairedBackend))
        let model = try pairedModel(settings(), saved: saved) { vehiclesJSON() }
        XCTAssertEqual(saved.acceptedBackend, pairedBackend)
        model.unpair()
        XCTAssertNil(saved.dashboard)
        XCTAssertNil(saved.acceptedBackend, "a load that outlives the pairing saves nothing")

        let demoSaved = MemorySavedDashboards(savedDashboard(backend: pairedBackend))
        let demo = try pairedModel(settings(), saved: demoSaved) { vehiclesJSON() }
        demo.tryDemoMode()
        XCTAssertNil(demoSaved.dashboard)
        XCTAssertNil(demoSaved.acceptedBackend)
    }

    /// Settings as an earlier build left them: an id without the explicit flag.
    private func savedSettings(_ values: [String: Any]) -> UserSettings {
        let name = "VoltaSelectionTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        values.forEach { defaults.set($1, forKey: $0) }
        return UserSettings(defaults: defaults)
    }

    func testSelectionSavedBeforeTheFlagExistedIsKept() async throws {
        // Earlier builds saved automatic and manual choices alike; it may be the user's.
        let settings = savedSettings(["selectedVehicleID": 1])
        XCTAssertTrue(settings.selectedVehicleIsExplicit)
        let model = try pairedModel(settings) { vehiclesJSON() }
        await model.loadVehicles()
        XCTAssertEqual(model.selectedVehicleID, 1)
        XCTAssertEqual(model.selectedVehicle?.name, "Tesla")
    }

    func testSavedAutomaticChoiceMovesOffANoDataCar() async throws {
        let model = try pairedModel(savedSettings(["selectedVehicleID": 1, "selectedVehicleIsExplicit": false])) { vehiclesJSON() }
        await model.loadVehicles()
        XCTAssertEqual(model.selectedVehicleID, 2)
    }

    func testLegacySelectionOfARemovedCarFallsBackToOneWithData() async throws {
        let model = try pairedModel(savedSettings(["selectedVehicleID": 9])) { vehiclesJSON() }
        await model.loadVehicles()
        XCTAssertEqual(model.selectedVehicleID, 2)
    }

    func testExplicitNoDataChoiceSurvivesReloadAndRelaunch() async throws {
        let name = "VoltaSelectionTests.\(UUID())"
        let settings = settings(name)
        let model = try pairedModel(settings) { vehiclesJSON() }
        await model.loadVehicles()
        model.selectedVehicleID = 1
        await model.loadVehicles()
        XCTAssertEqual(model.selectedVehicleID, 1)
        let relaunched = try pairedModel(UserSettings(defaults: UserDefaults(suiteName: name)!)) { vehiclesJSON() }
        await relaunched.loadVehicles()
        XCTAssertEqual(relaunched.selectedVehicleID, 1, "an explicit choice is never replaced while the car exists")
    }

    func testAutomaticChoiceDoesNotHopWhenAnEarlierCarGainsData() async throws {
        let firstHasData = Mutex(false)
        let model = try pairedModel(settings()) { vehiclesJSON(firstHasData: firstHasData.withLock { $0 }) }
        await model.loadVehicles()
        XCTAssertEqual(model.selectedVehicleID, 2)
        firstHasData.withLock { $0 = true }
        await model.loadVehicles()
        XCTAssertEqual(model.selectedVehicleID, 2)
    }

    func testChoiceMadeWhileVehiclesLoadWins() async throws {
        let started = expectation(description: "vehicles requested")
        let release = DispatchSemaphore(value: 0)
        let model = try pairedModel(settings()) {
            started.fulfill(); release.wait()
            return vehiclesJSON()
        }
        let load = Task { await model.loadVehicles() }
        await fulfillment(of: [started], timeout: 5)
        model.selectedVehicleID = 1  // e.g. from More → Switch Vehicle on cached data
        release.signal()
        await load.value
        XCTAssertEqual(model.selectedVehicleID, 1)
    }

    func testRemovedExplicitVehicleFallsBackAndUnpairForgetsChoice() async throws {
        let settings = settings()
        let model = try pairedModel(settings) { vehiclesJSON() }
        model.selectedVehicleID = 9
        await model.loadVehicles()
        XCTAssertEqual(model.selectedVehicleID, 2); XCTAssertFalse(settings.selectedVehicleIsExplicit)
        model.selectedVehicleID = 1
        model.unpair()
        XCTAssertNil(settings.selectedVehicleID); XCTAssertFalse(settings.selectedVehicleIsExplicit)
    }

    func testTappingTheCheckedAutomaticCarInTheDashboardPickerKeepsIt() async throws {
        let name = "VoltaSelectionTests.\(UUID())"
        let secondHasData = Mutex(false)
        let vehicles: @Sendable () -> Data = {
            try! JSONSerialization.data(withJSONObject: [
                ["id": 1, "name": "Tesla", "hasData": false],
                ["id": 2, "name": "Friday", "hasData": secondHasData.withLock { $0 }],
            ])
        }
        let model = try pairedModel(settings(name), vehicles: vehicles)
        await model.loadVehicles()
        XCTAssertEqual(model.selectedVehicleID, 1); XCTAssertFalse(model.settings.selectedVehicleIsExplicit)

        // Dashboard → vehicle sheet → tap the row that's already checked.
        let sheet = VehicleInfoSheet(vehicles: model.vehicles, selectedID: model.selectedVehicleID,
                                     onSelect: DashboardView.selectVehicle(app: model, vehicles: model.vehicles))
        sheet.choose(1)
        XCTAssertTrue(model.settings.selectedVehicleIsExplicit, "the deliberate tap is saved")

        secondHasData.withLock { $0 = true }
        await model.loadVehicles()
        XCTAssertEqual(model.selectedVehicleID, 1)
        let relaunched = try pairedModel(UserSettings(defaults: UserDefaults(suiteName: name)!), vehicles: vehicles)
        await relaunched.loadVehicles()
        XCTAssertEqual(relaunched.selectedVehicleID, 1, "a car the user tapped never moves when another gains data")
    }

    func testSelectingACarMissingFromTheAppListAdoptsIt() async throws {
        let settings = settings()
        let model = try pairedModel(settings) { try! JSONSerialization.data(withJSONObject: [["id": 1, "name": "Tesla", "hasData": true]]) }
        await model.loadVehicles()
        model.select(Vehicle(id: 2, name: "Friday", hasData: true))
        XCTAssertEqual(model.vehicles.map(\.id), [1, 2])
        XCTAssertEqual(model.selectedVehicle?.name, "Friday")
        XCTAssertEqual(model.surfaceContext, .vehicle(id: 2, name: "Friday"))
        XCTAssertTrue(settings.selectedVehicleIsExplicit)
    }

    func testNoDataStatusShowsNoDataForTheSelectedCar() async {
        let model = DashboardModel()
        await model.load(dataSource: SelectionSource(statusError: .server(code: "data_unavailable", message: "none")), vehicleID: 2)
        XCTAssertEqual(model.phase, .noData)
        XCTAssertEqual(model.vehicle?.name, "Friday", "names the selected car, never the first one")
        XCTAssertEqual(model.vehicles.count, 2)

        let failed = DashboardModel()
        await failed.load(dataSource: SelectionSource(statusError: .transport("offline")), vehicleID: 2)
        XCTAssertEqual(failed.phase, .failed("offline"))
    }

    func testVehicleDetailMarksCarsWithoutData() {
        XCTAssertEqual(VehicleInfoSheet.detail(Vehicle(id: 1, name: "Tesla", hasData: false)), "No data yet")
        XCTAssertEqual(VehicleInfoSheet.detail(Vehicle(id: 2, name: "Friday", model: "Model Y", hasData: true)), "Model Y")
    }

    func testRangeLabelNamesTheRangeShown() {
        var status = VehicleStatus.skeleton
        status.estRangeKm = 300; status.ratedRangeKm = 328.52
        XCTAssertEqual(DashboardView.rangeDisplay(status).label, "Est. range")
        XCTAssertEqual(DashboardView.rangeDisplay(status).km, 300)
        status.estRangeKm = nil
        XCTAssertEqual(DashboardView.rangeDisplay(status).label, "Rated range")
        XCTAssertEqual(DashboardView.rangeDisplay(status).km, 328.52)
        status.ratedRangeKm = nil
        XCTAssertEqual(DashboardView.rangeDisplay(status).label, "Range")
        XCTAssertNil(DashboardView.rangeDisplay(status).km)
    }
}

@MainActor private final class NoSurfaces: VehicleSurfaces {
    func setContext(_ context: VehicleSurfaceContext) {}
    func publish(_ refresh: VehicleRefresh, dataSource: any VoltaDataSource) {}
    func drivingActivityPreferenceChanged() {}
    func nextStatusToken() -> StatusRequestToken { StatusRequestToken(value: 0) }
}

private struct SelectionSource: VoltaDataSource {
    var statusError: VoltaError
    func vehicles() async throws -> [Vehicle] {
        [Vehicle(id: 1, name: "Tesla", hasData: true), Vehicle(id: 2, name: "Friday", hasData: false)]
    }
    func status(vehicleID: Int) async throws -> VehicleStatus { throw statusError }
    func summary(vehicleID: Int, range: SummaryRange) async throws -> ActivitySummary { throw VoltaError.notFound }
    func timeline(vehicleID: Int, hours: Int) async throws -> [TimelineSegment] { [] }
    func drives(vehicleID: Int, range: DateRange, cursor: String?) async throws -> Page<DriveSummary> { throw VoltaError.notFound }
    func drive(id: Int) async throws -> DriveDetail { throw VoltaError.notFound }
    func charges(vehicleID: Int, range: DateRange, cursor: String?) async throws -> Page<ChargeSummary> { throw VoltaError.notFound }
    func charge(id: Int) async throws -> ChargeDetail { throw VoltaError.notFound }
    func idles(vehicleID: Int, range: DateRange, cursor: String?) async throws -> Page<IdleSummary> { throw VoltaError.notFound }
    func battery(vehicleID: Int) async throws -> BatteryHealth { throw VoltaError.notFound }
    func mileage(vehicleID: Int, bucket: MileageBucketSize) async throws -> [MileageBucket] { throw VoltaError.notFound }
    func firmware(vehicleID: Int) async throws -> [FirmwareUpdate] { throw VoltaError.notFound }
    func places(vehicleID: Int) async throws -> [Place] { throw VoltaError.notFound }
}
