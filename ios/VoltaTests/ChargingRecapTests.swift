import XCTest
@testable import Volta

final class ChargingRecapTests: XCTestCase {
    /// The user's calendar: Pacific time, so month edges differ from UTC.
    private let pacific: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()

    private let english = Locale(identifier: "en_US")

    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    /// 2026-11-21 12:00 Pacific.
    private var now: Date { date("2026-11-21T20:00:00Z") }

    private var nextID = 0

    private func charge(_ iso: String, added: Double? = 20, cost: Double? = 5, currency: String? = "USD",
                        place: String? = nil) -> ChargeSummary {
        nextID += 1
        return ChargeSummary(id: nextID, start: date(iso), end: nil, address: nil, placeName: place,
                             energyAddedKwh: added, energyUsedKwh: nil, startBatteryLevel: nil, endBatteryLevel: nil,
                             durationMin: 30, maxPowerKw: nil, fastCharger: false, cost: cost, currency: currency,
                             outsideTempAvgC: nil)
    }

    // MARK: Month bucketing

    func testBucketsByStartInTheUsersTimeZone() {
        let charges = [
            // 2026-11-01 06:30Z is Oct 31, 23:30 Pacific (still PDT, UTC−7).
            charge("2026-11-01T06:30:00Z"),
            // 2026-11-01 08:30Z is Nov 1, 01:30 Pacific.
            charge("2026-11-01T08:30:00Z"),
            // Sept 30, 23:00 Pacific: before last month, ignored.
            charge("2026-10-01T06:00:00Z"),
            // Oct 1, 00:00 Pacific exactly: last month's first instant.
            charge("2026-10-01T07:00:00Z"),
        ]
        let recap = ChargingRecap(charges: charges, now: now, calendar: pacific)
        XCTAssertEqual(recap.current.sessions, 1)
        XCTAssertEqual(recap.previous.sessions, 2)
        XCTAssertEqual(recap.current.interval.start, date("2026-11-01T07:00:00Z"))
        XCTAssertEqual(recap.previous.interval.start, date("2026-10-01T07:00:00Z"))
        XCTAssertEqual(recap.previous.interval.end, recap.current.interval.start)
    }

    func testTheSameInstantFallsInOneMonthOnly() {
        // November's first instant belongs to November, not also to October.
        let recap = ChargingRecap(charges: [charge("2026-11-01T07:00:00Z")], now: now, calendar: pacific)
        XCTAssertEqual(recap.current.sessions, 1)
        XCTAssertEqual(recap.previous.sessions, 0)
    }

    func testRangeStartsAtLastMonthInTheUsersCalendar() {
        let range = ChargingRecap.range(now: now, calendar: pacific)
        XCTAssertEqual(range.from, date("2026-10-01T07:00:00Z"))
        XCTAssertNil(range.to)
        // January looks back into December of the year before.
        let january = ChargingRecap.range(now: date("2027-01-10T20:00:00Z"), calendar: pacific)
        XCTAssertEqual(january.from, date("2026-12-01T08:00:00Z"))
    }

    func testTitleSaysTheMonthIsInProgress() {
        let recap = ChargingRecap(charges: [], now: now, calendar: pacific)
        XCTAssertEqual(recap.title(calendar: pacific, locale: english), "November so far")
        XCTAssertEqual(recap.comparison(calendar: pacific, locale: english), "vs October")
    }

    // MARK: Figures and changes

    func testFiguresAndChangesAgainstLastMonth() throws {
        let charges = [
            charge("2026-11-02T18:00:00Z", added: 40, cost: 8, place: "Home"),
            charge("2026-11-05T18:00:00Z", added: 10, cost: 6),
            charge("2026-11-09T18:00:00Z", added: 50, cost: 10, place: "home "),
            charge("2026-10-03T18:00:00Z", added: 30, cost: 9, place: "Home"),
            charge("2026-10-20T18:00:00Z", added: 30, cost: 15),
        ]
        let recap = ChargingRecap(charges: charges, now: now, calendar: pacific)
        XCTAssertEqual(recap.current.sessions, 3)
        XCTAssertEqual(try XCTUnwrap(recap.current.energyKwh), 100, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(recap.current.cost), 24, accuracy: 1e-9)
        XCTAssertEqual(recap.current.currency, "USD")
        XCTAssertEqual(recap.current.homePercent, 90)
        XCTAssertEqual(recap.previous.homePercent, 50)

        XCTAssertEqual(recap.sessionsChange, 1)
        XCTAssertEqual(try XCTUnwrap(recap.energyChange), 40, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(recap.costChange), 0, accuracy: 1e-9)
        XCTAssertEqual(recap.homeShareChange, 40)
        XCTAssertTrue(recap.notes(calendar: pacific, locale: english).isEmpty)
    }

    func testHomeShareIsChargingInsightsOwnRule() throws {
        let charges = [
            charge("2026-11-02T18:00:00Z", added: 30, place: "Home Depot"),
            charge("2026-11-03T18:00:00Z", added: 10, place: " HOME"),
            charge("2026-11-04T18:00:00Z", added: nil, place: "Home"),
        ]
        let recap = ChargingRecap(charges: charges, now: now, calendar: pacific)
        let insights = ChargingInsights.homeAway(charges)
        XCTAssertEqual(try XCTUnwrap(recap.current.homeShare), try XCTUnwrap(insights.firstEnergyFraction), accuracy: 1e-12)
        XCTAssertEqual(recap.current.homePercent, 25)
        XCTAssertEqual(recap.current.energyUnknown, 1)
    }

    // MARK: Unpriced sessions

    func testUnpricedSessionsAreCountedButNotPriced() throws {
        let charges = [
            charge("2026-11-02T18:00:00Z", cost: 7),
            charge("2026-11-03T18:00:00Z", cost: nil),
            charge("2026-11-04T18:00:00Z", cost: nil),
            charge("2026-11-05T18:00:00Z", cost: .nan),
            charge("2026-10-05T18:00:00Z", cost: 4),
        ]
        let recap = ChargingRecap(charges: charges, now: now, calendar: pacific)
        XCTAssertEqual(recap.current.sessions, 4)
        XCTAssertEqual(recap.current.unpriced, 3)
        XCTAssertEqual(try XCTUnwrap(recap.current.cost), 7, accuracy: 1e-9, "unpriced sessions are never priced at zero")
        XCTAssertFalse(recap.current.isFullyPriced)
        XCTAssertNil(recap.costChange, "a partly priced month's change would really be a missing price")
        XCTAssertEqual(recap.sessionsChange, 3, "counts still compare")
        XCTAssertEqual(recap.notes(calendar: pacific, locale: english), ["3 sessions unpriced"])
    }

    func testAMonthWithNothingPricedHasUnknownCost() {
        let recap = ChargingRecap(charges: [charge("2026-11-02T18:00:00Z", cost: nil)], now: now, calendar: pacific)
        XCTAssertNil(recap.current.cost, "unknown, never zero")
        XCTAssertNil(recap.current.currency)
        XCTAssertEqual(recap.notes(calendar: pacific, locale: english).first, "1 session unpriced")
    }

    // MARK: Currencies

    func testMixedCurrenciesAreNeverAddedTogether() throws {
        let charges = [
            charge("2026-11-02T18:00:00Z", cost: 10, currency: "USD"),
            charge("2026-11-03T18:00:00Z", cost: 12, currency: "usd"),
            charge("2026-11-04T18:00:00Z", cost: 50, currency: "EUR"),
            charge("2026-11-05T18:00:00Z", cost: 3, currency: nil),
        ]
        let recap = ChargingRecap(charges: charges, now: now, calendar: pacific)
        XCTAssertEqual(recap.current.currency, "USD", "the dominant currency")
        XCTAssertEqual(try XCTUnwrap(recap.current.cost), 22, accuracy: 1e-9)
        XCTAssertEqual(recap.current.otherCurrencies, ["EUR": 1])
        XCTAssertEqual(recap.current.currencyUnknown, 1)
        XCTAssertEqual(recap.notes(calendar: pacific, locale: english), [
            "1 session with a cost but no currency, not added",
            "1 session priced in EUR, not added",
            "No charges in October to compare with.",
        ])
    }

    func testCostChangeNeedsTheSameCurrencyInBothMonths() {
        let charges = [
            charge("2026-11-02T18:00:00Z", cost: 10, currency: "USD"),
            charge("2026-10-02T18:00:00Z", cost: 10, currency: "CAD"),
        ]
        let recap = ChargingRecap(charges: charges, now: now, calendar: pacific)
        XCTAssertNil(recap.costChange)
        XCTAssertEqual(recap.sessionsChange, 0)
    }

    // MARK: Empty months and partial loads

    func testEmptyMonthsHaveNoFiguresAndNoChanges() {
        let recap = ChargingRecap(charges: [charge("2026-10-02T18:00:00Z")], now: now, calendar: pacific)
        XCTAssertTrue(recap.current.isEmpty)
        XCTAssertNil(recap.current.energyKwh)
        XCTAssertNil(recap.current.cost)
        XCTAssertNil(recap.current.homeShare)
        XCTAssertNil(recap.sessionsChange, "a change needs both months to have sessions")
        XCTAssertNil(recap.energyChange)
        XCTAssertNil(recap.homeShareChange)

        let lastEmpty = ChargingRecap(charges: [charge("2026-11-02T18:00:00Z")], now: now, calendar: pacific)
        XCTAssertNil(lastEmpty.sessionsChange)
        XCTAssertEqual(lastEmpty.notes(calendar: pacific, locale: english), ["No charges in October to compare with."])
    }

    func testAPartialLoadClaimsNoChange() {
        let charges = [charge("2026-11-02T18:00:00Z"), charge("2026-10-02T18:00:00Z")]
        let recap = ChargingRecap(charges: charges, now: now, calendar: pacific, isComplete: false)
        XCTAssertNil(recap.sessionsChange)
        XCTAssertNil(recap.energyChange)
        XCTAssertNil(recap.costChange)
        XCTAssertEqual(recap.notes(calendar: pacific, locale: english).first,
                       "Not every session could be loaded, so these figures are lower bounds.")
    }

    // MARK: Words

    func testChangeWords() {
        XCTAssertEqual(ChargingRecap.changeText(3), "+3")
        XCTAssertEqual(ChargingRecap.changeText(-2), "\u{2212}2")
        XCTAssertEqual(ChargingRecap.changeText(0), "Same")
        XCTAssertEqual(ChargingRecap.energyChangeText(0.02), "Same")
        XCTAssertTrue(ChargingRecap.energyChangeText(12.44).hasPrefix("+12"))
        XCTAssertTrue(ChargingRecap.energyChangeText(-150).hasSuffix(" kWh"))
        XCTAssertEqual(ChargingRecap.costChangeText(0.001, currency: "USD"), "Same")
        XCTAssertTrue(ChargingRecap.costChangeText(-6, currency: "USD").hasPrefix("\u{2212}"))
        XCTAssertEqual(ChargingRecap.pointsChangeText(8), "+8 points")
        XCTAssertEqual(ChargingRecap.pointsChangeText(-1), "\u{2212}1 point")
    }

    // MARK: Loading

    @MainActor
    func testModelLoadsFromLastMonthAndBucketsEveryPage() async throws {
        let source = RecapSource(charges: [charge("2026-11-02T18:00:00Z"), charge("2026-10-02T18:00:00Z"),
                                           charge("2026-11-03T18:00:00Z")])
        let model = ChargingRecapModel()
        let landed = await model.load(source: source, vehicleID: 1, now: now, calendar: pacific)
        XCTAssertTrue(landed)
        let recap = try XCTUnwrap(model.state.value)
        XCTAssertEqual(recap.current.sessions, 2, "the second page is read too")
        XCTAssertEqual(recap.previous.sessions, 1)
        XCTAssertTrue(recap.isComplete)
        XCTAssertEqual(source.ranges.first?.from, date("2026-10-01T07:00:00Z"))

        // Back within a minute: nothing is fetched again.
        let calls = source.ranges.count
        await model.loadIfNeeded(source: source, vehicleID: 1, now: now.addingTimeInterval(30), calendar: pacific)
        XCTAssertEqual(source.ranges.count, calls)
    }

    @MainActor
    func testAFailedRefreshKeepsTheRecapShown() async throws {
        let source = RecapSource(charges: [charge("2026-11-02T18:00:00Z")])
        let model = ChargingRecapModel()
        await model.load(source: source, vehicleID: 1, now: now, calendar: pacific)
        source.failing = true
        let landed = await model.load(source: source, vehicleID: 1, now: now, calendar: pacific)
        XCTAssertFalse(landed)
        XCTAssertEqual(model.state.value?.current.sessions, 1)
        // Another vehicle has nothing to keep: the failure shows.
        await model.load(source: source, vehicleID: 2, now: now, calendar: pacific)
        guard case .failed = model.state else { return XCTFail("expected the failure") }
    }
}

/// The mock's data, except charges: these, two per page, recording the ranges asked for.
private final class RecapSource: VoltaDataSource, @unchecked Sendable {
    let base = MockDataSource()
    let all: [ChargeSummary]
    private let lock = NSLock()
    private var _ranges: [DateRange] = []
    private var _failing = false
    var ranges: [DateRange] { lock.withLock { _ranges } }
    var failing: Bool {
        get { lock.withLock { _failing } }
        set { lock.withLock { _failing = newValue } }
    }
    init(charges: [ChargeSummary]) { all = charges }

    func charges(vehicleID: Int, range: DateRange, cursor: String?) async throws -> Page<ChargeSummary> {
        lock.withLock { _ranges.append(range) }
        if failing { throw URLError(.notConnectedToInternet) }
        let offset = cursor.flatMap(Int.init) ?? 0
        let next = offset + 2 < all.count ? String(offset + 2) : nil
        return Page(items: Array(all.dropFirst(offset).prefix(2)), nextCursor: next)
    }
    func drives(vehicleID: Int, range: DateRange, cursor: String?) async throws -> Page<DriveSummary> { try await base.drives(vehicleID: vehicleID, range: range, cursor: cursor) }
    func vehicles() async throws -> [Vehicle] { try await base.vehicles() }
    func status(vehicleID: Int) async throws -> VehicleStatus { try await base.status(vehicleID: vehicleID) }
    func summary(vehicleID: Int, range: SummaryRange) async throws -> ActivitySummary { try await base.summary(vehicleID: vehicleID, range: range) }
    func timeline(vehicleID: Int, hours: Int) async throws -> [TimelineSegment] { try await base.timeline(vehicleID: vehicleID, hours: hours) }
    func drive(id: Int) async throws -> DriveDetail { try await base.drive(id: id) }
    func charge(id: Int) async throws -> ChargeDetail { try await base.charge(id: id) }
    func idles(vehicleID: Int, range: DateRange, cursor: String?) async throws -> Page<IdleSummary> { try await base.idles(vehicleID: vehicleID, range: range, cursor: cursor) }
    func battery(vehicleID: Int) async throws -> BatteryHealth { try await base.battery(vehicleID: vehicleID) }
    func mileage(vehicleID: Int, bucket: MileageBucketSize) async throws -> [MileageBucket] { try await base.mileage(vehicleID: vehicleID, bucket: bucket) }
    func firmware(vehicleID: Int) async throws -> [FirmwareUpdate] { try await base.firmware(vehicleID: vehicleID) }
    func places(vehicleID: Int) async throws -> [Place] { try await base.places(vehicleID: vehicleID) }
}
