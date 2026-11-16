import XCTest
import Synchronization
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
        XCTAssertTrue(freshness.label.contains("car last seen"), "the car's own last report stays in the caption")
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

    // MARK: Review round 1

    func testSavedDataNeverMakesAForegroundReloadDue() async {
        let source = StubSource(), gate = SectionGate(), calls = Counter(), model = DashboardModel()
        source.statusHandler = { _ = await calls.next(); await gate.wait(); return makeStatus(battery: 90) }
        let task = Task { await model.load(dataSource: source, vehicleID: 1, initialVehicles: DashboardStart(saved: saved())) }
        await waitUntil { model.status != nil }
        XCTAssertNil(model.lastLoadedAt, "saved data is not a recent load")
        XCTAssertFalse(model.foregroundRefreshDue(now: .now.addingTimeInterval(3600)),
                       "becoming active while saved data shows sends nothing more")
        XCTAssertNil(model.controlsInitialStatus, "the Controls sheet never starts from saved status")
        await gate.open()
        await task.value
        let statuses = await calls.value
        XCTAssertEqual(statuses, 1)
        XCTAssertNotNil(model.lastLoadedAt)
        XCTAssertEqual(model.controlsInitialStatus?.batteryLevel, 90)
        XCTAssertTrue(model.foregroundRefreshDue(now: .now.addingTimeInterval(31)))
    }

    func testForegroundReloadWaitsWhileSectionsLoad() async {
        let source = StubSource(), gate = SectionGate(), model = DashboardModel()
        await model.load(dataSource: source, vehicleID: 1)
        source.summaryHandler = { range in await gate.wait(); return makeSummary(range) }
        let task = Task { await model.load(dataSource: source, vehicleID: 1) }
        await waitUntil { !model.loadingSections.isEmpty }
        XCTAssertFalse(model.foregroundRefreshDue(now: .now.addingTimeInterval(3600)))
        await gate.open()
        await task.value
    }

    func testFreshStatusHidesSavedHistoryUntilThisLoadReplacesIt() async {
        let source = StubSource(), gate = SectionGate(), store = MemorySavedDashboards(), model = DashboardModel()
        store.acceptedBackend = "backend-a"
        source.timelineHandler = { await gate.wait(); throw VoltaError.unreachable("offline") }
        source.summaryHandler = { _ in await gate.wait(); throw VoltaError.unreachable("offline") }
        let task = Task {
            await model.load(dataSource: source, vehicleID: 1,
                             initialVehicles: DashboardStart(saved: saved(), store: store, backend: "backend-a"))
        }
        await waitUntil { model.status?.batteryLevel == 72 }
        XCTAssertFalse(model.showsSavedStatus)
        XCTAssertTrue(model.timeline.isEmpty, "saved history is not shown beside fresh status")
        XCTAssertTrue(model.summaries.isEmpty)
        XCTAssertEqual(model.loadingSections.count, 4, "those sections show as loading")

        await gate.open()
        await task.value
        XCTAssertEqual(model.failedSections.count, 4, "and then as failed, not as saved data")
        XCTAssertTrue(model.timeline.isEmpty)
        let written = store.dashboard
        XCTAssertEqual(written?.status.batteryLevel, 72)
        XCTAssertEqual(written?.timeline, [], "failed sections are never saved under the new date")
        XCTAssertEqual(written?.summaries, [])

        // The next launch shows what that load really fetched, and nothing older.
        let next = DashboardModel(), nextGate = SectionGate()
        source.statusHandler = { await nextGate.wait(); return makeStatus() }
        let relaunch = Task {
            await next.load(dataSource: source, vehicleID: 1,
                            initialVehicles: DashboardStart(saved: written, store: store, backend: "backend-a"))
        }
        await waitUntil { next.status != nil }
        XCTAssertTrue(next.showsSavedStatus)
        XCTAssertTrue(next.timeline.isEmpty)
        XCTAssertTrue(next.summaries.isEmpty)
        await nextGate.open()
        await relaunch.value
    }

    func testOnlySectionsLoadedFreshAreSaved() async {
        let source = StubSource(), store = MemorySavedDashboards(), model = DashboardModel()
        store.acceptedBackend = "backend-a"
        source.timelineHandler = { [segment] }
        await model.load(dataSource: source, vehicleID: 1, initialVehicles: DashboardStart(store: store, backend: "backend-a"))
        XCTAssertEqual(store.dashboard?.summaries.count, 3)
        let firstSavedAt = store.dashboard?.savedAt

        // A refresh whose history fails keeps the earlier sections on screen,
        // but does not save them again under the new date.
        source.timelineHandler = { throw VoltaError.unreachable("offline") }
        source.summaryHandler = { _ in throw VoltaError.unreachable("offline") }
        source.statusHandler = { makeStatus(battery: 55) }
        await model.load(dataSource: source, vehicleID: 1)
        XCTAssertEqual(model.timeline.count, 1, "kept on screen with the partial-failure banner")
        XCTAssertNotNil(model.partialFailureMessage)
        XCTAssertEqual(store.dashboard?.status.batteryLevel, 55)
        XCTAssertNotEqual(store.dashboard?.savedAt, firstSavedAt)
        XCTAssertEqual(store.dashboard?.timeline, [])
        XCTAssertEqual(store.dashboard?.summaries, [])
    }

    func testAPrefetchSentTooLongAgoIsNotAdopted() async {
        let source = StubSource(), calls = Counter(), model = DashboardModel()
        source.statusHandler = { let call = await calls.next(); return makeStatus(battery: call == 1 ? 11 : 66) }
        let prefetch = DashboardPrefetch(dataSource: source, vehicleID: 1, surfaces: nil,
                                         sentAt: .now - .seconds(6))
        await model.load(dataSource: source, vehicleID: 1, initialVehicles: DashboardStart(prefetch: prefetch))
        XCTAssertTrue(prefetch.status.isCancelled)
        let statuses = await calls.value
        XCTAssertEqual(statuses, 2, "the dashboard asks again rather than show an old answer as fresh")
        XCTAssertFalse(prefetch.isUsable(for: 1))
    }

    func testAPrefetchThatGotNoAnswerIsRetriedOnce() async {
        let source = StubSource(), calls = Counter(), model = DashboardModel()
        source.statusHandler = {
            if await calls.next() == 1 { throw VoltaError.unreachable("timed out while suspended") }
            return makeStatus(battery: 66)
        }
        let prefetch = DashboardPrefetch(dataSource: source, vehicleID: 1, surfaces: nil)
        await model.load(dataSource: source, vehicleID: 1, initialVehicles: DashboardStart(prefetch: prefetch))
        let statuses = await calls.value
        XCTAssertEqual(statuses, 2)
        XCTAssertEqual(model.status?.batteryLevel, 66)
        XCTAssertNil(model.refreshError)
        XCTAssertEqual(model.phase, .loaded)

        // A server error is the answer: no second request.
        let rejecting = StubSource(), rejected = Counter(), other = DashboardModel()
        rejecting.statusHandler = { _ = await rejected.next(); throw VoltaError.server(code: "data_unavailable", message: "none") }
        let failed = DashboardPrefetch(dataSource: rejecting, vehicleID: 1, surfaces: nil)
        await other.load(dataSource: rejecting, vehicleID: 1, initialVehicles: DashboardStart(prefetch: failed))
        let rejections = await rejected.value
        XCTAssertEqual(rejections, 1)
        XCTAssertEqual(other.phase, .noData)
    }

    func testRemoveDropsAQueuedWriteThatIsStillRunning() async throws {
        let url = FileManager.default.temporaryDirectory.appending(path: "saved-race-\(UUID())/saved-dashboard.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let gate = SectionGate(), started = Mutex(false)
        let file = SavedDashboardFile(url: url) { started.withLock { $0 = true }; await gate.wait() }
        file.acceptedBackend = "backend-a"
        file.write(saved(backend: "backend-a"))
        await waitUntil { started.withLock { $0 } }
        file.remove()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "deleted before remove() returns")
        await gate.open()
        await file.drain()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "the queued write cannot recreate it")

        // Writes queued after the removal still land.
        file.write(saved(backend: "backend-a"))
        await file.drain()
        XCTAssertNotNil(file.read(backend: "backend-a"))
    }

    func testSavedFileIsProtectedAndItsFolderExcludedFromBackup() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "saved-attrs-\(UUID())", directoryHint: .isDirectory)
        let url = folder.appending(path: "saved-dashboard.json")
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = SavedDashboardFile(url: url)
        file.acceptedBackend = "backend-a"
        file.write(saved(backend: "backend-a"))
        await file.drain()
        let values = try folder.resourceValues(forKeys: [.isExcludedFromBackupKey])
        XCTAssertEqual(values.isExcludedFromBackup, true)
        XCTAssertTrue(SavedDashboardFile.writeOptions.contains(.completeFileProtection))
        let protection = try FileManager.default.attributesOfItem(atPath: url.path)[.protectionKey] as? FileProtectionType
        #if targetEnvironment(simulator)
        // The simulator has no data protection and reports none; devices do.
        if let protection { XCTAssertEqual(protection, .complete) }
        #else
        XCTAssertEqual(protection, .complete)
        #endif
    }

    func testSavedStatusEnablesNoCommandUntilTheSheetHasFreshStatus() async throws {
        enum StatusMode { case gated, fails, fresh }
        let mode = Mutex(StatusMode.fresh), commands = Mutex<[String]>([])
        let release = DispatchSemaphore(value: 0)
        let capabilities = try JSONSerialization.data(withJSONObject: [
            "available": true, "commands": Array(VehicleCommand.supportedNames).sorted()])
        var fresh = try XCTUnwrap(JSONSerialization.jsonObject(with: DecodingTests.fixture("status")) as? [String: Any])
        fresh["chargeLimit"] = 90
        let freshData = try JSONSerialization.data(withJSONObject: fresh)
        StubProtocol.handler.withLock {
            $0 = { request in
                let path = request.url?.path ?? ""
                if path == "/v1/vehicles/1/commands" { return (200, capabilities) }
                if path.hasPrefix("/v1/vehicles/1/commands/") {
                    let name = String(path.dropFirst("/v1/vehicles/1/commands/".count))
                    commands.withLock { $0.append(name) }
                    return (200, Data(#"{"ok":true,"command":"\#(name)","requestId":"request_123"}"#.utf8))
                }
                switch mode.withLock({ $0 }) {
                case .gated: release.wait(); return (200, freshData)
                case .fails: return (503, try DecodingTests.fixture("error"))
                case .fresh: return (200, freshData)
                }
            }
        }
        StubProtocol.responseHeaders.withLock { $0 = [:] }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        let api = APIDataSource(baseURL: URL(string: "https://volta.example")!, token: "synthetic-\(UUID())",
                                session: URLSession(configuration: config))
        let coordinator = VehicleCommandCoordinator(store: VehicleCommandIntentStore(inMemory: []))

        // Saved status from the last launch: charge limit 80, a location
        // observed just now (as saved), which HomeLink would otherwise accept.
        var savedStatus = makeStatus()
        savedStatus.location = Location(latitude: 37.4419, longitude: -122.143)
        savedStatus.locationUpdatedAt = .now
        var dashboard = saved(); dashboard.status = savedStatus
        let controls = ControlsModel(status: dashboard.labelledStatus)
        XCTAssertNil(ControlsView.homeLinkCommand(status: controls.status), "saved status never offers HomeLink")

        // The sheet opens: capabilities succeed while its status is held back.
        _ = try await api.displayStatus(vehicleID: 1)  // the dashboard's status never counts
        mode.withLock { $0 = .gated }
        await coordinator.refreshCapabilities(dataSource: api, vehicleID: 1)
        XCTAssertTrue(coordinator.supports(.setChargeLimit(percent: 85), dataSource: api, vehicleID: 1))
        let pending = Task { await controls.refresh(dataSource: api, vehicleID: 1) }
        XCTAssertFalse(coordinator.canStart(.setChargeLimit(percent: 85), dataSource: api, vehicleID: 1))
        await controls.adjustChargeLimit(by: 5, coordinator: coordinator, dataSource: api, vehicleID: 1)
        XCTAssertEqual(controls.chargeLimit, 80)
        release.signal()
        await pending.value
        XCTAssertEqual(commands.withLock { $0 }, [], "no command while the sheet's status was pending")

        // Reopened: the status request fails, so the saved values stay unusable.
        let reopened = ControlsModel(status: dashboard.labelledStatus)
        mode.withLock { $0 = .fails }
        await coordinator.refreshCapabilities(dataSource: api, vehicleID: 1)
        await reopened.refresh(dataSource: api, vehicleID: 1)
        await reopened.adjustChargeLimit(by: 5, coordinator: coordinator, dataSource: api, vehicleID: 1)
        await reopened.setLocked(false, coordinator: coordinator, dataSource: api, vehicleID: 1)
        XCTAssertEqual(commands.withLock { $0 }, [], "no command after the refresh failed")

        // A fresh status from the sheet itself enables commands, based on it.
        mode.withLock { $0 = .fresh }
        await reopened.refresh(dataSource: api, vehicleID: 1)
        XCTAssertEqual(reopened.chargeLimit, 90)
        XCTAssertTrue(coordinator.canStart(.setChargeLimit(percent: 95), dataSource: api, vehicleID: 1))
        await reopened.adjustChargeLimit(by: 5, coordinator: coordinator, dataSource: api, vehicleID: 1)
        XCTAssertEqual(commands.withLock { $0 }, ["set_charge_limit"])
    }

    func testLiveChargingNamesSavedDataAndAFailedRefresh() {
        var status = makeStatus()
        status.chargingState = .charging; status.chargerPowerKw = 11
        XCTAssertEqual(LiveChargingSheet.stateText(status), "CHARGING")
        XCTAssertNil(LiveChargingSheet.provenance(status, refreshFailed: true))

        var dashboard = saved(); dashboard.status = status
        let savedCharging = dashboard.labelledStatus
        XCTAssertEqual(LiveChargingSheet.stateText(savedCharging), "SAVED DATA", "a saved session never reads as live")
        XCTAssertEqual(LiveChargingSheet.provenance(savedCharging, refreshFailed: false)?.hasPrefix("Saved data from"), true)
        let failed = LiveChargingSheet.provenance(savedCharging, refreshFailed: true)
        XCTAssertEqual(failed?.hasPrefix("Couldn't refresh · saved data from"), true)
    }
}
