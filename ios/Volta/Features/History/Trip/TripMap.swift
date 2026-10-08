import MapKit
import SwiftUI

/// What the trip route is colored by.
enum TripMapMode: String, CaseIterable, Identifiable, Sendable {
    case speed, efficiency, elevation
    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .speed: "speedometer"
        case .efficiency: "bolt.fill"
        case .elevation: "mountain.2.fill"
        }
    }

    var title: String { rawValue.capitalized }
}

/// Continuous color ramps for the route. Each ramp is a list of RGB stops.
enum TripPalette {
    struct RGB: Equatable { var r, g, b: Double }

    static let speed: [RGB] = [RGB(r: 0.13, g: 0.77, b: 0.37), RGB(r: 0.92, g: 0.80, b: 0.20), RGB(r: 0.96, g: 0.45, b: 0.18), RGB(r: 0.94, g: 0.27, b: 0.27)]
    static let efficiency: [RGB] = speed
    static let elevation: [RGB] = [RGB(r: 0.23, g: 0.51, b: 0.96), RGB(r: 0.45, g: 0.80, b: 0.85), RGB(r: 0.65, g: 0.55, b: 0.98)]

    /// Fixed efficiency reference band (Wh/km) so colors mean the same across trips.
    static let efficiencyBand: ClosedRange<Double> = 90...310

    static func rgb(_ fraction: Double, stops: [RGB]) -> RGB {
        guard stops.count > 1 else { return stops.first ?? RGB(r: 1, g: 1, b: 1) }
        let f = min(max(fraction.isFinite ? fraction : 0, 0), 1) * Double(stops.count - 1)
        let i = min(Int(f), stops.count - 2)
        let t = f - Double(i)
        let a = stops[i], b = stops[i + 1]
        return RGB(r: a.r + (b.r - a.r) * t, g: a.g + (b.g - a.g) * t, b: a.b + (b.b - a.b) * t)
    }

    static func color(_ fraction: Double, stops: [RGB]) -> Color {
        let c = rgb(fraction, stops: stops)
        return Color(red: c.r, green: c.g, blue: c.b)
    }

    static func stops(_ mode: TripMapMode) -> [RGB] {
        switch mode {
        case .speed: speed
        case .efficiency: efficiency
        case .elevation: elevation
        }
    }
}

/// Route pieces for the map: colored pieces where the mode's metric was
/// recorded, neutral pieces where it wasn't, and plain markers for gaps. Gap
/// connectors are drawn dashed and gray, never as route.
struct TripRoute: Equatable {
    struct Piece: Identifiable, Equatable {
        var id: Int
        /// Timeline indices of the piece's first and last sample: the piece
        /// draws exactly the recorded positions in this range (thinned).
        var indices: ClosedRange<Int>
        var coordinates: [CLLocationCoordinate2D]
        /// `coordinates` as map points, so projecting per camera change is a
        /// linear transform.
        var mapPoints: [MKMapPoint]
        /// 0...1 along the mode's ramp; nil = metric not recorded for this piece.
        var fraction: Double?

        static func == (a: Piece, b: Piece) -> Bool {
            a.id == b.id && a.indices == b.indices && a.fraction == b.fraction && a.coordinates.count == b.coordinates.count
                && zip(a.coordinates, b.coordinates).allSatisfy { $0.latitude == $1.latitude && $0.longitude == $1.longitude }
        }
    }

    struct Gap: Identifiable, Equatable {
        var id: Int
        var from: CLLocationCoordinate2D
        var to: CLLocationCoordinate2D
        static func == (a: Gap, b: Gap) -> Bool {
            a.id == b.id && a.from.latitude == b.from.latitude && a.from.longitude == b.from.longitude
                && a.to.latitude == b.to.latitude && a.to.longitude == b.to.longitude
        }
    }

    var pieces: [Piece]
    var gaps: [Gap]
    /// Samples that form a segment on their own (no neighbours within the gap threshold).
    var isolated: [Int]
    var valueRange: ClosedRange<Double>?

    /// Mean speed (km/h) an efficiency interval needs: below it Wh/km divides by ~0.
    static let minEfficiencySpeedKph = 3.0

    /// Whether the mode's metric is supported on the interval from timeline
    /// sample `i` to `i + 1` (same position segment): the metric is recorded
    /// and finite at both ends. Efficiency needs speed and power at both ends
    /// and a mean speed above `minEfficiencySpeedKph`.
    static func supports(_ mode: TripMapMode, _ a: DrivePoint, _ b: DrivePoint) -> Bool {
        func finite(_ v: Double?) -> Double? { v.flatMap { $0.isFinite ? $0 : nil } }
        switch mode {
        case .speed: return finite(a.speedKph) != nil && finite(b.speedKph) != nil
        case .elevation: return finite(a.elevationM) != nil && finite(b.elevationM) != nil
        case .efficiency:
            guard let s0 = finite(a.speedKph), let s1 = finite(b.speedKph),
                  finite(a.powerKw) != nil, finite(b.powerKw) != nil else { return false }
            return (s0 + s1) / 2 > minEfficiencySpeedKph
        }
    }

    /// Splits every position segment into runs of consecutive intervals that
    /// are all supported or all unsupported for `mode` *before* reducing
    /// anything for drawing, so a colored piece only ever spans intervals whose
    /// metric was recorded at both ends; unsupported runs are neutral. Long
    /// runs are cut into pieces of at most `stride` intervals and their
    /// coordinates thinned, which changes how finely a run is drawn but never
    /// which time it covers. Nothing is interpolated across a gap.
    init(_ timeline: TripTimeline, mode: TripMapMode, maxPieces: Int = 160, maxCoordinatesPerPiece: Int = 16) {
        let points = timeline.points
        let sampledCount = timeline.segments.reduce(0) { $0 + max(0, $1.count - 1) }
        let stride = max(1, Int((Double(sampledCount) / Double(maxPieces)).rounded(.up)))

        func value(_ chunk: ArraySlice<DrivePoint>) -> Double? {
            switch mode {
            case .speed:
                let s = chunk.compactMap(\.speedKph)
                return s.isEmpty ? nil : s.reduce(0, +) / Double(s.count)
            case .efficiency:
                return RouteBuilder.efficiencyWhPerKm(chunk)
            case .elevation:
                let e = chunk.compactMap(\.elevationM)
                return e.isEmpty ? nil : e.reduce(0, +) / Double(e.count)
            }
        }

        var raw: [(indices: ClosedRange<Int>, value: Double?)] = []
        var isolated: [Int] = []
        var gaps: [Gap] = []
        for (n, seg) in timeline.segments.enumerated() {
            if n > 0 {
                gaps.append(Gap(id: n, from: points[seg.lowerBound - 1].coordinate, to: points[seg.lowerBound].coordinate))
            }
            guard seg.count > 1 else { isolated.append(seg.lowerBound); continue }
            var runStart = seg.lowerBound
            while runStart < seg.upperBound - 1 {
                let supported = Self.supports(mode, points[runStart], points[runStart + 1])
                var runEnd = runStart + 1
                while runEnd < seg.upperBound - 1, Self.supports(mode, points[runEnd], points[runEnd + 1]) == supported { runEnd += 1 }
                var i = runStart
                while i < runEnd {
                    let end = min(i + stride, runEnd)
                    raw.append((i...end, supported ? value(points[i...end]) : nil))
                    i = end
                }
                runStart = runEnd
            }
        }

        let values = raw.compactMap(\.value)
        let range: ClosedRange<Double>?
        switch mode {
        case .efficiency: range = TripPalette.efficiencyBand
        case .speed: range = values.max().map { 0...max($0, 1) }
        case .elevation: range = values.min().flatMap { lo in values.max().map { lo...max($0, lo + 1) } }
        }
        valueRange = range
        pieces = raw.enumerated().map { n, r in
            let fraction = r.value.flatMap { v in range.map { (v - $0.lowerBound) / ($0.upperBound - $0.lowerBound) } }
            let coords = Self.thin(points[r.indices].map(\.coordinate), to: maxCoordinatesPerPiece)
            return Piece(id: n, indices: r.indices, coordinates: coords, mapPoints: coords.map(MKMapPoint.init),
                         fraction: fraction.map { min(max($0, 0), 1) })
        }
        self.gaps = gaps
        self.isolated = isolated
    }

    /// Seconds of the trip drawn in color (pieces with a value).
    func coloredSeconds(_ timeline: TripTimeline) -> TimeInterval {
        pieces.filter { $0.fraction != nil }.reduce(0) {
            $0 + timeline.points[$1.indices.upperBound].t.timeIntervalSince(timeline.points[$1.indices.lowerBound].t)
        }
    }

    /// Evenly thins a piece's coordinates for drawing, keeping both ends so
    /// pieces still join. The piece's value is computed from every sample.
    static func thin(_ coords: [CLLocationCoordinate2D], to limit: Int) -> [CLLocationCoordinate2D] {
        guard coords.count > limit, limit >= 2 else { return coords }
        let step = Double(coords.count - 1) / Double(limit - 1)
        return (0..<limit).map { coords[Int((Double($0) * step).rounded())] }
    }

    /// Map rect around every sample, padded so the route isn't on the edge and
    /// extra at the top and bottom for the header controls and the fade.
    static func framing(_ points: [DrivePoint]) -> MapCameraPosition {
        guard let rect = framingRect(points) else { return .automatic }
        return .rect(rect)
    }

    static func framingRect(_ points: [DrivePoint]) -> MKMapRect? {
        guard let first = points.first else { return nil }
        var rect = MKMapRect(origin: MKMapPoint(first.coordinate), size: MKMapSize(width: 0, height: 0))
        for p in points.dropFirst() {
            rect = rect.union(MKMapRect(origin: MKMapPoint(p.coordinate), size: MKMapSize(width: 0, height: 0)))
        }
        // ~1 km minimum so a lone sample isn't shown at maximum zoom.
        let minSide = 1000 * MKMapPointsPerMeterAtLatitude(first.latitude)
        let side = max(rect.size.width, rect.size.height, minSide)
        rect = rect.insetBy(dx: -(side * 0.15 + max(0, minSide - rect.size.width) / 2),
                            dy: -(side * 0.15 + max(0, minSide - rect.size.height) / 2))
        // Map points grow southward: room above for the header, below for the fade.
        return MKMapRect(x: rect.minX, y: rect.minY - side * 0.55, width: rect.width, height: rect.height + side * 0.75)
    }

    /// Where `coordinate` falls in a view of `size` showing `visible`. Exact for
    /// the flat, unrotated camera this map allows (pan and zoom only).
    static func project(_ coordinate: CLLocationCoordinate2D, visible: MKMapRect, size: CGSize) -> CGPoint? {
        project(MKMapPoint(coordinate), visible: visible, size: size)
    }

    static func project(_ m: MKMapPoint, visible: MKMapRect, size: CGSize) -> CGPoint? {
        guard visible.width > 0, visible.height > 0 else { return nil }
        return CGPoint(x: (m.x - visible.minX) / visible.width * size.width,
                       y: (m.y - visible.minY) / visible.height * size.height)
    }
}

/// The trip map: a desaturated, dark MapKit base (muted monochrome like the
/// rest of the screen) with the route drawn on top in color. The route is not
/// MapKit content because content shares the base map's desaturation; it is
/// projected from the camera's visible rect into a Canvas over the same extent,
/// redrawn on every camera change.
struct TripMapView: View {
    var timeline: TripTimeline
    var route: TripRoute
    var mode: TripMapMode
    /// Highlighted sample (replay position or chart scrub), if any.
    var highlight: DrivePoint?

    @State private var position: MapCameraPosition
    /// The map's visible rect, from the latest camera change; nil until MapKit reports one.
    @State private var visible: MKMapRect?

    init(timeline: TripTimeline, route: TripRoute, mode: TripMapMode, highlight: DrivePoint?) {
        self.timeline = timeline
        self.route = route
        self.mode = mode
        self.highlight = highlight
        _position = State(initialValue: TripRoute.framing(timeline.points))
    }

    var body: some View {
        // Both layers ignore the safe area so the canvas covers exactly the map's bounds.
        Map(position: $position, interactionModes: [.pan, .zoom])
            .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
            .mapControls { }
            .environment(\.colorScheme, .dark)
            .saturation(0)
            .brightness(-0.06)
            .onMapCameraChange(frequency: .continuous) { visible = $0.rect }
            .ignoresSafeArea()
            .overlay {
                GeometryReader { geo in
                    if let visible {
                        TripRouteCanvas(projection: projection(visible: visible, size: geo.size), stops: TripPalette.stops(mode))
                    }
                }
                .ignoresSafeArea()
                .allowsHitTesting(false)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Trip route map")
    }

    private func projection(visible: MKMapRect, size: CGSize) -> TripRouteProjection {
        func point(_ c: CLLocationCoordinate2D) -> CGPoint? { TripRoute.project(c, visible: visible, size: size) }
        let points = timeline.points
        return TripRouteProjection(
            gaps: route.gaps.compactMap { g in point(g.from).flatMap { a in point(g.to).map { (a, $0) } } },
            pieces: route.pieces.map { piece in
                (points: piece.mapPoints.compactMap { TripRoute.project($0, visible: visible, size: size) }, fraction: piece.fraction)
            },
            // Endpoints have their own markers.
            isolated: route.isolated.filter { $0 != 0 && $0 != points.count - 1 }.compactMap { point(points[$0].coordinate) },
            start: points.first.flatMap { point($0.coordinate) },
            end: points.count > 1 ? points.last.flatMap { point($0.coordinate) } : nil,
            highlight: highlight.flatMap { point($0.coordinate) })
    }
}

/// Screen positions of everything drawn over the map, for one camera.
struct TripRouteProjection {
    var gaps: [(CGPoint, CGPoint)]
    var pieces: [(points: [CGPoint], fraction: Double?)]
    var isolated: [CGPoint]
    var start: CGPoint?
    var end: CGPoint?
    var highlight: CGPoint?
}

private struct TripRouteCanvas: View {
    var projection: TripRouteProjection
    var stops: [TripPalette.RGB]

    static let colorSteps = 48

    var body: some View {
        Canvas { ctx, _ in
            let p = projection
            for (a, b) in p.gaps {
                var path = Path()
                path.move(to: a)
                path.addLine(to: b)
                ctx.stroke(path, with: .color(.white.opacity(0.35)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [2, 6]))
            }
            // The whole route is drawn neutral first; color goes on top only
            // along pieces whose metric was recorded. Colored strokes use butt
            // caps so a short recorded interval is drawn no longer than it is
            // (round caps would grow every 3 s piece into a dot that merges
            // with its neighbours). One path per color step keeps a route split
            // into thousands of pieces to a handful of strokes.
            var neutral = Path()
            var buckets: [Int: Path] = [:]
            for piece in p.pieces {
                guard let first = piece.points.first, piece.points.count > 1 else { continue }
                neutral.move(to: first)
                for q in piece.points.dropFirst() { neutral.addLine(to: q) }
                guard let fraction = piece.fraction else { continue }
                let key = Int((fraction * Double(Self.colorSteps)).rounded())
                buckets[key, default: Path()].move(to: first)
                for q in piece.points.dropFirst() { buckets[key]!.addLine(to: q) }
            }
            let colored = buckets.keys.sorted().map { key in
                (buckets[key]!, TripPalette.color(Double(key) / Double(Self.colorSteps), stops: stops))
            }
            ctx.stroke(neutral, with: .color(.white.opacity(0.15)), style: StrokeStyle(lineWidth: 12, lineCap: .round, lineJoin: .round))
            for (path, color) in colored {
                ctx.stroke(path, with: .color(color.opacity(0.28)), style: StrokeStyle(lineWidth: 12, lineCap: .butt, lineJoin: .round))
            }
            ctx.stroke(neutral, with: .color(.white.opacity(0.6)), style: StrokeStyle(lineWidth: 4.5, lineCap: .round, lineJoin: .round))
            for (path, color) in colored {
                ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: 4.5, lineCap: .butt, lineJoin: .round))
            }
            for q in p.isolated { ctx.fill(Self.circle(q, 3.5), with: .color(.white.opacity(0.85))) }
            if let start = p.start { Self.endpoint(&ctx, start, HistoryTheme.green) }
            if let end = p.end { Self.endpoint(&ctx, end, HistoryTheme.red) }
            if let h = p.highlight {
                ctx.fill(Self.circle(h, 15), with: .color(.white.opacity(0.22)))
                var shadowed = ctx
                shadowed.addFilter(.shadow(color: .black.opacity(0.5), radius: 3))
                shadowed.fill(Self.circle(h, 6.5), with: .color(.white))
            }
        }
    }

    private static func circle(_ c: CGPoint, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    }

    private static func endpoint(_ ctx: inout GraphicsContext, _ c: CGPoint, _ color: Color) {
        ctx.fill(circle(c, 11), with: .color(color.opacity(0.3)))
        ctx.fill(circle(c, 5.5), with: .color(color))
        ctx.stroke(circle(c, 4.75), with: .color(.white.opacity(0.9)), lineWidth: 1.5)
    }
}
