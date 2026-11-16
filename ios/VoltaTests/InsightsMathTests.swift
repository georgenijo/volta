import XCTest
@testable import Volta

final class InsightsMathTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21T14:13:20Z
    private let miles = UnitPreferences(distance: .miles)
    private let km = UnitPreferences(distance: .kilometers)

    /// A completed drive unless `open`: an open drive has no end yet.
    private func drive(km: Double, kwh: Double?, speedKph: Double?, start: Date? = nil, open: Bool = false) -> DriveSummary {
        let begin = start ?? t0
        return DriveSummary(id: Int.random(in: 1...1_000_000), start: begin, end: open ? nil : begin.addingTimeInterval(600), startAddress: nil, endAddress: nil,
                     distanceKm: km, durationMin: 10, startBatteryLevel: nil, endBatteryLevel: nil,
                     energyUsedKwh: kwh, efficiencyWhPerKm: nil, maxSpeedKph: nil, avgSpeedKph: speedKph, outsideTempAvgC: nil)
    }

    private func charge(added: Double?, cost: Double?, currency: String? = "USD", fast: Bool = false,
                        place: String? = nil, start: Date? = nil) -> ChargeSummary {
        ChargeSummary(id: Int.random(in: 1...1_000_000), start: start ?? t0, end: nil, address: nil, placeName: place,
                      energyAddedKwh: added, energyUsedKwh: nil, startBatteryLevel: nil, endBatteryLevel: nil,
                      durationMin: 30, maxPowerKw: nil, fastCharger: fast, cost: cost, currency: currency, outsideTempAvgC: nil)
    }

    // MARK: Efficiency by speed

    func testSpeedBinsWeightByDistanceAndKeepEmptyGaps() throws {
        // 16.09 km/h ≈ 10 mph, so 40 kph is the 20–30 mph bin and 100 kph the 60–70 mph bin.
        let drives = [drive(km: 10, kwh: 1.5, speedKph: 40), drive(km: 30, kwh: 6, speedKph: 45),
                      drive(km: 50, kwh: 10, speedKph: 100),
                      drive(km: 0.3, kwh: 0.1, speedKph: 70),   // too short
                      drive(km: 10, kwh: nil, speedKph: 70),    // no energy
                      drive(km: 10, kwh: 2, speedKph: nil)]     // no speed
        let bins = SpeedEfficiency.bins(drives, units: miles)
        XCTAssertEqual(bins.map(\.lower), [20, 30, 40, 50, 60])
        XCTAssertEqual(bins.map(\.drives), [2, 0, 0, 0, 1])
        // (1.5 + 6) kWh over 40 km, not the mean of 150 and 200.
        XCTAssertEqual(try XCTUnwrap(bins[0].whPerKm), 187.5, accuracy: 0.001)
        XCTAssertNil(bins[1].whPerKm, "an empty bin has no efficiency, not zero")
        XCTAssertTrue(bins[1].isEmpty)
        XCTAssertTrue(bins[0].isSparse && bins[4].isSparse)
    }

    func testSpeedBinsLeaveOutOpenDrives() {
        let open = drive(km: 20, kwh: 3, speedKph: 50, open: true)
        let done = drive(km: 20, kwh: 3, speedKph: 50)
        XCTAssertFalse(SpeedEfficiency.isUsable(open), "an open drive's figures are still growing")
        XCTAssertTrue(SpeedEfficiency.isUsable(done))
        let bins = SpeedEfficiency.bins([open, done, drive(km: 30, kwh: 9, speedKph: 120, open: true)], units: km)
        XCTAssertEqual(bins.map(\.drives), [1])
        XCTAssertEqual(bins.first?.lower, 45)
    }

    func testSpeedBinsUseDisplayUnitsAndFlagSparse() {
        let drives = (0..<4).map { _ in drive(km: 20, kwh: 3, speedKph: 50) }
        let bins = SpeedEfficiency.bins(drives, units: km)
        XCTAssertEqual(bins.count, 1)
        XCTAssertEqual(bins[0].lower, 45)
        XCTAssertEqual(bins[0].width, 15)
        XCTAssertFalse(bins[0].isSparse)
        XCTAssertTrue(SpeedEfficiency.bins([], units: km).isEmpty)
    }

    // MARK: Lease

    private var utc: Calendar { calendar("UTC") }

    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ min: Int = 0, in cal: Calendar? = nil) -> Date {
        (cal ?? utc).date(from: DateComponents(year: y, month: m, day: d, hour: h, minute: min))!
    }

    private func lease(_ y: Int, _ m: Int, _ d: Int, months: Int, allowance: Double, startOdometer: Double) -> LeaseTerms {
        LeaseTerms(startDay: CivilDate(year: y, month: m, day: d), termMonths: months, allowanceKm: allowance, startOdometerKm: startOdometer)
    }

    func testLeasePaceAndProjection() throws {
        // 36 months, 36,000 km, started at 1,000 km. 2026-01-01 → 2029-01-01 is 1,096 days.
        let terms = lease(2026, 1, 1, months: 36, allowance: 36_000, startOdometer: 1_000)
        let now = date(2027, 1, 1) // 365 days in
        let progress = LeaseProgress(terms: terms, odometerKm: 15_600, now: now, calendar: utc)
        XCTAssertEqual(progress.phase, .active)
        XCTAssertEqual(progress.totalDays, 1_096, accuracy: 0.001)
        XCTAssertEqual(progress.elapsedDays, 365, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(progress.usedKm), 14_600, accuracy: 0.001)
        XCTAssertEqual(progress.sinceStartKm, progress.usedKm)
        XCTAssertEqual(try XCTUnwrap(progress.remainingKm), 21_400, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(progress.actualKmPerDay), 40, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(progress.neededKmPerDay), 21_400 / 731, accuracy: 0.001)
        // 14,600 + 40 × 731 = 43,840 → 7,840 over.
        XCTAssertEqual(try XCTUnwrap(progress.projectedKmAtEnd), 43_840, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(progress.projectedOverKm), 7_840, accuracy: 0.001)
        XCTAssertEqual(progress.expectedKmToDate, 36_000 * 365 / 1_096, accuracy: 0.001)
        XCTAssertTrue(progress.isProjectionEstimate)
    }

    func testLeaseUnknownOdometerAndEarlyPace() {
        let terms = lease(2026, 1, 1, months: 24, allowance: 20_000, startOdometer: 500)
        let unknown = LeaseProgress(terms: terms, odometerKm: nil, now: date(2026, 6, 1), calendar: utc)
        XCTAssertNil(unknown.usedKm)
        XCTAssertNil(unknown.projectedKmAtEnd)
        XCTAssertNil(unknown.neededKmPerDay)
        XCTAssertFalse(unknown.odometerBelowStart)

        let early = LeaseProgress(terms: terms, odometerKm: 700, now: date(2026, 1, 4), calendar: utc)
        XCTAssertEqual(early.usedKm, 200)
        XCTAssertNil(early.actualKmPerDay, "three days is too few to project from")
        XCTAssertNil(early.projectedKmAtEnd)

        let below = LeaseProgress(terms: terms, odometerKm: 400, now: date(2026, 6, 1), calendar: utc)
        XCTAssertTrue(below.odometerBelowStart)
        XCTAssertNil(below.usedKm)
    }

    func testEndedLeaseHasNoFinalMileageWithoutAnEndReading() {
        // Ended on 2026-01-01 at what was 28,000 km; in March the odometer reads 31,000.
        let terms = lease(2024, 1, 1, months: 24, allowance: 30_000, startOdometer: 0)
        let ended = LeaseProgress(terms: terms, odometerKm: 31_000, now: date(2026, 3, 1), calendar: utc)
        XCTAssertEqual(ended.phase, .ended)
        XCTAssertEqual(ended.end, date(2026, 1, 1))
        XCTAssertEqual(ended.remainingDays, 0)
        XCTAssertEqual(ended.sinceStartKm, 31_000, "today's odometer, labelled as distance since the start")
        XCTAssertNil(ended.usedKm, "today's odometer is not the end-of-term figure")
        XCTAssertNil(ended.projectedKmAtEnd, "final mileage is unavailable")
        XCTAssertNil(ended.projectedOverKm)
        XCTAssertNil(ended.remainingKm)
        XCTAssertNil(ended.actualKmPerDay)
        XCTAssertNil(ended.neededKmPerDay)
        XCTAssertNil(ended.aheadOfPaceKm)
        XCTAssertFalse(ended.isProjectionEstimate)

        let future = LeaseProgress(terms: lease(2027, 1, 1, months: 36, allowance: 1, startOdometer: 0),
                                   odometerKm: 9_000, now: date(2026, 3, 1), calendar: utc)
        XCTAssertEqual(future.phase, .notStarted)
        XCTAssertNil(future.usedKm)
        XCTAssertNil(future.sinceStartKm)
        XCTAssertEqual(future.elapsedDays, 0)
    }

    func testLeaseTermsValidation() {
        XCTAssertTrue(lease(2026, 1, 1, months: 36, allowance: 1, startOdometer: 0).isValid)
        XCTAssertFalse(lease(2026, 1, 1, months: 0, allowance: 1, startOdometer: 0).isValid)
        XCTAssertFalse(lease(2026, 1, 1, months: 36, allowance: 0, startOdometer: 0).isValid)
        XCTAssertFalse(lease(2026, 1, 1, months: 36, allowance: .nan, startOdometer: 0).isValid)
        XCTAssertFalse(lease(2026, 1, 1, months: 36, allowance: 1, startOdometer: -1).isValid)
        XCTAssertFalse(lease(2026, 13, 1, months: 36, allowance: 1, startOdometer: 0).isValid)
    }

    func testLeaseStartIsACivilDateAtLocalMidnight() throws {
        let la = calendar("America/Los_Angeles")
        // The picker can hand back 1 July at 15:30; only the day is kept.
        let picked = date(2026, 7, 1, 15, 30, in: la)
        let day = CivilDate(picked, calendar: la)
        XCTAssertEqual(day, CivilDate(year: 2026, month: 7, day: 1))
        let terms = LeaseTerms(startDay: day, termMonths: 36, allowanceKm: 36_000, startOdometerKm: 0)
        XCTAssertEqual(terms.start(calendar: la), date(2026, 7, 1, 7, in: utc), "midnight PDT is 07:00 UTC")
        XCTAssertEqual(terms.end(calendar: la), date(2029, 7, 1, 0, in: la))
        // Stored as a civil date: decoding keeps the day, not an instant.
        let decoded = try JSONDecoder().decode(LeaseTerms.self, from: JSONEncoder().encode(terms))
        XCTAssertEqual(decoded.startDay, day)
    }

    func testLeaseRecordedDistanceUsesDrivesInsideTheLocalInterval() {
        let la = calendar("America/Los_Angeles")
        let terms = lease(2026, 7, 1, months: 12, allowance: 20_000, startOdometer: 0)
        let start = terms.start(calendar: la), end = terms.end(calendar: la)
        let drives = [
            // 30 June 20:00 PDT is already 1 July in UTC: before the lease, left out.
            drive(km: 99, kwh: nil, speedKph: nil, start: date(2026, 6, 30, 20, in: la)),
            drive(km: 10, kwh: nil, speedKph: nil, start: date(2026, 7, 1, 0, 5, in: la)),
            drive(km: 15, kwh: nil, speedKph: nil, start: date(2026, 7, 1, 18, in: la)),
            drive(km: 30, kwh: nil, speedKph: nil, start: date(2026, 7, 3, 9, in: la)),
            drive(km: 40, kwh: nil, speedKph: nil, start: date(2026, 7, 9, 9, in: la)), // after now
        ]
        let now = date(2026, 7, 5, 12, in: la)
        let points = LeaseProgress.recorded(drives, start: start, end: end, now: now, calendar: la)
        XCTAssertEqual(points.map(\.km), [0, 25, 55])
        XCTAssertEqual(points.first?.date, start, "starts at the first recorded day, at zero")
        XCTAssertEqual(points[1].date, date(2026, 7, 2, 0, in: la), "steps up at local midnight, not UTC")
        XCTAssertEqual(points.last?.date, date(2026, 7, 4, 0, in: la))

        // Nothing recorded: nothing drawn, not a flat zero line.
        XCTAssertTrue(LeaseProgress.recorded([], start: start, end: end, now: now, calendar: la).isEmpty)
        // The first recorded drive later in the lease: the line begins there.
        let late = LeaseProgress.recorded([drive(km: 5, kwh: nil, speedKph: nil, start: date(2026, 7, 4, 9, in: la))],
                                          start: start, end: end, now: now, calendar: la)
        XCTAssertEqual(late.first?.date, date(2026, 7, 4, 0, in: la))
        // An ended lease stops at its end, whatever came after.
        let after = LeaseProgress.recorded([drive(km: 5, kwh: nil, speedKph: nil, start: end.addingTimeInterval(3600))],
                                           start: start, end: end, now: end.addingTimeInterval(86_400 * 30), calendar: la)
        XCTAssertTrue(after.isEmpty)
    }

    // MARK: Charging insights

    func testHomeAwaySharesExcludeUnknownCostAndOtherCurrency() throws {
        let charges = [charge(added: 30, cost: 6, place: "Home"), charge(added: 10, cost: nil, place: "Home"),
                       charge(added: 20, cost: 8, fast: true), charge(added: nil, cost: 2, place: "Work"),
                       charge(added: 15, cost: 5, currency: "EUR", fast: true)]
        let split = ChargingInsights.homeAway(charges)
        XCTAssertEqual(split.currency, "USD")
        XCTAssertEqual(split.first.energyKwh, 40)
        XCTAssertEqual(split.second.energyKwh, 35)
        XCTAssertEqual(split.energyUnknown, 1)
        XCTAssertEqual(try XCTUnwrap(split.firstEnergyFraction), 40.0 / 75, accuracy: 0.0001)
        XCTAssertEqual(split.first.cost, 6)
        XCTAssertEqual(split.first.costUnknown, 1)
        XCTAssertEqual(split.second.cost, 10, "USD only: the EUR session is excluded, not converted")
        XCTAssertEqual(split.second.otherCurrency, 1)
        XCTAssertEqual(split.costUnknown, 1)
        XCTAssertEqual(try XCTUnwrap(split.firstCostFraction), 6.0 / 16, accuracy: 0.0001)
    }

    func testCostWithoutACurrencyIsNeverCountedAsMoney() throws {
        // 10 with no currency and 5 USD is 5 USD plus one excluded session, not 15 USD.
        let charges = [charge(added: 10, cost: 10, currency: nil), charge(added: 10, cost: 5, currency: "USD")]
        XCTAssertEqual(ChargingInsights.primaryCurrency(charges), "USD")
        let split = ChargingInsights.acDc(charges)
        XCTAssertEqual(split.cost, 5)
        XCTAssertEqual(split.first.costSessions, 1)
        XCTAssertEqual(split.currencyUnknown, 1)
        XCTAssertEqual(split.costUnknown, 0, "the cost is known; its currency is not")
        // Only unknown currencies: nothing is priced, so no currency and no total.
        let unknownOnly = ChargingInsights.acDc([charge(added: 10, cost: 10, currency: nil), charge(added: 5, cost: 3, currency: " ")])
        XCTAssertNil(unknownOnly.currency)
        XCTAssertNil(unknownOnly.cost)
        XCTAssertEqual(unknownOnly.currencyUnknown, 2)
        XCTAssertNil(ChargingInsights.primaryCurrency([charge(added: 1, cost: nil)]))
        // Recorded codes compare case-insensitively.
        XCTAssertEqual(ChargingInsights.primaryCurrency([charge(added: 1, cost: 1, currency: "usd"),
                                                         charge(added: 1, cost: 1, currency: "USD"),
                                                         charge(added: 1, cost: 50, currency: "EUR")]), "USD")
    }

    func testHomeIsAnExactPlaceNameRegardlessOfChargerType() {
        XCTAssertTrue(ChargingInsights.isHome(charge(added: 1, cost: nil, place: "Home")))
        XCTAssertTrue(ChargingInsights.isHome(charge(added: 1, cost: nil, place: "  home ")))
        XCTAssertTrue(ChargingInsights.isHome(charge(added: 1, cost: nil, fast: true, place: "HOME")),
                      "a fast charger at home is still home")
        XCTAssertFalse(ChargingInsights.isHome(charge(added: 1, cost: nil, place: "Home Depot")))
        XCTAssertFalse(ChargingInsights.isHome(charge(added: 1, cost: nil, place: "Mom's home")))
        XCTAssertFalse(ChargingInsights.isHome(charge(added: 1, cost: nil, place: nil)))
        let split = ChargingInsights.homeAway([charge(added: 10, cost: nil, fast: true, place: "Home"),
                                               charge(added: 20, cost: nil, place: "Home Depot")])
        XCTAssertEqual(split.first.energyKwh, 10)
        XCTAssertEqual(split.second.energyKwh, 20)
    }

    func testAcDcAndUnpricedSplit() {
        let charges = [charge(added: 10, cost: nil), charge(added: 30, cost: nil, fast: true)]
        let split = ChargingInsights.acDc(charges)
        XCTAssertEqual(split.first.label, "AC")
        XCTAssertEqual(split.first.energyKwh, 10)
        XCTAssertEqual(split.second.energyKwh, 30)
        XCTAssertNil(split.currency)
        XCTAssertNil(split.cost, "nothing priced means unknown, not $0")
        XCTAssertNil(split.firstCostFraction)
        XCTAssertEqual(split.costUnknown, 2)
    }

    func testCostPerDistancePlotsOnlyFullyPricedBuckets() throws {
        let jan = date(2026, 1, 5), feb = date(2026, 2, 5), mar = date(2026, 3, 5), apr = date(2026, 4, 5),
            may = date(2026, 5, 5), jun = date(2026, 6, 5)
        let drives = [drive(km: 100, kwh: 15, speedKph: 40, start: jan), drive(km: 50, kwh: 8, speedKph: 40, start: jan),
                      drive(km: 200, kwh: 30, speedKph: 40, start: feb), drive(km: 80, kwh: 12, speedKph: 40, start: mar),
                      drive(km: 60, kwh: 9, speedKph: 40, start: may), drive(km: 90, kwh: 9, speedKph: 40, start: jun)]
        let charges = [charge(added: 20, cost: 4, start: jan), charge(added: 10, cost: 2, start: jan),
                       charge(added: 30, cost: 6, start: feb), charge(added: 10, cost: nil, start: feb),   // unknown → excluded
                       charge(added: 10, cost: 3, currency: "EUR", start: mar),                          // other currency
                       charge(added: 10, cost: 2, start: apr),                                           // no driving
                       charge(added: 10, cost: 2, start: jun), charge(added: 10, cost: 9, currency: nil, start: jun)] // no currency
        let series = ChargingInsights.costPerDistance(charges: charges, drives: drives, bucket: .month, calendar: utc)
        XCTAssertEqual(series.currency, "USD")
        XCTAssertEqual(series.points.count, 1)
        XCTAssertEqual(series.points[0].start, date(2026, 1, 1))
        XCTAssertEqual(series.points[0].costPerKm, 6.0 / 150, accuracy: 0.0001)
        XCTAssertEqual(series.unknownCostBuckets, 1)
        XCTAssertEqual(series.unknownCurrencyBuckets, 1, "a session missing its currency rejects the whole month")
        XCTAssertEqual(series.otherCurrencyBuckets, 1)
        XCTAssertEqual(series.noDistanceBuckets, 1)
        XCTAssertEqual(series.noChargeBuckets, 1)
        XCTAssertEqual(series.excludedBuckets, 5)
        XCTAssertEqual(try XCTUnwrap(series.costPerKm), 0.04, accuracy: 0.0001)
    }

    // MARK: Cycles

    func testCycleEstimate() throws {
        let charges = [charge(added: 50, cost: nil), charge(added: 25, cost: nil), charge(added: nil, cost: nil),
                       charge(added: .nan, cost: nil)]
        let estimate = try XCTUnwrap(CycleEstimate.make(charges: charges, usableCapacityKwh: 75, isComplete: false))
        XCTAssertEqual(estimate.cycles, 1, accuracy: 0.0001)
        XCTAssertEqual(estimate.sessionsCounted, 2)
        XCTAssertEqual(estimate.sessionsTotal, 4)
        XCTAssertFalse(estimate.isComplete)
        XCTAssertNil(CycleEstimate.make(charges: charges, usableCapacityKwh: nil))
        XCTAssertNil(CycleEstimate.make(charges: charges, usableCapacityKwh: 0))
        XCTAssertNil(CycleEstimate.make(charges: [charge(added: nil, cost: nil)], usableCapacityKwh: 75))
    }
}

// MARK: - Charging Insights period switching

@MainActor
final class ChargingInsightsLoadingTests: XCTestCase {
    func testSwitchingPeriodShowsLoadingUntilThatPeriodArrives() async throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let source = DelayedSource(base: MockDataSource(now: now))
        let vehicleID = try await source.vehicles()[0].id

        // 1Y has loaded and is on screen.
        await source.gate.release()
        let year = try await ChargingInsightsView.fetch(source: source, vehicleID: vehicleID, period: .year, now: now)
        XCTAssertEqual(year.period, .year)
        var state: Loadable<ChargingInsightsView.Snapshot> = .loaded(year)
        XCTAssertNotNil(ChargingInsightsView.shown(state, period: .year).value)

        // The owner picks 90D while the server is slow: the 1Y figures are not relabelled.
        await source.gate.close()
        XCTAssertNil(ChargingInsightsView.shown(state, period: .quarter).value)
        let before = source.calls.value
        let pending = Task { try await ChargingInsightsView.fetch(source: source, vehicleID: vehicleID, period: .quarter, now: now) }
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(source.calls.value, before + 2, "the first 90D charges and drives requests wait on the gate")
        if case .loading = ChargingInsightsView.shown(state, period: .quarter) {} else { XCTFail("expected loading while 90D loads") }

        await source.gate.release()
        let quarter = try await pending.value
        XCTAssertEqual(quarter.period, .quarter)
        XCTAssertTrue(quarter.charges.allSatisfy { $0.start >= now.addingTimeInterval(-90 * 86_400) })
        state = .loaded(quarter)
        XCTAssertEqual(ChargingInsightsView.shown(state, period: .quarter).value?.period, .quarter)
        // Switching back reads as loading again rather than showing 90D as 1Y.
        XCTAssertNil(ChargingInsightsView.shown(state, period: .year).value)
    }
}

private actor TestGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func close() { isOpen = false }
    func release() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func bump() { lock.withLock { count += 1 } }
}

/// The mock's data, with charges and drives held until the gate opens.
private final class DelayedSource: VoltaDataSource {
    let base: MockDataSource
    let gate = TestGate()
    let calls = Counter()
    init(base: MockDataSource) { self.base = base }
    func charges(vehicleID: Int, range: DateRange, cursor: String?) async throws -> Page<ChargeSummary> {
        calls.bump()
        await gate.wait()
        return try await base.charges(vehicleID: vehicleID, range: range, cursor: cursor)
    }
    func drives(vehicleID: Int, range: DateRange, cursor: String?) async throws -> Page<DriveSummary> {
        calls.bump()
        await gate.wait()
        return try await base.drives(vehicleID: vehicleID, range: range, cursor: cursor)
    }
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
