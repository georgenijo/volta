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
        for (ratio, hex) in [(0.5, 0x5EEBC4), (0.75, 0x46B79C), (1.0, 0xA8B0BB), (1.375, 0xE9A34B), (1.75, 0xFF7A45)] as [(Double, UInt32)] {
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
        assertColor(RoutePalette.efficiency(whPerKm: 160, reference: EfficiencyReference(ratedWhPerKm: nil)), 0xA8B0BB)
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
        XCTAssertEqual(speed.mid, "40 mph")
        let estimated = RouteLegendModel.efficiency(reference: EfficiencyReference(ratedWhPerKm: nil), units: miles)
        XCTAssertEqual(estimated.mid, "Est. 257 Wh/mi", "an estimated reference is labelled as one")
        XCTAssertTrue(estimated.sentence.contains("estimated"))
        XCTAssertEqual(estimated.low, "Efficient")
        XCTAssertEqual(estimated.high, "Thirsty")
        let rated = RouteLegendModel.efficiency(reference: EfficiencyReference(ratedWhPerKm: 164), units: miles)
        XCTAssertEqual(rated.mid, "Rated 264 Wh/mi")
        XCTAssertEqual(RouteLegendModel.efficiency(reference: EfficiencyReference(ratedWhPerKm: 164),
                                                   units: UnitPreferences(distance: .kilometers)).mid, "Rated 164 Wh/km")
        let density = RouteLegendModel.density
        XCTAssertEqual(density.marks?.map(\.label), ["1", "3", "10", "30+"])
        XCTAssertNil(density.tick, "fixed labels, no floating tick")
        XCTAssertEqual(density.marks?[2].position ?? 0, 1 / log10(30), accuracy: 1e-12)
        XCTAssertTrue(density.sentence.contains("1 drive to 30 or more"))
    }

    // MARK: Framing

    func testFittedRectPutsTheRouteInsideTheInsets() {
        let content = MKMapRect(x: 43_112_000, y: 104_057_000, width: 79_000, height: 56_000)
        let safe = EdgeInsets(top: 0, leading: 0, bottom: 64, trailing: 0)
        // The trip map's clearances plus marker reach: iPhone (the page safe area, toolbar and
        // status bar) and iPhone Duo (bar in the side strip); bottom is fade +
        // attribution + 24.
        let phone = EdgeInsets(top: 104 + 24 + 8, leading: 32, bottom: 64 + 24 + 24 + 8, trailing: 32)
        let duo = EdgeInsets(top: 32, leading: 32, bottom: 64 + 24 + 24 + 8, trailing: 32)
        let cases: [(CGSize, EdgeInsets)] = [(CGSize(width: 402, height: 900), phone), (CGSize(width: 375, height: 600), phone),
                                             (CGSize(width: 375, height: 350), phone),
                                             (CGSize(width: 466, height: 265), duo), (CGSize(width: 466, height: 224), duo)]
        for (size, insets) in cases {
            let rect = TripRoute.fitted(content, size: size, safe: safe, insets: insets)
            let a = try! XCTUnwrap(TripRoute.project(MKMapPoint(x: content.minX, y: content.minY), visible: rect, size: size, safe: safe))
            let b = try! XCTUnwrap(TripRoute.project(MKMapPoint(x: content.maxX, y: content.maxY), visible: rect, size: size, safe: safe))
            XCTAssertGreaterThanOrEqual(a.x, 32 - 0.01, "\(size)")
            XCTAssertLessThanOrEqual(b.x, size.width - 32 + 0.01, "\(size)")
            XCTAssertGreaterThan(b.y - a.y, 0)
            // Clear of the attribution and fade, and of the top controls.
            XCTAssertLessThanOrEqual(b.y, size.height - insets.bottom + 0.01, "\(size)")
            XCTAssertGreaterThanOrEqual(a.y, min(insets.top, 24) - 0.01, "\(size)")
            // The route fills the map: it reaches the wanted area's edge in one direction.
            let filled = abs(a.x - insets.leading) < 0.5 || abs(b.y - (size.height - insets.bottom)) < 0.5
            XCTAssertTrue(filled, "\(size)")
        }
        // 13 mini: the toolbar's clearance holds.
        let mini = CGSize(width: 375, height: 350)
        let miniRect = TripRoute.fitted(content, size: mini, safe: safe, insets: phone)
        let miniTop = try! XCTUnwrap(TripRoute.project(MKMapPoint(x: content.minX, y: content.minY), visible: miniRect, size: mini, safe: safe))
        XCTAssertGreaterThanOrEqual(miniTop.y, phone.top - 0.01)
    }

    @MainActor
    func testTheAllDrivesMapIsFramedToItsRoutes() {
        // The demo drives' routes, as the Drives hero and heatmap load them.
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let runs = DemoRoutes.all.indices.map { id in
            DemoRoutes.points(for: id, start: start, durationMin: 30).map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
        }
        let content = try! XCTUnwrap(voltaBounds(runs.joined().map(MKMapPoint.init)))
        let safe = DrivesRouteMap.mapSafe()
        // 13 mini hero (first layout without its top inset, then the real
        // one), iPhone Duo hero, heatmap.
        let cases: [(CGSize, CGFloat, Bool)] = [(CGSize(width: 375, height: 150), 0, true), (CGSize(width: 375, height: 254), 104, true),
                                                (CGSize(width: 419, height: 232), 122, true), (CGSize(width: 375, height: 320), 0, false)]
        for (size, top, hero) in cases {
            let rect = try! XCTUnwrap(DrivesRouteMap.camera(runs, size: size, topInset: top, fullBleed: hero))
            let a = try! XCTUnwrap(TripRoute.project(MKMapPoint(x: content.minX, y: content.minY), visible: rect, size: size, safe: safe))
            let b = try! XCTUnwrap(TripRoute.project(MKMapPoint(x: content.maxX, y: content.maxY), visible: rect, size: size, safe: safe))
            let clear = DrivesRouteMap.clearance(topInset: top, fullBleed: hero)
            let insetTop = clear.top, insetBottom = clear.bottom
            XCTAssertEqual(insetTop, top + (hero ? 12 : 24))
            XCTAssertGreaterThanOrEqual(insetBottom, DrivesRouteMap.fade + 24)
            // Inside the clearances: under the bars, above the attribution.
            XCTAssertGreaterThanOrEqual(a.y, insetTop - 0.01, "\(size)")
            XCTAssertLessThanOrEqual(b.y, size.height - insetBottom + 0.01, "\(size)")
            XCTAssertGreaterThanOrEqual(a.x, 32 - 0.01, "\(size)")
            XCTAssertLessThanOrEqual(b.x, size.width - 32 + 0.01, "\(size)")
            // And filling them one way: the camera never shows a region wider
            // than the routes plus those margins (no fallback to the Bay Area).
            let fillsHeight = abs((b.y - a.y) - (size.height - insetTop - insetBottom)) < 0.5
            let fillsWidth = abs((b.x - a.x) - (size.width - 64)) < 0.5
            XCTAssertTrue(fillsHeight || fillsWidth, "\(size)")
        }
    }

    func testAnEqualFitIsStillReapplied() {
        let rect = MKMapRect(x: 43_000_000, y: 104_000_000, width: 400_000, height: 100_000)
        let again = MapCameraPosition.fitting(rect, replacing: .rect(rect))
        let moved = try! XCTUnwrap(again.rect)
        XCTAssertFalse(MKMapRectEqualToRect(moved, rect), "a new value, so SwiftUI hands it to MapKit")
        XCTAssertEqual(moved.origin.x, rect.origin.x, accuracy: 0.01)
        XCTAssertEqual(moved.size.width, rect.size.width)
        let other = MKMapRect(x: 1, y: 2, width: 3, height: 4)
        XCTAssertTrue(MKMapRectEqualToRect(MapCameraPosition.fitting(other, replacing: .rect(rect)).rect!, other))
    }

    func testTinyFramesFallBackInsteadOfANegativeRect() {
        let content = MKMapRect(x: 43_112_000, y: 104_057_000, width: 79_000, height: 56_000)
        let insets = EdgeInsets(top: 126, leading: 32, bottom: 120, trailing: 32)
        // 100 pt tall with a 64 pt fade: margins can't fit.
        let small = TripRoute.fitted(content, size: CGSize(width: 300, height: 100), safe: EdgeInsets(top: 0, leading: 0, bottom: 64, trailing: 0), insets: insets)
        XCTAssertTrue(small.width > 0 && small.height > 0 && small.width.isFinite && small.height.isFinite)
        let a = try! XCTUnwrap(TripRoute.project(MKMapPoint(x: content.minX, y: content.minY), visible: small,
                                                 size: CGSize(width: 300, height: 100), safe: EdgeInsets(top: 0, leading: 0, bottom: 64, trailing: 0)))
        XCTAssertGreaterThanOrEqual(a.y, -0.01)
        // The fade alone is taller than the map: hand MapKit the bare content.
        let none = TripRoute.fitted(content, size: CGSize(width: 300, height: 50), safe: EdgeInsets(top: 0, leading: 0, bottom: 64, trailing: 0), insets: insets)
        XCTAssertTrue(MKMapRectEqualToRect(none, content))
        XCTAssertTrue(MKMapRectEqualToRect(TripRoute.fitted(content, size: .zero, safe: EdgeInsets(), insets: insets), content))
    }

    func testBucketKeyQuantisesChannels() {
        let a = RoutePalette.RGB(r: 1, g: 0.5, b: 0)
        XCTAssertEqual(a.bucketKey, (63 << 12) | (32 << 6) | 0)
        XCTAssertEqual(RoutePalette.RGB(r: 0.999, g: 0.501, b: 0.001).bucketKey, a.bucketKey)
    }

    func testEfficiencyLegendSaysTheColourIsAveraged() {
        let miles = UnitPreferences(distance: .miles), km = UnitPreferences(distance: .kilometers)
        let legend = RouteLegendModel.efficiency(reference: EfficiencyReference(ratedWhPerKm: 160), units: miles,
                                                 averagedOverKm: EfficiencyWindow.minimumKm)
        XCTAssertEqual(legend.note, "Averaged over 0.25 mi")
        XCTAssertTrue(legend.sentence.contains("averaged over 0.25 miles"), legend.sentence)
        XCTAssertNil(RouteLegendModel.efficiency(reference: EfficiencyReference(ratedWhPerKm: 160), units: miles).note)
        // The trip's own window, in the user's units.
        let style = TripRouteStyle(mode: .efficiency, reference: EfficiencyReference(ratedWhPerKm: 160), windowKm: 16.9 / 12)
        XCTAssertEqual(style.legend(units: miles)?.note, "Averaged over 0.9 mi")
        XCTAssertEqual(style.legend(units: km)?.note, "Averaged over 1.4 km")
        XCTAssertEqual(RouteLegendModel.windowText(0.4, units: km).short, "400 m")
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

    func testAPlaceIsTheKindItsSessionsAgreeOn() {
        func session(_ id: Int, fast: Bool, brand: String?) -> ChargeSummary {
            var c = ChargeSummary(id: id, start: .init(timeIntervalSince1970: 0), end: nil, address: nil, placeName: "Mountain View Supercharger",
                                  energyAddedKwh: 30, energyUsedKwh: nil, startBatteryLevel: nil, endBatteryLevel: nil,
                                  durationMin: 25, maxPowerKw: nil, fastCharger: fast, cost: nil, currency: nil, outsideTempAvgC: nil)
            c.fastChargerBrand = brand
            return c
        }
        XCTAssertEqual(ChargerKind(agreeing: [session(1, fast: true, brand: "Tesla"), session(2, fast: true, brand: "Tesla")]), .supercharger)
        XCTAssertEqual(ChargerKind(agreeing: [session(1, fast: true, brand: "Tesla"), session(2, fast: false, brand: nil)]), .unknown,
                       "conflicting evidence is neutral")
        XCTAssertEqual(ChargerKind(agreeing: [ChargeSummary]()), .unknown, "no sessions: no guessing from the name")
        XCTAssertEqual(ChargerKind(agreeing: [session(1, fast: true, brand: "Tesla"), session(2, fast: true, brand: nil)]), .supercharger,
                       "an unrecorded network is missing evidence, not a conflict")
        XCTAssertEqual(ChargerKind(agreeing: [session(1, fast: true, brand: nil)]), .dcFast)
        XCTAssertEqual(ChargerKind(agreeing: [session(1, fast: true, brand: "Tesla"), session(2, fast: true, brand: "Electrify America")]), .unknown)
        XCTAssertEqual(ChargerKind(agreeing: [session(1, fast: false, brand: nil), session(2, fast: true, brand: nil)]), .unknown)
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

    private func layerOf(_ drives: [RouteDensity.Drive]) -> RouteDensity.Layer {
        RouteDensity.build(drives, isCancelled: { false })!
    }

    func testASegmentAcrossTheAntimeridianTakesTheShortWay() {
        let hop = RouteDensity.Drive(id: 1, runs: [[CLLocationCoordinate2D(latitude: 0, longitude: 179.999),
                                                    CLLocationCoordinate2D(latitude: 0, longitude: -179.999)]], ratio: nil)
        var visits = 0
        RouteDensity.traverse(MKMapPoint(hop.runs[0][0]), MKMapPoint(hop.runs[0][1])) { _, _, _, _ in visits += 1 }
        XCTAssertLessThan(visits, 10, "about 220 m of road, not the whole world")
        let layer = layerOf([hop])
        XCTAssertLessThan(layer.counts.count, 10)
        // Cell x wraps: both sides of the line are cells inside the world.
        XCTAssertTrue(layer.counts.keys.allSatisfy { (0..<RouteDensity.cellsAcross).contains($0.x) })
        XCTAssertTrue(layer.counts.keys.contains { $0.x == 0 } && layer.counts.keys.contains { $0.x == RouteDensity.cellsAcross - 1 })
        // A drive crossing it the other way counts on the same cells.
        let back = RouteDensity.Drive(id: 2, runs: [hop.runs[0].reversed()], ratio: nil)
        XCTAssertEqual(layerOf([hop, back]).maxCount, 2)
        XCTAssertTrue(layer.strokes.allSatisfy { stroke in
            zip(stroke.points, stroke.points.dropFirst()).allSatisfy { abs($0.x - $1.x) < RouteDensity.worldWidth / 2 }
        }, "no stroke draws back across the world")
    }

    func testCellsDoNotDependOnTheLoadedSelection() {
        let nearby = drive(1, from: west, to: east)
        let far = drive(0, from: (61.2, -149.9), to: (61.21, -149.8))   // a lower id, far north
        let alone = layerOf([nearby]).counts.keys
        let withFar = Set(layerOf([nearby, far]).counts.keys)
        XCTAssertTrue(alone.allSatisfy { withFar.contains($0) }, "an older page elsewhere doesn't redefine the cells")
        XCTAssertEqual(RouteDensity.cellMeters(latitude: 0), 38.0, accuracy: 0.1)
        XCTAssertEqual(RouteDensity.cellMeters(latitude: 37.4), 30.4, accuracy: 0.2)
    }

    func testACancelledBuildStopsEarly() {
        let many = (1...50).map { drive($0, from: west, to: east) }
        var checks = 0
        let result = RouteDensity.build(many) { checks += 1; return checks > 2 }
        XCTAssertNil(result)
        XCTAssertEqual(checks, 3, "stops at the first check after cancelling, not after every drive")
        XCTAssertLessThan(checks, many.count, "returned before visiting every drive")
    }

    @MainActor
    func testNetRegenerationIsRegenOnTheHeatmap() {
        let layer = layerOf([drive(1, from: west, to: east, ratio: -0.3)])
        let stroke = try! XCTUnwrap(layer.strokes.first)
        XCTAssertLessThan(stroke.ratio!, 0)
        // Through the function the heatmap's renderer colours each stroke with.
        let reference = EfficiencyReference(ratedWhPerKm: 160)
        XCTAssertEqual(DrivesRouteMap.strokeColor(stroke, coloring: .efficiency(reference)), RoutePalette.regen)
        var neutral = stroke; neutral.ratio = 1
        XCTAssertEqual(DrivesRouteMap.strokeColor(neutral, coloring: .efficiency(reference)), RoutePalette.RGB(hex: 0xA8B0BB))
        XCTAssertEqual(DrivesRouteMap.strokeColor(stroke, coloring: .density), RoutePalette.density(count: stroke.count))
    }

    private func summary(_ id: Int, route: [DriveRoutePoint]) -> DriveSummary {
        var d = DriveSummary(id: id, start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 600), startAddress: nil,
                             endAddress: nil, distanceKm: 5, durationMin: 10, startBatteryLevel: nil, endBatteryLevel: nil,
                             energyUsedKwh: 1, efficiencyWhPerKm: 160, maxSpeedKph: nil, avgSpeedKph: nil, outsideTempAvgC: nil)
        d.route = route
        return d
    }

    @MainActor
    func testTheHeatmapLayerKeyCoversRouteContents() {
        let route = (0..<20).map { i in
            DriveRoutePoint(t: Date(timeIntervalSince1970: Double(i) * 30), latitude: 37.40 + Double(i) * 0.001, longitude: -122.1)
        }
        var moved = route; moved[10].latitude += 0.0005          // one interior coordinate corrected
        var broken = route; broken[10].routeBreakBefore = true   // one break flag
        let reference = EfficiencyReference(ratedWhPerKm: 160)
        func key(_ r: [DriveRoutePoint]) -> DrivesRouteMap.LayerKey {
            DrivesRouteMap.LayerKey.make([summary(1, route: r)], coloring: .density, reference: reference, digests: RouteDigests())
        }
        XCTAssertEqual(key(route), key(route))
        XCTAssertNotEqual(key(route), key(moved))
        XCTAssertNotEqual(key(route), key(broken))
        // A cached digest is replaced when the drive's route changes.
        let digests = RouteDigests()
        let first = digests.digest(summary(1, route: route))
        XCTAssertNotEqual(digests.digest(summary(1, route: moved)), first)
        XCTAssertEqual(digests.digest(summary(1, route: route)), first)
    }

    func testTwoDrivesOverOneRoadCountTwo() {
        let layer = layerOf([drive(1, from: west, to: east), drive(2, from: east, to: west)])
        XCTAssertFalse(layer.counts.isEmpty)
        XCTAssertEqual(layer.maxCount, 2)
        XCTAssertTrue(layer.counts.values.allSatisfy { $0 == 2 }, "the same road is covered by both drives everywhere")
        XCTAssertTrue(layer.strokes.allSatisfy { $0.count == 2 })
    }

    func testOneDrivePassingTwiceCountsOne() {
        var there = drive(1, from: west, to: east)
        let back = drive(1, from: east, to: west)
        there.runs = [there.runs[0] + back.runs[0].dropFirst()]
        let layer = layerOf([there])
        XCTAssertEqual(layer.maxCount, 1)
        XCTAssertTrue(layer.counts.values.allSatisfy { $0 == 1 })
        // Also when the second pass is its own run (after a recording gap).
        there.runs = [drive(1, from: west, to: east).runs[0], back.runs[0]]
        XCTAssertEqual(layerOf([there]).maxCount, 1)
    }

    func testResamplingADriveDoesNotChangeCounts() {
        let other = drive(2, from: (37.3990, -122.1000), to: (37.4100, -122.0900))
        let coarse = layerOf([drive(1, from: west, to: east, samples: 12), other])
        let fine = layerOf([drive(1, from: west, to: east, samples: 97), other])
        XCTAssertEqual(coarse.counts, fine.counts)
    }

    func testCountsAreDeterministicWhateverTheInputOrder() {
        let drives = [drive(3, from: west, to: east), drive(1, from: east, to: (37.41, -122.07)), drive(2, from: west, to: (37.39, -122.12))]
        let a = layerOf(drives), b = layerOf(drives.reversed())
        XCTAssertEqual(a.counts, b.counts)
        XCTAssertEqual(a.strokes, b.strokes)
        XCTAssertEqual(a.strokes.map(\.count), a.strokes.map(\.count).sorted(), "busiest strokes are drawn last")
    }

    func testEfficiencyIsDistanceWeightedPerCell() {
        let layer = layerOf([drive(1, from: west, to: east, ratio: 0.8), drive(2, from: west, to: east, ratio: 1.2),
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

final class EfficiencyWindowTests: XCTestCase {
    private typealias Interval = EfficiencyWindow.Interval
    private let reference = EfficiencyReference(ratedWhPerKm: 160)

    func testWindowScalesWithTheTrip() {
        XCTAssertEqual(EfficiencyWindow.windowKm(forTripKm: 2), 0.4, "a short trip gets 400 m")
        XCTAssertEqual(EfficiencyWindow.windowKm(forTripKm: 16.9), 16.9 / 12, accuracy: 1e-12, "about 1.4 km")
        XCTAssertEqual(EfficiencyWindow.windowKm(forTripKm: 300), 2, "a very long trip caps at 2 km")
        XCTAssertEqual(EfficiencyWindow.windowKm(forTripKm: .nan), 0.4)
    }

    @MainActor
    func testATripRouteUsesItsOwnWindow() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        // About 12 km along a meridian: 25 m every 2 s.
        let rows = stride(from: 0.0, through: 960, by: 2).map { t in
            DrivePoint(t: t0.addingTimeInterval(t), latitude: 37.0 + t / 2 * 0.000225, longitude: -122.1, speedKph: 45,
                       powerKw: 8, elevationM: 30, batteryLevel: 60)
        }
        let route = TripRoute(TripTimeline(path: rows), mode: .efficiency)
        let km = TripRoute.recordedKm(TripTimeline(path: rows))
        XCTAssertEqual(km, 12, accuracy: 0.3)
        XCTAssertEqual(route.windowKm, km / 12, accuracy: 1e-9, "no drive distance: the positions' length")
        // The drive's own distance (18 km, not the 12 km of positions) sets it.
        let supplied = TripRoute(TripTimeline(path: rows), mode: .efficiency, tripKm: 18)
        XCTAssertEqual(supplied.windowKm, 1.5, accuracy: 1e-9)
        XCTAssertEqual(TripRouteStyle(mode: .efficiency, reference: reference, windowKm: supplied.windowKm)
            .legend(units: UnitPreferences(distance: .kilometers))?.note, "Averaged over 1.5 km")
    }

    @MainActor
    func testElevationRangeComesFromTheRecordedSamples() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = [0.0, 100].enumerated().map { n, e in
            DrivePoint(t: t0.addingTimeInterval(Double(n) * 2), latitude: 37.4 + Double(n) * 0.0002, longitude: -122.1,
                       speedKph: 40, powerKw: 8, elevationM: e, batteryLevel: 60)
        }
        let route = TripRoute(TripTimeline(path: rows), mode: .elevation)
        XCTAssertEqual(route.valueRange, 0...100, "not the one piece's average, 50...50")
        let legend = TripRouteStyle(mode: .elevation, valueRange: route.valueRange, reference: reference)
            .legend(units: UnitPreferences(distance: .kilometers))
        XCTAssertEqual(legend?.low, "0 m")
        XCTAssertEqual(legend?.high, "100 m")
        // Flat: the guard keeps one colour.
        let flat = TripRouteStyle(mode: .elevation, valueRange: 30...30, reference: reference)
        XCTAssertEqual(flat.rgb(30), RoutePalette.elevation(fraction: 0))
    }

    /// `count` intervals of `metres` each at `whPerKm`.
    private func steady(_ count: Int, metres: Double = 14, whPerKm: Double = 160) -> [Interval] {
        Array(repeating: Interval(distanceKm: metres / 1000, energyKwh: metres / 1000 * whPerKm / 1000), count: count)
    }

    private func colour(_ whPerKm: Double?) -> Int {
        RoutePalette.efficiency(whPerKm: whPerKm!, reference: reference).bucketKey
    }

    func testConstantConsumptionIsOneColour() {
        let values = EfficiencyWindow.smoothed(steady(200))
        XCTAssertEqual(values.count, 200)
        for v in values { XCTAssertEqual(v!, 160, accuracy: 1e-6) }
        XCTAssertEqual(Set(values.map(colour)).count, 1)
    }

    func testNoiseAroundAConstantMeanIsOneColour() {
        // Samples alternate 100 and 220 Wh/km around a 160 mean: unsmoothed,
        // the line would flicker between green and orange.
        let run = (0..<200).map { i in
            Interval(distanceKm: 0.014, energyKwh: 0.014 * (i.isMultiple(of: 2) ? 100 : 220) / 1000)
        }
        let raw = run.map { $0.energyKwh / $0.distanceKm * 1000 }
        XCTAssertGreaterThan(Set(raw.map(colour)).count, 1, "the raw samples are confetti")
        let values = EfficiencyWindow.smoothed(run)
        // Past the ends, where the window has shrunk to a few samples, every
        // value sits within 3 % of the mean (raw: ±37 %), one colour to the eye.
        for v in values[20..<180] { XCTAssertEqual(v! / 160, 1, accuracy: 0.03) }
        let steady = RoutePalette.OKLab(RoutePalette.efficiency(whPerKm: 160, reference: reference))
        for v in values[20..<180] {
            let c = RoutePalette.OKLab(RoutePalette.efficiency(whPerKm: v!, reference: reference))
            XCTAssertLessThan(hypot(hypot(c.l - steady.l, c.a - steady.a), c.b - steady.b), 0.02)
        }
    }

    func testOneSpikeInASteadyStretchDoesNotFlipTheColour() {
        // One sample at 40 kW among 8 kW samples, 1 s apart at 50 km/h: the two
        // intervals touching it read 480 Wh/km on their own (thirsty orange).
        var run = steady(200)
        let spike = Interval(distanceKm: 50.0 / 3600, energyKwh: 24.0 / 3600)
        run[100] = spike; run[101] = spike
        XCTAssertGreaterThan(spike.energyKwh / spike.distanceKm * 1000 / 160, 1.375, "raw interval is thirsty")
        let values = EfficiencyWindow.smoothed(run)
        let steadyColour = colour(160)
        for i in 60...140 {
            let ratio = values[i]! / 160
            XCTAssertLessThan(ratio, 1.2, "index \(i)")
            // Still on the neutral side of the ramp, nowhere near orange.
            XCTAssertLessThan(abs(ratio - 1), 0.2)
        }
        XCTAssertEqual(colour(values[20]), steadyColour)
        XCTAssertEqual(colour(values[180]), steadyColour)
    }

    func testRegenIsDecidedOnTheWindowedValue() {
        var run = steady(100, whPerKm: -60)
        run[50] = Interval(distanceKm: 0.014, energyKwh: 0.014 * 0.4)   // one thirsty interval
        let values = EfficiencyWindow.smoothed(run)
        XCTAssertGreaterThan(run[50].energyKwh, 0)
        for i in 30...70 { XCTAssertLessThan(values[i]!, 0, "index \(i)") }
        XCTAssertEqual(RoutePalette.efficiency(whPerKm: values[50]!, reference: reference), RoutePalette.regen)
    }

    @MainActor
    func testARegenStretchShorterThanADrawingPieceKeepsItsColour() {
        // 60 km at 72 km/h, a sample every 10 s (200 m), 300 Wh/km, with a
        // 3 km descent at -60 Wh/km. Eight drawing pieces of 7.5 km each:
        // the descent is shorter than its piece, which averaged as a whole
        // would read about +160 Wh/km and show no regen.
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = (0...300).map { n -> DrivePoint in
            let regen = (150...165).contains(n)
            return DrivePoint(t: t0.addingTimeInterval(Double(n) * 10), latitude: 37.0 + Double(n) * 0.0018, longitude: -122.1,
                              speedKph: 72, powerKw: regen ? -4.32 : 21.6, elevationM: nil, batteryLevel: 60)
        }
        let route = TripRoute(TripTimeline(path: rows), mode: .efficiency, tripKm: 60, maxPieces: 8)
        XCTAssertEqual(route.windowKm, 2, accuracy: 1e-9)
        let regen = route.pieces.filter { ($0.value ?? 0) < 0 }
        XCTAssertFalse(regen.isEmpty, "the descent is drawn in regen")
        XCTAssertTrue(regen.allSatisfy { $0.indices.count >= 2 }, "each regen piece is at least one drawable segment")
        let style = TripRouteStyle(mode: .efficiency, valueRange: route.valueRange, reference: reference, windowKm: route.windowKm)
        XCTAssertEqual(style.rgb(regen[0].value!), RoutePalette.regen)
        // Pieces still cover the run without a gap.
        for (a, b) in zip(route.pieces, route.pieces.dropFirst()) { XCTAssertEqual(a.indices.upperBound, b.indices.lowerBound) }
        // The split rule on its own: a piece ends where the windowed sign flips.
        XCTAssertEqual(TripRoute.signBreak([5, 4, -1, -2, 3], from: 0, to: 5), 2)
        XCTAssertEqual(TripRoute.signBreak([nil, -1, -2, 3], from: 0, to: 4), 3)
        XCTAssertEqual(TripRoute.signBreak([5, 4, 3], from: 0, to: 3), 3)
    }

    func testRunShorterThanTheWindowUsesTheWholeRun() {
        let run = [Interval(distanceKm: 0.05, energyKwh: 0.005), Interval(distanceKm: 0.05, energyKwh: 0.02),
                   Interval(distanceKm: 0.1, energyKwh: 0.015)]
        let values = EfficiencyWindow.smoothed(run)
        for v in values { XCTAssertEqual(v!, 0.04 * 1000 / 0.2, accuracy: 1e-9) }
    }

    func testWindowShrinksSymmetricallyAtTheEnds() {
        // 1 km: 500 m at 100 Wh/km then 500 m at 300 Wh/km, 10 m intervals.
        let run = steady(50, metres: 10, whPerKm: 100) + steady(50, metres: 10, whPerKm: 300)
        let values = EfficiencyWindow.smoothed(run)
        XCTAssertEqual(values[0]!, 100, accuracy: 1e-6, "first interval's window is itself")
        XCTAssertEqual(values[99]!, 300, accuracy: 1e-6)
        let blended: Double = (205.0 * 100 + 195.0 * 300) / 400
        XCTAssertEqual(values[49]!, blended, accuracy: 1e-6, "full 400 m window")
        XCTAssertEqual(values.count, 100)
        XCTAssertTrue(EfficiencyWindow.smoothed([]).isEmpty)
        XCTAssertEqual(EfficiencyWindow.smoothed([Interval(distanceKm: 0, energyKwh: 0)]), [nil])
    }

    @MainActor
    func testAGapOrUnrecordedStretchSplitsWindows() {
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func point(_ s: Double, power: Double?, lat: Double) -> DrivePoint {
            DrivePoint(t: t0.addingTimeInterval(s), latitude: lat, longitude: -122.1, speedKph: 50,
                       powerKw: power, elevationM: 30, batteryLevel: 60)
        }
        // 8 kW (160 Wh/km), a position gap, then 20 kW (400 Wh/km).
        let first = stride(from: 0.0, through: 120, by: 2).map { point($0, power: 8, lat: 37.40 + $0 / 100_000) }
        let second = stride(from: 400.0, through: 520, by: 2).map { point($0, power: 20, lat: 37.41 + $0 / 100_000) }
        let gapped = TripRoute(TripTimeline(path: first + second), mode: .efficiency)
        XCTAssertEqual(gapped.gaps.count, 1)
        for piece in gapped.pieces {
            let v = try! XCTUnwrap(piece.value)
            XCTAssertEqual(v, piece.coordinates[0].latitude < 37.41 ? 160 : 400, accuracy: 1e-6, "no blending across the gap")
        }
        // 8 kW, a minute with no power recorded, then 20 kW, all one position segment.
        let rows = stride(from: 0.0, through: 360, by: 2).map { t -> DrivePoint in
            point(t, power: t < 120 ? 8 : (t <= 180 ? nil : 20), lat: 37.40 + t / 100_000)
        }
        // A stop is recorded data: braking regen, idle and pull-away stay
        // inside one window run instead of restarting it at the light.
        let stopRows = stride(from: 0.0, through: 360, by: 2).map { t -> DrivePoint in
            let stopped = t >= 170 && t <= 190
            let braking = t >= 160 && t < 170, launching = t > 190 && t <= 200
            let power: Double = stopped ? 1 : (braking ? -15 : (launching ? 25 : 8))
            return DrivePoint(t: t0.addingTimeInterval(t), latitude: 37.40 + t / 100_000, longitude: -122.1,
                              speedKph: stopped ? 0 : 50, powerKw: power, elevationM: 30, batteryLevel: 60)
        }
        let stop = TripRoute(TripTimeline(path: stopRows), mode: .efficiency)
        XCTAssertTrue(stop.pieces.allSatisfy { $0.value != nil }, "the stop doesn't break the run")
        for piece in stop.pieces {
            let v = try! XCTUnwrap(piece.value)
            XCTAssertGreaterThan(v, 0, "braking regen is averaged in, not shown on its own")
            // On its own the pull-away reads 500 Wh/km (3.1x the reference).
            XCTAssertLessThan(v / 160, 2.0, "the pull-away is averaged in")
        }

        let unrecorded = TripRoute(TripTimeline(path: rows), mode: .efficiency)
        XCTAssertTrue(unrecorded.gaps.isEmpty)
        XCTAssertTrue(unrecorded.pieces.contains { $0.value == nil }, "the unrecorded stretch is drawn as not recorded")
        for piece in unrecorded.pieces {
            guard let v = piece.value else { continue }
            XCTAssertEqual(v, piece.indices.upperBound <= 60 ? 160 : 400, accuracy: 1e-6, "no blending across it")
        }
    }
}
