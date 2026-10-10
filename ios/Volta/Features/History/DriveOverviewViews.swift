import MapKit
import SwiftUI

struct DriveScoreRing: View {
    var score: Int?
    var size: CGFloat = 44
    private var value: Int? { score.flatMap { (0...100).contains($0) ? $0 : nil } }
    private var tint: Color {
        guard let value else { return HistoryTheme.secondary }
        return value >= 85 ? HistoryTheme.green : value >= 70 ? HistoryTheme.blue : HistoryTheme.amber
    }
    var body: some View {
        ZStack {
            Circle().trim(from: 0.12, to: 0.88).stroke(HistoryTheme.track, style: StrokeStyle(lineWidth: size * 0.075, lineCap: .round)).rotationEffect(.degrees(90))
            if let value {
                SweepIn { p in
                    Circle().trim(from: 0.12, to: 0.12 + min(0.76 * Double(value) / 100 * p, 0.776))
                        .stroke(tint, style: StrokeStyle(lineWidth: size * 0.075, lineCap: .round)).rotationEffect(.degrees(90))
                        .shadow(color: tint.opacity(0.6 * VoltaMotion.bloom(p)), radius: 4)
                }
            }
            CountUpNumber(value.map(Double.init), placeholder: "–", alignment: .center) { String(Int($0.rounded())) }
                .font(.system(size: size * 0.30, weight: .bold, design: .rounded)).foregroundStyle(.white)
        }.frame(width: size, height: size)
            .accessibilityLabel(value.map { "Drive score \($0) of 100" } ?? "Drive score unavailable")
    }
}

enum DriveRouteSegments {
    /// Share of flagged points above which break flags are read as jitter.
    static let noisyBreakShare = 0.5

    /// Break flags on most of a route are collector gap jitter, not recording
    /// gaps: honoring them shatters the line into isolated points. Above
    /// `noisyBreakShare` the flags are dropped so the route draws continuously;
    /// invalid positions still break it in `runs`. Short routes keep their flags.
    static func tolerant(_ points: [DriveRoutePoint]) -> [DriveRoutePoint] {
        let candidates = points.dropFirst()
        guard candidates.count >= 3 else { return points }
        let flagged = candidates.reduce(0) { $0 + ($1.routeBreakBefore == true ? 1 : 0) }
        guard Double(flagged) / Double(candidates.count) > noisyBreakShare else { return points }
        return points.map { point in
            var point = point
            point.routeBreakBefore = nil
            return point
        }
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
/// Routes draw as light over a dimmed, desaturated map: each color is one combined
/// path, blurred for a halo under a thin bright core, so busy roads glow without
/// stacking into a solid band. Edges fade into the page.
struct DrivesRouteMap: View {
    var drives: [DriveSummary]
    var height: CGFloat = 240
    /// nil: mint→blue route light. Otherwise each drive takes its own color.
    var tint: ((DriveSummary) -> Color)? = nil
    @State private var visible: MKMapRect?

    private struct Run {
        var coordinates: [CLLocationCoordinate2D]
        var color: Color?
    }

    private var runs: [Run] {
        drives.flatMap { drive in
            let color = tint?(drive)
            return DriveRouteSegments.runs(drive.drawableRoute).filter { !$0.isEmpty }.map { run in
                Run(coordinates: run.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }, color: color)
            }
        }
    }

    /// Fit every recorded point with breathing room; computed locally, never looked up.
    private static func fit(_ runs: [Run]) -> MKMapRect {
        let points = runs.flatMap(\.coordinates).map(MKMapPoint.init)
        let minX = points.map(\.x).min()!, maxX = points.map(\.x).max()!
        let minY = points.map(\.y).min()!, maxY = points.map(\.y).max()!
        let side = max(maxX - minX, maxY - minY, 2_000)
        let padX = max(maxX - minX, side * 0.6) * 0.35, padY = max(maxY - minY, side * 0.6) * 0.35
        return MKMapRect(x: minX - padX, y: minY - padY, width: maxX - minX + padX * 2, height: maxY - minY + padY * 2)
    }

    var body: some View {
        let runs = runs
        ZStack {
            if runs.isEmpty {
                Text("Routes not recorded for these drives").font(.system(size: 13, weight: .medium)).foregroundStyle(HistoryTheme.secondary)
            } else {
                Map(initialPosition: .rect(Self.fit(runs)), interactionModes: [])
                    .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll, showsTraffic: false))
                    .environment(\.colorScheme, .dark)
                    .onMapCameraChange(frequency: .continuous) { visible = $0.rect }
                    .saturation(0.15)
                    .opacity(0.62)
                    .overlay { light(runs).allowsHitTesting(false) }
                    .mask {
                        LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.2),
                                               .init(color: .black, location: 0.7), .init(color: .black.opacity(0.3), location: 1)],
                                       startPoint: .top, endPoint: .bottom)
                            .mask {
                                LinearGradient(stops: [.init(color: .black.opacity(0.55), location: 0), .init(color: .black, location: 0.14),
                                                       .init(color: .black, location: 0.86), .init(color: .black.opacity(0.55), location: 1)],
                                               startPoint: .leading, endPoint: .trailing)
                            }
                    }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Recorded routes for loaded drives")
    }

    private func light(_ runs: [Run]) -> some View {
        Canvas { context, size in
            guard let rect = visible, rect.width > 0, rect.height > 0 else { return }
            func point(_ c: CLLocationCoordinate2D) -> CGPoint {
                let m = MKMapPoint(c)
                return CGPoint(x: (m.x - rect.minX) / rect.width * size.width, y: (m.y - rect.minY) / rect.height * size.height)
            }
            let defaultShading = GraphicsContext.Shading.linearGradient(
                Gradient(colors: [HistoryTheme.mint, HistoryTheme.blue]),
                startPoint: CGPoint(x: 0, y: size.height), endPoint: CGPoint(x: size.width, y: 0))
            // One path per color: overlapping drives brighten the halo, not thicken it.
            var groups: [(color: Color?, path: Path, dots: [CGPoint])] = []
            for run in runs {
                let index = groups.firstIndex { $0.color == run.color } ?? {
                    groups.append((run.color, Path(), []))
                    return groups.count - 1
                }()
                if run.coordinates.count == 1 {
                    groups[index].dots.append(point(run.coordinates[0]))
                } else {
                    groups[index].path.addLines(run.coordinates.map(point))
                }
            }
            for group in groups {
                let shading = group.color.map { GraphicsContext.Shading.color($0) } ?? defaultShading
                var halo = context
                halo.addFilter(.blur(radius: 7))
                halo.opacity = 0.75
                halo.stroke(group.path, with: shading, style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                context.stroke(group.path, with: shading, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                for dot in group.dots {
                    context.fill(Path(ellipseIn: CGRect(x: dot.x - 3, y: dot.y - 3, width: 6, height: 6)), with: shading)
                }
            }
            // A single chain reads as a journey: mint where it starts, blue where it ends.
            if tint == nil, let first = runs.first?.coordinates.first, let last = runs.last?.coordinates.last {
                for (coordinate, color) in [(first, HistoryTheme.mint), (last, HistoryTheme.blue)] {
                    let p = point(coordinate)
                    var glow = context
                    glow.addFilter(.blur(radius: 5))
                    glow.fill(Path(ellipseIn: CGRect(x: p.x - 7, y: p.y - 7, width: 14, height: 14)), with: .color(color.opacity(0.8)))
                    context.fill(Path(ellipseIn: CGRect(x: p.x - 4, y: p.y - 4, width: 8, height: 8)), with: .color(color))
                }
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
                AnalyticsFootnote("Drives linked by stops of up to 2 hours, covering at least \(units.formatDistance(100)). Closed drives only.")
                    .padding(.top, 18)
                if partial {
                    Text("Loaded drives only · groups may change when more history is loaded")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(AnalyticsStyle.amber).padding(.top, 6)
                }
                if trips.isEmpty {
                    HistoryEmptyState(systemImage: "road.lanes", title: "No roadtrips in loaded drives",
                                      message: "Long drives and multi-stop chains covering at least \(units.formatDistance(100)) appear here.")
                        .padding(.top, AnalyticsStyle.sectionGap)
                } else {
                    AnalyticsSectionHeader("Trips", trailing: trips.count == 1 ? "1 trip" : "\(trips.count) trips")
                        .padding(.top, AnalyticsStyle.sectionGap)
                    LazyVStack(spacing: AnalyticsStyle.cardGap) {
                        ForEach(trips) { trip in
                            NavigationLink { RoadtripDetailView(trip: trip, partial: partial) } label: { RoadtripCard(trip: trip) }
                                .buttonStyle(VoltaPressStyle())
                                .voltaCascade()
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
        .voltaArrivalScope()
        .screenKitPage("Roadtrips")
    }

    private func hero(_ trips: [Roadtrip]) -> some View {
        let distance = trips.reduce(0) { $0 + $1.distanceKm }
        let longest = trips.map(\.distanceKm).max()
        return VStack(alignment: .leading, spacing: 22) {
            AnalyticsHero(eyebrow: partial ? "Roadtrip distance · loaded" : "Roadtrip distance",
                          value: VoltaFormat.number(units.distanceValue(km: distance), digits: 0),
                          unit: units.distanceUnit, identifier: "screen.roadtrips")
            AnalyticsStatStrip(items: [
                ("\(trips.count)\(partial ? "+" : "")", trips.count == 1 && !partial ? "Trip" : "Trips"),
                ("\(trips.reduce(0) { $0 + $1.drives.count })", "Drives"),
                (VoltaFormat.duration(trips.reduce(0) { $0 + $1.durationMin }), "Driving"),
                (longest.map { VoltaFormat.number(units.distanceValue(km: $0), digits: 0) } ?? "—", "Longest"),
            ])
        }
    }
}

/// DriveCard's voice for a chain of drives: itinerary, expanded distance, route watermark.
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
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(VoltaFormat.number(units.distanceValue(km: trip.distanceKm), digits: 0))
                            .font(.system(size: 30, weight: .bold)).fontWidth(.expanded).tracking(-0.8).monospacedDigit()
                        Text(units.distanceUnit.uppercased()).font(.system(size: 10, weight: .semibold)).tracking(0.8).foregroundStyle(HistoryTheme.secondary)
                    }
                    .foregroundStyle(.white)
                    Text(first.start.formatted(.dateTime.month(.abbreviated).day().year()))
                        .font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(HistoryTheme.secondary)
                    Text(first.start.historyTime)
                        .font(.system(size: 11, weight: .medium)).monospacedDigit().foregroundStyle(HistoryTheme.tertiary)
                }
            }
            .padding(.bottom, 16)
            Rectangle().fill(HistoryTheme.hairline).frame(height: 1)
            HStack(spacing: 8) {
                metric("clock", VoltaFormat.duration(trip.durationMin))
                dot
                metric("bolt", trip.energyKwh.map { "\(VoltaFormat.number($0)) kWh" } ?? "—")
                dot
                metric("leaf", trip.efficiencyWhPerKm.map { units.formatEfficiency($0) } ?? "—")
                Spacer(minLength: 0)
            }
            .padding(.top, 12)
        }
        .padding(.horizontal, 18).padding(.top, 18).padding(.bottom, 14)
        .background {
            RouteWatermark(points: trip.routePoints, opacity: 0.42)
                .padding(.leading, 130).padding(.trailing, 90).padding(.top, 4).padding(.bottom, 44)
                .mask(RadialGradient(colors: [.black, .black.opacity(0.6), .clear], center: .center, startRadius: 10, endRadius: 120))
        }
        .driveSurface()
        .accessibilityElement(children: .combine)
    }

    private func itinerary(from start: String, to end: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                Circle().fill(HistoryTheme.mint).frame(width: 8, height: 8).padding(.top, 7)
                Rectangle().fill(LinearGradient(colors: [HistoryTheme.mint.opacity(0.6), HistoryTheme.blue.opacity(0.6)], startPoint: .top, endPoint: .bottom))
                    .frame(width: 1.5).frame(maxHeight: .infinity).padding(.vertical, 4)
                Circle().fill(HistoryTheme.blue).frame(width: 8, height: 8).padding(.bottom, 7)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(start).font(.system(size: 18, weight: .semibold))
                Text(trip.stops == 0 ? "NONSTOP" : trip.stops == 1 ? "1 STOP" : "\(trip.stops) STOPS")
                    .font(.system(size: 10, weight: .semibold)).tracking(1.2).foregroundStyle(HistoryTheme.tertiary)
                Text(end).font(.system(size: 18, weight: .semibold))
            }
            .foregroundStyle(.white)
            .lineLimit(1).minimumScaleFactor(0.75)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private var dot: some View { Circle().fill(HistoryTheme.tertiary).frame(width: 2.5, height: 2.5) }

    private func metric(_ icon: String, _ text: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: icon).font(.system(size: 11, weight: .medium)).foregroundStyle(HistoryTheme.tertiary)
            Text(text).font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(.white.opacity(0.78))
        }
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
                AnalyticsHero(eyebrow: "\(first.startPlace) → \(last.endPlace)",
                              value: VoltaFormat.number(units.distanceValue(km: trip.distanceKm)),
                              unit: units.distanceUnit, size: 72, identifier: "screen.roadtrip")
                    .padding(.top, 4)
                AnalyticsStatStrip(items: [
                    ("\(trip.drives.count)", trip.drives.count == 1 ? "Drive" : "Drives"),
                    (VoltaFormat.duration(trip.durationMin), "Driving"),
                    (trip.energyKwh.map { VoltaFormat.number($0) } ?? "—", "kWh"),
                    (trip.efficiencyWhPerKm.map { VoltaFormat.number(units.efficiencyValue(whPerKm: $0), digits: 0) } ?? "—", units.efficiencyUnit),
                ])
                .padding(.top, 22)
                if partial {
                    Text("Loaded history · this chain may be incomplete")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(AnalyticsStyle.amber).padding(.top, 14)
                }
                AnalyticsSectionHeader("Legs", trailing: first.start.formatted(.dateTime.month(.abbreviated).day().year()))
                    .padding(.top, AnalyticsStyle.sectionGap)
                LazyVStack(spacing: AnalyticsStyle.cardGap) {
                    ForEach(trip.drives) { drive in
                        NavigationLink { DriveDetailView(drive: drive) } label: { DriveCard(drive: drive, showsDate: true) }
                            .buttonStyle(VoltaPressStyle())
                            .voltaCascade()
                    }
                }
            }
            .padding(.horizontal, ScreenKit.horizontalPadding)
            .padding(.bottom, ScreenKit.bottomBarClearance)
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("scroll.roadtrip")
        .voltaArrivalScope()
        .screenKitPage("Roadtrip")
    }
}

// MARK: - Heatmap

/// Absolute efficiency bands for route light; shared by the map and its legend.
private enum EfficiencyLight {
    static let bounds: [Double] = [130, 170, 210]  // Wh/km
    static let colors: [Color] = [AnalyticsStyle.mint, AnalyticsStyle.blue, AnalyticsStyle.amber, AnalyticsStyle.red]

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
                AnalyticsSectionHeader("Calendar", trailing: "Distance per day")
                    .padding(.top, AnalyticsStyle.sectionGap)
                VStack(spacing: AnalyticsStyle.cardGap) {
                    ForEach(months, id: \.self) { month in monthGrid(month, days: days) }
                }
                if days.isEmpty {
                    Text("No drives to show in this selection").font(.system(size: 13, weight: .medium)).foregroundStyle(AnalyticsStyle.secondary)
                }
                AnalyticsFootnote(partial ? "Loaded drives only · blank dates may have unloaded history" : "Distance per day · blank dates have no drives in this selection")
                    .padding(.top, 14)
            }
            .padding(.horizontal, ScreenKit.horizontalPadding)
            .padding(.top, 8)
            .padding(.bottom, ScreenKit.bottomBarClearance)
        }
        .scrollIndicators(.hidden)
        .accessibilityIdentifier("scroll.heatmap")
        .voltaArrivalScope()
        .screenKitPage("Heatmap")
    }

    private func hero(_ days: [DriveDay]) -> some View {
        let distance = days.reduce(0) { $0 + $1.distanceKm }
        let busiest = days.map(\.distanceKm).max()
        return VStack(alignment: .leading, spacing: 22) {
            AnalyticsHero(eyebrow: partial ? "Driving days · loaded" : "Driving days",
                          value: "\(days.count)", unit: days.count == 1 ? "day" : "days", identifier: "screen.heatmap")
            AnalyticsStatStrip(items: [
                ("\(drives.count)\(partial ? "+" : "")", drives.count == 1 && !partial ? "Drive" : "Drives"),
                (VoltaFormat.number(units.distanceValue(km: distance), digits: 0), units.distanceUnit),
                (days.isEmpty ? "—" : VoltaFormat.number(units.distanceValue(km: distance / Double(days.count)), digits: 0), "Per day"),
                (busiest.map { VoltaFormat.number(units.distanceValue(km: $0), digits: 0) } ?? "—", "Busiest"),
            ])
        }
    }

    /// Thin glowing gradient bar; the labels mark the band edges in the user's unit.
    private var legend: some View {
        let edges = EfficiencyLight.bounds.map { VoltaFormat.number(units.efficiencyValue(whPerKm: $0), digits: 0) }
        return VStack(alignment: .leading, spacing: 7) {
            Capsule()
                .fill(LinearGradient(colors: EfficiencyLight.colors, startPoint: .leading, endPoint: .trailing))
                .frame(height: 3)
                .shadow(color: AnalyticsStyle.blue.opacity(0.5), radius: 4)
            HStack {
                Text("Efficient").foregroundStyle(AnalyticsStyle.mint)
                Spacer()
                Text("\(edges[0]) · \(edges[1]) · \(edges[2]) \(units.efficiencyUnit)").monospacedDigit().foregroundStyle(AnalyticsStyle.tertiary)
                Spacer()
                Text("Thirsty").foregroundStyle(AnalyticsStyle.red.opacity(0.9))
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
                    .font(.system(size: 13, weight: .medium)).monospacedDigit().foregroundStyle(AnalyticsStyle.secondary)
            }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                ForEach(0..<7) { index in
                    Text(symbols[(calendar.firstWeekday - 1 + index) % 7])
                        .font(.system(size: 10, weight: .semibold)).tracking(1).foregroundStyle(AnalyticsStyle.tertiary)
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

    /// Driven days glow mint in proportion to distance; the brightest carry a halo.
    private func cell(number: Int, ratio: Double?) -> some View {
        let lit = (ratio ?? 0) >= 0.66
        return Text("\(number)")
            .font(.system(size: 13, weight: ratio == nil ? .medium : .semibold)).monospacedDigit()
            .foregroundStyle(ratio == nil ? AnalyticsStyle.tertiary : .white)
            .frame(maxWidth: .infinity).frame(height: 38)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(ratio.map { AnalyticsStyle.mint.opacity(0.1 + 0.42 * $0) } ?? Color.white.opacity(0.03))
                    .overlay {
                        if lit {
                            RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(AnalyticsStyle.mint.opacity(0.55), lineWidth: 1)
                        }
                    }
                    .shadow(color: AnalyticsStyle.mint.opacity(lit ? 0.35 : 0), radius: 6)
            }
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
                AnalyticsHero(eyebrow: date.formatted(.dateTime.weekday(.wide)) + (partial ? " · loaded" : ""),
                              value: VoltaFormat.number(units.distanceValue(km: drives.reduce(0) { $0 + $1.distanceKm })),
                              unit: units.distanceUnit, identifier: "screen.heatmap-day")
                if partial {
                    Text("Loaded history only").font(.system(size: 12, weight: .medium)).foregroundStyle(AnalyticsStyle.amber).padding(.top, 10)
                }
                if drives.isEmpty {
                    Text("No drives loaded for this day in the current selection")
                        .font(.system(size: 13, weight: .medium)).foregroundStyle(AnalyticsStyle.secondary).padding(.top, 18)
                } else {
                    AnalyticsSectionHeader("Drives", trailing: drives.count == 1 ? "1 drive" : "\(drives.count) drives")
                        .padding(.top, AnalyticsStyle.sectionGap)
                    LazyVStack(spacing: AnalyticsStyle.cardGap) {
                        ForEach(drives) { drive in
                            NavigationLink { DriveDetailView(drive: drive) } label: { DriveCard(drive: drive) }
                                .buttonStyle(VoltaPressStyle())
                                .voltaCascade()
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
