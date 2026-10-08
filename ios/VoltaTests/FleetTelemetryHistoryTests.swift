import XCTest
@testable import Volta

final class FleetTelemetryHistoryTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func sample(_ seconds: Double, latitude: Double? = 37.2, longitude: Double? = -122.1,
                        speed: Double? = 50, power: Double? = 10, elevation: Double? = 40, battery: Double? = 70,
                        energy: Double? = 48, minTemp: Double? = 22, maxTemp: Double? = 30,
                        inside: Double? = 20, outside: Double? = 12, breakBefore: Bool = false,
                        invalidFields: [String] = [], longitudinal: Double? = nil,
                        lateral: Double? = nil) -> FleetTelemetrySample {
        FleetTelemetrySample(t: t0.addingTimeInterval(seconds), latitude: latitude, longitude: longitude,
                             speedKph: speed, powerKw: power, elevationM: elevation, batteryLevel: battery,
                             energyRemainingKwh: energy, batteryTempMinC: minTemp, batteryTempMaxC: maxTemp,
                             insideTempC: inside, outsideTempC: outside, voltage: 390, currentA: 25,
                             ratedRangeKm: 360, longitudinalAccelerationMps2: longitudinal,
                             lateralAccelerationMps2: lateral, routeBreakBefore: breakBefore,
                             invalidFields: invalidFields)
    }

    private func telemetry(_ samples: [FleetTelemetrySample], gaps: [FleetTelemetryGap] = [],
                           coverage: FleetTelemetryCoverage? = nil, downsampled: Bool = false,
                           truncated: Bool = false) -> FleetTelemetrySeries {
        FleetTelemetrySeries(source: "fleet_telemetry", samples: samples, gaps: gaps, coverage: coverage,
                             downsampled: downsampled, truncated: truncated)
    }

    private func metric(_ start: Double, _ end: Double, source: Int, returned: Int? = nil,
                        maxInterval: Double?, returnedMaxInterval: Double? = nil,
                        gaps: Int = 0, downsampled: Bool = false) -> FleetTelemetryMetricCoverage {
        FleetTelemetryMetricCoverage(start: t0.addingTimeInterval(start), end: t0.addingTimeInterval(end),
                                     sourceSampleCount: source, returnedSampleCount: returned ?? source,
                                     densityPerMinute: Double(source) / max(end / 60, 1.0 / 60),
                                     maxIntervalSeconds: maxInterval,
                                     returnedMaxIntervalSeconds: returnedMaxInterval ?? maxInterval,
                                     gapCount: gaps, downsampled: downsampled,
                                     truncated: false)
    }

    private func coverage(seconds: Double, returned: Int, metrics: [String: FleetTelemetryMetricCoverage],
                          source: Int? = nil) -> FleetTelemetryCoverage {
        FleetTelemetryCoverage(sessionStart: t0, sessionEnd: t0.addingTimeInterval(seconds), sampleStart: t0,
                               sampleEnd: t0.addingTimeInterval(seconds), sourceSampleCount: source ?? returned,
                               returnedSampleCount: returned, metrics: metrics)
    }

    private func summary(seconds: Double = 600) -> DriveSummary {
        DriveSummary(id: 1, start: t0, end: t0.addingTimeInterval(seconds), startAddress: nil, endAddress: nil,
                     distanceKm: 5, durationMin: seconds / 60, startBatteryLevel: 70, endBatteryLevel: 68,
                     energyUsedKwh: 1, efficiencyWhPerKm: 200, maxSpeedKph: 70, avgSpeedKph: 30,
                     outsideTempAvgC: 12)
    }

    func testLegacyDetailsDecodeWithoutTelemetry() throws {
        let decoder = APIDataSource.makeDecoder()
        let drive = try decoder.decode(DriveDetail.self, from: DecodingTests.fixture("driveDetail"))
        let charge = try decoder.decode(ChargeDetail.self, from: DecodingTests.fixture("chargeDetail"))
        XCTAssertNil(drive.telemetry)
        XCTAssertNil(charge.telemetry)
        XCTAssertNil(drive.path.first?.routeBreakBefore)
        let oldSample = try decoder.decode(FleetTelemetrySample.self,
            from: Data(#"{"t":"2026-10-06T12:00:00Z"}"#.utf8))
        XCTAssertEqual(oldSample.invalidFields, [])
        XCTAssertFalse(oldSample.routeBreakBefore)
        XCTAssertNil(oldSample.longitudinalAccelerationMps2)
        XCTAssertNil(oldSample.lateralAccelerationMps2)
    }

    private func detailFixture(_ name: String, telemetry: Any) throws -> Data {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: DecodingTests.fixture(name)) as? [String: Any])
        root["telemetry"] = telemetry
        return try JSONSerialization.data(withJSONObject: root)
    }

    func testZeroDurationNullMetricDensityDecodesForDriveAndCharge() throws {
        let instant = "2026-10-06T12:00:00Z"
        let block: [String: Any] = [
            "source": "fleet_telemetry", "samples": [["t": instant, "batteryLevel": 70]], "gaps": [],
            "coverage": [
                "sessionStart": instant, "sessionEnd": instant, "sampleStart": instant, "sampleEnd": instant,
                "sourceSampleCount": 1, "returnedSampleCount": 1,
                "metrics": ["batteryLevel": [
                    "start": instant, "end": instant, "sourceSampleCount": 1, "returnedSampleCount": 1,
                    "densityPerMinute": NSNull(), "maxIntervalSeconds": NSNull(),
                    "returnedMaxIntervalSeconds": NSNull(), "gapCount": 0,
                    "downsampled": false, "truncated": false,
                ]],
            ],
            "downsampled": false, "truncated": false,
        ]
        let decoder = APIDataSource.makeDecoder()
        let drive = try decoder.decode(DriveDetail.self, from: detailFixture("driveDetail", telemetry: block))
        let charge = try decoder.decode(ChargeDetail.self, from: detailFixture("chargeDetail", telemetry: block))
        for series in [drive.telemetry, charge.telemetry] {
            let metric = try XCTUnwrap(try XCTUnwrap(series).coverage?.metrics["batteryLevel"])
            XCTAssertNil(metric.densityPerMinute, "zero duration has undefined density, not an absent telemetry block")
            XCTAssertNil(metric.maxIntervalSeconds)
            XCTAssertEqual(series?.samples.first?.batteryLevel, 70)
        }
        XCTAssertEqual(drive.path.count, 1)
        XCTAssertEqual(charge.samples.count, 1)
    }

    func testMalformedTelemetryKeepsValidLegacyDriveAndChargeDetails() throws {
        let decoder = APIDataSource.makeDecoder()
        let originalDrive = try decoder.decode(DriveDetail.self, from: DecodingTests.fixture("driveDetail"))
        let originalCharge = try decoder.decode(ChargeDetail.self, from: DecodingTests.fixture("chargeDetail"))
        let malformed: [Any] = [
            "invalid block",
            ["source": "fleet_telemetry", "samples": [["t": "invalid date"]], "gaps": []],
            ["source": "fleet_telemetry", "samples": [["t": "2026-10-06T12:00:00Z", "batteryLevel": "invalid number"]], "gaps": []],
            ["source": "fleet_telemetry", "samples": [], "gaps": [], "coverage": ["metrics": "invalid coverage"]],
        ]
        for block in malformed {
            let drive = try decoder.decode(DriveDetail.self, from: detailFixture("driveDetail", telemetry: block))
            let charge = try decoder.decode(ChargeDetail.self, from: detailFixture("chargeDetail", telemetry: block))
            XCTAssertNil(drive.telemetry)
            XCTAssertEqual(drive, originalDrive, "malformed supplemental telemetry must preserve all legacy drive fields")
            XCTAssertNil(charge.telemetry)
            XCTAssertEqual(charge, originalCharge, "malformed supplemental telemetry must preserve all legacy charge fields")
        }
    }

    func testTelemetryEnvelopeDecodesAllSignalsAndProvenance() throws {
        var root = try XCTUnwrap(JSONSerialization.jsonObject(with: DecodingTests.fixture("driveDetail")) as? [String: Any])
        root["telemetry"] = [
            "source": "fleet_telemetry",
            "samples": [[
                "t": "2026-10-06T12:00:01Z", "latitude": 37.1, "longitude": -122.2,
                "speedKph": 51.5, "powerKw": -8.2, "elevationM": 38.0, "batteryLevel": 79.5,
                "energyRemainingKwh": 48.7, "batteryTempMinC": 21.2, "batteryTempMaxC": 29.4,
                "insideTempC": 20.5, "outsideTempC": 12.3, "voltage": 389.2, "currentA": -21.0,
                "longitudinalAccelerationMps2": -1.25, "lateralAccelerationMps2": 0.42,
                "ratedRangeKm": 355.0, "routeBreakBefore": true, "invalidFields": ["Power"],
            ]],
            "gaps": [["start": "2026-10-06T12:00:00Z", "end": "2026-10-06T12:00:01Z", "reason": "receiver_restart"]],
            "coverage": [
                "sessionStart": "2026-10-06T12:00:00Z", "sessionEnd": "2026-10-06T13:00:00Z",
                "sampleStart": "2026-10-06T12:00:01Z", "sampleEnd": "2026-10-06T12:59:59Z",
                "sourceSampleCount": 1201, "returnedSampleCount": 600,
                "metrics": ["speedKph": [
                    "start": "2026-10-06T12:00:01Z", "end": "2026-10-06T12:59:59Z",
                    "sourceSampleCount": 1200, "returnedSampleCount": 600, "densityPerMinute": 20,
                    "maxIntervalSeconds": 3, "returnedMaxIntervalSeconds": 6,
                    "gapCount": 0, "downsampled": true, "truncated": false,
                ]],
            ],
            "downsampled": true,
            "truncated": true,
        ]
        let detail = try APIDataSource.makeDecoder().decode(DriveDetail.self, from: JSONSerialization.data(withJSONObject: root))
        let series = try XCTUnwrap(detail.telemetry)
        XCTAssertEqual(series.source, "fleet_telemetry")
        XCTAssertEqual(series.samples.first?.energyRemainingKwh, 48.7)
        XCTAssertEqual(series.samples.first?.batteryTempMaxC, 29.4)
        XCTAssertEqual(series.samples.first?.insideTempC, 20.5)
        XCTAssertEqual(series.samples.first?.longitudinalAccelerationMps2, -1.25)
        XCTAssertEqual(series.samples.first?.lateralAccelerationMps2, 0.42)
        XCTAssertEqual(series.samples.first?.invalidFields, ["Power"])
        XCTAssertEqual(series.gaps.first?.reason, "receiver_restart")
        XCTAssertEqual(series.coverage?.metrics["speedKph"]?.sourceSampleCount, 1200)
        XCTAssertEqual(series.coverage?.metrics["speedKph"]?.returnedSampleCount, 600)
        XCTAssertEqual(series.coverage?.metrics["speedKph"]?.returnedMaxIntervalSeconds, 6)
        XCTAssertTrue(series.downsampled)
        XCTAssertTrue(series.truncated)
    }

    func testTelemetryRouteUsesOnlyRealCoordinatesAndBreaksAtKnownGap() {
        let gap = FleetTelemetryGap(start: t0.addingTimeInterval(1), end: t0.addingTimeInterval(2), reason: "disconnect")
        let source = telemetry([
            sample(0),
            sample(1, latitude: nil, longitude: nil, energy: 47),
            sample(3),
        ], gaps: [gap])
        let path = source.drivePath()
        XCTAssertEqual(path.count, 2, "a slow signal-only row must not receive a fabricated coordinate")
        XCTAssertEqual(path.last?.routeBreakBefore, true)
        let timeline = TripTimeline(path: path, start: t0, end: t0.addingTimeInterval(3))
        XCTAssertEqual(timeline.segments.count, 2, "a declared stream gap splits a route even when timestamps are close")
        XCTAssertTrue(timeline.sampledPairs.isEmpty)
    }

    func testSlowSignalsKeepTheirOwnCadenceAndBreakOnlyAtKnownBoundary() {
        let source = telemetry([
            sample(0, energy: 50),
            sample(30, energy: nil),
            sample(60, energy: 49),
            sample(90, latitude: nil, longitude: nil, energy: 48, breakBefore: true),
        ])
        let energy = TelemetryMetricSeries(source, field: "EnergyRemaining") { $0.energyRemainingKwh }
        XCTAssertEqual(energy.points.map(\.value), [50, 49, 48])
        XCTAssertEqual(energy.segmentCount, 2, "other signals' rows do not break this signal; an explicit route break does")
        XCTAssertEqual(source.drivePath().count, 3, "signal cadence is independent of GPS cadence")
    }

    func testOnlyAnExplicitInvalidForThisFieldBreaksItsRun() {
        let unrelated = telemetry([
            sample(0, minTemp: 20),
            sample(60, minTemp: nil, invalidFields: ["EnergyRemaining"]),
            sample(120, minTemp: 24),
        ])
        let continuous = TelemetryMetricSeries(unrelated, field: "ModuleTempMin") { $0.batteryTempMinC }
        XCTAssertEqual(continuous.segmentCount, 1, "an unrelated null/invalid signal keeps module temperature's cadence")

        let explicit = telemetry([
            sample(0, minTemp: 20),
            sample(60, minTemp: nil, invalidFields: ["ModuleTempMin"]),
            sample(120, minTemp: 24),
        ])
        let split = TelemetryMetricSeries(explicit, field: "ModuleTempMin") { $0.batteryTempMinC }
        XCTAssertEqual(split.points.map(\.value), [20, 24])
        XCTAssertEqual(split.segmentCount, 2, "an explicitly invalid observation must not be bridged")
    }

    func testSelectionDoesNotSnapAcrossGapOrDistantObservation() {
        let gap = FleetTelemetryGap(start: t0.addingTimeInterval(40), end: t0.addingTimeInterval(80), reason: "disconnect")
        let source = telemetry([sample(0, energy: 50), sample(120, energy: 49)], gaps: [gap])
        let energy = TelemetryMetricSeries(source, field: "EnergyRemaining") { $0.energyRemainingKwh }
        XCTAssertEqual(energy.nearestPoint(to: t0.addingTimeInterval(30))?.value, 50)
        XCTAssertNil(energy.nearestPoint(to: t0.addingTimeInterval(60)), "selection inside a known gap has no annotation")
        XCTAssertEqual(energy.nearestPoint(to: t0.addingTimeInterval(239))?.value, 49,
                       "a point 119 seconds away remains selectable")
        XCTAssertNil(energy.nearestPoint(to: t0.addingTimeInterval(241)),
                     "a chart selection over 120 seconds from a recording must not silently snap")
    }

    func testAccelerationMappingDomainAndFieldSpecificInvalidBoundary() {
        let source = telemetry([
            sample(0, longitudinal: -0.4, lateral: 0.2),
            sample(3, invalidFields: ["LongitudinalAcceleration"]),
            sample(6, longitudinal: 0.7, lateral: -0.3),
        ])
        let longitudinal = TelemetryMetricSeries(source, field: "LongitudinalAcceleration") {
            $0.longitudinalAccelerationMps2
        }
        let lateral = TelemetryMetricSeries(source, field: "LateralAcceleration") {
            $0.lateralAccelerationMps2
        }
        XCTAssertEqual(longitudinal.points.map(\.value), [-0.4, 0.7])
        XCTAssertEqual(longitudinal.segmentCount, 2, "explicit longitudinal invalidity splits only that trace")
        XCTAssertEqual(lateral.points.map(\.value), [0.2, -0.3])
        XCTAssertEqual(lateral.segmentCount, 1)
        XCTAssertEqual(TelemetryAcceleration.domain(longitudinal.values + lateral.values), -1...1)
        let strong = TelemetryAcceleration.domain([-3, 2])
        XCTAssertEqual(strong.lowerBound, -3.3, accuracy: 1e-9)
        XCTAssertEqual(strong.upperBound, 3.3, accuracy: 1e-9)
    }

    func testFullTripTelemetryWinsPerMetricWhenReturnedCoverageIsBetter() {
        let legacy = stride(from: 0.0, through: 600, by: 10).map {
            DrivePoint(t: t0.addingTimeInterval($0), latitude: 1 + $0 / 10_000, longitude: 2,
                       speedKph: 30, powerKw: -5, elevationM: 100 - $0 / 60, batteryLevel: 70)
        }
        let samples = stride(from: 0.0, through: 600, by: 3).map {
            sample($0, latitude: 37.2 + $0 / 100_000, speed: 50 + $0 / 100, power: -10,
                   elevation: 200 - $0 / 30, battery: 80 - $0 / 600)
        }
        let full = metric(0, 600, source: samples.count, maxInterval: 3)
        let metadata = coverage(seconds: 600, returned: samples.count, metrics: [
            "latitude": full, "longitude": full, "speedKph": full, "powerKw": full,
            "elevationM": full, "batteryLevel": full,
        ])
        let detail = DriveDetail(summary: summary(), path: legacy, elevationGainM: nil,
                                 telemetry: telemetry(samples, coverage: metadata))
        let snapshot = TripSnapshot(detail, units: .init(distance: .kilometers, temperature: .celsius))
        XCTAssertTrue(snapshot.usesFleetTelemetry)
        XCTAssertTrue(snapshot.usesTelemetrySpeed)
        XCTAssertTrue(snapshot.usesTelemetryPower)
        XCTAssertTrue(snapshot.usesTelemetryElevation)
        XCTAssertTrue(snapshot.usesTelemetryBattery)
        XCTAssertEqual(snapshot.timeline.points.count, samples.count)
        XCTAssertEqual(snapshot.speed.values.max(), 56)
    }

    func testDenseTelemetryWithOffsetBoundariesWinsWithinOneLegacyInterval() {
        let legacyDates = stride(from: 0.0, through: 600, by: 10).map { t0.addingTimeInterval($0) }
        let legacy = RecordedMetricCoverage.dates(legacyDates, sessionStart: t0, sessionEnd: t0.addingTimeInterval(600))
        XCTAssertEqual(legacy.sampleIntervalSeconds, 10)
        for (start, end) in [(1.0, 599.0), (10.0, 590.0)] {
            let samples = stride(from: start, through: end, by: 1).map { sample($0) }
            let full = metric(start, end, source: samples.count, maxInterval: 1)
            let source = telemetry(samples, coverage: coverage(seconds: 600, returned: samples.count,
                                                               metrics: ["speedKph": full]))
            XCTAssertTrue(source.shouldPrefer(metric: "speedKph", over: legacy),
                          "dense full telemetry should not lose on independent cadence endpoints")
        }
        let samples = stride(from: 11.0, through: 590, by: 1).map { sample($0) }
        let full = metric(11, 590, source: samples.count, maxInterval: 1)
        XCTAssertFalse(telemetry(samples, coverage: coverage(seconds: 600, returned: samples.count,
            metrics: ["speedKph": full])).shouldPrefer(metric: "speedKph", over: legacy),
            "boundary loss beyond one legacy interval must preserve legacy")
    }

    func testBoundaryToleranceDoesNotForgiveInternalCoverageLoss() {
        let legacyDates = stride(from: 0.0, through: 600, by: 10).map { t0.addingTimeInterval($0) }
        let legacy = RecordedMetricCoverage.dates(legacyDates, sessionStart: t0, sessionEnd: t0.addingTimeInterval(600))
        let samples = stride(from: 1.0, through: 599, by: 1).filter { $0 < 230 || $0 > 370 }.map { sample($0) }
        let incomplete = metric(1, 599, source: samples.count, maxInterval: 142)
        let source = telemetry(samples, coverage: coverage(seconds: 600, returned: samples.count,
                                                           metrics: ["speedKph": incomplete]))
        XCTAssertFalse(source.shouldPrefer(metric: "speedKph", over: legacy),
                       "accepted endpoint offsets do not compensate a missing internal interval")
    }

    func testBoundaryToleranceIsCappedAtGapThreshold() {
        let legacyDates = stride(from: 0.0, through: 6000, by: 200).map { t0.addingTimeInterval($0) }
        let legacy = RecordedMetricCoverage.dates(legacyDates, sessionStart: t0, sessionEnd: t0.addingTimeInterval(6000))
        XCTAssertEqual(legacy.sampleIntervalSeconds, 200)
        for (start, expected) in [(120.0, true), (121.0, false)] {
            let samples = stride(from: start, through: 6000, by: 1).map { sample($0) }
            let full = metric(start, 6000, source: samples.count, maxInterval: 1)
            XCTAssertEqual(telemetry(samples, coverage: coverage(seconds: 6000, returned: samples.count,
                metrics: ["speedKph": full])).shouldPrefer(metric: "speedKph", over: legacy), expected,
                "a slow legacy cadence must not permit more than the gap threshold of boundary loss")
        }
    }

    func testMidDriveFragmentNeverReplacesCompleteLegacyHistory() {
        let legacy = stride(from: 0.0, through: 600, by: 10).map {
            DrivePoint(t: t0.addingTimeInterval($0), latitude: 1, longitude: 2, speedKph: 30,
                       powerKw: -5, elevationM: 100, batteryLevel: 70)
        }
        let samples = stride(from: 120.0, through: 480, by: 3).map { sample($0, speed: 90, power: -20) }
        let middle = metric(120, 480, source: samples.count, maxInterval: 3)
        let metadata = coverage(seconds: 600, returned: samples.count, metrics: [
            "latitude": middle, "longitude": middle, "speedKph": middle, "powerKw": middle,
            "elevationM": middle, "batteryLevel": middle,
        ])
        let snapshot = TripSnapshot(.init(summary: summary(), path: legacy, elevationGainM: nil,
                                          telemetry: telemetry(samples, coverage: metadata)),
                                    units: .init(distance: .kilometers, temperature: .celsius))
        XCTAssertFalse(snapshot.usesFleetTelemetry)
        XCTAssertFalse(snapshot.usesTelemetrySpeed)
        XCTAssertFalse(snapshot.usesTelemetryPower)
        XCTAssertFalse(snapshot.usesTelemetryElevation)
        XCTAssertEqual(snapshot.timeline.points.map(\.latitude), legacy.map(\.latitude))
        XCTAssertEqual(snapshot.speed.values.max(), 30)

        let emptyLegacy = RecordedMetricCoverage.dates([], sessionStart: t0, sessionEnd: t0.addingTimeInterval(600))
        XCTAssertFalse(telemetry(samples, coverage: metadata).shouldPrefer(metric: "speedKph", over: emptyLegacy),
                       "a primary series still requires near-whole-session coverage when legacy has no values")
    }

    func testKnownGapAndLowDensityDownsampleEachFallBackToLegacy() {
        let legacy = stride(from: 0.0, through: 600, by: 10).map {
            DrivePoint(t: t0.addingTimeInterval($0), latitude: 1, longitude: 2, speedKph: 30,
                       powerKw: -5, elevationM: 100, batteryLevel: 70)
        }
        let denseSamples = stride(from: 0.0, through: 600, by: 3).map { sample($0, speed: 80) }
        let gapped = metric(0, 600, source: denseSamples.count, maxInterval: 3, gaps: 1)
        let gappedCoverage = coverage(seconds: 600, returned: denseSamples.count, metrics: ["speedKph": gapped])
        var snapshot = TripSnapshot(.init(summary: summary(), path: legacy, elevationGainM: nil,
                                          telemetry: telemetry(denseSamples, coverage: gappedCoverage)),
                                    units: .init(distance: .kilometers, temperature: .celsius))
        XCTAssertFalse(snapshot.usesTelemetrySpeed, "a known gap is worse than the complete legacy series")

        let returned = stride(from: 0.0, through: 600, by: 60).map { sample($0, speed: 80) }
        let reduced = metric(0, 600, source: 201, returned: returned.count, maxInterval: 3,
                             returnedMaxInterval: 60, downsampled: true)
        let reducedCoverage = coverage(seconds: 600, returned: returned.count, metrics: ["speedKph": reduced], source: 201)
        snapshot = TripSnapshot(.init(summary: summary(), path: legacy, elevationGainM: nil,
                                      telemetry: telemetry(returned, coverage: reducedCoverage, downsampled: true)),
                                units: .init(distance: .kilometers, temperature: .celsius))
        XCTAssertFalse(snapshot.usesTelemetrySpeed, "source density cannot hide the lower density actually returned")
    }

    func testEqualSpanCountAndBetterMaxGapStillNeedsEqualCoveredDuration() {
        let legacySeconds: [Double] = [0, 100, 500, 600, 802, 852, 902, 952, 1000]
        let candidateSeconds: [Double] = [0, 100, 410, 510, 820, 870, 920, 960, 1000]
        let legacy = TripTimeline(path: legacySeconds.map {
            DrivePoint(t: t0.addingTimeInterval($0), latitude: 1, longitude: 2, speedKph: 50,
                       powerKw: nil, elevationM: nil, batteryLevel: nil)
        }, start: t0, end: t0.addingTimeInterval(1000))
        let legacyCoverage = RecordedMetricCoverage.values(in: legacy) { $0.speedKph }
        XCTAssertEqual(legacyCoverage.coveredSeconds, 398)

        let samples = candidateSeconds.map { sample($0, speed: 70, power: nil, elevation: nil, battery: nil) }
        let candidate = metric(0, 1000, source: samples.count, maxInterval: 310,
                               returnedMaxInterval: 310)
        let source = telemetry(samples, coverage: coverage(seconds: 1000, returned: samples.count,
                                                            metrics: ["speedKph": candidate]))
        XCTAssertFalse(source.shouldPrefer(metric: "speedKph", over: legacyCoverage),
                       "two shorter maximum gaps can still discard more total driven time")
    }

    func testWholeSessionDownsampleCanWinChartsButNotIntervalDerivedMetrics() {
        let legacy = stride(from: 0.0, through: 600, by: 3).map {
            DrivePoint(t: t0.addingTimeInterval($0), latitude: 1, longitude: 2, speedKph: 50,
                       powerKw: -6, elevationM: 100 - $0 / 60, batteryLevel: 70)
        }
        let samples = stride(from: 0.0, through: 600, by: 2).map {
            sample($0, latitude: 37.2 + $0 / 100_000, longitude: -122.1,
                   speed: Int($0 / 2).isMultiple(of: 2) ? 20 : 90,
                   power: Int($0 / 2).isMultiple(of: 2) ? -60 : 60,
                   elevation: 200 - $0 / 20, battery: nil)
        }
        let reduced = metric(0, 600, source: 601, returned: samples.count, maxInterval: 1,
                             returnedMaxInterval: 2, downsampled: true)
        let metadata = coverage(seconds: 600, returned: samples.count, metrics: [
            "latitude": reduced, "longitude": reduced, "speedKph": reduced,
            "powerKw": reduced, "elevationM": reduced,
        ], source: 601)
        let snapshot = TripSnapshot(.init(summary: summary(), path: legacy, elevationGainM: nil,
                                          telemetry: telemetry(samples, coverage: metadata, downsampled: true)),
                                    units: .init(distance: .kilometers, temperature: .celsius))
        XCTAssertTrue(snapshot.usesFleetTelemetry, "a whole-session returned route denser than legacy may replace it")
        XCTAssertTrue(snapshot.usesTelemetrySpeed)
        XCTAssertTrue(snapshot.usesTelemetryPower)
        XCTAssertTrue(snapshot.usesTelemetryElevation)
        XCTAssertEqual(snapshot.speed.values.max(), 90, "the denser returned series may drive the chart and max")
        XCTAssertEqual(snapshot.power.values.max(), 60)
        XCTAssertEqual(snapshot.regen, TripAnalysis.regen(TripTimeline(path: legacy, start: t0,
                                                                       end: t0.addingTimeInterval(600))),
                       "regen integration must retain full legacy power when telemetry was downsampled")
        XCTAssertEqual(snapshot.score, SmoothnessScore.evaluate(TripTimeline(path: legacy, start: t0,
                                                                              end: t0.addingTimeInterval(600))),
                       "smoothness must retain full legacy speed when telemetry was downsampled")
        XCTAssertEqual(snapshot.descent, TripAnalysis.descent(TripTimeline(path: legacy, start: t0,
                                                                           end: t0.addingTimeInterval(600))),
                       "descent must retain full legacy elevation when telemetry was downsampled")
    }

    func testSmoothnessKeepsPowerForFullTelemetryAndMixedSourceFallback() {
        let seconds = 20.0 * 60
        let legacy = stride(from: 0.0, through: seconds, by: 3).map {
            DrivePoint(t: t0.addingTimeInterval($0), latitude: 1, longitude: 2,
                       speedKph: 55 + sin($0 / 35), powerKw: 14 + sin($0 / 18),
                       elevationM: 100, batteryLevel: 70)
        }
        let telemetryRows = stride(from: 0.0, through: seconds, by: 2).map {
            sample($0, latitude: nil, longitude: nil, speed: 58 + sin($0 / 30),
                   power: 16 + sin($0 / 15), elevation: nil, battery: nil)
        }
        let full = metric(0, seconds, source: telemetryRows.count, maxInterval: 2)
        let fullCoverage = coverage(seconds: seconds, returned: telemetryRows.count,
                                    metrics: ["speedKph": full, "powerKw": full])
        let fullSnapshot = TripSnapshot(.init(summary: summary(seconds: seconds), path: legacy, elevationGainM: nil,
                                              telemetry: telemetry(telemetryRows, coverage: fullCoverage)),
                                        units: .init(distance: .kilometers, temperature: .celsius))
        XCTAssertTrue(fullSnapshot.usesTelemetrySpeed)
        XCTAssertTrue(fullSnapshot.usesTelemetryPower)
        guard case .score(let fullScore) = fullSnapshot.score else {
            return XCTFail("20 minutes of co-timed 2-second telemetry should produce a score")
        }
        XCTAssertTrue(fullScore.parts.contains { $0.name == "Power" },
                      "full selected telemetry must preserve Smoothness v1's Power component")

        let speedOnlyRows = telemetryRows.map { row -> FleetTelemetrySample in
            var row = row
            row.powerKw = nil
            return row
        }
        let speedOnlyCoverage = coverage(seconds: seconds, returned: speedOnlyRows.count,
                                         metrics: ["speedKph": full])
        let mixedSnapshot = TripSnapshot(.init(summary: summary(seconds: seconds), path: legacy, elevationGainM: nil,
                                               telemetry: telemetry(speedOnlyRows, coverage: speedOnlyCoverage)),
                                         units: .init(distance: .kilometers, temperature: .celsius))
        XCTAssertTrue(mixedSnapshot.usesTelemetrySpeed)
        XCTAssertFalse(mixedSnapshot.usesTelemetryPower)
        let legacyScore = SmoothnessScore.evaluate(TripTimeline(path: legacy, start: t0,
                                                                end: t0.addingTimeInterval(seconds)))
        XCTAssertEqual(mixedSnapshot.score, legacyScore,
                       "selected telemetry speed with uncalibrated power must keep the intact legacy scoring timeline")
        guard case .score(let mixedScore) = mixedSnapshot.score else { return XCTFail("legacy score should remain available") }
        XCTAssertTrue(mixedScore.parts.contains { $0.name == "Power" })
    }

    func testOffsetFullTelemetryCadencesKeepLegacyScorePower() {
        let seconds = 20.0 * 60
        let legacy = stride(from: 1.0, through: seconds - 1, by: 2).map {
            DrivePoint(t: t0.addingTimeInterval($0), latitude: 1, longitude: 2,
                       speedKph: 54 + sin($0 / 30), powerKw: 13 + sin($0 / 14),
                       elevationM: 100, batteryLevel: 70)
        }
        let telemetryRows = stride(from: 0.0, through: seconds, by: 1).map { second in
            let even = Int(second).isMultiple(of: 2)
            return sample(second, latitude: nil, longitude: nil,
                          speed: even ? 58 + sin(second / 28) : nil,
                          power: even ? nil : 15 + sin(second / 12), elevation: nil, battery: nil)
        }
        let speed = metric(0, seconds, source: 601, maxInterval: 2)
        let power = metric(1, seconds - 1, source: 600, maxInterval: 2)
        let metadata = coverage(seconds: seconds, returned: telemetryRows.count,
                                metrics: ["speedKph": speed, "powerKw": power])
        let snapshot = TripSnapshot(.init(summary: summary(seconds: seconds), path: legacy, elevationGainM: nil,
                                          telemetry: telemetry(telemetryRows, coverage: metadata)),
                                    units: .init(distance: .kilometers, temperature: .celsius))
        XCTAssertTrue(snapshot.usesTelemetrySpeed)
        XCTAssertTrue(snapshot.usesTelemetryPower)
        let legacyScore = SmoothnessScore.evaluate(TripTimeline(path: legacy, start: t0,
                                                                end: t0.addingTimeInterval(seconds)))
        XCTAssertEqual(snapshot.score, legacyScore,
                       "independently full but offset telemetry must not silently drop legacy scoring power")
        guard case .score(let score) = snapshot.score else { return XCTFail("legacy score should remain available") }
        XCTAssertTrue(score.parts.contains { $0.name == "Power" })
    }

    func testParkedCoTimedPowerCannotHideMovingOffsetPower() {
        let seconds = 20.0 * 60
        let legacy = stride(from: 0.0, through: seconds, by: 3).map { second in
            DrivePoint(t: t0.addingTimeInterval(second), latitude: 1, longitude: 2,
                       speedKph: 55 + sin(second / 30),
                       powerKw: second <= 600 ? 13 + sin(second / 14) : nil,
                       elevationM: 100, batteryLevel: 70)
        }
        let telemetryRows = stride(from: 0.0, through: seconds, by: 1).map { second in
            let even = Int(second).isMultiple(of: 2)
            let parked = second <= 720
            return sample(second, latitude: nil, longitude: nil,
                          speed: even ? (parked ? 0 : 58 + sin(second / 28)) : nil,
                          power: parked ? (even ? 8 : nil) : (even ? nil : 15 + sin(second / 12)),
                          elevation: nil, battery: nil)
        }
        let speed = metric(0, seconds, source: 601, maxInterval: 2)
        let power = metric(0, seconds - 1, source: 601, maxInterval: 2)
        let metadata = coverage(seconds: seconds, returned: telemetryRows.count,
                                metrics: ["speedKph": speed, "powerKw": power])
        let snapshot = TripSnapshot(.init(summary: summary(seconds: seconds), path: legacy, elevationGainM: nil,
                                          telemetry: telemetry(telemetryRows, coverage: metadata)),
                                    units: .init(distance: .kilometers, temperature: .celsius))
        XCTAssertTrue(snapshot.usesTelemetrySpeed)
        XCTAssertTrue(snapshot.usesTelemetryPower)
        let legacyScore = SmoothnessScore.evaluate(TripTimeline(path: legacy, start: t0,
                                                                end: t0.addingTimeInterval(seconds)))
        XCTAssertEqual(snapshot.score, legacyScore,
                       "parked co-timed power must not mask missing power on telemetry's moving score intervals")
        guard case .score(let score) = snapshot.score else { return XCTFail("legacy score should remain available") }
        XCTAssertTrue(score.parts.contains { $0.name == "Power" })
    }

    func testSpeedCanUseTelemetryWhileMissingPowerKeepsLegacyPowerAndRegen() {
        let legacy = stride(from: 0.0, through: 600, by: 10).map {
            DrivePoint(t: t0.addingTimeInterval($0), latitude: 1, longitude: 2, speedKph: 30,
                       powerKw: -6, elevationM: 100, batteryLevel: 70)
        }
        let samples = stride(from: 0.0, through: 600, by: 3).map {
            sample($0, latitude: nil, longitude: nil, speed: 70 + $0 / 30, power: nil, elevation: nil, battery: nil)
        }
        let speed = metric(0, 600, source: samples.count, maxInterval: 3)
        let metadata = coverage(seconds: 600, returned: samples.count, metrics: ["speedKph": speed, "powerKw": speed])
        let snapshot = TripSnapshot(.init(summary: summary(), path: legacy, elevationGainM: nil,
                                          telemetry: telemetry(samples, coverage: metadata)),
                                    units: .init(distance: .kilometers, temperature: .celsius))
        XCTAssertTrue(snapshot.usesTelemetrySpeed)
        XCTAssertFalse(snapshot.usesTelemetryPower,
                       "null payload power must keep TeslaMate power even if inconsistent metadata advertises coverage")
        XCTAssertEqual(snapshot.power.values, Array(repeating: -6, count: legacy.count))
        XCTAssertEqual(snapshot.regen.number ?? 0, 1, accuracy: 1e-9)
        let sharedSelection = TripSelection(minute: 5, timeline: snapshot.timeline)
        XCTAssertEqual(snapshot.speed.value(at: sharedSelection) ?? -1, 80, accuracy: 1e-9,
                       "shared scrub time must resolve against the speed source, not reuse the map row index")
    }

    func testTruncatedCoverageAndOldServerEnvelopeFailClosed() {
        let legacy = stride(from: 0.0, through: 600, by: 10).map {
            DrivePoint(t: t0.addingTimeInterval($0), latitude: 1, longitude: 2, speedKph: 30,
                       powerKw: -5, elevationM: 100, batteryLevel: 70)
        }
        let samples = stride(from: 0.0, through: 600, by: 3).map { sample($0, speed: 80) }
        let speed = metric(0, 600, source: samples.count, maxInterval: 3)
        let metadata = coverage(seconds: 600, returned: samples.count, metrics: ["speedKph": speed])
        let truncated = TripSnapshot(.init(summary: summary(), path: legacy, elevationGainM: nil,
                                           telemetry: telemetry(samples, coverage: metadata, truncated: true)),
                                     units: .init(distance: .kilometers, temperature: .celsius))
        let oldServer = TripSnapshot(.init(summary: summary(), path: legacy, elevationGainM: nil,
                                           telemetry: telemetry(samples)),
                                     units: .init(distance: .kilometers, temperature: .celsius))
        XCTAssertFalse(truncated.usesTelemetrySpeed)
        XCTAssertFalse(oldServer.usesTelemetrySpeed)
    }

    func testChargeSelectionAndTelemetryChartDomainUseWholeSession() {
        let legacyDates = stride(from: 0.0, through: 600, by: 60).map { t0.addingTimeInterval($0) }
        let battery = metric(0, 600, source: 21, maxInterval: 30)
        let returned = stride(from: 0.0, through: 600, by: 30).map { sample($0) }
        let source = telemetry(returned, coverage: coverage(seconds: 600, returned: returned.count,
            metrics: ["batteryLevel": battery]))
        let legacy = RecordedMetricCoverage.dates(legacyDates, sessionStart: t0, sessionEnd: t0.addingTimeInterval(600))
        XCTAssertTrue(source.shouldPrefer(metric: "batteryLevel", over: legacy))
        XCTAssertFalse(source.shouldPrefer(metric: "powerKw", over: legacy), "absent power stays on the charge samples")
        XCTAssertEqual(TelemetryChartDomain.range(sessionStart: t0, sessionEnd: t0.addingTimeInterval(600)),
                       t0...t0.addingTimeInterval(600))
        XCTAssertEqual(TelemetryChartSelection.date(minute: 4.5, sessionStart: t0), t0.addingTimeInterval(270))
        XCTAssertEqual(TelemetryChartSelection.minute(date: t0.addingTimeInterval(270), sessionStart: t0,
                                                       sessionEnd: t0.addingTimeInterval(600)), 4.5)
        XCTAssertEqual(TelemetryChartSelection.minute(date: t0.addingTimeInterval(900), sessionStart: t0,
                                                       sessionEnd: t0.addingTimeInterval(600)), 10,
                       "a chart drag outside the plot stays on the session clock")
    }
}
