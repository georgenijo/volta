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
/// Routes draw as thin cyan light over a dark, desaturated map: each color is
/// one combined path, softly haloed under a thin core, so busy roads glow
/// without stacking into a solid band. Single positions (sparse polling) are
/// not drawn: a lone dot reads as a place, not a route. Edges fade into the page.
struct DrivesRouteMap: View {
    var drives: [DriveSummary]
    var height: CGFloat = 240
    /// nil: cyan route light. Otherwise each drive takes its own color.
    var tint: ((DriveSummary) -> Color)? = nil
    /// Full-bleed hero: the map runs under the status bar and header (`topInset`
    /// keeps routes clear of the status bar) and fades out only at the bottom.
    var fullBleed = false
    var topInset: CGFloat = 0
    /// Lifts MapKit's legal attribution above the bottom fade so it never sits under content.
    var legalInset: CGFloat = 0
    @State private var visible: MKMapRect?

    private struct Run {
        var coordinates: [CLLocationCoordinate2D]
        var color: Color?
    }

    private var runs: [Run] {
        drives.flatMap { drive in
            let color = tint?(drive)
            return DriveRouteSegments.runs(drive.drawableRoute).filter { $0.count > 1 }.map { run in
                Run(coordinates: run.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }, color: color)
            }
        }
    }

    /// Fit every recorded point with breathing room; computed locally, never looked up.
    private static func fit(_ runs: [Run], padding: Double) -> MKMapRect {
        let points = runs.flatMap(\.coordinates).map(MKMapPoint.init)
        let minX = points.map(\.x).min()!, maxX = points.map(\.x).max()!
        let minY = points.map(\.y).min()!, maxY = points.map(\.y).max()!
        let side = max(maxX - minX, maxY - minY, 2_000)
        let padX = max(maxX - minX, side * 0.6) * padding, padY = max(maxY - minY, side * 0.6) * padding
        return MKMapRect(x: minX - padX, y: minY - padY, width: maxX - minX + padX * 2, height: maxY - minY + padY * 2)
    }

    private var fade: some View {
        LinearGradient(stops: fullBleed
                       ? [.init(color: .black.opacity(0.75), location: 0), .init(color: .black, location: 0.3),
                          .init(color: .black, location: 0.62), .init(color: .clear, location: 1)]
                       : [.init(color: .clear, location: 0), .init(color: .black, location: 0.2),
                          .init(color: .black, location: 0.7), .init(color: .black.opacity(0.3), location: 1)],
                       startPoint: .top, endPoint: .bottom)
    }

    var body: some View {
        let runs = runs
        ZStack {
            if runs.isEmpty {
                Text("Routes not recorded for these drives").font(.system(size: 13, weight: .medium)).foregroundStyle(HistoryTheme.secondary)
                    .padding(.top, topInset)
            } else {
                MapReader { proxy in
                Map(initialPosition: .rect(Self.fit(runs, padding: fullBleed ? 0.12 : 0.35)), interactionModes: [])
                    .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
                    .environment(\.colorScheme, .dark)
                    .safeAreaPadding(.top, topInset)
                    .safeAreaPadding(.bottom, legalInset)
                    .onMapCameraChange(frequency: .continuous) { visible = $0.rect }
                    // Dark and grey: roads read as texture, labels stay dim.
                    .saturation(0)
                    .opacity(fullBleed ? 0.4 : 0.5)
                    // Project through MapKit itself so routes stay on the roads under any safe-area padding.
                    .overlay { light(runs, proxy: proxy).allowsHitTesting(false) }
                    .mask {
                        fade.mask {
                            if fullBleed { Color.black } else {
                                LinearGradient(stops: [.init(color: .black.opacity(0.55), location: 0), .init(color: .black, location: 0.14),
                                                       .init(color: .black, location: 0.86), .init(color: .black.opacity(0.55), location: 1)],
                                               startPoint: .leading, endPoint: .trailing)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recorded routes for loaded drives")
    }

    private func light(_ runs: [Run], proxy: MapProxy) -> some View {
        Canvas { context, size in
            // `visible` changes with the camera and redraws the light.
            guard visible != nil else { return }
            func point(_ c: CLLocationCoordinate2D) -> CGPoint? { proxy.convert(c, to: .local) }
            let defaultShading = GraphicsContext.Shading.color(HistoryTheme.route)
            // One path per color: overlapping drives brighten the halo, not thicken it.
            var groups: [(color: Color?, path: Path)] = []
            for run in runs {
                let index = groups.firstIndex { $0.color == run.color } ?? {
                    groups.append((run.color, Path()))
                    return groups.count - 1
                }()
                let points = run.coordinates.compactMap(point)
                if points.count == run.coordinates.count { groups[index].path.addLines(points) }
            }
            for group in groups {
                let shading = group.color.map { GraphicsContext.Shading.color($0) } ?? defaultShading
                var halo = context
                halo.addFilter(.blur(radius: 4))
                halo.opacity = 0.4
                halo.stroke(group.path, with: shading, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                context.stroke(group.path, with: shading, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
            }
        }
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
                    }.stroke(HistoryTheme.blue, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                    ForEach(Array(valid.enumerated()), id: \.offset) { _, point in
                        Circle().fill(HistoryTheme.blue).frame(width: 3, height: 3).position(point)
                    }
                    if let start = valid.first {
                        Circle().fill(HistoryTheme.green).frame(width: 8, height: 8).position(start)
                    }
                    if let end = valid.last {
                        Circle().strokeBorder(HistoryTheme.blue, lineWidth: 2).background(Circle().fill(valid.count == 1 ? HistoryTheme.green : HistoryTheme.blue))
                            .frame(width: 8, height: 8).position(end)
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
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
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
                    LazyVStack(spacing: 14) {
                        ForEach(trips) { trip in
                            NavigationLink { RoadtripDetailView(trip: trip, partial: partial) } label: { RoadtripCard(trip: trip) }
                                .buttonStyle(VoltaPressStyle())
                        }
                    }
                }
            }
            .padding(.horizontal, ScreenKit.horizontalPadding)
            .padding(.top, 8)
            .padding(.bottom, ScreenKit.bottomBarClearance)
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("scroll.roadtrips")
        .screenKitPage("Roadtrips")
    }

    private func hero(_ trips: [Roadtrip]) -> some View {
        let distance = trips.reduce(0) { $0 + $1.distanceKm }
        let longest = trips.map(\.distanceKm).max()
        return VStack(alignment: .leading, spacing: 20) {
            OverviewHero(eyebrow: partial ? "Roadtrip distance · loaded" : "Roadtrip distance",
                         value: VoltaFormat.number(units.distanceValue(km: distance), digits: 0),
                         unit: units.distanceUnit, identifier: "screen.roadtrips")
            HistoryFlowStats(items: [
                ("point.topleft.down.to.point.bottomright.curvepath", "\(trips.count)\(partial ? "+" : "") \(trips.count == 1 && !partial ? "trip" : "trips")"),
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

    var body: some View {
        let first = trip.drives[0], last = trip.drives[trip.drives.count - 1]
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                itinerary(from: first.startPlace, to: last.endPlace)
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(VoltaFormat.number(units.distanceValue(km: trip.distanceKm), digits: 0))
                            .font(.system(size: 30, weight: .bold)).monospacedDigit()
                        Text(units.distanceUnit.uppercased()).font(.system(size: 11, weight: .semibold)).tracking(0.8).foregroundStyle(HistoryTheme.secondary)
                    }
                    .foregroundStyle(.white)
                    Text(first.start.formatted(.dateTime.month(.abbreviated).day().year()))
                        .font(.system(size: 15)).monospacedDigit().foregroundStyle(HistoryTheme.secondary)
                    Text(first.start.historyTime)
                        .font(.system(size: 13)).monospacedDigit().foregroundStyle(HistoryTheme.tertiary)
                }
            }
            .padding(.bottom, 18)
            Rectangle().fill(HistoryTheme.hairline).frame(height: 1)
            HStack(spacing: 8) {
                metric("clock", VoltaFormat.duration(trip.durationMin))
                dot
                metric("bolt.fill", trip.energyKwh.map { "\(VoltaFormat.number($0)) kWh" } ?? "—")
                dot
                metric("leaf.fill", trip.efficiencyWhPerKm.map { units.formatEfficiency($0) } ?? "—")
                Spacer(minLength: 0)
            }
            .padding(.vertical, 12)
        }
        .padding(.horizontal, 22).padding(.top, 22).padding(.bottom, 6)
        .background {
            RouteWatermark(points: trip.routePoints, opacity: 0.22)
                .padding(.leading, 150).padding(.trailing, 100).padding(.vertical, 6)
        }
        .driveSurface()
        .accessibilityElement(children: .combine)
    }

    private func itinerary(from start: String, to end: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 0) {
                Circle().fill(HistoryTheme.green).frame(width: 9, height: 9).padding(.top, 8)
                Rectangle().fill(HistoryTheme.tertiary.opacity(0.6))
                    .frame(width: 1).frame(maxHeight: .infinity).padding(.vertical, 6)
                Circle().fill(HistoryTheme.blue).frame(width: 9, height: 9).padding(.bottom, 8)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(start).font(.system(size: 22, weight: .medium))
                Text(trip.stops == 0 ? "NONSTOP" : trip.stops == 1 ? "1 STOP" : "\(trip.stops) STOPS")
                    .font(.system(size: 11, weight: .semibold)).tracking(1.2).foregroundStyle(HistoryTheme.tertiary)
                Text(end).font(.system(size: 22, weight: .medium))
            }
            .foregroundStyle(.white)
            .lineLimit(1).minimumScaleFactor(0.7)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var dot: some View { Circle().fill(HistoryTheme.tertiary).frame(width: 3, height: 3) }

    private func metric(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 13, weight: .medium))
            Text(text).font(.system(size: 16)).monospacedDigit()
        }
        .foregroundStyle(HistoryTheme.secondary)
        .lineLimit(1).fixedSize()
    }
}

struct RoadtripDetailView: View {
    var trip: Roadtrip
    var partial: Bool
    @Environment(\.units) private var units

    var body: some View {
        let first = trip.drives[0], last = trip.drives[trip.drives.count - 1]
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                DrivesRouteMap(drives: trip.drives, height: 250)
                    .padding(.horizontal, -ScreenKit.horizontalPadding)
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
                        NavigationLink { DriveDetailView(drive: drive) } label: { DriveCard(drive: drive, showsDate: true) }
                            .buttonStyle(VoltaPressStyle())
                    }
                }
            }
            .padding(.horizontal, ScreenKit.horizontalPadding)
            .padding(.bottom, ScreenKit.bottomBarClearance)
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("scroll.roadtrip")
        .screenKitPage("Roadtrip")
    }
}

// MARK: - Overview chrome

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
                .padding(.horizontal, -ScreenKit.horizontalPadding)
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

/// Absolute efficiency bands for route color; shared by the map and its legend.
private enum EfficiencyLight {
    static let bounds: [Double] = [130, 170, 210]  // Wh/km
    static let colors: [Color] = [HistoryTheme.green, HistoryTheme.blue, HistoryTheme.amber, HistoryTheme.red]

    static func color(_ whPerKm: Double?) -> Color {
        guard let whPerKm else { return .white.opacity(0.45) }
        return colors[bounds.firstIndex { whPerKm < $0 } ?? bounds.count]
    }
}

struct DrivesHeatmapView: View {
    var drives: [DriveSummary]
    var partial: Bool
    @Environment(\.units) private var units
    private var days: [DriveDay] { DriveDay.days(drives) }
    private var months: [Date] { Array(Set(days.compactMap { Calendar.current.dateInterval(of: .month, for: $0.date)?.start })).sorted().reversed() }

    var body: some View {
        let days = days
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero(days)
                if drives.contains(where: { !($0.route ?? []).isEmpty }) {
                    DrivesRouteMap(drives: drives, height: 300, tint: { EfficiencyLight.color($0.efficiencyWhPerKm) })
                        .padding(.horizontal, -ScreenKit.horizontalPadding)
                        .padding(.top, 12)
                    legend.padding(.top, 8)
                }
                OverviewSectionHeader(title: "Calendar", trailing: "Distance per day")
                    .padding(.top, 30)
                VStack(spacing: 14) {
                    ForEach(months, id: \.self) { month in monthGrid(month, days: days) }
                }
                if days.isEmpty {
                    Text("No drives to show in this selection").font(.system(size: 13, weight: .medium)).foregroundStyle(HistoryTheme.secondary)
                }
                OverviewFootnote(partial ? "Loaded drives only · blank dates may have unloaded history" : "Distance per day · blank dates have no drives in this selection")
                    .padding(.top, 14)
            }
            .padding(.horizontal, ScreenKit.horizontalPadding)
            .padding(.top, 8)
            .padding(.bottom, ScreenKit.bottomBarClearance)
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("scroll.heatmap")
        .screenKitPage("Heatmap")
    }

    private func hero(_ days: [DriveDay]) -> some View {
        let distance = days.reduce(0) { $0 + $1.distanceKm }
        let busiest = days.map(\.distanceKm).max()
        return VStack(alignment: .leading, spacing: 20) {
            OverviewHero(eyebrow: partial ? "Driving days · loaded" : "Driving days",
                         value: "\(days.count)", unit: days.count == 1 ? "day" : "days", identifier: "screen.heatmap")
            HistoryFlowStats(items: [
                ("road.lanes", "\(drives.count)\(partial ? "+" : "") \(drives.count == 1 && !partial ? "drive" : "drives")"),
                ("point.topleft.down.to.point.bottomright.curvepath", units.formatDistance(distance, fractionDigits: 0)),
            ])
            HistoryFlowStats(items: [
                ("calendar", "\(days.isEmpty ? "—" : units.formatDistance(distance / Double(days.count), fractionDigits: 0)) per day"),
                ("arrow.up.right", "\(busiest.map { units.formatDistance($0, fractionDigits: 0) } ?? "—") busiest"),
            ])
        }
    }

    /// Thin gradient bar; the labels mark the band edges in the user's unit.
    private var legend: some View {
        let edges = EfficiencyLight.bounds.map { VoltaFormat.number(units.efficiencyValue(whPerKm: $0), digits: 0) }
        return VStack(alignment: .leading, spacing: 7) {
            Capsule()
                .fill(LinearGradient(colors: EfficiencyLight.colors, startPoint: .leading, endPoint: .trailing))
                .frame(height: 3)
            HStack {
                Text("Efficient").foregroundStyle(HistoryTheme.green)
                Spacer()
                Text("\(edges[0]) · \(edges[1]) · \(edges[2]) \(units.efficiencyUnit)").monospacedDigit().foregroundStyle(HistoryTheme.tertiary)
                Spacer()
                Text("Thirsty").foregroundStyle(HistoryTheme.red.opacity(0.9))
            }
            .font(.system(size: 10, weight: .semibold)).tracking(1).textCase(.uppercase)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Route color shows efficiency, from efficient below \(edges[0]) to thirsty above \(edges[2]) \(units.efficiencyUnit)")
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
                        .font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(HistoryTheme.tertiary)
                }
                ForEach(0..<(offset + count), id: \.self) { index in
                    if index < offset { Color.clear.frame(height: 38) } else {
                        let day = calendar.date(byAdding: .day, value: index - offset, to: month)!
                        let value = lookup[day]
                        let matching = drives.filter { calendar.isDate($0.start, inSameDayAs: day) }
                        NavigationLink { HeatmapDayView(date: day, drives: matching, partial: partial) } label: {
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
        Text("\(number)")
            .font(.system(size: 13, weight: ratio == nil ? .medium : .semibold)).monospacedDigit()
            .foregroundStyle(ratio == nil ? HistoryTheme.tertiary : .white)
            .frame(maxWidth: .infinity).frame(height: 38)
            .background(ratio.map { HistoryTheme.green.opacity(0.15 + 0.6 * $0) } ?? Color.white.opacity(0.03),
                        in: .rect(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
    }
}

private struct HeatmapDayView: View {
    var date: Date
    var drives: [DriveSummary]
    var partial: Bool
    @Environment(\.units) private var units

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                OverviewHero(eyebrow: date.formatted(.dateTime.weekday(.wide)) + (partial ? " · loaded" : ""),
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
                    LazyVStack(spacing: 14) {
                        ForEach(drives) { drive in
                            NavigationLink { DriveDetailView(drive: drive) } label: { DriveCard(drive: drive) }
                                .buttonStyle(VoltaPressStyle())
                        }
                    }
                }
            }
            .padding(.horizontal, ScreenKit.horizontalPadding)
            .padding(.top, 8)
            .padding(.bottom, ScreenKit.bottomBarClearance)
        }
        .scrollIndicators(.hidden)
        .screenKitPage(date.formatted(date: .abbreviated, time: .omitted))
    }
}
