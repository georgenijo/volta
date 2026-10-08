import MapKit
import XCTest
@testable import Volta

@MainActor
final class TripTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func point(_ seconds: Double, speed: Double? = 50, power: Double? = 10, elevation: Double? = 30,
                       battery: Int? = 60, lat: Double = 37.2) -> DrivePoint {
        DrivePoint(t: t0.addingTimeInterval(seconds), latitude: lat, longitude: -122.1, speedKph: speed,
                   powerKw: power, elevationM: elevation, batteryLevel: battery)
    }

    private func summary(minutes: Double) -> DriveSummary {
        DriveSummary(id: 99, start: t0, end: t0.addingTimeInterval(minutes * 60), startAddress: nil, endAddress: nil,
                     distanceKm: 10, durationMin: minutes, startBatteryLevel: 60, endBatteryLevel: 58,
                     energyUsedKwh: 2, efficiencyWhPerKm: 200, maxSpeedKph: 80, avgSpeedKph: 40, outsideTempAvgC: nil)
    }

    // MARK: Normalization

    func testCollectorRepeatPatternCollapsesToFiveDistinctSamples() {
        let detail = TripFixtures.sparse(summary(minutes: 56))
        XCTAssertEqual(detail.path.count, 1335)
        let timeline = TripTimeline(path: detail.path, start: detail.summary.start, end: detail.summary.end)
        XCTAssertEqual(timeline.rawCount, 1335)
        XCTAssertEqual(timeline.points.count, 5)
        XCTAssertEqual(timeline.conflictingTimestamps, 1)
        XCTAssertEqual(timeline.conflictingRowsDropped, 1)
        XCTAssertEqual(timeline.duplicatesRemoved, 1335 - 5 - 1)
        XCTAssertEqual(Set(timeline.points.map(\.t)).count, 5, "chart ids must be unique")
        // Every sample is ~14 min from its neighbours: all gaps, nothing covered.
        XCTAssertEqual(timeline.segments.count, 5)
        XCTAssertEqual(timeline.gapCount, 4)
        XCTAssertEqual(timeline.coverage, 0)
        XCTAssertEqual(timeline.quality, .sparse)
        XCTAssertEqual(timeline.longestGap, 14 * 60, accuracy: 0.001)
        XCTAssertTrue(timeline.sampledPairs.isEmpty)
    }

    func testConflictResolutionIsIndependentOfInputOrder() {
        let a = point(10, speed: 61), b = point(10, speed: 64), c = point(10, speed: nil)
        let rows = [point(0), a, b, c, point(20)]
        let picks = [rows, rows.reversed(), [rows[3], rows[0], rows[2], rows[4], rows[1]]].map {
            TripTimeline(path: $0).points[1]
        }
        XCTAssertEqual(Set(picks).count, 1)
        // More recorded fields wins over nil; then the lower value tuple.
        XCTAssertEqual(picks[0].speedKph, 61)
        XCTAssertEqual(TripTimeline(path: rows).conflictingTimestamps, 1)
        XCTAssertEqual(TripTimeline(path: rows).conflictingRowsDropped, 2)
    }

    func testUnsortedInputIsSortedAndNullMetricsArePreserved() {
        let rows = [point(6, speed: nil, power: nil), point(0), point(3, elevation: nil)]
        let timeline = TripTimeline(path: rows)
        XCTAssertEqual(timeline.points.map(\.t), [0, 3, 6].map { t0.addingTimeInterval($0) })
        XCTAssertNil(timeline.points[2].speedKph)
        XCTAssertNil(timeline.points[2].powerKw)
        XCTAssertNil(timeline.points[1].elevationM)
    }

    func testGapsSplitSegmentsAndCoverageCountsOnlySampledTime() {
        // 0…300 s every 3 s, a 10-minute hole, then 900…1200 s every 3 s.
        let rows = stride(from: 0.0, through: 300, by: 3).map { point($0) } + stride(from: 900.0, through: 1200, by: 3).map { point($0) }
        let timeline = TripTimeline(path: rows, start: t0, end: t0.addingTimeInterval(1200))
        XCTAssertEqual(timeline.segments.count, 2)
        XCTAssertEqual(timeline.coveredSeconds, 600, accuracy: 0.001)
        XCTAssertEqual(timeline.coverage, 0.5, accuracy: 0.001)
        XCTAssertEqual(timeline.quality, .partial)
        XCTAssertEqual(timeline.gapRanges.count, 1)
        XCTAssertEqual(timeline.gapRanges[0].lowerBound, 5, accuracy: 0.001)
        XCTAssertEqual(timeline.gapRanges[0].upperBound, 15, accuracy: 0.001)
        XCTAssertNil(timeline.sampleIndex(atMinute: 10), "inside the gap there is no sample to highlight")
        XCTAssertNotNil(timeline.sampleIndex(atMinute: 4))
        XCTAssertFalse(timeline.sampledPairs.contains { $1.t.timeIntervalSince($0.t) > TripTimeline.gapThreshold })
    }

    func testEmptyPathIsNone() {
        let timeline = TripTimeline(path: [], start: t0, end: t0.addingTimeInterval(600))
        XCTAssertEqual(timeline.quality, .none)
        XCTAssertEqual(timeline.gapRanges, [0...10])
        XCTAssertEqual(TripAnalysis.regen(timeline), .unavailable("Power not recorded"))
    }

    // MARK: Charts and route

    func testChartSeriesNeverJoinsAcrossGaps() {
        let rows = stride(from: 0.0, through: 60, by: 3).map { point($0) } + [point(600)] + stride(from: 900.0, through: 960, by: 3).map { point($0) }
        let timeline = TripTimeline(path: rows, start: t0, end: t0.addingTimeInterval(960))
        let series = TripChartSeries(timeline) { $0.speedKph }
        XCTAssertEqual(Set(series.points.map(\.segment)), [0, 1, 2])
        XCTAssertEqual(series.points.filter { $0.segment == 1 }.count, 1, "lone sample stays its own series")
        XCTAssertEqual(Set(series.points.map(\.id)).count, series.points.count)
        XCTAssertTrue(series.inGap(5))
        let inGap = TripSelection(minute: 5, timeline: timeline)
        XCTAssertNil(inGap.index)
        XCTAssertNil(series.value(at: inGap))
        XCTAssertEqual(TripChart.tooltipText(nil, selection: inGap, unit: "km/h", digits: 0), "No sample")
    }

    func testRouteHasNoColoredPieceAcrossAGap() {
        let rows = stride(from: 0.0, through: 60, by: 3).map { point($0, lat: 37 + $0 / 10_000) }
            + stride(from: 900.0, through: 960, by: 3).map { point($0, lat: 38 + $0 / 10_000) }
        let timeline = TripTimeline(path: rows)
        let route = TripRoute(timeline, mode: .speed)
        XCTAssertEqual(route.gaps.count, 1)
        for piece in route.pieces {
            let lats = piece.coordinates.map(\.latitude)
            XCTAssertTrue(lats.allSatisfy { $0 < 37.5 } || lats.allSatisfy { $0 > 37.5 }, "piece spans the gap")
        }
        let sparse = TripTimeline(path: TripFixtures.sparse(summary(minutes: 56)).path)
        let sparseRoute = TripRoute(sparse, mode: .efficiency)
        XCTAssertTrue(sparseRoute.pieces.isEmpty)
        XCTAssertEqual(sparseRoute.isolated.count, 5)
        XCTAssertEqual(sparseRoute.gaps.count, 4)
    }

    func testAxisStrideAndLabels() {
        XCTAssertEqual(TripChartSeries.axisStride(12), 5)
        XCTAssertEqual(TripChartSeries.axisStride(49), 10)
        XCTAssertEqual(TripChartSeries.axisStride(150), 30)
        XCTAssertEqual(TripChartSeries.axisStride(400), 60)
        XCTAssertEqual(TripChart.minuteLabel(33.4), "33m")
        XCTAssertEqual(TripChart.minuteLabel(180), "3h")
    }

    func testPaletteIsContinuousAndClamped() {
        let lo = TripPalette.rgb(-1, stops: TripPalette.speed), hi = TripPalette.rgb(2, stops: TripPalette.speed)
        XCTAssertEqual(lo, TripPalette.speed.first)
        XCTAssertEqual(hi, TripPalette.speed.last)
        let mid = TripPalette.rgb(1.0 / 6, stops: TripPalette.speed)
        XCTAssertGreaterThan(mid.r, TripPalette.speed[0].r)
        XCTAssertLessThan(mid.r, TripPalette.speed[1].r)
    }

    // MARK: Derived metrics

    func testRegenIsWithheldOnSparseSamplesInsteadOfIntegratingGaps() {
        let sparse = TripFixtures.sparse(summary(minutes: 56))
        let timeline = TripTimeline(path: sparse.path, start: sparse.summary.start, end: sparse.summary.end)
        guard case .unavailable = TripAnalysis.regen(timeline) else { return XCTFail("regen must not be integrated across 14-minute gaps") }
        // The old estimator would have reported ~1.9 kWh from one −8 kW sample.
        XCTAssertGreaterThan(RegenEstimate(sparse.path)?.kwh ?? 0, 1)
    }

    func testRegenIsAnEstimateWithCoverageNeverABound() {
        let full = stride(from: 0.0, through: 3600, by: 60).map { point($0, power: -10) }
        let whole = TripAnalysis.regen(TripTimeline(path: full, start: t0, end: t0.addingTimeInterval(3600)))
        XCTAssertEqual(whole.number ?? 0, 10, accuracy: 0.001)
        XCTAssertTrue(whole.isComplete)
        var partial = full
        for i in 0..<6 { partial[i].powerKw = nil }
        guard case .estimate(let kwh, let coverage) = TripAnalysis.regen(TripTimeline(path: partial, start: t0, end: t0.addingTimeInterval(3600))) else {
            return XCTFail("expected a partial estimate")
        }
        XCTAssertEqual(kwh, 9, accuracy: 0.001)
        XCTAssertEqual(coverage, 0.9, accuracy: 1e-9)
    }

    func testMaxSpeedIsALowerBoundUnlessDense() {
        let sparse = TripTimeline(path: TripFixtures.sparse(summary(minutes: 56)).path)
        XCTAssertEqual(TripAnalysis.maxSpeed(summary: 64, timeline: sparse), .atLeast(64))
        let dense = TripTimeline(path: stride(from: 0.0, through: 600, by: 3).map { point($0, speed: 70) })
        XCTAssertEqual(TripAnalysis.maxSpeed(summary: 72, timeline: dense), .value(72))
        XCTAssertEqual(TripAnalysis.maxSpeed(summary: nil, timeline: TripTimeline(path: [point(0, speed: nil)])), .unavailable("Not recorded"))
    }

    func testDescentOnlyFromDenseSamples() {
        let dense = TripTimeline(path: stride(from: 0.0, through: 300, by: 3).map { point($0, elevation: 100 - $0 / 10) })
        XCTAssertEqual(TripAnalysis.descent(dense).number ?? 0, 30, accuracy: 2)
        guard case .unavailable = TripAnalysis.descent(TripTimeline(path: TripFixtures.sparse(summary(minutes: 56)).path)) else {
            return XCTFail("sparse samples must not produce a descent")
        }
    }

    // MARK: Smoothness

    func testSmoothnessUnavailableWhenSparse() {
        let sparse = TripFixtures.sparse(summary(minutes: 56))
        let result = SmoothnessScore.evaluate(TripTimeline(path: sparse.path, start: sparse.summary.start, end: sparse.summary.end))
        guard case .unavailable(let reason) = result else { return XCTFail("score must not be shown for sparse samples") }
        XCTAssertTrue(reason.contains("0%"))
    }

    func testSmoothnessUsesTheDocumentedThresholds() {
        // ~10 minutes at 3 s: cruise, one 3.5 m/s² slowdown (hard), gentle 1 m/s² recovery.
        let drop = 3.5 * 3.6 * 3, rise = 1.0 * 3.6 * 3      // km/h per 3 s interval at 3.5 and 1.0 m/s²
        var speeds: [Double] = Array(repeating: 100, count: 100)
        speeds += [100 - drop, 100 - 2 * drop]                // two hard braking intervals = one event
        speeds += Array(repeating: 100 - 2 * drop, count: 40)
        speeds += (1...10).map { 100 - 2 * drop + Double($0) * rise }
        speeds += Array(repeating: speeds.last!, count: 40)
        let rows = speeds.enumerated().map { point(Double($0.offset) * 3, speed: $0.element, power: nil) }
        let timeline = TripTimeline(path: rows, start: t0, end: rows.last!.t)
        guard case .score(let s) = SmoothnessScore.evaluate(timeline) else { return XCTFail("dense trip should score") }
        XCTAssertEqual(s.hardEvents, 1)
        XCTAssertEqual(s.maxG, 3.5 / 9.80665, accuracy: 0.01)
        XCTAssertEqual(s.parts.map(\.name), ["Acceleration", "Braking"], "no power part without power samples")
        XCTAssertEqual(s.parts[0].score, 100, accuracy: 0.001)
        XCTAssertEqual(s.parts[1].score, 0, accuracy: 0.001)
        XCTAssertEqual(s.score, 50)
        XCTAssertEqual(s.label, "Lively")
    }

    func testDenseFixtureScoresAndIsDense() throws {
        let detail = TripFixtures.dense(summary(minutes: 49))
        let timeline = TripTimeline(path: detail.path, start: detail.summary.start, end: detail.summary.end)
        XCTAssertEqual(timeline.quality, .dense)
        XCTAssertEqual(timeline.points.count, detail.path.count)
        guard case .score(let s) = SmoothnessScore.evaluate(timeline) else { return XCTFail("dense fixture should score") }
        XCTAssertGreaterThanOrEqual(s.hardEvents, 1)
        XCTAssertEqual(s.parts.count, 3)
        XCTAssertNotNil(TripAnalysis.regen(timeline).number)
        let summary = detail.summary
        XCTAssertEqual(summary.distanceKm, 33, accuracy: 4)
        XCTAssertEqual(summary.maxSpeedKph ?? 0, 112, accuracy: 4)
        XCTAssertEqual(summary.startBatteryLevel, 64)
    }

    // MARK: Cost

    private func charge(_ id: Int, hoursBefore: Double, cost: Double?, energy: Double?, currency: String? = "USD") -> ChargeSummary {
        ChargeSummary(id: id, start: t0.addingTimeInterval(-hoursBefore * 3600), end: nil, address: nil, placeName: "Home",
                      energyAddedKwh: energy, energyUsedKwh: nil, startBatteryLevel: nil, endBatteryLevel: nil,
                      durationMin: 60, maxPowerKw: nil, fastCharger: false, cost: cost, currency: currency, outsideTempAvgC: nil)
    }

    private func rate(_ charges: [ChargeSummary]) -> TripRateLookup {
        TripRate.latestPriced(charges, before: t0).map(TripRate.lookup(from:)) ?? .noPricedCharge
    }

    func testRateComesFromTheLatestPricedChargeBeforeTheTrip() throws {
        let charges = [
            charge(1, hoursBefore: 2, cost: nil, energy: 20),       // unpriced: skipped
            charge(2, hoursBefore: 5, cost: 7, energy: 0),          // no energy to divide by: skipped
            charge(3, hoursBefore: 30, cost: 5, energy: 25, currency: "EUR"),
            charge(4, hoursBefore: 60, cost: 9, energy: 20),
            charge(5, hoursBefore: -1, cost: 4, energy: 10),        // after the trip
        ]
        let rate = try XCTUnwrap(rate(charges).rate)
        XCTAssertEqual(rate.perKwh, 0.2, accuracy: 1e-9)
        XCTAssertEqual(rate.currency, "EUR")
        XCTAssertEqual(rate.cost(energyKwh: 4.3) ?? 0, 0.86, accuracy: 1e-9)
        XCTAssertNil(rate.cost(energyKwh: nil), "unknown energy means unknown cost")
        XCTAssertEqual(self.rate([charge(1, hoursBefore: 2, cost: nil, energy: 20)]), .noPricedCharge)
    }

    func testManualRateRoundTripAndScoping() {
        let rate = TripRate(perKwh: 0.31, currency: "USD", source: .manual)
        XCTAssertEqual(TripRate(stored: rate.stored), rate)
        XCTAssertNil(TripRate(stored: "abc|USD"))
        XCTAssertNil(TripRate(stored: "-1|USD"))
        XCTAssertNil(TripRate(stored: "nan|USD"))
        XCTAssertNil(TripRate(stored: "inf|USD"))
        XCTAssertNil(TripRate(stored: "0.2|U5D"))
        XCTAssertNil(TripRate(stored: "0.2|DOLLARS"))
        XCTAssertNil(TripRate.storageKey(serverURL: "https://a.example", isDemo: false, isLaunchDemo: true, vehicleID: 1))
        let a = TripRate.storageKey(serverURL: "https://a.example", isDemo: false, isLaunchDemo: false, vehicleID: 1)
        let b = TripRate.storageKey(serverURL: "https://b.example", isDemo: false, isLaunchDemo: false, vehicleID: 1)
        let c = TripRate.storageKey(serverURL: "https://a.example", isDemo: false, isLaunchDemo: false, vehicleID: 2)
        XCTAssertEqual(Set([a, b, c].compactMap { $0 }).count, 3)
    }

    // MARK: Loading

    func testStaleDetailRequestDoesNotPublish() async {
        let loader = HistoryDetailLoader<Int>()
        let gate = AsyncStream<Void>.makeStream()
        let started = AsyncStream<Void>.makeStream()
        let first = Task { @MainActor in
            await loader.load {
                started.continuation.yield()
                for await _ in gate.stream { break }
                return 1
            }
        }
        for await _ in started.stream { break }
        loader.reset()
        await loader.load { 2 }
        XCTAssertEqual(loader.detail, 2)
        gate.continuation.yield()
        await first.value
        XCTAssertEqual(loader.detail, 2, "the superseded request must not overwrite the newer result")
    }

    func testResetClearsDetailAndError() async {
        let loader = HistoryDetailLoader<Int>()
        await loader.load { throw VoltaError.notFound }
        XCTAssertNotNil(loader.error)
        loader.reset()
        XCTAssertNil(loader.error)
        XCTAssertNil(loader.detail)
    }

    // MARK: Fixtures through the demo source

    func testDemoSourceServesBothFixtureTrips() async throws {
        let source = MockDataSource()
        let dense = try await source.drive(id: TripFixtures.denseDriveID)
        let sparse = try await source.drive(id: TripFixtures.sparseDriveID)
        XCTAssertGreaterThan(dense.path.count, 900)
        XCTAssertEqual(sparse.path.count, TripFixtures.sparseRawCount)
        let list = try await source.drives(vehicleID: MockDataSource.vehicleID, range: .init(), cursor: nil).items
        XCTAssertEqual(list.first { $0.id == TripFixtures.sparseDriveID }?.durationMin, 56)
        XCTAssertEqual(list.first { $0.id == TripFixtures.denseDriveID }?.distanceKm, dense.summary.distanceKm)
    }

    func testSamplingCopyDisclosesCountsAndConflicts() {
        let t = TripTimeline(path: TripFixtures.sparse(summary(minutes: 56)).path, start: t0, end: t0.addingTimeInterval(56 * 60))
        XCTAssertTrue(TripSamplingNote.title(t).contains("5 distinct samples"))
        let detail = TripSamplingNote.detail(t)
        XCTAssertTrue(detail.contains("1,335"))
        XCTAssertTrue(detail.contains("conflicting"))
        XCTAssertTrue(detail.contains("not the driven path"))
    }

    func testPlaceSplitting() {
        XCTAssertEqual(TripPlace("Union City, CA"), TripPlace(primary: "Union City", secondary: "CA"))
        XCTAssertEqual(TripPlace(nil).primary, "Unknown place")
        XCTAssertNil(TripPlace("Home").secondary)
    }

    // MARK: R1 regressions

    /// R1-1: an hour of positions every 3 s with speed only in the first 6
    /// minutes must not earn a whole-trip score.
    func testSmoothnessCoverageCountsOnlyIntervalsWithRecordedSpeed() {
        let rows = stride(from: 0.0, through: 3600, by: 3).map { t in
            point(t, speed: t <= 360 ? 50 + sin(t / 30) : nil, power: nil)
        }
        let timeline = TripTimeline(path: rows, start: t0, end: t0.addingTimeInterval(3600))
        XCTAssertEqual(timeline.quality, .dense, "GPS is dense; speed is not")
        guard case .unavailable(let reason) = SmoothnessScore.evaluate(timeline) else {
            return XCTFail("54 minutes without speed must not be scored")
        }
        XCTAssertTrue(reason.contains("10%"), reason)

        // NaN speeds are missing, not observed.
        let nan = stride(from: 0.0, through: 3600, by: 3).map { t in point(t, speed: t <= 360 ? 50 : .nan, power: nil) }
        guard case .unavailable = SmoothnessScore.evaluate(TripTimeline(path: nan, start: t0, end: t0.addingTimeInterval(3600))) else {
            return XCTFail("NaN speeds must not count as coverage")
        }

        // A recorded standstill is observed (coverage) but not moving (eligible).
        let parked = stride(from: 0.0, through: 3600, by: 3).map { point($0, speed: 0, power: nil) }
        guard case .unavailable(let still) = SmoothnessScore.evaluate(TripTimeline(path: parked, start: t0, end: t0.addingTimeInterval(3600))) else {
            return XCTFail("no moving intervals, no score")
        }
        XCTAssertTrue(still.contains("moving"), still)

        // Positive control: the same hour with speed everywhere scores.
        let full = stride(from: 0.0, through: 3600, by: 3).map { point($0, speed: 50 + sin($0 / 30), power: nil) }
        guard case .score = SmoothnessScore.evaluate(TripTimeline(path: full, start: t0, end: t0.addingTimeInterval(3600))) else {
            return XCTFail("fully recorded speed should score")
        }
    }

    /// R1-2: dense GPS with elevation only at minutes 0 and 60 charts two
    /// isolated points with the hour between them shaded as a gap.
    func testChartSegmentsFollowEachSignalNotGPS() {
        let rows = stride(from: 0.0, through: 3600, by: 3).map { t in
            point(t, elevation: t == 0 ? 100 : t == 3600 ? 20 : nil)
        }
        let timeline = TripTimeline(path: rows, start: t0, end: t0.addingTimeInterval(3600))
        XCTAssertEqual(timeline.segments.count, 1)
        let elevation = TripChartSeries(timeline) { $0.elevationM }
        XCTAssertEqual(elevation.points.count, 2)
        XCTAssertEqual(Set(elevation.points.map(\.segment)).count, 2, "the two elevations must not be one line")
        XCTAssertEqual(elevation.gaps.count, 1)
        XCTAssertEqual(elevation.gaps[0].lowerBound, 0, accuracy: 1e-9)
        XCTAssertEqual(elevation.gaps[0].upperBound, 60, accuracy: 1e-9)
        XCTAssertTrue(elevation.inGap(30))
        XCTAssertFalse(elevation.signal.isDense)
        XCTAssertNotNil(TripChartSeries.coverageNote(elevation, title: "Elevation"))
        // Scrubbing mid-hour finds a GPS sample, but its elevation is unknown.
        let mid = TripSelection(minute: 30, timeline: timeline)
        XCTAssertNotNil(mid.index)
        XCTAssertNil(elevation.value(at: mid))
        XCTAssertEqual(TripChart.tooltipText(nil, selection: mid, unit: "m", digits: 0), "Not recorded")
        // Speed in the same timeline is dense and stays one line with no gaps.
        let speed = TripChartSeries(timeline) { $0.speedKph }
        XCTAssertEqual(Set(speed.points.map(\.segment)), [0])
        XCTAssertTrue(speed.gaps.isEmpty)
        XCTAssertNil(TripChartSeries.coverageNote(speed, title: "Speed"))
    }

    /// R2-1: a missing (nil or NaN) observation ends the signal's segment even
    /// when the valid values around it are only seconds apart.
    func testExplicitMissingObservationsSplitTheSignal() {
        let rows = stride(from: 0.0, through: 600, by: 3).map { t in point(t, power: (300...309).contains(t) ? .nan : 10) }
        let timeline = TripTimeline(path: rows, start: t0, end: t0.addingTimeInterval(600))
        let signal = TripSignal(timeline) { $0.powerKw }
        XCTAssertEqual(signal.segments.count, 2, "four missing readings are a gap, not skipped")
        XCTAssertEqual(signal.observationCount, rows.count - 4)
        XCTAssertNil(signal.values[100])
        XCTAssertEqual(signal.coveredSeconds, 600 - 15, accuracy: 1e-9, "the 297→312 s span is not covered")
        XCTAssertEqual(signal.gapRanges.count, 1)
        XCTAssertEqual(signal.gapRanges[0].lowerBound, 297.0 / 60, accuracy: 1e-9)
        XCTAssertEqual(signal.gapRanges[0].upperBound, 312.0 / 60, accuracy: 1e-9)
        XCTAssertFalse(signal.intervals.contains { $0 == (98, 104) }, "no interval may bridge the missing readings")
        XCTAssertTrue(signal.intervals.allSatisfy { $1 == $0 + 1 })
    }

    /// R2-1 reproduction: one hour of GPS every 3 s, elevation and speed valid
    /// only every 120 s. 31 of 1,201 observations are 31 lone samples.
    func testEvery120sSignalOnDenseGPSIsNotCovered() throws {
        let rows = stride(from: 0.0, through: 3600, by: 3).map { t -> DrivePoint in
            let on = t.truncatingRemainder(dividingBy: 120) == 0
            return point(t, speed: on ? 60 + t / 120 : nil, elevation: on ? 100 - t / 60 : nil)
        }
        let timeline = TripTimeline(path: rows, start: t0, end: t0.addingTimeInterval(3600))
        XCTAssertEqual(timeline.points.count, 1201)
        XCTAssertEqual(timeline.quality, .dense, "GPS is dense; the signals are not")
        for value in [{ (p: DrivePoint) in p.speedKph }, { (p: DrivePoint) in p.elevationM }] {
            let signal = TripSignal(timeline, value: value)
            XCTAssertEqual(signal.observationCount, 31)
            XCTAssertEqual(signal.segments.count, 31)
            XCTAssertTrue(signal.intervals.isEmpty)
            XCTAssertEqual(signal.coverage, 0)
            XCTAssertFalse(signal.isDense)
            XCTAssertEqual(signal.gapRanges.count, 30)
        }
        // Charts: 31 isolated points, never one filled curve; caption states 0%.
        let elevation = TripChartSeries(timeline) { $0.elevationM }
        XCTAssertEqual(elevation.points.count, 31)
        XCTAssertEqual(Set(elevation.points.map(\.segment)).count, 31)
        let note = try XCTUnwrap(TripChartSeries.coverageNote(elevation, title: "Elevation"))
        XCTAssertTrue(note.contains("0% of the trip") && note.contains("31 samples") && note.contains("30 gaps"), note)
        // Scrub: a recorded reading shows; the sample 3 s later shows "Not recorded".
        let speed = TripChartSeries(timeline) { $0.speedKph }
        XCTAssertEqual(speed.value(at: TripSelection(minute: 2, timeline: timeline)), 61)
        let between = TripSelection(minute: 2.05, timeline: timeline)
        XCTAssertNotNil(between.index)
        XCTAssertNil(speed.value(at: between))
        XCTAssertTrue(speed.inGap(2.05))
        // Derived metrics: no exact descent or max, no score, no tinted route.
        guard case .unavailable(let reason) = TripAnalysis.descent(timeline) else { return XCTFail("60 m must not be asserted") }
        XCTAssertTrue(reason.contains("0%"), reason)
        XCTAssertEqual(TripAnalysis.maxSpeed(summary: nil, timeline: timeline), .atLeast(90))
        guard case .unavailable = SmoothnessScore.evaluate(timeline) else { return XCTFail("no consecutive speeds") }
        for mode in [TripMapMode.speed, .elevation] {
            XCTAssertTrue(TripRoute(timeline, mode: mode).pieces.allSatisfy { $0.fraction == nil }, "\(mode)")
        }
        // Control: the same trip with every observation recorded.
        let full = stride(from: 0.0, through: 3600, by: 3).map { t in point(t, speed: 60, elevation: 100 - t / 60) }
        let fullTimeline = TripTimeline(path: full, start: t0, end: t0.addingTimeInterval(3600))
        XCTAssertEqual(TripAnalysis.descent(fullTimeline).number ?? 0, 60, accuracy: 2.01)
        guard case .value = TripAnalysis.descent(fullTimeline) else { return XCTFail("fully recorded descent is a value") }
        XCTAssertEqual(TripAnalysis.maxSpeed(summary: nil, timeline: fullTimeline), .value(60))
        XCTAssertTrue(TripRoute(fullTimeline, mode: .speed).pieces.allSatisfy { $0.fraction != nil })
    }

    func testAlternatingMissingObservationsCoverNothing() {
        let rows = stride(from: 0.0, through: 600, by: 3).enumerated().map { n, t in point(t, elevation: n % 2 == 0 ? 30 - Double(n) : nil) }
        let timeline = TripTimeline(path: rows, start: t0, end: t0.addingTimeInterval(600))
        let signal = TripSignal(timeline) { $0.elevationM }
        XCTAssertEqual(signal.observationCount, 101)
        XCTAssertEqual(signal.segments.count, 101)
        XCTAssertEqual(signal.coverage, 0)
        guard case .unavailable = TripAnalysis.descent(timeline) else { return XCTFail("every other reading is not a descent") }
    }

    func testSingleMissingObservationAndLeadTailMissing() {
        // One missing reading in a dense hour: two segments, a 6 s gap, still dense.
        let one = stride(from: 0.0, through: 3600, by: 3).map { t in point(t, elevation: t == 1800 ? nil : 3600 - t) }
        let timeline = TripTimeline(path: one, start: t0, end: t0.addingTimeInterval(3600))
        let signal = TripSignal(timeline) { $0.elevationM }
        XCTAssertEqual(signal.segments.count, 2)
        XCTAssertEqual(signal.coveredSeconds, 3594, accuracy: 1e-9)
        XCTAssertTrue(signal.isDense)
        XCTAssertEqual(signal.gapRanges.count, 1)
        // The 6 m drop across the missing reading is not counted.
        XCTAssertEqual(TripAnalysis.descent(timeline).number ?? 0, 3594, accuracy: 1e-6)

        // Lead-in and tail without the signal are gaps even though GPS is there.
        let edges = stride(from: 0.0, through: 600, by: 3).map { t in point(t, speed: t < 30 || t > 570 ? nil : 50) }
        let edged = TripTimeline(path: edges, start: t0, end: t0.addingTimeInterval(600))
        let speed = TripSignal(edged) { $0.speedKph }
        XCTAssertEqual(speed.segments.count, 1)
        XCTAssertEqual(speed.gapRanges.count, 2)
        XCTAssertEqual(speed.gapRanges[0].lowerBound, 0)
        XCTAssertEqual(speed.gapRanges[0].upperBound, 0.5, accuracy: 1e-9)
        XCTAssertEqual(speed.gapRanges[1].lowerBound, 9.5, accuracy: 1e-9)
        XCTAssertEqual(speed.gapRanges[1].upperBound, 10, accuracy: 1e-9)
        XCTAssertEqual(speed.coveredSeconds, 540, accuracy: 1e-9)
        XCTAssertEqual(speed.coverage, 0.9, accuracy: 1e-9)

        // Fully recorded control: one segment, no gaps, no caption.
        let full = TripChartSeries(edged) { $0.batteryLevel.map(Double.init) }
        XCTAssertEqual(full.signal.segments.count, 1)
        XCTAssertTrue(full.gaps.isEmpty)
        XCTAssertEqual(full.signal.coverage, 1)
        XCTAssertNil(TripChartSeries.coverageNote(full, title: "Battery"))
    }

    /// R2-2: a single power reading is not a regen measurement.
    func testRegenNeedsPowerAtBothEndsOfAnInterval() {
        let end = t0.addingTimeInterval(120)
        let single = TripTimeline(path: [point(0, power: -10), point(120, power: nil)], start: t0, end: end)
        XCTAssertEqual(TripAnalysis.regen(single), .unavailable("Only one power sample"))
        XCTAssertEqual(TripSignal(single) { $0.powerKw }.coverage, 0)
        // Control: both ends known gives a (sample-derived) value.
        let both = TripTimeline(path: [point(0, power: -10), point(120, power: -10)], start: t0, end: end)
        XCTAssertEqual(TripAnalysis.regen(both).number ?? 0, 10.0 * 120 / 3600, accuracy: 1e-9)
        // Trapezoid: −10 kW falling linearly to 0 over 60 s.
        let ramp = TripTimeline(path: [point(0, power: -10), point(60, power: 0)], start: t0, end: t0.addingTimeInterval(60))
        XCTAssertEqual(TripAnalysis.regen(ramp).number ?? 0, 5.0 * 60 / 3600, accuracy: 1e-9)
        // Power every 120 s on 3 s GPS: no interval has two readings.
        let sparse = stride(from: 0.0, through: 3600, by: 3).map { t in point(t, power: t.truncatingRemainder(dividingBy: 120) == 0 ? -10 : nil) }
        guard case .unavailable(let reason) = TripAnalysis.regen(TripTimeline(path: sparse, start: t0, end: t0.addingTimeInterval(3600))) else {
            return XCTFail("31 isolated readings must not integrate")
        }
        XCTAssertTrue(reason.contains("0%"), reason)
        // Known zero (no regen) stays a real 0.
        let coasting = stride(from: 0.0, through: 600, by: 3).map { point($0, power: 0) }
        XCTAssertEqual(TripAnalysis.regen(TripTimeline(path: coasting, start: t0, end: t0.addingTimeInterval(600))), .estimate(0, coverage: 1))
    }

    /// R3-1: power is assumed linear between two readings, so only the part
    /// of the line below zero is regen. Clipping the endpoints first and then
    /// averaging overstated −60 → +60 kW over 60 s as 0.5 kWh.
    func testRegenIntegratesOnlyTheNegativePartAcrossAZeroCrossing() {
        XCTAssertEqual(TripAnalysis.regenKwh(from: -60, to: 60, seconds: 60), 0.25, accuracy: 1e-12)
        XCTAssertEqual(TripAnalysis.regenKwh(from: 60, to: -60, seconds: 60), 0.25, accuracy: 1e-12)
        // Asymmetric crossing: zero at 15 s, triangle 30 kW × 15 s / 2.
        XCTAssertEqual(TripAnalysis.regenKwh(from: -30, to: 90, seconds: 60), 225.0 / 3600, accuracy: 1e-12)
        // Both negative: trapezoid. Both non-negative: nothing. Zero endpoints.
        XCTAssertEqual(TripAnalysis.regenKwh(from: -20, to: -40, seconds: 60), 0.5, accuracy: 1e-12)
        XCTAssertEqual(TripAnalysis.regenKwh(from: 20, to: 40, seconds: 60), 0)
        XCTAssertEqual(TripAnalysis.regenKwh(from: 0, to: -60, seconds: 60), 0.5, accuracy: 1e-12)
        XCTAssertEqual(TripAnalysis.regenKwh(from: 0, to: 60, seconds: 60), 0)
        XCTAssertEqual(TripAnalysis.regenKwh(from: 0, to: 0, seconds: 60), 0)
        XCTAssertEqual(TripAnalysis.regenKwh(from: -60, to: 60, seconds: 0), 0)
        XCTAssertEqual(TripAnalysis.regenKwh(from: .nan, to: -60, seconds: 60), 0)

        // Whole trip −60 → +60 over 60 s.
        let crossing = TripTimeline(path: [point(0, power: -60), point(60, power: 60)], start: t0, end: t0.addingTimeInterval(60))
        XCTAssertEqual(TripAnalysis.regen(crossing), .estimate(0.25, coverage: 1))
        // Reviewer's case: a missing reading at 75 s makes it 80% coverage. A
        // partial estimate of ≈0.25, never "≥ 0.5".
        let partial = TripTimeline(path: [point(0, power: -60), point(60, power: 60), point(75, power: nil)],
                                   start: t0, end: t0.addingTimeInterval(75))
        let regen = TripAnalysis.regen(partial)
        guard case .estimate(let kwh, let coverage) = regen else { return XCTFail("80% coverage is estimated") }
        XCTAssertEqual(kwh, 0.25, accuracy: 1e-12)
        XCTAssertEqual(coverage, 0.8, accuracy: 1e-12)
        XCTAssertFalse(regen.isComplete)
        let hero = TripStatsRow.regenText(regen)
        XCTAssertTrue(hero.hasPrefix("≈") && hero.hasSuffix(" · 80%"), hero)
        XCTAssertEqual(TripStatsRow.regenDetail(regen), "≈ 0.25 kWh (partial estimate · power sampled for 80% of the trip)")
        let wholeHero = TripStatsRow.regenText(TripAnalysis.regen(crossing))
        XCTAssertTrue(wholeHero.hasPrefix("≈") && !wholeHero.contains("·"), wholeHero)
        XCTAssertEqual(TripStatsRow.regenDetail(TripAnalysis.regen(crossing)), "≈ 0.25 kWh (estimated from samples)")
        // No label anywhere claims a bound.
        for estimate in [regen, TripAnalysis.regen(crossing)] {
            XCTAssertFalse(TripStatsRow.regenText(estimate).contains("≥"))
            XCTAssertFalse(TripStatsRow.regenDetail(estimate).contains("≥"))
        }
        // Below 80% stays withheld; one reading stays unavailable; known zero stays zero.
        let short = TripTimeline(path: [point(0, power: -60), point(60, power: 60), point(90, power: nil)],
                                 start: t0, end: t0.addingTimeInterval(90))
        XCTAssertEqual(TripAnalysis.regen(short), .unavailable("Power sampled for 67% of the trip"))
        XCTAssertEqual(TripStatsRow.regenText(TripAnalysis.regen(short)), "—")
        XCTAssertEqual(TripStatsRow.regenDetail(.unavailable("Only one power sample")), "— · Only one power sample")
    }

    func testPartialPowerFixtureIsAPartialEstimate() {
        let detail = TripFixtures.partialPower(summary(minutes: 49))
        let timeline = TripTimeline(path: detail.path, start: detail.summary.start, end: detail.summary.end)
        let regen = TripAnalysis.regen(timeline)
        guard case .estimate(let kwh, let coverage) = regen else { return XCTFail("85% power coverage is estimated") }
        XCTAssertEqual(coverage, 0.85, accuracy: 0.01)
        XCTAssertGreaterThan(kwh, 0)
        XCTAssertFalse(regen.isComplete)
        let dense = TripFixtures.dense(summary(minutes: 49))
        XCTAssertTrue(TripAnalysis.regen(TripTimeline(path: dense.path, start: dense.summary.start, end: dense.summary.end)).isComplete)
    }

    // MARK: Route color support (R3-2)

    /// One hour of GPS every 3 s with each signal on only the first two of
    /// every eight samples: one interval in eight is supported.
    private func alternatingRows(hours: Double = 1, onEvery block: Int = 8, on count: Int = 2) -> [DrivePoint] {
        stride(from: 0.0, through: 3600 * hours, by: 3).enumerated().map { n, t in
            let on = n % block < count
            return point(t, speed: on ? 60 + Double(n % 40) : nil, power: on ? 12 : nil,
                         elevation: on ? 30 + Double(n % 50) : nil, lat: 37 + t / 100_000)
        }
    }

    /// Every piece starts where the previous one ended (or at a gap), draws
    /// exactly its own samples' positions at both ends, and is colored only
    /// when every interval inside it is supported.
    private func assertRouteGeometry(_ route: TripRoute, _ timeline: TripTimeline, _ mode: TripMapMode,
                                     file: StaticString = #filePath, line: UInt = #line) {
        let points = timeline.points
        var next: Int?
        var segment = 0
        for piece in route.pieces {
            while !timeline.segments[segment].contains(piece.indices.lowerBound) { segment += 1; next = nil }
            let seg = timeline.segments[segment]
            XCTAssertTrue(seg.contains(piece.indices.upperBound), "piece crosses a GPS gap", file: file, line: line)
            XCTAssertEqual(piece.indices.lowerBound, next ?? seg.lowerBound, "pieces are contiguous", file: file, line: line)
            next = piece.indices.upperBound
            XCTAssertEqual(piece.coordinates.first?.latitude, points[piece.indices.lowerBound].latitude, file: file, line: line)
            XCTAssertEqual(piece.coordinates.last?.latitude, points[piece.indices.upperBound].latitude, file: file, line: line)
            XCTAssertEqual(piece.mapPoints.count, piece.coordinates.count, file: file, line: line)
            let supported = (piece.indices.lowerBound..<piece.indices.upperBound).map { TripRoute.supports(mode, points[$0], points[$0 + 1]) }
            if piece.fraction != nil {
                XCTAssertTrue(supported.allSatisfy { $0 }, "colored piece contains an unsupported interval", file: file, line: line)
            } else {
                XCTAssertTrue(supported.allSatisfy { $0 } || supported.allSatisfy { !$0 }, "pieces are homogeneous", file: file, line: line)
            }
        }
    }

    func testRouteColorsOnlySupportedIntervals() {
        let timeline = TripTimeline(path: alternatingRows(), start: t0, end: t0.addingTimeInterval(3600))
        XCTAssertEqual(timeline.quality, .dense)
        for mode in TripMapMode.allCases {
            let route = TripRoute(timeline, mode: mode)
            XCTAssertEqual(route.coloredSeconds(timeline) / timeline.spanSeconds, 0.125, accuracy: 1e-9, "\(mode)")
            let colored = route.pieces.filter { $0.fraction != nil }
            XCTAssertEqual(colored.count, 150, "\(mode)")
            // Each colored piece is exactly the supported 3 s between the two readings of a block.
            for piece in colored {
                XCTAssertEqual(piece.indices.lowerBound % 8, 0, "\(mode)")
                XCTAssertEqual(piece.indices.count, 2, "\(mode)")
            }
            assertRouteGeometry(route, timeline, mode)
            // The neutral pieces cover the rest of the drive; nothing is dropped.
            let drawn = route.pieces.reduce(0.0) { $0 + timeline.points[$1.indices.upperBound].t.timeIntervalSince(timeline.points[$1.indices.lowerBound].t) }
            XCTAssertEqual(drawn, 3600, accuracy: 1e-9)
        }
    }

    func testRouteColorEdgeCases() {
        // Fully recorded: every piece colored, still within the drawing budget.
        let dense = TripTimeline(path: stride(from: 0.0, through: 3600, by: 3).map { point($0, lat: 37 + $0 / 100_000) })
        for mode in TripMapMode.allCases {
            let route = TripRoute(dense, mode: mode)
            XCTAssertTrue(route.pieces.allSatisfy { $0.fraction != nil }, "\(mode)")
            XCTAssertLessThanOrEqual(route.pieces.count, 160)
            assertRouteGeometry(route, dense, mode)
        }
        // A single valid reading never colors anything.
        let single = TripTimeline(path: stride(from: 0.0, through: 600, by: 3).map { point($0, speed: $0 == 300 ? 50 : nil, lat: 37 + $0 / 100_000) })
        XCTAssertTrue(TripRoute(single, mode: .speed).pieces.allSatisfy { $0.fraction == nil })
        // A non-finite reading splits the color around it.
        let nan = TripTimeline(path: stride(from: 0.0, through: 600, by: 3).map { point($0, elevation: $0 == 300 ? .nan : 30, lat: 37 + $0 / 100_000) })
        let nanRoute = TripRoute(nan, mode: .elevation)
        assertRouteGeometry(nanRoute, nan, .elevation)
        XCTAssertEqual(nanRoute.coloredSeconds(nan), 594, accuracy: 1e-9)
        // Efficiency needs speed and power at both ends and a moving car.
        let parked = TripTimeline(path: stride(from: 0.0, through: 600, by: 3).map { point($0, speed: 0, power: 1, lat: 37 + $0 / 100_000) })
        XCTAssertTrue(TripRoute(parked, mode: .efficiency).pieces.allSatisfy { $0.fraction == nil })
        let noPower = TripTimeline(path: stride(from: 0.0, through: 600, by: 3).enumerated().map { n, t in
            point(t, power: n % 2 == 0 ? 10 : nil, lat: 37 + t / 100_000)
        })
        XCTAssertTrue(TripRoute(noPower, mode: .efficiency).pieces.allSatisfy { $0.fraction == nil })
        XCTAssertTrue(TripRoute(noPower, mode: .speed).pieces.allSatisfy { $0.fraction != nil }, "speed itself is dense")
        // GPS gaps stay gaps in every mode, colored or not.
        let gapped = TripTimeline(path: alternatingRows(hours: 0.1) + stride(from: 900.0, through: 1200, by: 3).map { point($0, lat: 38 + $0 / 100_000) })
        for mode in TripMapMode.allCases {
            let route = TripRoute(gapped, mode: mode)
            XCTAssertEqual(route.gaps.count, 1)
            assertRouteGeometry(route, gapped, mode)
        }
    }

    func testHugeFragmentedRouteStaysBoundedAndProjectsConsistently() {
        // Ten hours at 3 s with signals on two of every four samples.
        let rows = alternatingRows(hours: 10, onEvery: 4, on: 2)
        let timeline = TripTimeline(path: rows, start: t0, end: t0.addingTimeInterval(36_000))
        let started = Date()
        let routes = TripMapMode.allCases.map { TripRoute(timeline, mode: $0) }
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        for (mode, route) in zip(TripMapMode.allCases, routes) {
            XCTAssertEqual(route.coloredSeconds(timeline) / timeline.spanSeconds, 0.25, accuracy: 1e-9, "\(mode)")
            XCTAssertLessThanOrEqual(route.pieces.count, timeline.points.count - 1)
            assertRouteGeometry(route, timeline, mode)
        }
        // Panning and zooming only move the projection: every piece's precomputed
        // map points land where its coordinates do, in every mode and camera.
        let rect = try! XCTUnwrap(TripRoute.framingRect(timeline.points))
        let size = CGSize(width: 390, height: 500)
        let cameras = [rect, rect.offsetBy(dx: rect.width / 3, dy: -rect.height / 4), rect.insetBy(dx: rect.width / 3, dy: rect.height / 3)]
        for route in routes {
            for camera in cameras {
                for piece in route.pieces.prefix(200) {
                    for (m, c) in zip(piece.mapPoints, piece.coordinates) {
                        let a = try! XCTUnwrap(TripRoute.project(m, visible: camera, size: size))
                        let b = try! XCTUnwrap(TripRoute.project(c, visible: camera, size: size))
                        XCTAssertEqual(a.x, b.x, accuracy: 1e-6)
                        XCTAssertEqual(a.y, b.y, accuracy: 1e-6)
                    }
                }
            }
        }
        // Selection still resolves against the full timeline.
        XCTAssertEqual(TripSelection(minute: 1.575, timeline: timeline).index, 31)
    }

    func testAlternatingFixtureColorsOnlyAnEighthOfTheRoute() {
        let detail = TripFixtures.alternating(summary(minutes: 49))
        let timeline = TripTimeline(path: detail.path, start: detail.summary.start, end: detail.summary.end)
        XCTAssertEqual(timeline.quality, .dense)
        for mode in TripMapMode.allCases {
            let route = TripRoute(timeline, mode: mode)
            let share = route.coloredSeconds(timeline) / timeline.spanSeconds
            XCTAssertLessThanOrEqual(share, 0.126, "\(mode)")
            XCTAssertGreaterThan(share, mode == .efficiency ? 0.05 : 0.12, "\(mode)")
            assertRouteGeometry(route, timeline, mode)
        }
        guard case .unavailable = TripAnalysis.regen(timeline) else { return XCTFail("12.5% power coverage") }
    }

    func testIntermittentFixtureWithholdsEverySignalDerivedNumber() {
        let detail = TripFixtures.intermittent(summary(minutes: 49))
        let timeline = TripTimeline(path: detail.path, start: detail.summary.start, end: detail.summary.end)
        XCTAssertEqual(timeline.quality, .dense)
        XCTAssertEqual(TripAnalysis.regen(timeline), .unavailable("Only one power sample"))
        guard case .unavailable = TripAnalysis.descent(timeline) else { return XCTFail("isolated elevations") }
        guard case .atLeast = TripAnalysis.maxSpeed(summary: detail.summary.maxSpeedKph, timeline: timeline) else { return XCTFail("isolated speeds") }
        guard case .unavailable = SmoothnessScore.evaluate(timeline) else { return XCTFail("isolated speeds") }
        let speed = TripChartSeries(timeline) { $0.speedKph }
        XCTAssertEqual(speed.signal.observationCount, Set(speed.points.map(\.segment)).count, "every speed is its own segment")
        XCTAssertGreaterThan(speed.signal.observationCount, 20)
        XCTAssertTrue(TripChartSeries(timeline) { $0.batteryLevel.map(Double.init) }.signal.isDense)
        XCTAssertTrue(TripRoute(timeline, mode: .efficiency).pieces.allSatisfy { $0.fraction == nil })
    }

    /// R1-3: descent needs elevation coverage, not GPS coverage.
    func testDescentRequiresElevationCoverage() {
        let twoPoints = stride(from: 0.0, through: 3600, by: 3).map { t in point(t, elevation: t == 0 ? 100 : t == 3600 ? 20 : nil) }
        let timeline = TripTimeline(path: twoPoints, start: t0, end: t0.addingTimeInterval(3600))
        guard case .unavailable(let reason) = TripAnalysis.descent(timeline) else { return XCTFail("80 m must not be inferred across an hour") }
        XCTAssertTrue(reason.contains("0%"), reason)

        let one = stride(from: 0.0, through: 3600, by: 3).map { t in point(t, elevation: t == 0 ? 100 : nil) }
        XCTAssertEqual(TripAnalysis.descent(TripTimeline(path: one)), .unavailable("Only one elevation sample"), "one sample is unknown, not 0")
        XCTAssertEqual(TripAnalysis.descent(TripTimeline(path: [point(0, elevation: nil), point(3, elevation: nil)])), .unavailable("Elevation not recorded"))

        let flat = stride(from: 0.0, through: 600, by: 3).map { point($0, elevation: 30) }
        XCTAssertEqual(TripAnalysis.descent(TripTimeline(path: flat)), .value(0), "known flat terrain is a real 0")

        // Anchor resets at an elevation gap: the drop across it isn't counted.
        let split = stride(from: 0.0, through: 3600, by: 3).map { t -> DrivePoint in
            point(t, elevation: t < 1700 ? 100 : t > 1900 ? 50 : nil)
        }
        let partial = TripAnalysis.descent(TripTimeline(path: split, start: t0, end: t0.addingTimeInterval(3600)))
        guard case .atLeast(let lower) = partial else { return XCTFail("≥ 90% coverage with a gap is a lower bound, got \(partial)") }
        XCTAssertEqual(lower, 0, accuracy: 1e-9)
    }

    func testMaxSpeedBoundFollowsSpeedCoverageNotGPS() {
        let rows = stride(from: 0.0, through: 3600, by: 3).map { t in point(t, speed: t <= 360 ? 60 : nil) }
        let timeline = TripTimeline(path: rows, start: t0, end: t0.addingTimeInterval(3600))
        XCTAssertEqual(timeline.quality, .dense)
        XCTAssertEqual(TripAnalysis.maxSpeed(summary: nil, timeline: timeline), .atLeast(60))
    }

    /// R1-4: a ten-hour 3 s trip reduces to a few hundred plotted points, but
    /// selection reads the full timeline; map and every chart agree.
    func testSelectionUsesTheFullTimelineNotPlottedPoints() {
        let rows = stride(from: 0.0, through: 36_000, by: 3).map { point($0, speed: 80, elevation: 30 + $0 / 1000) }
        let timeline = TripTimeline(path: rows, start: t0, end: t0.addingTimeInterval(36_000))
        let speed = TripChartSeries(timeline) { $0.speedKph }
        let elevation = TripChartSeries(timeline) { $0.elevationM }
        XCTAssertLessThan(speed.points.count, 1000, "plotting is reduced")
        let selection = TripSelection(minute: 1.575, timeline: timeline)
        XCTAssertEqual(selection.index, 31)
        XCTAssertEqual(timeline.sampleIndex(atMinute: 1.575), 31, "the map highlights the same sample")
        XCTAssertEqual(speed.value(at: selection), 80)
        XCTAssertEqual(elevation.value(at: selection) ?? 0, 30 + 93.0 / 1000, accuracy: 1e-9)
        XCTAssertEqual(selection.sampleMinute ?? 0, 1.55, accuracy: 1e-9)
        // Map modes don't change which sample is selected.
        for mode in TripMapMode.allCases { _ = TripRoute(timeline, mode: mode) }
        XCTAssertEqual(TripSelection(minute: 1.575, timeline: timeline), selection)
    }

    func testSelectionDoesNotJumpAcrossALongGap() {
        let rows = stride(from: 0.0, through: 300, by: 3).map { point($0) } + stride(from: 1500.0, through: 1800, by: 3).map { point($0) }
        let timeline = TripTimeline(path: rows, start: t0, end: t0.addingTimeInterval(1800))
        XCTAssertNil(TripSelection(minute: 10, timeline: timeline).index)
        XCTAssertEqual(TripSelection(minute: 5.5, timeline: timeline).index, 100, "within a minute of the edge sample")
        XCTAssertNil(TripSelection(minute: 6.5, timeline: timeline).index)
    }

    /// R1-5: a charge without a recorded currency gives no automatic rate.
    func testUnknownChargeCurrencyIsNotFilledFromPreferences() {
        XCTAssertEqual(rate([charge(1, hoursBefore: 2, cost: 10, energy: 20, currency: nil)]), .currencyUnknown(date: t0.addingTimeInterval(-7200)))
        XCTAssertEqual(rate([charge(1, hoursBefore: 2, cost: 10, energy: 20, currency: "dollars")]), .currencyUnknown(date: t0.addingTimeInterval(-7200)))
        // The latest priced charge is the reference: no fallback to an older one with a currency.
        let fallback = rate([charge(1, hoursBefore: 2, cost: 10, energy: 20, currency: nil), charge(2, hoursBefore: 9, cost: 4, energy: 20)])
        XCTAssertNil(fallback.rate)
        XCTAssertEqual(rate([charge(1, hoursBefore: 2, cost: 10, energy: 20, currency: "eur")]).rate?.currency, "EUR")
        XCTAssertTrue(TripCostCard.unknownReason(energyKwh: 2, rate: nil, lookup: fallback).contains("no recorded currency"))
    }

    /// R1-6: free charging is a known price of 0.
    func testZeroCostIsAKnownFreeRate() throws {
        let latestFree = rate([charge(1, hoursBefore: 2, cost: 0, energy: 20), charge(2, hoursBefore: 9, cost: 6, energy: 20)])
        let free = try XCTUnwrap(latestFree.rate, "a free charge must not fall back to an older paid charge")
        XCTAssertEqual(free.perKwh, 0)
        XCTAssertEqual(free.cost(energyKwh: 4.3), 0)
        XCTAssertEqual(TripRate(stored: "0|usd"), TripRate(perKwh: 0, currency: "USD", source: .manual))
        XCTAssertEqual(TripRate(stored: "0.0|EUR")?.perKwh, 0)
        XCTAssertEqual(TripRate(stored: "-0|EUR")?.stored, "0.0|EUR")
        XCTAssertEqual(TripRate(stored: TripRate(perKwh: 0, currency: "GBP", source: .manual).stored)?.perKwh, 0, "persisted zero round-trips")
    }

    /// R1-7: paging continues past an unpriced first page; incomplete lookups
    /// never claim that no priced charge exists.
    func testRateLookupPagesPastUnpricedCharges() async {
        let unpriced = (1...50).map { charge($0, hoursBefore: Double($0), cost: nil, energy: 20) }
        let priced = charge(51, hoursBefore: 51, cost: 6, energy: 20)
        let source = PagedCharges(pages: [unpriced, [priced]])
        let found = await TripRate.lookup(before: t0) { try await source.page($0) }
        XCTAssertEqual(found.rate?.perKwh ?? 0, 0.3, accuracy: 1e-9)
        let fetches = await source.fetches
        XCTAssertEqual(fetches, 2)

        let exhausted = await TripRate.lookup(before: t0) { try await PagedCharges(pages: [unpriced]).page($0) }
        XCTAssertEqual(exhausted, .noPricedCharge, "only a fully checked history may say none")

        let capped = await TripRate.lookup(before: t0, maxPages: 1) { try await PagedCharges(pages: [unpriced, [priced]]).page($0) }
        guard case .incomplete(let reason) = capped else { return XCTFail("page cap must be incomplete, got \(capped)") }
        XCTAssertTrue(reason.contains("50"))
        XCTAssertFalse(TripCostCard.unknownReason(energyKwh: 2, rate: nil, lookup: capped).contains("No charge before"))

        let failing = await TripRate.lookup(before: t0) { try await PagedCharges(pages: [unpriced, [priced]], failAt: 1).page($0) }
        guard case .incomplete = failing else { return XCTFail("an error after page 1 must be incomplete, got \(failing)") }

        let looping = await TripRate.lookup(before: t0) { _ in Page(items: unpriced, nextCursor: "same") }
        guard case .incomplete = looping else { return XCTFail("a repeated cursor must stop, got \(looping)") }
    }

    func testOlderSameKeyRateLookupCannotOverwriteANewerOne() async {
        let loader = TripRateLoader()
        let gate = AsyncStream<Void>.makeStream()
        let started = AsyncStream<Void>.makeStream()
        let older = charge(1, hoursBefore: 2, cost: 2, energy: 20)
        let newer = charge(2, hoursBefore: 3, cost: 6, energy: 20)
        let t0 = self.t0
        let first = Task { @MainActor in
            await loader.load(before: t0) { _ in
                started.continuation.yield()
                for await _ in gate.stream { break }
                return Page(items: [older], nextCursor: nil)
            }
        }
        for await _ in started.stream { break }
        // A reload of the same drive starts while the first is in flight.
        await loader.load(before: t0) { _ in Page(items: [newer], nextCursor: nil) }
        XCTAssertEqual(loader.result?.rate?.perKwh ?? 0, 0.3, accuracy: 1e-9)
        gate.continuation.yield()
        await first.value
        XCTAssertEqual(loader.result?.rate?.perKwh ?? 0, 0.3, accuracy: 1e-9, "the older reload must not publish")

        // Cancelled lookups never publish; reset clears.
        loader.reset()
        XCTAssertNil(loader.result)
        let cancelled = Task { @MainActor in
            await loader.load(before: t0) { _ in Page(items: [older], nextCursor: nil) }
        }
        cancelled.cancel()
        await cancelled.value
        XCTAssertNil(loader.result)
    }

    /// The simulator fixture used to show per-signal gaps natively.
    func testSignalGapFixtureShowsGapsOnlyInThoseSignals() {
        let detail = TripFixtures.signalGaps(summary(minutes: 49))
        let timeline = TripTimeline(path: detail.path, start: detail.summary.start, end: detail.summary.end)
        XCTAssertEqual(timeline.quality, .dense)
        let speed = TripChartSeries(timeline) { $0.speedKph }
        let elevation = TripChartSeries(timeline) { $0.elevationM }
        let power = TripChartSeries(timeline) { $0.powerKw }
        XCTAssertEqual(Set(speed.points.map(\.segment)).count, 2)
        XCTAssertEqual(speed.gaps.count, 1)
        XCTAssertEqual(elevation.signal.observationCount, 2)
        XCTAssertEqual(Set(elevation.points.map(\.segment)).count, 2)
        XCTAssertTrue(power.signal.isDense)
        XCTAssertNil(TripChartSeries.coverageNote(power, title: "Power"))
        guard case .unavailable = SmoothnessScore.evaluate(timeline) else { return XCTFail("speed covers ~20%") }
        guard case .unavailable = TripAnalysis.descent(timeline) else { return XCTFail("two elevations are not a descent") }
        XCTAssertNil(elevation.value(at: TripSelection(minute: 24, timeline: timeline)))
    }

    func testRouteThinningKeepsEndsAndFramingCoversEverySample() {
        let coords = (0..<100).map { CLLocationCoordinate2D(latitude: 37 + Double($0) / 1000, longitude: -122) }
        let thin = TripRoute.thin(coords, to: 16)
        XCTAssertEqual(thin.count, 16)
        XCTAssertEqual(thin.first?.latitude, coords.first?.latitude)
        XCTAssertEqual(thin.last?.latitude, coords.last?.latitude)
        let detail = TripFixtures.dense(summary(minutes: 49))
        let route = TripRoute(TripTimeline(path: detail.path), mode: .speed)
        XCTAssertLessThanOrEqual(route.pieces.reduce(0) { $0 + $1.coordinates.count }, 160 * 16)

        // Every sample is inside the framed rect and projects inside the view.
        let rect = try! XCTUnwrap(TripRoute.framingRect(detail.path))
        let size = CGSize(width: 400, height: 400)
        for p in detail.path {
            XCTAssertTrue(rect.contains(MKMapPoint(p.coordinate)))
            let q = try! XCTUnwrap(TripRoute.project(p.coordinate, visible: rect, size: size))
            XCTAssertTrue((0...400).contains(q.x) && (0...400).contains(q.y))
        }
        // The rect's corners and centre land on the view's corners and centre.
        let centre = MKMapPoint(x: rect.midX, y: rect.midY).coordinate
        let c = try! XCTUnwrap(TripRoute.project(centre, visible: rect, size: size))
        XCTAssertEqual(c.x, 200, accuracy: 0.01)
        XCTAssertEqual(c.y, 200, accuracy: 0.01)
        let topLeft = try! XCTUnwrap(TripRoute.project(rect.origin.coordinate, visible: rect, size: size))
        XCTAssertEqual(topLeft.x, 0, accuracy: 0.01)
        XCTAssertEqual(topLeft.y, 0, accuracy: 0.01)
        XCTAssertNil(TripRoute.project(centre, visible: MKMapRect(x: 0, y: 0, width: 0, height: 10), size: size))
    }
}

/// Newest-first pages of charges, like the API.
private actor PagedCharges {
    let pages: [[ChargeSummary]]
    let failAt: Int?
    private(set) var fetches = 0

    init(pages: [[ChargeSummary]], failAt: Int? = nil) {
        self.pages = pages
        self.failAt = failAt
    }

    func page(_ cursor: String?) throws -> Page<ChargeSummary> {
        fetches += 1
        let index = cursor.flatMap(Int.init) ?? 0
        if index == failAt { throw VoltaError.notFound }
        return Page(items: pages[index], nextCursor: index + 1 < pages.count ? String(index + 1) : nil)
    }
}

extension TripPlace {
    init(primary: String, secondary: String?) {
        self.init(nil)
        self.primary = primary
        self.secondary = secondary
    }
}
