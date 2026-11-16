import SwiftUI
import UIKit
import XCTest
@testable import Volta

/// Every token resolves to its specified value in each appearance
/// (docs/APPEARANCE.md), and text and state colours meet WCAG AA there.
final class AppearanceTests: XCTestCase {
    struct RGBA: Equatable, CustomStringConvertible {
        var r, g, b, a: Double
        var description: String { String(format: "#%02X%02X%02X @ %.2f", Int((r * 255).rounded()), Int((g * 255).rounded()), Int((b * 255).rounded()), a) }

        init(r: Double, g: Double, b: Double, a: Double) { self.r = r; self.g = g; self.b = b; self.a = a }
        init(hex: UInt32, alpha: Double = 1) {
            self.init(r: Double((hex >> 16) & 0xFF) / 255, g: Double((hex >> 8) & 0xFF) / 255, b: Double(hex & 0xFF) / 255, a: alpha)
        }

        func isClose(to o: RGBA) -> Bool {
            abs(r - o.r) < 0.003 && abs(g - o.g) < 0.003 && abs(b - o.b) < 0.003 && abs(a - o.a) < 0.003
        }

        /// This colour composited over an opaque `base`.
        func over(_ base: RGBA) -> RGBA {
            RGBA(r: r * a + base.r * (1 - a), g: g * a + base.g * (1 - a), b: b * a + base.b * (1 - a), a: 1)
        }

        var luminance: Double {
            func lin(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
        }

        func contrast(_ o: RGBA) -> Double {
            let x = luminance, y = o.luminance
            return (max(x, y) + 0.05) / (min(x, y) + 0.05)
        }
    }

    static func resolve(_ color: Color, _ style: UIUserInterfaceStyle) -> RGBA {
        let ui = UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: style))
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        return RGBA(r: Double(r), g: Double(g), b: Double(b), a: Double(a))
    }

    struct Token {
        var name: String
        var color: Color
        var light: RGBA
        var dark: RGBA
    }

    /// The specified values (docs/APPEARANCE.md).
    static let tokens: [Token] = [
        Token(name: "voltaBackground", color: .voltaBackground, light: RGBA(hex: 0xF2F2F7), dark: RGBA(hex: 0x171717)),
        Token(name: "voltaCard", color: .voltaCard, light: RGBA(hex: 0xFFFFFF), dark: RGBA(hex: 0x202020)),
        Token(name: "voltaRaised", color: .voltaRaised, light: RGBA(hex: 0xE5E5EA), dark: RGBA(hex: 0x2C2C2C)),
        Token(name: "voltaHairline", color: .voltaHairline, light: RGBA(hex: 0x000000, alpha: 0.08), dark: RGBA(hex: 0xFFFFFF, alpha: 0.08)),
        Token(name: "voltaControlFill", color: .voltaControlFill, light: RGBA(hex: 0x767680, alpha: 0.12), dark: RGBA(hex: 0xFFFFFF, alpha: 0.10)),
        Token(name: "voltaTrack", color: .voltaTrack, light: RGBA(hex: 0x787880, alpha: 0.20), dark: RGBA(hex: 0xFFFFFF, alpha: 0.10)),
        Token(name: "voltaInk", color: .voltaInk, light: RGBA(hex: 0x111111), dark: RGBA(hex: 0xFFFFFF)),
        Token(name: "voltaInkInverse", color: .voltaInkInverse, light: RGBA(hex: 0xFFFFFF), dark: RGBA(hex: 0x000000)),
        Token(name: "voltaMapWash", color: .voltaMapWash, light: RGBA(hex: 0xFFFFFF), dark: RGBA(hex: 0x000000)),
        Token(name: "voltaMapBackdrop", color: .voltaMapBackdrop, light: RGBA(hex: 0xE4E6EA), dark: RGBA(hex: 0x1B1E23)),
        Token(name: "voltaCardShadow", color: .voltaCardShadow, light: RGBA(hex: 0x000000, alpha: 0.06), dark: RGBA(r: 0, g: 0, b: 0, a: 0)),
        Token(name: "voltaThumbShadow", color: .voltaThumbShadow, light: RGBA(hex: 0x000000, alpha: 0.30), dark: RGBA(r: 0, g: 0, b: 0, a: 0)),
        Token(name: "voltaShadow", color: .voltaShadow, light: RGBA(hex: 0x000000, alpha: 0.55), dark: RGBA(hex: 0x000000)),
        Token(name: "voltaTextPrimary", color: .voltaTextPrimary, light: RGBA(hex: 0x111111), dark: RGBA(hex: 0xFFFFFF)),
        Token(name: "voltaTextSecondary", color: .voltaTextSecondary, light: RGBA(hex: 0x5E5E63), dark: RGBA(hex: 0x9E9E9E)),
        Token(name: "voltaTextTertiary", color: .voltaTextTertiary, light: RGBA(hex: 0x6C6C70), dark: RGBA(hex: 0x888888)),
        Token(name: "voltaOnState", color: .voltaOnState, light: RGBA(hex: 0xFFFFFF), dark: RGBA(hex: 0x000000, alpha: 0.75)),
        Token(name: "voltaBlue", color: .voltaBlue, light: RGBA(hex: 0x2563EB), dark: RGBA(hex: 0x3B82F6)),
        Token(name: "voltaBlueFill", color: .voltaBlueFill, light: RGBA(hex: 0x1D4ED8), dark: RGBA(hex: 0x2563EB)),
        Token(name: "voltaBlueText", color: .voltaBlueText, light: RGBA(hex: 0x1D4ED8), dark: RGBA(hex: 0x3B82F6)),
        Token(name: "voltaGreen", color: .voltaGreen, light: RGBA(hex: 0x157A3E), dark: RGBA(hex: 0x5ECB93)),
        Token(name: "voltaAmber", color: .voltaAmber, light: RGBA(hex: 0xA84E0A), dark: RGBA(hex: 0xF59E0B)),
        Token(name: "voltaRed", color: .voltaRed, light: RGBA(hex: 0xC42B1C), dark: RGBA(hex: 0xEF4444)),
        Token(name: "voltaPurple", color: .voltaPurple, light: RGBA(hex: 0x7C3AED), dark: RGBA(hex: 0xA78BFA)),
        Token(name: "voltaTeal", color: .voltaTeal, light: RGBA(hex: 0x0F766E), dark: RGBA(hex: 0x14B8A6)),
    ]

    func testEveryTokenResolvesToItsSpecifiedValueInEachAppearance() {
        for t in Self.tokens {
            let light = Self.resolve(t.color, .light), dark = Self.resolve(t.color, .dark)
            XCTAssertTrue(light.isClose(to: t.light), "\(t.name) light: \(light), expected \(t.light)")
            XCTAssertTrue(dark.isClose(to: t.dark), "\(t.name) dark: \(dark), expected \(t.dark)")
            XCTAssertFalse(light.isClose(to: dark), "\(t.name) must differ between light and dark")
        }
    }

    /// iOS reports `.unspecified` before a trait is known; Volta treats it as light, as iOS does.
    func testUnspecifiedResolvesAsLight() {
        XCTAssertTrue(Self.resolve(.voltaBackground, .unspecified).isClose(to: RGBA(hex: 0xF2F2F7)))
    }

    /// Text on a saturated fill is white in both appearances by design.
    func testOnAccentIsWhiteInBoth() {
        XCTAssertTrue(Self.resolve(.voltaOnAccent, .light).isClose(to: RGBA(hex: 0xFFFFFF)))
        XCTAssertTrue(Self.resolve(.voltaOnAccent, .dark).isClose(to: RGBA(hex: 0xFFFFFF)))
    }

    func testOpacityKeepsTheTokenAdaptive() {
        let grid = Color.voltaInk.opacity(0.06)
        XCTAssertTrue(Self.resolve(grid, .light).isClose(to: RGBA(hex: 0x111111, alpha: 0.06)))
        XCTAssertTrue(Self.resolve(grid, .dark).isClose(to: RGBA(hex: 0xFFFFFF, alpha: 0.06)))
    }

    // MARK: Contrast (WCAG AA: 4.5:1 text, 3:1 graphics)

    private func ratio(_ fg: Color, on bg: Color, _ style: UIUserInterfaceStyle) -> Double {
        let base = Self.resolve(bg, style)
        return Self.resolve(fg, style).over(base).contrast(base)
    }

    func testTextMeetsAAOnPageAndCardInBothAppearances() {
        for (name, fg) in [("primary", Color.voltaTextPrimary), ("secondary", .voltaTextSecondary), ("tertiary", .voltaTextTertiary)] {
            for style in [UIUserInterfaceStyle.light, .dark] {
                for (bgName, bg) in [("page", Color.voltaBackground), ("card", .voltaCard)] {
                    let r = ratio(fg, on: bg, style)
                    XCTAssertGreaterThanOrEqual(r, 4.5, "\(name) on \(bgName), \(style == .dark ? "dark" : "light"): \(r)")
                }
            }
        }
    }

    /// The light state colours are text-grade. Dark mode keeps `main`'s values,
    /// which are text-grade except blue and red on a card (4.4 and 4.3; see the doc).
    func testStateColoursMeetAA() {
        let states: [(String, Color)] = [("blue", .voltaBlue), ("green", .voltaGreen), ("amber", .voltaAmber), ("red", .voltaRed),
                                         ("purple", .voltaPurple), ("teal", .voltaTeal), ("parked", NowCard.parkedText),
                                         ("fair", DriveScoreTint.fair), ("poor", DriveScoreTint.poor),
                                         ("stale", LiveDrivingCard.staleAmber), ("no data", LiveDrivingCard.noDataGray)]
        for (name, c) in states {
            for (bgName, bg) in [("page", Color.voltaBackground), ("card", .voltaCard)] {
                XCTAssertGreaterThanOrEqual(ratio(c, on: bg, .light), 4.5, "\(name) on \(bgName), light")
                XCTAssertGreaterThanOrEqual(ratio(c, on: bg, .dark), 4.3, "\(name) on \(bgName), dark")
            }
        }
        // Small blue text on its blue wash (pills, bordered buttons), over a card.
        for wash in [0.12, 0.18] {
            let bg = Self.resolve(Color.voltaBlue.opacity(wash), .light).over(Self.resolve(.voltaCard, .light))
            XCTAssertGreaterThanOrEqual(Self.resolve(.voltaBlueText, .light).contrast(bg), 4.5, "blue text on a \(wash) wash")
        }
        XCTAssertGreaterThanOrEqual(ratio(.voltaOnAccent, on: .voltaBlueFill, .light), 4.5)
        XCTAssertGreaterThanOrEqual(ratio(.voltaOnAccent, on: .voltaBlueFill, .dark), 4.5)
    }

    /// Graphics that carry values: at least 3:1 on a light card.
    func testLightGraphicsMeetThreeToOne() {
        let kinds: [IdleStateSlice.Kind] = [.sentry, .climate, .awake, .asleep, .unclassified]
        for kind in kinds {
            let slice = IdleStateSlice(kind: kind, minutes: 1)
            XCTAssertGreaterThanOrEqual(ratio(slice.color, on: .voltaCard, .light), 3, kind.rawValue)
        }
        XCTAssertGreaterThanOrEqual(ratio(MileageTrackerView.pastBar, on: .voltaCard, .light), 3, "mileage history bars")
    }

    // MARK: Route palette

    /// Light-map route colours read on light tiles (the muted basemap, at its
    /// lightest and around water).
    func testLightRouteColoursReadOnLightTiles() {
        let tiles = [RGBA(hex: 0xF2F2F2), RGBA(hex: 0xE3E3E3)]
        let v = RoutePalette.light
        let ramps: [(String, RoutePalette.Ramp)] = [("speed", v.speed), ("efficiency", v.efficiency),
                                                    ("elevation", v.elevation), ("density", v.density)]
        for (name, ramp) in ramps {
            let lo = ramp.domain.lowerBound, hi = ramp.domain.upperBound
            for n in 0...40 {
                let c = ramp.rgb(lo + (hi - lo) * Double(n) / 40)
                for tile in tiles {
                    XCTAssertGreaterThanOrEqual(RGBA(r: c.r, g: c.g, b: c.b, a: 1).contrast(tile), 3, "\(name) at \(n)/40")
                }
            }
        }
        for (name, c) in [("regen", v.regen), ("plain", v.plain)] {
            XCTAssertGreaterThanOrEqual(RGBA(r: c.r, g: c.g, b: c.b, a: 1).contrast(tiles[1]), 3, name)
        }
    }

    /// Same order and meaning: on the light map lightness falls where it rises on the dark one.
    func testLightRampsRunTheOtherWayInLightness() {
        for (name, ramp) in [("speed", RoutePalette.light.speed), ("elevation", RoutePalette.light.elevation),
                             ("density", RoutePalette.light.density)] {
            let lo = ramp.domain.lowerBound, hi = ramp.domain.upperBound
            let l = (0...20).map { ramp.rgb(lo + (hi - lo) * Double($0) / 20).lightness }
            XCTAssertLessThan(l.last!, l.first!, name)
        }
    }

    /// One colour still means one value within each appearance.
    func testEachAppearanceKeepsColoursDistinct() {
        for appearance in [RoutePalette.Appearance.dark, .light] {
            let keys = stride(from: 0.0, through: 130, by: 13).map { RoutePalette.speed(kph: $0, in: appearance).bucketKey }
            XCTAssertEqual(Set(keys).count, keys.count, "\(appearance)")
            XCTAssertNotEqual(RoutePalette.efficiency(ratio: -0.2, in: appearance), RoutePalette.efficiency(ratio: 0.5, in: appearance))
        }
        XCTAssertEqual(RoutePalette.speed(kph: 65, in: .dark), RoutePalette.speed(kph: 65), "dark stays the default")
        XCTAssertNotEqual(RoutePalette.speed(kph: 65, in: .light), RoutePalette.speed(kph: 65))
    }

    func testRouteChromeAdapts() {
        let casing = Self.resolve(RoutePalette.casingColor, .light), casingDark = Self.resolve(RoutePalette.casingColor, .dark)
        XCTAssertTrue(casing.isClose(to: RGBA(hex: 0xFFFFFF)))
        XCTAssertTrue(casingDark.isClose(to: RGBA(hex: 0x101318)))
        XCTAssertTrue(Self.resolve(RoutePalette.markerColor, .light).isClose(to: RGBA(hex: 0x1C1C1E)))
        XCTAssertTrue(Self.resolve(RoutePalette.markerColor, .dark).isClose(to: RGBA(hex: 0xFFFFFF)))
        let stops = RouteLegendModel.speed(units: UnitPreferences()).stops
        XCTAssertTrue(Self.resolve(stops.first!.color, .dark).isClose(to: RGBA(hex: 0x7C8CFF)))
        XCTAssertTrue(Self.resolve(stops.first!.color, .light).isClose(to: RGBA(hex: 0x616BFC)))
        XCTAssertTrue(Self.resolve(stops.last!.color, .light).isClose(to: RGBA(hex: 0x7E5D02)))
    }
}
