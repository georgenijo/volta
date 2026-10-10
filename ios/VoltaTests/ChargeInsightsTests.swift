import XCTest
@testable import Volta

final class ChargeInsightsTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func charge(added: Double? = 40, used: Double? = nil, grid: Double? = nil, cost: Double? = nil,
                        fast: Bool = false, start: Int? = 20, end: Int? = 80, place: String? = nil,
                        address: String? = nil, street: String? = nil, city: String? = nil) -> ChargeSummary {
        var c = ChargeSummary(id: 1, start: t0, end: t0.addingTimeInterval(1800), address: address, placeName: place,
                              energyAddedKwh: added, energyUsedKwh: used, startBatteryLevel: start, endBatteryLevel: end,
                              durationMin: 30, maxPowerKw: nil, fastCharger: fast, cost: cost, currency: cost == nil ? nil : "EUR",
                              outsideTempAvgC: nil)
        c.energyFromGridKwh = grid
        c.street = street
        c.city = city
        return c
    }

    // MARK: Cost

    func testRecordedCostWinsAndPriceIsPerKwhAdded() throws {
        let cost = try XCTUnwrap(ChargeCost.resolve(charge(added: 40, used: 44, cost: 12), fallbackRate: 0.2, fallbackCurrency: "USD"))
        XCTAssertFalse(cost.isEstimated)
        XCTAssertEqual(cost.amount, 12)
        XCTAssertEqual(cost.currency, "EUR")
        XCTAssertEqual(try XCTUnwrap(cost.pricePerKwh), 0.30, accuracy: 1e-9)
    }

    func testMissingCostIsEstimatedFromTheElectricityRate() throws {
        let cost = try XCTUnwrap(ChargeCost.resolve(charge(added: 40), fallbackRate: 0.25, fallbackCurrency: "USD"))
        XCTAssertTrue(cost.isEstimated)
        XCTAssertEqual(cost.amount, 10, accuracy: 1e-9)
        XCTAssertEqual(cost.pricePerKwh, 0.25)
        XCTAssertEqual(cost.currency, "USD")
    }

    func testFastChargeWithoutCostStillGetsALabelledEstimate() throws {
        let cost = try XCTUnwrap(ChargeCost.resolve(charge(added: 43.2, fast: true), fallbackRate: 0.2, fallbackCurrency: "USD"))
        XCTAssertTrue(cost.isEstimated)
        XCTAssertEqual(cost.amount, 8.64, accuracy: 1e-9)
    }

    func testNoCostWithoutEnergyOrRate() {
        XCTAssertNil(ChargeCost.resolve(charge(added: nil), fallbackRate: 0.2, fallbackCurrency: "USD"))
        XCTAssertNil(ChargeCost.resolve(charge(added: 40), fallbackRate: 0, fallbackCurrency: "USD"))
        XCTAssertNil(ChargeCost.resolve(charge(added: 40, cost: .nan), fallbackRate: 0, fallbackCurrency: "USD"))
        // A recorded cost with no energy has no price per kWh.
        XCTAssertNil(ChargeCost.resolve(charge(added: nil, cost: 5), fallbackRate: 0.2, fallbackCurrency: "USD")?.pricePerKwh)
    }

    // MARK: Energy flow

    func testMeasuredGridEnergyGivesLosses() throws {
        let flow = try XCTUnwrap(ChargeEnergyFlow.resolve(charge(added: 45, used: 47, grid: 50, fast: true)))
        XCTAssertEqual(flow.gridSource, .measured)
        XCTAssertFalse(flow.isEstimated)
        XCTAssertEqual(flow.lossKwh, 5, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(flow.lossFraction), 0.1, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(flow.efficiency), 0.9, accuracy: 1e-9)
    }

    func testACSessionUsesTeslaMateChargerEnergy() throws {
        let flow = try XCTUnwrap(ChargeEnergyFlow.resolve(charge(added: 20, used: 22)))
        XCTAssertEqual(flow.gridSource, .recorded)
        XCTAssertEqual(flow.gridKwh, 22)
        // Implausible (less than added) falls back to the estimate.
        XCTAssertEqual(ChargeEnergyFlow.resolve(charge(added: 20, used: 19))?.gridSource, .estimated)
    }

    func testDCSessionWithoutGridIsEstimatedAt91Percent() throws {
        let flow = try XCTUnwrap(ChargeEnergyFlow.resolve(charge(added: 45.5, used: 50, fast: true)))
        XCTAssertEqual(flow.gridSource, .estimated)
        XCTAssertTrue(flow.isEstimated)
        XCTAssertEqual(flow.gridKwh, 50, accuracy: 1e-9)
        XCTAssertEqual(flow.lossKwh, 4.5, accuracy: 1e-9)
        XCTAssertNil(ChargeEnergyFlow.resolve(charge(added: nil)))
    }

    // MARK: SoC bar

    func testSocBarValuesAndClamping() throws {
        let bar = try XCTUnwrap(ChargeSocBar(start: 22, end: 80))
        XCTAssertEqual(bar.lower, 0.22, accuracy: 1e-9)
        XCTAssertEqual(bar.upper, 0.80, accuracy: 1e-9)
        XCTAssertEqual(bar.delta, 58)
        let clamped = try XCTUnwrap(ChargeSocBar(start: -5, end: 104))
        XCTAssertEqual(clamped.start, 0); XCTAssertEqual(clamped.end, 100)
        let falling = try XCTUnwrap(ChargeSocBar(start: 60, end: 55))
        XCTAssertEqual(falling.delta, -5); XCTAssertEqual(falling.lower, 0.55, accuracy: 1e-9)
        XCTAssertNil(ChargeSocBar(start: nil, end: 80))
    }

    // MARK: Curve points (ghost triangle)

    /// Two sources concatenated (a later window, then an earlier overlapping
    /// one) used to be drawn in array order, so the area folded back in time
    /// and drew a stray wedge. Points must come out sorted, one per instant,
    /// clipped to the session.
    func testConcatenatedSourcesAreSortedDedupedAndClipped() {
        let start = t0, end = t0.addingTimeInterval(600)
        let later = (0...10).map { (t: t0.addingTimeInterval(Double($0) * 60), value: Double?(100 + Double($0))) }
        let earlier = (-5...5).map { (t: t0.addingTimeInterval(Double($0) * 60), value: Double?(50)) }
        let points = ChargeCurve.points(later + earlier, start: start, end: end)
        XCTAssertEqual(points.map(\.t), points.map(\.t).sorted())
        XCTAssertEqual(Set(points.map(\.t)).count, points.count, "one value per instant")
        XCTAssertTrue(points.allSatisfy { $0.t >= start && $0.t <= end })
        XCTAssertEqual(points.count, 11)
        XCTAssertEqual(points.map(\.id), Array(0..<11))
        XCTAssertEqual(Set(points.map(\.segment)), [0])
    }

    func testNonFiniteAndMissingValuesAreDropped() {
        let raw: [(t: Date, value: Double?)] = [(t0, 1), (t0.addingTimeInterval(30), nil),
                                                (t0.addingTimeInterval(60), .nan), (t0.addingTimeInterval(90), 2)]
        XCTAssertEqual(ChargeCurve.points(raw, start: t0, end: t0.addingTimeInterval(120)).map(\.value), [1, 2])
    }

    func testGapsStartANewSegment() {
        let times: [Double] = [0, 30, 60, 90, 600, 630, 660]
        let raw = times.map { (t: t0.addingTimeInterval($0), value: Double?(1)) }
        let points = ChargeCurve.points(raw, start: t0, end: t0.addingTimeInterval(700))
        XCTAssertEqual(points.map(\.segment), [0, 0, 0, 0, 1, 1, 1])
    }

    func testReductionKeepsSegmentsAndOrder() {
        let raw = (0..<2000).map { i in (t: t0.addingTimeInterval(Double(i) + (i >= 1000 ? 600 : 0)), value: Double?(Double(i % 97))) }
        let points = ChargeCurve.points(raw, start: t0, end: t0.addingTimeInterval(4000))
        let reduced = ChargeCurve.reduced(points, maxPoints: 200)
        XCTAssertLessThanOrEqual(reduced.count, 220)
        XCTAssertEqual(reduced.map(\.t), reduced.map(\.t).sorted())
        XCTAssertEqual(Set(reduced.map(\.segment)), [0, 1])
        XCTAssertEqual(reduced.map(\.id), Array(0..<reduced.count))
    }

    func testTelemetryIsPreferredUnlessItOnlyCoversPartOfTheSession() {
        func run(_ from: Double, _ to: Double) -> [ChargeCurvePoint] {
            ChargeCurve.points(stride(from: from, through: to, by: 15).map { (t: t0.addingTimeInterval($0), value: Double?(1)) },
                               start: t0, end: t0.addingTimeInterval(1800))
        }
        let end = t0.addingTimeInterval(1800)
        XCTAssertEqual(ChargeCurve.choose(telemetry: run(0, 1800), samples: run(0, 1800), start: t0, end: end).source, .telemetry)
        XCTAssertEqual(ChargeCurve.choose(telemetry: run(0, 1800), samples: [], start: t0, end: end).source, .telemetry)
        XCTAssertEqual(ChargeCurve.choose(telemetry: [], samples: run(0, 1800), start: t0, end: end).source, .samples)
        XCTAssertEqual(ChargeCurve.choose(telemetry: run(0, 900), samples: run(0, 1800), start: t0, end: end).source, .samples)
        // When the samples are themselves partial, telemetry only has to match them.
        XCTAssertEqual(ChargeCurve.choose(telemetry: run(0, 900), samples: run(0, 900), start: t0, end: end).source, .telemetry)
    }

    /// Two one-minute telemetry fragments at opposite ends of a 30-minute
    /// session span the whole session end to end but cover two minutes; the
    /// complete samples must win.
    func testSelectionMeasuresCoveredTimeNotFirstToLast() {
        let end = t0.addingTimeInterval(1800)
        let fragments = stride(from: 0.0, through: 60, by: 15).map { $0 } + stride(from: 1740.0, through: 1800, by: 15).map { $0 }
        let telemetry = ChargeCurve.points(fragments.map { (t: t0.addingTimeInterval($0), value: Double?(100)) }, start: t0, end: end)
        XCTAssertEqual(Set(telemetry.map(\.segment)).count, 2)
        XCTAssertEqual(ChargeCurve.coveredSeconds(telemetry), 120, accuracy: 1e-9)
        let samples = ChargeCurve.points(stride(from: 0.0, through: 1800, by: 60).map { (t: t0.addingTimeInterval($0), value: Double?(100)) },
                                         start: t0, end: end)
        XCTAssertEqual(ChargeCurve.coveredSeconds(samples), 1800, accuracy: 1e-9)
        XCTAssertEqual(ChargeCurve.choose(telemetry: telemetry, samples: samples, start: t0, end: end).source, .samples)
    }

    /// A declared 100-second outage is shorter than the heuristic gap
    /// threshold (at least two minutes), so only the declared boundary can
    /// split the fallback samples there. Invalid-field instants split too.
    func testSampleFallbackHonoursDeclaredGapsAndInvalidFields() {
        let end = t0.addingTimeInterval(600)
        let raw = stride(from: 0.0, through: 600, by: 30).map { (t: t0.addingTimeInterval($0), value: Double?(50)) }
        let gap = FleetTelemetryGap(start: t0.addingTimeInterval(200), end: t0.addingTimeInterval(300), reason: "offline")
        func row(_ offset: Double, invalid: [String]) -> FleetTelemetrySample {
            FleetTelemetrySample(t: t0.addingTimeInterval(offset), latitude: nil, longitude: nil, speedKph: nil, powerKw: nil,
                                 elevationM: nil, batteryLevel: nil, energyRemainingKwh: nil, batteryTempMinC: nil,
                                 batteryTempMaxC: nil, insideTempC: nil, outsideTempC: nil, voltage: nil, currentA: nil,
                                 ratedRangeKm: nil, routeBreakBefore: false, invalidFields: invalid)
        }
        let block = FleetTelemetrySeries(source: "fleet_telemetry",
                                         samples: [row(450, invalid: ["Power"]), row(500, invalid: ["BatteryLevel"])],
                                         gaps: [gap], truncated: false)

        XCTAssertEqual(Set(ChargeCurve.points(raw, start: t0, end: end).map(\.segment)), [0], "heuristic alone joins it")

        let power = ChargeCurve.points(raw, start: t0, end: end, breaks: ChargeCurve.boundaries(block, field: "Power"))
        let segmentAt = { (offset: Double) in power.first { $0.t == self.t0.addingTimeInterval(offset) }?.segment }
        XCTAssertEqual(segmentAt(180), 0)
        // 210...300 touch the gap, so each is cut from its neighbour.
        XCTAssertNotEqual(segmentAt(180), segmentAt(330))
        XCTAssertNotEqual(segmentAt(420), segmentAt(480), "invalid Power at 450 s splits the line")
        XCTAssertEqual(segmentAt(510), segmentAt(600))
        // Another field's invalid instant does not split Power.
        XCTAssertEqual(segmentAt(480), segmentAt(510))

        // Splitting also lowers covered time, which feeds source selection.
        XCTAssertLessThan(ChargeCurve.coveredSeconds(power), 600)
        XCTAssertTrue(ChargeCurve.boundaries(nil, field: "Power").isEmpty)
        XCTAssertTrue(ChargeCurve.boundaries(FleetTelemetrySeries(source: "teslamate", samples: [], gaps: [gap], truncated: false),
                                             field: "Power").isEmpty)
    }

    func testTelemetrySeriesIsClippedToTheSession() {
        let rows = stride(from: -300.0, through: 2100, by: 60).map { offset in
            FleetTelemetrySample(t: t0.addingTimeInterval(offset), latitude: nil, longitude: nil, speedKph: nil, powerKw: 50,
                                 elevationM: nil, batteryLevel: nil, energyRemainingKwh: nil, batteryTempMinC: nil,
                                 batteryTempMaxC: nil, insideTempC: nil, outsideTempC: nil, voltage: nil, currentA: nil,
                                 ratedRangeKm: nil, routeBreakBefore: false)
        }
        let telemetry = FleetTelemetrySeries(source: "fleet_telemetry", samples: rows,
                                             gaps: [FleetTelemetryGap(start: t0.addingTimeInterval(-200), end: t0.addingTimeInterval(-100), reason: "offline")],
                                             truncated: false)
        let series = TelemetryMetricSeries(telemetry, field: "Power") { $0.powerKw }
        let end = t0.addingTimeInterval(1800)
        let clipped = series.clipped(start: t0, end: end)
        XCTAssertEqual(clipped.points.first?.t, t0)
        XCTAssertEqual(clipped.points.last?.t, end)
        XCTAssertTrue(clipped.gaps.isEmpty, "a gap before the session is dropped")
        XCTAssertEqual(ChargeCurve.points(series, start: t0, end: end).count, 31)
    }

    func testPowerAxisAlwaysContainsThePeak() {
        XCTAssertGreaterThanOrEqual(ChargeCurve.powerDomain([20, 196, 120]).upperBound, 196)
        XCTAssertEqual(ChargeCurve.powerDomain([20, 196, 120]).upperBound, 250)
        XCTAssertGreaterThanOrEqual(ChargeCurve.powerDomain([7.7]).upperBound, 7.7)
        XCTAssertGreaterThanOrEqual(ChargeCurve.powerDomain([150], summaryPeak: 250).upperBound, 250)
        XCTAssertEqual(ChargeCurve.powerDomain([]), 0...10)
    }

    func testStaleElectricalReadingsAreHiddenForDC() {
        let flat = ChargeCurve.points((0..<10).map { (t: t0.addingTimeInterval(Double($0) * 60), value: Double?(240)) },
                                      start: t0, end: t0.addingTimeInterval(600))
        XCTAssertFalse(ChargeCurve.isMeaningful(flat, above: 50))
        XCTAssertTrue(ChargeCurve.isMeaningful(flat, above: 50, requireVariation: false))
        XCTAssertFalse(ChargeCurve.isMeaningful([], above: 50, requireVariation: false))
    }

    // MARK: Place

    func testTitleAndSubtitleFallbacks() {
        let full = charge(place: "Downtown Supercharger", address: "1 Sample Rd, Mountain View, CA",
                          street: "1 Sample Rd", city: "Mountain View")
        XCTAssertEqual(ChargePlace.title(full), "1 Sample Rd")
        XCTAssertEqual(ChargePlace.subtitle(full), "Downtown Supercharger · Mountain View")
        let placeOnly = charge(place: "Downtown Supercharger", address: "1 Sample Rd, Mountain View, CA")
        XCTAssertEqual(ChargePlace.title(placeOnly), "Downtown Supercharger")
        XCTAssertEqual(ChargePlace.subtitle(placeOnly), "1 Sample Rd, Mountain View, CA")
        let addressOnly = charge(address: "1 Sample Rd, Mountain View, CA")
        XCTAssertEqual(ChargePlace.title(addressOnly), "1 Sample Rd")
        XCTAssertEqual(ChargePlace.subtitle(addressOnly), "Mountain View, CA")
        XCTAssertEqual(ChargePlace.title(charge()), "Unknown location")
        XCTAssertEqual(ChargePlace.subtitle(charge(place: "Home", city: "Palo Alto")), "Palo Alto")
        XCTAssertEqual(ChargePlace.subtitle(charge(place: "Home")), "Home charger")
    }

    // MARK: Decoding

    func testNewOptionalFieldsDecodeAndNegativeIdsAreAccepted() throws {
        let decoder = APIDataSource.makeDecoder()
        let base = #"{"id":-42,"start":"2026-10-06T12:00:00Z","end":"2026-10-06T12:27:00Z","address":null,"placeName":"Sample Supercharger","energyAddedKwh":43.2,"energyUsedKwh":null,"startBatteryLevel":22,"endBatteryLevel":80,"durationMin":27,"maxPowerKw":196,"fastCharger":true,"cost":null,"currency":null,"outsideTempAvgC":null"#
        let rich = try decoder.decode(ChargeSummary.self, from: Data((base + #","source":"fleet_telemetry","avgPowerKw":96.5,"city":"Mountain View","street":"1 Sample Rd","energyFromGridKwh":47.1}"#).utf8))
        XCTAssertEqual(rich.id, -42)
        XCTAssertEqual(rich.source, "fleet_telemetry")
        XCTAssertEqual(rich.avgPowerKw, 96.5)
        XCTAssertEqual(rich.city, "Mountain View")
        XCTAssertEqual(rich.street, "1 Sample Rd")
        XCTAssertEqual(rich.energyFromGridKwh, 47.1)

        let bare = try decoder.decode(ChargeSummary.self, from: Data((base + "}").utf8))
        XCTAssertEqual(bare.id, -42)
        XCTAssertNil(bare.source); XCTAssertNil(bare.avgPowerKw); XCTAssertNil(bare.city)
        XCTAssertNil(bare.street); XCTAssertNil(bare.energyFromGridKwh)

        let nulls = try decoder.decode(ChargeSummary.self, from: Data((base + #","source":null,"avgPowerKw":null,"city":null,"street":null,"energyFromGridKwh":null}"#).utf8))
        XCTAssertNil(nulls.source); XCTAssertNil(nulls.energyFromGridKwh)

        let detail = try decoder.decode(ChargeDetail.self, from: Data((base + #","street":"1 Sample Rd","samples":[{"t":"2026-10-06T12:01:00Z","batteryLevel":25,"powerKw":180,"voltage":null,"currentA":null,"ratedRangeKm":null}],"efficiency":null}"#).utf8))
        XCTAssertEqual(detail.summary.id, -42)
        XCTAssertEqual(detail.summary.street, "1 Sample Rd")
        XCTAssertEqual(detail.samples.count, 1)
    }

    // MARK: Demo data

    func testDemoChargesExerciseTheNewFields() async throws {
        let source = MockDataSource()
        let page = try await source.charges(vehicleID: 1, range: .init(), cursor: nil)
        let telemetry = try XCTUnwrap(page.items.first { $0.id < 0 })
        XCTAssertTrue(telemetry.fastCharger)
        XCTAssertNil(telemetry.cost)
        XCTAssertGreaterThan(telemetry.maxPowerKw ?? 0, 150)
        XCTAssertTrue(page.items.contains { $0.energyFromGridKwh != nil })
        XCTAssertTrue(page.items.allSatisfy { $0.street != nil && $0.city != nil })
        let detail = try await source.charge(id: telemetry.id)
        let power = ChargeCurve.points(TelemetryMetricSeries(detail.telemetry, field: "Power") { $0.powerKw },
                                       start: telemetry.start, end: try XCTUnwrap(telemetry.end))
        XCTAssertEqual(try XCTUnwrap(ChargeCurve.peak(power)).value, 196, accuracy: 1)
        XCTAssertTrue(power.allSatisfy { $0.t >= telemetry.start })
    }
}
