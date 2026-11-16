import MapKit
import SwiftUI

/// Small open score dial tinted by band; the card-sized `ScoreDial`.
struct DriveScoreRing: View {
    var score: Int?
    var size: CGFloat = 44
    var body: some View { ScoreDial(score: score, size: size) }
}

enum DriveRouteSegments {
    /// A flagged break shorter than this, in time and in distance, is bridged.
    static let jitterSeconds: TimeInterval = 300
    static let jitterMeters = 1_000.0

    /// Break flags mark a recording gap before a point. A short hop (both
    /// close in time and close in space) bridges as one line: the straight
    /// join is within the road's width at map scale. A long hop stays broken,
    /// so sparse polling never draws a straight line across the map. Invalid
    /// positions still break the line in `runs`.
    static func tolerant(_ points: [DriveRoutePoint]) -> [DriveRoutePoint] {
        var result = points
        for index in result.indices.dropFirst() where result[index].routeBreakBefore == true {
            let previous = result[index - 1], point = result[index]
            if point.t.timeIntervalSince(previous.t) <= jitterSeconds,
               meters(previous, point) <= jitterMeters { result[index].routeBreakBefore = nil }
        }
        return result
    }

    static func meters(_ a: DriveRoutePoint, _ b: DriveRoutePoint) -> Double {
        let rad = Double.pi / 180
        let dLat = (b.latitude - a.latitude) * rad, dLon = (b.longitude - a.longitude) * rad
        let h = sin(dLat / 2) * sin(dLat / 2) + cos(a.latitude * rad) * cos(b.latitude * rad) * sin(dLon / 2) * sin(dLon / 2)
        let d = 2 * 6_371_000 * asin(min(1, sqrt(max(0, h))))
        return d.isFinite ? d : .infinity
    }

    static func runs(_ points: [DriveRoutePoint]) -> [[DriveRoutePoint]] {
        var runs: [[DriveRoutePoint]] = []
        var breakPending = true
        for point in points {
            guard point.latitude.isFinite, point.longitude.isFinite,
                  (-90...90).contains(point.latitude), (-180...180).contains(point.longitude) else { breakPending = true; continue }
            if breakPending || point.routeBreakBefore == true { runs.append([]) }
            runs[runs.count - 1].append(point)
            breakPending = false
        }
        return runs
    }

    /// Fit a local coordinate projection into the thumbnail without stretching
    /// or joining runs. Invalid positions break the path rather than bridging it.
    static func normalized(_ points: [DriveRoutePoint], in size: CGSize, inset: CGFloat = 8) -> [[CGPoint]] {
        let segments = runs(points)
        let valid = segments.flatMap { $0 }
        guard let origin = valid.first, size.width > 0, size.height > 0 else { return [] }
        let longitudeScale = max(cos(origin.latitude * .pi / 180), 0.00001)
        let projected = segments.map { run in
            run.map { point in
                var delta = point.longitude - origin.longitude
                if delta > 180 { delta -= 360 }
                if delta < -180 { delta += 360 }
                return CGPoint(x: delta * longitudeScale, y: origin.latitude - point.latitude)
            }
        }
        let all = projected.flatMap { $0 }
        let minX = all.map(\.x).min()!, maxX = all.map(\.x).max()!
        let minY = all.map(\.y).min()!, maxY = all.map(\.y).max()!
        let width = max(size.width - inset * 2, 0), height = max(size.height - inset * 2, 0)
        let scale = min(width / max(maxX - minX, 1e-9), height / max(maxY - minY, 1e-9))
        return projected.map { run in
            run.map { CGPoint(x: size.width / 2 + ($0.x - (minX + maxX) / 2) * scale,
                              y: size.height / 2 + ($0.y - (minY + maxY) / 2) * scale) }
        }
    }
}

/// Coordinate-only overview; no geocoding or directions, no joins across recording gaps.
/// Routes draw over a dark, desaturated map: plain blue (a roadtrip's few
/// drives), or by road density or efficiency on the shared `RoutePalette`
/// ramps (every all-drives map). No glow.
/// Single positions (sparse polling) are not drawn: a lone dot reads as a
/// place, not a route. The bottom edge fades into the page over at most 64 pt,
/// and MapKit's logo and Legal link sit just above that fade.
struct DrivesRouteMap: View {
    enum Coloring: Hashable {
        /// One plain colour.
        case plain
        /// Distinct drives per stretch of road.
        case density
        /// Distance-weighted efficiency per stretch, against the reference.
        case efficiency(EfficiencyReference)
    }

    var drives: [DriveSummary]
    var height: CGFloat = 240
    var coloring: Coloring = .plain
    /// Full-bleed hero: the map runs under the status bar and header (`topInset`
    /// keeps routes clear of the status bar) and fades out only at the bottom.
    var fullBleed = false
    var topInset: CGFloat = 0
    /// Route width; maps of many drives at region scale draw thinner than a trip.
    var lineWidth: CGFloat = 3
    /// The dark casing under the routes.
    var casingWidth: CGFloat = 5

    static let fade: CGFloat = VoltaMapChrome.fade

    @Environment(\.units) private var units
    @State private var visible: MKMapRect?
    @State private var layer: RouteDensity.Layer?
    @State private var position: MapCameraPosition = .automatic
    @State private var mapSize: CGSize = .zero
    private static let space = "drives.route.map"
    /// The area MapKit fits the camera into, as insets from the map's edges:
    /// our padding plus whatever safe area it inherits (iPhone Duo's side
    /// strip, the status bar). Measured from MapKit itself; nil until then.
    @State private var mapInsets: EdgeInsets?
    @State private var digests = RouteDigests()

    private struct FrameKey: Equatable { var size: CGSize; var insets: EdgeInsets? }

    /// The map's real safe area, once measured.
    private var safe: EdgeInsets { mapInsets ?? Self.mapSafe() }

    private var runs: [[CLLocationCoordinate2D]] {
        drives.flatMap { drive in
            DriveRouteSegments.runs(drive.drawableRoute).filter { $0.count > 1 }.map { run in
                run.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }
            }
        }
    }

    /// MapKit's padding: only the fade, so the logo and Legal link sit just
    /// above it in the bottom leading corner. No top padding: MapKit hides its
    /// logo on a short padded area, and the routes' clearance below the bars
    /// is kept by `camera` instead.
    static func mapSafe() -> EdgeInsets { EdgeInsets(top: 0, leading: 0, bottom: fade, trailing: 0) }

    /// Where routes are kept in a map: at least 24 pt below the bars
    /// (`topInset` is the page's safe area, which already ends a little under
    /// the floating toolbar, so the hero adds 12), 32 pt from the sides, and
    /// 24 pt above the fade. The short hero's routes are centred, clear of the
    /// logo in the leading corner; a taller map also keeps 24 pt above the
    /// attribution itself.
    static func clearance(topInset: CGFloat, fullBleed: Bool) -> EdgeInsets {
        EdgeInsets(top: topInset + (fullBleed ? 12 : 24), leading: 32,
                   bottom: fade + (fullBleed ? 0 : VoltaMapChrome.attribution) + 24, trailing: 32)
    }

    /// The camera rect framing `runs` in a map of `size`. The margins never
    /// give way, so however the map is laid out the camera never shows more
    /// than the routes plus those margins.
    /// `safe` is the safe area MapKit fits into (measured; by default only
    /// our padding).
    static func camera(_ runs: [[CLLocationCoordinate2D]], size: CGSize, topInset: CGFloat, fullBleed: Bool,
                       safe: EdgeInsets = mapSafe()) -> MKMapRect? {
        guard let content = voltaBounds(runs.joined().map(MKMapPoint.init)) else { return nil }
        return TripRoute.fitted(content, size: size, safe: safe, insets: clearance(topInset: topInset, fullBleed: fullBleed), strict: true)
    }

    private var fadeMask: some View {
        VStack(spacing: 0) {
            if !fullBleed {
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom).frame(height: 24)
            }
            Color.black
            LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom).frame(height: Self.fade)
        }
    }

    /// What the layer depends on: every drive's route contents (a digest of
    /// each point's time, coordinate and break flag), its consumption, and the
    /// reference. Correcting one interior coordinate or a break flag rebuilds it.
    struct LayerKey: Hashable {
        struct Revision: Hashable { var id: Int; var route: UInt64; var whPerKm: Double? }
        var coloring: Coloring
        var reference: EfficiencyReference
        var drives: [Revision]

        static func make(_ drives: [DriveSummary], coloring: Coloring, reference: EfficiencyReference, digests: RouteDigests) -> LayerKey {
            LayerKey(coloring: coloring, reference: reference, drives: drives.map {
                Revision(id: $0.id, route: digests.digest($0), whPerKm: $0.displayEfficiencyWhPerKm)
            })
        }
    }

    private var reference: EfficiencyReference {
        if case .efficiency(let reference) = coloring { return reference }
        return EfficiencyReference(drives: drives)
    }

    private var layerKey: LayerKey? {
        guard coloring != .plain else { return nil }
        return LayerKey.make(drives, coloring: coloring, reference: reference, digests: digests)
    }

    var body: some View {
        let runs = runs
        ZStack {
            if runs.isEmpty {
                Text("Routes not recorded for these drives").scaledFont(13, weight: .medium).foregroundStyle(HistoryTheme.secondary)
                    .padding(.top, topInset)
            } else {
                MapReader { proxy in
                    Map(position: $position, interactionModes: [])
                        .voltaBasemap()
                        .safeAreaPadding(Self.mapSafe())
                        .onMapCameraChange(frequency: .continuous) { context in
                            visible = context.rect
                            measureArea(proxy, visible: context.rect)
                        }
                        // Dark: roads read as texture, labels stay dim; the attribution stays clear.
                        .voltaMapDim(fullBleed ? 0.55 : 0.45, bottom: Self.fade)
                        .overlay { routes(runs).allowsHitTesting(false) }
                        .onGeometryChange(for: CGSize.self) { $0.size } action: { mapSize = $0 }
                        .onChange(of: FrameKey(size: mapSize, insets: mapInsets), initial: true) { frame(runs: runs) }
                        // Once the map has settled, measure again: the first
                        // camera reports can come before MapKit has placed it.
                        .task(id: mapSize) {
                            try? await Task.sleep(for: .milliseconds(350))
                            if let visible { measureArea(proxy, visible: visible) }
                        }
                }
                // Measured in the map's own space, which moves with it (a push
                // transition doesn't skew the measurement).
                .coordinateSpace(.named(Self.space))
                        .mask { fadeMask }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
        .task(id: layerKey) { await buildLayer() }
    }

    /// The map and its legend read as one element: what is drawn, then the
    /// legend's own sentence (density bounds, or the efficiency reference and
    /// whether it is estimated).
    private var accessibilityText: String {
        let base = "Recorded routes for loaded drives."
        switch coloring {
        case .plain: return base
        case .density: return base + " " + RouteLegendModel.density.sentence
        case .efficiency(let reference):
            return base + " " + RouteLegendModel.efficiency(reference: reference, units: units).sentence
        }
    }

    private func frame(runs: [[CLLocationCoordinate2D]]) {
        let size = mapSize
        guard size.width > 0, size.height > 0,
              let rect = Self.camera(runs, size: size, topInset: topInset, fullBleed: fullBleed, safe: safe) else { return }
        // Re-applied even when equal to the last fit: MapKit refits on resize.
        position = .fitting(rect, replacing: position)
    }

    /// Where the camera's visible rect lands on screen is the area MapKit
    /// fits into. Framing and drawing use it, so both agree with the tiles
    /// whatever safe area the map inherits.
    private func measureArea(_ proxy: MapProxy, visible: MKMapRect) {
        guard mapSize.width > 0, mapSize.height > 0,
              let a = proxy.convert(MKMapPoint(x: visible.minX, y: visible.minY).coordinate, to: .named(Self.space)),
              let b = proxy.convert(MKMapPoint(x: visible.maxX, y: visible.maxY).coordinate, to: .named(Self.space)) else { return }
        func r(_ v: CGFloat) -> CGFloat { (v * 2).rounded() / 2 }
        let measured = EdgeInsets(top: r(a.y), leading: r(a.x), bottom: r(mapSize.height - b.y), trailing: r(mapSize.width - b.x))
        // Before MapKit has placed the map the conversion can be far off
        // (hundreds of points outside the map): only an area inside the map counts.
        let edges = [measured.top, measured.leading, measured.bottom, measured.trailing]
        guard edges.allSatisfy({ $0.isFinite && $0 >= -0.5 }),
              measured.top + measured.bottom < mapSize.height - 1,
              measured.leading + measured.trailing < mapSize.width - 1 else { return }
        if let old = mapInsets, abs(old.top - measured.top) < 1, abs(old.leading - measured.leading) < 1,
           abs(old.bottom - measured.bottom) < 1, abs(old.trailing - measured.trailing) < 1 { return }
        mapInsets = measured
    }

    /// Counts off the main thread; plain maps need no layer. Leaving the
    /// screen or changing the selection cancels this task, and the
    /// cancellation is forwarded to the worker, which stops between drives.
    private func buildLayer() async {
        guard coloring != .plain else { layer = nil; return }
        let input = drives.map { RouteDensity.Drive($0, reference: reference) }
        let worker = Task.detached(priority: .userInitiated) { RouteDensity.build(input) }
        let built = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        if !Task.isCancelled, let built { layer = built }
    }

    /// A stroke's colour: density by count, or efficiency by ratio, where a
    /// negative ratio (net regeneration) takes the shared regen colour.
    static func strokeColor(_ stroke: RouteDensity.Stroke, coloring: Coloring) -> RoutePalette.RGB? {
        switch coloring {
        case .efficiency: return stroke.ratio.map { RoutePalette.efficiency(ratio: $0) }
        default: return RoutePalette.density(count: stroke.count)
        }
    }

    private func routes(_ runs: [[CLLocationCoordinate2D]]) -> some View {
        Canvas { context, size in
            // `visible` changes with the camera and redraws the routes.
            guard let visible else { return }
            let safe = self.safe
            let transform = { (m: MKMapPoint) in TripRoute.project(m, visible: visible, size: size, safe: safe) ?? .zero }
            let casing = StrokeStyle(lineWidth: casingWidth, lineCap: .round, lineJoin: .round)
            let line = StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round)
            switch coloring {
            case .plain:
                var path = Path()
                for run in runs { path.addLines(run.map { transform(MKMapPoint($0)) }) }
                context.stroke(path, with: .color(RoutePalette.casing.color), style: casing)
                context.stroke(path, with: .color(RoutePalette.plain.color), style: line)
            case .density, .efficiency:
                guard let layer else { return }
                var all = Path()
                for stroke in layer.strokes { all.addLines(stroke.points.map(transform)) }
                context.stroke(all, with: .color(RoutePalette.casing.color), style: casing)
                // Strokes come lowest count first; one path per colour, in that order.
                var order: [Int] = []
                var groups: [Int: (color: RoutePalette.RGB?, path: Path)] = [:]
                for stroke in layer.strokes {
                    let color: RoutePalette.RGB? = Self.strokeColor(stroke, coloring: coloring)
                    let key: Int = color?.bucketKey ?? -1
                    if groups[key] == nil { groups[key] = (color, Path()); order.append(key) }
                    groups[key]!.path.addLines(stroke.points.map(transform))
                }
                for key in order {
                    let group = groups[key]!
                    if let color = group.color {
                        context.stroke(group.path, with: .color(color.color), style: line)
                    } else {
                        context.stroke(group.path, with: .color(RoutePalette.missing.color),
                                       style: StrokeStyle(lineWidth: max(1.5, lineWidth - 1.5), lineCap: .round, lineJoin: .round))
                    }
                }
            }
        }
    }
}

/// Each drive's route digest, kept with the route it was taken from. A hit
/// costs one array comparison, which Swift answers at once when the route
/// is the same storage; a corrected route compares unequal and is digested
/// again. A class, so filling it from a view body changes no state.
final class RouteDigests {
    private var cache: [Int: (route: [DriveRoutePoint], digest: UInt64)] = [:]

    func digest(_ drive: DriveSummary) -> UInt64 {
        let route = drive.route ?? []
        if let hit = cache[drive.id], hit.route == route { return hit.digest }
        let digest = Self.digest(route)
        cache[drive.id] = (route, digest)
        return digest
    }

    /// FNV-1a over every point's time, coordinate and break flag: stable
    /// across launches, and any one changed value changes it.
    static func digest(_ route: [DriveRoutePoint]) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        func mix(_ v: UInt64) {
            var v = v
            for _ in 0..<8 { h ^= v & 0xff; h = h &* 0x100000001b3; v >>= 8 }
        }
        mix(UInt64(route.count))
        for p in route {
            mix(p.t.timeIntervalSince1970.bitPattern)
            mix(p.latitude.bitPattern)
            mix(p.longitude.bitPattern)
            mix(p.routeBreakBefore.map { $0 ? 2 : 1 } ?? 0)
        }
        return h
    }
}

/// Pure drawing from the row payload; no map tiles or location lookup.
struct DriveRouteThumbnail: View {
    var points: [DriveRoutePoint]
    var body: some View {
        GeometryReader { geometry in
            let runs = DriveRouteSegments.normalized(points, in: geometry.size)
            let valid = runs.flatMap { $0 }
            ZStack {
                if valid.isEmpty {
                    Image(systemName: "road.lanes").foregroundStyle(HistoryTheme.tertiary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    Path { path in
                        for run in runs {
                            for (index, point) in run.enumerated() {
                                if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                            }
                        }
                    }.stroke(RoutePalette.plain.color, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    if let end = valid.last, valid.count > 1 {
                        RouteEndpointMarker(kind: .end, size: 8).position(end)
                    }
                    if let start = valid.first {
                        RouteEndpointMarker(kind: valid.count == 1 ? .both : .start, size: 8).position(start)
                    }
                }
            }
        }.background(HistoryTheme.background.opacity(0.6), in: .rect(cornerRadius: 12))
            .allowsHitTesting(false).accessibilityHidden(true)
    }
}

// MARK: - Roadtrips

private extension Roadtrip {
    var durationMin: Double { drives.reduce(0) { $0 + $1.durationMin } }
    var stops: Int { drives.count - 1 }
    /// Sum only when every leg was measured; a partial sum would read as a total.
    var energyKwh: Double? {
        let values = drives.compactMap(\.energyUsedKwh)
        return values.count == drives.count ? values.reduce(0, +) : nil
    }
    var efficiencyWhPerKm: Double? { energyKwh.flatMap { distanceKm > 0 ? $0 * 1000 / distanceKm : nil } }
    /// Legs joined into one path; each leg starts a new run so gaps never bridge.
    var routePoints: [DriveRoutePoint] {
        drives.flatMap { drive in
            drive.drawableRoute.enumerated().map { index, point in
                var point = point
                if index == 0 { point.routeBreakBefore = true }
                return point
            }
        }
    }
}

struct RoadtripsView: View {
    var drives: [DriveSummary]
    var partial: Bool
    @Environment(\.units) private var units
    private var trips: [Roadtrip] { Roadtrip.group(drives) }

    var body: some View {
        let trips = trips
        OverviewScroll(title: "Roadtrips", identifier: "scroll.roadtrips") { wide in
            hero(trips)
            OverviewFootnote("Drives linked by stops of up to 2 hours, covering at least \(units.formatDistance(100)). Closed drives only.")
                .padding(.top, 18)
            if partial {
                Text("Loaded drives only · groups may change when more history is loaded")
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(HistoryTheme.amber).padding(.top, 6)
            }
            if trips.isEmpty {
                HistoryEmptyState(systemImage: "road.lanes", title: "No roadtrips in loaded drives",
                                  message: "Long drives and multi-stop chains covering at least \(units.formatDistance(100)) appear here.")
                    .padding(.top, 30)
            } else {
                OverviewSectionHeader(title: "Trips", trailing: trips.count == 1 ? "1 trip" : "\(trips.count) trips")
                    .padding(.top, 30)
                OverviewCards(wide: wide) {
                    ForEach(trips) { trip in
                        NavigationLink(value: DriveRoute.roadtrip(containing: trip.id)) { RoadtripCard(trip: trip) }
                            .buttonStyle(VoltaPressStyle())
                    }
                }
                // Cards sit 16 pt from the screen edge, as on Drives; text keeps the page margin.
                .padding(.horizontal, DrivesLayout.cardInset - VoltaSpacing.screen)
            }
        }
    }

    private func hero(_ trips: [Roadtrip]) -> some View {
        let distance = trips.reduce(0) { $0 + $1.distanceKm }
        let longest = trips.map(\.distanceKm).max()
        return VStack(alignment: .leading, spacing: 20) {
            OverviewHero(eyebrow: partial ? "Roadtrip distance in loaded drives" : "Roadtrip distance",
                         value: VoltaFormat.number(units.distanceValue(km: distance), digits: 0),
                         unit: units.distanceUnit, identifier: "screen.roadtrips")
            HistoryFlowStats(items: [
                ("point.topleft.down.to.point.bottomright.curvepath", "\(trips.count) \(trips.count == 1 ? "trip" : "trips")"),
                ("road.lanes", "\(trips.reduce(0) { $0 + $1.drives.count }) drives"),
            ])
            HistoryFlowStats(items: [
                ("clock", VoltaFormat.duration(trips.reduce(0) { $0 + $1.durationMin })),
                ("arrow.up.right", "\(longest.map { units.formatDistance($0, fractionDigits: 0) } ?? "—") longest"),
            ])
        }
    }
}

/// DriveCard's voice for a chain of drives: itinerary, distance, route watermark.
private struct RoadtripCard: View {
    var trip: Roadtrip
    @Environment(\.units) private var units
    @State private var width: CGFloat = 0

    /// Laid out like a Drives card: the same header row and sketch steps
    /// (`CardHeaderRow`), the same inner padding for the trailing column and
    /// footer, and the same footer metrics.
    var body: some View {
        let first = trip.drives[0], last = trip.drives[trip.drives.count - 1]
        VStack(alignment: .leading, spacing: 0) {
            CardHeaderRow(points: trip.routePoints, cardWidth: width) { oneLine in
                itinerary(from: first.startPlace, to: last.endPlace, oneLine: oneLine)
            } trailing: {
                VStack(alignment: .trailing, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(VoltaFormat.number(units.distanceValue(km: trip.distanceKm), digits: 0))
                            .font(.system(size: 30, weight: .bold)).monospacedDigit()
                        Text(units.distanceUnit.uppercased()).scaledFont(11, weight: .semibold).tracking(0.8).foregroundStyle(HistoryTheme.secondary)
                    }
                    .foregroundStyle(.white)
                    Text(first.start.formatted(.dateTime.month(.abbreviated).day().year()))
                        .font(.system(size: 13)).monospacedDigit().foregroundStyle(HistoryTheme.secondary)
                    Text(first.start.historyTime)
                        .font(.system(size: 13)).monospacedDigit().foregroundStyle(HistoryTheme.tertiary)
                }
            }
            .padding(.leading, 18).padding(.trailing, 16)
            .padding(.bottom, 16)
            Rectangle().fill(HistoryTheme.hairline).frame(height: 1).padding(.horizontal, 13)
            HStack(spacing: 8) {
                metric("clock", VoltaFormat.duration(trip.durationMin))
                dot
                metric("bolt.fill", trip.energyKwh.map { "\(VoltaFormat.number($0)) kWh" } ?? "—")
                dot
                metric("leaf.fill", trip.efficiencyWhPerKm.map { units.formatEfficiency($0) } ?? "—")
                Spacer(minLength: 0)
            }
            .padding(.leading, 18).padding(.trailing, 16)
            .padding(.top, 14)
        }
        .padding(.top, 14).padding(.bottom, 13)
        .driveSurface(radius: 18)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .accessibilityElement(children: .combine)
    }

    private func itinerary(from start: String, to end: String, oneLine: Bool) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                RouteEndpointMarker(kind: .start, size: 9).padding(.top, 7)
                Rectangle().fill(HistoryTheme.tertiary.opacity(0.6))
                    .frame(width: 1).frame(maxHeight: .infinity).padding(.vertical, 6)
                RouteEndpointMarker(kind: .end, size: 9).padding(.bottom, 7)
            }
            // Both names at one size; a long name wraps, never shrinks or truncates.
            VStack(alignment: .leading, spacing: 6) {
                CardPlaceName(name: start, oneLine: oneLine)
                Text(trip.stops == 0 ? "NONSTOP" : trip.stops == 1 ? "1 STOP" : "\(trip.stops) STOPS")
                    .scaledFont(11, weight: .semibold).tracking(0.8).foregroundStyle(HistoryTheme.tertiary)
                    .fixedSize()
                CardPlaceName(name: end, oneLine: oneLine)
            }
            .foregroundStyle(.white)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var dot: some View { Circle().fill(HistoryTheme.tertiary).frame(width: 3, height: 3) }

    private func metric(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11, weight: .medium))
            Text(text).font(.system(size: 13)).monospacedDigit()
        }
        .foregroundStyle(HistoryTheme.secondary)
        .lineLimit(1).fixedSize()
    }
}

struct RoadtripDetailView: View {
    var trip: Roadtrip
    var partial: Bool
    @Environment(\.units) private var units
    @State private var page = HistoryWindow()

    /// Wide enough for the route beside the legs (the inner display with the list hidden).
    private var usesPanes: Bool { page.isWide && page.size.width >= HistoryLayout.panesMinWidth }

    var body: some View {
        Group {
            if usesPanes {
                VoltaPanes {
                    DrivesRouteMap(drives: trip.drives, height: max(page.size.height, 250))
                        .frame(maxHeight: .infinity)
                } secondary: {
                    OverviewScroll(title: "Roadtrip", identifier: "scroll.roadtrip", page: false) { _ in summary }
                }
                .historyPage("Roadtrip")
            } else {
                OverviewScroll(title: "Roadtrip", identifier: "scroll.roadtrip") { _ in
                    DrivesRouteMap(drives: trip.drives, height: page.reveal(0.36, 170...250))
                        .overviewBleed()
                    summary
                }
            }
        }
        .readsHistoryWindow($page)
    }

    @ViewBuilder private var summary: some View {
        let first = trip.drives[0], last = trip.drives[trip.drives.count - 1]
        OverviewHero(eyebrow: "\(first.startPlace) → \(last.endPlace)",
                     value: VoltaFormat.number(units.distanceValue(km: trip.distanceKm)),
                     unit: units.distanceUnit, size: 72, identifier: "screen.roadtrip")
            .padding(.top, 4)
        VStack(alignment: .leading, spacing: 14) {
            HistoryFlowStats(items: [
                ("clock", VoltaFormat.duration(trip.durationMin)),
                ("road.lanes", "\(trip.drives.count) \(trip.drives.count == 1 ? "drive" : "drives")"),
            ])
            HistoryFlowStats(items: [
                ("bolt.fill", trip.energyKwh.map { VoltaFormat.energy($0) } ?? "— kWh"),
                ("leaf.fill", units.formatEfficiency(trip.efficiencyWhPerKm)),
            ])
        }
        .padding(.top, 20)
        if partial {
            Text("Loaded history · this chain may be incomplete")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(HistoryTheme.amber).padding(.top, 14)
        }
        OverviewSectionHeader(title: "Legs", trailing: first.start.formatted(.dateTime.month(.abbreviated).day().year()))
            .padding(.top, 30)
        LazyVStack(spacing: 14) {
            ForEach(trip.drives) { drive in
                NavigationLink(value: DriveRoute.drive(drive.id)) { DriveCard(drive: drive, showsDate: true) }
                    .buttonStyle(VoltaPressStyle())
            }
        }
    }
}

// MARK: - Overview chrome

/// A scrolling overview page: the title in the bar, or in the content while
/// the bars are on the side; a readable column on a phone, a wider one that
/// lays cards in two columns (one each side of the fold) on the inner display.
private struct OverviewScroll<Content: View>: View {
    var title: String
    var identifier: String
    /// False inside a pane, whose page already carries the chrome.
    var page = true
    @ViewBuilder var content: (_ wide: Bool) -> Content
    @Environment(\.barsOnSide) private var barsOnSide
    @Environment(\.historySideBars) private var sideBars
    @State private var width: CGFloat = 0

    private var wide: Bool { width >= HistoryLayout.twoColumnMinWidth }

    var body: some View {
        let scroll = ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if barsOnSide {
                    HistoryInlineTitle(title: title).padding(.bottom, VoltaSpacing.md)
                }
                content(wide)
            }
            .padding(.horizontal, VoltaSpacing.screen)
            .padding(.top, 8)
            .padding(.bottom, VoltaSpacing.tabBarClearance)
            .voltaReadableWidth(wide ? 1100 : VoltaLayout.readableWidth)
            .historySides(sideBars)
        }
        // Under the side bars, so a map can reach the edge (`overviewBleed`).
        .ignoresSafeArea(edges: sideBars.barEdges)
        .scrollIndicators(.hidden)
        .accessibilityIdentifier(identifier)
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        if page { scroll.historyPage(title) } else { scroll }
    }
}

private struct OverviewBleed: ViewModifier {
    @Environment(\.historySideBars) private var sideBars
    func body(content: Content) -> some View {
        content
            .padding(.leading, -(VoltaSpacing.screen + sideBars.leading))
            .padding(.trailing, -(VoltaSpacing.screen + sideBars.trailing))
    }
}

private extension View {
    /// Runs a map in an `OverviewScroll` to the screen edges, under the side bars.
    func overviewBleed() -> some View { modifier(OverviewBleed()) }
}

/// Cards in one column, or two even columns when `wide`.
private struct OverviewCards<Content: View>: View {
    var wide: Bool
    @ViewBuilder var content: Content

    var body: some View {
        if wide {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 14, alignment: .top), GridItem(.flexible(), alignment: .top)],
                      spacing: 14) { content }
        } else {
            LazyVStack(spacing: 14) { content }
        }
    }
}

/// Eyebrow over a big white numeral, carrying the screen's `screen.<name>` identifier.
private struct OverviewHero: View {
    var eyebrow: String
    var value: String
    var unit: String?
    var size: CGFloat = 84
    var identifier: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(eyebrow).voltaLabelStyle().lineLimit(1)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(value).font(.system(size: size, weight: .bold)).fontWidth(.expanded).tracking(-size / 42)
                    .foregroundStyle(.white).monospacedDigit().lineLimit(1).minimumScaleFactor(0.4)
                if let unit {
                    Text(unit).font(.system(size: max(15, size * 0.24))).foregroundStyle(HistoryTheme.secondary).fixedSize()
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityIdentifier(identifier)
    }
}

/// Section title with a quiet trailing note and a hairline below, like a drive day header.
private struct OverviewSectionHeader: View {
    var title: String
    var trailing: String?

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).font(.system(size: 22, weight: .medium)).foregroundStyle(.white)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing).font(.system(size: 15)).monospacedDigit().foregroundStyle(HistoryTheme.secondary).lineLimit(1)
                }
            }
            .padding(.bottom, 14)
            Rectangle().fill(HistoryTheme.hairline).frame(height: 1)
                .padding(.horizontal, -VoltaSpacing.screen)
        }
        .padding(.bottom, 18)
    }
}

private struct OverviewFootnote: View {
    var text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 13)).foregroundStyle(HistoryTheme.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Heatmap

/// What the heatmap colours roads by.
enum HeatmapMode: String, CaseIterable, Identifiable {
    case density, efficiency
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct DrivesHeatmapView: View {
    var drives: [DriveSummary]
    var partial: Bool
    @Environment(\.units) private var units
    @State private var mode: HeatmapMode = .density
    private var days: [DriveDay] { DriveDay.days(drives) }
    private var months: [Date] { Array(Set(days.compactMap { Calendar.current.dateInterval(of: .month, for: $0.date)?.start })).sorted().reversed() }

    var body: some View {
        let days = days
        OverviewScroll(title: "Heatmap", identifier: "scroll.heatmap") { wide in
            hero(days)
            if drives.contains(where: { !($0.route ?? []).isEmpty }) {
                Picker("Colour roads by", selection: $mode) {
                    ForEach(HeatmapMode.allCases) { Text($0.title).tag($0).accessibilityIdentifier("heatmap.mode.\($0.rawValue)") }
                }
                .pickerStyle(.segmented)
                .padding(.top, 18)
                .accessibilityIdentifier("heatmap.mode")
                let reference = EfficiencyReference(drives: drives)
                // The same legend strip as the trip map, on the page, between
                // the switch and the map; its labels line up with the switch.
                RouteLegendStrip(model: mode == .density ? .density : .efficiency(reference: reference, units: units))
                    .padding(.horizontal, -16)
                    .padding(.top, 6)
                DrivesRouteMap(drives: drives, height: wide ? 380 : 320,
                               coloring: mode == .density ? .density : .efficiency(reference),
                               lineWidth: 4, casingWidth: 7)
                    .overviewBleed()
            }
            OverviewSectionHeader(title: "Calendar", trailing: "Distance per day")
                .padding(.top, 30)
            // Two months side by side on a wide page, so no month straddles the fold.
            OverviewCards(wide: wide) {
                ForEach(months, id: \.self) { month in monthGrid(month, days: days) }
            }
            if days.isEmpty {
                Text("No drives to show in this selection").font(.system(size: 13, weight: .medium)).foregroundStyle(HistoryTheme.secondary)
            }
            OverviewFootnote(partial ? "Loaded drives only · blank dates may have unloaded history" : "Distance per day · blank dates have no drives in this selection")
                .padding(.top, 14)
        }
    }

    private func hero(_ days: [DriveDay]) -> some View {
        let distance = days.reduce(0) { $0 + $1.distanceKm }
        let busiest = days.map(\.distanceKm).max()
        return VStack(alignment: .leading, spacing: 20) {
            OverviewHero(eyebrow: partial ? "Driving days in loaded drives" : "Driving days",
                         value: "\(days.count)", unit: days.count == 1 ? "day" : "days", identifier: "screen.heatmap")
            HistoryFlowStats(items: [
                ("road.lanes", DrivesHero.countText(drives.count, partial: partial)),
                ("point.topleft.down.to.point.bottomright.curvepath", units.formatDistance(distance, fractionDigits: 0)),
            ])
            HistoryFlowStats(items: [
                ("calendar", "\(days.isEmpty ? "—" : units.formatDistance(distance / Double(days.count), fractionDigits: 0)) per day"),
                ("arrow.up.right", "\(busiest.map { units.formatDistance($0, fractionDigits: 0) } ?? "—") busiest"),
            ])
        }
    }

    private func monthGrid(_ month: Date, days: [DriveDay]) -> some View {
        let calendar = Calendar.current
        let count = calendar.range(of: .day, in: .month, for: month)!.count
        let offset = (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
        let lookup = Dictionary(uniqueKeysWithValues: days.map { ($0.date, $0) })
        let maxDistance = max(days.map(\.distanceKm).max() ?? 1, 1)
        let symbols = calendar.veryShortWeekdaySymbols
        let monthDays = days.filter { calendar.isDate($0.date, equalTo: month, toGranularity: .month) }
        let monthDistance = monthDays.reduce(0) { $0 + $1.distanceKm }
        return VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(month.formatted(.dateTime.month(.wide).year())).font(.system(size: 17, weight: .semibold)).foregroundStyle(.white)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                Text("\(monthDays.count) \(monthDays.count == 1 ? "day" : "days") · \(units.formatDistance(monthDistance, fractionDigits: 0))")
                    .font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(HistoryTheme.secondary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                ForEach(0..<7) { index in
                    Text(symbols[(calendar.firstWeekday - 1 + index) % 7])
                        .scaledFont(11, weight: .semibold).tracking(0.8).foregroundStyle(HistoryTheme.tertiary)
                }
                ForEach(0..<(offset + count), id: \.self) { index in
                    if index < offset { Color.clear.frame(height: 38) } else {
                        let day = calendar.date(byAdding: .day, value: index - offset, to: month)!
                        let value = lookup[day]
                        NavigationLink(value: DriveRoute.heatmapDay(day)) {
                            cell(number: index - offset + 1, ratio: value.map { $0.distanceKm / maxDistance })
                        }.buttonStyle(.plain).accessibilityLabel("\(day.formatted(date: .abbreviated, time: .omitted)), \(value.map { units.formatDistance($0.distanceKm) } ?? (partial ? "No loaded drives" : "No drives in selection"))")
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .voltaCardBackground()
    }

    /// Driven days fill green in proportion to distance.
    private func cell(number: Int, ratio: Double?) -> some View {
        let weight: Font.Weight = ratio == nil ? .medium : .semibold
        let text: Color = ratio == nil ? HistoryTheme.tertiary : .white
        let fill: Color
        if let ratio { fill = HistoryTheme.green.opacity(0.15 + 0.6 * ratio) } else { fill = Color.white.opacity(0.03) }
        return Text("\(number)")
            .font(.system(size: 13, weight: weight)).monospacedDigit()
            .foregroundStyle(text)
            .frame(maxWidth: .infinity).frame(height: 38)
            .background(fill, in: .rect(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
    }
}

struct HeatmapDayView: View {
    var date: Date
    var drives: [DriveSummary]
    var partial: Bool
    @Environment(\.units) private var units

    var body: some View {
        OverviewScroll(title: date.formatted(date: .abbreviated, time: .omitted), identifier: "scroll.heatmap-day") { wide in
            OverviewHero(eyebrow: date.formatted(.dateTime.weekday(.wide)) + (partial ? " · loaded drives" : ""),
                         value: VoltaFormat.number(units.distanceValue(km: drives.reduce(0) { $0 + $1.distanceKm })),
                         unit: units.distanceUnit, identifier: "screen.heatmap-day")
            if partial {
                Text("Loaded history only").font(.system(size: 12, weight: .medium)).foregroundStyle(HistoryTheme.amber).padding(.top, 10)
            }
            if drives.isEmpty {
                Text("No drives loaded for this day in the current selection")
                    .font(.system(size: 13, weight: .medium)).foregroundStyle(HistoryTheme.secondary).padding(.top, 18)
            } else {
                OverviewSectionHeader(title: "Drives", trailing: drives.count == 1 ? "1 drive" : "\(drives.count) drives")
                    .padding(.top, 30)
                OverviewCards(wide: wide) {
                    ForEach(drives) { drive in
                        NavigationLink(value: DriveRoute.drive(drive.id)) { DriveCard(drive: drive) }
                            .buttonStyle(VoltaPressStyle())
                    }
                }
            }
        }
    }
}
