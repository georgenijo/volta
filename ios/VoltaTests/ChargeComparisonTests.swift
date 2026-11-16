import XCTest
@testable import Volta

/// Charge curve comparison: grouping, the session cap, colour slots, pairing
/// power with charge level, binning, the shared window, and the loading model.
final class ChargeComparisonTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func charge(_ id: Int, place: String? = "Home", address: String? = nil, fast: Bool = false, brand: String? = nil,
                        hoursAgo: Double = 0, open: Bool = false, lat: Double? = nil, lon: Double? = nil) -> ChargeSummary {
        let start = t0.addingTimeInterval(-hoursAgo * 3600)
        var c = ChargeSummary(id: id, start: start, end: open ? nil : start.addingTimeInterval(3600), address: address, placeName: place,
                              energyAddedKwh: 20, energyUsedKwh: nil, startBatteryLevel: 40, endBatteryLevel: 80, durationMin: 60,
                              maxPowerKw: nil, fastCharger: fast, cost: nil, currency: nil, outsideTempAvgC: nil)
        c.fastChargerBrand = brand; c.latitude = lat; c.longitude = lon
        return c
    }

    private func point(_ seconds: Double, _ value: Double, segment: Int = 0, id: Int = 0) -> ChargeCurvePoint {
        ChargeCurvePoint(id: id, t: t0.addingTimeInterval(seconds), value: value, segment: segment)
    }

    // MARK: Grouping

    func testPlaceKeyPrefersHomeThenPlaceThenAddressThenCoordinate() {
        XCTAssertEqual(ChargeComparison.placeKey(charge(1, place: " home ")), "home")
        XCTAssertEqual(ChargeComparison.placeKey(charge(1, place: "Downtown Garage")), ChargeComparison.placeKey(charge(2, place: "downtown garage ")))
        XCTAssertEqual(ChargeComparison.placeKey(charge(1, place: nil, address: "1 Example St")), "address:1 example st")
        XCTAssertEqual(ChargeComparison.placeKey(charge(1, place: nil, lat: 37.44191, lon: -122.14302)),
                       ChargeComparison.placeKey(charge(2, place: "", lat: 37.44188, lon: -122.14298)))
        XCTAssertNil(ChargeComparison.placeKey(charge(1, place: nil)), "nothing recorded matches nothing")
        XCTAssertNil(ChargeComparison.placeKey(charge(1, place: nil, lat: .nan, lon: 1)))
    }

    func testKindGroupsFollowChargerKind() {
        XCTAssertEqual(ChargeComparison.KindGroup(charge(1)), .home)
        XCTAssertEqual(ChargeComparison.KindGroup(charge(1, place: "Library")), .away)
        XCTAssertEqual(ChargeComparison.KindGroup(charge(1, place: "SC", fast: true, brand: "Tesla")), .fast)
        XCTAssertEqual(ChargeComparison.KindGroup(charge(1, place: "Home", fast: true)), .fast, "DC is fast wherever it is")
    }

    func testFiltersAreNewestFirstAndSamePlaceNeedsARecordedPlace() {
        let sessions = [charge(1, hoursAgo: 30), charge(2, place: "Garage", hoursAgo: 20), charge(3, hoursAgo: 10),
                        charge(4, place: "SC", fast: true, brand: "Tesla", hoursAgo: 5)]
        XCTAssertEqual(ChargeComparison.filtered(sessions, by: .samePlace, anchor: sessions[0]).map(\.id), [3, 1])
        XCTAssertEqual(ChargeComparison.filtered(sessions, by: .kind(.fast), anchor: nil).map(\.id), [4])
        XCTAssertEqual(ChargeComparison.filtered(sessions, by: .all, anchor: nil).map(\.id), [4, 3, 2, 1])
        XCTAssertEqual(ChargeComparison.filtered(sessions, by: .samePlace, anchor: nil), [])
        XCTAssertEqual(ChargeComparison.filtered(sessions, by: .samePlace, anchor: charge(9, place: nil)), [])
    }

    func testSuggestionsTakeTheSamePlaceThenTheSameKindAndSkipOpenSessions() {
        let seed = charge(1, place: "Garage", hoursAgo: 1)
        let candidates = [seed, charge(2, place: "Garage", hoursAgo: 50, open: true), charge(3, place: "Garage", hoursAgo: 40),
                          charge(4, place: "Library", hoursAgo: 30), charge(5, place: "Library", hoursAgo: 20), charge(6, hoursAgo: 2)]
        XCTAssertEqual(ChargeComparison.suggestions(for: seed, among: candidates).map(\.id), [3, 5], "same place, then same kind (away AC)")
        XCTAssertEqual(ChargeComparison.suggestions(for: seed, among: [seed]), [])
    }

    func testInsightsShortcuts() {
        let sessions = [charge(1, hoursAgo: 1), charge(2, hoursAgo: 2), charge(3, place: "Garage", hoursAgo: 3),
                        charge(4, hoursAgo: 4), charge(5, place: "SC", fast: true, hoursAgo: 5), charge(6, hoursAgo: 0, open: true)]
        XCTAssertEqual(ChargeComparison.latest(sessions, group: .home).map(\.id), [1, 2, 4], "open sessions are not offered")
        XCTAssertEqual(ChargeComparison.homeAgainstAway(sessions).map(\.id), [1, 2, 3, 5])
        XCTAssertEqual(ChargeComparison.homeAgainstAway(sessions.filter(\.isAtHome)), [], "needs both sides")
    }

    // MARK: Cap and slots

    func testSelectionIsCappedAtFiveAndKeepsOrder() {
        let many = (1...8).map { charge($0) }
        XCTAssertEqual(ChargeComparison.capped(many + [many[0]]).map(\.id), [1, 2, 3, 4, 5])
        var selection = ChargeComparison.capped(many)
        selection = ChargeComparison.toggled(selection, many[6])
        XCTAssertEqual(selection.map(\.id), [1, 2, 3, 4, 5], "a sixth session is not added")
        selection = ChargeComparison.toggled(selection, many[1])
        XCTAssertEqual(selection.map(\.id), [1, 3, 4, 5])
        selection = ChargeComparison.toggled(selection, many[6])
        XCTAssertEqual(selection.map(\.id), [1, 3, 4, 5, 7])
    }

    func testSlotsStayPutWhenASessionIsRemoved() {
        var slots = ChargeComparison.slots([10, 20, 30], previous: [:])
        XCTAssertEqual(slots, [10: 0, 20: 1, 30: 2])
        slots = ChargeComparison.slots([10, 30], previous: slots)
        XCTAssertEqual(slots, [10: 0, 30: 2])
        slots = ChargeComparison.slots([10, 30, 40], previous: slots)
        XCTAssertEqual(slots[40], 1, "the new session takes the freed slot")
        XCTAssertEqual(ChargeComparison.slots(Array(1...7), previous: [:]).count, ChargeComparison.maxSessions)
    }

    // MARK: Pairing and binning

    func testPairingInterpolatesWithinAStretchAndSkipsGaps() {
        let soc = [point(0, 40), point(60, 41), point(120, 42, segment: 0), point(1000, 50, segment: 1), point(1060, 51, segment: 1)]
        let power = [point(30, 7), point(60, 7.2), point(500, 7.1), point(1030, 7.4, segment: 1), point(-10, 7)]
            .sorted { $0.t < $1.t }
        let paired = ChargeComparison.pair(power: power, soc: soc)
        XCTAssertEqual(paired.map(\.soc), [40.5, 41, 50.5])
        XCTAssertEqual(paired.map(\.kW), [7, 7.2, 7.4], "readings before the first level or inside a level gap get none")
        XCTAssertEqual(paired.map(\.segment), [0, 0, 1])
    }

    func testPairingNeedsALevelNearby() {
        // Two readings ten minutes apart in one segment: a power sample midway is too far from both.
        let soc = [point(0, 40), point(600, 45)]
        XCTAssertTrue(ChargeComparison.pair(power: [point(300, 7)], soc: soc).isEmpty)
        XCTAssertEqual(ChargeComparison.pair(power: [point(60, 7)], soc: soc).first?.soc ?? 0, 40.5, accuracy: 1e-9)
        XCTAssertTrue(ChargeComparison.pair(power: [point(60, 7)], soc: [point(0, 40)]).isEmpty, "one level reading is not a curve")
    }

    func testBinningAveragesEachPercentAndBreaksOnJumps() {
        let paired: [ChargeComparison.Paired] = [
            .init(t: t0, soc: 20.2, kW: 100, segment: 0), .init(t: t0, soc: 20.8, kW: 110, segment: 0),
            .init(t: t0, soc: 21.5, kW: 120, segment: 0), .init(t: t0, soc: 26.1, kW: 90, segment: 0),
            .init(t: t0, soc: 27.0, kW: 80, segment: 1),
        ]
        let bins = ChargeComparison.binned(paired)
        XCTAssertEqual(bins.map(\.x), [20, 21, 26, 27])
        XCTAssertEqual(bins.map(\.kW), [105, 120, 90, 80])
        XCTAssertEqual(bins.map(\.segment), [0, 0, 1, 2], "a 5-point jump and a recording gap both break the line")
    }

    // MARK: Sessions with and without curves

    private func detail(_ summary: ChargeSummary, samples: [ChargeSample]) -> ChargeDetail {
        ChargeDetail(summary: summary, samples: samples, efficiency: nil)
    }

    private func acSamples(from start: Date, minutes: Int, startLevel: Int, kW: Double, level: Bool = true) -> [ChargeSample] {
        (0...minutes).map { m in
            ChargeSample(t: start.addingTimeInterval(Double(m) * 60), batteryLevel: level ? startLevel + m / 2 : nil,
                         powerKw: kW, voltage: nil, currentA: nil, ratedRangeKm: nil)
        }
    }

    func testASessionWithoutARecordedCurveHasNone() {
        let curve = ChargeComparison.curve(detail(charge(1), samples: []))
        XCTAssertFalse(curve.hasPower); XCTAssertFalse(curve.hasSoc)
        XCTAssertNil(curve.peakKw); XCTAssertTrue(curve.bySoc.isEmpty); XCTAssertTrue(curve.byTime.isEmpty)
    }

    func testPowerWithoutChargeLevelIsTimeOnly() {
        let s = charge(1)
        let curve = ChargeComparison.curve(detail(s, samples: acSamples(from: s.start, minutes: 60, startLevel: 40, kW: 7.2, level: false)))
        XCTAssertTrue(curve.hasPower); XCTAssertFalse(curve.hasSoc)
        XCTAssertEqual(curve.byTime.first?.x, 0); XCTAssertEqual(curve.byTime.last?.x ?? 0, 60, accuracy: 1e-9)
        XCTAssertEqual(curve.peakKw, 7.2)
    }

    func testCommonWindowAverageAndTime() throws {
        let a = charge(1), b = charge(2)
        // a: 40 → 70 % over 60 min; b: 50 → 80 % over 60 min, both at a steady power.
        let ca = ChargeComparison.curve(detail(a, samples: acSamples(from: a.start, minutes: 60, startLevel: 40, kW: 7)))
        let cb = ChargeComparison.curve(detail(b, samples: acSamples(from: b.start, minutes: 60, startLevel: 50, kW: 11)))
        let window = try XCTUnwrap(ChargeComparison.commonWindow([ca, cb]))
        XCTAssertEqual(window, 50...70)
        XCTAssertEqual(try XCTUnwrap(ChargeComparison.averageKw(ca, in: window)), 7, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(ChargeComparison.averageKw(cb, in: window)), 11, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(ChargeComparison.minutes(ca, across: window)), 40, accuracy: 1e-9)
        XCTAssertNil(ChargeComparison.commonWindow([ca]), "one curve has nothing to share")
        let short = ChargeComparison.curve(detail(b, samples: acSamples(from: b.start, minutes: 12, startLevel: 66, kW: 11)))
        XCTAssertNil(ChargeComparison.commonWindow([ca, short]), "overlap under ten points")
    }

    func testAGapInsideTheWindowLeavesItsFiguresUnknown() throws {
        let s = charge(1)
        // 40 → 70 %, with ten minutes missing in the middle of the record.
        let samples = acSamples(from: s.start, minutes: 60, startLevel: 40, kW: 7).filter { !(25...35).contains(Int($0.t.timeIntervalSince(s.start) / 60)) }
        let curve = ChargeComparison.curve(detail(s, samples: samples))
        XCTAssertGreaterThan(Set(curve.bySoc.map(\.segment)).count, 1)
        XCTAssertNil(ChargeComparison.minutes(curve, across: 45...65))
        XCTAssertNil(ChargeComparison.averageKw(curve, in: 45...65), "the missing percents are not filled in")
        XCTAssertNotNil(ChargeComparison.averageKw(curve, in: 40...50))
    }

    /// The window span of power and charge level read together at each moment.
    private func span(_ points: [(seconds: Double, soc: Double, kW: Double)], across window: ClosedRange<Int>,
                      segments: [Int]? = nil) -> ChargeComparison.WindowSpan? {
        let series = points.enumerated().map { i, p in
            (power: ChargeCurvePoint(id: i, t: t0.addingTimeInterval(p.seconds), value: p.kW, segment: segments?[i] ?? 0),
             soc: ChargeCurvePoint(id: i, t: t0.addingTimeInterval(p.seconds), value: p.soc, segment: segments?[i] ?? 0))
        }
        return ChargeComparison.span(power: series.map(\.power), soc: series.map(\.soc), across: window)
    }

    func testWindowAverageIsOverTimeNotOverPercents() throws {
        // 50 → 55 % in 5 min at 120 kW, then 55 → 60 % in 10 min at 60 kW.
        // Per percent the mean is 90 kW; over the 15 minutes it is 80 kW.
        let readings: [(seconds: Double, soc: Double, kW: Double)] = stride(from: 0.0, through: 900, by: 10).map { (t: Double) in
            let soc: Double = t <= 300 ? 50 + 5 * t / 300 : 55 + 5 * (t - 300) / 600
            let kW: Double = t < 300 ? 120 : 60
            return (t, soc, kW)
        }
        let span = try XCTUnwrap(self.span(readings, across: 50...60))
        XCTAssertEqual(span.minutes, 15, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(span.averageKw), 80, accuracy: 0.5)
        XCTAssertEqual(span.energyKWh, 20, accuracy: 0.15, "120 kW for 5 min plus 60 kW for 10 min")
    }

    func testWindowCrossingsAreInterpolated() throws {
        // (minutes, charge level): 50 % is reached at 1 min, 60 % at 25 min.
        let readings: [(seconds: Double, soc: Double, kW: Double)] = [(0, 49.5, 10), (120, 50.5, 10), (1200, 59.5, 10), (1800, 60.5, 10)]
        let span = try XCTUnwrap(self.span(readings, across: 50...60))
        XCTAssertEqual(span.minutes, 24, accuracy: 1e-9, "not 28 from the first readings past each level")
        XCTAssertEqual(try XCTUnwrap(span.averageKw), 10, accuracy: 1e-9)
        XCTAssertNil(self.span(Array(readings.dropFirst()), across: 50...60),
                     "a record that starts above the lower level cannot say when it was crossed")
        XCTAssertNotNil(self.span([(0, 50, 10), (600, 60, 10)], across: 50...60),
                        "a first reading exactly at the level is its crossing")
    }

    func testAnExactLowerCrossingAfterAGapStillCounts() throws {
        // A gap before the reading at exactly 50 %; 50 → 60 % is unbroken.
        let span = try XCTUnwrap(self.span([(0, 49, 10), (600, 50, 10), (1200, 60, 10)], across: 50...60, segments: [0, 1, 1]))
        XCTAssertEqual(span.minutes, 10, accuracy: 1e-9)
        // Interpolating 50 % across that gap would need the 49 % reading: unknown.
        XCTAssertNil(self.span([(0, 49, 10), (600, 51, 10), (1200, 60, 10)], across: 50...60, segments: [0, 1, 1]))
    }

    func testSparseChargeLevelsStillAverageEveryPowerReading() throws {
        let s = charge(1)
        // Charge level every ten minutes, power every 30 s: 10 kW within two
        // minutes of a charge-level reading, 5 kW otherwise. Pairing keeps only
        // the readings near a level, so averaging pairs alone would say 10 kW.
        let samples = stride(from: 0.0, through: 1200, by: 30).map { t -> ChargeSample in
            let fromLevel = min(t.truncatingRemainder(dividingBy: 600), 600 - t.truncatingRemainder(dividingBy: 600))
            return ChargeSample(t: s.start.addingTimeInterval(t), batteryLevel: t.truncatingRemainder(dividingBy: 600) == 0 ? 50 + Int(t / 120) : nil,
                                powerKw: fromLevel <= 120 ? 10 : 5, voltage: nil, currentA: nil, ratedRangeKm: nil)
        }
        let curve = ChargeComparison.curve(detail(s, samples: samples))
        let span = try XCTUnwrap(ChargeComparison.span(curve, across: 50...60))
        XCTAssertEqual(span.minutes, 20, accuracy: 1e-9)
        // Trapezoids over every 30 s reading: 145 kW·min over 20 min is 7.25 kW
        // (about 480 s at 10 kW and 720 s at 5 kW, with a ramp at each change).
        XCTAssertEqual(try XCTUnwrap(span.averageKw), 7.25, accuracy: 1e-9)
    }

    func testAGapThatRemovesNoPercentStillLeavesTheWindowUnknown() throws {
        let s = charge(1)
        // Slow AC: 1 % every 6 minutes, a reading every 30 s. Four minutes go
        // missing while the car sits at 52 %, so every percent is still recorded.
        func samples(dropping gap: ClosedRange<Double>?) -> [ChargeSample] {
            stride(from: 0.0, through: 3600, by: 30).compactMap { t in
                if let gap, gap.contains(t) { return nil }
                return ChargeSample(t: s.start.addingTimeInterval(t), batteryLevel: 50 + Int(t / 360), powerKw: 7,
                                    voltage: nil, currentA: nil, ratedRangeKm: nil)
            }
        }
        let whole = ChargeComparison.curve(detail(s, samples: samples(dropping: nil)))
        XCTAssertEqual(try XCTUnwrap(ChargeComparison.averageKw(whole, in: 50...60)), 7, accuracy: 1e-9)
        let gapped = ChargeComparison.curve(detail(s, samples: samples(dropping: 13 * 60...17 * 60)))
        XCTAssertEqual(Set(gapped.bySoc.map { Int($0.x) }), Set(whole.bySoc.map { Int($0.x) }), "no percent is missing")
        XCTAssertNil(ChargeComparison.averageKw(gapped, in: 50...60))
        XCTAssertNil(ChargeComparison.minutes(gapped, across: 50...60))
    }

    func testAnOutageAtOneChargeLevelStillBreaksTheWindow() throws {
        let s = charge(1)
        // 40 → 50 % at 100 kW, twenty minutes with no record, then 50 → 60 % at 50 kW:
        // every percent has a reading, but not in one stretch.
        let before = acSamples(from: s.start, minutes: 20, startLevel: 40, kW: 100)
        let after = acSamples(from: s.start.addingTimeInterval(40 * 60), minutes: 20, startLevel: 50, kW: 50)
        let curve = ChargeComparison.curve(detail(s, samples: before + after))
        XCTAssertEqual(Set(curve.bySoc.map { Int($0.x) }), Set(40...60))
        XCTAssertNil(ChargeComparison.averageKw(curve, in: 40...60), "an outage is not averaged across")
        XCTAssertNil(ChargeComparison.minutes(curve, across: 40...60))
        XCTAssertEqual(try XCTUnwrap(ChargeComparison.averageKw(curve, in: 40...50)), 100, accuracy: 1e-9)
    }

    func testDomains() {
        XCTAssertEqual(ChargeComparison.xDomain([], axis: .soc), 0...100)
        let s = charge(1)
        let curve = ChargeComparison.curve(detail(s, samples: acSamples(from: s.start, minutes: 60, startLevel: 43, kW: 7)))
        XCTAssertEqual(ChargeComparison.xDomain([curve], axis: .soc), 40...80)
        XCTAssertEqual(ChargeComparison.xDomain([curve], axis: .time).upperBound, 60, accuracy: 1e-9)
        XCTAssertNil(ChargeComparison.value(near: 10, in: curve.bySoc, tolerance: 1.5))
        XCTAssertEqual(ChargeComparison.value(near: 50.4, in: curve.bySoc, tolerance: 1.5)?.x, 50)
    }

    func testAxisTicks() {
        XCTAssertEqual(ChargeComparison.xTicks(10...80, axis: .soc), [20, 40, 60, 80])
        XCTAssertEqual(ChargeComparison.xTicks(40...80, axis: .soc), [40, 50, 60, 70, 80])
        XCTAssertEqual(ChargeComparison.xTicks(0...100, axis: .soc), [0, 20, 40, 60, 80, 100])
        XCTAssertEqual(ChargeComparison.xTicks(0...38.5, axis: .time), [0, 10, 20, 30])
        XCTAssertEqual(ChargeComparison.xTicks(0...300, axis: .time), [0, 60, 120, 180, 240, 300])
        XCTAssertEqual(ChargeComparison.xTicks(5...5, axis: .soc), [5])
    }

    func testTimeAxisEndsOnATick() {
        let s = charge(1)
        let curve = ChargeComparison.curve(detail(s, samples: acSamples(from: s.start, minutes: 38, startLevel: 43, kW: 7)))
        let domain = ChargeComparison.xDomain([curve], axis: .time)
        XCTAssertEqual(domain.upperBound, 40, accuracy: 1e-9)
        XCTAssertEqual(ChargeComparison.xTicks(domain, axis: .time).last ?? 0, domain.upperBound, accuracy: 1e-9, "the axis end is labelled")
    }

    func testFarApartPeaksSplitIntoTwoPanels() throws {
        XCTAssertNil(ChargeComparison.panels([(1, 150), (2, 120), (3, 60)]), "within 5×: one scale")
        let split = try XCTUnwrap(ChargeComparison.panels([(1, 150), (2, 11), (3, 7.2), (4, 120)]))
        XCTAssertEqual(Set(split.high), [1, 4])
        XCTAssertEqual(Set(split.low), [2, 3])
        XCTAssertNil(ChargeComparison.panels([(1, 150)]))
        XCTAssertNil(ChargeComparison.panels([(1, 7), (2, 7.4)]))
        XCTAssertEqual(ChargeComparison.panels([(1, 0), (2, 7), (3, 11)])?.low, nil, "a zero peak is no curve, not a scale")
    }

    func testShortNamesAddTheTimeOnlyWhenADayRepeats() {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!
        let day = c.startOfDay(for: t0)
        let names = ChargeComparison.shortNames([(1, day.addingTimeInterval(8 * 3600)), (2, day.addingTimeInterval(18 * 3600)),
                                                 (3, day.addingTimeInterval(-86_400))], calendar: c)
        var dayFormat = Date.FormatStyle.dateTime.month(.abbreviated).day(); dayFormat.timeZone = c.timeZone
        XCTAssertEqual(names[3], day.addingTimeInterval(-86_400).formatted(dayFormat))
        XCTAssertNotEqual(names[1], names[2])
        XCTAssertTrue(names[1]!.hasPrefix(names[3]!.components(separatedBy: " ")[0]))
    }

    func testVerdictNamesTheQuickestInShownMinutes() throws {
        XCTAssertNil(ChargeComparison.verdict([(1, 20.4), (2, 18.2), (3, nil)]),
                     "a session whose record breaks in the window might have been quicker")
        let verdict = try XCTUnwrap(ChargeComparison.verdict([(1, 20.4), (2, 18.2), (4, 31)]))
        XCTAssertEqual(verdict, .init(leader: 2, runnerUp: 1, minutes: 18, margin: 2))
        XCTAssertEqual(ChargeComparison.verdictTail(verdict, window: 45...80, runnerUp: "Nov 5"),
                       " was quickest from 45 to 80%: 18 min, 2 min faster than Nov 5.")
        let tie = try XCTUnwrap(ChargeComparison.verdict([(1, 18.4), (2, 17.6)]))
        XCTAssertEqual(tie.margin, 0)
        XCTAssertEqual(ChargeComparison.verdictTail(tie, window: 45...80, runnerUp: "Nov 5"), " and Nov 5 were equally quick from 45 to 80%: 18 min each.")
        XCTAssertNil(ChargeComparison.verdict([(1, 18), (2, nil)]), "one time is no comparison")
    }

    func testLineLabelsAreNudgedApartInOrder() {
        XCTAssertEqual(ChargeComparison.nudged([50, 52, 200], minGap: 12, within: 0...240), [50, 62, 200])
        XCTAssertEqual(ChargeComparison.nudged([100, 95], minGap: 12, within: 0...240), [107, 95])
        // Crowded at the bottom: the stack moves up instead of leaving the plot.
        XCTAssertEqual(ChargeComparison.nudged([238, 239, 240], minGap: 12, within: 0...240), [216, 228, 240])
        XCTAssertEqual(ChargeComparison.nudged([-5], minGap: 12, within: 0...240), [0])
        XCTAssertEqual(ChargeComparison.nudged([], minGap: 12, within: 0...240), [])
    }

    // MARK: Demo data

    func testDemoSessionsGiveDistinctCurvesAndOneWithout() async throws {
        let source = MockDataSource()
        let charges = try await source.charges(vehicleID: 1, range: .init(), cursor: nil).items
        let fast = charges.filter(\.fastCharger)
        let curves = try await withThrowingTaskGroup(of: ChargeComparison.SessionCurve.self) { group in
            for c in fast { group.addTask { ChargeComparison.curve(try await source.charge(id: c.id)) } }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        XCTAssertEqual(Set(curves.compactMap { $0.peakKw.map { Int($0) } }).count, curves.count, "every fast session peaks differently")
        XCTAssertTrue(curves.allSatisfy(\.hasSoc))
        XCTAssertNotNil(ChargeComparison.commonWindow(curves))
        let none = ChargeComparison.curve(try await source.charge(id: MockDataSource.noCurveChargeID))
        XCTAssertFalse(none.hasPower)
        XCTAssertTrue(charges.contains { ChargeComparison.KindGroup($0) == .away })
    }
}

// MARK: - Loading model

private actor Gate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async { if open { return }; await withCheckedContinuation { waiters.append($0) } }
    func release() { open = true; waiters.forEach { $0.resume() }; waiters = [] }
}

/// Details for ids 1…n: id 2 fails, id 3 has no curve; `gate` holds every reply.
private struct ComparisonSource: VoltaDataSource {
    let gate = Gate()
    let calls = Counter()
    let base = MockDataSource()
    func vehicles() async throws -> [Vehicle] { try await base.vehicles() }
    func status(vehicleID: Int) async throws -> VehicleStatus { try await base.status(vehicleID: vehicleID) }
    func summary(vehicleID: Int, range: SummaryRange) async throws -> ActivitySummary { try await base.summary(vehicleID: vehicleID, range: range) }
    func timeline(vehicleID: Int, hours: Int) async throws -> [TimelineSegment] { [] }
    func drives(vehicleID: Int, range: DateRange, cursor: String?) async throws -> Page<DriveSummary> { Page(items: [], nextCursor: nil) }
    func drive(id: Int) async throws -> DriveDetail { throw VoltaError.notFound }
    func charges(vehicleID: Int, range: DateRange, cursor: String?) async throws -> Page<ChargeSummary> {
        Page(items: (1...8).map(Self.summary), nextCursor: nil)
    }
    func charge(id: Int) async throws -> ChargeDetail {
        await calls.add()
        await gate.wait()
        try Task.checkCancellation()
        if id == 2 { throw VoltaError.server(code: "service_unavailable", message: "Synthetic failure") }
        let s = Self.summary(id)
        let samples = id == 3 ? [] : (0...30).map { m in
            ChargeSample(t: s.start.addingTimeInterval(Double(m) * 60), batteryLevel: 40 + m, powerKw: Double(id) * 10,
                         voltage: nil, currentA: nil, ratedRangeKm: nil)
        }
        return ChargeDetail(summary: s, samples: samples, efficiency: nil)
    }
    func idles(vehicleID: Int, range: DateRange, cursor: String?) async throws -> Page<IdleSummary> { Page(items: [], nextCursor: nil) }
    func battery(vehicleID: Int) async throws -> BatteryHealth { try await base.battery(vehicleID: vehicleID) }
    func mileage(vehicleID: Int, bucket: MileageBucketSize) async throws -> [MileageBucket] { [] }
    func firmware(vehicleID: Int) async throws -> [FirmwareUpdate] { [] }
    func places(vehicleID: Int) async throws -> [Place] { [] }

    static func summary(_ id: Int) -> ChargeSummary {
        let start = Date(timeIntervalSince1970: 1_790_000_000 - Double(id) * 86_400)
        return ChargeSummary(id: id, start: start, end: start.addingTimeInterval(1800), address: nil, placeName: id.isMultiple(of: 2) ? "Garage" : "Home",
                             energyAddedKwh: 10, energyUsedKwh: nil, startBatteryLevel: 40, endBatteryLevel: 70, durationMin: 30,
                             maxPowerKw: nil, fastCharger: false, cost: nil, currency: nil, outsideTempAvgC: nil)
    }
}

private actor Counter {
    private(set) var value = 0
    func add() { value += 1 }
}

@MainActor
final class ChargeComparisonModelTests: XCTestCase {
    func testMoreSessionsThanTheCapLoadOnlyTheFirstFive() async {
        let source = ComparisonSource()
        let model = ChargeComparisonModel()
        model.start(ChargeComparisonRequest(sessions: (1...8).map(ComparisonSource.summary)))
        XCTAssertEqual(model.selection.map(\.id), [1, 2, 3, 4, 5])
        await source.gate.release()
        await model.loadDetails(source: source)
        let calls = await source.calls.value
        XCTAssertEqual(calls, 5)
        XCTAssertNotNil(model.curves[1]?.value)
        if case .failed = model.curves[2] {} else { XCTFail("a failed session says so") }
        XCTAssertEqual(model.curves[3]?.value?.hasPower, false, "a session with no samples has no curve, not a flat one")
        XCTAssertEqual(model.curves[4]?.value?.peakKw, 40)
    }

    func testCancelledOrSupersededLoadsNeverLand() async {
        let source = ComparisonSource()
        let model = ChargeComparisonModel()
        model.start(ChargeComparisonRequest(sessions: [ComparisonSource.summary(1)]))
        let first = Task { await model.loadDetails(source: source) }
        for _ in 0..<20 { await Task.yield() }
        first.cancel()
        await source.gate.release()
        await first.value
        if case .loading = model.curves[1] {} else { XCTFail("a cancelled load must not publish") }
        // The screen comes back: the session loads again.
        await model.loadDetails(source: source)
        XCTAssertNotNil(model.curves[1]?.value)
    }

    func testRemovingASessionDropsItsCurveAndLateResult() async {
        let source = ComparisonSource()
        let model = ChargeComparisonModel()
        model.start(ChargeComparisonRequest(sessions: [ComparisonSource.summary(1), ComparisonSource.summary(4)]))
        let pending = Task { await model.loadDetails(source: source) }
        for _ in 0..<20 { await Task.yield() }
        model.toggle(ComparisonSource.summary(4))
        await source.gate.release()
        await pending.value
        XCTAssertNil(model.curves[4], "a removed session's late reply is ignored")
        XCTAssertNotNil(model.curves[1]?.value)
        XCTAssertEqual(model.slots, [1: 0])
    }

    func testRetryOnlyAsksTheScreenToLoadAgain() async {
        let source = ComparisonSource()
        let model = ChargeComparisonModel()
        model.start(ChargeComparisonRequest(sessions: [ComparisonSource.summary(1), ComparisonSource.summary(2)]))
        await source.gate.release()
        await model.loadDetails(source: source)
        if case .failed = model.curves[2] {} else { XCTFail("session 2 fails") }
        let calls = await source.calls.value
        // Retry starts nothing itself: it changes the key the screen's
        // cancellable task is bound to, and that task does the loading.
        model.retry(2)
        XCTAssertNil(model.curves[2])
        XCTAssertEqual(model.detailAttempt, 1)
        let afterRetry = await source.calls.value
        XCTAssertEqual(afterRetry, calls)
        await model.loadDetails(source: source)
        let afterLoad = await source.calls.value
        XCTAssertEqual(afterLoad, calls + 1, "only the failed session is asked for again")
        XCTAssertNotNil(model.curves[1]?.value)

        model.retryCandidates()
        if case .loading = model.candidates {} else { XCTFail("the picker shows loading again") }
        XCTAssertEqual(model.candidateAttempt, 1)
    }

    func testCompareWithFillsSimilarSessionsUntilTheOwnerPicks() async {
        let source = ComparisonSource()
        let model = ChargeComparisonModel()
        let seed = ComparisonSource.summary(2) // "Garage"
        model.start(.comparing(seed))
        await model.loadCandidates(source: source, vehicleID: 1, now: Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertEqual(model.selection.map(\.id), [2, 4, 6], "the seed and the newest sessions at the same place")
        // Once the owner changes it, a reload leaves the selection alone.
        model.toggle(ComparisonSource.summary(6))
        await model.loadCandidates(source: source, vehicleID: 1, now: Date(timeIntervalSince1970: 1_790_000_000))
        XCTAssertEqual(model.selection.map(\.id), [2, 4])
    }
}
