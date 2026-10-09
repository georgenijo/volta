import MapKit
import SwiftUI

struct DriveScoreRing: View {
    var score: Int
    var size: CGFloat = 44
    private var tint: Color { score >= 85 ? HistoryTheme.green : score >= 70 ? HistoryTheme.blue : HistoryTheme.amber }
    var body: some View {
        ZStack {
            Circle().trim(from: 0.12, to: 0.88).stroke(HistoryTheme.track, style: StrokeStyle(lineWidth: size * 0.075, lineCap: .round)).rotationEffect(.degrees(90))
            Circle().trim(from: 0.12, to: 0.12 + 0.76 * Double(score) / 100).stroke(tint, style: StrokeStyle(lineWidth: size * 0.075, lineCap: .round)).rotationEffect(.degrees(90))
            Text("\(score)").font(.system(size: size * 0.30, weight: .bold, design: .rounded)).foregroundStyle(.white)
        }.frame(width: size, height: size)
            .accessibilityLabel("Efficiency score \(score) of 100; rated consumption divided by actual consumption")
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

struct DriveRouteThumbnail: View {
    var points: [DriveRoutePoint]
    var body: some View {
        GeometryReader { geometry in
            let runs = DriveRouteSegments.runs(points)
            let valid = runs.flatMap { $0 }
            if let minLat = valid.map(\.latitude).min(), let maxLat = valid.map(\.latitude).max(), let minLon = valid.map(\.longitude).min(), let maxLon = valid.map(\.longitude).max() {
                let latSpan = max(maxLat - minLat, 0.00001), lonSpan = max(maxLon - minLon, 0.00001)
                Path { path in
                    for run in runs {
                        for (index, point) in run.enumerated() {
                            let p = CGPoint(x: (point.longitude - minLon) / lonSpan * geometry.size.width, y: (maxLat - point.latitude) / latSpan * geometry.size.height)
                            if index == 0 { path.move(to: p) } else { path.addLine(to: p) }
                        }
                    }
                }.stroke(.white.opacity(0.08), style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
            }
        }.allowsHitTesting(false).accessibilityHidden(true)
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
