import MapKit
import SwiftUI
import UIKit
import XCTest
@testable import Volta

final class RoutePaletteTests: XCTestCase {
    private typealias RGB = RoutePalette.RGB

    private func assertColor(_ c: RGB, _ hex: UInt32, file: StaticString = #filePath, line: UInt = #line) {
        let e = RGB(hex: hex)
        XCTAssertEqual(c.r, e.r, accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(c.g, e.g, accuracy: 1e-6, file: file, line: line)
        XCTAssertEqual(c.b, e.b, accuracy: 1e-6, file: file, line: line)
    }

    // MARK: Knots

    func testSpeedKnotsAreExact() {
        for (kph, hex) in [(0.0, 0x7C8CFF), (32.5, 0x4BA8FF), (65, 0x39D8EE), (97.5, 0x9AEAC8), (130, 0xF3F5B0)] as [(Double, UInt32)] {
            assertColor(RoutePalette.speed(kph: kph), hex)
        }
    }

    func testEfficiencyKnotsAreExactAgainstTheReference() {
        let rated = EfficiencyReference(ratedWhPerKm: 200)
        for (ratio, hex) in [(0.5, 0x5EEBC4), (0.75, 0x46B79C), (1.0, 0x868C96), (1.375, 0xE9A34B), (1.75, 0xFF7A45)] as [(Double, UInt32)] {
            assertColor(RoutePalette.efficiency(whPerKm: 200 * ratio, reference: rated), hex)
        }
        assertColor(RoutePalette.efficiency(whPerKm: -40, reference: rated), 0xB79CFF)
    }

    func testElevationAndDensityKnotsAreExact() {
        assertColor(RoutePalette.elevation(fraction: 0), 0x7C8CFF)
        assertColor(RoutePalette.elevation(fraction: 0.5), 0xB2AEFF)
        assertColor(RoutePalette.elevation(fraction: 1), 0xF3D9FF)
        for (count, hex) in [(1, 0x6698DD), (3, 0x56B6EC), (10, 0x77DBED), (30, 0xF1F8FF)] as [(Int, UInt32)] {
            assertColor(RoutePalette.density(count: count), hex)
        }
    }

    // MARK: Clamping

    func testValuesOutsideTheDomainClampToTheEnds() {
        assertColor(RoutePalette.speed(kph: -20), 0x7C8CFF)
        assertColor(RoutePalette.speed(kph: 250), 0xF3F5B0)
        assertColor(RoutePalette.speed(kph: .nan), 0x7C8CFF)
        let ref = EfficiencyReference(ratedWhPerKm: 150)
        assertColor(RoutePalette.efficiency(whPerKm: 10, reference: ref), 0x5EEBC4)
        assertColor(RoutePalette.efficiency(whPerKm: 900, reference: ref), 0xFF7A45)
        assertColor(RoutePalette.elevation(fraction: -1), 0x7C8CFF)
        assertColor(RoutePalette.elevation(fraction: 3), 0xF3D9FF)
        assertColor(RoutePalette.density(count: 0), 0x6698DD)
        assertColor(RoutePalette.density(count: 400), 0xF1F8FF)
    }

    // MARK: Ramps

    func testSequentialRampsRiseInLightness() {
        func assertRising(_ ramp: RoutePalette.Ramp, _ name: String) {
            let lo = ramp.domain.lowerBound, hi = ramp.domain.upperBound
            let samples = (0...40).map { ramp.rgb(lo + (hi - lo) * Double($0) / 40).lightness }
            for (a, b) in zip(samples, samples.dropFirst()) {
                XCTAssertLessThanOrEqual(a, b + 1e-9, "\(name) must not get darker along the ramp")
            }
            XCTAssertGreaterThan(samples.last! - samples.first!, 0.15, name)
        }
        assertRising(RoutePalette.speed, "speed")
        assertRising(RoutePalette.elevation, "elevation")
        assertRising(RoutePalette.density, "density")
    }

    func testInterpolationIsInOKLabBetweenKnots() {
        let mid = RoutePalette.speed(kph: 16.25)
        let a = RoutePalette.OKLab(RGB(hex: 0x7C8CFF)), b = RoutePalette.OKLab(RGB(hex: 0x4BA8FF)), m = RoutePalette.OKLab(mid)
        XCTAssertEqual(m.l, (a.l + b.l) / 2, accuracy: 1e-4)
        XCTAssertEqual(m.a, (a.a + b.a) / 2, accuracy: 1e-4)
        XCTAssertEqual(m.b, (a.b + b.b) / 2, accuracy: 1e-4)
    }

    func testOKLabRoundTrips() {
        for hex: UInt32 in [0x000000, 0xFFFFFF, 0x7C8CFF, 0xFF7A45, 0x101318] {
            assertColor(RoutePalette.OKLab(RGB(hex: hex)).rgb, hex)
        }
    }

    // MARK: Reference

    func testReferenceFallsBackWhenRatingIsUnknown() {
        XCTAssertFalse(EfficiencyReference(ratedWhPerKm: nil).isRated)
        XCTAssertEqual(EfficiencyReference(ratedWhPerKm: nil).whPerKm, 160)
        for bad in [0.0, -10, .nan, .infinity] {
            XCTAssertFalse(EfficiencyReference(ratedWhPerKm: bad).isRated, "\(bad)")
        }
        let rated = EfficiencyReference(ratedWhPerKm: 164)
        XCTAssertTrue(rated.isRated)
        XCTAssertEqual(rated.whPerKm, 164)
        // The fallback's midpoint is 160 Wh/km.
        assertColor(RoutePalette.efficiency(whPerKm: 160, reference: EfficiencyReference(ratedWhPerKm: nil)), 0x868C96)
    }

    func testSharedReferenceIsTheCommonRating() {
        func drive(_ id: Int, rated: Double?) -> DriveSummary {
            var d = DriveSummary(id: id, start: .init(timeIntervalSince1970: 0), end: nil, startAddress: nil, endAddress: nil,
                                 distanceKm: 1, durationMin: 1, startBatteryLevel: nil, endBatteryLevel: nil, energyUsedKwh: nil,
                                 efficiencyWhPerKm: nil, maxSpeedKph: nil, avgSpeedKph: nil, outsideTempAvgC: nil)
            d.ratedWhPerKm = rated
            return d
        }
        XCTAssertEqual(EfficiencyReference(drives: [drive(1, rated: 150), drive(2, rated: 150), drive(3, rated: 170)]).whPerKm, 150)
        XCTAssertFalse(EfficiencyReference(drives: [drive(1, rated: nil)]).isRated)
    }

    func testLegendsReadAsOneSentenceInTheUsersUnits() {
        let miles = UnitPreferences(distance: .miles)
        let speed = RouteLegendModel.speed(units: miles)
        XCTAssertEqual(speed.high, "80+ mph")
        let estimated = RouteLegendModel.efficiency(reference: EfficiencyReference(ratedWhPerKm: nil), units: miles)
        XCTAssertTrue(estimated.mid?.hasPrefix("~") == true, "an estimated reference is marked")
        XCTAssertTrue(estimated.sentence.contains("estimated"))
        XCTAssertEqual(estimated.low, "Efficient")
        XCTAssertEqual(estimated.high, "Thirsty")
        XCTAssertEqual(RouteLegendModel.density.low, "1 drive")
        XCTAssertEqual(RouteLegendModel.density.high, "30+ drives")
    }

    // MARK: Framing

    func testFittedRectPutsTheRouteInsideTheInsets() {
        let content = MKMapRect(x: 43_112_000, y: 104_057_000, width: 79_000, height: 56_000)
        let safe = EdgeInsets(top: 0, leading: 254, bottom: 64, trailing: 0)
        let insets = EdgeInsets(top: 140, leading: 48, bottom: 96, trailing: 48)
        for size in [CGSize(width: 375, height: 600), CGSize(width: 402, height: 900), CGSize(width: 375, height: 354),
                     CGSize(width: 466, height: 265)] {
            let rect = TripRoute.fitted(content, size: size, safe: safe, insets: insets)
            let a = try! XCTUnwrap(TripRoute.project(MKMapPoint(x: content.minX, y: content.minY), visible: rect, size: size, safe: safe))
            let b = try! XCTUnwrap(TripRoute.project(MKMapPoint(x: content.maxX, y: content.maxY), visible: rect, size: size, safe: safe))
            XCTAssertGreaterThanOrEqual(a.x, 48 - 0.01, "\(size)")
            XCTAssertLessThanOrEqual(b.x, size.width - 48 + 0.01, "\(size)")
            XCTAssertGreaterThanOrEqual(b.y - a.y, 0)
            // The bottom inset holds even on a short map; the top gives way first.
            XCTAssertLessThanOrEqual(b.y, size.height - 96 + 0.01, "\(size)")
            XCTAssertGreaterThanOrEqual(a.y, 24 - 0.01, "\(size)")
            // Fills the wanted area in at least one direction.
            XCTAssertTrue(abs(a.x - 48) < 0.5 || abs(b.y - (size.height - 96)) < 0.5 || abs(a.y - 140) < 0.5, "\(size)")
        }
    }

    // MARK: Score

    func testScoreBands() {
        XCTAssertEqual(DriveScoreTint.color(80), DriveScoreTint.good)
        XCTAssertEqual(DriveScoreTint.color(79), DriveScoreTint.fair)
        XCTAssertEqual(DriveScoreTint.color(60), DriveScoreTint.fair)
        XCTAssertEqual(DriveScoreTint.color(59), DriveScoreTint.poor)
        XCTAssertEqual(DriveScoreBand.tint(92), TripScoreStyle.tint(92), "one function for every ring")
    }

    // MARK: Charge state glyphs

    @MainActor
    func testEveryChargeStateSymbolResolves() {
        let states: [ChargingState?] = [.charging, .complete, .stopped, .disconnected, nil]
        for state in states {
            let symbol = StateDisplay.charging(state).symbol
            XCTAssertNotNil(UIImage(systemName: symbol), "\(String(describing: state)): \(symbol)")
        }
        XCTAssertEqual(Set(states.map { StateDisplay.charging($0).symbol }).count, states.count, "each state has its own glyph")
        for kind in [ChargerKind.home, .publicAC, .supercharger, .dcFast, .unknown] {
            XCTAssertNotNil(UIImage(systemName: kind.systemImage), "\(kind)")
        }
    }
}

final class RouteDensityTests: XCTestCase {
    /// A straight drive between two Bay Area points, sampled every `step` of the way.
    private func drive(_ id: Int, from a: (Double, Double), to b: (Double, Double), samples: Int = 30, ratio: Double? = nil) -> RouteDensity.Drive {
        let run = (0...samples).map { n -> CLLocationCoordinate2D in
            let t = Double(n) / Double(samples)
            return CLLocationCoordinate2D(latitude: a.0 + (b.0 - a.0) * t, longitude: a.1 + (b.1 - a.1) * t)
        }
        return RouteDensity.Drive(id: id, runs: [run], ratio: ratio)
    }

    private let west = (37.4012, -122.1103), east = (37.3958, -122.0791)

    func testTwoDrivesOverOneRoadCountTwo() {
        let layer = RouteDensity.build([drive(1, from: west, to: east), drive(2, from: east, to: west)])
        XCTAssertFalse(layer.counts.isEmpty)
        XCTAssertEqual(layer.maxCount, 2)
        XCTAssertTrue(layer.counts.values.allSatisfy { $0 == 2 }, "the same road is covered by both drives everywhere")
        XCTAssertTrue(layer.strokes.allSatisfy { $0.count == 2 })
    }

    func testOneDrivePassingTwiceCountsOne() {
        var there = drive(1, from: west, to: east)
        let back = drive(1, from: east, to: west)
        there.runs = [there.runs[0] + back.runs[0].dropFirst()]
        let layer = RouteDensity.build([there])
        XCTAssertEqual(layer.maxCount, 1)
        XCTAssertTrue(layer.counts.values.allSatisfy { $0 == 1 })
        // Also when the second pass is its own run (after a recording gap).
        there.runs = [drive(1, from: west, to: east).runs[0], back.runs[0]]
        XCTAssertEqual(RouteDensity.build([there]).maxCount, 1)
    }

    func testResamplingADriveDoesNotChangeCounts() {
        let other = drive(2, from: (37.3990, -122.1000), to: (37.4100, -122.0900))
        let coarse = RouteDensity.build([drive(1, from: west, to: east, samples: 12), other])
        let fine = RouteDensity.build([drive(1, from: west, to: east, samples: 97), other])
        XCTAssertEqual(coarse.counts, fine.counts)
    }

    func testCountsAreDeterministicWhateverTheInputOrder() {
        let drives = [drive(3, from: west, to: east), drive(1, from: east, to: (37.41, -122.07)), drive(2, from: west, to: (37.39, -122.12))]
        let a = RouteDensity.build(drives), b = RouteDensity.build(drives.reversed())
        XCTAssertEqual(a.counts, b.counts)
        XCTAssertEqual(a.strokes, b.strokes)
        XCTAssertEqual(a.strokes.map(\.count), a.strokes.map(\.count).sorted(), "busiest strokes are drawn last")
    }

    func testEfficiencyIsDistanceWeightedPerCell() {
        let layer = RouteDensity.build([drive(1, from: west, to: east, ratio: 0.8), drive(2, from: west, to: east, ratio: 1.2),
                                        drive(3, from: west, to: east)])
        for stroke in layer.strokes {
            XCTAssertEqual(try XCTUnwrap(stroke.ratio), 1.0, accuracy: 1e-9, "a drive without efficiency doesn't weigh in")
        }
    }

    func testThinningKeepsRunEnds() {
        let long = drive(1, from: west, to: east, samples: 2_000).runs
        let thinned = RouteDensity.thin(long, to: RouteDensity.maxPointsPerDrive)
        XCTAssertLessThanOrEqual(thinned[0].count, RouteDensity.maxPointsPerDrive)
        XCTAssertEqual(thinned[0].first?.latitude, long[0].first?.latitude)
        XCTAssertEqual(thinned[0].last?.longitude, long[0].last?.longitude)
    }
}
