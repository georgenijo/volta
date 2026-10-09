import XCTest
@testable import Volta

final class DriveInsightsTests: XCTestCase {
    private func drive(_ id: Int = 1, start: Double = 0, end: Double? = 3600, km: Double = 60, kwh: Double? = 10) -> DriveSummary {
        DriveSummary(id: id, start: Date(timeIntervalSince1970: start), end: end.map { Date(timeIntervalSince1970: $0) }, startAddress: nil, endAddress: nil, distanceKm: km, durationMin: 60, startBatteryLevel: nil, endBatteryLevel: nil, energyUsedKwh: kwh, efficiencyWhPerKm: kwh.map { $0 * 1000 / km }, maxSpeedKph: nil, avgSpeedKph: nil, outsideTempAvgC: nil)
    }
    func testCostPrecedenceUnknownFreeAndCurrency() {
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
    func testScoreMissingInputsAndCap() {
        var d = drive(km: 50, kwh: 10)
        XCTAssertNil(d.efficiencyScore)
        d.ratedWhPerKm = 160
        XCTAssertEqual(d.efficiencyScore, 80)
        d.efficiencyWhPerKm = 100
        XCTAssertEqual(d.efficiencyScore, 100)
        d.efficiencyWhPerKm = 0
        XCTAssertNil(d.efficiencyScore)
    }
    func testRoadtripGapsOpenDrivesOverlapAndThreshold() {
        let a = drive(), b = drive(2, start: 7200, end: 10800)
        XCTAssertEqual(Roadtrip.group([b, a]).first?.drives.map(\.id), [1, 2])
        XCTAssertTrue(Roadtrip.group([a, drive(2, start: 10801, end: 14400)]).isEmpty)
        XCTAssertTrue(Roadtrip.group([a, drive(2, start: 3600, end: nil)]).isEmpty)
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
