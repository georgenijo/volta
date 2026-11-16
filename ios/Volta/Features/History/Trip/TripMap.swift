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
    /// metric was recorded at both ends; unsupported runs are neutral. In
    /// efficiency mode a supported run is further split into regen and
    /// consumption stretches (see `sides`). Runs are then cut into pieces and
    /// their coordinates thinned, which changes how finely a run is drawn but
    /// never which time it covers. Nothing is interpolated across a gap.
    ///
    /// There are never more than `maxPieces` pieces while the trip has at most
    /// that many recorded and unrecorded runs: regen and consumption
    /// stretches beyond the budget merge, shortest first. Runs themselves
    /// never merge (colour covers exactly the recorded time), so a route
    /// fragmented past the budget draws one piece per run.
    /// `tripKm` is the drive's own distance; without one the window uses the
    /// recorded positions' length.
    init(_ timeline: TripTimeline, mode: TripMapMode, tripKm: Double? = nil,
         maxPieces: Int = 160, maxCoordinatesPerPiece: Int = 16) {
        let points = timeline.points
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

        // Interval k runs from sample k to k + 1. Efficiency's windowed value
        // and distance per interval, filled inside supported runs.
        var windowedAt = [Double?](repeating: nil, count: points.count)
        var distanceAt = [Double](repeating: 0, count: points.count)
        var units: [Unit] = []
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
                if supported && mode == .efficiency {
                    // Efficiency colours by consumption over a rolling distance
                    // window inside this run, never per sample.
                    let intervals = (runStart..<runEnd).map { EfficiencyWindow.interval(points[$0], points[$0 + 1]) ?? .init(distanceKm: 0, energyKwh: 0) }
                    let windowed = EfficiencyWindow.smoothed(intervals, windowKm: window)
                    for (k, v) in windowed.enumerated() {
                        windowedAt[runStart + k] = v
                        distanceAt[runStart + k] = intervals[k].distanceKm
                    }
                    // A piece never spans a lasting change between regen and
                    // consumption: averaging a descent into a long piece would hide it.
                    for side in Self.sides(windowed, distances: intervals.map(\.distanceKm), windowKm: window) {
                        units.append(Unit(segment: n, intervals: (runStart + side.range.lowerBound)..<(runStart + side.range.upperBound),
                                          supported: true, regen: side.regen))
                    }
                } else {
                    units.append(Unit(segment: n, intervals: runStart..<runEnd, supported: supported, regen: nil))
                }
                runStart = runEnd
            }
        }
        units = Self.merged(units, toAtMost: maxPieces)

        var raw: [(indices: ClosedRange<Int>, value: Double?)] = []
        for (unit, count) in zip(units, Self.pieceCounts(units.map(\.intervals.count), budget: maxPieces)) {
            let length = Int((Double(unit.intervals.count) / Double(count)).rounded(.up))
            if let regen = unit.regen {
                // Each piece's colour is its own true mean, never forced: the
                // stretch only decides where pieces end (see `agreeingPieces`).
                for r in Self.agreeingPieces(unit.intervals, regen: regen, length: length, windowed: windowedAt, distances: distanceAt) {
                    raw.append((r.lowerBound...r.upperBound, Self.net(Self.distanceWeighted(windowedAt, distanceAt, range: r))))
                }
                continue
            }
            var i = unit.intervals.lowerBound
            while i < unit.intervals.upperBound {
                let end = min(i + length, unit.intervals.upperBound)
                raw.append((i...end, unit.supported ? value(points[i...end]) : nil))
                i = end
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

    /// Intervals that never share a piece with their neighbours: a position
    /// segment's run of recorded (or unrecorded) intervals, and in efficiency
    /// mode its regen or consumption stretch.
    struct Unit: Equatable {
        var segment: Int
        /// Interval indices (interval k runs from sample k to k + 1).
        var intervals: Range<Int>
        var supported: Bool
        /// Efficiency only: which side of zero the stretch is drawn on.
        var regen: Bool?
    }

    /// Means this close to zero (Wh/km) are rounding, not regen: a run that
    /// nets exactly zero sums to a few 1e-14 either side.
    static let rounding: Double = 1e-9

    /// A mean with rounding taken off: zero within `rounding`, else itself.
    static func net(_ v: Double?) -> Double? { v.map { abs($0) < rounding ? 0 : $0 } }

    /// A run's lasting regen and consumption stretches. A sign belongs to a
    /// stretch only when it persists for half the window (by distance); a flip
    /// that doesn't persist never splits, whatever its size, and is absorbed
    /// into its neighbours, shortest first. Persistence counts only intervals
    /// whose window is whole: near a run's ends the window shrinks, so one
    /// sample there can swing the windowed value without being evidence of
    /// anything. When no sign persists, the run is one stretch on the side of
    /// its net mean (consumption at zero). Unknown values
    /// continue the stretch they are in. The ranges cover the run in order.
    static func sides(_ windowed: [Double?], distances: [Double], windowKm: Double) -> [(range: Range<Int>, regen: Bool)] {
        let n = windowed.count
        guard n > 0 else { return [] }
        let half = windowKm / 2
        func d(_ k: Int) -> Double { k < distances.count ? distances[k] : 0 }
        let length = (0..<n).reduce(0.0) { $0 + d($1) }
        var stretches: [(start: Int, regen: Bool, held: Double)] = []
        var travelled = 0.0
        for k in 0..<n {
            let centre = travelled + d(k) / 2
            travelled += d(k)
            let whole = centre >= half - 1e-9 && length - centre >= half - 1e-9
            let regen = windowed[k].map { $0 < 0 } ?? stretches.last?.regen ?? false
            if let last = stretches.last, last.regen == regen {
                if whole { stretches[stretches.count - 1].held += d(k) }
            } else {
                stretches.append((k, regen, whole ? d(k) : 0))
            }
        }
        // Absorb flips that don't persist, shortest first; a stretch between
        // two others joins them into one.
        while stretches.count > 1 {
            var shortest: Int?
            for (i, s) in stretches.enumerated() where s.held < half - 1e-9 {
                if let j = shortest, stretches[j].held <= s.held { continue }
                shortest = i
            }
            guard let i = shortest else { break }
            if i == 0 {
                stretches[1].start = stretches[0].start
                stretches.remove(at: 0)
            } else if i == stretches.count - 1 {
                stretches.remove(at: i)
            } else {
                stretches[i - 1].held += stretches[i + 1].held
                stretches.removeSubrange(i...(i + 1))
            }
        }
        if stretches.count == 1, stretches[0].held < half - 1e-9 {
            stretches[0].regen = (net(distanceWeighted(windowed, (0..<n).map(d), range: 0..<n)) ?? 0) < 0
        }
        return stretches.enumerated().map { i, s in
            (s.start..<(i + 1 < stretches.count ? stretches[i + 1].start : n), s.regen)
        }
    }

    /// Cuts a stretch into pieces of at least `length` intervals, each
    /// extended until its own distance-weighted mean is on the stretch's side
    /// (negative for regen, otherwise not negative); a last piece that never
    /// gets there joins the one before it. The pieces' values are their true
    /// means: a flip that didn't persist widens a piece instead of being
    /// clamped, so a positive mean is never drawn as regen and a lasting
    /// negative one always is.
    static func agreeingPieces(_ range: Range<Int>, regen: Bool, length: Int, windowed: [Double?], distances: [Double]) -> [Range<Int>] {
        func agrees(_ r: Range<Int>) -> Bool {
            guard let v = net(distanceWeighted(windowed, distances, range: r)) else { return true }
            return regen ? v < 0 : v >= 0
        }
        var pieces: [Range<Int>] = []
        var start = range.lowerBound
        while start < range.upperBound {
            var sum = 0.0, weight = 0.0, plain = 0.0, count = 0.0
            func meanAgrees() -> Bool {
                let v: Double? = net(weight > 0 ? sum / weight : count > 0 ? plain / count : nil)
                guard let v else { return true }
                return regen ? v < 0 : v >= 0
            }
            var end = start
            while end < range.upperBound, end - start < max(1, length) || !meanAgrees() {
                if end < windowed.count, let v = windowed[end] {
                    let dist = end < distances.count ? distances[end] : 0
                    sum += v * dist; weight += dist; plain += v; count += 1
                }
                end += 1
            }
            pieces.append(start..<end)
            start = end
        }
        while pieces.count > 1, let last = pieces.last, !agrees(last) {
            pieces.removeLast()
            pieces[pieces.count - 1] = pieces[pieces.count - 1].lowerBound..<last.upperBound
        }
        return pieces
    }

    /// Merges units until there are at most `limit`. Only a run's regen and
    /// consumption stretches merge (the shortest first, into its longer
    /// neighbour, whose side it takes): recorded and unrecorded runs never
    /// do, so colour covers exactly the recorded time, and a piece never
    /// spans a gap.
    static func merged(_ input: [Unit], toAtMost limit: Int) -> [Unit] {
        var units = input
        while units.count > max(1, limit) {
            var best: (index: Int, into: Int, length: Int)?
            for (i, u) in units.enumerated() where u.regen != nil {
                let neighbours = [i - 1, i + 1].filter { j in
                    j >= 0 && j < units.count && units[j].segment == u.segment && units[j].regen != nil
                        && (j < i ? units[j].intervals.upperBound == u.intervals.lowerBound : u.intervals.upperBound == units[j].intervals.lowerBound)
                }
                guard let into = neighbours.max(by: { units[$0].intervals.count < units[$1].intervals.count }) else { continue }
                if let b = best, b.length <= u.intervals.count { continue }
                best = (i, into, u.intervals.count)
            }
            guard let best else { break }
            let a = units[best.index], b = units[best.into]
            units[best.into].intervals = min(a.intervals.lowerBound, b.intervals.lowerBound)..<max(a.intervals.upperBound, b.intervals.upperBound)
            units.remove(at: best.index)
        }
        return units
    }

    /// How many pieces each unit of `lengths` intervals is cut into: one each,
    /// and the rest of `budget` shared in proportion to length. The total never
    /// exceeds `budget` when there are at most `budget` units.
    static func pieceCounts(_ lengths: [Int], budget: Int) -> [Int] {
        let spare = max(0, budget - lengths.count)
        let extra = lengths.reduce(0) { $0 + max(0, $1 - 1) }
        return lengths.map { n in
            let share = extra > 0 ? (max(0, n - 1) * spare) / extra : 0
            return max(1, min(n, 1 + share))
        }
    }

    /// Distance-weighted mean of a run's windowed values over `range` (a
    /// piece covers several intervals when the route is long).
    private static func distanceWeighted(_ windowed: [Double?], _ distances: [Double], range: Range<Int>) -> Double? {
        var sum = 0.0, weight = 0.0, plain = 0.0, n = 0.0
        for k in range where k < windowed.count {
            guard let v = windowed[k] else { continue }
            let d: Double = distances[k]
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
    /// `hard` is the part of each margin that clears something covering the
    /// map (the toolbar, iPhone Duo's tab strip): it never gives way; only
    /// the decorative rest does. When the hard margins alone leave no area,
    /// the tiny-frame guards apply.
    static func fitted(_ content: MKMapRect, size: CGSize, safe: EdgeInsets, insets: EdgeInsets,
                       hard: EdgeInsets = EdgeInsets(), minContentHeight: CGFloat? = nil, strict: Bool = false) -> MKMapRect {
        guard size.width > 0, size.height > 0, content.width > 0, content.height > 0 else { return content }
        var insets = EdgeInsets(top: max(insets.top, hard.top), leading: max(insets.leading, hard.leading),
                                bottom: max(insets.bottom, hard.bottom), trailing: max(insets.trailing, hard.trailing))
        if !strict {
            // A short map keeps its bottom margin (it clears the attribution, logo and
            // Legal link) and gives up its top margin first, down to 24 pt, to give
            // the route `preferred` height. The bottom margin gives way only when
            // the route would otherwise get under 32 pt, and never past the fade.
            let preferred: CGFloat = minContentHeight ?? max(48, size.height * 0.2)
            let least: CGFloat = 32
            if size.height - insets.top - insets.bottom < preferred {
                insets.top = max(hard.top, min(insets.top, 24), size.height - insets.bottom - preferred)
            }
            if size.height - insets.top - insets.bottom < least {
                insets.bottom = max(hard.bottom, min(insets.bottom, safe.bottom), size.height - insets.top - least)
            }
            // Side margins over 60% of the width shrink, decorative part only.
            if insets.leading + insets.trailing > size.width * 0.6 {
                let loose: CGFloat = insets.leading - hard.leading + insets.trailing - hard.trailing
                let room: CGFloat = max(0, size.width * 0.6 - hard.leading - hard.trailing)
                let k: CGFloat = loose > 0 ? min(1, room / loose) : 1
                insets.leading = hard.leading + (insets.leading - hard.leading) * k
                insets.trailing = hard.trailing + (insets.trailing - hard.trailing) * k
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
    /// The part of `frameInsets` that clears something covering the map
    /// (toolbar, side strip): it never gives way on a small map.
    var hardInsets = EdgeInsets()
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

    /// `hardInsets` plus the markers' reach on each side that has one.
    private var fitHard: EdgeInsets {
        func reach(_ v: CGFloat) -> CGFloat { v > 0 ? v + Self.markerReach : 0 }
        return EdgeInsets(top: reach(hardInsets.top), leading: reach(hardInsets.leading),
                          bottom: reach(hardInsets.bottom), trailing: reach(hardInsets.trailing))
    }

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
        position = .fitting(TripRoute.fitted(content, size: size, safe: mapSafe, insets: fitInsets, hard: fitHard), replacing: position)
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
