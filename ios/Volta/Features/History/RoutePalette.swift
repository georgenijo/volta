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

        var color: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: 1) }

        /// OKLab lightness, 0...1.
        var lightness: Double { OKLab(self).l }
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

    /// km/h, fixed domain 0...130.
    static let speed = Ramp([(0, 0x7C8CFF), (32.5, 0x4BA8FF), (65, 0x39D8EE), (97.5, 0x9AEAC8), (130, 0xF3F5B0)])
    /// Consumption over the reference consumption (1 = as rated).
    static let efficiency = Ramp([(0.5, 0x5EEBC4), (0.75, 0x46B79C), (1.0, 0x868C96), (1.375, 0xE9A34B), (1.75, 0xFF7A45)])
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

    static let lineWidth: CGFloat = 5
    static let casingWidth: CGFloat = 8
    static let missingWidth: CGFloat = 3

    /// Reference consumption when the vehicle's rated figure isn't known (Wh/km).
    static let fallbackReferenceWhPerKm = 160.0
    static let speedDomainKph = 0.0...130.0
    static let densityCap = 30

    // MARK: Lookups

    static func speed(kph: Double) -> RGB { speed.rgb(kph) }

    /// Colour for a consumption against a reference. Negative is regen.
    static func efficiency(whPerKm: Double, reference: EfficiencyReference) -> RGB {
        whPerKm < 0 ? regen : efficiency.rgb(whPerKm / reference.whPerKm)
    }

    static func elevation(fraction: Double) -> RGB { elevation.rgb(fraction) }

    /// Distinct drives on a stretch: 1 at the bottom, 30 and above at the top.
    static func density(count: Int) -> RGB { density.rgb(log10(Double(max(1, count)))) }

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

/// What a route legend shows: a gradient and three labels in the user's units.
struct RouteLegendModel: Equatable {
    var stops: [Gradient.Stop]
    var low: String
    var mid: String?
    var high: String
    /// Mid label sits under a tick at this fraction of the bar (nil: no tick).
    var tick: Double?
    /// Extra swatch after the bar, e.g. regen.
    var extra: (label: String, color: Color)?
    /// Read by VoiceOver as one sentence.
    var sentence: String

    static func == (a: RouteLegendModel, b: RouteLegendModel) -> Bool {
        a.low == b.low && a.mid == b.mid && a.high == b.high && a.tick == b.tick && a.sentence == b.sentence
            && a.extra?.label == b.extra?.label
    }

    static func speed(units: UnitPreferences) -> RouteLegendModel {
        let unit = units.distance == .miles ? "mph" : "km/h"
        // Floor, so the inequality stays true: 130 km/h reads "80+ mph".
        let top = units.distanceValue(km: RoutePalette.speedDomainKph.upperBound).rounded(.down)
        let mid = units.distanceValue(km: RoutePalette.speedDomainKph.upperBound / 2)
        let topText = "\(VoltaFormat.number(top, digits: 0))+ \(unit)"
        return RouteLegendModel(stops: RoutePalette.speed.gradientStops(), low: "0", mid: VoltaFormat.number(mid, digits: 0),
                                high: topText, tick: 0.5, extra: nil,
                                sentence: "Route colour shows speed, from 0 to \(VoltaFormat.number(top, digits: 0)) \(unit) and above.")
    }

    static func efficiency(reference: EfficiencyReference, units: UnitPreferences, showsRegen: Bool = true) -> RouteLegendModel {
        let ramp = RoutePalette.efficiency
        let span = ramp.domain.upperBound - ramp.domain.lowerBound
        let ref = VoltaFormat.number(units.efficiencyValue(whPerKm: reference.whPerKm), digits: 0)
        let label = reference.isRated ? ref : "~\(ref)"
        let what = reference.isRated ? "the car's rated \(ref) \(units.efficiencyUnit)"
            : "an estimated reference of \(ref) \(units.efficiencyUnit)"
        return RouteLegendModel(stops: ramp.gradientStops(), low: "Efficient", mid: label, high: "Thirsty",
                                tick: (1 - ramp.domain.lowerBound) / span,
                                extra: showsRegen ? ("Regen", RoutePalette.regen.color) : nil,
                                sentence: "Route colour shows efficiency against \(what): green is more efficient, orange is thirstier"
                                    + (showsRegen ? ", violet is regenerating." : "."))
    }

    static func elevation(minM: Double, maxM: Double, units: UnitPreferences) -> RouteLegendModel {
        let feet = units.distance == .miles
        func h(_ m: Double) -> String { "\(VoltaFormat.number(feet ? m * 3.28084 : m, digits: 0)) \(feet ? "ft" : "m")" }
        return RouteLegendModel(stops: RoutePalette.elevation.gradientStops(), low: h(minM), mid: nil, high: h(maxM),
                                tick: nil, extra: nil,
                                sentence: "Route colour shows elevation on this trip, from \(h(minM)) to \(h(maxM)).")
    }

    static var density: RouteLegendModel {
        RouteLegendModel(stops: RoutePalette.density.gradientStops(), low: "1 drive", mid: "10", high: "30+ drives",
                         tick: 1 / log10(30), extra: nil,
                         sentence: "Route colour shows how many drives used each road, from 1 drive to 30 or more.")
    }
}

/// A compact glass chip: a thin gradient capsule with low, reference and
/// high labels. Placed at a map's bottom leading corner, above the fade.
struct RouteLegendChip: View {
    var model: RouteLegendModel
    var width: CGFloat = 140
    /// Room kept beside the chip so MapKit's logo never moves when the
    /// legend changes (the widest chip, with its regen swatch, plus a gap).
    static let reservedWidth: CGFloat = 238

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let mid = model.mid {
                // The reference number sits over its tick.
                ZStack(alignment: .leading) {
                    Color.clear.frame(width: width, height: 1)
                    Text(mid).alignmentGuide(.leading) { d in d.width / 2 - width * (model.tick ?? 0.5) }
                }
            }
            HStack(spacing: 10) {
                Capsule()
                    .fill(LinearGradient(stops: model.stops, startPoint: .leading, endPoint: .trailing))
                    .frame(width: width, height: 4)
                    .overlay(alignment: .leading) {
                        if let tick = model.tick {
                            Capsule().fill(.white).frame(width: 2, height: 10).offset(x: width * tick - 1)
                        }
                    }
                if let extra = model.extra {
                    HStack(spacing: 5) {
                        Capsule().fill(extra.color).frame(width: 12, height: 4)
                        Text(extra.label)
                    }
                }
            }
            HStack(spacing: 0) {
                Text(model.low)
                Spacer(minLength: 6)
                Text(model.high)
            }
            .frame(width: width)
        }
        .scaledFont(11, weight: .semibold)
        .monospacedDigit()
        .foregroundStyle(.white.opacity(0.85))
        .lineLimit(1)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .glassEffect(.regular, in: .rect(cornerRadius: 14))
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
    /// with a 3 pt white stroke and a dark centre; a 12 pt white dot with a
    /// 2 pt dark edge. Smaller sizes scale both.
    static func draw(_ kind: RouteEndpoint, in ctx: inout GraphicsContext, at c: CGPoint, size: CGFloat) {
        func circle(_ r: CGFloat) -> Path { Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)) }
        let casing = RoutePalette.casing.color
        let k = size / 14
        switch kind {
        case .start, .both:
            ctx.fill(circle(8 * k), with: .color(casing))
            ctx.fill(circle(7 * k), with: .color(.white))
            ctx.fill(circle(4 * k), with: .color(casing))
            if kind == .both { ctx.fill(circle(2 * k), with: .color(.white)) }
        case .end:
            ctx.fill(circle(8 * k), with: .color(casing))
            ctx.fill(circle(6 * k), with: .color(.white))
        }
    }
}

// MARK: - Score

/// The drive score band, for every score ring (header, cards, detail).
enum DriveScoreTint {
    static let good = Color.voltaGreen               // #5ECB93
    static let fair = Color(hex: 0xF5BE62)
    static let poor = Color(hex: 0xFF8178)

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
