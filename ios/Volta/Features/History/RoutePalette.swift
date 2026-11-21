import SwiftUI

/// The one colour system for routes: the trip map, the Drives overview map,
/// the heatmap, every route legend and the efficiency gauge on drive detail.
/// Ramps are continuous and interpolated in OKLab, so equal steps along a
/// ramp look like equal steps of colour. Domains are fixed (speed, efficiency,
/// density) so a colour means the same thing on every trip; only elevation is
/// relative to the trip, and its legend shows the real values.
enum RoutePalette {
    /// sRGB, 0...1 per channel.
    struct RGB: Equatable, Sendable {
        var r, g, b: Double

        init(r: Double, g: Double, b: Double) { self.r = r; self.g = g; self.b = b }

        init(hex: UInt32) {
            self.init(r: Double((hex >> 16) & 0xFF) / 255, g: Double((hex >> 8) & 0xFF) / 255, b: Double(hex & 0xFF) / 255)
        }

        var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: 1) }  // appearance: one variant's value (see `Variant`)

        /// OKLab lightness, 0...1.
        var lightness: Double { OKLab(self).l }

        /// Quantised to 6 bits per channel, so a route split into thousands of
        /// pieces draws as a handful of strokes.
        var bucketKey: Int {
            let red: Int = Self.level(r), green: Int = Self.level(g), blue: Int = Self.level(b)
            return (red << 12) | (green << 6) | blue
        }

        private static func level(_ channel: Double) -> Int {
            let scaled: Double = (channel * 63).rounded()
            return Int(scaled)
        }
    }

    /// A ramp: colours pinned at increasing positions along a domain. Values
    /// outside the domain clamp to the end colours.
    struct Ramp: Sendable {
        var knots: [(position: Double, color: RGB)]

        init(_ knots: [(Double, UInt32)]) {
            self.knots = knots.map { ($0.0, RGB(hex: $0.1)) }
        }

        var domain: ClosedRange<Double> { knots[0].position...knots[knots.count - 1].position }
        var colors: [RGB] { knots.map(\.color) }

        func rgb(_ value: Double) -> RGB {
            guard let first = knots.first, let last = knots.last else { return RGB(r: 1, g: 1, b: 1) }
            guard value.isFinite else { return first.color }
            if value <= first.position { return first.color }
            if value >= last.position { return last.color }
            let i = knots.lastIndex { $0.position <= value } ?? 0
            let a = knots[i], b = knots[min(i + 1, knots.count - 1)]
            let span = b.position - a.position
            return RoutePalette.mix(a.color, b.color, span > 0 ? (value - a.position) / span : 0)
        }

        func color(_ value: Double) -> Color { rgb(value).color }

        /// Stops for a SwiftUI gradient across the whole domain, sampled finely
        /// enough that the sRGB gradient follows the OKLab ramp.
        func gradientStops(samples: Int = 12) -> [Gradient.Stop] {
            let lo = domain.lowerBound, hi = domain.upperBound
            return (0...samples).map { n in
                let f = Double(n) / Double(samples)
                return Gradient.Stop(color: color(lo + (hi - lo) * f), location: f)
            }
        }
    }

    // MARK: Ramps

    // Each ramp, and each single colour, has a dark-map and a light-map
    // variant with the same meaning, order and legend. The light variant keeps
    // every hue and inverts lightness: on the dark map a higher value is
    // brighter, on the light map it is deeper, so in both it stands out more
    // from the tiles. Every light colour is at least 3:1 against light tiles
    // (docs/APPEARANCE.md). Within one appearance a colour still means one value.

    /// Which map a colour is for: the system appearance.
    enum Appearance: Sendable, Equatable {
        case dark, light

        init(_ scheme: ColorScheme) { self = scheme == .dark ? .dark : .light }
    }

    /// One appearance's ramps and colours.
    struct Variant: Sendable {
        var speed, efficiency, elevation, density: Ramp
        var regen, missing, plain, casing, marker: RGB
    }

    /// km/h, fixed domain 0...130. (Dark map; `light.speed` for the light one.)
    static let speed = Ramp([(0, 0x7C8CFF), (32.5, 0x4BA8FF), (65, 0x39D8EE), (97.5, 0x9AEAC8), (130, 0xF3F5B0)])
    /// Consumption over the reference consumption (1 = as rated).
    static let efficiency = Ramp([(0.5, 0x5EEBC4), (0.75, 0x46B79C), (1.0, 0xA8B0BB), (1.375, 0xE9A34B), (1.75, 0xFF7A45)])
    /// Fraction of the trip's own elevation range.
    static let elevation = Ramp([(0, 0x7C8CFF), (0.5, 0xB2AEFF), (1, 0xF3D9FF)])
    /// log10 of the number of distinct drives on a stretch of road (1, 3, 10, 30+).
    static let density = Ramp([(0, 0x6698DD), (log10(3), 0x56B6EC), (1, 0x77DBED), (log10(30), 0xF1F8FF)])

    /// Negative consumption (the car recovered energy).
    static let regen = RGB(hex: 0xB79CFF)
    /// A stretch where the metric was not recorded. Thinner than the route
    /// line, so it never reads as the efficiency midpoint.
    static let missing = RGB(hex: 0x6B7078)
    /// Plain routes, when nothing is being measured.
    static let plain = RGB(hex: 0x4BA8FF)
    /// Dark edge under every route line and marker.
    static let casing = RGB(hex: 0x101318)

    /// The dark map's palette: the values above.
    static let dark = Variant(speed: speed, efficiency: efficiency, elevation: elevation, density: density,
                              regen: regen, missing: missing, plain: plain, casing: casing, marker: RGB(hex: 0xFFFFFF))

    /// The light map's palette. Casing is a white halo under each line, and
    /// endpoint markers are near-black rings on it.
    static let light = Variant(
        speed: Ramp([(0, 0x616BFC), (32.5, 0x0B7CD1), (65, 0x06808F), (97.5, 0x027E5B), (130, 0x7E5D02)]),
        efficiency: Ramp([(0.5, 0x097B62), (0.75, 0x088B73), (1.0, 0x778190), (1.375, 0xB0700E), (1.75, 0xBD4506)]),
        elevation: Ramp([(0, 0x5B62F8), (0.5, 0x5E4FB8), (1, 0x6B2B83)]),
        density: Ramp([(0, 0x3E7ACB), (log10(3), 0x0571A0), (1, 0x015D6A), (log10(30), 0x003760)]),
        regen: RGB(hex: 0x7449C5), missing: RGB(hex: 0x939AA3), plain: RGB(hex: 0x0C74C4),
        casing: RGB(hex: 0xFFFFFF), marker: RGB(hex: 0x1C1C1E))

    static func variant(_ appearance: Appearance) -> Variant { appearance == .dark ? dark : light }

    /// A colour that follows the system appearance, from the same lookup in
    /// each appearance: `RoutePalette.adaptive { variant($0).regen }`.
    static func adaptive(_ lookup: (Appearance) -> RGB) -> Color {
        Color(light: lookup(.light).color, dark: lookup(.dark).color)
    }

    /// Gradient stops for a legend or gauge that follow the system appearance.
    static func adaptiveStops(_ ramp: (Variant) -> Ramp, samples: Int = 12) -> [Gradient.Stop] {
        zip(ramp(dark).gradientStops(samples: samples), ramp(light).gradientStops(samples: samples)).map { d, l in
            Gradient.Stop(color: Color(light: l.color, dark: d.color), location: d.location)
        }
    }

    static let regenColor = adaptive { variant($0).regen }
    static let missingColor = adaptive { variant($0).missing }
    static let plainColor = adaptive { variant($0).plain }
    static let casingColor = adaptive { variant($0).casing }
    static let markerColor = adaptive { variant($0).marker }

    static let lineWidth: CGFloat = 5
    static let casingWidth: CGFloat = 8
    static let missingWidth: CGFloat = 3

    /// Reference consumption when the vehicle's rated figure isn't known (Wh/km).
    static let fallbackReferenceWhPerKm = 160.0
    static let speedDomainKph = 0.0...130.0
    static let densityCap = 30

    // MARK: Lookups

    static func speed(kph: Double, in appearance: Appearance = .dark) -> RGB { variant(appearance).speed.rgb(kph) }

    /// Colour for a consumption against a reference. Negative is regen.
    static func efficiency(whPerKm: Double, reference: EfficiencyReference, in appearance: Appearance = .dark) -> RGB {
        efficiency(ratio: whPerKm / reference.whPerKm, in: appearance)
    }

    /// Colour for consumption over the reference; a negative ratio (net
    /// regeneration) is regen on every map, trip or heatmap.
    static func efficiency(ratio: Double, in appearance: Appearance = .dark) -> RGB {
        let v = variant(appearance)
        return ratio < 0 ? v.regen : v.efficiency.rgb(ratio)
    }

    static func elevation(fraction: Double, in appearance: Appearance = .dark) -> RGB {
        variant(appearance).elevation.rgb(fraction)
    }

    /// Distinct drives on a stretch: 1 at the bottom, 30 and above at the top.
    static func density(count: Int, in appearance: Appearance = .dark) -> RGB {
        variant(appearance).density.rgb(log10(Double(max(1, count))))
    }

    // MARK: OKLab

    struct OKLab: Equatable {
        var l, a, b: Double

        init(l: Double, a: Double, b: Double) { self.l = l; self.a = a; self.b = b }

        init(_ c: RGB) {
            func linear(_ v: Double) -> Double { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            let r = linear(c.r), g = linear(c.g), bl = linear(c.b)
            let lm = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * bl)
            let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * bl)
            let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * bl)
            l = 0.2104542553 * lm + 0.7936177850 * m - 0.0040720468 * s
            a = 1.9779984951 * lm - 2.4285922050 * m + 0.4505937099 * s
            b = 0.0259040371 * lm + 0.7827717662 * m - 0.8086757660 * s
        }

        var rgb: RGB {
            let lm = pow(l + 0.3963377774 * a + 0.2158037573 * b, 3)
            let m = pow(l - 0.1055613458 * a - 0.0638541728 * b, 3)
            let s = pow(l - 0.0894841775 * a - 1.2914855480 * b, 3)
            func gamma(_ v: Double) -> Double {
                let c = min(max(v, 0), 1)
                return c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
            }
            return RGB(r: gamma(4.0767416621 * lm - 3.3077115913 * m + 0.2309699292 * s),
                       g: gamma(-1.2684380046 * lm + 2.6097574011 * m - 0.3413193965 * s),
                       b: gamma(-0.0041960863 * lm - 0.7034186147 * m + 1.7076147010 * s))
        }
    }

    /// `t` of the way from `a` to `b`, in OKLab.
    static func mix(_ a: RGB, _ b: RGB, _ t: Double) -> RGB {
        if t <= 0 { return a }
        if t >= 1 { return b }
        let p = OKLab(a), q = OKLab(b)
        return OKLab(l: p.l + (q.l - p.l) * t, a: p.a + (q.a - p.a) * t, b: p.b + (q.b - p.b) * t).rgb
    }
}

/// What "1.0×" on the efficiency ramp means: the vehicle's rated consumption
/// when the app knows it, otherwise an estimated reference.
struct EfficiencyReference: Hashable, Sendable {
    var whPerKm: Double
    /// False when this is the fallback rather than the vehicle's rating.
    var isRated: Bool

    init(ratedWhPerKm: Double?) {
        if let rated = ratedWhPerKm, rated.isFinite, rated > 0 {
            whPerKm = rated
            isRated = true
        } else {
            whPerKm = RoutePalette.fallbackReferenceWhPerKm
            isRated = false
        }
    }

    /// The most common rating among `drives` (one car normally has one), so
    /// every drive on a shared map is coloured against the same reference.
    init(drives: [DriveSummary]) {
        var counts: [Double: Int] = [:]
        for drive in drives {
            if let rated = drive.ratedWhPerKm, rated.isFinite, rated > 0 { counts[rated, default: 0] += 1 }
        }
        let best = counts.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key
        self.init(ratedWhPerKm: best)
    }

    /// Consumption at a position along the ramp (`ratio` × reference).
    func whPerKm(atRatio ratio: Double) -> Double { whPerKm * ratio }
}

// MARK: - Legend

/// What a route legend shows: a gradient, its end labels and a reference tick
/// in the user's units.
struct RouteLegendModel: Equatable {
    var stops: [Gradient.Stop]
    var low: String
    /// Label for the tick (nil: no label).
    var mid: String?
    var high: String
    /// A tick at this fraction of the bar (nil: no tick).
    var tick: Double?
    /// Extra swatch after the bar, e.g. regen.
    var extra: (label: String, color: Color)?
    /// Read by VoiceOver as one sentence.
    var sentence: String
    /// A small line under the bar, e.g. how the colour is averaged.
    var note: String? = nil
    /// Fixed labels along the bar at fractions of its length, in place of the
    /// end labels (density: 1 · 3 · 10 · 30+).
    var marks: [Mark]? = nil

    struct Mark: Equatable {
        var label: String
        var position: Double
    }

    static func == (a: RouteLegendModel, b: RouteLegendModel) -> Bool {
        a.low == b.low && a.mid == b.mid && a.high == b.high && a.tick == b.tick && a.sentence == b.sentence
            && a.extra?.label == b.extra?.label && a.note == b.note && a.marks == b.marks
    }

    /// A distance for captions: "0.25 mi", "0.9 mi", "400 m", "1.4 km".
    static func windowText(_ km: Double, units: UnitPreferences) -> (short: String, long: String) {
        if units.distance == .miles {
            let miles: Double = km / 1.609344
            let text = VoltaFormat.number(miles, digits: miles < 0.5 ? 2 : 1)
            return ("\(text) mi", "\(text) miles")
        }
        if km < 1 {
            let metres = VoltaFormat.number((km * 100).rounded() * 10, digits: 0)
            return ("\(metres) m", "\(metres) metres")
        }
        let text = VoltaFormat.number(km, digits: 1)
        return ("\(text) km", "\(text) kilometres")
    }

    static func speed(units: UnitPreferences) -> RouteLegendModel {
        let unit = units.distance == .miles ? "mph" : "km/h"
        // Floor, so the inequality stays true: 130 km/h reads "80+ mph".
        let top = units.distanceValue(km: RoutePalette.speedDomainKph.upperBound).rounded(.down)
        let mid = units.distanceValue(km: RoutePalette.speedDomainKph.upperBound / 2)
        let topText = "\(VoltaFormat.number(top, digits: 0))+ \(unit)"
        return RouteLegendModel(stops: RoutePalette.adaptiveStops { $0.speed }, low: "0", mid: "\(VoltaFormat.number(mid, digits: 0)) \(unit)",
                                high: topText, tick: 0.5, extra: nil,
                                sentence: "Route colour shows speed, from 0 to \(VoltaFormat.number(top, digits: 0)) \(unit) and above.")
    }

    /// The tick's label: "Rated 264 Wh/mi" when the rating is recorded,
    /// "Est. 264 Wh/mi" for the fallback reference.
    static func referenceLabel(_ reference: EfficiencyReference, units: UnitPreferences) -> String {
        let value = VoltaFormat.number(units.efficiencyValue(whPerKm: reference.whPerKm), digits: 0)
        return "\(reference.isRated ? "Rated" : "Est.") \(value) \(units.efficiencyUnit)"
    }

    /// `averagedOverKm`: the colour is a rolling average over this much
    /// driving (a single drive), so the legend says so.
    static func efficiency(reference: EfficiencyReference, units: UnitPreferences, showsRegen: Bool = true,
                           averagedOverKm: Double? = nil) -> RouteLegendModel {
        let ramp = RoutePalette.efficiency
        let span = ramp.domain.upperBound - ramp.domain.lowerBound
        let ref = VoltaFormat.number(units.efficiencyValue(whPerKm: reference.whPerKm), digits: 0)
        let window = averagedOverKm.map { windowText($0, units: units) }
        let what = reference.isRated ? "the car's rated \(ref) \(units.efficiencyUnit)"
            : "an estimated reference of \(ref) \(units.efficiencyUnit), because the car's rating isn't recorded"
        return RouteLegendModel(stops: RoutePalette.adaptiveStops { $0.efficiency }, low: "Efficient", mid: referenceLabel(reference, units: units),
                                high: "Thirsty", tick: (1 - ramp.domain.lowerBound) / span,
                                extra: showsRegen ? ("Regen", RoutePalette.regenColor) : nil,
                                sentence: "Route colour shows efficiency against \(what): green is more efficient, orange is thirstier"
                                    + (showsRegen ? ", violet is regenerating." : ".")
                                    + (window.map { " Colour is averaged over \($0.long) of driving, not a reading at each point." } ?? ""),
                                note: window.map { "Averaged over \($0.short)" })
    }

    static func elevation(minM: Double, maxM: Double, units: UnitPreferences) -> RouteLegendModel {
        let feet = units.distance == .miles
        func h(_ m: Double) -> String { "\(VoltaFormat.number(feet ? m * 3.28084 : m, digits: 0)) \(feet ? "ft" : "m")" }
        return RouteLegendModel(stops: RoutePalette.adaptiveStops { $0.elevation }, low: h(minM), mid: nil, high: h(maxM),
                                tick: nil, extra: nil,
                                sentence: "Route colour shows elevation on this trip, from \(h(minM)) to \(h(maxM)).")
    }

    static var density: RouteLegendModel {
        let top = log10(Double(RoutePalette.densityCap))
        return RouteLegendModel(stops: RoutePalette.adaptiveStops { $0.density }, low: "1", mid: nil, high: "30+",
                                tick: nil, extra: nil,
                                sentence: "Route colour shows how many drives used each road, from 1 drive to 30 or more.",
                                marks: [Mark(label: "1", position: 0), Mark(label: "3", position: log10(3) / top),
                                        Mark(label: "10", position: 1 / top), Mark(label: "30+", position: 1)])
    }
}

/// Labels placed along a bar of `width` at fractions of it, each centred on
/// its position but kept inside the bar's ends.
private struct LegendMarks: View {
    var marks: [RouteLegendModel.Mark]
    var width: CGFloat

    var body: some View {
        ZStack(alignment: .leading) {
            Color.clear.frame(width: width, height: 1)
            ForEach(marks, id: \.label) { mark in
                Text(mark.label).fixedSize().alignmentGuide(.leading) { d in
                    let centred: CGFloat = d.width / 2 - width * mark.position
                    return min(0, max(d.width - width, centred))
                }
            }
        }
    }
}

/// The one route legend, a strip on the page background: under the trip map,
/// and between the heatmap's switch and its map. One row (end labels around
/// the bar and its tick; the regen swatch at the trailing end), and a caption
/// line under it only when there is a tick label, a note or fixed marks
/// (density's 1 · 3 · 10 · 30+, placed under the bar instead of end labels).
struct RouteLegendStrip: View {
    var model: RouteLegendModel
    /// Height kept for the legend's lines whatever the mode shows, so the
    /// content below doesn't move when a mode has no caption line.
    var reservedHeight: CGFloat? = nil
    @State private var bar: CGRect = .zero
    @State private var strip: CGFloat = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 8) {
                if model.marks == nil { Text(model.low) }
                Capsule()
                    .fill(LinearGradient(stops: model.stops, startPoint: .leading, endPoint: .trailing))
                    .frame(height: 4)
                    .frame(maxWidth: .infinity)
                    .overlay {
                        GeometryReader { g in
                            if let tick = model.tick {
                                Capsule().fill(Color.voltaTextPrimary).frame(width: 2, height: 10)
                                    .position(x: g.size.width * tick, y: g.size.height / 2)
                            }
                        }
                    }
                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named("legend.strip")) } action: { bar = $0 }
                if model.marks == nil { Text(model.high) }
                if let extra = model.extra {
                    HStack(spacing: 5) {
                        Capsule().fill(extra.color).frame(width: 12, height: 4)
                        Text(extra.label)
                    }
                    .padding(.leading, 6)
                }
            }
            .foregroundStyle(Color.voltaTextPrimary.opacity(0.85))
            if let marks = model.marks {
                // Over a flexible line, so the marks (placed by the bar's
                // measured width) never widen the strip themselves: a stale
                // wide first measurement would otherwise hold it wide.
                Text(marks.last?.label ?? " ").hidden()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .overlay(alignment: .topLeading) {
                        LegendMarks(marks: marks, width: bar.width)
                            .padding(.leading, bar.minX)
                            .foregroundStyle(HistoryTheme.secondary)
                    }
            } else if model.mid != nil || model.note != nil {
                ZStack(alignment: .leading) {
                    Color.clear.frame(maxWidth: .infinity).frame(height: 1)
                    if let note = model.note {
                        Text(note).frame(maxWidth: .infinity, alignment: .trailing)
                    }
                    if let mid = model.mid {
                        // Centred under the tick, kept inside the strip.
                        Text(mid).fixedSize().alignmentGuide(.leading) { d in
                            let x: CGFloat = bar.minX + bar.width * (model.tick ?? 0.5)
                            return min(0, max(d.width - strip, d.width / 2 - x))
                        }
                    }
                }
                .foregroundStyle(HistoryTheme.secondary)
            }
        }
        .scaledFont(11, weight: .semibold)
        .monospacedDigit()
        .lineLimit(1)
        .frame(minHeight: reservedHeight, alignment: .top)
        .coordinateSpace(.named("legend.strip"))
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { strip = $0 }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(model.sentence)
        .accessibilityIdentifier("route.legend")
    }
}

// MARK: - Endpoint markers

/// Route start and end, the same everywhere: a ring for the start, a solid
/// dot for the end, a ring with a dot when they coincide. Never green or red.
enum RouteEndpoint {
    case start, end, both
}

struct RouteEndpointMarker: View {
    var kind: RouteEndpoint
    /// Outer diameter; the map uses 14 (ring) and 12 (dot).
    var size: CGFloat = 9

    var body: some View {
        Canvas { ctx, canvasSize in
            RouteEndpointMarker.draw(kind, in: &ctx, at: CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2), size: size)
        }
        .frame(width: size * 16 / 14, height: size * 16 / 14)
        .accessibilityHidden(true)
    }

    /// Draws the marker centred on `c`. At `size` 14 (the map): a 14 pt ring
    /// with a 3 pt stroke in the marker colour and a centre in the casing
    /// colour; a 12 pt dot in the marker colour with a 2 pt casing edge.
    /// Dark map: white on near-black. Light map: near-black on white. Smaller
    /// sizes scale both.
    static func draw(_ kind: RouteEndpoint, in ctx: inout GraphicsContext, at c: CGPoint, size: CGFloat) {
        func circle(_ r: CGFloat) -> Path { Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)) }
        let casing = RoutePalette.casingColor, mark = RoutePalette.markerColor
        let k = size / 14
        switch kind {
        case .start, .both:
            ctx.fill(circle(8 * k), with: .color(casing))
            ctx.fill(circle(7 * k), with: .color(mark))
            ctx.fill(circle(4 * k), with: .color(casing))
            if kind == .both { ctx.fill(circle(2 * k), with: .color(mark)) }
        case .end:
            ctx.fill(circle(8 * k), with: .color(casing))
            ctx.fill(circle(6 * k), with: .color(mark))
        }
    }
}

// MARK: - Score

/// The drive score band, for every score ring (header, cards, detail).
/// A score's band colour, one rule for every score ring and bar: green for a
/// high (efficient, smooth) score, ink for an ordinary one, amber for a low
/// one that deserves attention. Red is kept for problems, and a low score
/// isn't one.
enum DriveScoreTint {
    static let good = Color.voltaGreen
    static let fair = Color.voltaTextPrimary
    static let poor = Color.voltaAmber

    static func color(_ score: Int?) -> Color {
        guard let score else { return HistoryTheme.secondary }
        return score >= 80 ? good : score >= 60 ? fair : poor
    }
}

// MARK: - Small type

private struct ScaledFont: ViewModifier {
    @ScaledMetric private var size: CGFloat
    var weight: Font.Weight

    init(size: CGFloat, weight: Font.Weight, relativeTo style: Font.TextStyle) {
        _size = ScaledMetric(wrappedValue: size, relativeTo: style)
        self.weight = weight
    }

    func body(content: Content) -> some View { content.font(.system(size: size, weight: weight)) }
}

extension View {
    /// A fixed design size that still follows Dynamic Type (never below 11 pt).
    func scaledFont(_ size: CGFloat, weight: Font.Weight = .regular, relativeTo style: Font.TextStyle = .caption2) -> some View {
        modifier(ScaledFont(size: max(11, size), weight: weight, relativeTo: style))
    }
}
