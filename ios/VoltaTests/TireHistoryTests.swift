import XCTest
@testable import Volta

/// Tyre pressure history: decoding, gaps, the change over a period, a wheel
/// reading apart, units, the loading model and the demo data.
final class TireHistoryTests: XCTestCase {
    private var utc: Calendar { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c }
    private func day(_ n: Int) -> Date { Date(timeIntervalSince1970: 1_780_000_000 - 1_780_000_000.truncatingRemainder(dividingBy: 86_400) + Double(n) * 86_400) }
    private func point(_ n: Int, low: Double, avg: Double? = nil, high: Double? = nil,
                       peer: (delta: Double, others: Double, readings: Int)? = nil, peerWheels: Int? = nil) -> TirePressureHistory.Point {
        TirePressureHistory.Point(start: day(n), minBar: low, avgBar: avg ?? low + 0.1, maxBar: high ?? low + 0.2, readings: 10,
                                  firstAt: day(n).addingTimeInterval(3600), lastAt: day(n).addingTimeInterval(7200),
                                  peerReadings: peer?.readings, peerDeltaBar: peer?.delta, peerBar: peer?.others, peerWheels: peerWheels)
    }
    /// Days `days` of one wheel, each with the same-moment comparison `delta`
    /// against the others' `others` bar.
    private func run(_ days: ClosedRange<Int>, low: Double, delta: Double, others: Double = 2.9, readings: Int = 40,
                     wheels: Int? = nil) -> [TirePressureHistory.Point] {
        days.map { point($0, low: low, peer: (delta, others, readings), peerWheels: wheels) }
    }
    private func history(fl: [TirePressureHistory.Point] = [], fr: [TirePressureHistory.Point] = [], rl: [TirePressureHistory.Point] = [],
                         rr: [TirePressureHistory.Point] = [], bucket: TirePressureHistory.Bucket = .day) -> TirePressureHistory {
        TirePressureHistory(bucket: bucket, timeZone: "UTC", from: nil, to: day(100), firstReadingAt: nil, lastReadingAt: nil,
                            wheels: .init(fl: fl, fr: fr, rl: rl, rr: rr))
    }

    func testDecodesTheServerShape() throws {
        let json = """
        {"vehicleId":1,"source":"teslamate","unit":"bar","bucket":"day","timeZone":"America/Los_Angeles",
         "from":null,"to":"2026-06-30T12:00:00.000Z","firstReadingAt":"2026-06-01T08:00:00.000Z","lastReadingAt":"2026-06-01T08:00:00.000Z",
         "wheels":{"fl":[{"start":"2026-06-01T07:00:00.000Z","minBar":2.9,"avgBar":2.9,"maxBar":2.9,"readings":1,
           "firstAt":"2026-06-01T08:00:00.000Z","lastAt":"2026-06-01T08:00:00.000Z"}],"fr":[],"rl":[],"rr":[]}}
        """
        let decoded = try APIDataSource.makeDecoder().decode(TirePressureHistory.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.bucket, .day)
        XCTAssertNil(decoded.from)
        XCTAssertEqual(decoded.wheels.fl.first?.readings, 1)
        XCTAssertTrue(decoded.wheels.rr.isEmpty)
        XCTAssertFalse(decoded.isEmpty)
        XCTAssertTrue(history().isEmpty)
    }

    func testEmptyHistoryHasNothingToPlotOrCompare() {
        let h = history()
        XCTAssertTrue(TireHistoryMath.plots([], bucket: .day, statistic: .low, calendar: utc).isEmpty)
        XCTAssertNil(TireHistoryMath.change([], statistic: .low, calendar: utc))
        XCTAssertNil(TireHistoryMath.apart(h, calendar: utc))
        XCTAssertEqual(TireHistoryMath.unusualDrops(h, statistic: .low), [])
        XCTAssertEqual(TireHistoryMath.yDomain([], guide: nil), 2...3.5)
    }

    func testOneReadingIsAnIsolatedDotWithNoChange() {
        let plots = TireHistoryMath.plots([point(1, low: 2.9)], bucket: .day, statistic: .low, calendar: utc)
        XCTAssertEqual(plots.count, 1)
        XCTAssertEqual(TireHistoryMath.isolated(plots).count, 1)
        XCTAssertNil(TireHistoryMath.change([point(1, low: 2.9)], statistic: .low, calendar: utc))
    }

    func testMissingDaysBreakTheLine() {
        let points = [point(1, low: 2.9), point(2, low: 2.9), point(5, low: 2.8), point(6, low: 2.8), point(9, low: 2.7)]
        let plots = TireHistoryMath.plots(points.shuffled(), bucket: .day, statistic: .low, calendar: utc)
        XCTAssertEqual(plots.map(\.segment), [0, 0, 1, 1, 2])
        XCTAssertEqual(TireHistoryMath.isolated(plots).map(\.start), [day(9)])
        // Weeks: consecutive weekly buckets join; a missing week breaks.
        let weeks = [point(0, low: 2.9), point(7, low: 2.9), point(21, low: 2.8)]
        XCTAssertEqual(TireHistoryMath.plots(weeks, bucket: .week, statistic: .low, calendar: utc).map(\.segment), [0, 0, 1])
    }

    func testDaysAreCountedInTheServersZoneAcrossDaylightSaving() {
        var la = Calendar(identifier: .gregorian); la.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        // Local midnights on either side of the November 2026 change are 25 hours apart: still consecutive days.
        let before = la.date(from: DateComponents(year: 2026, month: 10, day: 31))!, after = la.date(from: DateComponents(year: 2026, month: 11, day: 1))!
        let next = la.date(from: DateComponents(year: 2026, month: 11, day: 2))!
        func p(_ d: Date) -> TirePressureHistory.Point { .init(start: d, minBar: 2.9, avgBar: 2.9, maxBar: 2.9, readings: 1, firstAt: d, lastAt: d) }
        let h = TirePressureHistory(bucket: .day, timeZone: "America/Los_Angeles", from: nil, to: next, firstReadingAt: nil, lastReadingAt: nil,
                                    wheels: .init(fl: [p(before), p(after), p(next)], fr: [], rl: [], rr: []))
        let plots = TireHistoryMath.plots(h.wheels.fl, bucket: .day, statistic: .low, calendar: TireHistoryMath.calendar(for: h))
        XCTAssertEqual(plots.map(\.segment), [0, 0, 0])
    }

    func testStatisticChoosesTheLine() {
        let points = [point(1, low: 2.8, avg: 2.95, high: 3.1)]
        XCTAssertEqual(TireHistoryMath.plots(points, bucket: .day, statistic: .low, calendar: utc).first?.bar, 2.8)
        XCTAssertEqual(TireHistoryMath.plots(points, bucket: .day, statistic: .average, calendar: utc).first?.bar, 2.95)
        XCTAssertEqual(TireHistoryMath.plots(points, bucket: .day, statistic: .low, calendar: utc).first?.highBar, 3.1)
    }

    func testNonFiniteValuesAreDropped() {
        let points = [point(1, low: .nan), point(2, low: 2.9)]
        XCTAssertEqual(TireHistoryMath.plots(points, bucket: .day, statistic: .low, calendar: utc).map(\.start), [day(2)])
    }

    func testChangeOverThePeriod() throws {
        let change = try XCTUnwrap(TireHistoryMath.change([point(30, low: 2.6), point(1, low: 2.9), point(12, low: 2.8)],
                                                          statistic: .low, calendar: utc))
        XCTAssertEqual(change.deltaBar, -0.3, accuracy: 1e-9)
        XCTAssertEqual(change.days, 30, "day 1 to day 30 is a change in 30 days")
        XCTAssertEqual(change.from, day(1))
    }

    func testAWeeklyChangeSpansTheReadingsNotTheBucketStarts() throws {
        // Readings only on Sunday Nov 1 and Monday Nov 2: the weeks start
        // Oct 26 and Nov 2, but the change covers two days of readings.
        func at(_ text: String) -> Date { try! Date(text, strategy: .iso8601) }
        let sunday = TirePressureHistory.Point(start: at("2026-10-26T00:00:00Z"), minBar: 2.9, avgBar: 2.9, maxBar: 2.9, readings: 3,
                                               firstAt: at("2026-11-01T08:00:00Z"), lastAt: at("2026-11-01T18:00:00Z"))
        let monday = TirePressureHistory.Point(start: at("2026-11-02T00:00:00Z"), minBar: 2.7, avgBar: 2.7, maxBar: 2.7, readings: 3,
                                               firstAt: at("2026-11-02T08:00:00Z"), lastAt: at("2026-11-02T09:00:00Z"))
        let change = try XCTUnwrap(TireHistoryMath.change([sunday, monday], statistic: .low, calendar: utc))
        XCTAssertEqual(change.days, 2, "not 8, from Oct 26 to Nov 2")
        XCTAssertEqual(change.deltaBar, -0.2, accuracy: 1e-9)
    }

    func testAWheelReadingApartAtTheSameMomentsForThreeDays() throws {
        let h = history(fl: run(1...3, low: 2.9, delta: 0.05), fr: run(1...3, low: 2.9, delta: 0.05),
                        rl: run(1...3, low: 2.5, delta: -0.4, others: 2.92), rr: run(1...3, low: 2.8, delta: 0))
        let apart = try XCTUnwrap(TireHistoryMath.apart(h, calendar: utc))
        XCTAssertEqual(apart.wheel, .rl)
        XCTAssertEqual(apart.deltaBar, -0.4, accuracy: 1e-9)
        XCTAssertEqual(apart.othersBar, 2.92, accuracy: 1e-9)
        XCTAssertEqual(apart.wheelBar, 2.52, accuracy: 1e-9)
        XCTAssertEqual(apart.on, day(3))
        XCTAssertNil(apart.otherWheels, "an older server does not say how many took part")
        // Ordinary spread is not called out.
        let even = history(fl: run(1...3, low: 2.9, delta: 0.1), fr: run(1...3, low: 2.8, delta: -0.1),
                           rl: run(1...3, low: 2.8, delta: -0.1), rr: run(1...3, low: 2.9, delta: 0.1))
        XCTAssertNil(TireHistoryMath.apart(even, calendar: utc))
    }

    func testTheBannerNamesOnlyTheTyresThatTookPart() throws {
        // Rear right reported last month but not in the last three days: rear
        // left was compared with two wheels, whatever the period's history holds.
        let two = history(fl: run(1...3, low: 2.9, delta: 0.1, wheels: 2), fr: run(1...3, low: 2.9, delta: 0.1, wheels: 2),
                          rl: run(1...3, low: 2.5, delta: -0.4, wheels: 2), rr: [point(-20, low: 2.9)])
        XCTAssertEqual(try XCTUnwrap(TireHistoryMath.apart(two, calendar: utc)).otherWheels, 2)
        // Three in two of the days and two in the third: the count is not certain.
        let mixed = history(fl: run(1...3, low: 2.9, delta: 0.1), rl: run(1...2, low: 2.5, delta: -0.4, wheels: 3) + run(3...3, low: 2.5, delta: -0.4, wheels: 2))
        let apart = try XCTUnwrap(TireHistoryMath.apart(mixed, calendar: utc))
        XCTAssertNil(apart.otherWheels)
        var bar = UnitPreferences(); bar.pressure = .bar
        XCTAssertTrue(TireHistoryMath.apartMessage(apart, change: nil, isCurrent: true, units: bar).contains("below the other tires today"))
    }

    func testAMissedColdReadingIsNotAWheelApart() {
        // All four read 2.7 bar cold and 3.0 warm; the front left missed the
        // cold readings, so its daily low is 3.0. At the same moments it reads
        // like the others, and nothing is flagged.
        let h = history(fl: run(1...3, low: 3.0, delta: 0), fr: run(1...3, low: 2.7, delta: 0),
                        rl: run(1...3, low: 2.7, delta: 0), rr: run(1...3, low: 2.7, delta: 0))
        XCTAssertNil(TireHistoryMath.apart(h, calendar: utc))
    }

    func testAWheelMustReadApartSeveralBucketsInARow() {
        // Apart only today: not yet.
        let once = history(fl: run(1...3, low: 2.9, delta: 0), fr: run(1...3, low: 2.9, delta: 0),
                           rl: run(1...2, low: 2.9, delta: 0) + run(3...3, low: 2.5, delta: -0.4), rr: run(1...3, low: 2.9, delta: 0))
        XCTAssertNil(TireHistoryMath.apart(once, calendar: utc))
        // Three days apart, but with a missing day in the run: not a run.
        let broken = history(fl: run(1...5, low: 2.9, delta: 0), rl: run(1...1, low: 2.5, delta: -0.4) + run(4...5, low: 2.5, delta: -0.4))
        XCTAssertNil(TireHistoryMath.apart(broken, calendar: utc))
        // Too few same-moment readings on a day: that day does not count.
        let thin = history(fl: run(1...3, low: 2.9, delta: 0), rl: run(1...2, low: 2.5, delta: -0.4) + run(3...3, low: 2.5, delta: -0.4, readings: 3))
        XCTAssertNil(TireHistoryMath.apart(thin, calendar: utc))
        // A run that ended a week ago is not today's news.
        let stale = history(fl: run(1...10, low: 2.9, delta: 0), rl: run(1...3, low: 2.5, delta: -0.4))
        XCTAssertNil(TireHistoryMath.apart(stale, calendar: utc))
        // Weekly buckets need two weeks in a row.
        let weeks = history(fl: [0, 7].map { point($0, low: 2.9, peer: (0, 2.9, 40)) },
                            rl: [0, 7].map { point($0, low: 2.5, peer: (-0.4, 2.9, 40)) }, bucket: .week)
        XCTAssertEqual(TireHistoryMath.apart(weeks, calendar: utc)?.buckets, 2)
    }

    func testAnOlderServerWithoutSameMomentDataFlagsNothing() {
        let h = history(fl: [point(1, low: 2.9), point(2, low: 2.9), point(3, low: 2.9)],
                        rl: [point(1, low: 2.2), point(2, low: 2.2), point(3, low: 2.2)])
        XCTAssertNil(TireHistoryMath.apart(h, calendar: utc))
    }

    func testTheBannerAgreesWithItsOwnNumbers() {
        var psi = UnitPreferences(); psi.pressure = .psi
        var bar = UnitPreferences(); bar.pressure = .bar
        var apart = TireHistoryMath.Apart(wheel: .rl, deltaBar: -0.69, wheelBar: 2.21, othersBar: 2.9, on: day(90), buckets: 3, otherWheels: 3)
        let change = TireHistoryMath.Change(deltaBar: -0.83, from: day(1), to: day(90), days: 90)
        // 2.21 bar shows as 32 psi and 2.9 as 42: the gap reads 10, from the shown values.
        XCTAssertEqual(TireHistoryMath.apartMessage(apart, change: change, isCurrent: true, units: psi),
                       "Rear left is 10 psi below the other three today (32 vs 42 psi) and has dropped 12 psi in 90 days. Check it with a gauge when cold.")
        XCTAssertTrue(TireHistoryMath.apartMessage(apart, change: nil, isCurrent: true, bucket: .week, units: bar)
            .contains("below the other three this week"))
        apart.otherWheels = 2
        XCTAssertEqual(TireHistoryMath.apartMessage(apart, change: nil, isCurrent: false, units: bar),
                       "Rear left is 0.7 bar below the other two on \(day(90).formatted(.dateTime.month(.abbreviated).day())) (2.2 vs 2.9 bar). Check it with a gauge when cold.")
        apart.otherWheels = nil
        XCTAssertTrue(TireHistoryMath.apartMessage(apart, change: nil, isCurrent: false, bucket: .week, units: bar)
            .contains("below the other tires in the week of"))
        // A change that rounds to nothing is not mentioned.
        let flat = TireHistoryMath.Change(deltaBar: -0.02, from: day(1), to: day(90), days: 90)
        XCTAssertFalse(TireHistoryMath.apartMessage(apart, change: flat, isCurrent: true, units: bar).contains("dropped"))
    }

    func testASeasonalDropMarksNoWheelButALeakMarksOne() {
        // Every wheel cools by 0.2–0.3 bar between day 1 and day 60: none stands out.
        let seasonal = history(fl: [point(1, low: 2.9), point(60, low: 2.7)], fr: [point(1, low: 2.9), point(60, low: 2.7)],
                               rl: [point(1, low: 2.9), point(60, low: 2.6)], rr: [point(1, low: 2.8), point(60, low: 2.6)])
        XCTAssertEqual(TireHistoryMath.unusualDrops(seasonal, statistic: .low), [])
        let leak = history(fl: [point(1, low: 2.9), point(60, low: 2.7)], fr: [point(1, low: 2.9), point(60, low: 2.8)],
                           rl: [point(1, low: 2.9), point(60, low: 2.2)], rr: [point(1, low: 2.8), point(60, low: 2.6)])
        XCTAssertEqual(TireHistoryMath.unusualDrops(leak, statistic: .low), [.rl])
        XCTAssertEqual(TireHistoryMath.unusualDrops(history(rl: [point(1, low: 2.9), point(60, low: 2.2)]), statistic: .low), [],
                       "one wheel alone has nothing to differ from")
    }

    func testDropsAreComparedOverTheBucketsEveryWheelShares() {
        // The front left has 90 days falling 3.1 → 2.8 bar; the others only
        // report from day 60, after the cooling, and agree with it from there.
        let h = history(fl: [point(1, low: 3.1), point(60, low: 2.8), point(90, low: 2.8)],
                        fr: [point(60, low: 2.8), point(90, low: 2.8)], rl: [point(60, low: 2.8), point(90, low: 2.8)],
                        rr: [point(60, low: 2.8), point(90, low: 2.8)])
        XCTAssertEqual(TireHistoryMath.unusualDrops(h, statistic: .low), [], "over their overlap the wheels agree")
        // Its own change over the period still says what happened to it.
        XCTAssertEqual(TireHistoryMath.change(h.wheels.fl, statistic: .low, calendar: utc)?.deltaBar ?? 0, -0.3, accuracy: 1e-9)
    }

    func testAMissingWheelNeitherCountsNorHides() throws {
        // Rear right never reported; the others are still compared.
        let h = history(fl: run(1...3, low: 2.9, delta: 0.1), fr: run(1...3, low: 2.9, delta: 0.1), rl: run(1...3, low: 2.5, delta: -0.4))
        XCTAssertTrue(TireHistoryMath.plots(h.wheels.rr, bucket: .day, statistic: .low, calendar: utc).isEmpty)
        XCTAssertNil(TireHistoryMath.change(h.wheels.rr, statistic: .low, calendar: utc))
        XCTAssertEqual(TireHistoryMath.apart(h, calendar: utc)?.wheel, .rl)
    }

    func testDateTicksAreCalendarAligned() {
        let ticks = ChartDateTicks.ticks(day(0)...day(29), calendar: utc)
        XCTAssertEqual(ticks.map(\.value), [day(0), day(7), day(14), day(21), day(28)])
        XCTAssertEqual(ChartDateTicks.ticks(day(0)...day(3), calendar: utc).count, 4, "short spans tick every day")
        // A partial first day is not ticked at its start, which lies off the chart.
        XCTAssertEqual(ChartDateTicks.ticks(day(0).addingTimeInterval(3600)...day(3), calendar: utc).first?.value, day(1))
        // Longer spans tick on the first of the month, at most five.
        let year = ChartDateTicks.ticks(day(0)...day(364), calendar: utc)
        XCTAssertLessThanOrEqual(year.count, 5)
        XCTAssertTrue(year.allSatisfy { utc.component(.day, from: $0.value) == 1 })
        XCTAssertTrue(ChartDateTicks.ticks(day(0)...day(0), calendar: utc).isEmpty)
    }

    func testPressureTextFollowsTheUnitSetting() {
        var psi = UnitPreferences(); psi.pressure = .psi
        var bar = UnitPreferences(); bar.pressure = .bar
        XCTAssertEqual(TireHistoryMath.pressureText(2.9, units: psi), "42 psi")
        XCTAssertEqual(TireHistoryMath.pressureText(2.9, units: bar), "2.9 bar")
        XCTAssertEqual(TireHistoryMath.pressureText(-0.6, units: psi, signed: true), "−9 psi")
        XCTAssertEqual(TireHistoryMath.pressureText(0.1, units: bar, signed: true), "+0.1 bar")
        XCTAssertEqual(TireHistoryMath.pressureText(0.02, units: bar, signed: true), "0.0 bar", "a change that rounds away is no change")
        XCTAssertEqual(TireHistoryMath.pressureText(-0.02, units: psi, signed: true), "0 psi")
        // No saved preference shows psi, like the current-pressure display.
        XCTAssertEqual(TireHistoryMath.pressureText(2.5, units: UnitPreferences()), "36 psi")
    }

    func testChartDomainIncludesTheGuide() {
        let plots = TireHistoryMath.plots([point(1, low: 2.9, high: 3.1)], bucket: .day, statistic: .low, calendar: utc)
        let domain = TireHistoryMath.yDomain(plots, guide: TireReading.lowGuideBar)
        XCTAssertLessThan(domain.lowerBound, 2.5)
        XCTAssertGreaterThan(domain.upperBound, 3.1)
    }

    func testPeriodsStartAtLocalMidnight() {
        let now = day(100).addingTimeInterval(15 * 3600)
        XCTAssertEqual(TireHistoryMath.Period.month.from(now: now, calendar: utc), day(71))
        XCTAssertNil(TireHistoryMath.Period.all.from(now: now, calendar: utc))
    }

    func testLineNamesFollowTheBucket() {
        XCTAssertEqual(TireHistoryMath.Statistic.low.title(.day), "Daily low")
        XCTAssertEqual(TireHistoryMath.Statistic.low.title(.week), "Weekly low")
        XCTAssertEqual(TireHistoryMath.Statistic.average.title(.day), "Daily average")
        XCTAssertEqual(TireHistoryMath.Statistic.average.title(.week), "Weekly average")
    }

    func testRotationStatusPutsAReachedDeadlineFirst() {
        let km = { (v: Double) in "\(Int(v.rounded())) km" }
        func status(_ remainingKm: Double?, _ remainingDays: Int?) -> TireHistoryMath.RotationStatus {
            TireHistoryMath.rotationStatus(remainingKm: remainingKm, remainingDays: remainingDays, distance: km)
        }
        XCTAssertEqual(status(1000, -14), .init(text: "Due: 14 days past the date", isDue: true),
                       "distance left does not hide a date already past")
        XCTAssertEqual(status(-200, 30), .init(text: "Due: 200 km past the distance", isDue: true))
        XCTAssertEqual(status(-200, -3), .init(text: "Due: 200 km past the distance, 3 days past the date", isDue: true))
        XCTAssertEqual(status(500, 0), .init(text: "Due today", isDue: true))
        XCTAssertEqual(status(500, 1), .init(text: "Due in 500 km or 1 day, whichever comes first", isDue: false))
        XCTAssertEqual(status(500, nil), .init(text: "Due in 500 km", isDue: false))
        XCTAssertEqual(status(nil, 40), .init(text: "Due in 40 days", isDue: false))
        XCTAssertFalse(status(nil, nil).isDue)
    }

    func testRotationItemIsFoundByName() {
        let items = [ServiceItem(id: "a", name: "Cabin air filter", nextDate: nil, nextOdometerKm: nil, remainingKm: nil, remainingDays: nil, progress: nil),
                     ServiceItem(id: "b", name: "Tire rotation", nextDate: nil, nextOdometerKm: nil, remainingKm: 1200, remainingDays: nil, progress: 0.8)]
        XCTAssertEqual(TireHistoryMath.rotationItem(items)?.id, "b")
        XCTAssertNil(TireHistoryMath.rotationItem(Array(items.prefix(1))))
    }

    // MARK: Demo data

    func testDemoHistoryShowsTheLeakAndTheGap() async throws {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        let source = MockDataSource(now: now)
        let quarter = try await source.tireHistory(vehicleID: 1, range: DateRange(from: now.addingTimeInterval(-90 * 86_400), to: nil))
        XCTAssertEqual(quarter.bucket, .day)
        XCTAssertTrue(quarter.wheels.rl.allSatisfy { $0.start > now.addingTimeInterval(-91 * 86_400) })
        let calendar = TireHistoryMath.calendar(for: quarter)
        let rl = try XCTUnwrap(TireHistoryMath.change(quarter.wheels.rl, statistic: .low, calendar: calendar))
        XCTAssertLessThan(rl.deltaBar, -0.4, "the rear left leaks")
        XCTAssertEqual(TireHistoryMath.apart(quarter, calendar: calendar)?.wheel, .rl)
        XCTAssertEqual(TireHistoryMath.unusualDrops(quarter, statistic: .low), [.rl])
        XCTAssertGreaterThan(Set(TireHistoryMath.plots(quarter.wheels.fl, bucket: .day, statistic: .low, calendar: calendar).map(\.segment)).count, 1,
                             "the stretch without readings breaks the line")
        let all = try await source.tireHistory(vehicleID: 1, range: .init())
        XCTAssertGreaterThan(all.wheels.fl.count, 300)
        XCTAssertTrue(all.wheels.fl.allSatisfy { $0.minBar <= $0.avgBar && $0.avgBar <= $0.maxBar })
        let empty = try await MockDataSource(empty: true, now: now).tireHistory(vehicleID: 1, range: .init())
        XCTAssertTrue(empty.isEmpty)
        do { _ = try await source.tireHistory(vehicleID: 9, range: .init()); XCTFail() } catch { XCTAssertEqual(error as? VoltaError, .notFound) }
    }
}

// MARK: - Loading model and API

private actor TireGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if open { return }; await withCheckedContinuation { waiters.append($0) } }
    func release() { open = true; waiters.forEach { $0.resume() }; waiters = [] }
    func close() { open = false }
}

/// One gate per request kind, so a test decides which reply arrives first.
private actor KeyedGate {
    private var open: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    func wait(_ key: String) async {
        if open.contains(key) { return }
        await withCheckedContinuation { waiters[key, default: []].append($0) }
    }
    func release(_ key: String) { open.insert(key); waiters[key]?.forEach { $0.resume() }; waiters[key] = nil }
}

/// Answers `tireHistory` after `gate` opens, tagging the reply with its range.
/// With `ordered`, an unbounded request ("all") and a bounded one wait on
/// separate gates.
private struct TireSource: VoltaDataSource {
    let gate = TireGate()
    let keyed = KeyedGate()
    var ordered = false
    let base = MockDataSource(now: Date(timeIntervalSince1970: 1_790_000_000))
    var unsupported = false
    func vehicles() async throws -> [Vehicle] { try await base.vehicles() }
    func status(vehicleID: Int) async throws -> VehicleStatus { try await base.status(vehicleID: vehicleID) }
    func summary(vehicleID: Int, range: SummaryRange) async throws -> ActivitySummary { try await base.summary(vehicleID: vehicleID, range: range) }
    func timeline(vehicleID: Int, hours: Int) async throws -> [TimelineSegment] { [] }
    func drives(vehicleID: Int, range: DateRange, cursor: String?) async throws -> Page<DriveSummary> { Page(items: [], nextCursor: nil) }
    func drive(id: Int) async throws -> DriveDetail { throw VoltaError.notFound }
    func charges(vehicleID: Int, range: DateRange, cursor: String?) async throws -> Page<ChargeSummary> { Page(items: [], nextCursor: nil) }
    func charge(id: Int) async throws -> ChargeDetail { throw VoltaError.notFound }
    func idles(vehicleID: Int, range: DateRange, cursor: String?) async throws -> Page<IdleSummary> { Page(items: [], nextCursor: nil) }
    func battery(vehicleID: Int) async throws -> BatteryHealth { try await base.battery(vehicleID: vehicleID) }
    func mileage(vehicleID: Int, bucket: MileageBucketSize) async throws -> [MileageBucket] { [] }
    func firmware(vehicleID: Int) async throws -> [FirmwareUpdate] { [] }
    func places(vehicleID: Int) async throws -> [Place] { [] }
    func tireHistory(vehicleID: Int, range: DateRange) async throws -> TirePressureHistory {
        if ordered { await keyed.wait(range.from == nil ? "all" : "bounded") } else { await gate.wait() }
        if unsupported { throw VoltaError.notFound }
        return try await base.tireHistory(vehicleID: vehicleID, range: range)
    }
}

@MainActor
final class TireHistoryModelTests: XCTestCase {
    func testASlowOlderPeriodNeverReplacesTheNewerOne() async {
        var source = TireSource(); source.ordered = true
        let model = TireHistoryModel()
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        model.period = .all
        let older = Task { await model.load(source: source, vehicleID: 1, now: now) }
        for _ in 0..<20 { await Task.yield() }
        model.period = .month
        if case .loading = model.shown {} else { XCTFail("the new period reads as loading") }
        let newer = Task { await model.load(source: source, vehicleID: 1, now: now) }
        for _ in 0..<20 { await Task.yield() }
        // The newer request answers first and is shown…
        await source.keyed.release("bounded")
        await newer.value
        XCTAssertEqual(model.shown.value?.period, .month)
        // …then the older one succeeds last, and must not replace it.
        await source.keyed.release("all")
        await older.value
        XCTAssertEqual(model.shown.value?.period, .month)
        XCTAssertLessThan(model.shown.value?.history.wheels.fl.count ?? 99, 32)
    }

    func testAServerWithoutTheRouteSaysSo() async {
        var source = TireSource(); source.unsupported = true
        await source.gate.release()
        let model = TireHistoryModel()
        await model.load(source: source, vehicleID: 1)
        if case .failed(let message) = model.shown { XCTAssertEqual(message, TireHistoryModel.unsupportedMessage) } else { XCTFail() }
    }

    func testAPIRequestsTheRangeInTheDevicesZone() async throws {
        let body = Data(#"{"vehicleId":1,"bucket":"day","timeZone":"UTC","from":"2026-06-01T00:00:00.000Z","to":"2026-06-30T00:00:00.000Z","firstReadingAt":null,"lastReadingAt":null,"wheels":{"fl":[],"fr":[],"rl":[],"rr":[]}}"#.utf8)
        StubProtocol.handler.withLock { $0 = { request in
            XCTAssertEqual(request.url?.path, "/v1/vehicles/1/tires")
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(query.first { $0.name == "from" }?.value, "2026-06-01T00:00:00Z")
            XCTAssertNil(query.first { $0.name == "to" })
            XCTAssertEqual(query.first { $0.name == "tz" }?.value, APIDataSource.summaryTimeZone())
            return (200, body)
        } }
        StubProtocol.responseHeaders.withLock { $0 = [:] }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [StubProtocol.self]
        let api = APIDataSource(baseURL: URL(string: "https://volta.example")!, token: "synthetic-token", session: URLSession(configuration: config))
        let history = try await api.tireHistory(vehicleID: 1, range: DateRange(from: ISO8601DateFormatter().date(from: "2026-06-01T00:00:00Z"), to: nil))
        XCTAssertTrue(history.isEmpty)
    }
}
