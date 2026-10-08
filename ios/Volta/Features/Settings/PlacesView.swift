import MapKit
import SwiftUI

/// TeslaMate geofences for the selected vehicle.
struct PlacesView: View {
    @Environment(\.dataSource) private var dataSource
    @Environment(\.vehicleID) private var vehicleID
    @Environment(\.units) private var units
    @State private var state: Loadable<[Place]> = .loading

    var body: some View {
        ScrollView {
            LoadableContent(state: state, retry: load) { places in
                if places.isEmpty {
                    EmptyState(systemImage: "mappin.slash", title: "No saved places",
                               message: "Add geofences in TeslaMate and they'll appear here, named in your drives and charges.")
                        .padding(.top, 60)
                } else {
                    VStack(alignment: .leading, spacing: 22) {
                        map(places)
                        ScreenKit.GroupCard(title: "Geofences", footer: "Managed in TeslaMate on your server.") {
                            ForEach(Array(places.enumerated()), id: \.element.id) { index, place in
                                ScreenKit.ValueRow(title: place.name, subtitle: subtitle(place), showsDivider: index < places.count - 1) {
                                    Text(place.costPerKwh.map { "\(VoltaFormat.money($0, currency: units.currency))/kWh" } ?? "—")
                                        .font(.system(size: 14, weight: .medium)).foregroundStyle(ScreenKit.secondary).monospacedDigit()
                                }
                            }
                        }
                    }
                }
            }
            .padding(.horizontal, ScreenKit.horizontalPadding)
            .padding(.top, 8)
            .padding(.bottom, ScreenKit.bottomBarClearance)
        }
        .screenKitPage("Places")
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
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                }
            }
        }
        .mapStyle(.standard(elevation: .flat, emphasis: .muted, pointsOfInterest: .excludingAll))
        .environment(\.colorScheme, .dark)
        .frame(height: 220)
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
