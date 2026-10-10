import XCTest
@testable import Volta

final class DriveInsightsTests: XCTestCase {
    private func drive(_ id: Int = 1, start: Double = 0, end: Double? = 3600, km: Double = 60, kwh: Double? = 10) -> DriveSummary {
        DriveSummary(id: id, start: Date(timeIntervalSince1970: start), end: end.map { Date(timeIntervalSince1970: $0) }, startAddress: nil, endAddress: nil, distanceKm: km, durationMin: 60, startBatteryLevel: nil, endBatteryLevel: nil, energyUsedKwh: kwh, efficiencyWhPerKm: kwh.map { $0 * 1000 / km }, maxSpeedKph: nil, avgSpeedKph: nil, outsideTempAvgC: nil)
    }
    func testCostPrecedenceUnknownFreeAndCurrency() {
        XCTAssertNil(DrivePricing.cost(drive(kwh: 0), fallback: 0.20))
        XCTAssertEqual(DrivePricing.cost(drive(kwh: 10), fallback: 0), 0)
        var d = drive()
        XCTAssertEqual(DrivePricing.cost(d, fallback: 0.20), 2)
        d.electricityRatePerKwh = 0.30; d.rateCurrency = "EUR"
        XCTAssertEqual(DrivePricing.cost(d, fallback: 0.20), 3)
        XCTAssertEqual(DrivePricing.rate(d, fallback: 0.20).currency, "EUR")
        d.electricityRatePerKwh = 0
        XCTAssertEqual(DrivePricing.cost(d, fallback: 0.20), 0)
        d.energyUsedKwh = nil
        XCTAssertNil(DrivePricing.cost(d, fallback: 0.20))
        let total = DrivePricing.total([drive(), d], fallback: 0.20)
        XCTAssertEqual(total.note, "Cost available for 1 of 2 drives")
    }
    func testScoreUsesServerCompositeAndPreservesMissing() {
        var d = drive(km: 50, kwh: 10)
        d.ratedWhPerKm = 160
        XCTAssertNil(d.efficiencyScore, "The old efficiency ratio must not invent a composite score")
        d.driveScore = 71
        XCTAssertEqual(d.efficiencyScore, 71)
        d.legacyDriveScore = 87
        XCTAssertEqual(d.efficiencyScore, 71, "The current key takes precedence")
        d.driveScore = nil
        XCTAssertEqual(d.efficiencyScore, 87)
        d.driveScore = 101
        XCTAssertNil(d.efficiencyScore)
        d.driveScore = -1
        XCTAssertNil(d.efficiencyScore)
        d.driveScore = 0
        XCTAssertEqual(d.efficiencyScore, 0)
    }
    func testDistanceWeightedScoreUsesOnlyPositiveScoredDistance() {
        var short = drive(-1, km: 10); short.driveScore = 100
        var long = drive(-2, km: 30); long.driveScore = 60
        var zero = drive(-3, km: 0); zero.driveScore = 0
        let unknown = drive(-4, km: 20)
        let totals = DriveTotals([short, long, zero, unknown])
        XCTAssertEqual(totals.distanceKm, 60)
        XCTAssertEqual(totals.drives, 4)
        XCTAssertEqual(UnitPreferences(distance: .miles).distanceValue(km: totals.distanceKm), 60 / 1.609344, accuracy: 0.001)
        XCTAssertEqual(UnitPreferences(distance: .kilometers).distanceValue(km: totals.distanceKm), 60)
        XCTAssertEqual(totals.score, 70)
        XCTAssertEqual(totals.scoredDrives, 2)
        XCTAssertNil(DriveTotals([unknown, zero]).score)
        XCTAssertNil(DriveTotals([]).score)
    }
    func testLocalDayGroupingAcrossMidnightAndDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let decoder = APIDataSource.makeDecoder()
        func date(_ value: String) throws -> Date { try decoder.decode(Date.self, from: Data("\"\(value)\"".utf8)) }
        let now = try date("2026-03-09T07:30:00Z") // March 9, 00:30 after DST.
        let today = drive(-1, start: now.timeIntervalSince1970, km: 10)
        let yesterday = drive(-2, start: try date("2026-03-09T06:30:00Z").timeIntervalSince1970, km: 20)
        let yesterdayMorning = drive(-3, start: try date("2026-03-08T09:30:00Z").timeIntervalSince1970, km: 30)
        let earlier = drive(-4, start: try date("2026-03-07T20:00:00Z").timeIntervalSince1970, km: 40)
        let groups = DayGroup.group([yesterday, today, earlier, yesterdayMorning], by: \.start, calendar: calendar)
        XCTAssertEqual(groups.map { $0.items.count }, [1, 2, 1])
        XCTAssertEqual(groups.map { $0.items.reduce(0) { $0 + $1.distanceKm } }, [10, 50, 40])
        XCTAssertEqual(groups[0].title(now: now, calendar: calendar), "Today")
        XCTAssertEqual(groups[1].title(now: now, calendar: calendar), "Yesterday")
        XCTAssertNotEqual(groups[2].title(now: now, calendar: calendar), "Yesterday")
        let clock = yesterday.start.historyTime(timeZone: calendar.timeZone)
        let expected = DateFormatter(); expected.locale = .autoupdatingCurrent
        expected.timeZone = calendar.timeZone; expected.timeStyle = .short
        XCTAssertEqual(clock, expected.string(from: yesterday.start))
        XCTAssertNotEqual(clock, yesterday.start.historyTime(timeZone: TimeZone(secondsFromGMT: 0)!))
    }
    func testRoadtripGapsOpenDrivesOverlapAndThreshold() {
        let a = drive(), b = drive(2, start: 7200, end: 10800)
        XCTAssertEqual(Roadtrip.group([b, a]).first?.drives.map(\.id), [1, 2])
        XCTAssertTrue(Roadtrip.group([a, drive(2, start: 10801, end: 14400)]).isEmpty)
        XCTAssertTrue(Roadtrip.group([a, drive(2, start: 3600, end: nil)]).isEmpty)
        XCTAssertTrue(Roadtrip.group([a, drive(3, start: 5000, end: nil), b]).isEmpty)
        XCTAssertTrue(Roadtrip.group([a, drive(2, start: 3000, end: 6000)]).isEmpty)
        XCTAssertEqual(Roadtrip.group([drive(km: 100)]).count, 1)
    }
    func testDailyAggregateUsesDeviceCalendarAndKeepsEnergyUnknown() {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let days = DriveDay.days([drive(), drive(2, start: 100, end: 300), drive(3, start: 86400, end: 90000)], calendar: calendar)
        XCTAssertEqual(days.map(\.count), [2, 1]); XCTAssertEqual(days.map(\.distanceKm), [120, 60])
        let totals = DriveTotals([drive(), drive(2, kwh: nil)])
        XCTAssertEqual(totals.energyUsedKwh.known, 1); XCTAssertTrue(totals.energyUsedKwh.isPartial)
    }
    func testRouteBreaksArePreserved() {
        let p = DriveRoutePoint(t: Date(), latitude: 37.4, longitude: -122.1)
        var after = p; after.routeBreakBefore = true
        XCTAssertEqual(DriveRouteSegments.runs([p, after]).map(\.count), [1, 1])
    }
    func testRouteNormalizationFitsWithoutStretchingAndBreaksAtInvalidPoints() throws {
        let a = DriveRoutePoint(t: Date(timeIntervalSince1970: 0), latitude: 37.4, longitude: -122.1)
        let b = DriveRoutePoint(t: a.t, latitude: 37.401, longitude: -122.09)
        var invalid = a; invalid.latitude = .nan
        var c = b; c.routeBreakBefore = true
        let runs = DriveRouteSegments.normalized([a, b, invalid, a, c], in: CGSize(width: 100, height: 80))
        XCTAssertEqual(runs.map(\.count), [2, 1, 1])
        let start = try XCTUnwrap(runs.first?.first), end = try XCTUnwrap(runs.first?.last)
        XCTAssertEqual(start.x, 8, accuracy: 0.001)
        XCTAssertEqual(end.x, 92, accuracy: 0.001)
        let projectedRatio = 0.001 / (0.01 * cos(a.latitude * .pi / 180))
        XCTAssertEqual(abs(end.y - start.y) / (end.x - start.x), projectedRatio, accuracy: 0.001)
        for point in runs.flatMap({ $0 }) {
            XCTAssertTrue((8...92).contains(point.x))
            XCTAssertTrue((8...72).contains(point.y))
        }
    }
    func testRouteNormalizationHandlesEmptySingletonRepeatedAndOutOfBounds() {
        let point = DriveRoutePoint(t: Date(timeIntervalSince1970: 0), latitude: 37.4, longitude: -122.1)
        let size = CGSize(width: 64, height: 64)
        XCTAssertTrue(DriveRouteSegments.normalized([], in: size).isEmpty)
        XCTAssertEqual(DriveRouteSegments.normalized([point], in: size), [[CGPoint(x: 32, y: 32)]])
        XCTAssertEqual(DriveRouteSegments.normalized([point, point], in: size), [[CGPoint(x: 32, y: 32), CGPoint(x: 32, y: 32)]])
        var invalid = point; invalid.longitude = 181
        XCTAssertEqual(DriveRouteSegments.runs([point, invalid, point]).map(\.count), [1, 1])
        XCTAssertTrue(DriveRouteSegments.normalized([invalid], in: size).isEmpty)
    }
    @MainActor func testRateSettingsPersistenceAndDefault() {
        let defaults = UserDefaults(suiteName: "DriveInsightsTests")!
        defaults.removePersistentDomain(forName: "DriveInsightsTests")
        defer { defaults.removePersistentDomain(forName: "DriveInsightsTests") }
        let settings = UserSettings(defaults: defaults)
        XCTAssertEqual(settings.electricityRate, 0.20)
        settings.electricityRate = 0
        XCTAssertEqual(UserSettings(defaults: defaults).electricityRate, 0)
        defaults.set(-1.0, forKey: "electricityRate")
        XCTAssertEqual(UserSettings(defaults: defaults).electricityRate, 0.20)
    }
}
