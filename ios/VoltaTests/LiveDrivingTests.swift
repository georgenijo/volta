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
        XCTAssertNil(LiveDriveText.freshness(display.freshness, now: now))
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
        XCTAssertNotEqual(LiveDriveText.freshness(display.freshness, now: now), "Live")
    }

    func testAStatusNotRefreshedForFifteenSecondsStopsBeingLive() {
        let fetched = now.addingTimeInterval(-16)
        let display = LiveDriveDisplay.make(driving(moving), fetchedAt: fetched, now: now)
        XCTAssertEqual(display.speed, .stale(kph: 64, at: now.addingTimeInterval(-1)))
        XCTAssertEqual(display.power, .stale(kw: 42, at: now.addingTimeInterval(-1)))
        XCTAssertFalse(display.gearIsLive)
        XCTAssertEqual(display.freshness, .notRefreshed(since: fetched))
        XCTAssertEqual(LiveDriveDisplay.make(driving(moving), fetchedAt: now.addingTimeInterval(-15), now: now).freshness, .live)
        XCTAssertEqual(LiveDriveDisplay.make(driving(moving), fetchedAt: nil, now: now).speed,
                       .stale(kph: 64, at: now.addingTimeInterval(-1)), "never fetched here: never live")
    }

    func testStoppedInDriveShowsStoppedNotTheHeldSpeed() {
        let quiet = now.addingTimeInterval(-40)
        let drive = LiveDrive(gear: reading(.d, ago: 300), speedKph: reading(6.4, ago: 40, current: false),
                              powerKw: reading(-2, ago: 40, current: false), stoppedSince: quiet)
        let display = LiveDriveDisplay.make(driving(drive), fetchedAt: now, now: now)
        XCTAssertEqual(display.speed, .stopped(since: quiet))
        XCTAssertEqual(display.power, .awaitingMovement, "the held power is from before the stop")
        XCTAssertEqual(display.freshness, .live)
        XCTAssertEqual(LiveDriveText.accessibility(display, units: .default, now: now).contains("Stopped"), true)
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
        XCTAssertFalse(LiveDrivingRefresher.shouldRun(visible: true, sceneActive: true, status: status))
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
        let odd = #"{"gear":{"value":"X","observedAt":"2026-01-02T12:00:00Z","current":true},"speedKph":{"value":"fast"},"powerKw":{"value":-12.5,"observedAt":"2026-01-02T12:00:00Z","current":false},"stoppedSince":null}"#
        let drive = try decoder.decode(LiveDrive.self, from: Data(odd.utf8))
        XCTAssertNil(drive.gear)
        XCTAssertNil(drive.speedKph)
        XCTAssertEqual(drive.powerKw?.value, -12.5)
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

    func testRefreshRunsOnlyWhileVisibleActiveAndDriving() {
        let status = driving(moving)
        XCTAssertTrue(LiveDrivingRefresher.shouldRun(visible: true, sceneActive: true, status: status))
        XCTAssertFalse(LiveDrivingRefresher.shouldRun(visible: false, sceneActive: true, status: status))
        XCTAssertFalse(LiveDrivingRefresher.shouldRun(visible: true, sceneActive: false, status: status))
        XCTAssertFalse(LiveDrivingRefresher.shouldRun(visible: true, sceneActive: true, status: nil))
        XCTAssertFalse(LiveDrivingRefresher.shouldRun(visible: true, sceneActive: true,
                                                      status: driving(LiveDrive(gear: reading(.p)))))
    }

    func testRefreshShowsEachStatusAndStopsWhenTheDriveEnds() async {
        let source = ScriptedStatusSource(steps: [.status(driving(moving)), .failure, .status(driving(moving)),
                                                 .status(driving(LiveDrive(gear: reading(.p)), state: .online))])
        let model = DashboardModel()
        await model.load(dataSource: source, vehicleID: MockDataSource.vehicleID)
        let surfaces = CountingSurfaces()
        var clock = now
        let refresher = LiveDrivingRefresher(sleep: { _ in await Task.yield() })
        let outcome = await refresher.run(dashboard: model, dataSource: source, vehicleID: MockDataSource.vehicleID,
                                          surfaces: surfaces, now: { clock = clock.addingTimeInterval(5); return clock })
        XCTAssertEqual(outcome, .driveEnded)
        XCTAssertFalse(refresher.isRunning)
        XCTAssertEqual(model.status?.liveDrive?.gear?.value, .p, "the parked status is shown")
        XCTAssertEqual(source.statusRequests, 4, "one load, then one request per refresh, failures included")
        XCTAssertEqual(surfaces.published.count, 1, "surfaces hear the end of the drive, not every refresh")
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
        // 13 driving refreshes 5 s apart, starting 5 s after the load: two publishes, then the end.
        XCTAssertEqual(surfaces.published.count, 3)
        let tokens = surfaces.published.map(\.issued.value)
        XCTAssertEqual(tokens, tokens.sorted(), "issue order is kept")
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
            case .stopped: XCTAssertEqual(display.power, .awaitingMovement)
            case .city, .cruising: XCTAssertEqual(display.freshness, .live)
            }
        }
        // The city loop moves: speeds differ across a minute.
        let speeds = stride(from: 0.0, to: 60, by: 5).map { offset -> LiveDriveDisplay.Speed in
            var status = VehicleStatus.skeleton
            let at = Date(timeIntervalSince1970: 1_800_000_040 + offset)
            MockDriving.city.apply(to: &status, now: at)
            return LiveDriveDisplay.make(status, fetchedAt: at, now: at).speed
        }
        XCTAssertGreaterThan(Set(speeds.map { "\($0)" }).count, 6)
        XCTAssertTrue(speeds.contains { if case .stopped = $0 { true } else { false } })
    }
}

// MARK: - Fakes

private final class ScriptedStatusSource: VoltaDataSource, @unchecked Sendable {
    enum Step { case status(VehicleStatus), failure }
    private let lock = NSLock()
    private var steps: [Step]
    private var requests = 0
    let base = MockDataSource(empty: false)

    init(steps: [Step]) { self.steps = steps }

    var statusRequests: Int { lock.withLock { requests } }

    func status(vehicleID: Int) async throws -> VehicleStatus {
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
    func summary(vehicleID: Int, range: SummaryRange) async throws -> ActivitySummary { try await base.summary(vehicleID: vehicleID, range: range) }
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

@MainActor private final class CountingSurfaces: VehicleSurfaces {
    var published: [VehicleRefresh] = []
    private var issued: UInt64 = 0
    func setContext(_ context: VehicleSurfaceContext) {}
    func nextStatusToken() -> StatusRequestToken { issued += 1; return StatusRequestToken(value: issued) }
    func publish(_ refresh: VehicleRefresh, dataSource: any VoltaDataSource) { published.append(refresh) }
    func drivingActivityPreferenceChanged() {}
}
