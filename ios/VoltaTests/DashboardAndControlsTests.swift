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
