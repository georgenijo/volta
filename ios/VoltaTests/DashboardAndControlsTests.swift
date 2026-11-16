import XCTest
@testable import Volta

// MARK: - Test doubles

/// Data source whose dashboard calls are driven by per-test handlers.
private final class StubSource: VoltaDataSource, @unchecked Sendable {
    var vehiclesHandler: @Sendable () async throws -> [Vehicle] = { [Vehicle(id: 1, name: "Friday")] }
    var statusHandler: @Sendable () async throws -> VehicleStatus = { makeStatus() }
    var timelineHandler: @Sendable () async throws -> [TimelineSegment] = { [] }
    var summaryHandler: @Sendable (SummaryRange) async throws -> ActivitySummary = { makeSummary($0) }
    var capability = VehicleCommandCapabilities(available: true, reason: nil,
                                                commands: Array(VehicleCommand.supportedNames))
    var backendID = "stub-backend"
    var commandHandler: @Sendable (VehicleCommand, UUID) async throws -> VehicleCommandResult = { command, _ in
        VehicleCommandResult(command: command.name, requestID: "request-1", replayed: false)
    }
    let commands = Recorder()

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
    var commandBackendID: String { backendID }
    func commandCapabilities(vehicleID: Int) async throws -> VehicleCommandCapabilities { capability }
    func command(vehicleID: Int, command: VehicleCommand, intentID: UUID) async throws -> VehicleCommandResult {
        await commands.append(command.name, intentID: intentID)
        return try await commandHandler(command, intentID)
    }
}

private actor Recorder {
    struct Entry: Equatable { var name: String; var intentID: UUID }
    private(set) var entries: [Entry] = []
    var names: [String] { entries.map(\.name) }
    func append(_ name: String, intentID: UUID) { entries.append(Entry(name: name, intentID: intentID)) }
    func snapshot() -> [Entry] { entries }
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

private struct Boom: Error {}

private func makeStatus(battery: Int = 72, locked: Bool? = true, climateOn: Bool? = false,
                        sentry: Bool? = false, chargeLimit: Int? = 80,
                        chargingState: ChargingState? = .disconnected) -> VehicleStatus {
    VehicleStatus(vehicleId: 1, state: .online, updatedAt: .now, batteryLevel: battery, usableBatteryLevel: nil,
                  ratedRangeKm: 300, estRangeKm: 300, chargeLimit: chargeLimit, chargingState: chargingState,
                  chargerPowerKw: nil, minutesToFull: nil, insideTempC: 20, outsideTempC: 15, climateOn: climateOn,
                  driverTempSettingC: nil, locked: locked, sentryMode: sentry, odometerKm: nil, location: nil,
                  firmware: nil)
}

private func makeSummary(_ range: SummaryRange, km: Double = 10) -> ActivitySummary {
    ActivitySummary(range: range, distanceKm: km, driveCount: 1, chargeCount: 0, energyUsedKwh: nil,
                    efficiencyWhPerKm: 160, energyAddedKwh: nil, chargeCost: nil, currency: nil)
}

private let segment = TimelineSegment(kind: .drive, start: .now.addingTimeInterval(-3600), end: .now)

// MARK: - Dashboard

@MainActor final class DashboardModelTests: XCTestCase {
    /// A bounded wait for cooperative child tasks, not a timing assertion.
    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
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
        XCTAssertEqual(summaries, 3)
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

    func testInitialPreloadedVehiclesAvoidDuplicateVehicleRequest() async {
        let source = StubSource(), calls = Counter(), model = DashboardModel()
        source.vehiclesHandler = {
            _ = await calls.next()
            return [Vehicle(id: 1, name: "Fetched")]
        }
        let preloaded = [Vehicle(id: 1, name: "Preloaded"), Vehicle(id: 2, name: "Second")]

        await model.load(dataSource: source, vehicleID: 1, initialVehicles: preloaded)

        let vehicleCalls = await calls.value
        XCTAssertEqual(vehicleCalls, 0)
        XCTAssertEqual(model.vehicles.map(\.name), ["Preloaded", "Second"])
        XCTAssertEqual(model.vehicle?.name, "Preloaded")
        XCTAssertEqual(model.status?.batteryLevel, 72)
    }

    func testInvalidPreloadedVehiclesFallBackToFreshListForStatusErrorContext() async {
        let source = StubSource(), calls = Counter(), model = DashboardModel()
        source.vehiclesHandler = {
            _ = await calls.next()
            return [Vehicle(id: 2, name: "Friday")]
        }
        source.statusHandler = { throw VoltaError.server(code: "data_unavailable", message: "none") }

        await model.load(dataSource: source, vehicleID: 2,
                         initialVehicles: [Vehicle(id: 1, name: "Wrong vehicle")])

        let vehicleCalls = await calls.value
        XCTAssertEqual(vehicleCalls, 1)
        XCTAssertEqual(model.phase, .noData)
        XCTAssertEqual(model.vehicle?.name, "Friday")
    }

    func testFreshStatusIsNotHeldBySuspendedVehicleListRefresh() async {
        let source = StubSource(), gate = SectionGate(), model = DashboardModel()
        source.vehiclesHandler = {
            await gate.wait()
            return [Vehicle(id: 1, name: "Refreshed")]
        }
        let task = Task { await model.load(dataSource: source, vehicleID: 1) }

        await waitUntil { model.status != nil }

        XCTAssertEqual(model.status?.batteryLevel, 72)
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertNil(model.vehicle, "the suspended list has not published yet")

        await gate.open()
        await task.value
        XCTAssertEqual(model.vehicle?.name, "Refreshed")
    }

    func testVehicleRequestCancellationStillLoadsIndependentHistory() async {
        let source = StubSource(), model = DashboardModel()
        source.vehiclesHandler = { throw URLError(.cancelled) }
        source.timelineHandler = { [segment] }
        await model.load(dataSource: source, vehicleID: 1)
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.status?.batteryLevel, 72)
        XCTAssertEqual(model.timeline.count, 1)
        XCTAssertEqual(model.summaries.count, 3)
        XCTAssertTrue(model.loadingSections.isEmpty)
        XCTAssertTrue(model.failedSections.isEmpty)
    }

    func testAnAlreadyLoadedDashboardIgnoresAnotherSeed() async {
        let source = StubSource(), calls = Counter(), model = DashboardModel()
        source.vehiclesHandler = {
            _ = await calls.next()
            return [Vehicle(id: 1, name: "Current")]
        }
        let seed = [Vehicle(id: 1, name: "Old")]
        await model.load(dataSource: source, vehicleID: 1, initialVehicles: seed)
        await model.load(dataSource: source, vehicleID: 1, initialVehicles: seed)
        let vehicleCalls = await calls.value
        XCTAssertEqual(vehicleCalls, 1)
        XCTAssertEqual(model.vehicle?.name, "Current")
    }

    func testExplicitRefreshStillFetchesAndUpdatesVehicleListAfterInitialSeed() async {
        let source = StubSource(), calls = Counter(), model = DashboardModel()
        source.vehiclesHandler = {
            _ = await calls.next()
            return [Vehicle(id: 1, name: "Renamed"), Vehicle(id: 2, name: "Second")]
        }
        await model.load(dataSource: source, vehicleID: 1,
                         initialVehicles: [Vehicle(id: 1, name: "Preloaded")])

        await model.load(dataSource: source, vehicleID: 1)

        let vehicleCalls = await calls.value
        XCTAssertEqual(vehicleCalls, 1)
        XCTAssertEqual(model.vehicles.map(\.name), ["Renamed", "Second"])
        XCTAssertEqual(model.vehicle?.name, "Renamed")
    }

    func testCancelledRefreshCannotPublishLateVehicleListOrHistory() async {
        let source = StubSource(), gate = SectionGate(), model = DashboardModel()
        await model.load(dataSource: source, vehicleID: 1,
                         initialVehicles: [Vehicle(id: 1, name: "Preloaded")])
        source.statusHandler = { makeStatus(battery: 55) }
        source.vehiclesHandler = {
            await gate.wait()
            return [Vehicle(id: 1, name: "Late")]
        }
        source.summaryHandler = { makeSummary($0, km: 99) }
        let task = Task { await model.load(dataSource: source, vehicleID: 1) }
        await waitUntil { model.status?.batteryLevel == 55 }

        task.cancel()
        await gate.open()
        await task.value

        XCTAssertEqual(model.status?.batteryLevel, 55, "status published before cancellation remains usable")
        XCTAssertEqual(model.vehicle?.name, "Preloaded")
        XCTAssertEqual(model.summaries[.today]?.distanceKm, 10, "buffered history must not publish after cancellation")
        XCTAssertTrue(model.loadingSections.isEmpty)
    }

    func testSupersededRefreshCannotPublishLateVehicleList() async {
        let old = StubSource(), gate = SectionGate(), model = DashboardModel()
        await model.load(dataSource: old, vehicleID: 1,
                         initialVehicles: [Vehicle(id: 1, name: "Preloaded")])
        old.statusHandler = { makeStatus(battery: 40) }
        old.vehiclesHandler = {
            await gate.wait()
            return [Vehicle(id: 1, name: "Stale")]
        }
        let first = Task { await model.load(dataSource: old, vehicleID: 1) }
        await waitUntil { model.status?.batteryLevel == 40 }

        let newer = StubSource()
        newer.statusHandler = { makeStatus(battery: 90) }
        newer.vehiclesHandler = { [Vehicle(id: 1, name: "Newest")] }
        await model.load(dataSource: newer, vehicleID: 1)
        await gate.open()
        await first.value

        XCTAssertEqual(model.status?.batteryLevel, 90)
        XCTAssertEqual(model.vehicle?.name, "Newest")
        XCTAssertEqual(model.vehicles.map(\.name), ["Newest"])
    }

    func testStatusBecomesUsableWhileAllHistoryRequestsAreSuspended() async {
        let source = StubSource(), gate = SectionGate(), model = DashboardModel()
        source.timelineHandler = { await gate.wait(); return [segment] }
        source.summaryHandler = { range in await gate.wait(); return makeSummary(range) }
        let task = Task { await model.load(dataSource: source, vehicleID: 1) }
        await waitUntil { model.status != nil }
        XCTAssertEqual(model.status?.batteryLevel, 72)
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertEqual(model.loadingSections, [.timeline, .summary(.today), .summary(.sevenDays), .summary(.thirtyDays)])
        XCTAssertTrue(model.summaries.isEmpty)
        XCTAssertTrue(model.failedSections.isEmpty)
        await gate.open()
        await task.value
        XCTAssertEqual(model.timeline.count, 1)
        XCTAssertEqual(model.summaries.count, 3)
        XCTAssertTrue(model.loadingSections.isEmpty)
    }

    func testFastHistorySectionsDoNotWaitForTheMonthSummary() async {
        let source = StubSource(), gate = SectionGate(), model = DashboardModel()
        source.timelineHandler = { [segment] }
        source.summaryHandler = { range in
            if range == .thirtyDays { await gate.wait() }
            return makeSummary(range)
        }
        let task = Task { await model.load(dataSource: source, vehicleID: 1) }
        await waitUntil { model.summaries.count == 2 && !model.timeline.isEmpty }
        XCTAssertEqual(model.phase, .loaded)
        XCTAssertNotNil(model.summaries[.today])
        XCTAssertNotNil(model.summaries[.sevenDays])
        XCTAssertEqual(model.timeline.count, 1)
        XCTAssertNil(model.summaries[.thirtyDays])
        XCTAssertEqual(model.loadingSections, [.summary(.thirtyDays)])
        await gate.open()
        await task.value
        XCTAssertNotNil(model.summaries[.thirtyDays])
    }

    func testOldHistoryCannotReplaceNewLoadAfterStatusWasPublished() async {
        let source = StubSource(), gate = SectionGate(), model = DashboardModel()
        source.summaryHandler = { range in await gate.wait(); return makeSummary(range, km: 5) }
        let first = Task { await model.load(dataSource: source, vehicleID: 1) }
        await waitUntil { model.status != nil }
        let newer = StubSource()
        newer.statusHandler = { makeStatus(battery: 90) }
        newer.summaryHandler = { makeSummary($0, km: 40) }
        await model.load(dataSource: newer, vehicleID: 1)
        await gate.open()
        await first.value
        XCTAssertEqual(model.status?.batteryLevel, 90)
        XCTAssertEqual(model.summaries[.today]?.distanceKm, 40)
        XCTAssertTrue(model.loadingSections.isEmpty)
    }

    func testCancellingAfterStatusKeepsItAndDoesNotPublishLateHistory() async {
        let source = StubSource(), gate = SectionGate(), model = DashboardModel()
        source.summaryHandler = { range in await gate.wait(); return makeSummary(range) }
        let task = Task { await model.load(dataSource: source, vehicleID: 1) }
        await waitUntil { model.status != nil }
        task.cancel()
        await gate.open()
        await task.value
        XCTAssertEqual(model.status?.batteryLevel, 72)
        XCTAssertTrue(model.summaries.isEmpty)
        XCTAssertTrue(model.failedSections.isEmpty)
        XCTAssertTrue(model.loadingSections.isEmpty)
    }

    func testEfficiencyCardSaysNoDrivesOnlyForALoadedEmptySummary() {
        XCTAssertEqual(DashboardView.efficiencyDetail(nil, loading: true), "Loading 30-day average…")
        XCTAssertEqual(DashboardView.efficiencyDetail(makeSummary(.thirtyDays), loading: true), "30-day average")
        XCTAssertEqual(DashboardView.efficiencyDetail(nil), "Unavailable", "Missing or failed summary is not 'no drives'")
        var empty = makeSummary(.thirtyDays, km: 0); empty.driveCount = 0; empty.efficiencyWhPerKm = nil
        XCTAssertEqual(DashboardView.efficiencyDetail(empty), "No drives in 30 days")
        var unmeasured = makeSummary(.thirtyDays); unmeasured.efficiencyWhPerKm = nil
        XCTAssertEqual(DashboardView.efficiencyDetail(unmeasured), "Unavailable", "Drives without recorded energy are not 'no drives'")
        XCTAssertEqual(DashboardView.efficiencyDetail(makeSummary(.thirtyDays)), "30-day average")
    }

    func testOlderOverlappingLoadDoesNotOverwriteNewerData() async {
        let source = StubSource()
        let calls = Counter()
        let (gate, opener) = AsyncStream<Void>.makeStream()
        source.statusHandler = {
            if await calls.next() == 1 {
                for await _ in gate { break }
                return makeStatus(battery: 10)
            }
            return makeStatus(battery: 90)
        }
        let model = DashboardModel()
        let first = Task { await model.load(dataSource: source, vehicleID: 1) }
        while await calls.value < 1 { await Task.yield() }

        await model.load(dataSource: source, vehicleID: 1)
        XCTAssertEqual(model.status?.batteryLevel, 90)

        opener.yield(())
        await first.value
        XCTAssertEqual(model.status?.batteryLevel, 90, "stale load must not publish")
        XCTAssertEqual(model.phase, .loaded)
    }

    func testOlderOverlappingFailureIsNotPublished() async {
        let source = StubSource()
        let calls = Counter()
        let (gate, opener) = AsyncStream<Void>.makeStream()
        source.statusHandler = {
            if await calls.next() == 1 {
                for await _ in gate { break }
                throw Boom()
            }
            return makeStatus(battery: 90)
        }
        let model = DashboardModel()
        let first = Task { await model.load(dataSource: source, vehicleID: 1) }
        while await calls.value < 1 { await Task.yield() }
        await model.load(dataSource: source, vehicleID: 1)
        opener.yield(())
        await first.value
        XCTAssertNil(model.refreshError)
        XCTAssertEqual(model.phase, .loaded)
    }

    func testCancelledLoadPublishesNothing() async {
        let source = StubSource()
        let started = Counter()
        let (gate, opener) = AsyncStream<Void>.makeStream()
        source.statusHandler = {
            _ = await started.next()
            for await _ in gate { break }
            return makeStatus()
        }
        let model = DashboardModel()
        let task = Task { await model.load(dataSource: source, vehicleID: 1) }
        while await started.value < 1 { await Task.yield() }
        task.cancel()
        opener.yield(())
        await task.value
        XCTAssertNil(model.status)
        XCTAssertEqual(model.phase, .loading)
    }

    func testCancellationOfASectionDoesNotDiscardFreshStatus() async {
        let source = StubSource()
        let model = DashboardModel()
        await model.load(dataSource: source, vehicleID: 1)
        source.statusHandler = { makeStatus(battery: 50) }
        source.timelineHandler = { throw CancellationError() }
        await model.load(dataSource: source, vehicleID: 1)
        XCTAssertEqual(model.status?.batteryLevel, 50, "independent section cancellation cannot roll back fresh status")
        XCTAssertEqual(model.failedSections, [.timeline], "a cancelled section isn't a successful empty result")
    }

    func testIndependentlyCancelledInitialSectionsAreUnavailable() async {
        let source = StubSource(), model = DashboardModel()
        source.timelineHandler = { throw URLError(.cancelled) }
        source.summaryHandler = { range in
            if range == .sevenDays { throw CancellationError() }
            return makeSummary(range)
        }
        await model.load(dataSource: source, vehicleID: 1)
        XCTAssertEqual(model.status?.batteryLevel, 72)
        XCTAssertEqual(model.failedSections, [.timeline, .summary(.sevenDays)])
        XCTAssertTrue(model.loadingSections.isEmpty)
        XCTAssertNotNil(model.summaries[.today])
    }

    func testPartialFailureKeepsPreviousSectionDataAndReportsIt() async {
        let source = StubSource()
        source.timelineHandler = { [segment] }
        let model = DashboardModel()
        await model.load(dataSource: source, vehicleID: 1)
        XCTAssertEqual(model.timeline.count, 1)
        XCTAssertEqual(model.summaries[.sevenDays]?.distanceKm, 10)
        XCTAssertNil(model.partialFailureMessage)

        source.statusHandler = { makeStatus(battery: 60) }
        source.timelineHandler = { throw Boom() }
        source.summaryHandler = { range in
            if range == .sevenDays { throw Boom() }
            return makeSummary(range, km: 25)
        }
        await model.load(dataSource: source, vehicleID: 1)

        XCTAssertEqual(model.status?.batteryLevel, 60)
        XCTAssertEqual(model.timeline.count, 1, "failed timeline keeps previous data")
        XCTAssertEqual(model.summaries[.sevenDays]?.distanceKm, 10, "failed summary keeps previous data")
        XCTAssertEqual(model.summaries[.today]?.distanceKm, 25)
        XCTAssertEqual(model.failedSections, [.timeline, .summary(.sevenDays)])
        XCTAssertTrue(model.timelineFailed)
        XCTAssertTrue(model.summaryFailed(.sevenDays))
        XCTAssertEqual(model.partialFailureMessage, "Couldn't load 48h timeline, 7D activity.")
        XCTAssertNil(model.refreshError)

        source.timelineHandler = { [] }
        source.summaryHandler = { makeSummary($0) }
        await model.load(dataSource: source, vehicleID: 1)
        XCTAssertTrue(model.failedSections.isEmpty)
        XCTAssertTrue(model.timeline.isEmpty, "a successful empty timeline replaces old data")
    }

    func testTodayUsesTheServerReportedDay() async throws {
        var newYork = Calendar(identifier: .gregorian)
        newYork.timeZone = try XCTUnwrap(TimeZone(identifier: "America/New_York"))
        let source = StubSource()
        let localStart = newYork.startOfDay(for: .now)
        source.summaryHandler = { range in
            var summary = makeSummary(range, km: range == .today ? 25 : 10)
            summary.periodStart = range == .today ? localStart : nil
            summary.timeZone = "America/New_York"
            return summary
        }
        let model = DashboardModel()
        await model.load(dataSource: source, vehicleID: 1)
        let day = try XCTUnwrap(model.todayDay?.interval)
        XCTAssertEqual(day.start, localStart)
        XCTAssertEqual(day.end, newYork.startOfDay(for: try XCTUnwrap(newYork.date(byAdding: .day, value: 1, to: localStart))))
        XCTAssertEqual(model.visibleSummaries(at: .now)[.today]?.distanceKm, 25)
        XCTAssertNil(model.visibleSummaries(at: day.end)[.today], "local midnight ends Today")
        XCTAssertEqual(model.visibleSummaries(at: day.end)[.sevenDays]?.distanceKm, 10)

        // Totals for a day that already ended are not published as Today.
        let stale = try XCTUnwrap(newYork.date(byAdding: .day, value: -2, to: localStart))
        source.summaryHandler = { range in
            var summary = makeSummary(range, km: 40)
            summary.periodStart = range == .today ? stale : nil
            summary.timeZone = "America/New_York"
            return summary
        }
        await model.load(dataSource: source, vehicleID: 1)
        XCTAssertNil(model.summaries[.today])
        XCTAssertNil(model.todayDay)
        XCTAssertFalse(model.summaryFailed(.today))
        XCTAssertEqual(model.visibleSummaries(at: .now)[.thirtyDays]?.distanceKm, 40)
    }

    func testZoneChangeHidesTodayUntilRefreshedInTheNewZone() async throws {
        let here = TimeZone.current.identifier
        let elsewhere = here == "America/New_York" ? "America/Los_Angeles" : "America/New_York"
        let source = StubSource()
        let localStart = Calendar.current.startOfDay(for: .now)
        source.summaryHandler = { range in
            var summary = makeSummary(range, km: range == .today ? 25 : 10)
            summary.periodStart = range == .today ? localStart : nil
            summary.timeZone = here
            return summary
        }
        let model = DashboardModel()
        await model.load(dataSource: source, vehicleID: 1)
        XCTAssertEqual(model.todayDay?.zone, here)
        XCTAssertEqual(model.visibleSummaries(at: .now)[.today]?.distanceKm, 25)

        model.deviceZoneChanged(to: elsewhere)
        XCTAssertNil(model.visibleSummaries(at: .now)[.today], "computed for another zone: unknown")
        XCTAssertEqual(model.visibleSummaries(at: .now)[.sevenDays]?.distanceKm, 10)
        XCTAssertNotNil(model.summaries[.today], "kept until the refresh replaces it")

        // The refresh (in the device's actual zone) shows Today again.
        await model.load(dataSource: source, vehicleID: 1)
        XCTAssertEqual(model.deviceZone, here)
        XCTAssertEqual(model.visibleSummaries(at: .now)[.today]?.distanceKm, 25)

        // Old-server (UTC) days ignore the device zone.
        let utcModel = DashboardModel()
        await utcModel.load(dataSource: StubSource(), vehicleID: 1)
        XCTAssertNil(utcModel.todayDay?.zone)
        utcModel.deviceZoneChanged(to: elsewhere)
        XCTAssertNotNil(utcModel.visibleSummaries(at: .now)[.today])
    }

    func testOldServerTodayUsesUTCDay() async throws {
        let model = DashboardModel()
        await model.load(dataSource: StubSource(), vehicleID: 1)
        let day = try XCTUnwrap(model.todayDay?.interval)
        XCTAssertEqual(day.duration, 86_400)
        XCTAssertEqual(day.start, ReportingDay.utcCalendar.startOfDay(for: day.start))
        XCTAssertNotNil(model.visibleSummaries(at: day.end.addingTimeInterval(-1))[.today])
        XCTAssertNil(model.visibleSummaries(at: day.end)[.today])
    }

    func testFailedIsDistinctFromEmpty() async {
        let failing = StubSource()
        failing.timelineHandler = { throw Boom() }
        failing.summaryHandler = { _ in throw Boom() }
        let failed = DashboardModel()
        await failed.load(dataSource: failing, vehicleID: 1)
        XCTAssertTrue(failed.timeline.isEmpty)
        XCTAssertTrue(failed.timelineFailed)
        XCTAssertTrue(SummaryRange.allCases.allSatisfy(failed.summaryFailed))

        let empty = DashboardModel()
        await empty.load(dataSource: StubSource(), vehicleID: 1)
        XCTAssertTrue(empty.timeline.isEmpty)
        XCTAssertFalse(empty.timelineFailed)
        XCTAssertNil(empty.partialFailureMessage)
    }

    func testStatusFailureKeepsDataAndSetsRefreshError() async {
        let source = StubSource()
        source.timelineHandler = { [segment] }
        let model = DashboardModel()
        await model.load(dataSource: source, vehicleID: 1)
        source.statusHandler = { throw VoltaError.transport("offline") }
        source.timelineHandler = { [] }
        await model.load(dataSource: source, vehicleID: 1)
        XCTAssertEqual(model.status?.batteryLevel, 72)
        XCTAssertEqual(model.timeline.count, 1)
        XCTAssertNotNil(model.refreshError)
        XCTAssertEqual(model.phase, .loaded)
    }

    func testInitialStatusFailureFailsScreen() async {
        let source = StubSource()
        source.statusHandler = { throw Boom() }
        let model = DashboardModel()
        await model.load(dataSource: source, vehicleID: 1)
        guard case .failed = model.phase else { return XCTFail("expected failed phase") }
    }
}

// MARK: - Controls

@MainActor final class ControlsModelTests: XCTestCase {
    private func coordinator(_ records: [PendingVehicleCommand] = []) -> VehicleCommandCoordinator {
        VehicleCommandCoordinator(store: VehicleCommandIntentStore(inMemory: records))
    }

    func testReplayRefusalCannotDiscardTheOriginalUnknownOutcome() async {
        let source = StubSource()
        let record = PendingVehicleCommand(intentID: UUID(), backendID: source.commandBackendID,
                                           vehicleID: 1, command: .flash, label: "Flash lights", createdAt: .now)
        let commands = coordinator([record])
        await commands.refreshCapabilities(dataSource: source, vehicleID: 1)
        source.commandHandler = { _, _ in
            throw VehicleCommandFailure(status: 409, code: "command_scope_required", requestID: nil,
                                        retryAfter: nil, replayed: false)
        }
        let result = await commands.retry(record.intentID, dataSource: source, vehicleID: 1)
        XCTAssertEqual(result, .unknown)
        XCTAssertEqual(commands.pending(dataSource: source, vehicleID: 1).map(\.intentID), [record.intentID])
        XCTAssertEqual(commands.activity(dataSource: source, vehicleID: 1)?.phase, .unknown)

        await commands.refreshCapabilities(dataSource: source, vehicleID: 1)
        XCTAssertFalse(commands.canStart(.flash, dataSource: source, vehicleID: 1))
        source.commandHandler = { _, _ in
            throw VehicleCommandFailure(status: 409, code: "command_rejected", requestID: "synthetic-receipt",
                                        retryAfter: nil, replayed: true)
        }
        let settled = await commands.retry(record.intentID, dataSource: source, vehicleID: 1)
        XCTAssertEqual(settled, .failed)
        XCTAssertTrue(commands.pending(dataSource: source, vehicleID: 1).isEmpty)
    }

    func testHomeLinkSavedCoordinatesCanNeverBeReplayed() async {
        let source = StubSource()
        let record = PendingVehicleCommand(intentID: UUID(), backendID: source.commandBackendID, vehicleID: 1,
                                           command: .triggerHomeLink(latitude: 37.77, longitude: -122.42),
                                           label: "Activate HomeLink", createdAt: .now)
        let commands = coordinator([record])
        await commands.refreshCapabilities(dataSource: source, vehicleID: 1)
        XCTAssertFalse(commands.activity(dataSource: source, vehicleID: 1)?.canRetry ?? true)
        let result = await commands.retry(record.intentID, dataSource: source, vehicleID: 1)
        let sent = await source.commands.snapshot()
        XCTAssertEqual(result, .unknown)
        XCTAssertTrue(sent.isEmpty)
        XCTAssertEqual(commands.pending(dataSource: source, vehicleID: 1).count, 1)
        commands.acknowledgeCheckedVehicle(record.intentID, dataSource: source, vehicleID: 1)
        XCTAssertTrue(commands.pending(dataSource: source, vehicleID: 1).isEmpty)
    }

    func testRefreshingAnActiveSendPreservesPendingUIAndPreventsAcknowledgement() async {
        let source = StubSource(), gate = SectionGate(), commands = coordinator()
        source.commandHandler = { command, _ in
            await gate.wait()
            return VehicleCommandResult(command: command.name, requestID: "synthetic-receipt", replayed: false)
        }
        await commands.refreshCapabilities(dataSource: source, vehicleID: 1)
        let send = Task { await commands.perform(.flash, label: "Flash lights", dataSource: source, vehicleID: 1) }
        while !commands.isBusy(dataSource: source, vehicleID: 1) { await Task.yield() }
        let intent = commands.pending(dataSource: source, vehicleID: 1).first!
        await commands.refreshCapabilities(dataSource: source, vehicleID: 1)
        XCTAssertEqual(commands.activity(dataSource: source, vehicleID: 1)?.phase, .pending)
        commands.acknowledgeCheckedVehicle(intent.intentID, dataSource: source, vehicleID: 1)
        XCTAssertEqual(commands.pending(dataSource: source, vehicleID: 1).count, 1)
        await gate.open()
        _ = await send.value
        XCTAssertTrue(commands.pending(dataSource: source, vehicleID: 1).isEmpty)
    }

    func testUnknownObservedStatesRemainUnknownAndOfferTypedActions() async throws {
        let model = ControlsModel(status: makeStatus(locked: nil, climateOn: nil, sentry: nil,
                                                     chargeLimit: nil, chargingState: nil))
        XCTAssertNil(model.locked)
        XCTAssertNil(model.climateOn)
        XCTAssertNil(model.sentry)
        XCTAssertNil(model.chargeLimit)
        XCTAssertNil(model.chargingState)
        XCTAssertEqual(try json(.seatHeater(heater: 5, level: 3))["heater"] as? Int, 5)
        XCTAssertThrowsError(try VehicleCommand.seatHeater(heater: 3, level: 4).encodedBody())
        let temperatures = try json(.setTemperatures(driverTempC: 20.5, passengerTempC: 21))
        XCTAssertEqual(temperatures["driverTempC"] as? Double, 20.5)
        XCTAssertEqual(temperatures["passengerTempC"] as? Double, 21)
        XCTAssertEqual(try json(.setChargeLimit(percent: 85))["percent"] as? Int, 85)
        XCTAssertEqual(try json(.steeringWheelHeat(on: true))["on"] as? Bool, true)
        XCTAssertEqual(try json(.triggerHomeLink(latitude: 37.4, longitude: -122.1))["longitude"] as? Double, -122.1)
    }

    func testStateDisplayForUnknownAndKnownValues() {
        XCTAssertEqual(StateDisplay.doors(nil).text, "Unknown")
        XCTAssertEqual(StateDisplay.doors(nil).tone, .unknown)
        XCTAssertEqual(StateDisplay.doors(true).text, "Locked")
        XCTAssertEqual(StateDisplay.doors(false).text, "Unlocked")
        XCTAssertEqual(StateDisplay.climate(nil).text, "Unknown")
        XCTAssertEqual(StateDisplay.climate(false).text, "Off")
        XCTAssertEqual(StateDisplay.sentry(nil).text, "Unknown")
        XCTAssertEqual(StateDisplay.sentry(true).text, "Armed")
        XCTAssertEqual(StateDisplay.charging(nil).text, "Unknown")
        XCTAssertEqual(StateDisplay.charging(.charging).tone, .active)
        XCTAssertEqual(StateDisplay.chargeLimit(nil), "—")
        XCTAssertEqual(StateDisplay.chargeLimit(80), "80%")
    }

    func testHomeLinkRequiresActualRecentPositionTimestamp() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        var status = makeStatus()
        status.location = Location(latitude: 37.4, longitude: -122.1, heading: nil, address: nil, placeName: nil)
        status.updatedAt = now
        XCTAssertNil(ControlsView.homeLinkCommand(status: status, now: now), "status freshness is not position freshness")
        status.locationUpdatedAt = now.addingTimeInterval(-301)
        XCTAssertNil(ControlsView.homeLinkCommand(status: status, now: now))
        status.locationUpdatedAt = now.addingTimeInterval(1)
        XCTAssertNil(ControlsView.homeLinkCommand(status: status, now: now), "future position timestamps fail closed")
        status.locationUpdatedAt = now.addingTimeInterval(-300)
        XCTAssertEqual(ControlsView.homeLinkCommand(status: status, now: now),
                       .triggerHomeLink(latitude: 37.4, longitude: -122.1))
    }

    func testOlderOverlappingRefreshDoesNotOverwriteNewerStatus() async {
        let source = StubSource()
        let calls = Counter()
        let (gate, opener) = AsyncStream<Void>.makeStream()
        source.statusHandler = {
            if await calls.next() == 1 {
                for await _ in gate { break }
                return makeStatus(locked: true, sentry: false)
            }
            return makeStatus(locked: false, sentry: true)
        }
        let model = ControlsModel(status: nil)
        // Initial `.task` refresh stays pending while the user refreshes again.
        let first = Task { await model.refresh(dataSource: source, vehicleID: 1) }
        while await calls.value < 1 { await Task.yield() }

        await model.refresh(dataSource: source, vehicleID: 1)
        XCTAssertEqual(model.locked, false)
        XCTAssertEqual(model.sentry, true)

        opener.yield(())
        await first.value
        XCTAssertEqual(model.locked, false, "stale refresh must not publish")
        XCTAssertEqual(model.sentry, true)
        XCTAssertEqual(model.status?.locked, false)
    }

    func testUnavailableCapabilityBlocksBeforeDispatch() async {
        let source = StubSource(); source.capability = .unavailable
        let coordinator = coordinator()
        await coordinator.refreshCapabilities(dataSource: source, vehicleID: 1)
        XCTAssertFalse(coordinator.canStart(.unlock, dataSource: source, vehicleID: 1))
        let outcome = await coordinator.perform(.unlock, label: "Unlock", dataSource: source, vehicleID: 1)
        let entries = await source.commands.snapshot()
        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(entries.isEmpty)
    }

    func testLiveSuccessDoesNotPretendObservedStateChanged() async {
        let source = StubSource(), coordinator = coordinator()
        source.statusHandler = { makeStatus(locked: true) }
        await coordinator.refreshCapabilities(dataSource: source, vehicleID: 1)
        let model = ControlsModel(status: makeStatus(locked: true))
        await model.setLocked(false, coordinator: coordinator, dataSource: source, vehicleID: 1)
        XCTAssertEqual(model.locked, true, "fresh observed telemetry stays authoritative even after acceptance")
        XCTAssertEqual(coordinator.activity(dataSource: source, vehicleID: 1)?.phase, .success)
    }

    func testUnknownPersistsAcrossFileBackedRestartAndReplaysSameKey() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = directory.appendingPathComponent("pending.json")
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = StubSource()
        source.commandHandler = { _, _ in
            throw VehicleCommandFailure(status: 504, code: "command_outcome_unknown", requestID: "req-1",
                                        retryAfter: nil, replayed: false)
        }
        let first = VehicleCommandCoordinator(store: VehicleCommandIntentStore(fileURL: file))
        await first.refreshCapabilities(dataSource: source, vehicleID: 1)
        let firstOutcome = await first.perform(.honk, label: "Honk", dataSource: source, vehicleID: 1)
        let firstEntries = await source.commands.snapshot()
        XCTAssertEqual(firstOutcome, .unknown)
        let original = try! XCTUnwrap(firstEntries.first).intentID

        let restarted = VehicleCommandCoordinator(store: VehicleCommandIntentStore(fileURL: file))
        await restarted.refreshCapabilities(dataSource: source, vehicleID: 1)
        XCTAssertFalse(restarted.canStart(.flash, dataSource: source, vehicleID: 1), "unresolved intent gates fresh commands")
        source.commandHandler = { command, _ in VehicleCommandResult(command: command.name, requestID: "req-1", replayed: true) }
        let replayOutcome = await restarted.retry(original, dataSource: source, vehicleID: 1)
        let entries = await source.commands.snapshot()
        XCTAssertEqual(replayOutcome, .succeeded(simulated: false))
        XCTAssertEqual(entries.map(\.intentID), [original, original])
    }

    func testOwnerCanAcknowledgeFreshUnknownAfterCheckingVehicle() async {
        let record = PendingVehicleCommand(intentID: UUID(), backendID: "stub-backend", vehicleID: 1,
                                           command: .honk, label: "Honk horn", createdAt: .now)
        let source = StubSource(), coordinator = coordinator([record])
        await coordinator.refreshCapabilities(dataSource: source, vehicleID: 1)
        XCTAssertFalse(coordinator.canStart(.flash, dataSource: source, vehicleID: 1))
        coordinator.acknowledgeCheckedVehicle(record.intentID, dataSource: source, vehicleID: 1)
        XCTAssertTrue(coordinator.canStart(.flash, dataSource: source, vehicleID: 1))
    }

    func testDemoResultIsExplicitlySimulated() async {
        let source = MockDataSource(), coordinator = coordinator()
        await coordinator.refreshCapabilities(dataSource: source, vehicleID: MockDataSource.vehicleID)
        let outcome = await coordinator.perform(.flash, label: "Flash lights", dataSource: source,
                                                vehicleID: MockDataSource.vehicleID)
        XCTAssertEqual(outcome, .succeeded(simulated: true))
        XCTAssertEqual(coordinator.activity(dataSource: source, vehicleID: MockDataSource.vehicleID)?.phase, .simulated)
        XCTAssertTrue(coordinator.activity(dataSource: source, vehicleID: MockDataSource.vehicleID)?.message.contains("No vehicle was contacted") == true)
    }

    func testPendingIsolationUsesBackendAndVehicle() async {
        let record = PendingVehicleCommand(intentID: UUID(), backendID: "backend-a", vehicleID: 1,
                                           command: .lock, label: "Lock", createdAt: .now)
        let coordinator = coordinator([record])
        let a = StubSource(); a.backendID = "backend-a"
        let b = StubSource(); b.backendID = "backend-b"
        await coordinator.refreshCapabilities(dataSource: a, vehicleID: 1)
        await coordinator.refreshCapabilities(dataSource: a, vehicleID: 2)
        await coordinator.refreshCapabilities(dataSource: b, vehicleID: 1)
        XCTAssertFalse(coordinator.canStart(.honk, dataSource: a, vehicleID: 1))
        XCTAssertTrue(coordinator.canStart(.honk, dataSource: a, vehicleID: 2))
        XCTAssertTrue(coordinator.canStart(.honk, dataSource: b, vehicleID: 1))
    }

    func testExpiredIntentCannotReplayUntilOwnerAcknowledgesCheck() async {
        let record = PendingVehicleCommand(intentID: UUID(), backendID: "stub-backend", vehicleID: 1,
                                           command: .unlock, label: "Unlock",
                                           createdAt: .now.addingTimeInterval(-VehicleCommandIntentStore.maximumReplayAge - 1))
        let source = StubSource(), coordinator = coordinator([record])
        await coordinator.refreshCapabilities(dataSource: source, vehicleID: 1)
        let outcome = await coordinator.retry(record.intentID, dataSource: source, vehicleID: 1)
        let entries = await source.commands.snapshot()
        XCTAssertEqual(outcome, .unknown)
        XCTAssertTrue(entries.isEmpty, "expired receipt must never be replayed")
        XCTAssertEqual(coordinator.activity(dataSource: source, vehicleID: 1)?.requiresAcknowledgement, true)
        XCTAssertFalse(coordinator.canStart(.lock, dataSource: source, vehicleID: 1))
        coordinator.acknowledgeCheckedVehicle(record.intentID, dataSource: source, vehicleID: 1)
        XCTAssertTrue(coordinator.canStart(.lock, dataSource: source, vehicleID: 1))
    }

    func testRetryAfterBlocksEarlyReplay() async {
        let future = Date.now.addingTimeInterval(60)
        let record = PendingVehicleCommand(intentID: UUID(), backendID: "stub-backend", vehicleID: 1,
                                           command: .flash, label: "Flash", createdAt: .now, retryNotBefore: future)
        let source = StubSource(), coordinator = coordinator([record])
        await coordinator.refreshCapabilities(dataSource: source, vehicleID: 1)
        let outcome = await coordinator.retry(record.intentID, dataSource: source, vehicleID: 1)
        let entries = await source.commands.snapshot()
        XCTAssertEqual(outcome, .unknown)
        XCTAssertTrue(entries.isEmpty)
    }

    func testCommandNotSentIsDefinitiveAndAllowsNewDeliberateIntent() async {
        let source = StubSource(), coordinator = coordinator()
        source.commandHandler = { _, _ in
            throw VehicleCommandFailure(status: 503, code: "command_not_sent", requestID: nil,
                                        retryAfter: nil, replayed: false)
        }
        await coordinator.refreshCapabilities(dataSource: source, vehicleID: 1)
        let outcome = await coordinator.perform(.flash, label: "Flash", dataSource: source, vehicleID: 1)
        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(coordinator.pending(dataSource: source, vehicleID: 1).isEmpty)
        XCTAssertTrue(coordinator.canStart(.flash, dataSource: source, vehicleID: 1))
        XCTAssertTrue(coordinator.activity(dataSource: source, vehicleID: 1)?.message.contains("before sending") == true)
    }

    func testCorruptDurableStoreFailsClosedBeforeNetwork() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("pending.json")
        try Data("not-json".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = StubSource(), coordinator = VehicleCommandCoordinator(store: VehicleCommandIntentStore(fileURL: file))
        await coordinator.refreshCapabilities(dataSource: source, vehicleID: 1)
        XCTAssertFalse(coordinator.canStart(.honk, dataSource: source, vehicleID: 1))
        let outcome = await coordinator.perform(.honk, label: "Honk", dataSource: source, vehicleID: 1)
        let entries = await source.commands.snapshot()
        XCTAssertEqual(outcome, .failed)
        XCTAssertTrue(entries.isEmpty)
    }

    private func json(_ command: VehicleCommand) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: command.encodedBody()) as? [String: Any])
    }
}

// MARK: - Duo cockpit: Now card, dock, stepped settings, command log, panes

private actor SentLimits {
    private(set) var values: [Int] = []
    private(set) var cancelled: [Bool] = []
    func append(_ value: Int, cancelled wasCancelled: Bool) { values.append(value); cancelled.append(wasCancelled) }
}

@MainActor final class DuoCockpitTests: XCTestCase {
    private func coordinator() -> VehicleCommandCoordinator {
        VehicleCommandCoordinator(store: VehicleCommandIntentStore(inMemory: []))
    }

    private func status(_ state: VehicleState = .online, charging: ChargingState? = .disconnected,
                        locked: Bool? = true, updatedAt: Date = .now) -> VehicleStatus {
        var status = makeStatus(locked: locked, chargingState: charging)
        status.state = state
        status.updatedAt = updatedAt
        return status
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
    }

    // MARK: Now card

    func testPackToneFollowsThePackTemperature() {
        XCTAssertNil(DashboardView.packTone(nil), "no reading, no colour")
        XCTAssertEqual(DashboardView.packTone(-5), .voltaBlue)
        XCTAssertEqual(DashboardView.packTone(9.9), .voltaBlue)
        XCTAssertEqual(DashboardView.packTone(10), .voltaGreen)
        XCTAssertEqual(DashboardView.packTone(34.9), .voltaGreen)
        XCTAssertEqual(DashboardView.packTone(37.8), .voltaAmber)
        XCTAssertEqual(DashboardView.packTone(50), .voltaRed)
    }

    func testNowCardIsTintedOnlyWhileChargingOrParked() {
        XCTAssertEqual(NowCard.accent(for: .charging), .voltaGreen)
        XCTAssertEqual(NowCard.accent(for: .parked), .voltaBlue)
        XCTAssertNil(NowCard.accent(for: .pluggedIn))
        XCTAssertNil(NowCard.accent(for: .driving))
        XCTAssertNil(NowCard.accent(for: .unreachable(.asleep)))
    }

    func testStripColoursDrivesChargingAndOnlineAndLeavesSleepEmpty() {
        XCTAssertEqual(ActivityStrip.color(for: .drive), .voltaRed)
        XCTAssertEqual(ActivityStrip.color(for: .charge), .voltaGreen)
        XCTAssertEqual(ActivityStrip.color(for: .idle), .voltaBlue)
        XCTAssertNil(ActivityStrip.color(for: .asleep))
        XCTAssertNil(ActivityStrip.color(for: .offline))
    }

    func testNowVariantFollowsWhatTheCarIsDoing() {
        XCTAssertEqual(NowVariant.of(status(charging: .charging)), .charging)
        XCTAssertEqual(NowVariant.of(status(.charging, charging: nil)), .charging, "state alone says charging")
        XCTAssertEqual(NowVariant.of(status(charging: .stopped)), .pluggedIn)
        XCTAssertEqual(NowVariant.of(status(charging: .complete)), .pluggedIn)
        XCTAssertEqual(NowVariant.of(status(charging: .disconnected)), .parked)
        XCTAssertEqual(NowVariant.of(status(charging: nil)), .parked)
        XCTAssertEqual(NowVariant.of(status(.driving)), .driving)
        XCTAssertEqual(NowVariant.of(status(.asleep, charging: .complete)), .unreachable(.asleep),
                       "a sleeping car is unreachable even while plugged in")
        XCTAssertEqual(NowVariant.of(status(.offline)), .unreachable(.offline))
    }

    func testNowCardTextComesOnlyFromReportedFields() {
        var charging = status(charging: .charging)
        XCTAssertNil(NowCardContent.timeToLimit(charging))
        XCTAssertNil(NowCardContent.electrical(charging))
        XCTAssertEqual(NowCardContent.power(nil), "—")
        charging.minutesToFull = 48
        charging.chargerCurrentA = 32
        charging.chargerVoltage = 241
        charging.chargeEnergyAddedKwh = 2.94
        XCTAssertEqual(NowCardContent.timeToLimit(charging), "48m to 80%")
        XCTAssertEqual(NowCardContent.electrical(charging), "32 A · 241 V · +2.9 kWh added")
        XCTAssertEqual(NowCardContent.power(7.7), "7.7")
        XCTAssertEqual(NowCardContent.power(150.4), "150")
    }

    func testParkedSinceUsesTheLatestDriveAlreadyLoaded() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let older = TimelineSegment(kind: .drive, start: now.addingTimeInterval(-9000), end: now.addingTimeInterval(-8000))
        let latest = TimelineSegment(kind: .drive, start: now.addingTimeInterval(-6000), end: now.addingTimeInterval(-5280))
        let charge = TimelineSegment(kind: .charge, start: now.addingTimeInterval(-4000), end: now.addingTimeInterval(-100))
        XCTAssertEqual(NowCardContent.parkedSince([latest, charge, older], now: now), latest.end)
        XCTAssertNil(NowCardContent.parkedSince([charge], now: now), "no drive in the window: unknown, not guessed")
    }

    // MARK: Dock

    func testDockTilesStateFirstAndSendWhenKnownAndSupported() {
        let tiles = DockTile.tiles(locked: true, climateOn: false, sentry: true) { _ in true }
        XCTAssertEqual(tiles.map(\.kind), DockTile.Kind.allCases)
        XCTAssertEqual(tiles[0].title, "Locked")
        XCTAssertEqual(tiles[0].action, "Unlock")
        XCTAssertEqual(tiles[0].tap, .send(.unlock))
        XCTAssertEqual(tiles[1].tap, .send(.climateOn))
        XCTAssertEqual(tiles[2].title, "Sentry on")
        XCTAssertEqual(tiles[2].tone, .armed)
        XCTAssertEqual(tiles[2].tap, .send(.sentryOff))
        XCTAssertEqual(tiles[7].tap, .openControls)
        let unlocked = DockTile.tiles(locked: false, climateOn: true, sentry: false) { _ in true }
        XCTAssertEqual(unlocked[0].tone, .attention)
        XCTAssertEqual(unlocked[0].tap, .send(.lock))
        XCTAssertEqual(unlocked[0].accessibilityLabel, "Doors unlocked. Lock")
    }

    func testDockTilesOpenControlsWhenStateUnknown() {
        let tiles = DockTile.tiles(locked: nil, climateOn: nil, sentry: nil) { _ in true }
        for tile in tiles.prefix(3) {
            XCTAssertEqual(tile.tap, .openControls, "\(tile.kind) must not guess a direction")
            XCTAssertEqual(tile.action, "Unknown")
            XCTAssertEqual(tile.tone, .unknown)
        }
        XCTAssertEqual(tiles[3].tap, .send(.windowControl(command: .vent)), "stateless tiles still send")
    }

    func testDockTilesOpenControlsWhenControlsAreNotEnabled() {
        let tiles = DockTile.tiles(locked: true, climateOn: false, sentry: false) { $0 == .flash }
        XCTAssertEqual(tiles.first { $0.kind == .lights }?.tap, .send(.flash))
        for tile in tiles where tile.kind != .lights {
            XCTAssertEqual(tile.tap, .openControls, "\(tile.kind)")
        }
        XCTAssertEqual(tiles[0].action, "Open Controls")
        XCTAssertEqual(tiles[0].accessibilityLabel, "Locked. Opens Controls")
    }

    // MARK: Stepped charge limit

    func testSteppedChargeLimitSendsOneCommandForTheFinalValue() async {
        let source = StubSource(), sent = SentLimits(), commands = coordinator()
        source.commandHandler = { command, _ in
            if case .setChargeLimit(let percent) = command { await sent.append(percent, cancelled: Task.isCancelled) }
            return VehicleCommandResult(command: command.name, requestID: "request-1", replayed: false)
        }
        await commands.refreshCapabilities(dataSource: source, vehicleID: 1)
        let model = ControlsModel(status: makeStatus(chargeLimit: 80))
        model.log = VehicleCommandLog()
        model.settingDelay = .milliseconds(50)
        for _ in 0..<3 {
            model.stepChargeLimit(by: 5, coordinator: commands, dataSource: source, vehicleID: 1)
        }
        XCTAssertEqual(model.displayedChargeLimit, 95, "the stepper shows the pending value at once")
        XCTAssertEqual(model.chargeLimit, 80, "observed state does not move before the car reports it")
        var values: [Int] = []
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while values.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
            values = await sent.values
        }
        try? await Task.sleep(for: .milliseconds(150))
        values = await sent.values
        let cancelled = await sent.cancelled
        XCTAssertEqual(values, [95])
        XCTAssertEqual(cancelled, [false], "the debounced send must not run in a cancelled task")
        let names = await source.commands.names
        XCTAssertEqual(names, ["set_charge_limit"])
        await waitUntil { model.pendingChargeLimit == nil }
        XCTAssertNil(model.pendingChargeLimit)
    }

    func testSteppingBackToTheObservedLimitSendsNothing() async {
        let source = StubSource(), commands = coordinator()
        await commands.refreshCapabilities(dataSource: source, vehicleID: 1)
        let model = ControlsModel(status: makeStatus(chargeLimit: 80))
        model.log = VehicleCommandLog()
        model.settingDelay = .milliseconds(20)
        model.stepChargeLimit(by: 5, coordinator: commands, dataSource: source, vehicleID: 1)
        model.stepChargeLimit(by: -5, coordinator: commands, dataSource: source, vehicleID: 1)
        try? await Task.sleep(for: .milliseconds(200))
        let names = await source.commands.names
        XCTAssertTrue(names.isEmpty)
        XCTAssertNil(model.pendingChargeLimit)
    }

    func testSteppedChargeLimitWaitsForACommandInFlightInsteadOfBeingDropped() async {
        let source = StubSource(), gate = SectionGate(), commands = coordinator()
        source.commandHandler = { command, _ in
            if command == .flash { await gate.wait() }
            return VehicleCommandResult(command: command.name, requestID: "request-1", replayed: false)
        }
        await commands.refreshCapabilities(dataSource: source, vehicleID: 1)
        let model = ControlsModel(status: makeStatus(chargeLimit: 80))
        model.log = VehicleCommandLog()
        model.settingDelay = .milliseconds(30)
        model.stepChargeLimit(by: 5, coordinator: commands, dataSource: source, vehicleID: 1)
        // Another command starts before the pause ends and is still in flight after it.
        let flash = Task { await model.send(.flash, coordinator: commands, dataSource: source, vehicleID: 1) }
        try? await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(model.pendingChargeLimit, 85, "the stepped value is kept while it cannot be sent")
        var names = await source.commands.names
        XCTAssertEqual(names, [VehicleCommand.flash.name])
        await gate.open()
        _ = await flash.value
        await waitUntil { model.pendingChargeLimit == nil }
        names = await source.commands.names
        XCTAssertEqual(names, [VehicleCommand.flash.name, "set_charge_limit"], "sent once the other command finished")
        let key = VehicleCommandLog.key(backendID: source.commandBackendID, vehicleID: 1)
        XCTAssertEqual(model.log.entries(for: key).map(\.command), [.setChargeLimit(percent: 85), .flash])
    }

    func testSteppedSettingTheCoordinatorRefusesIsLoggedAsFailed() async {
        let source = StubSource(), commands = coordinator()
        // Controls are not enabled for the charge limit: nothing can be sent.
        source.capability = VehicleCommandCapabilities(available: true, reason: nil, commands: [VehicleCommand.flash.name])
        await commands.refreshCapabilities(dataSource: source, vehicleID: 1)
        let model = ControlsModel(status: makeStatus(chargeLimit: 80))
        model.log = VehicleCommandLog()
        model.settingDelay = .milliseconds(20)
        model.stepChargeLimit(by: 5, coordinator: commands, dataSource: source, vehicleID: 1)
        await waitUntil { model.pendingChargeLimit == nil }
        let names = await source.commands.names
        XCTAssertTrue(names.isEmpty)
        let key = VehicleCommandLog.key(backendID: source.commandBackendID, vehicleID: 1)
        XCTAssertEqual(model.log.entries(for: key).map(\.outcome), [.failed], "a dropped change leaves a trace")
    }

    func testClimateScreenAndItsEditsLiveInTheSharedModel() {
        let model = ControlsModel(status: makeStatus())
        XCTAssertFalse(model.climateOpen)
        model.climateOpen = true
        model.climateDriverDraftC = 21.5
        // A newer status (as after a fold re-creates the views) does not reset them.
        model.apply(makeStatus(battery: 71))
        XCTAssertTrue(model.climateOpen)
        XCTAssertEqual(model.climateDriverDraftC, 21.5)
        XCTAssertNil(model.climatePassengerDraftC)
    }

    func testChargeLimitStepsStayInRange() {
        let model = ControlsModel(status: makeStatus(chargeLimit: 100))
        model.settingDelay = .seconds(60)
        let source = StubSource(), commands = coordinator()
        model.stepChargeLimit(by: 5, coordinator: commands, dataSource: source, vehicleID: 1)
        XCTAssertNil(model.pendingChargeLimit, "already at the top: nothing pending")
        let unknown = ControlsModel(status: makeStatus(chargeLimit: nil))
        unknown.stepChargeLimit(by: 5, coordinator: commands, dataSource: source, vehicleID: 1)
        XCTAssertNil(unknown.displayedChargeLimit, "an unreported limit is never invented")
    }

    // MARK: Command log

    func testCommandLogWordingFollowsTheEvidence() {
        let log = VehicleCommandLog(), key = VehicleCommandLog.key(backendID: "b", vehicleID: 1)
        let sent = Date(timeIntervalSince1970: 1_800_000_000)
        let lock = log.begin(.lock, label: "Lock", key: key, at: sent)
        XCTAssertEqual(log.entries(for: key).first?.outcome, .sending)
        log.finish(lock, with: .succeeded(simulated: false))
        XCTAssertEqual(log.entries(for: key).first?.outcome, .accepted)
        let demo = log.begin(.flash, label: "Flash lights", key: key, at: sent)
        log.finish(demo, with: .succeeded(simulated: true))
        let failed = log.begin(.honk, label: "Honk", key: key, at: sent)
        log.finish(failed, with: .failed)
        let unknown = log.begin(.unlock, label: "Unlock", key: key, at: sent)
        log.finish(unknown, with: .unknown)
        XCTAssertEqual(log.entries(for: key).map(\.outcome), [.unknown, .failed, .simulated, .accepted],
                       "newest first")
        XCTAssertEqual(VehicleCommandLog.Outcome.unknown.text, "Outcome unknown")
        XCTAssertTrue(log.entries(for: VehicleCommandLog.key(backendID: "b", vehicleID: 2)).isEmpty)
    }

    func testRetriedRequestUpdatesItsLogEntry() {
        let log = VehicleCommandLog(), key = VehicleCommandLog.key(backendID: "b", vehicleID: 1)
        let sent = Date(timeIntervalSince1970: 1_800_000_000), retried = sent.addingTimeInterval(60)
        log.finish(log.begin(.flash, label: "Flash lights", key: key, at: sent), with: .failed, at: sent)
        log.finish(log.begin(.lock, label: "Lock", key: key, at: sent), with: .unknown, at: sent)
        log.settleRetry(of: .unlock, key: key, with: .succeeded(simulated: false), at: retried)
        XCTAssertEqual(log.entries(for: key).map(\.outcome), [.unknown, .failed], "no unknown entry for that command")
        log.settleRetry(of: .lock, key: key, with: .succeeded(simulated: false), at: retried)
        XCTAssertEqual(log.entries(for: key).map(\.outcome), [.accepted, .failed])
        XCTAssertEqual(log.entries(for: key).first?.updatedAt, retried)
        // Only a status from after the retry can confirm it.
        log.observe(status(locked: true, updatedAt: sent.addingTimeInterval(30)), key: key)
        XCTAssertEqual(log.entries(for: key).first?.outcome, .accepted)
        log.observe(status(locked: true, updatedAt: retried.addingTimeInterval(5)), key: key)
        XCTAssertEqual(log.entries(for: key).first?.outcome, .confirmed)
    }

    func testRetryThatCannotStartLeavesTheOutcomeUnknown() async throws {
        let source = StubSource(), commands = coordinator()
        source.commandHandler = { _, _ in throw Boom() }
        await commands.refreshCapabilities(dataSource: source, vehicleID: 1)
        let model = ControlsModel(status: makeStatus())
        model.log = VehicleCommandLog()
        let key = VehicleCommandLog.key(backendID: source.commandBackendID, vehicleID: 1)
        await model.send(.flash, coordinator: commands, dataSource: source, vehicleID: 1)
        XCTAssertEqual(model.log.entries(for: key).map(\.outcome), [.unknown])

        // Controls become unavailable: the retry is refused before anything is sent.
        source.capability = VehicleCommandCapabilities(available: true, reason: nil, commands: [])
        await commands.refreshCapabilities(dataSource: source, vehicleID: 1)
        let refused = try XCTUnwrap(commands.activity(dataSource: source, vehicleID: 1))
        let first = await commands.retry(refused, log: model.log, dataSource: source, vehicleID: 1)
        XCTAssertEqual(first, .failed)
        XCTAssertEqual(model.log.entries(for: key).map(\.outcome), [.unknown],
                       "the original request may still have run")
        XCTAssertEqual(commands.pending(dataSource: source, vehicleID: 1).count, 1)

        // Available again and the server accepts the replay: now it is settled.
        source.capability = VehicleCommandCapabilities(available: true, reason: nil,
                                                       commands: Array(VehicleCommand.supportedNames))
        source.commandHandler = { command, _ in
            VehicleCommandResult(command: command.name, requestID: "request-2", replayed: true)
        }
        await commands.refreshCapabilities(dataSource: source, vehicleID: 1)
        let saved = try XCTUnwrap(commands.activity(dataSource: source, vehicleID: 1))
        let second = await commands.retry(saved, log: model.log, dataSource: source, vehicleID: 1)
        XCTAssertEqual(second, .succeeded(simulated: false))
        XCTAssertEqual(model.log.entries(for: key).map(\.outcome), [.accepted])
        XCTAssertTrue(commands.pending(dataSource: source, vehicleID: 1).isEmpty)
    }

    func testRetryTheServerAnswersSettlesTheLogEvenWhenTheSavedRequestCannotBeRemoved() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let path = directory.path
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
            try? FileManager.default.removeItem(at: directory)
        }
        let source = StubSource()
        let commands = VehicleCommandCoordinator(
            store: VehicleCommandIntentStore(fileURL: directory.appendingPathComponent("pending.json")))
        source.commandHandler = { _, _ in throw Boom() }
        await commands.refreshCapabilities(dataSource: source, vehicleID: 1)
        let model = ControlsModel(status: makeStatus())
        model.log = VehicleCommandLog()
        let key = VehicleCommandLog.key(backendID: source.commandBackendID, vehicleID: 1)
        await model.send(.flash, coordinator: commands, dataSource: source, vehicleID: 1)
        XCTAssertEqual(model.log.entries(for: key).map(\.outcome), [.unknown])

        // Storage stops accepting writes while the server is answering.
        source.commandHandler = { command, _ in
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: path)
            return VehicleCommandResult(command: command.name, requestID: "request-2", replayed: true)
        }
        let saved = try XCTUnwrap(commands.activity(dataSource: source, vehicleID: 1))
        let result = await commands.retry(saved, log: model.log, dataSource: source, vehicleID: 1)
        XCTAssertEqual(result, .succeeded(simulated: false))
        XCTAssertEqual(commands.pending(dataSource: source, vehicleID: 1).count, 1,
                       "the saved request could not be removed")
        XCTAssertEqual(model.log.entries(for: key).map(\.outcome), [.accepted],
                       "the server's answer is the evidence, not the storage cleanup")
    }

    func testConfirmedNeedsALaterStatusShowingTheExpectedState() {
        let log = VehicleCommandLog(), key = VehicleCommandLog.key(backendID: "b", vehicleID: 1)
        let sent = Date(timeIntervalSince1970: 1_800_000_000)
        let lock = log.begin(.lock, label: "Lock", key: key, at: sent)
        log.finish(lock, with: .succeeded(simulated: false))
        log.observe(status(locked: true, updatedAt: sent.addingTimeInterval(-5)), key: key)
        XCTAssertEqual(log.entries(for: key).first?.outcome, .accepted, "a status from before the send proves nothing")
        log.observe(status(locked: false, updatedAt: sent.addingTimeInterval(5)), key: key)
        XCTAssertEqual(log.entries(for: key).first?.outcome, .accepted, "the car still reports unlocked")
        log.observe(status(locked: nil, updatedAt: sent.addingTimeInterval(6)), key: key)
        XCTAssertEqual(log.entries(for: key).first?.outcome, .accepted, "an unreported lock confirms nothing")
        log.observe(status(locked: true, updatedAt: sent.addingTimeInterval(10)), key: key)
        XCTAssertEqual(log.entries(for: key).first?.outcome, .confirmed)
    }

    func testCommandsTheCarDoesNotReportStayAccepted() {
        let log = VehicleCommandLog(), key = VehicleCommandLog.key(backendID: "b", vehicleID: 1)
        let sent = Date(timeIntervalSince1970: 1_800_000_000)
        for command: VehicleCommand in [.flash, .honk, .actuateTrunk(whichTrunk: .front), .windowControl(command: .vent),
                                        .setTemperatures(driverTempC: 21, passengerTempC: 21)] {
            let id = log.begin(command, label: command.controlLabel, key: key, at: sent)
            log.finish(id, with: .succeeded(simulated: false))
            XCTAssertNil(command.isObserved(in: status()), "\(command.name)")
        }
        log.observe(status(updatedAt: sent.addingTimeInterval(60)), key: key)
        XCTAssertTrue(log.entries(for: key).allSatisfy { $0.outcome == .accepted })
        var limit = status(updatedAt: sent.addingTimeInterval(60))
        limit.chargeLimit = 90
        XCTAssertEqual(VehicleCommand.setChargeLimit(percent: 90).isObserved(in: limit), true)
        XCTAssertEqual(VehicleCommand.setChargeLimit(percent: 85).isObserved(in: limit), false)
        limit.chargePortDoorOpen = true
        XCTAssertEqual(VehicleCommand.openChargePort.isObserved(in: limit), true)
        XCTAssertEqual(VehicleCommand.closeChargePort.isObserved(in: limit), false)
    }

    func testControlsSendsAreLoggedWithTheirOutcome() async {
        let source = StubSource(), commands = coordinator()
        await commands.refreshCapabilities(dataSource: source, vehicleID: 1)
        let model = ControlsModel(status: makeStatus())
        let log = VehicleCommandLog()
        model.log = log
        await model.send(.flash, coordinator: commands, dataSource: source, vehicleID: 1)
        let key = VehicleCommandLog.key(backendID: source.commandBackendID, vehicleID: 1)
        XCTAssertEqual(log.entries(for: key).map(\.label), ["Flash lights"])
        XCTAssertEqual(log.entries(for: key).map(\.outcome), [.accepted])
    }

    // MARK: Controls rows

    func testChargePortOffersOnlyTheActionThatChangesIt() {
        XCTAssertEqual(ControlsView.chargePortCommands(doorOpen: true), [.closeChargePort])
        XCTAssertEqual(ControlsView.chargePortCommands(doorOpen: false), [.openChargePort])
        XCTAssertEqual(ControlsView.chargePortCommands(doorOpen: nil), [.openChargePort, .closeChargePort])
    }

    func testChargingSubtitleStatesTheChargingState() {
        var charging = status(charging: .charging)
        charging.chargerPowerKw = 7.7
        charging.minutesToFull = 48
        XCTAssertEqual(ControlsView.chargingSubtitle(state: .charging, status: charging), "7.7 kW · 48m to 80%")
        XCTAssertEqual(ControlsView.chargingSubtitle(state: .disconnected, status: nil), "Not plugged in")
        XCTAssertEqual(ControlsView.chargingSubtitle(state: .complete, status: nil), "Complete · plugged in")
        XCTAssertEqual(ControlsView.chargingSubtitle(state: nil, status: nil), "State not recorded")
    }

    func testConfirmationTableMatchesControls() {
        for command: VehicleCommand in [.unlock, .actuateTrunk(whichTrunk: .front), .actuateTrunk(whichTrunk: .rear),
                                        .openChargePort, .windowControl(command: .vent), .honk] {
            XCTAssertNotNil(CommandConfirmation.required(for: command), "\(command.name)")
        }
        for command: VehicleCommand in [.flash, .climateOn, .sentryOff, .chargeStop, .setChargeLimit(percent: 80)] {
            XCTAssertNil(CommandConfirmation.required(for: command), "\(command.name)")
        }
    }

    // MARK: Identity row

    func testFreshnessSaysLiveOnlyWhenTelemetryIsConnected() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var live = status(updatedAt: now)
        live.telemetryFreshness = TelemetryFreshness(connected: true, lastSeenAt: now, recordedAt: [:])
        XCTAssertEqual(DashboardView.freshness(live, now: now).text, "Live")
        XCTAssertTrue(DashboardView.freshness(live, now: now).isLive)
        live.telemetryFreshness?.connected = false
        XCTAssertFalse(DashboardView.freshness(live, now: now).isLive)
        let asleep = status(.asleep, updatedAt: now.addingTimeInterval(-3600))
        XCTAssertFalse(DashboardView.freshness(asleep, now: now).isLive)
        XCTAssertTrue(DashboardView.freshness(asleep, now: now).text.hasPrefix("Asleep"))
    }

    // MARK: Panes

    func testPanesMeetAtTheMiddleOfAFlatHinge() {
        // Open flat: an inactive division region 40 pt wide around the hinge.
        let split = PaneSplit.resolve(length: 867, division: (455.5...495.5, false), windowOffset: 0,
                                      insets: (0, 84))
        XCTAssertEqual(split, PaneSplit(firstEnd: 475.5, secondStart: 475.5))
    }

    func testPanesGiveUpTheFoldMarginsWhenPartlyFolded() {
        let split = PaneSplit.resolve(length: 867, division: (455.5...495.5, true), windowOffset: 0,
                                      insets: (0, 84))
        XCTAssertEqual(split, PaneSplit(firstEnd: 455.5, secondStart: 495.5))
    }

    func testPanesFallBackToTheWindowMiddleOnlyAtTheWindowEdge() {
        let middle = PaneSplit.resolve(length: 867, division: nil, windowOffset: 0, insets: (0, 84))
        XCTAssertEqual(middle, PaneSplit(firstEnd: 475.5, secondStart: 475.5), "bars count toward the middle")
        XCTAssertNil(PaneSplit.resolve(length: 600, division: nil, windowOffset: 300, insets: (0, 0)),
                     "a detail column cannot know where the window's middle is")
        XCTAssertNil(PaneSplit.resolve(length: 400, division: nil, windowOffset: 0, insets: (0, 0)),
                     "too narrow for two panes")
        XCTAssertEqual(PaneSplit.resolve(length: 600, division: (40...80, false), windowOffset: 0, insets: (0, 0)),
                       PaneSplit(firstEnd: 300, secondStart: 300), "a hinge near an edge is not this container's")
    }
}
