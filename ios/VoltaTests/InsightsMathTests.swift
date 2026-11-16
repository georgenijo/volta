import XCTest
@testable import Volta

final class InsightsMathTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21T14:13:20Z
    private let miles = UnitPreferences(distance: .miles)
    private let km = UnitPreferences(distance: .kilometers)

    private func drive(km: Double, kwh: Double?, speedKph: Double?, start: Date? = nil) -> DriveSummary {
        DriveSummary(id: Int.random(in: 1...1_000_000), start: start ?? t0, end: nil, startAddress: nil, endAddress: nil,
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

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date { utc.date(from: DateComponents(year: y, month: m, day: d))! }

    func testLeasePaceAndProjection() throws {
        // 36 months, 36,000 km, started at 1,000 km. 2026-01-01 → 2029-01-01 is 1,096 days.
        let terms = LeaseTerms(start: date(2026, 1, 1), termMonths: 36, allowanceKm: 36_000, startOdometerKm: 1_000)
        let now = date(2027, 1, 1) // 365 days in
        let progress = LeaseProgress(terms: terms, odometerKm: 15_600, now: now, calendar: utc)
        XCTAssertEqual(progress.phase, .active)
        XCTAssertEqual(progress.totalDays, 1_096, accuracy: 0.001)
        XCTAssertEqual(progress.elapsedDays, 365, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(progress.usedKm), 14_600, accuracy: 0.001)
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
        let terms = LeaseTerms(start: date(2026, 1, 1), termMonths: 24, allowanceKm: 20_000, startOdometerKm: 500)
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

    func testLeaseEndedAndNotStarted() throws {
        let terms = LeaseTerms(start: date(2024, 1, 1), termMonths: 24, allowanceKm: 30_000, startOdometerKm: 0)
        let ended = LeaseProgress(terms: terms, odometerKm: 28_000, now: date(2026, 3, 1), calendar: utc)
        XCTAssertEqual(ended.phase, .ended)
        XCTAssertEqual(ended.remainingDays, 0)
        XCTAssertEqual(ended.projectedKmAtEnd, 28_000, "the final figure, not an estimate")
        XCTAssertEqual(try XCTUnwrap(ended.projectedOverKm), -2_000, accuracy: 0.001)
        XCTAssertFalse(ended.isProjectionEstimate)
        XCTAssertNil(ended.neededKmPerDay)

        let future = LeaseProgress(terms: LeaseTerms(start: date(2027, 1, 1), termMonths: 36, allowanceKm: 1, startOdometerKm: 0),
                                   odometerKm: 9_000, now: date(2026, 3, 1), calendar: utc)
        XCTAssertEqual(future.phase, .notStarted)
        XCTAssertNil(future.usedKm)
        XCTAssertEqual(future.elapsedDays, 0)
    }

    func testLeaseTermsValidation() {
        XCTAssertTrue(LeaseTerms(start: t0, termMonths: 36, allowanceKm: 1, startOdometerKm: 0).isValid)
        XCTAssertFalse(LeaseTerms(start: t0, termMonths: 0, allowanceKm: 1, startOdometerKm: 0).isValid)
        XCTAssertFalse(LeaseTerms(start: t0, termMonths: 36, allowanceKm: 0, startOdometerKm: 0).isValid)
        XCTAssertFalse(LeaseTerms(start: t0, termMonths: 36, allowanceKm: .nan, startOdometerKm: 0).isValid)
        XCTAssertFalse(LeaseTerms(start: t0, termMonths: 36, allowanceKm: 1, startOdometerKm: -1).isValid)
    }

    func testLeaseCumulativeStartsAtZeroAndSkipsDaysBeforeStart() {
        let start = date(2026, 3, 10).addingTimeInterval(9 * 3600)
        let buckets = [MileageBucket(start: date(2026, 3, 12), distanceKm: 30, driveCount: 1, energyUsedKwh: nil),
                       MileageBucket(start: date(2026, 3, 9), distanceKm: 99, driveCount: 1, energyUsedKwh: nil),   // before
                       MileageBucket(start: date(2026, 3, 10), distanceKm: 20, driveCount: 1, energyUsedKwh: nil),  // start day
                       MileageBucket(start: date(2026, 3, 20), distanceKm: 50, driveCount: 1, energyUsedKwh: nil)]  // after now
        let points = LeaseProgress.cumulative(buckets, start: start, now: date(2026, 3, 15))
        XCTAssertEqual(points.map(\.km), [0, 20, 50])
        XCTAssertEqual(points.first?.date, start)
        XCTAssertEqual(points.last?.date, date(2026, 3, 13))
    }

    // MARK: Charging insights

    func testHomeAwaySharesExcludeUnknownCostAndOtherCurrency() throws {
        let charges = [charge(added: 30, cost: 6, place: "Home"), charge(added: 10, cost: nil, place: "Home"),
                       charge(added: 20, cost: 8, fast: true), charge(added: nil, cost: 2, place: "Work"),
                       charge(added: 15, cost: 5, currency: "EUR", fast: true)]
        let split = ChargingInsights.homeAway(charges, fallbackCurrency: "USD")
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

    func testAcDcAndUnpricedSplit() {
        let charges = [charge(added: 10, cost: nil), charge(added: 30, cost: nil, fast: true)]
        let split = ChargingInsights.acDc(charges, fallbackCurrency: "USD")
        XCTAssertEqual(split.first.label, "AC")
        XCTAssertEqual(split.first.energyKwh, 10)
        XCTAssertEqual(split.second.energyKwh, 30)
        XCTAssertNil(split.currency)
        XCTAssertNil(split.cost, "nothing priced means unknown, not $0")
        XCTAssertNil(split.firstCostFraction)
        XCTAssertEqual(split.costUnknown, 2)
    }

    func testPrimaryCurrencyUsesFallbackAndCounts() {
        let charges = [charge(added: 1, cost: 1, currency: nil), charge(added: 1, cost: 50, currency: "EUR"),
                       charge(added: 1, cost: 1, currency: "USD")]
        XCTAssertEqual(ChargingInsights.primaryCurrency(charges, fallbackCurrency: "USD"), "USD")
        XCTAssertNil(ChargingInsights.primaryCurrency([charge(added: 1, cost: nil)], fallbackCurrency: "USD"))
    }

    func testCostPerDistancePlotsOnlyFullyPricedBuckets() throws {
        let jan = date(2026, 1, 5), feb = date(2026, 2, 5), mar = date(2026, 3, 5), apr = date(2026, 4, 5), may = date(2026, 5, 5)
        let drives = [drive(km: 100, kwh: 15, speedKph: 40, start: jan), drive(km: 50, kwh: 8, speedKph: 40, start: jan),
                      drive(km: 200, kwh: 30, speedKph: 40, start: feb), drive(km: 80, kwh: 12, speedKph: 40, start: mar),
                      drive(km: 60, kwh: 9, speedKph: 40, start: may)]
        let charges = [charge(added: 20, cost: 4, start: jan), charge(added: 10, cost: 2, start: jan),
                       charge(added: 30, cost: 6, start: feb), charge(added: 10, cost: nil, start: feb),   // unknown → excluded
                       charge(added: 10, cost: 3, currency: "EUR", start: mar),                          // other currency
                       charge(added: 10, cost: 2, start: apr)]                                           // no driving
        let series = ChargingInsights.costPerDistance(charges: charges, drives: drives, bucket: .month, calendar: utc,
                                                      fallbackCurrency: "USD")
        XCTAssertEqual(series.currency, "USD")
        XCTAssertEqual(series.points.count, 1)
        XCTAssertEqual(series.points[0].start, date(2026, 1, 1))
        XCTAssertEqual(series.points[0].costPerKm, 6.0 / 150, accuracy: 0.0001)
        XCTAssertEqual(series.unknownCostBuckets, 1)
        XCTAssertEqual(series.otherCurrencyBuckets, 1)
        XCTAssertEqual(series.noDistanceBuckets, 1)
        XCTAssertEqual(series.noChargeBuckets, 1)
        XCTAssertEqual(series.excludedBuckets, 4)
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
