import XCTest
@testable import Volta

final class ParkedSummaryTests: XCTestCase {
    private let calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    /// 2026-11-15 12:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_794_744_000)
    private let miles = ParkedText(units: UnitPreferences(distance: .miles))
    private let kilometres = ParkedText(units: UnitPreferences(distance: .kilometers))
    private let kmPerMile = 1.609344

    private func stop(_ id: Int, endingHoursAgo: Double = 1, minutes: Double, km: Double?, name: String? = "Home",
                      latitude: Double? = nil, longitude: Double? = nil, asleep: Double? = nil, open: Bool = false) -> IdleSummary {
        let end = now.addingTimeInterval(-endingHoursAgo * 3600)
        let start = open ? now.addingTimeInterval(-minutes * 60) : end.addingTimeInterval(-minutes * 60)
        return IdleSummary(id: id, start: start, end: open ? nil : end, address: nil, placeName: name, durationMin: minutes,
                           startBatteryLevel: 80, endBatteryLevel: open ? nil : 79, rangeLostKm: km, energyLostKwh: km.map { $0 * 0.15 },
                           sentryMinutes: nil, climateMinutes: nil, asleepMinutes: asleep, latitude: latitude, longitude: longitude)
    }

    private func summary(_ stops: [IdleSummary], partial: Bool = false, from: Date? = nil) -> ParkedSummary {
        ParkedSummary(stops, partial: partial, from: from, now: now, calendar: calendar)
    }

    // MARK: Rates

    func testRateDividesByTheTimeThatRecordedLossOnly() {
        let s = summary([stop(1, minutes: 720, km: 5), stop(2, endingHoursAgo: 20, minutes: 1440, km: nil)])
        XCTAssertEqual(s.total.lost, 5)
        XCTAssertEqual(try XCTUnwrap(s.total.perDayKm), 10, accuracy: 1e-9, "5 km over 12 recorded hours, not over 36")
        XCTAssertEqual(s.total.minutes, 2160)
        XCTAssertEqual(s.notes, ["Range loss recorded for 1 of 2 stops"])
        XCTAssertEqual(s.energyKwh.value ?? 0, 0.75, accuracy: 1e-9)
    }

    func testOneRateFunctionForRowsPlacesAndTotals() {
        let only = stop(1, minutes: 600, km: 4)
        let s = summary([only])
        guard case .lost(_, let rowRate?) = ParkedLoss(only) else { return XCTFail("expected a rate") }
        XCTAssertEqual(rowRate, s.places[0].tally.perDayKm)
        XCTAssertEqual(rowRate, s.total.perDayKm)
        XCTAssertEqual(ParkedTally.rate(lostKm: 4, minutes: 600), rowRate)
    }

    func testShortStopsHaveNoRate() {
        XCTAssertEqual(ParkedLoss(stop(1, minutes: 59, km: 0.4)), .lost(km: 0.4, perDayKm: nil))
        XCTAssertNotNil(ParkedTally.rate(lostKm: 0.4, minutes: ParkedRules.rateMinMinutes))
        XCTAssertEqual(miles.lossLine(.lost(km: 0.4 * kmPerMile, perDayKm: nil)), "−0.4 mi")
    }

    // MARK: Missing, zero and open

    func testMissingLossIsNotZero() {
        let s = summary([stop(1, minutes: 600, km: nil), stop(2, minutes: 120, km: nil)])
        XCTAssertNil(s.total.lost)
        XCTAssertNil(s.total.perDayKm)
        XCTAssertNil(s.energyKwh.value)
        XCTAssertNil(s.fastest)
        XCTAssertEqual(ParkedLoss(stop(1, minutes: 600, km: nil)), .notRecorded)
        XCTAssertEqual(miles.lossLine(.notRecorded), "Loss not recorded")
        XCTAssertEqual(s.days.last?.lostKm, nil, "stops that ended today recorded nothing: unknown, not 0")
    }

    func testRecordedZeroIsNoLossMeasured() {
        XCTAssertEqual(ParkedLoss(stop(1, minutes: 600, km: 0)), .noLoss)
        XCTAssertEqual(miles.lossLine(.noLoss), "No loss measured")
        let s = summary([stop(1, minutes: 600, km: 0)])
        XCTAssertEqual(s.total.lost, 0)
        XCTAssertEqual(s.total.perDayKm, 0)
        XCTAssertNil(s.fastest, "a zero rate is no drain record")
    }

    func testOpenStopIsPendingAndOutsideTheTotals() {
        let live = stop(9, minutes: 88, km: 3, open: true)
        XCTAssertEqual(ParkedLoss(live), .pending, "the end range is unknown until the next drive or charge")
        XCTAssertEqual(miles.lossLine(.pending), "Loss is measured when the car next drives or charges")
        let s = summary([live, stop(1, minutes: 600, km: 2)])
        XCTAssertEqual(s.open?.id, 9)
        XCTAssertEqual(s.stops.map(\.id), [1])
        XCTAssertEqual(s.total.stops, 1)
        XCTAssertEqual(s.total.lost, 2)
        XCTAssertFalse(s.isEmpty)
        XCTAssertNil(summary([stop(1, minutes: 600, km: 2)]).open)
    }

    // MARK: Days

    func testStopCrossingMidnightCountsForTheDayItEnded() {
        // Ended 09:00 today after 11 hours: started 22:00 yesterday.
        let overnight = stop(1, endingHoursAgo: 3, minutes: 660, km: 2)
        let s = summary([overnight], from: now.addingTimeInterval(-2 * 86_400))
        XCTAssertEqual(s.days.count, 3)
        XCTAssertEqual(s.days.last?.lostKm, 2)
        XCTAssertTrue(s.days.last?.isToday ?? false)
        XCTAssertEqual(s.days[1].lostKm, 0, "nothing ended yesterday")
        XCTAssertEqual(s.groups.map(\.day), [calendar.startOfDay(for: now)])
        let range = overnight.timeRange(now: now, calendar: calendar)
        XCTAssertTrue(range.0.hasPrefix("Yesterday "))
    }

    func testPartialPagesStartTheChartAtTheEarliestLoadedStop() {
        let stops = [stop(1, endingHoursAgo: 1, minutes: 300, km: 1), stop(2, endingHoursAgo: 49, minutes: 300, km: 1)]
        let from = now.addingTimeInterval(-30 * 86_400)
        XCTAssertEqual(summary(stops, partial: true, from: from).days.count, 3, "days before the loaded pages are unknown")
        XCTAssertEqual(summary(stops, partial: false, from: from).days.count, 31)
        XCTAssertTrue(summary(stops, partial: true).partial)
    }

    func testHighestDayIsMarkedOnlyWhenClearlyAboveTheMean() {
        let spiky = summary([stop(1, endingHoursAgo: 1, minutes: 600, km: 1), stop(2, endingHoursAgo: 25, minutes: 600, km: 6),
                             stop(3, endingHoursAgo: 49, minutes: 600, km: 1)])
        XCTAssertEqual(spiky.days.filter(\.isHighest).map(\.lostKm), [6])
        let flat = summary([stop(1, endingHoursAgo: 1, minutes: 600, km: 2), stop(2, endingHoursAgo: 25, minutes: 600, km: 2.1)])
        XCTAssertTrue(flat.days.allSatisfy { !$0.isHighest })
    }

    func testDayTotalIsTheSumOfTheRowsAsShown() {
        // Each row shows 1.0 mi (1.04 rounded); the header must say 2.0, not 2.1.
        let km = 1.04 * kmPerMile
        let rows = [stop(1, minutes: 600, km: km), stop(2, minutes: 600, km: km), stop(3, minutes: 600, km: nil)]
        XCTAssertEqual(miles.dayTotal(rows), "3 stops · −2.0 mi")
        XCTAssertTrue(miles.lossLine(ParkedLoss(rows[0])).hasPrefix("−1.0 mi"))
        XCTAssertEqual(miles.dayTotal([stop(4, minutes: 600, km: nil)]), "1 stop")
    }

    // MARK: Places, amber and the finding

    func testSinglePlaceHasNoFindingAndNoAmber() {
        let s = summary((1...5).map { stop($0, endingHoursAgo: Double($0) * 24, minutes: 600, km: 4) })
        XCTAssertEqual(s.places.count, 1)
        XCTAssertEqual(s.places[0].share, 1, accuracy: 1e-9)
        XCTAssertFalse(s.places[0].isNotable)
        XCTAssertNil(s.finding)
    }

    func testFindingComparesTwoSubstantialPlaces() {
        let home = 3.0 * kmPerMile, work = 5.8 * kmPerMile
        let stops = (1...3).map { stop($0, endingHoursAgo: Double($0) * 24, minutes: 480, km: home / 3, name: "Home") }
            + (4...6).map { stop($0, endingHoursAgo: Double($0) * 24 + 12, minutes: 600, km: work * 600 / 1440, name: "Work") }
        let s = summary(stops)
        let finding = try? XCTUnwrap(s.finding)
        XCTAssertEqual(finding?.higher.name, "Work")
        XCTAssertEqual(finding?.lower.name, "Home")
        XCTAssertEqual(finding?.ratio ?? 0, 5.8 / 3.0, accuracy: 1e-9)
        let words = miles.finding(s.finding!)
        XCTAssertEqual(words.headline, "Recorded loss at Work was about twice Home’s per day.")
        XCTAssertEqual(words.detail, "5.8 mi a day against 3.0.")
        XCTAssertEqual(kilometres.finding(s.finding!).detail, "9.3 km a day against 4.8.")
    }

    func testPlacesBelowTheMinimumGetNoFindingOrAmber() {
        // Work loses fast but has only two stops (20 h).
        let stops = (1...4).map { stop($0, endingHoursAgo: Double($0) * 24, minutes: 600, km: 2, name: "Home") }
            + (5...6).map { stop($0, endingHoursAgo: Double($0) * 24 + 12, minutes: 600, km: 12, name: "Work") }
        let s = summary(stops)
        XCTAssertNil(s.finding)
        let work = try? XCTUnwrap(s.places.first { $0.name == "Work" })
        XCTAssertFalse(work?.tally.isSubstantial ?? true)
        XCTAssertFalse(work?.isNotable ?? true, "below the minimum stays neutral even with a high rate")
        XCTAssertNotNil(work?.tally.perDayKm)
    }

    func testAmberNeedsTheMinimumAndOneAndAHalfTimesTheAverage() {
        var substantial = ParkedTally()
        for _ in 0..<3 { substantial.add(stop(1, minutes: 480, km: 3)) }   // 24 h, 9 km/day
        XCTAssertTrue(substantial.isSubstantial)
        XCTAssertTrue(ParkedSummary.isNotable(substantial, average: 6))     // 1.5×
        XCTAssertFalse(ParkedSummary.isNotable(substantial, average: 6.1))
        XCTAssertFalse(ParkedSummary.isNotable(substantial, average: nil))
        XCTAssertFalse(ParkedSummary.isNotable(substantial, average: 0))
        var thin = ParkedTally()
        for _ in 0..<2 { thin.add(stop(1, minutes: 900, km: 9)) }          // 30 h but 2 stops
        XCTAssertFalse(ParkedSummary.isNotable(thin, average: 1))
        var short = ParkedTally()
        for _ in 0..<4 { short.add(stop(1, minutes: 300, km: 9)) }         // 4 stops, 20 h
        XCTAssertFalse(ParkedSummary.isNotable(short, average: 1))
    }

    func testAmberAppliesInASummary() {
        // Home: long and slow; Work: substantial and fast.
        let stops = (1...6).map { stop($0, endingHoursAgo: Double($0) * 24, minutes: 1200, km: 2, name: "Home") }
            + (7...9).map { stop($0, endingHoursAgo: Double($0) * 24 + 12, minutes: 600, km: 5, name: "Work") }
        let s = summary(stops)
        XCTAssertEqual(s.places.first { $0.name == "Work" }?.isNotable, true)
        XCTAssertEqual(s.places.first { $0.name == "Home" }?.isNotable, false)
    }

    func testUnnamedStopsGroupByRoundedCoordinates() {
        let a = stop(1, minutes: 600, km: 1, name: nil, latitude: 37.44191, longitude: -122.14302)
        let b = stop(2, minutes: 600, km: 1, name: nil, latitude: 37.44194, longitude: -122.14304)
        let c = stop(3, minutes: 600, km: 1, name: nil, latitude: 37.45, longitude: -122.14)
        let named = stop(4, minutes: 600, km: 1, name: " Home ", latitude: 37.44191, longitude: -122.14302)
        XCTAssertEqual(ParkedPlace.key(a), ParkedPlace.key(b))
        XCTAssertNotEqual(ParkedPlace.key(a), ParkedPlace.key(c))
        XCTAssertEqual(ParkedPlace.key(named), "name:home")
        XCTAssertEqual(summary([a, b, c, named]).places.count, 3)
    }

    func testRestOfThePlacesFoldIntoOneRow() {
        let names = ["A", "B", "C", "D", "E"]
        let stops = names.enumerated().map { stop($0.offset, minutes: Double(600 - $0.offset * 60), km: 1, name: $0.element) }
        let shown = summary(stops).shownPlaces
        XCTAssertEqual(shown.map(\.name), ["A", "B", "C", "2 other places"])
        XCTAssertEqual(shown.last?.tally.stops, 2)
        XCTAssertFalse(shown.last?.isNotable ?? true)
        XCTAssertEqual(summary(Array(stops.prefix(4))).shownPlaces.count, 4, "four places need no fold")
    }

    // MARK: Fastest drain and asleep

    func testFastestDrainCountsOnlyStopsLongEnoughForARate() {
        let s = summary([stop(1, minutes: 30, km: 3),       // short: no rate
                         stop(2, minutes: 600, km: 4),
                         stop(3, minutes: 120, km: 1)])     // 12 km/day
        XCTAssertEqual(s.fastest?.id, 3)
    }

    func testAsleepCoversOnlyStopsThatRecordedIt() {
        let s = summary([stop(1, minutes: 600, km: 1, asleep: 540), stop(2, minutes: 400, km: 1, asleep: 200),
                         stop(3, minutes: 900, km: 1)])
        let asleep = try? XCTUnwrap(s.asleep)
        XCTAssertEqual(asleep?.coveredStops, 2)
        XCTAssertEqual(asleep?.stops, 3)
        XCTAssertEqual(asleep?.share ?? 0, 0.74, accuracy: 1e-9)
        XCTAssertNil(summary([stop(1, minutes: 600, km: 1)]).asleep, "hidden when no stop recorded it")
    }

    // MARK: Units

    func testDistancesFollowTheUnitSetting() {
        XCTAssertEqual(miles.distance(4.828), "3.0 mi")
        XCTAssertEqual(kilometres.distance(4.828), "4.8 km")
        XCTAssertEqual(miles.distance(37 * kmPerMile), "37 mi")
        XCTAssertEqual(kilometres.rate(9.3), "9.3 km a day")
        XCTAssertEqual(kilometres.lossLine(.lost(km: 2.75, perDayKm: 6.6)), "−2.8 km · 6.6 km a day")
        XCTAssertEqual(miles.lossLine(.lost(km: 2.75, perDayKm: 6.6)), "−1.7 mi · 4.1 mi a day")
        XCTAssertEqual(ParkedText.span(14_460), "10d 1h")
        XCTAssertEqual(ParkedText.span(424), "7h 4m")
    }

    func testChartTicksAreRound() {
        XCTAssertEqual(ParkedLossChart.axisTop(2.6), 3)
        XCTAssertEqual(ParkedLossChart.axisTop(4.4), 6)
        XCTAssertEqual(ParkedLossChart.axisTop(6.5), 7.5)
        XCTAssertEqual(ParkedLossChart.axisTop(0), 3)
        XCTAssertEqual(ParkedLossChart.ticks(6), [2, 4, 6])
    }

    // MARK: Demo data

    func testDemoHasAnOpenStopOnlyWhileNotCharging() async throws {
        defer { UserDefaults.standard.removeObject(forKey: "demoCharging") }
        let source = MockDataSource(now: now)
        UserDefaults.standard.set(false, forKey: "demoCharging")
        let parked = try await source.idles(vehicleID: 1, range: .init(), cursor: nil).items
        let open = parked.filter(\.isLive)
        XCTAssertEqual(open.count, 1)
        XCTAssertNil(open.first?.rangeLostKm, "an open stop has no loss yet")
        UserDefaults.standard.set(true, forKey: "demoCharging")
        let charging = try await source.idles(vehicleID: 1, range: .init(), cursor: nil).items
        XCTAssertTrue(charging.allSatisfy { !$0.isLive }, "no stop is open while the car charges")
        XCTAssertNil(charging.first { $0.sentryMinutes != nil }, "the server never sends sentry time")
    }
}
