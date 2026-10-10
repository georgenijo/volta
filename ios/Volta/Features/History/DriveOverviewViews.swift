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
                Circle().trim(from: 0.12, to: 0.12 + 0.76 * Double(value) / 100).stroke(tint, style: StrokeStyle(lineWidth: size * 0.075, lineCap: .round)).rotationEffect(.degrees(90))
            }
            Text(value.map(String.init) ?? "–").font(.system(size: size * 0.30, weight: .bold, design: .rounded)).foregroundStyle(.white)
        }.frame(width: size, height: size)
            .accessibilityLabel(value.map { "Drive score \($0) of 100" } ?? "Drive score unavailable")
    }
}

enum DriveRouteSegments {
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
struct DrivesRouteMap: View {
    var drives: [DriveSummary]
    private var runs: [[DriveRoutePoint]] { drives.flatMap { DriveRouteSegments.runs($0.route ?? []) } }
    var body: some View {
        ZStack(alignment: .bottom) {
            if runs.contains(where: { !$0.isEmpty }) {
                Map(interactionModes: []) {
                    ForEach(Array(runs.enumerated()), id: \.offset) { _, run in
                        if run.count >= 2 {
                            MapPolyline(coordinates: run.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) }).stroke(HistoryTheme.blue.opacity(0.8), lineWidth: 3)
                        } else if let p = run.first {
                            Annotation("Recorded position", coordinate: .init(latitude: p.latitude, longitude: p.longitude)) { Circle().fill(HistoryTheme.blue).frame(width: 6, height: 6) }
                        }
                    }
                }.mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll)).environment(\.colorScheme, .dark)
            } else {
                HistoryTheme.card
                Text("Routes not recorded for these drives").font(.system(size: 13)).foregroundStyle(HistoryTheme.secondary)
            }
            LinearGradient(colors: [.clear, HistoryTheme.background], startPoint: .top, endPoint: .bottom).allowsHitTesting(false)
        }.frame(height: 240).clipShape(.rect(cornerRadius: 24)).accessibilityLabel("Recorded routes for loaded drives")
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

struct RoadtripsView: View {
    var drives: [DriveSummary]
    var partial: Bool
    @Environment(\.units) private var units
    private var trips: [Roadtrip] { Roadtrip.group(drives) }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Drives linked by stops of up to 2 hours, covering at least \(units.formatDistance(100)). Closed drives only.").font(.system(size: 13)).foregroundStyle(HistoryTheme.secondary)
                if partial { Text("Loaded drives only · groups may change when more history is loaded").foregroundStyle(HistoryTheme.amber) }
                if trips.isEmpty { HistoryEmptyState(systemImage: "road.lanes", title: "No roadtrips in loaded drives", message: "Long drives and multi-stop chains covering at least \(units.formatDistance(100)) appear here.") }
                ForEach(trips) { trip in
                    NavigationLink { RoadtripDetailView(trip: trip, partial: partial) } label: {
                        HistoryCard {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("\(trip.drives[0].startPlace) → \(trip.drives.last!.endPlace)").font(.headline)
                                Text("\(units.formatDistance(trip.distanceKm)) · \(trip.drives.count) drives").foregroundStyle(HistoryTheme.green)
                                Text(trip.drives[0].start.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(HistoryTheme.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }.buttonStyle(.plain)
                }
            }.padding(HistoryTheme.gutter)
        }.navigationTitle("Roadtrips").historyScreenBackground()
    }
}

struct RoadtripDetailView: View {
    var trip: Roadtrip
    var partial: Bool
    @Environment(\.units) private var units
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DrivesRouteMap(drives: trip.drives)
                HistoryValue(value: VoltaFormat.number(units.distanceValue(km: trip.distanceKm)), unit: units.distanceUnit, size: 52)
                if partial { Text("Loaded history · this chain may be incomplete").foregroundStyle(HistoryTheme.amber) }
                ForEach(trip.drives) { drive in NavigationLink { DriveDetailView(drive: drive) } label: { DriveRow(drive: drive, showsDate: true) }.buttonStyle(.plain) }
            }.padding(HistoryTheme.gutter)
        }.navigationTitle("Roadtrip").historyScreenBackground()
    }
}

struct DrivesHeatmapView: View {
    var drives: [DriveSummary]
    var partial: Bool
    @Environment(\.units) private var units
    private var days: [DriveDay] { DriveDay.days(drives) }
    private var months: [Date] { Array(Set(days.compactMap { Calendar.current.dateInterval(of: .month, for: $0.date)?.start })).sorted().reversed() }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(partial ? "Loaded drives only · blank dates may have unloaded history" : "Distance per day · blank dates have no drives in this selection").font(.system(size: 13)).foregroundStyle(HistoryTheme.secondary)
                ForEach(months, id: \.self) { month in monthGrid(month) }
                if days.isEmpty { Text("No drives to show in this selection").foregroundStyle(HistoryTheme.secondary) }
            }.padding(HistoryTheme.gutter)
        }.navigationTitle("Heatmap").historyScreenBackground()
    }
    private func monthGrid(_ month: Date) -> some View {
        let calendar = Calendar.current
        let count = calendar.range(of: .day, in: .month, for: month)!.count
        let offset = (calendar.component(.weekday, from: month) - calendar.firstWeekday + 7) % 7
        let lookup = Dictionary(uniqueKeysWithValues: days.map { ($0.date, $0) })
        let maxDistance = max(days.map(\.distanceKm).max() ?? 1, 1)
        let symbols = calendar.shortWeekdaySymbols
        return VStack(alignment: .leading, spacing: 12) {
            SectionLabel(month.formatted(.dateTime.month(.wide).year()))
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 7), spacing: 6) {
                ForEach(0..<7) { index in Text(symbols[(calendar.firstWeekday - 1 + index) % 7]).font(.system(size: 10)).foregroundStyle(HistoryTheme.secondary) }
                ForEach(0..<(offset + count), id: \.self) { index in
                    if index < offset { Color.clear.frame(height: 42) } else {
                        let day = calendar.date(byAdding: .day, value: index - offset, to: month)!
                        let value = lookup[day]
                        let matching = drives.filter { calendar.isDate($0.start, inSameDayAs: day) }
                        NavigationLink { HeatmapDayView(date: day, drives: matching, partial: partial) } label: {
                            Text("\(index - offset + 1)").font(.system(size: 13, weight: .semibold)).foregroundStyle(.white).frame(maxWidth: .infinity).frame(height: 42)
                                .background(value.map { HistoryTheme.green.opacity(0.2 + 0.8 * $0.distanceKm / maxDistance) } ?? HistoryTheme.card, in: .rect(cornerRadius: 8))
                        }.buttonStyle(.plain).accessibilityLabel("\(day.formatted(date: .abbreviated, time: .omitted)), \(value.map { units.formatDistance($0.distanceKm) } ?? (partial ? "No loaded drives" : "No drives in selection"))")
                    }
                }
            }
        }
    }
}

private struct HeatmapDayView: View {
    var date: Date
    var drives: [DriveSummary]
    var partial: Bool
    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if partial { Text("Loaded history only").foregroundStyle(HistoryTheme.amber) }
                if drives.isEmpty { Text("No drives loaded for this day in the current selection").foregroundStyle(HistoryTheme.secondary) }
                ForEach(drives) { drive in NavigationLink { DriveDetailView(drive: drive) } label: { DriveRow(drive: drive) }.buttonStyle(.plain) }
            }.padding(HistoryTheme.gutter)
        }.navigationTitle(date.formatted(date: .abbreviated, time: .omitted)).historyScreenBackground()
    }
}
