import MapKit
import SwiftUI

struct ChargerMapView: View {
    @Environment(\.dataSource) private var dataSource
    @Environment(\.vehicleID) private var vehicleID
    @State private var state: Loadable<[ChargerLocation]> = .loading
    @State private var generation = UUID()
    @State private var selected: ChargerLocation?
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                LoadableContent(state: state, retry: load) { locations in
                    Text("Your recorded charging places · TeslaMate history").font(.system(size: 12, weight: .medium)).foregroundStyle(ScreenKit.secondary)
                    if locations.isEmpty {
                        EmptyState(systemImage: "mappin.and.ellipse", title: "No charging places yet", message: "Locations appear after TeslaMate records a charging session. This map shows your own history.")
                    } else {
                        let mapped = locations.filter(\.hasCoordinate)
                        if !mapped.isEmpty {
                            Map {
                                ForEach(mapped) { location in
                                    Annotation(location.name, coordinate: CLLocationCoordinate2D(latitude: location.latitude!, longitude: location.longitude!)) {
                                        Button { selected = location } label: {
                                            Image(systemName: "bolt.fill").padding(12).foregroundStyle(.white).background(ScreenKit.blue, in: Circle())
                                        }.accessibilityLabel("\(location.name), \(location.sessionCount) sessions")
                                    }
                                }
                            }.mapStyle(.standard(elevation: .flat, pointsOfInterest: .excludingAll, showsTraffic: false))
                                .frame(height: 300).clipShape(.rect(cornerRadius: 22))
                        } else {
                            Text("TeslaMate has not recorded coordinates for these places. Their sessions are available below.").foregroundStyle(ScreenKit.secondary)
                        }
                        ForEach(locations) { location in
                            Button { selected = location } label: {
                                Card {
                                    VStack(alignment: .leading, spacing: 12) {
                                        HStack { Text(location.name).font(.system(size: 16, weight: .semibold)); Spacer(); ScreenKit.Chevron() }
                                        Text("\(location.sessionCount) sessions · Last visit \(location.lastVisit.formatted(date: .abbreviated, time: .omitted))").font(.system(size: 12, weight: .medium)).foregroundStyle(ScreenKit.secondary)
                                        Text(location.energyAddedKwh.map { VoltaFormat.energy($0) + " added" } ?? "Total energy unknown — some sessions lack readings")
                                        Text(location.avgPowerKw.map { "\(VoltaFormat.number($0)) kW average input · \(location.powerSessionCount) measured sessions" } ?? "Average power not recorded").font(.system(size: 12, weight: .medium)).foregroundStyle(ScreenKit.secondary)
                                        Text(ChargerPresentation.cost(location.cost, currency: location.currency)).font(.system(size: 12, weight: .medium))
                                        if !location.hasCoordinate { Text("Coordinates not recorded").font(.system(size: 12, weight: .medium)).foregroundStyle(ScreenKit.secondary) }
                                    }.frame(maxWidth: .infinity, alignment: .leading)
                                }
                            }.buttonStyle(.plain)
                        }
                    }
                }
            }.padding(.horizontal, ScreenKit.horizontalPadding).padding(.bottom, ScreenKit.bottomBarClearance)
        }.screenKitPage("Charger Map")
            .task(id: vehicleID) { selected = nil; await load() }
            .refreshable { await load() }
            .navigationDestination(item: $selected) { location in ChargerLocationSessionsView(location: location) }
    }
    @MainActor private func load() async {
        let id = vehicleID, token = UUID(); generation = token; state = .loading
        do {
            let locations = try await dataSource.chargerLocations(vehicleID: id)
            guard !Task.isCancelled, generation == token, vehicleID == id else { return }
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
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                LoadableContent(state: state, retry: { await load(reset: true) }) { sessions in
                    if sessions.isEmpty { Text("No sessions remain at this recorded location.").foregroundStyle(ScreenKit.secondary) }
                    ForEach(sessions) { session in
                        NavigationLink { ChargingDetailView(charge: session) } label: {
                            Card {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(VoltaFormat.dateTime(session.start)).font(.system(size: 16, weight: .semibold))
                                    Text(session.energyAddedKwh.map { VoltaFormat.energy($0) + " added" } ?? "Energy not recorded")
                                    Text(ChargerPresentation.cost(session.cost, currency: session.currency)).font(.system(size: 12, weight: .medium)).foregroundStyle(ScreenKit.secondary)
                                    if session.end == nil { Text("Session in progress").font(.system(size: 12, weight: .medium)).foregroundStyle(ScreenKit.blue) }
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }.buttonStyle(.plain)
                    }
                    if let pageError { Text(pageError).foregroundStyle(ScreenKit.red) }
                    if cursor != nil { Button(paging ? "Loading…" : "Load more sessions") { Task { await load(reset: false) } }.disabled(paging) }
                }
            }.padding(.horizontal, ScreenKit.horizontalPadding).padding(.bottom, ScreenKit.bottomBarClearance)
        }.screenKitPage(location.name).task(id: vehicleID) { if loadedVehicle != vehicleID || state.value == nil { await load(reset: true) } }
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
