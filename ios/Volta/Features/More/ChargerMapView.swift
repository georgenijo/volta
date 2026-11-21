import MapKit
import SwiftUI

struct ChargerMapView: View {
    @Environment(\.dataSource) private var dataSource
    @Environment(\.vehicleID) private var vehicleID
    @State private var state: Loadable<[ChargerLocation]> = .loading
    @State private var generation = UUID()
    @Environment(\.pushMoreRoute) private var push
    @State private var loadedVehicle: Int?
    /// Each place's kind, from all of its recorded sessions.
    @State private var kinds: [String: ChargerKind] = [:]
    /// Bumped by a pull to refresh that brought data, for its haptic.
    @State private var refreshes = 0

    var body: some View {
        // Wide: the map fills one pane beside the list of places.
        ScreenKit.Page(splits: !(state.value ?? []).isEmpty) {
            switch state {
            case .loading:
                // The map's shape, sweeping, while the places load.
                RoundedRectangle(cornerRadius: 22).fill(Color.voltaInk.opacity(0.06))
                    .modifier(ScreenKit.MapHeight())
                    .voltaSkeleton(true)
            case .failed(let message):
                ErrorState(title: "Couldn't load charging places", message: message, retry: load)
                    .padding(.top, 40)
            case .loaded(let locations):
                Text("Your recorded charging places · TeslaMate history").font(.caption).foregroundStyle(ScreenKit.secondary)
                    // Kinds for every place: its pin and its card.
                    .task(id: locations.map(\.id)) { await loadKinds(locations) }
                if locations.isEmpty {
                    EmptyState(systemImage: "mappin.and.ellipse", title: "No charging places yet", message: "Locations appear after TeslaMate records a charging session. This map shows your own history.")
                } else {
                    let mapped = locations.filter(\.hasCoordinate)
                    if !mapped.isEmpty {
                        // The shared grey basemap; badges drawn over it in colour.
                        PinnedMap(items: mapped, coordinate: { CLLocationCoordinate2D(latitude: $0.latitude!, longitude: $0.longitude!) },
                                  // Whole badges at least 40 pt from every edge of the card.
                                  clearance: .init(top: 40, leading: 40, bottom: 40, trailing: 40),
                                  pinAnchor: .center) { location in
                            Button { push?(.chargerPlace(location)) } label: {
                                ChargerBadge(kind: kinds[location.id] ?? .unknown)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(location.name), \((kinds[location.id] ?? .unknown).title), \(location.sessionCount) sessions")
                        }
                        .modifier(ScreenKit.MapHeight())
                        .clipShape(.rect(cornerRadius: 22))
                        .voltaFocusIn(0)
                    } else {
                        Text("TeslaMate has not recorded coordinates for these places. Their sessions are available below.").foregroundStyle(ScreenKit.secondary)
                    }
                }
            }
        } secondary: {
            switch state {
            case .loading:
                ForEach(0..<3, id: \.self) { i in
                    placeCard(Self.placeholder(i), kind: .unknown).voltaSkeleton(true)
                }
            case .loaded(let locations):
                ForEach(Array(locations.enumerated()), id: \.element.id) { index, location in
                    Button { push?(.chargerPlace(location)) } label: {
                        placeCard(location, kind: kinds[location.id] ?? .unknown)
                    }
                    .buttonStyle(.plain)
                    .chargeRowFocusIn(index + 1)
                }
            case .failed:
                EmptyView()
            }
        }
        .screenKitPage("Charger map", screen: "charger-map")
        // The task starts again when the page moves, as when iPhone Duo folds;
        // only another vehicle reloads.
        .task(id: vehicleID) { if loadedVehicle != vehicleID || state.value == nil { await load() } }
        .refreshable {
            await load()
            if state.value != nil { refreshes += 1 }
        }
        .voltaFeedback(.refreshed, trigger: refreshes)
    }

    /// One place: its badge (the same kind as its pin), visits, energy, power and cost.
    private func placeCard(_ location: ChargerLocation, kind: ChargerKind) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    ChargerBadge(kind: kind)
                    Text(location.name).font(.headline)
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(ScreenKit.secondary)
                }
                Text("\(location.sessionCount) sessions · Last visit \(location.lastVisit.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(ScreenKit.secondary)
                if let energy = location.energyAddedKwh {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        RollingNumber(value: energy) { VoltaFormat.number($0) }
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                        Text("kWh added").foregroundStyle(ScreenKit.secondary)
                    }
                    .accessibilityElement(children: .combine)
                } else {
                    Text("Total energy unknown — some sessions lack readings").foregroundStyle(ScreenKit.secondary)
                }
                Text(location.avgPowerKw.map { "\(VoltaFormat.number($0)) kW average input · \(location.powerSessionCount) measured sessions" } ?? "Average power not recorded").font(.caption).foregroundStyle(ScreenKit.secondary)
                // A real figure reads as one; an unknown cost stays quiet.
                Text(ChargerPresentation.cost(location.cost, currency: location.currency))
                    .font(location.cost != nil ? .subheadline : .caption)
                    .foregroundStyle(location.cost != nil ? Color.voltaTextPrimary : ScreenKit.secondary)
                if !location.hasCoordinate { Text("Coordinates not recorded").font(.caption).foregroundStyle(ScreenKit.secondary) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// A synthetic place for the loading skeleton.
    static func placeholder(_ index: Int) -> ChargerLocation {
        ChargerLocation(id: "placeholder-\(index)", name: "Charging place", latitude: nil, longitude: nil, sessionCount: 12,
                        lastVisit: .now, energyAddedKwh: 240, avgPowerKw: 7.2, powerSessionCount: 12, cost: 40, currency: "USD")
    }

    /// A place's kind comes from every one of its recorded sessions
    /// (`ChargerKind(agreeing:)`): a place whose sessions disagree, have none,
    /// or can't all be loaded stays the neutral unknown badge.
    @MainActor private func loadKinds(_ places: [ChargerLocation]) async {
        let id = vehicleID
        for place in places where kinds[place.id] == nil {
            let kind = await Self.kind(of: place, vehicleID: id, dataSource: dataSource)
            guard !Task.isCancelled, vehicleID == id else { return }
            kinds[place.id] = kind
        }
    }

    static func kind(of place: ChargerLocation, vehicleID: Int, dataSource: any VoltaDataSource) async -> ChargerKind {
        var sessions: [ChargeSummary] = []
        var cursor: String?
        for _ in 0..<200 {
            guard !Task.isCancelled,
                  let page = try? await dataSource.chargerSessions(vehicleID: vehicleID, locationID: place.id, cursor: cursor)
            else { return .unknown }
            sessions += page.items
            cursor = page.nextCursor
            if cursor == nil { return ChargerKind(agreeing: sessions) }
        }
        return .unknown
    }

    @MainActor private func load() async {
        let id = vehicleID, token = UUID(); generation = token
        // A refresh keeps the places on screen; a first load or another vehicle shows the skeleton.
        if state.value == nil || loadedVehicle != id { state = .loading }
        do {
            let locations = try await dataSource.chargerLocations(vehicleID: id)
            guard !Task.isCancelled, generation == token, vehicleID == id else { return }
            // A refresh re-derives every place's kind from its sessions.
            kinds = [:]
            loadedVehicle = id
            state = .loaded(locations)
        } catch {
            guard !Task.isCancelled, generation == token, vehicleID == id else { return }
            state = .failed(error.localizedDescription)
        }
    }
}
struct ChargerLocationSessionsView: View {
    let location: ChargerLocation
    @Environment(\.dataSource) private var dataSource
    @Environment(\.vehicleID) private var vehicleID
    @State private var state: Loadable<[ChargeSummary]> = .loading
    @State private var cursor: String?
    @State private var loadedVehicle: Int?
    @State private var paging = false
    @State private var pageError: String?
    @State private var generation = UUID()
    @Environment(\.pushMoreRoute) private var push
    var body: some View {
        ScreenKit.Page(spacing: 16) {
            switch state {
            case .loading:
                ForEach(0..<4, id: \.self) { i in
                    sessionCard(ChargeSummary.skeleton(i)).voltaSkeleton(true)
                }
            case .failed(let message):
                ErrorState(title: "Couldn't load sessions", message: message) { await load(reset: true) }
                    .padding(.top, 40)
            case .loaded(let sessions):
                if sessions.isEmpty {
                    EmptyState(systemImage: "bolt.slash", title: "No sessions here",
                               message: "TeslaMate no longer holds any session at this recorded place.")
                        .padding(.top, 40)
                }
                ForEach(Array(sessions.enumerated()), id: \.element.id) { index, session in
                    Button { push?(.chargerSession(session)) } label: { sessionCard(session) }
                        .buttonStyle(.plain)
                        .chargeRowFocusIn(index)
                }
                if let pageError { Text(pageError).foregroundStyle(ScreenKit.red) }
                if cursor != nil { Button(paging ? "Loading…" : "Load more sessions") { Task { await load(reset: false) } }.disabled(paging) }
            }
        }.screenKitPage(location.name).task(id: vehicleID) { if loadedVehicle != vehicleID || state.value == nil { await load(reset: true) } }
    }
    private func sessionCard(_ session: ChargeSummary) -> some View {
        Card {
            VStack(alignment: .leading, spacing: 8) {
                Text(VoltaFormat.dateTime(session.start)).font(.headline)
                Text(session.energyAddedKwh.map { VoltaFormat.energy($0) + " added" } ?? "Energy not recorded")
                Text(ChargerPresentation.cost(session.cost, currency: session.currency)).font(.caption).foregroundStyle(ScreenKit.secondary)
                if session.end == nil { Text("Session in progress").font(.caption).foregroundStyle(ScreenKit.blue) }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    @MainActor private func load(reset: Bool) async {
        if !reset && paging { return }
        let id = vehicleID, token = UUID(); generation = token
        let previous = reset ? [] : (state.value ?? [])
        let next = reset ? nil : cursor
        if reset { state = .loading; cursor = nil }
        paging = true; pageError = nil
        defer { if generation == token { paging = false } }
        do {
            let result = try await dataSource.chargerSessions(vehicleID: id, locationID: location.id, cursor: next)
            guard !Task.isCancelled, generation == token, vehicleID == id else { return }
            var seen = Set(previous.map(\.id))
            loadedVehicle = id
            state = .loaded(previous + result.items.filter { seen.insert($0.id).inserted }); cursor = result.nextCursor
        } catch {
            guard !Task.isCancelled, generation == token, vehicleID == id else { return }
            if reset { state = .failed(error.localizedDescription) } else { pageError = error.localizedDescription }
        }
        if generation == token { paging = false }
    }
}
enum ChargerPresentation {
    static func cost(_ value: Double?, currency: String?) -> String {
        guard let value else { return "Cost unknown — not recorded for every session" }
        guard let currency else { return "Recorded cost \(VoltaFormat.number(value, digits: 2)) · currency unknown" }
        return VoltaFormat.money(value, currency: currency)
    }
}
#Preview { NavigationStack { ChargerMapView() }.voltaPreviewEnvironment() }
