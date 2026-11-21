import MapKit
import SwiftUI

/// TeslaMate geofences for the selected vehicle.
struct PlacesView: View {
    @Environment(\.dataSource) private var dataSource
    @Environment(\.vehicleID) private var vehicleID
    @Environment(\.units) private var units
    @State private var state: Loadable<[Place]> = .loading
    @Environment(\.openURL) private var openURL

    static let geofenceDocs = URL(string: "https://docs.teslamate.org")!

    var body: some View {
        // Wide: the map fills one pane beside the list of geofences.
        ScreenKit.Page(splits: !(state.value ?? []).isEmpty, spacing: 22) {
            LoadableContent(state: state, retry: load, errorTitle: "Couldn't load places") { places in
                if places.isEmpty {
                    EmptyState(systemImage: "mappin.slash", title: "No saved places",
                               message: "Add geofences in TeslaMate and they'll appear here, named in your drives and charges.",
                               action: .init("Open TeslaMate docs", systemImage: "arrow.up.right") { openURL(Self.geofenceDocs) })
                        .padding(.top, 60)
                } else {
                    map(places).voltaFocusIn(0)
                }
            }
        } secondary: {
            if let places = state.value, !places.isEmpty {
                ScreenKit.GroupCard(title: "Geofences", footer: "Managed in TeslaMate on your server. The price is TeslaMate's cost per kWh at that place.") {
                    ForEach(Array(places.enumerated()), id: \.element.id) { index, place in
                        ScreenKit.ValueRow(title: place.name, subtitle: subtitle(place), showsDivider: index < places.count - 1) {
                            Text(place.costPerKwh.map { "\(VoltaFormat.money($0, currency: units.currency))/kWh" } ?? "—")
                                .font(.subheadline.weight(.medium)).foregroundStyle(ScreenKit.secondary).monospacedDigit()
                        }
                    }
                }
                .voltaFocusIn(1)
            }
        }
        .screenKitPage("Places", screen: "places")
        .task(id: vehicleID) { await load() }
    }

    private func subtitle(_ place: Place) -> String {
        let radius = place.radiusM.map { units.distance == .miles ? "\(Int(($0 * 3.28084).rounded())) ft radius" : "\(Int($0.rounded())) m radius" }
        return radius ?? String(format: "%.4f, %.4f", place.latitude, place.longitude)
    }

    private func map(_ places: [Place]) -> some View {
        Map(initialPosition: .automatic, interactionModes: [.pan, .zoom]) {
            ForEach(places) { place in
                let coordinate = CLLocationCoordinate2D(latitude: place.latitude, longitude: place.longitude)
                MapCircle(center: coordinate, radius: place.radiusM ?? 100)
                    .foregroundStyle(ScreenKit.blue.opacity(0.25))
                    .stroke(ScreenKit.blue, lineWidth: 1.5)
                Annotation(place.name, coordinate: coordinate) {
                    Circle().fill(ScreenKit.blue).frame(width: 10, height: 10)
                        .overlay(Circle().stroke(Color.voltaOnAccent, lineWidth: 2))  // a pin's white rim, on both maps
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
        .modifier(ScreenKit.MapHeight())
        .clipShape(.rect(cornerRadius: VoltaRadius.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: VoltaRadius.card, style: .continuous).strokeBorder(Color.voltaHairline, lineWidth: 1))
    }

    private func load() async {
        do { state = .loaded(try await dataSource.places(vehicleID: vehicleID)) }
        catch is CancellationError {}
        catch { state = .failed(error.localizedDescription) }
    }
}

#Preview("Populated") { NavigationStack { PlacesView() }.voltaPreviewEnvironment() }
#Preview("Empty") {
    NavigationStack { PlacesView() }.voltaPreviewEnvironment(empty: true)
}
