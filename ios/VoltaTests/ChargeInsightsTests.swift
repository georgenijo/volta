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

    private func rates(home: Double? = 0.2, dc: Double? = nil) -> ElectricityRates {
        ElectricityRates(home: home, dcFast: dc, currency: "USD")
    }

    func testRecordedCostWinsAndPriceIsPerKwhAdded() throws {
        let cost = try XCTUnwrap(ChargeCost.resolve(charge(added: 40, used: 44, cost: 12), rates: rates()))
        XCTAssertFalse(cost.isEstimated)
        XCTAssertEqual(cost.amount, 12)
        XCTAssertEqual(cost.currency, "EUR")
        XCTAssertEqual(try XCTUnwrap(cost.pricePerKwh), 0.30, accuracy: 1e-9)
        // The server price wins over both local rates, home and DC fast alike.
        XCTAssertEqual(ChargeCost.resolve(charge(added: 40, cost: 12, fast: true), rates: rates(dc: 0.5))?.amount, 12)
        XCTAssertEqual(ChargeCost.resolve(charge(added: 40, cost: 12), rates: rates(home: nil))?.amount, 12)
    }

    func testMissingCostIsEstimatedFromTheElectricityRate() throws {
        let cost = try XCTUnwrap(ChargeCost.resolve(charge(added: 40), rates: rates(home: 0.25)))
        XCTAssertTrue(cost.isEstimated)
        XCTAssertEqual(cost.amount, 10, accuracy: 1e-9)
        XCTAssertEqual(cost.pricePerKwh, 0.25)
        XCTAssertEqual(cost.currency, "USD")
    }

    func testFastChargeUsesTheDCRateAndHomeChargeTheHomeRate() throws {
        let fast = try XCTUnwrap(ChargeCost.resolve(charge(added: 40, fast: true), rates: rates(home: 0.2, dc: 0.5)))
        XCTAssertTrue(fast.isEstimated)
        XCTAssertEqual(fast.amount, 20, accuracy: 1e-9)
        XCTAssertEqual(fast.pricePerKwh, 0.5)
        let home = try XCTUnwrap(ChargeCost.resolve(charge(added: 40), rates: rates(home: 0.2, dc: 0.5)))
        XCTAssertEqual(home.amount, 8, accuracy: 1e-9)
        // DC fast with no DC rate falls back to the home rate, labelled as an estimate.
        let fallback = try XCTUnwrap(ChargeCost.resolve(charge(added: 43.2, fast: true), rates: rates()))
        XCTAssertTrue(fallback.isEstimated)
        XCTAssertEqual(fallback.amount, 8.64, accuracy: 1e-9)
        // A DC rate alone never prices a home session.
        XCTAssertNil(ChargeCost.resolve(charge(added: 40), rates: rates(home: nil, dc: 0.5)))
    }

    func testNoCostWithoutEnergyOrRate() throws {
        XCTAssertNil(ChargeCost.resolve(charge(added: nil), rates: rates()))
        XCTAssertNil(ChargeCost.resolve(charge(added: 40), rates: rates(home: nil)))
        XCTAssertNil(ChargeCost.resolve(charge(added: 40, fast: true), rates: rates(home: nil)))
        XCTAssertNil(ChargeCost.resolve(charge(added: 40, cost: .nan), rates: rates(home: nil)))
        // A recorded cost with no energy has no price per kWh.
        XCTAssertNil(ChargeCost.resolve(charge(added: nil, cost: 5), rates: rates())?.pricePerKwh)
        // Free charging is a real rate.
        XCTAssertEqual(try XCTUnwrap(ChargeCost.resolve(charge(added: 40), rates: rates(home: 0))).amount, 0)
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
        var tesla = full
        tesla.fastCharger = true; tesla.fastChargerBrand = "Tesla"
        XCTAssertEqual(ChargePlace.network(tesla), "Tesla Supercharger")
        XCTAssertEqual(ChargePlace.subtitle(tesla), "Tesla Supercharger · Mountain View")
        // The brand only names a DC session; other brands fall back to the place.
        var ac = tesla
        ac.fastCharger = false
        XCTAssertNil(ChargePlace.network(ac))
        XCTAssertEqual(ChargePlace.subtitle(ac), "Downtown Supercharger · Mountain View")
        tesla.fastChargerBrand = "Other"
        XCTAssertNil(ChargePlace.network(tesla))
    }

    // MARK: Decoding

    func testNewOptionalFieldsDecodeAndNegativeIdsAreAccepted() throws {
        let decoder = APIDataSource.makeDecoder()
        let base = #"{"id":-42,"start":"2026-10-06T12:00:00Z","end":"2026-10-06T12:27:00Z","address":null,"placeName":"Sample Supercharger","energyAddedKwh":43.2,"energyUsedKwh":null,"startBatteryLevel":22,"endBatteryLevel":80,"durationMin":27,"maxPowerKw":196,"fastCharger":true,"cost":null,"currency":null,"outsideTempAvgC":null"#
        let rich = try decoder.decode(ChargeSummary.self, from: Data((base + #","source":"fleet_telemetry","avgPowerKw":96.5,"city":"Mountain View","street":"1 Sample Rd","energyFromGridKwh":47.1,"fastChargerBrand":"Tesla"}"#).utf8))
        XCTAssertEqual(rich.id, -42)
        XCTAssertEqual(rich.source, "fleet_telemetry")
        XCTAssertEqual(rich.avgPowerKw, 96.5)
        XCTAssertEqual(rich.city, "Mountain View")
        XCTAssertEqual(rich.street, "1 Sample Rd")
        XCTAssertEqual(rich.energyFromGridKwh, 47.1)
        XCTAssertEqual(rich.fastChargerBrand, "Tesla")

        let bare = try decoder.decode(ChargeSummary.self, from: Data((base + "}").utf8))
        XCTAssertEqual(bare.id, -42)
        XCTAssertNil(bare.source); XCTAssertNil(bare.avgPowerKw); XCTAssertNil(bare.city)
        XCTAssertNil(bare.street); XCTAssertNil(bare.energyFromGridKwh); XCTAssertNil(bare.fastChargerBrand)

        let nulls = try decoder.decode(ChargeSummary.self, from: Data((base + #","source":null,"avgPowerKw":null,"city":null,"street":null,"energyFromGridKwh":null,"fastChargerBrand":null}"#).utf8))
        XCTAssertNil(nulls.source); XCTAssertNil(nulls.energyFromGridKwh)

        let detail = try decoder.decode(ChargeDetail.self, from: Data((base + #","street":"1 Sample Rd","samples":[{"t":"2026-10-06T12:01:00Z","batteryLevel":25,"powerKw":180,"voltage":null,"currentA":null,"ratedRangeKm":null}],"efficiency":null}"#).utf8))
        XCTAssertEqual(detail.summary.id, -42)
        XCTAssertEqual(detail.summary.street, "1 Sample Rd")
        XCTAssertEqual(detail.samples.count, 1)
    }

    // MARK: Peak state of charge

    private func curve(_ values: [(minute: Double, value: Double, segment: Int)]) -> [ChargeCurvePoint] {
        values.enumerated().map { ChargeCurvePoint(id: $0, t: t0.addingTimeInterval($1.minute * 60), value: $1.value, segment: $1.segment) }
    }

    func testSocAtPeakPairsOnlyTheShownPeakSample() {
        let power = curve([(0, 40, 0), (1, 80, 0), (2, 70, 0)])
        let soc = curve([(0, 55, 0), (1, 60, 0), (2, 62, 0)])
        XCTAssertEqual(ChargeCurve.socAtPeak(power: power, soc: soc, shownPeak: 80), 60)
        XCTAssertNil(ChargeCurve.socAtPeak(power: power, soc: soc, shownPeak: 150),
                     "the summary's 150 kW peak is not the sample where the car was at 60%")
        XCTAssertNil(ChargeCurve.socAtPeak(power: power, soc: [], shownPeak: 80))
    }

    func testSocAtPeakNeverCrossesAGap() {
        // Power peaks just before a recording gap; the only SoC reading is after it.
        let power = curve([(0, 60, 0), (1, 80, 0), (10, 50, 1), (11, 45, 1)])
        XCTAssertNil(ChargeCurve.socAtPeak(power: power, soc: curve([(1.5, 61, 0), (10, 70, 0)]), shownPeak: 80),
                     "a reading past the end of the peak's stretch is across the gap")
        XCTAssertNil(ChargeCurve.socAtPeak(power: curve([(0, 80, 0), (20, 60, 0)]), soc: curve([(10, 50, 0)]), shownPeak: 80),
                     "too far from the peak in time")
        XCTAssertEqual(ChargeCurve.socAtPeak(power: power, soc: curve([(0.5, 58, 0), (10, 70, 0)]), shownPeak: 80), 58)
    }

    func testSocAtPeakNeedsAnUnbrokenSocStretch() {
        let end = t0.addingTimeInterval(600)
        func at(_ seconds: Double) -> Date { t0.addingTimeInterval(seconds) }
        let power = ChargeCurve.points([(at(0), 40), (at(30), 60), (at(60), 80), (at(90), 70)], start: t0, end: end, gap: 120)
        // BatteryLevel is invalid at the peak; the next valid reading starts a new SoC segment.
        let broken = ChargeCurve.points([(at(0), 55), (at(30), 58), (at(60), nil), (at(90), 65)], start: t0, end: end,
                                        gap: 120, breaks: [at(60)...at(60)])
        XCTAssertNil(ChargeCurve.socAtPeak(power: power, soc: broken, shownPeak: 80),
                     "65% after the invalid reading is not the SoC at the peak")
        let onlyAfter = ChargeCurve.points([(at(60), nil), (at(90), 65)], start: t0, end: end, gap: 120, breaks: [at(60)...at(60)])
        XCTAssertNil(ChargeCurve.socAtPeak(power: power, soc: onlyAfter, shownPeak: 80))
        let continuous = ChargeCurve.points([(at(0), 55), (at(30), 58), (at(90), 65)], start: t0, end: end, gap: 120)
        XCTAssertEqual(ChargeCurve.socAtPeak(power: power, soc: continuous, shownPeak: 80), 58)
        let atPeak = ChargeCurve.points([(at(30), 58), (at(60), 61), (at(90), 65)], start: t0, end: end, gap: 120)
        XCTAssertEqual(ChargeCurve.socAtPeak(power: power, soc: atPeak, shownPeak: 80), 61)
    }

    // MARK: Demo data

    func testDemoChargesExerciseTheNewFields() async throws {
        let source = MockDataSource()
        let page = try await source.charges(vehicleID: 1, range: .init(), cursor: nil)
        let telemetry = try XCTUnwrap(page.items.first { $0.id < 0 && $0.cost == nil })
        XCTAssertTrue(telemetry.fastCharger)
        XCTAssertNil(telemetry.cost)
        XCTAssertGreaterThan(telemetry.maxPowerKw ?? 0, 150)
        XCTAssertTrue(page.items.contains { $0.energyFromGridKwh != nil })
        XCTAssertTrue(page.items.allSatisfy { $0.street != nil && $0.city != nil })
        // The newest session is a priced Tesla Supercharger visit; home sessions are AC.
        XCTAssertEqual(page.items.first.flatMap(ChargePlace.network), "Tesla Supercharger")
        XCTAssertNotNil(page.items.first?.cost)
        XCTAssertTrue(page.items.contains { $0.kind == .home && !$0.fastCharger })
        let detail = try await source.charge(id: telemetry.id)
        let power = ChargeCurve.points(TelemetryMetricSeries(detail.telemetry, field: "Power") { $0.powerKw },
                                       start: telemetry.start, end: try XCTUnwrap(telemetry.end))
        XCTAssertEqual(try XCTUnwrap(ChargeCurve.peak(power)).value, 196, accuracy: 1)
        XCTAssertTrue(power.allSatisfy { $0.t >= telemetry.start })
    }
}
