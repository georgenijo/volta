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

/// How a trip's recorded values map onto the shared `RoutePalette`: speed and
/// efficiency on fixed domains, elevation across the trip's own range.
struct TripRouteStyle: Equatable {
    var mode: TripMapMode
    /// The trip's elevation range (elevation mode only).
    var valueRange: ClosedRange<Double>?
    var reference: EfficiencyReference
    /// The rolling window efficiency is averaged over (efficiency mode only).
    var windowKm: Double? = nil

    func rgb(_ value: Double) -> RoutePalette.RGB {
        switch mode {
        case .speed:
            return RoutePalette.speed(kph: value)
        case .efficiency:
            return RoutePalette.efficiency(whPerKm: value, reference: reference)
        case .elevation:
            guard let range = valueRange, range.upperBound > range.lowerBound else { return RoutePalette.elevation(fraction: 0) }
            return RoutePalette.elevation(fraction: (value - range.lowerBound) / (range.upperBound - range.lowerBound))
        }
    }

    func legend(units: UnitPreferences) -> RouteLegendModel? {
        switch mode {
        case .speed: return .speed(units: units)
        case .efficiency: return .efficiency(reference: reference, units: units, averagedOverKm: windowKm ?? EfficiencyWindow.minimumKm)
        case .elevation: return valueRange.map { .elevation(minM: $0.lowerBound, maxM: $0.upperBound, units: units) }
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
        /// The mode's metric over the piece (km/h, Wh/km or m); nil = not recorded.
        var value: Double?

        static func == (a: Piece, b: Piece) -> Bool {
            a.id == b.id && a.indices == b.indices && a.value == b.value && a.coordinates.count == b.coordinates.count
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
    /// Lowest to highest value; the elevation ramp spans it (elevation: the
    /// recorded samples' range, not the pieces' averages).
    var valueRange: ClosedRange<Double>?
    /// The efficiency colour's rolling window for this trip.
    var windowKm: Double = EfficiencyWindow.minimumKm

    /// Length of the recorded track, km: consecutive positions inside each
    /// position segment (never across a gap).
    static func recordedKm(_ timeline: TripTimeline) -> Double {
        let points = timeline.points
        var metres = 0.0
        for seg in timeline.segments where seg.count > 1 {
            for i in seg.lowerBound..<(seg.upperBound - 1) {
                metres += MKMapPoint(points[i].coordinate).distance(to: MKMapPoint(points[i + 1].coordinate))
            }
        }
        return metres / 1000
    }

    /// Whether the mode's metric is supported on the interval from timeline
    /// sample `i` to `i + 1` (same position segment): the metric is recorded
    /// and finite at both ends. Efficiency needs speed and power at both ends.
    /// A stop is recorded data (speed 0, idle power): it stays inside its
    /// efficiency run, so the rolling window counts its energy and carries on
    /// through it instead of restarting at every traffic light.
    static func supports(_ mode: TripMapMode, _ a: DrivePoint, _ b: DrivePoint) -> Bool {
        func finite(_ v: Double?) -> Bool { v.map(\.isFinite) ?? false }
        switch mode {
        case .speed: return finite(a.speedKph) && finite(b.speedKph)
        case .elevation: return finite(a.elevationM) && finite(b.elevationM)
        case .efficiency: return finite(a.speedKph) && finite(b.speedKph) && finite(a.powerKw) && finite(b.powerKw)
        }
    }

    /// Splits every position segment into runs of consecutive intervals that
    /// are all supported or all unsupported for `mode` *before* reducing
    /// anything for drawing, so a colored piece only ever spans intervals whose
    /// metric was recorded at both ends; unsupported runs are neutral. Long
    /// runs are cut into pieces of at most `stride` intervals and their
    /// coordinates thinned, which changes how finely a run is drawn but never
    /// which time it covers. Nothing is interpolated across a gap.
    /// `tripKm` is the drive's own distance; without one the window uses the
    /// recorded positions' length.
    init(_ timeline: TripTimeline, mode: TripMapMode, tripKm: Double? = nil, maxPieces: Int = 160, maxCoordinatesPerPiece: Int = 16) {
        let points = timeline.points
        let sampledCount = timeline.segments.reduce(0) { $0 + max(0, $1.count - 1) }
        let stride = max(1, Int((Double(sampledCount) / Double(maxPieces)).rounded(.up)))
        let km: Double = tripKm.flatMap { $0.isFinite && $0 > 0 ? $0 : nil } ?? Self.recordedKm(timeline)
        let window: Double = EfficiencyWindow.windowKm(forTripKm: km)

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
                // Efficiency colours by consumption over a rolling distance
                // window inside this run, never per sample.
                let intervals: [EfficiencyWindow.Interval]? = supported && mode == .efficiency
                    ? (runStart..<runEnd).map { EfficiencyWindow.interval(points[$0], points[$0 + 1]) ?? .init(distanceKm: 0, energyKwh: 0) }
                    : nil
                let windowed: [Double?]? = intervals.map { EfficiencyWindow.smoothed($0, windowKm: window) }
                var i = runStart
                while i < runEnd {
                    var end = min(i + stride, runEnd)
                    if let windowed {
                        // A piece never mixes regen with consumption: averaging a
                        // short descent into a long piece would hide it.
                        end = Self.signBreak(windowed, from: i - runStart, to: end - runStart) + runStart
                    }
                    let pieceValue: Double?
                    if !supported {
                        pieceValue = nil
                    } else if let windowed, let intervals {
                        pieceValue = Self.distanceWeighted(windowed, intervals, range: (i - runStart)..<(end - runStart))
                    } else {
                        pieceValue = value(points[i...end])
                    }
                    raw.append((i...end, pieceValue))
                    i = end
                }
                runStart = runEnd
            }
        }

        if mode == .elevation {
            // The trip's real range, from every finite recorded elevation
            // before pieces average it (two samples at 0 and 100 m span 0–100).
            let recorded = points.compactMap(\.elevationM).filter(\.isFinite)
            valueRange = recorded.min().flatMap { lo in recorded.max().map { lo...max($0, lo) } }
        } else {
            let values = raw.compactMap(\.value)
            valueRange = values.min().flatMap { lo in values.max().map { lo...max($0, lo) } }
        }
        windowKm = window
        pieces = raw.enumerated().map { n, r in
            let coords = Self.thin(points[r.indices].map(\.coordinate), to: maxCoordinatesPerPiece)
            return Piece(id: n, indices: r.indices, coordinates: coords, mapPoints: coords.map(MKMapPoint.init), value: r.value)
        }
        self.gaps = gaps
        self.isolated = isolated
    }

    /// The end of a piece starting at interval `from`: `to`, or earlier, at
    /// the first interval whose windowed value is on the other side of zero
    /// (regen versus consumption). Always at least one interval.
    static func signBreak(_ windowed: [Double?], from: Int, to: Int) -> Int {
        func regen(_ k: Int) -> Bool? { windowed[k].map { $0 < 0 } }
        var side = regen(from)
        var k = from + 1
        while k < to {
            if let r = regen(k) {
                if let s = side, r != s { return k }
                side = r
            }
            k += 1
        }
        return to
    }

    /// Distance-weighted mean of a run's windowed values over `range` (a
    /// piece covers several intervals when the route is long).
    private static func distanceWeighted(_ windowed: [Double?], _ intervals: [EfficiencyWindow.Interval], range: Range<Int>) -> Double? {
        var sum = 0.0, weight = 0.0, plain = 0.0, n = 0.0
        for k in range where k < windowed.count {
            guard let v = windowed[k] else { continue }
            let d: Double = intervals[k].distanceKm
            sum += v * d; weight += d; plain += v; n += 1
        }
        if weight > 0 { return sum / weight }
        return n > 0 ? plain / n : nil
    }

    /// Seconds of the trip drawn in color (pieces with a value).
    func coloredSeconds(_ timeline: TripTimeline) -> TimeInterval {
        pieces.filter { $0.value != nil }.reduce(0) {
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

    /// Every sample's bounding rect, at least ~1 km across so a lone sample
    /// isn't shown at maximum zoom. No padding: `fitted` adds it in points.
    static func contentRect(_ points: [DrivePoint]) -> MKMapRect? {
        guard let first = points.first else { return nil }
        var rect = MKMapRect(origin: MKMapPoint(first.coordinate), size: MKMapSize(width: 0, height: 0))
        for p in points.dropFirst() {
            rect = rect.union(MKMapRect(origin: MKMapPoint(p.coordinate), size: MKMapSize(width: 0, height: 0)))
        }
        let minSide = 1000 * MKMapPointsPerMeterAtLatitude(first.latitude)
        return rect.insetBy(dx: -max(0, minSide - rect.size.width) / 2, dy: -max(0, minSide - rect.size.height) / 2)
    }

    /// The rect to hand MapKit so `content` lands inside `insets` (points from
    /// each edge of a view of `size`), when MapKit fits the rect to the area
    /// left by the map's own safe-area padding `safe`. The rect has that
    /// area's aspect ratio, so MapKit shows it exactly. On a short map the
    /// route gets `minContentHeight` (default a fifth of the map, at least
    /// 48 pt) by giving up top inset, down to 24 pt; the bottom gives way only
    /// below 32 pt of route.
    /// `strict` keeps every margin as given (pins and the Drives hero): no
    /// margin gives way for size, only the tiny-frame guards below apply.
    static func fitted(_ content: MKMapRect, size: CGSize, safe: EdgeInsets, insets: EdgeInsets,
                       minContentHeight: CGFloat? = nil, strict: Bool = false) -> MKMapRect {
        guard size.width > 0, size.height > 0, content.width > 0, content.height > 0 else { return content }
        var insets = insets
        if !strict {
            // A short map keeps its bottom margin (it clears the attribution, logo and
            // Legal link) and gives up its top margin first, down to 24 pt, to give
            // the route `preferred` height. The bottom margin gives way only when
            // the route would otherwise get under 32 pt, and never past the fade.
            let preferred: CGFloat = minContentHeight ?? max(48, size.height * 0.2)
            let least: CGFloat = 32
            if size.height - insets.top - insets.bottom < preferred {
                insets.top = max(min(insets.top, 24), size.height - insets.bottom - preferred)
            }
            if size.height - insets.top - insets.bottom < least {
                insets.bottom = max(min(insets.bottom, safe.bottom), size.height - insets.top - least)
            }
            let horizontal: CGFloat = insets.leading + insets.trailing
            if horizontal > size.width * 0.6 {
                let k: CGFloat = size.width * 0.6 / horizontal
                insets.leading *= k; insets.trailing *= k
            }
        }
        // Too small a frame for the margins: frame the route in MapKit's own
        // area instead, and when even that is empty, hand MapKit the bare
        // content (the unpadded fit).
        let areaW: CGFloat = size.width - safe.leading - safe.trailing
        let areaH: CGFloat = size.height - safe.top - safe.bottom
        guard areaW >= 1, areaH >= 1 else { return content }
        if size.width - insets.leading - insets.trailing < 1 { insets.leading = safe.leading; insets.trailing = safe.trailing }
        if size.height - insets.top - insets.bottom < 1 { insets.top = safe.top; insets.bottom = safe.bottom }
        let wantW: CGFloat = size.width - insets.leading - insets.trailing
        let wantH: CGFloat = size.height - insets.top - insets.bottom
        let scale: Double = min(wantW / content.width, wantH / content.height)   // points per map point
        guard scale.isFinite, scale > 0 else { return content }
        // Map point that must sit at the safe area's top-left corner so the
        // content's centre lands at the centre of the wanted area.
        let wantMidX = insets.leading + wantW / 2, wantMidY = insets.top + wantH / 2
        let x = content.midX - (wantMidX - safe.leading) / scale
        let y = content.midY - (wantMidY - safe.top) / scale
        return MKMapRect(x: x, y: y, width: areaW / scale, height: areaH / scale)
    }

    /// Where `coordinate` falls in a view of `size` showing `visible`. Exact for
    /// the flat, unrotated camera this map allows (pan and zoom only).
    static func project(_ coordinate: CLLocationCoordinate2D, visible: MKMapRect, size: CGSize) -> CGPoint? {
        project(MKMapPoint(coordinate), visible: visible, size: size)
    }

    static func project(_ m: MKMapPoint, visible: MKMapRect, size: CGSize) -> CGPoint? {
        project(m, visible: visible, size: size, safe: EdgeInsets())
    }

    /// With safe-area padding on the map, the camera's visible rect is the
    /// padded area, not the whole view: map it onto that area.
    static func project(_ m: MKMapPoint, visible: MKMapRect, size: CGSize, safe: EdgeInsets) -> CGPoint? {
        let w = size.width - safe.leading - safe.trailing, h = size.height - safe.top - safe.bottom
        guard visible.width > 0, visible.height > 0, w > 0, h > 0 else { return nil }
        return CGPoint(x: safe.leading + (m.x - visible.minX) / visible.width * w,
                       y: safe.top + (m.y - visible.minY) / visible.height * h)
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
    var style: TripRouteStyle
    /// Highlighted sample (replay position or chart scrub), if any.
    var highlight: DrivePoint?
    /// The page fade at the bottom: MapKit's logo and Legal link sit just above it.
    var bottomInset: CGFloat = 0
    /// Where the route is framed, in points from each edge: clear of the top
    /// controls, the attribution and the fade (marker reach is added here).
    var frameInsets = EdgeInsets(top: 140, leading: 48, bottom: 96, trailing: 48)
    /// Safe-area edges the map runs under. In a split view's detail column,
    /// leave out the edge under the list column, or the camera frames the
    /// route partly behind it.
    var underEdges: Edge.Set = .all

    @State private var position: MapCameraPosition = .automatic
    /// The map's visible rect, from the latest camera change; nil until MapKit reports one.
    @State private var visible: MKMapRect?
    @State private var framedSize: CGSize?

    /// Endpoint markers reach this far past the route's own extent.
    static let markerReach: CGFloat = 8

    /// Where the route's extent is fitted: the caller's clearances plus the
    /// markers' reach, so no ring or dot touches the controls or the attribution.
    private var fitInsets: EdgeInsets {
        var insets = frameInsets
        insets.top += Self.markerReach
        insets.bottom += Self.markerReach
        insets.leading += Self.markerReach
        insets.trailing += Self.markerReach
        return insets
    }

    /// MapKit's own padding: the logo and Legal link sit in their native
    /// bottom-leading place, just above the fade.
    private var mapSafe: EdgeInsets { EdgeInsets(top: 0, leading: 0, bottom: bottomInset, trailing: 0) }

    var body: some View {
        // Both layers ignore the safe area so the canvas covers exactly the map's bounds.
        Map(position: $position, interactionModes: [.pan, .zoom])
            .mapControls { }
            .voltaBasemap()
            .onMapCameraChange(frequency: .continuous) { visible = $0.rect }
            .safeAreaPadding(mapSafe)
            .ignoresSafeArea(edges: underEdges)
            // MapKit draws into any safe area it touches; keep it to the edges asked for.
            .clipped()
            // Darker than MapKit's dark style so labels recede behind the route; the attribution stays clear.
            .voltaMapDim(0.4, bottom: bottomInset, ignoring: underEdges)
            .overlay {
                GeometryReader { geo in
                    ZStack {
                        if let visible {
                            TripRouteCanvas(projection: projection(visible: visible, size: geo.size), style: style)
                        }
                    }
                    .onChange(of: geo.size, initial: true) { _, size in frame(size) }
                }
                .ignoresSafeArea(edges: underEdges)
                .allowsHitTesting(false)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Trip route map")
    }

    /// Frames the whole trip once the map's size is known (again if it changes).
    private func frame(_ size: CGSize) {
        guard size.width > 0, size.height > 0, framedSize != size,
              let content = TripRoute.contentRect(timeline.points) else { return }
        framedSize = size
        position = .fitting(TripRoute.fitted(content, size: size, safe: mapSafe, insets: fitInsets), replacing: position)
    }

    private func projection(visible: MKMapRect, size: CGSize) -> TripRouteProjection {
        let safe = mapSafe
        func point(_ c: CLLocationCoordinate2D) -> CGPoint? { TripRoute.project(MKMapPoint(c), visible: visible, size: size, safe: safe) }
        let points = timeline.points
        let first = points.first, last = points.last
        // Start and end within a few metres: one ring with a dot.
        let loop = points.count > 1 && first.flatMap { f in last.map { DriveRouteSegments.meters(
            DriveRoutePoint(t: f.t, latitude: f.latitude, longitude: f.longitude),
            DriveRoutePoint(t: $0.t, latitude: $0.latitude, longitude: $0.longitude)) < 30 } } == true
        return TripRouteProjection(
            gaps: route.gaps.compactMap { g in point(g.from).flatMap { a in point(g.to).map { (a, $0) } } },
            pieces: route.pieces.map { piece in
                (points: piece.mapPoints.compactMap { TripRoute.project($0, visible: visible, size: size, safe: safe) }, value: piece.value)
            },
            // Endpoints have their own markers.
            isolated: route.isolated.filter { $0 != 0 && $0 != points.count - 1 }.compactMap { point(points[$0].coordinate) },
            start: first.flatMap { point($0.coordinate) },
            end: points.count > 1 && !loop ? last.flatMap { point($0.coordinate) } : nil,
            loop: loop || points.count == 1,
            highlight: highlight.flatMap { point($0.coordinate) })
    }
}

/// Screen positions of everything drawn over the map, for one camera.
struct TripRouteProjection {
    var gaps: [(CGPoint, CGPoint)]
    var pieces: [(points: [CGPoint], value: Double?)]
    var isolated: [CGPoint]
    var start: CGPoint?
    var end: CGPoint?
    /// Start and end coincide: the start marker carries the end dot.
    var loop = false
    var highlight: CGPoint?
}

private struct TripRouteCanvas: View {
    var projection: TripRouteProjection
    var style: TripRouteStyle

    private static func key(_ c: RoutePalette.RGB) -> Int { c.bucketKey }

    var body: some View {
        Canvas { ctx, _ in
            let p = projection
            for (a, b) in p.gaps {
                var path = Path()
                path.move(to: a)
                path.addLine(to: b)
                ctx.stroke(path, with: .color(.white.opacity(0.35)), style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [2, 6]))
            }
            // One dark casing under the whole route; then the stretches whose
            // metric wasn't recorded (thin grey); then colour by value.
            var casing = Path(), missing = Path()
            var buckets: [Int: (color: RoutePalette.RGB, path: Path)] = [:]
            // Consecutive pieces of one colour join into a single run, so the
            // run bends with round joins and a short change of colour shows at
            // its true length; runs end square (the casing rounds the ends).
            var run: (key: Int, color: RoutePalette.RGB, end: CGPoint, path: Path)?
            func flush() {
                guard let r = run else { return }
                if buckets[r.key] == nil { buckets[r.key] = (r.color, Path()) }
                buckets[r.key]!.path.addPath(r.path)
                run = nil
            }
            for piece in p.pieces {
                guard let first = piece.points.first, let last = piece.points.last, piece.points.count > 1 else { flush(); continue }
                var path = Path()
                path.move(to: first)
                for q in piece.points.dropFirst() { path.addLine(to: q) }
                casing.addPath(path)
                guard let value = piece.value else { flush(); missing.addPath(path); continue }
                let color: RoutePalette.RGB = style.rgb(value)
                let key: Int = Self.key(color)
                if var r = run, r.key == key, r.end == first {
                    for q in piece.points.dropFirst() { r.path.addLine(to: q) }
                    r.end = last
                    run = r
                } else {
                    flush()
                    run = (key, color, last, path)
                }
            }
            flush()
            let round = { (w: CGFloat) in StrokeStyle(lineWidth: w, lineCap: .round, lineJoin: .round) }
            ctx.stroke(casing, with: .color(RoutePalette.casing.color), style: round(RoutePalette.casingWidth))
            ctx.stroke(missing, with: .color(RoutePalette.missing.color), style: round(RoutePalette.missingWidth))
            let square = StrokeStyle(lineWidth: RoutePalette.lineWidth, lineCap: .butt, lineJoin: .round)
            for key in buckets.keys.sorted() {
                let bucket = buckets[key]!
                ctx.stroke(bucket.path, with: .color(bucket.color.color), style: square)
            }
            for q in p.isolated {
                RouteEndpointMarker.draw(.end, in: &ctx, at: q, size: 8)
            }
            if let end = p.end { RouteEndpointMarker.draw(.end, in: &ctx, at: end, size: 14) }
            if let start = p.start { RouteEndpointMarker.draw(p.loop ? .both : .start, in: &ctx, at: start, size: 14) }
            if let h = p.highlight {
                ctx.fill(Self.circle(h, 13), with: .color(.white.opacity(0.18)))
                ctx.fill(Self.circle(h, 8), with: .color(RoutePalette.casing.color))
                ctx.fill(Self.circle(h, 6), with: .color(.white))
            }
        }
    }

    private static func circle(_ c: CGPoint, _ r: CGFloat) -> Path {
        Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    }
}
