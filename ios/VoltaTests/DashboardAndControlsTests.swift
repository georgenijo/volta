import XCTest
@testable import Volta

// MARK: - Test doubles

/// Data source whose dashboard calls are driven by per-test handlers.
private final class StubSource: VoltaDataSource, @unchecked Sendable {
    var statusHandler: @Sendable () async throws -> VehicleStatus = { makeStatus() }
    var timelineHandler: @Sendable () async throws -> [TimelineSegment] = { [] }
    var summaryHandler: @Sendable (SummaryRange) async throws -> ActivitySummary = { makeSummary($0) }
    var commandHandler: @Sendable (String) async throws -> Void = { _ in throw VoltaError.commandsUnavailable }
    let commands = Recorder()

    func vehicles() async throws -> [Vehicle] { [Vehicle(id: 1, name: "Friday")] }
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
    func command(vehicleID: Int, name: String, params: [String: String]) async throws {
        await commands.append(name)
        try await commandHandler(name)
    }
}

private actor Recorder {
    private(set) var names: [String] = []
    func append(_ name: String) { names.append(name) }
}

private actor Counter {
    private(set) var value = 0
    func next() -> Int { value += 1; return value }
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

    func testCancellationErrorFromSectionIsNotTreatedAsFailure() async {
        let source = StubSource()
        let model = DashboardModel()
        await model.load(dataSource: source, vehicleID: 1)
        source.statusHandler = { makeStatus(battery: 50) }
        source.timelineHandler = { throw CancellationError() }
        await model.load(dataSource: source, vehicleID: 1)
        XCTAssertEqual(model.status?.batteryLevel, 72, "cancelled refresh publishes nothing")
        XCTAssertTrue(model.failedSections.isEmpty)
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
    func testCommandsUnavailableBlocksBeforeAnyMutationOrDispatch() async {
        let source = StubSource()
        let model = ControlsModel(status: makeStatus(locked: true, climateOn: false, sentry: false, chargeLimit: 80))
        XCTAssertFalse(model.canSend)

        let sent = [
            await model.setLocked(false, dataSource: source, vehicleID: 1),
            await model.setClimate(true, dataSource: source, vehicleID: 1),
            await model.setSentry(true, dataSource: source, vehicleID: 1),
            await model.setCharging(true, dataSource: source, vehicleID: 1),
            await model.adjustChargeLimit(by: 5, dataSource: source, vehicleID: 1),
            await model.perform(VehicleCommand.honk, label: "Honk", dataSource: source, vehicleID: 1),
        ]
        XCTAssertEqual(sent, [false, false, false, false, false, false])
        XCTAssertEqual(model.locked, true)
        XCTAssertEqual(model.climateOn, false)
        XCTAssertEqual(model.sentry, false)
        XCTAssertEqual(model.chargingState, .disconnected)
        XCTAssertEqual(model.chargeLimit, 80)
        XCTAssertNil(model.toast)
        let names = await source.commands.names
        XCTAssertTrue(names.isEmpty, "no command may reach the data source")
    }

    func testRejectedCommandRevertsAndDisablesCommands() async {
        let source = StubSource()
        let model = ControlsModel(status: makeStatus(locked: true), commandsAvailable: true)
        let ok = await model.setLocked(false, dataSource: source, vehicleID: 1)
        XCTAssertFalse(ok)
        XCTAssertEqual(model.locked, true, "optimistic change reverted")
        XCTAssertFalse(model.commandsAvailable)
        XCTAssertFalse(model.canSend)
        XCTAssertEqual(model.toast?.isError, true)
        let names = await source.commands.names
        XCTAssertEqual(names, [VehicleCommand.unlock])
    }

    func testSuccessfulCommandKeepsNewState() async {
        let source = StubSource()
        source.commandHandler = { _ in }
        let model = ControlsModel(status: makeStatus(chargeLimit: 80), commandsAvailable: true)
        let ok = await model.adjustChargeLimit(by: 5, dataSource: source, vehicleID: 1)
        XCTAssertTrue(ok)
        XCTAssertEqual(model.chargeLimit, 85)
        XCTAssertNil(model.busy)
        let names = await source.commands.names
        XCTAssertEqual(names, [VehicleCommand.setChargeLimit])
    }

    func testUnknownStatesStayUnknown() async {
        let source = StubSource()
        source.commandHandler = { _ in }
        let model = ControlsModel(status: makeStatus(locked: nil, climateOn: nil, sentry: nil,
                                                     chargeLimit: nil, chargingState: nil),
                                  commandsAvailable: true)
        XCTAssertNil(model.locked)
        XCTAssertNil(model.climateOn)
        XCTAssertNil(model.sentry)
        XCTAssertNil(model.chargeLimit)
        XCTAssertNil(model.chargingState)
        let adjusted = await model.adjustChargeLimit(by: 5, dataSource: source, vehicleID: 1)
        XCTAssertFalse(adjusted, "can't step an unknown limit")
        XCTAssertNil(model.chargeLimit)
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

    func testCancelledRefreshPublishesNothing() async {
        let source = StubSource()
        let started = Counter()
        let (gate, opener) = AsyncStream<Void>.makeStream()
        source.statusHandler = {
            _ = await started.next()
            for await _ in gate { break }
            return makeStatus(locked: false)
        }
        let model = ControlsModel(status: makeStatus(locked: true))
        let task = Task { await model.refresh(dataSource: source, vehicleID: 1) }
        while await started.value < 1 { await Task.yield() }
        task.cancel()
        opener.yield(())
        await task.value
        XCTAssertEqual(model.locked, true)
        XCTAssertNil(model.toast, "cancellation isn't a failure")
    }

    func testRefreshStartedBeforeCommandCannotOverwriteCommandResult() async {
        let source = StubSource()
        source.commandHandler = { _ in }
        let started = Counter()
        let (gate, opener) = AsyncStream<Void>.makeStream()
        source.statusHandler = {
            _ = await started.next()
            for await _ in gate { break }
            return makeStatus(locked: true)
        }
        let model = ControlsModel(status: makeStatus(locked: true), commandsAvailable: true)
        let refresh = Task { await model.refresh(dataSource: source, vehicleID: 1) }
        while await started.value < 1 { await Task.yield() }

        let ok = await model.setLocked(false, dataSource: source, vehicleID: 1)
        XCTAssertTrue(ok)
        XCTAssertNil(model.busy)

        opener.yield(())
        await refresh.value
        XCTAssertEqual(model.locked, false, "pre-command refresh must not publish")
    }

    func testRefreshFailureKeepsCurrentStatus() async {
        let source = StubSource()
        source.statusHandler = { throw Boom() }
        let model = ControlsModel(status: makeStatus(locked: true))
        await model.refresh(dataSource: source, vehicleID: 1)
        XCTAssertEqual(model.locked, true)
        XCTAssertEqual(model.status?.locked, true)
    }

    func testChargeLimitClampsAtBounds() async {
        let source = StubSource()
        source.commandHandler = { _ in }
        let model = ControlsModel(status: makeStatus(chargeLimit: 100), commandsAvailable: true)
        let sent = await model.adjustChargeLimit(by: 5, dataSource: source, vehicleID: 1)
        XCTAssertFalse(sent)
        XCTAssertEqual(model.chargeLimit, 100)
    }
}
