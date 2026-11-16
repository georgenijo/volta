import XCTest
@testable import Volta

// Saved dashboard and launch-request tests. Kept apart from
// DashboardAndControlsTests so the dashboard redesign can change that file freely.

/// Data source whose dashboard calls are driven by per-test handlers.
private final class StubSource: VoltaDataSource, @unchecked Sendable {
    var vehiclesHandler: @Sendable () async throws -> [Vehicle] = { [Vehicle(id: 1, name: "Friday")] }
    var statusHandler: @Sendable () async throws -> VehicleStatus = { makeStatus() }
    var timelineHandler: @Sendable () async throws -> [TimelineSegment] = { [] }
    var summaryHandler: @Sendable (SummaryRange) async throws -> ActivitySummary = { makeSummary($0) }

    func vehicles() async throws -> [Vehicle] { try await vehiclesHandler() }
    func status(vehicleID: Int) async throws -> VehicleStatus { try await statusHandler() }
    func summary(vehicleID: Int, range: SummaryRange) async throws -> ActivitySummary { try await summaryHandler(range) }
    func timeline(vehicleID: Int, hours: Int) async throws -> [TimelineSegment] { try await timelineHandler() }
    func drives(vehicleID: Int, range: DateRange, cursor: String?) async throws -> Page<DriveSummary> { throw VoltaError.notFound }
    func drive(id: Int) async throws -> DriveDetail { throw VoltaError.notFound }
    func charges(vehicleID: Int, range: DateRange, cursor: String?) async throws -> Page<ChargeSummary> { throw VoltaError.notFound }
    func charge(id: Int) async throws -> ChargeDetail { throw VoltaError.notFound }
    func idles(vehicleID: Int, range: DateRange, cursor: String?) async throws -> Page<IdleSummary> { throw VoltaError.notFound }
    func battery(vehicleID: Int) async throws -> BatteryHealth { throw VoltaError.notFound }
    func mileage(vehicleID: Int, bucket: MileageBucketSize) async throws -> [MileageBucket] { throw VoltaError.notFound }
    func firmware(vehicleID: Int) async throws -> [FirmwareUpdate] { throw VoltaError.notFound }
    func places(vehicleID: Int) async throws -> [Place] { throw VoltaError.notFound }
    var commandBackendID: String { "stub-backend" }
    func commandCapabilities(vehicleID: Int) async throws -> VehicleCommandCapabilities {
        VehicleCommandCapabilities(available: false, reason: nil, commands: [])
    }
    func command(vehicleID: Int, command: VehicleCommand, intentID: UUID) async throws -> VehicleCommandResult {
        throw VoltaError.notFound
    }
}

private actor Counter {
    private(set) var value = 0
    func next() -> Int { value += 1; return value }
}

private actor SectionGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var opened = false
    func wait() async {
        if opened { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        opened = true
        let pending = waiters; waiters = []
        for waiter in pending { waiter.resume() }
    }
}

private func makeStatus(battery: Int = 72) -> VehicleStatus {
    VehicleStatus(vehicleId: 1, state: .online, updatedAt: .now, batteryLevel: battery, usableBatteryLevel: nil,
                  ratedRangeKm: 300, estRangeKm: 300, chargeLimit: 80, chargingState: .disconnected,
                  chargerPowerKw: nil, minutesToFull: nil, insideTempC: 20, outsideTempC: 15, climateOn: false,
                  driverTempSettingC: nil, locked: true, sentryMode: false, odometerKm: nil, location: nil,
                  firmware: nil)
}

private func makeSummary(_ range: SummaryRange, km: Double = 10) -> ActivitySummary {
    ActivitySummary(range: range, distanceKm: km, driveCount: 1, chargeCount: 0, energyUsedKwh: nil,
                    efficiencyWhPerKm: 160, energyAddedKwh: nil, chargeCost: nil, currency: nil)
}

private let segment = TimelineSegment(kind: .drive, start: .now.addingTimeInterval(-3600), end: .now)

@MainActor final class SavedDashboardTests: XCTestCase {
    /// A bounded wait for cooperative child tasks, not a timing assertion.
    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    func testSavedFreshnessLabelNamesWhenItWasSaved() {
        var freshness = TelemetryFreshness(connected: true, lastSeenAt: .now, recordedAt: [:])
        XCTAssertEqual(freshness.label, "Telemetry connected")
        freshness.savedAt = .now.addingTimeInterval(-300)
        XCTAssertTrue(freshness.label.hasPrefix("Saved data from"))
        let encoded = try? JSONEncoder().encode(freshness)
        let decoded = encoded.flatMap { try? JSONDecoder().decode(TelemetryFreshness.self, from: $0) }
        XCTAssertNil(decoded?.savedAt, "the saved marker is local only and never persisted or decoded")
    }

    private func saved(battery: Int = 41, backend: String = "backend-a", vehicleID: Int = 1) -> SavedDashboard {
        var status = makeStatus(battery: battery)
        status.vehicleId = vehicleID
        return SavedDashboard(backend: backend, vehicleID: vehicleID, savedAt: .now.addingTimeInterval(-600),
                              vehicles: [Vehicle(id: vehicleID, name: "Saved")], status: status,
                              timeline: [segment], summaries: [makeSummary(.sevenDays, km: 70), makeSummary(.thirtyDays, km: 300)],
                              todayRequestedAt: nil, todayRequestedZone: nil)
    }

    func testSavedDashboardShowsLabelledWhileFreshStatusIsSuspended() async {
        let source = StubSource(), gate = SectionGate(), model = DashboardModel()
        source.statusHandler = { await gate.wait(); return makeStatus(battery: 90) }
        let start = DashboardStart(saved: saved())
        let task = Task { await model.load(dataSource: source, vehicleID: 1, initialVehicles: start) }
        await waitUntil { model.status != nil }

        XCTAssertEqual(model.phase, .loaded)
        XCTAssertTrue(model.showsSavedStatus)
        XCTAssertEqual(model.status?.batteryLevel, 41)
        XCTAssertEqual(model.vehicle?.name, "Saved")
        XCTAssertEqual(model.summaries[.thirtyDays]?.distanceKm, 300)
        XCTAssertEqual(model.timeline.count, 1)
        XCTAssertTrue(model.status?.telemetryFreshness?.label.hasPrefix("Saved data from") == true,
                      "saved status is labelled, never shown as live")

        await gate.open()
        await task.value
        XCTAssertFalse(model.showsSavedStatus)
        XCTAssertEqual(model.status?.batteryLevel, 90)
        XCTAssertNil(model.status?.telemetryFreshness?.savedAt)
        XCTAssertEqual(model.summaries[.thirtyDays]?.distanceKm, 10, "fresh history replaces saved history")
    }

    func testSavedDashboardStaysWithRefreshErrorWhenStatusFails() async {
        let source = StubSource(), model = DashboardModel()
        source.statusHandler = { throw VoltaError.unreachable("offline") }
        await model.load(dataSource: source, vehicleID: 1, initialVehicles: DashboardStart(saved: saved()))
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.status?.batteryLevel, 41)
        XCTAssertNotNil(model.refreshError, "the banner says the shown data could not be refreshed")
    }

    func testSavedDashboardForAnotherVehicleIsNotShown() async {
        let source = StubSource(), gate = SectionGate(), model = DashboardModel()
        source.statusHandler = { await gate.wait(); return makeStatus() }
        let task = Task { await model.load(dataSource: source, vehicleID: 1, initialVehicles: DashboardStart(saved: saved(vehicleID: 2))) }
        await Task.yield()
        XCTAssertNil(model.status)
        XCTAssertEqual(model.phase, .loading)
        await gate.open()
        await task.value
    }

    func testFreshLoadsAreSavedForTheAcceptedBackendOnly() async {
        let source = StubSource(), store = MemorySavedDashboards(), model = DashboardModel()
        store.acceptedBackend = "backend-a"
        source.timelineHandler = { [segment] }
        await model.load(dataSource: source, vehicleID: 1,
                         initialVehicles: DashboardStart(store: store, backend: "backend-a"))
        XCTAssertEqual(store.dashboard?.status.batteryLevel, 72)
        XCTAssertEqual(store.dashboard?.vehicles.map(\.name), ["Friday"])
        XCTAssertEqual(store.dashboard?.summaries.count, 3)
        XCTAssertEqual(store.dashboard?.timeline.count, 1)
        XCTAssertNotNil(store.dashboard?.today, "today's reporting day can be recomputed on relaunch")

        // A later refresh on the same model keeps saving.
        source.statusHandler = { makeStatus(battery: 50) }
        await model.load(dataSource: source, vehicleID: 1)
        XCTAssertEqual(store.dashboard?.status.batteryLevel, 50)

        // After unpairing the store accepts nothing, so a late load cannot save.
        store.remove(); store.acceptedBackend = nil
        await model.load(dataSource: source, vehicleID: 1)
        XCTAssertNil(store.dashboard)
    }

    func testFailedStatusIsNotSaved() async {
        let source = StubSource(), store = MemorySavedDashboards(), model = DashboardModel()
        store.acceptedBackend = "backend-a"
        source.statusHandler = { throw VoltaError.unreachable("offline") }
        await model.load(dataSource: source, vehicleID: 1, initialVehicles: DashboardStart(store: store, backend: "backend-a"))
        XCTAssertNil(store.dashboard)
    }

    func testSavedTodayTotalIsHiddenOnceItsDayHasEnded() async {
        let source = StubSource(), gate = SectionGate(), model = DashboardModel()
        source.statusHandler = { await gate.wait(); return makeStatus() }
        var old = saved()
        var today = makeSummary(.today, km: 12)
        today.periodStart = .now.addingTimeInterval(-3 * 86_400); today.timeZone = TimeZone.current.identifier
        old.summaries.append(today)
        old.todayRequestedAt = .now.addingTimeInterval(-2.5 * 86_400); old.todayRequestedZone = TimeZone.current.identifier
        let task = Task { await model.load(dataSource: source, vehicleID: 1, initialVehicles: DashboardStart(saved: old)) }
        await waitUntil { model.status != nil }
        XCTAssertNil(model.visibleSummaries(at: .now)[.today], "yesterday's totals never show as Today")
        await gate.open()
        await task.value
    }

    func testLaunchPrefetchReplacesTheFirstLoadsRequests() async {
        let source = StubSource(), statusCalls = Counter(), summaryCalls = Counter(), model = DashboardModel()
        source.statusHandler = { _ = await statusCalls.next(); return makeStatus(battery: 66) }
        source.summaryHandler = { range in _ = await summaryCalls.next(); return makeSummary(range) }
        let prefetch = DashboardPrefetch(dataSource: source, vehicleID: 1, surfaces: nil)
        await model.load(dataSource: source, vehicleID: 1, initialVehicles: DashboardStart(prefetch: prefetch))
        let statuses = await statusCalls.value, summaries = await summaryCalls.value
        XCTAssertEqual(statuses, 1, "the dashboard awaits the launch request instead of sending another")
        XCTAssertEqual(summaries, 3, "history is requested by the dashboard")
        XCTAssertEqual(model.status?.batteryLevel, 66)
        XCTAssertEqual(model.summaries.count, 3)

        await model.load(dataSource: source, vehicleID: 1, initialVehicles: DashboardStart(prefetch: prefetch))
        let refreshed = await statusCalls.value
        XCTAssertEqual(refreshed, 2, "a loaded dashboard never reuses launch responses")
    }

    func testLaunchPrefetchForAnotherVehicleIsCancelledAndNotShown() async {
        let source = StubSource(), gate = SectionGate(), model = DashboardModel()
        let other = StubSource()
        other.statusHandler = { await gate.wait(); return makeStatus(battery: 5) }
        let prefetch = DashboardPrefetch(dataSource: other, vehicleID: 2, surfaces: nil)
        await model.load(dataSource: source, vehicleID: 1, initialVehicles: DashboardStart(prefetch: prefetch))
        XCTAssertEqual(model.status?.batteryLevel, 72)
        XCTAssertTrue(prefetch.status.isCancelled)
        await gate.open()
    }

    func testSavedDashboardRoundTripsThroughTheFile() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "saved-dashboard-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let file = SavedDashboardFile(url: url)
        file.write(saved(backend: "backend-a"))
        await file.drain()
        XCTAssertNil(file.read(backend: "backend-a"), "nothing is written until a backend is accepted")
        file.acceptedBackend = "backend-a"
        file.write(saved(backend: "backend-a"))
        await file.drain()
        XCTAssertEqual(file.read(backend: "backend-a")?.status.batteryLevel, 41)
        XCTAssertNil(file.read(backend: "backend-b"), "another server or device token never sees it")
        file.remove()
        XCTAssertNil(file.read(backend: "backend-a"))
        await file.drain()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }
}
