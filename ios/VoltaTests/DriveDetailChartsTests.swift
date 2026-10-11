import XCTest
@testable import Volta

@MainActor
final class DriveDetailChartsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }
    private func values(_ points: [DriveCharts.Point]) -> [Double] { points.map(\.v) }
    private func times(_ points: [DriveCharts.Point]) -> [Double] { points.map { $0.t.timeIntervalSince(t0) } }

    private func summary(minutes: Double = 30, km: Double = 16, energy: Double? = 2.5) -> DriveSummary {
        DriveSummary(id: 7, start: t0, end: at(minutes * 60), startAddress: nil, endAddress: nil,
                     distanceKm: km, durationMin: minutes - 2, startBatteryLevel: 62, endBatteryLevel: 59,
                     energyUsedKwh: energy, efficiencyWhPerKm: 160, maxSpeedKph: 90, avgSpeedKph: 40, outsideTempAvgC: nil)
    }

    // MARK: Step series

    func testStepSeriesForwardFillsAndRunsStartToEnd() {
        let points = DriveChartSeries.stepSeries([(at(0), 60), (at(60), nil), (at(120), 60), (at(180), 59), (at(240), nil)],
                                                 start: t0, end: at(300))
        // Seeded at start, a point only where the value changes, held to the end.
        XCTAssertEqual(times(points), [0, 180, 300])
        XCTAssertEqual(values(points), [60, 59, 59])
    }

    func testStepSeriesSeedsFromLatestValueAtOrBeforeStart() {
        let before = DriveChartSeries.stepSeries([(at(-120), 10), (at(-30), 11), (at(60), 12)], start: t0, end: at(120))
        XCTAssertEqual(values(before), [11, 12, 12])
        XCTAssertEqual(times(before), [0, 60, 120])
        // Nothing before the start: the first value is carried back to it, never a gap.
        let after = DriveChartSeries.stepSeries([(at(90), 5), (at(30), 4)], start: t0, end: at(120))
        XCTAssertEqual(times(after), [0, 90, 120])
        XCTAssertEqual(values(after), [4, 5, 5])
    }

    func testStepSeriesHasNoGapsAndIgnoresJunk() {
        let samples: [(t: Date, v: Double?)] = [(at(10), 1), (at(20), .nan), (at(30), .infinity), (at(400), 9),
                                                (at(50), 2), (at(50), 3)]
        let points = DriveChartSeries.stepSeries(samples, start: t0, end: at(300))
        // Same timestamp: last in input order wins. After-end samples are dropped.
        XCTAssertEqual(values(points), [1, 3, 3])
        XCTAssertEqual(points.first?.t, t0)
        XCTAssertEqual(points.last?.t, at(300))
        XCTAssertTrue(points.allSatisfy { $0.v.isFinite })
        XCTAssertEqual(points.map(\.t), points.map(\.t).sorted())
    }

    func testStepSeriesEmptyWithoutValues() {
        XCTAssertTrue(DriveChartSeries.stepSeries([], start: t0, end: at(60)).isEmpty)
        XCTAssertTrue(DriveChartSeries.stepSeries([(at(0), nil), (at(10), .nan)], start: t0, end: at(60)).isEmpty)
    }

    func testValueLookupIsStepwise() {
        let points = [DriveCharts.Point(t: t0, v: 1), .init(t: at(60), v: 2), .init(t: at(120), v: 2)]
        XCTAssertEqual(DriveChartSeries.value(points, at: at(-5)), 1)
        XCTAssertEqual(DriveChartSeries.value(points, at: at(59)), 1)
        XCTAssertEqual(DriveChartSeries.value(points, at: at(60)), 2)
        XCTAssertEqual(DriveChartSeries.value(points, at: at(500)), 2)
        XCTAssertNil(DriveChartSeries.value([], at: t0))
    }

    // MARK: Build

    func testBuildPrefersServerSeriesAndFallsBackPerMetricOmittingEmpty() {
        let path = [DrivePoint(t: at(0), latitude: 37.4, longitude: -122.1, speedKph: 10, powerKw: nil, elevationM: 20, batteryLevel: 62),
                    DrivePoint(t: at(600), latitude: 37.4, longitude: -122.1, speedKph: 40, powerKw: nil, elevationM: 25, batteryLevel: 61)]
        let server = DriveCharts(start: t0, end: at(1800), series: [
            "speedKph": [.init(t: at(0), v: 50), .init(t: at(900), v: 70)],
            "batteryLevel": [],
        ])
        let detail = DriveDetail(summary: summary(), path: path, elevationGainM: nil, charts: server)
        let built = DriveChartSeries.build(detail)
        XCTAssertEqual(values(built.series["speedKph"] ?? []), [50, 70, 70], "server wins")
        XCTAssertEqual(built.series["speedKph"]?.last?.t, at(1800))
        XCTAssertEqual(values(built.series["batteryLevel"] ?? []), [62, 61, 61], "empty server series falls back to the path")
        XCTAssertEqual(values(built.series["elevationM"] ?? []), [20, 25, 25])
        XCTAssertNil(built.series["powerKw"], "no data anywhere: omitted")
        XCTAssertNil(built.series["insideTempC"])
    }

    func testBuildWithoutServerChartsUsesSummaryWindow() {
        let path = [DrivePoint(t: at(30), latitude: 37.4, longitude: -122.1, speedKph: 20, powerKw: 5, elevationM: nil, batteryLevel: nil)]
        let built = DriveChartSeries.build(DriveDetail(summary: summary(minutes: 10), path: path, elevationGainM: nil))
        XCTAssertEqual(built.start, t0)
        XCTAssertEqual(built.end, at(600))
        XCTAssertEqual(times(built.series["speedKph"] ?? []), [0, 600])
        XCTAssertEqual(Set(built.series.keys), ["speedKph", "powerKw"])
    }

    // MARK: Range efficiency

    func testRangeEfficiencyIdealAndPercent() throws {
        let range = [DriveCharts.Point(t: t0, v: 300), .init(t: at(900), v: 290), .init(t: at(1800), v: 280)]
        let speed = [DriveCharts.Point(t: t0, v: 40), .init(t: at(1800), v: 40)]
        let result = try XCTUnwrap(DriveRangeEfficiency.compute(range: range, speed: speed, distanceKm: 16,
                                                                start: t0, end: at(1800), step: 300))
        // 16 km driven for 20 km of rated range.
        XCTAssertEqual(try XCTUnwrap(result.percent), 80, accuracy: 1e-9)
        XCTAssertEqual(result.points.first?.idealKm, 300)
        XCTAssertEqual(try XCTUnwrap(result.points.last?.idealKm), 284, accuracy: 1e-9)
        // Constant speed: half the time, half the distance.
        let mid = try XCTUnwrap(result.points.first { $0.t == at(900) })
        XCTAssertEqual(mid.idealKm, 292, accuracy: 1e-9)
        XCTAssertEqual(mid.actualKm, 290)
    }

    func testRangeEfficiencyDistanceFollowsSpeedShape() throws {
        // Parked for the first half: no distance until the car moves.
        let range = [DriveCharts.Point(t: t0, v: 100), .init(t: at(1200), v: 90)]
        let speed = [DriveCharts.Point(t: t0, v: 0), .init(t: at(600), v: 60), .init(t: at(1200), v: 60)]
        let result = try XCTUnwrap(DriveRangeEfficiency.compute(range: range, speed: speed, distanceKm: 10,
                                                                start: t0, end: at(1200), step: 300))
        XCTAssertEqual(try XCTUnwrap(result.points.first { $0.t == at(600) }).idealKm, 100, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(result.points.last).idealKm, 90, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(result.percent), 100, accuracy: 1e-9)
    }

    func testRangeEfficiencyNilWithoutRangeAndNoPercentWithoutDrop() throws {
        XCTAssertNil(DriveRangeEfficiency.compute(range: [], speed: [], distanceKm: 5, start: t0, end: at(60)))
        let flat = try XCTUnwrap(DriveRangeEfficiency.compute(range: [.init(t: t0, v: 50), .init(t: at(60), v: 50)],
                                                              speed: [], distanceKm: 1, start: t0, end: at(60)))
        XCTAssertNil(flat.percent)
    }

    // MARK: Trip cost

    private func rate(_ value: Double, _ currency: String = "USD", _ source: TripRate.Source = .chargeAverage) -> TripRate {
        TripRate(perKwh: value, currency: currency, source: source)
    }

    private func estimate(server: TripRate? = nil, previous: TripRate? = nil, home: Double? = nil, dc: Double? = nil,
                          energy: Double? = 2, km: Double = 16.09344, currency: String = "USD") -> TripCostEstimate? {
        TripCostEstimate.make(energyKwh: energy, distanceKm: km, server: server, previousCharge: previous,
                              homeRate: home, dcFastRate: dc, settingsCurrency: currency)
    }

    func testRateChainPrecedence() throws {
        let previous = rate(0.25, "USD", .previousCharge(place: nil, date: t0))
        let all = try XCTUnwrap(estimate(server: rate(0.40), previous: previous, home: 0.15, dc: 0.50))
        XCTAssertEqual(all.source, .server); XCTAssertEqual(all.ratePerKwh, 0.40)
        let noServer = try XCTUnwrap(estimate(previous: previous, home: 0.15, dc: 0.50))
        XCTAssertEqual(noServer.source, .previousCharge); XCTAssertEqual(noServer.ratePerKwh, 0.25)
        let home = try XCTUnwrap(estimate(home: 0.15, dc: 0.50))
        XCTAssertEqual(home.source, .home); XCTAssertEqual(home.ratePerKwh, 0.15)
        let dc = try XCTUnwrap(estimate(dc: 0.50))
        XCTAssertEqual(dc.source, .dcFast); XCTAssertEqual(dc.ratePerKwh, 0.50)
        let fallback = try XCTUnwrap(estimate())
        XCTAssertEqual(fallback.source, .estimated)
        XCTAssertEqual(fallback.ratePerKwh, TripCostEstimate.defaultRatePerKwh)
        XCTAssertEqual(fallback.ratePerKwh, 0.30)
    }

    func testRateChainSkipsUnusableRatesButKeepsFree() throws {
        let skipped = try XCTUnwrap(estimate(server: rate(.nan), previous: rate(-1), home: .infinity, dc: 0.45))
        XCTAssertEqual(skipped.source, .dcFast)
        // A free previous charge is a real rate, not missing.
        let free = try XCTUnwrap(estimate(previous: rate(0), home: 0.2))
        XCTAssertEqual(free.source, .previousCharge)
        XCTAssertEqual(free.electric, 0)
    }

    func testRateChainCurrencies() throws {
        let euro = try XCTUnwrap(estimate(server: rate(0.35, "EUR")))
        XCTAssertEqual(euro.currency, "EUR")
        XCTAssertNil(euro.fuel, "fuel defaults are USD; no cross-currency comparison")
        XCTAssertNil(euro.savings); XCTAssertNil(euro.percentVsFuel)
        let settings = try XCTUnwrap(estimate(home: 0.2, currency: "GBP"))
        XCTAssertEqual(settings.currency, "GBP")
        XCTAssertEqual(try XCTUnwrap(estimate(currency: "CAD")).currency, "CAD")
    }

    func testCostNilOnlyWithoutUsableEnergy() {
        XCTAssertNil(estimate(energy: nil))
        XCTAssertNil(estimate(energy: -1))
        XCTAssertNil(estimate(energy: .nan))
        XCTAssertNotNil(estimate(energy: 0))
    }

    func testSavingsAndPercentMath() throws {
        // 10 mi at 25 mpg and $4.50 = $1.80 fuel; 2 kWh × $0.30 = $0.60 electric.
        let e = try XCTUnwrap(estimate())
        XCTAssertEqual(e.electric, 0.60, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(e.fuel), 1.80, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(e.savings), 1.20, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(e.percentVsFuel), -66.666_666, accuracy: 1e-4)
        XCTAssertEqual(TripCostCard.percentText(-66.67), "−67% vs fuel")
        XCTAssertEqual(TripCostCard.percentText(12.4), "+12% vs fuel")
        XCTAssertEqual(TripCostCard.rateText(e), "$0.300/kWh")
        // Pricier than fuel: negative savings, positive percent.
        let dear = try XCTUnwrap(estimate(server: rate(1.20)))
        XCTAssertEqual(try XCTUnwrap(dear.savings), -0.60, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(dear.percentVsFuel), 33.333_333, accuracy: 1e-4)
        // No distance: zero fuel, so no percentage.
        let parked = try XCTUnwrap(estimate(km: 0))
        XCTAssertEqual(parked.fuel, 0)
        XCTAssertNil(parked.percentVsFuel)
    }

    func testFuelComparison() {
        XCTAssertEqual(FuelComparison.default.cost(distanceKm: 16.576_243_2) ?? 0, 1.854, accuracy: 1e-3, "10.3 mi")
        XCTAssertNil(FuelComparison(milesPerGallon: 0, pricePerGallon: 4, currency: "USD").cost(distanceKm: 10))
        XCTAssertNil(FuelComparison.default.cost(distanceKm: -1))
        XCTAssertNil(FuelComparison.default.cost(distanceKm: .nan))
    }

    // MARK: Stats

    func testStatsUseFullDurationAndHonestRegen() throws {
        let s = summary(minutes: 30, km: 15)
        XCTAssertEqual(TripStatsRow.durationMinutes(s), 30, "start to end, not the reported driving minutes")
        XCTAssertEqual(try XCTUnwrap(TripStatsRow.avgSpeedKph(s)), 30, accuracy: 1e-9)
        var open = s; open.end = nil
        XCTAssertEqual(TripStatsRow.durationMinutes(open), 28)
        var zero = s; zero.end = nil; zero.durationMin = 0
        XCTAssertNil(TripStatsRow.avgSpeedKph(zero))

        XCTAssertEqual(TripStatsRow.regenKwh(server: 1.5, estimate: .estimate(0.9, coverage: 1)), 1.5)
        XCTAssertEqual(TripStatsRow.regenKwh(server: nil, estimate: .estimate(0.9, coverage: 1)), 0.9)
        XCTAssertNil(TripStatsRow.regenKwh(server: nil, estimate: .estimate(0.9, coverage: 0.5)), "partial estimate is hidden")
        XCTAssertNil(TripStatsRow.regenKwh(server: .nan, estimate: .unavailable("no power")))
        XCTAssertNil(TripStatsRow.regenKwh(server: nil, estimate: nil))
    }

    // MARK: Decoding

    private func detailJSON(_ extra: [String: Any]) throws -> DriveDetail {
        var detail = try XCTUnwrap(JSONSerialization.jsonObject(with: DecodingTests.fixture("driveDetail")) as? [String: Any])
        for (key, value) in extra { detail[key] = value }
        return try APIDataSource.makeDecoder().decode(DriveDetail.self, from: JSONSerialization.data(withJSONObject: detail))
    }

    func testDecodesChartsRegenAndElevationLoss() throws {
        let parsed = try detailJSON([
            "regenKwh": 1.5, "elevationLossM": 208,
            "charts": ["start": "2026-07-01T10:00:00.000Z", "end": "2026-07-01T10:30:00.000Z",
                       "series": ["batteryLevel": [["t": "2026-07-01T10:00:00.000Z", "v": 62],
                                                   ["t": "2026-07-01T10:30:00.000Z", "v": 59]]]],
        ])
        XCTAssertEqual(parsed.summary.regenKwh, 1.5)
        XCTAssertEqual(parsed.elevationLossM, 208)
        let charts = try XCTUnwrap(parsed.charts)
        XCTAssertEqual(charts.end.timeIntervalSince(charts.start), 1800)
        XCTAssertEqual(charts.series["batteryLevel"]?.map(\.v), [62, 59])
    }

    func testMissingOrMalformedChartFieldsDecodeToNil() throws {
        let absent = try detailJSON([:])
        XCTAssertNil(absent.charts); XCTAssertNil(absent.elevationLossM); XCTAssertNil(absent.summary.regenKwh)
        let nulls = try detailJSON(["charts": NSNull(), "regenKwh": NSNull(), "elevationLossM": NSNull()])
        XCTAssertNil(nulls.charts); XCTAssertNil(nulls.summary.regenKwh)
        // A bad charts block never fails the whole drive.
        let bad = try detailJSON(["charts": ["start": "nope", "series": 3], "elevationLossM": "x"])
        XCTAssertNil(bad.charts)
        XCTAssertNil(bad.elevationLossM)
        XCTAssertEqual(bad.summary.id, 10)
    }

    // MARK: Demo

    func testDemoShowcaseHasEverySection() async throws {
        let detail = try await MockDataSource().drive(id: TripFixtures.denseDriveID)
        let charts = try XCTUnwrap(detail.charts)
        XCTAssertEqual(Set(charts.series.keys), Set(DriveChartMetric.allCases.map(\.rawValue)))
        for (key, points) in charts.series {
            XCTAssertEqual(points.first?.t, charts.start, key)
            XCTAssertEqual(points.last?.t, charts.end, key)
        }
        XCTAssertNotNil(detail.summary.regenKwh)
        XCTAssertNotNil(detail.elevationGainM)
        XCTAssertNotNil(detail.elevationLossM)
        let minutes = TripStatsRow.durationMinutes(detail.summary)
        XCTAssertEqual(minutes, 31.7, accuracy: 0.1)
        let miles = detail.summary.distanceKm / 1.609344
        XCTAssertTrue((9...12).contains(miles), "~10 mi demo drive, got \(miles)")
        let snapshot = TripSnapshot(detail, units: UnitPreferences())
        XCTAssertNotNil(snapshot.rangeEfficiency?.percent)
    }
}
