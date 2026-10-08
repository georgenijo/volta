import MapKit
import SwiftUI

/// TeslaMate geofences (`/places`), loaded once per screen. No external
/// geocoding: a session is mapped only from coordinates the server sent or a
/// geofence with a matching name.
@MainActor @Observable
final class HistoryPlaces {
    enum State: Equatable {
        case idle
        case loading
        case loaded([Place])
        case failed(String)
    }

    private(set) var state: State = .idle

    func load(dataSource: any VoltaDataSource, vehicleID: Int) async {
        switch state {
        case .loading, .loaded: return
        case .idle, .failed: break
        }
        state = .loading
        do {
            state = .loaded(try await dataSource.places(vehicleID: vehicleID))
        } catch {
            // Cancelled: back to idle so the next appearance retries. Never stay `.loading`.
            state = (error is CancellationError || Task.isCancelled) ? .idle : .failed(error.localizedDescription)
        }
    }

    func retry(dataSource: any VoltaDataSource, vehicleID: Int) async {
        if case .failed = state { state = .idle }
        await load(dataSource: dataSource, vehicleID: vehicleID)
    }
}

/// Where a charge or idle session happened, as far as we know.
enum HistoryLocation: Equatable {
    /// Coordinates from the record or a matched geofence.
    case known(latitude: Double, longitude: Double)
    /// Waiting for `/places` to decide whether the place name matches a geofence.
    case pending
    /// `/places` failed, so a geofence match couldn't be checked.
    case placesUnavailable(String)
    /// No coordinates and no matching geofence (or no place name to match).
    case unmapped

    var coordinate: CLLocationCoordinate2D? {
        if case .known(let lat, let lon) = self { return CLLocationCoordinate2D(latitude: lat, longitude: lon) }
        return nil
    }

    static func resolve(latitude: Double?, longitude: Double?, placeName: String?,
                        places: HistoryPlaces.State) -> HistoryLocation {
        if let latitude, let longitude, (-90...90).contains(latitude), (-180...180).contains(longitude) {
            return .known(latitude: latitude, longitude: longitude)
        }
        guard let placeName, !key(placeName).isEmpty else { return .unmapped }
        switch places {
        case .idle, .loading:
            return .pending
        case .failed(let message):
            return .placesUnavailable(message)
        case .loaded(let places):
            guard let place = places.first(where: { key($0.name) == key(placeName) }) else { return .unmapped }
            return .known(latitude: place.latitude, longitude: place.longitude)
        }
    }

    /// Whether resolving this record could use `/places` at all.
    static func needsPlaces(latitude: Double?, longitude: Double?, placeName: String?) -> Bool {
        (latitude == nil || longitude == nil) && !(placeName.map(key)?.isEmpty ?? true)
    }

    private static func key(_ s: String) -> String { s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
}

extension ChargeSummary {
    func location(_ places: HistoryPlaces.State) -> HistoryLocation {
        .resolve(latitude: latitude, longitude: longitude, placeName: placeName, places: places)
    }
    var needsPlaces: Bool { HistoryLocation.needsPlaces(latitude: latitude, longitude: longitude, placeName: placeName) }
}

extension IdleSummary {
    func location(_ places: HistoryPlaces.State) -> HistoryLocation {
        .resolve(latitude: latitude, longitude: longitude, placeName: placeName, places: places)
    }
    var needsPlaces: Bool { HistoryLocation.needsPlaces(latitude: latitude, longitude: longitude, placeName: placeName) }
}

/// A pin cluster for the list map mode.
struct HistoryMapPin: Identifiable {
    var id: String
    var coordinate: CLLocationCoordinate2D
    var title: String
    var subtitle: String
    var systemImage: String
    var tint: Color
}

/// Dark, flat map showing session locations.
struct HistorySessionsMap: View {
    var pins: [HistoryMapPin]
    /// Groups that are still resolving or can't be pinned.
    var summary = HistoryMapSummary()
    var retryPlaces: () -> Void = {}
    var onSelect: (String) -> Void = { _ in }
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        Map(position: $position) {
            ForEach(pins) { pin in
                Annotation(pin.title, coordinate: pin.coordinate, anchor: .bottom) {
                    Button { onSelect(pin.id) } label: {
                        VStack(spacing: 4) {
                            VStack(spacing: 1) {
                                Text(pin.title)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.white)
                                Text(pin.subtitle.uppercased())
                                    .font(.system(size: 9, weight: .semibold))
                                    .tracking(1)
                                    .foregroundStyle(HistoryTheme.secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(HistoryTheme.card.opacity(0.92), in: .rect(cornerRadius: 10))
                            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(HistoryTheme.hairline) }
                            ZStack {
                                Circle().fill(pin.tint.opacity(0.25)).frame(width: 30, height: 30)
                                Circle().fill(pin.tint).frame(width: 18, height: 18)
                                Image(systemName: pin.systemImage)
                                    .font(.system(size: 9, weight: .bold))
                                    .foregroundStyle(.black.opacity(0.75))
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                .annotationTitles(.hidden)
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
        .mapControls { }
        // Leave room for the callouts drawn above each pin when auto-framing.
        .safeAreaPadding(.init(top: 64, leading: 56, bottom: 24, trailing: 56))
        .environment(\.colorScheme, .dark)
        .onChange(of: pins.map(\.id)) { position = .automatic }
        .overlay(alignment: .bottom) { status.padding(.bottom, HistoryTheme.bottomInset + 20) }
    }

    @ViewBuilder private var status: some View {
        if summary.pending > 0 {
            ProgressView().tint(.white)
        } else if summary.placesFailed || summary.unmapped > 0 {
            VStack(spacing: 8) {
                Text(summary.message)
                    .font(.system(size: 13))
                    .foregroundStyle(HistoryTheme.secondary)
                    .multilineTextAlignment(.center)
                if summary.placesFailed {
                    Button("Retry", action: retryPlaces)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(HistoryTheme.blue)
                        .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(HistoryTheme.card.opacity(0.92), in: .rect(cornerRadius: 14))
            .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(HistoryTheme.hairline) }
            .padding(.horizontal, HistoryTheme.gutter)
        }
    }
}

/// Counts of map groups that couldn't be pinned, for the map status overlay.
struct HistoryMapSummary: Equatable {
    var pending = 0
    var unmapped = 0
    var placesFailed = false

    init() {}

    init<S: Sequence>(_ locations: S) where S.Element == HistoryLocation {
        for location in locations {
            switch location {
            case .known: break
            case .pending: pending += 1
            case .unmapped: unmapped += 1
            case .placesUnavailable: unmapped += 1; placesFailed = true
            }
        }
    }

    /// Counts are sessions, not places: every session that can't be pinned is counted.
    var message: String {
        let sessions = unmapped == 1 ? "1 session" : "\(unmapped) sessions"
        if placesFailed { return "Saved places couldn't load, so \(sessions) can't be mapped." }
        return unmapped == 1 ? "1 session has no coordinates and isn't shown."
            : "\(unmapped) sessions have no coordinates and aren't shown."
    }
}

/// Sessions sharing one resolved map position.
struct HistoryMapCluster<Item: Identifiable>: Identifiable {
    var id: String
    var latitude: Double
    var longitude: Double
    var items: [Item]

    var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }

    /// The most common title among the cluster's sessions (first seen wins ties).
    func title(_ title: (Item) -> String) -> String {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for item in items {
            let t = title(item)
            if counts[t] == nil { order.append(t) }
            counts[t, default: 0] += 1
        }
        var best = ""
        var bestCount = 0
        for t in order where counts[t, default: 0] > bestCount {
            best = t
            bestCount = counts[t, default: 0]
        }
        return best
    }
}

/// Groups sessions by their *resolved* location. Only sessions with known
/// coordinates are pinned, each at its own position; sessions that can't be
/// resolved stay out of every cluster and are counted in `summary`.
struct HistoryMapGrouping<Item: Identifiable> {
    var clusters: [HistoryMapCluster<Item>]
    var summary: HistoryMapSummary

    init(_ items: [Item], location: (Item) -> HistoryLocation) {
        var order: [String] = []
        var byKey: [String: HistoryMapCluster<Item>] = [:]
        var unresolved: [HistoryLocation] = []
        for item in items {
            let resolved = location(item)
            guard case .known(let latitude, let longitude) = resolved else {
                unresolved.append(resolved)
                continue
            }
            let key = Self.key(latitude: latitude, longitude: longitude)
            if byKey[key] == nil {
                order.append(key)
                byKey[key] = HistoryMapCluster(id: key, latitude: latitude, longitude: longitude, items: [])
            }
            byKey[key]?.items.append(item)
        }
        clusters = order.compactMap { byKey[$0] }
        summary = HistoryMapSummary(unresolved)
    }

    /// Same position to about a metre (geofence matches share exact coordinates).
    static func key(latitude: Double, longitude: Double) -> String {
        String(format: "%.5f,%.5f", latitude, longitude)
    }
}

/// Map-mode scope and pagination: says whether the map shows every session
/// in the range or only the loaded pages, and loads the next page on request.
struct HistoryMapScopeBar<Item: Codable & Hashable & Sendable & Identifiable>: View {
    var feed: HistoryFeed<Item>
    var period: String
    var noun: String
    var count: Int
    var retryRefresh: () async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                if feed.hasMore {
                    Image(systemName: "circle.dashed")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(HistoryTheme.secondary)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(HistoryTotalsScope.title(period: period, hasMore: feed.hasMore, noun: noun).uppercased())
                        .font(.system(size: 11, weight: .semibold))
                        .tracking(1)
                        .foregroundStyle(HistoryTheme.secondary)
                    Text(feed.hasMore ? "\(count) loaded so far" : "\(count) in range")
                        .font(.system(size: 13))
                        .foregroundStyle(.white.opacity(0.9))
                }
                Spacer(minLength: 8)
                trailing
            }
            if let error = feed.footerError {
                Text(error)
                    .font(.system(size: 12))
                    .foregroundStyle(HistoryTheme.secondary)
                    .lineLimit(2)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(HistoryTheme.card.opacity(0.92), in: .rect(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(HistoryTheme.hairline) }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("map.scope")
    }

    @ViewBuilder private var trailing: some View {
        if feed.footerError != nil {
            Button("Retry") {
                Task { if feed.refreshError != nil { await retryRefresh() } else { await feed.retryLoadMore() } }
            }
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(HistoryTheme.blue)
            .buttonStyle(.plain)
        } else if feed.isLoadingMore || feed.isRefreshing {
            ProgressView().tint(.white)
        } else if feed.hasMore {
            Button("Load more") { Task { await feed.loadMore() } }
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(HistoryTheme.blue)
                .buttonStyle(.plain)
                .disabled(!feed.canLoadMore)
                .accessibilityIdentifier("map.loadMore")
        }
    }
}

/// Lists the sessions behind one map pin; selecting one opens its detail.
struct HistoryClusterSheet<Item: Identifiable, Row: View>: View {
    var title: String
    var items: [Item]
    var onSelect: (Item) -> Void
    @ViewBuilder var row: (Item) -> Row

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                Text(title)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.top, 24)
                Text(items.count == 1 ? "1 session" : "\(items.count) sessions")
                    .font(.system(size: 13))
                    .foregroundStyle(HistoryTheme.secondary)
                    .padding(.bottom, 6)
                ForEach(items) { item in
                    Button { onSelect(item) } label: { row(item) }
                        .buttonStyle(VoltaPressStyle())
                }
            }
            .padding(.horizontal, HistoryTheme.gutter)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.hidden)
        .background(HistoryTheme.background.ignoresSafeArea())
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .preferredColorScheme(.dark)
    }
}

/// Detail-screen location: a small non-interactive map when coordinates are
/// known, otherwise the address text with no map.
struct HistoryLocationCard: View {
    var location: HistoryLocation
    var address: String?
    var systemImage: String
    var tint: Color
    var retryPlaces: () -> Void = {}
    var height: CGFloat = 150

    var body: some View {
        switch location {
        case .known:
            if let coordinate = location.coordinate { map(coordinate) }
        case .pending:
            HistoryCard {
                HStack(spacing: 12) {
                    addressLabel
                    Spacer(minLength: 8)
                    ProgressView().tint(HistoryTheme.secondary)
                }
            }
        case .placesUnavailable:
            HistoryCard {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        addressLabel
                        Text("Saved places couldn't load, so this location isn't mapped.")
                            .font(.system(size: 12))
                            .foregroundStyle(HistoryTheme.tertiary)
                    }
                    Spacer(minLength: 8)
                    Button("Retry", action: retryPlaces)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(HistoryTheme.blue)
                        .buttonStyle(.plain)
                }
            }
        case .unmapped:
            HistoryCard { addressLabel.frame(maxWidth: .infinity, alignment: .leading) }
        }
    }

    private var addressLabel: some View {
        HStack(spacing: 10) {
            Image(systemName: "mappin.and.ellipse")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(HistoryTheme.secondary)
            Text(address ?? "Address not recorded")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(address == nil ? HistoryTheme.secondary : .white)
                .lineLimit(2)
        }
        .accessibilityElement(children: .combine)
    }

    private func map(_ coordinate: CLLocationCoordinate2D) -> some View {
        ZStack {
            Map(initialPosition: .camera(MapCamera(centerCoordinate: coordinate, distance: 1600, heading: 0, pitch: 45)),
                interactionModes: []) {
                Annotation("", coordinate: coordinate) {
                    ZStack {
                        Circle().fill(tint.opacity(0.22)).frame(width: 46, height: 46)
                        Circle().fill(tint).frame(width: 24, height: 24)
                            .shadow(color: tint.opacity(0.6), radius: 8)
                        Image(systemName: systemImage)
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.black.opacity(0.75))
                    }
                }
            }
            .mapStyle(.standard(elevation: .realistic, emphasis: .muted, pointsOfInterest: .excludingAll))
            .environment(\.colorScheme, .dark)
            .allowsHitTesting(false)
            LinearGradient(colors: [.clear, HistoryTheme.card.opacity(0.85)], startPoint: .center, endPoint: .bottom)
                .allowsHitTesting(false)
        }
        .frame(height: height)
        .clipShape(.rect(cornerRadius: HistoryTheme.cardRadius))
        .overlay { RoundedRectangle(cornerRadius: HistoryTheme.cardRadius).strokeBorder(HistoryTheme.hairline) }
    }
}

// MARK: - Route coloring

enum RouteColoring: String, CaseIterable, Identifiable {
    case speed = "Speed"
    case efficiency = "Efficiency"
    var id: String { rawValue }
}

struct RouteSegment: Identifiable {
    var id: Int
    var coordinates: [CLLocationCoordinate2D]
    var color: Color
}

enum RouteBuilder {
    /// Splits a drive path into short colored polylines, downsampled so long
    /// drives stay cheap to render.
    static func segments(_ path: [DrivePoint], coloring: RouteColoring, maxSegments: Int = 240) -> [RouteSegment] {
        guard path.count > 1 else { return [] }
        let stride = max(1, Int((Double(path.count - 1) / Double(maxSegments)).rounded(.up)))
        var indices = Array(Swift.stride(from: 0, to: path.count, by: stride))
        if indices.last != path.count - 1 { indices.append(path.count - 1) }
        var result: [RouteSegment] = []
        for (n, pair) in zip(indices, indices.dropFirst()).enumerated() {
            let slice = path[pair.0...pair.1]
            let value: Double?
            switch coloring {
            case .speed: value = averageSpeedKph(slice)
            case .efficiency: value = efficiencyWhPerKm(slice)
            }
            result.append(RouteSegment(
                id: n,
                coordinates: slice.map { CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude) },
                color: color(for: value, coloring: coloring)))
        }
        return result
    }

    static func averageSpeedKph<C: Collection>(_ points: C) -> Double? where C.Element == DrivePoint {
        let speeds = points.compactMap(\.speedKph)
        return speeds.isEmpty ? nil : speeds.reduce(0, +) / Double(speeds.count)
    }

    /// Wh/km from samples that recorded both speed and power. Nil (neutral
    /// color) when there are no such samples or the car was barely moving, so
    /// missing power never reads as efficient driving.
    static func efficiencyWhPerKm<C: Collection>(_ points: C) -> Double? where C.Element == DrivePoint {
        var speed = 0.0, power = 0.0, n = 0
        for point in points {
            guard let s = point.speedKph, let p = point.powerKw, s.isFinite, p.isFinite else { continue }
            speed += s; power += p; n += 1
        }
        guard n > 0 else { return nil }
        let avgSpeed = speed / Double(n)
        guard avgSpeed > 3 else { return nil }
        return (power / Double(n)) * 1000 / avgSpeed
    }

    static func color(for value: Double?, coloring: RouteColoring) -> Color {
        guard let value else { return HistoryTheme.secondary }
        switch coloring {
        case .speed:
            // km/h: city → highway
            switch value {
            case ..<35: return HistoryTheme.blue
            case ..<70: return HistoryTheme.green
            case ..<105: return HistoryTheme.amber
            default: return HistoryTheme.red
            }
        case .efficiency:
            // Wh/km: regen → hungry
            switch value {
            case ..<0: return HistoryTheme.purple
            case ..<130: return HistoryTheme.green
            case ..<190: return HistoryTheme.amber
            default: return HistoryTheme.red
            }
        }
    }

    static func legend(_ coloring: RouteColoring, units: UnitPreferences) -> [(String, Color)] {
        switch coloring {
        case .speed:
            let f = { (kph: Double) in VoltaFormat.number(units.distanceValue(km: kph), digits: 0) }
            let u = units.distance == .miles ? "mph" : "km/h"
            return [("<\(f(35))", HistoryTheme.blue), ("\(f(35))–\(f(70))", HistoryTheme.green),
                    ("\(f(70))–\(f(105))", HistoryTheme.amber), (">\(f(105)) \(u)", HistoryTheme.red)]
        case .efficiency:
            let f = { (wh: Double) in VoltaFormat.number(units.efficiencyValue(whPerKm: wh), digits: 0) }
            return [("Regen", HistoryTheme.purple), ("<\(f(130))", HistoryTheme.green),
                    ("\(f(130))–\(f(190))", HistoryTheme.amber), (">\(f(190)) \(units.efficiencyUnit)", HistoryTheme.red)]
        }
    }
}

/// A tapped multi-session pin, for `HistoryClusterSheet`.
struct HistoryClusterSelection: Identifiable, Equatable {
    var id: String
    var title: String
    var itemIDs: [Int]
}
