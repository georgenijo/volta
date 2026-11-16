import XCTest
@testable import Volta

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func driving(_ drive: LiveDrive?, state: VehicleState = .driving) -> VehicleStatus {
    var status = VehicleStatus.skeleton
    status.vehicleId = MockDataSource.vehicleID
    status.state = state
    status.liveDrive = drive
    return status
}

private func reading<T>(_ value: T, ago: TimeInterval = 1, current: Bool = true) -> LiveDrive.Reading<T> {
    LiveDrive.Reading(value: value, observedAt: now.addingTimeInterval(-ago), current: current, source: "fleet_telemetry")
}

private let moving = LiveDrive(gear: reading(.d, ago: 300), speedKph: reading(64), powerKw: reading(42))

@MainActor final class LiveDrivingTests: XCTestCase {
    // MARK: When the card shows

    func testALiveGearDecidesWhetherTheCarDrives() {
        XCTAssertTrue(LiveDriveDisplay.isDriving(driving(nil)), "TeslaMate's open drive alone")
        XCTAssertFalse(LiveDriveDisplay.isDriving(driving(nil, state: .online)))
        XCTAssertFalse(LiveDriveDisplay.isDriving(driving(LiveDrive(gear: reading(.p)))),
                       "Park ends the drive before TeslaMate closes it")
        for gear in [LiveDrive.Gear.r, .n, .d] {
            XCTAssertTrue(LiveDriveDisplay.isDriving(driving(LiveDrive(gear: reading(gear)), state: .online)),
                          "\(gear) starts it before TeslaMate opens one")
        }
        XCTAssertFalse(LiveDriveDisplay.isDriving(driving(LiveDrive(gear: reading(.d, current: false)), state: .online)),
                       "a gear that does not hold now says nothing")
        var saved = driving(LiveDrive(gear: reading(.d)), state: .online)
        saved.telemetryFreshness = TelemetryFreshness(connected: true, lastSeenAt: now, recordedAt: [:], savedAt: now)
        XCTAssertFalse(LiveDriveDisplay.isDriving(saved), "a saved gear is never live")
    }

    func testTheNowCardSwitchesToDrivingAndBack() {
        XCTAssertEqual(NowVariant.of(driving(moving, state: .online)), .driving)
        XCTAssertEqual(NowVariant.of(driving(LiveDrive(gear: reading(.p)))), .parked)
        var plugged = driving(LiveDrive(gear: reading(.p)))
        plugged.chargingState = .complete
        XCTAssertEqual(NowVariant.of(plugged), .pluggedIn)
        XCTAssertEqual(NowCard.accent(for: .driving), .voltaBlue)
    }

    // MARK: Honest values

    func testLiveReadingsAreLive() {
        let display = LiveDriveDisplay.make(driving(moving), fetchedAt: now.addingTimeInterval(-2), now: now)
        XCTAssertEqual(display.speed, .live(kph: 64))
        XCTAssertEqual(display.power, .live(kw: 42))
        XCTAssertEqual(display.gear, .d)
        XCTAssertTrue(display.gearIsLive)
        XCTAssertEqual(display.freshness, .live)
        XCTAssertEqual(LiveDriveText.freshness(display.freshness, now: now), "Live")
    }

    func testUnknownValuesStayUnknownNotZero() {
        let display = LiveDriveDisplay.make(driving(nil), fetchedAt: now, now: now)
        XCTAssertEqual(display.speed, .unknown)
        XCTAssertEqual(display.power, .unknown)
        XCTAssertNil(display.gear)
        XCTAssertEqual(display.freshness, .unknown)
        XCTAssertEqual(LiveDriveText.freshness(display.freshness, now: now), "No data")
        let spoken = LiveDriveText.accessibility(display, units: .default, now: now)
        XCTAssertTrue(spoken.contains("Speed unknown") && spoken.contains("Power unknown") && spoken.contains("Gear unknown"), spoken)
        XCTAssertFalse(spoken.contains("0"), spoken)
    }

    func testReadingsTheServerDoesNotCallCurrentAreStaleWithTheirAge() {
        let lost = LiveDrive(gear: reading(.d, ago: 600, current: false), speedKph: reading(87, ago: 75, current: false),
                             powerKw: reading(24, ago: 75, current: false))
        let display = LiveDriveDisplay.make(driving(lost), fetchedAt: now, now: now)
        XCTAssertEqual(display.speed, .stale(kph: 87, at: now.addingTimeInterval(-75)))
        XCTAssertEqual(display.power, .stale(kw: 24, at: now.addingTimeInterval(-75)))
        XCTAssertFalse(display.gearIsLive)
        XCTAssertEqual(display.freshness, .lastReading(at: now.addingTimeInterval(-75)))
        XCTAssertTrue(display.isStale)
        XCTAssertEqual(LiveDriveText.freshness(display.freshness, now: now), "1m old")
        // The card says its age once, not per value.
        let spoken = LiveDriveText.accessibility(display, units: .default, now: now)
        XCTAssertEqual(spoken.components(separatedBy: "ago").count - 1, 1, spoken)
        XCTAssertTrue(spoken.contains("Last reading"), spoken)
    }

    func testAgesReadNaturally() {
        XCTAssertEqual(LiveDriveText.shortAge(now.addingTimeInterval(-12), now: now), "12s")
        XCTAssertEqual(LiveDriveText.shortAge(now.addingTimeInterval(-130), now: now), "2m")
        XCTAssertEqual(LiveDriveText.shortAge(now.addingTimeInterval(-7300), now: now), "2h")
        XCTAssertEqual(LiveDriveText.shortAge(now.addingTimeInterval(3), now: now), "1s", "a reading from a fast clock is not in the future")
        // The hero's "Updated" never reads "in 0 sec.".
        var status = driving(nil)
        status.updatedAt = now.addingTimeInterval(0.4)
        XCTAssertEqual(DashboardView.freshness(status, now: now).text, "Updated just now")
    }

    func testAStatusNotRefreshedForFifteenSecondsStopsBeingLive() {
        let fetched = now.addingTimeInterval(-16)
        let display = LiveDriveDisplay.make(driving(moving), fetchedAt: fetched, now: now)
        XCTAssertEqual(display.speed, .stale(kph: 64, at: now.addingTimeInterval(-1)))
        XCTAssertEqual(display.power, .stale(kw: 42, at: now.addingTimeInterval(-1)))
        XCTAssertFalse(display.gearIsLive)
        XCTAssertEqual(display.freshness, .notRefreshed(since: fetched))
        XCTAssertEqual(LiveDriveText.freshness(display.freshness, now: now), "16s old")
        XCTAssertEqual(LiveDriveDisplay.make(driving(moving), fetchedAt: now.addingTimeInterval(-15), now: now).freshness, .live)
        XCTAssertEqual(LiveDriveDisplay.make(driving(moving), fetchedAt: nil, now: now).speed,
                       .stale(kph: 64, at: now.addingTimeInterval(-1)), "never fetched here: never live")
    }

    func testAQuietCarShowsStoppedNotZeroOrTheHeldSpeed() {
        let quiet = now.addingTimeInterval(-40)
        let drive = LiveDrive(gear: reading(.d, ago: 300), speedKph: reading(6.4, ago: 40, current: false),
                              powerKw: reading(-2, ago: 40, current: false),
                              quiet: LiveDrive.Quiet(since: quiet, speedBelowKph: 0.29))
        let display = LiveDriveDisplay.make(driving(drive), fetchedAt: now, now: now)
        XCTAssertEqual(display.speed, .stopped(since: quiet))
        XCTAssertEqual(display.power, .awaitingMovement, "the held power is from before the car went quiet")
        XCTAssertEqual(display.freshness, .live)
        let spoken = LiveDriveText.accessibility(display, units: .default, now: now)
        XCTAssertTrue(spoken.contains("Stopped for"), spoken)
        XCTAssertFalse(spoken.contains("6") || spoken.contains(" 0 "), "neither the held speed nor an invented zero: \(spoken)")
        // A looser bound is not called a stop: it says what is known.
        var looser = drive
        looser.quiet = LiveDrive.Quiet(since: quiet, speedBelowKph: 1.35)
        let slow = LiveDriveDisplay.make(driving(looser), fetchedAt: now, now: now)
        XCTAssertEqual(slow.speed, .slow(belowKph: 1.35, since: quiet))
        XCTAssertEqual(slow.power, .awaitingMovement)
        var metric = UnitPreferences.default
        metric.distance = .kilometers
        XCTAssertEqual(LiveDriveText.below(kph: 1.35, units: .default), "Under 1 mph")
        XCTAssertEqual(LiveDriveText.below(kph: 1.35, units: metric), "Under 2 km/h", "rounded up, so it stays true")
        let slowSpoken = LiveDriveText.accessibility(slow, units: .default, now: now)
        XCTAssertTrue(slowSpoken.contains("Under 1 miles per hour, no movement reported"), slowSpoken)
        XCTAssertFalse(slowSpoken.contains("Stopped"), slowSpoken)
        // Stillness is as old as the fetch: an unrefreshed status shows the held reading's age instead.
        XCTAssertEqual(LiveDriveDisplay.make(driving(drive), fetchedAt: now.addingTimeInterval(-30), now: now).speed,
                       .stale(kph: 6.4, at: quiet))
    }

    func testASavedDashboardNeverShowsLiveDriving() {
        var status = driving(moving)
        status.telemetryFreshness = TelemetryFreshness(connected: true, lastSeenAt: now, recordedAt: [:])
        let saved = SavedDashboard(backend: "test", vehicleID: status.vehicleId, savedAt: now.addingTimeInterval(-3600),
                                   vehicles: [], status: status, timeline: [], summaries: [],
                                   todayRequestedAt: nil, todayRequestedZone: nil)
        XCTAssertNil(saved.labelledStatus.liveDrive, "an earlier launch's drive is not this one")
        // Even a saved status that kept its readings shows none of them.
        status.telemetryFreshness?.savedAt = now.addingTimeInterval(-3600)
        let display = LiveDriveDisplay.make(status, fetchedAt: now, now: now)
        XCTAssertEqual(display.speed, .unknown)
        XCTAssertEqual(display.power, .unknown)
        XCTAssertNil(display.gear)
        XCTAssertEqual(display.freshness, .saved(at: now.addingTimeInterval(-3600)))
        XCTAssertFalse(LiveDrivingRefresher.shouldRun(visible: true, sceneActive: true, unlocked: true, status: status))
    }

    // MARK: Drive and regen

    func testRegenAndDrivePowerAreDifferent() {
        XCTAssertEqual(LiveDriveText.kind(kw: 42), .drive)
        XCTAssertEqual(LiveDriveText.kind(kw: -18), .regen)
        XCTAssertEqual(LiveDriveText.kind(kw: 0.3), .idle)
        XCTAssertEqual(LiveDriveText.power(kw: -18.4), "18", "the label carries the direction")
        XCTAssertEqual(LiveDriveText.power(kw: 0.2), "0")
        XCTAssertEqual(LiveDriveText.powerTitle(.live(kw: -18)), "Regen")
        XCTAssertEqual(LiveDriveText.powerTitle(.live(kw: 42)), "Power")
        var regen = moving
        regen.powerKw = reading(-18)
        let spoken = LiveDriveText.accessibility(LiveDriveDisplay.make(driving(regen), fetchedAt: now, now: now),
                                                 units: .default, now: now)
        XCTAssertTrue(spoken.contains("Regenerating 18 kilowatts"), spoken)
        XCTAssertTrue(LiveDriveText.accessibility(LiveDriveDisplay.make(driving(moving), fetchedAt: now, now: now),
                                                  units: .default, now: now).contains("Using 42 kilowatts"))
    }

    func testThePowerMeterSharesOneScaleAroundZero() {
        XCTAssertEqual(PowerMeter.zero, 0.25)
        XCTAssertEqual(PowerMeter.span(kw: 0), 0.25...0.25)
        XCTAssertEqual(PowerMeter.span(kw: -50), 0...0.25)
        XCTAssertEqual(PowerMeter.span(kw: 150), 0.25...1)
        XCTAssertEqual(PowerMeter.span(kw: -500), 0...0.25, "clamped")
        let drive = PowerMeter.span(kw: 30), regen = PowerMeter.span(kw: -30)
        XCTAssertEqual(drive.upperBound - drive.lowerBound, regen.upperBound - regen.lowerBound, accuracy: 1e-9)
    }

    // MARK: Units and gear

    func testSpeedFollowsTheUnitSetting() {
        var miles = UnitPreferences.default
        miles.distance = .miles
        XCTAssertEqual(LiveDriveText.speed(kph: 64.37, units: miles), "40")
        XCTAssertEqual(LiveDriveText.speedUnit(miles), "mph")
        var metric = UnitPreferences.default
        metric.distance = .kilometers
        XCTAssertEqual(LiveDriveText.speed(kph: 64.37, units: metric), "64")
        XCTAssertEqual(LiveDriveText.speedUnit(metric), "km/h")
    }

    func testGearDecodesAndAnythingElseIsUnknownWithoutFailingTheStatus() throws {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        for gear in ["P", "R", "N", "D"] {
            let json = #"{"gear":{"value":"\#(gear)","observedAt":"2026-01-02T12:00:00Z","current":true,"source":"fleet_telemetry"}}"#
            XCTAssertEqual(try decoder.decode(LiveDrive.self, from: Data(json.utf8)).gear?.value.rawValue, gear)
        }
        let odd = #"{"gear":{"value":"X","observedAt":"2026-01-02T12:00:00Z","current":true},"speedKph":{"value":"fast"},"powerKw":{"value":-12.5,"observedAt":"2026-01-02T12:00:00Z","current":false},"quiet":{"since":"soon"}}"#
        let drive = try decoder.decode(LiveDrive.self, from: Data(odd.utf8))
        XCTAssertNil(drive.gear)
        XCTAssertNil(drive.speedKph)
        XCTAssertEqual(drive.powerKw?.value, -12.5)
        XCTAssertNil(drive.quiet, "a malformed quiet span is unknown")
        // A malformed block leaves the rest of the status intact.
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(VehicleStatus.skeleton)) as? [String: Any])
        object["liveDrive"] = "garbage"
        let status = try JSONDecoder().decode(VehicleStatus.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(status.liveDrive, LiveDrive())
        XCTAssertFalse(LiveDriveDisplay.isDriving(status))
        object["liveDrive"] = nil
        XCTAssertNil(try JSONDecoder().decode(VehicleStatus.self, from: JSONSerialization.data(withJSONObject: object)).liveDrive,
                     "older servers send none")
    }

    // MARK: Refreshing

    func testRefreshRunsOnlyWhileVisibleActiveUnlockedAndDriving() {
        let status = driving(moving)
        XCTAssertTrue(LiveDrivingRefresher.shouldRun(visible: true, sceneActive: true, unlocked: true, status: status))
        XCTAssertFalse(LiveDrivingRefresher.shouldRun(visible: false, sceneActive: true, unlocked: true, status: status))
        XCTAssertFalse(LiveDrivingRefresher.shouldRun(visible: true, sceneActive: false, unlocked: true, status: status))
        XCTAssertFalse(LiveDrivingRefresher.shouldRun(visible: true, sceneActive: true, unlocked: true, status: nil))
        XCTAssertFalse(LiveDrivingRefresher.shouldRun(visible: true, sceneActive: true, unlocked: true,
                                                      status: driving(LiveDrive(gear: reading(.p)))))
        // Behind the app lock (reopened, authentication cancelled): no refresh, no publishing.
        XCTAssertFalse(LiveDrivingRefresher.shouldRun(visible: true, sceneActive: true, unlocked: false, status: status))
    }

    func testRefreshShowsEachStatusAndStopsWhenTheDriveEnds() async {
        let source = ScriptedStatusSource(steps: [.status(driving(moving)), .failure, .status(driving(moving)),
                                                 .status(driving(LiveDrive(gear: reading(.p)), state: .online))])
        let model = DashboardModel()
        let surfaces = CountingSurfaces()
        await model.load(dataSource: source, vehicleID: MockDataSource.vehicleID, surfaces: surfaces)
        var clock = Date()
        let refresher = LiveDrivingRefresher(sleep: { _ in await Task.yield() })
        let outcome = await refresher.run(dashboard: model, dataSource: source, vehicleID: MockDataSource.vehicleID,
                                          surfaces: surfaces, now: { clock = clock.addingTimeInterval(5); return clock })
        XCTAssertEqual(outcome, .driveEnded)
        XCTAssertFalse(refresher.isRunning)
        XCTAssertEqual(model.status?.liveDrive?.gear?.value, .p, "the parked status is shown")
        XCTAssertEqual(source.statusRequests, 4, "one load, then one request per refresh, failures included")
        XCTAssertEqual(surfaces.published.count, 2, "the load, then the end of the drive; not every refresh")
        XCTAssertEqual(surfaces.published.last?.status.state, .online)
    }

    func testRefreshPublishesToSurfacesAtMostEveryThirtySeconds() async {
        var script = Array(repeating: ScriptedStatusSource.Step.status(driving(moving)), count: 14)
        script.append(.status(driving(nil, state: .online)))
        let source = ScriptedStatusSource(steps: script)
        let model = DashboardModel()
        await model.load(dataSource: source, vehicleID: MockDataSource.vehicleID)
        let surfaces = CountingSurfaces()
        var clock = now
        let refresher = LiveDrivingRefresher(sleep: { _ in await Task.yield() })
        _ = await refresher.run(dashboard: model, dataSource: source, vehicleID: MockDataSource.vehicleID,
                                surfaces: surfaces, now: { clock = clock.addingTimeInterval(5); return clock })
        // 13 driving refreshes 5 s apart after a load that published nothing:
        // the first publishes, then every 30 s (35, 65), then the end.
        XCTAssertEqual(surfaces.published.count, 4)
        let tokens = surfaces.published.map(\.issued.value)
        XCTAssertEqual(tokens, tokens.sorted(), "issue order is kept")
    }

    func testShortVisitsDoNotPostponeSurfaceUpdates() async {
        let source = ScriptedStatusSource(steps: [.status(driving(moving))])
        let model = DashboardModel()
        let surfaces = CountingSurfaces()
        await model.load(dataSource: source, vehicleID: MockDataSource.vehicleID, surfaces: surfaces)
        XCTAssertEqual(surfaces.published.count, 1, "the load publishes")
        let clock = TestClock(Date()), sleeps = TestCounter()
        // Each visit refreshes four times (20 s), then the screen is left.
        let refresher = LiveDrivingRefresher(sleep: { _ in
            if sleeps.next() % 5 == 0 { throw CancellationError() }
            await Task.yield()
        })
        for _ in 0..<3 {
            let outcome = await refresher.run(dashboard: model, dataSource: source, vehicleID: MockDataSource.vehicleID,
                                              surfaces: surfaces, now: { clock.advance(5) })
            XCTAssertEqual(outcome, .cancelled)
            _ = clock.advance(10) // away from the Dashboard
        }
        // Refreshes at 5–20, 35–50, 65–80 s: due 30 s after the load's publish, then 30 s after that.
        XCTAssertEqual(surfaces.published.count, 3, "20 s visits keep the real last publication")
    }

    func testOnlyAcceptedPublicationsCountTowardTheThirtySeconds() async {
        let source = ScriptedStatusSource(steps: [.status(driving(moving))])
        let model = DashboardModel()
        let refusing = CountingSurfaces()
        refusing.refusals = 1
        await model.load(dataSource: source, vehicleID: MockDataSource.vehicleID, surfaces: refusing)
        XCTAssertNil(model.surfacesPublishedAt, "an older token's publication was rejected: not an update")
        // The refresher's first publication is rejected too; the next refresh tries again.
        let surfaces = CountingSurfaces()
        surfaces.refusals = 1
        let clock = TestClock(Date()), sleeps = TestCounter()
        let refresher = LiveDrivingRefresher(sleep: { _ in
            if sleeps.next() > 3 { throw CancellationError() }
            await Task.yield()
        })
        _ = await refresher.run(dashboard: model, dataSource: source, vehicleID: MockDataSource.vehicleID,
                                surfaces: surfaces, now: { clock.advance(5) })
        XCTAssertEqual(surfaces.published.count, 1, "rejected at 5 s, taken at 10 s, not due at 15 s")
        XCTAssertEqual(surfaces.published.first?.issued.value, 2)
    }

    func testTheDriveEndingReloadsHistoryOnceOutsideTheRefresh() async {
        let source = ScriptedStatusSource(steps: [.status(driving(moving)), .status(driving(LiveDrive(gear: reading(.p)), state: .online))])
        let model = DashboardModel()
        await model.load(dataSource: source, vehicleID: MockDataSource.vehicleID)
        let refresher = LiveDrivingRefresher(sleep: { _ in await Task.yield() })
        XCTAssertFalse(refresher.reloadDue)
        let outcome = await refresher.run(dashboard: model, dataSource: source, vehicleID: MockDataSource.vehicleID, surfaces: nil)
        XCTAssertEqual(outcome, .driveEnded)
        XCTAssertTrue(refresher.reloadDue, "due after the refresh has ended, so cancelling it cannot lose the reload")
        // Leaving the screen cancels the reload; it stays due for the return.
        let left = Task { await refresher.reloadHistory { try? await Task.sleep(for: .seconds(30)) } }
        left.cancel()
        await left.value
        XCTAssertTrue(refresher.reloadDue)
        var loads = 0
        await refresher.reloadHistory { loads += 1 }
        await refresher.reloadHistory { loads += 1 }
        XCTAssertEqual(loads, 1, "once")
        XCTAssertFalse(refresher.reloadDue)
    }

    func testCancellingTheRefreshStopsItWithoutAnotherRequest() async {
        let source = ScriptedStatusSource(steps: [.status(driving(moving))])
        let model = DashboardModel()
        await model.load(dataSource: source, vehicleID: MockDataSource.vehicleID)
        let refresher = LiveDrivingRefresher(sleep: { _ in throw CancellationError() })
        let outcome = await refresher.run(dashboard: model, dataSource: source, vehicleID: MockDataSource.vehicleID,
                                          surfaces: nil)
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(source.statusRequests, 1)
        XCTAssertFalse(refresher.isRunning)
    }

    func testALoadInFlightWinsOverALiveAnswer() async {
        let model = DashboardModel()
        let source = ScriptedStatusSource(steps: [.status(driving(moving))])
        await model.load(dataSource: source, vehicleID: MockDataSource.vehicleID)
        let started = model.loadGeneration
        XCTAssertTrue(model.showLive(driving(moving), vehicleID: MockDataSource.vehicleID, startedGeneration: started))
        XCTAssertNotNil(model.lastLoadedAt)
        await model.load(dataSource: source, vehicleID: MockDataSource.vehicleID)
        XCTAssertFalse(model.showLive(driving(nil, state: .online), vehicleID: MockDataSource.vehicleID, startedGeneration: started),
                       "a load started after the request: its answer is newer")
        XCTAssertFalse(model.showLive(driving(moving), vehicleID: 99, startedGeneration: model.loadGeneration))
    }

    func testSlowHistoryDoesNotHoldBackLiveStatus() async throws {
        let source = ScriptedStatusSource(steps: [.status(driving(moving))])
        source.summaryDelay = .seconds(5)
        let model = DashboardModel()
        let load = Task { await model.load(dataSource: source, vehicleID: MockDataSource.vehicleID) }
        defer { load.cancel() }
        await waitUntil { model.status != nil }
        XCTAssertTrue(model.isLoading, "history is still loading")
        XCTAssertTrue(model.showLive(driving(LiveDrive(gear: reading(.n))), vehicleID: MockDataSource.vehicleID,
                                     startedGeneration: model.loadGeneration))
        XCTAssertEqual(model.status?.liveDrive?.gear?.value, .n)
    }

    func testALoadsPendingStatusRefusesALiveAnswer() async throws {
        let source = ScriptedStatusSource(steps: [.status(driving(moving))])
        let model = DashboardModel()
        await model.load(dataSource: source, vehicleID: MockDataSource.vehicleID)
        source.statusDelay = .seconds(5)
        let load = Task { await model.load(dataSource: source, vehicleID: MockDataSource.vehicleID) }
        defer { load.cancel() }
        await waitUntil { model.isLoading }
        XCTAssertFalse(model.showLive(driving(moving), vehicleID: MockDataSource.vehicleID, startedGeneration: model.loadGeneration),
                       "the load's own status is newer")
    }

    func testTheDrivingLiveActivityFollowsALiveGear() {
        XCTAssertEqual(LiveActivityPlanner.drivingObservation(driving(LiveDrive(gear: reading(.p)))), .ended,
                       "Park ends it while TeslaMate's drive is still open")
        XCTAssertEqual(LiveActivityPlanner.drivingObservation(driving(LiveDrive(gear: reading(.d)), state: .online)), .driving)
        XCTAssertEqual(LiveActivityPlanner.drivingObservation(driving(LiveDrive(gear: reading(.d, current: false)), state: .online)), .ended,
                       "a gear that does not hold now says nothing; state decides")
        XCTAssertEqual(LiveActivityPlanner.drivingObservation(driving(nil)), .driving)
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(2)) }
    }

    // MARK: Demo

    func testDemoModeDrivesBelievably() async throws {
        for scenario in MockDriving.allCases {
            var status = VehicleStatus.skeleton
            scenario.apply(to: &status, now: now)
            let display = LiveDriveDisplay.make(status, fetchedAt: now, now: now)
            switch scenario {
            case .parked: XCTAssertFalse(LiveDriveDisplay.isDriving(status))
            case .stale:
                XCTAssertTrue(LiveDriveDisplay.isDriving(status))
                XCTAssertNotEqual(display.freshness, .live)
            case .unknown:
                XCTAssertEqual(display.speed, .unknown)
            case .regen:
                guard case .live(let kw) = display.power else { return XCTFail("regen power") }
                XCTAssertLessThan(kw, 0)
            case .stopped:
                XCTAssertEqual(display.power, .awaitingMovement)
                XCTAssertEqual(display.speed, .stopped(since: now.addingTimeInterval(-38)))
            case .city, .cruising: XCTAssertEqual(display.freshness, .live)
            case .arriving: XCTAssertTrue(LiveDriveDisplay.isDriving(status), "cruises first")
            }
        }
        // The city loop moves: speeds differ across a minute.
        let speeds = stride(from: 0.0, to: 60, by: 3).map { offset -> LiveDriveDisplay.Speed in
            var status = VehicleStatus.skeleton
            let at = Date(timeIntervalSince1970: 1_800_000_040 + offset)
            MockDriving.city.apply(to: &status, now: at)
            return LiveDriveDisplay.make(status, fetchedAt: at, now: at).speed
        }
        XCTAssertGreaterThan(Set(speeds.map { "\($0)" }).count, 6)
        XCTAssertTrue(speeds.contains(where: \.isQuiet), "waits at a light")
    }
}

// MARK: - Fakes

private final class ScriptedStatusSource: VoltaDataSource, @unchecked Sendable {
    enum Step { case status(VehicleStatus), failure }
    private let lock = NSLock()
    private var steps: [Step]
    private var requests = 0
    private var delays: (status: Duration?, summary: Duration?) = (nil, nil)
    let base = MockDataSource(empty: false)
    var statusDelay: Duration? { get { lock.withLock { delays.status } } set { lock.withLock { delays.status = newValue } } }
    var summaryDelay: Duration? { get { lock.withLock { delays.summary } } set { lock.withLock { delays.summary = newValue } } }

    init(steps: [Step]) { self.steps = steps }

    var statusRequests: Int { lock.withLock { requests } }

    func status(vehicleID: Int) async throws -> VehicleStatus {
        if let delay = statusDelay { try await Task.sleep(for: delay) }
        let step: Step = lock.withLock {
            requests += 1
            return steps.count > 1 ? steps.removeFirst() : steps[0]
        }
        switch step {
        case .status(let status): return status
        case .failure: throw VoltaError.unreachable("scripted")
        }
    }
    func vehicles() async throws -> [Vehicle] { try await base.vehicles() }
    func summary(vehicleID: Int, range: SummaryRange) async throws -> ActivitySummary {
        if let delay = summaryDelay { try await Task.sleep(for: delay) }
        return try await base.summary(vehicleID: vehicleID, range: range)
    }
    func timeline(vehicleID: Int, hours: Int) async throws -> [TimelineSegment] { try await base.timeline(vehicleID: vehicleID, hours: hours) }
    func drives(vehicleID: Int, range: DateRange, cursor: String?) async throws -> Page<DriveSummary> { try await base.drives(vehicleID: vehicleID, range: range, cursor: cursor) }
    func drive(id: Int) async throws -> DriveDetail { try await base.drive(id: id) }
    func charges(vehicleID: Int, range: DateRange, cursor: String?) async throws -> Page<ChargeSummary> { try await base.charges(vehicleID: vehicleID, range: range, cursor: cursor) }
    func charge(id: Int) async throws -> ChargeDetail { try await base.charge(id: id) }
    func idles(vehicleID: Int, range: DateRange, cursor: String?) async throws -> Page<IdleSummary> { try await base.idles(vehicleID: vehicleID, range: range, cursor: cursor) }
    func battery(vehicleID: Int) async throws -> BatteryHealth { try await base.battery(vehicleID: vehicleID) }
    func mileage(vehicleID: Int, bucket: MileageBucketSize) async throws -> [MileageBucket] { try await base.mileage(vehicleID: vehicleID, bucket: bucket) }
    func firmware(vehicleID: Int) async throws -> [FirmwareUpdate] { try await base.firmware(vehicleID: vehicleID) }
    func places(vehicleID: Int) async throws -> [Place] { try await base.places(vehicleID: vehicleID) }
}

private final class TestClock: @unchecked Sendable {
    private var date: Date
    init(_ date: Date) { self.date = date }
    func advance(_ seconds: TimeInterval) -> Date { date += seconds; return date }
}

private final class TestCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Int { lock.withLock { count += 1; return count } }
}

@MainActor private final class CountingSurfaces: VehicleSurfaces {
    /// Publications to reject first, as an older token's would be.
    var refusals = 0
    var published: [VehicleRefresh] = []
    private var issued: UInt64 = 0
    func setContext(_ context: VehicleSurfaceContext) {}
    func nextStatusToken() -> StatusRequestToken { issued += 1; return StatusRequestToken(value: issued) }
    func publish(_ refresh: VehicleRefresh, dataSource: any VoltaDataSource) {
        _ = publishAccepted(refresh, dataSource: dataSource)
    }
    func publishAccepted(_ refresh: VehicleRefresh, dataSource: any VoltaDataSource) -> Bool {
        if refusals > 0 { refusals -= 1; return false }
        published.append(refresh)
        return true
    }
    func drivingActivityPreferenceChanged() {}
}
