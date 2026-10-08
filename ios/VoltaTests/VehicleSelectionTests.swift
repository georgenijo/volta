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
    private func pairedModel(_ settings: UserSettings, vehicles: @escaping @Sendable () -> Data) throws -> AppModel {
        StubProtocol.handler.withLock { $0 = { _ in (200, vehicles()) } }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        settings.serverURL = "https://volta.example"
        let store = SelectionTokenStore(); try store.save("synthetic-token")
        return AppModel(settings: settings, tokenStore: store, session: URLSession(configuration: config),
                        launchArguments: ["Volta"], surfaces: NoSurfaces())
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
    func command(vehicleID: Int, name: String, params: [String: String]) async throws { throw VoltaError.commandsUnavailable }
}
